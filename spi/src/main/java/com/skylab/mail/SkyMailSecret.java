package com.skylab.mail;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * The client secret of the {@code keycloak-mailer} service account. The value is read from its
 * mounted file on every token request, so an operator can rotate the secret without restarting
 * Keycloak, and it is never held in a field, printed by {@link #toString()} or logged.
 */
final class SkyMailSecret {

    /** Largest accepted secret file; a Keycloak client secret is a few dozen characters. */
    private static final int MAX_SECRET_BYTES = 4_096;

    private final Path file;
    private final String literal;

    private SkyMailSecret(Path file, String literal) {
        this.file = file;
        this.literal = literal;
    }

    static SkyMailSecret ofFile(Path file) {
        return new SkyMailSecret(file, null);
    }

    /** Only the integration harness ({@code SKY_HARNESS=1}) may pass the secret in an env var. */
    static SkyMailSecret ofLiteral(String literal) {
        return new SkyMailSecret(null, literal);
    }

    /**
     * The secret without its trailing newline. Operators write the file with {@code printf} or a
     * here-document, so both a bare value and a value followed by a newline are accepted.
     */
    String read() throws IOException {
        if (literal != null) {
            return literal;
        }
        if (Files.size(file) > MAX_SECRET_BYTES) {
            throw new IOException("The SkyMail client secret file is larger than expected.");
        }
        String value = stripTrailingNewlines(Files.readString(file, StandardCharsets.UTF_8));
        if (value.isEmpty()) {
            throw new IOException("The SkyMail client secret file is empty.");
        }
        return value;
    }

    static String stripTrailingNewlines(String value) {
        int end = value.length();
        while (end > 0 && (value.charAt(end - 1) == '\n' || value.charAt(end - 1) == '\r')) {
            end--;
        }
        return value.substring(0, end);
    }

    Path file() {
        return file;
    }

    @Override
    public String toString() {
        return "SkyMailSecret[redacted]";
    }
}
