#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
JAVA_BIN=${JAVA_BIN:-java}
KEYCLOAK_LIB_DIR=${KEYCLOAK_LIB_DIR:-/opt/keycloak/lib/lib/main}
CONFIG_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
TARGET_REALM=${KEYCLOAK_REALM:-e-skylab}
BASE_URL=${ACCOUNT_CENTER_BASE_URL:-https://my.yildizskylab.com}
REQUIRE_PRODUCTION_HOST=${ACCOUNT_CENTER_REQUIRE_PRODUCTION_HOST:-false}
CONFIG_CLIENT_ID=${KEYCLOAK_CONFIG_CLIENT_ID:-account-center-config}
PASSKEY_RP_ID=${KEYCLOAK_PASSKEY_RP_ID:-yildizskylab.com}
PASSKEY_EXTRA_ORIGINS=${KEYCLOAK_PASSKEY_EXTRA_ORIGINS:-https://my.yildizskylab.com}
# Realm attribute that records (ISO-8601 UTC) when the passwordless relying party id last
# changed; cleanup-legacy-passkeys.sh uses it as the cutover and refuses a later one.
PASSKEY_SWITCH_ATTRIBUTE=skylab.passkeyRpIdSwitchedAt
CLIENT_ID=account-center
# The retired client-specific browser flow of the native handoff (ADR-0048); removed on sight.
LEGACY_FLOW_ALIAS=account-center-browser
# K4: the realm browser flow signs in with the SKY LAB username/password form, which also takes
# the School and Personal e-mail. KEYCLOAK_PASSWORD_FORM=auth-username-password-form puts
# Keycloak's own form back (the rollback; run it before going back to an image without the
# SKY LAB form, or every password login of the realm fails).
BROWSER_FLOW_ALIAS='browser plus passkey'
STOCK_PASSWORD_FORM=auth-username-password-form
SKY_PASSWORD_FORM=sky-username-password-form
PASSWORD_FORM=${KEYCLOAK_PASSWORD_FORM:-$SKY_PASSWORD_FORM}
# K4b: the first step of the realm's reset credentials flow ("Şifremi unuttum") finds the person by
# the same identifiers as the password form; the mail still goes to the Primary e-mail.
# KEYCLOAK_RESET_CHOOSE_USER=reset-credentials-choose-user puts Keycloak's own step back (the
# rollback; run it before going back to an image without the SKY LAB step, or every reset-password
# request of the realm fails). A realm bound to Keycloak's built-in flow moves to an editable copy.
RESET_FLOW_COPY_ALIAS='sky reset credentials'
STOCK_RESET_CHOOSE_USER=reset-credentials-choose-user
SKY_RESET_CHOOSE_USER=sky-reset-credentials-choose-user
RESET_CHOOSE_USER=${KEYCLOAK_RESET_CHOOSE_USER:-$SKY_RESET_CHOOSE_USER}
# A person with an OTP authenticator proves it on the reset: the realm's reset credentials flow
# asks for the code of the registered authenticator (auth-otp-form, "verify") in the place of
# Keycloak's reset-otp, which asks every such person to set up a new authenticator and keeps the
# old one. The condition of the subflow (user configured) is Keycloak's: a person without OTP is
# never asked. KEYCLOAK_RESET_OTP_STEP=reset puts Keycloak's step back (the rollback). Only an
# editable flow (K4b's copy) changes; Keycloak's built-in flow is never touched.
STOCK_RESET_OTP_STEP=reset-otp
VERIFY_RESET_OTP_STEP=auth-otp-form
RESET_OTP_STEP=${KEYCLOAK_RESET_OTP_STEP:-verify}
# Set by reconcile_reset_otp_step when the OTP step is in place but never runs; every other step
# still runs, then the reconciliation ends with exit status 3 instead of reporting success.
RESET_OTP_UNGUARDED=''
# eskylab-login-ux 07 (ADR-0063 decision 5): a new account opened by a first YTÜ login starts with
# the School e-mail as its verified Primary e-mail. The realm's first broker login flow moves to an
# editable copy of Keycloak's built-in one (FIRST_BROKER_FLOW_COPY_ALIAS) that runs the SKY LAB step
# sky-ytu-first-login before the review profile step, shows the review profile page only when a
# required field is missing, and never verifies an existing account by a mailed link (ADR-0044).
# Turning it on is an explicit KEYCLOAK_YTU_FIRST_LOGIN=on run (realm by realm: sandbox first);
# KEYCLOAK_YTU_FIRST_LOGIN=off binds the realm back to the built-in flow (the rollback; run it
# before going back to an image without the SKY LAB step, or every first YTÜ login fails). The
# copy stays. The default, keep, leaves the binding as it is and only keeps an already bound copy
# in shape, so a full reconciliation never turns the feature on or off. An identity provider with its own first login flow override ignores the realm
# binding; the reconciler identity cannot read identity providers, so an operator session
# (KEYCLOAK_RECONCILE_ONLY=first-broker-login) makes OBS follow the realm binding once.
# Production's OBS has its own override, YTU_IDP_LEGACY_FIRST_BROKER_FLOWS: an Admin Console
# duplicate of the built-in flow (first named "first broker login kopyasi", then renamed), made by
# hand before 2026-09-21. With on, the operator session removes it too, but only while that flow has
# the built-in flow's shape (see reconcile_ytu_idp_first_login_flow); the flow itself stays, and
# off writes the override back from the note on OBS (YTU_IDP_PREVIOUS_FLOW_SETTING).
FIRST_BROKER_FLOW_BUILT_IN='first broker login'
FIRST_BROKER_FLOW_COPY_ALIAS='sky first broker login'
YTU_FIRST_LOGIN_STEP=sky-ytu-first-login
YTU_IDP_ALIAS=OBS
YTU_IDP_LEGACY_FIRST_BROKER_FLOWS=('first broker login for obs' 'first broker login kopyasi')
YTU_IDP_PREVIOUS_FLOW_SETTING=skyFirstLoginFlowBeforeYtuStep
REVIEW_PROFILE_SETTING=update.profile.on.first.login
YTU_FIRST_LOGIN=${KEYCLOAK_YTU_FIRST_LOGIN:-keep}
# ADR-0063 decision 4: optional first-Microsoft-login existing-account proof. Installing the image
# never enables this flow. Explicit on/off only edits our existing first-broker-login copy.
EXISTING_ACCOUNT_PROMPT=${KEYCLOAK_EXISTING_ACCOUNT_PROMPT:-keep}
# eskylab-login-ux 21: once, at the end of a first YTÜ login that opened an account with the School
# e-mail as its Primary e-mail, sky-ytu-first-login puts the SPI's required action
# sky-personal-email-offer on the sign-in session ("Kişisel e-postanı ekle": address, code, or
# "Şimdilik geç"). The realm runs it only while the action is registered and enabled.
# KEYCLOAK_PERSONAL_EMAIL_OFFER=on registers and enables it (realm by realm: sandbox first), off
# disables it (the rollback; run it before going back to an image without the action). The default,
# keep, changes nothing, so a full reconciliation never turns the offer on or off. It is never a
# default action (that would put it on every new account).
PERSONAL_EMAIL_OFFER_ACTION=sky-personal-email-offer
PERSONAL_EMAIL_OFFER_NAME='SKY LAB personal e-mail offer (first YTÜ login)'
PERSONAL_EMAIL_OFFER=${KEYCLOAK_PERSONAL_EMAIL_OFFER:-keep}
# "Bu cihazda oturumum açık kalsın mı?" (Microsoft's "Stay signed in?", Yusuf's decision of
# 2026-10-12): at the end of every YTÜ login the SPI's required action sky-stay-signed-in asks once
# whether the new session stays signed in on this device ("Evet, açık kalsın": a remember-me session;
# "Hayır": an ordinary one), with a warning against yes on a shared computer. The password form's
# "Beni hatırla" box is unchanged. KEYCLOAK_STAY_SIGNED_IN=on registers and enables it and runs it
# after every other required action (realm by realm: sandbox first), off disables it (the rollback;
# run it before going back to an image without the action). The default, keep, changes nothing, so a
# full reconciliation never turns the question on or off.
STAY_SIGNED_IN_ACTION=sky-stay-signed-in
STAY_SIGNED_IN_NAME='SKY LAB stay signed in (after a YTÜ login)'
STAY_SIGNED_IN=${KEYCLOAK_STAY_SIGNED_IN:-keep}
# eskylab-login-ux 08 (ADR-0063 decision 2, CONTEXT "Login code"): "E-postayla devam et". With
# KEYCLOAK_EMAIL_CODE_LOGIN=on the realm's browser flow gets the ALTERNATIVE subflow
# EMAIL_CODE_FLOW_ALIAS next to the password form's subflow: the SPI step sky-email-code (address or
# username, then the code mailed to the Primary e-mail), Keycloak's conditional OTP (a person with TOTP
# is asked for it after the code) and the passkey offer. The login theme offers it only while the
# subflow is there. off makes the subflow DISABLED (the rollback; the password and passkey paths never
# change; run it before going back to an image without the step). The default, keep, only reports, so
# a full reconciliation never turns it on or off. Realm by realm (sandbox first), also as an operator
# step (KEYCLOAK_RECONCILE_ONLY=email-code-login).
EMAIL_CODE_LOGIN=${KEYCLOAK_EMAIL_CODE_LOGIN:-keep}
# Set by reconcile_email_code_login (keep) when the subflow runs but may no longer ask a person with
# TOTP for it after the code (an Admin Console change; security review K1). Like
# RESET_OTP_UNGUARDED, every other step still runs, then the run ends with exit status 3. The SPI
# step refuses such a person meanwhile (OtpAfterCode).
EMAIL_CODE_UNGUARDED=''
EMAIL_CODE_STEP=sky-email-code
EMAIL_CODE_FLOW_ALIAS='sky email code'
EMAIL_CODE_OTP_FLOW_ALIAS='sky email code conditional otp'
# eskylab-login-ux 09 (ADR-0063 decision 1, CONTEXT "Self-registration"): with
# KEYCLOAK_EMAIL_CODE_SIGN_UP=on the realm's sky-email-code step gets its sign-up setting (Keycloak's
# authenticator config EMAIL_CODE_SIGN_UP_CONFIG_ALIAS, EMAIL_CODE_SIGN_UP_SETTING=true): an e-mail
# address without an account is mailed a sign-up code and the right code opens the sign-up form (SPI
# 1.22.0). off sets it to false (the rollback; sign-in codes are not touched). The default, keep, only
# reports, so a full reconciliation never turns sign-up on or off. Realm by realm (sandbox first); it
# needs the step (KEYCLOAK_EMAIL_CODE_LOGIN=on, which may run in the same call). Also part of the
# operator step KEYCLOAK_RECONCILE_ONLY=email-code-login. Keycloak's own registration page
# (registrationAllowed) stays off whatever this says (spec S2). In production it goes on only after
# tickets 11 and 12 are live (spec §10).
EMAIL_CODE_SIGN_UP=${KEYCLOAK_EMAIL_CODE_SIGN_UP:-keep}
EMAIL_CODE_SIGN_UP_SETTING=sign-up
EMAIL_CODE_SIGN_UP_CONFIG_ALIAS='sky email code sign-up'
PASSKEY_OFFER_STEP=passkey-offer-authenticator
# Registration-only continuation. keep never mutates this feature; on activates the realm flag
# only after the email child-flow leaf and session-only required action have been read back.
AFTER_SIGN_UP=${KEYCLOAK_AFTER_SIGN_UP:-keep}
AFTER_SIGN_UP_ATTRIBUTE=skyAfterSignUpEnabled
AFTER_SIGN_UP_STEP=sky-after-login
AFTER_SIGN_UP_ACTION=sky-sign-up-credentials
SCOPE_NAME=account-center-account-api
CORE_SCOPE_NAME=account-center-core-claims
SKYAPP_CLIENT_ID=skyapp
SKYAPP_SCOPE_NAME=skyapp-account-center-audience
# Login clients whose access token must name the API they call in aud (made by hand in
# production first, adopted here by name; see reconcile_login_client_audience).
FRONTEND_MAIN_CLIENT_ID=frontend-main
FRONTEND_MAIN_SCOPE_NAME=frontend-main-core-audience
FRONTEND_ARGE_CLIENT_ID=frontend-arge
FRONTEND_ARGE_SCOPE_NAME=frontend-arge-core-audience
SKYFORMS_CLIENT_ID=skyforms
SKYFORMS_SCOPE_NAME=skyforms-forms-audience
SKYFORMS_GROUPS_SCOPE_NAME=skyforms-groups
# forms-frontend calls core with the person's own skyforms token (the person picker, /v1/groups;
# ekip-yetkileri ticket 03 §7), and core wants aud core. Members got it only through audience-resolve
# of core roles some composite or default role gave them, which the role clean-up takes away: a
# fixed Audience mapper, as frontend-main's.
SKYFORMS_CORE_SCOPE_NAME=skyforms-core-audience
# Login clients whose token is narrowed to the APIs their app calls (ADR-0058, ADR-0059; see
# reconcile_login_clients). skycms-audience is the realm scope that puts inscribed's audience into
# the Site clients' tokens: the event sites' clients (site-clients.sh) and skyapp
# (skyapp-cms-editor.sh) carry it too. It has two writers: this step, which must not turn the full
# scope off without it, and site-clients.sh --shared-scope, which repairs it alone before a release.
# Both write the same attributes and the same mapper (config/skycms-audience-mappers.json is
# site-clients.sh's audience_mapper_body); tests/login-clients.sh proves that neither changes what
# the other wrote. They differ only on another mapper in the scope: this step prunes it, as in every
# scope it owns, while site-clients.sh stops on a foreign audience. SkyMail's login client is also
# SkyMail's API client (SKYMAIL_CLIENT_ID, mailer-client-contract.sh): its own scope names it as the
# audience.
SKYCMS_SCOPE_NAME=skycms-audience
SKYMAIL_SCOPE_NAME=skymail-api-audience
# The admin panel's login client (ADR-0058; see reconcile_admin_panel_client): admin, superadmin in
# the sandbox realm (as in inscribed-cms-roles.sh); KEYCLOAK_ADMIN_PANEL_CLIENT_ID names another.
if [[ $TARGET_REALM == e-skylab-sandbox ]]; then
  ADMIN_PANEL_CLIENT_ID=${KEYCLOAK_ADMIN_PANEL_CLIENT_ID:-superadmin}
else
  ADMIN_PANEL_CLIENT_ID=${KEYCLOAK_ADMIN_PANEL_CLIENT_ID:-admin}
fi
ADMIN_PANEL_SCOPE_NAME=admin-panel-api-audience
# Seconds the panel's client session lives at most, remember-me or not (see reconcile_admin_panel_client).
ADMIN_PANEL_CLIENT_SESSION_MAX_LIFESPAN=28800
# The API clients whose every role the panel's token may carry (skycms reads the panel's own roles).
ADMIN_PANEL_API_CLIENTS=(core forms)
# An operator runs one step with a kcadm session they logged in themselves (the sandbox realm has no
# reconciler identity): KEYCLOAK_RECONCILE_KCADM_CONFIG names that session's kcadm config file, which
# is never deleted here, and KEYCLOAK_RECONCILE_ONLY the step. The whole reconciliation still runs
# only as the scoped reconciler identity, so an operator session requires KEYCLOAK_RECONCILE_ONLY.
OPERATOR_KCADM_CONFIG=${KEYCLOAK_RECONCILE_KCADM_CONFIG:-}
RECONCILE_ONLY=${KEYCLOAK_RECONCILE_ONLY:-}
# KEYCLOAK_RECONCILE_CHECK=true: a dry run. Of the operator's service-roles step (runbook §20), of the
# role-groups, leader-app-roles and tohum-atamalar steps (§26, §27, §33) and of the default-roles step
# (§33): it prints "would ..." for each change and writes nothing. Of the whole reconciliation (the
# reconciler identity, no KEYCLOAK_RECONCILE_ONLY) and of the operator's core-roles step: every write
# is withheld (see kcadm below): each one is a "[reconcile] would kcadm VERB PATH ..." line instead,
# the step's own lines say what a real run would log, and the run ends with "... is checked; nothing
# was written (N write(s) withheld)." A step that reads back what it would have written (a flow it
# would have copied, say) may then stop the dry run (exit 1): the dry run cannot show that change, and
# the real run must wait for someone to look. The release wizard compares the dry run with its plan
# and runs the real reconciliation only when they match (ekip-yetkileri ticket 03).
# role-groups, leader-app-roles and tohum-atamalar are operator scripts of their own
# (config/role-groups.sh, config/leader-app-roles.sh, config/app-assignments.sh --seed: a dry run by
# default, --apply writes); this step runs the script with the operator's kcadm session and --apply
# unless KEYCLOAK_RECONCILE_CHECK=true. app-assignments (config/app-assignments.sh --check) only reads:
# the code and panel areas of every role mapping (§33).
RECONCILE_CHECK=${KEYCLOAK_RECONCILE_CHECK:-false}
# Event retention (account erasure ticket 09). Keycloak deletes no event with the person core's
# erasure saga removes: CREATE and UPDATE admin events hold the whole user representation
# (e-mail, names, school and personal e-mail), DELETE holds the username, LOGIN and LOGIN_ERROR
# user events hold the typed address, and admin events without an expiration are kept forever.
# Both stores therefore expire after 30 days, the period KVKK (Law 6698, art. 13) gives for
# concluding an erasure request. Admin event details stay on: they are the audit trail of who
# changed what (Yusuf's choice, 2026-09-26). Enabled event types are not managed; of the listeners
# only keycloak-to-rabbitmq is (KEYCLOAK_RABBITMQ_EVENTS below).
EVENT_RETENTION_SECONDS=2592000
EVENT_RETENTION_SETTINGS="{\"eventsEnabled\":true,\"eventsExpiration\":$EVENT_RETENTION_SECONDS,\"adminEventsEnabled\":true,\"adminEventsDetailsEnabled\":true}"
# The admin event expiration is a realm attribute (seconds), read by Keycloak's scheduled task.
ADMIN_EVENTS_EXPIRATION_ATTRIBUTE=adminEventsExpiration
# RabbitMQ R07 (ADR-0071 decision 8, docs/keycloak-events-to-rabbitmq.md): the realm's event listener
# RABBITMQ_EVENT_LISTENER, which publishes the event catalog to RabbitMQ. KEYCLOAK_RABBITMQ_EVENTS=on
# adds it to the realm's eventsListeners, off removes it (the rollback); every other listener
# (jboss-logging) stays as it is. The default, keep, only reports, so a release never turns it on or
# off: production turns it on once its broker, its KK_TO_RMQ_* settings and this image are live
# (R15). The sandbox realm is never connected to a broker (Yusuf, 2026-10-21): the provider's
# connection is one per Keycloak, the production one, so on is refused there before anything is read.
RABBITMQ_EVENTS=${KEYCLOAK_RABBITMQ_EVENTS:-keep}
RABBITMQ_EVENT_LISTENER=keycloak-to-rabbitmq
ACCOUNT_ROLE_ALLOWLIST=(manage-account view-profile manage-account-links)
case $RECONCILE_ONLY in
  '' | admin-panel-client | login-clients | core-roles | service-roles | first-broker-login | email-code-login | role-groups | leader-app-roles | default-roles | app-assignments | tohum-atamalar) ;;
  # The step's name before core's service roles became a list (core-internal-auth ticket 03).
  media-attach) RECONCILE_ONLY=service-roles ;;
  *)
    printf 'KEYCLOAK_RECONCILE_ONLY must be empty, admin-panel-client, login-clients, core-roles, service-roles, first-broker-login, email-code-login, role-groups, leader-app-roles, default-roles, app-assignments or tohum-atamalar, not %s\n' "$RECONCILE_ONLY" >&2
    exit 2
    ;;
esac
case $RECONCILE_CHECK in
  false) ;;
  true)
    # The whole reconciliation (the reconciler identity) or one operator step that has a dry run.
    if [[ -n $RECONCILE_ONLY ]] \
      && [[ ! $RECONCILE_ONLY =~ ^(service-roles|role-groups|leader-app-roles|core-roles|default-roles|app-assignments|tohum-atamalar)$ || -z $OPERATOR_KCADM_CONFIG ]]; then
      printf 'KEYCLOAK_RECONCILE_CHECK=true is a dry run of the operator step KEYCLOAK_RECONCILE_ONLY=service-roles (or core-roles, role-groups, leader-app-roles, default-roles, tohum-atamalar) with KEYCLOAK_RECONCILE_KCADM_CONFIG only, or of the whole reconciliation with the reconciler identity\n' >&2
      exit 2
    fi
    ;;
  *)
    printf 'KEYCLOAK_RECONCILE_CHECK must be true or false, not %s\n' "$RECONCILE_CHECK" >&2
    exit 2
    ;;
esac
case $RABBITMQ_EVENTS in
  keep | off) ;;
  on)
    if [[ $TARGET_REALM == e-skylab-sandbox ]]; then
      printf 'KEYCLOAK_RABBITMQ_EVENTS=on is refused for e-skylab-sandbox: the sandbox realm is never connected to a broker; nothing was read or changed\n' >&2
      exit 2
    fi
    ;;
  *)
    printf 'KEYCLOAK_RABBITMQ_EVENTS must be keep, on or off, not %s\n' "$RABBITMQ_EVENTS" >&2
    exit 2
    ;;
esac
if [[ -n $OPERATOR_KCADM_CONFIG ]]; then
  if [[ -z $RECONCILE_ONLY ]]; then
    printf 'KEYCLOAK_RECONCILE_KCADM_CONFIG needs KEYCLOAK_RECONCILE_ONLY: an operator session runs one step; the whole reconciliation runs as %s\n' \
      "$CONFIG_CLIENT_ID" >&2
    exit 2
  fi
  if [[ ! -r $OPERATOR_KCADM_CONFIG ]]; then
    printf 'KEYCLOAK_RECONCILE_KCADM_CONFIG is not a readable kcadm config file: %s\n' "$OPERATOR_KCADM_CONFIG" >&2
    exit 2
  fi
  KCADM_CONFIG=$OPERATOR_KCADM_CONFIG
else
  KCADM_CONFIG=$(mktemp /tmp/account-center-kcadm.XXXXXX)
fi
if [[ $RECONCILE_ONLY =~ ^(default-roles|app-assignments|tohum-atamalar)$ && -z $OPERATOR_KCADM_CONFIG ]]; then
  rm -f "$KCADM_CONFIG"
  printf 'KEYCLOAK_RECONCILE_ONLY=%s is an operator step: set KEYCLOAK_RECONCILE_KCADM_CONFIG (it reads or maps roles of groups and people, or identity providers, which the reconciler identity %s may not)\n' \
    "$RECONCILE_ONLY" "$CONFIG_CLIENT_ID" >&2
  exit 2
fi
if [[ $RECONCILE_ONLY == role-groups || $RECONCILE_ONLY == leader-app-roles ]]; then
  if [[ -z $OPERATOR_KCADM_CONFIG ]]; then
    rm -f "$KCADM_CONFIG"
    printf 'KEYCLOAK_RECONCILE_ONLY=%s is an operator step: set KEYCLOAK_RECONCILE_KCADM_CONFIG (mapping roles to groups needs user permissions the reconciler identity %s does not have)\n' \
      "$RECONCILE_ONLY" "$CONFIG_CLIENT_ID" >&2
    exit 2
  fi
  operator_step_arguments=(--kcadm-config "$OPERATOR_KCADM_CONFIG")
  [[ $RECONCILE_CHECK == true ]] || operator_step_arguments+=(--apply)
  KEYCLOAK_REALM=$TARGET_REALM KEYCLOAK_ADMIN_URL=$ADMIN_URL \
    exec bash "$CONFIG_DIR/$RECONCILE_ONLY.sh" "${operator_step_arguments[@]}"
fi
WORK_DIR=$(mktemp -d /tmp/account-center-reconcile.XXXXXX)
JSON_TOOL_CLASSPATH=''
ENSURED_SCOPE_ID=''
ACCOUNT_CENTER_UUID=''
PASSKEY_EXTRA_ORIGIN_LIST=()

# shellcheck source=account-center-origin.sh
source "$CONFIG_DIR/account-center-origin.sh"
# shellcheck source=mailer-client-contract.sh
source "$CONFIG_DIR/mailer-client-contract.sh"
# shellcheck source=erasure-client-contract.sh
source "$CONFIG_DIR/erasure-client-contract.sh"

cleanup() {
  if [[ -z $OPERATOR_KCADM_CONFIG ]]; then
    rm -f "$KCADM_CONFIG"
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

log() {
  printf '[reconcile] %s\n' "$1"
}

warn() {
  printf '[reconcile] WARNING: %s\n' "$1" >&2
}

require() {
  local variable_name=$1
  if [[ -z ${!variable_name:-} ]]; then
    printf 'Missing required environment variable: %s\n' "$variable_name" >&2
    exit 1
  fi
}

if [[ -z $OPERATOR_KCADM_CONFIG ]]; then
  require KEYCLOAK_CONFIG_CLIENT_SECRET
fi

case $PASSWORD_FORM in
  "$SKY_PASSWORD_FORM" | "$STOCK_PASSWORD_FORM") ;;
  *)
    printf 'KEYCLOAK_PASSWORD_FORM must be %s (default) or %s (rollback), not %s\n' \
      "$SKY_PASSWORD_FORM" "$STOCK_PASSWORD_FORM" "$PASSWORD_FORM" >&2
    exit 1
    ;;
esac
case $RESET_CHOOSE_USER in
  "$SKY_RESET_CHOOSE_USER" | "$STOCK_RESET_CHOOSE_USER") ;;
  *)
    printf 'KEYCLOAK_RESET_CHOOSE_USER must be %s (default) or %s (rollback), not %s\n' \
      "$SKY_RESET_CHOOSE_USER" "$STOCK_RESET_CHOOSE_USER" "$RESET_CHOOSE_USER" >&2
    exit 1
    ;;
esac
case $RESET_OTP_STEP in
  verify | reset) ;;
  *)
    printf 'KEYCLOAK_RESET_OTP_STEP must be verify (default) or reset (rollback), not %s\n' "$RESET_OTP_STEP" >&2
    exit 1
    ;;
esac
case $YTU_FIRST_LOGIN in
  keep | on | off) ;;
  *)
    printf 'KEYCLOAK_YTU_FIRST_LOGIN must be keep (default), on or off (rollback), not %s\n' "$YTU_FIRST_LOGIN" >&2
    exit 1
    ;;
esac
case $EXISTING_ACCOUNT_PROMPT in
  keep | on | off) ;;
  *)
    printf 'KEYCLOAK_EXISTING_ACCOUNT_PROMPT must be keep (default), on or off, not %s\n' "$EXISTING_ACCOUNT_PROMPT" >&2
    exit 1
    ;;
esac
case $PERSONAL_EMAIL_OFFER in
  keep | on | off) ;;
  *)
    printf 'KEYCLOAK_PERSONAL_EMAIL_OFFER must be keep (default), on or off (rollback), not %s\n' "$PERSONAL_EMAIL_OFFER" >&2
    exit 1
    ;;
esac
case $STAY_SIGNED_IN in
  keep | on | off) ;;
  *)
    printf 'KEYCLOAK_STAY_SIGNED_IN must be keep (default), on or off (rollback), not %s\n' "$STAY_SIGNED_IN" >&2
    exit 1
    ;;
esac
case $EMAIL_CODE_LOGIN in
  keep | on | off) ;;
  *)
    printf 'KEYCLOAK_EMAIL_CODE_LOGIN must be keep (default), on or off (rollback), not %s\n' "$EMAIL_CODE_LOGIN" >&2
    exit 1
    ;;
esac
case $EMAIL_CODE_SIGN_UP in
  keep | on | off) ;;
  *)
    printf 'KEYCLOAK_EMAIL_CODE_SIGN_UP must be keep (default), on or off (rollback), not %s\n' "$EMAIL_CODE_SIGN_UP" >&2
    exit 1
    ;;
esac
case $AFTER_SIGN_UP in
  keep | on | off) ;;
  *) printf 'KEYCLOAK_AFTER_SIGN_UP must be keep (default), on or off, not %s\n' "$AFTER_SIGN_UP" >&2; exit 1 ;;
esac

BASE_URL=$(normalize_account_center_base_url \
  "$BASE_URL" \
  "$REQUIRE_PRODUCTION_HOST")

# The dry run of the whole reconciliation, of core-roles and of default-roles (KEYCLOAK_RECONCILE_CHECK
# =true, see above): every kcadm create, update and delete is withheld. Each one is logged on the
# run's own stderr (file descriptor CHECK_FD, so that a caller that captures or silences the call's
# output, as kcadm_quiet does, cannot hide it) as "[reconcile] would kcadm VERB PATH (-s KEY=VALUE
# ... body)" ("(body)" for a body alone), with a person's id masked; nothing the reconciler writes is secret. A create that asks
# for the new id (-i) answers a placeholder (CHECK_ID_PREFIX<n>), and a read of a path that holds a
# placeholder answers an empty list (an empty object for one resource or a mapping set, nothing in
# CSV), so that a step goes on as if the thing were made and empty. Anything else is read live.
CHECK_WRITES=false
if [[ $RECONCILE_CHECK == true && ( -z $RECONCILE_ONLY || $RECONCILE_ONLY == core-roles || $RECONCILE_ONLY == default-roles ) ]]; then
  CHECK_WRITES=true
fi
CHECK_ID_PREFIX=checked-not-created-
CHECK_FD=8
exec 8>&2

check_write() {
  local verb=$1 path=$2 summary='' argument
  shift 2
  while [[ $# -gt 0 ]]; do
    argument=$1
    shift
    case $argument in
      -s) summary="$summary -s ${1:0:160}"; shift ;;
      -b | -f) summary="$summary body"; shift ;;
      -r | -q) shift ;;
      *) ;;
    esac
  done
  printf '%s\n' "$verb $path" >>"$WORK_DIR/check-writes"
  path=$(sed -E 's#users/[0-9a-f-]{36}#users/<person>#g' <<<"$path")
  printf '[reconcile] would kcadm %s %s%s\n' "$verb" "$path" "${summary:+ (${summary# })}" >&"$CHECK_FD"
}

check_placeholder_read() {
  local path=$1 argument csv=false
  for argument in "$@"; do
    [[ $argument != csv ]] || csv=true
  done
  if [[ $csv == true ]]; then
    return 0
  fi
  path=${path%%\?*}
  case ${path##*/} in
    models | default-client-scopes | optional-client-scopes | executions | roles | composites | members | groups \
      | users | children | clients | realm | flows | mappers)
      printf '[]\n' ;;
    *) printf '{}\n' ;;
  esac
}

kcadm() {
  local command=$1
  shift
  if [[ $CHECK_WRITES == true ]]; then
    case $command in
      create | update | delete)
        check_write "$command" "$@"
        if [[ $command == create && " $* " == *' -i '* ]]; then
          printf '%s%s\n' "$CHECK_ID_PREFIX" "$(wc -l <"$WORK_DIR/check-writes" | tr -d ' ')"
        fi
        return 0
        ;;
      get)
        if [[ $1 == *"$CHECK_ID_PREFIX"* ]]; then
          check_placeholder_read "$@"
          return 0
        fi
        ;;
    esac
  fi
  "$KCADM" "$command" --config "$KCADM_CONFIG" "$@"
}

# The number of writes the dry run withheld so far.
check_writes_withheld() {
  if [[ -f $WORK_DIR/check-writes ]]; then
    wc -l <"$WORK_DIR/check-writes" | tr -d ' '
  else
    printf '0\n'
  fi
}

authenticate() {
  local attempt
  for attempt in $(seq 1 60); do
    if "$KCADM" config credentials \
      --config "$KCADM_CONFIG" \
      --server "$ADMIN_URL" \
      --realm "$TARGET_REALM" \
      --client "$CONFIG_CLIENT_ID" \
      --secret "$KEYCLOAK_CONFIG_CLIENT_SECRET" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  printf 'Keycloak did not become ready for reconciliation\n' >&2
  return 1
}

# The Keycloak image has no jq. ReconcileJson.java is compiled once per run with the JDK
# that ships in the image and gives every comparison real JSON semantics.
compile_json_tool() {
  local jackson_jars=("$KEYCLOAK_LIB_DIR"/com.fasterxml.jackson.core.jackson-*.jar)
  local classpath jar
  if [[ ! -f ${jackson_jars[0]} ]]; then
    printf 'Jackson libraries were not found under %s\n' "$KEYCLOAK_LIB_DIR" >&2
    return 1
  fi
  classpath=''
  for jar in "${jackson_jars[@]}"; do
    classpath="$classpath$jar:"
  done
  mkdir -p "$WORK_DIR/classes"
  "$JAVA_BIN" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC \
    -m jdk.compiler/com.sun.tools.javac.Main \
    -d "$WORK_DIR/classes" \
    -cp "$classpath" \
    "$CONFIG_DIR/ReconcileJson.java" >/dev/null
  JSON_TOOL_CLASSPATH="$WORK_DIR/classes:$classpath"
}

json_tool() {
  "$JAVA_BIN" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC \
    -cp "$JSON_TOOL_CLASSPATH" ReconcileJson "$@"
}

# kcadm prints informational lines on stderr ("Created new model with id ...", an empty line
# for every JSON read). Keep the reconcile log to its own lines while still surfacing the
# diagnostics of a failed call.
kcadm_quiet() {
  local stderr_file status
  stderr_file=$(mktemp "$WORK_DIR/stderr.XXXXXX")
  if kcadm "$@" 2>"$stderr_file" >/dev/null; then
    status=0
  else
    status=$?
  fi
  if [[ $status != 0 ]]; then
    cat "$stderr_file" >&2
  fi
  rm -f "$stderr_file"
  return "$status"
}

kcadm_json() {
  local stderr_file status
  stderr_file=$(mktemp "$WORK_DIR/stderr.XXXXXX")
  if kcadm get "$@" 2>"$stderr_file"; then
    status=0
  else
    status=$?
  fi
  if [[ $status != 0 ]]; then
    cat "$stderr_file" >&2
  fi
  rm -f "$stderr_file"
  return "$status"
}

# id_from_csv WANTED CSV: the id of the "id,name" line whose name is WANTED (status 1: none).
id_from_csv() {
  local wanted=$1 csv=$2 id name
  while IFS=, read -r id name; do
    if [[ $name == "$wanted" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done <<<"$csv"
  return 1
}

# cached_id_by_name PATH FIELD WANTED WHAT: the id of the PATH entry (clients, client-scopes) whose
# FIELD is WANTED; status 1 when there is none, 2 when the list cannot be read. Each kcadm call starts
# a JVM, and a run looks the same few clients up some twenty times, so the "id,FIELD" list is kept in
# WORK_DIR (a file, since most callers run in a command substitution) and an id found there is used
# again: a run deletes no client and no client scope, and Keycloak never changes an id. A name not in
# the kept list is read again, because a step of the run may have created it since.
cached_id_by_name() {
  local path=$1 field=$2 wanted=$3 what=$4
  local cache="$WORK_DIR/ids-$path.csv" csv
  if [[ -f $cache ]] && id_from_csv "$wanted" "$(<"$cache")"; then
    return 0
  fi
  if ! csv=$(kcadm get "$path" -r "$TARGET_REALM" \
    --fields "id,$field" \
    --format csv \
    --noquotes); then
    printf 'Failed to read %s while looking up %s\n' "$what" "$wanted" >&2
    return 2
  fi
  printf '%s\n' "$csv" >"$cache"
  id_from_csv "$wanted" "$csv"
}

client_id_by_client_id() {
  cached_id_by_name clients clientId "$1" clients
}

flow_id_by_alias() {
  local wanted=$1
  local flows_csv id alias
  if ! flows_csv=$(kcadm get authentication/flows -r "$TARGET_REALM" \
    --fields id,alias \
    --format csv \
    --noquotes); then
    printf 'Failed to read authentication flows while looking up %s\n' "$wanted" >&2
    return 2
  fi
  while IFS=, read -r id alias; do
    if [[ $alias == "$wanted" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done <<<"$flows_csv"
  return 1
}

client_scope_id_by_name() {
  cached_id_by_name client-scopes name "$1" 'client scopes'
}

client_role_id_by_name() {
  local client_id=$1
  local wanted=$2
  local roles_csv id name
  if ! roles_csv=$(kcadm get "clients/$client_id/roles" -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes); then
    printf 'Failed to read client roles while looking up %s\n' "$wanted" >&2
    return 2
  fi
  while IFS=, read -r id name; do
    if [[ $name == "$wanted" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done <<<"$roles_csv"
  return 1
}

optional_lookup() {
  local result status
  if result=$("$@"); then
    printf '%s\n' "$result"
    return 0
  else
    status=$?
  fi
  if [[ $status == 1 ]]; then
    return 0
  fi
  return "$status"
}

# account-center signs in through the realm's own browser flow. The retired native handoff
# needed a client-specific copy of it (account-center-browser, with the sky-native-handoff
# subflow) bound to the client; the Web handoff (ADR-0048) does not. An older deployment is
# brought back here: the client's browser binding is removed, then that flow is deleted
# together with its subflows. Both steps are no-ops once done. Keycloak 26.7.4 refuses to
# delete a flow that something still points to, but only with "unknown_error"; a realm flow
# binding or another client that still uses it stops the run first and is named.
retire_account_center_browser_flow() {
  local live_file overrides flow_id realm_bindings clients_json
  live_file=$(mktemp "$WORK_DIR/client-flow.XXXXXX")
  kcadm_json "clients/$ACCOUNT_CENTER_UUID" -r "$TARGET_REALM" >"$live_file"
  overrides=$(json_tool field authenticationFlowBindingOverrides <"$live_file")
  if [[ $overrides =~ \"browser\"[[:space:]]*:[[:space:]]*\"[^\"]+\" ]]; then
    kcadm update "clients/$ACCOUNT_CENTER_UUID" -r "$TARGET_REALM" \
      -s 'authenticationFlowBindingOverrides.browser=' >/dev/null
    log "client $CLIENT_ID browser flow binding: updated (removed; the realm browser flow applies)"
  else
    log "client $CLIENT_ID browser flow binding: unchanged (the realm browser flow applies)"
  fi

  if flow_id=$(optional_lookup flow_id_by_alias "$LEGACY_FLOW_ALIAS"); then
    :
  else
    return $?
  fi
  if [[ -z $flow_id ]]; then
    log "authentication flow $LEGACY_FLOW_ALIAS: unchanged (absent)"
    return 0
  fi
  # No -c with --fields: kcadm then prints nothing and still exits 0. A map field needs (*), or
  # kcadm returns it empty.
  realm_bindings=$(kcadm_json "realms/$TARGET_REALM" \
    --fields browserFlow,registrationFlow,directGrantFlow,resetCredentialsFlow,clientAuthenticationFlow,dockerAuthenticationFlow,firstBrokerLoginFlow)
  if [[ $realm_bindings == *"\"$LEGACY_FLOW_ALIAS\""* ]]; then
    printf 'A realm flow binding still uses %s; bind the realm to its own flows before this flow can be retired\n' \
      "$LEGACY_FLOW_ALIAS" >&2
    return 1
  fi
  clients_json=$(kcadm_json clients -r "$TARGET_REALM" --fields 'clientId,authenticationFlowBindingOverrides(*)')
  if [[ $clients_json == *"$flow_id"* ]]; then
    printf 'Another client is still bound to %s; unbind it before this flow can be retired\n' \
      "$LEGACY_FLOW_ALIAS" >&2
    return 1
  fi
  kcadm delete "authentication/flows/$flow_id" -r "$TARGET_REALM" >/dev/null
  log "authentication flow $LEGACY_FLOW_ALIAS: deleted (with its retired native handoff subflow)"
}

# Kcadm path segment for a flow alias. Aliases outside this conservative set are refused
# rather than encoded, so an unexpected name can never address another resource.
flow_alias_path() {
  local alias=$1
  if [[ ! $alias =~ ^[A-Za-z0-9._\ -]+$ ]]; then
    printf 'Unsupported characters in authentication flow alias: %s\n' "$alias" >&2
    return 1
  fi
  printf '%s\n' "${alias// /%20}"
}

# Puts authenticator TO in the place of authenticator FROM in FLOW_ALIAS and logs one line
# "NOUN of flow 'FLOW_ALIAS': unchanged|updated (...)" (K4's password form, K4b's choose-user step,
# the reset credentials OTP step). Admin REST cannot change the provider of an execution, so the
# new one is added under the same parent flow with the same priority (Keycloak orders executions
# by priority alone) and made REQUIRED (Admin REST adds it DISABLED when its factory offers more
# than one requirement, as auth-otp-form and reset-otp do), then the old one is deleted. For that
# moment the flow runs the step twice; there is never a moment without it. ReconcileJson (its
# password-form planner, which names no provider of its own) refuses, and nothing is written,
# unless the flow holds exactly one of the two, REQUIRED, without an authenticator config and with
# a priority none of its siblings shares. A run cut between the writes leaves both side by side,
# which the next run finishes; a DISABLED FROM next to a REQUIRED TO in the same flow (the state an
# Admin Console change leaves) is removed, and so is a DISABLED TO elsewhere next to a REQUIRED
# FROM (that change taken back) before the swap. The flow's other executions are never touched. Keycloak
# refuses any change to a built-in flow, so FLOW_ALIAS must name an editable one.
swap_flow_execution() {
  local flow_alias=$1 from=$2 to=$3 noun=$4
  local flow_path live_file plan_file status action execution_id parent_id priority parent_alias parent_path added_id
  flow_path=$(flow_alias_path "$flow_alias")
  live_file=$(mktemp "$WORK_DIR/flow-execution.XXXXXX")
  plan_file=$(mktemp "$WORK_DIR/flow-execution-plan.XXXXXX")
  kcadm_json "authentication/flows/$flow_path/executions" -r "$TARGET_REALM" >"$live_file"
  if json_tool password-form "$from" "$to" <"$live_file" >"$plan_file"; then
    status=0
  else
    status=$?
  fi
  if [[ $status == 4 ]]; then
    printf "%s of flow '%s' was not changed: the step above explains why\n" "${noun^}" "$flow_alias" >&2
    return 1
  elif [[ $status != 0 ]]; then
    printf "Could not plan the %s of flow '%s' (status %s)\n" "$noun" "$flow_alias" "$status" >&2
    return 1
  fi
  # The third field is the parent flow id for swap and the id of TO for resume.
  IFS=$'\t' read -r action execution_id parent_id priority <"$plan_file"
  case $action in
    unchanged)
      log "$noun of flow '$flow_alias': unchanged ($to)"
      return 0
      ;;
    finish)
      kcadm delete "authentication/executions/$execution_id" -r "$TARGET_REALM" >/dev/null
      log "$noun of flow '$flow_alias': updated (finished an interrupted swap: removed $from next to $to)"
      ;;
    resume)
      kcadm update "authentication/flows/$flow_path/executions" -r "$TARGET_REALM" -n \
        -b "{\"id\":\"$parent_id\",\"requirement\":\"REQUIRED\",\"priority\":$priority}" >/dev/null
      kcadm delete "authentication/executions/$execution_id" -r "$TARGET_REALM" >/dev/null
      log "$noun of flow '$flow_alias': updated (finished an interrupted swap: $to DISABLED -> REQUIRED, removed $from)"
      ;;
    retire)
      kcadm delete "authentication/executions/$execution_id" -r "$TARGET_REALM" >/dev/null
      log "$noun of flow '$flow_alias': updated (removed the DISABLED $from next to the REQUIRED $to)"
      ;;
    discard)
      kcadm delete "authentication/executions/$execution_id" -r "$TARGET_REALM" >/dev/null
      log "$noun of flow '$flow_alias': updated (removed the DISABLED $to next to the REQUIRED $from)"
      swap_flow_execution "$flow_alias" "$from" "$to" "$noun"
      return
      ;;
    swap)
      if [[ $parent_id == - ]]; then
        parent_alias=$flow_alias
      else
        parent_alias=$(kcadm_json "authentication/flows/$parent_id" -r "$TARGET_REALM" | json_tool field alias)
      fi
      parent_path=$(flow_alias_path "$parent_alias")
      added_id=$(kcadm create "authentication/flows/$parent_path/executions/execution" -r "$TARGET_REALM" -i \
        -b "{\"provider\":\"$to\",\"priority\":$priority}")
      # A no-op when the factory already added it REQUIRED (its only requirement).
      kcadm update "authentication/flows/$flow_path/executions" -r "$TARGET_REALM" -n \
        -b "{\"id\":\"$added_id\",\"requirement\":\"REQUIRED\",\"priority\":$priority}" >/dev/null
      kcadm delete "authentication/executions/$execution_id" -r "$TARGET_REALM" >/dev/null
      log "$noun of flow '$flow_alias': updated ($from -> $to in subflow '$parent_alias', priority $priority, REQUIRED)"
      ;;
    *)
      printf "Unexpected %s plan for flow '%s': %s\n" "$noun" "$flow_alias" "$action" >&2
      return 1
      ;;
  esac
  kcadm_json "authentication/flows/$flow_path/executions" -r "$TARGET_REALM" >"$live_file"
  if ! json_tool password-form "$from" "$to" <"$live_file" >"$plan_file" \
    || [[ $(cut -f1 "$plan_file") != unchanged ]]; then
    printf "%s of flow '%s' is not in place after the swap; inspect it in the Admin Console\n" \
      "${noun^}" "$flow_alias" >&2
    return 1
  fi
}

# K4: puts PASSWORD_FORM in the place of the other username/password form in FLOW_ALIAS
# (default: the SKY LAB form replaces Keycloak's; the rollback swaps it back). The flow's other
# executions (passkey, OTP, passkey offer, organization) are never touched.
reconcile_password_form() {
  local flow_alias=$1 from
  if [[ $PASSWORD_FORM == "$SKY_PASSWORD_FORM" ]]; then
    from=$STOCK_PASSWORD_FORM
  else
    from=$SKY_PASSWORD_FORM
  fi
  swap_flow_execution "$flow_alias" "$from" "$PASSWORD_FORM" 'password form'
}

# K4b: puts RESET_CHOOSE_USER in the place of the other choose-user step in the realm's reset
# credentials flow (default: the SKY LAB step replaces Keycloak's; the rollback swaps it back),
# with swap_flow_execution. Keycloak's built-in "reset credentials" flow cannot be edited: a realm
# still bound to a built-in flow gets an editable copy of it (RESET_FLOW_COPY_ALIAS, made once and
# reused afterwards, even by a run cut short), the swap happens in the copy, and only then is the
# realm bound to the copy, so no request ever meets a half-made flow. The rollback swaps back in
# whichever flow is bound and keeps that binding: the copy then holds exactly Keycloak's steps.
# A realm bound to a built-in flow already runs Keycloak's own step, which the rollback leaves as
# it is. Binding the copy is a realm PUT of that one field, the same kind every realm step makes.
reconcile_reset_choose_user() {
  local from bound bound_path flow_id built_in target rebound
  if [[ $RESET_CHOOSE_USER == "$SKY_RESET_CHOOSE_USER" ]]; then
    from=$STOCK_RESET_CHOOSE_USER
  else
    from=$SKY_RESET_CHOOSE_USER
  fi
  bound=$(kcadm_json "realms/$TARGET_REALM" --fields resetCredentialsFlow | json_tool field resetCredentialsFlow)
  if [[ -z $bound ]]; then
    printf 'The realm has no reset credentials flow binding; nothing was changed\n' >&2
    return 1
  fi
  if flow_id=$(optional_lookup flow_id_by_alias "$bound"); then
    :
  else
    return $?
  fi
  if [[ -z $flow_id ]]; then
    printf "The realm's reset credentials flow '%s' does not exist; nothing was changed\n" "$bound" >&2
    return 1
  fi
  built_in=$(kcadm_json "authentication/flows/$flow_id" -r "$TARGET_REALM" | json_tool field builtIn)
  target=$bound
  if [[ $built_in == true && $RESET_CHOOSE_USER == "$SKY_RESET_CHOOSE_USER" ]]; then
    target=$RESET_FLOW_COPY_ALIAS
    if flow_id=$(optional_lookup flow_id_by_alias "$target"); then
      :
    else
      return $?
    fi
    if [[ -z $flow_id ]]; then
      bound_path=$(flow_alias_path "$bound")
      kcadm create "authentication/flows/$bound_path/copy" -r "$TARGET_REALM" \
        -s "newName=$target" >/dev/null
      log "authentication flow '$target': created (an editable copy of the built-in '$bound')"
    fi
  fi
  swap_flow_execution "$target" "$from" "$RESET_CHOOSE_USER" 'choose-user step'
  if [[ $target == "$bound" ]]; then
    log "realm reset credentials flow binding: unchanged ($bound)"
    return 0
  fi
  kcadm update "realms/$TARGET_REALM" -n -b "{\"resetCredentialsFlow\":\"$target\"}" >/dev/null
  rebound=$(kcadm_json "realms/$TARGET_REALM" --fields resetCredentialsFlow | json_tool field resetCredentialsFlow)
  if [[ $rebound != "$target" ]]; then
    printf "The realm's reset credentials flow is '%s', not '%s', after binding it; inspect it in the Admin Console\n" \
      "$rebound" "$target" >&2
    return 1
  fi
  log "realm reset credentials flow binding: updated ($bound -> $target)"
}

# eskylab-login-ux 23: in the realm's reset credentials flow, the OTP step of Keycloak's
# "Reset - Conditional OTP" subflow (its condition, user configured, stays): auth-otp-form asks a
# person with OTP for the code of the registered authenticator (the default, verify), reset-otp
# is Keycloak's own step (the rollback, reset). Runs after reconcile_reset_choose_user, so the
# realm is already bound to its editable copy; swap_flow_execution makes the change. In verify,
# ReconcileJson otp-guard then checks that the step actually runs (CONDITIONAL subflow on "user
# configured" with no other REQUIRED or CONDITIONAL step, nothing above it DISABLED); if not, a WARNING line replaces the "unchanged" line
# and the run ends with exit status 3 after its other steps. A realm
# still bound to Keycloak's built-in flow (only after a choose-user rollback on a realm that never
# had the copy) runs reset-otp, which cannot be changed there: verify warns, reset has nothing to do.
reconcile_reset_otp_step() {
  local from to bound flow_id built_in swap_lines guard status
  if [[ $RESET_OTP_STEP == verify ]]; then
    from=$STOCK_RESET_OTP_STEP
    to=$VERIFY_RESET_OTP_STEP
  else
    from=$VERIFY_RESET_OTP_STEP
    to=$STOCK_RESET_OTP_STEP
  fi
  bound=$(kcadm_json "realms/$TARGET_REALM" --fields resetCredentialsFlow | json_tool field resetCredentialsFlow)
  if [[ -z $bound ]]; then
    printf 'The realm has no reset credentials flow binding; nothing was changed\n' >&2
    return 1
  fi
  if flow_id=$(optional_lookup flow_id_by_alias "$bound"); then
    :
  else
    return $?
  fi
  if [[ -z $flow_id ]]; then
    printf "The realm's reset credentials flow '%s' does not exist; nothing was changed\n" "$bound" >&2
    return 1
  fi
  built_in=$(kcadm_json "authentication/flows/$flow_id" -r "$TARGET_REALM" | json_tool field builtIn)
  if [[ $built_in == true ]]; then
    if [[ $RESET_OTP_STEP == verify ]]; then
      warn "OTP step of flow '$bound' was not changed: Keycloak's built-in flow cannot be edited and runs $STOCK_RESET_OTP_STEP; a run with the default KEYCLOAK_RESET_CHOOSE_USER binds the realm to '$RESET_FLOW_COPY_ALIAS' first"
    else
      log "OTP step of flow '$bound': unchanged ($STOCK_RESET_OTP_STEP, Keycloak's built-in flow)"
    fi
    return 0
  fi
  # The swap's lines are held back until the guard below has looked at the result.
  swap_lines=$(swap_flow_execution "$bound" "$from" "$to" 'OTP step')
  if [[ $RESET_OTP_STEP == reset ]]; then
    printf '%s\n' "$swap_lines"
    return 0
  fi
  # A step in place proves nothing when its subflow never runs it (an Admin Console change):
  # the subflow must be CONDITIONAL on "user configured" alone, hold no other REQUIRED or CONDITIONAL
  # step (user configured would then need it too) and no enclosing subflow be DISABLED.
  # Otherwise a person with OTP resets by e-mail alone, which the run must not call unchanged.
  if guard=$(kcadm_json "authentication/flows/$(flow_alias_path "$bound")/executions" -r "$TARGET_REALM" \
    | json_tool otp-guard "$to"); then
    printf '%s\n' "$swap_lines"
    return 0
  else
    status=$?
  fi
  if [[ $status != 4 ]]; then
    printf "Could not check the OTP step of flow '%s' (status %s)\n" "$bound" "$status" >&2
    return 1
  fi
  grep -v ': unchanged (' <<<"$swap_lines" || true
  warn "OTP step of flow '$bound': $guard; OTP is not verified on reset as intended"
  RESET_OTP_UNGUARDED="OTP step of flow '$bound': $guard"
}

# eskylab-login-ux 08: the e-mail code subflow of the realm's browser flow (see EMAIL_CODE_LOGIN
# above). ReconcileJson email-code-flow plans it: the subflow belongs next to the password form's
# subflow (in production 'browser plus passkey' forms: passwordless WebAuthn ALTERNATIVE, password flow
# ALTERNATIVE), and is refused, with nothing written, when a REQUIRED or CONDITIONAL execution there
# would keep an ALTERNATIVE from ever running, or when someone added an execution to the subflow by
# hand. on adds what is missing (the subflow DISABLED first, then its parts, then their
# requirements), and only then makes the subflow ALTERNATIVE, so it never runs without its steps; a
# run cut in between is finished by the next one. Every write is read back. The realm's own browser
# flow binding is followed; a realm bound to Keycloak's built-in flow is refused (it cannot be edited).
reconcile_email_code_login() {
  local flow_alias built_in flow_id providers parent_alias subflow_path otp_path was executions
  local changes=()
  flow_alias=$(kcadm_json "realms/$TARGET_REALM" --fields browserFlow | json_tool field browserFlow)
  if [[ -z $flow_alias ]]; then
    if [[ $EMAIL_CODE_LOGIN == keep ]]; then
      warn "realm $TARGET_REALM has no browser flow binding; the e-mail code sign-in step has nothing to report"
      return 0
    fi
    printf 'Realm %s has no browser flow binding\n' "$TARGET_REALM" >&2
    return 1
  fi
  flow_id=$(flow_id_by_alias "$flow_alias")
  built_in=$(kcadm_json "authentication/flows/$flow_id" -r "$TARGET_REALM" | json_tool field builtIn)
  if [[ $built_in == true ]]; then
    if [[ $EMAIL_CODE_LOGIN == on ]]; then
      printf "Realm %s is bound to Keycloak's built-in browser flow '%s', which cannot be edited; nothing was changed\n" \
        "$TARGET_REALM" "$flow_alias" >&2
      return 1
    fi
    log "e-mail code sign-in of flow '$flow_alias': unchanged (Keycloak's built-in flow)"
    return 0
  fi
  # A full reconciliation (keep) never stops on a flow this step could not change: it says why, and
  # when the flow holds the e-mail code step it cannot vouch for the OTP after the code either.
  if [[ $EMAIL_CODE_LOGIN == keep ]]; then
    if ! plan_email_code_flow "$flow_alias" 2>"$WORK_DIR/email-code-keep.err"; then
      warn "e-mail code sign-in of flow '$flow_alias' could not be planned ($(head -n 1 "$WORK_DIR/email-code-keep.err")); KEYCLOAK_EMAIL_CODE_LOGIN=on or off would stop here"
      # Read whole first: grep -q stopping early would fail the pipe under pipefail.
      executions=$(kcadm_json "authentication/flows/$(flow_alias_path "$flow_alias")/executions" -r "$TARGET_REALM")
      if grep -Fq "\"$EMAIL_CODE_STEP\"" <<<"$executions"; then
        EMAIL_CODE_UNGUARDED="flow '$flow_alias' holds $EMAIL_CODE_STEP but could not be planned"
      fi
      return 0
    fi
  else
    plan_email_code_flow "$flow_alias" || return 1
  fi
  case $EMAIL_CODE_LOGIN in
    keep)
      if [[ $ECF_SUBFLOW == - ]]; then
        log "e-mail code sign-in of flow '$flow_alias': unchanged (no subflow; KEYCLOAK_EMAIL_CODE_LOGIN=on adds it)"
      else
        log "e-mail code sign-in of flow '$flow_alias': unchanged (subflow '$EMAIL_CODE_FLOW_ALIAS' $ECF_SUBFLOW_REQ; KEYCLOAK_EMAIL_CODE_LOGIN=on or off changes it)"
        if [[ $ECF_SUBFLOW_REQ != DISABLED ]] && ! email_code_parts_in_place; then
          warn "subflow '$EMAIL_CODE_FLOW_ALIAS' of flow '$flow_alias' runs without all its parts ($(email_code_parts_summary)); a person with TOTP may not be asked for it after the code; KEYCLOAK_EMAIL_CODE_LOGIN=on completes it, off turns it off"
          EMAIL_CODE_UNGUARDED="subflow '$EMAIL_CODE_FLOW_ALIAS' of flow '$flow_alias' runs without all its parts"
        fi
      fi
      return 0
      ;;
    off)
      if [[ $ECF_SUBFLOW == - ]]; then
        log "e-mail code sign-in of flow '$flow_alias': unchanged (no subflow; KEYCLOAK_EMAIL_CODE_LOGIN=off)"
      elif [[ $ECF_SUBFLOW_REQ == DISABLED ]]; then
        log "e-mail code sign-in of flow '$flow_alias': unchanged (subflow '$EMAIL_CODE_FLOW_ALIAS' DISABLED)"
      else
        was=$ECF_SUBFLOW_REQ
        set_email_code_requirement "$flow_alias" "$ECF_SUBFLOW" DISABLED "$ECF_SUBFLOW_PRIO"
        plan_email_code_flow "$flow_alias" || return 1
        if [[ $ECF_SUBFLOW_REQ != DISABLED ]]; then
          printf "Subflow '%s' of flow '%s' is %s after the change, not DISABLED; inspect it in the Admin Console\n" \
            "$EMAIL_CODE_FLOW_ALIAS" "$flow_alias" "$ECF_SUBFLOW_REQ" >&2
          return 1
        fi
        log "e-mail code sign-in of flow '$flow_alias': updated (subflow '$EMAIL_CODE_FLOW_ALIAS' $was -> DISABLED)"
      fi
      return 0
      ;;
  esac
  providers=$(kcadm get authentication/authenticator-providers -r "$TARGET_REALM" --fields id --format csv --noquotes)
  if ! grep -Fxq "$EMAIL_CODE_STEP" <<<"$providers"; then
    printf 'The image offers no %s authenticator (SPI 1.21.0 or later); nothing was changed\n' "$EMAIL_CODE_STEP" >&2
    return 1
  fi
  if [[ $ECF_SUBFLOW == - ]]; then
    if [[ $ECF_FORMS == - ]]; then
      parent_alias=$flow_alias
    else
      parent_alias=$(kcadm_json "authentication/flows/$ECF_FORMS" -r "$TARGET_REALM" | json_tool field alias)
    fi
    kcadm create "authentication/flows/$(flow_alias_path "$parent_alias")/executions/flow" -r "$TARGET_REALM" -i \
      -b "{\"alias\":\"$EMAIL_CODE_FLOW_ALIAS\",\"type\":\"basic-flow\",\"description\":\"SKY LAB: e-postaya gelen kodla giris (eskylab-login-ux 08)\",\"priority\":$ECF_NEXT}" >/dev/null
    changes+=("added subflow '$EMAIL_CODE_FLOW_ALIAS' to '$parent_alias' at priority $ECF_NEXT")
    plan_email_code_flow "$flow_alias" || return 1
  fi
  subflow_path=$(flow_alias_path "$EMAIL_CODE_FLOW_ALIAS")
  if [[ $ECF_STEP == - ]]; then
    kcadm create "authentication/flows/$subflow_path/executions/execution" -r "$TARGET_REALM" -i \
      -b "{\"provider\":\"$EMAIL_CODE_STEP\",\"priority\":10}" >/dev/null
    changes+=("added $EMAIL_CODE_STEP")
  fi
  if [[ $ECF_OTP == - ]]; then
    kcadm create "authentication/flows/$subflow_path/executions/flow" -r "$TARGET_REALM" -i \
      -b "{\"alias\":\"$EMAIL_CODE_OTP_FLOW_ALIAS\",\"type\":\"basic-flow\",\"description\":\"SKY LAB: koddan sonra TOTP (yalniz TOTP sahibine)\",\"priority\":20}" >/dev/null
    changes+=("added subflow '$EMAIL_CODE_OTP_FLOW_ALIAS'")
  fi
  if [[ $ECF_OFFER == - ]]; then
    kcadm create "authentication/flows/$subflow_path/executions/execution" -r "$TARGET_REALM" -i \
      -b "{\"provider\":\"$PASSKEY_OFFER_STEP\",\"priority\":30}" >/dev/null
    changes+=("added $PASSKEY_OFFER_STEP")
  fi
  otp_path=$(flow_alias_path "$EMAIL_CODE_OTP_FLOW_ALIAS")
  if [[ $ECF_COND == - ]]; then
    kcadm create "authentication/flows/$otp_path/executions/execution" -r "$TARGET_REALM" -i \
      -b '{"provider":"conditional-user-configured","priority":10}' >/dev/null
    changes+=("added conditional-user-configured")
  fi
  if [[ $ECF_OTP_FORM == - ]]; then
    kcadm create "authentication/flows/$otp_path/executions/execution" -r "$TARGET_REALM" -i \
      -b '{"provider":"auth-otp-form","priority":20}' >/dev/null
    changes+=("added auth-otp-form")
  fi
  plan_email_code_flow "$flow_alias" || return 1
  if ! email_code_parts_present; then
    printf "Subflow '%s' of flow '%s' still lacks a part after the additions; inspect it in the Admin Console\n" \
      "$EMAIL_CODE_FLOW_ALIAS" "$flow_alias" >&2
    return 1
  fi
  # The parts first, the subflow last: it never runs without its steps.
  set_email_code_requirement "$flow_alias" "$ECF_STEP" REQUIRED "$ECF_STEP_PRIO" "$ECF_STEP_REQ" "$EMAIL_CODE_STEP"
  set_email_code_requirement "$flow_alias" "$ECF_COND" REQUIRED "$ECF_COND_PRIO" "$ECF_COND_REQ" conditional-user-configured
  set_email_code_requirement "$flow_alias" "$ECF_OTP_FORM" REQUIRED "$ECF_OTP_FORM_PRIO" "$ECF_OTP_FORM_REQ" auth-otp-form
  set_email_code_requirement "$flow_alias" "$ECF_OTP" CONDITIONAL "$ECF_OTP_PRIO" "$ECF_OTP_REQ" "subflow '$EMAIL_CODE_OTP_FLOW_ALIAS'"
  set_email_code_requirement "$flow_alias" "$ECF_OFFER" REQUIRED "$ECF_OFFER_PRIO" "$ECF_OFFER_REQ" "$ECF_OFFER_PROVIDER"
  set_email_code_requirement "$flow_alias" "$ECF_SUBFLOW" ALTERNATIVE "$ECF_SUBFLOW_PRIO" "$ECF_SUBFLOW_REQ" "subflow '$EMAIL_CODE_FLOW_ALIAS'"
  plan_email_code_flow "$flow_alias" || return 1
  if [[ $ECF_SUBFLOW_REQ != ALTERNATIVE ]] || ! email_code_parts_in_place; then
    printf "Subflow '%s' of flow '%s' is not in place after the changes; inspect it in the Admin Console\n" \
      "$EMAIL_CODE_FLOW_ALIAS" "$flow_alias" >&2
    return 1
  fi
  if ((${#changes[@]} == 0)); then
    log "e-mail code sign-in of flow '$flow_alias': unchanged (subflow '$EMAIL_CODE_FLOW_ALIAS' ALTERNATIVE)"
  else
    local joined
    printf -v joined '%s; ' "${changes[@]}"
    log "e-mail code sign-in of flow '$flow_alias': updated (${joined%; })"
  fi
}

# Reads ReconcileJson email-code-flow's plan of FLOW_ALIAS into the ECF_* globals (one per line of
# the plan; "-" for a part that is missing). Runs in the caller's shell, never inside $( ).
plan_email_code_flow() {
  local flow_alias=$1 live_file plan_file status kind a b c d
  live_file=$(mktemp "$WORK_DIR/email-code.XXXXXX")
  plan_file=$(mktemp "$WORK_DIR/email-code-plan.XXXXXX")
  kcadm_json "authentication/flows/$(flow_alias_path "$flow_alias")/executions" -r "$TARGET_REALM" >"$live_file"
  if json_tool email-code-flow "$EMAIL_CODE_STEP" "$EMAIL_CODE_FLOW_ALIAS" "$EMAIL_CODE_OTP_FLOW_ALIAS" \
    "$PASSKEY_OFFER_STEP,$AFTER_SIGN_UP_STEP" "$SKY_PASSWORD_FORM" "$STOCK_PASSWORD_FORM" <"$live_file" >"$plan_file"; then
    status=0
  else
    status=$?
  fi
  if [[ $status != 0 ]]; then
    printf "E-mail code sign-in of flow '%s' was not changed (status %s): the step above explains why\n" \
      "$flow_alias" "$status" >&2
    return 1
  fi
  ECF_FORMS=- ECF_NEXT=-
  ECF_SUBFLOW=- ECF_SUBFLOW_REQ=- ECF_SUBFLOW_PRIO=-
  ECF_STEP=- ECF_STEP_REQ=- ECF_STEP_PRIO=-
  ECF_OTP=- ECF_OTP_REQ=- ECF_OTP_PRIO=-
  ECF_OFFER=- ECF_OFFER_REQ=- ECF_OFFER_PRIO=-
  ECF_OFFER_PROVIDER=-
  ECF_COND=- ECF_COND_REQ=- ECF_COND_PRIO=-
  ECF_OTP_FORM=- ECF_OTP_FORM_REQ=- ECF_OTP_FORM_PRIO=-
  while IFS=$'\t' read -r kind a b c d; do
    case $kind in
      forms) ECF_FORMS=$a ECF_NEXT=$b ;;
      subflow) ECF_SUBFLOW=$a ECF_SUBFLOW_REQ=$c ECF_SUBFLOW_PRIO=$d ;;
      step) ECF_STEP=$a ECF_STEP_REQ=$b ECF_STEP_PRIO=$c ;;
      otp) ECF_OTP=$a ECF_OTP_REQ=$c ECF_OTP_PRIO=$d ;;
      offer) ECF_OFFER=$a ECF_OFFER_REQ=$b ECF_OFFER_PRIO=$c ;;
      offer-provider) ECF_OFFER_PROVIDER=$a ;;
      otp-condition) ECF_COND=$a ECF_COND_REQ=$b ECF_COND_PRIO=$c ;;
      otp-form) ECF_OTP_FORM=$a ECF_OTP_FORM_REQ=$b ECF_OTP_FORM_PRIO=$c ;;
    esac
  done <"$plan_file"
}

email_code_parts_present() {
  [[ $ECF_STEP != - && $ECF_OTP != - && $ECF_OFFER != - && $ECF_COND != - && $ECF_OTP_FORM != - ]]
}

# What each part of the subflow is now, for a warning: "sky-email-code REQUIRED, subflow '…' DISABLED, …".
email_code_parts_summary() {
  printf "%s %s, subflow '%s' %s, conditional-user-configured %s, auth-otp-form %s, %s %s" \
    "$EMAIL_CODE_STEP" "${ECF_STEP_REQ/#-/missing}" "$EMAIL_CODE_OTP_FLOW_ALIAS" "${ECF_OTP_REQ/#-/missing}" \
    "${ECF_COND_REQ/#-/missing}" "${ECF_OTP_FORM_REQ/#-/missing}" "${ECF_OFFER_PROVIDER/#-/missing}" "${ECF_OFFER_REQ/#-/missing}"
}

email_code_parts_in_place() {
  email_code_parts_present \
    && [[ $ECF_STEP_REQ == REQUIRED && $ECF_OTP_REQ == CONDITIONAL && $ECF_OFFER_REQ == REQUIRED \
      && $ECF_COND_REQ == REQUIRED && $ECF_OTP_FORM_REQ == REQUIRED ]]
}

# set_email_code_requirement FLOW_ALIAS ID WANTED PRIORITY [CURRENT LABEL]: makes the execution ID
# WANTED with its own priority (Admin REST would otherwise move it to priority 0) and, with CURRENT
# and LABEL, notes the change in the caller's changes array when there is one.
set_email_code_requirement() {
  local flow_alias=$1 id=$2 wanted=$3 priority=$4 current=${5:-} label=${6:-}
  [[ $current != "$wanted" ]] || return 0
  kcadm update "authentication/flows/$(flow_alias_path "$flow_alias")/executions" -r "$TARGET_REALM" -n \
    -b "{\"id\":\"$id\",\"requirement\":\"$wanted\",\"priority\":$priority}" >/dev/null
  if [[ -n $label ]]; then
    changes+=("$label $current -> $wanted")
  fi
}

# B10 changes only the offer in the email-code child flow. Disable the child during replacement;
# a cut leaves it closed. Rerun with EMAIL_CODE_LOGIN=on to complete a cut/disabled swap explicitly.
after_sign_up_flag() {
  local attributes
  # kcadm --fields attributes projects an EMPTY map. The wildcard keeps every existing key.
  attributes=$(kcadm_json "realms/$TARGET_REALM" --fields 'attributes(*)' | json_tool field attributes)
  [[ -n $attributes ]] || attributes='{}'
  json_tool field "$AFTER_SIGN_UP_ATTRIBUTE" <<<"$attributes"
}

set_after_sign_up_flag() {
  local wanted=$1 live_file="$WORK_DIR/after-sign-up-realm.json" body="$WORK_DIR/after-sign-up-write.json"
  [[ $(after_sign_up_flag) != "$wanted" ]] || return 0
  kcadm_json "realms/$TARGET_REALM" --fields 'attributes(*)' >"$live_file"
  json_tool realm-attribute "$AFTER_SIGN_UP_ATTRIBUTE" "$wanted" <"$live_file" >"$body"
  kcadm update "realms/$TARGET_REALM" -n -f "$body" >/dev/null
  [[ $(after_sign_up_flag) == "$wanted" ]] || { printf 'Registration continuation flag readback failed\n' >&2; return 1; }
}

reconcile_after_sign_up() {
  local flag flow_alias wanted providers original_requirement offer_priority actions password_priority passkey_priority
  local mine minimum stay last action enabled row
  local changes=()
  flag=$(after_sign_up_flag)
  if [[ $AFTER_SIGN_UP == keep && $flag != true ]]; then
    log 'registration continuation: unchanged (off; KEYCLOAK_AFTER_SIGN_UP=on activates it)'
    return 0
  fi
  # Rollback must close new continuations before touching registrations or executions.
  if [[ $AFTER_SIGN_UP == off ]]; then set_after_sign_up_flag false; fi
  flow_alias=$(kcadm_json "realms/$TARGET_REALM" --fields browserFlow | json_tool field browserFlow)
  [[ -n $flow_alias ]] || { printf 'Registration continuation needs the realm browser flow\n' >&2; return 1; }
  plan_email_code_flow "$flow_alias" || return 1
  if [[ $ECF_SUBFLOW == - ]]; then
    if [[ $AFTER_SIGN_UP == off ]]; then
      reconcile_switched_required_action 'registration credentials' "$AFTER_SIGN_UP_ACTION" \
        'SKY LAB sign-up credential choices' KEYCLOAK_AFTER_SIGN_UP off 1.27.0
      log 'registration continuation: unchanged (off, no email-code child flow)'
      return 0
    fi
    printf 'Registration continuation needs KEYCLOAK_EMAIL_CODE_LOGIN=on\n' >&2
    return 1
  fi
  wanted=$AFTER_SIGN_UP_STEP
  [[ $AFTER_SIGN_UP != off ]] || wanted=$PASSKEY_OFFER_STEP
  providers=$(kcadm get authentication/authenticator-providers -r "$TARGET_REALM" --fields id --format csv --noquotes)
  grep -Fxq "$wanted" <<<"$providers" || { printf 'The image offers no %s (SPI 1.27.0 or later)\n' "$wanted" >&2; return 1; }
  actions=$(kcadm get authentication/required-actions -r "$TARGET_REALM" \
    --fields alias,providerId,enabled,defaultAction,priority --format csv --noquotes)
  row=$(grep -E "^$AFTER_SIGN_UP_ACTION," <<<"$actions" || true)
  if [[ -n $row && $row != "$AFTER_SIGN_UP_ACTION,$AFTER_SIGN_UP_ACTION,"* ]]; then
    printf 'Registration credential alias belongs to another provider; inspect it before changing anything\n' >&2
    return 1
  fi
  if [[ $AFTER_SIGN_UP != off ]]; then
    # These remain native optional actions; do not grant roles/scopes or change their policies.
    for action in UPDATE_PASSWORD webauthn-register-passwordless; do
      row=$(grep -E "^$action,$action,true,false," <<<"$actions" || true)
      [[ -n $row ]] || { printf 'Registration continuation needs enabled non-default native action %s\n' "$action" >&2; return 1; }
    done
    password_priority=$(grep '^UPDATE_PASSWORD,' <<<"$actions" | cut -d, -f5)
    passkey_priority=$(grep '^webauthn-register-passwordless,' <<<"$actions" | cut -d, -f5)
    minimum=$password_priority
    ((passkey_priority >= minimum)) || minimum=$passkey_priority
    ((minimum > -2147483648)) || { printf 'Native action priorities leave no room for registration choices\n' >&2; return 1; }
    mine=$(grep -E "^$AFTER_SIGN_UP_ACTION,$AFTER_SIGN_UP_ACTION,true,false," <<<"$actions" | cut -d, -f5 || true)
    stay=$(grep -E "^$STAY_SIGNED_IN_ACTION,$STAY_SIGNED_IN_ACTION,true," <<<"$actions" | cut -d, -f5 || true)
    last=$(grep -Ev "^$STAY_SIGNED_IN_ACTION," <<<"$actions" | cut -d, -f5 | sort -n | tail -1)
    if [[ $flag == true && $ECF_SUBFLOW_REQ == ALTERNATIVE && $ECF_OFFER_PROVIDER == "$wanted" ]] \
      && email_code_parts_in_place && [[ -n $mine ]] && ((mine < minimum)) \
      && { [[ -z $stay ]] || ((stay > last)); }; then
      log 'registration continuation: unchanged (on; native action order verified)'
      return 0
    fi
    if [[ $AFTER_SIGN_UP == keep ]]; then
      printf 'Registration continuation is on with flow/action drift; use KEYCLOAK_AFTER_SIGN_UP=on to repair or off to roll back\n' >&2
      return 1
    fi
    if [[ $ECF_SUBFLOW_REQ != ALTERNATIVE || $ECF_STEP_REQ != REQUIRED || $ECF_OTP_REQ != CONDITIONAL \
      || $ECF_COND_REQ != REQUIRED || $ECF_OTP_FORM_REQ != REQUIRED || $ECF_OFFER == - ]]; then
      printf 'Complete the email-code subflow with KEYCLOAK_EMAIL_CODE_LOGIN=on before registration continuation\n' >&2
      return 1
    fi
  fi
  if [[ $AFTER_SIGN_UP == on ]]; then
    # A repair is closed while its dependencies change. In a steady state the early return above
    # means on is a real no-op, including no realm-attribute write/admin event.
    set_after_sign_up_flag false
    reconcile_switched_required_action 'registration credentials' "$AFTER_SIGN_UP_ACTION" \
      'SKY LAB sign-up credential choices' KEYCLOAK_AFTER_SIGN_UP on 1.27.0
    if [[ -z $mine ]] || ((mine >= minimum)); then
      kcadm update "authentication/required-actions/$AFTER_SIGN_UP_ACTION" -r "$TARGET_REALM" \
        -s "priority=$((minimum - 1))" >/dev/null
    fi
    actions=$(kcadm get authentication/required-actions -r "$TARGET_REALM" \
      --fields alias,providerId,enabled,defaultAction,priority --format csv --noquotes)
    mine=$(grep -E "^$AFTER_SIGN_UP_ACTION,$AFTER_SIGN_UP_ACTION,true,false," <<<"$actions" | cut -d, -f5 || true)
    [[ -n $mine ]] && ((mine < minimum)) || { printf 'Registration credential action priority readback failed\n' >&2; return 1; }
    if [[ -n $stay ]]; then
      last=$(grep -Ev "^$STAY_SIGNED_IN_ACTION," <<<"$actions" | cut -d, -f5 | sort -n | tail -1)
      if ((stay <= last)); then
        kcadm update "authentication/required-actions/$STAY_SIGNED_IN_ACTION" -r "$TARGET_REALM" \
          -s "priority=$((last + 1))" >/dev/null
        row=$(kcadm get "authentication/required-actions/$STAY_SIGNED_IN_ACTION" -r "$TARGET_REALM" --fields priority | json_tool field priority)
        [[ $row == "$((last + 1))" ]] || { printf 'Stay signed in priority readback failed\n' >&2; return 1; }
      fi
    fi
  fi
  original_requirement=$ECF_SUBFLOW_REQ
  offer_priority=$ECF_OFFER_PRIO
  [[ $offer_priority != - ]] || offer_priority=$((ECF_OTP_PRIO + 10))
  if [[ $ECF_OFFER_PROVIDER != "$wanted" ]]; then
    set_email_code_requirement "$flow_alias" "$ECF_SUBFLOW" DISABLED "$ECF_SUBFLOW_PRIO" "$ECF_SUBFLOW_REQ"
    [[ $ECF_OFFER == - ]] || kcadm delete "authentication/executions/$ECF_OFFER" -r "$TARGET_REALM" >/dev/null
    kcadm create "authentication/flows/$(flow_alias_path "$EMAIL_CODE_FLOW_ALIAS")/executions/execution" -r "$TARGET_REALM" \
      -b "{\"provider\":\"$wanted\",\"priority\":$offer_priority}" >/dev/null
    plan_email_code_flow "$flow_alias" || return 1
    [[ $ECF_OFFER_PROVIDER == "$wanted" ]] || { printf 'Registration offer swap readback failed\n' >&2; return 1; }
    set_email_code_requirement "$flow_alias" "$ECF_OFFER" REQUIRED "$offer_priority"
    set_email_code_requirement "$flow_alias" "$ECF_SUBFLOW" "$original_requirement" "$ECF_SUBFLOW_PRIO" "$ECF_SUBFLOW_REQ"
  fi
  plan_email_code_flow "$flow_alias" || return 1
  [[ $ECF_OFFER_PROVIDER == "$wanted" && $ECF_OFFER_REQ == REQUIRED ]] || { printf 'Registration offer final readback failed\n' >&2; return 1; }
  if [[ $AFTER_SIGN_UP == on ]]; then
    email_code_parts_in_place && [[ $ECF_SUBFLOW_REQ == ALTERNATIVE ]] || return 1
    set_after_sign_up_flag true
  else
    reconcile_switched_required_action 'registration credentials' "$AFTER_SIGN_UP_ACTION" \
      'SKY LAB sign-up credential choices' KEYCLOAK_AFTER_SIGN_UP off 1.27.0
  fi
  log "registration continuation: reconciled ($AFTER_SIGN_UP; only the email-code offer changed)"
}

# eskylab-login-ux 09: Self-registration on the e-mail code step (see EMAIL_CODE_SIGN_UP above). The
# step's sign-up setting lives in its Keycloak authenticator config: on creates the config
# (EMAIL_CODE_SIGN_UP_CONFIG_ALIAS) or sets the setting to true, off sets it to false; both read the
# config back. The step is found with the e-mail code planner, so a flow that one would refuse is
# refused here too. keep only reports.
reconcile_email_code_sign_up() {
  local flow_alias flow_id built_in config_id config_file body_file status state wanted
  flow_alias=$(kcadm_json "realms/$TARGET_REALM" --fields browserFlow | json_tool field browserFlow)
  if [[ -z $flow_alias ]]; then
    if [[ $EMAIL_CODE_SIGN_UP == on ]]; then
      printf 'Realm %s has no browser flow binding\n' "$TARGET_REALM" >&2
      return 1
    fi
    log "e-mail code sign-up: unchanged (realm $TARGET_REALM has no browser flow binding)"
    return 0
  fi
  flow_id=$(flow_id_by_alias "$flow_alias")
  built_in=$(kcadm_json "authentication/flows/$flow_id" -r "$TARGET_REALM" | json_tool field builtIn)
  if [[ $built_in == true ]]; then
    if [[ $EMAIL_CODE_SIGN_UP == on ]]; then
      printf "Realm %s is bound to Keycloak's built-in browser flow '%s', which has no e-mail code step; nothing was changed\n" \
        "$TARGET_REALM" "$flow_alias" >&2
      return 1
    fi
    log "e-mail code sign-up of flow '$flow_alias': unchanged (Keycloak's built-in flow)"
    return 0
  fi
  if [[ $EMAIL_CODE_SIGN_UP == keep ]]; then
    if ! plan_email_code_flow "$flow_alias" 2>/dev/null; then
      log "e-mail code sign-up of flow '$flow_alias': unchanged (the flow could not be planned; see the e-mail code sign-in line)"
      return 0
    fi
  else
    plan_email_code_flow "$flow_alias" || return 1
  fi
  if [[ $ECF_STEP == - ]]; then
    if [[ $EMAIL_CODE_SIGN_UP == on ]]; then
      printf "Flow '%s' has no %s step for the sign-up setting; KEYCLOAK_EMAIL_CODE_LOGIN=on adds it (it may run in the same call)\n" \
        "$flow_alias" "$EMAIL_CODE_STEP" >&2
      return 1
    fi
    log "e-mail code sign-up of flow '$flow_alias': unchanged (no $EMAIL_CODE_STEP step)"
    return 0
  fi
  config_file=$(mktemp "$WORK_DIR/sign-up-config.XXXXXX")
  body_file=$(mktemp "$WORK_DIR/sign-up-body.XXXXXX")
  config_id=$(kcadm_json "authentication/executions/$ECF_STEP" -r "$TARGET_REALM" | json_tool field authenticatorConfig)
  state=off
  if [[ -n $config_id ]]; then
    kcadm_json "authentication/config/$config_id" -r "$TARGET_REALM" >"$config_file"
    if json_tool config-value "$EMAIL_CODE_SIGN_UP_SETTING" true <"$config_file" >/dev/null; then
      state=on
    fi
  fi
  case $EMAIL_CODE_SIGN_UP in
    keep)
      log "e-mail code sign-up of flow '$flow_alias': unchanged ($state; KEYCLOAK_EMAIL_CODE_SIGN_UP=on or off changes it)"
      return 0
      ;;
    on)
      if [[ $state == on ]]; then
        log "e-mail code sign-up of flow '$flow_alias': unchanged (on)"
        return 0
      fi
      if [[ -z $config_id ]]; then
        kcadm create "authentication/executions/$ECF_STEP/config" -r "$TARGET_REALM" \
          -b "{\"alias\":\"$EMAIL_CODE_SIGN_UP_CONFIG_ALIAS\",\"config\":{\"$EMAIL_CODE_SIGN_UP_SETTING\":\"true\"}}" >/dev/null
      else
        if json_tool config-value "$EMAIL_CODE_SIGN_UP_SETTING" true <"$config_file" >"$body_file"; then
          status=0
        else
          status=$?
        fi
        if [[ $status != 3 ]]; then
          printf "Could not plan the sign-up setting of %s in flow '%s' (status %s)\n" "$EMAIL_CODE_STEP" "$flow_alias" "$status" >&2
          return 1
        fi
        kcadm update "authentication/config/$config_id" -r "$TARGET_REALM" -n -f "$body_file" >/dev/null
      fi
      ;;
    off)
      if [[ $state == off ]]; then
        log "e-mail code sign-up of flow '$flow_alias': unchanged (off)"
        return 0
      fi
      if json_tool config-value "$EMAIL_CODE_SIGN_UP_SETTING" false <"$config_file" >"$body_file"; then
        status=0
      else
        status=$?
      fi
      if [[ $status != 3 ]]; then
        printf "Could not plan the sign-up setting of %s in flow '%s' (status %s)\n" "$EMAIL_CODE_STEP" "$flow_alias" "$status" >&2
        return 1
      fi
      kcadm update "authentication/config/$config_id" -r "$TARGET_REALM" -n -f "$body_file" >/dev/null
      ;;
  esac
  # Read back: the setting is what was asked for.
  config_id=$(kcadm_json "authentication/executions/$ECF_STEP" -r "$TARGET_REALM" | json_tool field authenticatorConfig)
  if [[ -z $config_id ]]; then
    printf "The %s step of flow '%s' has no config after the change; inspect it in the Admin Console\n" "$EMAIL_CODE_STEP" "$flow_alias" >&2
    return 1
  fi
  kcadm_json "authentication/config/$config_id" -r "$TARGET_REALM" >"$config_file"
  wanted=false
  if [[ $EMAIL_CODE_SIGN_UP == on ]]; then
    wanted=true
  fi
  if ! json_tool config-value "$EMAIL_CODE_SIGN_UP_SETTING" "$wanted" <"$config_file" >/dev/null; then
    printf "The sign-up setting of %s in flow '%s' is not %s after the change; inspect it in the Admin Console\n" \
      "$EMAIL_CODE_STEP" "$flow_alias" "$EMAIL_CODE_SIGN_UP" >&2
    return 1
  fi
  log "e-mail code sign-up of flow '$flow_alias': updated ($state -> $EMAIL_CODE_SIGN_UP)"
}

# eskylab-login-ux 07: the realm's first broker login flow. With KEYCLOAK_YTU_FIRST_LOGIN=on the
# realm runs FIRST_BROKER_FLOW_COPY_ALIAS, an editable copy of Keycloak's built-in flow (made once,
# reused afterwards, even by a run cut short) in which
#   - YTU_FIRST_LOGIN_STEP runs at the top level just before the review profile step (REQUIRED,
#     the only requirement its factory offers);
#   - the review profile step shows its page only when a required field is missing
#     (REVIEW_PROFILE_SETTING=missing in its own config; the built-in flow's config is not touched);
#   - every "Verify Existing Account By Email" step (idp-email-verification) is DISABLED, so an
#     existing account is only ever confirmed by re-authentication (ADR-0044: no mailed links).
# The copy is edited first and only then is the realm bound to it, so no login meets a half-made
# flow. A realm bound to any other flow than these two is refused: the rollback has to be able to
# give back exactly Keycloak's built-in flow. KEYCLOAK_YTU_FIRST_LOGIN=off binds the realm back to
# the built-in flow and leaves the copy as it is. Binding is a realm PUT of that one field. With
# keep (the default) the binding is left as it is; a realm already bound to the copy gets the copy's
# three edits checked and repaired.
reconcile_first_broker_login() {
  local bound flow_id built_in
  bound=$(kcadm_json "realms/$TARGET_REALM" --fields firstBrokerLoginFlow | json_tool field firstBrokerLoginFlow)
  if [[ $YTU_FIRST_LOGIN == keep ]]; then
    if [[ $bound == "$FIRST_BROKER_FLOW_COPY_ALIAS" ]]; then
      edit_first_broker_login_flow "$FIRST_BROKER_FLOW_COPY_ALIAS"
    fi
    log "realm first broker login flow binding: unchanged (${bound:-none}; KEYCLOAK_YTU_FIRST_LOGIN=on or off changes it)"
    return 0
  fi
  if [[ $YTU_FIRST_LOGIN == off ]]; then
    if [[ $bound == "$FIRST_BROKER_FLOW_COPY_ALIAS" ]]; then
      bind_first_broker_login_flow "$bound" "$FIRST_BROKER_FLOW_BUILT_IN"
    else
      log "realm first broker login flow binding: unchanged (${bound:-none}; KEYCLOAK_YTU_FIRST_LOGIN=off)"
    fi
    reconcile_ytu_idp_first_login_flow
    return 0
  fi
  if [[ -z $bound ]]; then
    printf 'The realm has no first broker login flow binding; nothing was changed\n' >&2
    return 1
  fi
  if [[ $bound != "$FIRST_BROKER_FLOW_COPY_ALIAS" ]]; then
    if flow_id=$(optional_lookup flow_id_by_alias "$bound"); then
      :
    else
      return $?
    fi
    built_in=''
    if [[ -n $flow_id ]]; then
      built_in=$(kcadm_json "authentication/flows/$flow_id" -r "$TARGET_REALM" | json_tool field builtIn)
    fi
    if [[ $bound != "$FIRST_BROKER_FLOW_BUILT_IN" || $built_in != true ]]; then
      printf "The realm's first broker login flow is '%s', neither Keycloak's built-in '%s' nor '%s'; nothing was changed\n" \
        "$bound" "$FIRST_BROKER_FLOW_BUILT_IN" "$FIRST_BROKER_FLOW_COPY_ALIAS" >&2
      return 1
    fi
    if flow_id=$(optional_lookup flow_id_by_alias "$FIRST_BROKER_FLOW_COPY_ALIAS"); then
      :
    else
      return $?
    fi
    if [[ -z $flow_id ]]; then
      kcadm create "authentication/flows/$(flow_alias_path "$bound")/copy" -r "$TARGET_REALM" \
        -s "newName=$FIRST_BROKER_FLOW_COPY_ALIAS" >/dev/null
      log "authentication flow '$FIRST_BROKER_FLOW_COPY_ALIAS': created (an editable copy of the built-in '$bound')"
    fi
  fi
  edit_first_broker_login_flow "$FIRST_BROKER_FLOW_COPY_ALIAS"
  if [[ $bound == "$FIRST_BROKER_FLOW_COPY_ALIAS" ]]; then
    log "realm first broker login flow binding: unchanged ($bound)"
  else
    bind_first_broker_login_flow "$bound" "$FIRST_BROKER_FLOW_COPY_ALIAS"
  fi
  reconcile_ytu_idp_first_login_flow
}

# The three edits of reconcile_first_broker_login in FLOW_ALIAS, each logged as unchanged or
# updated; ReconcileJson's first-broker-login planner refuses a flow it cannot place them in.
edit_first_broker_login_flow() {
  local flow_alias=$1
  local flow_path live_file plan_file config_file body_file status kind id priority requirement
  local review_id='' review_config=''
  flow_path=$(flow_alias_path "$flow_alias")
  live_file=$(mktemp "$WORK_DIR/first-broker.XXXXXX")
  plan_file=$(mktemp "$WORK_DIR/first-broker-plan.XXXXXX")
  config_file=$(mktemp "$WORK_DIR/review-config.XXXXXX")
  body_file=$(mktemp "$WORK_DIR/review-config-body.XXXXXX")
  kcadm_json "authentication/flows/$flow_path/executions" -r "$TARGET_REALM" >"$live_file"
  if json_tool first-broker-login "$YTU_FIRST_LOGIN_STEP" <"$live_file" >"$plan_file"; then
    status=0
  else
    status=$?
  fi
  if [[ $status != 0 ]]; then
    printf "Flow '%s' was not changed (status %s): the step above explains why\n" "$flow_alias" "$status" >&2
    return 1
  fi
  while IFS=$'\t' read -r kind id priority requirement; do
    case $kind in
      step)
        if [[ $id == - ]]; then
          kcadm create "authentication/flows/$flow_path/executions/execution" -r "$TARGET_REALM" \
            -b "{\"provider\":\"$YTU_FIRST_LOGIN_STEP\",\"priority\":$priority}" >/dev/null
          log "first login step of flow '$flow_alias': updated (added $YTU_FIRST_LOGIN_STEP before the review profile step, priority $priority, REQUIRED)"
        elif [[ $requirement != REQUIRED ]]; then
          kcadm update "authentication/flows/$flow_path/executions" -r "$TARGET_REALM" -n \
            -b "{\"id\":\"$id\",\"requirement\":\"REQUIRED\",\"priority\":$priority}" >/dev/null
          log "first login step of flow '$flow_alias': updated ($YTU_FIRST_LOGIN_STEP $requirement -> REQUIRED)"
        else
          log "first login step of flow '$flow_alias': unchanged ($YTU_FIRST_LOGIN_STEP, priority $priority)"
        fi
        ;;
      review)
        review_id=$id
        review_config=$priority
        ;;
      email-verification)
        if [[ $requirement == DISABLED ]]; then
          log "link verification of flow '$flow_alias': unchanged (idp-email-verification DISABLED)"
        else
          kcadm update "authentication/flows/$flow_path/executions" -r "$TARGET_REALM" -n \
            -b "{\"id\":\"$id\",\"requirement\":\"DISABLED\",\"priority\":$priority}" >/dev/null
          log "link verification of flow '$flow_alias': updated (idp-email-verification $requirement -> DISABLED)"
        fi
        ;;
    esac
  done <"$plan_file"
  if [[ -z $review_id ]]; then
    printf "Flow '%s' has no review profile step to configure\n" "$flow_alias" >&2
    return 1
  fi
  if [[ $review_config == - ]]; then
    kcadm create "authentication/executions/$review_id/config" -r "$TARGET_REALM" \
      -b "{\"alias\":\"$flow_alias review profile config\",\"config\":{\"$REVIEW_PROFILE_SETTING\":\"missing\"}}" >/dev/null
    log "review profile of flow '$flow_alias': updated (created its config, $REVIEW_PROFILE_SETTING=missing)"
  else
    kcadm_json "authentication/config/$review_config" -r "$TARGET_REALM" >"$config_file"
    if json_tool config-value "$REVIEW_PROFILE_SETTING" missing <"$config_file" >"$body_file"; then
      log "review profile of flow '$flow_alias': unchanged ($REVIEW_PROFILE_SETTING=missing)"
    else
      status=$?
      if [[ $status != 3 ]]; then
        printf "Could not plan the review profile config of flow '%s' (status %s)\n" "$flow_alias" "$status" >&2
        return 1
      fi
      kcadm update "authentication/config/$review_config" -r "$TARGET_REALM" -n -f "$body_file" >/dev/null
      log "review profile of flow '$flow_alias': updated ($REVIEW_PROFILE_SETTING=missing)"
    fi
  fi
  # Read back: the step is in place and REQUIRED, and no link verification is left.
  kcadm_json "authentication/flows/$flow_path/executions" -r "$TARGET_REALM" >"$live_file"
  if ! json_tool first-broker-login "$YTU_FIRST_LOGIN_STEP" <"$live_file" >"$plan_file" \
    || ! grep -Eq "^step"$'\t'"[^-]"".*"$'\t'"REQUIRED\$" "$plan_file" \
    || grep -Eq "^email-verification"$'\t'".*"$'\t'"(REQUIRED|ALTERNATIVE|CONDITIONAL)\$" "$plan_file"; then
    printf "Flow '%s' is not in place after the edits; inspect it in the Admin Console\n" "$flow_alias" >&2
    return 1
  fi
  check_first_broker_login_copy_shape "$flow_alias" "$live_file"
}

# Apart from the step and the disabled link verification, the copy must stay the built-in flow
# (eskylab-login-ux 22, review F2): every first YTÜ login runs it, and an execution added by hand
# (idp-auto-link, idp-detect-existing-broker-user, idp-confirm-override-link, …) would change who can
# link which account. A difference is reported loudly (the release wizards treat it as a failure)
# and nothing is changed: removing someone's execution is a decision, not a repair. A Keycloak
# upgrade that changes the built-in flow is reported the same way (the copy does not follow it).
check_first_broker_login_copy_shape() {
  local flow_alias=$1 live_file=$2 built_in_file difference_file
  built_in_file=$(mktemp "$WORK_DIR/built-in-flow.XXXXXX")
  difference_file=$(mktemp "$WORK_DIR/copy-shape.XXXXXX")
  kcadm_json "authentication/flows/$(flow_alias_path "$FIRST_BROKER_FLOW_BUILT_IN")/executions" -r "$TARGET_REALM" >"$built_in_file"
  if json_tool same-shape "$built_in_file" "$YTU_FIRST_LOGIN_STEP" <"$live_file" 2>"$difference_file"; then
    log "shape of flow '$flow_alias': unchanged (the built-in '$FIRST_BROKER_FLOW_BUILT_IN' plus the SKY LAB edits)"
  else
    warn "flow '$flow_alias' is not shaped like the built-in '$FIRST_BROKER_FLOW_BUILT_IN' apart from the SKY LAB edits: $(head -n 1 "$difference_file"); nothing was changed; inspect it in the Admin Console"
  fi
}

# The native create/confirm/reauthentication/OTP branches stay intact. Only their known review
# step gets a config-preserving wrapper; a proven-link alternative runs before native creation.
# The planner refuses any extra/moved native execution before the first mutation.
reconcile_existing_account_prompt() {
  local mode=$EXISTING_ACCOUNT_PROMPT flow_id bound live_file builtin_file plan_file providers_file
  local kind id parent provider priority extra last added config_source config_body line
  flow_id=$(optional_lookup flow_id_by_alias "$FIRST_BROKER_FLOW_COPY_ALIAS")
  if [[ -z $flow_id ]]; then
    if [[ $mode == on ]]; then
      printf 'Existing-account protection requires KEYCLOAK_YTU_FIRST_LOGIN=on first; no flow was changed\n' >&2
      return 1
    fi
    return 0
  fi
  live_file=$(mktemp "$WORK_DIR/existing-account-live.XXXXXX")
  builtin_file=$(mktemp "$WORK_DIR/existing-account-builtin.XXXXXX")
  plan_file=$(mktemp "$WORK_DIR/existing-account-plan.XXXXXX")
  providers_file=$(mktemp "$WORK_DIR/existing-account-providers.XXXXXX")
  kcadm_json "authentication/flows/$(flow_alias_path "$FIRST_BROKER_FLOW_COPY_ALIAS")/executions" -r "$TARGET_REALM" >"$live_file"
  if [[ $mode == keep ]]; then
    if ! grep -Eq '"providerId"[[:space:]]*:[[:space:]]*"(sky-existing-account-prompt|sky-existing-account-proven|sky-broker-review-profile)"' "$live_file"; then
      log 'existing-account protection: unchanged (not enabled; explicit KEYCLOAK_EXISTING_ACCOUNT_PROMPT=on is required)'
      return 0
    fi
    mode=on
  fi
  if [[ $mode == on ]]; then
    bound=$(kcadm_json "realms/$TARGET_REALM" --fields firstBrokerLoginFlow | json_tool field firstBrokerLoginFlow)
    if [[ $bound != "$FIRST_BROKER_FLOW_COPY_ALIAS" ]]; then
      printf 'Existing-account protection only edits the active SKY LAB first-broker-login copy; enable the school-primary step first\n' >&2
      return 1
    fi
    kcadm_json authentication/authenticator-providers -r "$TARGET_REALM" >"$providers_file"
    json_tool existing-account-providers <"$providers_file" || return 1
  fi
  kcadm_json "authentication/flows/$(flow_alias_path "$FIRST_BROKER_FLOW_BUILT_IN")/executions" -r "$TARGET_REALM" >"$builtin_file"
  json_tool existing-account-flow "$mode" "$flow_id" "$builtin_file" <"$live_file" >"$plan_file" || return 1
  while IFS=$'\t' read -r kind id parent provider priority extra last; do
    case $kind in
      remove)
        kcadm delete "authentication/executions/$id" -r "$TARGET_REALM" >/dev/null
        log "existing-account protection: updated (removed replaced execution $id)"
        ;;
      review)
        added=$id
        if [[ $added == - ]]; then
          added=$(kcadm create authentication/executions -r "$TARGET_REALM" -i \
            -b "{\"parentFlow\":\"$parent\",\"authenticator\":\"$provider\",\"priority\":$priority,\"requirement\":\"REQUIRED\",\"authenticatorFlow\":false}")
          log "existing-account protection: updated (added $provider at the native review position)"
        fi
        # EXTRA is the replaced review's config; LAST is the desired review's config. Never
        # share the old config: native execution deletion may remove it too.
        if [[ $last == - ]]; then
          config_source=$(mktemp "$WORK_DIR/existing-review-source.XXXXXX")
          config_body=$(mktemp "$WORK_DIR/existing-review-body.XXXXXX")
          if [[ $extra != - ]]; then
            kcadm_json "authentication/config/$extra" -r "$TARGET_REALM" >"$config_source"
          else
            printf '{}\n' >"$config_source"
          fi
          json_tool copy-broker-review-config "$FIRST_BROKER_FLOW_COPY_ALIAS $provider config" <"$config_source" >"$config_body"
          kcadm create "authentication/executions/$added/config" -r "$TARGET_REALM" -f "$config_body" >/dev/null
          log 'existing-account protection: updated (copied review config; missing fields only)'
        fi
        ;;
      ensure)
        if [[ $last == same ]]; then
          continue
        fi
        added=$id
        if [[ $added == - ]]; then
          added=$(kcadm create authentication/executions -r "$TARGET_REALM" -i \
            -b "{\"parentFlow\":\"$parent\",\"authenticator\":\"$provider\",\"priority\":$priority,\"requirement\":\"$extra\",\"authenticatorFlow\":false}")
        else
          kcadm update "authentication/flows/$(flow_alias_path "$FIRST_BROKER_FLOW_COPY_ALIAS")/executions" -r "$TARGET_REALM" -n \
            -b "{\"id\":\"$added\",\"priority\":$priority,\"requirement\":\"$extra\"}" >/dev/null
        fi
        log "existing-account protection: updated ($provider $extra at priority $priority)"
        ;;
      *)
        printf 'Unexpected existing-account flow plan row: %s\n' "$kind" >&2
        return 1
        ;;
    esac
  done <"$plan_file"
  kcadm_json "authentication/flows/$(flow_alias_path "$FIRST_BROKER_FLOW_COPY_ALIAS")/executions" -r "$TARGET_REALM" >"$live_file"
  json_tool existing-account-flow "$mode" "$flow_id" "$builtin_file" <"$live_file" >"$plan_file" || return 1
  while IFS=$'\t' read -r kind id parent provider priority extra last; do
    if [[ $kind == remove || $id == - || ( $kind == review && $last == - ) || ( $kind == ensure && $last != same ) ]]; then
      printf 'Existing-account protection did not converge; inspect the flow before enabling registration\n' >&2
      return 1
    fi
  done <"$plan_file"
  json_tool same-shape "$builtin_file" "$YTU_FIRST_LOGIN_STEP" <"$live_file" || return 1
  log "existing-account protection: reconciled ($mode; native duplicate, confirmation, reauthentication and OTP paths preserved)"
}

bind_first_broker_login_flow() {
  local from=$1 to=$2 rebound
  kcadm update "realms/$TARGET_REALM" -n -b "{\"firstBrokerLoginFlow\":\"$to\"}" >/dev/null
  rebound=$(kcadm_json "realms/$TARGET_REALM" --fields firstBrokerLoginFlow | json_tool field firstBrokerLoginFlow)
  if [[ $rebound != "$to" ]]; then
    printf "The realm's first broker login flow is '%s', not '%s', after binding it; inspect it in the Admin Console\n" \
      "$rebound" "$to" >&2
    return 1
  fi
  log "realm first broker login flow binding: updated ($from -> $to)"
}

# OBS follows the realm's first broker login flow binding when it has no override of its own.
# With KEYCLOAK_YTU_FIRST_LOGIN=on its override is cleared when it names
#   - one of the two flows above, or
#   - one of YTU_IDP_LEGACY_FIRST_BROKER_FLOWS (production's hand-made duplicate of the built-in
#     flow), and only when that flow has the built-in flow's shape: the same executions in the same
#     order, levels, indexes and requirements (ReconcileJson same-shape; ids, names, priorities and
#     config values are not compared, so its review profile "on" does not count). OBS then gets
#     what the copy adds and nothing it had is lost. A flow of another shape is refused with a
#     WARNING and nothing on OBS changes (exit status 0: the realm binding is already done and
#     harmless; the operator reads the warning). The cleared alias is noted on OBS itself, in its
#     config YTU_IDP_PREVIOUS_FLOW_SETTING, in the same update; the flow is kept, unused.
# With off the override is written back from that note and the note emptied, so the rollback gives
# back exactly the pre-on state, but only while the note names one of YTU_IDP_LEGACY_FIRST_BROKER_FLOWS
# and that flow still exists with the built-in flow's shape (otherwise a WARNING, and OBS follows the
# built-in binding); an override naming the copy is cleared as before. The note, not a fixed name, decides: off restores only what on removed, never
# an override someone removed by hand. Any other override is reported and kept. Sync mode FORCE is
# reported loudly: the SKY LAB step then leaves an address another account already has unwritten
# (Keycloak would copy it onto the account being linked). The reconciler identity cannot read
# identity providers (no identity provider permissions, by design), so a reconcile run only says
# so; an operator session (KEYCLOAK_RECONCILE_ONLY=first-broker-login) does the check.
reconcile_ytu_idp_first_login_flow() {
  local idp_file stderr_file override previous
  idp_file=$(mktemp "$WORK_DIR/idp.XXXXXX")
  stderr_file=$(mktemp "$WORK_DIR/idp-stderr.XXXXXX")
  if ! kcadm get "identity-provider/instances/$YTU_IDP_ALIAS" -r "$TARGET_REALM" >"$idp_file" 2>"$stderr_file"; then
    if grep -Eqi '403|forbidden' "$stderr_file"; then
      log "identity provider $YTU_IDP_ALIAS first login flow: unchanged (not readable with this identity; an operator checks it with KEYCLOAK_RECONCILE_ONLY=first-broker-login)"
      return 0
    fi
    if grep -Eqi '404|not found' "$stderr_file"; then
      log "identity provider $YTU_IDP_ALIAS first login flow: unchanged (absent)"
      return 0
    fi
    cat "$stderr_file" >&2
    return 1
  fi
  if [[ $(json_tool field config <"$idp_file") =~ \"syncMode\"[[:space:]]*:[[:space:]]*\"FORCE\" ]]; then
    warn "identity provider $YTU_IDP_ALIAS syncs with FORCE: a first YTÜ login whose School e-mail or username another account already has opens the review profile page instead of linking that account; turn the step off (KEYCLOAK_YTU_FIRST_LOGIN=off) before keeping OBS on FORCE"
  fi
  override=$(json_tool field firstBrokerLoginFlowAlias <"$idp_file")
  previous=$(json_tool field config <"$idp_file" | json_tool field "$YTU_IDP_PREVIOUS_FLOW_SETTING")
  if [[ $YTU_FIRST_LOGIN == off && ( -z $override || $override == "$FIRST_BROKER_FLOW_COPY_ALIAS" ) && -n $previous ]]; then
    restore_ytu_idp_first_login_flow "$previous" "$override"
  elif [[ -z $override ]]; then
    log "identity provider $YTU_IDP_ALIAS first login flow: unchanged (follows the realm binding)"
  elif [[ ( $YTU_FIRST_LOGIN == on && ( $override == "$FIRST_BROKER_FLOW_BUILT_IN" || $override == "$FIRST_BROKER_FLOW_COPY_ALIAS" ) ) \
    || ( $YTU_FIRST_LOGIN == off && $override == "$FIRST_BROKER_FLOW_COPY_ALIAS" ) ]]; then
    set_ytu_idp_first_login_flow ''
    log "identity provider $YTU_IDP_ALIAS first login flow: updated (its override is removed; it follows the realm binding)"
  elif is_ytu_idp_legacy_flow "$override"; then
    if [[ $YTU_FIRST_LOGIN == on ]]; then
      remove_ytu_idp_legacy_flow "$override"
    else
      log "identity provider $YTU_IDP_ALIAS first login flow: unchanged (keeps its own first login flow '$override', as before KEYCLOAK_YTU_FIRST_LOGIN=on)"
    fi
  else
    warn "identity provider $YTU_IDP_ALIAS keeps its own first login flow '$override' and ignores the realm binding"
  fi
}

is_ytu_idp_legacy_flow() {
  local candidate
  for candidate in "${YTU_IDP_LEGACY_FIRST_BROKER_FLOWS[@]}"; do
    [[ $1 == "$candidate" ]] && return 0
  done
  return 1
}

# set_ytu_idp_first_login_flow OVERRIDE [NOTE]: one update of OBS, its override and (when given)
# the note YTU_IDP_PREVIOUS_FLOW_SETTING, read back. Without NOTE the note is left as it is.
set_ytu_idp_first_login_flow() {
  local want_override=$1 idp_file override previous
  local arguments=(-s "firstBrokerLoginFlowAlias=$want_override")
  if [[ $# == 2 ]]; then
    arguments+=(-s "config.$YTU_IDP_PREVIOUS_FLOW_SETTING=$2")
  fi
  kcadm update "identity-provider/instances/$YTU_IDP_ALIAS" -r "$TARGET_REALM" "${arguments[@]}" >/dev/null
  idp_file=$(mktemp "$WORK_DIR/idp-after.XXXXXX")
  kcadm_json "identity-provider/instances/$YTU_IDP_ALIAS" -r "$TARGET_REALM" >"$idp_file"
  override=$(json_tool field firstBrokerLoginFlowAlias <"$idp_file")
  previous=$(json_tool field config <"$idp_file" | json_tool field "$YTU_IDP_PREVIOUS_FLOW_SETTING")
  if [[ $override != "$want_override" || ( $# == 2 && $previous != "$2" ) ]]; then
    printf "Identity provider %s overrides the first login flow with '%s' (note: '%s') after the update, not '%s'; inspect it in the Admin Console\n" \
      "$YTU_IDP_ALIAS" "$override" "$previous" "$want_override" >&2
    return 1
  fi
}

# on: OBS's override names a legacy duplicate of the built-in flow. Cleared (and noted) only while
# that flow has the built-in flow's shape.
remove_ytu_idp_legacy_flow() {
  local legacy=$1 legacy_file built_in_file difference_file bound
  legacy_file=$(mktemp "$WORK_DIR/legacy-flow.XXXXXX")
  built_in_file=$(mktemp "$WORK_DIR/built-in-flow.XXXXXX")
  difference_file=$(mktemp "$WORK_DIR/flow-shape.XXXXXX")
  kcadm_json "authentication/flows/$(flow_alias_path "$legacy")/executions" -r "$TARGET_REALM" >"$legacy_file"
  kcadm_json "authentication/flows/$(flow_alias_path "$FIRST_BROKER_FLOW_BUILT_IN")/executions" -r "$TARGET_REALM" >"$built_in_file"
  if ! json_tool same-shape "$built_in_file" <"$legacy_file" 2>"$difference_file"; then
    warn "identity provider $YTU_IDP_ALIAS: first login flow binding refused (its override '$legacy' is not shaped like the built-in '$FIRST_BROKER_FLOW_BUILT_IN': $(head -n 1 "$difference_file"); OBS keeps it and ignores the realm binding; nothing on OBS was changed; inspect the flow in the Admin Console)"
    return 0
  fi
  set_ytu_idp_first_login_flow '' "$legacy"
  bound=$(kcadm_json "realms/$TARGET_REALM" --fields firstBrokerLoginFlow | json_tool field firstBrokerLoginFlow)
  log "identity provider $YTU_IDP_ALIAS: first login flow binding removed (follows realm binding '$bound'; previous '$legacy' kept, unused)"
}

# off: OBS's override goes back to the alias the on run noted, but only while that alias is one of
# YTU_IDP_LEGACY_FIRST_BROKER_FLOWS, the flow still exists and it still has the built-in flow's shape
# (review F1: the note and the unused flow can be edited after on). Otherwise nothing is written
# back: a WARNING, OBS follows the realm binding (the built-in flow after off; an override naming
# the copy is cleared first) and the note stays for the operator to read.
restore_ytu_idp_first_login_flow() {
  local previous=$1 override=$2 flow_id legacy_file built_in_file difference_file why='' bound
  if ! is_ytu_idp_legacy_flow "$previous"; then
    why="its note names '$previous', not one of the known earlier flows"
  else
    if flow_id=$(optional_lookup flow_id_by_alias "$previous"); then
      :
    else
      return $?
    fi
    if [[ -z $flow_id ]]; then
      why="the flow '$previous' it had before KEYCLOAK_YTU_FIRST_LOGIN=on is absent"
    else
      legacy_file=$(mktemp "$WORK_DIR/legacy-flow.XXXXXX")
      built_in_file=$(mktemp "$WORK_DIR/built-in-flow.XXXXXX")
      difference_file=$(mktemp "$WORK_DIR/flow-shape.XXXXXX")
      kcadm_json "authentication/flows/$(flow_alias_path "$previous")/executions" -r "$TARGET_REALM" >"$legacy_file"
      kcadm_json "authentication/flows/$(flow_alias_path "$FIRST_BROKER_FLOW_BUILT_IN")/executions" -r "$TARGET_REALM" >"$built_in_file"
      if ! json_tool same-shape "$built_in_file" <"$legacy_file" 2>"$difference_file"; then
        why="the flow '$previous' is not shaped like the built-in '$FIRST_BROKER_FLOW_BUILT_IN' any more: $(head -n 1 "$difference_file")"
      fi
    fi
  fi
  if [[ -n $why ]]; then
    if [[ $override == "$FIRST_BROKER_FLOW_COPY_ALIAS" ]]; then
      set_ytu_idp_first_login_flow ''
    fi
    bound=$(kcadm_json "realms/$TARGET_REALM" --fields firstBrokerLoginFlow | json_tool field firstBrokerLoginFlow)
    warn "identity provider $YTU_IDP_ALIAS: first login flow binding not restored ($why; OBS follows the realm binding '$bound'; inspect it in the Admin Console)"
    return 0
  fi
  set_ytu_idp_first_login_flow "$previous" ''
  log "identity provider $YTU_IDP_ALIAS: first login flow binding restored ('$previous', as before KEYCLOAK_YTU_FIRST_LOGIN=on)"
}

# eskylab-login-ux 21: the realm's required action sky-personal-email-offer (see
# PERSONAL_EMAIL_OFFER above).
reconcile_personal_email_offer() {
  reconcile_switched_required_action 'personal e-mail offer' "$PERSONAL_EMAIL_OFFER_ACTION" \
    "$PERSONAL_EMAIL_OFFER_NAME" KEYCLOAK_PERSONAL_EMAIL_OFFER "$PERSONAL_EMAIL_OFFER" 1.18.0
}

# "Bu cihazda oturumum açık kalsın mı?" after a YTÜ login: the realm's required action
# sky-stay-signed-in (see STAY_SIGNED_IN above). With on it also runs after every other required
# action of the realm (the last page before the application, as Microsoft asks); keep only reports
# when it does not. The question needs the realm's remember-me on (config/account-center-realm.json):
# without it the action never asks, and the run says so.
reconcile_stay_signed_in() {
  local actions_csv mine others last remember_me
  reconcile_switched_required_action 'stay signed in' "$STAY_SIGNED_IN_ACTION" \
    "$STAY_SIGNED_IN_NAME" KEYCLOAK_STAY_SIGNED_IN "$STAY_SIGNED_IN" 1.19.0
  actions_csv=$(kcadm get authentication/required-actions -r "$TARGET_REALM" \
    --fields alias,enabled,priority --format csv --noquotes)
  mine=$(grep -E "^$STAY_SIGNED_IN_ACTION,true," <<<"$actions_csv" | cut -d, -f3 || true)
  [[ -n $mine ]] || return 0
  others=$(grep -Ev "^$STAY_SIGNED_IN_ACTION," <<<"$actions_csv" | cut -d, -f3 | sort -n | tail -n 1 || true)
  last=${others:--1}
  if ((mine > last)); then
    log "stay signed in required action order: unchanged (priority $mine, after every other required action)"
  elif [[ $STAY_SIGNED_IN == on ]]; then
    kcadm update "authentication/required-actions/$STAY_SIGNED_IN_ACTION" -r "$TARGET_REALM" \
      -s "priority=$((last + 1))" >/dev/null
    mine=$(kcadm get authentication/required-actions -r "$TARGET_REALM" --fields alias,priority --format csv --noquotes \
      | grep -E "^$STAY_SIGNED_IN_ACTION," | cut -d, -f2 || true)
    if [[ $mine != "$((last + 1))" ]]; then
      printf 'Required action %s has priority "%s" after the change, not %s; inspect it in the Admin Console\n' \
        "$STAY_SIGNED_IN_ACTION" "$mine" "$((last + 1))" >&2
      return 1
    fi
    log "stay signed in required action order: updated (priority -> $mine, after every other required action)"
  else
    warn "the stay signed in question runs before another required action (priority $mine, the last is $last); KEYCLOAK_STAY_SIGNED_IN=on puts it last"
  fi
  remember_me=$(kcadm_json "realms/$TARGET_REALM" --fields rememberMe | json_tool field rememberMe)
  if [[ $remember_me != true ]]; then
    warn "the realm has remember-me off: the stay signed in question is never asked until rememberMe=true (config/account-center-realm.json)"
  fi
}

# A required action of the SPI that a flag switches realm by realm (KEYCLOAK_PERSONAL_EMAIL_OFFER,
# KEYCLOAK_STAY_SIGNED_IN): on registers it when the image offers it and Keycloak lists it as
# unregistered (Keycloak registers it enabled), then enables it and keeps defaultAction false; off
# disables a registered action and leaves an unregistered one alone; keep only reports, so a full
# reconciliation never turns it on or off. It is never a default action (that would put it on every
# new account). The state is read back after every write.
# reconcile_switched_required_action LABEL ACTION NAME FLAG_NAME FLAG_VALUE SPI_VERSION
reconcile_switched_required_action() {
  local label=$1 action=$2 name=$3 flag_name=$4 flag=$5 spi_version=$6
  local actions_csv current enabled default_action unregistered
  actions_csv=$(kcadm get authentication/required-actions -r "$TARGET_REALM" \
    --fields alias,enabled,defaultAction --format csv --noquotes)
  current=$(grep -E "^$action," <<<"$actions_csv" || true)
  IFS=, read -r _ enabled default_action <<<"${current:-,,}"
  if [[ $flag == keep ]]; then
    if [[ -z $current ]]; then
      log "$label required action: unchanged (not registered; $flag_name=on registers and enables it)"
    else
      log "$label required action: unchanged (enabled=$enabled; $flag_name=on or off changes it)"
    fi
    return 0
  fi
  if [[ $flag == off ]]; then
    if [[ -z $current ]]; then
      log "$label required action: unchanged (not registered; $flag_name=off)"
    elif [[ $enabled == false && $default_action == false ]]; then
      log "$label required action: unchanged (disabled)"
    else
      kcadm update "authentication/required-actions/$action" -r "$TARGET_REALM" \
        -s enabled=false -s defaultAction=false >/dev/null
      verify_switched_required_action "$action" false
      log "$label required action: updated (enabled=$enabled -> disabled)"
    fi
    return 0
  fi
  if [[ -z $current ]]; then
    unregistered=$(kcadm get authentication/unregistered-required-actions -r "$TARGET_REALM" --fields providerId \
      --format csv --noquotes)
    if ! grep -Fxq "$action" <<<"$unregistered"; then
      printf 'The image offers no %s required action (SPI %s or later); nothing was changed\n' \
        "$action" "$spi_version" >&2
      return 1
    fi
    kcadm create authentication/register-required-action -r "$TARGET_REALM" \
      -b "{\"providerId\":\"$action\",\"name\":\"$name\"}" >/dev/null
    kcadm update "authentication/required-actions/$action" -r "$TARGET_REALM" \
      -s enabled=true -s defaultAction=false >/dev/null
    verify_switched_required_action "$action" true
    log "$label required action: updated (registered and enabled)"
  elif [[ $enabled == true && $default_action == false ]]; then
    log "$label required action: unchanged (enabled)"
  else
    kcadm update "authentication/required-actions/$action" -r "$TARGET_REALM" \
      -s enabled=true -s defaultAction=false >/dev/null
    verify_switched_required_action "$action" true
    log "$label required action: updated (enabled=$enabled defaultAction=$default_action -> enabled)"
  fi
}

verify_switched_required_action() {
  local action=$1 wanted=$2 actual
  actual=$(kcadm get authentication/required-actions -r "$TARGET_REALM" --fields alias,enabled,defaultAction \
    --format csv --noquotes | grep -E "^$action," || true)
  if [[ $actual != "$action,$wanted,false" ]]; then
    printf 'Required action %s is "%s" after the change, not enabled=%s defaultAction=false; inspect it in the Admin Console\n' \
      "$action" "$actual" "$wanted" >&2
    return 1
  fi
}

# Reads ENDPOINT, compares the desired fields against it and writes only when at least one
# differs. Objects compare as subsets and arrays as multisets, so an unchanged realm, client
# or client scope produces no admin event. Extra arguments (for example "-r realm") are
# passed to both kcadm calls.
apply_fields_if_changed() {
  local label=$1
  local desired_file=$2
  local endpoint=$3
  shift 3
  local live_file changed
  live_file=$(mktemp "$WORK_DIR/live.XXXXXX")
  kcadm_json "$endpoint" "$@" >"$live_file"
  changed=$(json_tool diff-fields "$desired_file" <"$live_file")
  if [[ -z $changed ]]; then
    log "$label: unchanged"
    return 0
  fi
  kcadm update "$endpoint" "$@" -n -f "$desired_file" >/dev/null
  log "$label: updated ($(tr '\n' ' ' <<<"$changed" | sed 's/ $//'))"
}

reconcile_realm_settings() {
  apply_fields_if_changed 'realm session, login and theme settings' \
    "$CONFIG_DIR/account-center-realm.json" "realms/$TARGET_REALM"
}

reconcile_brute_force_and_password_policy() {
  local login_csv
  apply_fields_if_changed 'brute force protection and password policy' \
    "$CONFIG_DIR/account-center-realm-security.json" "realms/$TARGET_REALM"
  # Username changes go through the sky-account extension; Account REST must not be able to
  # edit the username, and both e-mail addresses of a person sign in through the SKY LAB
  # authenticator, which requires unique e-mails.
  login_csv=$(kcadm get "realms/$TARGET_REALM" \
    --fields editUsernameAllowed,loginWithEmailAllowed,duplicateEmailsAllowed \
    --format csv \
    --noquotes)
  if [[ $login_csv != 'false,true,false' ]]; then
    printf 'Realm login settings differ from editUsernameAllowed=false, loginWithEmailAllowed=true, duplicateEmailsAllowed=false: %s\n' "$login_csv" >&2
    return 1
  fi
  log 'login settings asserted: editUsernameAllowed=false loginWithEmailAllowed=true duplicateEmailsAllowed=false'
}

# User and admin event retention (EVENT_RETENTION_* above). The four settings are fields of the
# realm; the admin event expiration is a realm attribute and is sent with the complete live
# attribute map (Keycloak drops every attribute a PUT with "attributes" leaves out). Both go in one
# PUT, and only when one of them differs, so an unchanged realm produces no admin event. The
# realm PUT needs manage-realm, which the reconciler identity holds; Keycloak's events/config
# endpoint (manage-events) is not used. Listeners and enabled event types are never sent.
reconcile_event_retention() {
  local desired_file="$WORK_DIR/event-retention.json" live_file="$WORK_DIR/event-retention-live.json"
  local attribute_file="$WORK_DIR/event-retention-attribute.json" write_file="$WORK_DIR/event-retention-write.json"
  local label="realm event retention (user and admin events ${EVENT_RETENTION_SECONDS} s, admin event details on)"
  local changed
  printf '%s\n' "$EVENT_RETENTION_SETTINGS" >"$desired_file"
  printf '{"attributes":{"%s":"%s"}}\n' "$ADMIN_EVENTS_EXPIRATION_ATTRIBUTE" "$EVENT_RETENTION_SECONDS" \
    >"$attribute_file"
  kcadm_json "realms/$TARGET_REALM" >"$live_file"
  changed=$(json_tool diff-fields "$desired_file" <"$live_file")
  if [[ -n $(json_tool diff-fields "$attribute_file" <"$live_file") ]]; then
    json_tool realm-attribute "$ADMIN_EVENTS_EXPIRATION_ATTRIBUTE" "$EVENT_RETENTION_SECONDS" \
      <"$live_file" >"$attribute_file"
    json_tool merge "$desired_file" "$attribute_file" >"$write_file"
    changed=$(printf '%s\nattributes.%s' "$changed" "$ADMIN_EVENTS_EXPIRATION_ATTRIBUTE")
  elif [[ -n $changed ]]; then
    cp "$desired_file" "$write_file"
  else
    log "$label: unchanged"
    return 0
  fi
  kcadm update "realms/$TARGET_REALM" -n -f "$write_file" >/dev/null
  log "$label: updated ($(sed '/^$/d' <<<"$changed" | tr '\n' ' ' | sed 's/ $//'))"
}

# The realm's RabbitMQ event listener (KEYCLOAK_RABBITMQ_EVENTS above). Only its own entry of
# eventsListeners is written, with one realm PUT of that field alone (manage-realm) and only when it
# changes, so an unchanged realm produces no admin event.
reconcile_rabbitmq_event_listener() {
  local label="realm event listener $RABBITMQ_EVENT_LISTENER" live entry state=off
  local write_file="$WORK_DIR/event-listeners.json" listeners=() kept=()
  local shape='^\[("[A-Za-z0-9_.-]+"(,"[A-Za-z0-9_.-]+")*)?\]$'
  live=$(kcadm_json "realms/$TARGET_REALM" --fields eventsListeners | json_tool field eventsListeners)
  [[ -n $live ]] || live='[]'
  if [[ ! $live =~ $shape ]]; then
    printf '%s: the realm eventsListeners are not a list of provider ids: %s\n' "$label" "$live" >&2
    return 1
  fi
  live=${live#[}
  live=${live%]}
  [[ -z $live ]] || IFS=',' read -ra listeners <<<"$live"
  for entry in ${listeners[@]+"${listeners[@]}"}; do
    entry=${entry//\"/}
    if [[ $entry == "$RABBITMQ_EVENT_LISTENER" ]]; then
      state=on
    else
      kept+=("$entry")
    fi
  done
  if [[ $RABBITMQ_EVENTS == keep ]]; then
    log "$label: unchanged ($state; KEYCLOAK_RABBITMQ_EVENTS=on or off changes it)"
    return 0
  fi
  if [[ $RABBITMQ_EVENTS == "$state" ]]; then
    log "$label: unchanged ($state)"
    return 0
  fi
  [[ $RABBITMQ_EVENTS == off ]] || kept+=("$RABBITMQ_EVENT_LISTENER")
  {
    printf '{"eventsListeners":['
    for entry in "${!kept[@]}"; do
      ((entry == 0)) || printf ','
      printf '"%s"' "${kept[$entry]}"
    done
    printf ']}\n'
  } >"$write_file"
  kcadm update "realms/$TARGET_REALM" -n -f "$write_file" >/dev/null
  log "$label: updated ($state -> $RABBITMQ_EVENTS)"
}

validate_passkey_policy_inputs() {
  local origin host configured_origins
  if [[ ! $PASSKEY_RP_ID =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$ ]]; then
    printf 'KEYCLOAK_PASSKEY_RP_ID must be a lowercase DNS name without scheme, port or path\n' >&2
    return 1
  fi
  if [[ $REQUIRE_PRODUCTION_HOST == true && $PASSKEY_RP_ID != yildizskylab.com ]]; then
    printf 'Production KEYCLOAK_PASSKEY_RP_ID must be exactly yildizskylab.com\n' >&2
    return 1
  fi
  PASSKEY_EXTRA_ORIGIN_LIST=()
  IFS=',' read -ra configured_origins <<<"$PASSKEY_EXTRA_ORIGINS"
  for origin in ${configured_origins[@]+"${configured_origins[@]}"}; do
    origin=${origin//[[:space:]]/}
    [[ -n $origin ]] || continue
    if [[ ! $origin =~ ^(https?)://([a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*)(:[0-9]{1,5})?$ ]]; then
      printf 'KEYCLOAK_PASSKEY_EXTRA_ORIGINS entries must be plain origins (scheme://host[:port]): %s\n' "$origin" >&2
      return 1
    fi
    host=${BASH_REMATCH[2]}
    if [[ $host != "$PASSKEY_RP_ID" && $host != *".$PASSKEY_RP_ID" ]]; then
      printf 'Passkey extra origin %s is not within the relying party id %s\n' "$origin" "$PASSKEY_RP_ID" >&2
      return 1
    fi
    if [[ $REQUIRE_PRODUCTION_HOST == true && ${BASH_REMATCH[1]} != https ]]; then
      printf 'Production passkey extra origins must use https: %s\n' "$origin" >&2
      return 1
    fi
    PASSKEY_EXTRA_ORIGIN_LIST+=("$origin")
  done
  if [[ ${#PASSKEY_EXTRA_ORIGIN_LIST[@]} == 0 ]]; then
    printf 'KEYCLOAK_PASSKEY_EXTRA_ORIGINS must name at least the Account Center origin\n' >&2
    return 1
  fi
}

# The relying party id makes one passkey valid on every SKY LAB origin (e., my., WebViews);
# the extra origins let Account Center run WebAuthn ceremonies against this realm policy.
# Keycloak rebuilds the whole passwordless policy from one realm update (defaults for every
# field the update leaves out), so the complete policy is declared in one document:
# account-center-passkey-policy.json plus the environment-derived rpId and extra origins.
# The two-factor WebAuthn policy (webAuthnPolicy*) is deliberately left unmanaged. Realm PUTs
# that carry no "attributes" map (this one and the realm settings above) make Keycloak reset
# the CIBA and PAR lifespans to their defaults; SKY LAB uses neither beyond the defaults.
#
# Every passkey registered before a relying party id change stops verifying, so the moment of
# a change is recorded in the realm attribute skylab.passkeyRpIdSwitchedAt before the policy
# is written: cleanup-legacy-passkeys.sh takes it as the cutover and refuses a later one. The
# attribute is written through the complete live "attributes" map because Keycloak drops every
# realm attribute that a PUT with "attributes" leaves out. Writing it first keeps a failed run
# repairable: the next run still sees the old relying party id and records the moment again.
reconcile_passkey_policy() {
  local desired_file="$WORK_DIR/passkey-policy.json" extra_file="$WORK_DIR/passkey-extra.json"
  local live_file="$WORK_DIR/passkey-live.json" switch_file="$WORK_DIR/passkey-switch.json"
  local origins_json='' origin live_rp_id switched_at
  validate_passkey_policy_inputs
  for origin in "${PASSKEY_EXTRA_ORIGIN_LIST[@]}"; do
    origins_json="$origins_json,\"$origin\""
  done
  origins_json="[${origins_json#,}]"
  printf '{"webAuthnPolicyPasswordlessRpId":"%s","webAuthnPolicyPasswordlessExtraOrigins":%s}\n' \
    "$PASSKEY_RP_ID" "$origins_json" >"$extra_file"
  json_tool merge "$CONFIG_DIR/account-center-passkey-policy.json" "$extra_file" >"$desired_file"
  kcadm_json "realms/$TARGET_REALM" >"$live_file"
  live_rp_id=$(json_tool field webAuthnPolicyPasswordlessRpId <"$live_file")
  if [[ $live_rp_id != "$PASSKEY_RP_ID" ]]; then
    switched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    json_tool realm-attribute "$PASSKEY_SWITCH_ATTRIBUTE" "$switched_at" <"$live_file" >"$switch_file"
    kcadm update "realms/$TARGET_REALM" -n -f "$switch_file" >/dev/null
    log "passkey relying party id switches from '${live_rp_id:-(empty)}' to '$PASSKEY_RP_ID': realm attribute $PASSKEY_SWITCH_ATTRIBUTE=$switched_at recorded; passkeys registered before it stop verifying (cleanup-legacy-passkeys.sh)"
  fi
  apply_fields_if_changed "passwordless passkey policy (rpId=$PASSKEY_RP_ID extraOrigins=$origins_json)" \
    "$desired_file" "realms/$TARGET_REALM"
}

reconcile_required_actions() {
  local actions_csv alias enabled default_action updated=''
  actions_csv=$(kcadm get authentication/required-actions -r "$TARGET_REALM" \
    --fields alias,enabled,defaultAction \
    --format csv \
    --noquotes)
  while IFS='|' read -r alias enabled default_action; do
    [[ -n $alias ]] || continue
    if grep -Fxq "$alias,$enabled,$default_action" <<<"$actions_csv"; then
      continue
    fi
    kcadm update "authentication/required-actions/$alias" \
      -r "$TARGET_REALM" \
      -s "enabled=$enabled" \
      -s "defaultAction=$default_action" >/dev/null
    updated="$updated $alias"
  done <"$CONFIG_DIR/account-center-required-actions.tsv"
  if [[ -z $updated ]]; then
    log 'required actions: unchanged'
  else
    log "required actions: updated (${updated# })"
  fi
}

# The User Profile keeps its live shape (groups, annotations, requirements, message keys).
# It only gains the SKY LAB attributes the sky-account extension writes at model level, makes
# firstName, lastName and email user:view-only and never leaves unmanaged attributes
# editable by the person.
reconcile_user_profile() {
  local live_file="$WORK_DIR/user-profile.json" desired_file="$WORK_DIR/user-profile.desired.json"
  local status policy
  kcadm_json users/profile -r "$TARGET_REALM" >"$live_file"
  if json_tool user-profile "$CONFIG_DIR/account-center-user-profile.json" \
    <"$live_file" >"$desired_file"; then
    log 'user profile: unchanged'
  else
    status=$?
    if [[ $status != 3 ]]; then
      printf 'User Profile merge failed with status %s\n' "$status" >&2
      return 1
    fi
    kcadm update users/profile -r "$TARGET_REALM" -n -f "$desired_file" >/dev/null
    log 'user profile: updated (SKY LAB attributes, user:view-only identity fields, unmanagedAttributePolicy=ADMIN_VIEW)'
  fi
  policy=$(kcadm get users/profile -r "$TARGET_REALM" \
    --fields unmanagedAttributePolicy \
    --format csv \
    --noquotes)
  if [[ $policy != ADMIN_VIEW ]]; then
    printf 'User Profile unmanagedAttributePolicy is %s instead of ADMIN_VIEW\n' "${policy:-unset}" >&2
    return 1
  fi
}

prune_protocol_mappers() {
  local scope_id=$1
  shift
  local mappers_csv id name allowed_name
  local seen_names='|'
  local keep pruned=''
  if ! mappers_csv=$(kcadm get "client-scopes/$scope_id/protocol-mappers/models" \
    -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes); then
    printf 'Failed to read protocol mappers for client scope %s\n' "$scope_id" >&2
    return 2
  fi
  while IFS=, read -r id name; do
    [[ -n $id ]] || continue
    keep=false
    for allowed_name in "$@"; do
      if [[ $name == "$allowed_name" && $seen_names != *"|$name|"* ]]; then
        seen_names="$seen_names$name|"
        keep=true
        break
      fi
    done
    if [[ $keep == true ]]; then
      continue
    fi
    kcadm delete "client-scopes/$scope_id/protocol-mappers/models/$id" \
      -r "$TARGET_REALM" >/dev/null
    pruned="$pruned $name"
  done <<<"$mappers_csv"
  if [[ -n $pruned ]]; then
    log "pruned protocol mappers from scope $scope_id:${pruned}"
  fi
}

# Creates missing mappers and rewrites drifted ones; mappers that already match the desired
# body are left alone so an unchanged scope produces no admin event.
ensure_protocol_mappers() {
  local scope_id=$1
  local desired_file=$2
  local live_file="$WORK_DIR/mappers-$scope_id.json" plan action mapper_id name body changed=''
  if ! kcadm_json "client-scopes/$scope_id/protocol-mappers/models" \
    -r "$TARGET_REALM" >"$live_file"; then
    printf 'Failed to read protocol mappers for client scope %s\n' "$scope_id" >&2
    return 2
  fi
  plan=$(json_tool mapper-diff "$desired_file" <"$live_file")
  [[ -n $plan ]] || return 0
  while IFS=$'\t' read -r action mapper_id name body; do
    [[ -n $action ]] || continue
    case $action in
      create)
        kcadm_quiet create "client-scopes/$scope_id/protocol-mappers/models" \
          -r "$TARGET_REALM" \
          -b "$body"
        changed="$changed +$name"
        ;;
      update)
        kcadm_quiet update "client-scopes/$scope_id/protocol-mappers/models/$mapper_id" \
          -r "$TARGET_REALM" \
          -n \
          -b "$body"
        changed="$changed ~$name"
        ;;
      *)
        printf 'Unexpected mapper plan entry: %s\n' "$action" >&2
        return 1
        ;;
    esac
  done <<<"$plan"
  log "protocol mappers of scope $scope_id: updated (${changed# })"
}

# Ensures one source-controlled client scope: attributes, allowlisted mappers, nothing else.
# Leaves the scope id in ENSURED_SCOPE_ID (stdout carries the log lines).
ensure_client_scope() {
  local scope_name=$1
  local mappers_file=$2
  local scope_id desired_file="$WORK_DIR/scope-$scope_name.json" allowed_names
  printf '{"name":"%s","protocol":"openid-connect","attributes":{"include.in.token.scope":"false","display.on.consent.screen":"false"}}\n' \
    "$scope_name" >"$desired_file"
  scope_id=$(optional_lookup client_scope_id_by_name "$scope_name")
  if [[ -z $scope_id ]]; then
    scope_id=$(kcadm create client-scopes -r "$TARGET_REALM" -i -f "$desired_file")
    log "client scope $scope_name: created"
  fi
  apply_fields_if_changed "client scope $scope_name" "$desired_file" \
    "client-scopes/$scope_id" -r "$TARGET_REALM"
  allowed_names=$(json_tool names <"$mappers_file")
  [[ -n $allowed_names ]] || {
    printf 'No protocol mappers are declared in %s\n' "$mappers_file" >&2
    return 1
  }
  # shellcheck disable=SC2086
  prune_protocol_mappers "$scope_id" $allowed_names
  ensure_protocol_mappers "$scope_id" "$mappers_file"
  ENSURED_SCOPE_ID=$scope_id
}

ensure_default_client_scope() {
  local client_uuid=$1
  local scope_id=$2
  local scope_name=$3
  local default_scopes
  default_scopes=$(kcadm get "clients/$client_uuid/default-client-scopes" \
    -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes)
  if ! grep -Eq "^$scope_id," <<<"$default_scopes"; then
    kcadm update "clients/$client_uuid/default-client-scopes/$scope_id" \
      -r "$TARGET_REALM" \
      -n \
      -b '{}' >/dev/null
    log "default client scope $scope_name attached to client $client_uuid"
  fi
}

ensure_account_center_client() {
  ACCOUNT_CENTER_UUID=$(optional_lookup client_id_by_client_id "$CLIENT_ID")
  if [[ -z $ACCOUNT_CENTER_UUID ]]; then
    ACCOUNT_CENTER_UUID=$(kcadm create clients -r "$TARGET_REALM" -i \
      -s "clientId=$CLIENT_ID" \
      -s name='SKY LAB Account Center' \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s bearerOnly=false)
    log "client $CLIENT_ID: created"
  fi
}

# fullScopeAllowed stays false: Keycloak Admin REST authorizes a bearer token through
# AdminAuth.hasAppRole = user.hasRole(role) && client.hasScope(role), and client.hasScope is
# true for every role once full scope is on, so a my. token of a person holding
# realm-management roles would be a valid Admin REST credential. The sky_authorization
# permissions view is therefore produced by the sky-authorization-mapper of the SPI, which
# reads the person's effective client roles itself instead of going through the client scope.
# The integration harness proves that a token of a view-users holder gets 403 from Admin REST.
reconcile_account_center_client() {
  local desired_file="$WORK_DIR/client-$CLIENT_ID.json"
  local callback_uri="$BASE_URL/api/auth/callback"
  local logout_uri="$BASE_URL/api/auth/logout/callback"
  local backchannel_logout_uri="$BASE_URL/api/auth/backchannel-logout"
  cat >"$desired_file" <<EOF
{
  "clientId": "$CLIENT_ID",
  "name": "SKY LAB Account Center",
  "enabled": true,
  "protocol": "openid-connect",
  "clientAuthenticatorType": "client-secret",
  "publicClient": false,
  "bearerOnly": false,
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "authorizationServicesEnabled": false,
  "consentRequired": false,
  "frontchannelLogout": false,
  "fullScopeAllowed": false,
  "rootUrl": "$BASE_URL",
  "baseUrl": "$BASE_URL/",
  "adminUrl": "$BASE_URL",
  "redirectUris": ["$callback_uri"],
  "webOrigins": [],
  "attributes": {
    "pkce.code.challenge.method": "S256",
    "require.pushed.authorization.requests": "true",
    "backchannel.logout.url": "$backchannel_logout_uri",
    "backchannel.logout.session.required": "true",
    "backchannel.logout.revoke.offline.tokens": "true",
    "post.logout.redirect.uris": "$logout_uri"
  }
}
EOF
  apply_fields_if_changed "client $CLIENT_ID" "$desired_file" \
    "clients/$ACCOUNT_CENTER_UUID" -r "$TARGET_REALM"
}

reconcile_account_center_client_scopes() {
  local scope_uuid=$1
  local core_scope_uuid=$2
  local default_scopes optional_scopes default_scope_id default_scope_name
  local optional_scope_id optional_scope_name required_default_scope_id
  default_scopes=$(kcadm get "clients/$ACCOUNT_CENTER_UUID/default-client-scopes" \
    -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes)
  while IFS=, read -r default_scope_id default_scope_name; do
    [[ -n $default_scope_id ]] || continue
    if [[ $default_scope_id != "$scope_uuid" && $default_scope_id != "$core_scope_uuid" ]]; then
      kcadm delete "clients/$ACCOUNT_CENTER_UUID/default-client-scopes/$default_scope_id" \
        -r "$TARGET_REALM" >/dev/null
      log "client $CLIENT_ID: detached default scope $default_scope_name"
    fi
  done <<<"$default_scopes"
  for required_default_scope_id in "$scope_uuid" "$core_scope_uuid"; do
    if ! grep -Eq "^$required_default_scope_id," <<<"$default_scopes"; then
      kcadm update "clients/$ACCOUNT_CENTER_UUID/default-client-scopes/$required_default_scope_id" \
        -r "$TARGET_REALM" \
        -n \
        -b '{}' >/dev/null
      log "client $CLIENT_ID: attached default scope $required_default_scope_id"
    fi
  done

  optional_scopes=$(kcadm get "clients/$ACCOUNT_CENTER_UUID/optional-client-scopes" \
    -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes)
  while IFS=, read -r optional_scope_id optional_scope_name; do
    [[ -n $optional_scope_id ]] || continue
    kcadm delete "clients/$ACCOUNT_CENTER_UUID/optional-client-scopes/$optional_scope_id" \
      -r "$TARGET_REALM" >/dev/null
    log "client $CLIENT_ID: detached optional scope $optional_scope_name"
  done <<<"$optional_scopes"
}

# Client scope mappings for the built-in account client. manage-account-links is required
# because the idp_link application-initiated action checks client.hasScope() in addition to
# the token roles; the hardcoded role mapper alone does not satisfy that check.
reconcile_account_scope_mappings() {
  local account_client_uuid assigned_account_roles assigned_role_id assigned_role_name
  local role_name role_uuid keep allowed changed=''
  account_client_uuid=$(optional_lookup client_id_by_client_id account)
  if [[ -z $account_client_uuid ]]; then
    printf 'Built-in account client was not found\n' >&2
    exit 1
  fi
  assigned_account_roles=$(kcadm get \
    "clients/$ACCOUNT_CENTER_UUID/scope-mappings/clients/$account_client_uuid" \
    -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes)
  while IFS=, read -r assigned_role_id assigned_role_name; do
    [[ -n $assigned_role_id ]] || continue
    keep=false
    for allowed in "${ACCOUNT_ROLE_ALLOWLIST[@]}"; do
      [[ $assigned_role_name == "$allowed" ]] && keep=true
    done
    if [[ $keep == false ]]; then
      kcadm delete "clients/$ACCOUNT_CENTER_UUID/scope-mappings/clients/$account_client_uuid" \
        -r "$TARGET_REALM" \
        -b "[{\"id\":\"$assigned_role_id\",\"name\":\"$assigned_role_name\"}]" >/dev/null
      changed="$changed -$assigned_role_name"
    fi
  done <<<"$assigned_account_roles"
  for role_name in "${ACCOUNT_ROLE_ALLOWLIST[@]}"; do
    role_uuid=$(optional_lookup client_role_id_by_name "$account_client_uuid" "$role_name")
    if [[ -z $role_uuid ]]; then
      printf 'Built-in account role was not found: %s\n' "$role_name" >&2
      exit 1
    fi
    if ! grep -Eq "^[^,]+,$role_name$" <<<"$assigned_account_roles"; then
      kcadm create "clients/$ACCOUNT_CENTER_UUID/scope-mappings/clients/$account_client_uuid" \
        -r "$TARGET_REALM" \
        -b "[{\"id\":\"$role_uuid\",\"name\":\"$role_name\"}]" >/dev/null
      changed="$changed +$role_name"
    fi
  done
  if [[ -z $changed ]]; then
    log "account role scope mappings of $CLIENT_ID: unchanged (${ACCOUNT_ROLE_ALLOWLIST[*]})"
  else
    log "account role scope mappings of $CLIENT_ID: updated (${changed# })"
  fi
}

reconcile_skyapp_audience() {
  local skyapp_client_uuid skyapp_scope_uuid
  skyapp_client_uuid=$(optional_lookup client_id_by_client_id "$SKYAPP_CLIENT_ID")
  if [[ -z $skyapp_client_uuid ]]; then
    printf 'Required client was not found: %s\n' "$SKYAPP_CLIENT_ID" >&2
    exit 1
  fi
  ensure_client_scope "$SKYAPP_SCOPE_NAME" \
    "$CONFIG_DIR/skyapp-account-center-audience-mappers.json"
  skyapp_scope_uuid=$ENSURED_SCOPE_ID
  ensure_default_client_scope "$skyapp_client_uuid" "$skyapp_scope_uuid" "$SKYAPP_SCOPE_NAME"
}

# A login client whose access token must carry the audience of the API it calls, for every
# person: Keycloak's audience-resolve adds an API only when the token carries that API's roles,
# and most people hold none. frontend-main (the site) needs core (core requires it on every
# Bearer, ADR 0019: the site's upload bridge forwards the editor's token to core /v1/media, and
# without it every CMS image upload is 401); frontend-arge (arge) needs core for the same reason
# once its CMS uploads go through core with the move to inscribed (ADR-0056); skyforms needs forms
# (forms-backend requires it: without it members get 401). The scopes were made by hand in
# production with these exact names, so they are adopted by name (never recreated), repaired when
# they drift and kept among the client's default scopes. A realm without the client skips the item
# with a warning. Today it runs for skyforms; frontend-main and frontend-arge get their core scope in
# reconcile_login_clients together with the rest of their narrowed token.
reconcile_login_client_audience() {
  local client_id=$1 scope_name=$2 mappers_file=$3
  local client_uuid
  if ! client_uuid=$(optional_lookup client_id_by_client_id "$client_id"); then
    return 2
  fi
  if [[ -z $client_uuid ]]; then
    warn "client $client_id does not exist in realm $TARGET_REALM; skipped client scope $scope_name"
    return 0
  fi
  ensure_default_audience_scope "$client_id" "$client_uuid" "$scope_name" "$mappers_file"
}

# The source-controlled audience scope of a login client, kept among its default scopes only.
ensure_default_audience_scope() {
  local client_id=$1 client_uuid=$2 scope_name=$3 mappers_file=$4
  local scope_uuid optional_scopes
  ensure_client_scope "$scope_name" "$mappers_file"
  scope_uuid=$ENSURED_SCOPE_ID
  # Keycloak keeps one link per client and scope, so an optional link would block the default one.
  optional_scopes=$(kcadm get "clients/$client_uuid/optional-client-scopes" \
    -r "$TARGET_REALM" \
    --fields id,name \
    --format csv \
    --noquotes)
  if grep -Eq "^$scope_uuid," <<<"$optional_scopes"; then
    kcadm delete "clients/$client_uuid/optional-client-scopes/$scope_uuid" \
      -r "$TARGET_REALM" >/dev/null
    log "client $client_id: detached optional scope $scope_name (it must be a default scope)"
  fi
  ensure_default_client_scope "$client_uuid" "$scope_uuid" "$scope_name"
}

# Login clients narrowed to the APIs their app calls (ADR-0058, ADR-0059; admin-token-authz tickets
# 16, 17 and 18). They were made by hand in production with "Full scope allowed" on, so their
# tokens carried every audience, realm role and client role of the person, most of it read by no
# service. What each app sends its token to and what that API reads was measured on the apps'
# origin/main (2026-10-05; sky_lab_genel .scratch/admin-token-authz/issues/16-18):
#   frontend-main (the main site and its CMS editor) and frontend-arge (arge) call inscribed (aud
#     skycms, tenant azp, the flat roles claim of the client's own roles, collection rules on
#     full-path groups, the teams collection among them) and core POST /v1/media for images (aud
#     core, no core role); the sites' editor gate looks for cms:access in any client of
#     resource_access, so with full scope another site's cms:access opened this site's editor;
#   skymail (the SkyMail UI) calls SkyMail only, which reads the client's own roles
#     (resource_access.skymail) and sub, name and e-mail from Keycloak's userinfo, and no groups
#     (mailing lists read groups with SkyMail's own service account).
# The contract per client: the API audiences come from hardcoded Audience mappers in default scopes
# (a person without a role of the API keeps them; audience-resolve adds nothing once the full scope
# is off, and production's skycms reached the sites' tokens only through it), no realm role and no
# other client's role in the role scope (the client's own roles always pass Keycloak's filter, so
# cms:access, content:* and the skymail:* roles stay), "Full scope allowed" off. The sites keep
# their full-path groups (inscribed reads them); SkyMail's token carries none: every default or
# optional scope writing the claim groups is detached from skymail only (the realm scope and every
# other client keep it) and a mapper of skymail itself writing it is deleted. The order keeps the
# apps working during the run: audiences first, full scope off last. The client's secret, URIs,
# flags and other mappers are not touched. A missing client is skipped with a warning (the sandbox
# realm may lack one); the operator runs this step alone there (KEYCLOAK_RECONCILE_ONLY=login-clients).
reconcile_login_clients() {
  reconcile_narrowed_login_client "$FRONTEND_MAIN_CLIENT_ID" keep-groups \
    "$FRONTEND_MAIN_SCOPE_NAME=$CONFIG_DIR/frontend-main-core-audience-mappers.json" \
    "$SKYCMS_SCOPE_NAME=$CONFIG_DIR/skycms-audience-mappers.json"
  reconcile_narrowed_login_client "$FRONTEND_ARGE_CLIENT_ID" keep-groups \
    "$FRONTEND_ARGE_SCOPE_NAME=$CONFIG_DIR/frontend-arge-core-audience-mappers.json" \
    "$SKYCMS_SCOPE_NAME=$CONFIG_DIR/skycms-audience-mappers.json"
  reconcile_narrowed_login_client "$SKYMAIL_CLIENT_ID" drop-groups \
    "$SKYMAIL_SCOPE_NAME=$CONFIG_DIR/skymail-api-audience-mappers.json"
}

# reconcile_narrowed_login_client CLIENT keep-groups|drop-groups SCOPE=MAPPERS_FILE...
reconcile_narrowed_login_client() {
  local client_id=$1 groups=$2
  shift 2
  local client_uuid spec scopes='' desired_file="$WORK_DIR/narrowed-$client_id.json"
  for spec in "$@"; do
    scopes="$scopes${scopes:+, }${spec%%=*}"
  done
  if ! client_uuid=$(optional_lookup client_id_by_client_id "$client_id"); then
    return 2
  fi
  if [[ -z $client_uuid ]]; then
    warn "client $client_id does not exist in realm $TARGET_REALM; skipped client scope $scopes and its token narrowing"
    return 0
  fi
  for spec in "$@"; do
    ensure_default_audience_scope "$client_id" "$client_uuid" "${spec%%=*}" "${spec#*=}"
  done
  reconcile_role_scope "$client_id" "$client_uuid"
  if [[ $groups == drop-groups ]]; then
    remove_groups_claim "$client_id" "$client_uuid"
  fi
  printf '{"fullScopeAllowed":false}\n' >"$desired_file"
  apply_fields_if_changed "client $client_id (no full scope)" "$desired_file" \
    "clients/$client_uuid" -r "$TARGET_REALM"
}

# writes_groups TYPE CLAIM: a mapper of TYPE writing CLAIM puts group data into a token: Keycloak's
# Group Membership mapper, SKY LAB's group overage mapper, or any mapper whose claim is groups
# (microprofile-jwt's "groups" writes the realm roles there).
writes_groups() {
  [[ $1 == oidc-group-membership-mapper || $1 == sky-group-overage-mapper || $2 == groups || $2 == groups.* ]]
}

# mappers_write_groups ENDPOINT: one of the protocol mappers at ENDPOINT writes group data.
mappers_write_groups() {
  local mappers_csv id type claim name
  mappers_csv=$(kcadm get "$1" -r "$TARGET_REALM" \
    --fields 'id,protocolMapper,config(claim.name),name' \
    --format csv \
    --noquotes)
  while IFS=, read -r id type claim name; do
    [[ -n $id ]] || continue
    if writes_groups "$type" "$claim"; then
      return 0
    fi
  done <<<"$mappers_csv"
  return 1
}

# The claim groups out of one client's tokens (ADR-0059: an app whose APIs read no groups gets none,
# Entra's "groups assigned to the application"): every default or optional scope with a mapper that
# writes group data is detached from this client only, and such a mapper of the client is deleted.
remove_groups_claim() {
  local client_id=$1 client_uuid=$2
  local kind scopes_csv scope_id scope_name mappers_csv id type claim name changed=''
  for kind in default optional; do
    scopes_csv=$(kcadm get "clients/$client_uuid/$kind-client-scopes" -r "$TARGET_REALM" \
      --fields id,name \
      --format csv \
      --noquotes)
    while IFS=, read -r scope_id scope_name; do
      [[ -n $scope_id ]] || continue
      if mappers_write_groups "client-scopes/$scope_id/protocol-mappers/models"; then
        kcadm delete "clients/$client_uuid/$kind-client-scopes/$scope_id" -r "$TARGET_REALM" >/dev/null
        changed="$changed -$kind scope $scope_name"
      fi
    done <<<"$scopes_csv"
  done
  mappers_csv=$(kcadm get "clients/$client_uuid/protocol-mappers/models" -r "$TARGET_REALM" \
    --fields 'id,protocolMapper,config(claim.name),name' \
    --format csv \
    --noquotes)
  while IFS=, read -r id type claim name; do
    [[ -n $id ]] || continue
    if writes_groups "$type" "$claim"; then
      kcadm delete "clients/$client_uuid/protocol-mappers/models/$id" -r "$TARGET_REALM" >/dev/null
      changed="$changed -mapper $name"
    fi
  done <<<"$mappers_csv"
  if [[ -z $changed ]]; then
    log "groups claim of $client_id (none): unchanged"
  else
    log "groups claim of $client_id (none): updated (${changed# })"
  fi
}

# The admin panel's login client (ADR-0058, admin-token-authz ticket 02), made by hand and
# confidential in both realms. With full scope its token carried every audience and role of the
# person (11 audiences, 12 realm roles, 3.3 KB in production). Here the token is narrowed to the APIs
# the panel calls: every role of core and forms is in the client's role scope and nothing else,
# "Full scope allowed" is off (the panel's own roles, content:* for inscribed, always pass), and
# core, forms and skycms come from hardcoded audience mappers so a person without a role of that API
# is not refused (the reason of reconcile_login_client_audience). realm_access disappears; groups and
# the client's own mappers stay. Standard Token Exchange is on, so the panel's server can trade its
# token for a token of one of the three APIs (Keycloak lets a confidential client exchange a token
# issued to itself). The order keeps the live panel working during the run: audiences and API roles
# first, full scope off last. A role made on core or forms outside the reconciler reaches the panel's
# token with the next run.
#
# The client session of the panel lasts at most 8 hours (client.session.max.lifespan, the realm's
# SSO max): Keycloak takes the client's own value before the realm's and before remember-me
# (SessionExpirationUtils), so a panel refresh token dies 8 hours after the panel's client session
# began, even in a 30-day remember-me session, whatever the panel's code checks. It asks for no
# credential: while the SSO session lives, a silent panel login starts a new client session (another
# 8 hours); re-authentication is the panel's max_age. 28800 is the realm's ssoSessionMaxLifespan in
# config/account-center-realm.json: Keycloak refuses a client max above the realm's SSO max (the
# remember-me max when remember-me is on), so lowering that one means lowering this one. A PUT that
# carries "attributes" writes only the attributes it names; the client's other attributes stay.
#
# A missing client is skipped with a warning. A public one fails the run before anything is written
# to it: token exchange needs a confidential client, and making it confidential changes how the panel
# signs in (it must then send the client secret), which is the panel's change (admin-token-authz
# ticket 07). The step runs last, so every other step is done by then.
reconcile_admin_panel_client() {
  local client_uuid live_file public_client desired_file="$WORK_DIR/client-$ADMIN_PANEL_CLIENT_ID.json"
  if ! client_uuid=$(optional_lookup client_id_by_client_id "$ADMIN_PANEL_CLIENT_ID"); then
    return 2
  fi
  if [[ -z $client_uuid ]]; then
    warn "client $ADMIN_PANEL_CLIENT_ID does not exist in realm $TARGET_REALM; skipped the admin panel token contract"
    return 0
  fi
  live_file=$(mktemp "$WORK_DIR/admin-panel.XXXXXX")
  kcadm_json "clients/$client_uuid" -r "$TARGET_REALM" >"$live_file"
  public_client=$(json_tool field publicClient <"$live_file")
  if [[ $public_client != true && $public_client != false ]]; then
    printf 'Client %s has no readable publicClient flag (%s); nothing was changed on it\n' \
      "$ADMIN_PANEL_CLIENT_ID" "${public_client:-empty}" >&2
    return 1
  fi
  if [[ $public_client == true ]]; then
    printf 'Client %s is public: Standard Token Exchange needs a confidential client, and making it confidential changes how the admin panel signs in (it must send the client secret; admin-token-authz ticket 07). Nothing was changed on %s; make it confidential together with the panel, then run again\n' \
      "$ADMIN_PANEL_CLIENT_ID" "$ADMIN_PANEL_CLIENT_ID" >&2
    return 1
  fi
  ensure_default_audience_scope "$ADMIN_PANEL_CLIENT_ID" "$client_uuid" "$ADMIN_PANEL_SCOPE_NAME" \
    "$CONFIG_DIR/admin-panel-api-audience-mappers.json"
  reconcile_role_scope "$ADMIN_PANEL_CLIENT_ID" "$client_uuid" "${ADMIN_PANEL_API_CLIENTS[@]}"
  printf '{"fullScopeAllowed":false,"attributes":{"standard.token.exchange.enabled":"true","client.session.max.lifespan":"%s"}}\n' \
    "$ADMIN_PANEL_CLIENT_SESSION_MAX_LIFESPAN" >"$desired_file"
  apply_fields_if_changed "client $ADMIN_PANEL_CLIENT_ID (no full scope, standard token exchange)" \
    "$desired_file" "clients/$client_uuid" -r "$TARGET_REALM"
}

# {"id":…,"name":…} of one role; role names are free text (a quote or backslash stays JSON).
role_reference() {
  local name=${2//\\/\\\\}
  name=${name//\"/\\\"}
  printf '{"id":"%s","name":"%s"}' "$1" "$name"
}

# The role scope of a login client whose full scope is turned off: every role of the API clients
# given after its id and uuid (the admin panel: core, forms; the sites and SkyMail: none), no other
# client role and no realm role. The client's own roles always pass Keycloak's filter and need no
# mapping. A missing API client is reported; its roles are added once it exists.
reconcile_role_scope() {
  local client_id=$1 client_uuid=$2
  shift 2
  local apis=("$@")
  local live_file mapped api api_uuid roles_csv role_id role_name body owner owner_uuid is_api
  local changed='' label
  if [[ ${#apis[@]} -gt 0 ]]; then
    label="role scope mappings of $client_id (every role of $(printf '%s, ' "${apis[@]}" | sed 's/, $//'))"
  else
    label="role scope mappings of $client_id (none: only its own roles)"
  fi
  live_file=$(mktemp "$WORK_DIR/role-scope.XXXXXX")
  kcadm_json "clients/$client_uuid/scope-mappings" -r "$TARGET_REALM" >"$live_file"
  mapped=$(json_tool scope-mappings <"$live_file")
  for api in ${apis[@]+"${apis[@]}"}; do
    if ! api_uuid=$(optional_lookup client_id_by_client_id "$api"); then
      return 2
    fi
    if [[ -z $api_uuid ]]; then
      warn "client $api does not exist in realm $TARGET_REALM; no $api role is in the scope of $client_id"
      continue
    fi
    roles_csv=$(kcadm get "clients/$api_uuid/roles" -r "$TARGET_REALM" \
      --fields id,name \
      --format csv \
      --noquotes)
    body=''
    while IFS=, read -r role_id role_name; do
      [[ -n $role_id ]] || continue
      if ! grep -Fq "$api"$'\t'"$api_uuid"$'\t'"$role_id"$'\t' <<<"$mapped"; then
        body="$body,$(role_reference "$role_id" "$role_name")"
        changed="$changed +$api/$role_name"
      fi
    done <<<"$roles_csv"
    if [[ -n $body ]]; then
      kcadm create "clients/$client_uuid/scope-mappings/clients/$api_uuid" \
        -r "$TARGET_REALM" \
        -b "[${body#,}]" >/dev/null
    fi
  done
  while IFS=$'\t' read -r owner owner_uuid role_id role_name; do
    [[ -n $owner ]] || continue
    is_api=false
    for api in ${apis[@]+"${apis[@]}"}; do
      [[ $owner == "$api" ]] && is_api=true
    done
    [[ $is_api == false ]] || continue
    body="[$(role_reference "$role_id" "$role_name")]"
    if [[ $owner == - ]]; then
      kcadm delete "clients/$client_uuid/scope-mappings/realm" -r "$TARGET_REALM" -b "$body" >/dev/null
      changed="$changed -realm/$role_name"
    else
      kcadm delete "clients/$client_uuid/scope-mappings/clients/$owner_uuid" -r "$TARGET_REALM" -b "$body" >/dev/null
      changed="$changed -$owner/$role_name"
    fi
  done <<<"$mapped"
  if [[ -z $changed ]]; then
    log "$label: unchanged"
  else
    log "$label: updated (${changed# })"
  fi
}

# core's per-resource client roles (ADR-0059, admin-token-authz ticket 03): what the Privileged
# group check of core gave, one role per resource, so that it can be granted per resource from the
# SKY LAB admin panel. The list is the contract table in sky_lab_genel
# .scratch/admin-token-authz/spec.md ("Sözleşme: core'un kaynak rolleri"); core (tickets 04/05)
# checks exactly these names. Every run creates a missing role (manage-clients). Each role is
# granted to the Privileged groups of its set (CORE_PRIVILEGED_NAMES, or its line in
# CORE_ROLE_SEED_GROUPS; each name at /<NAME> and /UYELER/<NAME>, whichever exist)
# ONCE: the role attribute CORE_ROLE_SEED_ATTRIBUTE records when and to which groups, and a role
# that carries it is never granted again, so a mapping changed or removed in the admin panel stays
# that way. Nothing here ever removes a mapping or a role. A role added to the list later is seeded
# on its own first run. Granting a client role to a group needs user permissions, which the
# reconciler identity deliberately lacks (ADR-0048's reason for manage-clients): its runs create
# the roles and warn about unseeded ones; an operator seeds them by running this step alone with
# their own kcadm session (KEYCLOAK_RECONCILE_ONLY=core-roles, runbook §19).
# DK reads and does not write (grup-yonetimi GY1, ticket 08; core-backend #244): the write roles go
# to ADMIN and YK only, DK gets global:read (Entra's Global Reader), audit:read (Reports Reader, with
# ADMIN and YK) and keeps url:access (its own short links, with ADMIN and YK). The write roles DK got before this change are marked as seeded, so no run takes
# them away: config/dk-read-only.sh does that once (runbook §28).
CORE_CLIENT_ID=${KEYCLOAK_CORE_CLIENT_ID:-core}
CORE_ROLE_SEED_ATTRIBUTE=skylab.seeded-group-mappings
# The Privileged groups the write roles (every role of CORE_ROLE_DEFINITIONS without a line in
# CORE_ROLE_SEED_GROUPS) are seeded to.
CORE_PRIVILEGED_NAMES=(ADMIN YK)
# name|description (the description is written only when the role is created)
CORE_ROLE_DEFINITIONS=(
  'event:manage|Her takımın etkinliklerini, etkinlik günlerini ve oturumlarını yönetir; kapı görevlisi atar (ADR-0059)'
  'season:manage|Sezonları oluşturur, değiştirir, siler (ADR-0059)'
  'ticket:manage|Her etkinliğin biletlerini görür ve atar (ADR-0059)'
  'ticket:validate|Her etkinlikte kapı girişi yapar (bilet doğrulama; ADR-0059)'
  'competitor:manage|Her yarışmacıyı görür ve yönetir (ADR-0059)'
  'competition:manage|Her ekibin yarışmalarını ve yarışmacılarını yönetir; competitor:manage rolünün yeni adı, geçişte core ikisini eşdeğer okur (ADR-0068)'
  'media:manage|Medyayı listeler ve siler (ADR-0059)'
  'media:private:read|core uygulamasının özel medyasını açar (sertifika varlıkları; ADR-0059)'
  'certificate:manage|Her takımın sertifikalarını ve sertifika şablonlarını yönetir (ADR-0059)'
  'users:manage|Kullanıcıları görür ve yönetir (ADR-0059)'
  'groups:manage|Grupları görür ve yönetir (ADR-0059)'
  'github:activity:read|Kulübün GitHub etkinliğini (özel depolar dahil) görür (ADR-0059)'
  'url:moderator|Her kısa linki ve form bağlantısını görür ve yönetir'
  'url:access|Kısa link oluşturur, kendi linklerini görür ve yönetir'
  'global:read|Privileged okumaların hepsini yapar, hiçbir şeyi değiştirmez (DK; Entra Global Reader, grup-yonetimi 08)'
  'audit:read|Ekip denetim kaydını okur (ADMIN, YK ve DK; Entra Reports Reader, ekip-yetki-devri 09)'
)
# name|Privileged groups (space separated names): a role seeded to other groups than
# CORE_PRIVILEGED_NAMES. global:read is DK's alone (core takes it for a reader only); audit:read is
# read by ADMIN, YK and DK (grup-yonetimi GY1 replaced S11's "not DK"); url:access is the holder's own
# short links, an app role DK keeps (Yusuf, 2026-10-14, Y1).
CORE_ROLE_SEED_GROUPS=(
  'global:read|DK'
  'audit:read|ADMIN YK DK'
  'url:access|ADMIN YK DK'
)
# new|old: a role that renames another one is seeded once where the old one is held, not to the
# Privileged groups, so that the rename moves nobody's rights (core reads both names as one while
# both exist; core-backend docs/authz-roles.md, ADR-0068). Where = every holder the old role has
# at seeding time: groups and users (service accounts too) it is mapped to directly, composite
# roles (realm and client) that contain it, the role scope of clients and client scopes that map
# it. The old role stays; it is dropped in a later change, once core no longer reads it.
CORE_ROLE_RENAMES=(
  'competition:manage|competitor:manage'
)

# The Privileged groups that exist, one "path<TAB>id" per line: of the names given (ADMIN, YK, DK or
# fewer), CORE_PRIVILEGED_NAMES when none is given. Only Keycloak's answer that the path does not exist counts as a
# missing group; any other failed lookup (network, permission,
# server error) fails the function, so the caller never seeds and marks a role without a group
# that is in fact there.
core_privileged_groups() {
  local name path line id stderr_file
  local wanted=("$@")
  [[ ${#wanted[@]} -gt 0 ]] || wanted=("${CORE_PRIVILEGED_NAMES[@]}")
  stderr_file=$(mktemp "$WORK_DIR/stderr.XXXXXX")
  for name in "${wanted[@]}"; do
    for path in "/$name" "/UYELER/$name"; do
      if line=$(kcadm get "group-by-path$path" -r "$TARGET_REALM" --fields id,path --format csv --noquotes \
        2>"$stderr_file"); then
        line=$(tr -d '\r' <<<"$line" | sed '/^$/d')
      elif grep -Eqi 'not found|does not exist' "$stderr_file"; then
        continue
      else
        cat "$stderr_file" >&2
        printf 'The Privileged group %s could not be looked up in realm %s; nothing was granted\n' \
          "$path" "$TARGET_REALM" >&2
        return 1
      fi
      id=${line%%,*}
      [[ -n $line && ${line#*,} == "$path" && -n $id ]] || continue
      printf '%s\t%s\n' "$path" "$id"
    done
  done
}

reconcile_core_roles() {
  local core_uuid roles_csv definition name description created='' roles_file seeds
  local unseeded=() role_name role_seed_value seed
  if ! core_uuid=$(optional_lookup client_id_by_client_id "$CORE_CLIENT_ID"); then
    return 2
  fi
  if [[ -z $core_uuid ]]; then
    warn "client $CORE_CLIENT_ID does not exist in realm $TARGET_REALM; skipped core's resource roles"
    return 0
  fi
  roles_csv=$(kcadm get "clients/$core_uuid/roles" -r "$TARGET_REALM" --fields name --format csv --noquotes \
    | tr -d '\r')
  for definition in "${CORE_ROLE_DEFINITIONS[@]}"; do
    name=${definition%%|*}
    description=${definition#*|}
    if ! grep -Fxq -- "$name" <<<"$roles_csv"; then
      kcadm_quiet create "clients/$core_uuid/roles" -r "$TARGET_REALM" \
        -s "name=$name" -s "description=$description"
      created="$created, $name"
    fi
  done
  if [[ -z $created ]]; then
    log "client roles of $CORE_CLIENT_ID (${#CORE_ROLE_DEFINITIONS[@]} resource roles): unchanged"
  else
    log "client roles of $CORE_CLIENT_ID (${#CORE_ROLE_DEFINITIONS[@]} resource roles): created (${created#, })"
  fi

  roles_file=$(mktemp "$WORK_DIR/core-roles.XXXXXX")
  kcadm_json "clients/$core_uuid/roles" -r "$TARGET_REALM" -q briefRepresentation=false >"$roles_file"
  seeds=$(json_tool role-attribute "$CORE_ROLE_SEED_ATTRIBUTE" <"$roles_file")
  for definition in "${CORE_ROLE_DEFINITIONS[@]}"; do
    name=${definition%%|*}
    seed=''
    while IFS=$'\t' read -r role_name role_seed_value; do
      [[ $role_name == "$name" ]] && seed=$role_seed_value
    done <<<"$seeds"
    [[ -n $seed ]] || unseeded+=("$name")
  done
  if [[ ${#unseeded[@]} == 0 ]]; then
    log "group mappings of the $CORE_CLIENT_ID resource roles: unchanged (each seeded once; the SKY LAB admin panel owns them)"
    return 0
  fi
  if [[ -z $OPERATOR_KCADM_CONFIG ]]; then
    local waiting=() carried=()
    for name in "${unseeded[@]}"; do
      if [[ -n $(core_role_rename_source "$name") ]]; then
        carried+=("$name (from $(core_role_rename_source "$name"))")
      else
        waiting+=("$name")
      fi
    done
    [[ ${#carried[@]} == 0 ]] \
      || warn "core roles not yet carried over from their old names: ${carried[*]} (they go wherever the old role is held; granting needs user permissions the reconciler identity does not have); run this step alone with an operator session: KEYCLOAK_RECONCILE_ONLY=core-roles (runbook §19.1)"
    [[ ${#waiting[@]} == 0 ]] && return 0
    warn "core roles not yet granted to the Privileged groups: ${waiting[*]} (granting a role to a group needs user permissions the reconciler identity does not have); run this step alone with an operator session: KEYCLOAK_RECONCILE_ONLY=core-roles (runbook §19)"
    return 0
  fi

  # Operator session: seed. The Privileged roles first, so that a rename whose old role is seeded in
  # the same run (a new realm) finds the old role's group mappings.
  local privileged=() renamed=()
  for name in "${unseeded[@]}"; do
    if [[ -n $(core_role_rename_source "$name") ]]; then
      renamed+=("$name")
    else
      privileged+=("$name")
    fi
  done
  # One call per set of Privileged groups (as SkyMail's roles), the write roles' set
  # (CORE_PRIVILEGED_NAMES) first, then the others in the order of the list.
  local group_names known set_names=() sets=("${CORE_PRIVILEGED_NAMES[*]}")
  for name in ${privileged[@]+"${privileged[@]}"}; do
    group_names=$(core_role_seed_names "$name")
    for known in "${sets[@]}"; do
      [[ $known != "$group_names" ]] || continue 2
    done
    sets+=("$group_names")
  done
  for group_names in "${sets[@]}"; do
    set_names=()
    for name in ${privileged[@]+"${privileged[@]}"}; do
      if [[ $(core_role_seed_names "$name") == "$group_names" ]]; then
        set_names+=("$name")
      fi
    done
    if [[ ${#set_names[@]} -gt 0 ]]; then
      seed_privileged_client_roles core "$core_uuid" "$group_names" "${set_names[@]}"
    fi
  done
  for name in ${renamed[@]+"${renamed[@]}"}; do
    core_role_seed_rename "$core_uuid" "$name" "$(core_role_rename_source "$name")"
  done
}

# The Privileged group names (space separated) a core role is seeded to: its line in
# CORE_ROLE_SEED_GROUPS, else CORE_PRIVILEGED_NAMES.
core_role_seed_names() {
  local line
  for line in "${CORE_ROLE_SEED_GROUPS[@]}"; do
    if [[ ${line%%|*} == "$1" ]]; then
      printf '%s\n' "${line#*|}"
      return 0
    fi
  done
  printf '%s\n' "${CORE_PRIVILEGED_NAMES[*]}"
}

# The old name of a renamed core role (CORE_ROLE_RENAMES), empty for any other role.
core_role_rename_source() {
  local rename
  for rename in "${CORE_ROLE_RENAMES[@]}"; do
    [[ ${rename%%|*} == "$1" ]] && printf '%s\n' "${rename#*|}"
  done
  return 0
}

# seed_privileged_client_roles LABEL CLIENT_UUID GROUP_NAMES NAME...: grants each client role to the
# Privileged groups named in GROUP_NAMES (space separated: ADMIN YK DK or fewer) once and marks it
# (operator session). Nothing is written unless every check passes. LABEL (core, skymail, forms)
# names the roles in the messages ("<LABEL> role <name>: seeded once to ..."). core's resource roles
# (runbook §19), SkyMail's Privileged roles (§25) and Forms' (§28) share it.
seed_privileged_client_roles() {
  local label=$1 client_uuid=$2 group_names=$3
  shift 3
  local names=("$@") kind
  if [[ $label == core ]]; then
    kind='core resource roles'
  else
    kind="$label Privileged roles"
  fi
  local name groups default path gid stamp granted held role_id paths role_ids body defaults
  # shellcheck disable=SC2086  # GROUP_NAMES is a space separated list of plain names
  if ! groups=$(core_privileged_groups $group_names); then
    return 1
  fi
  if [[ -z $groups ]]; then
    warn "no Privileged group ($group_names, at /<NAME> or under /UYELER) exists in realm $TARGET_REALM; nothing was granted, the $kind stay unseeded"
    return 0
  fi
  # Read into a variable first: a failed read inside a process substitution would pass as "no
  # default group" and seed anyway. This check is what keeps every new user from getting the roles.
  if ! defaults=$(kcadm get "realms/$TARGET_REALM/default-groups" --fields path --format csv --noquotes); then
    printf 'The default groups of realm %s could not be read; nothing was granted (a Privileged default group would give every new user the %s)\n' \
      "$TARGET_REALM" "$kind" >&2
    return 1
  fi
  while IFS= read -r default; do
    default=${default%$'\r'}
    [[ -n $default ]] || continue
    while IFS=$'\t' read -r path gid; do
      if [[ $default == "$path" || $default == "$path"/* ]]; then
        printf 'The default group %s is at or under the Privileged group %s: every new user would get the %s. Nothing was granted\n' \
          "$default" "$path" "$kind" >&2
        return 1
      fi
    done <<<"$groups"
  done <<<"$defaults"
  for name in $group_names; do
    grep -Eq "^(/UYELER)?/$name"$'\t' <<<"$groups" \
      || warn "no Privileged group $name (neither /$name nor /UYELER/$name) in realm $TARGET_REALM; it gets none of the $kind"
  done
  paths=$(cut -f1 <<<"$groups" | paste -sd, -)
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  role_ids=$(kcadm get "clients/$client_uuid/roles" -r "$TARGET_REALM" --fields id,name --format csv --noquotes \
    | tr -d '\r')
  declare -A granted_to=()
  # One read and at most one write per group.
  while IFS=$'\t' read -r path gid; do
    held=$(kcadm get "groups/$gid/role-mappings/clients/$client_uuid" -r "$TARGET_REALM" --fields name --format csv \
      --noquotes | tr -d '\r')
    body=''
    for name in "${names[@]}"; do
      grep -Fxq -- "$name" <<<"$held" && continue
      # By exact name: a role name like skyforms:* is no pattern.
      role_id=$(id_from_csv "$name" "$role_ids" || true)
      if [[ -z $role_id && $CHECK_WRITES == true ]]; then
        role_id="${CHECK_ID_PREFIX}role"
      fi
      [[ -n $role_id ]] || { printf '%s role %s could not be read back\n' "$label" "$name" >&2; return 1; }
      body="$body,$(role_reference "$role_id" "$name")"
      granted_to[$name]="${granted_to[$name]:-}, $path"
    done
    if [[ -n $body ]]; then
      kcadm_quiet create "groups/$gid/role-mappings/clients/$client_uuid" -r "$TARGET_REALM" \
        -b "[${body#,}]" || return 1
    fi
  done <<<"$groups"
  # The mark comes last: a run cut before it grants the same (idempotently) next time.
  for name in "${names[@]}"; do
    # By id: a role name like skyforms:* never goes into the admin path.
    role_id=$(id_from_csv "$name" "$role_ids" || true)
    if [[ -z $role_id && $CHECK_WRITES == true ]]; then
      role_id="${CHECK_ID_PREFIX}role"
    fi
    [[ -n $role_id ]] || { printf '%s role %s could not be read back\n' "$label" "$name" >&2; return 1; }
    kcadm_quiet update "roles-by-id/$role_id" -r "$TARGET_REALM" \
      -s "attributes.\"$CORE_ROLE_SEED_ATTRIBUTE\"=[\"$stamp $paths\"]" || return 1
    granted=${granted_to[$name]:-, none (every group already held it)}
    log "$label role $name: seeded once to $paths (granted to: ${granted#, })"
  done
}

# core_rename_read WHAT ARGS...: a kcadm read of the rename seeding as CSV lines; a failure names
# WHAT and stops the step before it writes anything (never taken for "no holder").
core_rename_read() {
  local what=$1 result
  shift
  if ! result=$(kcadm get "$@" -r "$TARGET_REALM" --format csv --noquotes); then
    printf '%s could not be read in realm %s; nothing was granted\n' "$what" "$TARGET_REALM" >&2
    return 1
  fi
  tr -d '\r' <<<"$result" | sed '/^$/d'
}

# The core roles a composite role contains, one name per line ($1: role id).
core_rename_composites() {
  core_rename_read "The composites of role $2" "roles-by-id/$1/composites/clients/$3" --fields name
}

# core_role_seed_rename CORE_UUID NEW OLD: grants NEW once to every holder of OLD that lacks it
# (CORE_ROLE_RENAMES) and marks NEW (operator session). Every holder is read before anything is
# written. A person (a user that is not a client's service account) who holds OLD directly is not
# given NEW: people get roles only through groups (rol-temizligi, no direct roles to people). They
# are counted and warned about, never named.
core_role_seed_rename() {
  local core_uuid=$1 name=$2 old=$3
  local role_ids new_id old_id new_ref old_groups new_groups old_users new_users line id rest
  local composite role_name realm_roles clients client_uuid client_id full_scope client_roles held scopes
  local scope_id scope_name stamp mark kind target label count=0 granted=0 people=0 username sa_client sa_id lookup
  local groups_text composites_text role_scopes_text client_scopes_text roles_file old_seed
  local plan=() group_paths=() composite_labels=() role_scope_labels=() client_scope_labels=()
  role_ids=$(core_rename_read "The roles of client $CORE_CLIENT_ID" "clients/$core_uuid/roles" --fields id,name) || return 1
  new_id=$(sed -n "s/^\([^,]*\),$name\$/\1/p" <<<"$role_ids")
  old_id=$(sed -n "s/^\([^,]*\),$old\$/\1/p" <<<"$role_ids")
  [[ -n $new_id ]] || { printf 'core role %s could not be read back\n' "$name" >&2; return 1; }
  if [[ -z $old_id ]]; then
    warn "core role $old (the old name of $name) does not exist in realm $TARGET_REALM; nothing to carry over, $name stays unseeded"
    return 0
  fi
  # The old role must be seeded first (in this run or before): marking the new one while the old one
  # is still to be granted (a realm without Privileged groups yet) would leave the new one out of the
  # places the old one gets later.
  roles_file=$(mktemp "$WORK_DIR/core-roles.XXXXXX")
  kcadm_json "clients/$core_uuid/roles" -r "$TARGET_REALM" -q briefRepresentation=false >"$roles_file" || {
    printf 'The roles of client %s could not be read in realm %s; nothing was granted\n' "$CORE_CLIENT_ID" "$TARGET_REALM" >&2
    return 1
  }
  old_seed=$(json_tool role-attribute "$CORE_ROLE_SEED_ATTRIBUTE" <"$roles_file" | sed -n "s/^$old"$'\t'"//p") || return 1
  if [[ -z $old_seed ]]; then
    warn "core role $name not carried over: its old name $old is not seeded yet (no Privileged group?); $name stays unseeded until $old is"
    return 0
  fi
  new_ref="[$(role_reference "$new_id" "$name")]"

  # Groups and users the old role is mapped to directly. Of the users only service accounts get the
  # new role; a person holding the old role directly is counted and left alone.
  old_groups=$(core_rename_read "The groups of core role $old" "clients/$core_uuid/roles/$old/groups" \
    -q first=0 -q max=100000 --fields id,path) || return 1
  new_groups=$(core_rename_read "The groups of core role $name" "clients/$core_uuid/roles/$name/groups" \
    -q first=0 -q max=100000 --fields id,path) || return 1
  while IFS=, read -r id rest; do
    [[ -n $id ]] || continue
    group_paths+=("$rest")
    grep -Eq "^$id," <<<"$new_groups" || plan+=("group"$'\t'"$id"$'\t'"$rest")
  done <<<"$old_groups"
  old_users=$(core_rename_read "The users of core role $old" "clients/$core_uuid/roles/$old/users" \
    -q first=0 -q max=100000 --fields id,username) || return 1
  new_users=$(core_rename_read "The users of core role $name" "clients/$core_uuid/roles/$name/users" \
    -q first=0 -q max=100000 --fields id) || return 1
  # A service account is the user named service-account-<clientId> that is that client's own
  # service-account-user; anyone else (the name alone proves nothing) is a person.
  while IFS=, read -r id username; do
    [[ -n $id ]] || continue
    count=$((count + 1))
    sa_id=''
    if [[ $username == service-account-* ]]; then
      # client_id_by_client_id: 0 found, 1 no such client (a person), 2 the clients could not be read.
      lookup=0
      sa_client=$(client_id_by_client_id "${username#service-account-}") || lookup=$?
      if ((lookup == 0)); then
        sa_id=$(core_rename_read "The service account of client ${username#service-account-}" \
          "clients/$sa_client/service-account-user" --fields id) || return 1
      elif ((lookup != 1)); then
        printf 'The clients could not be read in realm %s; nothing was granted\n' "$TARGET_REALM" >&2
        return 1
      fi
    fi
    if [[ $sa_id != "$id" ]]; then
      people=$((people + 1))
      continue
    fi
    grep -Fxq -- "$id" <<<"$new_users" || plan+=("user"$'\t'"$id"$'\t'"user")
  done <<<"$old_users"

  # Composite roles of the realm and of every client that contain the old role.
  realm_roles=$(core_rename_read 'The realm roles' roles -q first=0 -q max=100000 --fields id,name,composite) || return 1
  while IFS=, read -r id rest; do
    composite=${rest##*,}
    role_name=${rest%,*}
    [[ -n $id && $composite == true ]] || continue
    held=$(core_rename_composites "$id" "$role_name" "$core_uuid") || return 1
    grep -Fxq -- "$old" <<<"$held" || continue
    composite_labels+=("$role_name")
    grep -Fxq -- "$name" <<<"$held" || plan+=("composite"$'\t'"$id"$'\t'"$role_name")
  done <<<"$realm_roles"
  clients=$(core_rename_read 'The clients' clients --fields id,clientId,fullScopeAllowed) || return 1
  while IFS=, read -r client_uuid rest; do
    full_scope=${rest##*,}
    client_id=${rest%,*}
    [[ -n $client_uuid ]] || continue
    client_roles=$(core_rename_read "The roles of client $client_id" "clients/$client_uuid/roles" \
      -q first=0 -q max=100000 --fields id,name,composite) || return 1
    while IFS=, read -r id rest; do
      composite=${rest##*,}
      role_name=${rest%,*}
      [[ -n $id && $composite == true && $id != "$new_id" && $id != "$old_id" ]] || continue
      held=$(core_rename_composites "$id" "$client_id/$role_name" "$core_uuid") || return 1
      grep -Fxq -- "$old" <<<"$held" || continue
      composite_labels+=("$client_id/$role_name")
      grep -Fxq -- "$name" <<<"$held" || plan+=("composite"$'\t'"$id"$'\t'"$client_id/$role_name")
    done <<<"$client_roles"
    # A client with full scope gets every role anyway; only a narrowed one maps roles one by one.
    [[ $full_scope == false ]] || continue
    held=$(core_rename_read "The role scope of client $client_id" \
      "clients/$client_uuid/scope-mappings/clients/$core_uuid" --fields name) || return 1
    grep -Fxq -- "$old" <<<"$held" || continue
    role_scope_labels+=("$client_id")
    grep -Fxq -- "$name" <<<"$held" || plan+=("role-scope"$'\t'"$client_uuid"$'\t'"$client_id")
  done <<<"$clients"
  scopes=$(core_rename_read 'The client scopes' client-scopes --fields id,name) || return 1
  while IFS=, read -r scope_id scope_name; do
    [[ -n $scope_id ]] || continue
    held=$(core_rename_read "The role scope of client scope $scope_name" \
      "client-scopes/$scope_id/scope-mappings/clients/$core_uuid" --fields name) || return 1
    grep -Fxq -- "$old" <<<"$held" || continue
    client_scope_labels+=("$scope_name")
    grep -Fxq -- "$name" <<<"$held" || plan+=("client-scope"$'\t'"$scope_id"$'\t'"$scope_name")
  done <<<"$scopes"

  # Every read passed: write.
  for line in ${plan[@]+"${plan[@]}"}; do
    IFS=$'\t' read -r kind target label <<<"$line"
    case $kind in
      group) kcadm_quiet create "groups/$target/role-mappings/clients/$core_uuid" -r "$TARGET_REALM" -b "$new_ref" || return 1 ;;
      user) kcadm_quiet create "users/$target/role-mappings/clients/$core_uuid" -r "$TARGET_REALM" -b "$new_ref" || return 1 ;;
      composite) kcadm_quiet create "roles-by-id/$target/composites" -r "$TARGET_REALM" -b "$new_ref" || return 1 ;;
      role-scope) kcadm_quiet create "clients/$target/scope-mappings/clients/$core_uuid" -r "$TARGET_REALM" -b "$new_ref" || return 1 ;;
      client-scope) kcadm_quiet create "client-scopes/$target/scope-mappings/clients/$core_uuid" -r "$TARGET_REALM" -b "$new_ref" || return 1 ;;
    esac
    granted=$((granted + 1))
  done
  # The mark comes last, as for the Privileged roles. It holds counts only: a role attribute value is
  # at most 255 characters in Keycloak (VARCHAR(255)), and the names of many groups would not fit;
  # the names go to the log. User names stay out of both.
  mark="where $old is held: groups ${#group_paths[@]}; users $count (people $people not granted); composite roles ${#composite_labels[@]}; role scopes ${#role_scope_labels[@]}; client scopes ${#client_scope_labels[@]}"
  groups_text=$(core_rename_list ${group_paths[@]+"${group_paths[@]}"})
  composites_text=$(core_rename_list ${composite_labels[@]+"${composite_labels[@]}"})
  role_scopes_text=$(core_rename_list ${role_scope_labels[@]+"${role_scope_labels[@]}"})
  client_scopes_text=$(core_rename_list ${client_scope_labels[@]+"${client_scope_labels[@]}"})
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  kcadm_quiet update "clients/$core_uuid/roles/$name" -r "$TARGET_REALM" \
    -s "attributes.\"$CORE_ROLE_SEED_ATTRIBUTE\"=[\"$stamp $mark\"]" || return 1
  if ((people > 0)); then
    warn "core role $name not granted to $people people holding $old directly (people get roles only through groups); move them to a /ROLLER or Privileged group that holds $name"
  fi
  log "core role $name: seeded once where $old is held: groups $groups_text; users $count (people $people not granted); composite roles $composites_text; role scopes $role_scopes_text; client scopes $client_scopes_text (granted to $granted of them; the rest already held it)"
}

# Comma separated arguments, or "none".
core_rename_list() {
  if [[ $# == 0 ]]; then
    printf 'none'
  else
    local IFS=,
    printf '%s' "$*"
  fi
}

# core's service roles (runbook §20): the client roles of core that a product's service account
# (client credentials) holds and core reads from resource_access.core.roles; aud must contain core.
#   media:attach        POST/DELETE /v1/media/{id}/attachments and the anonymous form upload rule
#                       (media redesign ticket 03, ADR-0052); core also requires azp and client_id
#                       to be a client of its MEDIA_SERVICE_CLIENTS.
#   ticket:forms        POST /v1/forms/{formId}/responses: forms reports its answers and core writes
#                       the Tickets an accepted answer to an Event's form earns (core's
#                       docs/form-response-tickets.md); core accepts it only from the forms
#                       product's service account.
#   url:forms           form-bound short links, /v1/urls/forms/{formId} and GET /v1/urls/availability.
#   users:read          GET /v1/users/{id}.
#   audience:read       POST /v1/audiences/resolve: who a News send goes to (core #242,
#                       docs/news-audience.md); SkyMail's service account (client skymail-backend,
#                       skymail-backend's KEYCLOAK_SERVICE_CLIENT_ID) only (duyuru-haber ticket 04).
#   communication-preferences:read
#                       POST /internal/v1/communication-preferences/tracking:resolve: whom SkyMail may
#                       track (core #256, docs/communication-preferences.md); SkyMail's service
#                       account (skymail-backend) only, core refuses a person's token whatever it
#                       carries (iletisim-servisi ticket 17).
#   consent:record      POST /v1/consents, /v1/consents/withdrawals and /v1/consents/lookup: a
#                       product records the contact consent (Davet onayı, ADR-0062) a person gave in
#                       it (core docs/contact-consents.md); core also requires azp to be a client of
#                       its CONTACT_CONSENT_SERVICE_CLIENTS (source:client pairs, unset
#                       forms:forms,place:place,guessr:guessr). forms, and place-service: Place's
#                       own service client (PLACE_SERVICE_CLIENT_ID below; its login client place has
#                       no service account, config/create-place-client.sh). Place has no consent box
#                       yet, so core's list stays without place:place-service until it has one (then
#                       place:place-service, not the default place:place). Guessr has no client; it is
#                       added here once it has a service account.
#   consent:audience:read
#                       GET /v1/consents/audience and POST /v1/consents/renewal-requests: who SkyMail
#                       may send an invitation or a promotional mail to (core docs/contact-consents.md,
#                       KVKK s6 tickets 11 and 12); SkyMail's service account (skymail-backend) only.
# core refuses a person's token on both consent routes whatever it carries.
# url:forms and users:read were granted to the forms service account by hand before (forms-url-role
# wizard, Java era); they are codified here with the other two.
# The same step grants SkyMail's client roles to core's own service account (client core), which
# calls SkyMail: SKYMAIL_SERVICE_ROLE_DEFINITIONS below, granted by hand until 2026-10-13.
#
# Every run creates a missing role (manage-clients; the description is written only then) and, for
# a listed client whose fullScopeAllowed is false, maps the role in the client's role scope, or it
# never reaches the token. Granting a role to a service account needs user permissions the
# reconciler identity deliberately lacks (as for core-roles), so an operator runs this step alone
# with their own kcadm session (KEYCLOAK_RECONCILE_ONLY=service-roles; media-attach, its name before
# ticket 03, still works). KEYCLOAK_RECONCILE_CHECK=true makes the operator step a dry run: it reads
# everything, prints "would ..." for each change and writes nothing. The operator step reads
# everything first and writes only when every read succeeded; a failed read is never taken for
# "absent" (one exception: a missing default client scope roles is attached during the reads, by
# the full run too; runbook §20.1). It then grants each role to each listed service account that
# lacks it, records on the role (attribute CORE_SERVICE_ROLE_GRANT_ATTRIBUTE) when and to which
# service accounts, and reports, never removes: another holder (a user, a group or the realm's
# default role) of a role meant for service accounts only, and a core role a listed service account
# holds beyond this list (a NOTE).
# aud core is not added here: Keycloak's audience resolve mapper (default scope roles) puts core in
# aud once resource_access.core is in the token; the step verifies that scope instead of adding a
# second audience mapper.
#
# name|clients (space separated)|holders|description. holders: services (only the listed clients'
# service accounts may hold it; any other holder is reported) or shared (people may hold it too:
# users:read predates the service accounts). Keep the clients of media:attach in step with core's
# MEDIA_SERVICE_CLIENTS (product:client pairs; unset it is forms:forms): a CMS client is added in
# both places together, once its service account exists. ticket:forms and url:forms are forms only.
CORE_SERVICE_ROLE_DEFINITIONS=(
  "media:attach|forms|services|Service attach API (media redesign ticket 03, ADR-0052): a product's service account links Media to its own records. Service accounts only; never a person or a group."
  "ticket:forms|forms|services|Forms reports its answers (POST /v1/forms/{formId}/responses, core docs/form-response-tickets.md); core writes the Tickets an accepted answer to an Event's form earns. Service accounts only; never a person or a group."
  "url:forms|forms|services|Forms service account: form-bound short links (/v1/urls/forms/{formId}) and GET /v1/urls/availability only. Grants nothing on the generic /v1/urls endpoints."
  "users:read|forms|shared|Reads a person's profile (GET /v1/users/{id}); held by the Forms service account."
  "audience:read|skymail-backend|services|SkyMail asks who a News send goes to (POST /v1/audiences/resolve, core docs/news-audience.md). SkyMail's service account only; never a person or a group."
  "communication-preferences:read|skymail-backend|services|SkyMail asks whom it may track (POST /internal/v1/communication-preferences/tracking:resolve, core docs/communication-preferences.md). SkyMail's service account only; never a person or a group."
  "consent:record|forms place-service|services|A product records, withdraws and looks up the contact consents its users gave (POST /v1/consents, /v1/consents/withdrawals, /v1/consents/lookup; core docs/contact-consents.md). Service accounts only; never a person or a group."
  "consent:audience:read|skymail-backend|services|SkyMail reads who consented to invitations and promotional mail (GET /v1/consents/audience, POST /v1/consents/renewal-requests; core docs/contact-consents.md). SkyMail's service account only; never a person or a group."
)
# SkyMail's client roles that core's service account (client core) holds: core sends single mails
# (POST /v1/mail_tasks/single: skymail:access and skymail:mails:send, core internal/mail/mail.go) and
# keeps the event mailing lists (POST/DELETE /v1/mailing_lists... need skymail:lists:write, GET
# skymail:lists:read; core internal/mail/lists.go, SkyMail main.go route table). People hold these
# roles too (shared). The roles are SkyMail's own: a missing one is reported, never created here.
# skymail:mails:write also allows the single send; a core service account that holds it is reported
# in a NOTE and keeps it.
# skymail:tracking:withdraw (iletisim-servisi ticket 17): core withdraws a person's mail tracking
# when they turn it off (PUT /internal/v1/tracking-withdrawals/{sub}, skymail-backend #75, core
# #256). SkyMail checks azp core, aud skymail and this role, not that the token is a service
# account's, so the role is core's service account's only (services): a person, a group, a
# composite role or the default role holding it is reported (review condition B2). It and
# skymail:templates:system are the lines with a description: nothing else makes them, so the step
# creates them like core's roles.
# skymail:templates:system: the Template seed (skymail-frontend seed-templates.yml, client
# skymail-seed) marks a template as a system template or takes the mark away (PUT
# /v1/templates/by-key/{key}, skymail-backend README "Keycloak"). An account.* or keycloak.* system
# template goes past SkyMail's suppression list, so skymail:templates:write no longer changes the
# mark (Yusuf, 2026-10-21): the role is skymail-seed's service account's only (services).
# skymail-seed itself, and its other three skymail roles, are made by sky_lab_genel
# ops/wizards/skymail-seed-github-wizard.sh.
SKYMAIL_SERVICE_ROLE_DEFINITIONS=(
  "skymail:access|core|shared|"
  "skymail:mails:send|core|shared|"
  "skymail:lists:read|core|shared|"
  "skymail:lists:write|core|shared|"
  "skymail:tracking:withdraw|core|services|core withdraws a person's mail tracking (PUT /internal/v1/tracking-withdrawals/{sub}, skymail-backend README). core's service account only; never a person, a group, a composite or the default role."
  "skymail:templates:system|skymail-seed|services|The Template seed marks a template as a system template or takes the mark away (PUT /v1/templates/by-key/{key}, skymail-backend README). skymail-seed's service account only; never a person, a group, a composite or the default role."
)
# realm-management roles of SkyMail's service account (client skymail-backend): SkyMail reads
# people through the Admin REST API: group members and the holders of its approver roles, and the
# one Keycloak account of a single mail's address for tracking (GET /users?email=…&exact=true,
# skymail-backend #85, iletisim-servisi 14/15); that needs view-users (query-users alone does not
# return the users) and view-clients (the client and its roles). Granted by hand in production on
# 2026-09-23 (skymail-frontend-prod-release-wizard.sh checks it); codified here, so the operator
# step only reports them held. Keycloak's own roles, never created here (existing); people and
# groups hold them too (shared). Keycloak refuses to update a realm-management role (403), so the
# grant record is not on the role as for the others but on each listed client
# (REALM_MANAGEMENT_GRANT_ATTRIBUTE = "<timestamp> <role>,<role>"); without it the reconciler
# identity, which cannot read a service account's roles, would warn on every run.
REALM_MANAGEMENT_SERVICE_ROLE_DEFINITIONS=(
  "view-users|skymail-backend|shared|"
  "view-clients|skymail-backend|shared|"
)
CORE_SERVICE_ROLE_GRANT_ATTRIBUTE=skylab.granted-service-accounts
REALM_MANAGEMENT_GRANT_ATTRIBUTE=skylab.granted-realm-management-roles
# Listed clients that must be service account only: no browser login (standard or implicit flow) and
# no password grant (direct access grants). core reads the product from client_id == azp, so a token
# of forms must always be its service account's; Forms signs people in through skyforms. The
# reconciler identity verifies and warns; the operator step sets the flags that are not false
# (KEYCLOAK_RECONCILE_CHECK=true: "would set ..."). No other client is touched.
CORE_SERVICE_ONLY_CLIENTS=(forms place-service)
CORE_SERVICE_ONLY_FLAGS=(standardFlowEnabled implicitFlowEnabled directAccessGrantsEnabled)
CORE_SERVICE_ROLE_OPERATOR_STEP='run this step alone with an operator session: KEYCLOAK_RECONCILE_ONLY=service-roles (runbook §20)'
SERVICE_ROLE_CHANGES=0

# service_role_read WHAT ARGS...: a kcadm read for the service-roles step; a failure names WHAT and
# stops the step before it writes anything.
service_role_read() {
  local what=$1 result
  shift
  if ! result=$(kcadm get "$@" -r "$TARGET_REALM" --format csv --noquotes); then
    printf '%s could not be read in realm %s; nothing was granted\n' "$what" "$TARGET_REALM" >&2
    return 1
  fi
  tr -d '\r' <<<"$result" | sed '/^$/d'
}

# service_role_change TEXT: one change of the step. With KEYCLOAK_RECONCILE_CHECK=true it is logged
# as "would TEXT" and the caller writes nothing (the function then returns 1).
service_role_change() {
  SERVICE_ROLE_CHANGES=$((SERVICE_ROLE_CHANGES + 1))
  if [[ $RECONCILE_CHECK == true ]]; then
    log "would $1"
    return 1
  fi
  return 0
}

# The composite roles of the realm, read once per operator step for both resources: the role id of
# each child -> ",<container>/<name>" of every composite role that holds it directly (container is
# realm or a clientId). The default role default-roles-<realm> is left out: its own check names it.
# A role of the services class must sit in none (review condition B2 of skymail-backend #75): every
# holder of such a composite holds the role. A failed read stops the step before it writes anything.
declare -A SERVICE_ROLE_PARENTS=()
SERVICE_ROLE_PARENTS_READ=false
service_role_composite_parents() {
  local clients roles children line entry container role_id role_name child client_uuid client_id
  local default_role="default-roles-${TARGET_REALM,,}"
  local containers=('realm|roles')
  [[ $SERVICE_ROLE_PARENTS_READ == false ]] || return 0
  clients=$(service_role_read 'The clients' clients --fields id,clientId) || return 1
  while IFS=, read -r client_uuid client_id; do
    [[ -z $client_uuid ]] || containers+=("$client_id|clients/$client_uuid/roles")
  done <<<"$clients"
  for entry in "${containers[@]}"; do
    container=${entry%%|*}
    # id first and composite last, whatever the name holds.
    roles=$(service_role_read "The roles of $container" "${entry#*|}" --fields id,name,composite) || return 1
    while IFS= read -r line; do
      [[ $line == *,true ]] || continue
      role_id=${line%%,*}
      role_name=${line#*,}
      role_name=${role_name%,true}
      [[ $container != realm || $role_name != "$default_role" ]] || continue
      children=$(service_role_read "The composites of $container/$role_name" "roles-by-id/$role_id/composites" --fields id) || return 1
      while IFS= read -r child; do
        [[ -z $child ]] || SERVICE_ROLE_PARENTS[$child]+=",$container/$role_name"
      done <<<"$children"
    done <<<"$roles"
  done
  SERVICE_ROLE_PARENTS_READ=true
}

# reconcile_service_roles RESOURCE DEFINITIONS CREATE: the service roles of one resource client
# (core's, SkyMail's): DEFINITIONS names the array of name|clients|holders|description lines; CREATE
# is create (a missing role is created) or existing (a missing role without a description is reported
# and skipped: SkyMail's roles are SkyMail's catalogue, made with the client skymail; a line with a
# description is a role nothing else makes, created as with create). Changes add up in
# SERVICE_ROLE_CHANGES; the caller resets it and logs the total.
reconcile_service_roles() {
  local resource=$1 create=$3
  local -n definitions=$2
  local resource_uuid roles_file marks role_name value definition name clients holders description
  local role_id client client_uuid flags full_scope scopes mapped sa_line sa_id sa_name held
  local stderr_file line accounts stamp label others account users groups defaults extra parents
  local flag flag_value open roles_scope_id attributes list
  local operator=false on_client=false
  local names=() all_clients=() plan=() sets=()
  local -A role_ids=() role_clients=() role_holders=() markers=() granted=() client_lines=() person_logins=()
  local -A client_markers=() client_roles=()
  [[ -z $OPERATOR_KCADM_CONFIG ]] || operator=true
  # realm-management's roles cannot be updated: their grant record is on the listed client.
  [[ $resource != realm-management ]] || on_client=true
  if ! resource_uuid=$(optional_lookup client_id_by_client_id "$resource"); then
    return 2
  fi
  if [[ -z $resource_uuid ]]; then
    warn "client $resource does not exist in realm $TARGET_REALM; skipped its service roles"
    return 0
  fi

  # The roles: created when missing (harmless, they grant nothing), before every read; with CREATE
  # existing a missing role without a description is reported and left out of the step.
  for definition in "${definitions[@]}"; do
    IFS='|' read -r name clients holders description <<<"$definition"
    label="client role $name of $resource"
    if ! role_id=$(optional_lookup client_role_id_by_name "$resource_uuid" "$name"); then
      return 2
    fi
    if [[ -z $role_id && $create != create && -z $description ]]; then
      warn "$label does not exist in realm $TARGET_REALM (it is made with the client $resource, not here); it is not granted to ${clients// /, }"
      continue
    fi
    names+=("$name")
    role_clients[$name]=$clients
    role_holders[$name]=$holders
    for client in $clients; do
      [[ " ${all_clients[*]} " == *" $client "* ]] || all_clients+=("$client")
    done
    if [[ -n $role_id ]]; then
      log "$label: unchanged"
    elif service_role_change "create $label"; then
      kcadm_quiet create "clients/$resource_uuid/roles" -r "$TARGET_REALM" \
        -s "name=$name" -s "description=$description"
      role_id=$(client_role_id_by_name "$resource_uuid" "$name")
      log "$label: created"
    fi
    role_ids[$name]=$role_id
  done
  roles_file=$(mktemp "$WORK_DIR/service-roles.XXXXXX")
  kcadm_json "clients/$resource_uuid/roles" -r "$TARGET_REALM" -q briefRepresentation=false >"$roles_file"
  # Into a variable first: a failure inside a process substitution would pass as "no record".
  marks=$(json_tool role-attribute "$CORE_SERVICE_ROLE_GRANT_ATTRIBUTE" <"$roles_file")
  # "<timestamp> <service account>,<service account>"
  while IFS=$'\t' read -r role_name value; do
    if [[ -n $role_name ]]; then markers[$role_name]=$value; fi
  done <<<"$marks"

  # Reads: one plan line per listed client that has a service account.
  for client in "${all_clients[@]}"; do
    if ! client_uuid=$(optional_lookup client_id_by_client_id "$client"); then
      return 2
    fi
    if [[ -z $client_uuid ]]; then
      warn "client $client does not exist in realm $TARGET_REALM; its $resource service roles are not granted to its service account"
      continue
    fi
    flags=$(service_role_read "Client $client" "clients/$client_uuid" --fields serviceAccountsEnabled,fullScopeAllowed)
    if [[ ${flags%%,*} != true ]]; then
      warn "client $client has no service account (serviceAccountsEnabled=${flags%%,*}); its $resource service roles are not granted and nothing was changed on the client"
      continue
    fi
    full_scope=${flags#*,}
    if [[ " ${CORE_SERVICE_ONLY_CLIENTS[*]} " == *" $client "* ]]; then
      # One field per read: nothing depends on the order of the csv columns.
      open=''
      for flag in "${CORE_SERVICE_ONLY_FLAGS[@]}"; do
        flag_value=$(service_role_read "Client $client" "clients/$client_uuid" --fields "$flag")
        [[ $flag_value == false ]] || open+=" $flag"
      done
      person_logins[$client]=${open# }
    fi
    scopes=$(service_role_read "The default client scopes of $client" "clients/$client_uuid/default-client-scopes" --fields name)
    if grep -Fxq roles <<<"$scopes"; then
      log "default client scope roles of $client: verified (it puts resource_access and, through audience resolve, aud $resource in the token)"
    else
      # Without it the service token carries neither resource_access.<resource> nor aud <resource>,
      # and the roles granted below would not reach it (core requires aud core). Attaching a default
      # client scope is client configuration (manage-clients): both identities do it.
      if ! roles_scope_id=$(optional_lookup client_scope_id_by_name roles); then
        return 2
      fi
      if [[ -z $roles_scope_id ]]; then
        warn "client $client has no default client scope roles and realm $TARGET_REALM has no client scope roles: its token carries neither resource_access.$resource nor aud $resource"
      elif service_role_change "add the default client scope roles to client $client (its token lacks resource_access.$resource and aud $resource without it)"; then
        kcadm_quiet update "clients/$client_uuid/default-client-scopes/$roles_scope_id" -r "$TARGET_REALM"
        log "default client scope roles of $client: added (it puts resource_access and, through audience resolve, aud $resource in the token)"
      fi
    fi
    mapped=-
    if [[ $full_scope == false ]]; then
      mapped=$(service_role_read "The role scope of $client" "clients/$client_uuid/scope-mappings/clients/$resource_uuid" --fields name)
      mapped=",$(paste -sd, - <<<"$mapped"),"
    fi
    sa_line=$(service_role_read "The service account of $client" "clients/$client_uuid/service-account-user" --fields id,username)
    sa_id=${sa_line%%,*}
    sa_name=${sa_line#*,}
    if [[ -z $sa_id || -z $sa_name || $sa_line != *,* || $sa_line == *$'\n'* ]]; then
      printf 'The service account of %s could not be resolved in realm %s; nothing was granted\n' "$client" "$TARGET_REALM" >&2
      return 1
    fi
    stderr_file=$(mktemp "$WORK_DIR/stderr.XXXXXX")
    if held=$(kcadm get "users/$sa_id/role-mappings/clients/$resource_uuid/composite" -r "$TARGET_REALM" \
      --fields name --format csv --noquotes 2>"$stderr_file"); then
      held=",$(tr -d '\r' <<<"$held" | sed '/^$/d' | paste -sd, -),"
    elif [[ $operator == true ]]; then
      cat "$stderr_file" >&2
      printf 'The %s roles of %s could not be read in realm %s; nothing was granted\n' "$resource" "$sa_name" "$TARGET_REALM" >&2
      return 1
    else
      # The reconciler identity has no user permissions: expected, the operator step checks.
      held=-
    fi
    client_lines[$client]="$client_uuid|$full_scope|$mapped|$sa_id|$sa_name|$held"
    if [[ $on_client == true ]]; then
      # Into a variable first: a failed read must not pass as "no record".
      # The whole client: kcadm's --fields attributes returns the map empty.
      attributes=$(kcadm_json "clients/$client_uuid" -r "$TARGET_REALM" | json_tool field attributes)
      client_markers[$client]=''
      if [[ -n $attributes ]]; then
        client_markers[$client]=$(json_tool field "$REALM_MANAGEMENT_GRANT_ATTRIBUTE" <<<"$attributes")
      fi
    fi
  done

  if [[ $operator == true ]]; then
    defaults=$(service_role_read "The default role default-roles-${TARGET_REALM,,}" "roles/default-roles-${TARGET_REALM,,}/composites/clients/$resource_uuid" --fields name)
    for name in "${names[@]}"; do
      [[ ${role_holders[$name]} == services && -n ${role_ids[$name]} ]] || continue
      users=$(service_role_read "The users holding $name" "clients/$resource_uuid/roles/$name/users" --fields username)
      groups=$(service_role_read "The groups holding $name" "clients/$resource_uuid/roles/$name/groups" --fields path)
      plan+=("$name"$'\037'"$(paste -sd, - <<<"$users")"$'\037'"$(paste -sd, - <<<"$groups")")
    done
    # After the reads above, so that each of them still fails first when it fails.
    if [[ ${#plan[@]} -gt 0 ]]; then
      service_role_composite_parents || return 1
    fi
  fi

  # Writes: the service-only clients' flags first, then role by role.
  for client in "${all_clients[@]}"; do
    [[ -n ${client_lines[$client]:-} && -n ${person_logins[$client]+set} ]] || continue
    client_uuid=${client_lines[$client]%%|*}
    open=${person_logins[$client]}
    if [[ -z $open ]]; then
      log "client $client: service account only, verified (${CORE_SERVICE_ONLY_FLAGS[*]} false)"
      continue
    fi
    if [[ $operator != true ]]; then
      warn "client $client lets a person sign in ($open not false): core reads the product from client_id == azp, so it must be service account only; nothing was changed on the client; $CORE_SERVICE_ROLE_OPERATOR_STEP"
      continue
    fi
    if service_role_change "set ${open// /=false, }=false on client $client (service account only: no browser login, no password grant)"; then
      sets=()
      for flag in $open; do sets+=(-s "$flag=false"); done
      kcadm_quiet update "clients/$client_uuid" -r "$TARGET_REALM" "${sets[@]}"
      log "client $client: updated (${open// /=false, }=false; service account only)"
    fi
  done
  for name in "${names[@]}"; do
    role_id=${role_ids[$name]}
    value=${markers[$name]:-}
    accounts=''
    for client in ${role_clients[$name]}; do
      [[ -n ${client_lines[$client]:-} ]] || continue
      IFS='|' read -r client_uuid full_scope mapped sa_id sa_name held <<<"${client_lines[$client]}"
      if [[ $mapped == - ]]; then
        log "role scope of $client: unchanged (full scope: the roles of its service account reach its token)"
      elif [[ $mapped == *",$name,"* ]]; then
        log "role scope of $client: unchanged ($resource/$name is mapped)"
      elif service_role_change "map $resource/$name in the role scope of $client (fullScopeAllowed is false)"; then
        kcadm_quiet create "clients/$client_uuid/scope-mappings/clients/$resource_uuid" -r "$TARGET_REALM" \
          -b "[$(role_reference "$role_id" "$name")]"
        log "role scope of $client: updated (+$resource/$name; fullScopeAllowed is false)"
      fi
      if [[ $held == - ]]; then
        if [[ $on_client == true ]]; then
          value=${client_markers[$client]:-}
          [[ -n $value && ,${value#* }, == *",$name,"* ]] || value=''
        fi
        if [[ -n $value && ( $on_client == true || ,${value#* }, == *",$sa_name,"* ) ]]; then
          log "service account $sa_name: $name unchanged (granted by the operator step at ${value%% *}; the reconciler identity cannot read service-account roles, the operator step re-checks them)"
        else
          warn "$name is not yet granted to service account $sa_name by the operator step (the reconciler identity cannot read or grant service-account roles); $CORE_SERVICE_ROLE_OPERATOR_STEP"
        fi
        continue
      fi
      if [[ $held == *",$name,"* ]]; then
        log "service account $sa_name: $name unchanged (held)"
      elif [[ $operator != true ]]; then
        warn "service account $sa_name lacks $name; $CORE_SERVICE_ROLE_OPERATOR_STEP"
        continue
      elif service_role_change "grant $name to service account $sa_name"; then
        kcadm_quiet create "users/$sa_id/role-mappings/clients/$resource_uuid" -r "$TARGET_REALM" \
          -b "[$(role_reference "$role_id" "$name")]"
        log "service account $sa_name: $name granted"
      fi
      accounts+=",$sa_name"
      client_roles[$client]+=",$name"
    done
    [[ $operator == true && $on_client == false ]] || continue

    accounts=$(tr ',' '\n' <<<"${accounts#,}" | sed '/^$/d' | sort | paste -sd, -)
    granted[$name]=$accounts
    if [[ -n $accounts && $accounts != "${value#* }" ]]; then
      stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      if service_role_change "record the grant of $name ($CORE_SERVICE_ROLE_GRANT_ATTRIBUTE=<now> $accounts)"; then
        kcadm_quiet update "clients/$resource_uuid/roles/$name" -r "$TARGET_REALM" \
          -s "attributes.\"$CORE_SERVICE_ROLE_GRANT_ATTRIBUTE\"=[\"$stamp $accounts\"]"
        log "client role $name of $resource: grant recorded ($CORE_SERVICE_ROLE_GRANT_ATTRIBUTE=$stamp $accounts)"
      fi
    fi
  done
  [[ $operator == true ]] || return 0
  if [[ $on_client == true ]]; then
    for client in "${all_clients[@]}"; do
      [[ -n ${client_roles[$client]:-} ]] || continue
      list=$(tr ',' '\n' <<<"${client_roles[$client]#,}" | sed '/^$/d' | sort | paste -sd, -)
      value=${client_markers[$client]:-}
      [[ $list != "${value#* }" ]] || continue
      stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      if service_role_change "record the grant of $resource roles $list on client $client ($REALM_MANAGEMENT_GRANT_ATTRIBUTE=<now> $list)"; then
        kcadm_quiet update "clients/${client_lines[$client]%%|*}" -r "$TARGET_REALM" \
          -s "attributes.\"$REALM_MANAGEMENT_GRANT_ATTRIBUTE\"=$stamp $list"
        log "client $client: $resource grants recorded ($REALM_MANAGEMENT_GRANT_ATTRIBUTE=$stamp $list)"
      fi
    done
  fi

  # Reports: nothing is removed.
  for line in ${plan[@]+"${plan[@]}"}; do
    IFS=$'\037' read -r name users groups <<<"$line"
    parents=${SERVICE_ROLE_PARENTS[${role_ids[$name]}]:-}
    others=''
    for account in ${users//,/ }; do
      [[ ,${granted[$name]}, == *",$account,"* ]] || others+=", $account"
    done
    [[ -z $others ]] \
      || warn "$name is also held by the users ${others#, } (nothing was removed; it is for the service accounts of ${role_clients[$name]} only, remove it in the Admin Console)"
    [[ -z $groups ]] \
      || warn "$name is held by the groups $groups (nothing was removed; every member holds it, remove it in the Admin Console)"
    ! grep -Fxq -- "$name" <<<"$defaults" \
      || warn "$name is in the default role default-roles-${TARGET_REALM,,} (nothing was removed; every user holds it, remove it in the Admin Console)"
    [[ -z $parents ]] \
      || warn "$name is in the composite roles ${parents#,} (nothing was removed; every holder of them holds it, remove it in the Admin Console)"
  done
  # No NOTE for realm-management: the held roles are the effective (composite) ones, and view-users
  # and view-clients themselves hold query-users, query-groups and query-clients.
  [[ $resource != realm-management ]] || return 0
  for client in "${all_clients[@]}"; do
    [[ -n ${client_lines[$client]:-} ]] || continue
    IFS='|' read -r client_uuid full_scope mapped sa_id sa_name held <<<"${client_lines[$client]}"
    extra=''
    for role_name in ${held//,/ }; do
      for name in "${names[@]}"; do
        [[ $role_name != "$name" || " ${role_clients[$name]} " != *" $client "* ]] || continue 2
      done
      extra+=", $role_name"
    done
    [[ -z $extra ]] \
      || log "NOTE: service account $sa_name also holds the $resource roles ${extra#, }, which this step does not manage (nothing was removed)"
  done
}

# The service-roles step: core's service roles, then SkyMail's roles of core's service account, then
# the realm-management roles of SkyMail's service account, and for the operator one total of the
# changes.
reconcile_core_service_roles() {
  SERVICE_ROLE_CHANGES=0
  reconcile_service_roles "$CORE_CLIENT_ID" CORE_SERVICE_ROLE_DEFINITIONS create
  reconcile_service_roles "$SKYMAIL_CLIENT_ID" SKYMAIL_SERVICE_ROLE_DEFINITIONS existing
  reconcile_service_roles realm-management REALM_MANAGEMENT_SERVICE_ROLE_DEFINITIONS existing
  [[ -n $OPERATOR_KCADM_CONFIG ]] || return 0
  if [[ $RECONCILE_CHECK == true ]]; then
    log "check: $SERVICE_ROLE_CHANGES change(s) pending; nothing was written"
  else
    log "applied $SERVICE_ROLE_CHANGES change(s)"
  fi
}

# SkyMail's Privileged roles (runbook §25): client roles of skymail that go to the Privileged groups,
# with the same one-time seeding as core's resource roles (CORE_ROLE_SEED_ATTRIBUTE,
# core_privileged_groups, the default-group refusal). This is the code area of SkyMail's roles
# (ekip-yetkileri ticket 03, YETKI-MATRISI §6.1 and §6.2): what the Privileged roots hold. Where else
# skymail:access and skymail:templates:read (app roles) are held is the panel's (config/app-assignments.json,
# core's Uygulamalar page) and never touched here. A role with a description is made by this step when
# it is missing (manage-clients; the description is written only then); a role whose description is
# "-" is SkyMail's own (SkyMail's M1 makes it): never created here, seeded once it exists, and a realm
# without it says so in the "unchanged" line. The operator's core-roles step (KEYCLOAK_RECONCILE_ONLY=
# core-roles) grants an unmarked role to its Privileged groups once and marks it
# (seed_privileged_client_roles, shared with core); a mapping changed later in the SKY LAB admin panel
# or the Keycloak Admin Console stays that way (the code area's check, KEYCLOAK_RECONCILE_ONLY=
# app-assignments, reports it). Nothing here removes a mapping or a role. skymail is SkyMail's login
# client too, and its own roles always pass its role scope, so a Privileged person's SkyMail token
# carries them.
# name|Privileged groups (space separated names, each at /<NAME> and/or /UYELER/<NAME>)|description
# (written only when the role is created; "-": SkyMail's own role, never created here).
#   skymail:system-mails:read      ADMIN, YK, DK: reading is for all three (skymail-backend #61).
#   skymail:mails:tracking:read    ADMIN, YK, DK: the per-person opening and click report of any send
#                                  (iletisim-servisi tickets 14b/17, decision T2; the privacy notice:
#                                  YK, DK, the system administrators and the sending officer see it).
#                                  A reading role, so DK holds it too; the sender sees their own send
#                                  without it (SkyMail checks sent_by, skymail-backend
#                                  internal/handlers/tracking_read.go).
#   skymail:access, skymail:templates:read, skymail:lists:read, skymail:mails:read,
#   skymail:mails:send, skymail:mails:write
#                                  ADMIN and YK (ekip-yetkileri ticket 03; ADR 0067: YK sends directly,
#                                  everyone else through Mail approval). DK reads and does not write
#                                  (grup-yonetimi GY1): none of them. Sub-groups inherit the mapping.
#   skymail:mails:approve          YK only (Yusuf, 2026-10-23, S2: the approver of Mail approval is the
#                                  YK root, so it follows the term's handover; until then one named
#                                  person in /ROLLER/SKYMAIL-MAILS-APPROVE approved).
# skymail:announcements:send left the list (ticket 03, YETKI-MATRISI §3 D-1): no service reads it (YK
# sends directly with mails:write and mails:send), so it only misled. Taken off the list, a new realm
# never gets it; the role and its mappings stay where they are (nothing here removes anything): the
# code area's check reports them as not in code, and the reset window (ticket 06 c2) takes them away.
SKYMAIL_PRIVILEGED_ROLE_DEFINITIONS=(
  'skymail:system-mails:read|ADMIN YK DK|Tekil sistem postalarının (doğrulama, bildirim) içeriğini görür (skymail-backend #61)'
  'skymail:mails:tracking:read|ADMIN YK DK|Her gönderimin kişi bazındaki açılma ve tıklama raporunu görür (iletisim-servisi 14b/17, T2; gönderen kendi gönderimini rolsüz görür)'
  'skymail:access|ADMIN YK|-'
  'skymail:templates:read|ADMIN YK|-'
  'skymail:lists:read|ADMIN YK|-'
  'skymail:mails:read|ADMIN YK|-'
  'skymail:mails:send|ADMIN YK|-'
  'skymail:mails:write|ADMIN YK|-'
  'skymail:mails:approve|YK|-'
)

# Forms' Privileged roles (runbook §28), the same way as SkyMail's (same list format):
#   skyforms:read-all  DK: DK reads every form, its answers and workflows in Forms and writes nothing
#                      (Yusuf, 2026-10-12 22:15; grup-yonetimi ticket 08, Entra's Global Reader). An
#                      admin role (club-wide personal data). Nothing reads it yet: forms-backend opens
#                      the reads to it and no write route (Fatih's; the role contract is in sky_lab_genel
#                      notes/mesajlar-2026-10-02/ekler/fatih-forms-rol-temizligi-devir-notu.md §6).
#                      Until then DK keeps the skyforms:* it holds (config/dk-read-only.sh --forms takes
#                      it away once forms-backend reads this role).
#   skyforms:access    ADMIN, YK, DK: the Forms seat of the Privileged roots (ekip-yetkileri ticket 03;
#                      DK's own forms, a known deviation: PLAN §1.10 row 13). Forms' own role ("-"):
#                      never created here. Where else the seat is held is the panel's (an app role).
#   skyforms:*         YK only (Yusuf, 2026-10-23, S4: "YK de olsun"; a deviation from Microsoft, where
#                      an admin does not see other people's forms by default: YK reads every answer,
#                      personal data, so the privacy notice names YK). The two named people of
#                      /ROLLER/FORMS-ALL keep it there (config/role-groups.json). Forms' own role.
# forms is a service account client (Forms signs people in through skyforms); the admin panel's role
# scope carries every forms role (ADMIN_PANEL_API_CLIENTS), these too.
FORMS_CLIENT_ID=forms
FORMS_PRIVILEGED_ROLE_DEFINITIONS=(
  'skyforms:read-all|DK|Her formu, cevaplarını ve iş akışlarını okur, hiçbir şeyi değiştirmez (DK; grup-yonetimi 08)'
  'skyforms:access|ADMIN YK DK|-'
  'skyforms:*|YK|-'
)

# SkyCloud's Privileged role (runbook §33.6), the same way as SkyMail's own roles (same list format):
#   admin    ADMIN and YK (Yusuf, 2026-10-24: the SkyCloud, Nextcloud, administrators are /ADMIN and
#            /UYELER/YK). An admin role, so the code area's (YETKI-MATRISI §6.2); the named people of
#            /ROLLER/SKYCLOUD-ADMIN keep it there (config/role-groups.json). Seeded once before the
#            reset window (ekip-yetkileri ticket 06), which takes away the admin the Java era's realm
#            role composites gave.
# The client skycloud is made by hand in production and is not in this repository (the sandbox has
# none): neither it nor its role ("-") is ever created here. A realm without the client skips the
# role with a WARNING; a client without the role says so in the "unchanged" line. skycloud:access is
# not in the list: the top teams' Leader groups hold it (config/leader-app-roles.sh), the Privileged
# roots do not (YETKI-MATRISI §6.2). Only the operator's core-roles step runs this: the full
# reconciliation has nothing to make for a hand-made client, and a realm without it would warn on
# every run.
SKYCLOUD_CLIENT_ID=skycloud
SKYCLOUD_PRIVILEGED_ROLE_DEFINITIONS=(
  'admin|ADMIN YK|-'
)

# reconcile_privileged_app_roles CLIENT_ID LABEL OWNER DEFINITIONS SECTION: the Privileged roles of one
# application client (DEFINITIONS names its list, "name|Privileged groups|description"). LABEL names
# the roles in the messages ("<LABEL> roles not yet granted", "<LABEL> role <name>: seeded once"),
# OWNER is the possessive in "skipped <OWNER> Privileged roles", SECTION the runbook section.
reconcile_privileged_app_roles() {
  local client_id=$1 label=$2 owner=$3 section=$5
  local -n definitions=$4
  local client_uuid roles_csv definition name description created='' seeds role_name role_seed_value seed
  local unseeded=()
  if ! client_uuid=$(optional_lookup client_id_by_client_id "$client_id"); then
    return 2
  fi
  if [[ -z $client_uuid ]]; then
    warn "client $client_id does not exist in realm $TARGET_REALM; skipped $owner Privileged roles"
    return 0
  fi
  roles_csv=$(kcadm get "clients/$client_uuid/roles" -r "$TARGET_REALM" --fields name --format csv --noquotes \
    | tr -d '\r')
  # absent: the application's own roles ("-") the realm does not have; never created, never seeded.
  local absent=''
  for definition in "${definitions[@]}"; do
    name=${definition%%|*}
    description=${definition##*|}
    if ! grep -Fxq -- "$name" <<<"$roles_csv"; then
      if [[ $description == - ]]; then
        absent="$absent $name"
        continue
      fi
      kcadm_quiet create "clients/$client_uuid/roles" -r "$TARGET_REALM" \
        -s "name=$name" -s "description=$description"
      created="$created, $name"
    fi
  done
  local not_here=''
  [[ -z $absent ]] || not_here="; not in the realm, the application makes them, seeded once they exist:$absent"
  if [[ -z $created ]]; then
    log "Privileged roles of $client_id (${#definitions[@]}): unchanged$not_here"
  else
    log "Privileged roles of $client_id (${#definitions[@]}): created (${created#, })$not_here"
  fi

  seeds=$(kcadm_json "clients/$client_uuid/roles" -r "$TARGET_REALM" -q briefRepresentation=false \
    | json_tool role-attribute "$CORE_ROLE_SEED_ATTRIBUTE")
  for definition in "${definitions[@]}"; do
    name=${definition%%|*}
    [[ " $absent " != *" $name "* ]] || continue
    seed=''
    while IFS=$'\t' read -r role_name role_seed_value; do
      [[ $role_name == "$name" ]] && seed=$role_seed_value
    done <<<"$seeds"
    [[ -n $seed ]] || unseeded+=("$name")
  done
  if [[ ${#unseeded[@]} == 0 ]]; then
    log "group mappings of the $client_id Privileged roles: unchanged (each seeded once; the SKY LAB admin panel owns them)"
    return 0
  fi
  if [[ -z $OPERATOR_KCADM_CONFIG ]]; then
    warn "$label roles not yet granted to the Privileged groups: ${unseeded[*]} (granting a role to a group needs user permissions the reconciler identity does not have); run this step alone with an operator session: KEYCLOAK_RECONCILE_ONLY=core-roles (runbook $section)"
    return 0
  fi

  # Operator session: seed, with the same checks and mark as core's resource roles, one call per set
  # of Privileged groups (in the order of the list).
  local group_names known set_names=() sets=()
  for definition in "${definitions[@]}"; do
    group_names=${definition#*|}
    group_names=${group_names%%|*}
    for known in ${sets[@]+"${sets[@]}"}; do
      [[ $known != "$group_names" ]] || continue 2
    done
    sets+=("$group_names")
  done
  for group_names in "${sets[@]}"; do
    set_names=()
    for definition in "${definitions[@]}"; do
      name=${definition%%|*}
      if [[ ${definition#*|} == "$group_names|"* && " ${unseeded[*]} " == *" $name "* ]]; then
        set_names+=("$name")
      fi
    done
    if [[ ${#set_names[@]} -gt 0 ]]; then
      seed_privileged_client_roles "$label" "$client_uuid" "$group_names" "${set_names[@]}"
    fi
  done
}

# write_privileged_expectations FILE: the code area's Privileged expectations that only this file
# holds, for config/app-assignments.sh (KEYCLOAK_RECONCILE_ONLY=app-assignments and tohum-atamalar):
# "privileged<TAB>NAMES<TAB>client<TAB>role" per role of CORE_ROLE_DEFINITIONS (its seed groups),
# SKYMAIL_PRIVILEGED_ROLE_DEFINITIONS, FORMS_PRIVILEGED_ROLE_DEFINITIONS and
# SKYCLOUD_PRIVILEGED_ROLE_DEFINITIONS; NAMES is the space
# separated Privileged names (ADMIN, YK, DK), each at /<NAME> and /UYELER/<NAME>.
write_privileged_expectations() {
  local file=$1 definition name groups
  : >"$file"
  for definition in "${CORE_ROLE_DEFINITIONS[@]}"; do
    name=${definition%%|*}
    printf 'privileged\t%s\t%s\t%s\n' "$(core_role_seed_names "$name")" "$CORE_CLIENT_ID" "$name" >>"$file"
  done
  for definition in "${SKYMAIL_PRIVILEGED_ROLE_DEFINITIONS[@]}"; do
    groups=${definition#*|}
    printf 'privileged\t%s\t%s\t%s\n' "${groups%%|*}" "$SKYMAIL_CLIENT_ID" "${definition%%|*}" >>"$file"
  done
  for definition in "${FORMS_PRIVILEGED_ROLE_DEFINITIONS[@]}"; do
    groups=${definition#*|}
    printf 'privileged\t%s\t%s\t%s\n' "${groups%%|*}" "$FORMS_CLIENT_ID" "${definition%%|*}" >>"$file"
  done
  for definition in "${SKYCLOUD_PRIVILEGED_ROLE_DEFINITIONS[@]}"; do
    groups=${definition#*|}
    printf 'privileged\t%s\t%s\t%s\n' "${groups%%|*}" "$SKYCLOUD_CLIENT_ID" "${definition%%|*}" >>"$file"
  done
}

# The realm's default role (ekip-yetkileri ticket 03, YETKI-MATRISI §6.2 and §6.4; Yusuf, 2026-10-23,
# K2): every account holds it, so it carries Keycloak's own roles only. DEFAULT_ROLE_EXPECTED is that
# set (Keycloak's own default for a new realm); a role of it that is missing is a NOTE and is not
# added. The account console's other roles (account/*: one's own account only) are Keycloak's own
# too and stay without a word. DEFAULT_ROLE_REMOVALS are taken away (KEYCLOAK_RECONCILE_ONLY=
# default-roles, an operator step: a dry run with KEYCLOAK_RECONCILE_CHECK=true, then the same without
# it, then a dry run with 0 changes): broker/read-token lets its holder read the token Keycloak stored
# from their YTÜ/Microsoft login (GET /realms/<realm>/broker/<alias>/token); no app reads it
# (2026-10-23 origin/main sweep) and neither Keycloak's own default nor Entra hands it out. It is taken
# away where the default role holds it: directly, or inside a composite role the default role holds
# (production, 2026-10-23 precheck: the Java era's realm role USER carries it; the composite stays in
# the default role with its other roles). Any other role in the default role is a WARNING and stays (a
# decision of its own; the reset window, ticket 06, takes it).
# The identity providers' token settings: Keycloak gives broker/read-token to every account a first
# login of an identity provider opens while its "Stored tokens readable" (addReadTokenRoleOnCreate) is
# on, so the step turns it off; "Store tokens" (storeToken) is reported, not changed (eskylab-login-ux
# ticket 04 turns it off after its sandbox test). The reconciler identity cannot read identity
# providers, hence an operator step. The people who already hold broker/read-token directly (given
# at a first login) and the groups and composite roles that hold it are reported, never taken away:
# the reset window (ticket 06) does. Lines "KOD|<holder>|<client>|<role or setting>|<expected>|<live>"
# (holder default-roles-<realm> or idp:<alias>; expected evet or hayır for a role, false for a
# setting), counts only, never a person.
DEFAULT_ROLE_EXPECTED=(realm/offline_access realm/uma_authorization account/view-profile account/manage-account)
DEFAULT_ROLE_REMOVALS=(broker/read-token)
DEFAULT_ROLE_CHANGES=0

default_role_change() {
  DEFAULT_ROLE_CHANGES=$((DEFAULT_ROLE_CHANGES + 1))
  if [[ $RECONCILE_CHECK == true ]]; then
    log "would $1"
    return 1
  fi
  log "$1"
  return 0
}

reconcile_default_roles() {
  local realm_file default_json default_name default_id composites clients line id rest name client_role
  local container owner key wanted found removal idps alias store readable broker_uuid holders people groups
  local queue next parent parent_key nested composite depth=0 parents parent_list
  local -A client_of=() key_of=() seen_parent=() removed_from=()
  DEFAULT_ROLE_CHANGES=0
  realm_file=$(mktemp "$WORK_DIR/realm.XXXXXX")
  kcadm_json "realms/$TARGET_REALM" >"$realm_file"
  default_json=$(json_tool field defaultRole <"$realm_file")
  default_name=$(json_tool field name <<<"$default_json")
  default_id=$(json_tool field id <<<"$default_json")
  [[ -n $default_name && -n $default_id ]] || { printf 'The default role of realm %s could not be read\n' "$TARGET_REALM" >&2; return 1; }
  clients=$(service_role_read 'The clients' clients --fields id,clientId) || return 1
  while IFS=, read -r id rest; do
    [[ -z $id ]] || client_of[$id]=$rest
  done <<<"$clients"
  # id first, containerId last: a role name holds no comma.
  composites=$(service_role_read "The composites of $default_name" "roles-by-id/$default_id/composites" \
    --fields id,name,clientRole,containerId) || return 1
  found=' '
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    id=${line%%,*}
    rest=${line#*,}
    container=${rest##*,}
    rest=${rest%,*}
    client_role=${rest##*,}
    name=${rest%,*}
    if [[ $client_role == true ]]; then
      owner=${client_of[$container]:-?}
    else
      owner=realm
    fi
    key="$owner/$name"
    key_of[$id]=$key
    found="$found$key "
    if [[ " ${DEFAULT_ROLE_EXPECTED[*]} " == *" $key "* || $owner == account ]]; then
      log "KOD|$default_name|$owner|$name|evet|var"
      continue
    fi
    log "KOD|$default_name|$owner|$name|hayır|var"
    removal=false
    for wanted in "${DEFAULT_ROLE_REMOVALS[@]}"; do
      [[ $wanted != "$key" ]] || removal=true
    done
    if [[ $removal == true ]]; then
      if default_role_change "remove $key from the default role $default_name (every account holds it; no app reads it)"; then
        kcadm delete "roles-by-id/$default_id/composites" -r "$TARGET_REALM" -b "[{\"id\":\"$id\"}]" >/dev/null
      fi
    else
      warn "$key is in the default role $default_name: every account holds it, and it is not one of Keycloak's own (${DEFAULT_ROLE_EXPECTED[*]} or an account console role); not taken away here (the reset window, ekip-yetkileri ticket 06)"
    fi
  done <<<"$composites"
  # The roles the default role reaches through its composite roles: every account holds them as well. A
  # DEFAULT_ROLE_REMOVALS role there is taken away from the composite that holds it; the rest is left
  # (Keycloak's own nesting such as account/manage-account -> manage-account-links). Three levels, each
  # composite read once. kcadm's CSV keeps the representation's field order (id, name, composite,
  # clientRole, containerId), so "composite" is read on its own, next to the id.
  queue=$(service_role_read "The composite roles in $default_name" "roles-by-id/$default_id/composites" --fields id,composite) || return 1
  queue=$(sed -n 's/^\([^,]*\),true$/\1/p' <<<"$queue")
  while [[ -n $queue ]] && ((depth < 3)); do
    depth=$((depth + 1))
    next=''
    for parent in $queue; do
      [[ -z ${seen_parent[$parent]:-} ]] || continue
      seen_parent[$parent]=1
      parent_key=${key_of[$parent]:-?}
      nested=$(service_role_read "The composites of $parent_key" "roles-by-id/$parent/composites" \
        --fields id,name,clientRole,containerId) || return 1
      composite=$(service_role_read "The composites of $parent_key" "roles-by-id/$parent/composites" --fields id,composite) || return 1
      next="$next $(sed -n 's/^\([^,]*\),true$/\1/p' <<<"$composite" | paste -sd' ' -)"
      while IFS= read -r line; do
        [[ -n $line ]] || continue
        id=${line%%,*}
        rest=${line#*,}
        container=${rest##*,}
        rest=${rest%,*}
        client_role=${rest##*,}
        name=${rest%,*}
        if [[ $client_role == true ]]; then
          owner=${client_of[$container]:-?}
        else
          owner=realm
        fi
        key="$owner/$name"
        [[ -n ${key_of[$id]:-} ]] || key_of[$id]=$key
        removal=false
        for wanted in "${DEFAULT_ROLE_REMOVALS[@]}"; do
          [[ $wanted != "$key" ]] || removal=true
        done
        [[ $removal == true ]] || continue
        log "KOD|$default_name>$parent_key|$owner|$name|hayır|var"
        removed_from[$parent_key]=1
        if default_role_change "remove $key from the composite role $parent_key, which is in the default role $default_name (every account holds it through $parent_key; no app reads it; $parent_key itself stays)"; then
          kcadm delete "roles-by-id/$parent/composites" -r "$TARGET_REALM" -b "[{\"id\":\"$id\"}]" >/dev/null
        fi
      done <<<"$nested"
    done
    queue=$next
  done
  for wanted in "${DEFAULT_ROLE_EXPECTED[@]}"; do
    [[ $found == *" $wanted "* ]] && continue
    log "KOD|$default_name|${wanted%%/*}|${wanted#*/}|evet|yok"
    log "NOTE: $wanted, one of Keycloak's own default roles, is not in $default_name; not added"
  done

  # The identity providers' token settings. Booleans Keycloak leaves out are false.
  idps=$(service_role_read 'The identity providers' identity-provider/instances \
    --fields alias,storeToken,addReadTokenRoleOnCreate) || return 1
  while IFS=, read -r alias store readable; do
    [[ -n $alias ]] || continue
    store=${store:-false}
    readable=${readable:-false}
    log "KOD|idp:$alias|-|storeToken|false|$store"
    log "KOD|idp:$alias|-|addReadTokenRoleOnCreate|false|$readable"
    if [[ $readable == true ]]; then
      if default_role_change "turn off Stored tokens readable of identity provider $alias (addReadTokenRoleOnCreate: Keycloak would give broker/read-token to every account its first login opens)"; then
        kcadm update "identity-provider/instances/$alias" -r "$TARGET_REALM" -s addReadTokenRoleOnCreate=false >/dev/null
      fi
    fi
    if [[ $store == true ]]; then
      warn "identity provider $alias stores the tokens of its logins (Store tokens on): turn it off once eskylab-login-ux ticket 04's sandbox test shows that the department still arrives; not changed here"
    fi
  done <<<"$idps"

  # Other holders of broker/read-token: counts and group paths only.
  if ! broker_uuid=$(optional_lookup client_id_by_client_id broker); then
    return 2
  fi
  if [[ -n $broker_uuid ]]; then
    holders=$(service_role_read 'The holders of broker/read-token' "clients/$broker_uuid/roles/read-token/users" \
      --fields username -q first=0 -q max=100000) || return 1
    people=$(grep -vc '^service-account-' <<<"$holders" || true)
    [[ -z $holders ]] && people=0
    [[ $people == 0 ]] \
      || log "NOTE: broker/read-token is held directly by $people person(s) (given at a first login while Stored tokens readable was on); not taken away here: the reset window (ekip-yetkileri ticket 06) does"
    groups=$(service_role_read 'The groups holding broker/read-token' "clients/$broker_uuid/roles/read-token/groups" \
      --fields path -q first=0 -q max=100000) || return 1
    [[ -z $groups ]] \
      || warn "broker/read-token is held by the group(s) $(paste -sd, - <<<"$groups" | sed 's/,/, /g') (every member holds it); not taken away here"
    id=$(service_role_read 'The roles of broker' "clients/$broker_uuid/roles" --fields id,name) || return 1
    id=$(id_from_csv read-token "$id" || true)
    if [[ -n $id ]]; then
      service_role_composite_parents || return 1
      # The composites this step takes it away from (above) are not reported again.
      parents=''
      IFS=, read -r -a parent_list <<<"${SERVICE_ROLE_PARENTS[$id]:-}"
      for parent in ${parent_list[@]+"${parent_list[@]}"}; do
        [[ -z $parent || -n ${removed_from[$parent]:-} ]] || parents="$parents,$parent"
      done
      [[ -z $parents ]] \
        || warn "broker/read-token is in the composite role(s) ${parents#,} (every holder holds it; the Java era's realm roles leave in rol-temizligi F3); not taken away here"
    fi
  fi
  if [[ $RECONCILE_CHECK == true ]]; then
    log "check: $DEFAULT_ROLE_CHANGES change(s) pending; nothing was written"
  else
    log "applied $DEFAULT_ROLE_CHANGES change(s)"
  fi
}

reconcile_skymail_privileged_roles() {
  reconcile_privileged_app_roles "$SKYMAIL_CLIENT_ID" skymail "SkyMail's" SKYMAIL_PRIVILEGED_ROLE_DEFINITIONS '§25'
}

reconcile_forms_privileged_roles() {
  reconcile_privileged_app_roles "$FORMS_CLIENT_ID" forms "Forms'" FORMS_PRIVILEGED_ROLE_DEFINITIONS '§28'
}

reconcile_skycloud_privileged_roles() {
  reconcile_privileged_app_roles "$SKYCLOUD_CLIENT_ID" skycloud "SkyCloud's" SKYCLOUD_PRIVILEGED_ROLE_DEFINITIONS '§33.6'
}

# place-service: Place's service account for core's contact consents (consent:record above; Yusuf,
# 2026-10-25). A confidential client with the client-credentials grant only: no browser login, no
# implicit flow, no password grant, no redirect URI, no web origin, no device grant, no CIBA, no token
# exchange, and fullScopeAllowed=false, so its token carries only the roles the service-roles step maps
# into its role scope (core/consent:record; aud core comes with it through the default scope roles).
# Place's login client place stays as config/create-place-client.sh keeps it (no service account):
# core reads the product from azp, and a person never signs in through place-service. Made by the
# reconciler identity (manage-clients) in every realm it runs in (sandbox and production); every run
# puts the fields below back. Keycloak generates the client secret when it creates the client; it is
# never read or printed here. Moving it to Place (OpenBao, a Dokploy reference) is an operator's step
# (runbook §20.2). The role itself is granted by the operator's service-roles step.
PLACE_SERVICE_CLIENT_ID=place-service
PLACE_SERVICE_CLIENT_NAME='Place service account'
PLACE_SERVICE_CLIENT_DESCRIPTION="Place backend's service account (client credentials only) for core's contact consents (consent:record). Made by config/reconcile-account-center.sh; never a login client."

reconcile_place_service_client() {
  local desired_file="$WORK_DIR/client-$PLACE_SERVICE_CLIENT_ID.json" client_uuid
  if ! client_uuid=$(optional_lookup client_id_by_client_id "$PLACE_SERVICE_CLIENT_ID"); then
    return 2
  fi
  if [[ -z $client_uuid ]]; then
    # The flags that matter are set when it is made, so that no moment has a login client.
    client_uuid=$(kcadm create clients -r "$TARGET_REALM" -i \
      -s "clientId=$PLACE_SERVICE_CLIENT_ID" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s bearerOnly=false \
      -s serviceAccountsEnabled=true \
      -s standardFlowEnabled=false \
      -s implicitFlowEnabled=false \
      -s directAccessGrantsEnabled=false \
      -s fullScopeAllowed=false)
    log "client $PLACE_SERVICE_CLIENT_ID: created"
  fi
  cat >"$desired_file" <<EOF
{
  "clientId": "$PLACE_SERVICE_CLIENT_ID",
  "name": "$PLACE_SERVICE_CLIENT_NAME",
  "description": "$PLACE_SERVICE_CLIENT_DESCRIPTION",
  "enabled": true,
  "protocol": "openid-connect",
  "clientAuthenticatorType": "client-secret",
  "publicClient": false,
  "bearerOnly": false,
  "standardFlowEnabled": false,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": true,
  "authorizationServicesEnabled": false,
  "consentRequired": false,
  "frontchannelLogout": false,
  "fullScopeAllowed": false,
  "redirectUris": [],
  "webOrigins": [],
  "attributes": {
    "oauth2.device.authorization.grant.enabled": "false",
    "oidc.ciba.grant.enabled": "false",
    "standard.token.exchange.enabled": "false"
  }
}
EOF
  apply_fields_if_changed "client $PLACE_SERVICE_CLIENT_ID" "$desired_file" \
    "clients/$client_uuid" -r "$TARGET_REALM"
}

# The keycloak-mailer service-account client (K5) is provisioned by the operator with
# create-mailer-client.sh because assigning its SkyMail roles needs user permissions the
# reconciler identity deliberately lacks. Here the client is verified only: a missing client
# or roles the reconciler cannot read produce a warning with the command to run, wrong flags
# or a missing roles scope fail the run (the fix is the same command).
verify_mailer_client() {
  local mailer_uuid live_flags skymail_uuid service_user_id assigned expected scope_roles
  if ! mailer_uuid=$(optional_lookup client_id_by_client_id "$MAILER_CLIENT_ID"); then
    return 2
  fi
  if [[ -z $mailer_uuid ]]; then
    warn "client $MAILER_CLIENT_ID does not exist; run: $MAILER_CREATE_COMMAND"
    return 0
  fi
  live_flags=$(mailer_client_flags "$mailer_uuid")
  if [[ $live_flags != "$MAILER_FLAG_VALUES" ]]; then
    printf 'Client %s drifted (%s: %s, expected %s); run: %s\n' \
      "$MAILER_CLIENT_ID" "$MAILER_FLAG_FIELDS" "$live_flags" "$MAILER_FLAG_VALUES" \
      "$MAILER_CREATE_COMMAND" >&2
    return 1
  fi
  if [[ -z $(mailer_roles_scope_attached "$mailer_uuid") ]]; then
    printf 'Client %s lacks the roles default scope; run: %s\n' \
      "$MAILER_CLIENT_ID" "$MAILER_CREATE_COMMAND" >&2
    return 1
  fi
  log "client $MAILER_CLIENT_ID: verified (confidential service account, $MAILER_FLAG_FIELDS=$MAILER_FLAG_VALUES, roles scope attached)"
  skymail_uuid=$(optional_lookup client_id_by_client_id "$SKYMAIL_CLIENT_ID")
  if [[ -z $skymail_uuid ]]; then
    warn "client $SKYMAIL_CLIENT_ID does not exist; $MAILER_CLIENT_ID cannot hold SkyMail roles yet; run after SkyMail exists: $MAILER_CREATE_COMMAND"
    return 0
  fi
  expected=$(mailer_expected_roles)
  scope_roles=$(mailer_scope_mapping_roles "$mailer_uuid" "$skymail_uuid")
  if [[ $scope_roles != "$expected" ]]; then
    warn "scope mappings of $MAILER_CLIENT_ID are '${scope_roles:-none}' instead of '$expected'; run: $MAILER_CREATE_COMMAND"
  fi
  service_user_id=$(kcadm get "clients/$mailer_uuid/service-account-user" \
    -r "$TARGET_REALM" \
    --fields id \
    --format csv \
    --noquotes)
  if [[ -z $service_user_id || $service_user_id == *,* ]]; then
    warn "the $MAILER_CLIENT_ID service-account user could not be resolved; run: $MAILER_CREATE_COMMAND"
    return 0
  fi
  if ! assigned=$(mailer_service_account_roles "$service_user_id" "$skymail_uuid" 2>/dev/null); then
    warn "service-account roles of $MAILER_CLIENT_ID are not readable with the reconciler identity (no user permissions); expected '$expected', verify with an administrator: $MAILER_CREATE_COMMAND"
    return 0
  fi
  if [[ $assigned == "$expected" ]]; then
    log "service-account roles of $MAILER_CLIENT_ID: verified ($expected)"
  else
    warn "service-account roles of $MAILER_CLIENT_ID are '${assigned:-none}' instead of '$expected'; run: $MAILER_CREATE_COMMAND"
  fi
}

# The core-erasure service-account client (account erasure, ADR-0051) is provisioned by the
# operator with create-erasure-client.sh, for the same reason as keycloak-mailer: its service
# account holds the erase roles, and assigning them needs user permissions. Here it is verified
# only, and everything that keeps one service's erase role out of another service's token is
# security state: wrong flags, a scope list other than the contract, a direct scope mapping, an
# erase scope with another mapper or another role, or a missing resource client fail the run
# (the fix is the operator command). A missing client and roles the reconciler cannot read are
# warnings.
verify_erasure_client() {
  local client_uuid live expected drift='' i scope_uuid resource_uuid service_user_id assigned
  local resource_arguments=() mismatched=''
  if ! client_uuid=$(optional_lookup erasure_client_uuid "$ERASURE_CLIENT_ID"); then
    return 2
  fi
  if [[ -z $client_uuid ]]; then
    warn "client $ERASURE_CLIENT_ID does not exist; run: $ERASURE_CREATE_COMMAND"
    return 0
  fi
  live=$(erasure_client_flags "$client_uuid")
  [[ $live == "$ERASURE_FLAG_VALUES" ]] \
    || drift+="; $ERASURE_FLAG_FIELDS: $live, expected $ERASURE_FLAG_VALUES"
  live=$(erasure_client_scopes "$client_uuid" default)
  expected=$(erasure_expected_default_scopes)
  [[ $live == "$expected" ]] || drift+="; default scopes: ${live:-none}, expected $expected"
  live=$(erasure_client_scopes "$client_uuid" optional)
  expected=$(erasure_expected_optional_scopes)
  [[ $live == "$expected" ]] || drift+="; optional scopes: ${live:-none}, expected $expected"
  for i in "${!ERASURE_SERVICES[@]}"; do
    if ! resource_uuid=$(optional_lookup erasure_client_uuid "${ERASURE_RESOURCE_CLIENTS[$i]}"); then
      return 2
    fi
    if [[ -z $resource_uuid ]]; then
      drift+="; resource client ${ERASURE_RESOURCE_CLIENTS[$i]} does not exist"
      continue
    fi
    resource_arguments+=("$resource_uuid" "${ERASURE_RESOURCE_CLIENTS[$i]}")
  done
  live=$(erasure_role_mappings "clients/$client_uuid/scope-mappings" "${resource_arguments[@]}")
  [[ -z $live ]] || drift+="; direct scope mappings $(paste -sd, - <<<"$live") (every token would carry them)"
  for i in "${!ERASURE_SERVICES[@]}"; do
    if ! scope_uuid=$(optional_lookup erasure_scope_uuid "${ERASURE_SCOPES[$i]}"); then
      return 2
    fi
    if [[ -z $scope_uuid ]]; then
      drift+="; scope ${ERASURE_SCOPES[$i]} does not exist"
      continue
    fi
    [[ $(erasure_scope_protocol "$scope_uuid") == openid-connect ]] \
      || drift+="; scope ${ERASURE_SCOPES[$i]} is not openid-connect"
    live=$(erasure_scope_mappers "$scope_uuid")
    [[ $live == "$(erasure_expected_mapper "$i")" ]] \
      || drift+="; mappers of ${ERASURE_SCOPES[$i]}: $(paste -sd' ' - <<<"${live:-none}"), expected $(erasure_expected_mapper "$i")"
    live=$(erasure_role_mappings "client-scopes/$scope_uuid/scope-mappings" "${resource_arguments[@]}")
    expected="${ERASURE_RESOURCE_CLIENTS[$i]}:${ERASURE_ROLES[$i]}"
    [[ $live == "$expected" ]] \
      || drift+="; roles of ${ERASURE_SCOPES[$i]}: $(paste -sd, - <<<"${live:-none}"), expected $expected"
  done
  if [[ -n $drift ]]; then
    printf 'Client %s drifted (%s); run: %s\n' "$ERASURE_CLIENT_ID" "${drift#; }" "$ERASURE_CREATE_COMMAND" >&2
    return 1
  fi
  log "client $ERASURE_CLIENT_ID: verified (confidential service account, $ERASURE_FLAG_FIELDS=$ERASURE_FLAG_VALUES, default scopes $(erasure_expected_default_scopes), optional scopes $(erasure_expected_optional_scopes), no direct scope mappings)"
  for i in "${!ERASURE_SERVICES[@]}"; do
    log "erase scope ${ERASURE_SCOPES[$i]}: verified (aud ${ERASURE_RESOURCE_CLIENTS[$i]}, role ${ERASURE_RESOURCE_CLIENTS[$i]}/${ERASURE_ROLES[$i]})"
  done
  service_user_id=$(kcadm get "clients/$client_uuid/service-account-user" \
    -r "$TARGET_REALM" \
    --fields id \
    --format csv \
    --noquotes)
  if [[ -z $service_user_id || $service_user_id == *,* ]]; then
    warn "the $ERASURE_CLIENT_ID service-account user could not be resolved; run: $ERASURE_CREATE_COMMAND"
    return 0
  fi
  for i in "${!ERASURE_SERVICES[@]}"; do
    resource_uuid=${resource_arguments[$((i * 2))]}
    if ! assigned=$(kcadm get "users/$service_user_id/role-mappings/clients/$resource_uuid" \
      -r "$TARGET_REALM" --fields name --format csv --noquotes 2>/dev/null); then
      warn "service-account roles of $ERASURE_CLIENT_ID are not readable with the reconciler identity (no user permissions); expected exactly one erase role per resource client, verify with an administrator: $ERASURE_CREATE_COMMAND (without --apply)"
      return 0
    fi
    [[ $(sed '/^$/d' <<<"$assigned" | paste -sd, -) == "${ERASURE_ROLES[$i]}" ]] \
      || mismatched+=" ${ERASURE_RESOURCE_CLIENTS[$i]}"
  done
  if [[ -z $mismatched ]]; then
    log "service-account roles of $ERASURE_CLIENT_ID: verified (one erase role per resource client)"
  else
    warn "service-account roles of $ERASURE_CLIENT_ID differ on${mismatched}; run: $ERASURE_CREATE_COMMAND"
  fi
}

if [[ -z $OPERATOR_KCADM_CONFIG ]]; then
  authenticate
fi
kcadm_json "realms/$TARGET_REALM" >/dev/null
compile_json_tool

if [[ $RECONCILE_ONLY == admin-panel-client ]]; then
  reconcile_admin_panel_client
  printf 'Admin panel client configuration is reconciled.\n'
  exit 0
fi
if [[ $RECONCILE_ONLY == login-clients ]]; then
  reconcile_login_clients
  printf 'Login client configuration is reconciled.\n'
  exit 0
fi
if [[ $CHECK_WRITES == true ]]; then
  log "CHECK: a dry run; no write is sent (each is a \"would kcadm\" line); the other lines say what a real run would log"
fi
if [[ $RECONCILE_ONLY == core-roles ]]; then
  reconcile_core_roles
  # SkyMail's, Forms' and SkyCloud's Privileged roles have the same operator step (runbook §25, §28,
  # §33.6); SkyCloud's has this step alone (see SKYCLOUD_PRIVILEGED_ROLE_DEFINITIONS).
  reconcile_skymail_privileged_roles
  reconcile_forms_privileged_roles
  reconcile_skycloud_privileged_roles
  if [[ $CHECK_WRITES == true ]]; then
    printf 'Core resource roles are checked; nothing was written (%s write(s) withheld).\n' "$(check_writes_withheld)"
  else
    printf 'Core resource roles are reconciled.\n'
  fi
  exit 0
fi
if [[ $RECONCILE_ONLY == default-roles ]]; then
  reconcile_default_roles
  if [[ $RECONCILE_CHECK == true ]]; then
    printf 'Default roles and identity provider token settings are checked; nothing was written.\n'
  else
    printf 'Default roles and identity provider token settings are reconciled.\n'
  fi
  exit 0
fi
if [[ $RECONCILE_ONLY == app-assignments || $RECONCILE_ONLY == tohum-atamalar ]]; then
  # config/app-assignments.sh with the Privileged expectations of this file (core's resource roles,
  # SkyMail's, Forms' and SkyCloud's Privileged roles), which only the reconciler knows.
  write_privileged_expectations "$WORK_DIR/privileged-expected.tsv"
  app_arguments=(--kcadm-config "$OPERATOR_KCADM_CONFIG" --privileged-file "$WORK_DIR/privileged-expected.tsv")
  if [[ $RECONCILE_ONLY == tohum-atamalar ]]; then
    app_arguments+=(--seed)
    [[ $RECONCILE_CHECK == true ]] || app_arguments+=(--apply)
  else
    app_arguments+=(--check)
  fi
  app_status=0
  # By name, as role-groups and leader-app-roles above: tests/role-groups.sh runs these steps
  # (tests/affected-jobs.sh EXTRA_EDGES), no reconciliation of the integration harness does.
  app_script=app-assignments
  KEYCLOAK_REALM=$TARGET_REALM KEYCLOAK_ADMIN_URL=$ADMIN_URL \
    bash "$CONFIG_DIR/$app_script.sh" "${app_arguments[@]}" || app_status=$?
  exit "$app_status"
fi
if [[ $RECONCILE_ONLY == first-broker-login ]]; then
  reconcile_first_broker_login
  reconcile_existing_account_prompt
  reconcile_personal_email_offer
  reconcile_stay_signed_in
  printf 'First broker login flow is reconciled.\n'
  exit 0
fi
if [[ $RECONCILE_ONLY == email-code-login ]]; then
  reconcile_email_code_login
  reconcile_email_code_sign_up
  reconcile_after_sign_up
  if [[ -n $EMAIL_CODE_UNGUARDED ]]; then
    printf 'E-mail code sign-in is reconciled except the OTP after the code (%s); run again with KEYCLOAK_EMAIL_CODE_LOGIN=on (or off), or fix the subflow in the Admin Console\n' \
      "$EMAIL_CODE_UNGUARDED" >&2
    exit 3
  fi
  printf 'E-mail code sign-in is reconciled.\n'
  exit 0
fi
if [[ $RECONCILE_ONLY == service-roles ]]; then
  reconcile_core_service_roles
  if [[ $RECONCILE_CHECK == true ]]; then
    printf 'Core service roles are checked; nothing was written.\n'
  else
    printf 'Core service roles are reconciled.\n'
  fi
  exit 0
fi

reconcile_realm_settings
reconcile_brute_force_and_password_policy
reconcile_event_retention
reconcile_rabbitmq_event_listener
reconcile_passkey_policy
reconcile_required_actions
reconcile_user_profile

ensure_account_center_client
retire_account_center_browser_flow
# account-center-browser, the other flow that held a username/password form, is retired and
# deleted just above; the realm browser flow is the only one left to swap.
reconcile_password_form "$BROWSER_FLOW_ALIAS"
reconcile_email_code_login
reconcile_email_code_sign_up
reconcile_after_sign_up
reconcile_reset_choose_user
reconcile_reset_otp_step
reconcile_first_broker_login
reconcile_existing_account_prompt
reconcile_personal_email_offer
reconcile_stay_signed_in
reconcile_account_center_client

ensure_client_scope "$SCOPE_NAME" \
  "$CONFIG_DIR/account-center-account-api-mappers.json"
scope_uuid=$ENSURED_SCOPE_ID
ensure_client_scope "$CORE_SCOPE_NAME" \
  "$CONFIG_DIR/account-center-core-claims-mappers.json"
core_scope_uuid=$ENSURED_SCOPE_ID
reconcile_skyapp_audience
# frontend-main and frontend-arge get their core audience scopes here as well (the scopes of
# reconcile_login_client_audience), together with the narrowing.
reconcile_login_clients
reconcile_login_client_audience "$SKYFORMS_CLIENT_ID" "$SKYFORMS_SCOPE_NAME" \
  "$CONFIG_DIR/skyforms-forms-audience-mappers.json"
# Forms' sidebar label reads the person's groups from the skyforms access token (Fatih, 2026-10-15;
# realm roles go with the role clean-up): full paths, as core and inscribed read them, in the access
# token and introspection only (not the ID token Auth.js keeps in its cookie, not userinfo). Its own
# source-controlled default scope, kept like the audience scope above; a realm scope "groups" that
# also reaches skyforms adds nothing (Keycloak merges a multivalued claim without repeating a path).
reconcile_login_client_audience "$SKYFORMS_CLIENT_ID" "$SKYFORMS_GROUPS_SCOPE_NAME" \
  "$CONFIG_DIR/skyforms-groups-mappers.json"
reconcile_login_client_audience "$SKYFORMS_CLIENT_ID" "$SKYFORMS_CORE_SCOPE_NAME" \
  "$CONFIG_DIR/skyforms-core-audience-mappers.json"
reconcile_account_center_client_scopes "$scope_uuid" "$core_scope_uuid"
reconcile_account_scope_mappings
verify_mailer_client
verify_erasure_client
# Before the admin panel's step, so that a core role created here enters its scope in this run.
reconcile_core_roles
reconcile_skymail_privileged_roles
# Before the admin panel's step too: a forms role created here enters its scope in this run.
reconcile_forms_privileged_roles
# Place's service client first, so that the service-roles step below maps consent:record into its
# role scope in this run.
reconcile_place_service_client
# Also before the admin panel's step: a core service role created here enters its scope in this run.
reconcile_core_service_roles
# Last: a public admin panel client stops the run, and every other step is done by then; core and
# forms roles made by earlier steps are already in place to enter the panel's scope.
reconcile_admin_panel_client

if [[ -n $RESET_OTP_UNGUARDED ]]; then
  printf 'Account Center Keycloak configuration is reconciled except the reset OTP step (%s); fix the subflow in the Admin Console and run again\n' \
    "$RESET_OTP_UNGUARDED" >&2
fi
if [[ -n $EMAIL_CODE_UNGUARDED ]]; then
  printf 'Account Center Keycloak configuration is reconciled except the OTP after the e-mail code (%s); run again with KEYCLOAK_EMAIL_CODE_LOGIN=on (or off), or fix the subflow in the Admin Console\n' \
    "$EMAIL_CODE_UNGUARDED" >&2
fi
if [[ -n $RESET_OTP_UNGUARDED || -n $EMAIL_CODE_UNGUARDED ]]; then
  exit 3
fi
if [[ $CHECK_WRITES == true ]]; then
  printf 'Account Center Keycloak configuration is checked; nothing was written (%s write(s) withheld).\n' "$(check_writes_withheld)"
  exit 0
fi
printf 'Account Center Keycloak configuration is reconciled.\n'
