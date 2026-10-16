package com.skylab.account;

import org.keycloak.common.util.Time;
import org.keycloak.common.util.SecretGenerator;
import org.keycloak.models.SingleUseObjectProvider;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Map;

/** Six-digit, single-use Sudo proof, isolated from login, signup and personal-email codes. */
final class SudoEmailCodes {
    static final int TTL_SECONDS = SingleUseCodes.TTL_SECONDS;
    private final SingleUseCodes codes;
    private final SingleUseObjectProvider store;
    record Issued(String handle, String code, int expiresAt) { }

    SudoEmailCodes(SingleUseObjectProvider store) {
        this.store = store;
        codes = new SingleUseCodes(store, 6, notes -> notes.get("address") != null);
    }

    Issued issue(String realm, String user, String sid, String address) {
        String handle = SecretGenerator.getInstance().generateSecureID();
        int expiresAt = Time.currentTime() + TTL_SECONDS;
        String code = codes.issue(codeKey(handle), Map.of("address", address));
        return new Issued(handle, code, expiresAt);
    }

    /** Publish only after delivery succeeds; a failed send never replaces a delivered code. */
    boolean activate(String realm, String user, String sid, Issued issued) {
        int remaining = issued.expiresAt() - Time.currentTime();
        if (remaining <= 0) return false;
        store.put(key(realm, user, sid), remaining,
                Map.of("handle", issued.handle(), "expiresAt", Integer.toString(issued.expiresAt())));
        return true;
    }

    /** Delivery failures only own their issuance, never a newer send's pointer or code. */
    void discard(Issued issued) {
        codes.discard(codeKey(issued.handle()));
    }

    void discard(String realm, String user, String sid) {
        String handle = activeHandle(key(realm, user, sid));
        if (handle != null) codes.discard(codeKey(handle));
    }

    private String activeHandle(String bindingKey) {
        Map<String, String> pointer = store.get(bindingKey);
        if (pointer == null) return null;
        String handle = pointer.get("handle");
        if (handle == null || !handle.matches("[A-Za-z0-9_-]{16,128}")) return null;
        try {
            return Integer.parseInt(pointer.get("expiresAt")) > Time.currentTime() ? handle : null;
        } catch (NumberFormatException malformed) {
            return null;
        }
    }

    private static String codeKey(String handle) {
        return "sky-account:sudo-email-code:issuance:" + handle;
    }

    SingleUseCodes.Result confirm(String realm, String user, String sid, String address, String code) {
        String bindingKey = key(realm, user, sid);
        String handle = activeHandle(bindingKey);
        if (handle == null) return SingleUseCodes.Result.NONE;
        String key = codeKey(handle);
        SingleUseCodes.Entry pending = codes.peek(key);
        if (pending == null || pending.expiresAt() <= Time.currentTime()
                || !address.equals(pending.payload().get("address"))) {
            codes.discard(key);
            return SingleUseCodes.Result.NONE;
        }
        SingleUseCodes.Result result = codes.confirm(key, code);
        // Recheck the consumed payload as well: a send may replace the code after peek.
        if (!handle.equals(activeHandle(bindingKey))) return SingleUseCodes.Result.NONE;
        if (result.payload() != null && (!address.equals(result.payload().get("address"))
                || Integer.parseInt(result.payload().get("expiresAt")) <= Time.currentTime())) {
            return SingleUseCodes.Result.NONE;
        }
        return result;
    }

    private static String key(String realm, String user, String sid) {
        try {
            String binding = realm.length() + ":" + realm + user.length() + ":" + user + sid.length() + ":" + sid;
            return "sky-account:sudo-email-code:" + HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(binding.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 unavailable", exception);
        }
    }
}
