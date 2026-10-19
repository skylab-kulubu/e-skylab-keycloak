# SKY LAB Keycloak login theme

This directory is the authoritative source for the `e-skylab-theme` login
theme. The removed `e-skylab-theme-v1-1-1` JAR is not a source dependency.
Only the two original brand image assets were carried forward.

## Runtime contract

- Keycloakify is pinned to `11.16.0` and targets Keycloak `26.7.4` through the
  single `all-other-versions` artifact `e-skylab-theme-2.0.1.jar`.
- The foundation image builds the theme from this directory and installs one
  login-theme JAR. A checked-in generated JAR is not used.
- The WebAuthn registration context must retain `authenticatorAttachment`,
  `requireResidentKey`, `residentKey` and `userVerificationRequirement`.
- WebAuthn retry posts the runtime `execution` as `authenticationExecution`;
  the historical literal `${execution}` value is forbidden.
- Conditional passkey submission mirrors the visible `rememberMe` choice into
  the WebAuthn form. Mediation and authenticator-attachment inputs continue to
  come from Keycloak's 26.7 context.
- App-initiated password, TOTP and passkey pages expose Keycloak's native
  `cancel-aia` control. `delete-credential.ftl` is the only credential-delete
  surface; the built-in delete-account action is not an Account Center
  destination.
- One design system: the colours, radius and type come from the
  `@skylab-kulubu/skylcn-ui` tokens (`tokens.css`, ADR 0055), and
  `src/login/legacy-login.css` is the theme's only stylesheet, mapping them
  onto the login roles (lilac submit, Space Grotesk bundled from
  `@fontsource-variable/space-grotesk`, no external font request). Space
  Grotesk is © The Space Grotesk Project Authors under the SIL Open Font
  License 1.1, which allows bundling it in the theme JAR; the licence text
  ships with the package (`node_modules/@fontsource-variable/space-grotesk/LICENSE`).
  `Template.tsx` renders every Keycloakify `DefaultPage` inside the same
  `LegacyFrame` chrome as `Login.tsx` and `PasskeyOffer.tsx`: a glass card
  with the SKY LAB logo (whole from the first frame; the animation only traces a
  light line over it once, and none with reduced motion), the KVKK footer and
  the language menu, over
  a grid of blinking squares (`GridBackdrop.tsx`: lines in CSS, lit cells on
  a canvas at about 15 fps, still on touch screens, small CPUs, data saver
  and reduced motion). On wide screens the login page alone
  (`getLegacyChromeProps(i18n, { brand: true })`) splits the card: the form
  on the left, a brand panel on the right (the logo, what one account gives,
  a faint watermark in its corner). Every other page keeps one column with the logo on top,
  as every page does on a phone.
- Team strips: on the login page (with the brand panel), both stages of "E-postayla devam et",
  every e-mail sign-up stage and the first YTÜ login's existing-account question/proof page,
  `TeamMarquee.tsx` runs two slow, faint rows of SKY LAB team logos
  above and below the card, each in a band narrower than the window that fades
  out before its ends (on a phone only the row below the card and footer, so the
  form comes first; still with reduced motion, hidden in forced colors,
  `aria-hidden`). Which teams, in what order, comes
  from the main site's CMS `teams` collection: `npm run teams`
  (`scripts/fetch-teams.mjs`) writes `src/login/teams.json`, which is
  committed. Builds never call the CMS, so CI and the release image build only
  what was reviewed; run `npm run teams` by hand when the club's teams change,
  add the new logo, and commit both (`teams.test.ts` fails on a team without a
  logo). Override the source with `SKYLAB_TEAMS_URL` / `SKYLAB_TEAMS_CLIENT_ID`. GDG, SKY MEDYA and
  SKY LAB, and the club's Gece Kodu and BİZ BİZE, are not in that collection
  and are added in `teams.ts`. The logos
  live in `src/assets/teams/<slug>.(svg|webp)`, drawn in one tone; a team with
  no file shows its name. The `sl-*` class contract handed out by `KcPage.tsx` is
  styled with the login tokens; `login-page-expired.ftl` is the only custom
  page body because Keycloak's markup cannot be phrased in Turkish.
- `sky-personal-email-offer.ftl` is the SPI's one-time Personal e-mail offer at
  the end of a first YTÜ login (required action `sky-personal-email-offer`,
  eskylab-login-ux 21). The SPI decides everything and hands over
  `skyOfferStage` (`address` or `code`), `skyOfferAddress`, `skyOfferError` (a code
  from `src/login/offerErrors.ts`; anything else shows no error),
  `skyOfferAttemptsLeft` and `skyOfferCodeMinutes`; `PersonalEmailOffer.tsx` only
  words them. One form posts `sky-offer-action` = `send` (with `address`),
  `verify` (with `code`), `change` or `skip`; the field ids `sky-offer-address`,
  `sky-offer-code` and the error's `data-sky-offer-error` match the SPI's own
  fallback template, which the harness drives.
- `sky-email-code-sign-up.ftl` is the SPI's Self-registration page on "E-postayla
  devam et" (step `sky-email-code`, eskylab-login-ux 09), shown only after the right
  sign-up code proved the address. The SPI decides the stage (`skySignUpStage`: `form`,
  `ytu`, `existing`, `unavailable`; anything else is the form) and hands over
  `skySignUpAddress`, `skySignUpError` (a code from `src/login/signUpStages.ts`),
  `skySignUpFirstName`/`skySignUpLastName` (what was typed) and `skySignUpYtuAlias`;
  `EmailCodeSignUp.tsx` only words them. The form posts `sky-email-code-action` = `sign-up`
  (with `firstName`, `lastName`) or `change`; the existing stage posts `continue`; the YTÜ
  stage links to the provider in `social.providers` whose alias is `skySignUpYtuAlias`. The
  address is read-only and not posted, there is no password field and no consent box (the
  KVKK footer only informs). Form ids (`kc-email-code-sign-up-form`, `…-ytu-form`,
  `…-existing-form`, `…-unavailable-form`) and `data-sky-sign-up-stage` /
  `data-sky-sign-up-error` match the SPI's own fallback template, which the harness drives.
  Previews: `?page=sky-email-code-sign-up.ftl&signup=ytu|existing|unavailable|error`. The
  password form's page carries `skyEmailCodeSignUp=true` while a realm offers it. The first
  choice screen says "Hesabın yok mu? Hesap aç" on its one quiet line beside the passkey; the
  password view says "Hesabın yok mu? E-postayla hesap aç". Either appears only
  with that explicit flag and an offered `sky-email-code` execution. It posts that execution
  and `sky-email-code-intent=sign-up` to the current `url.loginAction`, preserving the login
  session. Keycloak's built-in registration route is never offered. Broker account-proof mode
  never shows this ordinary entry; its explicit "Bağlanamadım, yeni hesap aç" POST stays separate.
  On the shared code page, only the enabled sign-up intent changes the heading to "Hesap aç"
  and the address-stage description; the code-stage notice, errors, budgets and proof-before-
  account-disclosure behavior remain the same. Ordinary e-mail/password switches carry no
  registration intent. Preview the enabled entry with `?page=login.ftl&registration=on`, or
  its address/code page with `?page=sky-email-code.ftl&registration=sign-up[&code=sent|wrong]`.
  The normal preview keeps registration off. The team strips on sign-up and existing-account
  pages use `LegacyFrame`'s `teams` opt-in, preserving the single-column card without a brand panel.
- `sky-email-code.ftl` is "E-postayla devam et", the SPI's sky-email-code step
  (eskylab-login-ux 08). The SPI hands over `skyEmailCodeStage` (`identifier` or
  `code`), `skyEmailCodeIdentifier` (what was typed), `skyEmailCodeError` (a code from
  `src/login/emailCodeChoice.ts`), `skyEmailCodeAttemptsLeft`, `skyEmailCodeMinutes`,
  `skyEmailCodeResendAfter` (seconds until "Kodu yeniden gönder" opens; the page
  counts down) and, on the identifier stage, Keycloak's conditional passkey data;
  `EmailCode.tsx` only words them and never says where a code went. One form posts
  `sky-email-code-action` = `send` (with `username`), `verify` (with `code`), `resend`
  or `change`; the field ids and `data-sky-email-code-error` match the SPI's fallback
  template, which the harness drives. The code field is one input styled as six
  cells (pasting and `autocomplete="one-time-code"` keep working). The login page's
  e-mail button switches to the step when Keycloak lists it in
  `auth.authenticationSelections` (display name `sky-email-code-display-name`) and
  keeps opening the password view otherwise; "Parolanla gir" switches to the password
  form the same way and the login page then opens on its password view with the
  field filled (one session-storage entry, read once). Both stages open with "Geri dön"
  (`BackToChoice.tsx`), back to the login page's first screen: the same execution switch to
  the password form, without the remembered choice, so the login page opens on its choice; the
  login session and a code already sent stay as they are. Only where Keycloak offers no password
  form there does it link `url.loginRestartFlowUrl` instead. The shared logo keeps one stable SVG markup
  object across re-renders, so the resend countdown never restarts its drawing animation. `tests/login-by-email-code.sh`
  proves this contract against a real Keycloak with the built theme.
- `sky-stay-signed-in.ftl` is the SPI's "Bu cihazda oturumum açık kalsın mı?" at
  the end of every YTÜ login and every e-mail code login (required action
  `sky-stay-signed-in`, Microsoft's "Stay signed in?"). The SPI hands over the realm's remember-me idle time and
  lifespan in whole days (`skyStaySignedInIdleDays`, `skyStaySignedInMaxDays`);
  `StaySignedIn.tsx` words them and warns against "Evet" on a shared computer. One
  form posts `sky-stay-signed-in` = `yes` ("Evet, açık kalsın", a remember-me
  session) or `no` ("Hayır", an ordinary one); the form id `kc-stay-signed-in-form`
  matches the SPI's own fallback template, which the harness drives. The password
  form's "Beni hatırla" box is a separate, unchanged control.
- `sky-handoff-failed.ftl` is the SPI's Web handoff failure page
  (`/realms/{realm}/sky-handoff/v1/failed?reason=`, rendered through Keycloak's
  login forms with the reason code as `skyHandoffReason`). `HandoffFailed.tsx`
  shows one sentence per reason (`src/login/handoffFailure.ts`; anything else
  is `unavailable`) and the retry hint inside `LegacyFrame`, with no form, no
  login link and no language menu; its heading is a full sentence, so the
  document title drops the final period before " · SKY LAB". The SPI sends it with its own strict
  headers (no framing, `no-store`, `no-referrer`, the inline page context
  allowed by hash only) and falls back to a built-in page when a realm's login
  theme lacks it.
- Every visible string comes from `src/login/i18n.ts` (Turkish first, English
  second); the Turkish keys that Keycloakify's default set lacks live there.
- The translations are one object literal written inside
  `withCustomTranslations(...)`: `keycloakify build` evaluates that argument on
  its own to write `messages_*.properties`, the only copy Keycloak reads for
  what it renders on the server (page-wide notices such as the reset e-mail
  confirmation, field errors, info pages, the password policy sentences that
  Account Center shows). A variable, import or spread there is dropped with a
  warning. `i18n.test.ts` reads the file the way the build does, and
  `tests/check-theme-contract.sh` runs `scripts/check-message-bundles.mjs`
  against the built JAR.
- The custom template owns the semantic main/content-info landmarks, the skip
  link, the plain-link language menu, the document title (page heading plus
  " · SKY LAB"), visible focus treatment, WCAG AA contrast including the blue
  and pink submit states (`themeContract.test.ts`) and `prefers-reduced-motion`
  behavior.
- Keycloak's page-wide message (`message` that is not a field error: the
  reset e-mail confirmation, a failed YTÜ Microsoft sign-in, an expired
  action) is rendered by `PageMessage.tsx` as the first element under the card
  heading on every page, the login page's first screen included: `role="alert"`
  for errors, `role="status"` otherwise, focused on load unless the page
  autofocused a field. Wrong credentials stay on the fields, once (Keycloak's
  own `displayMessage` rules).
- Copy is functional only: headings, at most one short line under a heading,
  labels, buttons, errors and the links someone needs. No explanatory or
  reassuring paragraphs (Yusuf, 2026-10-19). The login page's first screen is
  the two ways in ("YTÜ hesabınla devam et", "E-postayla devam et"), one quiet
  line under them ("Erişim anahtarı ile giriş yap" and, with sign-up on,
  "Hesabın yok mu? Hesap aç") and a plain "Okul şifreni sıfırla" link
  (Microsoft's self-service reset, in a new tab). The address stage of "E-postayla
  devam et" has no sentence under its heading; the code stage keeps "E-postana
  gelen 6 haneli kodu yaz." and "Kod {0} dakika geçerli.". Help copy, field
  labels and the KVKK line are at least 14px; the developer credit, the language
  links and the attempted-account label may stay at 12-13px (`themeContract.test.ts`).
- "Parolanı mı unuttun?" (`url.loginResetCredentialsUrl`, when the realm allows
  resetting) is in the password form only, directly below the password field,
  right-aligned, beside "Beni hatırla".
- `src/login/pageIds.ts` lists every themed page id; `src/devKcContext.ts`
  serves realistic Turkish mock data for each of them at `?page=<id>.ftl`
  (`&lang=en` switches locale; `&reason=<code>` picks the Web handoff failure
  reason of `sky-handoff-failed.ftl`; `&offer=code|taken` previews the code stage
  or a taken address of `sky-personal-email-offer.ftl`; `&code=sent|wrong` previews the
  code stage of `sky-email-code.ftl` just after the mail or after a wrong code; `&state=<name>` previews a server-side
  state from `previewStates`: `login.ftl` `reset-email-sent`,
  `invalid-credentials`, `idp-error`; `login-reset-password.ftl`
  `missing-username`).

## Landing page (welcome theme)

Keycloak answers `/` through its welcome theme; the bundled one redirects to the
Admin Console once an admin exists (`redirectToAdmin=true`). The image installs
a second, source-built theme instead: `e-skylab-welcome`, a folder theme at
`/opt/keycloak/themes/e-skylab-welcome` selected by
`KC_SPI_THEME__WELCOME_THEME=e-skylab-welcome` (Dockerfile, run-time option).

- `src/welcome/WelcomePage.tsx` is the page (what e-SKY LAB is, where the
  account is used, how to sign in today, the ADR-0063 trust copy, Account
  Center and KVKK links); `src/welcome/template.tsx` wraps it into `index.ftl`.
  `npm run build-welcome-theme` (`scripts/build-welcome-theme.mjs`) renders it
  once with `react-dom/server` and bundles `src/welcome/welcome.css` with Vite
  into `dist_welcome/e-skylab-welcome/welcome/`.
- Static by contract: no script, form or inline handler; the only Keycloak value
  it uses is `resourcesPath`, so it can show neither the Admin Console link nor
  the admin creation form; the body sits in `<#noparse>`; links go only to the
  club's own apps and the KVKK text. `theme.properties` sets
  `redirectToAdmin=false`.
- One design system: `welcome.css` imports the skylcn-ui tokens, Space Grotesk
  and `src/login/legacy-login.css` and adds only the landing layout (no token
  set of its own). The logo and YTÜ mark are the login theme's components.
- Tests: `WelcomePage.test.tsx` (Vitest: landmarks, copy, link allowlist,
  template contract), `../tests/check-welcome-theme.sh` (the built files) and
  `../tests/welcome-page.sh` (stock Keycloak serving the built theme: `/` is the
  page, its resources load, Keycloak's own paths are unchanged). The
  integration harness checks the optimized image serves it.
- Copy follows today's login buttons; when they change (e-mail code, sign-up,
  ADR-0063), change this page too.

## Account Center boundary

The theme does not construct Account Center AIA URLs. The BFF must create a PAR
request for exactly one of:

- `UPDATE_PASSWORD`
- `CONFIGURE_TOTP`
- `webauthn-register-passwordless`
- `delete_credential:{ownedCredentialId}`

The BFF remains responsible for state, nonce, S256 PKCE, fresh authentication,
expected-subject binding, an allowlisted local return path, owned-credential
validation and a fresh Account REST read after success. It must never use the
Account Console or Keycloak's built-in delete-account action as a destination.

The SPI's automatic Passkey Offer is intentionally skipped for the
`account-center` client and for every request carrying `kc_action`; Account
Center actions must not be interrupted by an unsolicited offer.

Realm desired state enables Keycloak's integrated passkey UI with
`conditional` mediation. This is separate from the custom Passkey Offer:
conditional/modal passkey sign-in remains available while the unsolicited
post-login offer stays disabled for Account Center and AIA traffic.

## Verification

```bash
npm ci --ignore-scripts
npm audit --audit-level=high
npm test
npx playwright install chromium
npm run test:browser
npm run build-keycloak-theme
bash ../tests/check-theme-contract.sh
```

Vitest covers the remember-me bridge, the stylesheet contract and, through
`Template.test.tsx`, that every page id renders the animated logo, the glass
card, the KVKK footer and Keycloak's element ids; `Login.test.tsx` covers where
page-wide messages and the forgot-password link sit. The theme Chromium suite
covers deterministic rendered-page contracts. `tests/browser/visual.spec.ts`
compares a desktop (1280×800) and mobile (390×844) screenshot of every page
(plus the login page's password form and its `&state=` previews),
Turkish locale, reduced motion (plus every Web handoff failure reason on mobile
with the phone in light and in dark mode), against the committed baselines in
`tests/browser/visual.spec.ts-snapshots/` (at most 1% of pixels may differ).
Baselines are rendered only inside `mcr.microsoft.com/playwright:v<pinned>-jammy`
with the fonts pinned by `tests/browser/fonts.conf` and the screenshot-only
`tests/browser/visual.css` (decorative noise layers hidden so the PNGs stay
small); the CI and release `theme` jobs run in that same image. The spec runs
only where `SL_VISUAL_BASELINE_ENV=1` is set (the image, the CI jobs and
`scripts/update-visual-baselines.sh` set it); elsewhere `npm run test:browser`
skips it. `SL_VISUAL_ANY_PLATFORM=1` forces the spec on any machine for a quick
look, but its fonts differ from the baselines, so expect diffs there.
`scripts/update-visual-baselines.sh --check` (Docker) compares in the image and
`scripts/update-visual-baselines.sh` regenerates the baselines after an
intentional design change; the committed PNGs are replaced only when every
screenshot was captured. The Keycloak integration runner additionally drives
Chromium through a live Keycloak `26.7.4` instance for Turkish/English locale
switching, password login, password/TOTP AIA cancel and completion, WebAuthn
error retry and registration plus a cookie-cleared passwordless assertion with
the same virtual authenticator, and renders every Web handoff failure reason
from the live SPI in light and dark mode under the page's own Content Security
Policy (`tests/integration/sky-handoff-failed.spec.ts`).

CI browser automation cannot prove platform authenticator behavior on real
Touch ID, Face ID, Android Credential Manager, Windows Hello or the supported
mobile WebViews. The initial production rollout records registration and
passwordless sign-in on physical Touch ID; cancellation and failure recovery
remain covered by the real-Keycloak automated fixture. Face ID and the other
device surfaces are deferred to post-release compatibility testing. Registry
publication is blocked unless the release environment binds an HTTPS evidence
record and the exact tested surface list to the candidate commit; a virtual
browser success is not a substitute.
