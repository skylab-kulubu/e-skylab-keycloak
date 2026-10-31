package com.skylab.account;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.email.EmailException;
import org.keycloak.email.EmailTemplateProvider;
import org.keycloak.models.FederatedIdentityModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.SingleUseObjectProvider;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * The Account erasure notice, decided after the request: only a person core closed for erasure is
 * mailed, where their Login codes would go, at most once an hour to an address.
 */
class AccountErasureNoticeTest {

    private static final String YTU = "OBS";

    private final KeycloakSession session = mock(KeycloakSession.class);
    private final RealmModel realm = mock(RealmModel.class);
    private final UserProvider users = mock(UserProvider.class);
    private final ExpiringStore store = new ExpiringStore();
    private final Map<String, UserModel> byId = new HashMap<>();
    private final Set<String> linkedToYtu = new HashSet<>();

    /** One mail handed to the template provider. */
    private record Mail(String subjectKey, String template, Map<String, Object> attributes, String address, String userId) {
    }

    private final List<Mail> mails = new ArrayList<>();

    @BeforeEach
    void setUp() throws EmailException {
        when(realm.getId()).thenReturn("realm-id");
        when(session.users()).thenReturn(users);
        when(session.singleUseObjects()).thenReturn(store);
        when(users.getUserById(eq(realm), anyString())).thenAnswer(call -> byId.get(call.<String>getArgument(1)));
        when(users.getFederatedIdentity(eq(realm), any(), eq(YTU))).thenAnswer(call ->
                linkedToYtu.contains(call.<UserModel>getArgument(1).getId()) ? mock(FederatedIdentityModel.class) : null);
        EmailTemplateProvider templates = mock(EmailTemplateProvider.class, RETURNS_SELF);
        UserModel[] recipient = new UserModel[1];
        when(templates.setUser(any())).thenAnswer(call -> {
            recipient[0] = call.getArgument(0);
            return templates;
        });
        doAnswer(call -> {
            mails.add(new Mail(call.getArgument(0), call.getArgument(2), Map.copyOf(call.<Map<String, Object>>getArgument(3)),
                    call.getArgument(4), recipient[0].getId()));
            return null;
        }).when(templates).send(anyString(), anyList(), anyString(), anyMap(), anyString());
        when(session.getProvider(EmailTemplateProvider.class)).thenReturn(templates);
    }

    private UserModel person(String id, String email, boolean enabled, boolean marked, String... attributes) {
        UserModel user = mock(UserModel.class);
        Map<String, String> values = new HashMap<>();
        for (String attribute : attributes) {
            values.put(attribute.substring(0, attribute.indexOf('=')), attribute.substring(attribute.indexOf('=') + 1));
        }
        if (marked) {
            values.put(AccountErasureMarkListener.ATTRIBUTE, "2026-10-31T20:00:00Z");
        }
        when(user.getId()).thenReturn(id);
        when(user.getEmail()).thenReturn(email);
        when(user.isEnabled()).thenReturn(enabled);
        when(user.getFirstAttribute(anyString())).thenAnswer(call -> values.get(call.<String>getArgument(0)));
        byId.put(id, user);
        return user;
    }

    private boolean deliver(String userId) throws EmailException {
        return AccountErasureNotice.deliver(session, realm, userId, YTU);
    }

    @Test
    void aPersonBeingErasedIsMailedTheNoticeAtTheirPrimaryAddress() throws EmailException {
        person("erased", "Erased@Example.com", false, true);

        assertTrue(deliver("erased"));

        assertEquals(List.of(new Mail(AccountErasureNotice.SUBJECT_KEY, AccountErasureNotice.MAIL_TEMPLATE, Map.of(),
                "Erased@Example.com", "erased")), mails);
    }

    @Test
    void aPersonAnAdministratorDisabledGetsNothing() throws EmailException {
        person("closed", "closed@example.com", false, false);

        assertFalse(deliver("closed"));

        assertTrue(mails.isEmpty());
        assertTrue(store.keys().isEmpty(), "nothing is spent for a person who is not being erased");
    }

    @Test
    void anEnabledPersonWithAMarkLeftOverGetsNothing() throws EmailException {
        person("rescued", "rescued@example.com", true, true);

        assertFalse(deliver("rescued"));

        assertTrue(mails.isEmpty());
    }

    @Test
    void aServiceAccountOrAPersonGoneByNowGetsNothing() throws EmailException {
        UserModel robot = person("robot", "robot@example.com", false, true);
        when(robot.getServiceAccountClientLink()).thenReturn("client-id");

        assertFalse(deliver("robot"));
        assertFalse(deliver("deleted-meanwhile"));

        assertTrue(mails.isEmpty());
    }

    @Test
    void withoutAPrimaryAddressTheNoticeGoesToTheSchoolAddressOfAVerifiedYtuAccount() throws EmailException {
        person("ytu", null, false, true, IdentityResource.SCHOOL_EMAIL_ATTRIBUTE + "=Yeni@std.yildiz.edu.tr");
        linkedToYtu.add("ytu");
        person("unlinked", null, false, true, IdentityResource.SCHOOL_EMAIL_ATTRIBUTE + "=old@std.yildiz.edu.tr");
        person("nowhere", " ", false, true);

        assertTrue(deliver("ytu"));
        assertFalse(deliver("unlinked"));
        assertFalse(deliver("nowhere"));

        assertEquals(List.of("Yeni@std.yildiz.edu.tr"), mails.stream().map(Mail::address).toList());
    }

    @Test
    void atMostOneNoticeAnHourToAnAddress() throws EmailException {
        UserModel erased = person("erased", "erased@example.com", false, true);
        person("other", "other@example.com", false, true);

        assertTrue(deliver("erased"));
        assertFalse(deliver("erased"), "a second request within the hour");
        when(erased.getEmail()).thenReturn(" ERASED@example.com ");
        assertFalse(deliver("erased"), "the same address in other letters");
        assertTrue(deliver("other"), "another address has its own hour");

        store.now = AccountErasureNotice.WINDOW_SECONDS - 1;
        assertFalse(deliver("erased"), "still within the hour");
        store.now = AccountErasureNotice.WINDOW_SECONDS;
        assertTrue(deliver("erased"), "an hour after the first notice");

        assertEquals(3, mails.size());
    }

    @Test
    void theHourIsKeptUnderAKeyedHashNotTheAddress() throws EmailException {
        person("erased", "erased@example.com", false, true);

        deliver("erased");

        assertEquals(1, store.keys().size());
        String key = store.keys().get(0);
        assertTrue(key.startsWith(AccountErasureNotice.KEY_PREFIX), key);
        assertFalse(key.toLowerCase().contains("erased"), "the address is not in the key");
        assertEquals(AccountErasureNotice.WINDOW_SECONDS, store.lifespan(key));
    }

    /** A single-use store whose entries expire by a clock the test moves (seconds). */
    private static final class ExpiringStore implements SingleUseObjectProvider {
        long now;
        private final Map<String, Long> expiries = new HashMap<>();
        private final Map<String, Long> lifespans = new HashMap<>();

        List<String> keys() {
            return new ArrayList<>(expiries.keySet());
        }

        long lifespan(String key) {
            return lifespans.get(key);
        }

        @Override
        public boolean putIfAbsent(String key, long lifespanInSeconds) {
            Long expiry = expiries.get(key);
            if (expiry != null && expiry > now) {
                return false;
            }
            expiries.put(key, now + lifespanInSeconds);
            lifespans.put(key, lifespanInSeconds);
            return true;
        }

        @Override
        public boolean contains(String key) {
            Long expiry = expiries.get(key);
            return expiry != null && expiry > now;
        }

        @Override
        public void put(String key, long lifespanSeconds, Map<String, String> notes) {
            throw new UnsupportedOperationException();
        }

        @Override
        public Map<String, String> get(String key) {
            throw new UnsupportedOperationException();
        }

        @Override
        public Map<String, String> remove(String key) {
            throw new UnsupportedOperationException();
        }

        @Override
        public boolean replace(String key, Map<String, String> notes) {
            throw new UnsupportedOperationException();
        }

        @Override
        public void close() {
        }
    }
}
