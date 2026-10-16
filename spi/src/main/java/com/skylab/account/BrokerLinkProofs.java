package com.skylab.account;

import org.keycloak.common.util.Time;
import org.keycloak.models.SingleUseObjectProvider;

import java.util.HashMap;
import java.util.Map;

/** Single-use link codes and callback proofs, never interchangeable with login or sign-up codes. */
final class BrokerLinkProofs {
    static final int PROOF_TTL_SECONDS = 120;
    private static final String PURPOSE = "link";
    private static final String CODE_PREFIX = "sky-broker-link-code:";
    private static final String PROOF_PREFIX = "sky-broker-link-proof:";

    /** Every identity and session component the two independent proofs must agree on. */
    record Binding(String realm, String root, String tab, String client, String provider, String subject,
                   String school, String target, String primary, String firstName, String lastName) {
        Map<String, String> notes() {
            Map<String, String> values = new HashMap<>();
            values.put("realm", realm);
            values.put("root", root);
            values.put("tab", tab);
            values.put("client", client);
            values.put("provider", provider);
            values.put("subject", subject);
            values.put("school", school);
            values.put("target", target);
            values.put("primary", primary);
            values.put("firstName", firstName);
            values.put("lastName", lastName);
            return Map.copyOf(values);
        }

        static Binding read(Map<String, String> values) {
            if (values == null) return null;
            for (String key : new String[]{"realm", "root", "tab", "client", "provider", "subject", "school",
                    "target", "primary", "firstName", "lastName"}) {
                String value = values.get(key);
                if (value == null || value.length() > 512) return null;
            }
            for (String key : new String[]{"realm", "root", "tab", "client", "provider", "subject", "school"}) {
                if (values.get(key).isBlank()) return null;
            }
            return new Binding(values.get("realm"), values.get("root"), values.get("tab"), values.get("client"),
                    values.get("provider"), values.get("subject"), values.get("school"), values.get("target"),
                    values.get("primary"), values.get("firstName"), values.get("lastName"));
        }
    }

    record Proof(Binding binding, String otpCredentials, String method, int expiresAt) { }

    private final SingleUseObjectProvider store;
    private final SingleUseCodes codes;

    BrokerLinkProofs(SingleUseObjectProvider store) {
        this.store = store;
        codes = new SingleUseCodes(store, LoginCodes.DIGITS,
                values -> PURPOSE.equals(values.get("purpose")) && Binding.read(values) != null);
    }

    String issueCode(String handle, Binding binding) {
        Map<String, String> notes = new HashMap<>(binding.notes());
        notes.put("purpose", PURPOSE);
        return codes.issue(CODE_PREFIX + handle, notes);
    }

    SingleUseCodes.Entry waiting(String handle) {
        return handle == null ? null : codes.peek(CODE_PREFIX + handle);
    }

    SingleUseCodes.Result confirmCode(String handle, String code, Binding expected) {
        SingleUseCodes.Entry waiting = waiting(handle);
        if (waiting == null || expected == null || !expected.equals(Binding.read(waiting.payload()))) {
            discardCode(handle);
            return SingleUseCodes.Result.NONE;
        }
        return codes.confirm(CODE_PREFIX + handle, code);
    }

    SingleUseCodes.Result spendTry(String handle) {
        return handle == null ? SingleUseCodes.Result.NONE : codes.spendTry(CODE_PREFIX + handle);
    }

    void discardCode(String handle) {
        if (handle != null) codes.discard(CODE_PREFIX + handle);
    }

    void issueProof(String handle, Binding binding, String otpCredentials, String method, int firstFactorDeadline) {
        int deadline = Math.min(firstFactorDeadline, Time.currentTime() + PROOF_TTL_SECONDS);
        if (deadline <= Time.currentTime() || binding.target().isBlank()) {
            throw new IllegalArgumentException("A link proof needs a live, proven target");
        }
        Map<String, String> notes = new HashMap<>(binding.notes());
        notes.put("purpose", PURPOSE);
        notes.put("otpCredentials", otpCredentials);
        notes.put("method", method);
        notes.put("expiresAt", Integer.toString(deadline));
        store.put(proofKey(handle), deadline - Time.currentTime(), notes);
    }

    Proof peekProof(String handle) {
        return handle == null ? null : readProof(store.get(proofKey(handle)));
    }

    Proof consumeProof(String handle) {
        return handle == null ? null : readProof(store.remove(proofKey(handle)));
    }

    void discardProof(String handle) {
        if (handle != null) store.remove(proofKey(handle));
    }

    static String proofKey(String handle) { return PROOF_PREFIX + handle; }

    private static Proof readProof(Map<String, String> notes) {
        if (notes == null || !PURPOSE.equals(notes.get("purpose"))) return null;
        Binding binding = Binding.read(notes);
        if (binding == null || binding.target().isBlank() || notes.get("otpCredentials") == null
                || notes.get("method") == null) return null;
        try {
            int expires = Integer.parseInt(notes.get("expiresAt"));
            return expires <= Time.currentTime() ? null
                    : new Proof(binding, notes.get("otpCredentials"), notes.get("method"), expires);
        } catch (RuntimeException malformed) {
            return null;
        }
    }
}
