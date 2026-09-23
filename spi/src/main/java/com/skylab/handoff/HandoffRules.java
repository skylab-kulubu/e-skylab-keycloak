package com.skylab.handoff;

import java.net.URI;
import java.net.URISyntaxException;
import java.util.Locale;
import java.util.Optional;
import java.util.regex.Pattern;

/**
 * The validation rules of a Web handoff, shared by every step that reads or writes a Handoff
 * target, so a target is judged the same way whenever a code for it is minted or redeemed.
 */
final class HandoffRules {

    static final int MAX_PATH_LENGTH = 512;
    static final int MAX_SIGN_IN_PATH_LENGTH = 128;

    /** Only SKY LAB's own origins may receive a browser session: {@code yildizskylab.com} and its subdomains. */
    private static final Pattern HOST = Pattern.compile(
            "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)*yildizskylab\\.com$");
    private static final Pattern SIGN_IN_PATH = Pattern.compile("^/([A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*/?)?$");
    private static final Pattern RETURN_PARAM = Pattern.compile("^[A-Za-z][A-Za-z0-9_]{0,31}$");
    /** Visible ASCII only: raw spaces, control characters and non-ASCII must arrive percent-encoded. */
    private static final Pattern VISIBLE_ASCII = Pattern.compile("^[\\x21-\\x7E]+$");
    /**
     * Percent-encoded slash, backslash, dot and control characters: a target that decodes the
     * return value once more would turn them into {@code //}, {@code \}, {@code ..} or a header break.
     */
    private static final Pattern DANGEROUS_ESCAPE = Pattern.compile("%(2[eEfF]|5[cC]|[01][0-9a-fA-F]|7[fF])");

    private HandoffRules() {
    }

    /**
     * The normalised origin ({@code https://host}) of a client {@code rootUrl}, or empty when the
     * root URL is not {@code https}, not on {@code yildizskylab.com} or a subdomain, or carries
     * user info, a port, a path other than {@code /}, a query or a fragment.
     */
    static Optional<String> origin(String rootUrl) {
        if (rootUrl == null || rootUrl.isEmpty() || !rootUrl.startsWith("https://")) {
            return Optional.empty();
        }
        final URI uri;
        try {
            uri = new URI(rootUrl);
        } catch (URISyntaxException exception) {
            return Optional.empty();
        }
        if (!"https".equals(uri.getScheme())
                || uri.getRawUserInfo() != null
                || uri.getPort() != -1
                || uri.getRawQuery() != null
                || uri.getRawFragment() != null
                || !(uri.getRawPath() == null || uri.getRawPath().isEmpty() || "/".equals(uri.getRawPath()))
                || uri.getHost() == null
                || !uri.getRawAuthority().equals(uri.getHost())) {
            return Optional.empty();
        }
        String host = uri.getHost().toLowerCase(Locale.ROOT);
        if (!HOST.matcher(host).matches()) {
            return Optional.empty();
        }
        return Optional.of("https://" + host);
    }

    /** A sign-in entry path: absolute, plain segments, no {@code //}, {@code ..}, {@code .} segment, query or fragment. */
    static boolean isSignInPath(String signInPath) {
        if (signInPath == null || signInPath.length() > MAX_SIGN_IN_PATH_LENGTH
                || !SIGN_IN_PATH.matcher(signInPath).matches() || signInPath.contains("..")) {
            return false;
        }
        for (String segment : signInPath.split("/")) {
            if (segment.equals(".")) {
                return false;
            }
        }
        return true;
    }

    /** The name of the query parameter that carries the path to the target's sign-in entry. */
    static boolean isReturnParam(String name) {
        return name != null && RETURN_PARAM.matcher(name).matches();
    }

    /**
     * The path the person should land on, relative to the target: starts with {@code /}, at most
     * {@value #MAX_PATH_LENGTH} characters of visible ASCII, no {@code //}, {@code \}, {@code ..}
     * and no percent-encoded slash, backslash, dot or control character. A scheme cannot appear
     * because the value starts with a single slash.
     */
    static boolean isRelativePath(String path) {
        return path != null
                && !path.isEmpty()
                && path.length() <= MAX_PATH_LENGTH
                && path.charAt(0) == '/'
                && VISIBLE_ASCII.matcher(path).matches()
                && !path.contains("//")
                && !path.contains("\\")
                && !path.contains("..")
                && !DANGEROUS_ESCAPE.matcher(path).find();
    }
}
