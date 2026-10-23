# Upstream provenance

This module is derived from
[`aznamier/keycloak-event-listener-rabbitmq`](https://github.com/aznamier/keycloak-event-listener-rabbitmq)
at commit `2f9fdbaa7bed27aecdd4d305c57f33e2d357a61c` (Apache-2.0).

SKY LAB changes pin Keycloak 26.7.4 and Java 21, update the RabbitMQ Java
client, avoid sharing a `Channel` between Keycloak sessions, make shutdown
null-safe and add compatibility tests.

3.2.0 (RabbitMQ R07, ADR-0071 decision 8) publishes only the event catalog
(`KK_TO_RMQ_EVENT_TYPES`, `KK_TO_RMQ_ADMIN_RESOURCES`), successful events only,
with a body of identifiers: no IP address, session, details, admin
representation or admin author, no Java type header. The AMQP `message-id` is
Keycloak's event id. See `docs/keycloak-events-to-rabbitmq.md`.

3.3.0 publishes from one background thread through a bounded queue (1000
events) on one connection and channel, so a Keycloak request never waits for
the broker. A full queue, a blocked broker (connection.blocked) or a missing
connection drops the event with a WARN line and a count. Short connection,
handshake and channel RPC timeouts, no automatic recovery (the publisher
reconnects itself, not sooner than every 5 s), and a 2 s drain when Keycloak
stops.

