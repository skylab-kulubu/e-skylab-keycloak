package com.github.aznamier.keycloak.event.provider;

import com.rabbitmq.client.AMQP;
import org.keycloak.events.Event;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.EventListenerTransaction;
import org.keycloak.events.admin.AdminEvent;
import org.keycloak.models.KeycloakSession;

import java.nio.charset.StandardCharsets;
import java.util.Date;

/**
 * Hands the catalog events of one Keycloak session, without personal data ({@link RabbitMqConfig#publishes},
 * {@link EventMessages}), to the factory's {@link RabbitMqPublisher} after the session's transaction.
 * Nothing here touches the network: the request that made the event never waits for the broker.
 * Keycloak's admin event builder creates its listeners with {@code factory.create(session)} and
 * never closes them, so the provider holds nothing.
 */
final class RabbitMqEventListenerProvider implements EventListenerProvider {

    /** Where a message goes once its transaction is committed (the publisher's queue). */
    @FunctionalInterface
    interface Outbox {
        void offer(RabbitMqPublisher.Message message);
    }

    private final RabbitMqConfig config;
    private final Outbox outbox;
    private final KeycloakSession session;
    private final EventListenerTransaction transaction;

    RabbitMqEventListenerProvider(Outbox outbox, KeycloakSession session, RabbitMqConfig config) {
        this.outbox = outbox;
        this.session = session;
        this.config = config;
        this.transaction = new EventListenerTransaction(this::publishAdminEvent, this::publishEvent);
        session.getTransactionManager().enlistAfterCompletion(transaction);
    }

    /** Only a catalog event is kept for the commit; every other one is dropped here, unread. */
    @Override
    public void onEvent(Event event) {
        if (config.publishes(event)) {
            transaction.addEvent(event.clone());
        }
    }

    /**
     * The representation is never published, whatever includeRepresentation says. A copy is kept,
     * as of a user event: the builder's event is Keycloak's, not this listener's.
     */
    @Override
    public void onEvent(AdminEvent event, boolean includeRepresentation) {
        if (config.publishes(event)) {
            transaction.addAdminEvent(new AdminEvent(event), false);
        }
    }

    private void publishEvent(Event event) {
        String id = EventMessages.id(event.getId());
        offer(RabbitMqConfig.routingKey(event, session), id, event.getTime(), EventMessages.user(event, id));
    }

    private void publishAdminEvent(AdminEvent event, boolean includeRepresentation) {
        String id = EventMessages.id(event.getId());
        offer(RabbitMqConfig.routingKey(event, session), id, event.getTime(), EventMessages.admin(event, id));
    }

    private void offer(String routingKey, String id, long time, Object body) {
        outbox.offer(new RabbitMqPublisher.Message(routingKey, properties(id, time),
                RabbitMqConfig.json(body).getBytes(StandardCharsets.UTF_8)));
    }

    /** message-id is the event's id: a consumer drops a repeat of it. */
    private static AMQP.BasicProperties properties(String id, long time) {
        return new AMQP.BasicProperties.Builder()
                .appId("Keycloak")
                .messageId(id)
                .timestamp(time > 0 ? new Date(time) : null)
                .contentType("application/json")
                .contentEncoding(StandardCharsets.UTF_8.name())
                .deliveryMode(2)
                .build();
    }

    @Override
    public void close() {
        // Nothing is held.
    }
}
