package com.skylab.handoff;

import org.keycloak.models.ClientModel;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.Optional;

/**
 * A Keycloak client that a Web handoff may land on. The three {@code sky.handoff.*} client
 * attributes make a client a target; the entry is built from the client's own {@code rootUrl}
 * and never from its redirect URIs, so no wildcard redirect URI is ever needed.
 *
 * @param clientId    the target's {@code client_id}
 * @param origin      the normalised {@code https://host} of the client's {@code rootUrl}
 * @param signInPath  the target's sign-in entry path on that origin
 * @param returnParam the query parameter of the sign-in entry that carries the path
 */
record HandoffTarget(String clientId, String origin, String signInPath, String returnParam) {

    static final String ENABLED_ATTRIBUTE = "sky.handoff.enabled";
    static final String SIGN_IN_PATH_ATTRIBUTE = "sky.handoff.signInPath";
    static final String RETURN_PARAM_ATTRIBUTE = "sky.handoff.returnParam";

    /**
     * @return the target when the client is enabled, {@code sky.handoff.enabled} is exactly
     *         {@code true}, its root URL satisfies the origin rule and both entry attributes are
     *         valid; otherwise empty
     */
    static Optional<HandoffTarget> of(ClientModel client) {
        if (client == null || !client.isEnabled() || !"true".equals(client.getAttribute(ENABLED_ATTRIBUTE))) {
            return Optional.empty();
        }
        String signInPath = client.getAttribute(SIGN_IN_PATH_ATTRIBUTE);
        String returnParam = client.getAttribute(RETURN_PARAM_ATTRIBUTE);
        if (!HandoffRules.isSignInPath(signInPath) || !HandoffRules.isReturnParam(returnParam)) {
            return Optional.empty();
        }
        return HandoffRules.origin(client.getRootUrl())
                .map(origin -> new HandoffTarget(client.getClientId(), origin, signInPath, returnParam));
    }

    /** {@code origin + signInPath + ?returnParam=<path>}, the path encoded as one query value. */
    String entry(String path) {
        return origin + signInPath + "?" + returnParam + "="
                + URLEncoder.encode(path, StandardCharsets.UTF_8).replace("+", "%20");
    }
}
