#!/usr/bin/env bash
# Shared contract of the keycloak-mailer service-account client (K5, SkyMail sender).
# Sourced by create-mailer-client.sh (operator, creates and assigns) and by
# reconcile-account-center.sh (steady state, verifies only). Callers provide a `kcadm`
# function and TARGET_REALM.

MAILER_CLIENT_ID=keycloak-mailer
MAILER_CLIENT_NAME='Keycloak system mail sender (SkyMail)'
MAILER_CLIENT_DESCRIPTION='Service account used by the sky-mail e-mail sender provider to call SkyMail'
SKYMAIL_CLIENT_ID=skymail
MAILER_SKYMAIL_ROLES=(skymail:access skymail:mails:send)
MAILER_FLAG_FIELDS=enabled,publicClient,bearerOnly,serviceAccountsEnabled,standardFlowEnabled,implicitFlowEnabled,directAccessGrantsEnabled,fullScopeAllowed,clientAuthenticatorType
MAILER_FLAG_VALUES=true,false,false,true,false,false,false,false,client-secret
MAILER_FLAG_SETTINGS=(
  -s enabled=true
  -s publicClient=false
  -s bearerOnly=false
  -s serviceAccountsEnabled=true
  -s standardFlowEnabled=false
  -s implicitFlowEnabled=false
  -s directAccessGrantsEnabled=false
  -s fullScopeAllowed=false
  -s clientAuthenticatorType=client-secret
  -s authorizationServicesEnabled=false
  -s consentRequired=false
  -s 'redirectUris=[]'
  -s 'webOrigins=[]'
)
MAILER_CREATE_COMMAND='docker compose -f docker-compose.yml run --rm --no-deps -it --entrypoint /opt/keycloak/config/create-mailer-client.sh keycloak-config --admin-user <admin> --apply'

# Prints the live flag values of the mailer client in MAILER_FLAG_FIELDS order.
mailer_client_flags() {
  local client_uuid=$1
  kcadm get "clients/$client_uuid" -r "$TARGET_REALM" \
    --fields "$MAILER_FLAG_FIELDS" \
    --format csv \
    --noquotes
}

# Prints the id of the roles client scope when it is attached as a default scope.
mailer_roles_scope_attached() {
  local client_uuid=$1
  kcadm get "clients/$client_uuid/default-client-scopes" -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes | grep -E ',roles$' | cut -d, -f1
}

# Prints the sorted, comma-separated names of the skymail roles held by the service-account
# user (empty when none). Fails when the caller lacks user permissions.
mailer_service_account_roles() {
  local service_user_id=$1
  local skymail_uuid=$2
  kcadm get "users/$service_user_id/role-mappings/clients/$skymail_uuid" -r "$TARGET_REALM" \
    --fields name \
    --format csv \
    --noquotes | sort | paste -sd, -
}

# Prints the sorted, comma-separated skymail roles in the mailer client's scope mappings.
mailer_scope_mapping_roles() {
  local client_uuid=$1
  local skymail_uuid=$2
  kcadm get "clients/$client_uuid/scope-mappings/clients/$skymail_uuid" -r "$TARGET_REALM" \
    --fields name \
    --format csv \
    --noquotes | sort | paste -sd, -
}

mailer_expected_roles() {
  printf '%s\n' "${MAILER_SKYMAIL_ROLES[@]}" | sort | paste -sd, -
}
