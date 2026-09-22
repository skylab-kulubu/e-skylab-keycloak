# Hesap Merkezi v2 kimlik uzlaştırması — üretim runbook'u

Bu runbook `config/reconcile-account-center.sh` içindeki v2 kimlik adımlarının
(passkey relying party id, realm giriş ve brute-force ayarları, User Profile,
`account-center-account-api` kapsamı, `keycloak-mailer` istemcisi) üretime
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
| Şifresiz passkey politikası (`account-center-passkey-policy.json` + ortam) | `webAuthnPolicyPasswordlessRpId=yildizskylab.com`, `webAuthnPolicyPasswordlessExtraOrigins=["https://my.yildizskylab.com"]`; entity name `SKY LAB`, ES256/RS256, resident key ve kullanıcı doğrulaması zorunlu, passkeys açık, conditional mediation; diğer alanlar Keycloak varsayılanları. Relying party id gerçekten değişiyorsa politika yazılmadan önce realm özniteliği `skylab.passkeyRpIdSwitchedAt=<ISO-8601 UTC>` kaydedilir (öznitelik haritası canlı halinin üstüne birleştirilir, başka öznitelik silinmez) ve `[reconcile] passkey relying party id switches from '…' to '…'` satırı basılır; §5'teki temizlik bu anı cutover alır. İki faktörlü (`webAuthnPolicy*`) politika yönetilmez. `attributes` taşımayan realm PUT'ları CIBA/PAR sürelerini Keycloak varsayılanına sıfırlar (önceden de böyleydi). |
| User Profile (`account-center-user-profile.json`) | Canlı yapı korunur (gruplar, açıklamalar, mesaj anahtarları, ek öznitelikler); `firstName`, `lastName`, `email` kişi için salt okunur (`edit=[admin]`, `view=[admin,user]`); `username` izinleri olduğu gibi; `schoolEmail`, `personalEmail`, `skyNumber`, `department`, `university`, `skyMail`, `usernameChangedAt` `view=[admin,user]`, `edit=[admin]`; e-posta özniteliklerinde `email`, `usernameChangedAt` için ISO-8601 UTC `pattern` doğrulayıcısı; eksik Türkçe görünen adlar eklenir, mevcutlar korunur; `unmanagedAttributePolicy=ADMIN_VIEW` (asla `ENABLED`) |
| `account-center-account-api` kapsamı | `account-api-audience` (`account`), `account-api-core-audience` (`core`), `account-api-manage-account`, `account-api-view-profile`, `account-api-manage-account-links` (sabit roller), `account-api-roles` (`resource_access.account.roles`), `account-api-sky-authorization` (SPI mapper'ı `sky-authorization-mapper`: `sky_authorization.<istemci>.roles`, yalnız access token ve introspection; ID token/userinfo'da yok; `realm-management`, `broker`, `account`, `account-console`, `security-admin-console`, `admin-cli`, `*-realm` hariç; sıralı; 64 istemci / 256 rol sınırı; rol yoksa claim yok). Audience-resolve mapper yoktur; `aud` tam olarak `["account","core"]` kalır. |
| `account-center` istemcisi | v1 sözleşmesi, `fullScopeAllowed=false` **kalır**: Keycloak Admin REST `AdminAuth.hasAppRole = user.hasRole && client.hasScope` ile yetkilendirir ve tam kapsam açıkken `client.hasScope` her rol için doğrudur; `realm-management` rolü olan bir kişinin `my.` token'ı Admin REST'te geçerli olurdu. `sky_authorization` bu yüzden kapsamdan bağımsız SPI mapper'ından gelir ve token'ın yetkisini genişletmez (harness: `view-users` sahibinin `account-center` token'ı ile `GET /admin/realms/{realm}/users` → 403; tam kapsamla 200 alırdı). Token'daki `resource_access` yalnız `account` rollerini içerir, `core` rolü taşımaz (test edilir). `account` istemci rolü scope mapping izin listesi: `manage-account`, `view-profile`, `manage-account-links` (AIA `idp_link` `client.hasScope` denetimi için). |
| `keycloak-mailer` istemcisi (K5) | Uzlaştırıcı **yalnız doğrular**: istemci yoksa uyarı ve çalıştırılacak komut; bayraklar (gizli, yalnız service account, standard flow / direct grant / implicit kapalı, `fullScopeAllowed=false`, `roles` varsayılan kapsamı) yanlışsa koşu hata ile durur; service account rolleri uzlaştırıcı kimliğiyle okunamadığından (kullanıcı yetkisi yok) uyarı olarak raporlanır. İstemciyi ve rolleri operatör `config/create-mailer-client.sh` ile oluşturur (§6). Gizli anahtarı Keycloak üretir, hiçbir betik yazdırmaz. |

Ortam değişkenleri: `KEYCLOAK_PASSKEY_RP_ID` (varsayılan `yildizskylab.com`) ve
`KEYCLOAK_PASSKEY_EXTRA_ORIGINS` (virgülle ayrılmış, varsayılan
`https://my.yildizskylab.com`). Üretim Compose dosyası bunları geçmez;
`ACCOUNT_CENTER_REQUIRE_PRODUCTION_HOST=true` iken uzlaştırıcı yalnız üretim
değerlerini kabul eder. Entegrasyon fixture'ı `localhost` +
`http://localhost:18080` kullanır.

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
