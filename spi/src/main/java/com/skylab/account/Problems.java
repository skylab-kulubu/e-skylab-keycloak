package com.skylab.account;

import java.util.List;

/**
 * The closed catalogue of sky-account problems. Codes are part of the BFF contract
 * (see docs/sky-account-api.md); details are the Turkish sentences the person may see.
 */
final class Problems {

    private Problems() {
    }

    static Problem unauthorized(String realmName) {
        return new Problem(401, "unauthorized", "Unauthorized",
                "Bu istek için geçerli bir Hesap Merkezi oturumu gerekiyor.")
                .withHeader("WWW-Authenticate", "Bearer realm=\"" + realmName + "\", error=\"invalid_token\"");
    }

    static Problem sudoRequired() {
        return new Problem(401, "sudo_required", "Re-authentication required",
                "Bu işlem için kimliğini yeniden doğrulaman gerekiyor.");
    }

    static Problem sudoExpired() {
        return new Problem(401, "sudo_expired", "Re-authentication expired",
                "Yeniden doğrulamanın süresi doldu. Lütfen tekrar doğrula.");
    }

    static Problem invalidPassword() {
        return new Problem(401, "invalid_credentials", "Invalid credentials",
                "Parola yanlış.");
    }

    static Problem invalidTotp() {
        return new Problem(401, "invalid_credentials", "Invalid credentials",
                "Doğrulama kodu geçersiz.");
    }

    static Problem temporarilyLocked() {
        return new Problem(401, "user_temporarily_locked", "Account temporarily locked",
                "Çok fazla başarısız deneme yapıldı. Hesap geçici olarak kilitlendi; bir süre sonra yeniden dene.");
    }

    static Problem permanentlyLocked() {
        return new Problem(401, "user_disabled", "Account disabled",
                "Hesap devre dışı bırakıldı. Yönetimle iletişime geç.");
    }

    static Problem rateLimited(int retryAfterSeconds) {
        return new Problem(429, "rate_limited", "Too many attempts",
                "Çok fazla deneme yapıldı. Lütfen daha sonra tekrar dene.")
                .withExtension("retryAfter", retryAfterSeconds)
                .withHeader("Retry-After", String.valueOf(retryAfterSeconds));
    }

    static Problem invalidRequest(String field) {
        Problem problem = new Problem(400, "invalid_request", "Invalid request",
                "İstek geçersiz.");
        return field == null ? problem : problem.withExtension("field", field);
    }

    static Problem passwordNotConfigured() {
        return new Problem(400, "password_not_configured", "No password on this account",
                "Bu hesapta parola tanımlı değil.");
    }

    static Problem totpNotConfigured() {
        return new Problem(400, "totp_not_configured", "No authenticator app on this account",
                "Bu hesapta doğrulama uygulaması tanımlı değil.");
    }

    static Problem passwordPolicy(String policyMessageKey, List<Object> params, String localizedDetail) {
        return new Problem(400, "password_policy", "New password violates the password policy", localizedDetail)
                .withExtension("policy", policyMessageKey)
                .withExtension("params", params);
    }

    static Problem passwordRejected(String localizedDetail) {
        return new Problem(400, "password_rejected", "New password rejected", localizedDetail);
    }

    static Problem totpSetupExpired() {
        return new Problem(400, "totp_setup_expired", "Authenticator setup expired",
                "Doğrulama uygulaması kurulumunun süresi doldu. Kurulumu yeniden başlat.");
    }

    static Problem invalidTotpSetupCode() {
        return new Problem(400, "invalid_totp_code", "Invalid authenticator code",
                "Doğrulama kodu geçersiz. Uygulamadaki güncel kodu gir.");
    }

    static Problem duplicateLabel() {
        return new Problem(409, "duplicate_label", "Label already used",
                "Bu adla kayıtlı bir doğrulama yöntemi zaten var. Başka bir ad seç.");
    }

    static Problem credentialNotFound() {
        return new Problem(404, "credential_not_found", "Credential not found",
                "Kimlik bilgisi bulunamadı.");
    }

    static Problem invalidName(String field) {
        return new Problem(400, "invalid_name", "Invalid name",
                "Ad ve soyad boş olamaz, en fazla 64 karakter olabilir ve <>&\"$%!#?§;*~/\\|^=[]{}() "
                        + "karakterlerini içeremez.")
                .withExtension("field", field);
    }

    static Problem nameLocked() {
        return new Problem(403, "name_locked", "Name is locked",
                "Doğrulanmış YTÜ hesaplarında ad ve soyad YTÜ kayıtlarından gelir; buradan değiştirilemez.");
    }

    static Problem invalidUsername() {
        return new Problem(400, "invalid_username", "Invalid username",
                "Kullanıcı adı 3-30 karakter olmalı ve yalnızca küçük harf, rakam, nokta ve alt çizgi içermeli.")
                .withExtension("field", "username");
    }

    static Problem usernameTaken() {
        return new Problem(409, "username_taken", "Username already in use",
                "Bu kullanıcı adı kullanımda. Başka bir kullanıcı adı seç.");
    }

    static Problem usernameCooldown(int retryAfterSeconds, String availableAt) {
        return new Problem(409, "username_cooldown", "Username changed recently",
                "Kullanıcı adı 14 günde bir değiştirilebilir. Bir sonraki değişiklik için biraz daha bekle.")
                .withExtension("retryAfter", retryAfterSeconds)
                .withExtension("availableAt", availableAt)
                .withHeader("Retry-After", String.valueOf(retryAfterSeconds));
    }

    static Problem unmanagedAttributesEnabled() {
        return new Problem(503, "unmanaged_attributes_enabled", "Account changes are paused",
                "Hesap değişiklikleri geçici olarak kapalı: realm yapılandırması yönetilmeyen özniteliklerin "
                        + "kişi tarafından düzenlenmesine izin veriyor. Yönetimle iletişime geç.");
    }

    static Problem internalError() {
        return new Problem(500, "internal_error", "Internal error",
                "Beklenmeyen bir hata oluştu. Lütfen daha sonra tekrar dene.");
    }
}
