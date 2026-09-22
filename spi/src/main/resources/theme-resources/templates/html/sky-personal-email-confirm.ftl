<html>
<body style="margin:0;padding:24px;background:#f4f5f7;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#16181d;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
  <tr>
    <td align="center">
      <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="max-width:520px;background:#ffffff;border-radius:12px;padding:32px;">
        <tr>
          <td style="font-size:18px;font-weight:600;padding-bottom:16px;">${realmName}</td>
        </tr>
        <tr>
          <td style="font-size:15px;line-height:22px;padding-bottom:24px;">
            ${msg("skyPersonalEmailConfirmIntro", newEmail, realmName)}
          </td>
        </tr>
        <tr>
          <td style="padding-bottom:24px;">
            <div style="display:inline-block;background:#f4f5f7;border-radius:8px;padding:12px 20px;font-family:'SF Mono',Menlo,Consolas,monospace;font-size:28px;font-weight:600;letter-spacing:6px;color:#16181d;">${code}</div>
          </td>
        </tr>
        <tr>
          <td style="font-size:13px;line-height:20px;color:#5b6170;padding-bottom:8px;">
            ${msg("skyPersonalEmailConfirmExpiry", codeExpiration)}
          </td>
        </tr>
        <tr>
          <td style="font-size:13px;line-height:20px;color:#5b6170;padding-bottom:16px;">
            ${msg("skyPersonalEmailConfirmNeverShare", realmName)}
          </td>
        </tr>
        <tr>
          <td style="font-size:13px;line-height:20px;color:#5b6170;">
            ${msg("skyPersonalEmailConfirmIgnore")}
          </td>
        </tr>
      </table>
    </td>
  </tr>
</table>
</body>
</html>
