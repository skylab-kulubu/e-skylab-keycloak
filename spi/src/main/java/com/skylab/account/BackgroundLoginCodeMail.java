package com.skylab.account;

import com.skylab.mail.SkyMailNotice;
import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.MultivaluedHashMap;
import jakarta.ws.rs.core.MultivaluedMap;
import jakarta.ws.rs.core.UriInfo;
import org.jboss.logging.Logger;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.email.EmailTemplateProvider;
import org.keycloak.executors.ExecutorsProvider;
import org.keycloak.http.FormPartValue;
import org.keycloak.http.HttpRequest;
import org.keycloak.models.GroupModel;
import org.keycloak.models.AbstractKeycloakTransaction;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.utils.KeycloakModelUtils;
import org.keycloak.storage.adapter.InMemoryUserAdapter;

import java.security.cert.X509Certificate;
import java.net.URI;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Executor;

/**
 * Sends the Login code and the operator alarm after the request, on Keycloak's executor
 * {@value #EXECUTOR}, each in a session of its own: the sign-in page answers in the same time
 * whether or not a mail goes out (spec §7.4), and a slow SkyMail never holds a sign-in page.
 *
 * <p>The code mail is Keycloak's generic template send with {@link EmailCodeAuthenticator#MAIL_TEMPLATE}:
 * the SkyMail provider routes exactly that name to SkyMail's {@code keycloak.login-code} (ADR-0045),
 * and Keycloak's own SMTP renders this extension's FreeMarker copy when SkyMail is unreachable. The
 * background session gets the realm and the request's URI (SkyMail's token endpoint is derived from
 * it), as Keycloak's brute-force protector does for its own background work; it has no request
 * headers, so the mail is in the person's or the realm's language.
 *
 * <p>Neither the address nor the code reaches a log: a mail that cannot be sent is logged by user
 * id with a fixed word, and the SMTP diagnostics stay at DEBUG.
 */
final class BackgroundLoginCodeMail implements LoginCodeMail {

    static final String EXECUTOR = "sky-email-code";
    static final String SUBJECT_KEY = "skyLoginCodeSubject";
    static final String SIGN_UP_SUBJECT_KEY = "skySignUpCodeSubject";
    static final String ALARM_HALF_SUBJECT_KEY = "skyLoginCodeAlarmHalfSubject";
    static final String ALARM_FULL_SUBJECT_KEY = "skyLoginCodeAlarmFullSubject";
    static final String ALARM_CEILING_SUBJECT_KEY = "skyLoginCodeAlarmCeilingSubject";
    static final String ALARM_CONSECUTIVE_SUBJECT_KEY = "skyLoginCodeAlarmConsecutiveSubject";

    private static final Logger LOG = Logger.getLogger(BackgroundLoginCodeMail.class);

    private final EmailCodeSettings settings;

    BackgroundLoginCodeMail(EmailCodeSettings settings) {
        this.settings = settings;
    }

    @Override
    public void sendCode(AuthenticationFlowContext context, UserModel user, String address, String code, String purpose) {
        String userId = user.getId();
        run(context, "sky_email_code_send_failed user=" + userId, (session, realm) -> {
            UserModel recipient = session.users().getUserById(realm, userId);
            if (recipient == null) {
                return;
            }
            // Mutable: Keycloak's FreeMarker provider puts the resolved locale into this very map.
            Map<String, Object> attributes = new HashMap<>();
            attributes.put("code", code);
            attributes.put("codeExpiration", LoginCodes.TTL_SECONDS / 60);
            attributes.put("purpose", purpose);
            session.getProvider(EmailTemplateProvider.class)
                    .setRealm(realm)
                    .setUser(recipient)
                    .send(SUBJECT_KEY, List.of(), EmailCodeAuthenticator.MAIL_TEMPLATE, attributes, address);
        });
    }

    /**
     * The sign-up code (eskylab-login-ux 09) goes to an address that has no account, so Keycloak's
     * template providers, which render for a person, get a stand-in that exists only in memory: its
     * address, and the language the sign-in page was shown in (the background session has no
     * request headers to resolve it from). Nothing of it is stored.
     */
    @Override
    public void sendSignUpCode(AuthenticationFlowContext context, String address, String code) {
        String language = requestLanguage(context);
        run(context, "sky_email_code_send_failed purpose=" + EmailCodeSignUp.SIGN_UP, (session, realm) -> {
            UserModel recipient = new InMemoryUserAdapter(session, realm, SIGN_UP_RECIPIENT_ID);
            recipient.setEmail(address);
            if (language != null) {
                recipient.setSingleAttribute(UserModel.LOCALE, language);
            }
            Map<String, Object> attributes = new HashMap<>();
            attributes.put("code", code);
            attributes.put("codeExpiration", LoginCodes.TTL_SECONDS / 60);
            attributes.put("purpose", LoginCodes.SIGN_UP_PURPOSE);
            session.getProvider(EmailTemplateProvider.class)
                    .setRealm(realm)
                    .setUser(recipient)
                    .send(SIGN_UP_SUBJECT_KEY, List.of(), EmailCodeAuthenticator.MAIL_TEMPLATE, attributes, address);
        });
    }

    /** The id of the in-memory stand-in a sign-up code is rendered for; never a stored account. */
    static final String SIGN_UP_RECIPIENT_ID = "sky-email-code-sign-up";

    /** The sign-in page's language, resolved in the request thread; null when it cannot be. */
    private static String requestLanguage(AuthenticationFlowContext context) {
        try {
            Locale locale = context.getSession().getContext().resolveLocale(null);
            return locale == null ? null : locale.toLanguageTag();
        } catch (RuntimeException unresolvable) {
            return null;
        }
    }

    /**
     * The operator alarm goes to every enabled member of the alarm group (default {@code /ADMIN})
     * who has an e-mail address, one SkyMail single mail each, with keycloak-mailer's own
     * {@code skymail:mails:send}: SkyMail's own group send ({@code POST /v1/mail_tasks}) would need
     * {@code skymail:mails:write}, which this service account does not have and does not get.
     */
    @Override
    public void alarm(AuthenticationFlowContext context, String level, int dailyLimit) {
        String realmName = context.getRealm().getName();
        LOG.warnf("sky_email_code_budget level=%s daily_limit=%d realm=%s", level, dailyLimit, realmName);
        boolean full = FULL.equals(level);
        mailAlarmGroup(context, full ? ALARM_FULL_SUBJECT_KEY : ALARM_HALF_SUBJECT_KEY, alarmSubject(full),
                alarmText(realmName, full, dailyLimit));
    }

    /**
     * The first account of the day at the wrong-code ceiling (security review K2): the same group
     * gets a mail; the log line of every such account is the authenticator's.
     */
    @Override
    public void ceilingAlarm(AuthenticationFlowContext context, int ceiling, int accounts) {
        mailAlarmGroup(context, ALARM_CEILING_SUBJECT_KEY, ceilingSubject(),
                ceilingText(context.getRealm().getName(), ceiling, accounts));
    }

    /** Capture only immutable, person-free data and long-lived factory/executor while the request is open. */
    @Override
    public void consecutiveAlarm(AuthenticationFlowContext context, int limit) {
        if (settings.alarmGroup() == null) return;
        KeycloakSession requestSession = context.getSession();
        KeycloakSessionFactory factory = requestSession.getKeycloakSessionFactory();
        Executor executor = requestSession.getProvider(ExecutorsProvider.class).getExecutor(EXECUTOR);
        ConsecutiveNotice notice = new ConsecutiveNotice(context.getRealm().getId(), context.getRealm().getName(),
                settings.alarmGroup(), context.getUriInfo().getBaseUri(), limit);
        requestSession.getTransactionManager().enlistAfterCompletion(new AbstractKeycloakTransaction() {
            @Override
            protected void commitImpl() {
                LOG.warnf("sky_email_code_consecutive_limit limit=%d realm=%s", notice.limit(), notice.realmName());
                try {
                executor.execute(() -> {
                    try {
                        KeycloakModelUtils.runJobInTransaction(factory, session -> {
                            RealmModel realm = session.realms().getRealm(notice.realmId());
                            if (realm == null) return;
                            session.getContext().setRealm(realm);
                            session.getContext().setHttpRequest(new DetachedRequest(new DetachedBaseUri(notice.baseUri())));
                            deliverAlarm(session, realm, notice.groupPath(), ALARM_CONSECUTIVE_SUBJECT_KEY,
                                    "SKY LAB: bir hesap ardışık yanlış e-posta kodu sınırına ulaştı",
                                    consecutiveText(notice.realmName(), notice.limit()));
                        });
                    } catch (RuntimeException failed) {
                        LOG.error("sky_email_code_consecutive_alarm_failed");
                    }
                });
                } catch (RuntimeException rejected) {
                    LOG.error("sky_email_code_consecutive_alarm_failed");
                }
            }

            @Override
            protected void rollbackImpl() { }
        });
    }

    private record ConsecutiveNotice(String realmId, String realmName, String groupPath, URI baseUri, int limit) { }

    static String consecutiveText(String realmName, int limit) {
        return "Keycloak'ın " + realmName + " realm'inde bir hesap " + limit + " ardışık yanlış e-posta kodu sınırına ulaştı.\n"
                + "O hesaba giriş/hesap bağlama kodu gönderilmez ve kodlar denetlenmez; ekran aynı kalır.\n"
                + "Gün dönümü veya yeniden başlatma sınırı kaldırmaz. Başarılı gerçek giriş veya yetkili bakım sıfırlar.\n"
                + "Parola, passkey ve YTÜ girişi etkilenmez. Bu uyarı her sınıra ulaşma geçişinde bir kez üretilir.\n";
    }

    private void mailAlarmGroup(AuthenticationFlowContext context, String subjectKey, String subject, String text) {
        String realmName = context.getRealm().getName();
        String groupPath = settings.alarmGroup();
        if (groupPath == null) {
            return;
        }
        run(context, "sky_email_code_alarm_failed realm=" + realmName, (session, realm) ->
                deliverAlarm(session, realm, groupPath, subjectKey, subject, text));
    }

    private static void deliverAlarm(KeycloakSession session, RealmModel realm, String groupPath,
            String subjectKey, String subject, String text) {
        List<UserModel> recipients = alarmRecipients(session, realm, groupPath);
        if (recipients.isEmpty()) {
            LOG.warnf("sky_email_code_alarm_unsent reason=no_recipient realm=%s", realm.getName());
            return;
        }
        int failed = 0;
        for (UserModel recipient : recipients) {
            try {
                SkyMailNotice.sendLoginCodeAlarm(session, realm, subjectKey, recipient, subject, text);
            } catch (Exception exception) {
                failed++;
                LOG.debug("sky-email-code alarm failure", exception);
            }
        }
        if (failed > 0) {
            LOG.errorf("sky_email_code_alarm_failed realm=%s failed=%d of=%d", realm.getName(), failed, recipients.size());
        }
    }

    /** At most this many members of the alarm group are mailed. */
    static final int MAX_ALARM_RECIPIENTS = 50;

    /**
     * The enabled members of the group at {@code groupPath} that have an e-mail address, at most
     * {@value #MAX_ALARM_RECIPIENTS}; none when the realm has no such group (the sandbox realm may not).
     */
    static List<UserModel> alarmRecipients(KeycloakSession session, RealmModel realm, String groupPath) {
        GroupModel group = KeycloakModelUtils.findGroupByPath(session, realm, groupPath);
        if (group == null) {
            return List.of();
        }
        return session.users().getGroupMembersStream(realm, group, 0, MAX_ALARM_RECIPIENTS)
                .filter(UserModel::isEnabled)
                .filter(user -> user.getEmail() != null && !user.getEmail().isBlank())
                .toList();
    }

    static String alarmSubject(boolean full) {
        return full
                ? "SKY LAB: e-posta kodu gönderimi günlük sınıra ulaştı"
                : "SKY LAB: e-posta kodu gönderimi günlük sınırın yarısında";
    }

    /** No person, no address, no IP: only the realm and the counts. */
    static String alarmText(String realmName, boolean full, int dailyLimit) {
        return (full
                ? "Keycloak'ın " + realmName + " realm'inde bugün (UTC günü) " + dailyLimit
                        + " e-posta kodu gönderildi; günlük genel sınır doldu.\n"
                : "Keycloak'ın " + realmName + " realm'inde bugün (UTC günü) " + (dailyLimit / 2)
                        + " e-posta kodu gönderildi; günlük genel sınır " + dailyLimit + ".\n")
                + "Giriş kodları sınırdan sonra da gider. Beklenmedik bir artışsa Keycloak olaylarına bakın "
                + "(LOGIN_ERROR, sky_email_code) ve SkyMail'in keycloak.login-code gönderimlerine bakın.\n"
                + "Bu posta Keycloak'ın e-posta kodu girişinden (sky-email-code) otomatik gelir.\n";
    }

    static String ceilingSubject() {
        return "SKY LAB: bir hesap e-posta kodunda günlük yanlış kod tavanına ulaştı";
    }

    /** No person, no address, no IP: the realm, the ceiling and how many accounts reached it so far. */
    static String ceilingText(String realmName, int ceiling, int accounts) {
        return "Keycloak'ın " + realmName + " realm'inde bugün (UTC günü) " + accounts
                + " hesap e-posta kodunda günlük yanlış kod tavanına (" + ceiling + " yanlış kod) ulaştı.\n"
                + "O hesaplara gün bitene kadar yeni kod postalanmaz; ekran kod isteyene aynı görünür. "
                + "Parola, passkey ve YTÜ girişi etkilenmez.\n"
                + "Bu uyarı günde bir kez gelir; gün içinde tavana ulaşan sonraki hesaplar yalnız sunucu "
                + "günlüğünde sayılır (sky_email_code_wrong_ceiling accounts=…). Keycloak olaylarında "
                + "LOGIN_ERROR, ayrıntı sky_email_code=wrong_code ve wrong_code_ceiling.\n"
                + "Bu posta Keycloak'ın e-posta kodu girişinden (sky-email-code) otomatik gelir.\n";
    }

    /** A mail job: the realm of the request and its URI in a session of its own, after the request. */
    interface MailJob {
        void run(KeycloakSession session, RealmModel realm) throws Exception;
    }

    private static void run(AuthenticationFlowContext context, String failureLine, MailJob job) {
        KeycloakSession requestSession = context.getSession();
        KeycloakSessionFactory factory = requestSession.getKeycloakSessionFactory();
        String realmId = context.getRealm().getId();
        UriInfo uri = context.getUriInfo();
        Executor executor = requestSession.getProvider(ExecutorsProvider.class).getExecutor(EXECUTOR);
        executor.execute(() -> {
            try {
                KeycloakModelUtils.runJobInTransaction(factory, session -> {
                    RealmModel realm = session.realms().getRealm(realmId);
                    if (realm == null) {
                        return;
                    }
                    session.getContext().setRealm(realm);
                    session.getContext().setHttpRequest(new DetachedRequest(uri));
                    try {
                        job.run(session, realm);
                    } catch (Exception exception) {
                        throw new MailFailed(exception);
                    }
                });
            } catch (RuntimeException failure) {
                LOG.error(failureLine);
                LOG.debug("sky-email-code mail failure", failure);
            }
        });
    }

    /** Carries a checked mail failure out of the transaction, so it rolls back and is logged once. */
    private static final class MailFailed extends RuntimeException {
        MailFailed(Exception cause) {
            super(cause);
        }
    }

    /**
     * The request this mail belongs to, after it ended: only its URI (Keycloak's issuer, from which
     * SkyMail's token endpoint is derived), no headers, no form. Keycloak's brute-force protector
     * runs its background work with the same kind of request.
     */
    private record DetachedRequest(UriInfo uri) implements HttpRequest {

        @Override
        public String getHttpMethod() {
            return "";
        }

        @Override
        public MultivaluedMap<String, String> getDecodedFormParameters() {
            return new MultivaluedHashMap<>();
        }

        @Override
        public MultivaluedMap<String, FormPartValue> getMultiPartFormParameters() {
            return new MultivaluedHashMap<>();
        }

        @Override
        public HttpHeaders getHttpHeaders() {
            return null;
        }

        @Override
        public X509Certificate[] getClientCertificateChain() {
            return null;
        }

        @Override
        public UriInfo getUri() {
            return uri;
        }

        @Override
        public boolean isProxyTrusted() {
            return true;
        }
    }
}
