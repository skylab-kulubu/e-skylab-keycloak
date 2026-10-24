package com.github.aznamier.keycloak.event.provider;

import com.rabbitmq.client.ConnectionFactory;
import org.keycloak.Config.Scope;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.EventListenerProviderFactory;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;
import java.io.FileInputStream;
import java.security.KeyStore;

public final class RabbitMqEventListenerProviderFactory implements EventListenerProviderFactory {

    public static final String PROVIDER_ID = "keycloak-to-rabbitmq";

    static final int CONNECTION_TIMEOUT_MILLIS = 2_000;
    static final int HANDSHAKE_TIMEOUT_MILLIS = 3_000;
    static final int CHANNEL_RPC_TIMEOUT_MILLIS = 3_000;
    static final int SHUTDOWN_TIMEOUT_MILLIS = 1_000;
    static final int HEARTBEAT_SECONDS = 30;

    private RabbitMqConfig config;
    private RabbitMqPublisher publisher;

    @Override
    public EventListenerProvider create(KeycloakSession session) {
        return new RabbitMqEventListenerProvider(publisher::offer, session, config);
    }

    /**
     * Short limits everywhere: only the publisher thread waits on them, but a stuck attempt delays
     * every event behind it. Automatic recovery is off: the publisher opens a new connection itself.
     */
    @Override
    public void init(Scope scope) {
        config = RabbitMqConfig.from(scope);
        ConnectionFactory connectionFactory = new ConnectionFactory();
        connectionFactory.setUsername(config.username());
        connectionFactory.setPassword(config.password());
        connectionFactory.setVirtualHost(config.virtualHost());
        connectionFactory.setHost(config.host());
        connectionFactory.setPort(config.port());
        connectionFactory.setAutomaticRecoveryEnabled(false);
        connectionFactory.setTopologyRecoveryEnabled(false);
        connectionFactory.setConnectionTimeout(CONNECTION_TIMEOUT_MILLIS);
        connectionFactory.setHandshakeTimeout(HANDSHAKE_TIMEOUT_MILLIS);
        connectionFactory.setChannelRpcTimeout(CHANNEL_RPC_TIMEOUT_MILLIS);
        connectionFactory.setShutdownTimeout(SHUTDOWN_TIMEOUT_MILLIS);
        connectionFactory.setRequestedHeartbeat(HEARTBEAT_SECONDS);

        if (config.useTls()) {
            configureTls(connectionFactory, config);
        }
        publisher = new RabbitMqPublisher(config.exchange(),
                () -> connectionFactory.newConnection("keycloak-event-listener"));
    }

    private static void configureTls(ConnectionFactory factory, RabbitMqConfig config) {
        try {
            SSLContext context = SSLContext.getInstance("TLSv1.3");
            TrustManagerFactory trustManagers = null;
            KeyManagerFactory keyManagers = null;

            if (!config.trustStore().isBlank()) {
                KeyStore trustStore = KeyStore.getInstance("JKS");
                char[] password = config.trustStorePassword().toCharArray();
                try (FileInputStream input = new FileInputStream(config.trustStore())) {
                    trustStore.load(input, password);
                }
                trustManagers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
                trustManagers.init(trustStore);
            }

            if (!config.keyStore().isBlank()) {
                KeyStore keyStore = KeyStore.getInstance("PKCS12");
                char[] password = config.keyStorePassword().toCharArray();
                try (FileInputStream input = new FileInputStream(config.keyStore())) {
                    keyStore.load(input, password);
                }
                keyManagers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
                keyManagers.init(keyStore, password);
            }

            context.init(
                    keyManagers == null ? null : keyManagers.getKeyManagers(),
                    trustManagers == null ? null : trustManagers.getTrustManagers(),
                    null
            );
            factory.useSslProtocol(context);
        } catch (Exception exception) {
            throw new IllegalStateException("RabbitMQ TLS configuration is invalid", exception);
        }
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // no-op
    }

    @Override
    public void close() {
        if (publisher != null) {
            publisher.close();
        }
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }
}

