<#-- The first-login Personal e-mail offer (eskylab-login-ux 21) for a login theme without its own
     page; the SKY LAB login theme draws it in its own design. The texts are this extension's
     messages (theme-resources/messages). -->
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=false; section>
    <#if section = "header">
        ${msg("personalEmailOfferTitle")}
    <#elseif section = "form">
        <p id="sky-offer-description">${msg("personalEmailOfferDescription")}</p>
        <#if skyOfferError?? && skyOfferError?has_content>
            <div id="sky-offer-error" class="${properties.kcAlertClass!} pf-m-danger" role="alert">
                <span class="${properties.kcAlertTitleClass!}">${msg("personalEmailOfferError." + skyOfferError, (skyOfferAttemptsLeft!""))}</span>
            </div>
        </#if>
        <form id="kc-personal-email-offer-form" action="${url.loginAction}" method="post">
            <#if (skyOfferStage!"address") == "code">
                <p id="sky-offer-code-sent">${msg("personalEmailOfferCodeSent", (skyOfferAddress!""), (skyOfferCodeMinutes!"10"))}</p>
                <div class="${properties.kcFormGroupClass!}">
                    <label for="sky-offer-code" class="${properties.kcLabelClass!}">${msg("personalEmailOfferCodeLabel")}</label>
                    <input id="sky-offer-code" name="code" type="text" inputmode="numeric" autocomplete="one-time-code"
                           maxlength="12" class="${properties.kcInputClass!}" autofocus/>
                </div>
                <div class="${properties.kcFormButtonsWrapperClass!}">
                    <button type="submit" name="sky-offer-action" value="verify"
                            class="${properties.kcButtonClass!} ${properties.kcButtonPrimaryClass!} ${properties.kcButtonBlockClass!}">${msg("personalEmailOfferVerify")}</button>
                    <button type="submit" name="sky-offer-action" value="change"
                            class="${properties.kcButtonClass!} ${properties.kcButtonDefaultClass!} ${properties.kcButtonBlockClass!}">${msg("personalEmailOfferChange")}</button>
                </div>
            <#else>
                <div class="${properties.kcFormGroupClass!}">
                    <label for="sky-offer-address" class="${properties.kcLabelClass!}">${msg("personalEmailOfferAddressLabel")}</label>
                    <input id="sky-offer-address" name="address" type="email" autocomplete="email" maxlength="255"
                           value="${skyOfferAddress!""}" class="${properties.kcInputClass!}" autofocus/>
                </div>
                <div class="${properties.kcFormButtonsWrapperClass!}">
                    <button type="submit" name="sky-offer-action" value="send"
                            class="${properties.kcButtonClass!} ${properties.kcButtonPrimaryClass!} ${properties.kcButtonBlockClass!}">${msg("personalEmailOfferSend")}</button>
                </div>
            </#if>
            <p class="${properties.kcFormHelperTextClass!}">${msg("personalEmailOfferPrimaryNote")}</p>
            <div class="${properties.kcFormButtonsWrapperClass!}">
                <button type="submit" name="sky-offer-action" value="skip" formnovalidate
                        class="${properties.kcButtonClass!} ${properties.kcButtonDefaultClass!} ${properties.kcButtonBlockClass!}">${msg("personalEmailOfferSkip")}</button>
            </div>
        </form>
    </#if>
</@layout.registrationLayout>
