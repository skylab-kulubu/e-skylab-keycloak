# Hesap Merkezi v2 kimlik uzlaştırması — üretim runbook'u

Bu runbook `config/reconcile-account-center.sh` içindeki v2 kimlik adımlarının
(passkey relying party id, realm giriş ve brute-force ayarları, olay saklama süresi, User Profile,
`account-center-account-api` ve `account-center-core-claims` kapsamları,
`keycloak-mailer` ve `core-erasure` istemcileri, admin panelinin istemcisi) üretime
alınma sırasını, ön kontrolleri, duyuru metnini ve geçiş sonrası eski passkey
temizliğini tanımlar. `docs/keycloak-26.7.4-upgrade-runbook.md` içindeki yedek,
klon provası ve geri dönüş adımları geçerliliğini korur; burada yalnız bu
sürüme özgü adımlar vardır.

## 0. Uzlaştırıcının uyguladığı realm durumu

Uzlaştırıcı her koşuda önce canlı durumu okur, yalnız farklı olan alanları
yazar ve her adım için `[reconcile] <adım>: unchanged|updated (...)` satırı
basar. Değişiklik gerektirmeyen ikinci koşu hiçbir admin olayı üretmez;
entegrasyon testi bunu doğrular.

| Adım | Uygulanan durum |
| --- | --- |
| Realm oturum/giriş/tema (`account-center-realm.json`) | `editUsernameAllowed=false`, `loginWithEmailAllowed=true`, `duplicateEmailsAllowed=false`, oturum süreleri, `e-skylab-theme` |
| Brute force ve parola politikası (`account-center-realm-security.json`) | `bruteForceProtected=true`, `permanentLockout=false`, `failureFactor=10`, `waitIncrementSeconds=60`, `maxFailureWaitSeconds=900`, `maxDeltaTimeSeconds=43200`, `quickLoginCheckMilliSeconds=1000`, `minimumQuickLoginWaitSeconds=60`, `passwordPolicy="length(8) and notUsername and notEmail"` |
| Olay saklama süresi (hesap silme 09; değerler betiğin başındaki `EVENT_RETENTION_*` sabitlerinde) | `eventsEnabled=true`, `eventsExpiration=2592000`, `adminEventsEnabled=true`, `adminEventsDetailsEnabled=true` ve realm özniteliği `adminEventsExpiration=2592000`: kullanıcı ve admin olayları 30 gün sonra silinir, admin olay ayrıntıları denetim için açık kalır (Yusuf'un seçimi). Neden: Keycloak silinen kişinin olaylarını silmez. `CREATE`/`UPDATE` admin olayları kişinin tam temsilini (e-posta, ad, okul ve kişisel e-posta), `DELETE` kullanıcı adını, `LOGIN`/`LOGIN_ERROR` yazılan adresi tutar. Süre kapatılırsa bunlar süresiz kalır; 30 gün KVKK'nın başvuruyu sonuçlandırma süresidir. Öznitelik, canlı öznitelik haritasının üstüne birleştirilerek yazılır. Dinleyiciler ve kaydedilen olay türleri yönetilmez. Yetki: realm PUT'u `manage-realm` ister, uzlaştırıcı kimliğinde var; `events/config` uç noktası (`manage-events`) kullanılmaz. Üretimde bu değerler 2026-09-26'dan önce elle kurulmuştu; ilk koşuda `[reconcile] realm event retention (…): unchanged` beklenir, `updated (…)` görülürse biri ayarı değiştirmiştir, not edin. Harness: `tests/event-retention.sh`. |
| Şifresiz passkey politikası (`account-center-passkey-policy.json` + ortam) | `webAuthnPolicyPasswordlessRpId=yildizskylab.com`, `webAuthnPolicyPasswordlessExtraOrigins=["https://my.yildizskylab.com"]`; entity name `SKY LAB`, ES256/RS256, resident key ve kullanıcı doğrulaması zorunlu, passkeys açık, conditional mediation; diğer alanlar Keycloak varsayılanları. Relying party id gerçekten değişiyorsa politika yazılmadan önce realm özniteliği `skylab.passkeyRpIdSwitchedAt=<ISO-8601 UTC>` kaydedilir (öznitelik haritası canlı halinin üstüne birleştirilir, başka öznitelik silinmez) ve `[reconcile] passkey relying party id switches from '…' to '…'` satırı basılır; §5'teki temizlik bu anı cutover alır. İki faktörlü (`webAuthnPolicy*`) politika yönetilmez. `attributes` taşımayan realm PUT'ları CIBA/PAR sürelerini Keycloak varsayılanına sıfırlar (önceden de böyleydi). |
| User Profile (`account-center-user-profile.json`) | Canlı yapı korunur (gruplar, açıklamalar, mesaj anahtarları, ek öznitelikler); `firstName`, `lastName`, `email` kişi için salt okunur (`edit=[admin]`, `view=[admin,user]`); `username` izinleri olduğu gibi; `schoolEmail`, `personalEmail`, `skyNumber`, `department`, `university`, `skyMail`, `usernameChangedAt` `view=[admin,user]`, `edit=[admin]`; e-posta özniteliklerinde `email`, `usernameChangedAt` için ISO-8601 UTC `pattern` doğrulayıcısı; eksik Türkçe görünen adlar eklenir, mevcutlar korunur; `unmanagedAttributePolicy=ADMIN_VIEW` (asla `ENABLED`) |
| `account-center-account-api` kapsamı | `account-api-audience` (`account`), `account-api-core-audience` (`core`), `account-api-manage-account`, `account-api-view-profile`, `account-api-manage-account-links` (sabit roller), `account-api-roles` (`resource_access.account.roles`), `account-api-sky-authorization` (SPI mapper'ı `sky-authorization-mapper`: `sky_authorization.<istemci>.roles`, yalnız access token ve introspection; ID token/userinfo'da yok; `realm-management`, `broker`, `account`, `account-console`, `security-admin-console`, `admin-cli`, `*-realm` hariç; sıralı; 64 istemci / 256 rol sınırı; rol yoksa claim yok). Audience-resolve mapper yoktur; `aud` tam olarak `["account","core"]` kalır. |
| `account-center-core-claims` kapsamı (`account-center-core-claims-mappers.json`) | `sub`, `auth_time`, `sky_session_lifetime` (`sky_session_started`/`sky_session_expires`), `sky_embed` (ayrıntı `docs/sky-handoff-api.md`) ve C2'den beri `university`, `department` (`oidc-usermodel-attribute-mapper`, aynı adlı kullanıcı özniteliğinden, `jsonType.label=String`, `multivalued=false`: realm'in `department_ve_university_to_jwt` kapsamıyla aynı biçim, düz metin; yalnız access token ve introspection; ID token/userinfo'da yok; öznitelik yoksa claim yok). core bu iki claim'i taşıyan her token'da kişinin üniversite, bölüm ve fakültesini yeniler ve `ytu_linked` yapar (§9). Kapsamdaki diğer mapper'lar silinir. |
| `frontend-main-core-audience`, `frontend-arge-core-audience` ve `skyforms-forms-audience` kapsamları | `frontend-main`, `frontend-arge` ve `skyforms` giriş istemcilerinin varsayılan kapsamları; access token'ın `aud`'una `core`, `core` ve `forms` ekler. Üretimde elle kuruldular, uzlaştırıcı adlarıyla devralır. İstemci realm'de yoksa uyarı yazılır ve o kalem atlanır (§0.1). |
| Giriş istemcilerinin dar token'ı (`frontend-main`, `frontend-arge`, `skymail`; ADR-0058, ADR-0059; §21) | Elle kurulmuş istemciler yerinde daraltılır: audience'lar varsayılan kapsamlardaki sabit mapper'lardan (sitelerde kendi `core` kapsamı ve ortak `skycms-audience`, SkyMail'de `skymail-api-audience`), rol kapsamında realm rolü ve başka istemcinin rolü yok, `fullScopeAllowed=false`. Siteler tam yollu `groups`'u tutar; `groups` yazan kapsamlar yalnız `skymail`'den ayrılır, `skymail`'in grup mapper'ı silinir. İstemci yoksa uyarı yazılır ve atlanır. |
| Admin panelinin istemcisi (`admin`, sandbox'ta `superadmin`; ADR-0058) | Elle kurulmuş gizli istemci yerinde daraltılır: `fullScopeAllowed=false`, `standard.token.exchange.enabled=true`, rol kapsamında yalnız `core` ve `forms`'un her rolü, varsayılan kapsam `admin-panel-api-audience` (sabit `core`, `forms`, `skycms` audience'ı). Adım en son koşar. İstemci yoksa uyarı; public ise koşu ona yazmadan hata verir (§16). |
| core'un kaynak rolleri (ADR-0059, §19) | `core` istemcisinde 13 rol her koşuda var edilir (yoksa açıklamasıyla oluşturulur; varsa dokunulmaz). Privileged gruplara (`/ADMIN`, `/YK`, `/DK`, `/UYELER/` altındakiler, hangileri varsa) **bir kez** verilir ve rol özniteliği `skylab.seeded-group-mappings` bunu kaydeder; işaretli role sonraki koşular eşleme eklemez, hiçbir koşu eşleme ya da rol silmez. Gruba rol vermek kullanıcı yetkisi ister: uzlaştırıcı kimliği yalnız rolleri oluşturur ve işaretsiz rolleri uyarıyla bildirir; tohumlamayı operatör `KEYCLOAK_RECONCILE_ONLY=core-roles` ile yapar. Adım admin panelinin adımından önce koşar. |
| `account-center` istemcisi | v1 sözleşmesi, `fullScopeAllowed=false` **kalır**: Keycloak Admin REST `AdminAuth.hasAppRole = user.hasRole && client.hasScope` ile yetkilendirir ve tam kapsam açıkken `client.hasScope` her rol için doğrudur; `realm-management` rolü olan bir kişinin `my.` token'ı Admin REST'te geçerli olurdu. `sky_authorization` bu yüzden kapsamdan bağımsız SPI mapper'ından gelir ve token'ın yetkisini genişletmez (harness: `view-users` sahibinin `account-center` token'ı ile `GET /admin/realms/{realm}/users` → 403; tam kapsamla 200 alırdı). Token'daki `resource_access` yalnız `account` rollerini içerir, `core` rolü taşımaz (test edilir). `account` istemci rolü scope mapping izin listesi: `manage-account`, `view-profile`, `manage-account-links` (AIA `idp_link` `client.hasScope` denetimi için). |
| `keycloak-mailer` istemcisi (K5) | Uzlaştırıcı **yalnız doğrular**: istemci yoksa uyarı ve çalıştırılacak komut; bayraklar (gizli, yalnız service account, standard flow / direct grant / implicit kapalı, `fullScopeAllowed=false`, `roles` varsayılan kapsamı) yanlışsa koşu hata ile durur; service account rolleri uzlaştırıcı kimliğiyle okunamadığından (kullanıcı yetkisi yok) uyarı olarak raporlanır. İstemciyi ve rolleri operatör `config/create-mailer-client.sh` ile oluşturur (§6). Gizli anahtarı Keycloak üretir, hiçbir betik yazdırmaz. |
| `core-erasure` istemcisi (hesap silme, ADR-0051) | Uzlaştırıcı **yalnız doğrular** (`keycloak-mailer` gibi): istemci yoksa uyarı ve çalıştırılacak komut. Şunlardan biri sözleşmeden farklıysa koşu hata ile durur ve operatör komutunu yazar: bayraklar (gizli, yalnız service account, standard flow / direct grant / implicit kapalı, `fullScopeAllowed=false`), varsayılan kapsamlar (tam olarak `basic` ve `roles`; Keycloak'ın eklediği `service_account` hoş görülür), isteğe bağlı kapsamlar (tam olarak üç `account-erase-*`), doğrudan scope mapping (olmamalı), her erase kapsamının tek audience mapper'ı ve tek rolü, servis istemcilerinin (`skymail`, `skycms`, `forms`) varlığı. Service account rolleri uzlaştırıcı kimliğiyle okunamadığından uyarı olarak raporlanır. İstemciyi, kapsamları ve rolleri operatör `config/create-erasure-client.sh` ile kurar (§11). |
| Parola formu (K4, §15) | Realm tarayıcı akışı `browser plus passkey`'deki `auth-username-password-form`'un yerine aynı alt akışta, aynı öncelik ve `REQUIRED` ile `sky-username-password-form` konur; akışın geri kalanına dokunulmaz. İki formdan tam olarak biri yoksa, form `REQUIRED` değilse ya da yanındaki bir yürütmeyle aynı önceliği paylaşıyorsa koşu hiçbir şey yazmadan durur. `KEYCLOAK_PASSWORD_FORM=auth-username-password-form` Keycloak'ın formunu geri koyar. |
| Parola sıfırlamanın kişi seçme adımı (K4b, §17) | Realm'in `reset credentials` akışındaki `reset-credentials-choose-user`'ın yerine aynı öncelik ve `REQUIRED` ile `sky-reset-credentials-choose-user` konur. Keycloak'ın yerleşik akışı değiştirilemediği için realm yerleşik bir akışa bağlıysa akış bir kez `sky reset credentials` adıyla kopyalanır, adım kopyada değiştirilir, realm ancak ondan sonra kopyaya bağlanır. Durdurma kuralları parola formununkiyle aynıdır. `KEYCLOAK_RESET_CHOOSE_USER=reset-credentials-choose-user` Keycloak'ın adımını bağlı akışa geri koyar. |
| Kimlik korumaları: core sertifika rolleri, OBS `department mapper`, core'un `manage-clients` rolü | Uzlaştırıcı **dokunmaz**: kimliğinin kullanıcı ve kimlik sağlayıcısı yetkisi yoktur. Operatör `config/identity-guardrails.sh` ile uygular (§8). |

Ortam değişkenleri: `KEYCLOAK_PASSKEY_RP_ID` (varsayılan `yildizskylab.com`) ve
`KEYCLOAK_PASSKEY_EXTRA_ORIGINS` (virgülle ayrılmış, varsayılan
`https://my.yildizskylab.com`). Üretim Compose dosyası bunları geçmez;
`ACCOUNT_CENTER_REQUIRE_PRODUCTION_HOST=true` iken uzlaştırıcı yalnız üretim
değerlerini kabul eder. Entegrasyon fixture'ı `localhost` +
`http://localhost:18080` kullanır.

### 0.1 Giriş istemcilerinin audience kapsamları (`frontend-main`, `frontend-arge`, `skyforms`)

Keycloak'ın audience-resolve mapper'ı bir API'yi `aud`'a yalnız token o API'nin
rollerini taşıyorsa ekler. Kişilerin çoğunun API rolü yoktur; token'larında API
bulunmaz ve API 401 döner. Bu giriş istemcileri API'yi kendi varsayılan kapsamıyla
`aud`'a ekler. Kapsamlar önce üretimde (`e-skylab`) elle kuruldu.

| İstemci | Kapsam / mapper | `aud`'a eklenen | Önlediği olay |
| --- | --- | --- | --- |
| `frontend-main` (skylab-site girişi) | `frontend-main-core-audience` / `core-audience` | `core` | core her Bearer token'da `aud` içinde `core` ister (ADR 0019). Site editörlerinin (ADMIN dahil) `core` rolü yoktur. Site, CMS görsel yüklemesinde (`/api/cms-media` → core `POST /v1/media`) editörün token'ını iletir; her yükleme 401 aldı. Elle kuruldu: 2026-09-25. |
| `frontend-arge` (arge girişi) | `frontend-arge-core-audience` / `core-audience` | `core` | `frontend-main` ile aynı gerekçe: CMS inscribed'a geçerken (ADR-0056) arge'nin CMS yüklemeleri de editörün token'ıyla core `POST /v1/media`'ya gider. Elle kurulum: sky_lab_genel `ops/wizards/inscribed-keycloak-roles-wizard.sh` (§12), bu uzlaştırıcının kuracağı biçimin aynısıyla. |
| `skyforms` (SkyForms girişi) | `skyforms-forms-audience` / `forms-audience` | `forms` | forms-backend `aud` içinde `forms` ister. Yöneticilerin `forms` rolü vardır, üyelerin yoktur: üyeler 401 aldı, SkyForms "Oturumunuzun süresi doldu" döngüsüne girdi. Elle kuruldu: 2026-09-21. |

`frontend-main` ve `frontend-arge`'ın kapsamları 2026-10-05'ten beri giriş istemcilerinin
daraltma adımında (§21) kurulur; aynı ad, aynı mapper, aynı devralma.

Uzlaştırıcı hepsini `skyapp-account-center-audience` gibi yönetir: kapsam
`include.in.token.scope=false`, `display.on.consent.screen=false`; tek mapper
`oidc-audience-mapper`, access token ve introspection'da açık, ID token'da kapalı
(`config/frontend-main-core-audience-mappers.json`,
`config/frontend-arge-core-audience-mappers.json`,
`config/skyforms-forms-audience-mappers.json`); başka mapper silinir; kapsam istemcinin
varsayılan kapsamıdır (isteğe bağlı listedeyse oradan alınır). Kapsam ve mapper adla
bulunur, yeniden oluşturulmaz, yerinde onarılır. İstemci realm'de yoksa (sandbox'ta iki
site istemcisi de yok) uzlaştırıcı `WARNING: client <istemci> does not exist in realm <realm>;
skipped client scope <kapsam>` yazar, kapsamı kurmaz ve devam eder; istemci eklenince
sonraki koşu kurar.

`frontend-arge-core-audience` wizard'la uzlaştırıcının biçiminde kurulduğu için onu
içeren ilk üretim koşusunda beklenen satır `client scope frontend-arge-core-audience:
unchanged`'dır (Keycloak'ın mapper'a eklediği `userinfo.token.claim=false` fark sayılmaz:
karşılaştırma istenen alanların alt kümesidir).

İlk üretim koşusunda beklenen: iki `client scope ...: updated (attributes)` satırı
(Admin Console yeni kapsamı büyük olasılıkla `include.in.token.scope=true` ile kurar;
tek etkisi token'ın `scope` claim'inden bu iki adın düşmesidir). `created`, mapper
`updated` ya da `default client scope ... attached` görürseniz elle kurulan durum
beklenenden farklıymış; uzlaştırıcı düzeltmiştir, nedenini not edin. İkinci koşuda iki
satır da `unchanged` olmalıdır. Doğrulama: Admin Console → Clients → `frontend-main`
(ya da `skyforms`) → Client scopes → Evaluate, rolü olmayan bir kullanıcıyla: access
token'ın `aud`'u `core` (ya da `forms`) içerir, ID token içermez. Harness
(`tests/login-client-audiences.sh`) devralmayı, eksik istemcide atlamayı, kayma
onarımını, rolsüz bir kişinin iki token'ını ve no-op koşuyu doğrular.

## 1. Ön koşullar

1. Hesap Merkezi'nin A0b imajı (hem `["account"]` hem `["account","core"]`
   audience kümesini kabul eden doğrulayıcı) üretimde çalışıyor olmalıdır.
   Aksi halde uzlaştırma anında bütün Hesap Merkezi oturumları düşer.
2. `keycloak-mailer` istemcisi uzlaştırıcı tarafından değil, operatör
   tarafından `config/create-mailer-client.sh` ile oluşturulur (§6);
   uzlaştırıcı istemci yokken yalnız `WARNING: client keycloak-mailer does not
   exist; run: ...` yazar ve sürümü engellemez. SkyMail'in
   `skymail:mails:send` istemci rolü (M1) henüz yoksa betik
   `WARNING: client skymail lacks the roles skymail:mails:send` yazar; rol
   oluşturulduktan sonra betik yeniden koşulur (idempotent).
3. Yedek + geri yükleme provası (`keycloak-26.7.4-upgrade-runbook.md` §1 ve
   §8) bu sürüm için yeniden yapılır; RP ID değişikliği geri alınabilir
   olmalıdır.
4. Passkey sahipleri için ön kontrol (aşağıda §2) çalıştırılır ve duyuru (§3)
   sürümden en az bir hafta önce gönderilir.

## 2. Salt okunur ön kontrol SQL'i (üretim veritabanı)

Yalnız `SELECT` içerir; `psql` ile Keycloak veritabanında (`keycloak`, şema
`public`) çalıştırılır. Çıktı kişisel veri içerdiği için yalnız operatörde
kalır; bilete, sohbete veya depoya yapıştırılmaz.

Yalnız passkey ile giren, OBS (YTÜ Microsoft) bağlantısı ve parolası olmayan
kişilerin sayısı (RP ID değişince tek giriş yolları kapanır; önce onlara
ulaşılmalıdır):

```sql
SELECT count(*) AS passkey_only_users
FROM user_entity u
JOIN realm r ON r.id = u.realm_id AND r.name = 'e-skylab'
WHERE u.enabled = true
  AND u.service_account_client_link IS NULL
  AND EXISTS (
    SELECT 1 FROM credential c
    WHERE c.user_id = u.id AND c.type = 'webauthn-passwordless')
  AND NOT EXISTS (
    SELECT 1 FROM credential c
    WHERE c.user_id = u.id AND c.type = 'password')
  AND NOT EXISTS (
    SELECT 1 FROM federated_identity f
    WHERE f.user_id = u.id AND f.identity_provider = 'OBS');
```

Aynı kişilerin iletişim listesi (yalnız operatör için):

```sql
SELECT u.username, u.email,
       count(c.id) AS passkeys,
       to_timestamp(max(c.created_date) / 1000.0) AS last_passkey_at
FROM user_entity u
JOIN realm r ON r.id = u.realm_id AND r.name = 'e-skylab'
JOIN credential c ON c.user_id = u.id AND c.type = 'webauthn-passwordless'
WHERE u.enabled = true
  AND u.service_account_client_link IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM credential p
    WHERE p.user_id = u.id AND p.type = 'password')
  AND NOT EXISTS (
    SELECT 1 FROM federated_identity f
    WHERE f.user_id = u.id AND f.identity_provider = 'OBS')
GROUP BY u.username, u.email
ORDER BY u.username;
```

Geçişten etkilenecek toplam passkey sayısı (duyuru ve temizlik için):

```sql
SELECT count(*) AS passkeys_before_switch,
       count(DISTINCT c.user_id) AS passkey_holders
FROM credential c
JOIN user_entity u ON u.id = c.user_id
JOIN realm r ON r.id = u.realm_id AND r.name = 'e-skylab'
WHERE c.type = 'webauthn-passwordless';
```

Beklenen üretim değerleri (2026-09-21 tespiti): 35 passkey, `password`
kimlik bilgisi 1, OBS bağlantısı 115 kişi. Yalnız passkey ile giren kişi
sayısı sıfır değilse bu kişilere e-posta ile ulaşılır ve YTÜ hesabını
bağlamaları ya da sürümden önce parola tanımlamaları istenir.

### A6 ön kontrolü: realm varsayılan rolünün `account` bileşenleri

`kc_action=idp_link` (YTÜ hesabını `my.` üzerinden bağlama, A6) Keycloak'ın
`IdpLinkAction` denetiminden geçer: `account-center` istemcisinin
`manage-account` / `manage-account-links` scope mapping'i yetmez, **kişinin
kendisi** `account.manage-account` ya da `account.manage-account-links` rolünü
taşımalıdır (`user.hasRole`). Uzlaştırıcı bilerek realm geneline rol vermez;
token'daki roller sabit mapper'lardan gelir. Bu nedenle sürümden önce
`default-roles-e-skylab` bileşik rolünün bu rolleri içerip içermediği salt
okunur olarak yazdırılır (Keycloak konteyneri içinde, geçici yönetici
oturumuyla, K0 sihirbazındaki gibi parola kcadm'ın kendi prompt'una):

```bash
/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
  --realm master --user <geçici-yönetici>
/opt/keycloak/bin/kcadm.sh get roles/default-roles-e-skylab/composites -r e-skylab \
  --fields name,clientRole,containerId --format csv --noquotes
account_uuid=$(/opt/keycloak/bin/kcadm.sh get clients -r e-skylab -q clientId=account \
  --fields id --format csv --noquotes)
/opt/keycloak/bin/kcadm.sh get "roles/default-roles-e-skylab/composites/clients/$account_uuid" \
  -r e-skylab --fields name --format csv --noquotes
```

İkinci komutun çıktısında `manage-account` (Keycloak varsayılanı; bileşik
olarak `manage-account-links` içerir) ya da `manage-account-links` yoksa A6
üretimde `NOT_ALLOWED` ile durur: bu durumda ya `default-roles-e-skylab`
bileşimine `account.manage-account-links` eklenir (realm geneline yalnız
bağlantı yönetme yetkisi verir; superadmin/yönetim kararı, uzlaştırıcı
dışında) ya da A6 ertelenir. Sonuç değişiklik kaydına yazılır. Uyarı: Hesap
REST'in 403 verdiği eski üretim sapması tam olarak bu bileşenlerin eksik
olmasıydı; entegrasyon fixture'ı aynı sapmayı bilerek üretir.

## 3. Duyuru metni

Konu: SKY LAB hesabınızdaki passkey'i yeniden kaydetmeniz gerekiyor

> Merhaba,
>
> SKY LAB kimlik sistemi <tarih> tarihinde tek bir passkey'in hem
> `e.yildizskylab.com` hem `my.yildizskylab.com` üzerinde çalışmasını sağlayan
> yeni güvenlik ayarına geçiyor. Bu geçişle birlikte <tarih> öncesinde
> kaydettiğiniz passkey'ler teknik olarak geçersiz kalacak; cihazınızda
> görünmeye devam etseler bile giriş için kullanılamayacaklar.
>
> Yapmanız gereken: geçişten sonra <https://my.yildizskylab.com> adresine YTÜ
> Microsoft hesabınız ya da parolanızla girin, **Güvenlik** sayfasından yeni bir
> passkey ekleyin ve eski passkey'i cihazınızın parola yöneticisinden silin.
> Eski passkey kayıtlarını biz de sistemden kaldıracağız.
>
> YTÜ hesabınız bağlı değilse ve parolanız yoksa geçişten önce
> <https://my.yildizskylab.com> üzerinden YTÜ hesabınızı bağlayın; aksi halde
> geçiş sonrasında giriş yapamazsınız. Sorunuz için <destek adresi>.
>
> SKY LAB WebLab

## 4. Üretim sırası

1. Yedek alın, geri yükleme provasını kaydedin (§1.3).
2. Yeni imaj digest'i ile `keycloak` servisini dağıtın; `/health/ready`
   yeşil olduktan sonra `keycloak-config` işini bir kez çalıştırın:

   ```bash
   docker compose -f docker-compose.yml run --rm --no-deps keycloak-config
   ```

   Günlükte ilk koşuda beklenen satırlar: `passkey relying party id switches
   from '(empty)' to 'yildizskylab.com': realm attribute
   skylab.passkeyRpIdSwitchedAt=<an> recorded` (bu an §5'teki temizliğin
   cutover'ıdır; değişiklik kaydına yazın), ardından `updated`: passwordless
   passkey policy (rpId, extraOrigins), brute force protection and password
   policy, user profile, protocol mappers
   of scope account-center-account-api (`+account-api-core-audience`,
   `+account-api-manage-account-links`, `+account-api-sky-authorization`,
   `~account-api-audience`; canlı audience mapper'larda `userinfo.token.claim`
   anahtarı yoktur, bir kez tamamlanır), protocol mappers of scope
   skyapp-account-center-audience (`~account-center-audience`, aynı neden),
   account role scope mappings (`+manage-account-links`). `client
   account-center` satırı `unchanged` olmalıdır (`fullScopeAllowed=false` v1'den
   beri böyledir; `updated (fullScopeAllowed)` görürseniz biri istemciyi elle
   açmıştır, nedenini bulun). `keycloak-mailer`
   için `WARNING: client keycloak-mailer does not exist; run: ...` beklenir
   (§6'daki betik çalıştırılana kadar). Realm oturum/giriş/tema ve required
   action satırları `unchanged` olmalıdır. Günlüğü (gizli anahtar içermez)
   değişiklik kaydına ekleyin.
3. Aynı işi ikinci kez çalıştırın; her `[reconcile]` satırı `unchanged`,
   `asserted` ya da `verified` olmalıdır (tek kabul edilen uyarı, uzlaştırıcı
   kimliğinin `keycloak-mailer` service account rollerini okuyamadığını
   söyleyen satırdır). Bir satır hâlâ `updated` diyorsa durun ve nedenini
   bulun; bu, dış bir aracın aynı alanı yazdığı anlamına gelir.
4. Token sözleşmesini gerçek bir token üretmeden doğrulayın: Admin Console →
   Clients → `account-center` → Client scopes → Evaluate → bir kullanıcı seçin
   → Generated access token. Beklenen: `aud` tam olarak `account` ve `core`,
   `sky_authorization.<istemci>.roles` altında kişinin uygulama rolleri
   (`realm-management` gibi yönetim istemcileri asla), `resource_access`
   altında yalnız `account`, `realm_access` yok; Clients → `account-center` →
   Client scopes sekmesinde "Full scope allowed" kapalı. Ardından
   `my.yildizskylab.com` üzerinde yeni bir giriş yapın; Hesap Merkezi
   günlüğünde `token_audience_legacy` olayı görülmemelidir (A0b).
5. Passkey doğrulaması: Touch ID ile `e.yildizskylab.com` üzerinde yeni bir
   passkey kaydedin, çıkış yapıp passkey ile girin; aynı passkey'in
   `my.yildizskylab.com` girişinde de çalıştığını doğrulayın (sürüm kanıtı,
   `keycloak-26.7.4-upgrade-runbook.md` "Known gates").
6. Brute force ve parola politikasını doğrulayın: Realm settings → Security
   defenses → Brute force detection (10 deneme, 1 dk artan bekleme, en çok 15
   dk, 12 saat sıfırlama) ve Authentication → Policies → Password policy.
7. User Profile'ı doğrulayın: Realm settings → User profile; `email`
   kişi tarafından düzenlenemez, yedi SKY LAB özniteliği görünür,
   Unmanaged attributes = "Only administrators can view".
8. `keycloak-mailer` istemcisini `config/create-mailer-client.sh` ile
   oluşturun, uzlaştırıcıyı bir kez daha çalıştırıp `client keycloak-mailer:
   verified` satırını görün ve gizli anahtarı K5 için teslim edin (§6).

## 5. Geçiş sonrası eski passkey temizliği

Eski RP ID'ye bağlı passkey'ler hiçbir zaman doğrulanamaz; giriş sayfasında
ölü passkey teklif edilmemesi için duyuru süresi dolduktan sonra silinir.
`config/cleanup-legacy-passkeys.sh` imajın içindedir, varsayılanı kuru
koşudur (`--dry-run`), yalnız sayı basar (kullanıcı adı, kimlik bilgisi
kimliği, gizli anahtar yazmaz) ve `--apply` verilmeden hiçbir şeyi silmez.
Cutover, uzlaştırıcının geçiş anında yazdığı realm özniteliği
`skylab.passkeyRpIdSwitchedAt` değeridir ve varsayılan olarak oradan okunur
(`cutoverSource=realmAttribute`). `--cutover` yalnız bu ana eşit ya da daha
erken bir zaman olabilir; daha geç bir değer açık bir hata ile reddedilir
(geçişten sonra kaydedilen passkey'ler geçerlidir, silinmemelidir), gelecek
zaman damgası reddedilir, öznitelik yoksa (geçiş bu sürümden önce yapılmışsa)
`--cutover` zorunludur ve RP ID hâlâ boşsa betik durur. Silme hataları
sayılır (`passkeysDeleteFailed`), özet yine basılır ve betik sonda sıfır dışı
çıkar; yeniden `--apply` yalnız kalanları siler.

Uzlaştırıcı istemcisinin kullanıcı yetkisi yoktur; betik geçici bir yönetici
hesabıyla (bootstrap adımındaki gibi, `KEYCLOAK_ADMIN_REALM=master`) çalışır.
Parola kcadm'ın kendi terminalinde sorulur; `KEYCLOAK_CLEANUP_ADMIN_PASSWORD`
yalnız entegrasyon harness'inde (`SKY_HARNESS=1`) kabul edilir, üretimde
parola argv'den geçmez.

```bash
# 1) Yeni bir veritabanı yedeği + geri yükleme provası (§1.3)
# 2) Kuru koşu: cutover=<skylab.passkeyRpIdSwitchedAt> satırını ve sayıları değişiklik kaydına ekleyin
docker compose -f docker-compose.yml run --rm --no-deps -it \
  -e KEYCLOAK_ADMIN_REALM=master \
  -e KEYCLOAK_CLEANUP_ADMIN_USERNAME=<geçici-yönetici> \
  --entrypoint /opt/keycloak/config/cleanup-legacy-passkeys.sh \
  keycloak-config

# 3) Uygulama: passkeysDeleted sayısı kuru koşudaki passkeysBeforeCutover ile aynı, passkeysDeleteFailed=0 olmalıdır
docker compose -f docker-compose.yml run --rm --no-deps -it \
  -e KEYCLOAK_ADMIN_REALM=master \
  -e KEYCLOAK_CLEANUP_ADMIN_USERNAME=<geçici-yönetici> \
  --entrypoint /opt/keycloak/config/cleanup-legacy-passkeys.sh \
  keycloak-config --apply

# 4) Geçici yöneticiyi kaldırın (bootstrap runbook'undaki gibi)
```

Çıktı satırları: `realm=… relyingPartyId=… cutover=… cutoverSource=…
mode=…`, `usersScanned`, `usersWithPasskeys`, `usersWithLegacyPasskeys`,
`usersLeftWithoutPasskeys` (bütün passkey'leri eski olan kişiler; yeniden
kayıt duyurusunun hedef kitlesi), `passkeysTotal`, `passkeysBeforeCutover`,
`passkeysDeleted`, `passkeysDeleteFailed`. Silme Admin REST
`DELETE users/{id}/credentials/{credentialId}` ile yapılır ve her silme
`REMOVE_CREDENTIAL` yönetici olayı bırakır. Entegrasyon harness'i aynı akışı
gerçek bir geçiş etrafında çalıştırır: geçişten önce kaydedilen passkey
silinir, geçişten sonra kaydedilen kalır, geç `--cutover` reddedilir, silme
hatası sıfır dışı çıkışla raporlanır.

## 6. `keycloak-mailer` istemcisinin oluşturulması ve gizli anahtarın teslimi (K5)

Uzlaştırıcı kimliğinin kullanıcı yetkisi yoktur (`manage-users` bilerek
verilmez: parola sıfırlama ve kullanıcı silme gücü, gizli anahtarı sunucuda
duran bir istemciye ait olmamalıdır). Bu yüzden `keycloak-mailer` istemcisini,
`roles` varsayılan kapsamını ve service account'un `skymail:access` +
`skymail:mails:send` rollerini operatör, imajdaki idempotent
`config/create-mailer-client.sh` betiğiyle oluşturur. Betik varsayılan olarak
kuru koşudur (istemci henüz yokken de istemci, `roles` kapsamı ve rol
adımlarının tamamını sayar), `--apply` ile uygular; yönetici parolası kcadm'ın
kendi prompt'una yazılır (K0 sihirbazındaki gibi), betikten geçmez
(`KEYCLOAK_MAILER_ADMIN_PASSWORD` yalnız `SKY_HARNESS=1` ile kabul edilir,
aksi halde betik durur); gizli anahtarı yazdırmaz; `skymail` rolleri yoksa
uyarır, asla oluşturmaz; rol listesi dışındaki atamaları kaldırır.

```bash
# Kuru koşu: planı gösterir, hiçbir şey yazmaz
docker compose -f docker-compose.yml run --rm --no-deps -it \
  --entrypoint /opt/keycloak/config/create-mailer-client.sh \
  keycloak-config --admin-user <geçici-yönetici>

# Uygulama
docker compose -f docker-compose.yml run --rm --no-deps -it \
  --entrypoint /opt/keycloak/config/create-mailer-client.sh \
  keycloak-config --admin-user <geçici-yönetici> --apply

# Doğrulama: uzlaştırıcı "client keycloak-mailer: verified" yazmalı
docker compose -f docker-compose.yml run --rm --no-deps keycloak-config
```

Keycloak gizli anahtarı üretir; hiçbir betik bu değeri yazdırmaz. Yetkili
operatör değeri bir kez, kabuk geçmişi ve terminal kaydı kapalıyken okur ve
SkyMail sağlayıcısının okuyacağı gizli dosyaya (`SKY_MAIL_CLIENT_SECRET` dosya
bağı, K5) yazar:

```bash
# Keycloak konteyneri içinde, geçici yönetici oturumuyla
/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
  --realm master --user <geçici-yönetici>
client_id=$(/opt/keycloak/bin/kcadm.sh get clients -r e-skylab -q clientId=keycloak-mailer \
  --fields id --format csv --noquotes)
/opt/keycloak/bin/kcadm.sh get "clients/$client_id/client-secret" -r e-skylab
```

Döndürme: Admin Console'dan yeni anahtar üretilir, SkyMail sağlayıcısının
gizli dosyası güncellenir, Keycloak yeniden başlatılır; eski değer geçersiz
kalır. `keycloak-mailer` service account'ının yalnız `skymail:access` ve
`skymail:mails:send` rollerini taşıdığı token'ın `resource_access` alanından
doğrulanır (entegrasyon testi aynı kontrolü yapar).

## 7. Geri dönüş

Parola formunun (K4) geri dönüşü imajdan **önce** yapılır: §15'teki
`KEYCLOAK_PASSWORD_FORM=auth-username-password-form` koşusu. Akış
`sky-username-password-form`'u gösterirken 1.14.0'dan eski bir imaja dönülürse realm'in
bütün parolalı girişleri durur.

Parola sıfırlama adımının (K4b) geri dönüşü de imajdan **önce** yapılır: §17'deki
`KEYCLOAK_RESET_CHOOSE_USER=reset-credentials-choose-user` koşusu. Bağlı akış
`sky-reset-credentials-choose-user`'ı gösterirken 1.15.0'dan eski bir imaja dönülürse
"Şifremi unuttum" isteklerinin hepsi hata verir. 1.14.0'a dönülecekse yalnız bu bayrak,
1.14.0'dan da eskiye dönülecekse iki bayrak aynı koşuda verilir. Her imajda çalışan acil yol:
Admin Console'dan realm'in Reset credentials flow bağlantısını yerleşik `reset credentials`'a
geri almak (§17).

Group overage mapper'ı (`sky-group-overage-mapper`, SPI 1.16.0, ADR-0059) da imajdan **önce** geri
alınır: 1.16.0'dan eski bir imaja dönmeden önce, onu kullanan her istemcide
`sky-group-overage-mapper` yerleşik Group Membership mapper'ına geri çevrilir; yoksa Keycloak eksik
mapper'ı sessizce atlar ve token'lar `groups` claim'ini kaybeder.

Realm ayarları için ayrı bir geri dönüş yolu yoktur; önceki imaj digest'i ile
eski uzlaştırıcı çalıştırıldığında RP ID yeniden boşalır (Keycloak passwordless
politikayı her yazımda bütünüyle yeniden kurar) ve `account-center` istemcisi
v1 sözleşmesine döner (`sky-authorization-mapper` eski imajda bulunmadığından
`account-api-sky-authorization` mapper'ı silinir), ancak brute force, parola
politikası, User Profile, `skylab.passkeyRpIdSwitchedAt` özniteliği ve
`keycloak-mailer` eski uzlaştırıcı tarafından yönetilmediği için olduğu gibi
kalır. Tam geri dönüş §1.3'teki veritabanı yedeğinin geri yüklenmesidir; geri
yüklemeden sonra yeni RP ID ile kaydedilmiş passkey'ler kaybolur. `keycloak-mailer`
istemcisi uzlaştırıcıya bağlı değildir; gerekirse Admin Console'dan silinir.

## 8. Kimlik korumaları: core sertifika rolleri, OBS bölüm eşlemesi, core'un en az yetkisi

`config/identity-guardrails.sh` imajın içindedir ve uzlaştırıcının yapamadığı
üç işi bu sırayla yapar. Uzlaştırıcı kimliğinin kullanıcı yetkisi
(`manage-users`) ve kimlik sağlayıcısı yetkisi (`manage-identity-providers`,
okumak için bile `view-identity-providers`) yoktur; bu yüzden betik
`create-mailer-client.sh` gibi geçici bir yöneticiyle çalışır. Varsayılanı
kuru koşudur (planı `would ...` satırlarıyla basar, hiçbir şey yazmaz);
`--apply` uygular; ikinci koşu hiçbir şey yazmaz ve hiçbir admin olayı
üretmez. Yönetici parolası kcadm'ın kendi prompt'una yazılır
(`KEYCLOAK_GUARDRAILS_ADMIN_PASSWORD` yalnız `SKY_HARNESS=1` ile kabul
edilir). core'un istemci kimliği `--core-client` ya da
`KEYCLOAK_CORE_CLIENT_ID` ile değişir (varsayılan `core`).

1. **core'un sertifika rolleri.** `core` istemcisinde
   `certificate:template:manage`, `certificate:binding:manage`,
   `certificate:issue` ve `certificate:revoke` yoksa oluşturulur (core'un
   kendisinin oluşturduğu gibi açıklamasız). Var olanlara dokunulmaz. core
   artık bu rolleri kendisi oluşturmaz; açılışta yalnız okur ve eksik rol varsa
   bu betiği adıyla gösteren bir uyarı basar.
2. **OBS `department mapper` → `syncMode=FORCE`.** Kişiler bölüm
   değiştirdiği için bölüm her YTÜ Microsoft girişinde Microsoft Graph'tan
   yeniden okunur. SPI 1.13.1'deki `microsoft-department-mapper` `FORCE`'da
   her girişte günceller; `LEGACY`'de (IdP'nin `LEGACY` modunu izleyen
   `INHERIT` dahil) eskisi gibi yalnız boş bölümü doldurur. Graph'a
   ulaşılamazsa, token yoksa ya da Graph boş dönerse kayıtlı bölüm silinmez.
   IdP yoksa adım atlanır (`identity provider OBS does not exist ...
   skipped`); o adla eşleme yoksa uyarı basılır. Aynı adla birden fazla eşleme
   ya da farklı türde bir eşleme varsa hiçbir şey yazılmaz, betik sonda sıfır
   dışı çıkar. IdP'nin kendisine ve diğer eşlemelere (`school-email-importer`,
   `university`) dokunulmaz.
3. **`service-account-core`'dan `manage-clients` kaldırılır**, diğer
   `realm-management` rolleri (`view-clients`, `query-clients`,
   `manage-users` ...) kalır. ADR-0048 core'a `manage-clients` vermeyi
   reddetti: bu rol core'un her istemcinin yönlendirme adreslerini ve gizli
   anahtarlarını yeniden yazabilmesi demektir. core bu rolü yalnız 1. adımdaki
   rolleri oluşturmak için kullanıyordu (`POST /clients/{id}/roles`); rolleri,
   rol sahiplerini ve istemcileri okumak `view-clients`/`query-clients` ile
   çalışır. Bu adım yalnız 1. adım dört rolün de var olduğunu doğruladıktan
   sonra çalışır. Rol bir bileşik rol (ör. `realm-admin`) ya da grup üzerinden
   hâlâ geliyorsa betik bunu yazar ve sıfır dışı çıkar; o kaynak elle
   kaldırılır.

### Üretim sırası

1. Bu betiği ve SPI 1.13.1'i taşıyan Keycloak sürümü yayımlanır (production
   dalı, Dokploy yeniden dağıtımı; `/health/ready` yeşil).
2. Sunucuda (`api.yildizskylab.com`), geçici bir master yöneticisiyle önce
   kuru koşu, çıktı kontrol edildikten sonra uygulama. Üretim Keycloak'ı bir
   Dokploy Application'ıdır; betik çalışan konteynerin içinde koşar:

   ```bash
   kc=$(docker ps -q -f name=sky-lab-production-keycloak | head -n 1)
   docker exec -it -e KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080 -e KEYCLOAK_REALM=e-skylab "$kc" \
     /opt/keycloak/config/identity-guardrails.sh --admin-user <geçici-yönetici>
   docker exec -it -e KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080 -e KEYCLOAK_REALM=e-skylab "$kc" \
     /opt/keycloak/config/identity-guardrails.sh --admin-user <geçici-yönetici> --apply
   ```

   Compose ile çalışan bir ortamda aynı iş:
   `docker compose -f docker-compose.yml run --rm --no-deps -it --entrypoint
   /opt/keycloak/config/identity-guardrails.sh keycloak-config --admin-user
   <geçici-yönetici> [--apply]`.

   Kuru koşuda beklenen: eksik sertifika rolleri için `would create client
   role ... on core`, `would set sync mode of identity provider OBS mapper
   'department mapper' from INHERIT to FORCE`, `would remove realm-management
   role manage-clients from service-account-core`, kalan rollerin listesi
   (`view-clients` ve `query-clients` içinde olmalı). Uygulamadan sonra kuru
   koşu `dry run: 0 change(s) pending` demelidir. Üç adım tek koşuda
   uygulanır: `manage-clients`'ın kaldırılması hâlâ eski core çalışırken de
   güvenlidir, çünkü eski core yalnız eksik rolü oluşturmaya çalışır ve betik
   rolü ancak dört rolün var olduğunu doğruladıktan sonra kaldırır; eski core
   yeniden başlarsa rolleri yalnız okur. Ayrı bir ikinci koşu gerekmez.
3. core'un salt okunur rol denetimini taşıyan sürümü yayımlanır.
4. core'un açılış günlüğünde `certificate client roles` ile başlayan bir
   uyarı olmamalıdır. Bir YTÜ hesabıyla giriş yapıldıktan sonra Admin Console
   → Users → kişi → Attributes'ta `department` Graph'taki değeri gösterir.
5. Geçici yönetici kaldırılır.

Geri dönüş: `department mapper` Admin Console'dan `INHERIT`'e alınır
(bölüm yalnız boşsa doldurulur). `manage-clients` geri verilmez; core'un
yeni sürümü ona ihtiyaç duymaz. Oluşturulan roller zararsızdır ve kalır.

## 9. Hesap Merkezi token'ında YTÜ üniversite ve bölüm claim'leri (C2)

Üniversite ve bölüm YTÜ Microsoft girişini izler. OBS `department mapper`
her girişte bölümü yeniler (§8); core, `university` ve `department`
claim'lerini taşıyan her token'da kişinin üniversite, bölüm ve fakültesini
yeniler ve `ytu_linked` yapar. Diğer istemciler bu claim'leri realm'in
`department_ve_university_to_jwt` kapsamından alır. `account-center`'ın
varsayılan kapsamları ise bilerek yalnız `account-center-account-api` ve
`account-center-core-claims`'tir (`fullScopeAllowed=false`, en az claim).
Bu yüzden yalnız `my.yildizskylab.com` kullanan bir kişi core'daki kaydını
hiç yenilemiyordu.

Uzlaştırıcı artık `account-center-core-claims` kapsamına iki mapper ekler
(`config/account-center-core-claims-mappers.json`): `university` ve
`department`. İkisi de `oidc-usermodel-attribute-mapper`'dır ve aynı adlı
kullanıcı özniteliğini aynı adlı claim'e yazar.

- **Biçim:** `jsonType.label=String`, `multivalued=false`. Bu, realm'deki
  `department_ve_university_to_jwt` kapsamıyla aynıdır (2026-09-21
  gerçekleri): claim düz bir metindir. core hem metni hem diziyi okur.
- **Yüzeyler:** yalnız access token ve introspection cevabı. core kişiyi
  Hesap Merkezi'nin access token'ından okur. ID token ve userinfo'da yoktur:
  Hesap Merkezi bu alanları token'dan değil core'un `ytuLinked` görünümünden
  okur, oturumunda sakladığı ID token da küçük kalır. Kapsamdaki diğer
  mapper'lar da introspection'a yazar.
- **Öznitelik yoksa claim yoktur.** core boş bir değeri değişiklik diye
  okumaz ve YTÜ bağlantısı olmayan kişiyi bağlı saymaz.
- `department_ve_university_to_jwt` kapsamının kendisi `account-center`'a
  eklenmez. Uzlaştırıcı varsayılan kapsamları tam bir küme olarak uygular;
  o kapsamın ID token ve userinfo ayarları uzlaştırıcının dışında elle
  değişebilir.

Uzlaştırıcı mapper'ları ada göre eşler. Eksik olanı oluşturur, farklı olanı
yeniden yazar, kapsamda listede olmayan mapper'ı siler. Değişmeyen koşu
hiçbir şey yazmaz. Entegrasyon testi şunları kanıtlar:

- mapper sözleşmesini;
- silinen `university` mapper'ının yeniden oluşturulmasını ve çok değerli ID
  token claim'ine kaymış `department` mapper'ının onarılmasını;
- boş koşunun hiçbir admin olayı üretmemesini;
- öznitelikleri olan bir kişinin `account-center` access token'ında ve core'un
  introspection cevabında iki düz metin claim'i, ID token ve userinfo'da
  hiçbirini;
- özniteliği olmayan kişinin token'ında hiçbir claim olmamasını.

### Üretim sırası

1. Bu mapper'ları taşıyan Keycloak sürümü yayımlanır. `main` tek squash
   commit'le `production`'a alınır, `keycloak-production` ortamındaki Touch ID
   onay değişkenleri o commit'e bağlanır, release iş akışı imajı yayımlar ve
   Dokploy'u tetikler. `/health/ready` yeşil olmalıdır. Uzlaştırıcı imajın
   içindedir; imaj değişmeden `reconcile-account-center.sh` eski mapper
   listesini uygular.
2. Sunucuda (`api.yildizskylab.com`) uzlaştırıcı, Hesap Merkezi sürüm
   sihirbazlarındaki gibi çalışan üretim Keycloak konteynerinin içinde bir kez
   koşar. Kapsamlı uzlaştırıcı istemcisinin gizli anahtarı yalnız stdin'den
   geçer, ekrana basılmaz:

   ```bash
   kc=$(docker ps -q -f name=sky-lab-production-keycloak | head -n 1)
   sudo cat <config-client.secret dosyası> | docker exec -i "$kc" sh -eu -c '
     IFS= read -r KEYCLOAK_CONFIG_CLIENT_SECRET; export KEYCLOAK_CONFIG_CLIENT_SECRET
     export KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080 KEYCLOAK_REALM=e-skylab
     export ACCOUNT_CENTER_BASE_URL=https://my.yildizskylab.com ACCOUNT_CENTER_REQUIRE_PRODUCTION_HOST=true
     export KEYCLOAK_PASSKEY_RP_ID=yildizskylab.com KEYCLOAK_PASSKEY_EXTRA_ORIGINS=https://my.yildizskylab.com
     exec /opt/keycloak/config/reconcile-account-center.sh'
   ```

   Beklenen tek değişiklik satırı
   `[reconcile] protocol mappers of scope <id>: updated (+university +department)`.
   Diğer satırlar `unchanged`, `asserted` ya da `verified` olmalıdır;
   `keycloak-mailer` rol uyarısı beklenir.
3. Aynı komutu ikinci kez çalıştırın. Hiçbir `[reconcile]` satırı `updated`
   dememelidir.
4. Admin Console → Clients → `account-center` → Client scopes → Evaluate'te
   YTÜ bağlantılı bir kişi seçin. Generated access token `university` ve
   `department`'ı düz metin olarak taşımalıdır; Generated ID token ve
   Generated user info taşımamalıdır. YTÜ bağlantısı olmayan bir kişinin
   token'ında ikisi de olmamalıdır. Ardından o YTÜ bağlantılı kişi yalnız
   `my.yildizskylab.com`'a girdiğinde core'daki kaydında `ytu_linked=true`
   olur, üniversite/bölüm/fakülte güncellenir.

Geri dönüş: bir önceki imaj yeniden dağıtılır ve uzlaştırıcı yeniden
çalıştırılır. Eski mapper listesi `university` ve `department`'ı kapsamdan
siler. core'daki kayıtlar kalır; kişi başka bir istemciyle girdiğinde yine
yenilenir.

## 10. Eski birincil adresin kişisel e-posta olarak devralınması (A1c)

v2'den önce konmuş bir Keycloak `email`'i okul adresi değilse ve kişinin hiç
`personalEmail`'i yoksa (**eski birincil**) `my./email` sayfası "henüz kişisel
e-posta eklemedin" derken hemen altında o adresi birincil olarak gösteriyordu.
Üretimde (2026-09-25, salt okunur sayım) 48 kişi böyle: 44 gmail.com, 1 hotmail,
3 başka alan adı, hiçbiri okul alan adında değil; 45'inde `emailVerified=true`
(Keycloak'ın kayıttaki doğrulama linki), 47'si OBS'ye bağlı, 1'inin okul adresi
yok. Karar (Yusuf): link ile doğrulanmış olanlar doğrudan kişisel e-posta olarak
devralınır; doğrulanmamış olanlar mevcut K3c kod akışıyla kanıtlar (Hesap
Merkezi o adres için "kodla doğrula" sunar).

`config/adopt-legacy-personal-email.sh` imajın içindedir ve §8'deki betiklerin
düzenindedir: varsayılanı kuru koşudur (yalnız sayılar, hiçbir şey yazmaz),
`--apply` yazar, ikinci koşu hiçbir şey yazmaz ve hiçbir admin olayı üretmez.
Yönetici parolası kcadm'ın kendi prompt'una yazılır
(`KEYCLOAK_LEGACY_EMAIL_ADMIN_PASSWORD` yalnız `SKY_HARNESS=1` ile kabul edilir).
**Çıktı yalnız sayıdır**: hiçbir adres, kullanıcı adı ya da kimlik basılmaz; adres
ve kimlikler yalnız konteynerin içindeki özel geçici dizinde durur ve çıkışta
silinir.

Seçilen kişi: service account değil; `email` dolu; `emailVerified=true`;
`email` okul adresine (`schoolEmail`, büyük/küçük harf duyarsız) eşit değil;
`personalEmail` yok; adres `yildiz.edu.tr` ya da herhangi bir alt alan adında
(`std.yildiz.edu.tr` dahil) değil. Böyle bir kişiye sky-account'un
`email/confirm`'ünün yazdığının aynısı yazılır, üstelik aynı Java koduyla
(`com.skylab.account.PersonalEmailProof`, imajdaki SPI jar'ından çağrılır):

- `personalEmail` = adres, kırpılmış ve `Locale.ROOT` ile küçük harf;
- `personalEmailVerifiedAt` = yazma anı, ISO-8601 UTC, tam saniye
  (ör. `2026-09-25T10:15:30Z`).

`email` ve `emailVerified`'a dokunulmaz: adres birincil kalır, `GET identity`
`primary: "personal"` ve `personalEmailVerified: true` okur. Hesabın diğer
alanları ve öznitelikleri olduğu gibi geri yazılır (yazmadan hemen önce hesap
yeniden okunur; o arada değişmişse atlanır ve `changedSinceScan` sayılır).

Devralınmayan, yalnız sayılanlar:

- `unverified`: Keycloak'ın doğrulamadığı eski birincil. Kişi `my./email`'de
  "kodla doğrula" ile kanıtlar; kod doğrulanınca adres kişisel e-posta olur,
  birincil kalır ve Keycloak onu doğrulanmış işaretler.
- `schoolDomain`: okul alan adındaki adres; okul adresi kişisel e-posta olamaz.
- `taken`: adres başka bir kişide (`email`, `schoolEmail` ya da `personalEmail`,
  büyük/küçük harf duyarsız).
- `duplicate`: aynı adres iki kişinin kişisel e-postası olacaktı; ikisi de
  atlanır. (`duplicateEmailsAllowed=false` olan realm'de pratikte oluşmaz.)

`taken` ve `duplicate` elle karar ister; betik bunları sayar ama sıfır dışı
çıkmaz. Yazma hatası olursa ya da uygulamadan sonraki yeniden taramada hâlâ
devralınacak kişi kalırsa betik sıfır dışı çıkar; `--apply` yeniden
çalıştırılabilir, devralınmış hesaplar yeniden yazılmaz. Yazma, Keycloak'ın
hesabın tamamını User Profile kurallarıyla yeniden doğrulaması demektir; bir
hesap bu yüzden reddedilirse (ör. v2'den önce kalmış ve artık izin verilmeyen
bir karakter taşıyan ad) yeniden koşu onu da reddeder. Betik kimlik basmadığı
için o hesap `failed` sayısıyla görünür; kişi "Kodla doğrula" ile aynı sonuca
kendisi ulaşabilir.

### Üretim sırası

1. Bu betiği ve SPI 1.13.2'yi taşıyan Keycloak sürümü yayımlanır (production
   dalı, Dokploy yeniden dağıtımı; `/health/ready` yeşil). 1.13.2 aynı zamanda
   `email/change-request`'in eski birincili kabul etmesini getirir.
2. Sunucuda (`api.yildizskylab.com`), §8'deki gibi geçici bir master
   yöneticisiyle önce kuru koşu, sayılar kontrol edildikten sonra uygulama:

   ```bash
   kc=$(docker ps -q -f name=sky-lab-production-keycloak | head -n 1)
   docker exec -it -e KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080 -e KEYCLOAK_REALM=e-skylab "$kc" \
     /opt/keycloak/config/adopt-legacy-personal-email.sh --admin-user <geçici-yönetici>
   docker exec -it -e KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080 -e KEYCLOAK_REALM=e-skylab "$kc" \
     /opt/keycloak/config/adopt-legacy-personal-email.sh --admin-user <geçici-yönetici> --apply
   ```

   Kuru koşuda beklenen (2026-09-25 sayımına göre): `legacyPrimaries=48`,
   `adopt=45 unverified=3 schoolDomain=0`, `duplicate=0 taken=0` ve
   `dry run: 45 adoption(s) pending`. Sayılar o günden bu yana değişmiş
   olabilir; `taken` ya da `duplicate` sıfırdan büyükse önce onlara bakılır.
   Uygulamada beklenen: `applied 45 adoption(s); failed=0 changedSinceScan=0`
   ve `after: legacy primaries still to adopt=0`. Ardından kuru koşu
   `dry run: 0 adoption(s) pending` demelidir.
3. Hesap Merkezi'nin eski birincil için "kodla doğrula"yı sunan sürümü
   yayımlanır (doğrulanmamış 3 kişi için).
4. Geçici yönetici kaldırılır.

Geri dönüş: devralma yalnız iki öznitelik ekler; bir kişi için geri almak
gerekirse Admin Console'da `personalEmail` ve `personalEmailVerifiedAt`
silinir (`email` zaten değişmemiştir). Toplu geri dönüş §1.3'teki veritabanı
yedeğidir.

## 11. Hesap silme: `core-erasure` istemcisi ve servislerin erase rolleri (ADR-0051)

core bir hesabı silerken SkyMail, CMS ve Forms'a birer silme komutu gönderir
(ADR-0051; komut sözleşmesi core-backend `docs/account-erasure-command.md`). Her
komutun token'ı ayrı bir Keycloak istemcisinden, `core-erasure`'dan gelir. Kural:
bir servise giden token başka bir servisin erase rolünü taşımaz. Taşısaydı token'ı
alan servis onu öbür servise gönderip silme yaptırabilirdi. core'un kendi istemcisi
(`core`) bu iş için kullanılmaz: onda `fullScopeAllowed` açıktır ve kapatmak core'un
bugünkü token'larını (SkyMail gönderimi, Admin REST) etkiler.

Sözleşme `config/erasure-client-contract.sh`'tadır; operatör betiği ve uzlaştırıcı
aynı dosyayı okur.

| Parça | Durum |
| --- | --- |
| `core-erasure` istemcisi | Gizli (`client-secret`), yalnız service account (standard flow, implicit ve direct grant kapalı), `fullScopeAllowed=false`, doğrudan scope mapping yok, `redirectUris` ve `webOrigins` boş |
| Varsayılan kapsamlar | Tam olarak `basic` ve `roles`. `basic` `sub`'ı verir: servislerin hesap erişim kapısı çağıranın kendi `sub`'ını okur, `sub`'sız token 401 alır (cms-backend #13). `roles` `resource_access`'i verir. Keycloak 26 `service_account` kapsamını her service account istemcisine ekler ve istemcinin her güncellemesinde (Admin Console'da kaydetme, rotatorun secret yazması) yeniden ekler; bu yüzden hoş görülür. Yalnız `client_id`, `clientHost` ve `clientAddress` verir. |
| İsteğe bağlı kapsamlar | Tam olarak `account-erase-skymail`, `account-erase-cms`, `account-erase-forms` |
| Her erase kapsamı | `openid-connect`. Tek mapper: `<kapsam>-audience` (`oidc-audience-mapper`, `included.client.audience=<servis istemcisi>`, access token ve introspection'da; ID token ve userinfo'da yok). Tek rol scope mapping'i: o servisin erase rolü. |
| Erase rolleri | `skymail` üzerinde `skymail:account:erase`, `skycms` üzerinde `cms:account:erase`, `forms` üzerinde `skyforms:account:erase`. Yalnız `service-account-core-erasure` taşır. |

Token isteği `grant_type=client_credentials`, `scope=openid account-erase-<servis>`
biçimindedir. Örneğin `account-erase-cms` token'ında `azp=core-erasure`,
`aud=["skycms"]`, `resource_access={"skycms":{"roles":["cms:account:erase"]}}` ve
`sub` (service account'un kimliği) vardır; öbür iki rol ve `realm_access` yoktur.
Erase kapsamı istenmeyen token hiçbir erase rolü taşımaz. Service account üç rolü de
taşır, ama `fullScopeAllowed=false` olduğundan bir rol token'a yalnız onu eşleyen
kapsam istendiğinde girer. core istemcisi bir erase kapsamı isteyemez
(`invalid_scope`).

`config/create-erasure-client.sh` imajın içindedir ve §8'deki betiklerin
düzenindedir: varsayılanı kuru koşudur, `--apply` yazar, ikinci koşu hiçbir şey
yazmaz ve hiçbir admin olayı üretmez; yönetici parolası kcadm'ın kendi prompt'una
yazılır (`KEYCLOAK_ERASURE_ADMIN_PASSWORD` yalnız `SKY_HARNESS=1` ile kabul edilir).
Sırası:

1. `skymail`, `skycms` ve `forms` istemcileri ile `basic` ve `roles` kapsamları var
   olmalıdır. Biri yoksa betik hiçbir şey yazmadan durur ve eksikleri adıyla yazar;
   servis istemcilerini servisler kurar.
2. Eksik erase rollerini oluşturur.
3. Erase kapsamlarını oluşturur ya da onarır: fazla ya da sapmış mapper'ı siler,
   audience mapper'ı ekler; kapsamdaki realm rollerini ve öbür servislerin rollerini
   kaldırır, kendi rolünü eşler.
4. İstemciyi oluşturur ya da bayraklarını düzeltir. Secret'ı Keycloak üretir; hiçbir
   betik basmaz.
5. Varsayılan ve isteğe bağlı kapsam listelerini tam olarak sözleşmeye getirir (bir
   kapsam listeler arasında önce ayrılır, sonra eklenir).
6. İstemcinin doğrudan scope mapping'lerini kaldırır.
7. Service account'a tam olarak üç erase rolünü verir; bu üç istemcideki başka
   rollerini kaldırır.
8. Bir erase rolünü service account'tan başka biri (kişi ya da grup) taşıyorsa bunu
   yazar ve sıfır dışı çıkar. O atamayı silmez; elle kaldırılır.

Uzlaştırıcı `core-erasure`'ı yalnız doğrular (§0; K2'deki `keycloak-mailer` ile aynı
gerekçe: service account'a rol atamak kullanıcı yetkisi ister). Başarılı doğrulama
`[reconcile] client core-erasure: verified (...)` ve her kapsam için
`[reconcile] erase scope <kapsam>: verified (aud ..., role ...)` satırlarıdır.

### Secret'ın core'a ulaşması

Secret hiçbir insanın elinden geçmez (ADR-0049). sky_lab_genel'deki
`ops/wizards/core-erasure-client-wizard.sh` sunucuda root olarak koşar ve her taraf
için, önce sandbox (`e-skylab-sandbox`), sonra production (`e-skylab`):

1. `create-erasure-client.sh`'ı çalışan Keycloak konteynerinde koşar: kuru koşu,
   onay, `--apply`.
2. Secret'ı Keycloak admin API'sinden belleğe okur (iki realm'deki `secret-rotator`
   istemcisiyle, o yoksa master yöneticisiyle) ve
   `kv/<taraf>/<core appName>/ACCOUNT_ERASURE_CLIENT_SECRET`'a yazar. Ardından üç
   erase kapsamının her biriyle ve kapsamsız birer token ister; yukarıdaki claim'leri
   denetler.
3. core'un Dokploy ortamına iki satır ekler, öbür satırlara dokunmaz ve deploy
   etmez: `ACCOUNT_ERASURE_CLIENT_ID=core-erasure` ve
   `ACCOUNT_ERASURE_CLIENT_SECRET=${{vault.bao-<taraf>.<core appName>/ACCOUNT_ERASURE_CLIENT_SECRET:value}}`.
   Referansın Dokploy'un kendi fetch'iyle çözüldüğünü ve değerin Keycloak'takiyle
   aynı olduğunu dener.
4. Rotator kuruluysa kuru çalışmasında `istemci core-erasure: eşleşti` satırını
   arar; sızıntı taraması yapar (OpenBao logları ve audit, Dokploy ortamları,
   operatör çıktısı).

Gece rotasyonu (`ops/wizards/openbao/rotate.sh`, ADR-0050)
`ACCOUNT_ERASURE_CLIENT_SECRET`'ı eşi `ACCOUNT_ERASURE_CLIENT_ID` ile tanır. core'un
iki Keycloak kalemi (`core` ve `core-erasure`) aynı birimde döner ve core bir kez
deploy edilir. core secret'ın kopyasını tutmaz; her token isteğinde ortamdan yeniden
okur.

### Üretim sırası

1. Bu betiği taşıyan Keycloak sürümü yayımlanır (production dalı, Dokploy yeniden
   dağıtımı; `/health/ready` yeşil). Uzlaştırıcı o andan itibaren
   `WARNING: client core-erasure does not exist; run: ...` yazar; bu sürümü
   engellemez.
2. `skymail`, `skycms` ve `forms` istemcilerinin iki realm'de de var olduğu
   doğrulanır. Betik eksik olanı adıyla yazar ve durur.
3. Sunucuda (`api.yildizskylab.com`) wizard koşulur; nasıl kopyalanacağı başında
   yazar: `sudo bash ~/openbao-setup/core-erasure-client-wizard.sh`. Geçici bir
   master yöneticisi gerekir; parolası yalnız kcadm'ın prompt'una yazılır. Betiği
   elle koşmak gerekirse (secret'ın taşınması yine wizard'ındır):

   ```bash
   kc=$(docker ps -q -f name=sky-lab-production-keycloak | head -n 1)
   docker exec -it -e KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080 -e KEYCLOAK_REALM=e-skylab-sandbox "$kc" \
     /opt/keycloak/config/create-erasure-client.sh --admin-user <geçici-yönetici>
   docker exec -it -e KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080 -e KEYCLOAK_REALM=e-skylab-sandbox "$kc" \
     /opt/keycloak/config/create-erasure-client.sh --admin-user <geçici-yönetici> --apply
   # sonra aynısı KEYCLOAK_REALM=e-skylab ile
   ```

   Hiç kurulmamış bir realm'de kuru koşuda beklenen: üçer `would create client
   role`, `would create optional client scope`, `would add audience mapper`,
   `would map role` ve `would assign role` satırı, bir `would create confidential
   service-account client core-erasure` satırı ve `dry run: 16 change(s) pending`.
   Uygulamadan sonra kuru koşu `dry run: 0 change(s) pending` demelidir.
4. Uzlaştırıcı bir kez daha koşar; `client core-erasure: verified` ve üç
   `erase scope ...: verified` satırı beklenir.
5. Geçici yönetici kaldırılır. core değişkenleri bir sonraki deploy'unda alır;
   `ACCOUNT_ERASURE_WORKER_ENABLED=false` iken okumaz bile.

Geri dönüş: istemci, kapsamlar ve roller başka hiçbir istemcinin token'ını
değiştirmez (entegrasyon testi core'un SkyMail gönderim token'ının ve Admin REST
erişiminin aynı kaldığını doğrular). Gerekirse Admin Console'dan `core-erasure`
istemcisi, üç `account-erase-*` kapsamı ve üç erase rolü silinir; core'un
ortamındaki iki satır ve OpenBao'daki yol kaldırılır. Uzlaştırıcı istemci yokken
yalnız uyarır.

## 12. inscribed: site istemcilerinde roller ve düz `roles` claim'i (ADR-0056)

CMS, Fatih'in inscribed'ına geçer. inscribed External modda token'ı `aud=skycms` ile
doğrular, kiracıyı `azp`'den, yetkileri **tek, sabit, düz** bir claim'den okur:
`roles`. Eski CMS `cms:access`'i `resource_access[azp].roles`'tan okuyordu; bu yol
istemciye göre değiştiği için inscribed onu okuyamaz. inscribed'ın yetenekleri
`content:read`, `content:write`, `schema:sync` ve `client:admin`'dir. Koleksiyon
kuralları `groups`'u (tam yol) okur.

`config/inscribed-cms-roles.sh` imajın içindedir ve §8'deki betiklerin düzenindedir:
varsayılanı `--check`'tir (durumu, planı ve raporu basar, hiçbir şey yazmaz), `--apply`
yazar, ikinci koşu hiçbir şey yazmaz ve hiçbir admin olayı üretmez; yönetici parolası
kcadm'ın kendi prompt'una yazılır ya da `--kcadm-config <dosya>` ile oturum açmış bir
kcadm yapılandırması yeniden kullanılır (betik o zaman giriş yapmaz, dosyayı silmez).

**Betik rol ve bileşik rol yaratır, claim'leri kurar; hiçbir gruba ya da kişiye rol
vermez.** Grup → istemci rolü eşlemeleri SKY LAB admin panelinden yapılır (Gruplar →
client rolleri; CONTEXT.md "Client role"), Keycloak konsolundan ya da betikle değil.
Betiğin verdiği tek roller istemcilerin kendi service account'larınadır.

Varsayılan istemciler `frontend-main`, `frontend-arge` ve admin panelinin istemcisidir
(`e-skylab`'da `admin`, `e-skylab-sandbox`'ta `superadmin`); `--client` ile
değiştirilebilir. Realm'de olmayan istemci `NOTE` ile atlanır. Her istemci için sırası:

1. `content:read`, `content:write`, `schema:sync` istemci rollerini oluşturur (yoksa).
   Site editörlerinde (`frontend-main`, `frontend-arge`) ayrıca:
   - `cms:access`: sitelerin editör arayüzü buna bakar
     (`@skylab-kulubu/inscribed-auth` 0.3.1, access token'ın `resource_access`'indeki
     herhangi bir istemcide `cms:access`). `frontend-arge` `fullScopeAllowed=false`
     olduğundan arge token'ı yalnız arge'nin rollerini taşır; her site kendi
     `cms:access`'ini ister.
   - `client:admin`: inscribed'da (2.0.1) koleksiyonlarda her `ClaimDerived` kaydı
     düzenleme ve yeni kayıt açma (yeni takım, ayrılan liderin takım sayfası), bir de
     yalnız o tenant'ın ayarları (`GET`/`PUT /admin/clients/<istemci>`: `isActive`,
     `allowAnonymousContentRead`). External modda üyelik ve servis anahtarı uçları yok.
     Koleksiyon yazma rotası yine `content:write` ister. `email` claim'i olmayan
     (makine) token'la `/admin/*` açılmaz.
2. İstemcinin `cms:access`'ini aynı istemcinin `content:read` ve `content:write`'ını
   içeren bileşik rol yapar: `cms:access` alan grup ikisini de `roles`'ta taşır. Site
   editörü olmayan istemcide (`admin`) `cms:access` yaratılmaz; varsa eskisi gibi
   bileşik yapılır.
3. `inscribed-roles` mapper'ını ekler (`oidc-usermodel-client-role-mapper`,
   `usermodel.clientRoleMapping.clientId=<istemcinin kendisi>`, `claim.name=roles`,
   çok değerli, yalnız access token ve introspection; ID token ve userinfo'da yok).
   Keycloak bileşik rolleri açar; `fullScopeAllowed=false` olan istemcide de
   istemcinin kendi rolleri token'a girer (harness'te kanıtlı). İstemcide ya da
   varsayılan kapsamlarından birinde access token'a `roles` yazan başka bir mapper
   varsa `PROBLEM` yazar, mapper'ı eklemez, o mapper'a dokunmaz ve 1 ile çıkar.
4. Access token'a tam yollu `groups` yazan bir Group Membership mapper'ı (istemcide ya
   da varsayılan kapsamlarında, örneğin realm'in `groups` kapsamı) varsa bir şey yapmaz;
   yoksa `inscribed-groups` mapper'ını ekler (tam yol, yalnız access token ve
   introspection). `groups`'u tam yolsuz ya da başka biçimde yazan bir mapper varsa
   `PROBLEM` yazar ve dokunmaz (başka tüketiciler o biçimi okuyor olabilir).
5. Service account'u olan istemcide service account'a `content:read` ve
   `schema:sync` verir (siteler sunucu tarafında içerik okur ve `cms-sync` ile
   koleksiyon şemalarını gönderir). Service account açmaz. `frontend-main`'in service
   account'u bugün `cms:access` da taşır, yani bileşik rol üzerinden `content:write`:
   eski CMS siteyi bu yetkiyle okur. Betik bunu yalnız `--post-cutover` ile alır
   (aşağıda); varsayılan koşu ona dokunmaz.
6. Rapor (salt okuma): istemcide `cms:access`, `content:read`, `content:write`,
   `schema:sync`, `client:admin`'i hangi grupların taşıdığını, doğrudan ya da bir
   bileşik rol (istemcinin kendi ya da bir realm rolü) üzerinden listeler; bir grubun
   rolü alt gruplarına da geçer. Satır biçimi:
   `frontend-main:   content:write <- group(s): /ADMIN (via cms:access), …`. Rolün bir
   kişiye doğrudan verilmesi (service account'lar hariç) `WARNING`'dir: CMS rolleri
   yalnız gruplara verilir. Bir CMS rolü realm'in varsayılan rollerindeyse ya da bir
   varsayılan gruba ulaşıyorsa `PROBLEM`'dir (her yeni kullanıcı alır). Başka
   istemcilerin bileşik rolleri izlenmez.

Eski CMS etkilenmez: cms-backend `resource_access[azp].roles`'u `roles` claim'lerine
kopyalar ve yalnız `cms:access`'e bakar; düz `roles` claim'i ona aynı değerlerin bir
kopyasını ekler. core, forms-backend, skymail-backend, account-center, core-frontend
ve siteler düz `roles`'u okumaz (2026-09-27 taraması, origin/main).

Uzlaştırıcı bu kalemleri doğrulamaz (service account'a rol atamak kullanıcı yetkisi
ister, §6). Realm yeniden kurulursa betik yeniden koşulur.

### Admin panelinden verilecek roller (Yusuf, 2026-09-28)

| İstemci | Rol | Gruplar |
|---|---|---|
| `frontend-main` | `cms:access` | `/ADMIN`, `/UYELER/YK`, `/UYELER/DK`, her `…/LIDERLER` ve `…/KOORDINATORLER` |
| `frontend-main` | `client:admin` | `/ADMIN`, `/UYELER/YK` |
| `frontend-arge` | `cms:access` | `/ADMIN`, `/UYELER/YK`, her `…/LIDERLER` ve `…/KOORDINATORLER` |
| `frontend-arge` | `client:admin` | `/ADMIN`, `/UYELER/YK` |
| `admin` | `content:read`, `content:write` | `/ADMIN`, `/UYELER/YK`, `/UYELER/DK` |

- Hiçbir CMS rolü `/UYELER`'e, bir kişiye, varsayılan rollere ya da varsayılan gruplara
  verilmez. `client:admin` liderlere verilmez.
- Bilinen sınır: inscribed'da `content:write` tenant geneli. `frontend-main`'de
  `cms:access` alan lider ana sitenin bütün sayfa bloklarını da düzenleyebilir. Fatih
  yalnız koleksiyona yazma yeteneğini getirene kadar kabul edildi. Hangi takımı
  düzenleyeceğini `teams` koleksiyonunun `ClaimDerived` kuralı sınırlar.
- Yeni takım açılınca `LIDERLER` ve `KOORDINATORLER` gruplarına iki sitede de
  `cms:access` verilir.

### Geçiş gecesi: `--post-cutover`

`--post-cutover`, `cms:access`'i service account'lardan alır (üretimde yalnız
`frontend-main`'inki); service account'ta `content:read` + `schema:sync` kalır ve betik
bunu etkin rollerden doğrular (`holds exactly: content:read schema:sync`). Varsayılan
koşuda hiç çalışmaz. **Yalnız geçiş gecesi, inscribed `/api/cms`'i devraldıktan sonra**
koşulur: eski CMS SSR okumalarını bu yetkiyle yapar, önce alınırsa ana site içeriksiz
kalır. sky_lab_genel'deki `ops/wizards/inscribed-keycloak-roles-wizard.sh --post-cutover`
bunu yazılı onayla koşar, sonra gerçek service account token'ıyla
`https://api.yildizskylab.com/api/cms/content?slug=/`'yi okur (200 beklenir) ve okuyamazsa
`cms:access`'i geri vermeyi önerir. Elle geri dönüş: Admin Console → Clients →
`frontend-main` → Service account roles → `cms:access`.

### Üretim sırası

1. sky_lab_genel'deki `ops/wizards/inscribed-keycloak-roles-wizard.sh` sunucuda koşar
   (kopyalama komutları başında): konteyneri bulur; imajdaki betik wizard'ın bildiği
   sürümse onu, değilse yanındaki kopyayı sha256'sını denetleyip konteynerin
   `/tmp`'sine koyar; master yöneticisiyle kcadm girişi; `--check`; plan; onay;
   `--apply`; yeniden `--check` ve rapor; `frontend-arge-core-audience`'ı (§0.1)
   uzlaştırıcının biçimiyle kurar; admin panelinde yapılacak eşlemelerin listesi
   (realm'deki lider ve koordinatör gruplarıyla, raporda olanlar ✓); Evaluate ile
   örnek token'lar ve istenirse `frontend-main` service account'uyla gerçek bir
   `client_credentials` token'ı (secret belleğe okunur, basılmaz).
2. Elle koşmak gerekirse:

   ```bash
   kc=$(docker ps -q -f name=sky-lab-production-keycloak | head -n 1)
   docker exec -it -e KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080 -e KEYCLOAK_REALM=e-skylab "$kc" \
     /opt/keycloak/config/inscribed-cms-roles.sh --admin-user <yönetici>            # --check
   docker exec -it -e KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080 -e KEYCLOAK_REALM=e-skylab "$kc" \
     /opt/keycloak/config/inscribed-cms-roles.sh --admin-user <yönetici> --apply
   ```

   Hiç kurulmamış, 2026-09-28 öncesi olgularla (`frontend-main`'de yalnız `cms:access`,
   onu yalnız service account'u taşır; `frontend-arge` ve `admin`'de rol yok) beklenen:
   `check: 24 change(s) pending`. 2026-09-27'deki uygulamadan sonraki production'da
   beklenen: `frontend-main`'e `client:admin`; `frontend-arge`'a `cms:access`, iki
   `would make …/cms:access include …` ve `client:admin`; yani `check: 5 change(s)
   pending`. Uygulamadan sonra `check: 0 change(s) pending`; uyarı yalnız bir kişiye
   doğrudan verilmiş CMS rolü varsa çıkar.
3. Admin panelinde yukarıdaki tablo uygulanır; `--check`'in raporu grupları listeler.
4. inscribed'ın ortamı: `Auth__Mode=External`,
   `Auth__Authority=https://e.yildizskylab.com/realms/e-skylab`,
   `Auth__Audience=skycms`, `Auth__TenantClaim=azp`, `Auth__RolesClaim=roles`.
5. Geçiş gecesi, inscribed `/api/cms`'i devraldıktan sonra: `--post-cutover`.

Harness: `tests/inscribed-cms-roles.sh` (tek başına; Dockerfile'daki Keycloak imajını
`docker run --rm` ile dev modunda açar, sonda `docker rm -fv`) `--check`'in yazmadığını,
planı, `--apply`'ın gruplara ve kişilere hiçbir rol vermediğini (admin olayları:
yalnız iki service account), yazmayan ikinci koşuyu, admin panelinin yaptığı gibi
gruplara verilen rollerle raporu ve gerçek access token'ları doğrular: `/UYELER/YK`
alt grubundaki bir YK üyesi `frontend-main` ve `frontend-arge`'da `roles` =
{`client:admin`, `cms:access`, `content:read`, `content:write`}, `admin`'de
{`content:read`, `content:write`}; bir lider iki sitede {`cms:access`, `content:read`,
`content:write`}, `client:admin` yok; sıradan üye hiçbirini almaz; editör kapısı
(`resource_access`'te `cms:access`) liderde ve YK'da açık, üyede kapalı; ID token ve
userinfo'da `roles` yok. Ayrıca doğrudan kişi atamasında `WARNING`'i, varsayılan rol ve
varsayılan grupta `PROBLEM`'i, `--post-cutover`'dan sonra `frontend-main` service
account token'ında tam olarak `content:read` + `schema:sync`'i, kayma onarımını,
yabancı bir `roles` ya da düz `groups` mapper'ında `PROBLEM`'i,
`frontend-arge-core-audience` ile arge token'ının `aud`'unda `core` ve `skycms`'i ve
`e-skylab-sandbox`'ta `superadmin`'in yalnız yetenek rollerini aldığını, eksik site
istemcilerinin `NOTE` ile atlandığını doğrular.

## 13. Sandbox realm'inde site istemcisi: `frontend-arge`

`e-skylab-sandbox`'ta site istemcisi yoktu. `https://sandbox-arge.yildizskylab.com`
girişsiz çalışıyor, arge'nin editörü sandbox'ta denenemiyordu. Production'daki
`frontend-arge` elle kurulmuştu ve uzlaştırıcı onu yönetmez (§0.1 yalnız audience
kapsamını yönetir). Sandbox'takini `config/sandbox-site-clients.sh` kurar. Betik §12'deki
betiklerin düzenindedir: varsayılanı `--check`'tir, `--apply` yazar, ikinci koşu hiçbir
şey yazmaz. Yönetici parolası kcadm'ın kendi prompt'una yazılır ya da `--kcadm-config`
kullanılır.

**Yalnız `e-skylab-sandbox`.** `KEYCLOAK_REALM` başka bir şeyse (`e-skylab` dahil) betik
girişten önce `refusing realm …` yazar ve 2 ile çıkar. Realm ya da `skycms` istemcisi
yoksa 1 ile çıkar ve hiçbir şey yazmaz.

Kurduğu istemci `frontend-arge`, production'dakinin biçimindedir:

- gizli (`client-secret`; secret'ı Keycloak üretir, hiçbir betik basmaz);
- standard flow açık: NextAuth'un Keycloak sağlayıcısı, dönüş adresi
  `/api/auth/callback/keycloak`;
- implicit ve direct grant kapalı;
- service account açık: site içeriği sunucu tarafında okur ve `cms-sync` ile koleksiyon
  şemalarını gönderir;
- `fullScopeAllowed=false` (uzlaştırıcı production'dakini de daraltır, §21; sitenin CMS rolleri
  kendi istemci rolleridir ve token'a her zaman girer);
- redirect `https://sandbox-arge.yildizskylab.com/*`, web origin
  `https://sandbox-arge.yildizskylab.com`, post-logout `https://sandbox-arge.yildizskylab.com/*`.
  İstemcide başka adres varsa korunur ve `NOTE` ile listelenir (örneğin bir geliştiricinin
  `localhost`'u).

Access token'a şunlar girer:

1. `aud` içinde `skycms` (inscribed denetler). İstemcide ya da varsayılan kapsamlarından
   birinde bunu yapan bir audience mapper'ı varsa yeterlidir. Yoksa istemci mapper'ı
   `skycms-audience` eklenir: access token ve introspection'a yazar, ID token'a yazmaz.
2. Realm'de `core` istemcisi varsa `aud` içinde `core`. arge'nin CMS yüklemeleri editörün
   token'ıyla core `POST /v1/media`'ya gider. Kapsam `frontend-arge-core-audience`,
   uzlaştırıcının production'da kurduğu biçimin aynısıdır
   (`config/frontend-arge-core-audience-mappers.json`, §0.1; harness karşılaştırır). İstemcinin
   varsayılan kapsamı yapılır. `core` yoksa `NOTE` yazılır ve bu kalem atlanır.
3. Tam yollu `groups`: inscribed'ın koleksiyonları okur. İstemcide ya da varsayılan
   kapsamlarında tam yollu bir Group Membership mapper'ı varsa yeterlidir. Yoksa realm'in
   `groups` kapsamı varsayılan kapsam yapılır; bu, production'daki biçimdir ve yalnız kapsam
   sadece tam yollu Group Membership mapper'ları taşıyorsa yapılır. O da yoksa istemci mapper'ı
   `groups` eklenir. `groups`'u başka biçimde (düz adlarla) yazan bir mapper `PROBLEM`'dir;
   dokunulmaz.

`frontend-main` kurulmaz: bugün sandbox'ta ana site uygulaması yok. Olunca aynı betiğe eklenir.

CMS rolleri, düz `roles` claim'i ve service account'un `content:read` + `schema:sync`'i bu
betiğin işi değil. Ardından §12'deki betik koşar:
`KEYCLOAK_REALM=e-skylab-sandbox inscribed-cms-roles.sh --client frontend-arge`. O betik bu
betiğin kurduğu tam yollu `groups`'u bulur, ikinci bir groups mapper'ı eklemez. Hiçbir betik
bir gruba ya da kişiye rol vermez. Sandbox'ta editör yetkisi (`frontend-arge` · `cms:access`)
sandbox admin panelinden bir gruba verilir; wizard isterse tek bir gruba kendisi verir.

`fullScopeAllowed` notu: production olguları 2026-09-28'de `true` olarak iletildi. #47'nin
açıklaması ve §12'nin harness'i ise production `frontend-arge`'ı `false` diye anlatıyor. Site
iki durumda da çalışır: CMS rolleri istemcinin kendi rolleridir ve token her zaman
istemcinin kendi rollerini taşır. Production'daki değer
`kcadm get clients -r e-skylab -q clientId=frontend-arge --fields fullScopeAllowed` ile
görülür. Farklıysa betikteki `FLAG_*` satırları değiştirilir.

### Sandbox sırası

1. sky_lab_genel'deki `ops/wizards/sandbox-arge-keycloak-wizard.sh` sunucuda koşar
   (kopyalama komutları başında):
   - Keycloak konteynerini bulur. Bu betiğin ve `inscribed-cms-roles.sh`'ın sha256'larını
     denetleyip onları konteynerin `/tmp`'sine koyar.
   - kcadm girişi yapar.
   - Bu betiği sırayla koşar: `--check`, plan, onay, `--apply`, yeniden `--check`.
   - Rol betiğini `frontend-arge` için aynı sırayla koşar.
   - İsteğe bağlı olarak tek bir gruba `cms:access` verir.
   - Evaluate ile örnek token'lara bakar ve giriş sayfasını dener.
   - İstenirse service account'la gerçek bir `client_credentials` token'ı alır. Secret
     belleğe okunur, basılmaz.
2. Elle koşmak gerekirse:

   ```bash
   kc=$(docker ps -q -f name=sky-lab-production-keycloak | head -n 1)
   docker exec -it -e KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080 -e KEYCLOAK_REALM=e-skylab-sandbox "$kc" \
     /opt/keycloak/config/sandbox-site-clients.sh --admin-user <yönetici>            # --check
   docker exec -it -e KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080 -e KEYCLOAK_REALM=e-skylab-sandbox "$kc" \
     /opt/keycloak/config/sandbox-site-clients.sh --admin-user <yönetici> --apply
   ```

   Hiç kurulmamış bir sandbox'ta, realm'de `core` varken beklenen: `check: 6 change(s)
   pending`. Bunlar istemci, `skycms-audience`, kapsam, mapper'ı, kapsam bağlantısı ve
   `groups`'tur. `core` yoksa `check: 3 change(s) pending` ve bir `NOTE` beklenir.
   Uygulamadan sonra beklenen: `check: 0 change(s) pending`.
3. Mac'te `ops/wizards/arge-dokploy-wizard.sh --sandbox-kc` koşar:
   - secret'ı sunucuda kcadm'le okur, doğrudan
     `kv/sandbox/<sandbox arge appName>/KEYCLOAK_CLIENT_SECRET`'a yazar;
   - sandbox arge'nin Dokploy ortamına `KEYCLOAK_CLIENT_SECRET` referansını ekler;
   - deploy eder ve girişi dener.

Geri dönüş: Admin Console → `e-skylab-sandbox` → Clients → `frontend-arge` silinir. Client
scopes → `frontend-arge-core-audience` da silinir; başka istemci onu kullanmaz. Sandbox arge
yeniden girişsiz çalışır. Dokploy ortamındaki `KEYCLOAK_CLIENT_SECRET` satırı ve OpenBao'daki
yol kaldırılır. Production'a hiçbir adımda dokunulmaz.

Harness: `tests/sandbox-site-clients.sh` tek başına çalışır. Dockerfile'daki Keycloak imajını
`docker run --rm` ile dev modunda açar; sonda `docker rm -fv`. Şunları doğrular:

- `e-skylab`, `master` ve başka bir realm girişten önce reddedilir.
- `skycms` yokken hiçbir şey yazılmaz.
- `--check` yazmaz (admin olayları).
- `--apply` yalnız planı yazar ve kimseye rol vermez. İstemcinin bayrakları ve adresleri
  beklenen biçimdedir; `core-audience` mapper'ı uzlaştırıcının JSON'uyla aynıdır.
- İkinci koşu yazmaz.
- Rol betiği sonradan ikinci bir groups mapper'ı eklemez.
- Gerçek authorization code akışı çalışır: giriş sayfası, dönüş adresine `code`, secret ile
  takas. Bir `/UYELER/ADMIN` editörünün access token'ında `aud` ⊇ {`skycms`, `core`},
  `groups` = [`/UYELER/ADMIN`], `roles` ⊇ {`cms:access`, `content:read`, `content:write`}
  bulunur; ID token'da rol, grup ve API audience'ı yoktur.
- Sıradan üye CMS rolü almaz.
- Production'ın dönüş adresi reddedilir (400).
- Service account token'ında `content:read` + `schema:sync` bulunur.
- Kaymalar onarılır; geliştiricinin ek adresi korunur.
- Düz `groups` bir `PROBLEM`'dir.
- Realm'in `groups` kapsamı varken o kapsam bağlanır.
- `core` yokken `NOTE` yazılır.
- Hiçbir çıktıda secret görünmez.

## 14. Place: `place` istemcisi, roller ve `school_email` claim'i (ADR-0060)

Place'in backend'i (`api.place.yildizskylab.com`) e-skylab girişini kendisi yürütür: realm
`e-skylab`'ın gizli istemcisi `place`'tir (BFF; Authorization Code + PKCE). Keycloak token'ları
tarayıcıya gitmez, Place kendi oturum cookie'sini verir (ADR-0058'in yönü). İstemciyi
`config/create-place-client.sh` kurar. Betik §13'teki betiğin düzenindedir: varsayılanı
`--check`'tir, `--apply` yazar, ikinci koşu hiçbir şey yazmaz. Yönetici parolası kcadm'ın
kendi prompt'una yazılır ya da `--kcadm-config` kullanılır. Uzlaştırıcı bu istemciyi
yönetmez ve doğrulamaz; imaj yayını gerekmez, betik çalışan konteynerde koşar.

**Yalnız `e-skylab`.** Place'in sandbox'ı yok. `KEYCLOAK_REALM` başka bir şeyse betik girişten
önce `refusing realm …` yazar ve 2 ile çıkar. Realm yoksa 1 ile çıkar ve hiçbir şey yazmaz.

Kurduğu istemci `place`:

- gizli (`client-secret`; secret'ı Keycloak üretir, betik basmaz);
- yalnız standard flow: implicit, direct grant, service account, device grant, CIBA ve
  standard token exchange kapalı; PKCE `S256` zorunlu;
- `fullScopeAllowed=false`: token yalnız Place'in kendi rollerini taşır, `realm_access` ve başka
  istemcilerin rolleri gelmez (tam kapsam açık olsaydı `realm-management` rolü olan bir
  yetkilinin token'ı Admin REST'te de geçerli olurdu, §0'daki `account-center` notu);
- consent ve front-channel logout kapalı (Place'ten çıkış e-skylab oturumunu kapatmaz);
- dönüş adresi tam olarak `https://api.place.yildizskylab.com/api/auth/eskylab/callback`; web
  origin yok (tarayıcı Keycloak'ın uçlarını çağırmaz). İstemcide başka adres varsa silinir ve
  satırda listelenir.

Roller: `place:admin` ve `place:moderator` (ADR-0059: uygulama geneli izin client rolüdür).
Betik hiçbir kişiye ya da gruba rol vermez; roller SKY LAB admin panelinin "Rol ekle"sinden
verilir (core'un rol kataloğu bütün istemcilerin rollerini listeler). Betik rolleri kimin
taşıdığını raporlar: doğrudan taşıyan kişi sayısı ve grup yolları.

Token'a girenler (ID token, access token, userinfo ve introspection):

1. `school_email`: istemci mapper'ı `school-email`, `schoolEmail` özniteliğinden (User Profile'da
   §0'daki biçimde). Place hesabı bununla eşler; kişinin birincil adresi (`email`, kişisel
   olabilir, ADR-0044) eşlemede kullanılmaz. Öznitelik yoksa claim de yoktur ve Place girişi
   reddeder. User Profile `schoolEmail`'i tanımlamıyorsa `WARNING` yazılır.
2. `resource_access.place.roles`: istemci mapper'ı `place-roles`. Realm'in `roles` kapsamı bu
   claim'i yalnız access token'a yazar; Place ID token'ı doğruladığı için ID token'a ve userinfo'ya
   da bu mapper yazar.

Grup yok (ADR-0059: Place grup okumaz). Keycloak yeni istemciye realm'in varsayılan ve isteğe
bağlı kapsamlarını bağlar. Bunlardan grup verisi yazan (Group Membership mapper'ı ya da claim'i
`groups` olan herhangi bir mapper; Keycloak'ın `microprofile-jwt`'si realm rollerini `groups`
adıyla yazar) `place`'ten ayrılır. Ayrılan kapsam istenirse Keycloak isteği `invalid_scope` ile
reddeder.

`school_email`'in tek kaynağı `school-email` mapper'ıdır. Bu claim'i yazan varsayılan ya da
isteğe bağlı kapsam da (claim adına bakılır) `place`'ten ayrılır. Production'da realm'in
varsayılan `profile` kapsamında elle eklenmiş bir `school_email` mapper'ı var ve core claim'i
oradan okur; bu yüzden `profile` `place`'ten ayrılır. Yalnız istemcinin kapsam bağı silinir:
realm kapsamı, mapper'ları, realm'in varsayılan kapsamları ve öteki istemciler değişmez. Place
`profile`'dan bir şey okumaz (yalnız `school_email`, `resource_access.place.roles`, `sub` ve ID
token'ın standart alanları; yalnız `openid` kapsamını ister). Ayrılmış kapsam ikinci koşuda
değişiklik üretmez.

İstemcinin kendi üzerinde grup yazan bir mapper, `school_email` yazan ikinci bir mapper ya da
`school-email`/`place-roles` adında başka türde bir mapper `PROBLEM`'dir; dokunulmaz.

### Üretim sırası

1. e-skylab-keycloak PR'ı `main`'e birleşir. İmaj yayını gerekmez.
2. sky_lab_genel'deki `ops/wizards/place-keycloak-client-wizard.sh` sunucuda koşar
   (kopyalama komutları başında):
   - Keycloak konteynerini bulur, realm'i ve istemcinin durumunu okur. Betiğin sha256'sını
     wizard'daki sabitle karşılaştırır, betiği konteynerin `/tmp`'sine koyar.
   - kcadm girişi yapar. Betiği sırayla koşar: `--check`, plan, onay, `--apply`, yeniden `--check`.
   - Secret'ı konteynerde kcadm ile okur ve borudan doğrudan OpenBao'ya yazar:
     `kv/etkinlik/<Place appName>/KEYCLOAK_CLIENT_SECRET` (`cas=0`). Değer ekrana, dosyaya ya da bir
     komut satırına girmez. OpenBao'daki değerin sha256'sını Keycloak'takiyle karşılaştırır.
   - Place backend'inin ortamına girecek sır olmayan değerleri basar: issuer, client id, dönüş
     adresi ve secret'ın OpenBao referansı. Ortama yazmak Place'in yayın biletinin işidir.
3. Elle koşmak gerekirse:

   ```bash
   kc=$(docker ps -q -f name=sky-lab-production-keycloak | head -n 1)
   docker exec -i "$kc" sh -c 'cat > /tmp/create-place-client.sh' < create-place-client.sh
   docker exec -it -e KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080 "$kc" \
     bash /tmp/create-place-client.sh --admin-user <yönetici>            # --check
   docker exec -it -e KEYCLOAK_ADMIN_URL=http://127.0.0.1:8080 "$kc" \
     bash /tmp/create-place-client.sh --admin-user <yönetici> --apply
   ```

   İlk koşuda beklenen en az `check: 5 change(s) pending` (istemci, iki rol, iki mapper) ve realm'in
   grup ya da `school_email` yazan her varsayılan ya da isteğe bağlı kapsamı için bir `detach`
   (Keycloak'ın varsayılanlarında `microprofile-jwt`; production'da `profile` de). Uygulamadan
   sonra: `check: 0 change(s) pending`.

Geri dönüş: Admin Console → `e-skylab` → Clients → `place` silinir (rolleri ve mapper'ları
birlikte gider; realm kapsamlarına dokunulmamıştır). OpenBao'daki yol kaldırılır. Place
backend'i `mail` modunda e-skylab'ı kullanmaz.

Harness: `tests/place-client.sh` tek başına çalışır. Dockerfile'daki Keycloak imajını
`docker run --rm` ile dev modunda açar; sonda `docker rm -fv`. Fixture realm'inde `groups`
kapsamı realm'in varsayılan kapsamıdır (en kötü durum); realm'in varsayılan `profile` kapsamında,
production'daki gibi, `schoolEmail`'den `school_email` yazan bir mapper vardır. Şunları doğrular:

- `e-skylab` dışındaki realm'ler girişten önce reddedilir; realm yokken hiçbir şey yazılmaz.
- `--check` yazmaz (admin olayları); `--apply` yalnız planı yazar ve kimseye rol vermez. İstemcinin
  bayrakları, PKCE'si, adresleri, rolleri, mapper'ları ve kapsamları beklenen biçimdedir.
- `profile` yalnız `place`'ten ayrılır: koşunun her admin olayı `place` üzerindedir; realm
  kapsamının mapper'ları, realm'in varsayılan kapsamları ve `core`'un `profile`'ı yerindedir.
- İkinci koşu yazmaz.
- Admin panelinin yaptığı gibi bir kişiye `place:moderator`, bir gruba `place:admin` verilince
  gerçek authorization code akışı (PKCE S256, state, nonce, giriş sayfası, dönüş adresine
  `code`, secret ve verifier ile takas) çalışır. ID token'da (aud `place`, nonce), access token'da
  ve userinfo'da `school_email` (okul adresi; `email` kişisel adres olarak kalır) ve
  `resource_access.place.roles` bulunur; `groups`, `realm_access` ve başka istemcinin rolü
  (kişinin `core` rolü) bulunmaz. Grupla verilen rol gelir; okul adresi olmayan kişide
  `school_email` ve rol yoktur. Place token'larında `profile`'ın claim'leri (`preferred_username`,
  `given_name` …) yoktur, yani `school_email` istemcinin kendi mapper'ından gelir; `core`'un
  token'ında (Evaluate) `profile`'ın claim'leri ve `school_email` durur.
- `groups`, `microprofile-jwt` ve `profile` kapsamları `invalid_scope` ile, PKCE'siz ve `plain` istek,
  `response_type=token`, yabancı dönüş adresi (400), password ve client_credentials grant'leri
  reddedilir.
- Kaymalar onarılır (bayraklar, PKCE, adresler, web origin, iki mapper, grup yazan iki kapsam,
  isteğe bağlı kapsam olarak geri bağlanan `profile`).
- Grup yazan bir istemci mapper'ı ve ikinci bir `school_email` mapper'ı `PROBLEM`'dir; dokunulmaz.
- User Profile `schoolEmail`'i tanımlamıyorsa `WARNING` yazılır.
- Hiçbir çıktıda secret görünmez.

## 15. Okul ya da kişisel e-postayla parolalı giriş (K4)

Parolalı girişte kullanıcı adı alanı artık dört şeyden birini alır: kullanıcı adı, birincil
e-posta (Keycloak `email`), YTÜ bağlantılı hesabın okul e-postası ya da kanıtlanmış kişisel
e-posta (CONTEXT.md, Primary e-mail: "Either address signs in"). Bunu SPI 1.14.0'daki
`sky-username-password-form` (`com.skylab.authenticator.SkyUsernamePasswordFormFactory`) yapar.
Uzlaştırıcı onu realm tarayıcı akışına koyar.

### Hangi adres giriş tanımlayıcısıdır

- `schoolEmail`: yalnız hesabın YTÜ Microsoft bağlantısı (`OBS`) varken. Değeri OBS'nin
  `school-email-importer` mapper'ı (Keycloak'ın `microsoft-user-attribute-mapper`'ı, FORCE)
  her YTÜ girişinde Microsoft'un verdiği gibi yazar: kırpılır, küçük harfe çevrilmez,
  benzersizlik denetlenmez. Bağlantısız bir hesapta içe aktarılmış ya da yönetici yazmış bir
  değer kanıt sayılmaz (Verified YTÜ account).
- `personalEmail`: yalnız `personalEmailVerifiedAt` damgası okunabilir bir ISO-8601 anken
  (`IdentityResource.isPersonalEmailVerified`, SPI'ın birincil seçiminde kullandığı kural).
  Değeri yalnız `email/confirm` (kod doğru girildikten sonra) ve A1c devralması yazar, ikisi de
  `PersonalEmailProof` ile: kırpılmış, `Locale.ROOT` ile küçük harf. Bekleyen değişiklik
  özniteliğe hiç girmez; tek kullanımlık depoda kodunu bekler. Benzersizlik yazılırken
  denetlenir: `change-request` ve `confirm` adresi başka birinin `email`, `schoolEmail` ya da
  `personalEmail`'inde bulursa `email_taken` döner.
- `email` ve kullanıcı adı: Keycloak'ın kendi araması (`KeycloakModelUtils.findUserByNameOrEmail`),
  büyük/küçük harf duyarsız. Realm `duplicateEmailsAllowed=false`, `loginWithEmailAllowed=true`
  (uzlaştırıcı bunu doğrular), `registrationEmailAsUsername=false` (üretim olgusu, 2026-09-21;
  uzlaştırıcı yönetmez).

İki öznitelik de büyük/küçük harf duyarsız karşılaştırılır (Keycloak'ın tam öznitelik araması
iki yanı da küçültür, sonra değer SPI'da bir kez daha denetlenir). `loginWithEmailAllowed`
kapalıysa ya da girdide `@` yoksa yalnız kullanıcı adı aranır.

### Belirsizlik ve hata cevabı

Her yol her girişte sorulur. Girdi iki farklı kişiyi gösteriyorsa (örneğin birinin `email`'i,
ötekinin okul e-postası) kimse seçilmez ve cevap, bilinmeyen bir kullanıcı adınınkiyle aynıdır:
Keycloak'ın `testInvalidUser`'ı, yani sabit süreli sahte parola özeti, `user_not_found` olayı
ve yanlış parolayla aynı "Geçersiz kullanıcı adı veya şifre" mesajı. Kanıtlanmamış bir adres de
hiç kimseyi göstermez; cevabı yazım hatasınınkidir. Kullanıcı adı `@` içeren eski bir hesap o
adresi taşıyan başka birine çözülüyorsa kişi aynı cevabı alır.

### Keycloak'ın davranışı nasıl korunuyor

`SkyUsernamePasswordForm`, Keycloak'ın `UsernamePasswordForm`'unu genişletir ve yalnız
`validateForm`'u değiştirir. Keycloak'ın kendi aramasının bulduğu girdi, hiç kimseyi göstermeyen
girdi ve formdan önce kişisi belli olan akış Keycloak'ın koduna hiç değiştirilmeden gider. Yalnız
okul ya da kişisel e-postayla bulunan kişi için Keycloak'ın formu o kişinin kullanıcı adıyla
çalışır. Parola denetimi, brute force, devre dışı hesap, zorunlu eylemler, hata mesajları ve
passkey (conditional UI) yolu Keycloak'ındır. İki ayrıntı:

- Keycloak brute force için kişiyi `ATTEMPTED_USERNAME` notundan bulur; giriş ve parola
  sıfırlama sayfaları da bu notu geri gösterir. Not, form çalıştıktan sonra yazılan adrese
  geri çevrilir; bir adres kimsenin kullanıcı adını açığa vurmaz. Not artık kişiye çözülmediği
  için yanlış parola burada Keycloak'ın akışının yaptığı çağrıyla (`BruteForceProtector
  .failedLogin`, bu yürütmenin `password` kategorisiyle) bir kez sayılır.
- Hata olayı (`LOGIN_ERROR`, `invalid_user_credentials`) adresle girişte `username` ayrıntısı
  olarak kullanıcı adını taşır; başarılı giriş olayı ve oturum yazılan adresi taşır.

Belirsiz bir girdi, Keycloak'ın her girdide yaptığı gibi, kendi aramasının bulduğu kişiye
(varsa, `email`'in ya da kullanıcı adının sahibi) brute-force hatası yazar; okul ya da kişisel
e-posta sahibine yazmaz.

### Uzlaştırıcı

`reconcile_password_form 'browser plus passkey'`, `account-center-browser` emekliye ayrılıp
silindikten hemen sonra koşar (o akış artık yoktur, değiştirilecek formu da yoktur). Admin REST
bir yürütmenin sağlayıcısını değiştiremediği için yeni form aynı alt akışa aynı öncelikle
eklenir (Keycloak yürütmeleri yalnız önceliğe göre sıralar), sonra eskisi silinir. O kısa anda
akış parolayı iki kez sorar; parolasız bir an hiç olmaz. `ReconcileJson password-form` şu
durumlarda hiçbir şey yazmadan durdurur: iki formdan tam olarak biri yok, form `REQUIRED`
değil, bir authenticator config'i var ya da yanındaki bir yürütme aynı önceliği paylaşıyor.
İki yazma arasında kesilmiş bir koşu iki formu yan yana, aynı öncelikte bırakır; sonraki koşu
eskisini silip tamamlar. Satırlar:

- `[reconcile] password form of flow 'browser plus passkey': updated (auth-username-password-form -> sky-username-password-form in subflow 'password flow', priority 0, REQUIRED)`
- `[reconcile] password form of flow 'browser plus passkey': unchanged (sky-username-password-form)`

Geri dönüş bayrağı `KEYCLOAK_PASSWORD_FORM` (varsayılan `sky-username-password-form`;
`auth-username-password-form` Keycloak'ın formunu aynı yere geri koyar; başka değer koşuyu
durdurur). Geri dönülen akışta adreslerle giriş durur, kullanıcı adı ve birincil e-posta çalışır.
Bayraksız sonraki koşu SKY LAB formunu yeniden koyar.

### Üretim sırası

1. SPI 1.14.0'ı taşıyan Keycloak sürümü yayımlanır (`main` → `production` tek squash,
   `keycloak-production` Touch ID onayı o commit'e bağlanır, `/health/ready` yeşil).
2. Uzlaştırıcı §9'daki `docker exec` komutuyla bir kez koşar. Beklenen tek yeni değişiklik
   satırı yukarıdaki `updated (auth-username-password-form -> sky-username-password-form in
   subflow 'password flow', priority 0, REQUIRED)` satırıdır (üretim olguları: forms →
   passwordless WebAuthn ALT / `password flow` alt akışı, formun önceliği 0, yanında
   `conditional 2fa` 1 ve `Passkey Offer` 2).
3. Aynı komut ikinci kez koşar; hiçbir satır `updated` dememelidir.
4. Admin Console → Authentication → `browser plus passkey`: `password flow` alt akışının ilk
   satırı "SKY LAB Username Password Form" (REQUIRED) olmalıdır.
5. Deneme: okul e-postası birincil olmayan bir hesapla kişisel e-posta, YTÜ bağlantılı bir
   hesapla okul e-postası girişi; bir yazım hatası "Geçersiz kullanıcı adı veya şifre" almalı.

Geri dönüş: aynı `docker exec` komutuna `export KEYCLOAK_PASSWORD_FORM=auth-username-password-form`
eklenip bir kez koşulur (beklenen satır `updated (sky-username-password-form ->
auth-username-password-form ...)`), sonra gerekirse eski imaja dönülür. Sıra önemlidir: eski
imajda `sky-username-password-form` bulunmadığından o akışla parolalı giriş de, Admin Console'da
akışın yürütme listesi de hata verir. Eski imaj zaten çalışıyorsa önce 1.14.0 imajı yeniden
dağıtılır, bayraklı koşu yapılır, sonra geri dönülür.

### Kapsam dışı: parola sıfırlama ve direct grant

Parola sıfırlama aynı aramaya K4b'de geçti (§17). `direct grant` akışı
(`direct-grant-validate-username`; üretimde `admin-cli` ve `skycloud`) değişmedi.

Harness: `tests/login-by-either-email.sh` (`run-integration.sh` içinden). İlk uzlaştırmadan
sonra akışın yalnız formu değişmiş olmalı. Kullanıcı adı, birincil, okul (karışık harfli
kayıt, boşluklu ve büyük harfli girdi) ve kişisel e-postayla giriş doğru `sub`'ı verir. Yazım
hatası, iki kişide olan adres (ikisinin doğru parolasıyla bile), kanıtsız kişisel e-posta ve
bağlantısız okul e-postası yanlış parolayla aynı cevabı alır ve kullanıcı adını hiçbir sayfada
göstermez; parola sıfırlama sayfası yazılan adresi taşır, kullanıcı adını değil. Adresle her
yanlış parola bir kez sayılır, 10. yanlış parola hesabı kilitler, kilit adreslerle de geçerlidir;
devre dışı hesap adresle de kullanıcı adıyla aldığı cevabı alır. Uzlaştırıcı tarafında: geçersiz
bayrak, ikinci form (durur, yazmaz), yarıda kalmış değişim (tamamlar), geri dönüş ve yeniden
ileri, her biri ikinci koşuda sessiz.

## 16. Admin panelinin istemcisi: dar token ve token exchange (ADR-0058)

Admin paneli (`admin.yildizskylab.com`, core-frontend) production'da `admin`, sandbox'ta
`superadmin` istemcisiyle girer. İkisi de elle kurulmuş ve gizlidir (production olguları
2026-09-21: `publicClient=false`, `fullScopeAllowed=true`; sandbox `superadmin`'in secret'ı
2026-09-25'te döndürüldü ve introspection'da 200 aldı, yani gizli). Tam kapsam yüzünden panelin
token'ı kişinin bütün audience ve rollerini taşıyordu: 11 audience, 12 realm rolü, ~3,3 KB.
Uzlaştırıcı (`reconcile_admin_panel_client`) istemciyi adıyla bulur ve yerinde daraltır:

| Ne | Durum |
| --- | --- |
| `admin-panel-api-audience` kapsamı | `config/admin-panel-api-audience-mappers.json`: `core-audience`, `forms-audience`, `skycms-audience` (`oidc-audience-mapper`, access token ve introspection açık, ID token kapalı); başka mapper silinir; istemcinin varsayılan kapsamı, isteğe bağlı listede olmaz (§0.1 düzeni) |
| Rol kapsamı (scope mapping) | `core` ve `forms` istemcilerinin **her** rolü; başka istemcinin rolü ve realm rolü kaldırılır. İstemcinin kendi rolleri (`content:*`, inscribed) Keycloak'ta her zaman geçer. Realm'de `forms` yoksa uyarı yazılır, rolleri istemci oluşunca eklenir |
| İstemci | `fullScopeAllowed=false`, öznitelik `standard.token.exchange.enabled=true`. Başka alana (secret, adresler, bayraklar, istemci mapper'ları) dokunulmaz |

Sonuç: access token'da `aud` tam olarak `core`, `forms`, `skycms`; `realm_access` yok;
`resource_access` yalnız `core`, `forms` ve istemcinin kendisi; `groups`, düz `roles`, `azp`,
`sid` ve profil claim'leri olduğu gibi. Bugünkü panel (token tarayıcıda, üç API'ye aynı token)
çalışmaya devam eder. Keycloak'ın Standard Token Exchange'i (26.2'den beri varsayılan açık özellik)
istemcide açılır: gizli bir istemci kendine kesilmiş token'ı `audience=core` (ya da `forms`,
`skycms`) ile tek audience'lı bir token'a çevirebilir; token'da olmayan bir audience `400
invalid_request` alır. BFF (admin-token-authz 08/09) bunu kullanacak; bugünkü panel kullanmaz.

Adımın sırası canlı paneli bozmaz: önce audience kapsamı ve API rolleri (tam kapsam açıkken
etkisizdir), en son tam kapsamın kapanması. `core` ya da `forms`'ta uzlaştırıcı dışında (Admin
Console, operatör betiği) oluşturulan yeni bir rol panelin token'ına **bir sonraki uzlaştırıcı
koşusunda** girer; o zamana kadar panelde o rolün gerektirdiği iş 403 alır.

Adım uzlaştırıcının en son adımıdır. İstemci realm'de yoksa `WARNING: client <istemci> does not
exist in realm <realm>; skipped the admin panel token contract` yazılır. İstemci **public** ise koşu
ona hiçbir şey yazmadan hata verir (diğer adımlar tamamlanmıştır) (`Client <istemci> is public: …`): token exchange gizli istemci ister ve
istemciyi gizliye çevirmek panelin secret'la girmesini gerektirir (admin-token-authz 07). Önce
panel secret'ını alır, sonra istemci gizliye çevrilir, sonra uzlaştırıcı yeniden koşar.

İstemci adı realm'den gelir (`e-skylab-sandbox` → `superadmin`, diğerleri → `admin`;
`inscribed-cms-roles.sh` ile aynı); `KEYCLOAK_ADMIN_PANEL_CLIENT_ID` başka bir ad verir.

### Token exchange'ten sonra API'lerin okuduğu claim'ler (admin-token-authz K1)

Panelin sunucusu (BFF) her API'ye exchange'li bir token gönderir: `audience` tek API, `scope`
yok. Keycloak 26.7 bu token'ı panelin kendi token'ıyla aynı oturumda (`sid` aynı), aynı istemciyle
(`azp`) ve aynı varsayılan kapsamlarla üretir. Sonra `aud`'u istenen API'ye, `resource_access`'i o
API'nin anahtarına indirir (`TokenManager.restrictRequestedAudience`). İstemcinin kendi
mapper'ları (`inscribed-roles`, `groups`) ve profil kapsamları yeniden çalışır. Yani düz `roles` ve
`groups` kalır, `resource_access.admin` düşer. Yanıtta refresh token ve ID token yoktur.
`requested_token_type=…:refresh_token` istenirse `400 invalid_request` döner.

Sözleşme `tests/admin-panel-exchanged-token.jq`'dadır. İki harness de onu çalıştırır:

- `aud` tam olarak istenen API'dir.
- `resource_access`, panel token'ının yalnız o API'ye ait kısmıdır. skycms için boştur.
- `realm_access` ve `client_id` yoktur. core, `client_id`'yi servis hesabı işareti sayar.
- Panel token'ındaki her claim aynı değerle kalır. Bunun dışında kalanlar yalnız `aud`,
  `resource_access`, `exp`, `iat` ve `jti`'dir.
- Yeni claim eklenmez.
- Token, panelin token'ından uzun yaşamaz.

| API | Token'dan okuduğu claim'ler (kaynak) | Exchange'ten sonra |
| --- | --- | --- |
| core (`aud` ∋ `core`) | `iss`, `sub` (UUID), `azp`, `email`, `given_name`, `family_name`, `preferred_username`, (varsa) `school_email`, `sky_number`, `university`, `department`, `groups` (tam yol; ya da Group overage işareti `_claim_names.groups`), `resource_access.core.roles`; `client_id` = `azp` servis hesabı demektir (core-backend `internal/authn/jwt.go`) | hepsi aynen; `resource_access` yalnız `core` |
| forms-backend (`aud` ∋ `forms`) | `iss`, `sub` (GUID; erişim kapısı), `resource_access.forms.roles` (`skyforms:*`) (`FormsJwtAuthenticationExtensions.cs`, `JwtCurrentUserService.cs`) | hepsi aynen; `resource_access` yalnız `forms` |
| inscribed (`aud` ∋ `skycms`) | `azp` (tenant), `sub` (`updatedBy`), düz `roles` (`content:*`), `groups` (tam yol; koleksiyon kuralları, takım slug'ı), `email` (yalnız `/admin/*` yolları) (inscribed-dotnet 2.0.1: `ConfigureJwtBearerOptions.cs`, `ClaimPrincipalTenant.cs`, `AccessRuleEvaluator.cs`) | hepsi aynen; `resource_access` boş |

Harness'ler:

- **Production biçimi:** `tests/admin-panel-client.sh`, aşama
  `stage_admin_panel_exchange_claims`. Roller production'daki gibi gruplardan gelir. Üç kişi
  panelden gerçekten giriş yapar:
  - Privileged kişi `/UYELER/YK`'dadır. Operatörün tohumladığı core rolleri, `content:read`,
    `content:write` ve forms'un `skyforms:*` rolü bu gruptan gelir.
  - Lider `/UYELER/ARGE/WEBLAB` ve `…/LIDERLER`'dedir. `content:*` rolleri `LIDERLER`'den
    gelir.
  - Sıradan üyenin rolü yoktur.

  Panel token'ı kişinin Admin API'deki etkin rollerini ve grup yollarını birebir taşır. Üç API'ye
  yapılan exchange sözleşmeyi korur.
- **Evaluate:** Keycloak'ın Evaluate'i (`evaluate-scopes/generate-example-access-token`,
  `userId`, `audience`, `scope=openid`) exchange'le aynı token'ı verir; yalnız `sid`, `iss` ve
  zamanlar farklıdır. Bu yüzden canlı bir realm, kimsenin parolası olmadan Evaluate'le
  denetlenebilir.
- **Sandbox biçimi:** `tests/sandbox-admin-local-client.sh`. Burada `groups` bir realm
  kapsamından gelir ve istemcide elle konmuş bir claim vardır. `superadmin`'in exchange'i aynı
  sözleşmeyi korur. `admin-local` public'tir ve exchange kapalıdır, bu yüzden `400
  invalid_request` alır. Exchange açılsa bile Keycloak public istemciye `invalid_client`
  döndürür. BFF yerelde çalışmadan önce `admin-local` gizli istemciye dönmelidir.

Kalan risk elle kurulmuş canlı istemcilerdedir. `profile`, `email` ve `basic` `admin`'in
varsayılan kapsamı değil de isteğe bağlı kapsamıysa durum değişir: panelin girişi bunları
`scope` ile ister, exchange istemez. O durumda `email`, profil ve `sub` exchange'li token'da
olmaz. Bu, canlıda bir kişi ve `audience` ile Evaluate'le görülür.

### Operatör oturumuyla tek adım (sandbox)

Sandbox realm'inde uzlaştırıcı kimliği (`account-center-config`) yoktur ve tam uzlaştırma sandbox'a
uygulanmaz. Operatör aynı adımı kendi kcadm oturumuyla tek başına koşar:

```bash
# Keycloak konteynerinde; kullanıcı adını read sorar, parola kcadm'ın kendi prompt'una girilir
read -r -p 'master realm geçici yönetici: ' OPERATOR_USER
/opt/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm-operator.config \
  --server http://localhost:8080 --realm master --user "$OPERATOR_USER"
KEYCLOAK_REALM=e-skylab-sandbox \
KEYCLOAK_RECONCILE_KCADM_CONFIG=/tmp/kcadm-operator.config \
KEYCLOAK_RECONCILE_ONLY=admin-panel-client \
  /opt/keycloak/config/reconcile-account-center.sh
rm -f /tmp/kcadm-operator.config
```

`KEYCLOAK_RECONCILE_KCADM_CONFIG` verilince uzlaştırıcı giriş yapmaz, config-client secret'ı
istemez ve o dosyayı silmez; `KEYCLOAK_RECONCILE_ONLY` olmadan reddeder (2), çünkü tam uzlaştırma
yalnız dar yetkili uzlaştırıcı kimliğiyle koşar. Çıktının son satırı `Admin panel client
configuration is reconciled.` olur.

### Sandbox sırası

1. sky_lab_genel'deki `ops/wizards/admin-panel-keycloak-sandbox-wizard.sh` sunucuda koşar
   (kopyalama komutları başında). Sürüm production'a çıkmadan da çalışır: gereken config
   dosyalarını sha256'larıyla denetleyip Keycloak konteynerinin `/tmp`'sine koyar.
   - kcadm girişi (şifre kcadm'ın kendi isteminde);
   - önce: `superadmin`'in bayrakları ve bir kişi için Evaluate ile örnek access token'ın boyutu,
     `aud`'u, `resource_access` anahtarları, `realm_access`'i (token ya da kişisel alan basılmaz);
   - onayla adım, ardından ikinci koşu (her satır `unchanged` olmalı);
   - sonra: aynı ölçüm;
   - `sandbox-admin.yildizskylab.com`'da yeniden giriş ve kontrol listesi: dashboard, form kapısı,
     News, SkyApp handoff hedefleri. Bir kontrol bozuksa wizard tam kapsamı geri açmayı önerir.
2. Wizard'ın sonundaki önce/sonra satırı spec'e (admin-token-authz) yazılır.

### Production sırası

1. Bu değişikliği içeren sürüm production'a çıkar (yayın kapısı ve WebAuthn onayı).
2. Uzlaştırıcı iki kez koşar (önceki yayın wizard'larındaki `reconcile` düzeni, config-client
   secret'ı stdin'den). İlk koşuda beklenen: `client scope admin-panel-api-audience: created`,
   `protocol mappers of scope <id>: updated (+core-audience +forms-audience +skycms-audience)`,
   `default client scope admin-panel-api-audience attached to client <id>`, `role scope mappings
   of admin (every role of core, forms): updated (+core/… +forms/…)` (elle konmuş başka eşleme
   varsa `-<istemci>/<rol>` ya da `-realm/<rol>`), `client admin (no full scope, standard token
   exchange): updated (fullScopeAllowed attributes)`. İkinci koşuda hepsi `unchanged`.
3. Evaluate ile önce/sonra boyut (Clients → `admin` → Client scopes → Evaluate, bir Privileged
   kişi, `openid profile email`) spec'e yazılır.
4. `admin.yildizskylab.com`'da çıkış + giriş, sonra sandbox'taki kontrol listesi.

Geri dönüş: Admin Console → Clients → `admin` (sandbox'ta `superadmin`) → Client scopes →
`admin-dedicated` → Scope → "Full scope allowed" açılır; token bir sonraki girişte eski haline
döner. Audience kapsamı kalabilir (zararsız). Uzlaştırıcı bir sonraki koşuda yeniden daraltır;
geri dönüş kalıcı olacaksa bu adımı içermeyen sürüme dönülür.

Harness (`tests/admin-panel-client.sh`, `run-integration.sh` çağırır): fixture'daki `admin`
production'ın biçimindedir (gizli, tam kapsam, `inscribed-roles` ve tam yollu `groups`
mapper'ları). Tam kapsamlı kontrol token'ı kişinin yabancı rollerini taşır; ilk koşu istemciyi
yerinde (aynı id, aynı secret) daraltır ve `forms` yokluğunu bildirir; kaymalar (tam kapsam,
exchange kapalı, eksik `core` rolü, realm ve `skymail` rolü, isteğe bağlı kapsam, bozuk ve yabancı
mapper) ikinci koşuda onarılır. `forms` oluştuktan sonra adım operatör oturumuyla tek başına koşar:
eksik istemci uyarıyla atlanır, public istemci reddedilir ve değişmez, adımsız operatör oturumu
reddedilir, yeni `forms` rolü kapsama girer. Gerçek authorization code girişinde `aud` tam
`core`, `forms`, `skycms`, `realm_access` yok, `resource_access` tam kişinin `admin`, `core`,
`forms` rolleri, `roles` ve `groups` duruyor, `azp` ve `sid` var; hiç API rolü olmayan bir
kişinin token'ı da üç audience'ı taşır; token exchange `core`, `forms`
ve `skycms` için tek audience verir, `skymail` için `400 invalid_request`. Değişiklik üretmeyen
koşu bu istemcinin durumunu da karşılaştırır; ardından web handoff sözleşmesi daraltılmış
istemcinin token'ıyla admin uçlarını dener.

## 17. Parola sıfırlamada okul ya da kişisel e-posta (K4b)

(§16 admin panelinin istemcisine ayrıldı, skylab-kulubu/e-skylab-keycloak#52.)

K4'ten önce "Şifremi unuttum" sayfası kişiyi yalnız kullanıcı adı ve birincil e-postayla
buluyordu: okul ya da kişisel e-postasını yazan kişi "e-posta gönderildi" cevabını alıyor ama
posta gitmiyordu. SPI 1.15.0'daki `sky-reset-credentials-choose-user`
(`com.skylab.authenticator.SkyResetCredentialChooseUser`), Keycloak'ın
`reset-credentials-choose-user`'ını genişletir ve yalnız aramasını değiştirir: alan, parolalı
girişin aldığı dört şeyi alır (§15, aynı `LoginIdentifiers` kodu ve kuralları). Uzlaştırıcı onu
realm'in parola sıfırlama akışına koyar.

### Cevap ve olaylar

Sayfa her girdide aynı "e-posta gönderildi" cevabını verir; bir adresin kimseye ait olup
olmadığı sayfadan anlaşılmaz. Kullanıcı adı ve birincil e-posta Keycloak'ın adımına
değiştirilmeden gider. Yalnız okul ya da kişisel e-postayla bulunan kişi Keycloak'ın bulduğu kişi
gibi seçilir; devre dışıysa Keycloak'ın devre dışı kullanıcı adındaki gibi seçilmez
(`RESET_PASSWORD_ERROR`, `user_disabled`) ve posta gitmez. İki kişiyi gösteren girdi (Keycloak'ın
kendi araması birini bulsa bile), kanıtlanmamış adres ve bilinmeyen adres bulunamayan kullanıcı
adı gibi işlenir: kimse seçilmez, `RESET_PASSWORD_ERROR` `user_not_found`, posta gitmez.
`ATTEMPTED_USERNAME` yazılan girdidir; hiçbir sayfa kişinin başka bir tanımlayıcısını
göstermez. Keycloak'ın bu adımında brute force denetimi yoktur, eklenmedi.

### Posta nereye gider

Bağlantı her zaman kişinin birincil e-postasına (Keycloak `email`) gider, yazılan adrese
değil. Bunu Keycloak'ın sonraki adımı `reset-credential-email` yapar; K4b ona dokunmaz.

- Birincil e-posta, kişinin okul ve kişisel e-postasından posta almak için seçtiği adrestir
  (CONTEXT.md, Primary e-mail); token'lar, core, SkyMail ve bildirimler de onu görür.
- Keycloak bağlantının action token'ını bu adrese bağlar (`eml`): birincil adres değişirse
  bağlantı geçersizleşir. Bağlantı izlenince `emailVerified=true` yazar; bu, bağlantının gittiği
  adres için doğrudur. Yazılan adrese göndermek iki güvenceyi de bozardı ve bu adımın da
  değiştirilmesini gerektirirdi.
- Kıyas: Microsoft hesabı kodu kayıtlı güvenlik bilgisine (yedek e-posta ya da telefon), Google
  kurtarma adresine yollar; ikisi de yazılan takma ada değil, hesabın kayıtlı adresine yollar
  (aynı). GitHub sıfırlamayı yalnız birincil ya da yedek adresle (varsayılan olarak her
  doğrulanmış adres) istetir ve bağlantıyı istenen adrese yollar (fark: burada yalnız birincil).
- Bilinen sınır: birincil adresi okul e-postası olan ve okul posta kutusunu kaybeden kişi (mezun)
  bağlantıyı alamaz; kişisel e-postasını yazsa da posta okul adresine gider. Microsoft ile hâlâ
  girebiliyorsa Hesap Merkezi'nden birincil adresi kişisel e-postaya çevirir; giremiyorsa
  destek gerekir. Bu durum için ürün kararı bekleniyor (K4b bileti).

### Uzlaştırıcı

`reconcile_reset_choose_user`, `reconcile_password_form`'dan hemen sonra koşar. Realm'in
`resetCredentialsFlow` bağlantısını okur. Keycloak yerleşik (`builtIn`) akışlara yürütme
eklemeyi ve silmeyi reddeder; realm yerleşik bir akışa bağlıysa (fixture'da ve büyük olasılıkla
üretimde `reset credentials`) akış bir kez `sky reset credentials` adıyla kopyalanır. Adım,
parola formunun değişimindeki yolla (`swap_flow_execution`, `ReconcileJson password-form`
planlayıcısı, aynı durdurma kuralları) kopyada değiştirilir. Realm kopyaya ancak bundan sonra
bağlanır; hiçbir istek yarım akışa denk gelmez. Bağlama, yalnız bu alanı taşıyan bir realm
PUT'udur (realm adımlarının yazımı gibi; §0'daki CIBA/PAR notu geçerli). Kopyadan sonra kesilmiş
bir koşu kopyayı bırakır; sonraki koşu yenisini yapmaz, onu kullanır. Realm zaten yerleşik
olmayan bir akışa bağlıysa kopya yapılmaz, değişim o akışta olur. Yerleşik akıştaki üretim
olgusu bilinmiyor: wizard ilk koşunun satırlarını gösterir.

Realm yerleşik `reset credentials`'a bağlıyken ilk koşunun satırları:

- `[reconcile] authentication flow 'sky reset credentials': created (an editable copy of the built-in 'reset credentials')`
- `[reconcile] choose-user step of flow 'sky reset credentials': updated (reset-credentials-choose-user -> sky-reset-credentials-choose-user in subflow 'sky reset credentials', priority 10, REQUIRED)`
- `[reconcile] realm reset credentials flow binding: updated (reset credentials -> sky reset credentials)`

İkinci koşu:

- `[reconcile] choose-user step of flow 'sky reset credentials': unchanged (sky-reset-credentials-choose-user)`
- `[reconcile] realm reset credentials flow binding: unchanged (sky reset credentials)`

Öncelik Keycloak 26'nın yerleşik akışında 10'dur; eski bir sürümde kurulmuş realm'de farklı
olabilir, değişim neyse onu korur.

Geri dönüş bayrağı `KEYCLOAK_RESET_CHOOSE_USER` (varsayılan `sky-reset-credentials-choose-user`;
`reset-credentials-choose-user` Keycloak'ın adımını bağlı akışta aynı yere geri koyar; başka
değer koşuyu hiçbir şey okumadan durdurur). Geri dönüş bağlantıyı değiştirmez: realm
`sky reset credentials`'a bağlı kalır, kopya artık yalnız Keycloak'ın adımlarını taşır.
Yerleşik akışa bağlı bir realm'de geri dönüşün yapacağı bir şey yoktur. Bayraksız sonraki koşu
SKY LAB adımını yeniden koyar.

### Üretim sırası

1. SPI 1.15.0'ı taşıyan Keycloak sürümü yayımlanır (`main` → `production` tek squash,
   `keycloak-production` Touch ID onayı o commit'e bağlanır, `/health/ready` yeşil). İmaj tek
   başına davranışı değiştirmez; akış uzlaştırıcıyla değişir.
2. Uzlaştırıcı bir kez koşar: sky_lab_genel `ops/wizards/keycloak-k4b-release-wizard.sh`
   (sunucuda) ya da §9'daki `docker exec` komutu. Beklenen yeni değişiklik satırları
   yukarıdaki üç satırdır (realm yerleşik olmayan bir akışa bağlıysa yalnız `choose-user step`
   satırı). Geri kalan her satır `unchanged` olmalıdır.
3. Aynı komut ikinci kez koşar; hiçbir satır `updated` dememelidir.
4. Admin Console → Authentication: `sky reset credentials` "Used by: Reset credentials flow"
   göstermeli, ilk satırı "SKY LAB Choose User" (REQUIRED) olmalıdır.
5. Deneme (gizli pencere, `https://my.yildizskylab.com` → "Şifremi unuttum"): birincil adresi
   kişisel e-posta olan YTÜ bağlantılı bir hesabın okul e-postası ve birincil adresi okul
   e-postası olan bir hesabın kişisel e-postası; ikisinde de posta birincil adrese gelir.
   Var olmayan bir adres aynı cevabı alır, posta gitmez.

Geri dönüş: aynı komuta `export KEYCLOAK_RESET_CHOOSE_USER=reset-credentials-choose-user`
eklenip bir kez koşulur (beklenen satır `choose-user step of flow 'sky reset credentials':
updated (sky-reset-credentials-choose-user -> reset-credentials-choose-user …)`), sonra gerekirse
eski imaja dönülür. Sıra önemlidir: 1.15.0'dan eski imajda `sky-reset-credentials-choose-user`
bulunmadığından o akışla her parola sıfırlama isteği ve Admin Console'da akışın yürütme listesi
hata verir. Eski imaj zaten çalışıyorsa önce 1.15.0 imajı yeniden dağıtılır, bayraklı koşu
yapılır, sonra geri dönülür. 1.14.0'dan da eskiye dönülecekse aynı koşuya
`KEYCLOAK_PASSWORD_FORM=auth-username-password-form` da eklenir (§15). Realm'i yerleşik
`reset credentials`'a geri bağlamak gerekmez; sky_lab_genel'deki wizard'ın `--rollback`'i bunu da
yapar.

**Acil yol (her imajda çalışır, uzlaştırıcı gerekmez):** Admin Console → `e-skylab` realm'i →
Authentication → listede `reset credentials` (yerleşik akış) satırının ⋮ menüsü (ya da akışı açıp sağ
üstteki Action menüsü) → **Bind flow** → **Reset credentials flow** → Save. Realm o anda Keycloak'ın kendi akışına döner ve K4b'den önceki
duruma gelir; `sky reset credentials` kopyası bağlantısız kalır, silinmesi gerekmez. 1.15.0'dan eski
bir imaj zaten çalışıyorsa ve parola sıfırlama hata veriyorsa önce bu yapılır. Bundan sonra
bayraksız bir uzlaştırıcı koşusu realm'i yeniden kopyaya bağlar; geri dönüşte kalınacaksa
uzlaştırıcı `KEYCLOAK_RESET_CHOOSE_USER=reset-credentials-choose-user` ile koşulur (yerleşik akışa
bağlı realm'de hiçbir şey yazmaz).

Harness: `tests/reset-by-either-email.sh` (`run-integration.sh` içinden). İlk uzlaştırmada
yerleşik akış değişmez; kopya, yerleşik akıştan yalnız adımıyla ayrılır ve realm ona bağlanır.
Yarıda kalmış bir koşu (realm yerleşik akışa geri bağlı, kopyada Keycloak'ın adımı) ikinci
uzlaştırmada aynı kopyayla tamamlanır; no-op koşu sessizdir. Geri dönüş ve yeniden ileri, K4'ün
koşularıyla birlikte (`tests/login-by-either-email.sh`): geri dönüşte kişisel e-posta kimseyi
bulmaz, kullanıcı adı bulur; ileride kişisel e-posta birincil adrese posta başlatır; geçersiz
bayrak durdurulur. K5'ten sonra, postalar SkyMail'den çıkarken: okul e-postası (karışık harfli
kayıt, boşluklu ve büyük harfli girdi) ve kişisel e-posta sıfırlama postasını birincil adrese
yollatır; kullanıcı adı Keycloak'ın yoluyla çalışır; bilinmeyen, iki kişide olan, kanıtsız
kişisel, bağlantısız okul e-postası ve devre dışı hesap aynı sayfayı alır, posta gitmez ve olayları
Keycloak'ınki gibidir; SkyMail tam olarak üç posta alır. Postadaki bağlantı, isteyen tarayıcıda
yeni parolayı kurar ve kişi okul e-postası ile yeni parolasıyla girer; adresleri değişmez.

## 18. Etkinlik sitelerinin site istemcileri ve editör grupları (ADR-0056 eki)

ARTLAB, YıldızJam ve SkyDays canlıdaki inscribed'ın kendi tenant'larıdır; tenant sitenin Site
client'ıdır. Üç betik sırayla koşar, hepsi §12'deki düzendedir (varsayılan `--check`, `--apply`
yazar, ikinci koşu hiçbir şey yazmaz; kcadm prompt'u ya da `--kcadm-config`):

1. `config/site-clients.sh [--site artlab|yildizjam|skydays]...` (varsayılan: üçü). `KEYCLOAK_REALM`
   zorunludur ve yalnız `e-skylab` ya da `e-skylab-sandbox` olabilir; başka değer ya da boş değer
   girişten önce `refusing realm …` ile 2 döner. Realm ya da `skycms` istemcisi yoksa 1 döner, hiçbir
   şey yazmaz. Her istemci:
   - gizli; standard flow açık ve PKCE `S256` zorunlu (NextAuth'un Keycloak sağlayıcısı PKCE gönderir);
     implicit ve direct grant kapalı; servis hesabı açık; `fullScopeAllowed=false`; consent kapalı;
   - redirect tam olarak `https://<site>.yildizskylab.com/api/auth/callback/keycloak` (sandbox'ta
     `https://sandbox-<site>.yildizskylab.com/…`), web origin site kökeni, post-logout `<köken>/*`.
     İstemcideki başka adresler (localhost dahil) silinir ve listelenir (karar D4);
   - `aud` içinde `skycms`: ortak realm kapsamı `skycms-audience` (tek Audience mapper'ı, access token
     ve introspection), varsayılan kapsam; yoksa kurulur;
   - `aud` içinde `core`: `frontend-<site>-core-audience`, uzlaştırıcının `frontend-arge` için kurduğu
     biçimde; realm'de `core` yoksa `NOTE` ile atlanır;
   - tam yollu `groups`; `groups`'u başka biçimde yazan varsayılan ya da isteğe bağlı kapsam (Keycloak'ın
     `microprofile-jwt`'si realm rollerini `groups`'a yazar) yalnız bu istemciden ayrılır. İstemcinin
     kendi üzerindeki böyle bir mapper `PROBLEM`'dir.
   `frontend-main` ve `frontend-arge` elle yapılmıştır; betik onları yalnız raporlar (Full scope,
   redirect adresleri, `skycms`'in nereden geldiği).
2. `config/inscribed-cms-roles.sh --client frontend-<site>`: §12. Etkinlik siteleri de editör sitesidir
   (`cms:access`, `client:admin`); servis hesabı yalnız `content:read` + `schema:sync` alır. `cms-sync`
   (`POST /cms/sync`) yalnız `schema:sync` ister; yazma yetkisi gerekmez.
3. `config/site-editor-grants.sh [--site …]... [--team SITE=/YOL]...`: `cms:access` Privileged gruplara
   (`ADMIN`, `YK`, `DK`; `/<AD>` ve `/UYELER/<AD>` hangisi varsa) ve sitenin iki takımının doğrudan
   `LIDERLER`/`KOORDINATORLER` alt gruplarına: sahip lab takımı ve etkinliğin organizasyon takımı
   (karar 2026-10-03, CONTEXT.md "Site editor"); `client:admin` yalnız `ADMIN` gruplarına. Takımlar:
   ARTLAB → `/UYELER/ARGE/AIRLAB` + `/UYELER/ORGANIZASYON/ARTLAB`, YıldızJam → `/UYELER/ARGE/GAMELAB`
   + `/UYELER/ORGANIZASYON/YILDIZJAM`, SkyDays → `/UYELER/ARGE/SKYSEC` + `/UYELER/ORGANIZASYON/SKYDAYS`.
   Realm'de olmayan bir takım ya da `LIDERLER`/`KOORDINATORLER`'i olmayan bir takım `WARNING`'dir; öbür
   yetkiler yine verilir. `--team` bir siteye bir takım daha ekler. Kişiye, `/UYELER`'e ya da bir
   varsayılan grubu kapsayan gruba rol verilmez (`PROBLEM`). Hiçbir şey geri alınmaz: beklenmeyen bir
   sahip `WARNING`'dir. İstemci ya da rolleri yoksa site `MISSING` ile atlanır, çıkış 1.

Harness `tests/site-clients.sh` (Dockerfile'daki stok Keycloak, dev modu, `docker run --rm`): realm
reddi, `--check`'in yazmadığı, planın tam boyu, istemci bayrakları ve adresleri, `microprofile-jwt`'nin
yalnız istemciden ayrıldığı, `frontend-main`'e yazılmadığı, ikinci koşunun yazmadığı; grupların tam
listesi; PKCE'li gerçek yetkilendirme kodu akışıyla AIRLAB liderinin token'ında `aud` ⊇ {skycms, core},
tam yollu `groups`, `roles` ⊇ {cms:access, content:read, content:write}; ARTLAB organizasyon
takımı liderinin de editör olduğu; organizasyon takımı yoksa `WARNING`; YıldızJam editörünün ARTLAB
token'ında CMS rolü olmadığı (Full scope kapalı); PKCE'siz akışın, localhost'un ve başka adreslerin
reddi; servis hesabının yalnız `content:read` + `schema:sync` taşıdığı; kaymanın onarımı; sandbox
realm'inde köken, `core` yokluğu ve `/UYELER/ADMIN`; secret'ın hiç basılmadığı.

Operatör: sky_lab_genel'deki `ops/wizards/site-cms-setup-wizard.sh --site <site> --sandbox|--production`
üç betiği Keycloak konteynerinde koşar (git'ten okur, SHA-256 ile denetler), secret'ı sunucuda
OpenBao'ya taşır, inscribed tenant'ını, Dokploy ortamını ve deploy hook'unu kurar. İmaj yayını
gerekmez: betikler imaja girmeden kullanılır.

**Ana sitenin sandbox'ı (`--site main`, 2026-10-04).** Production'daki `frontend-main` elle yapılmıştır
ve yalnız raporlanır; sandbox realm'inde ise yoktu. `site-clients.sh --site main` ve
`site-editor-grants.sh --site main` yalnız `KEYCLOAK_REALM=e-skylab-sandbox` ile çalışır; `e-skylab`'da
girişten önce `refusing --site main …` ile 2 döner. `--site main` varsayılana girmez, açıkça verilir.
İstemci etkinlik sitelerininkiyle aynı biçimdedir (PKCE `S256`, `fullScopeAllowed=false`, ortak
`skycms-audience`, `frontend-main-core-audience` (uzlaştırıcının adı ve biçimi), tam yollu `groups`);
köken `https://sandbox.yildizskylab.com` (sitenin kodu `sandbox.` ve `sandbox-` ile başlayan
`NEXTAUTH_URL`'yi sandbox sayar ve arama motorlarına kapatır), redirect birebir
`https://sandbox.yildizskylab.com/api/auth/callback/keycloak`. Rolleri `inscribed-cms-roles.sh --client
frontend-main` kurar (servis hesabı yalnız `content:read` + `schema:sync`); editörleri yalnız
Privileged gruplardır (takım yok; `--team main=/YOL` eklenebilir), `client:admin` yalnız `ADMIN`'e.
Harness bunu da dener: production reddi, istemcinin biçimi, ADMIN üyesinin token'ında `cms:access` +
`client:admin`, düz üyede CMS rolü olmadığı, servis hesabının salt okuma kaldığı, ikinci koşunun
yazmadığı. Operatör: `ops/wizards/site-cms-setup-wizard.sh --site main --sandbox`.

**Yalnız ortak kapsam (`--shared-scope`, 2026-10-05).** `site-clients.sh --shared-scope [--apply]`
yalnız ortak `skycms-audience` kapsamını kurar ya da onarır ve elle yapılmış istemcileri raporlar;
hiçbir site istemcisini okumaz, yazmaz (`--site` ile birlikte kullanım hatasıdır, çıkış 2). Kapsam
bugün etkinlik sitelerinden önce gerekiyor: production'da `frontend-main` ve `frontend-arge`'ın
varsayılan kapsamıdır, `config/skyapp-cms-editor.sh` de `skyapp`'e bağlar ve kapsamda `skycms`'i
access token'a yazan bir Audience mapper'ı yoksa `MISSING` ile durur. Production'daki kapsam elle
yapılmıştı; 2026-09-21 realm dökümünde tek mapper'ı `audience-mapper`'dır ve ne
`included.client.audience` ne `included.custom.audience` taşır, yani Keycloak onun için hiçbir şey
eklemez. `skycms` o güne kadar `frontend-main` token'ına yalnız audience-resolve ile, kişi bir
`skycms` rolü taşıyorsa giriyordu. Betik kapsamın kendi `skycms-audience` mapper'ını ekler
(access token ve introspection, ID token değil), öznitelikleri `include.in.token.scope=false`,
`display.on.consent.screen=false` yapar ve yalnız `skycms`'i adlandıran (ya da hiçbir audience
adlandırmayan) başka bir Audience mapper'ını kendi mapper'ı yerindeyken siler: o mapper'ın
ekleyebileceği her şeyi kendi mapper'ı da ekler. Başka bir audience adlandıran mapper `PROBLEM`'dir
ve kalır. Harness: `tests/site-clients.sh` (production'ın biçimi, plan, yazılanlar, `skycms`'siz
kişinin `frontend-main` token'ında önce yok sonra var olan `skycms`, ikinci koşu, özel audience,
başka audience) ve `tests/skyapp-cms-editor.sh` (production'ın 2026-10-05'te bastığı `MISSING`
satırı, `--shared-scope --apply`'dan sonra koşunun sürmesi). Operatör: sky_lab_genel'deki
`ops/wizards/skyapp-cms-editor-wizard.sh` bunu `skyapp-cms-editor.sh`'tan önce koşar.

## 19. core'un kaynak rolleri ve Privileged gruplara bir kez verilmesi (ADR-0059)

core bugün etkinlik, bilet, sertifika, kullanıcı, grup gibi işlerde "kişi `ADMIN`, `YK` ya da `DK`
grubunda mı" diye bakar (Privileged). ADR-0059 bunu Microsoft'un uygulama rolleri modeline taşır:
her kaynak için `core` istemcisinde bir rol, rollerin gruplara eşlemesi SKY LAB admin panelinden.
Rol listesi ve her rolün core'da hangi denetimin yerini aldığı sky_lab_genel'deki
`.scratch/admin-token-authz/spec.md`'nin "Sözleşme: core'un kaynak rolleri" tablosundadır (core
04/05 aynı adları okur; adı değiştiren önce o tabloyu değiştirir):

`event:manage`, `season:manage`, `ticket:manage`, `ticket:validate`, `competitor:manage`,
`media:manage`, `media:private:read`, `certificate:manage`, `users:manage`, `groups:manage`,
`github:activity:read` (yeni) ve `url:moderator`, `url:access` (var olan; kısa link ve form
bağlantısında Privileged'ın yetkisini bugün de bu ikisi veriyor).

Davranış değişmesin diye her rol bugünkü Privileged gruplara verilir: `ADMIN`, `YK`, `DK`; her biri
`/<AD>` ve `/UYELER/<AD>` yollarından hangisi varsa (`site-editor-grants.sh` ile aynı kural).
Keycloak'ta bir grubun rolleri alt gruplarının üyelerine de geçer; bu altı yoldan birinin alt
grubundaki (ör. `/UYELER/YK/…`) kişi rolleri miras alır.

**Birebir karşılık değildir.** core'un `isPrivileged`'ı adı `ADMIN`, `YK` ya da `DK` olan bir grubu
ağacın **herhangi bir yerinde** Privileged sayar; tohumlama yalnız altı yolu kapsar: `/ADMIN`,
`/YK`, `/DK`, `/UYELER/ADMIN`, `/UYELER/YK`, `/UYELER/DK`. Bu yolların dışında aynı adı taşıyan bir
grubun (ör. `/TAKIMLAR/<takım>/YK`) üyeleri bugün core'da Privileged'dır ama bu rolleri almaz. Bu
yüzden core `AUTHZ_ROLE_MODE`'u `roles`'a çevirmeden önce production'da bu altı yolun dışında
`ADMIN`, `YK` ya da `DK` adlı gruplar listelenir (Admin Console → Groups arama kutusu, üç ad için);
her biri ya SKY LAB admin panelinden rolleri alır ya da bilerek dışarıda bırakılır.

**Bir kez.** Rol verildikten sonra rolün `skylab.seeded-group-mappings` özniteliğine zaman ve grup
yolları yazılır (ör. `2026-10-04T09:00:00Z /ADMIN,/UYELER/YK,/UYELER/DK`). İşaretli bir role
uzlaştırıcı bir daha eşleme eklemez; admin panelinden kaldırılan eşleme geri gelmez, eklenen
eşleme silinmez. Hiçbir koşu eşleme ya da rol silmez. Listeye sonradan eklenen bir rol kendi ilk
koşusunda (işaretsiz olduğu için) aynı gruplara verilir. Rolün kendisi silinirse bir sonraki koşu
(uzlaştırıcı kimliğininki de) onu yeniden oluşturur; işaret rolle birlikte gittiği için rol
işaretsizdir. Uzlaştırıcı kimliği onu gruplara **vermez**, yalnız uyarır; rolü yeniden veren
yalnız operatörün `core-roles` koşusudur. Eşlemeler önce yazılır, işaret en son; yarıda kalan
koşu sonraki koşuda tamamlanır (var olan eşleme yeniden yazılmaz).

**Kim yazar.** Rolleri oluşturmak `manage-clients` ister, uzlaştırıcı kimliğinde var. Gruba rol
vermek kullanıcı yetkisi (`manage-users`) ister; uzlaştırıcı kimliğinde yoktur ve ona verilmez
(`keycloak-mailer` ve `core-erasure` ile aynı gerekçe). Bu yüzden:

- Tam uzlaştırma (uzlaştırıcı kimliği) eksik rolleri oluşturur ve işaretsiz roller için
  `WARNING: core roles not yet granted to the Privileged groups: … run this step alone with an
  operator session: KEYCLOAK_RECONCILE_ONLY=core-roles` yazar. Hepsi işaretliyse iki satır da
  `unchanged`'dir (`client roles of core (13 resource roles): unchanged`, `group mappings of the
  core resource roles: unchanged (…)`).
- Operatör aynı adımı kendi kcadm oturumuyla tek başına koşar ve tohumlar (Keycloak konteynerinde;
  kullanıcı adını `read` sorar, parola kcadm'ın kendi prompt'una girilir, config dosyası sonda
  silinir):

```bash
read -r -p 'master realm geçici yönetici: ' OPERATOR_USER
/opt/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm-operator.config \
  --server http://localhost:8080 --realm master --user "$OPERATOR_USER"
KEYCLOAK_REALM=e-skylab \
KEYCLOAK_RECONCILE_KCADM_CONFIG=/tmp/kcadm-operator.config \
KEYCLOAK_RECONCILE_ONLY=core-roles \
  /opt/keycloak/config/reconcile-account-center.sh
rm -f /tmp/kcadm-operator.config
```

  Her işaretsiz rol için `core role <rol>: seeded once to <yollar> (granted to: <yeni eşlenenler>)`
  satırı, sonunda `Core resource roles are reconciled.` basılır. Eksik bir Privileged grup (ör. `DK`
  yoksa) uyarıdır, ona rol verilmez. Hiç Privileged grup yoksa hiçbir şey yazılmaz ve roller
  işaretsiz kalır. Bir varsayılan grup (`default-groups`) bir Privileged grubun kendisi ya da altıysa
  koşu hiçbir şey yazmadan hata verir: her yeni kişi bu rolleri alırdı. Denetimler kapalı tarafta
  başarısız olur: varsayılan grupların okunması başarısız olursa (`The default groups of realm …
  could not be read`) ya da bir Privileged grubun araması Keycloak'ın "yok" cevabı dışında bir
  nedenle başarısız olursa (`The Privileged group … could not be looked up`) koşu hiçbir eşleme ve
  işaret yazmadan hata verir; yalnız gerçek "yok" cevabı grubu eksik sayar.

`core` istemcisinin adı `KEYCLOAK_CORE_CLIENT_ID` ile değişir (varsayılan `core`); istemci yoksa
uyarıyla atlanır.

**Sıra.** Adım admin panelinin adımından (§16) önce koşar; tam uzlaştırmada yeni roller aynı koşuda
`admin` istemcisinin rol kapsamına girer. Operatör yolunda `core-roles`'tan sonra
`admin-panel-client` adımı da koşulur. core'un rol denetimine geçen sürümü (admin-token-authz 04)
production'a ancak bu adım production'da tohumlandıktan sonra çıkar.

**Token boyutu.** Bir Privileged kişinin `core` rolleri olan her token'ı (bugün `admin`, ve tam
kapsamlı giriş istemcileri) en çok 13 rol adı (~230 bayt) büyür. `admin` 02'de daraldığı için bu
pay oradan geliyor; tam kapsamlı diğer istemciler admin-token-authz 16–19'da daralır.

Geri dönüş: roller zararsızdır (core 04'e kadar okumaz). Eşlemeler Admin Console'dan ya da SKY LAB
admin panelinden kaldırılabilir; işaret kaldığı için uzlaştırıcı onları geri koymaz. Yeniden
tohumlamak için rolün özniteliği silinir ve operatör adımı koşulur.

Harness (`tests/core-roles.sh`, `run-integration.sh` çağırır): ilk tam koşu 13 rolü açıklamalarıyla
oluşturur, hiçbirini gruba vermez, işaretlemez ve operatör adımını söyleyen uyarıyı basar; admin
panelinin kapsamı yeni rolleri içerir. Operatör adımı: Privileged bir varsayılan grup varken
reddeder ve yazmaz; varsayılan grupların ya da `/UYELER/YK`'nın okunması (enjekte edilmiş bir
kcadm hatasıyla, `tests/kcadm-core-roles-failure.sh`) başarısız olunca da reddeder ve yazmaz; sonra
`/ADMIN` ve `/UYELER/YK`'ya her rolü verir, `DK` yokluğunu bildirir,
her rolü işaretler (listede olmayan `url:create`'e dokunmaz). Gerçek authorization code girişinde
YK üyesinin `admin` token'ında roller var; grupsuz kişide yok; YK'nın bir alt grubuna eklenen kişide
miras yoluyla var. Panelden kaldırılmış bir eşleme ikinci koşuda geri gelmez, panelden eklenmiş
bir eşleme silinmez; işareti kaldırılan rol (listeye yeni eklenmiş gibi) üçüncü koşuda yalnız eksik
gruba verilir. Değişiklik üretmeyen tam koşu rolleri, işaretleri ve grupların eşlemelerini de
karşılaştırır.

## 20. core'un servis rolleri: `media:attach`, `ticket:guest-apply`, `url:forms`, `users:read` (Forms servis hesabı)

Bir ürünün servis hesabının (client credentials) taşıdığı ve core'un `resource_access.core.roles`'tan
okuduğu `core` istemci rolleri. Hepsinde core `aud` içinde `core` ister.

| Rol | core'da ne açar | Sahibi |
| --- | --- | --- |
| `media:attach` | `POST /v1/media/{id}/attachments`, `DELETE …/attachments/{attachmentId}`, anonim form yüklemesinin kuralı (ADR-0052); `azp`/`client_id` core'un `MEDIA_SERVICE_CLIENTS` listesinde olmalı (ayarsızken `forms:forms`) | yalnız servis hesapları |
| `ticket:guest-apply` | Guest apply'ı ürün olarak çağırmak, `POST /v1/events/{id}/applications/guest` (core-internal-auth 03; core `docs/guest-apply.md` "From log to enforce"). core servis çağıranı yalnız `MEDIA_SERVICE_CLIENTS`'taki bir ürünse güvenir; zorlama açılınca bu rol de şarttır | yalnız servis hesapları |
| `url:forms` | forma bağlı kısa linkler (`/v1/urls/forms/{formId}`, `GET /v1/urls/availability`) | yalnız servis hesapları |
| `users:read` | `GET /v1/users/{id}` | kişiler de taşıyabilir (Java döneminden) |

Ad `ticket:guest-apply`: admin-token-authz sözleşmesindeki `ticket:manage` ve `ticket:validate` gibi
tekil kaynak adı + eylem. O tablodaki bir rolle çakışmaz; Privileged rol değildir, hiçbir gruba
verilmez. `url:forms` ve `users:read` production'da daha önce elle verilmişti (forms-url-role wizard'ı,
Java dönemi); şimdi öbür ikisiyle aynı adımda kodlu. Kişinin token'ında `client_id` yoktur; core
servis rollerini kişiden kabul etmez. Uzlaştırıcının listesi (`CORE_SERVICE_ROLE_DEFINITIONS`; rol,
istemciler, sahiplik, açıklama) `media:attach` ve `ticket:guest-apply` için core'un
`MEDIA_SERVICE_CLIENTS`'ıyla aynı tutulur; CMS'in servis istemcisi ikisine birlikte eklenir.

**Ne yapılır** (`reconcile_core_service_roles`, core rollerinin adımından sonra, admin panelinin
adımından önce):

| Ne | Kim | Davranış |
| --- | --- | --- |
| `core` istemcisinde dört rol | her koşu | yoksa açıklamasıyla oluşturulur (`manage-clients`; varsa açıklamaya dokunulmaz); yeni rol aynı koşuda admin panelinin rol kapsamına girer (§16), kişi taşımadığı için panel token'ına girmez |
| `forms`'un varsayılan kapsamı `roles` | her koşu | yalnız doğrulanır: `resource_access`'i ve audience resolve mapper'ı ile `aud: core`'u o verir. Yoksa uyarı; istemciye dokunulmaz. İkinci bir audience mapper **eklenmez** |
| `forms`'un rol kapsamı | her koşu | `fullScopeAllowed=false` ise eksik `core/<rol>` kapsam eşlemesine eklenir (yoksa rol token'a girmez); tam kapsamda bir şey yapılmaz |
| `service-account-forms`'a roller | yalnız operatör | eksik olan verilir; rolün `skylab.granted-service-accounts` özniteliğine zaman ve servis hesapları yazılır (ör. `2026-10-06T20:00:00Z service-account-forms`); elle verilmiş rol `unchanged (held)` olur ve yalnız kaydı yazılır |
| Başka sahipler | yalnız operatör | yalnız servis hesaplarının rolünü taşıyan kullanıcı, grup ya da varsayılan rol uyarıyla bildirilir (`users:read` için değil); servis hesabının listede olmayan core rolleri `NOTE` ile bildirilir; **hiçbir şey silinmez** |

`forms` istemcisi yoksa ya da servis hesabı kapalıysa uyarı yazılır ve atlanır; istemcinin
ayarları değiştirilmez. `core` yoksa adım atlanır.

**Kim yazar.** Servis hesabına rol vermek ve onun rollerini okumak kullanıcı yetkisi ister;
uzlaştırıcı kimliğinde yoktur (§19 ile aynı gerekçe). Uzlaştırıcı kimliği rolleri ve kapsam
eşlemelerini kurar, servis hesabını okuyamaz: öznitelikte servis hesabı yazılıysa `service account
service-account-forms: <rol> unchanged (granted by the operator step at …)`, yazılı değilse
`WARNING: <rol> is not yet granted to service account service-account-forms by the operator step …
KEYCLOAK_RECONCILE_ONLY=service-roles (runbook §20)` basar. Operatör adımı her koşuda servis
hesabının rollerini yeniden okur. Adımın eski adı `KEYCLOAK_RECONCILE_ONLY=media-attach` aynı adımı
koşar.

**Kuru koşu.** `KEYCLOAK_RECONCILE_CHECK=true` (yalnız operatör oturumu ve `service-roles` ile; başka
türlüsü 2 ile reddedilir) her şeyi okur, her değişikliği `would create …`, `would map …`, `would grant
<rol> to service account …`, `would record the grant of …` diye yazar ve hiçbir şey yazmaz. Son
satırlar `check: N change(s) pending; nothing was written` ve `Core service roles are checked;
nothing was written.` Uygulayan koşu `applied N change(s)` ve `Core service roles are reconciled.`
ile biter; ikinci koşu `applied 0 change(s)`.

**Kapalı tarafta başarısızlık.** Operatör adımı önce her şeyi okur (istemci, bayraklar, varsayılan
kapsamlar, rol kapsamı, servis hesabı ve rolleri, varsayılan rol, rollerin kullanıcıları ve
grupları), sonra yazar. Bir okuma Keycloak'ın "yok" cevabı dışında başarısız olursa (`… could not be
read in realm …; nothing was granted`) koşu hiçbir şey vermeden ve işaretlemeden hata verir; boş
cevap "yok" sayılmaz. Eksik rolün oluşturulması (zararsız, hiçbir şey vermez) okumalardan önce gelir.

Operatör adımı (Keycloak konteynerinde; kullanıcı adını `read` sorar, parola kcadm'ın kendi
prompt'una girilir, config dosyası sonda silinir). Önce sandbox, sonra production; önce kuru koşu:

```bash
read -r -p 'master realm geçici yönetici: ' OPERATOR_USER
/opt/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm-operator.config \
  --server http://localhost:8080 --realm master --user "$OPERATOR_USER"
KEYCLOAK_REALM=e-skylab-sandbox \
KEYCLOAK_RECONCILE_KCADM_CONFIG=/tmp/kcadm-operator.config \
KEYCLOAK_RECONCILE_ONLY=service-roles KEYCLOAK_RECONCILE_CHECK=true \
  /opt/keycloak/config/reconcile-account-center.sh
KEYCLOAK_REALM=e-skylab-sandbox \
KEYCLOAK_RECONCILE_KCADM_CONFIG=/tmp/kcadm-operator.config \
KEYCLOAK_RECONCILE_ONLY=service-roles \
  /opt/keycloak/config/reconcile-account-center.sh
rm -f /tmp/kcadm-operator.config
```

Production için aynı komutlar `KEYCLOAK_REALM=e-skylab` ile koşar. sky_lab_genel'deki
`ops/wizards/keycloak-forms-guest-apply-wizard.sh` bunu iki realm için yapar (kuru koşu, onay,
uygulama, yeniden kuru koşu 0, Evaluate). Beklenen ilk koşu (production, `users:read`, `url:forms`,
`media:attach` elle ya da önceki adımla verilmişken): `client role ticket:guest-apply of core:
created`, `service account service-account-forms: ticket:guest-apply granted`, öbür üçü için
`unchanged (held)`, yazılmamış kayıtlar için `grant recorded (…)`. İkinci koşu: dördü `unchanged
(held)`, `applied 0 change(s)`.

**Doğrulama.** Admin Console → Clients → `forms` → Client scopes → Evaluate → kullanıcı
`service-account-forms`: üretilen access token'da `aud` `core`'u, `resource_access.core.roles`
dört rolü içerir (`client_id` yalnız gerçek client-credentials token'ında görünür). Uçtan uca
(`media:attach`): sandbox core'a Forms konteynerinin kendi kimliğiyle `POST
/v1/media/00000000-0000-4000-8000-000000000000/attachments`: `422 media_not_linkable` her kimlik
denetiminin geçtiğini, `403 media_attach_forbidden` geçmediğini gösterir.

Geri dönüş: Admin Console → Users → `service-account-forms` → Role mapping → `core` rolü
kaldırılır ve rolün `skylab.granted-service-accounts` özniteliği silinir (yoksa uzlaştırıcı
"granted" der); operatör adımı bir sonraki koşusunda rolü yeniden verir, yani kalıcı geri dönüş
rolü ya da istemciyi listeden çıkaran sürümdür. Rollerin kendisi zararsızdır.

Bilinen sınır: rolü bir bileşik rolün (composite) içinden taşıyan sahipler yalnız varsayılan rol
için aranır; başka bir bileşik rolün içine konmuşsa bildirilmez.

Harness (`tests/core-service-roles.sh`, `run-integration.sh` çağırır): ilk tam koşu dört rolü
açıklamasıyla oluşturur, `forms` yokluğunu bildirir, kimse rolleri taşımaz. `forms` oluştuktan
(core-erasure) sonra: kontrol token'ında rol yok; uzlaştırıcı kimliğiyle adım (eski adıyla
`media-attach`) vermez, işaretlemez ve operatör adımını söyler; uzlaştırıcı kimliğinin kuru koşusu
reddedilir; dört okumadan (varsayılan kapsamlar, servis hesabının rolleri, rolün kullanıcıları,
varsayılan rol) biri enjekte edilmiş kcadm hatasıyla başarısız olunca operatör adımı hiçbir şey
yazmadan durur. `users:read` servis hesabına elle verilmiş, `ticket:guest-apply` bir kişiye ve
`/ADMIN`'e, `users:read` bir kişiye, `url:create` servis hesabına elle verilmişken: kuru koşu yalnız
eksik üç rolü ve dört kaydı planlar (7), `users:read`'i vermeye kalkmaz, kişinin `users:read`'ini
bildirmez, admin olayı üretmez; uygulayan koşu aynı 7 değişikliği yapar, öbür sahipleri uyarıyla ve
`url:create`'i `NOTE` ile bildirir, hiçbirini silmez. Gerçek client-credentials token'ında `azp` ve
`client_id` `forms`, `aud` içinde `core`, `resource_access.core.roles` içinde dört rol;
`ticket:guest-apply`'ı servis hesabından başka kullanıcı ve grup taşımaz, `core-erasure`'ın
token'ında servis rolü yok. İkinci operatör koşusu `applied 0 change(s)`, admin olayı yok; ardından
kuru koşu `0 change(s) pending`. `fullScopeAllowed=false` yapılınca roller token'dan düşer
(kontrol), uzlaştırıcı kimliği dört kapsam eşlemesini ekler ve roller `aud: core` ile geri gelir.
Değişiklik üretmeyen tam koşu `forms`'un bayraklarını, rol kapsamını, servis hesabının `core`
rollerini ve kayıtları da karşılaştırır.

## 21. Giriş istemcilerinin dar token'ı: `frontend-main`, `frontend-arge`, `skymail` (ADR-0058, ADR-0059)

Üç giriş istemcisi production'da elle ve "Full scope allowed" açık kuruldu. Token kişinin bütün
audience'larını, realm rollerini ve başka istemcilerin rollerini taşıyordu; çoğunu hiçbir servis
okumuyordu. Uzlaştırıcı (`reconcile_login_clients`) her istemciyi uygulamanın çağırdığı API'lere
daraltır (admin-token-authz 16, 17, 18; admin paneli için §16'nın deseni).

**Ölçüm** (uygulamaların ve API'lerin `origin/main`'i, 2026-10-05: skylab-site `cbf670c`, arge
`74e3969`, `@skylab-kulubu/inscribed-auth` 0.3.1 (npm, `6994873`), skymail-frontend `f394739`,
skymail-backend `d9d6874`, core-backend `a6cec45` (production `3cbb235` bu dosyalarda aynı),
inscribed-dotnet `2ecc548`):

| İstemci | Token'ın gittiği API | Okunan | Daraltılmış token |
| --- | --- | --- | --- |
| `frontend-main` (ana site ve CMS editörü) | inscribed `/api/cms/cms/*` (tarayıcıdan, editörün ve oturum açmış her kişinin token'ı); core `POST /v1/media` (`/api/cms-media` köprüsü, amaç gönderilmez → `legacy`, kural `authenticated`) | inscribed: `aud ∋ skycms`, tenant `azp`, düz `roles` (`content:*`, `client:admin` + `email`), koleksiyon kuralları tam yollu `groups` (`teams`: `…/<TAKIM>/(LIDERLER\|KOORDINATORLER)`; `news`: Privileged yolları); core: imza, `iss`, `aud ∋ core`, UUID `sub` (rol ve grup gerekmez); site: herhangi bir istemcinin `resource_access` rollerinde `cms:access` (editör kapısı), ID token'dan ad ve e-posta | `aud` tam `core`, `skycms`; `realm_access` yok; `resource_access` yalnız `frontend-main`; `roles`, `groups`, `sub`, `azp`, ad ve e-posta aynı |
| `frontend-arge` (arge) | aynı iki API (köprü önce `cms:access`'e bakar) | aynı; arge'nin takımlar bölümü `teams` koleksiyonunu kullanır | `aud` tam `core`, `skycms`; `resource_access` yalnız `frontend-arge`; gerisi aynı |
| `skymail` (SkyMail arayüzü) | yalnız SkyMail `/api/skymail/v1` | SkyMail her `/v1` isteğinde token'la Keycloak userinfo'yu çağırır (`openid`, `sub`, `name`, `email`, `email_verified`); roller `resource_access.skymail.roles`; `aud`, `azp`, `realm_access`, `groups` okunmaz; posta listelerinin grupları SkyMail'in kendi servis hesabıyla okunur | `aud` tam `skymail`; `resource_access` yalnız `skymail`; `realm_access` ve `groups` yok |

Sitelerin servis hesabı token'ı (arge her sunucu çizimde, ana site `cms-sync`'te) da aynı istemciden
çıkar: `aud ∋ skycms`, `roles` = `content:read`, `schema:sync`; daraltmadan sonra da öyledir.

**Adım** (her istemci için, sırayla; istemci realm'de yoksa `WARNING: client <istemci> does not exist
in realm <realm>; skipped client scope <kapsamlar> and its token narrowing` ve sonraki istemci):

| Ne | Durum |
| --- | --- |
| Audience kapsamları | `frontend-main`: `frontend-main-core-audience` (`core`) ve `skycms-audience` (`skycms`); `frontend-arge`: `frontend-arge-core-audience` ve `skycms-audience`; `skymail`: `skymail-api-audience` (`skymail`, `config/skymail-api-audience-mappers.json`). §0.1 düzeni: kapsam adla devralınır, `include.in.token.scope=false`, tek `oidc-audience-mapper` (access token ve introspection, ID token değil), başka mapper silinir, varsayılan kapsamdır (isteğe bağlı listeden alınır) |
| Ortak `skycms-audience` | Etkinlik sitelerinin (`site-clients.sh`) ve SkyApp'in (`skyapp-cms-editor.sh`) de kullandığı realm kapsamı; uzlaştırıcı onu `site-clients.sh`'in biçimine getirir (`config/skycms-audience-mappers.json`, mapper adı `skycms-audience`). Production'daki tek mapper (`audience-mapper`) hiçbir audience adlandırmıyordu: sitelerin `skycms`'i yalnız audience-resolve'dan, yani tam kapsamdan ve kişinin bir `skycms` rolünden geliyordu. O mapper silinir, `skycms-audience` eklenir; etkisi `skycms-audience`'ı taşıyan her istemcide herkese `aud skycms` (e-skylab-keycloak#71 aynı onarımı `site-clients.sh --shared-scope` ile yapar; ikisi aynı sonuca varır) |
| Rol kapsamı | Boş: realm rolü ve başka istemcinin rolü yok, elle konmuş eşlemeler kaldırılır. İstemcinin kendi rolleri (`cms:access`, `content:*`, `schema:sync`, `client:admin`, `skymail:*`) Keycloak'ta her zaman geçer; core rolü gerekmez (core `/v1/media` yüklemesi rol istemez) |
| `groups` | Sitelerde dokunulmaz (inscribed okur). `skymail`'de `groups` yazan (Group Membership, `sky-group-overage-mapper` ya da claim'i `groups` olan; `microprofile-jwt` realm rollerini oraya yazar) her varsayılan ve isteğe bağlı kapsam yalnız `skymail`'den ayrılır, realm'de ve diğer istemcilerde kalır; `skymail`'in kendi böyle bir mapper'ı silinir (ADR-0059: grup okumayan uygulama grup almaz) |
| İstemci | `fullScopeAllowed=false`; başka alana (secret, adresler, bayraklar, istemcinin diğer mapper'ları) dokunulmaz |

Sıra uygulamaları bozmaz: önce audience'lar (tam kapsam açıkken zararsız), en son tam kapsamın
kapanması. Tam uzlaştırmada adım `skyapp` audience adımından sonra, `skyforms`'unkinden önce koşar.

Bilinçli davranış değişiklikleri:

- Sitelerin editör kapısı (`inscribed-auth` 0.3.1) `cms:access`'i token'daki **herhangi bir**
  istemcinin rollerinde arar. Tam kapsamda başka bir sitenin `cms:access`'i bu sitenin editörünü
  açıyordu; inscribed yazmayı yine reddediyordu (düz `roles` yalnız bu istemcinin rolleri). Daraltmadan
  sonra her site yalnız kendi `cms:access`'ine bakar. §12'deki atama tablosuna göre bundan yalnız
  `/UYELER/DK` etkilenir: arge'de editörü artık görmez (arge'de `cms:access` DK'ya verilmedi), ana
  sitede görmeye devam eder.
- Rolü olmayan bir kişinin site token'ında `skycms` de bulunur (önceden yoktu: oturum açmış
  editör olmayan kişinin koleksiyon okumaları inscribed'dan 401 alabiliyordu).
- SkyApp'in CMS rolleri (`skyapp-cms-editor.sh`, #62) `frontend-main`'in kendi `cms:access` ve
  `client:admin` rollerinin bileşenidir. Keycloak kapsamdaki rollerin bileşenlerini de açar ve
  istemcinin kendi rolleri her zaman kapsamdadır: #62 uygulandıktan sonra bir editörün ana site
  token'ı tam kapsam kapalıyken de `resource_access.skyapp` (`cms:access`, `content:*`, ADMIN/YK'da
  `client:admin`) ve `aud skyapp` taşır. Hiçbir servis bunları site token'ından okumaz (inscribed düz
  `roles`'a, yani `frontend-main`'in kendi rollerine bakar; editör kapısı aynı kişilerde açıktır);
  editör olmayanın token'ında yoktur. Harness bunu `skyapp-cms-editor.sh --apply`'dan sonra sınar.
- SkyMail token'ı `aud skymail` taşır (önceden SkyMail kendi adını `aud`'da görmüyordu; okumuyor da,
  RFC 9068 §2.2 ve ADR-0019'un "token API'yi `aud`'da adlandırır" kuralına uyum için).

### Operatör oturumuyla tek adım (sandbox)

Sandbox realm'inde uzlaştırıcı kimliği yoktur (§16). Operatör adımı kendi kcadm oturumuyla tek başına
koşar; sandbox `frontend-main`'i (`site-clients.sh --site main`, #65) zaten bu biçimdedir ve
değişmez, `frontend-arge`'a (`sandbox-site-clients.sh`) `skycms-audience` eklenir ve eski kurulumda
tam kapsam kapanır, sandbox'ta `skymail` varsa daralır:

```bash
read -r -p 'master realm geçici yönetici: ' OPERATOR_USER
/opt/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm-operator.config \
  --server http://localhost:8080 --realm master --user "$OPERATOR_USER"
KEYCLOAK_REALM=e-skylab-sandbox \
KEYCLOAK_RECONCILE_KCADM_CONFIG=/tmp/kcadm-operator.config \
KEYCLOAK_RECONCILE_ONLY=login-clients \
  /opt/keycloak/config/reconcile-account-center.sh
rm -f /tmp/kcadm-operator.config
```

Son satır `Login client configuration is reconciled.` İkinci koşu hiçbir şey yazmaz. Ardından
`site-clients.sh --site main --check`, `sandbox-site-clients.sh --check` ve `inscribed-cms-roles.sh
--check --client frontend-main --client frontend-arge` sıfır değişiklik planlar (harness'te kanıtlı).

### Production sırası

1. Bu değişikliği içeren sürüm production'a çıkar (yayın kapısı ve WebAuthn onayı).
2. **Önce** (sürümden önce ya da uzlaştırıcıdan önce): Evaluate ile üç istemcide örnek access token
   (Clients → istemci → Client scopes → Evaluate, `openid email profile`; bir Privileged kişi, bir
   takım lideri, bir üye): payload baytı, `aud`, `resource_access` anahtarları, `realm_access` rol
   sayısı, `groups` yol sayısı (§16'daki wizard'ın `measure` düzeni; token ve kişisel alan
   basılmaz). Ayrıca `frontend-main` ve `frontend-arge`'ın `fullScopeAllowed`'ı, `skymail`'in
   varsayılan ve isteğe bağlı kapsamları ve kendi mapper'ları not edilir (geri dönüş için).
3. Uzlaştırıcı iki kez koşar. İlk koşuda beklenen satırlar (production'ın bilinen hâline göre):
   `client scope frontend-main-core-audience: unchanged` (ya da `updated (attributes)`),
   `client scope skycms-audience: updated (attributes)`, `pruned protocol mappers from scope <id>:
   audience-mapper`, `protocol mappers of scope <id>: updated (+skycms-audience)`, `default client
   scope skycms-audience attached to client <frontend-arge id>` (ana sitede zaten bağlıysa yalnız
   arge), `role scope mappings of <istemci> (none: only its own roles): unchanged` (elle eşleme varsa
   `updated (-…)`), `client frontend-main (no full scope): updated (fullScopeAllowed)` (arge tam
   kapsamı zaten kapalıysa onunki `unchanged`), `client scope skymail-api-audience: created`,
   `protocol mappers of scope <id>: updated (+skymail-audience)`, `default client scope
   skymail-api-audience attached to client <skymail id>`, `groups claim of skymail (none): updated
   (-default scope groups …)` (kapsamın ya da mapper'ın adı canlıdakine göre), `client skymail (no
   full scope): updated (fullScopeAllowed)`. İkinci koşuda hepsi `unchanged`. `#71` daha önce
   uygulandıysa `skycms-audience` satırları `unchanged` olur.
4. **Sonra:** 2. adımdaki ölçüm aynı kişilerle; önce/sonra satırı spec'e (admin-token-authz) yazılır.
5. Uygulama kontrolleri (her birinde çıkış + giriş, yeni token için):
   - ana site: ADMIN/YK üyesi editörü görür, bir sayfa bloğunu ve bir haberi düzenleyip kaydeder,
     görsel yükler (`/api/cms-media` → core 201); bir takım lideri kendi takım sayfasını düzenler;
     DK üyesi editörü görür; oturum açmış editör olmayan biri sayfaları görür;
   - arge: lider editörü görür, bir takım kaydını düzenler, görsel yükler; sayfalar açılır
     (servis hesabıyla sunucu çizimi); DK üyesi editörü görmez (beklenen);
   - SkyMail: giriş, şablon listesi, posta görevleri özeti, onaylar ekranı (approver); sandbox'ta bir
     deneme gönderimi;
   - SkyApp'ten haber/takım düzenleme kurulduysa (`skyapp-cms-editor.sh`, #62) bir düzenleme.

Geri dönüş (istemci başına, Admin Console): Clients → istemci → Client scopes →
`<istemci>-dedicated` → Scope → "Full scope allowed" açılır; `skymail`'in grupları için not edilen
`groups` kapsamı yeniden varsayılan kapsam yapılır. Token bir sonraki girişte (ya da yenilemede) eski
hâline döner; audience kapsamları kalabilir (zararsız). Uzlaştırıcı bir sonraki koşuda yeniden
daraltır; geri dönüş kalıcı olacaksa bu adımı içermeyen sürüme dönülür.

Harness (`tests/login-clients.sh`, CI'da `login-clients` işi; tek başına stok Keycloak imajında, adımı
operatör yoluyla koşar): fixture production'ın biçimindedir (üç istemci elle, tam kapsamla;
`frontend-main`'de realm `groups` kapsamı, elle kurulmuş `frontend-main-core-audience` ve
production'daki boş `skycms-audience`; CMS rolleri `inscribed-cms-roles.sh` ile; Privileged kişide
sekiz başka istemcinin rolü ve 12 realm rolü). Önce kontrol token'ları yabancı audience'ları, realm
rollerini ve grupları taşır; rolsüz üyenin ana site token'ında `skycms` yoktur; DK üyesi arge
editörünü ana sitenin `cms:access`'iyle açar. Adımdan sonra gerçek girişlerde (PKCE, `openid email
profile`) siteler `aud` tam `core`, `skycms`, `realm_access` yok, `resource_access` yalnız sitenin
kendisi; sitenin, core'un ve inscribed'ın okuduğu claim'ler (Privileged kişi, lider, DK üyesi, üye)
öncekiyle aynı; servis hesabı token'ları `aud skycms` ve `content:read` + `schema:sync`; SkyMail `aud`
tam `skymail`, aynı roller, grup ve realm rolü yok, userinfo `sub`, ad ve e-postayı verir; her token
küçülür. İkinci koşu admin olayı üretmez; `inscribed-cms-roles.sh --check` değişiklik planlamaz;
`skyapp-cms-editor.sh --apply` artık geçer, SkyApp `cms:access`'i `frontend-main` üzerinden alır;
editörün site token'ı yalnız kendi bileşenlerinden gelen SkyApp rollerini ekler, üyeninki eklemez.
Adımdan önce açılmış oturumlar (ana site, arge, SkyMail) bir sonraki yenilemede dar token alır,
yeniden giriş gerekmez. Kaymalar onarılır. Sandbox realm'inde `site-clients.sh` ve
`sandbox-site-clients.sh`'in kurduğu istemcilerde adım yalnız `skycms-audience`'ı arge'ye ekler ve
üç betiğin `--check`'i sonra sıfır değişiklik planlar. Tam uzlaştırma yolu `run-integration.sh`'te
(`tests/login-client-audiences.sh`): `skymail` ilk koşuda, siteler ikinci koşuda daralır, değişiklik
üretmeyen koşu bu istemcilerin durumunu da karşılaştırır.
