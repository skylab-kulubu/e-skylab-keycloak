package com.skylab.mail;

/**
 * Why a mail left over Keycloak's own SMTP instead of SkyMail. The vocabulary is fixed and
 * closed: it is the only thing {@code sky_mail_fallback} logs about a mail, so no address, link,
 * token or secret can reach the log through it.
 */
enum SkyMailFallback {

    /** {@code SKY_MAIL_ENABLED} is false, or the secret file was missing or empty at startup. */
    DISABLED("disabled"),
    /** Keycloak sent a mail this provider does not template, such as the SMTP test mail. */
    NOT_MAPPED("not_mapped"),
    /** The realm issuer could not be resolved, so there was no token endpoint to call. */
    CONFIG("config"),
    /** The client-credentials token could not be obtained. */
    TOKEN("token"),
    /** SkyMail answered 404: the system template key is unknown or archived. */
    TEMPLATE_MISSING("template_missing"),
    /** SkyMail rejected the request (any other 4xx, or a 2xx that was not 201). */
    REFUSED("refused"),
    /** SkyMail answered 5xx. */
    UNAVAILABLE("unavailable"),
    /** SkyMail did not answer inside the request budget. */
    TIMEOUT("timeout"),
    /** SkyMail could not be reached. */
    TRANSPORT("transport"),
    /** SkyMail answered 201 without a usable mail task id. */
    RESPONSE("response");

    private final String reason;

    SkyMailFallback(String reason) {
        this.reason = reason;
    }

    String reason() {
        return reason;
    }

    /**
     * True when the fallback is an incident an operator should see. A disabled provider and an
     * untemplated mail are the configured behaviour, not a failure.
     */
    boolean isFailure() {
        return this != DISABLED && this != NOT_MAPPED;
    }
}
