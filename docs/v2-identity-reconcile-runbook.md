# Hesap Merkezi v2 kimlik uzlaştırması — üretim runbook'u

Bu runbook `config/reconcile-account-center.sh` içindeki v2 kimlik adımlarının
(passkey relying party id, realm giriş ve brute-force ayarları, olay saklama süresi, User Profile,
`account-center-account-api` ve `account-center-core-claims` kapsamları,
`keycloak-mailer` ve `core-erasure` istemcileri) üretime
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
| `frontend-main-core-audience` ve `skyforms-forms-audience` kapsamları | `frontend-main` ve `skyforms` giriş istemcilerinin varsayılan kapsamları; access token'ın `aud`'una `core` ve `forms` ekler. Üretimde elle kuruldular, uzlaştırıcı adlarıyla devralır. İstemci realm'de yoksa uyarı yazılır ve o kalem atlanır (§0.1). |
| `account-center` istemcisi | v1 sözleşmesi, `fullScopeAllowed=false` **kalır**: Keycloak Admin REST `AdminAuth.hasAppRole = user.hasRole && client.hasScope` ile yetkilendirir ve tam kapsam açıkken `client.hasScope` her rol için doğrudur; `realm-management` rolü olan bir kişinin `my.` token'ı Admin REST'te geçerli olurdu. `sky_authorization` bu yüzden kapsamdan bağımsız SPI mapper'ından gelir ve token'ın yetkisini genişletmez (harness: `view-users` sahibinin `account-center` token'ı ile `GET /admin/realms/{realm}/users` → 403; tam kapsamla 200 alırdı). Token'daki `resource_access` yalnız `account` rollerini içerir, `core` rolü taşımaz (test edilir). `account` istemci rolü scope mapping izin listesi: `manage-account`, `view-profile`, `manage-account-links` (AIA `idp_link` `client.hasScope` denetimi için). |
| `keycloak-mailer` istemcisi (K5) | Uzlaştırıcı **yalnız doğrular**: istemci yoksa uyarı ve çalıştırılacak komut; bayraklar (gizli, yalnız service account, standard flow / direct grant / implicit kapalı, `fullScopeAllowed=false`, `roles` varsayılan kapsamı) yanlışsa koşu hata ile durur; service account rolleri uzlaştırıcı kimliğiyle okunamadığından (kullanıcı yetkisi yok) uyarı olarak raporlanır. İstemciyi ve rolleri operatör `config/create-mailer-client.sh` ile oluşturur (§6). Gizli anahtarı Keycloak üretir, hiçbir betik yazdırmaz. |
| `core-erasure` istemcisi (hesap silme, ADR-0051) | Uzlaştırıcı **yalnız doğrular** (`keycloak-mailer` gibi): istemci yoksa uyarı ve çalıştırılacak komut. Şunlardan biri sözleşmeden farklıysa koşu hata ile durur ve operatör komutunu yazar: bayraklar (gizli, yalnız service account, standard flow / direct grant / implicit kapalı, `fullScopeAllowed=false`), varsayılan kapsamlar (tam olarak `basic` ve `roles`; Keycloak'ın eklediği `service_account` hoş görülür), isteğe bağlı kapsamlar (tam olarak üç `account-erase-*`), doğrudan scope mapping (olmamalı), her erase kapsamının tek audience mapper'ı ve tek rolü, servis istemcilerinin (`skymail`, `skycms`, `forms`) varlığı. Service account rolleri uzlaştırıcı kimliğiyle okunamadığından uyarı olarak raporlanır. İstemciyi, kapsamları ve rolleri operatör `config/create-erasure-client.sh` ile kurar (§11). |
| Kimlik korumaları: core sertifika rolleri, OBS `department mapper`, core'un `manage-clients` rolü | Uzlaştırıcı **dokunmaz**: kimliğinin kullanıcı ve kimlik sağlayıcısı yetkisi yoktur. Operatör `config/identity-guardrails.sh` ile uygular (§8). |

Ortam değişkenleri: `KEYCLOAK_PASSKEY_RP_ID` (varsayılan `yildizskylab.com`) ve
`KEYCLOAK_PASSKEY_EXTRA_ORIGINS` (virgülle ayrılmış, varsayılan
`https://my.yildizskylab.com`). Üretim Compose dosyası bunları geçmez;
`ACCOUNT_CENTER_REQUIRE_PRODUCTION_HOST=true` iken uzlaştırıcı yalnız üretim
değerlerini kabul eder. Entegrasyon fixture'ı `localhost` +
`http://localhost:18080` kullanır.

### 0.1 Giriş istemcilerinin audience kapsamları (`frontend-main`, `skyforms`)

Keycloak'ın audience-resolve mapper'ı bir API'yi `aud`'a yalnız token o API'nin
rollerini taşıyorsa ekler. Kişilerin çoğunun API rolü yoktur; token'larında API
bulunmaz ve API 401 döner. Bu iki giriş istemcisi API'yi kendi varsayılan kapsamıyla
`aud`'a ekler. İki kapsam da önce üretimde (`e-skylab`) elle kuruldu.

| İstemci | Kapsam / mapper | `aud`'a eklenen | Önlediği olay |
| --- | --- | --- | --- |
| `frontend-main` (skylab-site girişi) | `frontend-main-core-audience` / `core-audience` | `core` | core her Bearer token'da `aud` içinde `core` ister (ADR 0019). Site editörlerinin (ADMIN dahil) `core` rolü yoktur. Site, CMS görsel yüklemesinde (`/api/cms-media` → core `POST /v1/media`) editörün token'ını iletir; her yükleme 401 aldı. Elle kuruldu: 2026-09-25. |
| `skyforms` (SkyForms girişi) | `skyforms-forms-audience` / `forms-audience` | `forms` | forms-backend `aud` içinde `forms` ister. Yöneticilerin `forms` rolü vardır, üyelerin yoktur: üyeler 401 aldı, SkyForms "Oturumunuzun süresi doldu" döngüsüne girdi. Elle kuruldu: 2026-09-21. |

Uzlaştırıcı ikisini `skyapp-account-center-audience` gibi yönetir: kapsam
`include.in.token.scope=false`, `display.on.consent.screen=false`; tek mapper
`oidc-audience-mapper`, access token ve introspection'da açık, ID token'da kapalı
(`config/frontend-main-core-audience-mappers.json`,
`config/skyforms-forms-audience-mappers.json`); başka mapper silinir; kapsam istemcinin
varsayılan kapsamıdır (isteğe bağlı listedeyse oradan alınır). Kapsam ve mapper adla
bulunur, yeniden oluşturulmaz, yerinde onarılır. İstemci realm'de yoksa (sandbox'ta biri
eksik olabilir) uzlaştırıcı `WARNING: client <istemci> does not exist in realm <realm>;
skipped client scope <kapsam>` yazar, kapsamı kurmaz ve devam eder; istemci eklenince
sonraki koşu kurar.

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
