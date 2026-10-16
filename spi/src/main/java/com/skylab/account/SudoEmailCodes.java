package com.skylab.account;

import org.keycloak.common.util.Time;
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

    SudoEmailCodes(SingleUseObjectProvider store) {
        codes = new SingleUseCodes(store, 6, notes -> notes.get("address") != null);
    }

    String issue(String realm, String user, String sid, String address) {
        return codes.issue(key(realm, user, sid), Map.of("address", address));
    }

    void discard(String realm, String user, String sid) {
        codes.discard(key(realm, user, sid));
    }

    SingleUseCodes.Result confirm(String realm, String user, String sid, String address, String code) {
        String key = key(realm, user, sid);
        SingleUseCodes.Entry pending = codes.peek(key);
        if (pending == null || pending.expiresAt() <= Time.currentTime()
                || !address.equals(pending.payload().get("address"))) {
            codes.discard(key);
            return SingleUseCodes.Result.NONE;
        }
        SingleUseCodes.Result result = codes.confirm(key, code);
        // Recheck the consumed payload as well: a send may replace the code after peek.
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
