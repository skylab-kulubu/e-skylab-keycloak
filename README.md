<div align="center">
  <a href="https://yildizskylab.com">
    <img src="https://raw.githubusercontent.com/skylab-kulubu/skylab-assets/main/logos/skylab/skylab-colored.svg" alt="SKY LAB Logosu" width="120" />
  </a>

  <h1>SKY LAB Keycloak</h1>

  <p>
    SKY LAB kimlik altyapısının güvenli çalışma zamanı,<br />
    giriş teması ve kulübe özel kimlik uzantıları.
  </p>

  <p>
    <a href="https://github.com/skylab-kulubu/e-skylab-keycloak/actions/workflows/ci.yml"><img src="https://github.com/skylab-kulubu/e-skylab-keycloak/actions/workflows/ci.yml/badge.svg" alt="Sürekli Entegrasyon" /></a>
    <img src="https://img.shields.io/badge/Keycloak-26.7.4-4D4D4D?style=flat-square&logo=keycloak" alt="Keycloak 26.7.4" />
    <img src="https://img.shields.io/badge/Java-21-ED8B00?style=flat-square&logo=openjdk&logoColor=white" alt="Java 21" />
    <img src="https://img.shields.io/badge/Docker-Hazır-2496ED?style=flat-square&logo=docker&logoColor=white" alt="Docker Hazır" />
  </p>
</div>

---

## Projenin amacı

Bu depo, `e.yildizskylab.com` üzerinde çalışan SKY LAB kimlik sisteminin tek
kaynak deposudur. Keycloak imajını, markalı giriş ekranını, kulübe özel
kimlik sağlayıcılarını, geçiş anahtarı akışlarını ve Hesap Merkezi
yapılandırmasını birlikte ve sürümlü biçimde üretir.

Amaç; bütün SKY LAB ürünlerinin aynı kullanıcı, grup, oturum ve yetki
sözleşmesini kullanmasını sağlarken üretimde elle kopyalanmış JAR, tema veya
realm ayarı bırakmamaktır.

## Çalışma zamanı sözleşmesi

- Keycloak `26.7.4`, etiket ve digest birlikte sabitlenmiş tek bir imaj
  referansı olarak kullanılır.
- Keycloak ve iki sağlayıcı derlemesi Java 21 kullanır.
- Maven, Node.js, PostgreSQL ve RabbitMQ derleme/test imajları digest ile
  sabitlenmiştir.
- `kc.sh build` ile PostgreSQL için optimize edilmiş bir Keycloak imajı
  üretilir.
- `/opt/keycloak/providers` altında tam olarak bir SKY LAB SPI (`1.10.0`),
  kaynaktan derlenen bir SKY LAB giriş teması (`2.0.1`) ve bir RabbitMQ olay
  sağlayıcısı (`3.1.0`) bulunur.
- `account-api:v1`, PAR, geçiş anahtarları ve WebAuthn imaj derlenirken açıkça
  etkinleştirilir.
- Realm ve istemci ayarları `config/reconcile-account-center.sh` ile sürekli
  uzlaştırılır; tek seferlik realm içe aktarımına güvenilmez.
- Sistem e-postaları `sky-mail` sağlayıcılarıyla SkyMail üzerinden gönderilir;
  SkyMail kapalı ya da ulaşılamazken realm'in kendi SMTP'si devreye girer.
- Üretim yalnız
  `ghcr.io/skylab-kulubu/e-skylab-keycloak` deposundan imaj çeker ve doğrulanmış
  bir `KEYCLOAK_IMAGE_DIGEST` kabul eder. Çalışma zamanı, ön kontrol ve
  uzlaştırıcı aynı `repository@sha256:digest` değerini kullanır.
- Üretim mevcut ortak PostgreSQL 18 servisine bağlanır. Compose ayrı bir
  PostgreSQL servisi veya veri diski oluşturmaz.
- Yönlendirilmiş HTTP başlıkları yalnız
  `KEYCLOAK_PROXY_TRUSTED_ADDRESSES` izin listesindeki vekillerden kabul edilir.

Giriş teması [`theme/`](theme/) içinden Keycloakify `11.16.0` ile yeniden
derlenir. Birim, imaj, gerçek Keycloak ve Chromium testleri; WebAuthn alanlarını,
yeniden denemeyi, “beni hatırla” aktarımını, AIA ekranlarını, klavye kullanımını,
kontrastı ve azaltılmış hareket tercihlerini korur. Giriş sayfası, erişim
anahtarı teklifi ve Keycloak'ın diğer bütün sayfaları (parola yenileme, doğrulama
uygulaması, erişim anahtarı kaydı, hata, bilgi, çıkış onayı, kimlik sağlayıcı bağlama…)
tek bir tasarım sistemini paylaşır: `theme/src/login/legacy-login.css` tek
stil dosyası ve tek token kümesidir, `Template.tsx` her sayfayı giriş
sayfasının `LegacyFrame` çerçevesinde (animasyonlu SKY LAB logosu, cam kart,
KVKK altbilgisi, dil seçimi) çizer ve bütün metinler `i18n.ts` içinden gelir
(önce Türkçe, sonra İngilizce).

İlk fiziksel doğrulama Touch ID üzerinde tamamlanmıştır. Face ID, Android
Credential Manager, Windows Hello ve mobil WebView yüzeyleri sürüm sonrası
uyumluluk kapsamındadır; test edilmiş gibi gösterilmez.

## Hesap Merkezi istemcisi

Uzlaştırıcı, gizli `account-center` istemcisini şu sözleşmeyle yönetir:

- Yalnız Authorization Code akışı açıktır; implicit, Direct Access Grants ve
  service account kapalıdır.
- Yönlendirme adresi tam olarak
  `https://my.yildizskylab.com/api/auth/callback` değeridir ve web origin
  tanımlanmaz.
- S256 PKCE ve Pushed Authorization Requests zorunludur.
- Backchannel logout ve çıkış sonrası dönüş adresleri birebir sabitlenir.
- İstemciye özel tarayıcı akışının ilk alternatif adımı,
  `sky_native_handoff` değerini HMAC doğrulamalı mTLS üzerinden tek seferlik
  olarak kullanır.
- Özel varsayılan istemci kapsamı (`account-center-account-api`,
  mapper'ları `config/account-center-account-api-mappers.json`) `account` ve
  `core` audience değerlerini, sabit `manage-account` / `view-profile` /
  `manage-account-links` rollerini (`resource_access.account.roles`) ve kişinin
  uygulama (istemci) rollerini `sky_authorization.<istemci>.roles` altında
  (yalnız access token ve introspection; ID token ve userinfo'da yok) taşır.
  Audience-resolve mapper yoktur; `aud` tam olarak `["account","core"]` olur
  ve token `core` rolü taşımaz (`resource_access` altında yalnız `account`
  bulunur). Roller yalnız bu izole kapsamda sabitlenir; realm kullanıcılarına
  veya diğer istemcilere genel rol verilmez.
- `fullScopeAllowed` **kapalı kalır**: Keycloak Admin REST bir bearer token'ı
  `AdminAuth.hasAppRole = user.hasRole(rol) && client.hasScope(rol)` ile
  yetkilendirir ve tam kapsam açıkken `client.hasScope` her rol için doğrudur;
  `realm-management` rolü taşıyan bir kişinin `my.` token'ı Admin REST'te
  geçerli olurdu. Bu yüzden `sky_authorization` claim'ini Keycloak'ın kapsama
  bağlı rol mapper'ı değil, SPI'daki `sky-authorization-mapper`
  (`com.skylab.account.SkyAuthorizationMapper`) üretir: kişinin etkin rol
  eşlemelerini (doğrudan, grup, bileşik) kendisi okur, yalnız istemci
  rollerini alır, `realm-management`, `broker`, `account`, `account-console`,
  `security-admin-console`, `admin-cli` ve `*-realm` istemcilerini dışarıda
  bırakır, istemci ve rol adlarını sıralar, 64 istemci / istemci başına 256
  rol sınırını aşanı tek bir `WARN` ile atar, rol yoksa claim'i hiç yazmaz.
  Claim salt okunur bir yetki görünümüdür; token'ın yapabileceklerini
  genişletmez. Entegrasyon testi `realm-management/view-users` sahibi bir
  kişinin `account-center` token'ıyla `GET /admin/realms/{realm}/users`
  isteğinin 403 aldığını (tam kapsamla 200 alırdı) ve claim'de
  `realm-management` bulunmadığını doğrular. `manage-account-links` ayrıca
  `account` istemcisinin scope mapping izin listesindedir; AIA `idp_link`
  eylemi `client.hasScope` denetimi yapar.
- Core claim kapsamı yalnız gerekli `sub` ve `auth_time` alanlarını üretir.
- BFF'nin en küçük `openid` isteğine uygun biçimde isteğe bağlı kapsam yoktur.

Realm oturumu, giriş ayarları ve tema `config/account-center-realm.json`
(`editUsernameAllowed=false`, `loginWithEmailAllowed=true`,
`duplicateEmailsAllowed=false`), brute-force koruması ve parola politikası
`config/account-center-realm-security.json` (10 deneme, 60 sn artan bekleme,
en çok 15 dk, 12 saat sıfırlama, kalıcı kilit yok;
`length(8) and notUsername and notEmail`), şifresiz passkey politikası
`config/account-center-passkey-policy.json` içinde kaynak kontrolündedir.
Keycloak passwordless politikayı her yazımda bütünüyle yeniden kurduğundan
politika tek belgede eksiksiz tanımlanır; relying party id ve ek origin'ler
ortamdan gelir (`KEYCLOAK_PASSKEY_RP_ID`, varsayılan `yildizskylab.com`;
`KEYCLOAK_PASSKEY_EXTRA_ORIGINS`, virgülle ayrılmış, varsayılan
`https://my.yildizskylab.com`). Üretim modunda
(`ACCOUNT_CENTER_REQUIRE_PRODUCTION_HOST=true`) yalnız üretim değerleri kabul
edilir; entegrasyon fixture'ı `localhost` ve `http://localhost:18080` kullanır.
Relying party id gerçekten değiştiğinde uzlaştırıcı, politikayı yazmadan önce
realm özniteliği `skylab.passkeyRpIdSwitchedAt` değerine o anı (ISO-8601 UTC)
kaydeder; öznitelik haritası canlı halinin üstüne birleştirilerek yazılır
(Keycloak, `attributes` taşıyan bir PUT'ta eksik bırakılan her realm
özniteliğini siler). İki faktörlü WebAuthn politikası (`webAuthnPolicy*`)
yönetilmez. `attributes` taşımayan realm PUT'larında Keycloak CIBA ve PAR
sürelerini varsayılana sıfırlar (önceden de böyleydi; SKY LAB ikisini de
varsayılan dışında kullanmaz).

User Profile (`config/account-center-user-profile.json`) canlı yapısını
koruyarak uzlaştırılır: `firstName`, `lastName`, `email` kişi için salt
okunur olur, `username` izinlerine dokunulmaz, `schoolEmail`, `personalEmail`
(`email` doğrulayıcısı), `skyNumber`, `department`, `university`, `skyMail`,
`usernameChangedAt` (ISO-8601 UTC `pattern` doğrulayıcısı) öznitelikleri
`view=[admin,user]`, `edit=[admin]` olarak eklenir, mevcut görünen adlar,
gruplar, açıklamalar ve tanımlanmamış öznitelikler korunur,
`unmanagedAttributePolicy=ADMIN_VIEW` olur (asla `ENABLED`; sky-account API
`ENABLED` iken değişiklikleri kapatır).

K5'in gizli `keycloak-mailer` service-account istemcisini (standard flow ve
direct grant kapalı, `fullScopeAllowed=false`, `roles` varsayılan kapsamı,
`skymail` istemcisinin `skymail:access` ve `skymail:mails:send` rolleri service
account'ta ve scope mapping'de) operatör, imajdaki idempotent
`config/create-mailer-client.sh` betiğiyle oluşturur (varsayılan kuru koşu,
`--apply`; yönetici parolası kcadm'ın kendi prompt'una yazılır,
`KEYCLOAK_MAILER_ADMIN_PASSWORD` yalnız `SKY_HARNESS=1` ile kabul edilir;
`skymail` rolleri yoksa uyarır, asla oluşturmaz). Uzlaştırıcı kimliğine kullanıcı
yetkisi verilmediği için uzlaştırıcı bu istemciyi yalnız doğrular: yoksa
uyarı ve çalıştırılacak komut, bayraklar yanlışsa hata, service account
rolleri okunamıyorsa uyarı. Gizli anahtarı Keycloak üretir; hiçbir betik
yazdırmaz, ops `kcadm get clients/{id}/client-secret` ile okur (runbook §6).

İstemciye özel tarayıcı akışı realm'in etkin tarayıcı akışından kopyalanır;
böylece production'a özel parola, OTP ve passkey davranışı korunur.
Uzlaştırıcı kaynak akışı salt okunur kabul eder, yalnız izole native handoff
dalını ekler ve kopya saparsa onu yeniden kurar. Bilinmeyen mapper, rol ve
kapsamlar izin listeleriyle temizlenir.

Uzlaştırıcı her adımda önce canlı durumu okur, yalnız farklı olan alanları
yazar ve `[reconcile] <adım>: unchanged|updated (...)` satırı basar;
değişiklik gerektirmeyen koşu hiçbir admin olayı üretmez (entegrasyon testi
üçüncü koşuda bunu doğrular). İmajda `jq` bulunmadığından JSON
karşılaştırmaları imajdaki JDK ile çalışma anında derlenen
`config/ReconcileJson.java` ile yapılır. Passkey relying party id geçişinden
önce kayıtlı passkey'ler bir daha doğrulanamaz; `config/cleanup-legacy-passkeys.sh`
(varsayılan kuru koşu, yalnız sayı basar) geçiş anından önce oluşturulmuş
`webauthn-passwordless` kimlik bilgilerini `--apply` ile siler. Geçiş anını
realm özniteliği `skylab.passkeyRpIdSwitchedAt` verir; `--cutover` yalnız bu
andan önceki bir zaman olabilir (sonrası reddedilir, çünkü geçişten sonra
kaydedilen passkey'ler geçerlidir), silme hataları sayılır ve özet
basıldıktan sonra sıfır dışı çıkılır. Üretim sırası,
ön kontrol SQL'i, duyuru metni ve temizlik adımı
[`docs/v2-identity-reconcile-runbook.md`](docs/v2-identity-reconcile-runbook.md)
belgesindedir.

Sürekli uzlaştırma yalnız servis amaçlı `account-center-config` istemcisiyle
kimlik doğrular (`realm-management` rolleri yalnız `manage-clients`,
`view-clients`, `manage-realm`, `view-realm`; kullanıcı yetkisi yoktur). Bu
istemcinin oluşturulması veya gizli anahtarının döndürülmesi ayrı ve
denetlenebilir bir başlangıç adımıdır; ana yönetici bilgileri normal Compose
yığınına girmez.

`sky-native-handoff` yalnız Hesap Merkezi istemcisine bağlıdır. Köprü ipucu
yoksa masaüstü girişini değiştirmez. Geçerli bir ipucunu yalnız bir kez kullanır,
etkin kullanıcıyı `sub` ile seçer ve özgün `auth_time` değerini yeni tarayıcı
oturumuna taşır. Başarısız veya yeniden oynatılmış köprü parola formuna düşmez.

## sky-account API

`sky-account` uzantısı (`/realms/{realm}/sky-account/v1`) Hesap Merkezi'nin
kişi adına yaptığı kimlik ve kimlik bilgisi değişikliklerini Keycloak içinde
uygular; tam sözleşme [`docs/sky-account-api.md`](docs/sky-account-api.md)
belgesindedir.

- Yalnız `account-center` kullanıcı token'ı kabul edilir (`azp=account-center`,
  `aud ∋ account`, `manage-account` rolü, canlı oturum); her şey kişinin kendi
  hesabıyla sınırlıdır, yönetim işlemi yoktur.
- Uç noktalar: `GET identity`; `PATCH identity/name` (Doğrulanmış YTÜ hesabında
  kilitli); `POST identity/username` (14 gün bekleme, teklik); `POST sudo/password`,
  `POST sudo/totp`, `POST sudo/webauthn/options|verify` (passkey ile sudo);
  `POST sudo/authentication` (parolası, TOTP'si ve passkey'i olmayan kişi için
  Microsoft ile yeniden girişin ID token'ıyla sudo);
  `POST credentials/password` (`logoutOtherSessions` ile);
  `POST credentials/totp/setup|confirm`; `POST credentials/webauthn/options|register`
  (passkey kaydı); `DELETE credentials/{id}` (OTP ve passkey; parola asla);
  `POST email/change-request|confirm|primary`, `GET email/pending`, `DELETE email/personal`
  (kişisel e-posta ve birincil adres).
- Kişisel e-posta (ADR-0044): `POST email/change-request` adresi Keycloak'ın kendi
  e-posta doğrulayıcısıyla sınar, küçük harfe çevirir, kişinin kendi adreslerini ve
  başkasında olan adresleri reddeder (`409 email_taken`), kişiye hiçbir şey yazmadan
  **6 haneli bir kod** üretir ve kişi başına tek bir bekleyen değişiklik olarak
  Keycloak'ın single-use deposuna 10 dakikalığına koyar (yalnız tuzlu SHA-256 özeti;
  yeni istek eskisinin yerini alır). Kodu Keycloak'ın kendi `EmailTemplateProvider`'ıyla,
  bu uzantının `theme-resources` içindeki `sky-personal-email-confirm` şablonu ve
  Türkçe/İngilizce mesaj anahtarlarıyla gönderir (tema değişikliği gerekmez; postada
  link yoktur). Bütçe: her istek bir `mutation` yuvası, sudo doğrulandıktan sonra
  ayrıca saatte 3 istekle sınırlı `email-change` yuvası. `POST email/confirm {code}`
  sudo istemez ama bearer ister ve kodu **yalnız çağıranın kendi** bekleyen
  değişikliğiyle karşılaştırır: kod başka bir hesaba adres bağlayamaz. Yanlış kod
  `400 invalid_email_code` (`attemptsLeft`), beşinci yanlışta kod ölür; bekleyen
  değişiklik yoksa `404 no_pending_email_change`. `GET email/pending` bekleyen
  değişikliği tüketmeden okur (adres, bitiş, kalan hak; kod asla), sayfa yenilense de
  kod kutusu geri gelsin diye. Onayda `personalEmail` + `personalEmailVerifiedAt`
  yazılır; `makePrimary` istendiyse, hiç `email` yoksa ya da birincil kişisel adresin
  yerini alıyorsa Keycloak `email` alanını taşır. `POST email/primary` seçilen adres kanıtlıysa onu birincil
  yapar (okul adresi için YTÜ bağlantısı şarttır, `409 email_not_verified`); öteki
  adresin var olması gerekmez. `DELETE email/personal` adresi kaldırır ve birincilse
  YTÜ bağlantılı okul adresine düşer (`409 no_fallback_email` yoksa). `GET identity`
  `personalEmailVerified` alanını da verir. Posta realm SMTP ayarını kullanır (yoksa
  `503 email_not_sent`).
- Passkey (WebAuthn passwordless): ceremony `my.` tarayıcısında çalışır; SPI realm
  passwordless politikasından `navigator.credentials.create/get` seçeneklerini üretir
  ve sonucu Keycloak'ın kendi webauthn4j makinesiyle (`WebAuthnRegistrationManager`,
  `WebAuthnPasswordlessCredentialProvider`) doğrular — `WebAuthnRegister` /
  `WebAuthnAuthenticator` yollarının aynısı: origin + `extraOrigins`, RP ID,
  challenge, kullanıcı doğrulaması (sudo'da politikadan bağımsız her zaman
  zorunlu), imza ve sayaç. `GET identity` yalnız `webauthn-passwordless`
  kimlik bilgilerini passkey sayar. `my.`'de kaydedilen passkey `e.` girişinde
  de çalışır (RP ID her origin'de aynı).
- Sudo modu: parola, doğrulama kodu ya da passkey kanıtı, Keycloak'ın iç HMAC
  anahtarıyla (`HS512`, Keycloak dışında doğrulanamaz) imzaladığı beş dakikalık,
  `sub`+`sid` bağlı bir sudo token verir (`X-Sky-Sudo` başlığı; BFF için opak). Token tek kullanımlık değildir; başka oturumun
  bearer'ıyla çalışmaz, süresi dolunca `sudo_expired` döner. Her başarılı
  kanıt `CUSTOM_REQUIRED_ACTION` (`action=sky-sudo`,
  `method=password|totp|passkey|authentication`) olayı bırakır.
- Taze giriş kanıtı: üç kimlik bilgisinden hiçbiri olmayan kişi Keycloak'ta
  (Microsoft) yeniden giriş yapar; BFF callback'te aldığı ID token'ı
  `POST sudo/authentication` ile sunar. SPI token'ı Keycloak'ın `TokenVerifier`
  yolu ve realm anahtarlarıyla doğrular (`typ=ID`, `iss`, `aud`/`azp` yalnız
  `account-center`, bearer'ın `sub` ve `sid` değerleri, `iat`/`exp`,
  not-before) ve `auth_time` 300 saniyeden eskiyse `401 authentication_stale`,
  diğer her rette `401 sudo_required` döner. Sudo token'ın penceresi girişten
  başlar (`exp = auth_time + 300`), `amr=["idp"]`, olay `method=authentication`.
  Brute-force koruyucusu devreye girmez; denemeler `sudo` bütçesinden düşer.
- Brute-force koruması realm'de açıksa her parola/TOTP sudo denemesi Keycloak'ın
  kendi koruyucusuna bildirilir (kapalıysa açılışta tek bir uyarı günlüğe düşer;
  uzlaştırıcı korumayı ve parola politikasını açar). Keycloak 26.7.4 passkey
  kategorisini saymaz: başarısız passkey denemesi brute-force sayacını
  artırmaz, başarılısı temizlemez; mevcut kilit yine passkey ile sudo'yu da
  engeller. Passkey denemelerinin kısıtı kendi `sudo-passkey` bütçesidir.
  Kullanıcı başına atomik hız sınırları: sudo 10 / 15 dk, passkey sudo 10 / 15
  dk, TOTP onayı 10 / 15 dk, değişiklikler 30 / 15 dk, e-posta değişiklik isteği
  3 / 1 saat.
- Realm User Profile'ı yönetilmeyen öznitelikleri kişiye açıyorsa
  (`unmanagedAttributePolicy=ENABLED`) değişiklik uçları `503` ile kapanır,
  okuma sürer.
- Hatalar RFC 7807 (`application/problem+json`): İngilizce `code`, Türkçe
  `detail`. Parola, kod, sır ve token günlüğe yazılmaz.
- YTÜ Microsoft IdP alias'ı `SKY_ACCOUNT_YTU_IDP_ALIAS` ortam değişkeniyle
  (varsayılan `OBS`) ayarlanır.

Entegrasyon testi (`tests/sky-account-contract.sh`, `tests/run-integration.sh`
tarafından çağrılır) gerçek Keycloak üzerinde bearer korumasını, YTÜ kilidini,
brute-force sayımını ve kilidi, sudo oturum bağını, taze giriş kanıtını (ID
token ile sudo → parola belirleme; başka oturumun/kişinin ID token'ı, bozuk imza
ve access token reddedilir), parola politikasını,
diğer oturumların kapatılmasını, TOTP kurulum/onay/giriş/silme akışını,
kullanıcı adı kurallarını, hız sınırını, passkey uçlarının şeklini ve sudo
kapısını, ve olay kayıtlarını doğrular. Kişisel e-posta akışı uçtan uca sınanır:
istek → postanın harness posta kutusunda (`mailpit` servisi, yalnız fixture ağında)
yakalanması → postadaki kodla onay → `personalEmailVerified` → birincil seçimi →
başka bir istemcinin taze token'ındaki `email` claim'i → kaldırmada YTÜ bağlantılı okul
adresine düşüş; yanlış kod (kalan hak), kullanılmış kod, başka oturumdan denenen kod,
YTÜ bağlantısız okul adresi, doğrulanmamış adres, başkasında olan adres, geri
düşülecek adresin olmaması ve saatlik bütçe reddedilir. Passkey ceremony'si ayrı bir Playwright
adımıyla (`theme/tests/integration/webauthn-passkey.spec.ts`,
`tests/webauthn-page.mjs` üzerinden `http://localhost:18081`) sanal authenticator
ile uçtan uca sınanır: seçenek → oluştur → kaydet → `GET identity`'de görünür →
Keycloak'ın kendi giriş sayfasında o passkey ile giriş (RP ID uyumu) → passkey
assertion ile sudo → yeniden oynatılan challenge, izinsiz origin ve gerileyen
sayaç reddedilir.

## Sistem e-postaları (SkyMail)

Keycloak'ın doğrulama, parola sıfırlama, e-posta değişikliği ve YTÜ bağlama
postaları kulübün posta alanı SkyMail'in sistem şablonlarıyla yazılır ve SkyMail
tarafından gönderilir (ADR-0045). SPI iki sağlayıcı kaydeder: `sky-mail` şablon
sağlayıcısı stok `freemarker` sağlayıcısını sararak Keycloak'ın hangi şablonu
istediğini ve bağlantı ile ömrünü oturum üzerinde kaydeder, üretimi olduğu gibi
devreder; `sky-mail` göndericisi bu kaydı alıp
`POST {SKY_MAIL_BASE_URL}/v1/mail_tasks/single` ile `template_key`, alıcı ve
`body_variables` gönderir. İkisi de `order()` ile Keycloak'ın kendi
sağlayıcılarının önüne geçer, derleme seçeneği gerekmez.

Şablon eşlemesi `keycloak.verify-email`, `keycloak.reset-password`,
`keycloak.update-email`, `keycloak.idp-link`, `keycloak.personal-email-confirm`
ve eşlenmeyen her posta için `keycloak.generic`'tir. SkyMail Go `text/template`
kullandığından eksik değişken `<no value>` basar; bu yüzden `link`,
`linkExpirationMinutes`, `firstName`, `username`, `realmDisplayName` ve
`subjectKey` her postada, bilinmiyorsa boş string olarak gönderilir. SMTP test
postası realm'in kendi ayarlarını kanıtladığı için SkyMail'e hiç uğramaz.

Yetki, `keycloak-mailer` gizli service account istemcisinin client credentials
token'ıdır (`skymail:access` + `skymail:mails:send`); token süresi dolmadan
30 saniye öncesine kadar bellekte önbelleklenir. Yalnız `201` gönderildi
sayılır: 404 (şablon anahtarı yok ya da arşivlenmiş), başka 4xx, 5xx, zaman
aşımı, token hatası ve kapalı sağlayıcı dahil her durum Keycloak'ın kendi SMTP
göndericisine, üretilmiş stok gövdeyle devreder ve tek satır
`sky_mail_fallback reason=<sabit sözcük> template=<anahtar>` günlüğü düşer;
satır adres, bağlantı, token ya da gizli anahtar taşımaz.

Yapılandırma ortamdan gelir: `SKY_MAIL_ENABLED` (varsayılan `false`),
`SKY_MAIL_BASE_URL`, `SKY_MAIL_CLIENT_ID`, `SKY_MAIL_CLIENT_SECRET_FILE`
(varsayılan `/run/secrets/sky-mail/client.secret`), `SKY_MAIL_TOKEN_URL`
(varsayılan realm issuer'ından türetilir) ve `SKY_MAIL_TIMEOUT_MILLISECONDS`
(varsayılan 5000 toplam, bağlantı bütçesi en çok 2000). Biçimi bozuk bir değer
fabrikayı başarısız eder; gizli anahtar dosyası eksik ya da boşsa sağlayıcı
kapalı tarafa düşer (tek `sky_mail_disabled reason=…` uyarısı) ve postalar
SMTP'den çıkmaya devam eder.

Operatör `keycloak-mailer` istemcisini `config/create-mailer-client.sh` ile
oluşturur, Keycloak'ın ürettiği gizli anahtarı üretim sunucusunda
`/opt/weblab/account-center-keycloak/credentials/mailer-client.secret`
dosyasına (`root:1000`, `0640`; konteyner uid 1000 okuyabilmelidir) yazar ve
Compose bu dosyayı salt okunur olarak `/run/secrets/sky-mail/client.secret`
yoluna bağlar. Anahtar her token isteğinde okunur; döndürme dosyanın içeriğini
yerinde güncellemekle yapılır. Eşleme tablosu, değişkenler, ortam, geri düşüş
sözcükleri ve operatör adımları
[`docs/keycloak-mail-via-skymail.md`](docs/keycloak-mail-via-skymail.md)
belgesindedir.

## Yerel geliştirme ve doğrulama

Gereksinimler: Docker, `bash`, `curl`, `jq`, `openssl` ve Node.js (sky-account
sözleşmesindeki TOTP kodları `tests/totp-code.mjs` ile üretilir).

```bash
docker build --platform linux/amd64 -t account-keycloak:test .
KEYCLOAK_TEST_IMAGE=account-keycloak:test bash tests/run-integration.sh
```

Yalnız yerel imaj derlemesi için üretim sözleşmesini devralmayan bağımsız
Compose tanımını kullanın:

```bash
docker compose -f docker-compose.build.yml build
```

### Tema sayfalarını önizleme ve ekran görüntüsü temel çizgileri

Tema geliştirme sunucusu her Keycloak sayfasını gerçek Keycloak olmadan
gösterir; `?page=<sayfa>.ftl` ve `&lang=en` sorgu parametreleri
`theme/src/devKcContext.ts` içindeki sahte verilerle sayfayı açar:

```bash
cd theme
npm ci --ignore-scripts
npx vite            # http://localhost:5173/?page=login-config-totp.ftl
```

`theme/tests/browser/visual.spec.ts`, her sayfanın masaüstü (1280×800) ve
mobil (390×844) ekran görüntüsünü Türkçe ve azaltılmış hareketle alır ve
`theme/tests/browser/visual.spec.ts-snapshots/` altındaki temel çizgilerle
karşılaştırır (izin verilen fark en fazla %1 piksel). Temel çizgiler yalnız
Playwright'ın resmi Linux imajında (`mcr.microsoft.com/playwright:v<sürüm>-jammy`,
`theme/tests/browser/fonts.conf` ile sabitlenmiş yazı tipleri) üretilir; CI ve
yayın iş akışlarındaki `theme` işleri aynı imajda çalışır. Görsel test yalnız
`SL_VISUAL_BASELINE_ENV=1` tanımlıyken (bu imajda) koşar; başka makinelerde
`npm run test:browser` onu atlar. Yerelde karşılaştırmak ya da tasarım
değişikliğinden sonra temel çizgileri yenilemek için Docker ile şu betiği
kullanın:

```bash
# Karşılaştır (CI ile aynı): farklar theme/test-results/ altına yazılır
bash theme/scripts/update-visual-baselines.sh --check

# Bilinçli bir tasarım değişikliğinden sonra temel çizgileri yeniden üret
bash theme/scripts/update-visual-baselines.sh
```

Betik `@playwright/test` sürümünü `theme/package.json` içinden okur, tema
kaynaklarını salt okunur bağlar ve yalnız ekran görüntülerini geri yazar; bir
görüntü bile alınamazsa mevcut temel çizgilere dokunmaz.
Yenilenen PNG dosyaları incelenip değişiklikle birlikte commit edilmelidir; bir
sayfanın tasarımı değişmeden temel çizgisi değişiyorsa bu bir gerilemedir.
Apple Silicon üzerinde betik varsayılan olarak `linux/amd64` imajını
öykünerek çalıştırır (`VISUAL_BASELINE_PLATFORM` ile değiştirilebilir).

Doğrulama sırası şu şekildedir:

1. Sürüm, sabit imajlar, Compose ve yayın sınırları denetlenir.
2. Tema birim, Chromium ve ekran görüntüsü testlerinden geçirilip JAR olarak
   derlenir.
3. Aday Keycloak imajı bir kez oluşturulur.
4. PostgreSQL, RabbitMQ, OIDC, PAR/PKCE, oturum, AIA, tema, sky-account API ve
   olay yayını sözleşmeleri gerçek servislerle sınanır; v2 kimlik adımları
   (passkey RP ID, brute force, parola politikası, User Profile, token
   `aud`/`sky_authorization`, Admin REST'in `account-center` token'ını
   reddetmesi, `keycloak-mailer`, sapma onarımı, değişiklik üretmeyen üçüncü
   koşu, relying party id geçişi etrafında passkey temizliği kuru koşusu ve
   `--apply` uygulaması) aynı koşuda doğrulanır.
5. Commit'e bağlı fiziksel WebAuthn kanıtı doğrulanır.
6. Test edilen aynı imaj baytları paketlenir; yayın aşamasında yeniden derleme
   yapılmaz.

## Sürümleme ve yayın

`main` geliştirme ve entegrasyon dalıdır. Canlı adayları yalnız `production`
dalından çıkar. `production` dalına gönderilen her commit tam doğrulamadan sonra
`production` ve değişmez `sha-<commit>` imaj etiketlerini üretir.

`vX.Y.Z` etiketi yalnız güncel `production` commit'ini gösteriyorsa ve etiket
sürümü Dockerfile içindeki Keycloak sürümüyle eşleşiyorsa kabul edilir. Bu etiket
aynı test edilmiş imajı `X.Y.Z` ve `latest` adlarıyla da yayınlar. Böylece dal
tabanlı canlı dağıtım korunurken kesin geri dönüş noktaları kaybolmaz.

Korunan derleme işi registry yazma yetkisi almaz. Aday imajı test eder, fiziksel
WebAuthn kapısını doğrular ve imaj kimliği, commit SHA'sı, tema JAR'ı ile
checksum'ları bir günlük kısa ömürlü artefakta koyar. Yalnız ona bağlı yayın işi
`packages: write` yetkisi alır; aktarılan aynı imajı yayın türüne göre
`sha-<commit>`, `production`, `X.Y.Z` ve `latest` etiketleriyle GHCR'a gönderir.
`main` adlı imaj etiketi yayınlanmaz.

`production` imajı başarıyla yayımlandıktan sonra iş akışı
`DOKPLOY_DEPLOY_HOOK` GitHub secret'ını çağırır. Secret eksikse veya Dokploy
2xx dışında yanıt verirse yayın işi bunu sessizce geçmez. Webhook adresini
sohbete ya da diske yazmadan kurmak veya döndürmek için:

```bash
./scripts/setup-production-webhook.sh
```

Sihirbaz adresi yalnız terminalde gizli olarak alır, hedefi onaylatır ve
`skylab-kulubu/e-skylab-keycloak` deposunun GitHub Actions secret'ına kaydeder.
Webhook'u kurulum sırasında çağırmaz; ilk çağrı sonraki `production` yayınında
yapılır.

Üretim kurulumu değişebilir etiketle değil, iş akışının kaydettiği değişmez
manifest digest'iyle yapılır. Ayrıntılı geçiş ve geri dönüş adımları
[`docs/keycloak-26.7.4-upgrade-runbook.md`](docs/keycloak-26.7.4-upgrade-runbook.md)
belgesindedir.

## Katkıda bulunanlar

Projeye katkı veren kişiler GitHub commit geçmişinden otomatik olarak
listelenir.

<a href="https://github.com/skylab-kulubu/e-skylab-keycloak/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=skylab-kulubu/e-skylab-keycloak" alt="Katkıda bulunanlar" />
</a>

## Geliştiren ekip

<div align="center">
  <p>SKY LAB kimlik altyapısı, kulüp ürün ekiplerinin desteğiyle <strong>WebLab</strong> tarafından geliştirilmektedir.</p>
  <a href="https://github.com/skylab-kulubu">
    <img src="https://raw.githubusercontent.com/skylab-kulubu/skylab-assets/main/logos/arge/weblab/weblab-colored.svg" alt="SKY LAB WebLab" width="150" />
  </a>
</div>
