package com.skylab.account;

import org.keycloak.Token;
import org.keycloak.TokenCategory;
import org.keycloak.jose.JOSE;
import org.keycloak.jose.jws.JWSBuilder;
import org.keycloak.jose.jws.JWSInput;
import org.keycloak.jose.jws.crypto.HMACProvider;
import org.keycloak.models.AuthenticatedClientSessionModel;
import org.keycloak.models.ClientModel;
import org.keycloak.models.TokenManager;
import org.keycloak.models.UserModel;
import org.keycloak.representations.LogoutToken;

import java.util.function.BiConsumer;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Stands in for Keycloak's DefaultTokenManager: internal tokens are HS512 with the realm HMAC
 * key; every other category (ID tokens included) is signed with the realm's RS256 key.
 */
final class InternalKeyTokenManager implements TokenManager {

    static final String KID = "realm-hmac";

    private final byte[] key;

    InternalKeyTokenManager(byte[] key) {
        this.key = key;
    }

    @Override
    public String encode(Token token) {
        assertEquals(TokenCategory.INTERNAL, token.getCategory());
        return new JWSBuilder().kid(KID).type("JWT").jsonContent(token).hmac512(key);
    }

    @Override
    public <T extends Token> T decode(String token, Class<T> clazz) {
        try {
            JWSInput input = new JWSInput(token);
            if (input.getHeader().getAlgorithm() == null || !"HS512".equals(input.getHeader().getAlgorithm().name())) {
                return null;
            }
            return HMACProvider.verify(input, key) ? input.readJsonContent(clazz) : null;
        } catch (Exception exception) {
            return null;
        }
    }

    @Override
    public String signatureAlgorithm(TokenCategory category) {
        return category == TokenCategory.INTERNAL ? "HS512" : "RS256";
    }

    @Override
    public <T> T decodeClientJWT(String token, ClientModel client, BiConsumer<JOSE, ClientModel> jwtValidator,
            Class<T> clazz, boolean allowAlgorithmNone) {
        throw new UnsupportedOperationException();
    }

    @Override
    public String encodeAndEncrypt(Token token) {
        throw new UnsupportedOperationException();
    }

    @Override
    public String cekManagementAlgorithm(TokenCategory category) {
        return null;
    }

    @Override
    public String encryptAlgorithm(TokenCategory category) {
        return null;
    }

    @Override
    public LogoutToken initLogoutToken(ClientModel client, UserModel user, AuthenticatedClientSessionModel clientSessionModel) {
        throw new UnsupportedOperationException();
    }
}
