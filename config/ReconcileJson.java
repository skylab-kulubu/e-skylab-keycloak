import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.io.IOException;
import java.io.InputStream;
import java.io.PrintStream;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * JSON helper for reconcile-account-center.sh. The Keycloak image ships no jq, but it does
 * ship a JDK and Jackson, so the reconciler compiles this single file at start-up with the
 * in-image compiler and calls it for every comparison that needs real JSON semantics.
 *
 * Sub-commands (the live document always arrives on stdin, the desired state as a file):
 *
 *   diff-fields DESIRED.json    prints every top-level key of DESIRED whose value is not
 *                               already satisfied by the live document (objects compare as
 *                               subsets, arrays as multisets, numbers by value); prints
 *                               nothing when the live document already matches.
 *   mapper-diff DESIRED.json    DESIRED is an array of protocol mapper bodies, stdin the live
 *                               mapper list of one client scope; prints "create<TAB>-<TAB>name<TAB>body"
 *                               or "update<TAB>id<TAB>name<TAB>body" per mapper that is missing or
 *                               drifted (body is the compact JSON to send, with the id on update).
 *   merge BASE.json EXTRA.json  prints the top-level union of both objects (EXTRA wins); used to
 *                               add environment-derived fields to a source-controlled document.
 *   names                       prints the "name" of every element of the array on stdin.
 *   scope-mappings              stdin is the scope mappings of one client (GET
 *                               clients/{id}/scope-mappings); prints one line per mapped role:
 *                               "-<TAB>-<TAB>roleId<TAB>roleName" for a realm role and
 *                               "clientId<TAB>clientUuid<TAB>roleId<TAB>roleName" for a client role.
 *   field NAME                  prints the value of top-level NAME of the object on stdin as text
 *                               (empty when absent or null, JSON for containers).
 *   role-attribute NAME         stdin is a role list read with briefRepresentation=false; prints
 *                               "roleName<TAB>value" per role, value being the first value of the
 *                               role attribute NAME (empty when the role does not have it).
 *   realm-attribute NAME VALUE  prints {"attributes": {...}} with the complete "attributes" map of
 *                               the realm on stdin plus NAME=VALUE. Keycloak removes every realm
 *                               attribute absent from a PUT that carries "attributes", so the map
 *                               is always sent whole.
 *   user-profile SPEC.json      merges the User Profile specification into the live config on
 *                               stdin, prints the merged config and exits 3 when it differs
 *                               from the live one (0 when nothing has to change).
 *   password-form FROM TO       stdin is the flat execution list of one authentication flow
 *                               (GET authentication/flows/{alias}/executions); plans putting
 *                               authenticator TO in the place of FROM. Prints one line:
 *                               "unchanged<TAB>id" (TO is there, FROM is not),
 *                               "swap<TAB>id<TAB>parentFlowId|-<TAB>priority" (FROM is there: add
 *                               TO under the same parent with the same priority, then delete id),
 *                               "finish<TAB>id" (an interrupted swap left both side by side:
 *                               delete id), "resume<TAB>id<TAB>toId<TAB>priority" (a swap cut
 *                               before TO, added DISABLED, was made REQUIRED: make toId REQUIRED
 *                               with that priority, then delete id; refused like swap when FROM
 *                               carries an authenticator config) or "retire<TAB>id" (FROM is
 *                               DISABLED next to a REQUIRED TO in the same flow, as an Admin
 *                               Console change leaves it: delete id) or "discard<TAB>toId" (TO
 *                               is DISABLED elsewhere in the flow of a REQUIRED FROM: delete toId,
 *                               then plan again). Anything else is refused with exit status 4.
 *   first-broker-login STEP     stdin is the flat execution list of a first broker login flow;
 *                               prints what eskylab-login-ux 07 edits in it, one line each:
 *                               "step<TAB>id|-<TAB>priority<TAB>requirement|-" (STEP at the top
 *                               level, or "-" and the priority to add it with: one below the
 *                               review profile step),
 *                               "review<TAB>id<TAB>configId|-" (the review profile step) and
 *                               "email-verification<TAB>id<TAB>priority<TAB>requirement" per
 *                               idp-email-verification step. A flow without exactly one top-level
 *                               review profile step, with STEP twice, below the top level or after
 *                               the review profile step, or without a free priority for it is
 *                               refused with exit status 4.
 *   email-code-flow STEP SUBFLOW OTP_SUBFLOW OFFER FORM...
 *                               stdin is the flat execution list of the realm's browser flow; plans
 *                               eskylab-login-ux 08's ALTERNATIVE subflow SUBFLOW (STEP, then the
 *                               CONDITIONAL subflow OTP_SUBFLOW with conditional-user-configured and
 *                               auth-otp-form, then OFFER) next to the subflow of the password form
 *                               (the one REQUIRED execution of a FORM provider). Prints
 *                               "forms<TAB>flowId|-<TAB>priority" (the flow SUBFLOW belongs in, "-" for
 *                               the top level, and the priority to add it with), then
 *                               "subflow<TAB>id|-<TAB>flowId|-<TAB>requirement|-<TAB>priority|-" and, for
 *                               each part SUBFLOW has or lacks, "step", "otp" (with its flowId after the
 *                               id), "otp-condition", "otp-form" and "offer" lines of the same form
 *                               ("-" for a part that is missing). Refused with exit status 4: a flow
 *                               without exactly one REQUIRED password form, a password form at the top
 *                               level or in a subflow that is not ALTERNATIVE, a REQUIRED or CONDITIONAL
 *                               execution next to that subflow (an ALTERNATIVE beside it would never
 *                               run), SUBFLOW or a part twice, STEP outside SUBFLOW, an execution in
 *                               SUBFLOW or OTP_SUBFLOW that is none of its parts, or parts out of order.
 *   config-value NAME VALUE     stdin is one authenticator config ({id, alias, config}); prints it
 *                               with config.NAME = VALUE and exits 3 when that changes it, prints
 *                               nothing and exits 0 when config.NAME is already VALUE.
 *   role-groups FILE            FILE is config/role-groups.json (role-groups.sh); validates it and
 *                               prints "root<TAB>name<TAB>display_name_tr<TAB>description_tr", then
 *                               "group<TAB>name<TAB>client<TAB>role role...<TAB>display_name_tr<TAB>
 *                               description_tr" per role group. A name off the team code rule
 *                               (^[A-Z][A-Z0-9-]{1,23}$), a name twice, a group without exactly one
 *                               client or without a role, a role twice, or a text with a tab, a
 *                               line break, a double quote or a backslash is refused (exit 1).
 *   same-shape OTHER.json [STEP]
 *                               stdin and OTHER are the flat execution lists of two authentication
 *                               flows; exits 0 when both have the same shape (the same executions in
 *                               the same order, each with the same level, index, requirement,
 *                               provider and sub-flow-or-step kind; ids, names, descriptions,
 *                               priorities and authenticator configs are not compared) and 4 with
 *                               the first difference on stderr otherwise. With STEP, stdin is
 *                               eskylab-login-ux 07's copy of OTHER: its STEP executions are left
 *                               out, indexes are not compared (the added step shifts them; the
 *                               order and levels still fix the tree) and neither are the
 *                               requirements of idp-email-verification (the copy disables it).
 *   otp-guard STEP              stdin is the flat execution list of a reset credentials flow;
 *                               exits 0 when STEP (the reset OTP step) actually runs for a person
 *                               with OTP and only for them: exactly one REQUIRED STEP, inside a
 *                               CONDITIONAL subflow whose only enabled condition is one REQUIRED
 *                               conditional-user-configured and no other REQUIRED or CONDITIONAL
 *                               step, no enclosing subflow DISABLED.
 *                               Otherwise prints why on stdout and exits 4.
 *
 * Exit status 0 means "printed successfully", 3 means "changed" (user-profile and config-value),
 * 4 "refused" (password-form, first-broker-login, email-code-flow, same-shape and otp-guard) and 1 an
 * invalid input. Nothing
 * here prints secrets: all inputs are configuration documents.
 */
public final class ReconcileJson {
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final int EXIT_CHANGED = 3;
    private static final int EXIT_REFUSED = 4;
    private static final String ADMIN = "admin";
    private static final String USER = "user";

    private ReconcileJson() {
    }

    public static void main(String[] args) throws IOException {
        if (args.length == 0) {
            usage();
        }
        PrintStream out = new PrintStream(System.out, true, StandardCharsets.UTF_8);
        switch (args[0]) {
            case "diff-fields" -> diffFields(requireFile(args), readStdin(), out);
            case "mapper-diff" -> mapperDiff(requireFile(args), readStdin(), out);
            case "merge" -> merge(args, out);
            case "names" -> names(readStdin(), out);
            case "scope-mappings" -> scopeMappings(readStdin(), out);
            case "field" -> field(args, readStdin(), out);
            case "role-attribute" -> roleAttribute(args, readStdin(), out);
            case "realm-attribute" -> realmAttribute(args, readStdin(), out);
            case "user-profile" -> System.exit(userProfile(requireFile(args), readStdin(), out));
            case "password-form" -> System.exit(passwordForm(args, readStdin(), out));
            case "first-broker-login" -> System.exit(firstBrokerLogin(args, readStdin(), out));
            case "existing-account-flow" -> System.exit(existingAccountFlow(args, readStdin(), out));
            case "existing-account-providers" -> System.exit(existingAccountProviders(readStdin()));
            case "copy-broker-review-config" -> copyBrokerReviewConfig(args, readStdin(), out);
            case "email-code-flow" -> System.exit(emailCodeFlow(args, readStdin(), out));
            case "config-value" -> System.exit(configValue(args, readStdin(), out));
            case "role-groups" -> roleGroups(requireFile(args), out);
            case "same-shape" -> System.exit(sameShape(args, readStdin()));
            case "otp-guard" -> System.exit(otpGuard(args, readStdin(), out));
            default -> usage();
        }
    }

    private static void usage() {
        System.err.println("usage: ReconcileJson diff-fields|mapper-diff|user-profile FILE"
                + "  |  ReconcileJson merge BASE EXTRA  |  ReconcileJson names|scope-mappings"
                + "  |  ReconcileJson field NAME  |  ReconcileJson role-attribute NAME"
                + "  |  ReconcileJson realm-attribute NAME VALUE"
                + "  |  ReconcileJson password-form FROM TO  |  ReconcileJson first-broker-login STEP"
                + "  |  ReconcileJson email-code-flow STEP SUBFLOW OTP_SUBFLOW OFFER FORM..."
                + "  |  ReconcileJson config-value NAME VALUE  |  ReconcileJson same-shape OTHER [STEP]"
                + "  |  ReconcileJson otp-guard STEP  |  ReconcileJson role-groups FILE");
        System.exit(1);
    }

    private static JsonNode requireFile(String[] args) throws IOException {
        if (args.length != 2) {
            usage();
        }
        return MAPPER.readTree(Files.readString(Path.of(args[1]), StandardCharsets.UTF_8));
    }

    private static JsonNode readStdin() throws IOException {
        try (InputStream in = System.in) {
            byte[] bytes = in.readAllBytes();
            if (bytes.length == 0) {
                throw new IOException("expected a JSON document on stdin");
            }
            return MAPPER.readTree(bytes);
        }
    }

    // ------------------------------------------------------------------ diff-fields

    private static void diffFields(JsonNode desired, JsonNode live, PrintStream out) {
        if (!desired.isObject() || !live.isObject()) {
            throw new IllegalArgumentException("diff-fields expects two JSON objects");
        }
        for (Map.Entry<String, JsonNode> field : desired.properties()) {
            if (!matches(field.getValue(), live.get(field.getKey()))) {
                out.println(field.getKey());
            }
        }
    }

    /** True when the live value already satisfies the desired one. */
    static boolean matches(JsonNode desired, JsonNode live) {
        if (desired == null || desired.isMissingNode()) {
            return true;
        }
        if (live == null || live.isMissingNode()) {
            // Keycloak omits false, empty and null values from several representations.
            return isEmptyValue(desired);
        }
        if (desired.isObject()) {
            if (!live.isObject()) {
                return false;
            }
            for (Map.Entry<String, JsonNode> field : desired.properties()) {
                if (!matches(field.getValue(), live.get(field.getKey()))) {
                    return false;
                }
            }
            return true;
        }
        if (desired.isArray()) {
            return live.isArray() && multiset(desired).equals(multiset(live));
        }
        if (desired.isNumber()) {
            return live.isNumber() && desired.decimalValue().compareTo(live.decimalValue()) == 0;
        }
        return desired.equals(live);
    }

    private static boolean isEmptyValue(JsonNode node) {
        return node.isNull()
                || (node.isBoolean() && !node.booleanValue())
                || (node.isTextual() && node.textValue().isEmpty())
                || (node.isContainerNode() && node.isEmpty());
    }

    private static List<String> multiset(JsonNode array) {
        List<String> elements = new ArrayList<>();
        for (JsonNode element : array) {
            elements.add(canonical(element));
        }
        elements.sort(null);
        return elements;
    }

    /** Deterministic text form: sorted object keys, normalised numbers, nested arrays in order. */
    static String canonical(JsonNode node) {
        if (node == null || node.isNull() || node.isMissingNode()) {
            return "null";
        }
        if (node.isObject()) {
            TreeMap<String, String> sorted = new TreeMap<>();
            for (Map.Entry<String, JsonNode> field : node.properties()) {
                sorted.put(field.getKey(), canonical(field.getValue()));
            }
            StringBuilder text = new StringBuilder("{");
            for (Map.Entry<String, String> field : sorted.entrySet()) {
                text.append(quote(field.getKey())).append(':').append(field.getValue()).append(',');
            }
            return text.append('}').toString();
        }
        if (node.isArray()) {
            StringBuilder text = new StringBuilder("[");
            for (JsonNode element : node) {
                text.append(canonical(element)).append(',');
            }
            return text.append(']').toString();
        }
        if (node.isNumber()) {
            BigDecimal value = node.decimalValue().stripTrailingZeros();
            return value.toPlainString();
        }
        if (node.isTextual()) {
            return quote(node.textValue());
        }
        return node.toString();
    }

    private static String quote(String text) {
        return "\"" + text.replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
    }

    // ------------------------------------------------------------------ mapper-diff

    private static void mapperDiff(JsonNode desired, JsonNode live, PrintStream out) throws IOException {
        if (!desired.isArray() || !live.isArray()) {
            throw new IllegalArgumentException("mapper-diff expects two JSON arrays");
        }
        for (JsonNode wanted : desired) {
            String name = wanted.path("name").asText();
            if (name.isEmpty()) {
                throw new IllegalArgumentException("every desired mapper needs a name");
            }
            JsonNode existing = findByName(live, name);
            if (existing == null) {
                out.println("create\t-\t" + name + "\t" + MAPPER.writeValueAsString(wanted));
            } else if (!mapperMatches(wanted, existing)) {
                String id = existing.path("id").asText();
                ObjectNode body = wanted.deepCopy();
                body.put("id", id);
                out.println("update\t" + id + "\t" + name + "\t" + MAPPER.writeValueAsString(body));
            }
        }
    }

    private static JsonNode findByName(JsonNode array, String name) {
        for (JsonNode element : array) {
            if (name.equals(element.path("name").asText())) {
                return element;
            }
        }
        return null;
    }

    /**
     * Keycloak normalises mapper config on save: it drops empty values and adds defaults such as
     * userinfo.token.claim=false. A desired key with an empty value therefore matches an absent
     * live key, and live keys the desired body does not mention are ignored.
     */
    private static boolean mapperMatches(JsonNode desired, JsonNode live) {
        for (String field : new String[] {"protocol", "protocolMapper", "consentRequired"}) {
            if (desired.has(field) && !matches(desired.get(field), live.get(field))) {
                return false;
            }
        }
        JsonNode desiredConfig = desired.path("config");
        JsonNode liveConfig = live.path("config");
        for (Map.Entry<String, JsonNode> entry : desiredConfig.properties()) {
            String wanted = entry.getValue().asText();
            String actual = liveConfig.path(entry.getKey()).asText("");
            if (!wanted.equals(actual)) {
                return false;
            }
        }
        return true;
    }

    // ------------------------------------------------------------------ merge

    private static void merge(String[] args, PrintStream out) throws IOException {
        if (args.length != 3) {
            usage();
        }
        JsonNode base = MAPPER.readTree(Files.readString(Path.of(args[1]), StandardCharsets.UTF_8));
        JsonNode extra = MAPPER.readTree(Files.readString(Path.of(args[2]), StandardCharsets.UTF_8));
        if (!base.isObject() || !extra.isObject()) {
            throw new IllegalArgumentException("merge expects two JSON objects");
        }
        ObjectNode merged = base.deepCopy();
        merged.setAll((ObjectNode) extra);
        out.println(MAPPER.writerWithDefaultPrettyPrinter().writeValueAsString(merged));
    }

    // ------------------------------------------------------------------ names

    private static void names(JsonNode array, PrintStream out) {
        if (!array.isArray()) {
            throw new IllegalArgumentException("names expects a JSON array");
        }
        for (JsonNode element : array) {
            String name = element.path("name").asText();
            if (name.isEmpty()) {
                throw new IllegalArgumentException("every element needs a name");
            }
            out.println(name);
        }
    }

    // ------------------------------------------------------------------ scope-mappings

    private static void scopeMappings(JsonNode mappings, PrintStream out) {
        if (!mappings.isObject()) {
            throw new IllegalArgumentException("scope-mappings expects the scope mappings object of a client");
        }
        for (JsonNode role : mappings.path("realmMappings")) {
            out.println("-\t-\t" + roleColumns(role));
        }
        for (Map.Entry<String, JsonNode> client : mappings.path("clientMappings").properties()) {
            String clientUuid = client.getValue().path("id").asText();
            if (clientUuid.isEmpty()) {
                throw new IllegalArgumentException("client mapping " + client.getKey() + " has no id");
            }
            for (JsonNode role : client.getValue().path("mappings")) {
                out.println(client.getKey() + "\t" + clientUuid + "\t" + roleColumns(role));
            }
        }
    }

    private static String roleColumns(JsonNode role) {
        String id = role.path("id").asText();
        String name = role.path("name").asText();
        if (id.isEmpty() || name.isEmpty()) {
            throw new IllegalArgumentException("every mapped role needs an id and a name");
        }
        return id + "\t" + name;
    }

    // ------------------------------------------------------------------ field

    private static void field(String[] args, JsonNode live, PrintStream out) {
        if (args.length != 2) {
            usage();
        }
        JsonNode value = live.path(args[1]);
        if (value.isMissingNode() || value.isNull()) {
            out.println("");
        } else if (value.isValueNode()) {
            out.println(value.asText());
        } else {
            out.println(value.toString());
        }
    }

    // ------------------------------------------------------------------ role-attribute

    private static void roleAttribute(String[] args, JsonNode roles, PrintStream out) {
        if (args.length != 2) {
            usage();
        }
        if (!roles.isArray()) {
            throw new IllegalArgumentException("role-attribute expects a JSON array of roles");
        }
        for (JsonNode role : roles) {
            String name = role.path("name").asText();
            if (name.isEmpty()) {
                throw new IllegalArgumentException("every role needs a name");
            }
            JsonNode values = role.path("attributes").path(args[1]);
            String value = values.isArray() && !values.isEmpty() ? values.get(0).asText() : "";
            out.println(name + "\t" + value.replace('\t', ' ').replace('\n', ' '));
        }
    }

    // ------------------------------------------------------------------ role-groups

    private static final java.util.regex.Pattern ROLE_GROUP_NAME =
            java.util.regex.Pattern.compile("^[A-Z][A-Z0-9-]{1,23}$");
    private static final java.util.regex.Pattern ROLE_NAME = java.util.regex.Pattern.compile("^\\S+$");

    private static void roleGroups(JsonNode config, PrintStream out) {
        if (!config.isObject()) {
            throw new IllegalArgumentException("role-groups expects a JSON object");
        }
        String root = roleGroupName(config, "root");
        out.println(String.join("\t", "root", root,
                roleGroupText(config, "root_display_name_tr", root),
                roleGroupText(config, "root_description_tr", root)));
        JsonNode groups = config.path("groups");
        if (!groups.isArray() || groups.isEmpty()) {
            throw new IllegalArgumentException("role-groups: groups must be a non-empty array");
        }
        java.util.Set<String> names = new java.util.HashSet<>();
        names.add(root);
        for (JsonNode group : groups) {
            if (!group.isObject()) {
                throw new IllegalArgumentException("role-groups: every group must be an object");
            }
            String name = roleGroupName(group, "name");
            if (!names.add(name)) {
                throw new IllegalArgumentException("role-groups: the name " + name + " is used twice");
            }
            JsonNode client = group.path("client");
            if (!client.isTextual() || !ROLE_NAME.matcher(client.asText()).matches()) {
                throw new IllegalArgumentException("role-groups: " + name + " needs exactly one client (a string)");
            }
            JsonNode roles = group.path("roles");
            if (!roles.isArray() || roles.isEmpty()) {
                throw new IllegalArgumentException("role-groups: " + name + " needs at least one role");
            }
            java.util.Set<String> seen = new java.util.LinkedHashSet<>();
            for (JsonNode role : roles) {
                if (!role.isTextual() || !ROLE_NAME.matcher(role.asText()).matches()
                        || role.asText().contains("\"") || role.asText().contains("\\")
                        || !seen.add(role.asText())) {
                    throw new IllegalArgumentException("role-groups: " + name + " has an empty, odd or repeated role");
                }
            }
            out.println(String.join("\t", "group", name, client.asText(), String.join(" ", seen),
                    roleGroupText(group, "display_name_tr", name),
                    roleGroupText(group, "description_tr", name)));
        }
    }

    private static String roleGroupName(JsonNode node, String field) {
        String name = node.path(field).asText("");
        if (!node.path(field).isTextual() || !ROLE_GROUP_NAME.matcher(name).matches()) {
            throw new IllegalArgumentException("role-groups: " + field + " '" + name
                    + "' is not a team code style name (^[A-Z][A-Z0-9-]{1,23}$)");
        }
        return name;
    }

    private static String roleGroupText(JsonNode node, String field, String name) {
        JsonNode value = node.path(field);
        String text = value.asText("");
        if (!value.isTextual() || text.isBlank() || text.contains("\t") || text.contains("\n")
                || text.contains("\r") || text.contains("\"") || text.contains("\\")) {
            throw new IllegalArgumentException("role-groups: " + name + " needs a one-line " + field
                    + " without tabs, double quotes or backslashes");
        }
        return text;
    }

    // ------------------------------------------------------------------ realm-attribute

    private static void realmAttribute(String[] args, JsonNode live, PrintStream out) throws IOException {
        if (args.length != 3) {
            usage();
        }
        if (!live.isObject()) {
            throw new IllegalArgumentException("realm-attribute expects the live realm object on stdin");
        }
        JsonNode existing = live.get("attributes");
        ObjectNode attributes = existing != null && existing.isObject()
                ? existing.deepCopy() : MAPPER.createObjectNode();
        attributes.put(args[1], args[2]);
        ObjectNode body = MAPPER.createObjectNode();
        body.set("attributes", attributes);
        out.println(MAPPER.writeValueAsString(body));
    }

    // ------------------------------------------------------------------ password-form

    /** One authenticator execution of the flat list, with the flow it sits in. */
    private record Execution(String id, String parent, int priority, String requirement, boolean configured) {
    }

    private static int passwordForm(String[] args, JsonNode executions, PrintStream out) {
        if (args.length != 3 || !executions.isArray()) {
            usage();
        }
        String from = args[1];
        String to = args[2];
        List<Execution> all = new ArrayList<>();
        List<Execution> fromList = new ArrayList<>();
        List<Execution> toList = new ArrayList<>();
        Map<Integer, String> flowAtLevel = new TreeMap<>();
        for (JsonNode node : executions) {
            int level = node.path("level").asInt();
            String parent = level == 0 ? "-" : flowAtLevel.getOrDefault(level - 1, "?");
            if (node.path("authenticationFlow").asBoolean(false)) {
                flowAtLevel.put(level, node.path("flowId").asText());
            }
            JsonNode config = node.path("authenticationConfig");
            Execution execution = new Execution(
                    node.path("id").asText(),
                    parent,
                    node.path("priority").asInt(),
                    node.path("requirement").asText(),
                    !config.isMissingNode() && !config.isNull() && !config.asText().isEmpty());
            all.add(execution);
            String provider = node.path("providerId").asText("");
            if (from.equals(provider)) {
                fromList.add(execution);
            } else if (to.equals(provider)) {
                toList.add(execution);
            }
        }

        if (fromList.isEmpty() && toList.size() == 1) {
            Execution present = toList.get(0);
            if (!"REQUIRED".equals(present.requirement())) {
                return refuse(to + " is " + present.requirement() + ", expected REQUIRED");
            }
            out.println("unchanged\t" + present.id());
            return 0;
        }
        if (fromList.size() == 1 && toList.isEmpty()) {
            Execution old = fromList.get(0);
            if (!"REQUIRED".equals(old.requirement())) {
                return refuse(from + " is " + old.requirement() + ", expected REQUIRED");
            }
            if (old.configured()) {
                return refuse(from + " carries an authenticator config");
            }
            if ("?".equals(old.parent())) {
                return refuse("the flow that holds " + from + " could not be determined");
            }
            for (Execution sibling : all) {
                if (sibling != old && sibling.parent().equals(old.parent()) && sibling.priority() == old.priority()) {
                    return refuse("another execution next to " + from + " has the same priority "
                            + old.priority() + ", so its place could not be kept");
                }
            }
            out.println("swap\t" + old.id() + "\t" + old.parent() + "\t" + old.priority());
            return 0;
        }
        if (fromList.size() == 1 && toList.size() == 1) {
            Execution old = fromList.get(0);
            Execution added = toList.get(0);
            boolean sameFlow = old.parent().equals(added.parent()) && !"?".equals(old.parent());
            boolean samePlace = sameFlow && old.priority() == added.priority();
            if (samePlace && "REQUIRED".equals(old.requirement()) && "REQUIRED".equals(added.requirement())) {
                out.println("finish\t" + old.id());
                return 0;
            }
            // Admin REST adds an execution DISABLED whenever its factory offers more than one
            // requirement (auth-otp-form and reset-otp do), so a swap can also be cut before the
            // added one was made REQUIRED.
            if (samePlace && "REQUIRED".equals(old.requirement()) && "DISABLED".equals(added.requirement())) {
                if (old.configured()) {
                    return refuse(from + " carries an authenticator config");
                }
                out.println("resume\t" + old.id() + "\t" + added.id() + "\t" + old.priority());
                return 0;
            }
            // FROM no longer runs; removing it changes nothing a person sees.
            if (sameFlow && "DISABLED".equals(old.requirement()) && "REQUIRED".equals(added.requirement())) {
                out.println("retire\t" + old.id());
                return 0;
            }
            // A DISABLED TO elsewhere in the flow (an Admin Console change taken back) never runs
            // either; once it is removed, the flow is planned again.
            if (sameFlow && "REQUIRED".equals(old.requirement()) && "DISABLED".equals(added.requirement())) {
                out.println("discard\t" + added.id());
                return 0;
            }
        }
        return refuse("expected exactly one of " + from + " and " + to + ", found "
                + fromList.size() + " " + from + " and " + toList.size() + " " + to);
    }

    // ------------------------------------------------------------------ otp-guard

    private static int otpGuard(String[] args, JsonNode executions, PrintStream out) {
        if (args.length != 2 || !executions.isArray()) {
            usage();
        }
        String step = args[1];
        List<JsonNode> list = new ArrayList<>();
        executions.forEach(list::add);
        int at = -1;
        for (int i = 0; i < list.size(); i++) {
            if (step.equals(list.get(i).path("providerId").asText(""))) {
                if (at >= 0) {
                    out.println("the flow holds more than one " + step);
                    return EXIT_REFUSED;
                }
                at = i;
            }
        }
        if (at < 0) {
            out.println("the flow holds no " + step);
            return EXIT_REFUSED;
        }
        JsonNode found = list.get(at);
        if (!"REQUIRED".equals(found.path("requirement").asText())) {
            out.println(step + " is " + found.path("requirement").asText() + ", not REQUIRED");
            return EXIT_REFUSED;
        }
        int level = found.path("level").asInt();
        if (level == 0) {
            out.println(step + " is at the top level, outside a conditional subflow");
            return EXIT_REFUSED;
        }
        // The enclosing subflows: for each level above STEP, the nearest subflow before it.
        int parentAt = -1;
        int wanted = level - 1;
        for (int i = at - 1; i >= 0 && wanted >= 0; i--) {
            JsonNode node = list.get(i);
            if (node.path("level").asInt() == wanted && node.path("authenticationFlow").asBoolean(false)) {
                if (parentAt < 0) {
                    parentAt = i;
                }
                if ("DISABLED".equals(node.path("requirement").asText())) {
                    out.println("subflow '" + node.path("displayName").asText() + "' is DISABLED");
                    return EXIT_REFUSED;
                }
                wanted--;
            }
        }
        if (parentAt < 0) {
            out.println("the subflow that holds " + step + " could not be determined");
            return EXIT_REFUSED;
        }
        JsonNode parent = list.get(parentAt);
        String parentName = parent.path("displayName").asText();
        if (!"CONDITIONAL".equals(parent.path("requirement").asText())) {
            out.println("subflow '" + parentName + "' is " + parent.path("requirement").asText()
                    + ", not CONDITIONAL");
            return EXIT_REFUSED;
        }
        // The direct children of the subflow: the executions after it one level down, up to the
        // next execution at its level or above.
        // Keycloak's conditional-user-configured holds only when the person has every REQUIRED and
        // CONDITIONAL non-condition sibling configured (the ALTERNATIVE ones count only when there
        // is none). Any such sibling besides STEP (say a REQUIRED WebAuthn step added in the Admin
        // Console) makes a person with OTP alone skip the subflow, and with it the code.
        List<String> conditions = new ArrayList<>();
        List<String> others = new ArrayList<>();
        for (int i = parentAt + 1; i < list.size() && list.get(i).path("level").asInt() > parent.path("level").asInt(); i++) {
            JsonNode node = list.get(i);
            String provider = node.path("providerId").asText("");
            String requirement = node.path("requirement").asText();
            if (node.path("level").asInt() != level) {
                continue;
            }
            if (provider.startsWith("conditional-")) {
                if (!"DISABLED".equals(requirement)) {
                    conditions.add(provider + " " + requirement);
                }
            } else if (i != at && ("REQUIRED".equals(requirement) || "CONDITIONAL".equals(requirement))) {
                String name = node.path("authenticationFlow").asBoolean(false)
                        ? "subflow '" + node.path("displayName").asText() + "'" : provider;
                others.add(name + " " + requirement);
            }
        }
        if (!conditions.equals(List.of("conditional-user-configured REQUIRED"))) {
            out.println("subflow '" + parentName + "' has the enabled conditions " + conditions
                    + ", not exactly one REQUIRED conditional-user-configured");
            return EXIT_REFUSED;
        }
        if (!others.isEmpty()) {
            out.println("subflow '" + parentName + "' also requires " + others + " besides " + step
                    + ", so a person with OTP alone skips it");
            return EXIT_REFUSED;
        }
        return 0;
    }

    // ------------------------------------------------------------------ first-broker-login

    private static int firstBrokerLogin(String[] args, JsonNode executions, PrintStream out) {
        if (args.length != 2 || !executions.isArray()) {
            usage();
        }
        String step = args[1];
        List<JsonNode> reviews = new ArrayList<>();
        List<JsonNode> steps = new ArrayList<>();
        List<JsonNode> verifications = new ArrayList<>();
        List<Integer> topLevelPriorities = new ArrayList<>();
        for (JsonNode node : executions) {
            String provider = node.path("providerId").asText("");
            boolean topLevel = node.path("level").asInt() == 0;
            if (topLevel) {
                topLevelPriorities.add(node.path("priority").asInt());
            }
            if ("idp-review-profile".equals(provider) || "sky-broker-review-profile".equals(provider)) {
                if (!topLevel) {
                    return refuse("the review profile step is not at the top level of the flow");
                }
                reviews.add(node);
            } else if (step.equals(provider)) {
                if (!topLevel) {
                    return refuse(step + " is not at the top level of the flow");
                }
                steps.add(node);
            } else if ("idp-email-verification".equals(provider)) {
                verifications.add(node);
            }
        }
        // A stopped, config-preserving wrapper replacement may briefly leave these two known
        // reviews side by side. The existing-account planner completes it after this step.
        if (reviews.size() == 2 && reviews.stream().map(n -> n.path("providerId").asText()).distinct().count() == 2) {
            reviews.removeIf(n -> "idp-review-profile".equals(n.path("providerId").asText()));
        }
        if (reviews.size() != 1) {
            return refuse("expected exactly one review profile step, found " + reviews.size());
        }
        if (steps.size() > 1) {
            return refuse("expected at most one " + step + ", found " + steps.size());
        }
        JsonNode review = reviews.get(0);
        int reviewPriority = review.path("priority").asInt();
        if (steps.isEmpty()) {
            int priority = reviewPriority - 1;
            if (topLevelPriorities.contains(priority)) {
                return refuse("priority " + priority + " just before the review profile step is taken");
            }
            out.println("step\t-\t" + priority + "\t-");
        } else {
            JsonNode present = steps.get(0);
            if (present.path("priority").asInt() >= reviewPriority) {
                return refuse(step + " runs after the review profile step");
            }
            out.println("step\t" + present.path("id").asText() + "\t" + present.path("priority").asInt()
                    + "\t" + present.path("requirement").asText());
        }
        String config = review.path("authenticationConfig").asText("");
        out.println("review\t" + review.path("id").asText() + "\t" + (config.isEmpty() ? "-" : config));
        for (JsonNode verification : verifications) {
            out.println("email-verification\t" + verification.path("id").asText() + "\t"
                    + verification.path("priority").asInt() + "\t" + verification.path("requirement").asText());
        }
        return 0;
    }

    // ------------------------------------------------------------------ email-code-flow

    /** One execution of the flat list with the flow it sits in ("-" for the top level). */
    private record Node(String id, String parent, int priority, String requirement, String provider,
            boolean subFlow, String flowId, String alias) {

        String describe() {
            return subFlow ? "subflow '" + alias + "'" : provider;
        }
    }

    private static List<Node> brokerNodes(JsonNode executions) {
        List<Node> nodes = new ArrayList<>();
        Map<Integer, String> flowAtLevel = new TreeMap<>();
        for (JsonNode n : executions) {
            int level = n.path("level").asInt();
            String parent = level == 0 ? "-" : flowAtLevel.getOrDefault(level - 1, "?");
            boolean sub = n.path("authenticationFlow").asBoolean(false);
            if (sub) flowAtLevel.put(level, n.path("flowId").asText());
            nodes.add(new Node(n.path("id").asText(), parent, n.path("priority").asInt(),
                    n.path("requirement").asText(), n.path("providerId").asText(""), sub,
                    n.path("flowId").asText(""), n.path("displayName").asText("")));
        }
        return nodes;
    }

    private static int existingAccountProviders(JsonNode providers) {
        if (!providers.isArray()) return refuse("authenticator providers could not be read");
        for (String id : List.of("sky-existing-account-prompt", "sky-broker-review-profile", "sky-existing-account-proven")) {
            boolean found = false;
            for (JsonNode provider : providers) if (id.equals(provider.path("id").asText())) found = true;
            if (!found) return refuse("the running image has no " + id + "; deploy the reviewed image first");
        }
        return 0;
    }

    private static void copyBrokerReviewConfig(String[] args, JsonNode source, PrintStream out) throws IOException {
        if (args.length != 2 || !source.isObject()) usage();
        ObjectNode body = MAPPER.createObjectNode();
        body.put("alias", args[1]);
        ObjectNode config = source.path("config").isObject() ? source.path("config").deepCopy() : MAPPER.createObjectNode();
        config.put("update.profile.on.first.login", "missing");
        body.set("config", config);
        out.println(MAPPER.writeValueAsString(body));
    }

    /** Plans only the known additions to the editable first-broker-login copy. */
    private static int existingAccountFlow(String[] args, JsonNode executions, PrintStream out) throws IOException {
        if (args.length != 4 || !executions.isArray() || !List.of("on", "off").contains(args[1])) usage();
        boolean on = "on".equals(args[1]);
        List<Node> nodes = brokerNodes(executions);
        List<Node> ytu = nodes.stream().filter(n -> "sky-ytu-first-login".equals(n.provider())).toList();
        List<Node> creates = nodes.stream().filter(n -> "idp-create-user-if-unique".equals(n.provider())).toList();
        List<Node> reviews = nodes.stream().filter(n -> List.of("idp-review-profile", "sky-broker-review-profile")
                .contains(n.provider())).toList();
        List<Node> prompts = nodes.stream().filter(n -> "sky-existing-account-prompt".equals(n.provider())).toList();
        List<Node> proven = nodes.stream().filter(n -> "sky-existing-account-proven".equals(n.provider())).toList();
        if (reviews.isEmpty() || reviews.size() > 2 || creates.size() != 1 || prompts.size() > 1 || proven.size() > 1
                || reviews.stream().anyMatch(n -> !"-".equals(n.parent()) || !"REQUIRED".equals(n.requirement()))
                || reviews.stream().map(Node::provider).distinct().count() != reviews.size()) {
            return refuse("existing-account protection requires one known top-level review and one native Create User If Unique");
        }
        Node create = creates.getFirst();
        if (!"ALTERNATIVE".equals(create.requirement()) || "?".equals(create.parent()) || "-".equals(create.parent())) {
            return refuse("Create User If Unique is not an alternative in a known subflow");
        }
        if (prompts.stream().anyMatch(n -> !"-".equals(n.parent()))
                || proven.stream().anyMatch(n -> !create.parent().equals(n.parent()))) {
            return refuse("existing-account steps are outside their dedicated positions");
        }
        JsonNode builtIn = MAPPER.readTree(Files.readString(Path.of(args[3]), StandardCharsets.UTF_8));
        List<JsonNode> base = new ArrayList<>();
        boolean hadReview = false;
        for (JsonNode n : executions) {
            String provider = n.path("providerId").asText("");
            if (List.of("sky-ytu-first-login", "sky-existing-account-prompt", "sky-existing-account-proven")
                    .contains(provider)) continue;
            if (List.of("idp-review-profile", "sky-broker-review-profile").contains(provider)) {
                if (hadReview) continue;
                hadReview = true;
            }
            base.add(n);
        }
        if (!builtIn.isArray() || builtIn.size() != base.size()) return refuse("the native first-broker-login shape has changed");
        for (int i = 0; i < base.size(); i++) {
            if (!shapeOf(base.get(i), true).equals(shapeOf(builtIn.get(i), true))) {
                return refuse("native broker step " + (i + 1) + " has changed; inspect the flow before enabling protection");
            }
        }
        String wantedReview = on ? "sky-broker-review-profile" : "idp-review-profile";
        Node desired = reviews.stream().filter(n -> wantedReview.equals(n.provider())).findFirst().orElse(null);
        Node old = reviews.stream().filter(n -> !wantedReview.equals(n.provider())).findFirst().orElse(null);
        Node anchor = desired != null ? desired : old;
        if (on && (ytu.size() != 1 || !"-".equals(ytu.getFirst().parent())
                || !"REQUIRED".equals(ytu.getFirst().requirement())
                || ytu.getFirst().priority() >= anchor.priority())) {
            return refuse("turn on the school-primary first-login step before existing-account protection");
        }
        if (!on) {
            prompts.forEach(n -> out.println("remove\t" + n.id()));
            proven.forEach(n -> out.println("remove\t" + n.id()));
        }
        String desiredConfig = "-", oldConfig = "-";
        for (JsonNode n : executions) {
            if (desired != null && desired.id().equals(n.path("id").asText())) desiredConfig = n.path("authenticationConfig").asText("-");
            if (old != null && old.id().equals(n.path("id").asText())) oldConfig = n.path("authenticationConfig").asText("-");
        }
        out.println(String.join("\t", "review", desired == null ? "-" : desired.id(), args[2], wantedReview,
                Integer.toString(anchor.priority()), oldConfig.isBlank() ? "-" : oldConfig,
                desiredConfig.isBlank() ? "-" : desiredConfig));
        if (old != null) out.println("remove\t" + old.id());
        if (on) {
            int promptPriority = anchor.priority() - 1;
            int ytuPriority = anchor.priority() - 2;
            if (nodes.stream().anyMatch(n -> "-".equals(n.parent()) && n.priority() == ytuPriority
                    && !"sky-ytu-first-login".equals(n.provider()))) {
                return refuse("the reserved priority before the existing-account question is occupied");
            }
            brokerEnsure(out, ytu.getFirst(), args[2], "sky-ytu-first-login", ytuPriority, "REQUIRED");
            brokerEnsure(out, proven.isEmpty() ? null : proven.getFirst(), create.parent(),
                    "sky-existing-account-proven", create.priority() - 1, "ALTERNATIVE");
            brokerEnsure(out, prompts.isEmpty() ? null : prompts.getFirst(), args[2],
                    "sky-existing-account-prompt", promptPriority, "REQUIRED");
        }
        return 0;
    }

    private static void brokerEnsure(PrintStream out, Node present, String parent, String provider, int priority, String requirement) {
        boolean same = present != null && present.priority() == priority && requirement.equals(present.requirement());
        out.println(String.join("\t", "ensure", present == null ? "-" : present.id(), parent, provider,
                Integer.toString(priority), requirement, same ? "same" : "change"));
    }

    private static int emailCodeFlow(String[] args, JsonNode executions, PrintStream out) {
        if (args.length < 6 || !executions.isArray()) {
            usage();
        }
        String step = args[1];
        String subflowAlias = args[2];
        String otpAlias = args[3];
        List<String> offers = List.of(args[4].split(","));
        List<String> forms = List.of(args).subList(5, args.length);
        List<Node> nodes = new ArrayList<>();
        Map<Integer, String> flowAtLevel = new TreeMap<>();
        for (JsonNode node : executions) {
            int level = node.path("level").asInt();
            String parent = level == 0 ? "-" : flowAtLevel.getOrDefault(level - 1, "?");
            boolean subFlow = node.path("authenticationFlow").asBoolean(false);
            if (subFlow) {
                flowAtLevel.put(level, node.path("flowId").asText());
            }
            nodes.add(new Node(node.path("id").asText(), parent, node.path("priority").asInt(),
                    node.path("requirement").asText(), node.path("providerId").asText(""), subFlow,
                    node.path("flowId").asText(""), node.path("displayName").asText("")));
        }

        List<Node> passwordForms = nodes.stream()
                .filter(node -> forms.contains(node.provider()) && "REQUIRED".equals(node.requirement())).toList();
        if (passwordForms.size() != 1) {
            return refuse("expected exactly one REQUIRED password form (" + String.join(", ", forms) + "), found "
                    + passwordForms.size());
        }
        String passwordFlow = passwordForms.get(0).parent();
        if ("-".equals(passwordFlow) || "?".equals(passwordFlow)) {
            return refuse("the password form is not in a subflow, so there is no alternative to put the e-mail code next to");
        }
        Node passwordSubflow = nodes.stream().filter(node -> node.subFlow() && node.flowId().equals(passwordFlow))
                .findFirst().orElse(null);
        if (passwordSubflow == null || !"ALTERNATIVE".equals(passwordSubflow.requirement())) {
            return refuse("the subflow of the password form is "
                    + (passwordSubflow == null ? "unknown" : passwordSubflow.requirement()) + ", not ALTERNATIVE");
        }
        String target = passwordSubflow.parent();
        List<Node> siblings = children(nodes, target);
        List<Node> subflows = siblings.stream().filter(node -> node.subFlow() && node.alias().equals(subflowAlias)).toList();
        if (subflows.size() > 1) {
            return refuse("subflow '" + subflowAlias + "' is there " + subflows.size() + " times");
        }
        Node subflow = subflows.isEmpty() ? null : subflows.get(0);
        for (Node sibling : siblings) {
            if (sibling != subflow && !"ALTERNATIVE".equals(sibling.requirement()) && !"DISABLED".equals(sibling.requirement())) {
                return refuse(sibling.describe() + " next to the password form's subflow is " + sibling.requirement()
                        + ": an ALTERNATIVE beside it would never run");
            }
        }
        for (Node node : nodes) {
            if (step.equals(node.provider()) && (subflow == null || !node.parent().equals(subflow.flowId()))) {
                return refuse(step + " is in the flow outside subflow '" + subflowAlias + "'");
            }
        }
        int next = siblings.stream().mapToInt(Node::priority).max().orElse(0) + 10;
        // Printed only once the whole plan stands, so a refusal prints nothing on stdout.
        List<String> plan = new ArrayList<>();
        plan.add("forms\t" + target + "\t" + next);
        plan.add(line("subflow", subflow, true));
        if (subflow == null) {
            plan.forEach(out::println);
            return 0;
        }

        Node stepNode = null;
        Node otpNode = null;
        Node offerNode = null;
        List<Node> parts = children(nodes, subflow.flowId());
        for (Node part : parts) {
            if (!part.subFlow() && step.equals(part.provider()) && stepNode == null) {
                stepNode = part;
            } else if (part.subFlow() && otpAlias.equals(part.alias()) && otpNode == null) {
                otpNode = part;
            } else if (!part.subFlow() && offers.contains(part.provider()) && offerNode == null) {
                offerNode = part;
            } else {
                return refuse("subflow '" + subflowAlias + "' holds " + part.describe()
                        + ", which this reconciler does not put there; inspect it in the Admin Console");
            }
        }
        if (!inOrder(stepNode, otpNode, offerNode)) {
            return refuse("the parts of subflow '" + subflowAlias + "' are not in the order " + step + ", subflow '"
                    + otpAlias + "', " + String.join(" or ", offers));
        }
        plan.add(line("step", stepNode, false));
        plan.add(line("otp", otpNode, true));
        plan.add(line("offer", offerNode, false));
        plan.add("offer-provider\t" + (offerNode == null ? "-" : offerNode.provider()));
        Node condition = null;
        Node otpForm = null;
        if (otpNode != null) {
            for (Node part : children(nodes, otpNode.flowId())) {
                if (!part.subFlow() && "conditional-user-configured".equals(part.provider()) && condition == null) {
                    condition = part;
                } else if (!part.subFlow() && "auth-otp-form".equals(part.provider()) && otpForm == null) {
                    otpForm = part;
                } else {
                    return refuse("subflow '" + otpAlias + "' holds " + part.describe()
                            + ", which this reconciler does not put there; inspect it in the Admin Console");
                }
            }
            if (!inOrder(condition, otpForm)) {
                return refuse("subflow '" + otpAlias + "' does not ask the condition before the code");
            }
        }
        plan.add(line("otp-condition", condition, false));
        plan.add(line("otp-form", otpForm, false));
        plan.forEach(out::println);
        return 0;
    }

    private static List<Node> children(List<Node> nodes, String flow) {
        return nodes.stream().filter(node -> node.parent().equals(flow)).toList();
    }

    /** Whether the parts that are there have rising priorities in the given order. */
    private static boolean inOrder(Node... parts) {
        int last = Integer.MIN_VALUE;
        for (Node part : parts) {
            if (part != null) {
                if (part.priority() <= last) {
                    return false;
                }
                last = part.priority();
            }
        }
        return true;
    }

    private static String line(String kind, Node node, boolean withFlow) {
        if (node == null) {
            return kind + "\t-" + (withFlow ? "\t-" : "") + "\t-\t-";
        }
        return kind + "\t" + node.id() + (withFlow ? "\t" + node.flowId() : "") + "\t" + node.requirement()
                + "\t" + node.priority();
    }

    // ------------------------------------------------------------------ same-shape

    private static int sameShape(String[] args, JsonNode stdin) throws IOException {
        if (args.length != 2 && args.length != 3) {
            usage();
        }
        JsonNode otherNode = MAPPER.readTree(Files.readString(Path.of(args[1]), StandardCharsets.UTF_8));
        if (!otherNode.isArray() || !stdin.isArray()) {
            usage();
        }
        String step = args.length == 3 ? args[2] : null;
        List<JsonNode> other = new ArrayList<>();
        otherNode.forEach(other::add);
        List<JsonNode> executions = new ArrayList<>();
        for (JsonNode node : stdin) {
            String provider = node.path("providerId").asText("");
            if ("sky-ytu-first-login".equals(step)
                    && List.of("sky-existing-account-prompt", "sky-existing-account-proven").contains(provider)) {
                // Exact position and requirement are checked below, before ignoring these known additions.
                continue;
            }
            if (step == null || !step.equals(provider)) {
                executions.add(node);
            }
        }
        if ("sky-ytu-first-login".equals(step) && !safeBrokerProtectionShape(stdin)) {
            return refuse("existing-account protection has an unexpected position or requirement");
        }
        boolean copy = step != null;
        int count = Math.max(other.size(), executions.size());
        for (int i = 0; i < count; i++) {
            String want = i < other.size() ? shapeOf(other.get(i), copy) : "nothing";
            String have = i < executions.size() ? shapeOf(executions.get(i), copy) : "nothing";
            if (!want.equals(have)) {
                return refuse("execution " + (i + 1) + " is " + have + ", not " + want);
            }
        }
        return 0;
    }

    private static String shapeOf(JsonNode execution, boolean copy) {
        boolean subFlow = execution.path("authenticationFlow").asBoolean(false);
        String provider = execution.path("providerId").asText("?");
        if (copy && "sky-broker-review-profile".equals(provider)) provider = "idp-review-profile";
        String requirement = copy && "idp-email-verification".equals(provider)
                ? "any requirement" : execution.path("requirement").asText("?");
        return (subFlow ? "sub-flow" : "step " + provider)
                + " (level " + execution.path("level").asInt()
                + (copy ? "" : ", index " + execution.path("index").asInt())
                + ", " + requirement + ")";
    }

    private static boolean safeBrokerProtectionShape(JsonNode executions) {
        List<Node> nodes = brokerNodes(executions);
        List<Node> prompt = nodes.stream().filter(n -> "sky-existing-account-prompt".equals(n.provider())).toList();
        List<Node> proven = nodes.stream().filter(n -> "sky-existing-account-proven".equals(n.provider())).toList();
        List<Node> review = nodes.stream().filter(n -> "sky-broker-review-profile".equals(n.provider())).toList();
        if (prompt.isEmpty() && proven.isEmpty() && review.isEmpty()) return true;
        if (prompt.size() != 1 || proven.size() != 1 || review.size() != 1) return false;
        Node question = prompt.getFirst(), proof = proven.getFirst(), profile = review.getFirst();
        List<Node> ytu = nodes.stream().filter(n -> "sky-ytu-first-login".equals(n.provider())).toList();
        List<Node> create = nodes.stream().filter(n -> "idp-create-user-if-unique".equals(n.provider())).toList();
        return ytu.size() == 1 && create.size() == 1
                && "-".equals(question.parent()) && "REQUIRED".equals(question.requirement())
                && "-".equals(profile.parent()) && "REQUIRED".equals(profile.requirement())
                && ytu.getFirst().priority() < question.priority() && question.priority() < profile.priority()
                && create.getFirst().parent().equals(proof.parent()) && "ALTERNATIVE".equals(proof.requirement())
                && proof.priority() < create.getFirst().priority();
    }

    // ------------------------------------------------------------------ config-value

    private static int configValue(String[] args, JsonNode live, PrintStream out) throws IOException {
        if (args.length != 3 || !live.isObject()) {
            usage();
        }
        JsonNode current = live.path("config").path(args[1]);
        if (current.isTextual() && current.asText().equals(args[2])) {
            return 0;
        }
        ObjectNode body = live.deepCopy();
        JsonNode existing = body.get("config");
        ObjectNode config = existing != null && existing.isObject()
                ? (ObjectNode) existing : body.putObject("config");
        config.put(args[1], args[2]);
        out.println(MAPPER.writeValueAsString(body));
        return EXIT_CHANGED;
    }

    private static int refuse(String message) {
        System.err.println(message);
        return EXIT_REFUSED;
    }

    // ------------------------------------------------------------------ user-profile

    /**
     * Specification shape:
     * {
     *   "unmanagedAttributePolicy": "ADMIN_VIEW",
     *   "newAttributeGroup": "user-metadata",
     *   "userViewOnly": ["firstName", "lastName", "email"],
     *   "attributes": [{"name": "...", "displayName": "...", "validations": {"email": {}}}]
     * }
     * Existing attributes, groups, annotations, requirements and validator settings are kept.
     */
    private static int userProfile(JsonNode spec, JsonNode liveInput, PrintStream out) throws IOException {
        if (!liveInput.isObject()) {
            throw new IllegalArgumentException("user-profile expects the live configuration object on stdin");
        }
        ObjectNode live = (ObjectNode) liveInput;
        String before = setAwareCanonical(live);

        String policy = spec.path("unmanagedAttributePolicy").asText("");
        if (!policy.isEmpty()) {
            live.put("unmanagedAttributePolicy", policy);
        }

        ArrayNode attributes = arrayField(live, "attributes");
        String newAttributeGroup = spec.path("newAttributeGroup").asText("");
        if (!newAttributeGroup.isEmpty() && findByName(arrayField(live, "groups"), newAttributeGroup) == null) {
            newAttributeGroup = "";
        }

        for (JsonNode viewOnly : spec.path("userViewOnly")) {
            JsonNode attribute = findByName(attributes, viewOnly.asText());
            if (attribute == null) {
                System.err.println("user-profile: attribute " + viewOnly.asText()
                        + " is not declared in the live configuration; nothing to restrict");
                continue;
            }
            ensureUserViewOnly((ObjectNode) attribute);
        }

        for (JsonNode wanted : spec.path("attributes")) {
            String name = wanted.path("name").asText();
            if (name.isEmpty()) {
                throw new IllegalArgumentException("every attribute in the specification needs a name");
            }
            JsonNode existing = findByName(attributes, name);
            ObjectNode attribute;
            if (existing == null) {
                attribute = attributes.addObject();
                attribute.put("name", name);
                if (wanted.hasNonNull("displayName")) {
                    attribute.put("displayName", wanted.get("displayName").asText());
                }
                attribute.set("validations", wanted.has("validations")
                        ? wanted.get("validations").deepCopy() : MAPPER.createObjectNode());
                attribute.set("annotations", MAPPER.createObjectNode());
                ObjectNode permissions = attribute.putObject("permissions");
                permissions.putArray("view").add(ADMIN).add(USER);
                permissions.putArray("edit").add(ADMIN);
                if (!newAttributeGroup.isEmpty()) {
                    attribute.put("group", newAttributeGroup);
                }
                attribute.put("multivalued", false);
                continue;
            }
            attribute = (ObjectNode) existing;
            ensureUserViewOnly(attribute);
            if (wanted.hasNonNull("displayName") && attribute.path("displayName").asText("").isBlank()) {
                attribute.put("displayName", wanted.get("displayName").asText());
            }
            ObjectNode validations = objectField(attribute, "validations");
            for (Map.Entry<String, JsonNode> validator : wanted.path("validations").properties()) {
                if (!validations.has(validator.getKey())) {
                    validations.set(validator.getKey(), validator.getValue().deepCopy());
                }
            }
        }

        boolean changed = !before.equals(setAwareCanonical(live));
        out.println(MAPPER.writerWithDefaultPrettyPrinter().writeValueAsString(live));
        return changed ? EXIT_CHANGED : 0;
    }

    private static void ensureUserViewOnly(ObjectNode attribute) {
        ObjectNode permissions = objectField(attribute, "permissions");
        ensureStringSet(permissions, "view", List.of(ADMIN, USER));
        ensureStringSet(permissions, "edit", List.of(ADMIN));
    }

    /** Replaces the array only when it differs as a set; Keycloak stores these arrays as sets. */
    private static void ensureStringSet(ObjectNode parent, String field, List<String> wanted) {
        JsonNode current = parent.get(field);
        if (current != null && current.isArray()) {
            List<String> actual = multiset(current);
            List<String> expected = new ArrayList<>();
            for (String value : wanted) {
                expected.add(quote(value));
            }
            expected.sort(null);
            if (actual.equals(expected)) {
                return;
            }
        }
        ArrayNode replacement = parent.putArray(field);
        for (String value : wanted) {
            replacement.add(value);
        }
    }

    private static ObjectNode objectField(ObjectNode parent, String field) {
        JsonNode existing = parent.get(field);
        if (existing != null && existing.isObject()) {
            return (ObjectNode) existing;
        }
        return parent.putObject(field);
    }

    private static ArrayNode arrayField(ObjectNode parent, String field) {
        JsonNode existing = parent.get(field);
        if (existing != null && existing.isArray()) {
            return (ArrayNode) existing;
        }
        return parent.putArray(field);
    }

    /**
     * Canonical form in which arrays of plain strings compare as sets (User Profile permissions,
     * required roles and scopes are sets in Keycloak, so their order on read is not stable).
     */
    private static String setAwareCanonical(JsonNode node) {
        if (node == null || node.isNull() || node.isMissingNode()) {
            return "null";
        }
        if (node.isObject()) {
            TreeMap<String, String> sorted = new TreeMap<>();
            for (Map.Entry<String, JsonNode> field : node.properties()) {
                sorted.put(field.getKey(), setAwareCanonical(field.getValue()));
            }
            StringBuilder text = new StringBuilder("{");
            for (Map.Entry<String, String> field : sorted.entrySet()) {
                text.append(quote(field.getKey())).append(':').append(field.getValue()).append(',');
            }
            return text.append('}').toString();
        }
        if (node.isArray()) {
            List<String> elements = new ArrayList<>();
            boolean allStrings = true;
            for (JsonNode element : node) {
                allStrings &= element.isTextual();
                elements.add(setAwareCanonical(element));
            }
            if (allStrings) {
                elements.sort(null);
            }
            return "[" + String.join(",", elements) + "]";
        }
        return canonical(node);
    }
}
