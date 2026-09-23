# sky-handoff API v1 — SkyApp'ten web'e geçiş (Web handoff) sözleşmesi

`sky-handoff`, SKY LAB Keycloak imajının içinde çalışan ayrı bir `RealmResourceProvider`
uzantısıdır (`spi/src/main/java/com/skylab/handoff`, ADR-0048). SkyApp, bir SKY LAB
sitesini (Handoff target) kendi WebView'inde oturum açık açmak için buradan 45 saniyelik,
tek kullanımlık bir kod alır; WebView kodu kod başına gizli kanıt başlığıyla açar; Keycloak
tarayıcı oturumunu kurar ve kişiyi hedefin kendi giriş kapısına gönderir. Hedefin kendi
OIDC girişi bu oturumdan sayfasız tamamlanır. `sky-account` uzantısından bağımsızdır; Hesap
Merkezi aradan çıkar ve sıradan bir hedef olur.

Taban adres: `https://e.yildizskylab.com/realms/e-skylab/sky-handoff/v1`
(entegrasyon: `http://localhost:18080/realms/e-skylab-test/sky-handoff/v1`).

## Akış

1. Uygulama `POST handoffs` ile kod ister (SkyApp bearer token'ı + hedef + göreli yol).
2. Cevaptaki `handoffUrl`'i WebView'de açar ve **ilk istekte** `X-Sky-Handoff-Proof: <proof>`
   başlığını gönderir (`loadRequest(uri, headers: …)`).
3. `GET open` kodu doğrular, tarayıcı oturumunu kurar ve `303` ile hedefin giriş kapısına
   gönderir: `rootUrl + signInPath + ?returnParam=<path>` (örnek:
   `https://my.yildizskylab.com/api/auth/login?returnTo=%2F`,
   `https://forms.yildizskylab.com/auth/signin?callbackUrl=%2F<form-id>`).
4. Hedef kendi OIDC akışını başlatır; Keycloak yeni SSO oturumundan sayfa göstermeden cevap
   verir.
5. Herhangi bir hata WebView'i `303` ile `…/sky-handoff/v1/failed?reason=<neden>` sayfasına
   düşürür. Uygulama bu yolu izleyip WebView'i kapatabilir ve kendi hata ekranını gösterebilir.

## `POST handoffs`

```
POST /realms/e-skylab/sky-handoff/v1/handoffs
Authorization: Bearer <skyapp access token>
Content-Type: application/json

{"target": "skyforms", "path": "/3f1c2e9a-…"}
```

Kimlik doğrulama Keycloak'ın kendi `AppAuthManager.BearerTokenAuthenticator` servisiyle
yapılır: imza, süre, iptal listesi, canlı **çevrimiçi ya da çevrimdışı (offline)** kullanıcı
oturumu, etkin kullanıcı. Ardından `azp == "skyapp"` ve token'ın `sid` değerinin doğrulanan
oturumla aynı olması aranır. Uygulamadan çıkış yapılmış (iptal edilmiş offline oturum) bir
token kod alamaz.

- `target`: hedef istemcinin `client_id` değeri (1–255 karakter). Hedef, aşağıdaki
  özniteliklerle açılmış olmalıdır.
- `path`: hedefe göreli yol; `/` ile başlar, en çok 512 karakter, yalnız görünür ASCII
  (boşluk ve ASCII dışı karakterler yüzde kodlanmış olmalı); `//`, `\`, `..` ve yüzde
  kodlanmış `/`, `\`, `.` ya da kontrol karakteri içeremez. Sorgu ve parça (`?…`, `#…`)
  serbesttir; hepsi tek bir parametre değeri olarak kodlanır.
- Gövde tam olarak bu iki alandan oluşur; başka alan `invalid_request` döner.

Cevap `201`, `Cache-Control: no-store`:

```json
{"handoffUrl": "https://e.yildizskylab.com/realms/e-skylab/sky-handoff/v1/open?code=<43 karakter>",
 "proof": "<43 karakter>",
 "expiresIn": 45}
```

Kod ve kanıt 32 rastgele bayttır (base64url, dolgusuz). Keycloak'ın tek kullanımlık nesne
deposunda (`SingleUseObjectProvider`, küme genelinde) yalnız SHA-256 özetleri tutulur:
kodun özeti → {kişi, kaynak oturum ve türü, özgün `auth_time`, hedef, yol, kanıt özeti,
kodu alan IP, son geçerlilik}. Kod 45 saniye geçerlidir.

Hatalar RFC 7807 (`application/problem+json`, `type = tag:yildizskylab.com,2026:sky-handoff:<code>`,
İngilizce `code`, Türkçe `detail`):

| HTTP | `code` | Ne zaman |
|---|---|---|
| 400 | `invalid_request` | Gövde JSON nesnesi değil, çok büyük ya da sözleşme dışı alan var |
| 400 | `invalid_target` | Hedef yok, kapalı, istemcisi devre dışı ya da öznitelikleri/`rootUrl`'i kurala uymuyor |
| 400 | `invalid_path` | Yol kurala uymuyor |
| 401 | `invalid_token` | Token yok, geçersiz, SkyApp'e ait değil ya da oturumu kapanmış (`WWW-Authenticate` ile) |
| 429 | `rate_limited` | Kişi başına 5 dakikalık pencerede 30 kod aşıldı (`Retry-After` ile) |

## `GET open?code=<kod>`

WebView bu adresi `X-Sky-Handoff-Proof` başlığıyla açar. Sıra:

1. Kod biçimi ve özeti depoda aranır; realm aynı olmalı, süresi dolmamış olmalı.
2. Kanıt başlığı sabit zamanlı karşılaştırılır. Kanıtsız ya da yanlış kanıtlı istek `invalid`
   olur ve kodu **tüketmez**: sızmış bir bağlantı ya da ön-yükleme, kanıtı tutan WebView'i
   dışarıda bırakamaz.
3. Kod depodan atomik olarak silinir (`remove`); aynı anda gelen iki istekten yalnız biri
   geçer.
4. Hedef yeniden denetlenir (hâlâ açık, istemci etkin, köken kuralı geçerli), kişi etkin ve
   brute-force kilidi altında değil, kodu alan SkyApp oturumu hâlâ canlı.
5. Kodu alan IP ile açan IP farklıysa yalnız günlüğe ve olaya yazılır, engellenmez.
6. Bu tarayıcıda **başka bir kişinin** Keycloak oturumu varsa o oturum kapatılır (istemcilerine
   back-channel logout gider; o kişi için `LOGOUT` olayı, `details.action=sky-handoff`,
   `details.reason=replaced_by_another_user`). Aynı kişinin eski oturumu, Keycloak'ın aynı
   tarayıcıda yeni girişte yaptığı gibi silinir. Kodu alan SkyApp oturumuna dokunulmaz. Bu
   adım yeni çerezlerden önce gelir: tarayıcı `Set-Cookie` başlıklarını sırayla uygular.
7. Yeni bir Keycloak kullanıcı oturumu kurulur: `AUTH_TIME` notu kaynak oturumun özgün
   değeridir (taze giriş isteyen işlemler yine giriş ister), `sky.embed=skyapp` notu düşülür,
   `KEYCLOAK_IDENTITY`/`KEYCLOAK_SESSION` çerezleri yazılır.
8. `303` hedefin giriş kapısına; `Cache-Control: no-store`, `Referrer-Policy: no-referrer`.

Hata nedenleri (`303 …/v1/failed?reason=<neden>`):

| `reason` | Anlamı | Sayfadaki metin |
|---|---|---|
| `expired` | Kod 45 saniyeden eski | Bağlantının süresi doldu. |
| `used` | Kod daha önce açıldı | Bu bağlantı zaten kullanıldı. |
| `invalid` | Kod bilinmiyor, kanıt yok/yanlış ya da SkyApp oturumu kapanmış | Bağlantı geçersiz. |
| `target_disabled` | Hedef kod alındıktan sonra kapatıldı | Bu siteye uygulamadan geçiş şu an kapalı. |
| `account_unavailable` | Kişi devre dışı, silinmiş ya da kilitli | Hesabın şu an kullanılamıyor. |
| `unavailable` | Beklenmeyen hata | Geçici bir sorun oluştu. |

## `GET failed?reason=<neden>`

Her neden için ayrı Türkçe metin ve "Uygulamaya dönüp tekrar dene." yazan düz bir sayfa
(temalı LegacyFrame sayfası ayrı iştir; yol ve neden kodları sabittir). Giriş formu ve `e.`
giriş sayfasına bağlantı yoktur; bilinmeyen neden `unavailable` gösterir ve sorgu değeri
sayfaya hiç basılmaz. `200`, `Cache-Control: no-store`, `X-Frame-Options: DENY`,
`Content-Security-Policy: default-src 'none'; …; frame-ancestors 'none'`,
`Referrer-Policy: no-referrer`.

## Handoff target öznitelikleri

Bir Keycloak istemcisi şu özniteliklerle hedef olur (Admin REST birleştirmesi, realm
içe/dışa aktarımı ve `reconcile-account-center.sh` bunları silmez; entegrasyon testi bir
uzlaştırma yeniden yazımından sonra korunduklarını doğrular):

| Öznitelik | Anlamı | Hesap Merkezi | Forms |
|---|---|---|---|
| `sky.handoff.enabled` | tam olarak `true` ya da yok | `true` | `true` |
| `sky.handoff.signInPath` | `rootUrl` üzerindeki giriş kapısı yolu | `/api/auth/login` | `/auth/signin` |
| `sky.handoff.returnParam` | yolu taşıyan sorgu parametresi | `returnTo` | `callbackUrl` |

- Köken kuralı: istemcinin `rootUrl`'i `https://` olmalı, host `yildizskylab.com` ya da bir
  alt alan adı olmalı; kullanıcı bilgisi, port, `/` dışında yol, sorgu ve parça olamaz.
  Kural hem kod alınırken hem açılırken uygulanır. Giriş kapısı yönlendirme URI'lerinden
  türetilmez, bu yüzden joker yönlendirme URI'si gerekmez.
- `signInPath`: `/` ile başlar, en çok 128 karakter, yalnız `A-Z a-z 0-9 . _ ~ -` ve `/`;
  `//`, `..`, `.` parçası, sorgu ve parça olamaz.
- `returnParam`: `^[A-Za-z][A-Za-z0-9_]{0,31}$`.

## Yönetim uçları (superadmin)

Hedefleri yalnız SKY LAB yöneticileri değiştirir; superadmin'in "SkyApp'ten geçiş" sayfası bu
uçları sunucu tarafından, oturum açmış yöneticinin kendi token'ıyla çağırır. Core'a yeni bir
Keycloak yetkisi verilmez.

- **Kim:** Keycloak'ın doğruladığı bir bearer token; `azp`'si superadmin'in istemcisi **`admin`**,
  canlı ve **çevrimiçi** bir oturuma bağlı (`sid`), etkin bir kişi ve bu kişi Keycloak grubu
  **`/ADMIN`**'in üyesi (superadmin ve core'un yönetici saydığı grup). Üyelik token claim'lerinden
  değil kişinin grup eşlemelerinden okunur; `/ADMIN`'in herhangi bir alt grubunun üyeliği de sayılır
  (Keycloak'ın `isMemberOf` anlamı). Başka istemcilerin (`my.`, SkyApp, `admin-cli` …) token'ları,
  kişi `/ADMIN` üyesi olsa da reddedilir.
- **Ayarlar** (sağlayıcı ayarı, yoksa düz ortam değişkeni, yoksa varsayılan):
  - grup: `KC_SPI_REALM_RESTAPI_EXTENSION__SKY_HANDOFF__ADMIN_GROUP` (`admin-group`), sonra
    `SKY_HANDOFF_ADMIN_GROUP`; varsayılan `/ADMIN`. Grup yoluyla yazılır (`/ADMIN`, `/ADMIN/web`);
    baştaki `/` yoksa eklenir.
  - istemci: `KC_SPI_REALM_RESTAPI_EXTENSION__SKY_HANDOFF__ADMIN_CLIENT` (`admin-client`), sonra
    `SKY_HANDOFF_ADMIN_CLIENT`; varsayılan `admin`.
  - Grup realm'de yoksa uçlar herkese kapalıdır (`403`) ve günlüğe bir kez uyarı düşer (grup
    yeniden bulunup sonra yine kaybolursa yine bir kez).
- **Ret:** token yok ya da geçersiz → `401 invalid_token`; doğrulanmış ama kabul edilmeyen her
  çağıran (başka istemci, offline oturum, `sid` uyuşmazlığı, `/ADMIN` üyesi değil, grup yok) → hep
  aynı gövdeyle `403 forbidden`.

### `GET admin/targets`

Realm'deki her istemci, `clientId`'ye göre sıralı:

```json
{"targets": [
  {"clientId": "skyforms", "name": "SKY LAB Forms", "rootUrl": "https://forms.yildizskylab.com",
   "originAllowed": true, "clientEnabled": true,
   "enabled": false, "signInPath": "/auth/signin", "returnParam": "callbackUrl"}
]}
```

`originAllowed`, `rootUrl`'in köken kuralına uyup uymadığını; `clientEnabled`, Keycloak istemcisinin
kendisinin açık olup olmadığını söyler. Başka hiçbir istemci verisi (yönlendirme URI'leri, sırlar,
diğer öznitelikler) dönmez.

### `PUT admin/targets/{clientId}`

```json
{"enabled": true, "signInPath": "/auth/signin", "returnParam": "callbackUrl"}
```

- Gövde tam olarak bu üç alandır; `enabled` zorunlu boolean, diğer ikisi metin ya da `null`
  (yoksa `null` sayılır). Açık bir hedef için ikisi de zorunludur; verilen her değer kapalıyken de
  kurala uymalıdır. `null` özniteliği siler; "kapalı" `sky.handoff.enabled` özniteliğinin yokluğudur.
- Açmak için istemcinin `rootUrl`'i köken kuralına uymalıdır.
- Yalnız bu üç öznitelik yazılır; yönlendirme URI'leri, sırlar ve diğer öznitelikler hiç okunmaz ve
  değişmez.
- Cevap `200` ve güncel satır (yukarıdaki biçim). Değer değişmediyse hiçbir şey yazılmaz.
- Her değişiklik bir Keycloak **yönetim olayı** bırakır: `resourceType=SKY_HANDOFF_TARGET`,
  `operationType=UPDATE`, `resourcePath=clients/<uuid>/sky-handoff`, `authDetails` (kim, hangi
  istemciden, hangi IP), `details.clientId`, `details.before` ve `details.after` (eski ve yeni üç
  değerin JSON'u). Reddedilen istek olay bırakmaz. Yönetim olayları realm'de kapalıysa aynı
  bilgi (kim, hangi istemci, eski → yeni) Keycloak günlüğüne `INFO` satırı olarak da düşer.

Hatalar (RFC 7807, Türkçe `detail`):

| HTTP | `code` | Ne zaman |
|---|---|---|
| 400 | `invalid_request` | Gövde JSON nesnesi değil, `enabled` boolean değil ya da sözleşme dışı alan var |
| 400 | `invalid_sign_in_path` | Giriş kapısı yolu kurala uymuyor ya da açık hedefte eksik |
| 400 | `invalid_return_param` | Dönüş parametresi kurala uymuyor ya da açık hedefte eksik |
| 400 | `origin_not_allowed` | Açılmak istenen istemcinin `rootUrl`'i köken kuralına uymuyor |
| 401 | `invalid_token` | Token yok ya da geçersiz |
| 403 | `forbidden` | `/ADMIN` üyesi değil, token `admin` istemcisinin değil ya da oturum çevrimiçi değil |
| 404 | `client_not_found` | Böyle bir `clientId` yok (yalnız yöneticiye döner) |

## `account-center` token claim'leri

Uzlaştırıcı (`reconcile-account-center.sh`) iki eşleyiciyi `account-center`'ın varsayılan
`account-center-core-claims` kapsamına ekler (`config/account-center-core-claims-mappers.json`,
idempotent; istemcinin kendisinde başka bir şey değişmez). Üçü de ID ve access token'da ve
introspection cevabında yer alır, userinfo'da yoktur.

| Claim | Eşleyici | Değer |
|---|---|---|
| `sky_embed` | `sky_embed` (`oidc-usersessionmodel-note-mapper`, not `sky.embed`) | Web handoff ile kurulan oturumda `"skyapp"`; sıradan girişte hiç yok. Hesap Merkezi header'ı buna göre gizler. |
| `sky_session_started` | `sky_session_lifetime` (`sky-session-lifetime-mapper`, `com.skylab.account.SkySessionLifetimeMapper`) | Keycloak kullanıcı oturumunun gerçek başlangıcı (epoch saniye). Web handoff'ta açılış anıdır; `auth_time` ise SkyApp'teki özgün giriştir. |
| `sky_session_expires` | aynı eşleyici | Keycloak'ın bu oturumu en uzun ömürle bitireceği an (epoch saniye), Keycloak'ın kendi `SessionExpirationUtils` hesabıyla: realm SSO en uzun ömrü (varsayılan 10 saat), beni-hatırla oturumunda daha uzun olan beni-hatırla ömrü; istemcide `client.session.max.lifespan` ya da realm'de istemci oturumu en uzun ömrü varsa bu istemcinin oturum başlangıcından sayılan daha kısa değer. En uzun ömrü olmayan oturumda (en uzun ömrü kapalı offline oturum) yazılmaz. |

Hesap Merkezi kendi oturum sınırını `sky_session_expires` (yoksa `sky_session_started`, o da
yoksa `auth_time`) ile koyar; böylece beni-hatırla ile 30 günlük bir Keycloak oturumu sabit
8 saatlik sınıra takılmaz ve SkyApp'ten gelen eski `auth_time` oturumu erken bitirmez. Değerler
aynı oturumun her token'ında (yenilemeler dahil) aynıdır.

## Olaylar ve gizlilik

Her açılış bir Keycloak kullanıcı olayı bırakır: başarı `CUSTOM_REQUIRED_ACTION`
(`details.action=sky-handoff`, kişi, hedef `clientId`, yeni `sessionId`; gerekirse
`details.replaced_session=other_user|same_user`, `details.address_changed=true`), ret
`CUSTOM_REQUIRED_ACTION_ERROR` (`error=<neden>`, kod biliniyorsa kişi ve hedef). Kod, kanıt,
token ve yol hiçbir cevaba, günlüğe ya da olaya yazılmaz; entegrasyon testi bunu Keycloak
günlüğü ve olay deposu üzerinde doğrular.
