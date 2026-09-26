#!/usr/bin/env bash
# Shared contract of the core-erasure service-account client (account erasure, ADR-0051).
# Sourced by create-erasure-client.sh (operator, creates and assigns) and by
# reconcile-account-center.sh (steady state, verifies only). Callers provide a `kcadm`
# function and TARGET_REALM.
#
# core sends every service one Account erasure command with a token of its own:
#   grant_type=client_credentials, scope=openid account-erase-<service>
# The service account holds the erase role of every service, but the client has
# fullScopeAllowed=false and no direct scope mappings, so a role reaches a token only through
# the optional client scope that maps it. A token requested for one service therefore carries
# that service's role and audience and nothing of the others.

# shellcheck disable=SC2034  # the variables are read by the scripts that source this file
ERASURE_CLIENT_ID=core-erasure
ERASURE_SERVICE_ACCOUNT=service-account-core-erasure
ERASURE_CLIENT_NAME='Core account erasure (service to service)'
ERASURE_CLIENT_DESCRIPTION='Service account core uses to send Account erasure commands to SkyMail, CMS and Forms (ADR-0051)'
ERASURE_ROLE_DESCRIPTION='Account erasure command from core through the core-erasure client (ADR-0051)'
ERASURE_FLAG_FIELDS=enabled,publicClient,bearerOnly,serviceAccountsEnabled,standardFlowEnabled,implicitFlowEnabled,directAccessGrantsEnabled,fullScopeAllowed,clientAuthenticatorType
ERASURE_FLAG_VALUES=true,false,false,true,false,false,false,false,client-secret
ERASURE_FLAG_SETTINGS=(
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
# Default client scopes, exactly: roles emits resource_access; basic emits sub, which the
# services' account-access gate reads to check the caller itself (a token without sub gets 401).
# Everything else a new client gets from the realm defaults (acr, email, profile, web-origins,
# and the optional address, phone, offline_access, ...) is removed. The one exception is
# service_account: Keycloak 26 attaches it to every client with a service account and attaches
# it again on every update of the client (Admin Console save, the rotator's secret PUT), so it is
# tolerated rather than fought. Its claims (client_id, clientHost, clientAddress) grant nothing.
ERASURE_DEFAULT_SCOPES=(basic roles)
ERASURE_TOLERATED_DEFAULT_SCOPE=service_account

# One entry per service, same index in every array: the optional client scope core requests,
# the resource client the service validates as audience and the client role it requires.
ERASURE_SERVICES=(skymail cms forms)
ERASURE_SCOPES=(account-erase-skymail account-erase-cms account-erase-forms)
ERASURE_RESOURCE_CLIENTS=(skymail skycms forms)
ERASURE_ROLES=(skymail:account:erase cms:account:erase skyforms:account:erase)
ERASURE_SCOPE_DESCRIPTION='Account erasure command to one service (ADR-0051); requested by core-erasure only'
# Mapper CSV fields and the expected line per scope (erasure_expected_mapper).
ERASURE_MAPPER_FIELDS='name,protocolMapper,config(included.client.audience,included.custom.audience,access.token.claim,introspection.token.claim,id.token.claim,userinfo.token.claim)'
ERASURE_CREATE_COMMAND='docker compose -f docker-compose.yml run --rm --no-deps -it --entrypoint /opt/keycloak/config/create-erasure-client.sh keycloak-config --admin-user <admin> --apply'

# Prints the internal id of a client; 1 when it does not exist, 2 when clients cannot be read.
erasure_client_uuid() {
  local wanted=$1 clients_csv id client_id
  if ! clients_csv=$(kcadm get clients -r "$TARGET_REALM" -q "clientId=$wanted" \
    --fields id,clientId \
    --format csv \
    --noquotes); then
    printf 'Failed to read clients while looking up %s\n' "$wanted" >&2
    return 2
  fi
  while IFS=, read -r id client_id; do
    if [[ $client_id == "$wanted" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done <<<"$clients_csv"
  return 1
}

# Prints the id of a client scope; 1 when it does not exist, 2 when scopes cannot be read.
erasure_scope_uuid() {
  local wanted=$1 scopes_csv id name
  if ! scopes_csv=$(kcadm get client-scopes -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes); then
    printf 'Failed to read client scopes while looking up %s\n' "$wanted" >&2
    return 2
  fi
  while IFS=, read -r id name; do
    if [[ $name == "$wanted" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done <<<"$scopes_csv"
  return 1
}

# Prints the live flag values of a client in ERASURE_FLAG_FIELDS order.
erasure_client_flags() {
  kcadm get "clients/$1" -r "$TARGET_REALM" \
    --fields "$ERASURE_FLAG_FIELDS" \
    --format csv \
    --noquotes
}

# erasure_client_scopes UUID default|optional: the sorted, comma-separated scope names; the
# default list leaves the tolerated service_account out.
erasure_client_scopes() {
  local names
  names=$(kcadm get "clients/$1/$2-client-scopes" -r "$TARGET_REALM" \
    --fields name \
    --format csv \
    --noquotes)
  if [[ $2 == default ]]; then
    names=$(grep -Fvx -- "$ERASURE_TOLERATED_DEFAULT_SCOPE" <<<"$names" || true)
  fi
  sed '/^$/d' <<<"$names" | sort | paste -sd, -
}

erasure_expected_default_scopes() {
  printf '%s\n' "${ERASURE_DEFAULT_SCOPES[@]}" | sort | paste -sd, -
}

erasure_expected_optional_scopes() {
  printf '%s\n' "${ERASURE_SCOPES[@]}" | sort | paste -sd, -
}

# erasure_role_mappings PATH RESOURCE_UUID...: the realm roles and the roles of the given
# resource clients under a scope-mappings PATH (clients/<id>/scope-mappings or
# client-scopes/<id>/scope-mappings), one "realm:<role>" or "<clientId>:<role>" per line,
# sorted. The arguments after PATH alternate: resource uuid, resource clientId.
erasure_role_mappings() {
  local path=$1 uuid client_id
  shift
  {
    kcadm get "$path/realm" -r "$TARGET_REALM" --fields name --format csv --noquotes \
      | sed '/^$/d; s/^/realm:/'
    while [[ $# -ge 2 ]]; do
      uuid=$1 client_id=$2
      shift 2
      kcadm get "$path/clients/$uuid" -r "$TARGET_REALM" --fields name --format csv --noquotes \
        | sed "/^\$/d; s/^/$client_id:/"
    done
  } | sort
}

# Prints the protocol mappers of a client scope as ERASURE_MAPPER_FIELDS CSV lines, sorted.
erasure_scope_mappers() {
  kcadm get "client-scopes/$1/protocol-mappers/models" -r "$TARGET_REALM" \
    --fields "$ERASURE_MAPPER_FIELDS" \
    --format csv \
    --noquotes | sed '/^$/d' | sort
}

# erasure_expected_mapper INDEX: the one mapper line the scope of service INDEX must hold.
erasure_expected_mapper() {
  printf '%s-audience,oidc-audience-mapper,%s,,true,true,false,false\n' \
    "${ERASURE_SCOPES[$1]}" "${ERASURE_RESOURCE_CLIENTS[$1]}"
}

# Prints the protocol of a client scope.
erasure_scope_protocol() {
  kcadm get "client-scopes/$1" -r "$TARGET_REALM" --fields protocol --format csv --noquotes
}
