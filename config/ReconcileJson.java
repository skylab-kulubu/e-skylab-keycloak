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
 *                               or "finish<TAB>id" (an interrupted swap left both side by side:
 *                               delete id). Anything else is refused with exit status 4.
 *
 * Exit status 0 means "printed successfully", 3 means "changed" (user-profile only), 4 "refused"
 * (password-form only) and 1 an invalid input. Nothing here prints secrets: all inputs are
 * configuration documents.
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
            default -> usage();
        }
    }

    private static void usage() {
        System.err.println("usage: ReconcileJson diff-fields|mapper-diff|user-profile FILE"
                + "  |  ReconcileJson merge BASE EXTRA  |  ReconcileJson names|scope-mappings"
                + "  |  ReconcileJson field NAME  |  ReconcileJson role-attribute NAME"
                + "  |  ReconcileJson realm-attribute NAME VALUE"
                + "  |  ReconcileJson password-form FROM TO");
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
            if (old.parent().equals(added.parent()) && old.priority() == added.priority()
                    && "REQUIRED".equals(old.requirement()) && "REQUIRED".equals(added.requirement())) {
                out.println("finish\t" + old.id());
                return 0;
            }
        }
        return refuse("expected exactly one of " + from + " and " + to + ", found "
                + fromList.size() + " " + from + " and " + toList.size() + " " + to);
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
