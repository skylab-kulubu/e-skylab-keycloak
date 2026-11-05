package com.skylab.account;

import org.keycloak.email.EmailException;
import org.keycloak.email.EmailTemplateProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * The mail a person whose Account erasure is running gets when somebody asks "E-postayla devam et"
 * for a code to their account: the account is being deleted, and the address can sign up again
 * once it is. Without it the page said a code was on its way and none ever came.
 *
 * <p>The page does not change: {@link EmailCodeAuthenticator} hands every disabled person to this
 * mail after the request, exactly as it hands a code, so neither the page nor its time tells a
 * disabled account from any other. Here, in the background, only a person core closed for erasure
 * ({@link AccountErasureMarkListener}) is mailed; one an administrator disabled gets nothing, as
 * before. The mail goes where that person's Login codes would go ({@link EmailCodeAuthenticator#mailbox})
 * and at most once an hour to an address: the first notice keeps a store entry under a keyed hash of
 * the address ({@link BudgetKeys}) for {@value #WINDOW_SECONDS} seconds. It is Keycloak's generic
 * template send of {@value #MAIL_TEMPLATE}, which the SkyMail provider routes to SkyMail's
 * {@code account.deletion-in-progress} and Keycloak's own SMTP renders from this extension's copy
 * when SkyMail is unreachable. It carries no code, link or name, and asks SkyMail to keep no record
 * of it ({@code erase_after_send}): the person's Erasure command may have run in SkyMail already.
 */
public final class AccountErasureNotice {

    /** The mail ({@code theme-resources/templates/{text,html}/}); the SkyMail provider routes it by this name. */
    public static final String MAIL_TEMPLATE = "sky-account-erasure-notice.ftl";
    static final String SUBJECT_KEY = "skyAccountErasureNoticeSubject";
    /** At most one notice to an address in this many seconds. */
    static final int WINDOW_SECONDS = 60 * 60;
    static final String KEY_PREFIX = "sky-account:erasure-notice:";

    private AccountErasureNotice() {
    }

    /**
     * Mails the notice to the person with {@code userId} when their erasure is running, they have
     * somewhere to be mailed, and their address had none in the last hour. Returns whether it was
     * handed to the mail provider.
     */
    static boolean deliver(KeycloakSession session, RealmModel realm, String userId, String ytuIdpAlias)
            throws EmailException {
        UserModel user = session.users().getUserById(realm, userId);
        if (!AccountErasureMarkListener.erasureInProgress(user)) {
            return false;
        }
        String address = EmailCodeAuthenticator.mailbox(session, realm, user, ytuIdpAlias);
        if (address == null) {
            return false;
        }
        String key = KEY_PREFIX + BudgetKeys.keyed(session, realm, PersonalEmailProof.normalise(address));
        if (!session.singleUseObjects().putIfAbsent(key, WINDOW_SECONDS)) {
            return false;
        }
        // Mutable: Keycloak's FreeMarker provider puts the resolved locale into this very map.
        Map<String, Object> attributes = new HashMap<>();
        session.getProvider(EmailTemplateProvider.class)
                .setRealm(realm)
                .setUser(user)
                .send(SUBJECT_KEY, List.of(), MAIL_TEMPLATE, attributes, address);
        return true;
    }
}
