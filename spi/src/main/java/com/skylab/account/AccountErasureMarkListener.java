package com.skylab.account;

import jakarta.ws.rs.core.HttpHeaders;
import org.jboss.logging.Logger;
import org.keycloak.common.util.Time;
import org.keycloak.events.Event;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.admin.AdminEvent;
import org.keycloak.events.admin.OperationType;
import org.keycloak.events.admin.ResourceType;
import org.keycloak.http.HttpRequest;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * The Account erasure mark (ADR-0051): tells the sign-in pages that a disabled person is being
 * erased, not disabled by an administrator, without asking core.
 *
 * <p>Core's erasure worker closes the identity in its first step, {@code disable_identity}, with
 * a PUT of exactly {@code {"enabled":false}} to Admin REST (no attributes, so nothing personal
 * reaches the UPDATE admin event, tests/erasure-event-pii.sh) and sends the request header
 * {@value #HEADER}{@code : }{@value #HEADER_VALUE} with it. Admin REST has no partial attribute
 * write (a PUT that names attributes replaces all of them), so this global listener writes the
 * mark: Keycloak calls it in the same request and transaction, once the update is authorised and
 * applied. On a person the update left disabled it sets {@value #ATTRIBUTE} to the time the
 * identity was closed (kept on a repeated disable); the attribute goes with the person at
 * {@code delete_identity}. An update without the header (an administrator, the Admin Console,
 * kcadm) marks nothing, and an update that leaves the person enabled removes the mark, so the
 * mark means exactly "disabled for erasure".
 *
 * <p>The attribute is unmanaged: under the realm's ADMIN_VIEW policy ({@link UserProfileGuard})
 * an administrator sees it read-only, nobody sets or clears it through Admin REST or the Account
 * Console, and a whole-representation PUT keeps it. The mark commits with the disable or not at
 * all. A failure while it is written is logged with a fixed word and does not refuse the disable:
 * the person then gets no erasure notice, as before.
 */
final class AccountErasureMarkListener implements EventListenerProvider {

    static final String HEADER = "X-Sky-Account-Erasure";
    static final String HEADER_VALUE = "disable_identity";
    static final String ATTRIBUTE = "skyAccountErasureDisabledAt";

    private static final Pattern USER_PATH = Pattern.compile("^users/([0-9A-Fa-f-]{36})$");
    private static final Logger LOG = Logger.getLogger(AccountErasureMarkListener.class);

    private final KeycloakSession session;

    AccountErasureMarkListener(KeycloakSession session) {
        this.session = session;
    }

    /** A disabled person, not a service account, whose identity core closed for erasure. */
    static boolean erasureInProgress(UserModel user) {
        return user != null && !user.isEnabled() && user.getServiceAccountClientLink() == null
                && user.getFirstAttribute(ATTRIBUTE) != null;
    }

    @Override
    public void onEvent(Event event) {
    }

    @Override
    public void onEvent(AdminEvent event, boolean includeRepresentation) {
        if (event.getResourceType() != ResourceType.USER || event.getOperationType() != OperationType.UPDATE
                || event.getError() != null || event.getResourcePath() == null) {
            return;
        }
        Matcher path = USER_PATH.matcher(event.getResourcePath());
        if (!path.matches()) {
            return;
        }
        try {
            RealmModel realm = session.realms().getRealm(event.getRealmId());
            UserModel user = realm == null ? null : session.users().getUserById(realm, path.group(1));
            if (user == null) {
                return;
            }
            boolean marked = user.getFirstAttribute(ATTRIBUTE) != null;
            if (user.isEnabled()) {
                if (marked) {
                    user.removeAttribute(ATTRIBUTE);
                }
            } else if (!marked && HEADER_VALUE.equals(header())) {
                user.setSingleAttribute(ATTRIBUTE, PersonalEmailProof.verifiedAt(Time.currentTime()));
            }
        } catch (RuntimeException failed) {
            LOG.error("sky_account_erasure_mark_failed");
            LOG.debug("sky-account erasure mark failure", failed);
        }
    }

    private String header() {
        HttpRequest request = session.getContext().getHttpRequest();
        HttpHeaders headers = request == null ? null : request.getHttpHeaders();
        String value = headers == null ? null : headers.getHeaderString(HEADER);
        return value == null ? null : value.strip();
    }

    @Override
    public void close() {
    }
}
