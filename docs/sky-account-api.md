# sky-account API v1 — Account Center BFF sözleşmesi

`sky-account`, SKY LAB Keycloak imajının içinde çalışan bir `RealmResourceProvider`
uzantısıdır (`spi/src/main/java/com/skylab/account`). Hesap Merkezi BFF'sinin
(`my.yildizskylab.com`) kişinin kendi kimliği ve kimlik bilgileri üzerinde yaptığı
tüm değişiklikler bu API'den geçer. Keycloak kimlik deposu olarak kalır; uzantı
Keycloak'ın kendi servislerini (bearer doğrulama, brute-force koruması, parola ve
OTP politikaları, credential sağlayıcıları, event builder) kullanır.

Taban adres: `https://e.yildizskylab.com/realms/e-skylab/sky-account/v1`
(entegrasyon: `http://localhost:18080/realms/e-skylab-test/sky-account/v1`).

## Kimlik doğrulama (her istek)

`Authorization: Bearer <access_token>` — yalnız `account-center` istemcisine verilmiş
canlı bir kullanıcı token'ı kabul edilir. Doğrulama Keycloak'ın
`AppAuthManager.BearerTokenAuthenticator` servisiyle yapılır (imza, süre, iptal
listesi, aktif kullanıcı oturumu, etkin kullanıcı); ardından sky-account şu
sözleşmeyi arar:

- `azp == "account-center"`
- `aud` içinde `account`
- `resource_access.account.roles` içinde `manage-account`
- `sid` token'ın bağlı olduğu kullanıcı oturumuyla aynı

Hepsi kişinin kendi hesabı içindir; yönetim işlemi yoktur. CORS yoktur: BFF
sunucudan sunucuya çağırır. Her ret aynı `401 unauthorized` problemidir ve
`WWW-Authenticate: Bearer realm="…", error="invalid_token"` başlığı taşır.

## Sudo modu

Hassas işlemler (`credentials/*`, `identity/username`) taze bir **sudo token**
ister. Kişi parolasını, doğrulama uygulaması kodunu ya da passkey'ini
`POST sudo/password` / `POST sudo/totp` / `POST sudo/webauthn/verify` ile kanıtlar;
yanıt bir sudo token verir. BFF bu token'ı sonraki isteklerde
`X-Sky-Sudo: <sudoToken>` başlığıyla gönderir.

Sudo token, Keycloak'ın **iç** token'ları gibi realm HMAC anahtarıyla
imzalanmış bir JWT'dir (`HS512`, `kid` başlıkta; anahtar Keycloak dışına
çıkmaz, bu yüzden token Keycloak dışında doğrulanamaz ve üretilemez). BFF onu
opak bir dize olarak saklar ve geri gönderir; içeriğine güvenmez.

| Claim | Değer |
| --- | --- |
| `typ` | `sky-sudo` |
| `iss` | realm issuer (bearer token'ın `iss` değeriyle aynı) |
| `sub` | kişinin Keycloak id'si (bearer `sub`) |
| `sid` | kanıtı üreten Hesap Merkezi oturumu (bearer `sid`) |
| `azp` | `account-center` |
| `aud` | `sky-account` |
| `amr` | `["pwd"]`, `["otp"]` veya passkey için `["hwk","user"]` |
| `jti`, `iat`, `nbf`, `exp` | `exp = iat + 300` |

Doğrulama (`SudoTokens.require`): imza (`session.tokens().decode`, yalnız
Keycloak'ın iç algoritması `HS512`), `typ`, `iss`, `aud`, `azp`, `jti`, `sub` ve
`sid` bearer'ın değerleriyle eşit, `iat`/`nbf` gelecekte değil (10 sn tolerans),
`exp` geçmemiş.
Token **tek kullanımlık değildir**: beş dakikalık pencere içinde aynı oturumun
tüm hassas işlemlerini karşılar. Başka bir oturumun (`sid`) bearer'ıyla
kullanılamaz; süresi geçince `401 sudo_expired`, diğer her ret `401 sudo_required`
döner. BFF token'ı yalnız şifreli oturum kaydında tutar, tarayıcıya vermez.

Her başarılı kanıt bir denetim olayı bırakır: `CUSTOM_REQUIRED_ACTION`
(`client=account-center`, kişi, oturum) ve ayrıntılar
`action=sky-sudo`, `method=password|totp|passkey` (passkey için ayrıca imzalayan
kimlik bilgisinin `public_key_credential_id` değeri).

Brute-force koruması realm'de açıksa (`bruteForceProtected`) her parola ve TOTP
sudo denemesi Keycloak'ın `BruteForceProtector` servisine bir giriş denemesi
olarak bildirilir (passkey denemeleri de bildirilir ama Keycloak bu kategoriyi
saymaz; bkz. Hız sınırları):
kilitli hesap kanıt vermeden `401 user_temporarily_locked` / `401 user_disabled`
alır, başarısız deneme `LOGIN_ERROR` (`error=invalid_user_credentials`,
`auth_method=sky-account-sudo`) olayı üretir ve sayacı artırır, başarılı deneme
sayacı temizler. Realm'de koruma kapalıysa yalnız hız sınırı uygulanır; uzantı
bu durumu açılışta (ve sonradan içe aktarılan realm'ler için ilk sudo
denemesinde) tek bir `WARN` günlüğüyle bildirir. Canlı realm'de koruma bugün
kapalıdır; reconcile bileti **K2** brute-force korumasını (ve asgari parola
politikasını) açar, bu API o ayarları olduğu gibi kullanır.

## Hız sınırları

Kullanıcı başına, sabit 15 dakikalık pencere, Keycloak'ın single-use object
deposunda (küme genelinde) tutulur; aşımda `429 rate_limited` + `Retry-After`.
Her istek pencerenin `1..N` yuvalarından birini `putIfAbsent` ile (Infinispan'da
atomik, istek işleminden bağımsız olarak hemen) alır; boş yuva kalmadıysa
reddedilir. Paralel istekler aynı yuvayı paylaşamaz ve reddedilen deneme de
yuvasını tutar. Yuvalar pencere sonunda kendiliğinden düşer.

| Bütçe | Uç noktalar | Sınır |
| --- | --- | --- |
| `sudo` | `sudo/password`, `sudo/totp` | 10 / 15 dk |
| `sudo-passkey` | `sudo/webauthn/verify` | 10 / 15 dk |
| `sudo-options` | `sudo/webauthn/options` | 30 / 15 dk |
| `totp-confirm` | `credentials/totp/confirm` | 10 / 15 dk |
| `mutation` | `identity/name`, `identity/username`, `credentials/password`, `credentials/totp/setup`, `credentials/webauthn/options`, `credentials/webauthn/register`, `DELETE credentials/{id}` | 30 / 15 dk |

`sudo/webauthn/options` (bearer'la, sudo'suz) kendi `sudo-options` bütçesinden
sayılır. Passkey assertion'ı tahmin edilemez; bu yüzden `sudo/webauthn/verify`
parola/TOTP'nin `sudo` bütçesini paylaşmaz, kendi `sudo-passkey` bütçesinden
(aynı boyut) sayılır. Keycloak 26.7.4'ün brute-force koruyucusu yalnız
`password`, `otp` ve kurtarma kodu kategorilerini sayar: başarısız bir passkey
denemesi realm brute-force sayacını **artırmaz**, başarılı olanı da sayacı
temizlemez. Passkey denemelerinin tek kısıtı `sudo-passkey` bütçesidir; kilitli
bir hesabın (parola/TOTP denemelerinden) passkey ile de sudo alamaması ise
sürer, çünkü kilit **kontrolü** her kanıttan önce yapılır.

`GET identity` sınırlanmaz: kimliği doğrulanmış okuma ucuzdur ve her okumada
küme önbelleğine yazmak gereksizdir. Kimlik bilgisi tahminine karşı asıl
güvenlik sınırı brute-force korumasıdır; hız sınırı onu tamamlar.

## Hata biçimi (RFC 7807)

Her hata `application/problem+json`:

```json
{
  "type": "tag:yildizskylab.com,2026:sky-account:password_policy",
  "title": "New password violates the password policy",
  "status": 400,
  "detail": "Geçersiz Şifre: En az 12 karakter uzunluğunda olmalı.",
  "code": "password_policy",
  "policy": "invalidPasswordMinLengthMessage",
  "params": [12]
}
```

`code` İngilizce ve sabittir (BFF buna göre dallanır), `detail` kişiye
gösterilebilecek Türkçe cümledir. Parola politikası mesajları Keycloak'ın giriş
temasındaki Türkçe mesaj paketinden üretilir.

| HTTP | `code` | Ek alanlar | Anlam |
| --- | --- | --- | --- |
| 401 | `unauthorized` | — | Bearer yok, geçersiz, başka istemciye ait, oturum yok |
| 401 | `sudo_required` | — | Sudo token yok, geçersiz, başka oturuma ait |
| 401 | `sudo_expired` | — | Sudo token'ın süresi doldu |
| 401 | `invalid_credentials` | — | Parola veya doğrulama kodu yanlış |
| 401 | `user_temporarily_locked` | — | Brute-force geçici kilidi |
| 401 | `user_disabled` | — | Kalıcı kilit / devre dışı hesap |
| 400 | `invalid_request` | `field?` | Gövde JSON değil, bilinmeyen alan, tip/uzunluk hatası, eksik alan |
| 400 | `password_not_configured` | — | Hesapta parola yok (sudo/password) |
| 400 | `totp_not_configured` | — | Hesapta OTP yok (sudo/totp) |
| 400 | `passkey_not_registered` | — | Hesapta passkey yok (sudo/webauthn) |
| 400 | `webauthn_challenge_expired` | — | Kayıtlı passkey challenge yok, kullanılmış ya da 5 dakikayı geçmiş |
| 400/401 | `webauthn_invalid` | — | Attestation/assertion doğrulanamadı (kayıt 400, sudo 401) |
| 400/401 | `webauthn_origin_not_allowed` | — | Ceremony izin verilmeyen bir origin'den (kayıt 400, sudo 401) |
| 400 | `password_policy` | `policy`, `params` | Yeni parola realm politikasına uymuyor |
| 400 | `password_rejected` | — | Keycloak parolayı reddetti (ör. geçmiş politikası) |
| 400 | `totp_setup_expired` | — | Kurulum tanıtıcısı yok, kullanılmış ya da 10 dakikayı geçmiş |
| 400 | `invalid_totp_code` | — | Kurulum onay kodu yanlış |
| 400 | `invalid_name` | `field` | Ad/soyad boş, 64 karakterden uzun ya da yasak karakter içeriyor |
| 400 | `invalid_username` | `field` | `^[a-z0-9._]{3,30}$` desenine uymuyor |
| 403 | `name_locked` | — | Doğrulanmış YTÜ hesabı adını değiştiremez |
| 404 | `credential_not_found` | — | Kimlik bilgisi yok, kişiye ait değil ya da silinemez türde (parola) |
| 409 | `duplicate_label` | — | Aynı adda OTP ya da passkey zaten var |
| 409 | `passkey_already_registered` | — | Bu passkey (credential id) zaten hesabında kayıtlı |
| 409 | `username_taken` | — | Kullanıcı adı başkasında |
| 409 | `username_cooldown` | `retryAfter`, `availableAt` + `Retry-After` | 14 gün dolmadı |
| 429 | `rate_limited` | `retryAfter` + `Retry-After` | Hız sınırı |
| 503 | `unmanaged_attributes_enabled` | — | Realm User Profile'ı `unmanagedAttributePolicy=ENABLED`; değişiklikler kapalı (okuma açık) |
| 503 | `webauthn_not_configured` | — | Keycloak passwordless WebAuthn sağlayıcısı yok (web-authn özelliği kapalı) |
| 500 | `internal_error` | — | Beklenmeyen hata (işlem geri alınır) |

`Content-Type: application/json` olmayan gövdeli istekler RESTEasy tarafından
`415` ile (problem biçimi olmadan) reddedilir.

## Uç noktalar

Gövdeler UTF-8 JSON, en fazla 8 KB (passkey ceremony uçları
`credentials/webauthn/register`, `sudo/webauthn/verify` için 64 KB); bilinmeyen
alanlar reddedilir. Başarılı yanıtlar `Cache-Control: no-store` taşır. Zamanlar
ISO-8601 UTC.

### Passkey ceremony akışı (tarayıcı tarafı)

WebAuthn ceremony'si `my.` origin'inde tarayıcıda çalışır; SPI hiçbir zaman
`navigator.credentials` çağırmaz, yalnız seçenekleri üretir ve sonucu doğrular:

1. BFF (`my.`) sudo aldıktan sonra `POST credentials/webauthn/options` (kayıt) ya
   da bearer'la `POST sudo/webauthn/options` (sudo) çağırır ve dönen JSON'u
   tarayıcıya sunar.
2. Tarayıcı JSON'un base64url alanlarını (`challenge`, `user.id`,
   `excludeCredentials[].id` / `allowCredentials[].id`) `ArrayBuffer`'a çevirir,
   `navigator.credentials.create({publicKey})` ya da `.get({publicKey})` çalıştırır.
3. Tarayıcı sonucu (`PublicKeyCredential`) base64url alanlarla JSON'a çevirip
   (örn. `PublicKeyCredential.toJSON()` ya da alanları elle) BFF'ye verir; BFF
   olduğu gibi `POST credentials/webauthn/register` (etiket ekleyerek) ya da
   `POST sudo/webauthn/verify`'e iletir.

Tüm ikili alanlar **base64url** (RFC 4648 §5, padding'siz üretilir, padding'li de
kabul edilir). `id` ile `rawId` eşit olmalıdır. SPI'nin CORS'u yoktur; seçenekleri
tarayıcıya ve sonucu SPI'ye taşıyan BFF'dir.

### `GET identity`

```json
{
  "sub": "11111111-1111-4111-8111-111111111111",
  "username": "account-fixture",
  "firstName": "Ada",
  "lastName": "Lovelace",
  "email": "ada@std.yildiz.edu.tr",
  "emailVerified": true,
  "schoolEmail": "ada@std.yildiz.edu.tr",
  "personalEmail": "ada@example.com",
  "primary": "school",
  "verifiedYtu": true,
  "nameLocked": true,
  "usernameChangeAvailableAt": null,
  "credentials": {
    "password": true,
    "totp": [{ "id": "…", "type": "otp", "label": "Telefon", "createdAt": "2026-09-21T13:10:41.130Z" }],
    "passkeys": [{ "id": "…", "type": "webauthn-passwordless", "label": "MacBook", "createdAt": "…", "transports": ["internal", "hybrid"] }]
  }
}
```

- `schoolEmail` / `personalEmail`: `schoolEmail` / `personalEmail` kullanıcı
  öznitelikleri (boşsa `null`).
- `primary`: Keycloak `email` alanı okul adresine eşitse `school`, kişisel adrese
  eşitse `personal`, ikisine de eşit değilse `none` (büyük/küçük harf duyarsız).
- `verifiedYtu`: YTÜ Microsoft IdP'sine (varsayılan alias `OBS`) federated identity
  bağlantısı var. `nameLocked == verifiedYtu`.
- `usernameChangeAvailableAt`: kullanıcı adı en son 14 günden kısa süre önce
  değiştiyse bir sonraki izinli an; değilse `null`.
- `credentials.password`: Keycloak'ın `isConfiguredFor("password")` sonucu.
  `totp`: `otp` türündeki, `passkeys`: yalnız `webauthn-passwordless` türündeki
  saklı kimlik bilgileri (tek credential akışından süzülür; etiket kullanıcı
  etiketi, `createdAt` Keycloak oluşturma zamanı). Her passkey ayrıca, kayıt
  sırasında tarayıcının bildirdiği taşıyıcıları (`transports`, sıralı;
  bilinmiyorsa boş dizi) taşır. Eski iki-faktör `webauthn` kimlik bilgileri
  passkey değildir: listelenmez, sudo'da ve `excludeCredentials`/`allowCredentials`
  listelerinde kullanılmaz; yalnız `DELETE credentials/{id}` ile silinebilir.

### `PATCH identity/name` — sudo gerekmez

İstek `{"firstName": "Ada", "lastName": "Lovelace"}`; değerler normalleştirilir
(sıfır genişlikli/biçim karakterleri atılır, NBSP dahil her boşluk türü tek
boşluğa indirilir, kırpılır), boş olamaz, en fazla 64 karakter, Keycloak'ın
`person-name-prohibited-characters` kuralı uygulanır. `verifiedYtu` ise
`403 name_locked`. Yanıt `200` + güncel
`identity`. Olay: `UPDATE_PROFILE` (`previous_first_name`, `updated_first_name`,
`previous_last_name`, `updated_last_name`, `context=ACCOUNT`).

### `POST identity/username` — sudo gerekir

İstek `{"username": "Ada.Lovelace"}`; küçük harfe çevrilir ve
`^[a-z0-9._]{3,30}$` desenine uymalıdır. Aynı kullanıcı adı ise `200` (işlem
yok). Başka kişideyse `409 username_taken` (ön kontrol; iki kişi aynı anda
aynı adı isterse yazma anında veritabanına yürütülür ve kaybeden yine
`409 username_taken` alır, işlem geri alınır; her iki durumda
`UPDATE_PROFILE_ERROR error=username_in_use` olayı düşer); son değişiklik 14
günden yeni ise `409 username_cooldown`. Başarıda `200` + güncel `identity`,
`usernameChangedAt` özniteliği (ISO-8601 UTC) yazılır, olay `UPDATE_PROFILE`
(`previous_username`, `updated_username`). Realm `editUsernameAllowed=false`
kalır: Account REST ve Admin REST kullanıcı adını değiştiremez, yalnız bu uç
nokta değiştirir.

### `POST sudo/password`

İstek `{"password": "…"}`. Parola tanımlı değilse `400 password_not_configured`.
Brute-force kilidi kontrol edilir, ardından
`user.credentialManager().isValid(UserCredentialModel.password(...))`. Yanıt:

```json
{ "sudoToken": "<jwt>", "expiresAt": "2026-09-21T13:15:18Z" }
```

### `POST sudo/totp`

İstek `{"code": "123456"}` (4-10 rakam). Kişinin saklı `otp` kimlik bilgilerinden
biri realm OTP politikasıyla kodu doğrularsa aynı yanıt döner. Keycloak'ın kod
yeniden kullanım koruması geçerlidir: aynı kod pencere içinde ikinci kez kabul
edilmez (`401 invalid_credentials`).

### `POST sudo/webauthn/options`

Gövde yok, sudo gerekmez (yalnız bearer; kendi `sudo-options` bütçesi). Kişinin
passwordless passkey'leri yoksa `400 passkey_not_registered`. Yanıt, tarayıcının
`navigator.credentials.get()` çağrısı için assertion seçenekleridir; `challenge`
kişiye ve orduma bağlı olarak `SingleUseObjectProvider`'da 5 dakika tutulur:

```json
{
  "challenge": "…",
  "rpId": "yildizskylab.com",
  "allowCredentials": [{ "type": "public-key", "id": "…", "transports": ["internal"] }],
  "userVerification": "required",
  "timeout": 90000
}
```

`rpId` passwordless politikasının RP ID'sidir (boşsa istek host'una düşer);
`allowCredentials` kişinin passkey'lerinin credential id'leri (base64url) ve
saklıysa taşıyıcılarıdır; `userVerification` her zaman `required`'dır (sudo
politikadan bağımsız UV ister, bkz. `sudo/webauthn/verify`); `timeout`
politikanın `createTimeout` saniyesinin milisaniyesidir (`0` → alan yok).

### `POST sudo/webauthn/verify`

Tarayıcının `navigator.credentials.get()` döndürdüğü `PublicKeyCredential`
JSON'u: `{"id","rawId","type":"public-key","response":{"clientDataJSON",
"authenticatorData","signature","userHandle?"},"clientExtensionResults?"}`
(base64url alanlar; `id == rawId`). Doğrulama Keycloak'ın passwordless
`WebAuthnAuthenticationManager` yolundadır (`user.credentialManager().isValid`):
origin realm origin'i + politikanın `extraOrigins`'i, RP ID, challenge (atomik
tüketilir), **kullanıcı doğrulaması (UV) politikadan bağımsız olarak her zaman
zorunlu** — sudo cihaza sahipliği değil kişiyi kanıtlamalıdır, politika
`preferred` dese bile UV bayrağı olmayan assertion reddedilir —, imza ve **imza
sayacı** (gerilerse reddedilir, ilerlerse güncellenir). Başarıda parola/TOTP ile
aynı yanıt (`sudoToken`, `expiresAt`) döner; `amr` `["hwk","user"]`,
`method=passkey`. Başarısız deneme `sudo-passkey` bütçesinden (10 / 15 dk,
parola/TOTP'den ayrı) düşer ve `401 webauthn_invalid` (ya da başka origin için
`401 webauthn_origin_not_allowed`) döner; realm brute-force sayacını
**artırmaz** (Keycloak bu kategoriyi saymaz) ama mevcut bir kilit yine
`401 user_temporarily_locked` / `401 user_disabled` verir. Kayıtlı challenge
yoksa `400 webauthn_challenge_expired`. Doğrulama dışı bir hata (ör. sayaç
güncellemesinde veritabanı hatası) `500 internal_error` ile işlemi geri alır,
reddedilmiş assertion gibi görünmez.

### `POST credentials/password` — sudo gerekir

İstek `{"newPassword": "…", "logoutOtherSessions": true}` (ikisi de zorunlu).
Sıra: realm parola politikası (`PasswordPolicyManagerProvider.validate`) →
`updateCredential(UserCredentialModel.password(newPassword, false))` →
`logoutOtherSessions` ise mevcut `sid` dışındaki tüm çevrimiçi ve çevrimdışı
oturumlara `AuthenticationManager.backchannelLogout`. Yanıt `204`. Olaylar:
`UPDATE_CREDENTIAL` (`credential_type=password`) ve `UPDATE_PASSWORD`; kapatılan
her oturum için `LOGOUT` (`reason=sky_account_password_change`). Hatalarda
`UPDATE_CREDENTIAL_ERROR` / `UPDATE_PASSWORD_ERROR` (`error=password_rejected`,
`reason=<politika anahtarı>`).

### `POST credentials/totp/setup` — sudo gerekir

Gövde yok. `HmacOTP.generateSecret(20)` ile üretilen sır 10 dakika boyunca
Keycloak'ın single-use object deposunda, kişiye ve rastgele 256 bitlik
tanıtıcıya bağlı tutulur. Yanıt:

```json
{
  "setupHandle": "ZW9faHuWMziZ8fm_cttFxSmAMYRW82GJo8I-FBhR468",
  "secret": "OR4DE4DRNFXDKZTQJZUFMSBSKR4G2Z3B",
  "otpauthUri": "otpauth://totp/SKY%20LAB:ada?secret=…&digits=6&algorithm=SHA1&issuer=SKY%20LAB&period=30",
  "expiresAt": "2026-09-21T13:20:18Z",
  "policy": { "type": "totp", "algorithm": "SHA1", "digits": 6, "period": 30 }
}
```

`secret` elle giriş için Base32 biçimidir; `otpauthUri` realm OTP politikasıyla
(`OTPPolicy.getKeyURI`) üretilir, QR'ı BFF çizer. Sır yanıt dışında hiçbir yere
yazılmaz.

### `POST credentials/totp/confirm` — sudo gerekir

İstek `{"setupHandle": "…", "code": "123456", "label": "Telefon"}` (`label`
1-64 karakter, zorunlu). Kod realm politikasıyla sırra karşı doğrulanır
(`CredentialValidation.validOTP`); yanlış kod `400 invalid_totp_code` döner ve
tanıtıcı geçerli kalır (kişi yeniden dener; deneme bütçesi 10 / 15 dk). Doğru
kodda tanıtıcı tek seferlik tüketilir, kimlik bilgisi
`OTPCredentialModel.createFromPolicy` + `CredentialHelper.createOTPCredential` ile
oluşturulur (onay kodu kullanılmış sayılır). Yanıt `201`:

```json
{ "id": "…", "type": "otp", "label": "Telefon", "createdAt": "2026-09-21T13:10:41.130Z" }
```

Olaylar: `UPDATE_CREDENTIAL` (`credential_type=otp`, `credential_user_label`) ve
`UPDATE_TOTP`. Aynı adda OTP varsa `409 duplicate_label`.

### `POST credentials/webauthn/options` — sudo gerekir

Gövde yok. Yanıt, tarayıcının `navigator.credentials.create()` çağrısı için
realm **passwordless** politikasından üretilen `PublicKeyCredentialCreationOptions`
JSON'udur; `challenge` kişiye ve orduma bağlı 5 dakika `SingleUseObjectProvider`'da
tutulur:

```json
{
  "rp": { "id": "yildizskylab.com", "name": "SKY LAB" },
  "user": { "id": "<base64url(userId)>", "name": "ada.lovelace", "displayName": "Ada Lovelace" },
  "challenge": "<base64url(32 bayt)>",
  "pubKeyCredParams": [{ "type": "public-key", "alg": -7 }, { "type": "public-key", "alg": -257 }],
  "timeout": 90000,
  "excludeCredentials": [{ "type": "public-key", "id": "…", "transports": ["internal"] }],
  "authenticatorSelection": { "residentKey": "required", "requireResidentKey": true, "userVerification": "required" },
  "attestation": "none",
  "extensions": { "credProps": true }
}
```

Alanlar Keycloak'ın `WebAuthnRegister` (passwordless) mantığını birebir izler:
`rp.id` politikanın RP ID'si (boşsa istek host'una düşer), `rp.name` politikanın
RP entity adı; `user.id` Keycloak'ın kullandığı kodlama (`base64url(userId bayt)`);
`pubKeyCredParams` politikanın imza algoritmaları (COSE); `excludeCredentials`
**her zaman** kişinin mevcut passwordless passkey'leridir (Keycloak bunu yalnız
`avoidSameAuthenticatorRegister` açıkken yapar; aynı authenticator'ı ikinci kez
kaydetmenin kişiye yararı olmadığından burada bayrağa bakılmaz — daha katı);
`authenticatorSelection.residentKey` /
`userVerification` politikadan (`authenticatorAttachment` yalnız politika
belirlediyse); `attestation` politikadan (belirtilmemişse alan yok); `timeout`
`createTimeout` saniyesinin milisaniyesi (`0` → alan yok); `extensions.credProps`
her zaman `true`.

### `POST credentials/webauthn/register` — sudo gerekir

Tarayıcının `navigator.credentials.create()` döndürdüğü `PublicKeyCredential`
JSON'u + zorunlu `label`: `{"id","rawId","type":"public-key","response":
{"clientDataJSON","attestationObject","transports?"},"authenticatorAttachment?",
"clientExtensionResults?","label"}` (base64url alanlar; `id == rawId`). `label`
adlarla aynı normalizasyondan geçer (sıfır genişlikli/biçim karakterleri atılır,
boşluklar tek boşluğa iner, kırpılır), boş olamaz, en fazla 64 karakter; aynı
adda passkey varsa `409 duplicate_label`.

Doğrulama Keycloak'ın `WebAuthnRegister` (passwordless) yolunu birebir izler:
webauthn4j `WebAuthnRegistrationManager` (politikanın attestation formatı,
Keycloak truststore'unun sertifika zinciri, politikada AAGUID yoksa self
attestation), origin = realm origin'i + politikanın `extraOrigins`'i, RP ID,
challenge (atomik tüketilir), kullanıcı doğrulaması (politika `required` ise),
kabul edilen AAGUID'ler ve `authenticatorAttachment` uyumu; ayrıca zaten kayıtlı
bir credential id `409 passkey_already_registered` ile reddedilir
(`avoidSameAuthenticatorRegister` bayrağından bağımsız). Ardından passkey
`WebAuthnCredentialModel.create(TYPE_PASSWORDLESS, …)` ile
`WebAuthnPasswordlessCredentialProvider` üzerinden saklanır. Yanıt `201`:

```json
{ "id": "…", "type": "webauthn-passwordless", "label": "MacBook", "createdAt": "…", "transports": ["internal", "hybrid"] }
```

Olay: `UPDATE_CREDENTIAL` (`credential_type=webauthn-passwordless`,
`credential_user_label`, `public_key_credential_id`, `public_key_credential_label`,
`public_key_credential_aaguid`). Doğrulama başarısızsa `400 webauthn_invalid`,
başka origin `400 webauthn_origin_not_allowed`, kayıtlı challenge yoksa
`400 webauthn_challenge_expired`, aynı credential zaten varsa
`409 passkey_already_registered`; hepsi `UPDATE_CREDENTIAL_ERROR`
(`error=invalid_registration`) bırakır.

### `DELETE credentials/{id}` — sudo gerekir

Yalnız kişinin kendi `otp`, `webauthn-passwordless` ve (listelenmeyen, eski
iki-faktör) `webauthn` kimlik bilgileri; parola asla. Bulunamayan, başkasına ait ya da silinemez türdeki id
`404 credential_not_found`. Yanıt `204`. Olaylar: `REMOVE_CREDENTIAL`
(`credential_type`, `selected_credential_id`, `credential_user_label`), OTP için
ayrıca `REMOVE_TOTP`.

## Yapılandırma

| Ayar | Kaynak | Varsayılan |
| --- | --- | --- |
| YTÜ IdP alias'ı | `--spi-realm-restapi-extension-sky-account-ytu-idp-alias` / `KC_SPI_REALM_RESTAPI_EXTENSION_SKY_ACCOUNT_YTU_IDP_ALIAS`, yoksa `SKY_ACCOUNT_YTU_IDP_ALIAS` ortam değişkeni | `OBS` |

Alias `^[A-Za-z0-9._-]{1,64}$` desenine uymazsa Keycloak açılışta durur.

## Güvenlik notları ve sınırlar

- Parola, kod, sır, sudo token ve bearer token hiçbir günlüğe yazılmaz; JSON
  ayrıştırma hataları gövdeyi yansıtmaz; entegrasyon testi Keycloak günlüklerini
  bu değerler için tarar.
- Hata yanıtları `Response` olarak döner (istisna fırlatılmaz), böylece
  Keycloak'ın hata eşleyicisi işlemi geri almaz: olaylar başarısız denemede
  de kalıcıdır (hız yuvaları zaten işlemden bağımsızdır). `5xx` işlemi geri alır.
- Kapalı-güvenli User Profile denetimi: her değişiklik ucu önce realm'in
  `unmanagedAttributePolicy` değerine bakar; `ENABLED` ise (kişi Account REST
  ile `usernameChangedAt`, `schoolEmail`, `personalEmail` değerlerini
  değiştirebilirdi) `503 unmanaged_attributes_enabled` döner, okumalar sürer.
  Yapılandırma okunamıyorsa da aynı yanıt verilir.
- Sudo token tek kullanımlık değildir (5 dakikalık pencere, `sid` bağlı) ve
  Keycloak dışında doğrulanamaz (iç HMAC anahtarı).
- Federasyon (LDAP vb.) yoktur; OTP doğrulaması yalnız Keycloak'ta saklı OTP
  kimlik bilgilerine bakar, federated OTP'ler `totp_not_configured` verir.
- Passkey doğrulaması Keycloak'ın kendi webauthn4j makinesidir
  (`WebAuthnRegistrationManager`, `WebAuthnPasswordlessCredentialProvider`,
  passwordless `WebAuthnPolicy`); SPI kripto uygulamaz, yalnız Keycloak'ın
  `WebAuthnRegister` / `WebAuthnAuthenticator` yollarını birebir yansıtır ve
  kapalı-güvenli davranır (doğrulanamayan her şey reddedilir). Challenge'lar
  `SingleUseObjectProvider`'da kişi+oturuma bağlı 5 dakikalıktır ve doğrulamadan
  önce atomik olarak tüketilir, bu yüzden bir challenge yeniden oynatılamaz.
  RP ID ve izinli origin'ler realm passwordless politikasından gelir; passkey'in
  `e.` girişinde de çalışması RP ID'nin her SKY LAB origin'inde aynı olmasına
  bağlıdır (reconcile **K2**: RP ID `yildizskylab.com`, extra origin
  `https://my.yildizskylab.com`). Sınır: imza sayacı yalnız authenticator
  bildirdiğinde koruma sağlar (Apple Secure Enclave gibi hep sıfır bildiren
  authenticator'lar için klonlama tespiti Keycloak'ta olduğu gibi devre dışıdır);
  `authenticatorAttachment` istemci bildirimidir, kriptografik değildir.
- Keycloak'ta sudo'ya özel bir olay türü yoktur; başarılı kanıt genel
  `CUSTOM_REQUIRED_ACTION` olayıyla (`action=sky-sudo`, `method`) kaydedilir.
- `usernameChangedAt`, `schoolEmail`, `personalEmail` model düzeyinde okunup
  yazılır; User Profile'da tanımlı olmadıkları realm'de Admin REST'ten görünmez
  (yönetilmeyen öznitelik politikası kapalıyken salt okunur kalır, silinmez).
  Reconcile (K2) bu öznitelikleri User Profile'a `user: view, admin: edit`
  olarak eklemelidir; `unmanagedAttributePolicy=ENABLED` yapılırsa API
  değişiklikleri `503` ile durdurur.
