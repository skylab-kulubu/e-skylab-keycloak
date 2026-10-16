package com.skylab.account;

import org.keycloak.events.Event;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.EventType;
import org.keycloak.events.admin.AdminEvent;
import org.keycloak.models.AbstractKeycloakTransaction;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;

import java.util.LinkedHashSet;
import java.util.Set;

/** Resets at successful LOGIN commit, after TOTP/required actions; never on a partial code proof. */
final class LoginCodeFailuresListener implements EventListenerProvider {
    private final Set<String> logins = new LinkedHashSet<>();
    private final String realmId;

    LoginCodeFailuresListener(KeycloakSession session, LoginCodeFailureCounter counter) {
        // The transaction manager rejects new enlistments once preparation starts. Obtain JPA now.
        counter.prepare(session);
        RealmModel realm = session.getContext().getRealm();
        this.realmId = realm == null ? null : realm.getId();
        session.getTransactionManager().enlistPrepare(new AbstractKeycloakTransaction() {
            @Override
            protected void commitImpl() {
                for (String userId : logins) counter.reset(session, realm, userId);
                // An exception escapes the prepare phase, unlike EventBuilder.onEvent's swallowed
                // listener exceptions. Keycloak rolls back every transaction and fails the response.
            }

            @Override
            protected void rollbackImpl() { logins.clear(); }
        });
    }

    @Override
    public void onEvent(Event event) {
        if (event.getType() == EventType.LOGIN && event.getError() == null
                && event.getRealmId() != null && event.getUserId() != null) {
            if (event.getRealmId().equals(realmId)) logins.add(event.getUserId());
            // No provider/cache/DB access here. EventBuilder swallows callback exceptions, which
            // could otherwise leave a Direct Grant JWT response ready despite rollbackOnly.
        }
    }

    @Override
    public void onEvent(AdminEvent event, boolean includeRepresentation) { }

    @Override
    public void close() { }
}
