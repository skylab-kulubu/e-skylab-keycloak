package com.github.aznamier.keycloak.event.provider;

import com.rabbitmq.client.Channel;
import org.junit.jupiter.api.Test;
import org.keycloak.events.admin.AdminEvent;
import org.keycloak.events.admin.OperationType;
import org.keycloak.models.KeycloakContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakTransaction;
import org.keycloak.models.KeycloakTransactionManager;

import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

class RabbitMqEventListenerProviderTest {

    private final List<String> channelCalls = new ArrayList<>();
    private final AtomicInteger opened = new AtomicInteger();
    private final AtomicReference<KeycloakTransaction> afterCompletion = new AtomicReference<>();
    private boolean channelOpen = true;

    @Test
    void aProviderThatIsNeverClosedHoldsNoChannel() {
        RabbitMqEventListenerProvider provider = provider();

        provider.onEvent(adminEvent(), false);

        // Keycloak's admin event builder never closes its listeners: nothing may be open yet.
        assertEquals(0, opened.get());
        assertEquals(List.of(), channelCalls);
    }

    @Test
    void everyMessageGetsItsOwnChannelWhichIsClosedAfterPublishing() {
        RabbitMqEventListenerProvider provider = provider();
        provider.onEvent(adminEvent(), false);
        provider.onEvent(adminEvent(), true);

        commit();

        assertEquals(2, opened.get());
        assertEquals(List.of("isOpen", "basicPublish", "close", "isOpen", "basicPublish", "close"), channelCalls);
    }

    @Test
    void aClosedChannelIsSkippedAndStillReleased() {
        channelOpen = false;
        RabbitMqEventListenerProvider provider = provider();
        provider.onEvent(adminEvent(), false);

        commit();

        assertEquals(List.of("isOpen", "close"), channelCalls);
    }

    private RabbitMqEventListenerProvider provider() {
        Channel channel = proxy(Channel.class, (method, args) -> {
            channelCalls.add(method);
            return "isOpen".equals(method) ? channelOpen : null;
        });
        KeycloakTransactionManager transactions = proxy(KeycloakTransactionManager.class, (method, args) -> {
            if ("enlistAfterCompletion".equals(method)) {
                afterCompletion.set((KeycloakTransaction) args[0]);
            }
            return null;
        });
        KeycloakContext context = proxy(KeycloakContext.class, (method, args) -> null);
        KeycloakSession session = proxy(KeycloakSession.class, (method, args) -> switch (method) {
            case "getTransactionManager" -> transactions;
            case "getContext" -> context;
            default -> null;
        });
        return new RabbitMqEventListenerProvider(() -> {
            opened.incrementAndGet();
            return channel;
        }, session, RabbitMqConfig.from(null));
    }

    private void commit() {
        KeycloakTransaction transaction = afterCompletion.get();
        assertNotNull(transaction, "the provider must publish after the Keycloak transaction");
        transaction.begin();
        transaction.commit();
    }

    private static AdminEvent adminEvent() {
        AdminEvent event = new AdminEvent();
        event.setRealmId("e-skylab-test");
        event.setOperationType(OperationType.UPDATE);
        event.setResourceTypeAsString("REALM");
        event.setResourcePath("realms/e-skylab-test");
        return event;
    }

    @FunctionalInterface
    private interface Answer {
        Object answer(String method, Object[] args);
    }

    private static <T> T proxy(Class<T> type, Answer answer) {
        return type.cast(Proxy.newProxyInstance(
                RabbitMqEventListenerProviderTest.class.getClassLoader(),
                new Class<?>[] {type},
                (target, method, args) -> {
                    if (method.getDeclaringClass() == Object.class) {
                        return switch (method.getName()) {
                            case "hashCode" -> System.identityHashCode(target);
                            case "equals" -> target == args[0];
                            default -> type.getSimpleName();
                        };
                    }
                    Object result = answer.answer(method.getName(), args);
                    if (result == null && method.getReturnType() == boolean.class) {
                        return false;
                    }
                    return result;
                }));
    }
}
