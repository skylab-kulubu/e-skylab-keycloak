<#-- "Bu cihazda oturumum açık kalsın mı?" after a YTÜ login (required action sky-stay-signed-in) for a
     login theme without its own page; the SKY LAB login theme draws it in its own design. The texts
     are this extension's messages (theme-resources/messages). -->
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=false; section>
    <#if section = "header">
        ${msg("staySignedInTitle")}
    <#elseif section = "form">
        <p id="sky-stay-signed-in-description">${msg("staySignedInDescription", (skyStaySignedInMaxDays!"30"), (skyStaySignedInIdleDays!"7"))}</p>
        <p id="sky-stay-signed-in-shared-device" class="${properties.kcFormHelperTextClass!}">${msg("staySignedInSharedDevice")}</p>
        <form id="kc-stay-signed-in-form" action="${url.loginAction}" method="post">
            <div class="${properties.kcFormButtonsWrapperClass!}">
                <button type="submit" name="sky-stay-signed-in" value="yes"
                        class="${properties.kcButtonClass!} ${properties.kcButtonPrimaryClass!} ${properties.kcButtonBlockClass!}">${msg("staySignedInYes")}</button>
                <button type="submit" name="sky-stay-signed-in" value="no"
                        class="${properties.kcButtonClass!} ${properties.kcButtonDefaultClass!} ${properties.kcButtonBlockClass!}">${msg("staySignedInNo")}</button>
            </div>
        </form>
    </#if>
</@layout.registrationLayout>
