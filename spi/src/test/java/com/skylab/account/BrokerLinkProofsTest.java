package com.skylab.account;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.common.util.Time;
import org.keycloak.models.SingleUseObjectProvider;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class BrokerLinkProofsTest {
    private final Map<String, Map<String, String>> entries = new ConcurrentHashMap<>();
    private final SingleUseObjectProvider store = mock(SingleUseObjectProvider.class);
    private final BrokerLinkProofs proofs = new BrokerLinkProofs(store);
    private final BrokerLinkProofs.Binding binding = new BrokerLinkProofs.Binding(
            "realm", "root", "tab", "client", "OBS", "microsoft-subject", "school@std.yildiz.edu.tr",
            "target", "personal@example.org", "Microsoft", "Name");

    @BeforeEach
    void setup() {
        when(store.get(anyString())).thenAnswer(c -> entries.get(c.getArgument(0)));
        when(store.remove(anyString())).thenAnswer(c -> entries.remove(c.getArgument(0)));
        doAnswer(c -> entries.put(c.getArgument(0), Map.copyOf(c.getArgument(2))))
                .when(store).put(anyString(), anyLong(), anyMap());
    }

    @AfterEach
    void resetClock() { Time.setOffset(0); }

    @Test
    void linkCodesHaveSixDigitsAndCannotBeUsedAsLoginOrSignUpCodes() {
        String code = proofs.issueCode("handle", binding);
        assertTrue(code.matches("[0-9]{6}"));
        assertEquals(LoginCodes.Outcome.none(), new LoginCodes(store).confirm("handle", code));
        assertEquals(SingleUseCodes.Status.CONFIRMED, proofs.confirmCode("handle", code, binding).status());
        assertNull(proofs.waiting("handle"));
        assertEquals(SingleUseCodes.Status.NONE, proofs.confirmCode("handle", code, binding).status());
    }

    @Test
    void aCodeCannotMoveToAnotherTabTargetPrimaryOrBrokerSubject() {
        for (int field = 0; field < 11; field++) {
            String code = proofs.issueCode("handle", binding);
            Map<String, String> changed = new java.util.HashMap<>(binding.notes());
            String key = binding.notes().keySet().stream().sorted().toList().get(field);
            changed.put(key, "different");
            BrokerLinkProofs.Binding other = BrokerLinkProofs.Binding.read(changed);
            assertEquals(SingleUseCodes.Status.NONE, proofs.confirmCode("handle", code, other).status(), key);
            assertNull(proofs.waiting("handle"), "a binding mismatch invalidates the original code");
        }
    }

    @Test
    void fiveWrongTriesKillTheCodeWithoutExtendingItsOriginalDeadline() {
        String code = proofs.issueCode("handle", binding);
        int expires = proofs.waiting("handle").expiresAt();
        Time.setOffset(30);
        String wrong = code.equals("000000") ? "000001" : "000000";
        for (int i = 0; i < 4; i++) {
            assertEquals(SingleUseCodes.Status.WRONG_CODE, proofs.confirmCode("handle", wrong, binding).status());
            assertEquals(expires, proofs.waiting("handle").expiresAt());
        }
        assertEquals(0, proofs.confirmCode("handle", wrong, binding).attemptsLeft());
        assertEquals(SingleUseCodes.Status.NONE, proofs.confirmCode("handle", code, binding).status());
    }

    @Test
    void proofsAreFixedLivedAndBoundToTheirSecondFactorSnapshot() {
        int deadline = Time.currentTime() + 45;
        proofs.issueProof("proof", binding, "otp-id-1", "email_code", deadline);
        BrokerLinkProofs.Proof proof = proofs.peekProof("proof");
        assertEquals(deadline, proof.expiresAt());
        assertEquals("otp-id-1", proof.otpCredentials());
        assertEquals(binding, proof.binding());
        Time.setOffset(46);
        assertNull(proofs.peekProof("proof"));
        assertNull(proofs.consumeProof("proof"));
    }

    @Test
    void callbacksCannotConsumeTheSameProofTwice() throws Exception {
        proofs.issueProof("proof", binding, "", "passkey", Time.currentTime() + 600);
        assertTrue(proofs.peekProof("proof").expiresAt() <= Time.currentTime() + BrokerLinkProofs.PROOF_TTL_SECONDS);
        CountDownLatch start = new CountDownLatch(1);
        try (var pool = Executors.newFixedThreadPool(2)) {
            var a = pool.submit(() -> { start.await(); return proofs.consumeProof("proof"); });
            var b = pool.submit(() -> { start.await(); return proofs.consumeProof("proof"); });
            start.countDown();
            assertEquals(1, (a.get() == null ? 0 : 1) + (b.get() == null ? 0 : 1));
        }
    }

    @Test
    void aMalformedOrWrongPurposeProofFailsClosed() {
        proofs.issueProof("proof", binding, "", "email_code", Time.currentTime() + 600);
        String key = BrokerLinkProofs.proofKey("proof");
        Map<String, String> changed = new java.util.HashMap<>(entries.get(key));
        changed.put("purpose", "login");
        entries.put(key, changed);
        assertNull(proofs.consumeProof("proof"));
    }
}
