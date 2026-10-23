package com.github.aznamier.keycloak.event.provider;

import org.junit.jupiter.api.Test;
import org.keycloak.events.Event;
import org.keycloak.events.EventType;

import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;

class RabbitMqConfigTest {

    @Test
    void normalizesRoutingKeySegments() {
        assertEquals("e-skylab_org", RabbitMqConfig.normalize("e-skylab org!"));
    }

    @Test
    void removesDotsFromTopicSegments() {
        assertEquals("myyildizskylabcom", RabbitMqConfig.withoutDots("my.yildizskylab.com"));
    }

    @Test
    void theCatalogIsTheDefault() {
        RabbitMqConfig config = RabbitMqConfig.from(name -> null);

        assertEquals(List.of(EventType.REGISTER, EventType.UPDATE_EMAIL, EventType.UPDATE_PROFILE, EventType.DELETE_ACCOUNT),
                List.copyOf(config.eventTypes()));
        assertEquals(Set.of("USER"), config.adminResources());
    }

    @Test
    void aListNarrowsTheCatalogAndNothingOutsideItPasses() {
        assertEquals(Set.of(EventType.REGISTER, EventType.UPDATE_EMAIL),
                RabbitMqConfig.eventTypes(" register , UPDATE_EMAIL,LOGIN,REGISTER_ERROR,,NOT_A_TYPE "));
        assertEquals(Set.of("USER"), RabbitMqConfig.adminResources("user, REALM, CLIENT"));
    }

    @Test
    void anEmptyListSelectsNothing() {
        assertEquals(Set.of(), RabbitMqConfig.eventTypes(""));
        assertEquals(Set.of(), RabbitMqConfig.eventTypes(" , "));
        assertEquals(Set.of(), RabbitMqConfig.adminResources(""));
    }

    @Test
    void theSettingsComeFromTheirNames() {
        Map<String, String> settings = Map.of(
                "url", "rabbitmq", "port", "5673", "username", "keycloak_a", "password", "secret",
                "vhost", "skylab", "exchange", "keycloak.events", "event_types", "UPDATE_PROFILE",
                "admin_resources", "");
        RabbitMqConfig config = RabbitMqConfig.from(settings::get);

        assertEquals("rabbitmq", config.host());
        assertEquals(5673, config.port());
        assertEquals("keycloak_a", config.username());
        assertEquals("skylab", config.virtualHost());
        assertEquals("keycloak.events", config.exchange());
        assertEquals(Set.of(EventType.UPDATE_PROFILE), config.eventTypes());
        assertEquals(Set.of(), config.adminResources());
    }

    @Test
    void aFieldWithoutAValueIsLeftOut() {
        Event event = new Event();
        event.setType(EventType.DELETE_ACCOUNT);
        event.setRealmId("realm-uuid");
        event.setTime(1L);

        assertEquals(List.of("id", "type", "realmId", "time"), List.copyOf(EventMessages.user(event, "event-id").keySet()));
    }
}
