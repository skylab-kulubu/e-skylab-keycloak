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
- One design system: `src/login/legacy-login.css` is the only stylesheet and
  the only token set (accent `#e0c8e5`, background `#08070b`, blue submit with
  pink hover, Inter stack). `Template.tsx` renders every Keycloakify
  `DefaultPage` inside the same `LegacyFrame` chrome as `Login.tsx` and
  `PasskeyOffer.tsx`: animated SKY LAB logo, glass card, KVKK footer and the
  language menu. The `sl-*` class contract handed out by `KcPage.tsx` is
  styled with the login tokens; `login-page-expired.ftl` is the only custom
  page body because Keycloak's markup cannot be phrased in Turkish.
- Every visible string comes from `src/login/i18n.ts` (Turkish first, English
  second); the Turkish keys that Keycloakify's default set lacks live there.
- The custom template owns the semantic main/content-info landmarks, the skip
  link, the plain-link language menu, the document title (page heading plus
  " · SKY LAB"), visible focus treatment, WCAG AA contrast including the blue
  and pink submit states (`themeContract.test.ts`) and `prefers-reduced-motion`
  behavior.
- `src/login/pageIds.ts` lists every themed page id; `src/devKcContext.ts`
  serves realistic Turkish mock data for each of them at `?page=<id>.ftl`
  (`&lang=en` switches locale).

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
card, the KVKK footer and Keycloak's element ids. The theme Chromium suite
covers deterministic rendered-page contracts. `tests/browser/visual.spec.ts`
compares a desktop (1280×800) and mobile (390×844) screenshot of every page,
Turkish locale, reduced motion, against the committed baselines in
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
the same virtual authenticator.

CI browser automation cannot prove platform authenticator behavior on real
Touch ID, Face ID, Android Credential Manager, Windows Hello or the supported
mobile WebViews. The initial production rollout records registration and
passwordless sign-in on physical Touch ID; cancellation and failure recovery
remain covered by the real-Keycloak automated fixture. Face ID and the other
device surfaces are deferred to post-release compatibility testing. Registry
publication is blocked unless the release environment binds an HTTPS evidence
record and the exact tested surface list to the candidate commit; a virtual
browser success is not a substitute.
