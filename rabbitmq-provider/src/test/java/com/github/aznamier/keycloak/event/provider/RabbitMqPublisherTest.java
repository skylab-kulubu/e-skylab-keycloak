package com.github.aznamier.keycloak.event.provider;

import com.rabbitmq.client.AMQP;
import com.rabbitmq.client.BlockedCallback;
import com.rabbitmq.client.Channel;
import com.rabbitmq.client.Connection;
import com.rabbitmq.client.UnblockedCallback;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.BooleanSupplier;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class RabbitMqPublisherTest {

    private final List<String> published = new CopyOnWriteArrayList<>();
    private final List<String> calls = new CopyOnWriteArrayList<>();
    private final AtomicInteger connections = new AtomicInteger();
    private final AtomicLong now = new AtomicLong(1_000_000);
    private final AtomicReference<BlockedCallback> blockedCallback = new AtomicReference<>();
    private final AtomicReference<UnblockedCallback> unblockedCallback = new AtomicReference<>();
    /** Holds basicPublish, as a broker that stopped reading the socket does; abort releases it. */
    private volatile CountDownLatch hang;
    private volatile boolean refuseConnections;
    private volatile boolean failPublish;
    private RabbitMqPublisher publisher;

    @AfterEach
    void stop() {
        if (hang != null) {
            hang.countDown();
        }
        if (publisher != null) {
            publisher.close();
        }
    }

    @Test
    void aMessageGoesToTheExchangeWithItsRoutingKeyPropertiesAndBody() {
        publisher = publisher(10);

        publisher.offer(message("KK.EVENT.CLIENT.e-skylab.SUCCESS.app.REGISTER"));

        await(() -> published.size() == 1);
        assertEquals(List.of("keycloak.events KK.EVENT.CLIENT.e-skylab.SUCCESS.app.REGISTER id-1 {\"id\":\"id-1\"}"), published);
        assertEquals(1, connections.get());
    }

    @Test
    void oneConnectionAndOneChannelServeEveryMessage() {
        publisher = publisher(10);

        for (int i = 0; i < 5; i++) {
            publisher.offer(message("KK.EVENT.ADMIN.e-skylab.SUCCESS.USER.UPDATE"));
        }

        await(() -> published.size() == 5);
        assertEquals(1, connections.get());
        assertEquals(1, calls.stream().filter("createChannel"::equals).count());
    }

    @Test
    void anOfferNeverWaitsForAStuckBrokerAndAFullQueueDrops() {
        hang = new CountDownLatch(1);
        publisher = publisher(3);
        publisher.offer(message("first"));
        await(() -> calls.contains("basicPublish"));

        long started = System.nanoTime();
        for (int i = 0; i < 10; i++) {
            publisher.offer(message("waiting-" + i));
        }
        long tookMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started);

        assertTrue(tookMillis < 200, "ten offers to a stuck broker took " + tookMillis + " ms");
        assertEquals(3, publisher.queued());
        assertEquals(7, publisher.dropped());
    }

    @Test
    void anUnreachableBrokerIsTriedAgainOnlyAfterTheRetryPause() {
        refuseConnections = true;
        publisher = publisher(10);

        publisher.offer(message("one"));
        await(() -> publisher.dropped() == 1);
        publisher.offer(message("two"));
        await(() -> publisher.dropped() == 2);
        assertEquals(1, connections.get(), "a second attempt inside the retry pause");

        refuseConnections = false;
        now.addAndGet(RabbitMqPublisher.RETRY_MILLIS);
        publisher.offer(message("three"));
        await(() -> published.size() == 1);
        assertEquals(2, connections.get());
    }

    @Test
    void aBlockedBrokerGetsNothingUntilItUnblocks() throws Exception {
        publisher = publisher(10);
        publisher.offer(message("before"));
        await(() -> published.size() == 1);

        blockedCallback.get().handle("low on memory");
        publisher.offer(message("while-blocked"));
        await(() -> publisher.dropped() == 1);
        assertEquals(1, published.size());

        unblockedCallback.get().handle();
        publisher.offer(message("after"));
        await(() -> published.size() == 2);
        assertTrue(published.get(1).contains(" after "));
    }

    @Test
    void aFailedPublishClosesTheChannelAndTheNextOneOpensANewOne() {
        failPublish = true;
        publisher = publisher(10);
        publisher.offer(message("fails"));
        await(() -> publisher.dropped() == 1);
        assertTrue(calls.contains("close"));

        failPublish = false;
        now.addAndGet(RabbitMqPublisher.RETRY_MILLIS);
        publisher.offer(message("works"));
        await(() -> published.size() == 1);
        assertEquals(2, calls.stream().filter("createChannel"::equals).count());
    }

    @Test
    void stoppingPublishesWhatIsQueued() {
        publisher = publisher(10);
        for (int i = 0; i < 5; i++) {
            publisher.offer(message("queued-" + i));
        }

        publisher.close();

        assertEquals(5, published.size());
        assertEquals(0, publisher.dropped());
        publisher.offer(message("after-stop"));
        assertEquals(1, publisher.dropped());
    }

    @Test
    void stoppingDoesNotWaitLongForAStuckBroker() {
        hang = new CountDownLatch(1);
        publisher = publisher(10);
        publisher.offer(message("stuck"));
        await(() -> calls.contains("basicPublish"));
        publisher.offer(message("behind-it"));

        long started = System.nanoTime();
        publisher.close();
        long tookMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started);

        assertTrue(tookMillis < RabbitMqPublisher.DRAIN_MILLIS + 1_500, "stopping took " + tookMillis + " ms");
        assertTrue(calls.contains("abort"), "the connection of the stuck thread was not aborted");
    }

    private RabbitMqPublisher publisher(int capacity) {
        return new RabbitMqPublisher("keycloak.events", this::connection, capacity, now::get);
    }

    private Connection connection() throws IOException {
        connections.incrementAndGet();
        if (refuseConnections) {
            throw new IOException("connection refused");
        }
        Channel channel = proxy(Channel.class, (method, args) -> {
            calls.add(method);
            switch (method) {
                case "isOpen":
                    return !calls.contains("close") || calls.lastIndexOf("createChannel") > calls.lastIndexOf("close");
                case "basicPublish":
                    CountDownLatch latch = hang;
                    if (latch != null) {
                        latch.await();
                    }
                    if (failPublish) {
                        throw new IOException("channel closed");
                    }
                    AMQP.BasicProperties properties = (AMQP.BasicProperties) args[2];
                    published.add(args[0] + " " + args[1] + " " + properties.getMessageId() + " "
                            + new String((byte[]) args[3], StandardCharsets.UTF_8));
                    return null;
                default:
                    return null;
            }
        });
        return proxy(Connection.class, (method, args) -> {
            switch (method) {
                case "isOpen":
                    return true;
                case "createChannel":
                    calls.add("createChannel");
                    return channel;
                case "addBlockedListener":
                    if (args.length == 2) {
                        blockedCallback.set((BlockedCallback) args[0]);
                        unblockedCallback.set((UnblockedCallback) args[1]);
                    }
                    return null;
                case "abort":
                    calls.add("abort");
                    CountDownLatch latch = hang;
                    if (latch != null) {
                        latch.countDown();
                    }
                    return null;
                default:
                    return null;
            }
        });
    }

    private static RabbitMqPublisher.Message message(String routingKey) {
        AMQP.BasicProperties properties = new AMQP.BasicProperties.Builder().messageId("id-1").build();
        return new RabbitMqPublisher.Message(routingKey, properties, "{\"id\":\"id-1\"}".getBytes(StandardCharsets.UTF_8));
    }

    private static void await(BooleanSupplier condition) {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (!condition.getAsBoolean()) {
            if (System.nanoTime() > deadline) {
                throw new AssertionError("condition not reached in 5 s");
            }
            try {
                Thread.sleep(10);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                throw new AssertionError(interrupted);
            }
        }
    }

    @FunctionalInterface
    private interface Answer {
        Object answer(String method, Object[] args) throws Exception;
    }

    private static <T> T proxy(Class<T> type, Answer answer) {
        return type.cast(Proxy.newProxyInstance(
                RabbitMqPublisherTest.class.getClassLoader(),
                new Class<?>[] {type},
                (target, method, args) -> {
                    if (method.getDeclaringClass() == Object.class) {
                        return switch (method.getName()) {
                            case "hashCode" -> System.identityHashCode(target);
                            case "equals" -> target == args[0];
                            default -> type.getSimpleName();
                        };
                    }
                    Object result = answer.answer(method.getName(), args == null ? new Object[0] : args);
                    if (result == null && method.getReturnType() == boolean.class) {
                        return false;
                    }
                    if (result == null && method.getReturnType() == int.class) {
                        return 0;
                    }
                    return result;
                }));
    }
}
