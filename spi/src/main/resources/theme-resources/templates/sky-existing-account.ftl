<#-- Fallback for themes without the branded broker-link page. No account profile is exposed. -->
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=true; section>
    <#if section = "header">
        ${msg("existingAccountTitle")}
    <#elseif section = "form">
        <p>${msg("existingAccountDescription")}</p>
        <#assign stage = skyExistingAccountStage!"unavailable">
        <#if skyExistingAccountError??><p role="alert">${msg("existingAccountTryAgain")}</p></#if>
        <form action="${url.loginAction}" method="post" data-sky-existing-account-stage="${stage}">
            <#if stage == "question">
                <#if skyExistingAccountSchoolCandidate!false><p data-sky-existing-account-candidate="true">${msg("existingAccountSchoolCandidate")}</p></#if>
                <button type="submit" name="sky-existing-account-action" value="existing">${msg("existingAccountYes")}</button>
            <#elseif stage == "identifier">
                <label for="sky-existing-identifier">${msg("existingAccountIdentifier")}</label>
                <input id="sky-existing-identifier" name="username" type="text" autocomplete="username" maxlength="255"
                       value="${skyExistingAccountIdentifier!""}" autofocus>
                <button type="submit" name="sky-existing-account-action" value="send">${msg("emailCodeSend")}</button>
                <button type="submit" name="sky-existing-account-action" value="password">${msg("existingAccountPassword")}</button>
            <#elseif stage == "code">
                <p>${msg("existingAccountCodeSent")}</p>
                <label for="sky-existing-code">${msg("emailCodeCodeLabel")}</label>
                <input id="sky-existing-code" name="code" type="text" inputmode="numeric" autocomplete="one-time-code" maxlength="20" autofocus>
                <button type="submit" name="sky-existing-account-action" value="verify">${msg("existingAccountVerify")}</button>
                <button type="submit" name="sky-existing-account-action" value="resend" formnovalidate>${msg("emailCodeResend")}</button>
                <button type="submit" name="sky-existing-account-action" value="change" formnovalidate>${msg("emailCodeChange")}</button>
            <#else>
                <p>${msg("existingAccountTryAgain")}</p>
            </#if>
            <button type="submit" name="sky-existing-account-action" value="new-account" formnovalidate>
                ${msg("existingAccountEscape")}
            </button>
        </form>
    </#if>
</@layout.registrationLayout>
