# shellcheck shell=bash
# Sourced by the test scripts: kcadm "get" calls answered by Keycloak's Admin REST API from the host.
#
# Every kcadm.sh call is a docker exec and a new JVM (about a second); a test reads hundreds of
# times. The host has curl and jq and reaches Keycloak on its published port, so a read here is one
# HTTP request with one cached master token. Only the tests use this: the operator scripts
# (config/*.sh) run inside the image, where there is no curl or jq, and keep kcadm. Writes stay on
# kcadm everywhere.
#
# Set up once per run (the variables are exported, so a child script of the run reuses the token):
#   kcadm_rest_setup BASE_URL ADMIN_PASSWORD [STATE_DIR]
# (without STATE_DIR it makes its own temporary directory; kcadm_rest_cleanup removes it)
# A script's kcadm() then starts with
#   kcadm_rest_handles "$command" "$@" && { kcadm_rest_get "$@"; return; }
# kcadm_rest_handles accepts only what kcadm_rest_get reproduces exactly: "get" with a path and
# nothing but -r REALM, -q NAME=VALUE and -c (any other option, such as --fields, --format,
# --offset, --limit or --noquotes, stays on kcadm). KCADM_REST=0 sends every call to kcadm.
#
# The output is the same JSON document kcadm prints (compact with -c, indented otherwise; kcadm's
# indentation differs, so callers parse it, as they already do). On an HTTP error it prints a line
# like kcadm's to stderr (404: "Resource not found for url: ...") and returns 1.

# kcadm_rest_setup BASE_URL ADMIN_PASSWORD [STATE_DIR]: the master admin's password goes to a 0600
# file under STATE_DIR (curl reads it from there; it is never an argument); KCADM_REST_USER is the
# user name (default admin).
KCADM_REST_OWN_DIR=''
kcadm_rest_setup() {
  KCADM_REST_URL=${1%/}
  if [[ -n ${3:-} ]]; then
    KCADM_REST_DIR=$3/kcadm-rest
  else
    KCADM_REST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kcadm-rest.XXXXXX")
    KCADM_REST_OWN_DIR=$KCADM_REST_DIR
  fi
  KCADM_REST_USER=${KCADM_REST_USER:-admin}
  export KCADM_REST_URL KCADM_REST_DIR KCADM_REST_USER
  (umask 077 && mkdir -p "$KCADM_REST_DIR" && printf '%s' "$2" >"$KCADM_REST_DIR/password")
}

# kcadm_rest_cleanup: removes the directory kcadm_rest_setup made itself (none when given STATE_DIR).
kcadm_rest_cleanup() {
  [[ -z $KCADM_REST_OWN_DIR ]] || rm -rf "$KCADM_REST_OWN_DIR"
}

# kcadm_rest_handles COMMAND ARGS...: true when kcadm_rest_get answers this kcadm call.
kcadm_rest_handles() {
  [[ ${KCADM_REST:-1} != 0 && -n ${KCADM_REST_URL:-} && $1 == get ]] || return 1
  shift
  local path='' realm=0
  while (($#)); do
    case $1 in
      -r)
        (($# >= 2)) || return 1
        realm=1
        shift 2
        ;;
      -q)
        (($# >= 2)) && [[ $2 == ?*=* ]] || return 1
        shift 2
        ;;
      -c) shift ;;
      -*) return 1 ;;
      *)
        [[ -z $path ]] || return 1
        path=$1
        shift
        ;;
    esac
  done
  # kcadm resolves realms/... from the admin root and anything else under -r's realm (or the
  # configuration's); only those two shapes, and only characters a URL path may carry as they are
  # (anything else, such as a space or non-ASCII text, stays on kcadm, which refuses a space).
  [[ -n $path && $path != /* && $path != serverinfo* ]] || return 1
  if [[ $path == realms || $path == realms/* ]]; then
    ((realm == 0)) || return 1
  else
    ((realm == 1)) || return 1
  fi
  local safe='^[A-Za-z0-9._~!$&()*+,;=:@/%-]+$'
  [[ $path =~ $safe ]]
}

# kcadm_rest_token [force]: a master access token in $KCADM_REST_DIR/header, fetched again when half
# of its lifetime has passed (or with force).
kcadm_rest_token() {
  local now response status token expires_in
  now=$(date +%s)
  if [[ ${1:-} != force && -s $KCADM_REST_DIR/header && -s $KCADM_REST_DIR/refresh-at ]] \
    && ((now < $(<"$KCADM_REST_DIR/refresh-at"))); then
    return 0
  fi
  status=0
  response=$(curl --silent --show-error --write-out '\n%{http_code}' \
    --data-urlencode grant_type=password \
    --data-urlencode client_id=admin-cli \
    --data-urlencode "username=$KCADM_REST_USER" \
    --data-urlencode "password@$KCADM_REST_DIR/password" \
    "$KCADM_REST_URL/realms/master/protocol/openid-connect/token") || status=$?
  if ((status != 0)) || [[ ${response##*$'\n'} != 200 ]]; then
    printf 'kcadm REST: the master admin token request failed (curl %s, HTTP %s)\n' \
      "$status" "${response##*$'\n'}" >&2
    return 1
  fi
  response=${response%$'\n'*}
  token=$(jq -r '.access_token // empty' <<<"$response") || token=''
  expires_in=$(jq -r '.expires_in // 60' <<<"$response") || expires_in=60
  [[ -n $token && $expires_in =~ ^[0-9]+$ ]] || {
    printf 'kcadm REST: the master admin token response has no access token\n' >&2
    return 1
  }
  (
    umask 077
    printf 'Authorization: Bearer %s\n' "$token" >"$KCADM_REST_DIR/header.$$"
    mv -f "$KCADM_REST_DIR/header.$$" "$KCADM_REST_DIR/header"
    printf '%s\n' $((now + expires_in / 2)) >"$KCADM_REST_DIR/refresh-at.$$"
    mv -f "$KCADM_REST_DIR/refresh-at.$$" "$KCADM_REST_DIR/refresh-at"
  )
}

# kcadm_rest_get PATH [-r REALM] [-q NAME=VALUE]... [-c]: what "kcadm get" prints for the same
# arguments (call kcadm_rest_handles first).
kcadm_rest_get() {
  local path='' realm='' compact=0 url response status attempt error
  local -a query=()
  while (($#)); do
    case $1 in
      -r) realm=$2; shift 2 ;;
      -q) query+=(--data-urlencode "$2"); shift 2 ;;
      -c) compact=1; shift ;;
      *) path=$1; shift ;;
    esac
  done
  if [[ $path == realms || $path == realms/* ]]; then
    url="$KCADM_REST_URL/admin/$path"
  else
    url="$KCADM_REST_URL/admin/realms/$realm/$path"
  fi
  for attempt in 1 2; do
    if ((attempt == 1)); then
      kcadm_rest_token || return 1
    else
      kcadm_rest_token force || return 1
    fi
    status=0
    response=$(curl --silent --show-error --get --write-out '\n%{http_code}' \
      --header "@$KCADM_REST_DIR/header" \
      ${query[@]+"${query[@]}"} "$url") || status=$?
    if ((status != 0)); then
      printf 'kcadm REST: GET %s failed (curl %s)\n' "$url" "$status" >&2
      return 1
    fi
    status=${response##*$'\n'}
    response=${response%$'\n'*}
    # An expired or revoked token: one more try with a new one.
    [[ $status == 401 && $attempt == 1 ]] || break
  done
  if [[ ! $status =~ ^2[0-9][0-9]$ ]]; then
    error=$(jq -r '(.errorMessage // .error // empty) | tostring' <<<"$response" 2>/dev/null) || error=''
    if [[ $status == 404 ]]; then
      printf 'Resource not found for url: %s%s\n' "$url" "${error:+ [$error]}" >&2
    else
      printf 'HTTP error - %s, url: %s%s\n' "$status" "$url" "${error:+ [$error]}" >&2
    fi
    return 1
  fi
  [[ -n $response ]] || return 0
  if ! jq empty <<<"$response" >/dev/null 2>&1; then
    printf '%s\n' "$response"
  elif ((compact)); then
    jq -c . <<<"$response"
  else
    jq . <<<"$response"
  fi
}
