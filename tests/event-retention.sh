# shellcheck shell=bash
# Sourced by run-integration.sh; uses its kcadm, fail, json_assert, V2_REALM and TEST_STATE_DIR.
#
# Account erasure ticket 09: the reconciler keeps the realm's event retention in code. User and
# admin events expire after 30 days (the admin one through the realm attribute
# adminEventsExpiration, whose purge tests/erasure-event-pii.sh proves), admin event details stay
# on, and the event listeners and enabled event types are left as they are.
#   - The fixture realm starts the way a realm without retention looks: neither store expires,
#     admin event details are off. The first reconciliation must set all of it.
#   - Before the second reconciliation retention is switched off by hand (both stores disabled,
#     user events without expiration, admin events kept a year) and an enabled event type list is
#     set. The second reconciliation must restore retention and keep the list and the listeners.
#   - The no-op reconciliation must report it unchanged; the realm ends with exactly these values.
# No reconciliation run of its own: every stage reads the logs of the runs the harness makes.

ER_SECONDS=2592000
ER_LABEL="realm event retention (user and admin events $ER_SECONDS s, admin event details on)"
ER_DRIFT_EVENT_TYPES='["LOGIN","LOGIN_ERROR","LOGOUT","UPDATE_EMAIL"]'
ER_UNMANAGED=''

# The event settings the reconciler must never write: listeners and enabled event types.
er_unmanaged() {
  kcadm get "realms/$V2_REALM" -c \
    | jq -S -c '{eventsListeners: ((.eventsListeners // []) | sort), enabledEventTypes: ((.enabledEventTypes // []) | sort)}'
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
  [[ $(er_unmanaged) == "$ER_UNMANAGED" ]] \
    || fail 'the first reconciliation changed the event listeners or the enabled event types'
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
  [[ $(er_unmanaged) == "$ER_UNMANAGED" ]] \
    || fail 'the second reconciliation changed the event listeners or the enabled event types'
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
  json_assert "$(er_unmanaged)" \
    '. == {eventsListeners: ["jboss-logging", "keycloak-to-rabbitmq"], enabledEventTypes: []}' \
    'the fixture event listeners or enabled event types changed'
}
