# shellcheck shell=bash
# Sourced by run-integration.sh; uses its kcadm, fail, json_assert, V2_REALM and TEST_STATE_DIR.
#
# Account erasure ticket 09: the reconciler keeps the realm's event retention in code. User and
# admin events expire after 30 days (the admin one through the realm attribute
# adminEventsExpiration, whose purge tests/erasure-event-pii.sh proves), admin event details stay
# on, and the enabled event types are left as they are. Of the listeners only keycloak-to-rabbitmq is
# managed (RabbitMQ R07, KEYCLOAK_RABBITMQ_EVENTS): jboss-logging stays as it is.
#   - The fixture realm starts the way a realm without retention looks: neither store expires,
#     admin event details are off; both listeners are on. The first reconciliation (with
#     KEYCLOAK_RABBITMQ_EVENTS=off, the rollback) must set the retention and remove only
#     keycloak-to-rabbitmq.
#   - Before the second reconciliation retention is switched off by hand (both stores disabled,
#     user events without expiration, admin events kept a year) and an enabled event type list is
#     set. The second reconciliation (KEYCLOAK_RABBITMQ_EVENTS=on) must restore retention, keep the
#     list and add keycloak-to-rabbitmq back next to jboss-logging.
#   - The no-op reconciliation (keep, the default) must report both unchanged; the realm ends with
#     exactly these values. on is refused for the sandbox realm and an unknown value is refused,
#     before anything is read.
# No full reconciliation run of its own: every stage reads the logs of the runs the harness makes.

ER_SECONDS=2592000
ER_LABEL="realm event retention (user and admin events $ER_SECONDS s, admin event details on)"
ER_DRIFT_EVENT_TYPES='["LOGIN","LOGIN_ERROR","LOGOUT","UPDATE_EMAIL"]'
ER_UNMANAGED=''
ER_LISTENER_LABEL='realm event listener keycloak-to-rabbitmq'

# The event settings: the enabled event types, which the reconciler must never write, and the
# listeners, of which it writes only keycloak-to-rabbitmq.
er_unmanaged() {
  kcadm get "realms/$V2_REALM" -c \
    | jq -S -c '{eventsListeners: ((.eventsListeners // []) | sort), enabledEventTypes: ((.enabledEventTypes // []) | sort)}'
}

er_assert_listener_log_line() {
  grep -Fxq "[reconcile] $ER_LISTENER_LABEL: $2" "$TEST_STATE_DIR/$1" \
    || { grep -F "$ER_LISTENER_LABEL" "$TEST_STATE_DIR/$1" >&2 || true; fail "$1 does not report the RabbitMQ event listener as '$2'"; }
}

er_assert_retention() {
  json_assert "$(kcadm get "realms/$V2_REALM" -c)" \
    '.eventsEnabled == true and .eventsExpiration == $seconds and .adminEventsEnabled == true and .adminEventsDetailsEnabled == true and .attributes.adminEventsExpiration == ($seconds | tostring)' \
    "$1: the realm does not keep user and admin events for $ER_SECONDS s with admin event details" \
    --argjson seconds "$ER_SECONDS"
}

er_assert_log_line() {
  grep -Fxq "[reconcile] $ER_LABEL: $2" "$TEST_STATE_DIR/$1" \
    || { grep -F 'realm event retention' "$TEST_STATE_DIR/$1" >&2 || true; fail "$1 does not report the event retention as '$2'"; }
}

stage_event_retention_before_first_reconciliation() {
  CURRENT_STAGE='event retention: a realm without retention'
  json_assert "$(kcadm get "realms/$V2_REALM" -c)" \
    '.eventsEnabled == true and (.eventsExpiration // 0) == 0 and .adminEventsEnabled == true and .adminEventsDetailsEnabled == false and (.attributes.adminEventsExpiration // "") == ""' \
    'the fixture realm must start with events on, no user or admin event expiration and admin event details off'
  ER_UNMANAGED=$(er_unmanaged)
  json_assert "$ER_UNMANAGED" '.eventsListeners == ["jboss-logging", "keycloak-to-rabbitmq"]' \
    'the fixture realm does not start with its two event listeners'
}

stage_event_retention_after_first_reconciliation() {
  CURRENT_STAGE='event retention: the first reconciliation sets 30 days'
  er_assert_log_line reconcile-first.log \
    'updated (eventsExpiration adminEventsDetailsEnabled attributes.adminEventsExpiration)'
  er_assert_retention 'after the first reconciliation'
  er_assert_listener_log_line reconcile-first.log 'updated (on -> off)'
  [[ $(er_unmanaged) == "$(jq -c '.eventsListeners = ["jboss-logging"]' <<<"$ER_UNMANAGED")" ]] \
    || fail 'KEYCLOAK_RABBITMQ_EVENTS=off did not remove exactly keycloak-to-rabbitmq, or the enabled event types changed'
}

stage_event_retention_inject_drift() {
  CURRENT_STAGE='event retention: retention switched off by hand'
  kcadm update "realms/$V2_REALM" \
    -s eventsEnabled=false \
    -s eventsExpiration=0 \
    -s adminEventsEnabled=false \
    -s adminEventsDetailsEnabled=false \
    -s 'attributes.adminEventsExpiration=31536000' \
    -s "enabledEventTypes=$ER_DRIFT_EVENT_TYPES" >/dev/null
  json_assert "$(kcadm get "realms/$V2_REALM" -c)" \
    '.eventsEnabled == false and (.eventsExpiration // 0) == 0 and .adminEventsEnabled == false and .adminEventsDetailsEnabled == false and .attributes.adminEventsExpiration == "31536000"' \
    'event retention drift was not injected'
  ER_UNMANAGED=$(er_unmanaged)
  json_assert "$ER_UNMANAGED" '.enabledEventTypes == ($types | sort)' \
    'the enabled event type list was not injected' --argjson types "$ER_DRIFT_EVENT_TYPES"
}

stage_event_retention_after_second_reconciliation() {
  CURRENT_STAGE='event retention: the second reconciliation restores 30 days and keeps the event types'
  er_assert_log_line reconcile-second.log \
    'updated (eventsEnabled eventsExpiration adminEventsEnabled adminEventsDetailsEnabled attributes.adminEventsExpiration)'
  er_assert_retention 'after the second reconciliation'
  er_assert_listener_log_line reconcile-second.log 'updated (off -> on)'
  [[ $(er_unmanaged) == "$(jq -c '.eventsListeners = ["jboss-logging", "keycloak-to-rabbitmq"]' <<<"$ER_UNMANAGED")" ]] \
    || fail 'KEYCLOAK_RABBITMQ_EVENTS=on did not add keycloak-to-rabbitmq back, or the enabled event types changed'
  # Later stages read user events of every type: back to the fixture's empty list (Keycloak's
  # default event types).
  kcadm update "realms/$V2_REALM" -s 'enabledEventTypes=[]' >/dev/null
  json_assert "$(er_unmanaged)" '.enabledEventTypes == []' \
    'the fixture enabled event type list was not restored'
}

stage_event_retention_after_noop_reconciliation() {
  CURRENT_STAGE='event retention: the no-op reconciliation keeps it unchanged'
  er_assert_log_line reconcile-noop.log unchanged
  er_assert_retention 'after the no-op reconciliation'
  er_assert_listener_log_line reconcile-noop.log 'unchanged (on; KEYCLOAK_RABBITMQ_EVENTS=on or off changes it)'
  json_assert "$(er_unmanaged)" \
    '. == {eventsListeners: ["jboss-logging", "keycloak-to-rabbitmq"], enabledEventTypes: []}' \
    'the fixture event listeners or enabled event types changed'
  er_assert_listener_refusals
}

# KEYCLOAK_RABBITMQ_EVENTS refusals: the reconciler stops with exit 2 before it signs in.
er_assert_listener_refusals() {
  local output status
  status=0
  output=$("${COMPOSE[@]}" run --rm --no-deps -e KEYCLOAK_REALM=e-skylab-sandbox -e KEYCLOAK_RABBITMQ_EVENTS=on \
    keycloak-config 2>&1) || status=$?
  [[ $status == 2 ]] && grep -Fq 'KEYCLOAK_RABBITMQ_EVENTS=on is refused for e-skylab-sandbox' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail "KEYCLOAK_RABBITMQ_EVENTS=on was not refused for the sandbox realm (exit $status)"; }
  status=0
  output=$("${COMPOSE[@]}" run --rm --no-deps -e KEYCLOAK_RABBITMQ_EVENTS=yes keycloak-config 2>&1) || status=$?
  [[ $status == 2 ]] && grep -Fq 'KEYCLOAK_RABBITMQ_EVENTS must be keep, on or off, not yes' <<<"$output" \
    || { printf '%s\n' "$output" >&2; fail "an unknown KEYCLOAK_RABBITMQ_EVENTS was not refused (exit $status)"; }
  json_assert "$(er_unmanaged)" '.eventsListeners == ["jboss-logging", "keycloak-to-rabbitmq"]' \
    'a refused reconciliation changed the event listeners'
}
