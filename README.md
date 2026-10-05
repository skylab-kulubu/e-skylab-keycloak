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
- `/opt/keycloak/providers` altında tam olarak bir SKY LAB SPI (`1.16.0`),
  kaynaktan derlenen bir SKY LAB giriş teması (`2.0.1`) ve bir RabbitMQ olay
  sağlayıcısı (`3.1.1`) bulunur.
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
tek bir tasarım sistemini paylaşır: renkler, köşe yarıçapı ve yazı tipi
`@skylab-kulubu/skylcn-ui` token'larından gelir, `theme/src/login/legacy-login.css`
bunları giriş rollerine bağlayan tek stil dosyasıdır. `Template.tsx` her sayfayı
giriş sayfasının `LegacyFrame` çerçevesinde (solda sayfa, geniş ekranda sağda
animasyonlu SKY LAB logolu tanıtım paneli, KVKK altbilgisi, dil seçimi) çizer ve bütün metinler `i18n.ts` içinden gelir
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
flow ve service account açık, implicit ve direct grant kapalı, `fullScopeAllowed=true`;
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
token'a çevirebilir; başka bir audience reddedilir. Sıra canlı paneli bozmaz: önce audience ve
API rolleri, en son tam kapsamın kapanması. `core` ya da `forms`'ta uzlaştırıcı dışında
oluşturulan bir rol panelin token'ına bir sonraki koşuda girer. Adım en son koşar. İstemci yoksa
uyarıyla atlanır; public ise koşu ona hiçbir şey yazmadan hata verir (gizliye çevirmek panelin
secret'la girmesini gerektirir; o panelin işidir). Sandbox realm'inde uzlaştırıcı kimliği yoktur: operatör aynı adımı
kendi kcadm oturumuyla tek başına koşar (`KEYCLOAK_RECONCILE_KCADM_CONFIG` +
`KEYCLOAK_RECONCILE_ONLY=admin-panel-client`; tam uzlaştırma operatör oturumuyla koşmaz).
Sunucuda sky_lab_genel'deki `ops/wizards/admin-panel-keycloak-sandbox-wizard.sh` koşar
(runbook §16).

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
`users:manage` gibi 11 yeni rol ve var olan `url:moderator`, `url:access`) uzlaştırıcı her koşuda
`core` istemcisinde var eder ve admin panelinin adımından önce koşar. Roller Privileged gruplara
(`ADMIN`, `YK`, `DK`; `/<AD>` ya da `/UYELER/<AD>`) **bir kez** verilir; rol özniteliği
`skylab.seeded-group-mappings` bunu kaydeder ve sonraki koşular SKY LAB admin panelinde değişen
eşlemelere dokunmaz, hiçbir eşlemeyi silmez. Gruba rol vermek kullanıcı yetkisi istediği için bunu
uzlaştırıcı kimliği değil operatör yapar: `KEYCLOAK_RECONCILE_KCADM_CONFIG` +
`KEYCLOAK_RECONCILE_ONLY=core-roles`; uzlaştırıcı işaretsiz rolleri uyarıyla bildirir. Rol listesi
sky_lab_genel'deki admin-token-authz spec'inin sözleşme tablosudur (runbook §19).

core'un servis bağlama rolünü `media:attach` (ADR-0052; Forms'un core'a Media bağlaması ve anonim
form yüklemesi) uzlaştırıcı her koşuda `core` istemcisinde var eder; `forms`'un `fullScopeAllowed`'ı
kapalıysa rolü onun kapsam eşlemesine ekler ve `aud: core`'u veren varsayılan `roles` kapsamını
yalnız doğrular (ikinci audience mapper eklenmez). Rol yalnız `service-account-forms`'ta bulunur;
servis hesabına rol vermek kullanıcı yetkisi istediği için bunu operatör yapar
(`KEYCLOAK_RECONCILE_KCADM_CONFIG` + `KEYCLOAK_RECONCILE_ONLY=media-attach`): önce her şeyi okur,
okuma hatasında hiçbir şey vermez, verdikten sonra rolün `skylab.granted-service-accounts`
özniteliğine kaydeder, rolü taşıyan başka kullanıcı, grup ya da varsayılan rolü bildirir ve hiçbir
şey silmez. İstemci listesi core'un `MEDIA_SERVICE_CLIENTS`'ıyla aynı tutulur (runbook §20).

Etkinlik siteleri (ARTLAB, YıldızJam, SkyDays) da canlıdaki inscribed'ın tenant'larıdır (ADR-0056
eki, 2026-10-03). Site istemcilerini (`frontend-artlab`, `frontend-yildizjam`, `frontend-skydays`)
idempotent `config/site-clients.sh` kurar; realm açıkça verilir (`KEYCLOAK_REALM=e-skylab` ya da
`e-skylab-sandbox`; başkası ve boş değer girişten önce reddedilir). İstemciler gizli, PKCE `S256`,
`fullScopeAllowed=false`, servis hesabı açık; dönüş adresi birebir
`https://<site>/api/auth/callback/keycloak` (sandbox'ta `sandbox-<site>`), localhost yok; `aud`'a
`skycms` ortak `skycms-audience` kapsamından, `core` site başına `frontend-<site>-core-audience`
kapsamından gelir; tam yollu `groups`, `groups`'u başka biçimde yazan kapsam (ör.
`microprofile-jwt`) yalnız bu istemciden ayrılır. Elle yapılmış `frontend-main` ve `frontend-arge`
yalnız raporlanır; tek istisna ana sitenin sandbox'ı: `--site main` yalnız `e-skylab-sandbox`'ta
`frontend-main`'i aynı biçimde `https://sandbox.yildizskylab.com` için kurar (production'da reddedilir).
Ardından `inscribed-cms-roles.sh --client frontend-<site>` rolleri kurar (servis
hesabına yalnız `content:read` + `schema:sync`) ve `config/site-editor-grants.sh` `cms:access`'i
Privileged gruplara, sahip lab takımının ve etkinliğin organizasyon takımının
(`/UYELER/ORGANIZASYON/<ETKİNLİK>`) `LIDERLER`/`KOORDINATORLER` gruplarına, `client:admin`'i
yalnız `ADMIN`'e verir; kişiye vermez, hiçbir şeyi geri almaz. sky_lab_genel'deki
`ops/wizards/site-cms-setup-wizard.sh` üçünü koşar, secret'ı OpenBao'ya taşır. Harness
`tests/site-clients.sh` tek başına çalışır (runbook §18).

`account-center` realm'in etkin tarayıcı akışını kullanır; böylece
production'a özel parola, OTP ve passkey davranışı olduğu gibi geçerlidir ve
uzlaştırıcı o akışa hiç yazmaz. Native handoff döneminden kalan kurulumda
uzlaştırıcı istemcinin `browser` akış bağlamasını kaldırır ve eski
`account-center-browser` akışını alt akışıyla birlikte siler; ikisi de yoksa
hiçbir şey yazmaz (`unchanged`). Bilinmeyen mapper, rol ve kapsamlar izin
listeleriyle temizlenir.

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
