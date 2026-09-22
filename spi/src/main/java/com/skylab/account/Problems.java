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

    /** The ID token verified, but the authentication behind it is older than the Sudo mode window. */
    static Problem authenticationStale() {
        return new Problem(401, "authentication_stale", "Authentication too old",
                "Girişin üzerinden beş dakikadan fazla geçti. Kimliğini yeniden doğrula.");
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

    static Problem passkeyNotRegistered() {
        return new Problem(400, "passkey_not_registered", "No passkey on this account",
                "Bu hesapta kayıtlı bir passkey yok.");
    }

    static Problem webAuthnNotConfigured() {
        return new Problem(503, "webauthn_not_configured", "Passkeys are unavailable",
                "Passkey desteği bu sunucuda kapalı. Yönetimle iletişime geç.");
    }

    static Problem webAuthnChallengeExpired() {
        return new Problem(400, "webauthn_challenge_expired", "Passkey ceremony expired",
                "Passkey işleminin süresi doldu ya da işlem zaten kullanıldı. Yeniden başlat.");
    }

    /** The attestation or assertion did not verify; {@code status} is 400 on registration, 401 on sudo. */
    static Problem webAuthnInvalid(int status) {
        return new Problem(status, "webauthn_invalid", "Passkey verification failed",
                "Passkey doğrulanamadı. Yeniden dene.");
    }

    /** The browser ran the ceremony on an origin the realm passwordless policy does not allow. */
    static Problem webAuthnOriginNotAllowed(int status) {
        return new Problem(status, "webauthn_origin_not_allowed", "Origin not allowed for passkeys",
                "Passkey işlemi izin verilmeyen bir adresten başlatıldı.");
    }

    static Problem passkeyAlreadyRegistered() {
        return new Problem(409, "passkey_already_registered", "Passkey already registered",
                "Bu passkey zaten hesabında kayıtlı.");
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

    static Problem emailTaken() {
        return new Problem(409, "email_taken", "E-mail address already in use",
                "Bu e-posta adresi başka bir hesapta kayıtlı. Başka bir adres dene.");
    }

    /** The address exists but nobody proved it, so it cannot become the Primary e-mail. */
    static Problem emailNotVerified() {
        return new Problem(409, "email_not_verified", "E-mail address is not verified",
                "Bu e-posta adresi doğrulanmadı. Önce adrese gönderilen bağlantıyla doğrula.");
    }

    /** The verification link is unknown, already used, expired or belongs to another person. */
    static Problem invalidEmailCode(int attemptsLeft) {
        return new Problem(400, "invalid_email_code", "Invalid verification code",
                attemptsLeft > 0
                        ? "Doğrulama kodu yanlış. " + attemptsLeft + " deneme hakkın kaldı."
                        : "Doğrulama kodu yanlış ve deneme hakkın bitti. Yeni bir kod iste.")
                .withExtension("attemptsLeft", attemptsLeft);
    }

    static Problem noPendingEmailChange() {
        return new Problem(404, "no_pending_email_change", "No verification code is waiting",
                "Bekleyen bir doğrulama kodu yok: süresi dolmuş ya da zaten kullanılmış olabilir. Yeni bir kod iste.");
    }

    static Problem noFallbackEmail() {
        return new Problem(409, "no_fallback_email", "No address left to be primary",
                "Kişisel e-posta şu anda birincil adresin ve hesabında okul e-postası yok; "
                        + "kaldırılırsa giriş yapabileceğin bir adres kalmaz.");
    }

    static Problem emailNotSent() {
        return new Problem(503, "email_not_sent", "Verification mail could not be sent",
                "Doğrulama e-postası gönderilemedi. Lütfen daha sonra tekrar dene.");
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
