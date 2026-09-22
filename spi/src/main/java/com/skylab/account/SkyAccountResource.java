package com.skylab.account;

import jakarta.ws.rs.Path;
import org.keycloak.models.KeycloakSession;

/**
 * {@code /realms/{realm}/sky-account/v1}: the self-service identity and credential surface the
 * Account Center BFF calls on behalf of the signed-in person. Every request needs a live
 * Account Center user token; every mutation additionally needs a fresh Sudo mode token.
 */
public final class SkyAccountResource {

    private final AccountRequest request;

    public SkyAccountResource(KeycloakSession session, String ytuIdpAlias) {
        this.request = new AccountRequest(session, ytuIdpAlias);
    }

    @Path("v1/identity")
    public IdentityResource identity() {
        return new IdentityResource(request);
    }

    @Path("v1/sudo")
    public SudoResource sudo() {
        return new SudoResource(request);
    }

    @Path("v1/credentials")
    public CredentialResource credentials() {
        return new CredentialResource(request);
    }

    @Path("v1/email")
    public EmailResource email() {
        return new EmailResource(request);
    }
}
