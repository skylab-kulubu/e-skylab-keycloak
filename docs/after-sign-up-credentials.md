# Kayıt sonrası isteğe bağlı YTÜ, erişim anahtarı ve parola (bilet 10)

SPI **1.27.0** kayıt sonrası iki soruyu ekler: önce okul hesabı, sonra “Girişini kolaylaştır”.
Ad ve soyad, hesabı açan e-posta kayıt formunda zorunludur (#106); bu ekranlar yeniden isim istemez.
Parola ve erişim anahtarı isteğe bağlıdır. Özellik varsayılan **OFF**; bu kaynak değişikliği yayın,
realm ayarı, kayıt açılışı veya rol/scope grant'i yapmaz.

## Akış ve özgün uygulamaya dönüş

`sky-after-login`, yalnız e-posta kodu child flow'undaki eski `passkey-offer-authenticator` yerine
konur. Normal girişte değiştirilmemiş `PasskeyOfferAuthenticator` sınıfına delege eder: mevcut
passkey, 30 günlük susturma, Account Center/AIA atlaması ve yes/no davranışı korunur. Parola
branch'indeki eski offer execution'ına dokunulmaz.

Yeni kayıt dalı yalnız hesabı gerçekten açan #106'nın server
`sky-email-code.signed-up=true` notundan başlar. Kapsül bu notu bir kez tüketir. Sayfalar:

1. `sky-after-sign-up-school.ftl`: gerçek native yetki varsa “YTÜ hesabımı bağla” ve “Şimdi değil”.
   Yetki yoksa bağlama düğmesi gösterilmez; “Okul hesabını daha sonra Hesap Merkezi’nden
   bağlayabilirsin” açıklaması ve “Devam et” ikinci sayfaya geçirir. Desteklenmeyen forged link
   POST'u da sahte başarı veya 403 çıkmazı üretmez; aynı sayfada kalır, skip kullanılabilir.
2. `sky-after-sign-up-credentials.ftl`: önerilen erişim anahtarı, native parola belirleme veya
   “Şimdilik geç”. Sadece bu authentication-session'a hazır `webauthn-register-passwordless`
   ya da `UPDATE_PASSWORD` eklenir; kalıcı user required action, özel parola formu/hash/endpoint yoktur.
   Parola politikasını ve WebAuthn törenini Keycloak yürütür. Kodla giriş kullanılmaya devam eder.

Özgün RP/client, redirect_uri, state, nonce ve S256 PKCE korunur. Bütün uygulamalar Account
Center'a yönlendirilmez; OIDC code/state başka uygulamaya taşınmaz. Generic RP'deki YTÜ bağlantısı
ilk fazda sonraya bırakılabilir; bu durum parola/passkey/skip seçeneklerini kapatmaz.

## Native YTÜ kapısı ve sıralama

Temel iki ekran enabled, standard browser flow açık `openid-connect` RP'de geçerli signup kapsülü
ve etkin `sky-sign-up-credentials` action'ı ister. Native credential action'lar Account API rol/scope
kapısını paylaşmaz.

Anında native YTÜ linki ayrıca aynı account rolü için gerçek `user.hasRole` **ve** `client.hasScope`
(`manage-account` veya `manage-account-links`), enabled `OBS`, enabled native `idp_link` ister.
OBS gerçek `microsoft` provider'ı olmalı; Keycloak 26.7.4'ün kendi factory seçimi
`SkyMicrosoftIdentityProvider` üretmelidir. First-broker override yalnız null veya realm default
root'un tam ID'si olabilir; root'ta tek doğrudan REQUIRED existing-account prompt gerekir.
Nested/disabled/duplicate prompt veya stock/missing factory native bağlantıyı kapatır. Yeni grant,
recursive validator veya global provider/commit-guard değişikliği yoktur; B12/B24 korumaları sürer.

YTÜ seçimi yalnız `kc_action=idp_link` ve `kc_action_parameter=OBS` client notes'unda yürür;
`idp_link` session required-action listesine eklenmez, enforced yapılmaz. İkinci sayfa önceden
planlanmaz. `SignUpCredentialsRequiredAction.evaluateTriggers`, native AIA bittikten ve kendi
success/cancelled/error durumunu yazdıktan sonra ikinci sayfayı ekler; yalnız B10'un terminal
status/OBS parameter notları tüketilir. Terminal broker conflict/error ekranı atlanmaz, bağlı sonucu
uydurulmaz. Sayfa2/native credential action'lar en sondaki SkyStaySignedIn sorusundan önce çalışır.

Mevcut girilmiş ad/soyad ve kişisel primary korunur. Graph adını güncelleyen yeni hook yoktur;
“adın doğrulanır” sözü verilmez. OBS linki nedeniyle ad alanının kilitlenmesi, adın Graph'tan
alındığına dair yeni bir kanıt sayılmaz.

## Kapsül, tekrar ve hata

`SCHOOL → LINK_PENDING → CREDENTIALS → DONE` veya `SCHOOL → CREDENTIALS → DONE`; realm/sub/
root-session/tab/client ve server-generated 32-byte nonce bağlı server auth note'u. Sabit 600 saniye;
stage değişimi TTL'yi uzatmaz. Strict enum/JSON tipi/alanları ve 2048 karakter sınırı vardır.
Bozuk, expired, başka binding'e kopyalanmış kapsül; disabled/service-account kullanıcı; aktif başka
AIA yeni credential action'ı üretemez. Yeni action doğrudan AIA ile istenemez (`NOT_SUPPORTED`).

Geçiş supplied capsule ile güncel server note'u karşılaştırır, purpose+binding+nonce+source-stage
SHA-256 anahtarını Keycloak `SingleUseObjectProvider.putIfAbsent` ile yalnız kalan TTL için claim
eder, deadline/current note'u tekrar kontrol eder. Farklı password/passkey seçimleri aynı stage
claim'inde tek kazanana iner; stale DONE eski sayfayı yeniden açamaz. Başlangıç için ayrı binding
claim'i iki authenticate'ın farklı nonce yazmasını önler. Auth-note API'sinin CAS olduğu iddia edilmez.

Claim sonrası publish/cache hatasında claim geri açılmaz; belirsiz ikinci eylem yerine failclosed
kalır. Kişi yeni giriş başlatabilir, hesabı ve adları korunur. Başlatılmış native AIA/credential action
kendi Keycloak yaşam döngüsünü sürdürür; B10 kapsülü onun yerine geçen bir Sudo/bearer proof değildir.

Credential seçim POST'unda geçersiz kapsül `RequiredActionContext.failure(INVALID_REQUEST)`
üretir. Keycloak 26.7.4 `LoginActionsService.interruptionResponse` bunu `CONSENT_DENIED` ile OIDC
`sendError` yoluna taşır: özgün RP ve o auth-session'ın state'iyle `access_denied`, code/token olmadan
dönüş; ilgili authentication-session tab'ı kaldırılır. Bu nedenle callback pathname'i tek başına
başarı veya güvenlik açığı kanıtı değildir. Test özgün RP/state/error yanıtını, code/token yokluğunu
ve yeni credential/OBS/federated link oluşmadığını birlikte doğrulamalıdır. Kalıcı user required-action
ve LOGIN sayacının hiç değişmeyeceği varsayılmaz; native tab cleanup'ı ile mevcut LOGIN resetinin
kişisiz önce/sonra gözlemi ayrı tutulur. Bu beklenti kaynak sözleşmesidir; yeni gerçek koşu sonucu değildir.

## Uzlaştırıcı ve geri dönüş

Aynı `KEYCLOAK_RECONCILE_ONLY=email-code-login` operatör adımı; yeni
`KEYCLOAK_AFTER_SIGN_UP=keep|on|off`. Varsayılan keep B10 için hiçbir yazım yapmaz. ON olan bir
konfigürasyondaki factory/flow/action drift'ini sessizce sağlıklı saymaz. E-posta planner'ı child
flow'da eski/yeni offer'dan tam birini tanır; duplicate, foreign leaf ve yanlış sıra reddedilir.

- `on`: mevcut email-code flow, native parola/passkey enabled/non-default ve doğru provider
  sözleşmesini doğrular. Yeni RA enabled/non-default kaydedilir, priority native credential'lardan
  önceye konur; açık StaySignedIn en sonda tutulur. Yalnız email child kapatılır, offer değiştirilip
  geri okunur, child önceki requirement'a döner. `skyAfterSignUpEnabled=true` **en son** yazılır.
  Uygun mevcut ON konfigürasyonu tekrar ON/KEEP'te yazım yapmaz.
- `off`: `skyAfterSignUpEnabled=false` **ilk** yazılır; yalnız email child'ın offer'ı eskiye döner,
  yeni RA en son kapatılır. Başlatılmış native AIA Keycloak'ın normal tamamlanma/iptal yolunu korur.
- Kesilmiş swap child'ı DISABLED bırakır; flag açılmaz. Tek başına B10 ON bunu sessizce açmaz.
  Açık operatör tercihiyle `KEYCLOAK_EMAIL_CODE_LOGIN=on` + `KEYCLOAK_AFTER_SIGN_UP=on` yeniden
  çalıştırılarak eksik leaf tamamlanır ve bütün readback'ler geçince feature açılır. Yeni durable
  migration/continuation framework'ü yoktur. Aynı realm'de uzlaştırıcı/manuel flow yazımları seridir.

Native yetki yokluğu feature ON'u engellemez: o RP açıklama+skip yolunu kullanır. Önce sandbox;
kayıt canlı bayrağı diğer tüm 10/11/12/13/24 önkoşulları ve yürüyüş tamamlandıktan **sonra** açılır.
Bu B10 yığını B24/B12/#106 içerir, B11 #110 içermez; yalnız 1.27 numarası kayıt açılışı izni değildir.

## Doğrulama ve açık kapılar

Önceki 255 checkpoint'inin native SDK 18 / hedef 91 ve phase1 650 sonuçları hazırlık kanıtıdır.
Son 1.27 kaynak: 68 suite / 735 SPI testi, 214 tema testi, TypeScript, gerçek Java flow planner,
sürüm/shell/YAML kontrolü geçti. Bağımsız hafif shell lifecycle probu keep/idempotency, alias/provider/
factory/native-action drift refusal, flag-last/flag-first, kontrollü create failure ve closed retry'ı
ayrı doğrular; bu bir gerçek HTTP/DB/browser kanıtı değildir.

`tests/after-sign-up.sh`, aynı pinned PostgreSQL18/Keycloak26.7.4/Mailpit bootstrap'ını kullanır.
`AfterSignUpMicrosoftFixture` yalnız transport'u taklit eder, gerçek protected provider türünü ve
native callback guard'ını korur. `AfterSignUpRuntimeProbe` yalnız SKY_HARNESS fixture JAR'ındadır;
credential sayıları ve mevcut stage'i gözler, test için expired/wrong-tab kapsülü kurar. Üretim
SPI/image'a bu fixture'lar girmez. Gerçek native parola politikası, passkey, callback/token,
iptal/conflict, flow readback/half-swap recovery ve yarış kapıları bu paketle doğrulanmalıdır.
CI'da ayrı `after-sign-up-native` işi, mevcut tam login/B12/B24 gruplarıyla birlikte korunur.

Sekiz yeni Linux masaüstü/mobil baseline güncellemesi ve sekiz karşılaştırma geçti. SPI/tema
birim ve görsel kanıtları, bileşen kaynakları değişmediği doğrulanan 24cd007 checkpoint'ine bağlıdır.
Gerçek CLI turu realm attribute projection kusurunu gösterdi: düz `attributes` boş nesne döndürdüğü
için iki ürün okuması `attributes(*)` yapıldı; realm haritası bütünüyle korunur. Sonraki gerçek turda
ON/KEEP idempotency, unrelated attribute korunumu, native action sırası, eski parola dalı ve kapalı
yarım-swap onarımı/duplicate refusal geçti.

Tarayıcı paketi henüz **geçmedi**. İlk yerel turlardaki locale ve mevcut StaySignedIn sorusunu
tamamlamayan callback yardımcısı test kusurları düzeltildi; bu eski 0 başarılı / 1 başarısız / 1 kesilmiş /
7 çalışmamış turlar korunur. Exact `8b900922` CI turu 9 senaryoda **4 başarılı / 5 başarısız** verdi:
generic kayıt/ertele/atla/özgün PKCE dönüşü, native parola politikası ve sonraki giriş, sanal resident
passkey ve çift seçim/tekrar koruması geçti. YTÜ success/cancel/conflict senaryolarında `finally`
cleanup hatası ilk hatayı örttüğünden asıl neden henüz bilinmiyor. Expire/wrong-tab testleri callback
pathname beklentisinde durdu; o koşuda error/state/code/token ve sonraki DB durumu ölçülmedi.

Yeni yalnız-test adayı ilk body hatasını korur; yalnız cleanup başarısızsa test yine başarısızdır ve
bütün cleanup'lar denenir. Hata tanısı URL, input değeri, tam HTML veya protocol/session değeri yerine
sentetik sayfanın heading ve görünen control kimliklerini yazar. Süre/tab testleri yukarıdaki OIDC hata
terminalini, credential/link değişmediğini ve tab cleanup'ını ölçer; user-action sayıları ve counter
blocked durumu yalnız ayrı gözlemdir. Hafif kaynak probları bu test yardımcısını doğrular; **yeni gerçek
koşu yapılmadı**, mevcut 4/5 sonucu değişmedi. Final exact-head CI ve bağımsız son inceleme açıktır.
Hazır/yayın GO iddiası yoktur. Fiziksel Touch ID bu otomasyonla doğrulanmaz; sanal resident
authenticator kanıtı ayrı cihaz uyumluluğu sınırıdır, yeni bir insan onayı sorusu değildir.
