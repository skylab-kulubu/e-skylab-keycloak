package com.skylab.account;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.AfterEach;
import org.mockito.MockedStatic;
import org.junit.jupiter.api.Test;
import org.keycloak.models.*;
import org.keycloak.credential.CredentialModel;
import org.keycloak.events.EventBuilder;
import org.keycloak.services.managers.BruteForceProtector;
import org.keycloak.representations.AccessToken;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Supplier;
import java.util.stream.Stream;
import jakarta.ws.rs.core.Response;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SudoEmailResourceTest {
    final AccountRequest request = mock(AccountRequest.class);
    final KeycloakSession session = mock(KeycloakSession.class, RETURNS_DEEP_STUBS);
    final RealmModel realm = mock(RealmModel.class);
    final UserModel user = mock(UserModel.class);
    final SubjectCredentialManager credentials = mock(SubjectCredentialManager.class);
    final UserSessionModel userSession = mock(UserSessionModel.class);
    final SingleUseObjectProvider store = mock(SingleUseObjectProvider.class);
    final Map<String, Map<String,String>> entries = new ConcurrentHashMap<>();
    final AtomicReference<String> sentCode = new AtomicReference<>();
    final AtomicReference<String> sentAddress = new AtomicReference<>();
    final Caller caller = new Caller(user, userSession, new AccessToken(), mock(ClientModel.class));
    final SudoResource resource = new SudoResource(request, (c, address, code) -> {
        sentCode.set(code); sentAddress.set(address);
    });
    MockedStatic<AccountRequest> responses;
    @AfterEach void closeResponses() { responses.close(); }
    @BeforeEach void setup() {
        responses = mockStatic(AccountRequest.class, CALLS_REAL_METHODS);
        responses.when(() -> AccountRequest.ok(anyInt(), any())).thenAnswer(call -> response(call.getArgument(0)));
        when(request.execute(any())).thenAnswer(call -> {
            try { return ((Supplier<?>)call.getArgument(0)).get(); }
            catch (ProblemException ex) { return response(ex.problem().status()); }
        });
        when(request.authenticate()).thenReturn(caller);
        when(request.session()).thenReturn(session);
        when(request.realm()).thenReturn(realm);
        when(request.event(caller)).thenReturn(mock(EventBuilder.class, RETURNS_SELF));
        when(realm.getId()).thenReturn("realm");
        when(user.getId()).thenReturn("user");
        when(userSession.getId()).thenReturn("sid");
        when(user.credentialManager()).thenReturn(credentials);
        when(credentials.getStoredCredentialsStream()).thenAnswer(call -> Stream.empty());
        when(user.getEmail()).thenReturn("old@example.com");
        when(user.isEmailVerified()).thenReturn(true);
        when(session.singleUseObjects()).thenReturn(store);
        doAnswer(call -> { entries.put(call.getArgument(0), Map.copyOf(call.getArgument(2))); return null; })
                .when(store).put(anyString(), anyLong(), anyMap());
        when(store.get(anyString())).thenAnswer(call -> entries.get(call.getArgument(0)));
        when(store.remove(anyString())).thenAnswer(call -> entries.remove(call.getArgument(0)));
        when(request.issueSudo(caller, SudoTokens.Method.EMAIL_CODE)).thenReturn(new SudoTokens.Issued("opaque", 1900000000));
    }
    private static Response response(int status) {
        Response response = mock(Response.class);
        when(response.getStatus()).thenReturn(status);
        return response;
    }
    @Test void sendsToCurrentPrimaryThenIssuesNormalSessionBoundSudo() {
        when(user.getFirstAttribute("personalEmail")).thenReturn("pending@example.com");
        assertEquals(202, resource.sendEmailCode("{}").getStatus());
        assertEquals("old@example.com", sentAddress.get());
        assertTrue(sentCode.get().matches("[0-9]{6}"));
        assertEquals(200, resource.withEmailCode("{\"code\":\"" + sentCode.get() + "\"}").getStatus());
        verify(request).limit(RateLimiter.SUDO_EMAIL_SEND, caller);
        verify(request).limit(RateLimiter.SUDO, caller);
        verify(request).issueSudo(caller, SudoTokens.Method.EMAIL_CODE);
        assertEquals(404, resource.withEmailCode("{\"code\":\"" + sentCode.get() + "\"}").getStatus());
    }
    @Test void passwordHolderGets403AtSendAndVerify() {
        when(credentials.isConfiguredFor("password")).thenReturn(true);
        assertEquals(403, resource.sendEmailCode("{}").getStatus());
        assertEquals(403, resource.withEmailCode("{\"code\":\"123456\"}").getStatus());
        assertNull(sentCode.get());
    }
    @Test void addingPasskeyInvalidatesOutstandingCodeAndCapability() {
        assertEquals(202, resource.sendEmailCode("{}").getStatus());
        CredentialModel key = new CredentialModel(); key.setType("webauthn-passwordless");
        when(credentials.getStoredCredentialsStream()).thenAnswer(call -> Stream.of(key));
        assertFalse(SudoEmailEligibility.available(session, user));
        assertEquals(403, resource.withEmailCode("{\"code\":\"" + sentCode.get() + "\"}").getStatus());
        when(credentials.getStoredCredentialsStream()).thenAnswer(call -> Stream.empty());
        assertEquals(404, resource.withEmailCode("{\"code\":\"" + sentCode.get() + "\"}").getStatus());
    }
    @Test void changedOrMissingPrimaryCannotUseOldCode() {
        assertEquals(202, resource.sendEmailCode("{}").getStatus());
        when(user.getEmail()).thenReturn("new@example.com");
        assertEquals(404, resource.withEmailCode("{\"code\":\"" + sentCode.get() + "\"}").getStatus());
        when(user.getEmail()).thenReturn(null);
        assertEquals(409, resource.sendEmailCode("{}").getStatus());
        assertFalse(SudoEmailEligibility.available(session, user));
    }
    @Test void unverifiedOrMalformedPrimaryFailsClosed() {
        when(user.isEmailVerified()).thenReturn(false);
        assertEquals(409, resource.sendEmailCode("{}").getStatus());
        when(user.isEmailVerified()).thenReturn(true);
        when(user.getEmail()).thenReturn("not-an-email");
        assertEquals(409, resource.sendEmailCode("{}").getStatus());
    }
    @Test void wrongCodesReachBruteForceAndFiveAttemptsKillTheCode() {
        when(realm.isBruteForceProtected()).thenReturn(true);
        BruteForceProtector protector = mock(BruteForceProtector.class);
        doReturn(protector).when(session).getProvider(BruteForceProtector.class);
        assertEquals(202, resource.sendEmailCode("{}").getStatus());
        String wrong = sentCode.get().equals("000000") ? "000001" : "000000";
        for (int i=0;i<5;i++) assertEquals(400, resource.withEmailCode("{\"code\":\"" + wrong + "\"}").getStatus());
        verify(protector, times(5)).failedLogin(eq(realm), eq(user), any(), any(), eq(java.util.Set.of("password")));
        assertEquals(404, resource.withEmailCode("{\"code\":\"" + sentCode.get() + "\"}").getStatus());
    }
    @Test void totpAlsoRefusesMailAndResendingHonoursSendBudget() {
        CredentialModel otp = new CredentialModel(); otp.setType("otp");
        when(credentials.getStoredCredentialsStream()).thenAnswer(call -> Stream.of(otp));
        assertEquals(403, resource.sendEmailCode("{}").getStatus());
        when(credentials.getStoredCredentialsStream()).thenAnswer(call -> Stream.empty());
        doThrow(Problems.rateLimited(90).exception()).when(request).limit(RateLimiter.SUDO_EMAIL_SEND, caller);
        assertEquals(429, resource.sendEmailCode("{}").getStatus());
        assertNull(sentCode.get());
    }
    @Test void failedDeliveryDiscardsCodeWithoutIssuingSudo() {
        SudoResource failed = new SudoResource(request, (c, address, code) -> {
            throw new org.keycloak.email.EmailException("delivery failed");
        });
        assertEquals(503, failed.sendEmailCode("{}").getStatus());
        assertTrue(entries.values().stream().noneMatch(notes -> notes.containsKey("codeHash")));
        verify(request, never()).issueSudo(any(), any());
    }
    @Test void realMailAdapterUsesTheSudoTemplateAndPurposeWithoutRecipientOverride() throws Exception {
        var mail = mock(org.keycloak.email.EmailTemplateProvider.class, RETURNS_SELF);
        doReturn(mail).when(session).getProvider(org.keycloak.email.EmailTemplateProvider.class);
        assertEquals(202, new SudoResource(request).sendEmailCode("{}").getStatus());
        verify(mail).send(eq("skySudoCodeSubject"), eq(java.util.List.of()), eq(SudoResource.MAIL_TEMPLATE),
                argThat(attributes -> "sudo".equals(attributes.get("purpose"))
                        && attributes.get("code").toString().matches("[0-9]{6}")
                        && Integer.valueOf(10).equals(attributes.get("codeExpiration"))), eq("old@example.com"));
    }

    @Test void lateFailedSendCannotKillTheNewerDeliveredCode() {
        SudoResource first = new SudoResource(request, (c, address, code) -> {
            assertEquals(202, resource.sendEmailCode("{}").getStatus());
            throw new org.keycloak.email.EmailException("late delivery failure");
        });
        assertEquals(503, first.sendEmailCode("{}").getStatus());
        assertEquals(200, resource.withEmailCode("{\"code\":\"" + sentCode.get() + "\"}").getStatus());
    }

    @Test void factorAddedDuringConsumptionCannotObtainAGrant() {
        assertEquals(202, resource.sendEmailCode("{}").getStatus());
        when(store.remove(anyString())).thenAnswer(call -> {
            Map<String, String> removed = entries.remove(call.getArgument(0));
            when(credentials.isConfiguredFor("password")).thenReturn(true);
            return removed;
        });
        assertEquals(403, resource.withEmailCode("{\"code\":\"" + sentCode.get() + "\"}").getStatus());
        verify(request, never()).issueSudo(any(), any());
    }
    @Test void primaryChangedDuringConsumptionCannotObtainAGrant() {
        assertEquals(202, resource.sendEmailCode("{}").getStatus());
        when(store.remove(anyString())).thenAnswer(call -> {
            Map<String, String> removed = entries.remove(call.getArgument(0));
            when(user.getEmail()).thenReturn("new@example.com");
            return removed;
        });
        assertEquals(404, resource.withEmailCode("{\"code\":\"" + sentCode.get() + "\"}").getStatus());
        verify(request, never()).issueSudo(any(), any());
    }

}
