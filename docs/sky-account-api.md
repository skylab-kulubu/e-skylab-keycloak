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

Aynı token'daki `sky_authorization.<istemci>.roles` claim'ini (Hesap
Merkezi'nin yetki görünümü) bu SPI'daki `sky-authorization-mapper`
(`com.skylab.account.SkyAuthorizationMapper`) üretir; uzlaştırıcı onu
`account-center-account-api` kapsamına bağlar. Mapper kişinin etkin rol
eşlemelerini (doğrudan, grup, bileşik) kendisi okur, yalnız istemci rollerini
alır, Keycloak'ın yönetim istemcilerini (`realm-management`, `broker`,
`account`, `account-console`, `security-admin-console`, `admin-cli`, `*-realm`)
dışarıda bırakır, yalnız access token ve introspection'a yazar (ID token ve
userinfo'da yoktur), 64 istemci / istemci başına 256 rol sınırını aşanı tek
bir `WARN` ile atar ve rol yoksa claim'i yazmaz. Bu yol, `account-center`
istemcisinde `fullScopeAllowed` açmadan bütün uygulama rollerini listelemek
içindir: Keycloak Admin REST bearer token'ı `user.hasRole && client.hasScope`
ile yetkilendirir, tam kapsam açık olsaydı `realm-management` rolü olan bir
kişinin `my.` token'ı Admin REST'te geçerli olurdu. Claim salt okunur bir
görünümdür; sky-account API yetki kararlarında onu kullanmaz.

## Sudo modu

Hassas işlemler (`credentials/*`, `identity/username`, `email/change-request`,
`email/primary`, `DELETE email/personal`) taze bir **sudo token** ister.
`email/confirm` sudo istemez: postadaki kod adresi, kişinin kendi oturumu da kişiyi
kanıtlar (bkz. `POST email/confirm`). Kişi parolasını, doğrulama uygulaması kodunu ya da passkey'ini
`POST sudo/password` / `POST sudo/totp` / `POST sudo/webauthn/verify` ile kanıtlar;
yanıt bir sudo token verir. Bunların hiçbiri olmayan kişi (bugün çoğu YTÜ hesabı)
Keycloak'ta yeniden giriş yapar (Microsoft) ve BFF, callback'te aldığı taze ID
token'ı `POST sudo/authentication` ile kanıt olarak sunar. BFF sudo token'ı
sonraki isteklerde `X-Sky-Sudo: <sudoToken>` başlığıyla gönderir.

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
| `amr` | `["pwd"]`, `["otp"]`, passkey için `["hwk","user"]`, taze giriş kanıtı için `["idp"]` (ID token kendi `amr` claim'ini taşıyorsa o değerler) |
| `jti`, `iat`, `nbf`, `exp` | `exp = iat + 300`; taze giriş kanıtında `exp = auth_time + 300` (hiçbir zaman `iat + 300`'den geç değil) |

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
`action=sky-sudo`, `method=password|totp|passkey|authentication` (passkey için
ayrıca imzalayan kimlik bilgisinin `public_key_credential_id` değeri; taze giriş
kanıtı için doğrulanan ID token'ın `auth_time` değeri).

Brute-force koruması realm'de açıksa (`bruteForceProtected`) her parola ve TOTP
sudo denemesi Keycloak'ın `BruteForceProtector` servisine bir giriş denemesi
olarak bildirilir (passkey denemeleri de bildirilir ama Keycloak bu kategoriyi
saymaz; bkz. Hız sınırları):
kilitli hesap kanıt vermeden `401 user_temporarily_locked` / `401 user_disabled`
alır, başarısız deneme `LOGIN_ERROR` (`error=invalid_user_credentials`,
`auth_method=sky-account-sudo`) olayı üretir ve sayacı artırır, başarılı deneme
sayacı temizler. Realm'de koruma kapalıysa yalnız hız sınırı uygulanır; uzantı
bu durumu açılışta (ve sonradan içe aktarılan realm'ler için ilk sudo
denemesinde) tek bir `WARN` günlüğüyle bildirir. Uzlaştırıcı
(`config/reconcile-account-center.sh`, `config/account-center-realm-security.json`)
brute-force korumasını (10 deneme, 60 sn artan bekleme, en çok 15 dk, 12 saat
sıfırlama, kalıcı kilit yok) ve parola politikasını
(`length(8) and notUsername and notEmail`) her koşuda açık tutar; bu API o
ayarları olduğu gibi kullanır.

## Hız sınırları

Kullanıcı başına, sabit 15 dakikalık pencere, Keycloak'ın single-use object
deposunda (küme genelinde) tutulur; aşımda `429 rate_limited` + `Retry-After`.
Her istek pencerenin `1..N` yuvalarından birini `putIfAbsent` ile (Infinispan'da
atomik, istek işleminden bağımsız olarak hemen) alır; boş yuva kalmadıysa
reddedilir. Paralel istekler aynı yuvayı paylaşamaz ve reddedilen deneme de
yuvasını tutar. Yuvalar pencere sonunda kendiliğinden düşer.

| Bütçe | Uç noktalar | Sınır |
| --- | --- | --- |
| `sudo` | `sudo/password`, `sudo/totp`, `sudo/authentication` | 10 / 15 dk |
| `sudo-passkey` | `sudo/webauthn/verify` | 10 / 15 dk |
| `sudo-options` | `sudo/webauthn/options` | 30 / 15 dk |
| `totp-confirm` | `credentials/totp/confirm` | 10 / 15 dk |
| `email-change` | `email/change-request` (sudo kanıtından sonra) | 3 / 1 saat |
| `mutation` | `identity/name`, `identity/username`, `credentials/password`, `credentials/totp/setup`, `credentials/webauthn/options`, `credentials/webauthn/register`, `DELETE credentials/{id}`, `email/change-request`, `email/confirm`, `email/primary`, `DELETE email/personal` | 30 / 15 dk |

`sudo/webauthn/options` (bearer'la, sudo'suz) kendi `sudo-options` bütçesinden
sayılır. Passkey assertion'ı tahmin edilemez; bu yüzden `sudo/webauthn/verify`
parola/TOTP'nin `sudo` bütçesini paylaşmaz, kendi `sudo-passkey` bütçesinden
(aynı boyut) sayılır. Keycloak 26.7.4'ün brute-force koruyucusu yalnız
`password`, `otp` ve kurtarma kodu kategorilerini sayar: başarısız bir passkey
denemesi realm brute-force sayacını **artırmaz**, başarılı olanı da sayacı
temizlemez. Passkey denemelerinin tek kısıtı `sudo-passkey` bütçesidir; kilitli
bir hesabın (parola/TOTP denemelerinden) passkey ile de sudo alamaması ise
sürer, çünkü kilit **kontrolü** her kanıttan önce yapılır.

`sudo/authentication` kimlik bilgisi sınamaz, bu yüzden brute-force koruyucusuna
bildirilmez; denemeleri yalnız `sudo` bütçesinden düşer (ID token realm anahtarıyla
imzalıdır, tahmin edilemez; bütçe kötüye kullanımı sınırlar).

`email/change-request` kimsenin henüz kanıtlamadığı bir adrese posta gönderir; bu
yüzden `mutation` bütçesinin yanında kendi çok daha dar `email-change` bütçesinden
(kişi başına saatte 3) de sayılır. Dar bütçe **sudo doğrulandıktan sonra** düşülür:
sudo'suz bir istek kişinin saatlik hakkını yakamaz, yalnız `mutation` yuvasını
harcar. Sudo'lu bir istekte biçimi bozuk ya da başkasına ait bir adres de bir yuva
harcar: bütçe, gönderilen posta sayısını değil denemeyi sınırlar.

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
| 401 | `authentication_stale` | — | ID token doğrulandı ama girişin (`auth_time`) üzerinden 300 saniyeden fazla geçti (sudo/authentication) |
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
| 400 | `invalid_email_code` | `attemptsLeft` | E-posta doğrulama kodu yanlış; `attemptsLeft` 0 ise kod öldü, yeni kod istenmeli |
| 404 | `no_pending_email_change` | — | Kişinin bekleyen bir e-posta değişikliği yok: hiç istenmedi, kullanıldı, süresi doldu ya da deneme hakkı bitti |
| 409 | `duplicate_label` | — | Aynı adda OTP ya da passkey zaten var |
| 409 | `passkey_already_registered` | — | Bu passkey (credential id) zaten hesabında kayıtlı |
| 409 | `username_taken` | — | Kullanıcı adı başkasında |
| 409 | `email_taken` | — | E-posta adresi başka kişide (birincil, okul ya da kişisel) |
| 409 | `email_not_verified` | — | Kişisel adres var ama doğrulanmadı; birincil yapılamaz |
| 409 | `no_fallback_email` | — | Kişisel adres birincil ve geri düşülecek okul adresi yok |
| 409 | `username_cooldown` | `retryAfter`, `availableAt` + `Retry-After` | 14 gün dolmadı |
| 429 | `rate_limited` | `retryAfter` + `Retry-After` | Hız sınırı |
| 503 | `unmanaged_attributes_enabled` | — | Realm User Profile'ı `unmanagedAttributePolicy=ENABLED`; değişiklikler kapalı (okuma açık) |
| 503 | `webauthn_not_configured` | — | Keycloak passwordless WebAuthn sağlayıcısı yok (web-authn özelliği kapalı) |
| 503 | `email_not_sent` | — | Doğrulama postası gönderilemedi (realm SMTP kapalı ya da erişilemiyor); bekleyen değişiklik silinir |
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
  "personalEmailVerified": true,
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
- `personalEmailVerified`: kişisel adres var **ve** bu uzantının yazdığı
  `personalEmailVerifiedAt` (ISO-8601 UTC) damgası okunabiliyor. Özniteliğe doğrudan
  (Admin REST, içe aktarma) yazılmış bir adres doğrulanmış sayılmaz ve birincil
  yapılamaz.
- `primary`: Keycloak `email` alanı okul adresine eşitse `school`, kişisel adrese
  eşitse `personal`, ikisine de eşit değilse `none` (büyük/küçük harf duyarsız).
- `verifiedYtu`: YTÜ Microsoft IdP'sine (varsayılan alias `OBS`) federated identity
  bağlantısı var. `nameLocked == verifiedYtu`.
- `usernameChangeAvailableAt`: kullanıcı adı en son 14 günden kısa süre önce
  değiştiyse bir sonraki izinli an; değilse `null`.
- Üçü de boşsa (`password == false`, `totp == []`, `passkeys == []`) kişi
  `my.` içinde kanıt veremez; BFF Microsoft ile yeniden girişe yönlendirir ve
  callback'ten sonra `POST sudo/authentication` ile sudo token alır.
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

### `POST sudo/authentication`

Parolası, doğrulama uygulaması ve passkey'i olmayan kişinin yolu. İstek
`{"idToken": "<jwt>"}`: BFF'nin, kişiyi Keycloak'ta yeniden giriş yaptırdığı
(`prompt=login`, Microsoft) OIDC callback'inde aldığı ID token; bearer aynı
oturumun access token'ıdır. Kimlik bilgisi sınanmaz, brute-force koruyucusu
devreye girmez; deneme `sudo` bütçesinden düşer.

Doğrulama (`AuthenticationProofs.verify`), Keycloak'ın kendi token doğrulaması
(`TokenVerifier`) ile:

- başlık `alg` realm'in `account-center` ID token'ları için kullandığı imza
  algoritması (`session.tokens().signatureAlgorithm(ID)`; `none`, HMAC ya da
  başka bir algoritma reddedilir), `kid` zorunlu; imza o `kid`'li etkin ya da
  pasif realm imza anahtarıyla (`SignatureProvider.verifier(kid)`) doğrulanır,
  devre dışı ya da bilinmeyen anahtar reddedilir;
- `typ == "ID"`, `iss` bearer'ın `iss` değeri, `aud` **yalnız** `account-center`
  (dize ya da tek elemanlı dizi), `azp == "account-center"`, `sub` var;
- realm, istemci ve kişi "not-before" (push revocation) değerleri `iat`'i
  geçmemiş; `exp`/`nbf` Keycloak'ın `isActive` kuralıyla;
- `sub` bearer'ın `sub`'ı, `sid` bearer'ın oturumu (ID token başka bir oturumdan
  ya da başka bir kişiden olamaz);
- `iat` en fazla 30 sn ileride, `exp` var ve geçmemiş, `auth_time` var ve en
  fazla 30 sn ileride; `nonce` yok sayılır;
- son olarak `now - auth_time ≤ 300`; aşıldıysa `401 authentication_stale`.

Diğer her ret `401 sudo_required`'dır ve hangi claim'in tutmadığını söylemez;
`authentication_stale` yalnız geri kalan her şeyi geçen bir token için döner,
böylece doğrulanmayan bir token hakkında bilgi sızdırmaz. Gövde hatası
`400 invalid_request`. JWE (şifreli) ID token desteklenmez (`account-center`
istemcisi ID token'ı şifrelemez).

Başarıda parola/TOTP/passkey ile aynı yanıt (`sudoToken`, `expiresAt`), ama
pencere girişten başlar: `expiresAt = auth_time + 300` (hiçbir zaman
`now + 300`'den geç değil), `amr = ["idp"]` (ID token kendi `amr` claim'ini
taşıyorsa o değerler), `method=authentication`, olay ayrıntısı `auth_time`.
Kişinin ayrıca parolası/TOTP'si/passkey'i olması bu ucu kapatmaz: taze bir
Keycloak girişi en az onlar kadar güçlü bir kanıttır; "yalnız hiçbiri olmayanlar
Microsoft ile yeniden doğrular" kuralı ürün kararıdır ve BFF'de uygulanır.

Hesap Merkezi akışı: `GET identity` üç kimlik bilgisini de boş gösterir → BFF
`prompt=login&max_age=0` ile Keycloak'a yönlendirir (oturum `sid` korunur,
`auth_time` yenilenir) → callback `auth_time`, `sid`, `sub` bağını doğrular ve
yeni token'ları saklar → BFF `POST sudo/authentication {idToken}` çağırır →
dönen sudo token oturum kaydına `method=reauth` ile yazılır ve sonraki
`credentials/*`, `identity/username`, `email/*` isteklerinde `X-Sky-Sudo` ile
gönderilir. Token'sız `reauth` kanıtı yalnız geçiş dönemi için bir yedektir.

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

### Kişisel e-posta ve birincil adres (`email/*`)

ADR-0044: kişinin **Okul e-postası** (`schoolEmail` özniteliği) YTÜ Microsoft
bağlantısıyla gelir ve buradan hiç yazılmaz; **Kişisel e-posta** (`personalEmail`)
kişinin eklediği ve postasına gelen kodu kendi oturumunda girerek kanıtladığı adrestir; **Birincil e-posta**
ikisinden kişinin seçtiğidir ve Keycloak `email` alanının ta kendisidir. Birincili
değiştirmek `email` alanını yazmak demektir, bu yüzden token'lar, core ve SkyMail
bir sonraki token'da yeni adresi kendiliğinden görür.

Doğrulanmışlık kaydı: onay anında bu uzantı `personalEmailVerifiedAt` özniteliğine
ISO-8601 UTC damgayı yazar; `personalEmail` silindiğinde damga da silinir. Yalnız
damgalı adres birincil olabilir (`GET identity` alanı `personalEmailVerified`).

#### `POST email/change-request` — sudo gerekir

İstek `{"address": "ada@example.com", "makePrimary": false}` (`makePrimary`
isteğe bağlı, varsayılan `false`). Adres kırpılır ve `Locale.ROOT` ile küçük harfe
çevrilir (Türkçe yerelin `I` → `ı` katlaması devreye girmez), Keycloak'ın kendi
e-posta doğrulayıcısından (`EmailValidator`, realm SMTP ayarıyla birlikte) geçer.

- Adres zaten kişinin kendi birincil, okul ya da kişisel adresiyse
  `400 invalid_request` (`field: "address"`) — değiştirilecek bir şey yoktur.
- Adres başka kişideyse `409 email_taken`. Denetim üç yerde yapılır: Keycloak'ın
  kendi `getUserByEmail` araması (büyük/küçük harf duyarsız; realm
  `duplicateEmailsAllowed=false` olduğu sürece belirleyici) ve `schoolEmail` ile
  `personalEmail` özniteliklerinde birebir arama (uzantı her iki özniteliği de
  küçük harfle yazar). Yanıt adresin kimde olduğunu söylemez.
- Kişiye hiçbir şey yazılmaz. Bekleyen değişiklik **kişi başına bir tanedir**:
  Keycloak'ın `SingleUseObjectProvider` deposunda kişinin kimliğiyle anahtarlanır ve
  10 dakika tutulur; yeni bir istek öncekinin yerini alır (eski kod ölür). Değer
  `{address, makePrimary, salt, codeHash, expiresAt, attemptsLeft}`. Kodun kendisi
  depoda yoktur, yalnız tuzlu SHA-256 özeti vardır; kod yalnız postaya konur.
- Doğrulama postası Keycloak'ın kendi `EmailTemplateProvider`'ıyla, bu uzantının
  `theme-resources` içindeki `sky-personal-email-confirm.ftl` şablonuyla
  (`text/` ve `html/`) ve `skyPersonalEmailConfirm*` mesaj anahtarlarıyla (Türkçe
  ve İngilizce) gönderilir; tema değişikliği gerekmez. Posta **6 haneli kodu**,
  geçerlilik süresini ve "bu kodu kimseyle paylaşma" uyarısını taşır; link yoktur.
- Posta gönderilemezse bekleyen değişiklik hemen silinir (kod hiç çalışmaz) ve
  yanıt `503 email_not_sent` olur; `UPDATE_EMAIL_ERROR` (`error=email_send_failed`)
  üretilir (her `5xx` gibi işlem geri alınır, kayıt günlükte kalır).
- Bütçe: her istek bir `mutation` yuvası, sudo doğrulandıktan sonra ayrıca bir
  `email-change` yuvası (3 / 1 saat). Başarılı yanıt `202`:

```json
{ "expiresAt": "2026-09-21T13:45:18Z" }
```

Adres ve kod hiçbir günlük satırına yazılmaz.

#### `POST email/confirm` — sudo gerekmez, bearer gerekir

İstek `{"code": "123456"}`. Kod 6 rakamdır; kopyalanırken araya giren boşluklar
atılır, başka her biçim `400 invalid_request` (`field: "code"`) alır ve **deneme
hakkı yemez**.

Sudo istenmez: kişi kendini `change-request` için zaten kanıtladı, kod da adresi
kanıtlar. Güvenliği sağlayan bearer'dır: kod yalnız **çağıranın kendi** bekleyen
değişikliğiyle karşılaştırılır. Kodu kim okursa okusun, adresi başka bir hesaba
bağlayamaz; başka bir oturumdan denenen kod `404 no_pending_email_change` alır ve
asıl sahibinin değişikliğine dokunmaz. (Link modeli bu yüzden bırakıldı: oturumsuz
çalışan bir link, kendi hesabına kurbanın adresini ekleyen birinin, kurbana linke
bastırarak adresi kendi hesabına bağlamasına izin veriyordu. ADR-0044 güncellemesi.)

Her deneme kaydı depodan atomik olarak alır (`SingleUseObjectProvider.remove`):

- kod doğruysa kayıt geri konmaz; kod en fazla bir kez iş görür, paralel iki istek
  gelse de;
- kod yanlışsa kayıt **bir deneme eksik ve yalnız kalan süresiyle** geri konur ve
  yanıt `400 invalid_email_code` olur (`attemptsLeft` alanı kalan hakkı söyler);
  yavaş tahmin etmek kaydın ömrünü uzatmaz. Beşinci yanlış denemede kayıt ölür
  (`attemptsLeft: 0`), doğru kod bile artık `404` alır;
- kayıt yoksa (hiç istenmedi, kullanıldı, süresi doldu, hak bitti)
  `404 no_pending_email_change`.

Süre iki yerden sınırlanır: deponun ömrü (10 dakika) ve kaydın içine yazılan bitiş
anı. Depo kaydı daha uzun tutsa bile bitiş anı geçmiş bir kod çalışmaz; bitiş anı ya
da kalan deneme sayısı taşımayan kayıt reddedilir.

Doğru koddan sonra adres tekliği yeniden sınanır (10 dakika içinde başkası almış
olabilir): alınmışsa `409 email_taken`. **Bu durumda kod yanmış olur**: kayıt
denetimden önce depodan alındığı için kişi yeni bir kod ister. Bilinçli bir tercih:
kaydı sona kadar depoda bırakmak, iki paralel onayın ikisinin de onu görmesi demek
olurdu. Ardından:

- `personalEmail` ve `personalEmailVerifiedAt` yazılır;
- `makePrimary` istendiyse, kişinin henüz hiç `email` alanı yoksa, **ya da** yeni adres
  birincil olan kişisel adresin yerini alıyorsa Keycloak `email` bu adres olur ve `emailVerified=true` yazılır (olay `UPDATE_EMAIL`,
  `previous_email`/`updated_email`). İkinci durum kişinin yerine bir seçim yapmaz:
  `email`'i boş bir hesabın giriş yapabileceği ve posta alabileceği başka bir adres
  yoktur, az önce kanıtladığı adres tek adaydır. Üçüncüsü de bir seçim değil:
  birincil olan kişisel adresi değiştiren kişinin `email`'i aksi halde artık sahip
  olmadığı bir adreste kalırdı ve `primary` `none` okunurdu;
- olay `UPDATE_PROFILE` (`context=ACCOUNT`).

Yanıt `200` + güncel `identity`.

#### `GET email/pending` — sudo gerekmez, bearer gerekir

Kişinin kodunu bekleyen değişikliği, **tüketmeden** okur; posta ile kod arasında
yenilenen sayfa kod kutusunu yeniden gösterebilsin, kişi saatte üç kodluk hakkından
birini harcamasın diye. Yalnız çağıranın kendi değişikliği; kod ya da özeti asla
dönmez.

```json
{ "address": "ada@example.com", "expiresAt": "2026-09-23T00:10:00Z", "attemptsLeft": 4 }
```

Bekleyen değişiklik yoksa (hiç istenmedi, onaylandı, süresi doldu, hak bitti)
`404 no_pending_email_change`. Bütçe harcamaz (`GET identity` gibi).

#### `POST email/primary` — sudo gerekir

İstek `{"which": "school"}` ya da `{"which": "personal"}` (küçük harfe çevrilir).

- `which` bu iki değerden biri değilse ya da kişinin **seçtiği** adres yoksa
  `400 invalid_request` (`field: "which"`). Öteki adresin var olması gerekmez: okul
  adresi olmayan biri kanıtlı kişisel adresini seçebilir.
- Seçilen adres zaten birincilse ve Keycloak onu doğrulanmış sayıyorsa işlem yoktur
  (`200`, olay yazılmaz). Bu, adresin burada kanıtlanıp kanıtlanamamasından
  bağımsızdır; YTÜ bağlantısından önce okul adresi içe aktarılmış üyeler bu yüzden
  değişmeyen bir seçim için reddedilmez.
- Seçilen adres kanıtlı değilse `409 email_not_verified`:
  - kişisel adres, doğrulama kodu girilmediyse (`personalEmailVerifiedAt` yoksa);
  - okul adresi, hesabın YTÜ Microsoft bağlantısı yoksa. `schoolEmail` niteliğinin
    var olması kanıt değildir (CONTEXT, Verified YTÜ account): içe aktarma ya da bir
    yönetici de yazabilir.
- Aksi halde Keycloak `email` seçilen adres olur ve `emailVerified=true` yazılır. Adres
  zaten birincil ama `emailVerified=false` ise bu bir onarımdır: adres kanıtlı olduğu
  için doğrulanmış işaretlenir ve olay yine yazılır. Olay `UPDATE_EMAIL`
  (`previous_email`, `updated_email`, `context=ACCOUNT`). Yazma anında başkası aynı
  adresi almışsa `409 email_taken` ve işlem geri alınır.

Yanıt `200` + güncel `identity`.

#### `DELETE email/personal` — sudo gerekir

Kişisel adres yoksa işlem yoktur (`200` + `identity`). Varsa:

- adres birincilse okul adresi devralır (`email`, `emailVerified=true`, olay
  `UPDATE_EMAIL`). Devralma `email/primary` ile aynı kurala tabidir: okul adresi
  yoksa **ya da hesabın YTÜ bağlantısı yoksa** `409 no_fallback_email` döner ve
  **hiçbir şey değişmez** — kişinin giriş yapabildiği tek kanıtlı adres silinmez,
  yerine kimsenin doğrulamadığı bir adres geçmez;
- `personalEmail` ve `personalEmailVerifiedAt` silinir, olay `UPDATE_PROFILE`
  (`context=ACCOUNT`).

Yanıt `200` + güncel `identity`.

## Yapılandırma

| Ayar | Kaynak | Varsayılan |
| --- | --- | --- |
| YTÜ IdP alias'ı | `--spi-realm-restapi-extension-sky-account-ytu-idp-alias` / `KC_SPI_REALM_RESTAPI_EXTENSION_SKY_ACCOUNT_YTU_IDP_ALIAS`, yoksa `SKY_ACCOUNT_YTU_IDP_ALIAS` ortam değişkeni | `OBS` |

Alias `^[A-Za-z0-9._-]{1,64}$` desenine uymazsa Keycloak açılışta durur. Kişisel e-posta doğrulama postası realm'in
SMTP ayarına ihtiyaç duyar; SMTP tanımlı değilse `email/change-request`
`503 email_not_sent` döner.

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
- Taze giriş kanıtı (`sudo/authentication`) ID token'ı Keycloak'ın kendi
  `TokenVerifier` yolu ve realm anahtarlarıyla doğrular; yalnız bearer
  oturumunun (`sid`) ve kişisinin (`sub`) `account-center`'a verilmiş ID token'ı
  kabul edilir, pencere girişin `auth_time` değerinden başlar. ID token günlüğe
  yazılmaz; ret gerekçesi yalnız `DEBUG` düzeyinde ve token içeriği olmadan
  yazılır.
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
  bağlıdır (uzlaştırıcı, `config/account-center-passkey-policy.json`: RP ID
  `yildizskylab.com`, extra origin `https://my.yildizskylab.com`). Sınır: imza sayacı yalnız authenticator
  bildirdiğinde koruma sağlar (Apple Secure Enclave gibi hep sıfır bildiren
  authenticator'lar için klonlama tespiti Keycloak'ta olduğu gibi devre dışıdır);
  `authenticatorAttachment` istemci bildirimidir, kriptografik değildir.
- Keycloak'ta sudo'ya özel bir olay türü yoktur; başarılı kanıt genel
  `CUSTOM_REQUIRED_ACTION` olayıyla (`action=sky-sudo`, `method`) kaydedilir.
- Kişisel e-posta doğrulama kodu 6 rakamdır; tahmin edilebilir bir alan olduğu için
  üç yerden sınırlanır: 10 dakika ömür, 5 yanlış deneme, saatte en fazla 3 kod. Bir
  saatte en fazla 15 tahmin, milyonda 15 şans demektir. Depoda yalnız tuzlu SHA-256
  özeti tutulur; her deneme `SingleUseObjectProvider.remove` ile atomiktir, bu yüzden
  aynı hak iki kez harcanamaz ve doğru kod yeniden oynatılamaz. Kod yalnız sahibinin
  oturumunda çalışır. Kod ve adres günlüğe
  yazılmaz; SMTP hata ayrıntıları (alıcıyı içerebilir) yalnız `DEBUG` düzeyindedir.
  Denetim izi Keycloak'ın kendi alışkanlığını izler: adres olay kaydına yalnız
  birincil olduğunda (`UPDATE_EMAIL`, `previous_email`/`updated_email`) girer.
- E-posta tekliği üretimde realm'in `duplicateEmailsAllowed=false` ayarına dayanır;
  uzantı ayrıca `schoolEmail`/`personalEmail` özniteliklerinde arar. Öznitelik
  araması birebirdir: uzantı her iki adresi de küçük harfle yazdığı için yeterlidir,
  ama bir yöneticinin elle karışık harfle yazdığı öznitelik bu aramaya takılmaz.
- `usernameChangedAt`, `schoolEmail`, `personalEmail`, `personalEmailVerifiedAt` model düzeyinde okunup
  yazılır; User Profile'da tanımlı olmadıkları realm'de Admin REST'ten görünmez
  (yönetilmeyen öznitelik politikası kapalıyken salt okunur kalır, silinmez).
  Uzlaştırıcı (`config/account-center-user-profile.json`) bu öznitelikleri
  User Profile'a `user: view, admin: edit` olarak ekler ve
  `unmanagedAttributePolicy=ADMIN_VIEW` tutar; `ENABLED` yapılırsa API
  değişiklikleri `503` ile durdurur.
