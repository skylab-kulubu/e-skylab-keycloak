package com.github.aznamier.keycloak.event.provider;

import com.rabbitmq.client.AMQP;
import com.rabbitmq.client.Channel;
import org.jboss.logging.Logger;
import org.keycloak.events.Event;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.EventListenerTransaction;
import org.keycloak.events.admin.AdminEvent;
import org.keycloak.models.KeycloakSession;

import java.nio.charset.StandardCharsets;
import java.util.Map;

/**
 * Publishes the events of one Keycloak session after its transaction. A channel is opened for each
 * message and closed right after it: Keycloak's admin event builder creates its listeners with
 * {@code factory.create(session)} and never closes them, so a channel held by the provider would
 * leak once per admin request until the connection reaches its channel limit (2047) and every
 * later event is dropped.
 */
final class RabbitMqEventListenerProvider implements EventListenerProvider {

    private static final Logger LOG = Logger.getLogger(RabbitMqEventListenerProvider.class);

    /** Opens a channel on the shared connection; null when none can be opened (already logged). */
    @FunctionalInterface
    interface Channels {
        Channel open();
    }

    private final RabbitMqConfig config;
    private final Channels channels;
    private final KeycloakSession session;
    private final EventListenerTransaction transaction;

    RabbitMqEventListenerProvider(Channels channels, KeycloakSession session, RabbitMqConfig config) {
        this.channels = channels;
        this.session = session;
        this.config = config;
        this.transaction = new EventListenerTransaction(this::publishAdminEvent, this::publishEvent);
        session.getTransactionManager().enlistAfterCompletion(transaction);
    }

    @Override
    public void onEvent(Event event) {
        transaction.addEvent(event.clone());
    }

    @Override
    public void onEvent(AdminEvent event, boolean includeRepresentation) {
        transaction.addAdminEvent(event, includeRepresentation);
    }

    private void publishEvent(Event event) {
        publish(
                RabbitMqConfig.json(EventClientNotificationMqMsg.from(event)),
                properties(EventClientNotificationMqMsg.class.getName()),
                RabbitMqConfig.routingKey(event, session)
        );
    }

    private void publishAdminEvent(AdminEvent event, boolean includeRepresentation) {
        EventAdminNotificationMqMsg message = EventAdminNotificationMqMsg.from(event);
        if (!includeRepresentation) {
            message.setRepresentation(null);
        }
        publish(
                RabbitMqConfig.json(message),
                properties(EventAdminNotificationMqMsg.class.getName()),
                RabbitMqConfig.routingKey(event, session)
        );
    }

    private void publish(String body, AMQP.BasicProperties properties, String routingKey) {
        Channel channel = channels.open();
        if (channel == null || !channel.isOpen()) {
            LOG.errorf("keycloak-to-rabbitmq skipped event because no channel is available: %s", routingKey);
            closeQuietly(channel);
            return;
        }
        try {
            channel.basicPublish(
                    config.exchange(),
                    routingKey,
                    properties,
                    body.getBytes(StandardCharsets.UTF_8)
            );
            LOG.tracef("keycloak-to-rabbitmq published event: %s", routingKey);
        } catch (Exception exception) {
            LOG.errorf(exception, "keycloak-to-rabbitmq failed to publish event: %s", routingKey);
        } finally {
            closeQuietly(channel);
        }
    }

    /** The broker may already have closed it (a missing exchange closes the channel). */
    private static void closeQuietly(Channel channel) {
        if (channel == null) {
            return;
        }
        try {
            channel.close();
        } catch (Exception exception) {
            LOG.debug("Could not close RabbitMQ channel", exception);
        }
    }

    private static AMQP.BasicProperties properties(String className) {
        return new AMQP.BasicProperties.Builder()
                .appId("Keycloak")
                .headers(Map.of("__TypeId__", className))
                .contentType("application/json")
                .contentEncoding(StandardCharsets.UTF_8.name())
                .deliveryMode(2)
                .build();
    }

    @Override
    public void close() {
        // Nothing is held between messages.
    }
}

