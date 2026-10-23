package com.github.aznamier.keycloak.event.provider;

import org.keycloak.events.Event;
import org.keycloak.events.admin.AdminEvent;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/**
 * The bodies the provider publishes: identifiers and what a consumer decides on, nothing else
 * (ADR-0071 decision 5 and 8, RabbitMQ SPEC §2.6 and §5). Keycloak's own event carries the IP
 * address, the session and its details (the username and the e-mail address of a REGISTER, the
 * old and the new address of an UPDATE_EMAIL); an admin event carries who made it from where and,
 * with admin event details on, the whole user representation. None of it leaves Keycloak: a queue,
 * its DLQ and the unrouted queue are copies an erasure request never reaches. A consumer that needs
 * more reads it from Keycloak.
 */
final class EventMessages {

    private EventMessages() {
    }

    /** {@code id, type, realmId, clientId, userId, time}; a field without a value is left out. */
    static Map<String, Object> user(Event event, String id) {
        Map<String, Object> body = new LinkedHashMap<>();
        put(body, "id", id);
        put(body, "type", event.getType() == null ? null : event.getType().name());
        put(body, "realmId", event.getRealmId());
        put(body, "clientId", event.getClientId());
        put(body, "userId", event.getUserId());
        put(body, "time", event.getTime());
        return body;
    }

    /** {@code id, realmId, resourceType, operationType, resourcePath, time}, as {@link #user}. */
    static Map<String, Object> admin(AdminEvent event, String id) {
        Map<String, Object> body = new LinkedHashMap<>();
        put(body, "id", id);
        put(body, "realmId", event.getRealmId());
        put(body, "resourceType", event.getResourceTypeAsString());
        put(body, "operationType", event.getOperationType() == null ? null : event.getOperationType().name());
        put(body, "resourcePath", event.getResourcePath());
        put(body, "time", event.getTime());
        return body;
    }

    private static void put(Map<String, Object> body, String name, Object value) {
        if (value != null) {
            body.put(name, value);
        }
    }

    /**
     * Keycloak's id of the event (the id its event store keeps; EventBuilder and AdminEventBuilder
     * give every event one), or a new one for an event that came without.
     */
    static String id(String keycloakId) {
        return keycloakId == null || keycloakId.isBlank() ? UUID.randomUUID().toString() : keycloakId;
    }
}
