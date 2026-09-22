package com.skylab.handoff;

import org.keycloak.common.util.Base64Url;
import org.keycloak.common.util.SecretGenerator;
import org.keycloak.common.util.Time;
import org.keycloak.models.SingleUseObjectProvider;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HashMap;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * Handoff codes in Keycloak's single-use object store, shared by every cluster node.
 *
 * <p>A code and its proof are 32 random bytes each (base64url, 43 characters). The store keeps
 * only SHA-256 hashes of both, so a dump of the store cannot be replayed. Next to the code a
 * longer-lived tombstone records who the code was for and when it expires, which is what lets a
 * failed redemption say {@code used} or {@code expired} instead of a bare {@code invalid}.
 *
 * <p>Redemption checks the proof before it consumes the code: a link opened without its proof
 * (a leaked URL, a prefetch) is {@code invalid} and leaves the code for the WebView that holds
 * the proof. Consuming is {@link SingleUseObjectProvider#remove}, which the store guarantees to
 * succeed for exactly one caller, so concurrent opens redeem a code once.
 */
final class HandoffStore {

    static final int TTL_SECONDS = 45;
    /** How long a code is remembered after it was minted, to tell {@code used} and {@code expired} from {@code invalid}. */
    static final int TOMBSTONE_SECONDS = 10 * 60;
    static final int SECRET_BYTES = 32;

    private static final Pattern OPAQUE = Pattern.compile("^[A-Za-z0-9_-]{43}$");
    private static final String CODE_PREFIX = "sky-handoff:code:";
    private static final String TOMBSTONE_PREFIX = "sky-handoff:tombstone:";

    private static final String REALM = "rid";
    private static final String USER = "uid";
    private static final String SOURCE_SESSION = "sid";
    private static final String SOURCE_OFFLINE = "soff";
    private static final String AUTH_TIME = "at";
    private static final String CLIENT = "cid";
    private static final String PATH = "path";
    private static final String IP_ADDRESS = "ip";
    private static final String PROOF_HASH = "ph";
    private static final String EXPIRES_AT = "exp";
    private static final String USED = "used";

    private final SingleUseObjectProvider store;

    HandoffStore(SingleUseObjectProvider store) {
        this.store = store;
    }

    /** A freshly minted code, the proof the WebView must present with it, and its lifetime. */
    record Minted(String code, String proof, int expiresIn) {
    }

    /** The outcome of opening a code. */
    sealed interface Redemption permits Redeemed, Refused {
    }

    /** The code was valid, the proof matched and this caller consumed it. */
    record Redeemed(HandoffGrant grant) implements Redemption {
    }

    /**
     * The code cannot be redeemed. {@code userId} and {@code clientId} name the person and the
     * target when the code is known, for the audit event; both are {@code null} otherwise.
     */
    record Refused(FailureReason reason, String userId, String clientId) implements Redemption {
    }

    Minted mint(HandoffGrant grant) {
        String code = randomSecret();
        String proof = randomSecret();
        long expiresAt = (long) Time.currentTime() + TTL_SECONDS;

        Map<String, String> notes = new HashMap<>();
        notes.put(REALM, grant.realmId());
        notes.put(USER, grant.userId());
        notes.put(SOURCE_SESSION, grant.sourceSessionId());
        notes.put(SOURCE_OFFLINE, Boolean.toString(grant.sourceOffline()));
        notes.put(AUTH_TIME, Long.toString(grant.authTime()));
        notes.put(CLIENT, grant.clientId());
        notes.put(PATH, grant.path());
        if (grant.ipAddress() != null) {
            notes.put(IP_ADDRESS, grant.ipAddress());
        }
        notes.put(PROOF_HASH, sha256(proof));
        notes.put(EXPIRES_AT, Long.toString(expiresAt));

        String hash = sha256(code);
        store.put(TOMBSTONE_PREFIX + hash, TOMBSTONE_SECONDS, tombstone(grant.userId(), grant.clientId(), expiresAt, false));
        store.put(CODE_PREFIX + hash, TTL_SECONDS, notes);
        return new Minted(code, proof, TTL_SECONDS);
    }

    Redemption redeem(String code, String proof, String realmId) {
        if (code == null || !OPAQUE.matcher(code).matches()) {
            return new Refused(FailureReason.INVALID, null, null);
        }
        String hash = sha256(code);
        String key = CODE_PREFIX + hash;
        Map<String, String> notes = store.get(key);
        if (notes == null) {
            return fromTombstone(hash);
        }
        String userId = notes.get(USER);
        String clientId = notes.get(CLIENT);
        if (!realmId.equals(notes.get(REALM))) {
            return new Refused(FailureReason.INVALID, null, null);
        }
        if (isPast(notes.get(EXPIRES_AT))) {
            store.remove(key);
            return new Refused(FailureReason.EXPIRED, userId, clientId);
        }
        if (!proofMatches(proof, notes.get(PROOF_HASH))) {
            return new Refused(FailureReason.INVALID, userId, clientId);
        }
        Map<String, String> consumed = store.remove(key);
        if (consumed == null) {
            return fromTombstone(hash);
        }
        markUsed(hash, userId, clientId, consumed.get(EXPIRES_AT));
        final HandoffGrant grant;
        try {
            grant = new HandoffGrant(
                    consumed.get(REALM),
                    consumed.get(USER),
                    consumed.get(SOURCE_SESSION),
                    Boolean.parseBoolean(consumed.get(SOURCE_OFFLINE)),
                    Long.parseLong(consumed.get(AUTH_TIME)),
                    consumed.get(CLIENT),
                    consumed.get(PATH),
                    consumed.get(IP_ADDRESS));
        } catch (RuntimeException exception) {
            return new Refused(FailureReason.INVALID, userId, clientId);
        }
        if (grant.userId() == null || grant.sourceSessionId() == null || grant.clientId() == null || grant.path() == null) {
            return new Refused(FailureReason.INVALID, userId, clientId);
        }
        return new Redeemed(grant);
    }

    private Refused fromTombstone(String hash) {
        Map<String, String> tombstone = store.get(TOMBSTONE_PREFIX + hash);
        if (tombstone == null) {
            return new Refused(FailureReason.INVALID, null, null);
        }
        String userId = tombstone.get(USER);
        String clientId = tombstone.get(CLIENT);
        if ("true".equals(tombstone.get(USED))) {
            return new Refused(FailureReason.USED, userId, clientId);
        }
        // Gone before its expiry and not yet marked: another open consumed it a moment ago.
        return new Refused(isPast(tombstone.get(EXPIRES_AT)) ? FailureReason.EXPIRED : FailureReason.USED, userId, clientId);
    }

    private void markUsed(String hash, String userId, String clientId, String expiresAt) {
        long expiry = parseOrZero(expiresAt);
        Map<String, String> used = tombstone(userId, clientId, expiry, true);
        String key = TOMBSTONE_PREFIX + hash;
        if (!store.replace(key, used)) {
            store.put(key, TOMBSTONE_SECONDS, used);
        }
    }

    private static Map<String, String> tombstone(String userId, String clientId, long expiresAt, boolean used) {
        Map<String, String> notes = new HashMap<>();
        if (userId != null) {
            notes.put(USER, userId);
        }
        if (clientId != null) {
            notes.put(CLIENT, clientId);
        }
        notes.put(EXPIRES_AT, Long.toString(expiresAt));
        notes.put(USED, Boolean.toString(used));
        return notes;
    }

    private static boolean isPast(String expiresAt) {
        return Time.currentTime() > parseOrZero(expiresAt);
    }

    private static long parseOrZero(String value) {
        try {
            return value == null ? 0 : Long.parseLong(value);
        } catch (NumberFormatException exception) {
            return 0;
        }
    }

    private static boolean proofMatches(String presented, String expectedHash) {
        if (presented == null || expectedHash == null || !OPAQUE.matcher(presented).matches()) {
            return false;
        }
        return MessageDigest.isEqual(
                sha256(presented).getBytes(StandardCharsets.US_ASCII),
                expectedHash.getBytes(StandardCharsets.US_ASCII));
    }

    private static String randomSecret() {
        return Base64Url.encode(SecretGenerator.getInstance().randomBytes(SECRET_BYTES));
    }

    static String sha256(String value) {
        try {
            return Base64Url.encode(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.US_ASCII)));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }
}
