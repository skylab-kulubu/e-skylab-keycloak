package com.skylab.handoff;

import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.Response;
import org.keycloak.util.JsonSerialization;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * An RFC 7807 problem of the sky-handoff JSON endpoints: a stable English {@code code} that
 * SkyApp and superadmin branch on and a Turkish {@code detail} a person may read. It never
 * carries a token, a code, a proof or a path.
 */
record HandoffProblem(int status, String code, String title, String detail, Map<String, String> headers) {

    static final String MEDIA_TYPE = "application/problem+json";
    static final String TYPE_PREFIX = "tag:yildizskylab.com,2026:sky-handoff:";

    HandoffProblem {
        headers = Map.copyOf(headers);
    }

    HandoffProblem(int status, String code, String title, String detail) {
        this(status, code, title, detail, Map.of());
    }

    HandoffProblem withHeader(String name, String value) {
        Map<String, String> next = new LinkedHashMap<>(headers);
        next.put(name, value);
        return new HandoffProblem(status, code, title, detail, next);
    }

    Raised exception() {
        return new Raised(this);
    }

    /** The {@code application/problem+json} document. */
    String body() {
        ObjectNode body = JsonSerialization.mapper.createObjectNode();
        body.put("type", TYPE_PREFIX + code);
        body.put("title", title);
        body.put("status", status);
        body.put("detail", detail);
        body.put("code", code);
        return body.toString();
    }

    Response toResponse() {
        Response.ResponseBuilder builder = Response.status(status)
                .type(MEDIA_TYPE)
                .header(HttpHeaders.CACHE_CONTROL, "no-store")
                .entity(body());
        headers.forEach(builder::header);
        return builder.build();
    }

    static HandoffProblem invalidToken(String realmName) {
        return new HandoffProblem(401, "invalid_token", "Unauthorized",
                "Bu istek için geçerli bir oturum gerekiyor.")
                .withHeader("WWW-Authenticate", "Bearer realm=\"" + realmName + "\", error=\"invalid_token\"");
    }

    static HandoffProblem invalidRequest() {
        return new HandoffProblem(400, "invalid_request", "Invalid request", "İstek geçersiz.");
    }

    static HandoffProblem invalidTarget() {
        return new HandoffProblem(400, "invalid_target", "Invalid handoff target",
                "Bu siteye uygulamadan geçiş açık değil.");
    }

    static HandoffProblem invalidPath() {
        return new HandoffProblem(400, "invalid_path", "Invalid path",
                "Açılmak istenen sayfa adresi geçersiz.");
    }

    static HandoffProblem rateLimited(int retryAfterSeconds) {
        return new HandoffProblem(429, "rate_limited", "Too many handoffs",
                "Çok fazla deneme yapıldı. Lütfen daha sonra tekrar dene.")
                .withHeader("Retry-After", String.valueOf(retryAfterSeconds));
    }

    /** Every authenticated caller who is not a super admin gets exactly this body. */
    static HandoffProblem forbidden() {
        return new HandoffProblem(403, "forbidden", "Forbidden",
                "Bu işlem için SKY LAB süper yönetici yetkisi gerekiyor.");
    }

    static HandoffProblem clientNotFound() {
        return new HandoffProblem(404, "client_not_found", "Client not found",
                "Bu istemci bulunamadı.");
    }

    static HandoffProblem invalidSignInPath() {
        return new HandoffProblem(400, "invalid_sign_in_path", "Invalid sign-in path",
                "Giriş kapısı yolu / ile başlamalı; //, \\, .., sorgu ve # içeremez; yalnız harf, rakam, . _ ~ - "
                        + "ve / kullanılabilir. Açık bir hedef için zorunludur.");
    }

    static HandoffProblem invalidReturnParam() {
        return new HandoffProblem(400, "invalid_return_param", "Invalid return parameter",
                "Dönüş parametresi harfle başlamalı, yalnız harf, rakam ve _ içermeli ve en çok 32 karakter olmalı. "
                        + "Açık bir hedef için zorunludur.");
    }

    static HandoffProblem originNotAllowed() {
        return new HandoffProblem(400, "origin_not_allowed", "Origin not allowed",
                "Bu istemcinin kök adresi https:// ile yildizskylab.com ya da bir alt alan adında olmalı; kullanıcı "
                        + "bilgisi, port, yol, sorgu ve # içeremez. Bu haliyle uygulamadan geçişe açılamaz.");
    }

    static HandoffProblem internalError() {
        return new HandoffProblem(500, "internal_error", "Internal error",
                "Beklenmeyen bir hata oluştu. Lütfen daha sonra tekrar dene.");
    }

    /**
     * Carries a problem out of a guard or a validation step; the endpoint turns it into its
     * response, so Keycloak's error mapper and transaction rollback never see it.
     */
    static final class Raised extends RuntimeException {

        private final transient HandoffProblem problem;

        Raised(HandoffProblem problem) {
            super(problem.code(), null, false, false);
            this.problem = problem;
        }

        HandoffProblem problem() {
            return problem;
        }
    }
}
