<#-- "E-postayla devam et": sign-in with a Login code (sky-email-code, eskylab-login-ux 08) for a login
     theme without its own page; the SKY LAB login theme draws it in its own design. The texts are
     this extension's messages (theme-resources/messages). The same page is shown whether or not
     the typed address or username belongs to an account. -->
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=true; section>
    <#if section = "header">
        ${msg("emailCodeTitle")}
    <#elseif section = "form">
        <#if skyEmailCodeError?? && skyEmailCodeError?has_content>
            <div id="sky-email-code-error" data-sky-email-code-error="${skyEmailCodeError}" class="${properties.kcAlertClass!} pf-m-danger" role="alert">
                <span class="${properties.kcAlertTitleClass!}">${msg("emailCodeError." + skyEmailCodeError, (skyEmailCodeAttemptsLeft!""))}</span>
            </div>
        </#if>
        <#if (skyEmailCodeStage!"identifier") == "code">
            <p id="sky-email-code-sent">${msg("emailCodeSent", (skyEmailCodeMinutes!"10"))}</p>
            <#if skyEmailCodeIdentifier?? && skyEmailCodeIdentifier?has_content>
                <p id="sky-email-code-identifier" class="${properties.kcFormHelperTextClass!}">${msg("emailCodeFor", skyEmailCodeIdentifier)}</p>
            </#if>
            <form id="kc-email-code-form" action="${url.loginAction}" method="post">
                <div class="${properties.kcFormGroupClass!}">
                    <label for="sky-email-code" class="${properties.kcLabelClass!}">${msg("emailCodeCodeLabel")}</label>
                    <input id="sky-email-code" name="code" type="text" inputmode="numeric" autocomplete="one-time-code"
                           maxlength="20" class="${properties.kcInputClass!}" autofocus/>
                </div>
                <div class="${properties.kcFormButtonsWrapperClass!}">
                    <button type="submit" name="sky-email-code-action" value="verify"
                            class="${properties.kcButtonClass!} ${properties.kcButtonPrimaryClass!} ${properties.kcButtonBlockClass!}">${msg("emailCodeVerify")}</button>
                    <button type="submit" name="sky-email-code-action" value="resend" formnovalidate
                            data-sky-email-code-resend-after="${skyEmailCodeResendAfter!"0"}"
                            class="${properties.kcButtonClass!} ${properties.kcButtonDefaultClass!} ${properties.kcButtonBlockClass!}">${msg("emailCodeResend")}</button>
                    <button type="submit" name="sky-email-code-action" value="change" formnovalidate
                            class="${properties.kcButtonClass!} ${properties.kcButtonDefaultClass!} ${properties.kcButtonBlockClass!}">${msg("emailCodeChange")}</button>
                </div>
            </form>
        <#else>
            <form id="kc-email-code-identifier-form" action="${url.loginAction}" method="post">
                <div class="${properties.kcFormGroupClass!}">
                    <label for="username" class="${properties.kcLabelClass!}">${msg("emailCodeIdentifierLabel")}</label>
                    <input id="username" name="username" type="text" autocomplete="username" maxlength="255"
                           value="${skyEmailCodeIdentifier!""}" class="${properties.kcInputClass!}" autofocus/>
                </div>
                <div class="${properties.kcFormButtonsWrapperClass!}">
                    <button type="submit" name="sky-email-code-action" value="send"
                            class="${properties.kcButtonClass!} ${properties.kcButtonPrimaryClass!} ${properties.kcButtonBlockClass!}">${msg("emailCodeSend")}</button>
                </div>
            </form>
        </#if>
    </#if>
</@layout.registrationLayout>
