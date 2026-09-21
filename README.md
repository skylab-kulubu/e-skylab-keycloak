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
- `/opt/keycloak/providers` altında tam olarak bir SKY LAB SPI (`1.9.0`),
  kaynaktan derlenen bir SKY LAB giriş teması (`2.0.1`) ve bir RabbitMQ olay
  sağlayıcısı (`3.1.0`) bulunur.
- `account-api:v1`, PAR, geçiş anahtarları ve WebAuthn imaj derlenirken açıkça
  etkinleştirilir.
- Realm ve istemci ayarları `config/reconcile-account-center.sh` ile sürekli
  uzlaştırılır; tek seferlik realm içe aktarımına güvenilmez.
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
- Özel varsayılan istemci kapsamı yalnız Account API audience değerini ve
  `manage-account` / `view-profile` rollerini taşır. Roller yalnız bu izole
  kapsamda sabitlenir; realm kullanıcılarına veya diğer istemcilere genel rol
  verilmez. Böylece mevcut ve yeni kullanıcıların Account Center token'ları
  gerekli öz-servis yetkisini taşırken yetki sınırı istemcide kalır.
- Core claim kapsamı yalnız gerekli `sub` ve `auth_time` alanlarını üretir.
- BFF'nin en küçük `openid` isteğine uygun biçimde isteğe bağlı kapsam yoktur.

Realm oturumu, AIA, tema ve şifresiz WebAuthn ayarları
`config/account-center-realm.json` içinde kaynak kontrolündedir. İstemciye özel
tarayıcı akışı realm'in etkin tarayıcı akışından kopyalanır; böylece production'a
özel parola, OTP ve passkey davranışı korunur. Uzlaştırıcı kaynak akışı salt
okunur kabul eder, yalnız izole native handoff dalını ekler ve kopya saparsa onu
yeniden kurar. Bilinmeyen mapper, rol ve kapsamlar izin listeleriyle temizlenir.

Sürekli uzlaştırma yalnız servis amaçlı `account-center-config` istemcisiyle
kimlik doğrular. Bu istemcinin oluşturulması veya gizli anahtarının döndürülmesi
ayrı ve denetlenebilir bir başlangıç adımıdır; ana yönetici bilgileri normal
Compose yığınına girmez.

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
  `POST credentials/password` (`logoutOtherSessions` ile);
  `POST credentials/totp/setup|confirm`; `POST credentials/webauthn/options|register`
  (passkey kaydı); `DELETE credentials/{id}` (OTP ve passkey; parola asla).
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
  kanıt `CUSTOM_REQUIRED_ACTION` (`action=sky-sudo`, `method=password|totp|passkey`)
  olayı bırakır.
- Brute-force koruması realm'de açıksa her parola/TOTP sudo denemesi Keycloak'ın
  kendi koruyucusuna bildirilir (kapalıysa açılışta tek bir uyarı günlüğe düşer;
  reconcile K2 açar). Keycloak 26.7.4 passkey kategorisini saymaz: başarısız
  passkey denemesi brute-force sayacını artırmaz, başarılısı temizlemez; mevcut
  kilit yine passkey ile sudo'yu da engeller. Passkey denemelerinin kısıtı
  kendi `sudo-passkey` bütçesidir. Kullanıcı başına atomik hız sınırları:
  sudo 10 / 15 dk, passkey sudo 10 / 15 dk, TOTP onayı 10 / 15 dk,
  değişiklikler 30 / 15 dk.
- Realm User Profile'ı yönetilmeyen öznitelikleri kişiye açıyorsa
  (`unmanagedAttributePolicy=ENABLED`) değişiklik uçları `503` ile kapanır,
  okuma sürer.
- Hatalar RFC 7807 (`application/problem+json`): İngilizce `code`, Türkçe
  `detail`. Parola, kod, sır ve token günlüğe yazılmaz.
- YTÜ Microsoft IdP alias'ı `SKY_ACCOUNT_YTU_IDP_ALIAS` ortam değişkeniyle
  (varsayılan `OBS`) ayarlanır.

Entegrasyon testi (`tests/sky-account-contract.sh`, `tests/run-integration.sh`
tarafından çağrılır) gerçek Keycloak üzerinde bearer korumasını, YTÜ kilidini,
brute-force sayımını ve kilidi, sudo oturum bağını, parola politikasını,
diğer oturumların kapatılmasını, TOTP kurulum/onay/giriş/silme akışını,
kullanıcı adı kurallarını, hız sınırını, passkey uçlarının şeklini ve sudo
kapısını, ve olay kayıtlarını doğrular. Passkey ceremony'si ayrı bir Playwright
adımıyla (`theme/tests/integration/webauthn-passkey.spec.ts`,
`tests/webauthn-page.mjs` üzerinden `http://localhost:18081`) sanal authenticator
ile uçtan uca sınanır: seçenek → oluştur → kaydet → `GET identity`'de görünür →
Keycloak'ın kendi giriş sayfasında o passkey ile giriş (RP ID uyumu) → passkey
assertion ile sudo → yeniden oynatılan challenge, izinsiz origin ve gerileyen
sayaç reddedilir.

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
   olay yayını sözleşmeleri gerçek servislerle sınanır.
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
