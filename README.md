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
- `/opt/keycloak/providers` altında tam olarak bir SKY LAB SPI (`1.27.0`),
  kaynaktan derlenen bir SKY LAB giriş teması (`2.0.1`) ve bir RabbitMQ olay
  sağlayıcısı (`3.3.0`; yalnız olay kataloğu, kişisel verisiz gövde, arka planda yayın:
  [`docs/keycloak-events-to-rabbitmq.md`](docs/keycloak-events-to-rabbitmq.md)) bulunur.
- `account-api:v1`, PAR, geçiş anahtarları ve WebAuthn imaj derlenirken açıkça
  etkinleştirilir.
- `/` adresi (Keycloak'ın karşılama sayfası) Admin Console'a yönlenmez, e-SKY LAB
  tanıtım sayfasını gösterir: `/opt/keycloak/themes/e-skylab-welcome` klasör
  teması, imajdaki `KC_SPI_THEME__WELCOME_THEME=e-skylab-welcome` ile seçilir
  (çalışma zamanı seçeneği; Dokploy'da ayar gerekmez).
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
tek bir tasarım sistemini paylaşır: renkler, köşe yarıçapı ve yazı tipi
`@skylab-kulubu/skylcn-ui` token'larından gelir, `theme/src/login/legacy-login.css`
bunları giriş rollerine bağlayan tek stil dosyasıdır. `Template.tsx` her sayfayı
giriş sayfasının `LegacyFrame` çerçevesinde (solda sayfa, geniş ekranda sağda
animasyonlu SKY LAB logolu tanıtım paneli, KVKK altbilgisi, dil seçimi) çizer ve bütün metinler `i18n.ts` içinden gelir
(önce Türkçe, sonra İngilizce).

`https://e.yildizskylab.com/` adresini doğrudan açan kişi Keycloak'ın
karşılama sayfası yerine e-SKY LAB'in tanıtım sayfasını görür: e-SKY LAB nedir,
hangi uygulamalarda kullanılır, bugün nasıl giriş yapılır, okul şifresi ve
Microsoft'tan alınan bilgiler (ADR-0063'ün güven metni), Hesap Merkezi ve KVKK
Aydınlatma Metni bağlantıları. Sayfa `theme/src/welcome/` içindeki React
bileşenlerinden (`AnimatedSkyLabLogo`, `YtuMark` giriş temasıyla ortak) derleme
sırasında bir kez durağan HTML'e çevrilir (`npm run build-welcome-theme`); betik,
form ve Admin Console bağlantısı yoktur, Keycloak'ın verdiği değerlerden yalnız
`resourcesPath` kullanılır. Stil dosyası giriş temasının token'larını, yazı
tipini ve `legacy-login.css`'ini aynen içe alır, yalnız sayfa düzenini ekler.
Sayfa Keycloak'ın yalnız `/` yolunu kullanır; `/realms`, `/resources` (kaynaklar
`/resources/<sürüm>/welcome/e-skylab-welcome/` altında), `/admin` ve `/js`
değişmez. Giriş düğmelerinin metni değişince (e-postayla kod, kayıt) bu sayfa da
değişir.

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
- İstemciye özel tarayıcı akışı yoktur: `account-center` realm'in etkin
  tarayıcı akışıyla giriş yapar. SkyApp'ten oturum açık geçiş `sky-handoff`
  ile olur (ADR-0048); eski native handoff köprüsü (`sky-native-handoff`,
  mTLS/HMAC redeem istemcisi) kaldırıldı.
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
- Core claim kapsamı yalnız gerekli `sub` ve `auth_time` alanlarını, bir de
  Hesap Merkezi'nin oturum sınırı ve gömülü görünümü için `sky_session_started`,
  `sky_session_expires` (SPI'daki `sky-session-lifetime-mapper`) ve `sky_embed`
  (yalnız Web handoff oturumunda `"skyapp"`) claim'lerini üretir; ayrıntı
  [`docs/sky-handoff-api.md`](docs/sky-handoff-api.md). Ayrıca kişinin
  `university` ve `department` özniteliklerini aynı adlı düz metin claim'ler
  olarak yalnız access token'a ve introspection'a yazar (ID token ve userinfo'da
  yok, öznitelik yoksa claim yok). core bunlarla YTÜ bağlantılı kişinin
  üniversite, bölüm ve fakültesini yeniler (C2); ayrıntı
  [`docs/v2-identity-reconcile-runbook.md`](docs/v2-identity-reconcile-runbook.md) §9.
- BFF'nin en küçük `openid` isteğine uygun biçimde isteğe bağlı kapsam yoktur.

**Group overage mapper'ı** (ADR-0059; SPI'daki `sky-group-overage-mapper`,
`com.skylab.mapper.SkyGroupOverageMapper`): Keycloak'ın Group Membership mapper'ının Microsoft Entra
sınırlı hâli. Kişinin grup yolu sayısı eşiğe (`overage.threshold`, varsayılan 30) eşit ya da
altındaysa claim'i (`claim.name`, varsayılan `groups`; `full.path`, varsayılan açık) Group Membership
mapper'ı nasıl yazıyorsa öyle yazar (grubu yoksa claim yok). Üstündeyse liste yazılmaz, yerine
Entra'nın işareti gelir: `"_claim_names": {"groups": "src1"}`,
`"_claim_sources": {"src1": {"endpoint": "<kök>/admin/realms/<realm>/users/<id>/groups"}}`. Liste hiçbir
zaman kısaltılmaz (eksik liste "o grupta değil" diye okunurdu). Servisler yalnız işaretin varlığına
bakar (core `_claim_names.groups`; uç noktayı çağırmaz) ve grupları Keycloak'tan sorar; core
`groups` adını okuduğu için `claim.name` varsayılanda kalmalı. Access token, ID token, userinfo ve
introspection aynı kuralla, mapper'ın açık olduğu her yerde. Eşik tam sayı değilse Admin REST mapper'ı
kaydetmez; çalışma anında okunamazsa 30 kullanılır.

Yerleşik Group Membership mapper'ından iki bilinçli sapma (eşiğin altında bile):
`full.path` ayarı **yoksa** tam yollar yazılır (yerleşik mapper ayar yokken yalnız grup adını
yazar; kısa ad isteyen `full.path=false` verir) ve `claim.name` **yoksa** claim `groups` adıyla
yazılır (yerleşik mapper claim adı yokken hiçbir şey yazmaz). Mapper bir istemcide yerleşik grup
mapper'ının **yerini alır**, yanında çalışmaz: ikisi birden açıksa eşiğin üstünde yerleşik mapper
tam listeyi yine yazar ve işaretin anlamı (liste yok) bozulur; açarken aynı claim'i yazan Group
Membership mapper'ı (istemcide ya da varsayılan kapsamlarında) kaldırılır. Uç nokta yalnız bilgidir:
tüketiciler işaretteki `endpoint`'e **hiçbir zaman kimlik bilgisi göndermez** (token, cookie,
istemci secret'ı); grupları kendi yapılandırılmış Keycloak adreslerinden ve kendi yetkileriyle
sorarlar.

**Hiçbir istemcide açık değil**: `admin`'de
Group Membership mapper'ının yerini alması admin-token-authz 14'ün işi (core'un yedeği, panelin
token'dan grup okumayı bırakması ve News rolünden sonra); site istemcilerinde inscribed işareti
anlayana kadar açılmaz. Harness: JUnit (`SkyGroupOverageMapperTest`) ve `tests/group-overage-mapper.sh`
(gerçek imajda atılabilir bir realm: 30 grupta liste, 31'de işaret, grupsuz kişide ikisi de yok).

Realm oturumu, giriş ayarları ve tema `config/account-center-realm.json`
(`editUsernameAllowed=false`, `loginWithEmailAllowed=true`,
`duplicateEmailsAllowed=false`; SSO oturumu 2 saat hareketsizlikte, en geç 8 saatte
biter: `ssoSessionIdleTimeout=7200`, `ssoSessionMaxLifespan=28800`; "Beni hatırla"
açık, o oturum 7 gün hareketsizlikte, en geç 30 günde biter:
`rememberMe=true`, `ssoSessionIdleTimeoutRememberMe=604800`,
`ssoSessionMaxLifespanRememberMe=2592000`; istemci oturumu SSO oturumundan miras
alır, `clientSessionIdleTimeout=0` ve `clientSessionMaxLifespan=0`, yani refresh
token SSO oturumu yaşadıkça yaşar, ayrı bir 30 dakika ya da 10 saat sınırı yoktur),
brute-force koruması ve parola politikası
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

Parolalı girişte kullanıcı adı alanı kullanıcı adını, birincil e-postayı, YTÜ bağlantılı
hesabın okul e-postasını ya da kodla kanıtlanmış kişisel e-postayı alır (K4). Bunu SPI'daki
`sky-username-password-form` (`com.skylab.authenticator.SkyUsernamePasswordFormFactory`) yapar:
Keycloak'ın `UsernamePasswordForm`'u, yalnız araması değişmiş; parola denetimi, brute force,
devre dışı hesap, hata mesajları ve passkey yolu Keycloak'ındır. İki kişiyi gösteren ya da
kanıtlanmamış bir adres, yanlış parolayla aynı cevabı alır. Uzlaştırıcı onu realm tarayıcı
akışı `browser plus passkey`'de `auth-username-password-form`'un yerine, aynı alt akışa ve
aynı önceliğe koyar; `KEYCLOAK_PASSWORD_FORM=auth-username-password-form` geri alır. Ayrıntı ve
geri dönüş sırası:
[`docs/v2-identity-reconcile-runbook.md`](docs/v2-identity-reconcile-runbook.md) §15.

Parola sıfırlamada ("Şifremi unuttum") da aynı dört tanımlayıcı geçer (K4b). Bunu SPI'daki
`sky-reset-credentials-choose-user` (`com.skylab.authenticator.SkyResetCredentialChooseUser`)
yapar: Keycloak'ın `reset-credentials-choose-user`'ı, yalnız araması K4'ünki. Sayfa her girdide
aynı "e-posta gönderildi" cevabını verir; bağlantı her zaman kişinin birincil e-postasına gider,
yazılan adrese değil. Keycloak'ın yerleşik `reset credentials` akışı değiştirilemediği için
uzlaştırıcı onu bir kez `sky reset credentials` adıyla kopyalar, adımı kopyada değiştirir, sonra
realm'i kopyaya bağlar; `KEYCLOAK_RESET_CHOOSE_USER=reset-credentials-choose-user` Keycloak'ın
adımını geri koyar. Ayrıntı ve geri dönüş sırası: runbook §17.

OTP'li kişi parolayı sıfırlarken kayıtlı doğrulayıcısının kodunu girer (Microsoft SSPR ve
Google gibi): uzlaştırıcı kopyanın "Reset - Conditional OTP" alt akışında Keycloak'ın `reset-otp`'si
(yeni doğrulayıcı kurdurur) yerine `auth-otp-form`'u koyar; koşul (`conditional-user-configured`)
aynen kalır, OTP'siz kişiye kod sorulmaz, OTP kaydı silinmez. `KEYCLOAK_RESET_OTP_STEP=reset`
Keycloak'ın adımını geri koyar. Ayrıntı: runbook §17.1.

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

Uzlaştırıcının kimliği kullanıcı ve kimlik sağlayıcısı yetkisi taşımadığı için
üç kimlik korumasını operatör `config/identity-guardrails.sh` ile uygular
(aynı kuru koşu / `--apply` / kcadm prompt düzeni,
`KEYCLOAK_GUARDRAILS_ADMIN_PASSWORD` yalnız `SKY_HARNESS=1` ile): `core`
istemcisinin dört `certificate:*` rolü yoksa oluşturulur (core artık rol
oluşturmaz, yalnız okur); YTÜ Microsoft IdP'si `OBS`'nin `department mapper`
eşlemesi `syncMode=FORCE` olur ve SPI'daki `microsoft-department-mapper`
bölümü her girişte Microsoft Graph'tan yeniler; `service-account-core`'dan
`realm-management/manage-clients` kaldırılır, diğer rolleri kalır (ADR-0048:
bu rol core'a her istemcinin yönlendirme adreslerini ve gizli anahtarlarını
yeniden yazma gücü verir). Entegrasyon testi kuru koşu → uygulama → yazmayan
ikinci koşuyu ve core token'ının rolleri okuyup rol oluşturamadığını doğrular
(runbook §8).

A1c için operatör `config/adopt-legacy-personal-email.sh` ile v2'den önce
konmuş, okul adresi olmayan ve Keycloak'ın link ile doğruladığı birincil
adresleri bir kereye mahsus kişisel e-posta olarak devralır (aynı kuru koşu /
`--apply` / kcadm prompt düzeni, `KEYCLOAK_LEGACY_EMAIL_ADMIN_PASSWORD` yalnız
`SKY_HARNESS=1` ile; çıktı yalnız sayı). Kayıt `email/confirm`'ünkiyle aynıdır
ve aynı SPI koduyla (`PersonalEmailProof`) yazılır; birincil değişmez.
Doğrulanmamış, okul alan adındaki, başkasında olan ya da iki kişiye düşecek
adresler yalnız sayılır. Entegrasyon testi ayrı bir realm'de kuru koşu →
uygulama → yazmayan ikinci koşuyu doğrular (runbook §10).

Faz 2'den önce YTÜ girişiyle açılan hesapların birincil e-postası (`email`) yoktur:
`MicrosoftMapper` ilk girişte adresi siler. Operatör `config/fill-missing-primary-from-school.sh`
ile bu hesaplara bir kereye mahsus okul adresini birincil yapar (eskylab-login-ux bilet 06, karar
O5). Yalnız dört koşulun hepsi sağlanırsa yazar: `email` boş, OBS bağlantısı var, `schoolEmail`
dolu ve geçerli bir adres, adres başka hiçbir hesabın `email`, `schoolEmail` ya da
`personalEmail` değeri değil. Yazılan: `email` = kırpılmış, küçük harfli okul adresi,
`emailVerified=true`; hesabın geri kalanı okunduğu gibi kalır, posta gönderilmez, her yazma bir
UPDATE USER admin olayı bırakır. Koşulu tutmayanlar yalnız sayılır (`noObsLink`, `noSchoolEmail`,
`invalidSchoolEmail`, `taken`); `--skipped-list` onları `0600` izinli yeni bir dosyaya yazar.
Varsayılan kuru koşu, `--apply`; `--realm` yalnız `e-skylab` ya da `e-skylab-sandbox`; kcadm
prompt düzeni ya da `--kcadm-config`. Seçim kodu betiğin içindedir ve imajın JDK'sı ile
derlenir; imaj yayını gerekmez. sky_lab_genel'deki `ops/wizards/eskylab-missing-primary-wizard.sh`
production sunucusunda koşar. Harness `tests/fill-missing-primary-from-school.sh` tek başına
çalışır.

Faz 2'den sonra (eskylab-login-ux bilet 07, ADR-0063 karar 5) ilk YTÜ girişiyle açılan hesap
okul adresini doğrulanmış birincil e-posta olarak alır; boş birincil kalmaz. Bunu SPI'daki
`sky-ytu-first-login` (`com.skylab.authenticator.SkyYtuFirstLogin`) yapar: first broker login
akışının ilk adımıdır, `MicrosoftMapper`'ın boşalttığı aracı e-postasına `schoolEmail`'i
(kırpılmış, küçük harf; yalnız `std.yildiz.edu.tr` ve `yildiz.edu.tr` alan adlarında) yazar. Adres
kimsede yoksa ya da bir hesabın doğrulanmış `email`'i veya (e-postayla giriş açıkken) kullanıcı
adıysa yazılır; ikincisinde
Keycloak'ın hazır "var olan hesap" yolu (onay, sonra yeniden kimlik doğrulama) ikinci hesap
açılmasını önler. Adres başka bir hesabın `schoolEmail`'i, `personalEmail`'i ya da doğrulanmamış
`email`'iyse, ya da IdP `syncMode=FORCE` iken Keycloak'ın bildiği bir adres ya da aracı kullanıcı
adıysa yazılmaz (OBS FORCE'a alınmadan önce adım `off` ile kapatılır) ve profil
sayfası koruma kapalıyken bugünkü gibi çıkar. Bağlama
kipinde ve e-postası gelen kimlikte hiçbir şey yapmaz.
`MicrosoftMapper` değişmedi: bağlı hesapların birincil adresi hiçbir YTÜ girişinde değişmez.
Uzlaştırıcı Keycloak'ın yerleşik `first broker login` akışını bir kez `sky first broker login`
adıyla kopyalar, adımı "review profile"dan önce REQUIRED ekler, profil sayfasını yalnız eksik
alan varsa gösterir (`update.profile.on.first.login=missing`), bağlantıyla doğrulamayı
(`idp-email-verification`) kapatır (ADR-0044), sonra realm'in first broker login bağlamasını
kopyaya çevirir. Bu yalnız açıkça istenince olur: `KEYCLOAK_YTU_FIRST_LOGIN=on` açar, `off` realm'i
yerleşik akışa geri bağlar; varsayılan `keep` bağlamayı olduğu gibi bırakır (tam uzlaştırma
özelliği açıp kapatmaz, bağlı kopyayı yalnız onarır). Kendi ilk giriş akışı seçili olan bir IdP
realm bağlamasını görmez; uzlaştırıcı kimliği IdP okuyamadığı için OBS'yi bir kez operatör oturumu
(`KEYCLOAK_RECONCILE_ONLY=first-broker-login`) realm bağlamasına bırakır. Üretimdeki OBS'nin elle
yapılmış `first broker login for obs` geçersiz kılması da yalnız biçimi yerleşik akışla aynıysa
kaldırılır (adı OBS'ye not edilir, akış silinmez); `off` onu geri yazar (bilet 22). Ayrıntı, üretim sırası ve geri dönüş: runbook §22. Harness
`tests/ytu-first-login.sh` tek başına çalışır (stok imaj, SPI jar'ı, taklit YTÜ kiracısı).

SPI 1.27.0, gerçek e-posta kaydından sonra isteğe bağlı YTÜ bağlama ve native erişim anahtarı/parola
önerilerini ekler. Özgün uygulamanın OIDC callback'i korunur; native YTÜ yetkisi olmayan RP açıklama
ve atlama yolunu kullanır. `KEYCLOAK_AFTER_SIGN_UP=keep` varsayılandır; kayıt ve yayın ayrı kapıdır.
Akış, güvenlik, uzlaştırıcı ve geri dönüş: [Kayıt sonrası seçenekler](docs/after-sign-up-credentials.md).

SPI 1.26.0, e-posta giriş ve mevcut hesaba bağlama kodlarında hesap başına kalıcı ardışık yanlış
kod sayacını ekler: 100 sınırı gün değişiminde ve yeniden başlatmada korunur; gerçek başarılı LOGIN
sıfırlar. Genel ekran/HTTP, günlük bütçeler ve TOTP koşulları korunur. Bakım reseti, UserProfile
API yerine aynı kullanıcı kilitli SQL ile yapılır. Mimari, test ve yayın sırası:
[Kalıcı e-posta kodu hata sınırı](docs/email-code-consecutive-failures.md). Kayıt açılmadan önce
tüm örnekler yeni SPI'ye geçmeli ve yeni alarm şablonu seed edilmiş olmalıdır.

SPI 1.25.0, yeni Microsoft hesabını mevcut SKY LAB hesabına kanıtla bağlamak için
`sky-existing-account-prompt` ekler (bilet 12). `KEYCLOAK_EXISTING_ACCOUNT_PROMPT=on` yalnız etkin
SKY LAB first-broker kopyasında soru, native parola/passkey + TOTP veya current-primary'ye altı
haneli link kodu sunar; varsayılan `keep` kurulmamış özelliği açmaz. Primary ve doğrulama durumu
korunur; native/A6 callback'leri PostgreSQL'de aynı Microsoft subject'in çift hesaba bağlanmasını
engelleyen dar transaction guard'ını paylaşır. `off` yeni adımları geri alır ve pending kanıtları
iptal eder. Ayrıntı, veritabanı şartı ve yayın kapıları:
[`docs/broker-existing-account.md`](docs/broker-existing-account.md), runbook §31.
Gerçek PostgreSQL 17/Keycloak harness'i `tests/existing-account-link.sh` ve CI'daki
`existing-account-link` işidir; test fixture'ları üretim JAR'ına girmez.

Bilet 21'den sonra (SPI 1.18.0) aynı ilk girişin sonunda bir kez kişisel e-posta önerisi çıkar:
"Mezun olunca okul adresin kapanabilir. Kişisel e-postanı ekle." Adres kutusu, [Kod gönder],
[Şimdilik geç]. `sky-ytu-first-login` okul adresini yeni hesabın birincili olarak yazdığında
(adres kimsede yokken) giriş oturumuna SPI'daki `sky-personal-email-offer` gerekli eylemini
(`com.skylab.account.PersonalEmailOffer`) ekler; realm'de eylem kayıtlı ve açık değilse eklemez.
Sayfa gelmeden önce eylem yeniden bakar: hesabı bu oturum açmış olmalı
(`BROKER_REGISTERED_NEW_USER`), birincil hâlâ o doğrulanmış okul adresi olmalı, kişinin
`personalEmail`'i ve `personalEmailOfferSkippedAt` işareti olmamalı; değilse giriş sayfasız
sürer. Bu yüzden bağlanan hesapta, A6'da, YTÜ'süz girişte ve ikinci kez çıkmaz. Kod, Hesap
Merkezi'nin `email/change-request`'iyle aynı ortak parçadan geçer
(`PersonalEmailVerification`: adres kuralı, aynı `sky-personal-email-confirm` postası ve SkyMail
eşlemesi, kanıt kaydı; `PendingEmailChanges`: 6 hane, 10 dakika, 5 yanlışta ölür, tek kullanım,
yalnız tuzlu özet). Kod deposundaki kayıt kullanıcıya değil, yalnız bu giriş oturumunun bir
kimlik doğrulama notunda duran rastgele bir tutamağa bağlıdır; kod başka oturumda ya da Hesap Merkezi'nde
çalışmaz. Gönderim sınırı: giriş oturumu başına 3, adres başına saatte 3, IP sınıfı (IPv4 /24,
IPv6 /64) başına saatte 100, realm genelinde saatte 200 (saat dilimleri); anahtarlar realm'e özel,
realm'in HS512 anahtarından türetilmiş bir alt anahtarla HMAC'tir: IP ve adres saklanmaz, sınıf yalnız
HMAC olarak saat bitene dek bellekte durur. Başka hesabın kullanıcı adı, `email`, `schoolEmail` ya da `personalEmail`'i olan
adres Hesap Merkezi'ndeki gibi `email_taken` ile reddedilir ve bütçeler bu denemeden önce düşülür;
kişinin kendi okul adresi ve üniversite alan adı (`yildiz.edu.tr` ve her alt alan adı, Unicode
benzerleri dahil: alan adı IDNA `toASCII` biçiminde karşılaştırılır) bütçe harcamadan reddedilir
(`email_school_domain`). Doğru kodda `personalEmail` + `personalEmailVerifiedAt` yazılır,
birincil okul adresi kalır, giriş uygulamaya döner. "Şimdilik geç" `personalEmailOfferSkippedAt`
yazar (User Profile'da, yalnız yönetici düzenler). Olaylar `CUSTOM_REQUIRED_ACTION`,
`sky_personal_email_offer` ayrıntısı: `shown`, `code_sent`, `added`, `skip` (ve hatalar). Tema
sayfası `sky-personal-email-offer.ftl` (`theme/src/login/PersonalEmailOffer.tsx`); temasız realm
için SPI'nın kendi yedek şablonu vardır. Uzlaştırıcı: `KEYCLOAK_PERSONAL_EMAIL_OFFER=on` eylemi
kaydeder ve açar, `off` kapatır (geri dönüş), varsayılan `keep` dokunmaz. Ayrıntı: runbook §23.

SPI 1.19.0'dan sonra her YTÜ girişinin sonunda "Bu cihazda oturumum açık kalsın mı?" sorusu çıkar
(Microsoft'un federasyonlu girişten sonraki "Stay signed in?" sorusunun karşılığı, Yusuf'un
2026-10-12 kararı). [Evet, açık kalsın] oturumu beni-hatırla oturumu yapar (realm'in beni-hatırla
süreleri, kalıcı çerez); [Hayır] olağan oturum bırakır, tarayıcı kapanınca biter. Sayfa ortak
bilgisayarda Hayır'ı seçmeyi söyler ve beni-hatırla sürelerini realm'den gün olarak yazar. YTÜ
düğmesi IdP'ye giden bir bağlantıdır: parola formundaki "Beni hatırla" kutusu oraya taşınmaz, bağlı
bir hesabın sonraki YTÜ girişlerinde de realm'e bağlı hiçbir akış çalışmaz. Her girişte çalışan tek
şey realm'in gerekli eylemleridir; soru bu yüzden SPI'daki `sky-stay-signed-in` gerekli eylemidir
(`com.skylab.authenticator.SkyStaySignedIn`). `evaluateTriggers` onu giriş OBS üzerinden geldiyse
kullanıcıya değil giriş oturumuna ekler. Cevap Keycloak'ın kendi `REMEMBER_ME` kimlik doğrulama
notudur; Keycloak kullanıcı oturumunu gerekli eylemlerden sonra bu notla açar
(`AuthenticationProcessor.attachSession`), parola formundaki kutu da aynı notu yazar. Realm'de
beni-hatırla kapalıyken, IdP'ye `prompt=none` ile iletilen pasif girişte (gerekli eylem orada
`interaction_required` olur), `kc_action`'da ve canlı bir oturumun içindeki yeniden kimlik
doğrulamada (`prompt=login`, `max_age`: Keycloak o oturumu olduğu gibi tutar) sorulmaz. Aynı girişte
bir kez sorulur. Olay `CUSTOM_REQUIRED_ACTION`, ayrıntı `sky_stay_signed_in` = `yes` ya da `no`.
Parola ve geçiş anahtarı girişindeki "Beni hatırla" kutusu değişmedi. Tema sayfası
`sky-stay-signed-in.ftl` (`theme/src/login/StaySignedIn.tsx`); temasız realm için SPI'nın yedek
şablonu vardır. SPI 1.22.0'dan sonra soru e-postaya gelen kodla girişte de çıkar (bilet 08b). Uzlaştırıcı: `KEYCLOAK_STAY_SIGNED_IN=on` eylemi kaydeder, açar ve realm'in bütün
gerekli eylemlerinden sonraya koyar (kişisel e-posta önerisinden sonra); `off` kapatır (geri dönüş);
varsayılan `keep` dokunmaz, sıra bozulmuşsa uyarır. Ayrıntı: runbook §24.

SPI 1.20.0'dan sonra Keycloak'ın yeniden kimlik doğrulaması YTÜ'ye iletilir. Keycloak açık bir
oturumu olan kişiden yeniden kimlik doğrulama istediğinde (istemcinin `max_age`'i aşıldı, bir
`kc_action` taze giriş istiyor ya da istemci `prompt=login` gönderdi) YTÜ düğmesi ve
`kc_idp_hint=OBS` Microsoft'a `prompt=login` gönderir; Microsoft kimlik bilgisi ister, açık bir
Microsoft oturumu artık girişi sessiz geçirmez. Microsoft Entra'nın federasyondaki IdP'ye taze
giriş isteğini iletmesinin (`promptLoginBehavior`) karşılığıdır. Bunu SPI'daki
`com.skylab.broker.SkyMicrosoftIdentityProviderFactory` yapar: Keycloak'ın yerleşik `microsoft`
sağlayıcısının yerine aynı kimlikle kaydolur (Keycloak aynı kimlikte özel fabrikayı yerleşiğe
yeğler), bu yüzden OBS'nin ayarına dokunulmaz. Keycloak'ın kendi kararı kullanılır:
`CookieAuthenticator`'ın yazdığı `FORCED_REAUTHENTICATION` notu. Oturumsuz ilk girişte ve geçerli
SSO'da istek değişmez; IdP'de ayarlı ya da istemcinin gönderdiği bir `prompt` olduğu gibi gider.
`SKY_FORWARD_REAUTHENTICATION=false` (ya da SPI seçeneği
`spi-social--microsoft--forward-reauthentication`) Keycloak'ın kendi davranışını geri getirir
(geri dönüş, yeniden başlatmayla; runbook: `docs/keycloak-26.7.4-upgrade-runbook.md` §8); varsayılan
`true`, başka bir değer ERROR loglanır ve `false` sayılır, sunucu yine açılır. İstemcinin
`prompt`'u (boş ya da `none` dahil) Keycloak'ın kuralıyla olduğu gibi gider, ikinci bir `prompt`
eklenmez. Harness
`tests/microsoft-reauthentication.sh` tek başına çalışır (stok imaj, SPI jar'ı, `microsoft` tipinde
OBS; Microsoft'a gidilmez, yalnız Keycloak'ın yönlendirmesi okunur); optimize imajda
`run-integration.sh`'ın `login` grubu da aynı yönlendirmeye bakar.

SPI 1.21.0'dan sonra "E-postayla devam et": herkes e-postasına gelen 6 haneli kodla girebilir
(eskylab-login-ux bilet 08, ADR-0063 karar 2, CONTEXT "Login code"). Bunu SPI'daki `sky-email-code`
(`com.skylab.account.EmailCodeAuthenticator`) yapar: kişi e-posta adresini ya da kullanıcı adını yazar,
kod hesabın birincil e-postasına (birincili olmayan YTÜ hesabında okul adresine) gider, hangi
tanımlayıcı yazılmış olursa olsun (parolalı girişin `LoginIdentifiers` kuralı). Adres sayfası her
girdide aynıdır; hiçbir hesaba çıkmayan, iki kişiye çıkan ya da kapalı bir hesaba çıkan girdi de aynı
kod sayfasını ve hiç postalanmayan bir kodu alır, posta istekten sonra arka planda gider (yanıt süresi
aynı). Kod 6 hane (Yusuf, 2026-10-16; önceki 8 hane kararının yerine), 10 dakika, 5 yanlışta ölür, tek kullanım, yalnız isteyen giriş oturumunda (tarayıcı
ve sekme) çalışır, yalnız tuzlu özeti saklanır (`LoginCodes`, Hesap Merkezi'nin koduyla ortak
`SingleUseCodes`); yeni kod eskisini geçersiz kılar, "yeniden gönder" 60 saniye sonra açılır.
SPI 1.22.1'e geçişte önceki sürümden kalan 8 haneli kodlar kabul edilmez; kişi "Kodu yeniden gönder"
ile bir kez yeni kod ister. Hata hesabın varlığına göre değişmez. Yanlış kod
Keycloak'ın kaba kuvvet sayacına kişinin hatası olarak yazılır; kilitli ya da kapalı kişi doğru kodla da
giremez. Doğru koddan sonra realm'in koşullu OTP'si gelir: TOTP'si olan kişiye TOTP yine sorulur
(ADR-0063 S6). Gönderim sınırı: giriş oturumu başına saatte 5, IP sınıfı başına saatte 100, adres başına
15 dakikada 3 ve günde 10, realm genelinde günde 500 (`SKY_EMAIL_CODE_DAILY_LIMIT`). Adres sınırını aşan
istekte posta gitmez, ekran aynı kalır, oturumun eski kodu da yerini postalanmayan yeni koda bırakır
(güvenlik incelemesi B3: kalan deneme sayısı iki tanımlayıcının aynı hesaba çıktığını söylemesin); genel sınır giriş
kodunu durdurmaz, yarısında ve dolduğunda `/ADMIN` grubunun etkin ve adresi olan üyelerine posta
(`SKY_EMAIL_CODE_ALARM_GROUP`, `off` ile yalnız `sky_email_code_budget` log satırı) gider. Hesap başına
günde yaklaşık 10 yanlış kod (`SKY_EMAIL_CODE_WRONG_CODES_PER_ACCOUNT`, güvenlik incelemesi K2; eşzamanlı oturumlar birkaç deneme aşabilir): tavana
ulaşan hesaba gün bitene kadar kod postalanmaz, ekran aynı kalır, önceden gönderilmiş kod artık
denetlenmez (denemesi yanlış sayılır); günün ilk böyle hesabı aynı alarm grubuna posta, her biri
`sky_email_code_wrong_ceiling` log satırı yazar. Sayfa hiçbir zaman "hesap yok" demez: kimseye
postalanmamış bir kodun tutturulması süresi dolmuş kod gibi görünür (olayda `no_account`). Koddan
sonraki OTP Admin Console'da kapatılırsa OTP'li kişi kodla giremez (`otp_unguarded`, güvenlik incelemesi
K1). Posta SkyMail'in `keycloak.login-code` şablonuyla (SkyMail
yoksa SPI'nın FreeMarker kopyası) çıkar: konuda kod yok, bağlantı yok. Olaylar: başarılı giriş
Keycloak'ın `LOGIN` olayı, ayrıntısı `sky_method=email_code`; her ret `LOGIN_ERROR`, ayrıntısı
`sky_email_code` (`wrong_code`, `rate_limited`, `rate_limited_address`, `account_locked`, …), IP'siz
ve yazılan tanımlayıcı olmadan (olaylar jboss-logging ile sunucu günlüğüne de düşer). Uzlaştırıcı
`KEYCLOAK_EMAIL_CODE_LOGIN=on` realm'in tarayıcı akışında parola alt akışının yanına ALTERNATIVE
`sky email code` alt akışını kurar (`sky-email-code`, koşullu OTP, passkey önerisi), `off` onu
DISABLED yapar (geri dönüş), varsayılan `keep` dokunmaz; operatör adımı
`KEYCLOAK_RECONCILE_ONLY=email-code-login`. Ayrıntı, üretim sırası ve geri dönüş: runbook §29. Harness
`tests/login-by-email-code.sh` tek başına çalışır (stok imaj, SPI jar'ı, SkyMail fixture'ı, Mailpit).
Giriş teması (bilet 08b): ilk ekrandaki e-posta düğmesi, Keycloak adımı `auth.authenticationSelections`'ta
sunuyorsa (`sky-email-code-display-name`) koda geçer, sunmuyorsa bugünkü parola görünümünü açar;
`sky-email-code.ftl` sayfası (`theme/src/login/EmailCode.tsx`) adres ve kod aşamalarını, 60 saniyelik
yeniden gönderme sayacını, `one-time-code` alanını, "Parolanla gir"i ve passkey'i taşır. SPI 1.22.0'dan
sonra "Bu cihazda oturumum açık kalsın mı?" kodla girişte de sorulur (kod sayfasında "Beni hatırla"
yok) ve son sayfa olduğu için `LOGIN` olayının `sky_method=email_code` ayrıntısını korur.

SPI 1.23.0'dan sonra aynı kapıdan e-postayla kayıt (eskylab-login-ux bilet 09, ADR-0063 karar 1, CONTEXT
"Self-registration"); realm başına, varsayılan kapalı. Ayar `sky-email-code` yürütmesinin Keycloak
yapılandırmasındadır (`sign-up`, yapılandırma adı `sky email code sign-up`); Keycloak'ın hazır kayıt
sayfası (`registrationAllowed`) kapalı kalır. Açıkken hiçbir hesaba çıkmayan bir e-posta adresine kayıt
kodu gider (`purpose=signup`, aynı sayfa, aynı bütçeler; genel sınır dolunca yalnız kayıt kodları durur,
yanlış kayıt kodları adres başına aynı günlük tavana sayılır). Doğru kod ayrı bir tema sayfası
(`sky-email-code-sign-up.ftl`, `theme/src/login/EmailCodeSignUp.tsx`) açar: adres salt okunur, ad ve soyad,
KVKK yalnız bilgilendirir. "Hesabı aç" hesabı User Profile ile açar (`ProfileSignUpAccounts`, yönetici
bağlamı, realm'in ad ve adres doğrulamaları): adres doğrulanmış birincil ve kanıtlı kişisel adres
(`personalEmailVerifiedAt`), kullanıcı adı formdaki ad ve soyaddan `ad.soyad` olarak (`SignUpUsernames`: Türkçe/aksanlı harfler ASCII'ye, Hesap Merkezi'nin
`[a-z0-9._]{3,30}` alfabesi, çakışmada sayı), parola, grup ve realm varsayılanı dışında rol yok,
`REGISTER` olayı (`register_method` ve `sky_method` `email_code`; RabbitMQ'ya kimlikleriyle gider,
[`docs/keycloak-events-to-rabbitmq.md`](docs/keycloak-events-to-rabbitmq.md)); kişi girer, oturum notu
`sky-email-code.signed-up` bilet 10'un soruları içindir. YTÜ alan adındaki adres hesap açmaz, YTÜ
girişine (OBS) yönlendirilir. Adres bu arada bir hesaba eklendiyse ikinci hesap açılmaz, kod o hesapla
girer; aynı adresin iki kaydı tek hesap açar (adres başına bir dakikalık kilit ve veritabanının tekil
e-postası). Tema "Hesap aç"ı yürütme seçimiyle birlikte `sky-email-code-intent=sign-up` göndererek
açar; hesabı olan kişi koddan sonra "Bu adresle zaten hesabın vardı, giriş yaptın." görür. Parola formu
sayfası kaydın açık olduğunu `skyEmailCodeSignUp` ile söyler. Uzlaştırıcı `KEYCLOAK_EMAIL_CODE_SIGN_UP=on`
ayarı açar, `off` kapatır (geri dönüş), `keep` dokunmaz; aynı operatör adımı
(`KEYCLOAK_RECONCILE_ONLY=email-code-login`). Canlıda bilet 11 (Sudo e-posta kodu) ve 12 (çift hesap
koruması) olmadan açılmaz; 10 (kayıt sonrası), 13 (hoş geldin) ve 24 (ardışık yanlış kod sayacı) de açılış bağımlılığıdır. Ayrıntı: runbook §30. Harness `tests/sign-up-by-email-code.sh` tek başına
çalışır.

Hesap silmede (ADR-0051) core, SkyMail, CMS ve Forms'a ayrı bir gizli service
account istemcisinden, `core-erasure`'dan aldığı token'larla gider. Operatör
istemciyi, üç isteğe bağlı `account-erase-*` kapsamını ve üç erase rolünü
(`skymail:account:erase`, `cms:account:erase`, `skyforms:account:erase`)
imajdaki idempotent `config/create-erasure-client.sh` ile kurar (aynı kuru koşu /
`--apply` / kcadm prompt düzeni, `KEYCLOAK_ERASURE_ADMIN_PASSWORD` yalnız
`SKY_HARNESS=1` ile). İstemcide `fullScopeAllowed=false` ve doğrudan scope
mapping yoktur; bir rol token'a yalnız onu eşleyen kapsam istendiğinde girer,
böylece bir servise giden token başka bir servisin erase rolünü taşımaz.
Varsayılan kapsamlar `basic` (`sub`) ve `roles`'tür. Uzlaştırıcı istemciyi yalnız
doğrular. Secret'ı OpenBao'ya ve core'un ortamına sky_lab_genel'deki
`ops/wizards/core-erasure-client-wizard.sh` taşır (runbook §11).

CMS inscribed'a geçerken (ADR-0056) operatör site istemcilerinde (`frontend-main`,
`frontend-arge` ve admin panelinin istemcisi: `admin`, sandbox'ta `superadmin`)
inscribed'ın rollerini imajdaki idempotent `config/inscribed-cms-roles.sh` ile kurar
(varsayılan `--check`, `--apply`; kcadm prompt düzeni ya da `--kcadm-config`):
`content:read`, `content:write`, `schema:sync` rolleri; iki sitede ayrıca `cms:access`
(ilk ikisini içeren bileşik rol; sitelerin editör arayüzü ona bakar) ve `client:admin`;
istemcinin kendi rollerini düz `roles` claim'i olarak yalnız access token'a yazan
`inscribed-roles` mapper'ı; access token'da tam yollu `groups` yoksa `inscribed-groups`;
service account'lara `content:read` + `schema:sync`. Hiçbir gruba ya da kişiye rol
vermez: grup → istemci rolü eşlemeleri SKY LAB admin panelinden yapılır; betik hangi
grubun hangi rolü taşıdığını raporlar, kişiye doğrudan atamayı uyarır, varsayılan rol
ya da grupta CMS rolünü sorun sayar. `--post-cutover` (yalnız geçiş gecesi)
`frontend-main` service account'undan `cms:access`'i alır. Başka bir `roles` ya da tam
yolsuz `groups` yayıcısını raporlar, dokunmaz. Uzlaştırıcı bunu doğrulamaz. Üretimde
sky_lab_genel'deki `ops/wizards/inscribed-keycloak-roles-wizard.sh` koşar; harness
`tests/inscribed-cms-roles.sh` tek başına çalışır (runbook §12).

Sandbox realm'inde (`e-skylab-sandbox`) site istemcisi yoktu; sandbox arge girişsiz
çalışıyor, editörü denenemiyordu. Operatör `frontend-arge`'ı imajdaki idempotent
`config/sandbox-site-clients.sh` ile kurar (varsayılan `--check`, `--apply`; kcadm prompt
düzeni ya da `--kcadm-config`). İstemci production'dakinin biçimindedir: gizli, standard
flow ve service account açık, implicit ve direct grant kapalı, `fullScopeAllowed=false` (uzlaştırıcı
production'dakini de daraltır, runbook §21);
redirect `https://sandbox-arge.yildizskylab.com/*`, web origin ve post-logout adresi aynı
host (istemcideki başka adresler korunur). Access token'a `skycms` audience'ı, realm'de
`core` istemcisi varsa uzlaştırıcının biçimindeki `frontend-arge-core-audience` kapsamı ve
tam yollu `groups` gelir. `e-skylab-sandbox` dışındaki her realm'i girişten önce reddeder;
`skycms` istemcisi yoksa hiçbir şey yazmaz. `frontend-main` kurulmaz: sandbox'ta ana site
uygulaması yok. CMS rolleri ardından `inscribed-cms-roles.sh` ile gelir. Sunucuda
sky_lab_genel'deki `ops/wizards/sandbox-arge-keycloak-wizard.sh` ikisini koşar; secret'ı
OpenBao'ya `ops/wizards/arge-dokploy-wizard.sh --sandbox-kc` taşır. Harness
`tests/sandbox-site-clients.sh` tek başına çalışır (runbook §13).

Place'in backend'i (ADR-0060) e-skylab girişini kendisi yürütür: realm `e-skylab`'ın gizli
istemcisi `place`'tir. Operatör istemciyi idempotent `config/create-place-client.sh` ile kurar
(varsayılan `--check`, `--apply`; kcadm prompt düzeni ya da `--kcadm-config`): yalnız standard
flow, PKCE `S256` zorunlu, `fullScopeAllowed=false`, front-channel logout kapalı, dönüş adresi
tam olarak `https://api.place.yildizskylab.com/api/auth/eskylab/callback`, web origin yok;
`place:admin` ve `place:moderator` client rolleri (kimseye verilmez, admin panelinden verilir);
`schoolEmail`'den `school_email` claim'i ve `resource_access.place.roles` (ID token, access token,
userinfo). Place grup okumaz (ADR-0059): grup verisi yazan varsayılan ya da isteğe bağlı
kapsamlar (`microprofile-jwt` dahil) istemciden ayrılır. `school_email`'in tek kaynağı
istemcinin kendi mapper'ıdır: bu claim'i yazan kapsamlar da (production'da elle eklenmiş
mapper'ıyla `profile`) yalnız `place`'ten ayrılır; realm kapsamı ve öteki istemciler
değişmez. `e-skylab` dışındaki her realm'i girişten önce reddeder. Uzlaştırıcı bu istemciyi
yönetmez; imaj yayını gerekmez. Sunucuda sky_lab_genel'deki
`ops/wizards/place-keycloak-client-wizard.sh` betiği koşar ve secret'ı doğrudan OpenBao'ya taşır.
Harness `tests/place-client.sh` tek başına çalışır (runbook §14).

Forms (forms-backend) SkyMail'den tek tek posta gönderir (`POST /v1/mail_tasks/single`); SkyMail
token'daki `resource_access.skymail.roles`'ta `skymail:access` ve `skymail:mails:send` (ya da daha
geniş `skymail:mails:write`) arar. Bu yetki iki realm'de de elle verilmişti, sandbox'ta hiç
yoktu: her sandbox Forms postası 403 `server.forbidden` aldı. Operatör `config/forms-skymail-grants.sh`
ile `service-account-forms`'a eksik olanı verir (varsayılan `--check`, `--apply`; kcadm prompt
düzeni ya da `--kcadm-config`; `KEYCLOAK_REALM` yalnız `e-skylab` ya da `e-skylab-sandbox`):
`skymail:access`, ve `skymail:mails:write` tutmuyorsa `skymail:mails:send`; `forms`'un
`fullScopeAllowed`'ı kapalıysa aynı roller kapsam eşlemesine. Hiçbir şey silinmez, SkyMail rolü
oluşturulmaz; `skymail:mails:write` NOTE olarak kalır. Uzlaştırıcının kimliği kullanıcı yetkisi
taşımadığı için bu bir operatör betiğidir; imaj yayını gerekmez (betik `--kcadm-config` ile
dışarıdan da koşar). Harness `tests/forms-skymail-grants.sh` tek başına çalışır.

Admin panelinin istemcisini (`admin`, sandbox'ta `superadmin`; ADR-0058) uzlaştırıcı daraltır.
İstemci iki realm'de de elle kurulmuş ve gizlidir; uzlaştırıcı onu yerinde benimser, id'sine,
secret'ına, adreslerine ve kendi mapper'larına dokunmaz. Access token'ın `aud`'u tam olarak
`core`, `forms`, `skycms` olur (üçü de `admin-panel-api-audience` varsayılan kapsamındaki sabit
audience mapper'larından, `config/admin-panel-api-audience-mappers.json`), `realm_access`
kalkar, `resource_access` yalnız `core`, `forms` ve istemcinin kendi rollerini taşır: "Full scope
allowed" kapanır, rol kapsamında `core` ve `forms` istemcilerinin her rolü bulunur, başka istemci
ya da realm rolü bulunmaz. `groups` ve inscribed'ın düz `roles` claim'i kalır. Standard Token
Exchange açılır: panelin sunucusu token'ı `audience=core|forms|skycms` ile tek audience'lı bir
token'a çevirebilir; başka bir audience reddedilir. Exchange yalnız daraltır: `aud` tek API olur,
`resource_access` yalnız o API'nin rollerini taşır; `sub`, `azp`, `sid`, `groups`, düz `roles` ve
profil claim'leri aynen kalır, yeni claim eklenmez, token panelin token'ından uzun yaşamaz. Bu
sözleşme ve core, forms-backend ve inscribed'ın token'dan okuduğu claim'ler
`tests/admin-panel-exchanged-token.jq`'dadır (runbook §16). Sıra canlı paneli bozmaz: önce audience ve
API rolleri, en son tam kapsamın kapanması. `core` ya da `forms`'ta uzlaştırıcı dışında
oluşturulan bir rol panelin token'ına bir sonraki koşuda girer. Adım en son koşar. İstemci yoksa
uyarıyla atlanır; public ise koşu ona hiçbir şey yazmadan hata verir (gizliye çevirmek panelin
secret'la girmesini gerektirir; o panelin işidir). Sandbox realm'inde uzlaştırıcı kimliği yoktur: operatör aynı adımı
kendi kcadm oturumuyla tek başına koşar (`KEYCLOAK_RECONCILE_KCADM_CONFIG` +
`KEYCLOAK_RECONCILE_ONLY=admin-panel-client`; tam uzlaştırma operatör oturumuyla koşmaz).
Sunucuda sky_lab_genel'deki `ops/wizards/admin-panel-keycloak-sandbox-wizard.sh` koşar
(runbook §16).

Giriş istemcilerini (`frontend-main`, `frontend-arge`, `skymail`; ADR-0058, ADR-0059) de uzlaştırıcı
uygulamalarının çağırdığı API'lere daraltır (`reconcile_login_clients`). Üçü production'da elle ve tam
kapsamla kurulmuştu: token kişinin bütün audience'larını, realm rollerini ve başka istemcilerin
rollerini taşıyordu. Ne gerektiği uygulamaların `origin/main`'inden ölçüldü (2026-10-05): siteler (ana
site ve editörü, arge) inscribed'a (`aud` `skycms`, tenant `azp`, istemcinin kendi rollerinden düz
`roles`, koleksiyon kurallarında tam yollu `groups`) ve görsel yüklemede core `POST /v1/media`'ya (`aud`
`core`, rol ya da grup gerekmez) gider; SkyMail arayüzü yalnız SkyMail'e gider, SkyMail de kendi
rollerini (`resource_access.skymail`) ve Keycloak userinfo'dan `sub`, ad ve e-postayı okur, grup okumaz
(posta listelerinin grupları kendi servis hesabıyla okunur). Sözleşme: audience'lar varsayılan
kapsamlardaki sabit Audience mapper'larından gelir (sitelerde `frontend-<site>-core-audience` ve ortak
`skycms-audience`, SkyMail'de `skymail-api-audience` → `aud` `skymail`); rol kapsamında realm rolü ve
başka istemcinin rolü yoktur (istemcinin kendi rolleri, yani `cms:access`, `content:*`, `client:admin`,
`skymail:*`, her zaman geçer); "Full scope allowed" kapanır. Siteler tam yollu `groups`'u tutar;
SkyMail'in token'ında `groups` olmaz: `groups` yazan varsayılan ya da isteğe bağlı kapsamlar (realm'in
`groups` kapsamı, `microprofile-jwt`) yalnız `skymail`'den ayrılır, `skymail`'in kendi grup mapper'ı
silinir. Ortak `skycms-audience` kapsamı `site-clients.sh`'in kurduğu biçime getirilir: production'daki
tek mapper'ı hiçbir audience adlandırmıyordu ve sitelerin `skycms`'i yalnız audience-resolve'dan, yani
tam kapsamdan geliyordu; tam kapsam kapanmadan önce sabit audience gelmeseydi editör 401 alırdı. Sıra
uygulamaları bozmaz: önce audience'lar, en son tam kapsamın kapanması. Secret'a, adreslere, bayraklara
ve istemcilerin kendi mapper'larına dokunulmaz; eksik istemci uyarıyla atlanır. Sitelerin editör kapısı
(`@skylab-kulubu/inscribed-auth` 0.3.1) `cms:access`'i token'daki herhangi bir istemcide aradığı için
tam kapsamda başka bir sitenin `cms:access`'i bu sitenin editörünü açıyordu (inscribed yazmayı yine
reddediyordu); daraltmadan sonra her site yalnız kendi `cms:access`'ine bakar. Keycloak kapsamdaki
rollerin bileşenlerini de açar ve istemcinin kendi rolleri hep kapsamdadır: `skyapp-cms-editor.sh`
SkyApp'in CMS rollerini `frontend-main`'in `cms:access` ve `client:admin`'ine bağladıktan sonra bir
editörün ana site token'ı o `skyapp` rollerini ve `aud skyapp`'i de taşır (hiçbir servis okumaz;
inscribed sitenin kendi düz `roles`'una bakar). Sandbox realm'inde
operatör adımı tek başına koşar (`KEYCLOAK_RECONCILE_KCADM_CONFIG` +
`KEYCLOAK_RECONCILE_ONLY=login-clients`). Harness `tests/login-clients.sh` tek başına çalışır
(runbook §21).

Admin paneli (core-frontend) yerelde `next dev` ile `http://localhost:3000`'te sandbox'a karşı
geliştirilir. Sandbox panelinin istemcisi `superadmin` localhost dönüşünü kabul etmez ve öyle kalır
(adresleri ve secret'ı yayındaki sandbox panelinindir). Yerel geliştirme için ayrı istemciyi,
`admin-local`'ı, idempotent `config/sandbox-admin-local-client.sh` kurar (varsayılan `--check`,
`--apply`, `--revoke`; kcadm prompt düzeni ya da `--kcadm-config`). İstemci public'tir: secret yok,
core-frontend PKCE `S256` ile girer ve secret'ı yalnız `OAUTH2_CLIENT_SECRET` doluysa gönderir;
yalnız standard flow, dönüş adresi tam olarak `http://localhost:3000/api/auth/callback`, web origin
`http://localhost:3000`, çıkış dönüşü `http://localhost:3000/*`; başka adres silinir. Token'ı
uzlaştırıcının daralttığı panel token'ıdır: `fullScopeAllowed=false`, rol kapsamında `core` ve
`forms`'un her rolü ve panel istemcisinin kendi rolleri; varsayılan ve isteğe bağlı kapsamlar
`superadmin`'inkiler, ek olarak `admin-panel-api-audience` (`aud` core, forms, skycms; kapsam
uzlaştırıcınındır, burada yazılmaz, yoksa koşu hiçbir şey yazmadan durur); `superadmin`'in rollerini
düz `roles` claim'ine yazan `inscribed-roles` mapper'ı; tam yollu `groups` bir varsayılan kapsamdan
gelmiyorsa `groups` mapper'ı. `superadmin` yalnız okunur. İki fark istemci adından gelir: `azp`
`admin-local`'dır ve kişi panelin bir rolünü taşıyorsa `aud`'da `superadmin` de bulunur.
`superadmin`'de bunların dışında kalan bir mapper NOTE olarak bildirilir, kopyalanmaz. Public
istemci Standard Token Exchange yapamaz: panelin sunucusu token değiştirdiğinde (BFF) istemci
gizliye döner ve secret geliştiriciye şifreli ulaştırılır. `e-skylab`'ı adıyla, `e-skylab-sandbox`
dışındaki her realm'i girişten önce reddeder. Sunucuda sky_lab_genel'deki
`ops/wizards/sandbox-admin-local-client-wizard.sh` koşar; harness
`tests/sandbox-admin-local-client.sh` tek başına çalışır.

core'un kaynak rollerini (ADR-0059: `event:manage`, `ticket:manage`, `certificate:manage`,
`users:manage` gibi 11 yeni rol, var olan `url:moderator`, `url:access` ve yarışma modülünün
`competition:manage`'ı) uzlaştırıcı her koşuda
`core` istemcisinde var eder ve admin panelinin adımından önce koşar. Yazma rolleri Privileged
gruplardan `ADMIN` ve `YK`'ya, DK'nın okuma rolü `global:read` yalnız `DK`'ya, denetim kaydının
`audit:read`'i üçüne (`/<AD>` ya da `/UYELER/<AD>`) **bir kez** verilir; rol özniteliği
`skylab.seeded-group-mappings` bunu kaydeder ve sonraki koşular SKY LAB admin panelinde değişen
eşlemelere dokunmaz, hiçbir eşlemeyi silmez. Gruba rol vermek kullanıcı yetkisi istediği için bunu
uzlaştırıcı kimliği değil operatör yapar: `KEYCLOAK_RECONCILE_KCADM_CONFIG` +
`KEYCLOAK_RECONCILE_ONLY=core-roles`; uzlaştırıcı işaretsiz rolleri uyarıyla bildirir. Rol listesi
sky_lab_genel'deki admin-token-authz spec'inin sözleşme tablosudur (runbook §19).
`competition:manage`, `competitor:manage`'ın yeni adıdır (ADR-0068; geçişte core ikisini eşdeğer
okur): Privileged gruplara değil, operatör koşusunda eski rolün o an bulunduğu her yere (gruplar,
kullanıcılar, kompozit roller, rol kapsamları) bir kez verilir; eski rol silinmez (runbook §19.1).

core'un servis rollerini (`media:attach`: ADR-0052, Forms'un core'a Media bağlaması ve anonim form
yüklemesi; `ticket:forms`: Forms'un cevap bildirimi, core `docs/form-response-tickets.md`; `url:forms`:
forma bağlı kısa linkler; `users:read`: kişi profili; `consent:record`: rıza kaydı, core
`docs/contact-consents.md`, runbook §20.2; Place'in servis istemcisi `place-service`'te de, yalnız
o rol) uzlaştırıcı her koşuda `core` istemcisinde var eder;
`forms`'un `fullScopeAllowed`'ı kapalıysa rolleri onun kapsam eşlemesine ekler ve `aud: core`'u
veren varsayılan `roles` kapsamını doğrular, yoksa ekler (ikinci audience mapper eklenmez).
`place-service`'i (gizli, yalnız client credentials, `fullScopeAllowed=false`, redirect yok; sırrı
Keycloak üretir, uzlaştırıcı okumaz) uzlaştırıcı kimliği tam uzlaştırmada oluşturur; bu yalnız
production'dadır, sandbox'ta uzlaştırıcı kimliği ve `place-service` yoktur. Place'in giriş istemcisi
`place` dar kalır (runbook §20.2). Roller `service-account-forms`'ta bulunur; servis hesabına rol vermek kullanıcı yetkisi istediği için bunu
operatör yapar (`KEYCLOAK_RECONCILE_KCADM_CONFIG` + `KEYCLOAK_RECONCILE_ONLY=service-roles`; eski adı
`media-attach` de çalışır). `KEYCLOAK_RECONCILE_CHECK=true` aynı adımı kuru koşar: yalnız eksikleri
`would …` diye yazar, hiçbir şey yazmaz. Adım önce her şeyi okur, okuma hatasında hiçbir şey vermez
(eksik varsayılan `roles` kapsamı hariç: onu okuma sırasında ve tam uzlaştırmada da ekler, runbook §20.1),
verdikten sonra rolün `skylab.granted-service-accounts` özniteliğine kaydeder; yalnız servis
hesaplarına ait rolleri (`services` sınıfı; kişilerin de taşıyabildiği `users:read` ve SkyMail'in
paylaşılan rolleri değil) taşıyan başka kullanıcı, grup, varsayılan rolü ya da onları içeren bileşik
rolü, servis hesabının listede olmayan rollerini bildirir ve hiçbir şey silmez. `forms` yalnız servis hesabıdır (Forms kişileri `skyforms`
ile giriş yaptırır; core ürünü `client_id == azp`'den okur): uzlaştırıcı `standardFlowEnabled`,
`implicitFlowEnabled`, `directAccessGrantsEnabled`'in kapalı olduğunu doğrular, değilse uyarır;
operatör adımı açık olanları kapatır (kuru koşuda `would set …`). `media:attach`'ın istemci listesi
core'un `MEDIA_SERVICE_CLIENTS`'ıyla aynı tutulur (runbook §20).
Aynı adım SkyMail'in servis hesabına (`skymail-backend`) core'un `audience:read` rolünü (core #242,
haber ve duyuru kitlesi), `communication-preferences:read` rolünü (core #256, kimin takip
edilebileceği) ve `consent:audience:read` rolünü (rıza kaydının davet ve tanıtım kitlesi, runbook §20.2) ile `realm-management`'ın `view-users` ve `view-clients` rollerini (Admin REST'ten kişi okuma; production'da 2026-09-23'ten beri elle verilmişti), core'un servis hesabına SkyMail'in `skymail:access`, `skymail:mails:send`,
`skymail:lists:read`, `skymail:lists:write`, `skymail:notifications:send` (skymail-backend #79, `POST /v1/notifications`;
yalnız `service-account-core`) ve `skymail:tracking:withdraw` (skymail-backend #75, takibi
geri alma; yalnız `service-account-core`) rollerini, Template seed'in servis hesabına
(`skymail-seed`) `skymail:templates:system`'ı (yalnız o bir şablonu sistem şablonu yapar ya da
işareti kaldırır; skymail-backend README) verir; SkyMail'in rollerinden yalnız
`skymail:notifications:send`'i, `skymail:tracking:withdraw`'u ve `skymail:templates:system`'ı oluşturur, öbürleri eksikse uyarır (runbook §20.1); listelenen servis istemcisinde varsayılan `roles` kapsamı yoksa ekler (runbook §20.1). SkyMail'in kendi
rolleri `skymail:access`, `skymail:templates:read`, `skymail:lists:read`, `skymail:mails:read`,
`skymail:mails:send`, `skymail:mails:write` ADMIN ve YK'ya, `skymail:mails:approve` yalnız YK'ya
(onaycı YK kökü) aynı biçimde bir kez tohumlanır; uzlaştırıcı onları oluşturmaz, realm'de olanı
tohumlar. `skymail:announcements:send` listeden çıktı (okuyan yok; ekip-yetkileri bilet 03), var olan
eşlemeleri kalır (runbook §25).
`skymail:mails:tracking:read` (gönderimlerin kişi bazındaki açılma ve tıklama raporu) aynı biçimde
ADMIN, YK ve DK'ya bir kez tohumlanır; okuma rolüdür, DK'da kalır (runbook §25). Forms'un
salt okur rolü `skyforms:read-all` (DK her formu ve cevabı okur, yazamaz; forms-backend henüz okumuyor)
aynı biçimde `forms` istemcisinde var edilir ve yalnız DK'ya bir kez verilir (runbook §28). Forms
koltuğu `skyforms:access` ADMIN, YK ve DK'ya, `skyforms:*` (bütün formları okuma) yalnız YK'ya bir kez
tohumlanır (bilet 03, S4); ikisi de Forms'un rolüdür, oluşturulmaz. SkyCloud'un yönetici rolü `skycloud`
`admin` (Yusuf, 2026-10-24) yalnız `core-roles` adımında ADMIN ve YK'ya aynı biçimde bir kez tohumlanır;
istemci production'da elle kuruludur, ne o ne rolü oluşturulur, istemci yoksa uyarıyla atlanır (runbook
§33.6). Yönetim panelinin istemcisindeki (`admin`, sandbox'ta `superadmin`) inscribed rolleri de yalnız
`core-roles` adımında aynı biçimde bir kez tohumlanır: `content:read` ADMIN, YK ve DK'ya, `content:write`
ADMIN ve YK'ya (panelin Duyurular sayfası bunlarla yazar; DK okur). Rolleri `inscribed-cms-roles.sh`
yapar, burada oluşturulmaz (runbook §33.7).

DK salt okurdur (grup-yonetimi 08; Entra'nın Global Reader + Reports Reader'ı: `global:read` +
`audit:read`). Uzlaştırıcı bir eşlemeyi hiç geri almadığı için DK'nın eskiden aldığı yazma rollerini
(core'un 13 yazma rolü, site istemcilerinin `cms:access`'i ve benzerleri) tek seferlik operatör
betiği `config/dk-read-only.sh` kaldırır: kuru koşu varsayılan, `--apply` yedeğin yolunu ilk satırda
yazar, önce yedeği yazar, sonra site yazma rolünün yerine `content:read` verir ve yazma rollerini
kaldırır; ikinci koşu 0 değişiklik; `--restore <yedek>` geri verir. Kişinin kendi uygulama rolleri
(`url:access`: kendi kısa linkleri; Forms koltuğu `skyforms:access` ve ekran rolleri) kalır. Okuma
rolleri yoksa (önce `core-roles`) ya da DK'nın altında varsayılan grup varsa yazmaz; DK'nın alt
gruplarındaki ve üst gruptan gelen yazma rollerini yalnız bildirir. Forms'un yönetici rolleri
(`skyforms:*`, `skyforms:feedback:*`) forms-backend `skyforms:read-all`'u okuyana kadar kalır; sonra
`--forms` yalnız onları kaldırır. Uzlaştırıcının adımı değildir; Yusuf'un
onayıyla, önce sandbox'ta koşulur (runbook §28). Harness `tests/dk-read-only.sh` tek başına çalışır.

Uygulama rolü grupları `/ROLLER/<UYGULAMA>-<ROL>` (Entra'nın uygulama rolü güvenlik grupları;
`config/role-groups.json`) ve en üst ekiplerin Leader gruplarına `skycloud:access` iki operatör
betiğiyle kurulur (Forms koltuğunu Leader gruplarına artık `leader-app-roles.sh` yazmaz: uygulama
rolüdür, panelindir): `config/role-groups.sh` ve `config/leader-app-roles.sh` (kuru koşu varsayılan, `--apply`
yazar, ikinci koşu 0 değişiklik; uzlaştırıcıda `KEYCLOAK_RECONCILE_ONLY=role-groups` ve
`leader-app-roles`). Hiçbiri üye eklemez ya da bir şey almaz; `role-groups.sh --audit` doğrudan rol
sahiplerini ve izinli yerler dışındaki grup eşlemelerini kişi adı basmadan sayar (runbook §26, §27).
Harness `tests/role-groups.sh` tek başına çalışır.

Kod alanı ve panel alanı (ekip-yetkileri bilet 03; Microsoft Entra'nın Enterprise app modeli): rol
tanımları, "atama gerekli" (`config/app-assignments.json`, tam olarak core'un uygulama rolleri;
`tests/check-app-assignments.sh` core'un kopyasıyla karşılaştırır), Privileged kökler, `/ROLLER`,
yönetici rolleri, servis hesapları ve varsayılan rol koddadır; uygulama rolünün ekip grubuna ya da
kişiye ataması panelindir ve uzlaştırıcı ona dokunmaz. Operatör adımları:
`KEYCLOAK_RECONCILE_ONLY=app-assignments` (her eşlemeyi `KOD|…` ya da `PANEL|…` satırıyla sınıflar,
yalnız okur), `default-roles` (`broker/read-token`'ı varsayılan rolden ve onun içindeki bileşik rollerden, ör.
`USER`, alır, IdP'lerde "Stored tokens readable"ı kapatır; kuru koşulu), `tohum-atamalar` (tek seferlik başlangıç ataması: bütün en üst
ekiplere SkyForms, Leader gruplarına ve ALGOLAB'a SkyMail "onaya gönder"; yedekli, işaretli, ikinci
kez uygulanmaz). `KEYCLOAK_RECONCILE_CHECK=true` tam uzlaştırmanın ve `core-roles`'ın kuru koşusudur:
her yazma `would kcadm …` satırıdır, hiçbir şey yazılmaz. `skyforms`'un token'ı `skyforms-core-audience`
kapsamıyla `aud: core` taşır (Forms'un kişi seçicisi core'u kişinin token'ıyla çağırır). Ayrıntı:
runbook §33.

Etkinlik siteleri (ARTLAB, YıldızJam, SkyDays) da canlıdaki inscribed'ın tenant'larıdır (ADR-0056
eki, 2026-10-03). Site istemcilerini (`frontend-artlab`, `frontend-yildizjam`, `frontend-skydays`)
idempotent `config/site-clients.sh` kurar; realm açıkça verilir (`KEYCLOAK_REALM=e-skylab` ya da
`e-skylab-sandbox`; başkası ve boş değer girişten önce reddedilir). İstemciler gizli, PKCE `S256`,
`fullScopeAllowed=false`, servis hesabı açık; dönüş adresi birebir
`https://<site>/api/auth/callback/keycloak` (sandbox'ta `sandbox-<site>`), localhost yok; `aud`'a
`skycms` ortak `skycms-audience` kapsamından, `core` site başına `frontend-<site>-core-audience`
kapsamından gelir; tam yollu `groups`, `groups`'u başka biçimde yazan kapsam (ör.
`microprofile-jwt`) yalnız bu istemciden ayrılır. Elle yapılmış `frontend-main` ve `frontend-arge`
yalnız raporlanır; tek istisna ana sitenin sandbox'ı: `site-clients.sh --site main` yalnız
`e-skylab-sandbox`'ta `frontend-main`'i aynı biçimde `https://sandbox.yildizskylab.com` için kurar
(production'da reddedilir). `site-editor-grants.sh --site main` ise production'da da koşar: ana sitenin
`cms:access`'ini bugün taşıyan en üst ekip Leader grupları koddadır (`MAIN_SITE_TEAMS_E_SKYLAB`,
bilet 03 Ek-2).
Ardından `inscribed-cms-roles.sh --client frontend-<site>` rolleri kurar (servis
hesabına yalnız `content:read` + `schema:sync`) ve `config/site-editor-grants.sh` `cms:access`'i
`ADMIN` ve `YK` gruplarına, sahip lab takımının ve etkinliğin organizasyon takımının
(`/UYELER/ORGANIZASYON/<ETKİNLİK>`) `LIDERLER`/`KOORDINATORLER` gruplarına, `client:admin`'i
`ADMIN` ve `YK`'ya, `content:read`'i `DK`'ya (DK okur, yazmaz) verir; kişiye vermez, hiçbir şeyi geri
almaz. sky_lab_genel'deki
`ops/wizards/site-cms-setup-wizard.sh` üçünü koşar, secret'ı OpenBao'ya taşır. Harness
`tests/site-clients.sh` tek başına çalışır (runbook §18). `site-clients.sh --shared-scope`
yalnız ortak `skycms-audience` kapsamını kurar ya da onarır, hiçbir site istemcisine dokunmaz
(`--site` ile birlikte verilemez). Production'daki kapsam elle yapılmıştı ve tek mapper'ı
`audience-mapper` hiçbir audience adlandırmıyordu (2026-09-21 realm dökümü): `skycms`'i yalnız
bir `skycms` rolü taşıyanın token'ına audience-resolve koyuyordu. Kapsamda yalnız `skycms`'i
adlandıran (ya da hiç adlandırmayan) başka bir Audience mapper'ı, kapsamın kendi mapper'ı
yerindeyken silinir; başka audience adlandıran mapper PROBLEM'dir ve kalır.

SkyApp de ana sitenin haber ve takım sayfalarını düzenler (ADR-0056 eki, 2026-10-03): uygulama
inscribed'ın ortak `news`/`teams` koleksiyonlarına kişinin kendi `skyapp` token'ıyla doğrudan
yazar; köprü sunucu ve SkyApp tenant'ı yoktur. İdempotent `config/skyapp-cms-editor.sh`
(`KEYCLOAK_REALM` açıkça; varsayılan `--check`, `--apply`) `skyapp`'te `content:read`,
`content:write`, `cms:access` (ilk ikisinin composite'i; uygulamanın düğmeleri
`resource_access.skyapp.roles`'e bakar) ve `client:admin` rollerini kurar; bunları hiçbir gruba
vermez, `frontend-main`'in `cms:access`'ine ve `client:admin`'ine composite olarak bağlar. Böylece
Site editor tek yerden (panelde `frontend-main`) atanır. `skyapp`'e ortak `skycms-audience`
kapsamını ve `inscribed-roles` mapper'ını ekler; tam yollu `groups`'u doğrular. `skyapp`'in
bayraklarına, adreslerine ve öteki kapsamlarına dokunmaz; `skyapp` rolünün doğrudan atanmasını
uyarır, `frontend-main` rollerini doğrudan (grupsuz) taşıyan kişi ve servis hesaplarını sayar.
Kaynak her iki realm'de `frontend-main`'dir (sandbox'ınki #65'ten beri var); `skyapp`'in CMS
rollerini içeren başka her rol, başka bir `roles`/`groups` yayıcısı ya da mapper adı çakışması PROBLEM'dir ve
eksik önkoşul gibi hiçbir şey yazılmadan koşuyu durdurur (çıkış 1). `--revoke`, `skyapp`'in CMS
rollerine başka rollerden giden her bağı alır (`frontend-main`'in ikisi ve varsa başka istemci ya
da realm rolünden gelenler): sonraki token yenilemesinde kimse bir composite üzerinden SkyApp
rolü almaz. `skyapp` rolünün bir gruba ya da kişiye doğrudan atanması `--revoke`'la gitmez; betik
bunu WARNING olarak gösterir, panelden kaldırılır. `--drop-covered-direct` (varsayılan
`--check`, `--apply` ile yazar; `--revoke` ile verilemez) yalnız kurulumdan sonra kalan doğrudan
atamaları temizler: bir `skyapp` CMS rolünün gruba ya da kişiye doğrudan atamasını, o grup (ya da üst
grubu) veya kişi (doğrudan, bir grubu ya da composite üzerinden) aynı rolü içeren bir
`frontend-main` rolünü (`cms:access`, `client:admin`) zaten taşıyorsa kaldırır. Kapsama her ilke
ve her rol için yalnız `frontend-main`'den hesaplanır, yani kimsenin rolü değişmez; kapsanmayan
atama WARNING olarak kalır. `skyapp`'in CMS rollerinden biri başka bir rol içeriyorsa bu modda
PROBLEM'dir ve hiçbir şey yazılmaz. Önce `inscribed-cms-roles.sh --client
frontend-main` ve `skycms`'i access token'a yazan bir `skycms-audience` kapsamı gerekir
(`site-clients.sh --shared-scope` kurar ya da onarır); eksik önkoşulda hiçbir şey yazmaz. Harness
`tests/skyapp-cms-editor.sh` tek başına çalışır.

`account-center` realm'in etkin tarayıcı akışını kullanır; böylece
production'a özel parola, OTP ve passkey davranışı olduğu gibi geçerlidir ve
uzlaştırıcı o akışa hiç yazmaz. Native handoff döneminden kalan kurulumda
uzlaştırıcı istemcinin `browser` akış bağlamasını kaldırır ve eski
`account-center-browser` akışını alt akışıyla birlikte siler; ikisi de yoksa
hiçbir şey yazmaz (`unchanged`). Bilinmeyen mapper, rol ve kapsamlar izin
listeleriyle temizlenir.

Realm'in `eventsListeners` alanında uzlaştırıcı yalnız `keycloak-to-rabbitmq`'yu yönetir:
`KEYCLOAK_RABBITMQ_EVENTS=on` ekler, `off` çıkarır, varsayılan `keep` yalnız raporlar;
`e-skylab-sandbox` realm'inde `on` reddedilir (RabbitMQ R07,
[`docs/keycloak-events-to-rabbitmq.md`](docs/keycloak-events-to-rabbitmq.md)).

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
`view-clients`, `manage-realm`, `view-realm`; kullanıcı yetkisi yoktur). Tek istisna, operatörün
kendi kcadm oturumuyla tek başına koştuğu admin paneli adımıdır (yukarıda).
`account-center-config` istemcisinin oluşturulması veya gizli anahtarının döndürülmesi ayrı ve
denetlenebilir bir başlangıç adımıdır; ana yönetici bilgileri normal Compose
yığınına girmez.

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
  e-posta doğrulayıcısıyla sınar, küçük harfe çevirir, kişinin kendi adreslerini,
  üniversite alan adını ve her alt alan adını (`400 email_school_domain`, `field: "address"`;
  `confirm` de yeniden bakar) ve başkasında olan adresleri (kullanıcı adı, `email`, `schoolEmail`,
  `personalEmail`; büyük/küçük harf gözetmeden) reddeder (`409 email_taken`), kişiye hiçbir şey yazmadan
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
  bearer'ıyla çalışmaz, süresi dolunca `sudo_expired` döner. `aud`
  `["sky-account","core"]`'dur: core hesap silmede kanıtı kendi gizli
  istemcisiyle Keycloak introspection'ına sorar (Keycloak yalnız audience'taki
  istemciye cevap verir). Her başarılı
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
brute-force sayımını ve kilidi, sudo oturum bağını, sudo token'ın `core`
istemcisiyle introspection'ını (audience dışındaki `account-center` ve kapanmış
oturumun token'ı `active:false` alır), taze giriş kanıtını (ID
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
assertion ile sudo → yeniden oynatılan challenge, gerileyen sayaç, izinsiz
origin'den assertion ve kayıt reddedilir. Ceremony iki kez koşar: önce her şey
`localhost`'ta, sonra üretimdeki üst alan adı ilişkisiyle (K3b-t): passkey
`http://my.yildizskylab.test:18081`'de kaydedilir, Keycloak'a
`http://e.yildizskylab.test:18080`'den (yalnız bu koşuda realm frontend URL'si)
girilir, RP ID `yildizskylab.test`'tir. Kardeş alt alan adı
(`other.yildizskylab.test`) sunucuda, başka bir kayıtlı alan adındaki sayfa
(`my.attacker.test`) tarayıcıda reddedilir. Bu adlar yalnız Chromium içinde
`--host-resolver-rules` ile `127.0.0.1`'e çözülür ve güvenli bağlam sayılır
(üretimde TLS var). Tek etiketli bir üst ad (`my.localtest` için RP ID
`localtest`) olmaz: tarayıcı RP ID olarak yalnız kayıtlı bir alan adı kabul eder.

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
`linkExpirationMinutes`, `code`, `codeExpirationMinutes`, `firstName`, `username`,
`realmDisplayName` ve `subjectKey` her postada, bilinmiyorsa boş string olarak
gönderilir. Kişisel e-posta postası link değil kod taşır ve sky-account'un
`EmailResource.TEMPLATE` sabitiyle eşlenir. SMTP test
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
dosyasına (`root:root`, `0640`; Keycloak süreci uid 1000, gid 0 ile çalışır ve
dosyayı grup üzerinden okur) yazar ve bu dosya salt okunur olarak
`/run/secrets/sky-mail/client.secret` yoluna bağlanır. Production Keycloak bir
Dokploy uygulamasıdır ve bu Compose dosyasını kullanmaz: bağlama ve `SKY_MAIL_*`
değişkenleri Dokploy'da elle tanımlanır. Anahtar her token isteğinde okunur; döndürme dosyanın içeriğini
yerinde güncellemekle yapılır. Eşleme tablosu, değişkenler, ortam, geri düşüş
sözcükleri ve operatör adımları
[`docs/keycloak-mail-via-skymail.md`](docs/keycloak-mail-via-skymail.md)
belgesindedir.

## sky-handoff API (SkyApp'ten web'e geçiş)

`sky-handoff` uzantısı (`/realms/{realm}/sky-handoff/v1`, ADR-0048) SkyApp'in bir
SKY LAB sitesini WebView'inde oturum açık açmasını sağlar; tam sözleşme
[`docs/sky-handoff-api.md`](docs/sky-handoff-api.md).

- `POST handoffs`: SkyApp bearer token'ı (çevrimiçi ya da offline oturum,
  `azp=skyapp`, `sid`) ve `{target, path}` ile 45 saniyelik, tek kullanımlık kod
  ve kod başına kanıt (`X-Sky-Handoff-Proof`) verir; kişi başına 30 / 5 dk.
- `GET open?code=`: kanıtı denetler, kodu atomik tüketir, özgün `auth_time` ve
  `sky.embed=skyapp` notlu yeni bir tarayıcı oturumu kurar (başka kişinin oturumu
  varsa kapatır) ve hedefin giriş kapısına `303` ile gönderir; her hata
  `v1/failed?reason=` sayfasına düşer: giriş temasının LegacyFrame tasarımında,
  neden başına bir cümle ve "Uygulamaya dönüp tekrar dene.", form ve giriş
  bağlantısı yok (tema sayfayı çizemezse yerleşik düz sayfa).
- Hedefler istemci öznitelikleridir (`sky.handoff.enabled`, `signInPath`,
  `returnParam`); köken her zaman `https://*.yildizskylab.com`.
- `GET admin/targets` / `PUT admin/targets/{clientId}`: superadmin sayfasının
  kullandığı dar yönetim uçları; yalnız `/ADMIN` grubunun üyeleri (alt grup
  üyeliği de sayılır), yalnız superadmin'in `admin` istemcisinin (`azp`) çevrimiçi
  token'ıyla. Grup `KC_SPI_REALM_RESTAPI_EXTENSION__SKY_HANDOFF__ADMIN_GROUP` ya da
  `SKY_HANDOFF_ADMIN_GROUP`, istemci `..._ADMIN_CLIENT` ya da
  `SKY_HANDOFF_ADMIN_CLIENT` ile değişir; grup yoksa herkes `403` alır. Yalnız üç
  öznitelik yazılır, her değişiklik eski → yeni değerli bir yönetim olayı bırakır.

Entegrasyon testi (`tests/sky-handoff-contract.sh`, `tests/run-integration.sh`
tarafından çağrılır) kodu alma, kanıtsız/yanlış
kanıtlı açılış, sayfasız `account-center` girişi ve özgün `auth_time`, tekrar
(`used`), 45 saniye (`expired`), kapatılan hedef, devre dışı kişi, iptal edilen
offline oturum, başka kişinin oturumunun değiştirilmesi, hız sınırı, olaylar ve
kod/kanıt/yolun günlüğe düşmemesini gerçek Keycloak üzerinde doğrular.

## Yerel geliştirme ve doğrulama

Gereksinimler: Docker, `bash`, `curl`, `jq`, `openssl` ve Node.js (sky-account
sözleşmesindeki TOTP kodları `tests/totp-code.mjs` ile üretilir).

```bash
docker build --platform linux/amd64 -t account-keycloak:test .
KEYCLOAK_TEST_IMAGE=account-keycloak:test bash tests/run-integration.sh
```

Harness tek koşuda bütün aşamaları sırayla koşar (varsayılan `INTEGRATION_GROUP=all`).
CI aynı betiği altı paralel işte koşar
(`integration (erasure|roles|roles-noop|login|login-rollback|spi)`, sonra hepsini bekleyen
`integration`; gruplar `theme` işini beklemez):
her grup kendi Keycloak'ını açar, ortak realm önekini (bootstrap, ilk uzlaştırma,
drift, ikinci uzlaştırma) koşar, sonra kendi aşamalarını. Önceki bir grubun
aşamalarına dayanan grup önce o aşamaların yazdığı durumu kurar (sözleşmelerini
değil). Grupların içeriği `tests/run-integration.sh`'ın başında; her aşama değişimi
CI günlüğüne `[harness <grup> +12m34s] <aşama>` diye geçer. Tek grup yerelde:

```bash
INTEGRATION_GROUP=login KEYCLOAK_TEST_IMAGE=account-keycloak:test bash tests/run-integration.sh
```

**CI'ın iki boyu (`ci.yml`; `mode` karar verir, `scope (full|fast)` işi hangisi olduğunu söyler).**
`main`'e açılan PR'lar *hızlı kümeyi* koşar: `static` (sürüm sabitleri, iş akışı
bağlantıları, tema sözleşmeleri, imaj derlemesi ve içindeki SPI/RabbitMQ Maven testleri,
operatör betiklerinin statik denetimleri), `theme` ve kısa sözleşme işleri; her biri yalnız
okuduğu yollar değiştiyse (`theme/`, `spi/`, ya da `theme/`, `spi/`, `docs/`, `*.md`
dışındaki her şey). Uzun Keycloak işleri ve `integration (<grup>)` grupları PR'da koşmaz.
`main`'e açılan PR'da `tests/` ve `config/` yolları "her şey" sayılmaz: yalnız o yolu
(doğrudan veya dolaylı, yorum satırları hariç) okuyan ya da çalıştıran işler koşar
(`tests/affected-jobs.sh --pull-request`; harness Playwright dosyaları `theme/tests/` de). Bu,
hızlı kümenin kısa işleri ve PR süresine (15 dk) sığan tam takım işleri (`dk-read-only`,
`sandbox-admin-local-client`, `after-sign-up-native`) içindir. 15 dakikayı aşan tam takım işleri
(`PR_DEFERRED`: `integration (<grup>)` grupları, `role-groups`, `site-clients`, `login-clients`,
`skyapp-cms-editor`, `ytu-first-login`, `inscribed-cms-roles`) PR etkilese de PR'da koşmaz; adları
`scope` günlüğüne, koşu özetine ve PR'ın kontrol sayfasına uyarı (`::warning::`) olarak yazılır,
`main` push'unun tam koşusunda koşarlar (yayından önce).
PR'da da koşsunlar istenirse PR'a `full-ci` etiketi konur. Hiçbir iş akışının ulaşmadığı bir
`tests/` ya da `config/` dosyası PR'ın koşabileceği bütün işleri koşturur; izlenen her dosya ya
bir işe ulaşır ya da `LOCAL_ONLY` listesindedir (`check-fresh-runner.sh` denetler). Hızlı
`production` koşusu (terfi) tam takım işi koşturmaz: ağacı zaten tam test edildi. Bu koşuların
makbuzları yayın kanıtı sayılmaz (bulucu yalnız tam push, gece ve elle koşularına bakar).
*Tam takım* `main` push'unda, her gece (01:23 UTC), elle (`gh workflow run ci.yml --ref <dal>`)
ve `full-ci` etiketli PR'larda (etiket PR açılırken/push'ta okunur; etiket eklenince
`full-ci.yml` dalın başında hemen elle bir tam koşu başlatır; bu koşunun `gate`'i aynı commit'teki
en yeni `gate` olur ve PR'ın birleşim (merge) commit'ini değil dalın başını test eder) koşar. `ci.yml` `labeled` olayında
koşmaz: başka bir etiketin koşusu atlanmış (`skipped`) bir `gate` bırakırdı, GitHub atlanan zorunlu
kontrolü geçmiş sayar ve aynı commit'in kırmızı `gate`'ini örterdi. `production`'a açılan
PR'lar ve `production` push'u, ağaçlarını tamamen yeşil bir tam koşu zaten test ettiyse (yayın
PR'ı ve yayın push'u, `main` push koşusundan sonra) hızlı kümeyi koşar; etmediyse (hotfix) tam
takımı. Kanıtı `tests/find-green-full-ci-run.sh` bulur: yalnız push, gece ya da elle koşuları
sayılır (PR koşusu GitHub'ın merge commit'ini test eder), `scope (full)` ve her iş başarılı
olmalı. Tek zorunlu kontrol `gate`: bir iş düşer ya da iptal olursa kırmızı; tam koşuda atlanan
iş de kırmızı; `mode`'un seçimini olayla karşılaştırır, terfi eden bir production koşusunda
bulucuyu yeniden koşar. Aynı PR'a yeni push eskisini iptal eder; `main`'e yeni push da `main`'in eski push koşusunu
iptal eder (yalnız en yeni ağaç yayınlanır, eskisi ara ağaçtır). Grup anahtarında olay adı var:
push koşusu gece/elle/PR koşusunu iptal etmez; `production` push'u, gece ve elle koşular hiç
iptal edilmez.

**Test edilen baytlar terfi eder.** Tam koşuda `candidate` imajı bir kez derler, `docker save`
ile kaydeder ve `keycloak-ci-candidate` artifact'i olarak 14 gün saklar (SHA-256'sı ve imaj
kimliği işin çıktısıdır). Her `integration (<grup>)` işi bu tarball'ı indirir, SHA-256'sını ve
yüklenen imajın kimliğini doğrular, kendi grubunu koşar ve geçerse `keycloak-ci-tested-<grup>`
makbuzuna grubu, ağacı, imaj kimliğini ve SHA-256'yı yazar.

`release.yml` hiçbir şey derlemez ve test etmez. `keycloak-build` yayının güncel `production`
commit'ini gösterdiğini denetler, aynı ağacın tamamen yeşil tam `ci.yml` koşusunu bulur
(production `main`'in squash'ı olduğu için commit değil ağaç karşılaştırılır), o koşunun
adayını ve bütün makbuzlarını indirir; `tests/run-integration.sh`'ın `INTEGRATION_GROUPS`
satırındaki her grubun makbuzunun bu ağacı, bu imaj kimliğini ve tarball SHA-256'sını birebir
söylediğini, tarball'ın SHA-256'sını ve yüklenen imajın kimliğini doğrular. `keycloak-package`
aynı tarball'ı o koşudan indirir, fiziksel WebAuthn kapısını (`keycloak-production` ortamının
değişkenleri, exact production commit'i) koşar ve tarball'ın kendisini paketler;
`keycloak-publish` önceki gibi onu `keycloak-build`'in çıktılarına karşı doğrulayıp yayımlar.
`keycloak-package` Touch ID kapısından, `keycloak-publish` GHCR girişinden hemen önce yayının
hâlâ güncel `production` commit'ini gösterdiğini (`git ls-remote`) yeniden denetler: yeniden
koşturulan eski bir yayın `:production`'ı ezemez. Yayınlar tek tek koşar
(`concurrency: keycloak-release`, koşan iptal edilmez). Hotfix'te (ağaç `main`'de test
edilmedi) `production` push'unun kendi `ci.yml` koşusu tam koşar; yeşil olunca yayın yeniden
koşturulur (`gh run rerun <run> --failed`).
`keycloak-package` ve `keycloak-publish` (GHCR'a itme ve Dokploy kancası) `keycloak-production`
ortamında koşar; ortamın dağıtım politikası yalnız `production` dalını ve `v*` etiketlerini kabul
eder. Dokploy kancası (`DOKPLOY_DEPLOY_HOOK`) bu ortamın sırrı olacak şekilde taşınır
(`ops` sihirbazı; taşınana kadar ortam işi depo sırrını okur). `tests/check-fresh-runner.sh`
bunu ve iş akışı düzenini (izinler açık yazılı, yalnız `keycloak-publish` paket yazar ve sır okur,
`pull_request_target` yok) dürüst gerilemelere karşı denetler; güvenlik sınırı değildir: bir
dalın kendi iş akışı bu denetimden kaçar. Sınır ortam politikası, ruleset'ler ve paketin erişim
ayarıdır; GHCR'a itme bugün `GITHUB_TOKEN` ile yapıldığından ortama bağlı değil.

CI adayının ömrü 14 gün: Touch ID kanıtı beklenirken yayın (`gh run rerun <run> --failed`, Touch
ID adımı yeniden koşar) adayın kalan ömrü boyunca yeniden denenebilir. Paket artifact'i Touch ID
geçtikten sonra oluşur ve 3 gün yaşar; 3 gün yalnız paket ile `keycloak-publish`'in yeniden
denenmesi arasındaki sınırdır, daha geçse yayın koşusu baştan başlatılır. Ağacın tam koşusu 14 günden eskiyse (adayı silinmişse
bulucu onu kanıt saymaz) `gh workflow run ci.yml --ref production` ile yenisi alınır: `production`'ın
ağacını test eder (`main` o zamana kadar ayrışmış olabilir).

Tek Keycloak'ta bütün aşamaların sırayla koşusu (`INTEGRATION_GROUP=all`) artık ne CI'da ne
yayında var; `.github/workflows/integration-all.yml` onu haftada bir (pazartesi 03:17 UTC, main)
ve elle (`gh workflow run integration-all.yml`) koşar. Yalnız test eder: secret, ortam, kayıt
defteri ya da dağıtım yok.

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

Tanıtım sayfası (`/`) derlenip gerçek Keycloak'ta (stok imaj, geliştirme
kipi, derlenen tema salt okunur bağlı) şöyle açılır ve denetlenir:

```bash
(cd theme && npm run build-welcome-theme) && bash tests/check-welcome-theme.sh
bash tests/welcome-page.sh   # Docker; stok Keycloak 26.7.4, port 18096
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
   reddetmesi, `keycloak-mailer`, `core-erasure` (erase kapsamı başına tek rol ve
   `aud`, core token'larının değişmemesi), admin panelinin dar token'ı ve Standard
   Token Exchange'i, sapma onarımı, değişiklik üretmeyen üçüncü
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


### E-posta koduyla Sudo (SPI 1.27.0)

Hesap Merkezi’nde parola, passkey ve TOTP’si olmayan kişi doğrulanmış birincil
adresine altı haneli kod alıp hassas işlemi onaylayabilir. YTÜ bağlantılı kişiye
Microsoft yedeği de sunulur. `identity.sudoEmailCodeAvailable` capability’si
uygunluğu bildirir; send ve verify uygunluğu ayrıca yeniden kontrol eder.
Kod realm/kullanıcı/oturuma ve o anki birincile bağlı, 10 dakika, 5 yanlışta
geçersiz, tek kullanımlıdır. Gönderim 3/saat, doğrulama Sudo bütçesi ve mevcut
brute-force korumasıyla sınırlıdır.

Sözleşme: [sky-account API](docs/sky-account-api.md),
[yerel/sandbox kabul planı](docs/sudo-email-code-test-plan.md).
Önce SkyMail `keycloak.login-code` şablonunun `purpose=sudo` dalı hazır olmalı;
ardından Keycloak, sonra account-center yayımlanır. Bu sürüm kayıt ayarını
kendiliğinden açmaz. Endpoint’lerin yüklenmesi uygun mevcut hesaplara API’de
e-posta Sudo imkânı verir; bağımsız aç/kapat ayarı yoktur.
