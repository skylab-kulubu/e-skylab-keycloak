<#-- Self-registration on "E-postayla devam et" (sky-email-code, eskylab-login-ux 09) for a login theme
     without its own page; the SKY LAB login theme draws it in its own design. It opens only after the
     right code proved the address. Stages: form (the names), ytu (a school address: the YTÜ sign-in
     instead), existing ("Hesap aç" for an address that has an account: signed in), unavailable. The
     texts are this extension's messages (theme-resources/messages). -->
<#import "template.ftl" as layout>
<#assign stage = skySignUpStage!"form">
<@layout.registrationLayout displayMessage=false; section>
    <#if section = "header">
        <#if stage == "ytu">${msg("emailCodeSignUpYtuTitle")}
        <#elseif stage == "existing">${msg("emailCodeSignUpExistingTitle")}
        <#elseif stage == "unavailable">${msg("emailCodeSignUpUnavailableTitle")}
        <#else>${msg("emailCodeSignUpTitle")}
        </#if>
    <#elseif section = "form">
        <div id="sky-sign-up" data-sky-sign-up-stage="${stage}">
        <#if stage == "ytu">
            <p id="sky-sign-up-ytu-text">${msg("emailCodeSignUpYtuText", (skySignUpAddress!""))}</p>
            <#if social?? && social.providers??>
                <#list social.providers as provider>
                    <#if provider.alias == (skySignUpYtuAlias!"")>
                        <a id="sky-sign-up-ytu" href="${provider.loginUrl}"
                           class="${properties.kcButtonClass!} ${properties.kcButtonPrimaryClass!} ${properties.kcButtonBlockClass!}">${msg("emailCodeSignUpYtuButton")}</a>
                    </#if>
                </#list>
            </#if>
            <form id="kc-email-code-sign-up-ytu-form" action="${url.loginAction}" method="post">
                <button type="submit" name="sky-email-code-action" value="change" formnovalidate
                        class="${properties.kcButtonClass!} ${properties.kcButtonDefaultClass!} ${properties.kcButtonBlockClass!}">${msg("emailCodeSignUpChange")}</button>
            </form>
        <#elseif stage == "existing">
            <p id="sky-sign-up-existing-text">${msg("emailCodeSignUpExistingText")}</p>
            <form id="kc-email-code-sign-up-existing-form" action="${url.loginAction}" method="post">
                <button type="submit" name="sky-email-code-action" value="continue"
                        class="${properties.kcButtonClass!} ${properties.kcButtonPrimaryClass!} ${properties.kcButtonBlockClass!}">${msg("emailCodeSignUpContinue")}</button>
            </form>
        <#elseif stage == "unavailable">
            <p id="sky-sign-up-unavailable-text">${msg("emailCodeSignUpUnavailableText")}</p>
            <form id="kc-email-code-sign-up-unavailable-form" action="${url.loginAction}" method="post">
                <button type="submit" name="sky-email-code-action" value="change" formnovalidate
                        class="${properties.kcButtonClass!} ${properties.kcButtonDefaultClass!} ${properties.kcButtonBlockClass!}">${msg("emailCodeSignUpChange")}</button>
            </form>
        <#else>
            <#if skySignUpError?? && skySignUpError?has_content>
                <div id="sky-sign-up-error" data-sky-sign-up-error="${skySignUpError}" class="${properties.kcAlertClass!} pf-m-danger" role="alert">
                    <span class="${properties.kcAlertTitleClass!}">${msg("emailCodeSignUpError." + skySignUpError)}</span>
                </div>
            </#if>
            <p id="sky-sign-up-address">${msg("emailCodeSignUpAddress", (skySignUpAddress!""))}</p>
            <form id="kc-email-code-sign-up-form" action="${url.loginAction}" method="post">
                <div class="${properties.kcFormGroupClass!}">
                    <label for="sky-sign-up-first-name" class="${properties.kcLabelClass!}">${msg("emailCodeSignUpFirstName")}</label>
                    <input id="sky-sign-up-first-name" name="firstName" type="text" autocomplete="given-name" maxlength="64"
                           value="${skySignUpFirstName!""}" class="${properties.kcInputClass!}" autofocus/>
                </div>
                <div class="${properties.kcFormGroupClass!}">
                    <label for="sky-sign-up-last-name" class="${properties.kcLabelClass!}">${msg("emailCodeSignUpLastName")}</label>
                    <input id="sky-sign-up-last-name" name="lastName" type="text" autocomplete="family-name" maxlength="64"
                           value="${skySignUpLastName!""}" class="${properties.kcInputClass!}"/>
                </div>
                <p id="sky-sign-up-kvkk" class="${properties.kcFormHelperTextClass!}">${msg("emailCodeSignUpKvkk")}
                    <a href="https://yildizskylab.com/kvkk-metni.pdf" target="_blank" rel="noopener noreferrer">${msg("emailCodeSignUpKvkkLink")}</a></p>
                <div class="${properties.kcFormButtonsWrapperClass!}">
                    <button type="submit" name="sky-email-code-action" value="sign-up"
                            class="${properties.kcButtonClass!} ${properties.kcButtonPrimaryClass!} ${properties.kcButtonBlockClass!}">${msg("emailCodeSignUpSubmit")}</button>
                    <button type="submit" name="sky-email-code-action" value="change" formnovalidate
                            class="${properties.kcButtonClass!} ${properties.kcButtonDefaultClass!} ${properties.kcButtonBlockClass!}">${msg("emailCodeSignUpChange")}</button>
                </div>
            </form>
        </#if>
        </div>
    </#if>
</@layout.registrationLayout>
