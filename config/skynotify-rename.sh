#!/usr/bin/env bash
# One-off, idempotent operator script (sky_lab_genel .scratch/skynotify-ad ticket 07; e-skylab ADR
# 0091): renames SkyMail's Keycloak objects to SkyNotify in place, in one realm. The window runs it
# for the sandbox realm (step S6, no image release) and for the production realm while the old image
# is still up (step P4, before the one Keycloak deploy that brings the skynotify SPI and the new
# reconciler). --reverse is the rollback (spec §4, step 3): the same objects back to the old names.
#
# What is renamed (every object found by name, ids kept, nothing created or deleted):
#   - clients skymail, skymail-backend and skymail-seed -> skynotify, skynotify-backend,
#     skynotify-seed: the client id and every text field of the client (name, description, URLs,
#     attributes). The uuid, the secret, the service account user and every role mapping stay;
#     Keycloak renames the service account user (service-account-<clientId>) with the client;
#   - client roles skymail:* -> skynotify:* (and any realm or client role whose name or text names
#     SkyMail), with their descriptions and attributes; the role id is kept, so every mapping (users,
#     groups, composites, scope mappings) stays;
#   - client scopes skymail-api-audience, account-api-skymail-audience, account-erase-skymail and any
#     other whose name or text names SkyMail;
#   - protocol mappers of every client and client scope whose name or config names SkyMail (for
#     example included.client.audience=skymail of the Audience mappers);
#   - groups whose name names SkyMail (/ROLLER/SKYMAIL-* -> /ROLLER/SKYNOTIFY-*), with their
#     description and attributes (display_name_tr, description_tr).
# The text rule is the repository's: SkyMail -> SkyNotify, SKYMAIL -> SKYNOTIFY, skymail ->
# skynotify, and a Turkish suffix after the apostrophe follows the new name's vowels (SkyMail'e ->
# SkyNotify'a, SkyMail'in -> SkyNotify'ın); --reverse is the exact inverse. Out of scope (spec §1):
# the User Profile attribute skyMail and its label "SkyMail adresi (eski)" are never touched. Groups
# are found by name (Keycloak's group search); a group whose name does not name SkyMail is not read.
#
# Before anything is written every object is read and checked; a PROBLEM stops the run with nothing
# written: an object that names both the old and the new name, a spelling the rule cannot invert
# (sky-mail, sky_mail, Skymail ...), a new name another object of the same kind already holds, a text
# longer than Keycloak keeps (255 characters) after the rename, or a person (not a service account)
# whose username names SkyMail. The dry run (the default) prints every rename and, per renamed role,
# the users and groups that hold it. --apply writes, reads everything again and requires: nothing
# left to rename, no service account user with the old name and, per role id, the same number of
# holding users and groups as before. A second run finds nothing to rename and writes nothing; a run
# cut short is completed by running it again.
#
# Usage (inside the Keycloak image, old or new: the script needs only kcadm, the JDK and Keycloak's
# Jackson libraries, so the wizard copies this one file into the running container):
#   skynotify-rename.sh --realm <realm> --admin-user <admin>                    # dry run (default)
#   skynotify-rename.sh --realm <realm> --admin-user <admin> --apply            # renames
#   skynotify-rename.sh --realm <realm> --kcadm-config <file> [--apply] [--reverse]
# The realm (--realm or KEYCLOAK_REALM) has no default and may only be e-skylab or e-skylab-sandbox;
# any other is refused before the login (exit 2). The administrator password is typed into kcadm's
# own prompt and never passes through this script. Environment: KEYCLOAK_ADMIN_URL (default
# http://keycloak:8080), KEYCLOAK_ADMIN_REALM (default master), KEYCLOAK_SKYNOTIFY_RENAME_ADMIN_USERNAME
# (or --admin-user).
#
# Output: "[skynotify-rename] ..." lines with object names (configuration), counts, and the user names
# of service accounts; never a person's name, address or id.
# Exit 0 when the run did what it reports; 1 on a PROBLEM, a failed read or write, or a check after
# --apply that does not hold (rerun with --apply: renamed objects are not written again); 2 on a usage
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
ADMIN_USER=${KEYCLOAK_SKYNOTIFY_RENAME_ADMIN_USERNAME:-}
ALLOWED_REALMS=(e-skylab e-skylab-sandbox)
KCADM_CONFIG=''
OWN_CONFIG=false
MODE=dry-run
DIRECTION=forward

usage() {
  printf 'usage: %s --realm (e-skylab|e-skylab-sandbox) (--admin-user <administrator> | --kcadm-config <file>) [--dry-run | --apply] [--reverse]\n' \
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
    --apply)
      MODE=apply
      shift
      ;;
    --dry-run)
      MODE=dry-run
      shift
      ;;
    --reverse)
      DIRECTION=reverse
      shift
      ;;
    *)
      usage
      ;;
  esac
done

log() {
  printf '[skynotify-rename] %s\n' "$1"
}

allowed=false
for realm in "${ALLOWED_REALMS[@]}"; do
  [[ $TARGET_REALM == "$realm" ]] && allowed=true
done
if [[ $allowed != true ]]; then
  printf '[skynotify-rename] refusing realm %s: only %s; nothing was read or changed\n' \
    "${TARGET_REALM:-(unset)}" "${ALLOWED_REALMS[*]}" >&2
  exit 2
fi

if [[ $DIRECTION == forward ]]; then
  OLD_TOKEN=skymail
  NEW_TOKEN=skynotify
else
  OLD_TOKEN=skynotify
  NEW_TOKEN=skymail
fi

if [[ -z $KCADM_CONFIG ]]; then
  if [[ -z $ADMIN_USER ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Keycloak administrator username: " ADMIN_USER
    fi
    [[ -n $ADMIN_USER ]] || usage
  fi
  KCADM_CONFIG=$(mktemp /tmp/skynotify-rename-kcadm.XXXXXX)
  OWN_CONFIG=true
elif [[ ! -r $KCADM_CONFIG ]]; then
  printf 'kcadm config %s is not readable\n' "$KCADM_CONFIG" >&2
  exit 2
fi

# The files below hold client secrets (Keycloak's client list carries them); the directory is
# private (umask) and removed on exit. Nothing from it is printed but names and counts.
WORK_DIR=$(mktemp -d /tmp/skynotify-rename.XXXXXX)
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

# The plan runs in Java with the image's JDK and Keycloak's own Jackson libraries: the image has no
# jq. The source travels inside this script, so the script alone is the whole tool (the wizard copies
# one file into the old image) and no Keycloak release is needed to run it.
write_helper() {
  cat >"$1" <<'JAVA'
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * The plan of skynotify-rename.sh (see its header). Reads Admin REST representations from files and
 * prints tab-separated lines:
 *   unit KIND PATH BODY_FILE LABEL   one PUT that renames one object (BODY_FILE holds its body)
 *   done KIND LABEL                  an object that already carries the new name only
 *   count PATH ROLE_ID LABEL         a renamed (or already renamed) role whose holders are counted
 *   problem TEXT                     a reason not to write anything
 */
public final class SkynotifyRename {

    private static final ObjectMapper JSON = new ObjectMapper();
    private static final int KEPT_LENGTH = 255;
    // Out of scope (spec §1): the User Profile attribute skyMail and its label.
    private static final Pattern PROTECTED = Pattern.compile("SkyMail adresi \\(eski\\)|\\bskyMail\\b");
    private static final Pattern MAIL_ANY = Pattern.compile("(?i)sky[-_ .]?mail");
    private static final Pattern NOTIFY_ANY = Pattern.compile("(?i)sky[-_ .]?notify");
    private static final Set<String> MAIL_FORMS = Set.of("SkyMail", "SKYMAIL", "skymail");
    private static final Set<String> NOTIFY_FORMS = Set.of("SkyNotify", "SKYNOTIFY", "skynotify");
    private static final Map<String, String> FRONT_TO_BACK = new LinkedHashMap<>();
    private static final Map<String, String> BACK_TO_FRONT = new LinkedHashMap<>();

    static {
        String[][] suffixes = {
            {"inkiler", "ınkiler"}, {"inden", "ından"}, {"indir", "ındır"}, {"inde", "ında"},
            {"ine", "ına"}, {"ini", "ını"}, {"dedir", "dadır"}, {"deki", "daki"}, {"den", "dan"},
            {"dir", "dır"}, {"ten", "tan"}, {"ler", "lar"}, {"in", "ın"}, {"de", "da"}, {"le", "la"},
            {"te", "ta"}, {"e", "a"}, {"i", "ı"}};
        for (String[] pair : suffixes) {
            FRONT_TO_BACK.put(pair[0], pair[1]);
            BACK_TO_FRONT.put(pair[1], pair[0]);
        }
    }

    private final boolean forward;
    private final Pattern oldAny;
    private final Pattern newAny;
    private final Set<String> oldForms;
    private final List<String> units = new ArrayList<>();
    private final List<String> done = new ArrayList<>();
    private final List<String> counts = new ArrayList<>();
    private final List<String> problems = new ArrayList<>();
    private final Path workDir;
    private int bodies;

    private SkynotifyRename(boolean forward, Path workDir) {
        this.forward = forward;
        this.workDir = workDir;
        this.oldAny = forward ? MAIL_ANY : NOTIFY_ANY;
        this.newAny = forward ? NOTIFY_ANY : MAIL_ANY;
        this.oldForms = forward ? MAIL_FORMS : NOTIFY_FORMS;
    }

    public static void main(String[] args) throws IOException {
        PrintStream out = new PrintStream(System.out, true, StandardCharsets.UTF_8);
        if (args.length < 1) {
            System.exit(usage());
        }
        switch (args[0]) {
            case "plan" -> {
                if (args.length != 3) {
                    System.exit(usage());
                }
                SkynotifyRename plan = new SkynotifyRename("forward".equals(args[1]), Path.of(args[2]));
                plan.run();
                plan.units.forEach(out::println);
                plan.done.forEach(out::println);
                plan.counts.forEach(out::println);
                plan.problems.forEach(out::println);
            }
            case "ids" -> {
                for (JsonNode node : read(Path.of(args[1]))) {
                    out.println(node.path("id").asText());
                }
            }
            case "count" -> out.println(read(Path.of(args[1])).size());
            case "group-ids" -> {
                // args: TOKEN... then files; prints the id of every group in the trees whose name
                // names one of the tokens (case-insensitive).
                Set<String> ids = new LinkedHashSet<>();
                for (int i = 1; i < args.length; i++) {
                    collectGroups(read(Path.of(args[i])), ids);
                }
                ids.forEach(out::println);
            }
            case "users" -> {
                // Usernames that name a token: service accounts by name, people as a count.
                Set<String> accounts = new LinkedHashSet<>();
                Set<String> people = new LinkedHashSet<>();
                for (int i = 1; i < args.length; i++) {
                    for (JsonNode user : read(Path.of(args[i]))) {
                        String username = user.path("username").asText();
                        if (!MAIL_ANY.matcher(strip(username)).find() && !NOTIFY_ANY.matcher(username).find()) {
                            continue;
                        }
                        if (user.hasNonNull("serviceAccountClientId") || username.startsWith("service-account-")) {
                            accounts.add(username);
                        } else {
                            people.add(user.path("id").asText());
                        }
                    }
                }
                accounts.forEach(name -> out.println("account\t" + name));
                out.println("people\t" + people.size());
            }
            default -> System.exit(usage());
        }
    }

    private static void collectGroups(JsonNode groups, Set<String> ids) {
        for (JsonNode group : groups) {
            String name = group.path("name").asText();
            if (MAIL_ANY.matcher(strip(name)).find() || NOTIFY_ANY.matcher(name).find()) {
                ids.add(group.path("id").asText());
            }
            collectGroups(group.path("subGroups"), ids);
        }
    }

    private void run() throws IOException {
        JsonNode clients = read(workDir.resolve("clients.json"));
        JsonNode scopes = read(workDir.resolve("client-scopes.json"));
        JsonNode realmRoles = read(workDir.resolve("realm-roles.json"));
        List<String> clientUnits = new ArrayList<>();
        List<String> roleUnits = new ArrayList<>();
        List<String> scopeUnits = new ArrayList<>();
        List<String> mapperUnits = new ArrayList<>();
        List<String> groupUnits = new ArrayList<>();

        Map<String, String> clientIds = new HashMap<>();
        for (JsonNode client : clients) {
            clientIds.put(client.path("id").asText(), client.path("clientId").asText());
        }
        // Clients: the core fields, then their mappers and roles.
        Set<String> takenClientIds = new LinkedHashSet<>(clientIds.values());
        for (JsonNode client : clients) {
            String id = client.path("id").asText();
            String clientId = client.path("clientId").asText();
            ObjectNode body = JSON.createObjectNode();
            List<String> fields = new ArrayList<>();
            Scan scan = new Scan();
            for (String field : List.of("clientId", "name", "description", "rootUrl", "baseUrl", "adminUrl")) {
                JsonNode value = client.get(field);
                if (value != null && value.isTextual()) {
                    scan.add(value.asText(), field);
                    String renamed = rename(value.asText());
                    if (!renamed.equals(value.asText())) {
                        body.put(field, renamed);
                        fields.add(field);
                        if (!"clientId".equals(field) && !field.endsWith("Url")) {
                            scan.limit(renamed, field);
                        }
                    }
                }
            }
            for (String field : List.of("redirectUris", "webOrigins")) {
                JsonNode values = client.get(field);
                if (values != null && values.isArray()) {
                    ArrayNode renamed = JSON.createArrayNode();
                    boolean changed = false;
                    for (JsonNode value : values) {
                        scan.add(value.asText(), field);
                        String text = rename(value.asText());
                        changed |= !text.equals(value.asText());
                        renamed.add(text);
                    }
                    if (changed) {
                        body.set(field, renamed);
                        fields.add(field);
                    }
                }
            }
            JsonNode attributes = client.get("attributes");
            if (attributes != null && attributes.isObject()) {
                ObjectNode renamed = JSON.createObjectNode();
                boolean changed = false;
                for (Map.Entry<String, JsonNode> entry : attributes.properties()) {
                    String text = entry.getValue().asText();
                    scan.add(text, "attributes." + entry.getKey());
                    String value = rename(text);
                    changed |= !value.equals(text);
                    renamed.put(entry.getKey(), value);
                }
                if (changed) {
                    body.set("attributes", renamed);
                    fields.add("attributes");
                }
            }
            String newClientId = rename(clientId);
            String label = "client " + clientId + (newClientId.equals(clientId) ? "" : " -> " + newClientId);
            if (classify(scan, label)) {
                if (!newClientId.equals(clientId) && takenClientIds.contains(newClientId)) {
                    problems.add("problem\tclient " + newClientId + " already exists next to " + clientId
                            + ": the two cannot be one; nothing was changed");
                }
                body.put("clientId", newClientId);
                clientUnits.add(unit("client", "clients/" + id, body,
                        label + " (" + String.join(" ", fields) + "; uuid, secret and service account kept)"));
            } else if (scan.hasNew) {
                done.add("done\tclient\t" + label);
            }
            mappers(client.get("protocolMappers"), "clients/" + id, "client " + clientId, mapperUnits);
            JsonNode roles = readOptional(workDir.resolve("roles").resolve(id + ".json"));
            roles(roles, "clients/" + id + "/roles/", "client " + clientId, roleUnits);
        }
        roles(realmRoles, "roles/", "realm", roleUnits);

        Set<String> takenScopes = new LinkedHashSet<>();
        for (JsonNode scope : scopes) {
            takenScopes.add(scope.path("name").asText());
        }
        for (JsonNode scope : scopes) {
            String id = scope.path("id").asText();
            String name = scope.path("name").asText();
            Scan scan = new Scan();
            ObjectNode body = JSON.createObjectNode();
            body.put("id", id);
            for (String field : List.of("name", "description", "protocol")) {
                JsonNode value = scope.get(field);
                if (value != null && value.isTextual()) {
                    scan.add(value.asText(), field);
                    String renamed = rename(value.asText());
                    body.put(field, renamed);
                    if ("description".equals(field)) {
                        scan.limit(renamed, field);
                    }
                }
            }
            JsonNode attributes = scope.get("attributes");
            if (attributes != null && attributes.isObject()) {
                ObjectNode renamed = JSON.createObjectNode();
                for (Map.Entry<String, JsonNode> entry : attributes.properties()) {
                    scan.add(entry.getValue().asText(), "attributes." + entry.getKey());
                    renamed.put(entry.getKey(), rename(entry.getValue().asText()));
                }
                body.set("attributes", renamed);
            }
            String newName = rename(name);
            String label = "client scope " + name + (newName.equals(name) ? "" : " -> " + newName);
            if (classify(scan, label)) {
                if (!newName.equals(name) && takenScopes.contains(newName)) {
                    problems.add("problem\tclient scope " + newName + " already exists next to " + name
                            + "; nothing was changed");
                }
                scopeUnits.add(unit("client-scope", "client-scopes/" + id, body, label));
            } else if (scan.hasNew) {
                done.add("done\tclient-scope\t" + label);
            }
            mappers(scope.get("protocolMappers"), "client-scopes/" + id, "client scope " + name, mapperUnits);
        }

        Path groupDir = workDir.resolve("groups");
        if (Files.isDirectory(groupDir)) {
            Map<String, Set<String>> siblings = new HashMap<>();
            List<JsonNode> groups = new ArrayList<>();
            try (var files = Files.list(groupDir)) {
                for (Path file : files.sorted().toList()) {
                    groups.add(read(file));
                }
            }
            for (JsonNode group : groups) {
                siblings.computeIfAbsent(group.path("parentId").asText(""), key -> new LinkedHashSet<>())
                        .add(group.path("name").asText());
            }
            for (JsonNode group : groups) {
                String id = group.path("id").asText();
                String name = group.path("name").asText();
                String path = group.path("path").asText(name);
                Scan scan = new Scan();
                ObjectNode body = JSON.createObjectNode();
                scan.add(name, "name");
                String newName = rename(name);
                body.put("name", newName);
                JsonNode description = group.get("description");
                if (description != null && description.isTextual()) {
                    scan.add(description.asText(), "description");
                    String renamed = rename(description.asText());
                    scan.limit(renamed, "description");
                    body.put("description", renamed);
                }
                ObjectNode attributes = JSON.createObjectNode();
                for (Map.Entry<String, JsonNode> entry : group.path("attributes").properties()) {
                    ArrayNode values = JSON.createArrayNode();
                    for (JsonNode value : entry.getValue()) {
                        scan.add(value.asText(), "attributes." + entry.getKey());
                        String renamed = rename(value.asText());
                        scan.limit(renamed, "attributes." + entry.getKey());
                        values.add(renamed);
                    }
                    attributes.set(entry.getKey(), values);
                }
                body.set("attributes", attributes);
                String label = "group " + path + (newName.equals(name) ? "" : " -> " + newName);
                if (classify(scan, label)) {
                    if (!newName.equals(name)
                            && siblings.getOrDefault(group.path("parentId").asText(""), Set.of()).contains(newName)) {
                        problems.add("problem\tgroup " + newName + " already exists next to " + path
                                + "; nothing was changed");
                    }
                    groupUnits.add(unit("group", "groups/" + id, body, label + " (attributes kept, texts renamed)"));
                } else if (scan.hasNew) {
                    done.add("done\tgroup\t" + label);
                }
            }
        }

        units.addAll(clientUnits);
        units.addAll(roleUnits);
        units.addAll(scopeUnits);
        units.addAll(mapperUnits);
        units.addAll(groupUnits);
    }

    private void roles(JsonNode roles, String pathPrefix, String owner, List<String> roleUnits) {
        if (roles == null) {
            return;
        }
        Set<String> taken = new LinkedHashSet<>();
        for (JsonNode role : roles) {
            taken.add(role.path("name").asText());
        }
        for (JsonNode role : roles) {
            String id = role.path("id").asText();
            String name = role.path("name").asText();
            Scan scan = new Scan();
            ObjectNode body = JSON.createObjectNode();
            scan.add(name, "name");
            String newName = rename(name);
            body.put("name", newName);
            JsonNode description = role.get("description");
            if (description != null && description.isTextual()) {
                scan.add(description.asText(), "description");
                String renamed = rename(description.asText());
                scan.limit(renamed, "description");
                body.put("description", renamed);
            }
            JsonNode attributes = role.get("attributes");
            if (attributes != null && attributes.isObject()) {
                ObjectNode renamedAttributes = JSON.createObjectNode();
                for (Map.Entry<String, JsonNode> entry : attributes.properties()) {
                    ArrayNode values = JSON.createArrayNode();
                    for (JsonNode value : entry.getValue()) {
                        scan.add(value.asText(), "attributes." + entry.getKey());
                        String renamed = rename(value.asText());
                        scan.limit(renamed, "attributes." + entry.getKey());
                        values.add(renamed);
                    }
                    renamedAttributes.set(entry.getKey(), values);
                }
                body.set("attributes", renamedAttributes);
            }
            String label = "role " + name + (newName.equals(name) ? "" : " -> " + newName) + " (" + owner + ")";
            boolean change = classify(scan, label);
            if (change) {
                if (!newName.equals(name) && taken.contains(newName)) {
                    problems.add("problem\trole " + newName + " already exists next to " + name + " (" + owner
                            + "); nothing was changed");
                }
                roleUnits.add(unit("role", "roles-by-id/" + id, body, label + " (id kept)"));
            } else if (scan.hasNew) {
                done.add("done\trole\t" + label);
            }
            // Counted before and after by id: a role to rename now is a renamed one then.
            if (change || scan.hasNew) {
                counts.add("count\t" + pathPrefix + name + "\t" + id + "\t" + label);
            }
        }
    }

    private void mappers(JsonNode mappers, String ownerPath, String owner, List<String> mapperUnits) {
        if (mappers == null || !mappers.isArray()) {
            return;
        }
        Set<String> taken = new LinkedHashSet<>();
        for (JsonNode mapper : mappers) {
            taken.add(mapper.path("name").asText());
        }
        for (JsonNode mapper : mappers) {
            String id = mapper.path("id").asText();
            String name = mapper.path("name").asText();
            Scan scan = new Scan();
            ObjectNode body = mapper.deepCopy();
            scan.add(name, "name");
            String newName = rename(name);
            body.put("name", newName);
            List<String> keys = new ArrayList<>();
            JsonNode config = mapper.get("config");
            if (config != null && config.isObject()) {
                ObjectNode renamed = JSON.createObjectNode();
                for (Map.Entry<String, JsonNode> entry : config.properties()) {
                    String text = entry.getValue().asText();
                    scan.add(text, "config." + entry.getKey());
                    String value = rename(text);
                    if (!value.equals(text)) {
                        keys.add(entry.getKey());
                    }
                    renamed.put(entry.getKey(), value);
                }
                body.set("config", renamed);
            }
            String label = "mapper " + name + (newName.equals(name) ? "" : " -> " + newName) + " (" + owner
                    + (keys.isEmpty() ? "" : "; config " + String.join(" ", keys)) + ")";
            if (classify(scan, label)) {
                if (!newName.equals(name) && taken.contains(newName)) {
                    problems.add("problem\tmapper " + newName + " already exists next to " + name + " (" + owner
                            + "); nothing was changed");
                }
                mapperUnits.add(unit("mapper", ownerPath + "/protocol-mappers/models/" + id, body, label));
            } else if (scan.hasNew) {
                done.add("done\tmapper\t" + label);
            }
        }
    }

    /** true when the object is to be renamed; adds the problems that forbid it. */
    private boolean classify(Scan scan, String label) {
        if (!scan.unexpected.isEmpty()) {
            problems.add("problem\t" + label + ": " + String.join(", ", scan.unexpected)
                    + " cannot be renamed by the rule (only SkyMail, SKYMAIL, skymail and their SkyNotify forms); nothing was changed");
        }
        if (scan.hasOld && scan.hasNew) {
            problems.add("problem\t" + label + " names both the old and the new name (" + String.join(" ", scan.oldFields)
                    + " / " + String.join(" ", scan.newFields) + "); nothing was changed");
        }
        for (String field : scan.tooLong) {
            problems.add("problem\t" + label + ": " + field + " would be longer than " + KEPT_LENGTH
                    + " characters after the rename; nothing was changed");
        }
        return scan.hasOld;
    }

    private String unit(String kind, String path, ObjectNode body, String label) {
        Path file = workDir.resolve("body-" + (++bodies) + ".json");
        try {
            Files.writeString(file, JSON.writeValueAsString(body), StandardCharsets.UTF_8);
        } catch (IOException exception) {
            throw new IllegalStateException(exception);
        }
        return "unit\t" + kind + "\t" + path + "\t" + file + "\t" + label;
    }

    /** The rename rule (see the script's header); the protected texts are left as they are. */
    String rename(String text) {
        if (text == null || text.isEmpty()) {
            return text;
        }
        List<String> kept = new ArrayList<>();
        Matcher protectedText = PROTECTED.matcher(text);
        StringBuilder builder = new StringBuilder();
        while (protectedText.find()) {
            kept.add(protectedText.group());
            protectedText.appendReplacement(builder, Matcher.quoteReplacement("" + (kept.size() - 1) + ""));
        }
        protectedText.appendTail(builder);
        String result = builder.toString();
        if (forward) {
            result = result.replace("SkyMail", "SkyNotify").replace("SKYMAIL", "SKYNOTIFY").replace("skymail", "skynotify");
            result = suffixes(result, "(SkyNotify|SKYNOTIFY|skynotify)", FRONT_TO_BACK);
        } else {
            result = result.replace("SkyNotify", "SkyMail").replace("SKYNOTIFY", "SKYMAIL").replace("skynotify", "skymail");
            result = suffixes(result, "(SkyMail|SKYMAIL|skymail)", BACK_TO_FRONT);
        }
        for (int i = 0; i < kept.size(); i++) {
            result = result.replace("" + i + "", kept.get(i));
        }
        return result;
    }

    private static String suffixes(String text, String name, Map<String, String> map) {
        Pattern pattern = Pattern.compile(name + "(['’])(" + String.join("|", map.keySet()) + ")(?![\\p{L}])");
        Matcher matcher = pattern.matcher(text);
        StringBuilder builder = new StringBuilder();
        while (matcher.find()) {
            matcher.appendReplacement(builder,
                    Matcher.quoteReplacement(matcher.group(1) + matcher.group(2) + map.get(matcher.group(3))));
        }
        matcher.appendTail(builder);
        return builder.toString();
    }

    private static String strip(String text) {
        return PROTECTED.matcher(text).replaceAll("");
    }

    /** What one object's texts name. */
    private final class Scan {
        boolean hasOld;
        boolean hasNew;
        final Set<String> oldFields = new LinkedHashSet<>();
        final Set<String> newFields = new LinkedHashSet<>();
        final Set<String> unexpected = new LinkedHashSet<>();
        final Set<String> tooLong = new LinkedHashSet<>();

        void add(String text, String field) {
            if (text == null) {
                return;
            }
            String plain = strip(text);
            Matcher old = oldAny.matcher(plain);
            while (old.find()) {
                hasOld = true;
                oldFields.add(field);
                if (!oldForms.contains(old.group())) {
                    unexpected.add(field + " '" + old.group() + "'");
                }
            }
            if (newAny.matcher(plain).find()) {
                hasNew = true;
                newFields.add(field);
            }
        }

        void limit(String renamed, String field) {
            if (renamed != null && renamed.length() > KEPT_LENGTH) {
                tooLong.add(field);
            }
        }
    }

    private static JsonNode read(Path file) throws IOException {
        return JSON.readTree(Files.readString(file, StandardCharsets.UTF_8));
    }

    private static JsonNode readOptional(Path file) throws IOException {
        return Files.exists(file) ? read(file) : null;
    }

    private static int usage() {
        System.err.println("usage: SkynotifyRename plan forward|reverse DIR | ids FILE | count FILE | group-ids FILE... | users FILE...");
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
write_helper "$WORK_DIR/SkynotifyRename.java"
if ! "$JAVA_BIN" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -m jdk.compiler/com.sun.tools.javac.Main \
  -d "$WORK_DIR/classes" -cp "$classpath" "$WORK_DIR/SkynotifyRename.java" >/dev/null; then
  printf 'The plan code could not be compiled with %s; run this inside the Keycloak image\n' "$JAVA_BIN" >&2
  exit 1
fi

helper() {
  "$JAVA_BIN" -XX:TieredStopAtLevel=1 -XX:+UseSerialGC -cp "$WORK_DIR/classes:$classpath" SkynotifyRename "$@"
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
log "realm=$TARGET_REALM mode=$MODE direction=$DIRECTION ($OLD_TOKEN -> $NEW_TOKEN)"

if ! kcadm get "realms/$TARGET_REALM" --fields realm >/dev/null 2>&1; then
  log "realm $TARGET_REALM does not exist or cannot be read; nothing was changed"
  exit 1
fi

# read_into FILE LABEL ARGS...: one kcadm read into FILE; a failure stops the run (never "absent").
read_into() {
  local file=$1 label=$2
  shift 2
  if ! kcadm get "$@" -r "$TARGET_REALM" >"$file" 2>"$WORK_DIR/read.stderr"; then
    grep -Ev -- '-----BEGIN|secret' "$WORK_DIR/read.stderr" >&2 || true
    printf '%s could not be read in realm %s; nothing was changed\n' "$label" "$TARGET_REALM" >&2
    return 1
  fi
}

# scan DIR: every client (with its mappers and roles), client scope and realm role, the groups whose
# name names either name (with their attributes), the users whose username does, then the plan
# (DIR/plan.tsv) and the service accounts (DIR/users.tsv).
scan() {
  local directory=$1 id token
  mkdir -p "$directory/roles" "$directory/groups" "$directory/search"
  read_into "$directory/clients.json" 'The clients' clients -q first=0 -q max=10000
  read_into "$directory/client-scopes.json" 'The client scopes' client-scopes
  read_into "$directory/realm-roles.json" 'The realm roles' roles -q first=0 -q max=10000 -q briefRepresentation=false
  while IFS= read -r id; do
    [[ $id =~ ^[A-Za-z0-9-]+$ ]] || { printf 'unexpected client id in the client list\n' >&2; return 1; }
    read_into "$directory/roles/$id.json" "The roles of client $id" "clients/$id/roles" \
      -q first=0 -q max=10000 -q briefRepresentation=false
  done < <(helper ids "$directory/clients.json")
  # Keycloak's group search matches a part of the name; both spellings in case it is case-sensitive.
  for token in skymail SKYMAIL skynotify SKYNOTIFY; do
    read_into "$directory/search/groups-$token.json" "The groups named $token" groups \
      -q "search=$token" -q first=0 -q max=10000 -q briefRepresentation=false
  done
  while IFS= read -r id; do
    [[ $id =~ ^[A-Za-z0-9-]+$ ]] || { printf 'unexpected group id in the group search\n' >&2; return 1; }
    read_into "$directory/groups/$id.json" "Group $id" "groups/$id"
  done < <(helper group-ids "$directory"/search/groups-*.json)
  for token in skymail skynotify; do
    read_into "$directory/search/users-$token.json" "The users named $token" users \
      -q "username=$token" -q first=0 -q max=10000 -q briefRepresentation=true
  done
  helper users "$directory"/search/users-*.json >"$directory/users.tsv"
  helper plan "$DIRECTION" "$directory" >"$directory/plan.tsv"
}

# holders DIR: per counted role "roleId<TAB>users<TAB>groups" (DIR/holders.tsv), by role id, so the
# counts before and after a rename compare although the names differ.
holders() {
  local directory=$1 path id label users groups
  : >"$directory/holders.tsv"
  while IFS=$'\t' read -r _ path id label; do
    read_into "$directory/holders-users.json" "The users of $label" "$path/users" \
      -q first=0 -q max=100000 -q briefRepresentation=true
    read_into "$directory/holders-groups.json" "The groups of $label" "$path/groups" \
      -q first=0 -q max=100000 -q briefRepresentation=true
    users=$(helper count "$directory/holders-users.json")
    groups=$(helper count "$directory/holders-groups.json")
    printf '%s\t%s\t%s\n' "$id" "$users" "$groups" >>"$directory/holders.tsv"
    printf '%s\t%s\t%s\n' "$label" "$users" "$groups" >>"$directory/holders-labels.tsv"
  done < <(grep $'^count\t' "$directory/plan.tsv" || true)
  rm -f "$directory/holders-users.json" "$directory/holders-groups.json"
  sort -o "$directory/holders.tsv" "$directory/holders.tsv"
}

scan "$WORK_DIR/before"
plan="$WORK_DIR/before/plan.tsv"
planned=$(grep -c $'^unit\t' "$plan" || true)
already=$(grep -c $'^done\t' "$plan" || true)
problems=$(grep -c $'^problem\t' "$plan" || true)
people=$(sed -n 's/^people\t//p' "$WORK_DIR/before/users.tsv")
while IFS=$'\t' read -r _ kind _ _ label; do
  log "rename $kind: $label"
done < <(grep $'^unit\t' "$plan" || true)
while IFS=$'\t' read -r _ kind label; do
  log "already renamed $kind: $label"
done < <(grep $'^done\t' "$plan" || true)
while IFS=$'\t' read -r _ name; do
  log "service account user: $name (Keycloak renames it with its client)"
done < <(grep $'^account\t' "$WORK_DIR/before/users.tsv" || true)
if ((people > 0)); then
  log "PROBLEM: $people person(s) (not service accounts) have a username that names SkyMail or SkyNotify; usernames are not renamed here; nothing was changed"
  problems=$((problems + 1))
fi
while IFS=$'\t' read -r _ text; do
  log "PROBLEM: $text"
done < <(grep $'^problem\t' "$plan" || true)
if ((problems > 0)); then
  printf 'The rename found %s problem(s); nothing was changed\n' "$problems" >&2
  exit 1
fi

holders "$WORK_DIR/before"
if [[ -s $WORK_DIR/before/holders-labels.tsv ]]; then
  while IFS=$'\t' read -r label users groups; do
    log "holders of $label: users=$users groups=$groups"
  done <"$WORK_DIR/before/holders-labels.tsv"
fi
log "plan: rename=$planned alreadyRenamed=$already roles counted=$(grep -c . "$WORK_DIR/before/holders.tsv" || true)"

if [[ $MODE != apply ]]; then
  log "dry run: $planned change(s); rerun with --apply to execute them"
  exit 0
fi

# failure_reason STDERR_FILE: a class for a failed write; kcadm's text is not printed.
failure_reason() {
  if grep -Eqi '\b(401|403)\b|forbidden|unauthorized' "$1"; then
    printf 'forbidden'
  elif grep -Eqi '\b409\b|conflict|exists' "$1"; then
    printf 'conflict'
  elif grep -Eqi '\b400\b|bad request|invalid|error-' "$1"; then
    printf 'invalid'
  else
    printf 'other'
  fi
}

applied=0
failed=0
while IFS=$'\t' read -r _ kind path body label; do
  if kcadm update "$path" -r "$TARGET_REALM" -n -f "$body" >/dev/null 2>"$WORK_DIR/write.stderr"; then
    applied=$((applied + 1))
  else
    failed=$((failed + 1))
    log "FAILED ($(failure_reason "$WORK_DIR/write.stderr")) $kind: $label"
  fi
done < <(grep $'^unit\t' "$plan" || true)
rm -f "$WORK_DIR/write.stderr"
log "applied $applied rename(s); failed=$failed"

# Read back: nothing is left to rename, no service account keeps the old name and every role id has
# the holders it had.
scan "$WORK_DIR/after"
left=$(grep -c $'^unit\t' "$WORK_DIR/after/plan.tsv" || true)
after_problems=$(grep -c $'^problem\t' "$WORK_DIR/after/plan.tsv" || true)
old_accounts=$(grep $'^account\t' "$WORK_DIR/after/users.tsv" | grep -ci -- "$OLD_TOKEN" || true)
holders "$WORK_DIR/after"
status=0
if ((failed > 0 || left > 0 || after_problems > 0)); then
  log "after: $left rename(s) left, $after_problems problem(s)"
  status=1
fi
if ((old_accounts > 0)); then
  log "after: $old_accounts service account user(s) still carry the old name"
  status=1
fi
if ! cmp -s "$WORK_DIR/before/holders.tsv" "$WORK_DIR/after/holders.tsv"; then
  log 'after: the users or groups holding a renamed role differ from before'
  status=1
else
  log "after: holders equal for $(grep -c . "$WORK_DIR/after/holders.tsv" || true) role(s); nothing left to rename"
fi
if ((status != 0)); then
  printf 'The rename is incomplete; rerun with --apply (renamed objects are not written again)\n' >&2
  exit 1
fi
