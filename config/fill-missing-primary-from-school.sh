#!/usr/bin/env bash
# One-off, idempotent operator script (eskylab-login-ux ticket 06, decision O5): an account opened by
# a YTÜ login before Faz 2 has no Primary e-mail (Keycloak email), because MicrosoftMapper removes the
# address from the first login. It cannot get SkyMail announcements, the "forgot password" mail or a
# login code. This script makes its School e-mail the Primary e-mail, as Faz 2 does for new accounts
# (CONTEXT.md, Primary e-mail: "an account opened by a first YTÜ login starts with the School e-mail").
#
# An account is filled only when all four hold:
#   1. Keycloak email is empty;
#   2. the account is linked to the YTÜ Microsoft identity provider (alias OBS);
#   3. schoolEmail is set and a valid address;
#   4. no other account holds that address as email, schoolEmail or personalEmail (compared
#      trimmed and case-insensitively; two accounts with the same schoolEmail block each other).
# The fill: email = schoolEmail trimmed and lowercased (Locale.ROOT), emailVerified = true. The rest of
# the account is written back exactly as it was read, schoolEmail included. Nothing sends mail: the
# script reads users and their identity provider links and updates the user representation, nothing
# else (no execute-actions-email, no send-verify-email). Each write is one Keycloak admin event
# (UPDATE USER) when the realm records admin events; production does (reconcile sets
# adminEventsEnabled=true), and the run says whether they are on.
#
# Every other account without a Primary e-mail is only counted, by the first condition it fails:
# noObsLink, noSchoolEmail, invalidSchoolEmail, taken. Service accounts are not people. A second run
# finds nothing to fill and writes nothing. A realm with registrationEmailAsUsername=true is refused
# (the address would also become the username).
#
# Usage (inside the Keycloak image, or anywhere with its kcadm, JDK and Jackson libraries):
#   fill-missing-primary-from-school.sh --realm <realm> --admin-user <admin>            # dry run (default)
#   fill-missing-primary-from-school.sh --realm <realm> --admin-user <admin> --apply    # writes
#   fill-missing-primary-from-school.sh --realm <realm> --kcadm-config <file> [--apply] [--skipped-list <file>]
# The realm (--realm or KEYCLOAK_REALM) has no default and may only be e-skylab or e-skylab-sandbox;
# any other is refused before the login (exit 2). The administrator password is typed into kcadm's
# own prompt and never passes through this script. Environment: KEYCLOAK_ADMIN_URL (default
# http://keycloak:8080), KEYCLOAK_ADMIN_REALM (default master), KEYCLOAK_FILL_PRIMARY_ADMIN_USERNAME
# (or --admin-user).
#
# Output: "[fill-missing-primary] ..." lines with counts only, never an address, a username or an id.
# --skipped-list <file> writes "class<TAB>username<TAB>id" per skipped account to a new file of mode
# 0600 (an existing file is refused) for a manual decision; the terminal still shows counts only.
# Exit 0 when the run did what it reports; 1 when the realm is missing or refused, a read failed, or an
# apply left a write undone (rerun with --apply: filled accounts are not written again); 2 on a usage
# error or a refused realm name.
set -Eeuo pipefail
shopt -s inherit_errexit

umask 077

KCADM=${KCADM_BIN:-/opt/keycloak/bin/kcadm.sh}
JAVA_BIN=${JAVA_BIN:-java}
KEYCLOAK_LIB_DIR=${KEYCLOAK_LIB_DIR:-/opt/keycloak/lib/lib/main}
ADMIN_URL=${KEYCLOAK_ADMIN_URL:-http://keycloak:8080}
ADMIN_REALM=${KEYCLOAK_ADMIN_REALM:-master}
TARGET_REALM=${KEYCLOAK_REALM:-}
ADMIN_USER=${KEYCLOAK_FILL_PRIMARY_ADMIN_USERNAME:-}
ALLOWED_REALMS=(e-skylab e-skylab-sandbox)
# The YTÜ Microsoft identity provider (config/identity-guardrails.sh YTU_IDP_ALIAS).
YTU_IDP_ALIAS=OBS
PAGE_SIZE=100
KCADM_CONFIG=''
OWN_CONFIG=false
MODE=dry-run
SKIPPED_LIST=''

usage() {
  printf 'usage: %s --realm (e-skylab|e-skylab-sandbox) (--admin-user <administrator> | --kcadm-config <file>) [--dry-run | --apply] [--skipped-list <new file>]\n' \
    "${BASH_SOURCE[0]##*/}" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --realm)
      [[ $# -ge 2 ]] || usage
      TARGET_REALM=$2
      shift 2
      ;;
    --admin-user)
      [[ $# -ge 2 ]] || usage
      ADMIN_USER=$2
      shift 2
      ;;
    --kcadm-config)
      [[ $# -ge 2 ]] || usage
      KCADM_CONFIG=$2
      shift 2
      ;;
    --skipped-list)
      [[ $# -ge 2 && -n $2 ]] || usage
      SKIPPED_LIST=$2
      shift 2
      ;;
    --apply)
      MODE=apply
      shift
      ;;
    --dry-run)
      MODE=dry-run
      shift
      ;;
    *)
      usage
      ;;
  esac
done

log() {
  printf '[fill-missing-primary] %s\n' "$1"
}

allowed=false
for realm in "${ALLOWED_REALMS[@]}"; do
  [[ $TARGET_REALM == "$realm" ]] && allowed=true
done
if [[ $allowed != true ]]; then
  printf '[fill-missing-primary] refusing realm %s: only %s; nothing was read or changed\n' \
    "${TARGET_REALM:-(unset)}" "${ALLOWED_REALMS[*]}" >&2
  exit 2
fi

if [[ -n $SKIPPED_LIST && ( -e $SKIPPED_LIST || -L $SKIPPED_LIST ) ]]; then
  printf '[fill-missing-primary] refusing to overwrite %s: give --skipped-list a new file; nothing was read or changed\n' \
    "$SKIPPED_LIST" >&2
  exit 2
fi

if [[ -z $KCADM_CONFIG ]]; then
  if [[ -z $ADMIN_USER ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Keycloak administrator username: " ADMIN_USER
    fi
    [[ -n $ADMIN_USER ]] || usage
  fi
  KCADM_CONFIG=$(mktemp /tmp/fill-missing-primary-kcadm.XXXXXX)
  OWN_CONFIG=true
elif [[ ! -r $KCADM_CONFIG ]]; then
  printf 'kcadm config %s is not readable\n' "$KCADM_CONFIG" >&2
  exit 2
fi

# Every file below holds addresses and ids; the directory is private (umask) and removed on exit.
WORK_DIR=$(mktemp -d /tmp/fill-missing-primary.XXXXXX)
cleanup() {
  rm -rf "$WORK_DIR"
  if [[ $OWN_CONFIG == true ]]; then
    rm -f "$KCADM_CONFIG"
  fi
}
trap cleanup EXIT

kcadm() {
  local command=$1
  shift
  "$KCADM" "$command" --config "$KCADM_CONFIG" "$@" </dev/null
}

# The selection and the write run in Java with the image's JDK and Keycloak's own Jackson libraries:
# the image has no jq. The source travels inside this script, so the script alone is the whole tool
# (the wizard copies one file) and no Keycloak release is needed to run it.
write_helper() {
  cat >"$1" <<'JAVA'
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.EnumMap;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Selection and write of fill-missing-primary-from-school.sh (see its header). Reads Admin REST
 * representations from files; prints counts only. Addresses, usernames and ids leave it only
 * through the files the script names.
 */
public final class FillMissingPrimary {

    /** {@code fill}: the account no longer qualifies (it changed since the scan). */
    static final int EXIT_NOT_ELIGIBLE = 3;
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final String SCHOOL_EMAIL = "schoolEmail";
    private static final String PERSONAL_EMAIL = "personalEmail";
    private static final String SERVICE_ACCOUNT_PREFIX = "service-account-";
    private static final long RECENT_MILLIS = 30L * 24 * 60 * 60 * 1000;
    // Narrower than Keycloak's own rule (no quoted local part, ASCII only): an address it refuses is
    // counted as invalidSchoolEmail and never written, so a write never fails on the address itself.
    private static final String ATOM = "[a-z0-9!#$%&'*+/=?^_`{|}~-]+";
    private static final String LABEL = "[a-z0-9](?:[a-z0-9-]*[a-z0-9])?";
    private static final Pattern ADDRESS =
            Pattern.compile(ATOM + "(?:\\." + ATOM + ")*@" + LABEL + "(?:\\." + LABEL + ")+");

    enum Verdict { FILL, NO_OBS_LINK, NO_SCHOOL_EMAIL, INVALID_SCHOOL_EMAIL, TAKEN }

    private FillMissingPrimary() {
    }

    public static void main(String[] args) throws IOException {
        PrintStream out = new PrintStream(System.out, true, StandardCharsets.UTF_8);
        System.exit(run(args, out));
    }

    static int run(String[] args, PrintStream out) throws IOException {
        if (args.length == 0) {
            return usage();
        }
        switch (args[0]) {
            case "count" -> {
                out.println(JSON.readTree(System.in).size());
                return 0;
            }
            case "realm" -> {
                JsonNode realm = JSON.readTree(System.in);
                out.printf("adminEventsEnabled=%s registrationEmailAsUsername=%s%n",
                        realm.path("adminEventsEnabled").asBoolean(false),
                        realm.path("registrationEmailAsUsername").asBoolean(false));
                return 0;
            }
            case "empty" -> {
                for (JsonNode user : pages(args, 1)) {
                    if (!isServiceAccount(user) && text(user, "email") == null) {
                        out.println(user.path("id").asText());
                    }
                }
                return 0;
            }
            case "plan" -> {
                if (args.length < 5) {
                    return usage();
                }
                return plan(args[1], Path.of(args[2]), Path.of(args[3]), Path.of(args[4]), pages(args, 5), out);
            }
            case "fill" -> {
                if (args.length != 5) {
                    return usage();
                }
                JsonNode user = JSON.readTree(Path.of(args[3]).toFile());
                JsonNode links = JSON.readTree(Path.of(args[4]).toFile());
                String address = args[1];
                if (isServiceAccount(user) || text(user, "email") != null || !linked(links, args[2])
                        || !address.equals(schoolAddress(user)) || !valid(address)) {
                    return EXIT_NOT_ELIGIBLE;
                }
                ObjectNode filled = user.deepCopy();
                filled.put("email", address);
                filled.put("emailVerified", true);
                out.println(JSON.writeValueAsString(filled));
                return 0;
            }
            default -> {
                return usage();
            }
        }
    }

    private static int plan(String idp, Path linkDirectory, Path fillFile, Path skippedFile, List<JsonNode> users,
                            PrintStream out) throws IOException {
        // Who holds which address, in any of the three places, by id; service accounts included.
        Map<String, Set<String>> holders = new HashMap<>();
        for (JsonNode user : users) {
            String id = user.path("id").asText();
            hold(holders, text(user, "email"), id);
            for (String attribute : List.of(SCHOOL_EMAIL, PERSONAL_EMAIL)) {
                for (JsonNode value : user.path("attributes").path(attribute)) {
                    hold(holders, value.isTextual() ? value.asText() : null, id);
                }
            }
        }

        int people = 0;
        int serviceAccounts = 0;
        int primaryEmpty = 0;
        int recent = 0;
        long now = System.currentTimeMillis();
        Map<Verdict, Integer> counts = new EnumMap<>(Verdict.class);
        for (Verdict verdict : Verdict.values()) {
            counts.put(verdict, 0);
        }
        StringBuilder fills = new StringBuilder();
        StringBuilder skipped = new StringBuilder();
        for (JsonNode user : users) {
            if (isServiceAccount(user)) {
                serviceAccounts++;
                continue;
            }
            people++;
            if (text(user, "email") != null) {
                continue;
            }
            primaryEmpty++;
            long created = user.path("createdTimestamp").asLong(0);
            if (created > 0 && now - created <= RECENT_MILLIS) {
                recent++;
            }
            String id = user.path("id").asText();
            String address = schoolAddress(user);
            Path linkFile = linkDirectory.resolve(id + ".json");
            Verdict verdict;
            if (!Files.isRegularFile(linkFile) || !linked(JSON.readTree(linkFile.toFile()), idp)) {
                verdict = Verdict.NO_OBS_LINK;
            } else if (address == null) {
                verdict = Verdict.NO_SCHOOL_EMAIL;
            } else if (!valid(address)) {
                verdict = Verdict.INVALID_SCHOOL_EMAIL;
            } else if (holders.getOrDefault(address, Set.of()).stream().anyMatch(holder -> !holder.equals(id))) {
                verdict = Verdict.TAKEN;
            } else {
                verdict = Verdict.FILL;
            }
            counts.merge(verdict, 1, Integer::sum);
            if (verdict == Verdict.FILL) {
                fills.append(id).append('\t').append(address).append('\n');
            } else {
                skipped.append(className(verdict)).append('\t')
                        .append(user.path("username").asText()).append('\t').append(id).append('\n');
            }
        }
        Files.writeString(fillFile, fills, StandardCharsets.UTF_8);
        Files.writeString(skippedFile, skipped, StandardCharsets.UTF_8);
        out.printf("people=%d serviceAccounts=%d primaryEmpty=%d recent=%d%n", people, serviceAccounts, primaryEmpty, recent);
        out.printf("fill=%d noObsLink=%d noSchoolEmail=%d invalidSchoolEmail=%d taken=%d%n",
                counts.get(Verdict.FILL), counts.get(Verdict.NO_OBS_LINK), counts.get(Verdict.NO_SCHOOL_EMAIL),
                counts.get(Verdict.INVALID_SCHOOL_EMAIL), counts.get(Verdict.TAKEN));
        return 0;
    }

    private static String className(Verdict verdict) {
        return switch (verdict) {
            case NO_OBS_LINK -> "noObsLink";
            case NO_SCHOOL_EMAIL -> "noSchoolEmail";
            case INVALID_SCHOOL_EMAIL -> "invalidSchoolEmail";
            case TAKEN -> "taken";
            case FILL -> "fill";
        };
    }

    /** The first schoolEmail value, trimmed and lowercased; null when absent or blank. */
    static String schoolAddress(JsonNode user) {
        JsonNode values = user.path("attributes").path(SCHOOL_EMAIL);
        if (!values.isArray() || values.isEmpty() || !values.get(0).isTextual()) {
            return null;
        }
        String value = normalise(values.get(0).asText());
        return value.isEmpty() ? null : value;
    }

    static boolean valid(String address) {
        int at = address.lastIndexOf('@');
        return address.length() <= 255 && at > 0 && at <= 64 && ADDRESS.matcher(address).matches();
    }

    static boolean linked(JsonNode links, String idp) {
        for (JsonNode link : links) {
            if (idp.equals(link.path("identityProvider").asText())) {
                return true;
            }
        }
        return false;
    }

    private static String normalise(String address) {
        return address.trim().toLowerCase(Locale.ROOT);
    }

    private static void hold(Map<String, Set<String>> holders, String address, String id) {
        if (address != null && !address.isBlank()) {
            holders.computeIfAbsent(normalise(address), key -> new HashSet<>()).add(id);
        }
    }

    private static boolean isServiceAccount(JsonNode user) {
        return text(user, "serviceAccountClientId") != null
                || user.path("username").asText("").startsWith(SERVICE_ACCOUNT_PREFIX);
    }

    private static String text(JsonNode node, String field) {
        JsonNode value = node.get(field);
        if (value == null || !value.isTextual() || value.asText().isBlank()) {
            return null;
        }
        return value.asText();
    }

    private static List<JsonNode> pages(String[] args, int from) throws IOException {
        List<JsonNode> users = new ArrayList<>();
        for (int index = from; index < args.length; index++) {
            JSON.readTree(Path.of(args[index]).toFile()).forEach(users::add);
        }
        return users;
    }

    private static int usage() {
        System.err.println("usage: FillMissingPrimary count | realm | empty PAGE... | plan IDP LINKS FILLS SKIPPED PAGE..."
                + " | fill ADDRESS IDP USER LINKS");
        return 2;
    }
}
JAVA
}

jackson_jars=("$KEYCLOAK_LIB_DIR"/com.fasterxml.jackson.core.jackson-*.jar)
if [[ ! -f ${jackson_jars[0]} ]]; then
  printf 'Jackson libraries were not found under %s; run this inside the Keycloak image\n' "$KEYCLOAK_LIB_DIR" >&2
  exit 1
fi
classpath=$(IFS=:; printf '%s' "${jackson_jars[*]}")
write_helper "$WORK_DIR/FillMissingPrimary.java"
if ! "$JAVA_BIN" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -m jdk.compiler/com.sun.tools.javac.Main \
  -d "$WORK_DIR/classes" -cp "$classpath" "$WORK_DIR/FillMissingPrimary.java" >/dev/null; then
  printf 'The selection code could not be compiled with %s; run this inside the Keycloak image\n' "$JAVA_BIN" >&2
  exit 1
fi

helper() {
  "$JAVA_BIN" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -cp "$WORK_DIR/classes:$classpath" FillMissingPrimary "$@"
}

credential_arguments=(
  --config "$KCADM_CONFIG"
  --server "$ADMIN_URL"
  --realm "$ADMIN_REALM"
  --user "$ADMIN_USER"
)
if [[ $OWN_CONFIG == true ]]; then
  # No redirection: kcadm asks for the password only when stdout is a terminal ("Console is not
  # active" otherwise). Its "Logging into" line goes to stderr, so stdout stays clean either way.
  "$KCADM" config credentials "${credential_arguments[@]}"
fi
log "realm=$TARGET_REALM mode=$MODE"

if ! kcadm get "realms/$TARGET_REALM" >"$WORK_DIR/realm.json" 2>/dev/null; then
  log "realm $TARGET_REALM does not exist or cannot be read; nothing was changed"
  exit 1
fi
realm_settings=" $(helper realm <"$WORK_DIR/realm.json") "
if [[ $realm_settings != *' registrationEmailAsUsername=false '* ]]; then
  log "realm $TARGET_REALM has registrationEmailAsUsername=true: the address would also become the username; nothing was changed"
  exit 1
fi
if [[ $realm_settings == *' adminEventsEnabled=true '* ]]; then
  log 'admin events: on (every write leaves an UPDATE USER admin event)'
else
  log 'admin events: OFF (writes would leave no admin event; production has them on)'
fi

if kcadm get "identity-provider/instances/$YTU_IDP_ALIAS" -r "$TARGET_REALM" >/dev/null 2>"$WORK_DIR/idp.stderr"; then
  idp_present=true
  log "identity provider $YTU_IDP_ALIAS: present"
elif grep -qi 'not found' "$WORK_DIR/idp.stderr"; then
  idp_present=false
  log "identity provider $YTU_IDP_ALIAS: absent (no account can be linked to it, so none is filled)"
else
  cat "$WORK_DIR/idp.stderr" >&2
  printf 'The identity provider %s of realm %s could not be read; nothing was changed\n' "$YTU_IDP_ALIAS" "$TARGET_REALM" >&2
  exit 1
fi

# scan DIR: every user of the realm (full representations) into DIR/page-*.json, the identity
# provider links of every person without a Primary e-mail into DIR/links/<id>.json, then the plan:
# DIR/fill.tsv ("id<TAB>address"), DIR/skipped.tsv ("class<TAB>username<TAB>id") and the counts below.
scan() {
  local directory=$1 first=0 page count user_id counts line
  mkdir -p "$directory/links"
  while :; do
    page="$directory/page-$first.json"
    if ! kcadm get users -r "$TARGET_REALM" -q "first=$first" -q "max=$PAGE_SIZE" \
      -q briefRepresentation=false >"$page" 2>"$WORK_DIR/scan.stderr"; then
      cat "$WORK_DIR/scan.stderr" >&2
      printf 'Failed to read the users of realm %s\n' "$TARGET_REALM" >&2
      return 1
    fi
    count=$(helper count <"$page")
    if (( count < PAGE_SIZE )); then
      break
    fi
    first=$((first + PAGE_SIZE))
  done
  if [[ $idp_present == true ]]; then
    helper empty "$directory"/page-*.json >"$directory/empty.ids"
    while IFS= read -r user_id; do
      [[ $user_id =~ ^[A-Za-z0-9-]+$ ]] || {
        printf 'Unexpected user id format in realm %s\n' "$TARGET_REALM" >&2
        return 1
      }
      if ! kcadm get "users/$user_id/federated-identity" -r "$TARGET_REALM" \
        >"$directory/links/$user_id.json" 2>"$WORK_DIR/scan.stderr"; then
        cat "$WORK_DIR/scan.stderr" >&2
        printf 'Failed to read the identity provider links of a user of realm %s\n' "$TARGET_REALM" >&2
        return 1
      fi
    done <"$directory/empty.ids"
  fi
  counts=$(helper plan "$YTU_IDP_ALIAS" "$directory/links" "$directory/fill.tsv" "$directory/skipped.tsv" \
    "$directory"/page-*.json)
  people='' service_accounts='' primary_empty='' recent='' fill='' no_obs='' no_school='' invalid_school='' taken=''
  for line in $counts; do
    case ${line%%=*} in
      people) people=${line#*=} ;;
      serviceAccounts) service_accounts=${line#*=} ;;
      primaryEmpty) primary_empty=${line#*=} ;;
      recent) recent=${line#*=} ;;
      fill) fill=${line#*=} ;;
      noObsLink) no_obs=${line#*=} ;;
      noSchoolEmail) no_school=${line#*=} ;;
      invalidSchoolEmail) invalid_school=${line#*=} ;;
      taken) taken=${line#*=} ;;
    esac
  done
  [[ -n $people && -n $primary_empty && -n $fill && -n $taken ]] || {
    printf 'The plan could not be read\n' >&2
    return 1
  }
}

scan "$WORK_DIR/before"
log "users scanned=$people (service accounts skipped=$service_accounts) primaryEmpty=$primary_empty (opened in the last 30 days=$recent)"
log "primary empty: fill=$fill noObsLink=$no_obs noSchoolEmail=$no_school invalidSchoolEmail=$invalid_school taken=$taken"
planned=$fill

if [[ -n $SKIPPED_LIST ]]; then
  if ! (set -o noclobber && cat "$WORK_DIR/before/skipped.tsv" >"$SKIPPED_LIST") 2>/dev/null; then
    printf 'Could not create %s for the skipped list; nothing was changed\n' "$SKIPPED_LIST" >&2
    exit 1
  fi
  chmod 600 "$SKIPPED_LIST"
  log "skipped list: $(grep -c . "$SKIPPED_LIST" || true) line(s) in $SKIPPED_LIST (mode 0600: class, username, id)"
fi

# failure_reason STDERR_FILE: a class for a failed read or write. kcadm's own text may name the user
# and is never printed.
failure_reason() {
  if grep -Eqi '\b(401|403)\b|forbidden|unauthorized' "$1"; then
    printf 'forbidden'
  elif grep -Eqi '\b409\b|conflict|exists with same' "$1"; then
    printf 'conflict'
  elif grep -Eqi '\b400\b|bad request|invalid|error-' "$1"; then
    printf 'invalid'
  else
    printf 'other'
  fi
}

applied=0
failed=0
changed=0
declare -A failures=([forbidden]=0 [conflict]=0 [invalid]=0 [other]=0)
record_failure() {
  local reason
  reason=$(failure_reason "$WORK_DIR/write.stderr")
  failures[$reason]=$((failures[$reason] + 1))
  failed=$((failed + 1))
}

if [[ $MODE == apply ]]; then
  while IFS=$'\t' read -r user_id address; do
    [[ -n $user_id && -n $address ]] || continue
    # Read again right before the write: the account is filled only if it still qualifies.
    if ! kcadm get "users/$user_id" -r "$TARGET_REALM" >"$WORK_DIR/user.json" 2>"$WORK_DIR/write.stderr" \
      || ! kcadm get "users/$user_id/federated-identity" -r "$TARGET_REALM" >"$WORK_DIR/links.json" 2>"$WORK_DIR/write.stderr"; then
      record_failure
      continue
    fi
    status=0
    helper fill "$address" "$YTU_IDP_ALIAS" "$WORK_DIR/user.json" "$WORK_DIR/links.json" \
      >"$WORK_DIR/filled.json" 2>"$WORK_DIR/write.stderr" || status=$?
    if [[ $status == 3 ]]; then
      changed=$((changed + 1))
      continue
    elif [[ $status != 0 ]]; then
      record_failure
      continue
    fi
    if kcadm update "users/$user_id" -r "$TARGET_REALM" -n -f "$WORK_DIR/filled.json" >/dev/null 2>"$WORK_DIR/write.stderr"; then
      applied=$((applied + 1))
    else
      record_failure
    fi
  done <"$WORK_DIR/before/fill.tsv"
  rm -f "$WORK_DIR/user.json" "$WORK_DIR/links.json" "$WORK_DIR/filled.json" "$WORK_DIR/write.stderr"

  log "applied $applied fill(s); failed=$failed changedSinceScan=$changed"
  if (( failed > 0 )); then
    log "failed by reason: forbidden=${failures[forbidden]} conflict=${failures[conflict]} invalid=${failures[invalid]} other=${failures[other]}"
  fi
  # Read back: every fill must have persisted, so a new scan finds nothing left to fill.
  scan "$WORK_DIR/after"
  log "after: primaryEmpty=$primary_empty toFill=$fill noObsLink=$no_obs noSchoolEmail=$no_school invalidSchoolEmail=$invalid_school taken=$taken"
fi

if (( taken > 0 )); then
  log "$taken account(s) were skipped because another account holds the school address; they need a manual decision"
fi
if (( no_school + invalid_school > 0 )); then
  log "$((no_school + invalid_school)) linked account(s) have no usable school address and stay without a Primary e-mail"
fi
if (( no_obs > 0 )); then
  log "$no_obs account(s) without a Primary e-mail are not linked to $YTU_IDP_ALIAS and are not filled"
fi
if [[ $MODE == apply ]]; then
  if (( failed > 0 || fill > 0 )); then
    printf 'The fill is incomplete: %s write(s) failed and %s account(s) are still to fill. Check that the administrator holds manage-users for realm %s and rerun with --apply; filled accounts are not written again.\n' \
      "$failed" "$fill" "$TARGET_REALM" >&2
    exit 1
  fi
else
  log "dry run: $planned account(s) to fill; rerun with --apply to execute them"
fi
