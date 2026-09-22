package com.skylab.handoff;

import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

import java.util.Map;

/**
 * The page a failed Web handoff lands on inside the WebView ({@code v1/failed?reason=}). This is
 * the plain placeholder until the themed page ships; its path and reason codes are stable because
 * SkyApp may watch for them. It offers no login form and no link to the Keycloak login, and it
 * only ever prints one of the fixed sentences of {@link FailureReason}, never the query value.
 */
final class FailurePage {

    static final String CONTENT_SECURITY_POLICY =
            "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

    private FailurePage() {
    }

    /** Every header of the page: never cached, never framed, no referrer, no active content. */
    static final Map<String, String> HEADERS = Map.of(
            HttpHeaders.CACHE_CONTROL, "no-store",
            "X-Frame-Options", "DENY",
            "X-Content-Type-Options", "nosniff",
            "Referrer-Policy", "no-referrer",
            "Content-Security-Policy", CONTENT_SECURITY_POLICY);

    static Response render(FailureReason reason) {
        Response.ResponseBuilder builder = Response.ok(html(reason), MediaType.TEXT_HTML_TYPE.withCharset("UTF-8"));
        HEADERS.forEach(builder::header);
        return builder.build();
    }

    static String html(FailureReason reason) {
        return """
                <!doctype html>
                <html lang="tr">
                <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <meta name="robots" content="noindex">
                <title>SKY LAB</title>
                <style>
                body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;\
                font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:#0b1020;color:#f4f6fb}
                main{max-width:28rem;padding:2rem;text-align:center}
                h1{font-size:1.25rem;font-weight:600;margin:0 0 .75rem}
                p{margin:0;color:#c7cbe0}
                </style>
                </head>
                <body>
                <main data-reason="%s">
                <h1>%s</h1>
                <p>%s</p>
                </main>
                </body>
                </html>
                """.formatted(reason.code(), reason.message(), FailureReason.RETRY_HINT);
    }
}
