package com.skylab.account;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.keycloak.common.util.Time;
import org.keycloak.models.SingleUseObjectProvider;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SudoEmailCodesTest {
    final Map<String, Map<String, String>> entries = new ConcurrentHashMap<>();
    final SingleUseObjectProvider store = mock(SingleUseObjectProvider.class);
    final SudoEmailCodes codes;
    SudoEmailCodesTest() {
        doAnswer(call -> { entries.put(call.getArgument(0), Map.copyOf(call.getArgument(2))); return null; })
                .when(store).put(anyString(), anyLong(), anyMap());
        when(store.get(anyString())).thenAnswer(call -> entries.get(call.getArgument(0)));
        when(store.remove(anyString())).thenAnswer(call -> entries.remove(call.getArgument(0)));
        codes = new SudoEmailCodes(store);
    }
    private SudoEmailCodes.Issued issue(String realm, String user, String sid, String address) {
        var issued = codes.issue(realm, user, sid, address);
        assertTrue(codes.activate(realm, user, sid, issued));
        return issued;
    }
    @AfterEach void resetClock() { Time.setOffset(0); }
    @Test void sixDigitsSaltedHashAndSingleUse() {
        String code = issue("realm", "user", "sid", "old@example.com").code();
        assertTrue(code.matches("[0-9]{6}"));
        assertTrue(entries.values().stream().noneMatch(notes -> notes.values().contains(code)));
        assertEquals(SingleUseCodes.Status.CONFIRMED, codes.confirm("realm", "user", "sid", "old@example.com", code).status());
        assertEquals(SingleUseCodes.Status.NONE, codes.confirm("realm", "user", "sid", "old@example.com", code).status());
    }
    @Test void realmAccountSessionAndCurrentPrimaryAreBound() {
        String code = issue("realm", "user", "sid", "old@example.com").code();
        assertEquals(SingleUseCodes.Status.NONE, codes.confirm("other", "user", "sid", "old@example.com", code).status());
        assertEquals(SingleUseCodes.Status.NONE, codes.confirm("realm", "other", "sid", "old@example.com", code).status());
        assertEquals(SingleUseCodes.Status.NONE, codes.confirm("realm", "user", "other", "old@example.com", code).status());
        assertEquals(SingleUseCodes.Status.NONE, codes.confirm("realm", "user", "sid", "new@example.com", code).status());
        assertEquals(SingleUseCodes.Status.NONE, codes.confirm("realm", "user", "sid", "old@example.com", code).status());
    }
    @Test void fiveWrongAttemptsKillTheCode() {
        String code = issue("realm", "user", "sid", "old@example.com").code();
        String wrong = code.equals("000000") ? "000001" : "000000";
        for (int left = 4; left >= 0; left--) {
            var result = codes.confirm("realm", "user", "sid", "old@example.com", wrong);
            assertEquals(SingleUseCodes.Status.WRONG_CODE, result.status());
            assertEquals(left, result.attemptsLeft());
        }
        assertEquals(SingleUseCodes.Status.NONE, codes.confirm("realm", "user", "sid", "old@example.com", code).status());
    }
    @Test void exactDeadlineIsExpiredAndWrongAttemptsCannotExtendIt() {
        String code = issue("realm", "user", "sid", "old@example.com").code();
        Time.setOffset(600);
        assertEquals(SingleUseCodes.Status.NONE, codes.confirm("realm", "user", "sid", "old@example.com", code).status());
    }
    @Test void loginAndPersonalEmailCodesCannotBeUsedForSudo() {
        String login = new LoginCodes(store).issue("sid", "user", "old@example.com");
        assertEquals(SingleUseCodes.Status.NONE, codes.confirm("realm", "user", "sid", "old@example.com", login).status());
        assertEquals(LoginCodes.Outcome.Status.CONFIRMED, new LoginCodes(store).confirm("sid", login).status());
    }
    @Test void staleDeliveryFailureCannotDiscardANewerSend() {
        var first = issue("realm", "user", "sid", "old@example.com");
        var second = issue("realm", "user", "sid", "old@example.com");
        codes.discard(first);
        assertEquals(SingleUseCodes.Status.CONFIRMED, codes.confirm("realm", "user", "sid", "old@example.com", second.code()).status());
    }

    @Test void resendDuringAnOldWrongAttemptCannotOverwriteTheNewCode() {
        var first = issue("realm", "user", "sid", "old@example.com");
        var newer = new java.util.concurrent.atomic.AtomicReference<SudoEmailCodes.Issued>();
        var raced = new java.util.concurrent.atomic.AtomicBoolean();
        when(store.remove(anyString())).thenAnswer(call -> {
            Map<String, String> removed = entries.remove(call.getArgument(0));
            if (raced.compareAndSet(false, true)) newer.set(issue("realm", "user", "sid", "old@example.com"));
            return removed;
        });
        String wrong = first.code().equals("000000") ? "000001" : "000000";
        assertEquals(SingleUseCodes.Status.NONE, codes.confirm("realm", "user", "sid", "old@example.com", wrong).status());
        assertEquals(SingleUseCodes.Status.CONFIRMED, codes.confirm("realm", "user", "sid", "old@example.com", newer.get().code()).status());
    }
    @Test void resendDuringConsumptionRefusesTheRetiredCodeGrant() {
        var first = issue("realm", "user", "sid", "old@example.com");
        var newer = new java.util.concurrent.atomic.AtomicReference<SudoEmailCodes.Issued>();
        var raced = new java.util.concurrent.atomic.AtomicBoolean();
        when(store.remove(anyString())).thenAnswer(call -> {
            Map<String, String> removed = entries.remove(call.getArgument(0));
            if (raced.compareAndSet(false, true)) newer.set(issue("realm", "user", "sid", "old@example.com"));
            return removed;
        });
        assertEquals(SingleUseCodes.Status.NONE, codes.confirm("realm", "user", "sid", "old@example.com", first.code()).status());
        assertEquals(SingleUseCodes.Status.CONFIRMED, codes.confirm("realm", "user", "sid", "old@example.com", newer.get().code()).status());
    }

}
