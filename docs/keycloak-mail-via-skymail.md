# Keycloak sistem e-postaları SkyMail üzerinden (ADR-0045)

Keycloak'ın doğrulama, parola sıfırlama, e-posta değişikliği ve YTÜ bağlama
postaları kulübün posta alanı olan SkyMail'in sistem şablonlarıyla yazılır ve
SkyMail tarafından gönderilir. Metin değişikliği artık Keycloak sürümü
gerektirmez. SkyMail kapalı, ulaşılamaz ya da postayı reddediyorsa posta
Keycloak'ın kendi SMTP'siyle, değişmemiş stok şablonuyla yine de çıkar; güvenlik
postaları SkyMail'i beklemez.

SPI iki sağlayıcı kaydeder (`e-skylab-spi`, `com.skylab.mail`):

| Sağlayıcı | SPI | Kimlik | Görevi |
| --- | --- | --- | --- |
| `SkyMailEmailTemplateProviderFactory` | `emailTemplate` | `sky-mail` | Keycloak'ın hangi şablonu istediğini yakalar, üretimi stok `freemarker` sağlayıcısına bırakır |
| `SkyMailEmailSenderProviderFactory` | `emailSender` | `sky-mail` | Postayı SkyMail'e POST eder, başarısızlıkta Keycloak'ın `default` göndericisine devreder |

İkisi de `order()` değeriyle Keycloak'ın kendi sağlayıcılarının önüne geçer;
derleme seçeneği gerekmez. Devre dışıyken davranış birebir stok davranıştır.

## Neden iki sağlayıcı

Keycloak'ın `EmailSenderProvider` arayüzü göndericiye şablon kimliği değil,
üretilmiş konu ve gövde verir; o noktada postanın hangi şablon olduğu
kaybolmuştur. Bu yüzden `sky-mail` şablon sağlayıcısı stok `freemarker`
sağlayıcısını sarar: Keycloak'ın çağırdığı yöntemden (veya genel `send(...)`
aşırı yüklemelerindeki `.ftl` adından) SkyMail şablon anahtarını ve değişkenleri
çıkarır, bunları iki sağlayıcının da paylaştığı `KeycloakSession` üzerinde bir
özniteliğe koyar ve üretimi olduğu gibi devrederek devam eder. Gönderici bu
kaydı oturumdan alır (tek seferlik), SkyMail'e gönderir; stok üretim zaten
yapılmış olduğu için geri düşüş gönderecek bir gövdeye her zaman sahiptir.

Devir noktası thread-local değil oturum özniteliğidir: oturum tam olarak bir
postanın kapsamıdır, istekle birlikte atılır ve birim testinde sunucu
çalıştırmadan doğrulanabilir.

## Şablon eşlemesi

Şablon anahtarları SkyMail'de `system: true` sistem şablonlarıdır.

| Keycloak çağrısı | Keycloak gövde şablonu | SkyMail `template_key` | `subjectKey` |
| --- | --- | --- | --- |
| `sendVerifyEmail` | `email-verification.ftl` | `keycloak.verify-email` | `emailVerificationSubject` |
| `sendPasswordReset` | `password-reset.ftl` | `keycloak.reset-password` | `passwordResetSubject` |
| `sendEmailUpdateConfirmation` | `email-update-confirmation.ftl` | `keycloak.update-email` | `emailUpdateConfirmationSubject` |
| `sendConfirmIdentityBrokerLink` | `identity-provider-link.ftl` | `keycloak.idp-link` | `identityProviderLinkSubject` |
| `send(...)` | `sky-personal-email-confirm.ftl` (`EmailResource.TEMPLATE`) | `keycloak.personal-email-confirm` | çağıranın konu anahtarı (`skyPersonalEmailConfirmSubject`) |
| `sendExecuteActions` | `executeActions.ftl` | `keycloak.generic` | `executeActionsSubject` |
| `sendEvent`, `sendOrgInviteEmail`, `sendVerifiableCredentialOffer`, eşlenmemiş her `send(...)` | ilgili `.ftl` | `keycloak.generic` | Keycloak'ın konu anahtarı |
| `sendSmtpTestEmail` | `email-test.ftl` | — (SkyMail'e gitmez) | — |

Eşlenmeyen bir posta sessizce kaybolmaz: `keycloak.generic` şablonuyla, gerçek
Keycloak konu anahtarını `subjectKey` değişkeninde taşıyarak gider. SMTP test
postası realm'in kendi SMTP ayarlarını kanıtlamak içindir; SkyMail'e hiç
uğramaz, bekleyen bir kayıt varsa da temizlenir.

Hesap Merkezi'nin kişisel e-posta kodu (K3c) genel `send(...)` aşırı
yüklemesinden geçer. Eşleme, sky-account'un postayı gönderdiği sabitin kendisini
(`EmailResource.TEMPLATE`) okur; iki ad ayrı ayrı yazıldığında bir kez ayrışmış ve
posta kodsuz olarak `keycloak.generic`'e düşmüştü. Ad eşlemesi tema dizinini
(`html/`, `text/`), büyük-küçük harfi ve `.ftl` uzantısını yok sayar. Bu posta
link değil 6 haneli bir kod taşır: `code` ve `codeExpirationMinutes`.

## Gövde değişkenleri

SkyMail konuyu ve gövdeyi Go `text/template` ile üretir; eksik bir değişken
`<no value>` basar. Bu yüzden her posta sekiz değişkeni **her zaman** taşır,
Keycloak bilmiyorsa boş string olarak:

| Değişken | Kaynağı |
| --- | --- |
| `link` | Keycloak'ın eylem bağlantısı (olmayan postalarda boş) |
| `linkExpirationMinutes` | Bağlantının dakika cinsinden ömrü (ondalık metin, yoksa boş) |
| `code` | Kişisel e-posta doğrulama kodu, 6 rakam (yalnız `keycloak.personal-email-confirm`; diğerlerinde boş) |
| `codeExpirationMinutes` | Kodun dakika cinsinden ömrü (`10`; kod taşımayan postalarda boş) |
| `firstName` | `user.firstName` |
| `username` | `user.username` |
| `realmDisplayName` | Realm görünen adı, yoksa Keycloak'ın kuralıyla baş harfi büyütülmüş realm adı |
| `subjectKey` | Keycloak'ın konu anahtarı (konular SkyMail'de sabit Türkçe metindir) |

İstek gövdesi:

```json
POST {SKY_MAIL_BASE_URL}/v1/mail_tasks/single
{
  "template_key": "keycloak.verify-email",
  "recipient_email": "...",
  "recipient_full_name": "...",
  "body_variables": {
    "link": "...", "linkExpirationMinutes": "60", "code": "", "codeExpirationMinutes": "",
    "firstName": "...",
    "username": "...", "realmDisplayName": "...", "subjectKey": "emailVerificationSubject"
  }
}
```

`recipient_email` Keycloak'ın o posta için çözdüğü adrestir; e-posta değişikliği
onayı gibi adres geçersiz kılan postalarda yeni adrese gider.
`recipient_full_name` ad ve soyaddan, ikisi de yoksa kullanıcı adından üretilir.

## Yetkilendirme

Gönderici, realm'in token uç noktasından `keycloak-mailer` gizli istemcisiyle
client credentials akışıyla token alır (HTTP Basic). Service account'un
`skymail:access` ve `skymail:mails:send` rolleri ve aynı roller scope
mapping'inde olmalıdır; token `resource_access.skymail.roles` içinde ikisini de
taşır. Token bellekte, süresi dolmadan 30 saniye öncesine kadar önbelleklenir;
SkyMail isteği reddederse önbellek hemen boşaltılır. Token hiçbir günlüğe,
hiçbir `toString()` çıktısına girmez.

## Ortam değişkenleri

Hepsi fabrika ilklendirmesinde bir kez okunur ve doğrulanır.

| Değişken | Varsayılan | Anlamı |
| --- | --- | --- |
| `SKY_MAIL_ENABLED` | `false` | `true` olmadıkça hiçbir şey doğrulanmaz, her posta SMTP'den çıkar |
| `SKY_MAIL_BASE_URL` | — (etkinken zorunlu) | SkyMail API kökü; HTTPS, sorgu/parça ve kimlik bilgisi taşımaz. Paylaşılan bir API host'unda düz bir yol taşıyabilir (`/api/skymail`); nokta segmenti, kodlanmış karakter, boş segment ve sondaki `/v1` reddedilir. Uç nokta köke `/v1/mail_tasks/single` eklenerek kurulur |
| `SKY_MAIL_CLIENT_ID` | `keycloak-mailer` (compose) | Gizli service account istemcisi |
| `SKY_MAIL_CLIENT_SECRET_FILE` | `/run/secrets/sky-mail/client.secret` | Gizli anahtarın salt okunur bağlandığı mutlak dosya yolu |
| `SKY_MAIL_CLIENT_SECRET` | — | Yalnız `SKY_HARNESS=1` ile (entegrasyon koşumu); başka yerde yok sayılır |
| `SKY_MAIL_TOKEN_URL` | realm issuer'ından türetilir | Sabitlemek isteyen operatör için; `/protocol/openid-connect/token` ile bitmelidir |
| `SKY_MAIL_TIMEOUT_MILLISECONDS` | `5000` | Toplam istek bütçesi, 1000–15000 arası. Bağlantı bütçesi bunun ve 2000 ms'nin küçüğüdür |

Biçimi bozuk bir değer (HTTPS olmayan adres, aralık dışı süre, olanaksız istemci
kimliği) operatör hatasıdır ve fabrikayı `IllegalStateException` ile
başarısızlığa uğratır. Gizli anahtar dosyasının eksik ya da boş olması ise
**kapalı tarafa düşer**: sağlayıcı devre dışı kalır, başlangıçta tek bir
`sky_mail_disabled reason=secret_file_missing` (veya `…_empty`) uyarısı düşer ve
her posta SMTP'den çıkmaya devam eder. Posta sunucusunun hiç açılmaması, geri
düşen bir posta sunucusundan kötüdür.

`SKY_MAIL_ENABLED` varsayılanı `false` olduğu için iyileştirilmiş imaj derlemesi
(`kc.sh build`, her fabrikayı çalışma zamanı ortamı olmadan ilklendirir) hiçbir
şey doğrulamaz ve gizli anahtara ihtiyaç duymaz.

## Geri düşüş

201 dışındaki her yanıt gönderilmemiş sayılır. Özellikle **404**: SkyMail o
durumda kuyruk kaydı yazmaz, posta "gönderildi" sayılırsa sessizce kaybolur.
Her geri düşüş, Keycloak'ın `default` göndericisine üretilmiş konu ve gövdeyle
devreder ve tek satır günlük düşer:

```
sky_mail_fallback reason=<sabit sözcük> template=<şablon anahtarı>
```

| `reason` | Ne oldu | Günlük düzeyi |
| --- | --- | --- |
| `disabled` | Sağlayıcı kapalı ya da gizli anahtar dosyası açılışta yoktu | DEBUG |
| `not_mapped` | Bu sağlayıcının şablonlamadığı bir posta (SMTP test postası) | DEBUG |
| `config` | Realm issuer çözülemedi, çağrılacak token uç noktası yoktu | WARN |
| `token` | Client credentials token'ı alınamadı | WARN |
| `template_missing` | SkyMail 404: şablon anahtarı yok ya da arşivlenmiş | WARN |
| `refused` | Başka bir 4xx ya da 201 olmayan bir 2xx | WARN |
| `unavailable` | SkyMail 5xx | WARN |
| `timeout` | İstek bütçesi içinde yanıt gelmedi | WARN |
| `transport` | SkyMail'e ulaşılamadı | WARN |
| `response` | 201 geldi ama kullanılabilir bir görev kimliği yoktu | WARN |

Sözcük dağarcığı kapalıdır ve satırda başka hiçbir şey yoktur: adres, bağlantı,
token ya da gizli anahtar günlüğe hiçbir yoldan giremez. Birim testleri bunu
her `reason` için ayrı ayrı doğrular.

## Operatör adımları

1. **Mailer istemcisi.** `keycloak-mailer` gizli service account istemcisini
   imajdaki idempotent betikle oluşturun (K2; ayrıntı ve runbook §6 için
   [`docs/v2-identity-reconcile-runbook.md`](v2-identity-reconcile-runbook.md)):

   ```bash
   docker compose -f docker-compose.yml run --rm --no-deps -it \
     --entrypoint /opt/keycloak/config/create-mailer-client.sh \
     keycloak-config --admin-user <admin> --apply
   ```

   Betik `skymail` istemcisinin rollerini oluşturmaz; yoksa uyarır. SkyMail
   tarafında `skymail:access` ve `skymail:mails:send` var olduktan sonra betiği
   yeniden çalıştırın.

2. **Gizli anahtar dosyası.** Anahtarı Keycloak üretir, hiçbir betik yazdırmaz.
   Kabuk geçmişi ve terminal kaydı kapalıyken bir kez okuyup üretim sunucusuna
   yazın:

   ```bash
   install -d -m 0750 -o root -g 1000 /opt/weblab/account-center-keycloak/credentials
   umask 077
   kcadm.sh get clients/<client-uuid>/client-secret -r e-skylab \
     | jq -r .value > /opt/weblab/account-center-keycloak/credentials/mailer-client.secret
   chown root:1000 /opt/weblab/account-center-keycloak/credentials/mailer-client.secret
   chmod 0640 /opt/weblab/account-center-keycloak/credentials/mailer-client.secret
   ```

   Dosya Compose tarafından salt okunur olarak
   `/run/secrets/sky-mail/client.secret` yoluna bağlanır. Keycloak konteynerde
   uid 1000 ile çalıştığı için dosya o kullanıcı tarafından okunabilir olmalıdır:
   `root:1000` sahipliği ve `0640` izni bunu verir, `0600` root-only izin
   vermez ve sağlayıcı kapalı tarafa düşer. Dosyanın sonundaki satır sonu
   kırpılır.

   Anahtar her token isteğinde dosyadan okunur; döndürme için dosyanın içeriğini
   **yerinde** güncelleyin (aynı inode), Keycloak'ı yeniden başlatmak
   gerekmez. Dosyayı silip yerine yenisini koymak bağlamayı kopardığı için
   yeniden başlatma gerektirir.

3. **Etkinleştirme.** `.env` içinde `SKY_MAIL_ENABLED=true` ve
   `SKY_MAIL_BASE_URL=https://api.yildizskylab.com/api/skymail` ayarlayıp `keycloak`
   servisini yeniden başlatın. Açılışta `sky_mail_enabled client=keycloak-mailer`
   satırını arayın; `sky_mail_disabled reason=…` görürseniz dosya bağlaması ya
   da izinleri eksiktir.

4. **Realm SMTP'si kalır.** Geri düşüş realm'in kendi SMTP ayarlarını kullanır;
   `emailTheme` ve SMTP yapılandırması olduğu gibi bırakılır. SkyMail kapalıyken
   davranış stok Keycloak davranışıdır.

## SkyMail tarafı

Sistem şablonları SkyMail'de `system: true` işaretlidir ve arşivlenemez; arşiv
denemesi `409` döner. Yanlışlıkla arşivlenmiş ya da silinmiş bir şablonu geri
getirmek için SkyMail'in tohumlama çağrısı yeniden çalıştırılır:
`PUT /v1/templates/by-key/:key`. Bu çağrı şablonu anahtarıyla yeniden yazar, yani
tohumlamayı yinelemek bozulmuş bir sistem şablonunu onarır. Gönderici bu arada
404'ü `template_missing` olarak görür ve postaları SMTP'den çıkarmaya devam eder.

## Doğrulama

Birim testleri (`spi/src/test/java/com/skylab/mail`) şablon eşlemesini, altı
değişkenin her zaman gönderildiğini, 201/404/4xx/5xx/zaman aşımı sınıflamasını,
token önbelleğini ve yenilenmesini, gizli anahtar dosyasının okunmasını, kapalı
tarafa düşmeyi ve günlüklerin hiçbir hassas değer taşımadığını doğrular.

Entegrasyon koşumunda (`tests/run-integration.sh`, `skymail` fixture'ı) gerçek
`keycloak-mailer` service account'u gerçek bir token alır, doğrulama postası
eşlenen şablon anahtarı ve altı değişkeniyle bir kez gönderilir, fixture'ın 404
ve 500 döndüğü iki durumda geri düşüş tetiklenir ve posta fixture'ın SMTP
havuzuna yine de ulaşır.

> **`SKY_MAIL_BASE_URL` API'nin kökü olmalı, arayüzün değil.** `https://mail.yildizskylab.com`
> SkyMail'in tek sayfalık uygulamasıdır ve her yola HTML döndürür; oraya yapılan
> `POST /v1/mail_tasks/single` 200 + HTML alır. Gönderici yalnız 201'i gönderildi saydığı için
> bu hatada her posta sessizce SMTP yedeğine düşer, SkyMail hiçbir şey görmez. Doğru değer
> core'un `SKYMAIL_URL`'siyle aynı kök: `https://api.yildizskylab.com/api/skymail`
> (kimliksiz istek 403 döner — API'nin orada olduğunu gösterir).
>
> 2026-09-23'e kadar gönderici yol taşıyan bir kökü reddediyordu; bu değerle Keycloak
> `SKY_MAIL_BASE_URL must carry no path.` diyerek açılmadı (Swarm eski görevi ayakta tuttu).
> SPI artık düz bir yolu kabul ediyor.
