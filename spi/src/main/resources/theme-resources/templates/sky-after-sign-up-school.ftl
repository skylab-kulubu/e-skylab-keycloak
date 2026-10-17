<#-- Stock-theme fallback; the bundled SKY LAB theme supplies its branded page. -->
<#import "template.ftl" as layout>
<@layout.registrationLayout; section>
  <#if section = "header">${msg("afterSignUpSchoolTitle")}
  <#elseif section = "form">
    <p>${msg("afterSignUpSchoolDescription")}</p>
    <form id="kc-after-sign-up-school-form" action="${url.loginAction}" method="post">
      <#if (skyYtuLinkAvailable!false)?c == "true">
        <p>${msg("afterSignUpSchoolOptional")}</p>
        <button type="submit" name="sky-sign-up-school-choice" value="link">${msg("afterSignUpSchoolLink")}</button>
        <button type="submit" name="sky-sign-up-school-choice" value="skip">${msg("afterSignUpSchoolSkip")}</button>
      <#else>
        <p>${msg("afterSignUpSchoolDeferred")}</p>
        <button type="submit" name="sky-sign-up-school-choice" value="skip">${msg("afterSignUpContinue")}</button>
      </#if>
    </form>
  </#if>
</@layout.registrationLayout>
