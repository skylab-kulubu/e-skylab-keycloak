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
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.utils.KeycloakModelUtils;

import java.security.cert.X509Certificate;
import java.util.HashMap;
import java.util.List;
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
    static final String ALARM_HALF_SUBJECT_KEY = "skyLoginCodeAlarmHalfSubject";
    static final String ALARM_FULL_SUBJECT_KEY = "skyLoginCodeAlarmFullSubject";

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
     * The operator alarm goes to every enabled member of the alarm group (default {@code /ADMIN})
     * who has an e-mail address, one SkyMail single mail each, with keycloak-mailer's own
     * {@code skymail:mails:send}: SkyMail's own group send ({@code POST /v1/mail_tasks}) would need
     * {@code skymail:mails:write}, which this service account does not have and does not get.
     */
    @Override
    public void alarm(AuthenticationFlowContext context, String level, int dailyLimit) {
        String realmName = context.getRealm().getName();
        LOG.warnf("sky_email_code_budget level=%s daily_limit=%d realm=%s", level, dailyLimit, realmName);
        String groupPath = settings.alarmGroup();
        if (groupPath == null) {
            return;
        }
        boolean full = FULL.equals(level);
        run(context, "sky_email_code_alarm_failed realm=" + realmName, (session, realm) -> {
            List<UserModel> recipients = alarmRecipients(session, realm, groupPath);
            if (recipients.isEmpty()) {
                LOG.warnf("sky_email_code_alarm_unsent reason=no_recipient realm=%s", realmName);
                return;
            }
            int failed = 0;
            for (UserModel recipient : recipients) {
                try {
                    SkyMailNotice.sendLoginCodeAlarm(session, realm,
                            full ? ALARM_FULL_SUBJECT_KEY : ALARM_HALF_SUBJECT_KEY,
                            recipient, alarmSubject(full), alarmText(realmName, full, dailyLimit));
                } catch (Exception exception) {
                    failed++;
                    LOG.debug("sky-email-code alarm failure", exception);
                }
            }
            if (failed > 0) {
                LOG.errorf("sky_email_code_alarm_failed realm=%s failed=%d of=%d", realmName, failed, recipients.size());
            }
        });
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
