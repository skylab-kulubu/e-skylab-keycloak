package com.github.aznamier.keycloak.event.provider;

import com.rabbitmq.client.AMQP;
import com.rabbitmq.client.Channel;
import com.rabbitmq.client.Connection;
import org.jboss.logging.Logger;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.LongSupplier;

/**
 * The one thread that talks to the broker. A Keycloak request only hands its events to a bounded
 * queue ({@link #offer}) and never waits for RabbitMQ: a broker that is down, unreachable, slow or
 * blocked by a resource alarm costs the person signing up or signing in nothing. When the queue is
 * full, the broker blocked or the connection gone, the event is dropped with a WARN line and counted;
 * core's periodic user sync (every 5 minutes) closes the gap (ADR-0071, deviations 4 and 12). The
 * thread holds one connection and one channel, opens them again after a failure (not sooner than
 * {@link #RETRY_MILLIS}) and, when Keycloak stops, publishes what is queued for at most
 * {@link #DRAIN_MILLIS}.
 */
final class RabbitMqPublisher implements AutoCloseable {

    /** One message: where it goes and what it is. */
    record Message(String routingKey, AMQP.BasicProperties properties, byte[] body) {
    }

    /** Opens a connection (the factory's ConnectionFactory, a fake in tests). */
    @FunctionalInterface
    interface Connector {
        Connection open() throws Exception;
    }

    static final int CAPACITY = 1000;
    static final long RETRY_MILLIS = 5_000;
    static final long DRAIN_MILLIS = 2_000;
    static final long WARN_EVERY_MILLIS = 60_000;

    private static final Logger LOG = Logger.getLogger(RabbitMqPublisher.class);

    private final String exchange;
    private final Connector connector;
    private final LongSupplier clock;
    private final BlockingQueue<Message> queue;
    private final Thread thread;
    private final AtomicLong dropped = new AtomicLong();
    private final AtomicLong published = new AtomicLong();
    private volatile boolean blocked;
    private volatile boolean closing;
    private volatile Connection connection;
    private Channel channel;
    private long retryAt;
    private long warnedAt = Long.MIN_VALUE;

    RabbitMqPublisher(String exchange, Connector connector) {
        this(exchange, connector, CAPACITY, System::currentTimeMillis);
    }

    RabbitMqPublisher(String exchange, Connector connector, int capacity, LongSupplier clock) {
        this.exchange = exchange;
        this.connector = connector;
        this.clock = clock;
        this.queue = new ArrayBlockingQueue<>(capacity);
        this.thread = new Thread(this::run, "keycloak-to-rabbitmq-publisher");
        this.thread.setDaemon(true);
        this.thread.start();
    }

    /** Never blocks: the message is queued, or dropped and counted. */
    void offer(Message message) {
        if (closing) {
            drop(message, "Keycloak is stopping");
        } else if (!queue.offer(message)) {
            drop(message, "the queue of " + (queue.size() + queue.remainingCapacity()) + " events is full");
        }
    }

    long dropped() {
        return dropped.get();
    }

    long published() {
        return published.get();
    }

    int queued() {
        return queue.size();
    }

    boolean blocked() {
        return blocked;
    }

    private void run() {
        while (!closing || !queue.isEmpty()) {
            Message message;
            try {
                message = queue.poll(200, TimeUnit.MILLISECONDS);
            } catch (InterruptedException interrupted) {
                break;
            }
            if (message != null) {
                publish(message);
            }
        }
        while (queue.poll() instanceof Message left) {
            drop(left, "Keycloak stopped before it was published");
        }
        closeChannel();
    }

    private void publish(Message message) {
        if (blocked) {
            drop(message, "the broker blocks publishing (a resource alarm)");
            return;
        }
        Channel current = channel();
        if (current == null) {
            drop(message, "no connection to the broker");
            return;
        }
        try {
            current.basicPublish(exchange, message.routingKey(), message.properties(), message.body());
            published.incrementAndGet();
            LOG.tracef("keycloak-to-rabbitmq published event: %s", message.routingKey());
        } catch (Exception exception) {
            LOG.debug("keycloak-to-rabbitmq publish failed", exception);
            closeChannel();
            retryAt = clock.getAsLong() + RETRY_MILLIS;
            drop(message, "publishing failed (" + exception.getClass().getSimpleName() + ")");
        }
    }

    /** The open channel, or a new one; null while the last attempt is less than RETRY_MILLIS ago. */
    private Channel channel() {
        if (channel != null && channel.isOpen()) {
            return channel;
        }
        closeChannel();
        if (clock.getAsLong() < retryAt) {
            return null;
        }
        try {
            Connection current = connection;
            if (current == null || !current.isOpen()) {
                current = connector.open();
                current.addBlockedListener(reason -> {
                    blocked = true;
                    LOG.warnf("keycloak-to-rabbitmq: the broker blocks publishing (%s); events are dropped until it unblocks", reason);
                }, () -> {
                    blocked = false;
                    LOG.info("keycloak-to-rabbitmq: the broker unblocked publishing");
                });
                blocked = false;
                connection = current;
            }
            channel = current.createChannel();
            return channel;
        } catch (Exception exception) {
            LOG.errorf("keycloak-to-rabbitmq could not connect to the broker (%s); authentication remains available, "
                    + "the next attempt in %d s", exception.getClass().getSimpleName(), RETRY_MILLIS / 1000);
            LOG.debug("keycloak-to-rabbitmq connection failure", exception);
            closeChannel();
            retryAt = clock.getAsLong() + RETRY_MILLIS;
            return null;
        }
    }

    private synchronized void drop(Message message, String why) {
        long total = dropped.incrementAndGet();
        long now = clock.getAsLong();
        if (total == 1 || now - warnedAt >= WARN_EVERY_MILLIS) {
            warnedAt = now;
            LOG.warnf("keycloak-to-rabbitmq dropped event %s: %s; %d dropped since start (core's user sync catches up)",
                    message.routingKey(), why, total);
        }
    }

    private void closeChannel() {
        Channel current = channel;
        channel = null;
        if (current == null) {
            return;
        }
        try {
            current.close();
        } catch (Exception exception) {
            LOG.debug("Could not close RabbitMQ channel", exception);
        }
    }

    /**
     * Publishes what is queued for at most DRAIN_MILLIS, then drops the rest. A thread stuck on a
     * broker that stopped reading is freed by aborting the connection.
     */
    @Override
    public void close() {
        closing = true;
        try {
            thread.join(DRAIN_MILLIS);
            Connection current = connection;
            if (thread.isAlive()) {
                thread.interrupt();
                if (current != null) {
                    current.abort(1_000);
                }
                thread.join(1_000);
            } else if (current != null && current.isOpen()) {
                current.close(1_000);
            }
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        } catch (Exception exception) {
            LOG.debug("Could not close RabbitMQ connection", exception);
        }
    }
}
