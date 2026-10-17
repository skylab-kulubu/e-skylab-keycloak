<#-- All three choices are session actions; native Keycloak owns credential collection and policy. -->
<#import "template.ftl" as layout>
<@layout.registrationLayout; section>
  <#if section = "header">${msg("afterSignUpCredentialsTitle")}
  <#elseif section = "form">
    <p>${msg("afterSignUpCredentialsDescription")}</p>
    <p>${msg("afterSignUpCredentialsNote")}</p>
    <form id="kc-after-sign-up-credentials-form" action="${url.loginAction}" method="post">
      <button type="submit" name="sky-sign-up-credential-choice" value="passkey">${msg("afterSignUpPasskey")}</button>
      <button type="submit" name="sky-sign-up-credential-choice" value="password">${msg("afterSignUpPassword")}</button>
      <button type="submit" name="sky-sign-up-credential-choice" value="skip">${msg("afterSignUpSkip")}</button>
    </form>
  </#if>
</@layout.registrationLayout>
