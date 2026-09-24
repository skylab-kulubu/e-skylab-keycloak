package com.skylab.account;

import com.fasterxml.jackson.annotation.JsonProperty;
import org.keycloak.TokenCategory;
import org.keycloak.representations.JsonWebToken;

import java.util.List;

/**
 * The Sudo mode proof: a short-lived JWT that Keycloak signs as an internal token
 * ({@link TokenCategory#INTERNAL}: HS512 with the realm's HMAC key, which never leaves
 * Keycloak, so nobody outside can mint one or verify one without asking Keycloak's
 * introspection endpoint) and binds to the person ({@code sub})
 * and to the Account Center session ({@code sid}) that proved a credential.
 */
public final class SudoToken extends JsonWebToken {

    @JsonProperty("sid")
    private String sessionId;

    @JsonProperty("amr")
    private List<String> authenticationMethods;

    public String getSessionId() {
        return sessionId;
    }

    public void setSessionId(String sessionId) {
        this.sessionId = sessionId;
    }

    public List<String> getAuthenticationMethods() {
        return authenticationMethods;
    }

    public void setAuthenticationMethods(List<String> authenticationMethods) {
        this.authenticationMethods = authenticationMethods;
    }

    @Override
    public TokenCategory getCategory() {
        return TokenCategory.INTERNAL;
    }
}
