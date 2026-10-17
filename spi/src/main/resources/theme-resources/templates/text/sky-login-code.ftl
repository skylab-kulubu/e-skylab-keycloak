<#if (purpose!"") == "signup">${msg("skySignUpCodeIntro", realmName)}<#else>${msg("skyLoginCodeIntro", realmName)}</#if>

${code}

${msg("skyLoginCodeExpiry", codeExpiration)}

${msg("skyLoginCodeNeverShare", realmName)}

<#if (purpose!"") == "signup">${msg("skySignUpCodeIgnore")}<#else>${msg("skyLoginCodeIgnore")}</#if>
