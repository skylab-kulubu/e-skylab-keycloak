package com.skylab.handoff;

import java.util.Arrays;

/**
 * Why a Web handoff could not be completed inside the WebView. The code is the stable value of
 * the {@code reason} parameter of {@code v1/failed} (SkyApp may watch for it); the message is
 * the Turkish sentence the person reads there.
 */
enum FailureReason {
    EXPIRED("expired", "Bağlantının süresi doldu."),
    USED("used", "Bu bağlantı zaten kullanıldı."),
    INVALID("invalid", "Bağlantı geçersiz."),
    TARGET_DISABLED("target_disabled", "Bu siteye uygulamadan geçiş şu an kapalı."),
    ACCOUNT_UNAVAILABLE("account_unavailable", "Hesabın şu an kullanılamıyor."),
    UNAVAILABLE("unavailable", "Geçici bir sorun oluştu.");

    static final String RETRY_HINT = "Uygulamaya dönüp tekrar dene.";

    private final String code;
    private final String message;

    FailureReason(String code, String message) {
        this.code = code;
        this.message = message;
    }

    String code() {
        return code;
    }

    String message() {
        return message;
    }

    /** The reason for a {@code reason} query value; anything unknown is {@link #UNAVAILABLE}. */
    static FailureReason fromCode(String code) {
        return Arrays.stream(values())
                .filter(reason -> reason.code.equals(code))
                .findFirst()
                .orElse(UNAVAILABLE);
    }
}
