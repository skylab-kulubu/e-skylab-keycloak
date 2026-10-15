package com.skylab.account;

import org.keycloak.crypto.Algorithm;
import org.keycloak.crypto.KeyUse;
import org.keycloak.crypto.KeyWrapper;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;

import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.UnknownHostException;
import java.nio.charset.StandardCharsets;
import java.security.InvalidKeyException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.regex.Pattern;
import javax.crypto.Mac;
import javax.crypto.SecretKey;
import javax.crypto.spec.SecretKeySpec;

/**
 * The keys the sending budgets of a sign-in page are spent under ({@link RateLimiter}): the
 * first-login Personal e-mail offer ({@link PersonalEmailOffer}) and the Login code
 * ({@link EmailCodeAuthenticator}). A key is never the address, the IP or the session id itself,
 * only an HMAC of it under a realm secret ({@link #keyed}), and an IP enters it only as its class
 * ({@link #ipClass}); a key lives in memory until its window ends.
 */
final class BudgetKeys {

    private static final Pattern IPV4 = Pattern.compile("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$");
    private static final Pattern IPV6 = Pattern.compile("^[0-9a-fA-F:.]+$");

    private BudgetKeys() {
    }

    /**
     * The network an address belongs to, as a budget key: an IPv4 address's /24, an IPv6 address's
     * /64 (one subscriber), or {@code unknown} for anything that is not an address literal (no
     * name is ever resolved).
     */
    static String ipClass(String remote) {
        if (remote == null || remote.isBlank()) {
            return "unknown";
        }
        String literal = remote.strip();
        if (IPV4.matcher(literal).matches()) {
            String[] octets = literal.split("\\.");
            for (String octet : octets) {
                if (Integer.parseInt(octet) > 255) {
                    return "unknown";
                }
            }
            return "v4:" + Integer.parseInt(octets[0]) + "." + Integer.parseInt(octets[1]) + "." + Integer.parseInt(octets[2]);
        }
        try {
            // A string with a colon is only ever parsed as an IPv6 literal: no name is resolved.
            if (literal.indexOf(':') >= 0 && IPV6.matcher(literal).matches()) {
                InetAddress parsed = InetAddress.getByName(literal);
                byte[] bytes = parsed.getAddress();
                if (parsed instanceof Inet4Address) {
                    return "v4:" + (bytes[0] & 0xff) + "." + (bytes[1] & 0xff) + "." + (bytes[2] & 0xff);
                }
                if (parsed instanceof Inet6Address) {
                    return "v6:" + HexFormat.of().formatHex(bytes, 0, 8);
                }
            }
        } catch (UnknownHostException malformed) {
            return "unknown";
        }
        return "unknown";
    }

    /**
     * What the budget sub-key is derived for, so the realm's signing key is never used as is. The
     * name predates the Login code, whose budgets share the sub-key; the limit names keep their
     * keys apart.
     */
    static final String BUDGET_KEY_LABEL = "sky-personal-email-limits";

    /**
     * A budget key for {@code value} in this realm: HMAC-SHA256 under a sub-key derived from the
     * realm's active HS512 key (HMAC-SHA256 of {@value #BUDGET_KEY_LABEL} under it), a server secret
     * Keycloak keeps in its database, the same on every node, so a stored key cannot be turned back
     * into a /24 or an address by trying them all. Keycloak creates an HS512 key for a realm that has
     * none ({@code fallback-HS512}); only without a key manager (unit tests) is the key a SHA-256 of
     * the realm id and the value. Rotating the realm key only starts the budgets afresh.
     */
    static String keyed(KeycloakSession session, RealmModel realm, String value) {
        byte[] input = (realm.getId() + "/" + value).getBytes(StandardCharsets.UTF_8);
        SecretKey realmKey = realmHmacKey(session, realm);
        try {
            if (realmKey != null) {
                byte[] subKey = hmac(realmKey.getEncoded(), BUDGET_KEY_LABEL.getBytes(StandardCharsets.UTF_8));
                return "h" + HexFormat.of().formatHex(hmac(subKey, input));
            }
            return "s" + HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(input));
        } catch (NoSuchAlgorithmException | InvalidKeyException exception) {
            throw new IllegalStateException("HMAC-SHA256 or SHA-256 is unavailable", exception);
        }
    }

    private static byte[] hmac(byte[] key, byte[] input) throws NoSuchAlgorithmException, InvalidKeyException {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        return mac.doFinal(input);
    }

    private static SecretKey realmHmacKey(KeycloakSession session, RealmModel realm) {
        if (session.keys() == null) {
            return null;
        }
        KeyWrapper key = session.keys().getActiveKey(realm, KeyUse.SIG, Algorithm.HS512);
        return key == null || key.getSecretKey() == null || key.getSecretKey().getEncoded() == null
                ? null : key.getSecretKey();
    }
}
