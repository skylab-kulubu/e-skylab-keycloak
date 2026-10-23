# Keycloak olayları RabbitMQ'ya (ADR-0071 karar 8, RabbitMQ R07)

İmajdaki `keycloak-to-rabbitmq` olay dinleyicisi (`rabbitmq-provider/`,
`keycloak-to-rabbit-3.2.0.jar`) Keycloak'ın kullanıcı ve yönetici olaylarından
**yalnız olay kataloğundakileri**, **yalnız kimliklerle** RabbitMQ'ya yayımlar.
Tüketici core'dur: her olayda `usersync.Wake()` çağırır, verinin kendisini
Keycloak'tan okur (ADR-0008, core-backend #270). Olay yalnız eşitlemeyi
hızlandırır; 5 dakikalık tur kaçanı yine yakalar.

## Ne yayımlanır

| Olay | Routing key | Ne zaman |
| --- | --- | --- |
| `REGISTER` | `KK.EVENT.CLIENT.<realm>.SUCCESS.<clientId>.REGISTER` | Kayıt (Keycloak'ın kendi kaydı, ilk YTÜ girişi, SPI'nin e-posta koduyla kaydı) |
| `UPDATE_EMAIL` | `KK.EVENT.CLIENT.<realm>.SUCCESS.<clientId>.UPDATE_EMAIL` | Birincil e-posta değişti |
| `UPDATE_PROFILE` | `KK.EVENT.CLIENT.<realm>.SUCCESS.<clientId>.UPDATE_PROFILE` | Ad, soyad ya da profil alanı değişti |
| `DELETE_ACCOUNT` | `KK.EVENT.CLIENT.<realm>.SUCCESS.<clientId>.DELETE_ACCOUNT` | Hesap konsolundan silme (bizde kapalı olmalı; gelirse core uyarı yazar) |
| admin `USER` `CREATE`, `UPDATE`, `DELETE` | `KK.EVENT.ADMIN.<realm>.SUCCESS.USER.<CREATE\|UPDATE\|DELETE>` | Admin API'siyle kullanıcı yazımı |

- Başka hiçbir tür çıkmaz: `LOGIN`, `CODE_TO_TOKEN`, `*_ERROR`, admin `REALM`,
  `CLIENT`, `GROUP_MEMBERSHIP`, `USER ACTION` (eylem postası, parola sıfırlama)
  dinleyicide, kanal açılmadan düşer. Katalog koddadır
  (`RabbitMqConfig.CATALOG_*`); genişletmek kod, inceleme ve ADR işidir.
- Yalnız başarılı olaylar çıkar. Hatalı olayların türü zaten ayrıdır
  (`REGISTER_ERROR`); hata taşıyan admin olayı da düşer. Böylece
  `unrouted` kuyruğuna (R06 alarmı) yalnız gerçek bir bağ eksikliği düşer.
- `<clientId>` ve `<realm>` içindeki noktalar silinir (topic kelimesi tek
  parça kalsın diye); istemcisi olmayan olayda `UNKNOWN` yazılır.

## Gövde

Düz JSON nesnesi (CloudEvents değil, SPEC §9 sapma 4). Değeri olmayan alan
gövdeye konmaz.

Kullanıcı olayı:

```json
{"id":"8c1f…","type":"REGISTER","realmId":"5b0e…","clientId":"account-center","userId":"0d4a…","time":1792656000000}
```

Admin olayı:

```json
{"id":"41aa…","realmId":"5b0e…","resourceType":"USER","operationType":"CREATE","resourcePath":"users/0d4a…","time":1792656000000}
```

- **Yayımlanmayanlar:** IP adresi, `sessionId`, `details` (kayıtta kullanıcı
  adı ve e-posta, `UPDATE_EMAIL`'de eski ve yeni adres), admin temsili (admin
  olay ayrıntıları açık olduğu için Keycloak dinleyiciye bütün kullanıcıyı
  verir), admin olayının yazarı (`authDetails`: kim, hangi istemciden, hangi
  IP'den), Java tür bilgisi (`@class`, `__TypeId__` başlığı). Kuyruk, DLQ ve
  `unrouted` silme isteğinin (ADR-0051) erişemeyeceği kopyalardır; kişisel veri
  oraya girmez (ADR-0071 karar 5). Keycloak'ın kendi olay deposu 30 gün saklar
  (ADR-0062), o ayrı.
- **`id`:** Keycloak'ın olay kimliği (`Event.getId()`,
  `AdminEvent.getId()`): olay deposunda (`GET …/events`, `…/admin-events`)
  aynı kimlikle durur. Kimliksiz gelen olaya yeni bir UUID verilir.
- **AMQP özellikleri:** `message-id` = `id`, `app-id` = `Keycloak`,
  `content-type` = `application/json`, `delivery-mode` = 2 (kalıcı),
  `timestamp` = olay zamanı. Tüketici tekrarı bu kimlikle eler.
- Yayın Keycloak işlemi commit edildikten sonra, giden kutusu ve publisher
  confirms olmadan yapılır (SPEC §3.1 Keycloak istisnası). Broker yoksa ya da
  exchange eksikse olay kaybolur, Keycloak'ta giriş etkilenmez, hata satırında
  yalnız routing key yazar.

## Ayarlar (`KK_TO_RMQ_*`)

Sağlayıcı her ayarı önce Keycloak SPI seçeneğinden
(`spi-events-listener--keycloak-to-rabbitmq--<ad>`), yoksa ortamdan
(`KK_TO_RMQ_<AD>`) okur. Açılışta parolalar dışındaki her değeri INFO
satırında yazar (`keycloak-to-rabbitmq configuration: …`) ve hangi olayları
yayımlayacağını bir satırda söyler.

| Değişken | Varsayılan | Production | Not |
| --- | --- | --- | --- |
| `KK_TO_RMQ_URL` | `localhost` | RabbitMQ'nun `sky-lab-production-events` ağındaki servis adı | Ad "URL" ama değer yalnız ana makine adıdır |
| `KK_TO_RMQ_PORT` | `5672` | `5672` | |
| `KK_TO_RMQ_USERNAME` | `guest` | OpenBao'daki Keycloak ağacından referans (`kv/prod/keycloak/…`, SPEC §4.2): `keycloak_a` ya da `keycloak_b` | `_a`/`_b` dönüşümlü, pazar gecesi (SPEC §4.3) |
| `KK_TO_RMQ_PASSWORD` | `guest` | Aynı ağaçtan referans | Kayda yazılmaz |
| `KK_TO_RMQ_VHOST` | `/` | `skylab` | |
| `KK_TO_RMQ_EXCHANGE` | `amq.topic` | `keycloak.events` | Topolojiyi ops kurar; Keycloak kullanıcısında `configure` izni yok |
| `KK_TO_RMQ_USE_TLS` | `false` | `false` | İç ağda TLS ilk sürümde yok (SPEC §4.4) |
| `KK_TO_RMQ_TRUST_STORE`, `KK_TO_RMQ_TRUST_STORE_PASS` | boş | — | Yalnız TLS ile (JKS) |
| `KK_TO_RMQ_KEY_STORE`, `KK_TO_RMQ_KEY_STORE_PASS` | boş | — | Yalnız TLS istemci sertifikasıyla (PKCS12) |
| `KK_TO_RMQ_EVENT_TYPES` | katalog: `REGISTER,UPDATE_EMAIL,UPDATE_PROFILE,DELETE_ACCOUNT` | ayarlanmaz | Virgüllü liste katalogu **daraltır**; boş değer hiçbir kullanıcı olayı göndermez; katalog dışı ad hata satırıyla yok sayılır |
| `KK_TO_RMQ_ADMIN_RESOURCES` | katalog: `USER` | ayarlanmaz | Aynı kural; işlemler her zaman `CREATE,UPDATE,DELETE` |

Production Keycloak bir Dokploy Application'dır: değerler env sekmesine
`${{vault.bao-prod.…}}` referansıyla birebir yazılır, repo compose'unun
varsayılanları uygulanmaz. Keycloak'ın `sky-lab-production-events` ağına da
üye olması gerekir (ADR-0061, Dokploy Networks alanı).

## Realm'de açma: `KEYCLOAK_RABBITMQ_EVENTS`

Dinleyici realm'in `eventsListeners` alanında olmadan hiçbir şey yayımlamaz.
Alanı reconciler (`config/reconcile-account-center.sh`, tam koşu) yönetir; elle
açılan dinleyici sürüklenir.

| Değer | Ne yapar |
| --- | --- |
| `keep` (varsayılan) | Yalnız raporlar: `realm event listener keycloak-to-rabbitmq: unchanged (on\|off; KEYCLOAK_RABBITMQ_EVENTS=on or off changes it)` |
| `on` | `keycloak-to-rabbitmq`'yu listeye ekler, öteki dinleyicilere (`jboss-logging`) dokunmaz |
| `off` | Yalnız `keycloak-to-rabbitmq`'yu çıkarır (geri alma) |

- Yazım yalnız alan değişecekse, tek realm PUT'uyla olur (manage-realm yeter).
- **Sandbox realm'i hiçbir broker'a bağlanmaz** (Yusuf, 2026-10-21; SPEC §5):
  `KEYCLOAK_REALM=e-skylab-sandbox` ile `on` girişten önce reddedilir (çıkış 2,
  hiçbir şey okunmaz ya da yazılmaz). Sağlayıcının ayarı örnek başınadır ve tek
  Keycloak iki realm'i taşır; sandbox'ta açılan dinleyici olayları production
  broker'ına gönderirdi.
- Varsayılan `keep` olduğu için bu sürümün yayını production'da hiçbir şeyi
  açmaz; production realm'inde bugün yalnız `jboss-logging` var (R02).

## Açılış sırası (R15)

1. Production broker ve `keycloak_a`/`keycloak_b` kullanıcıları hazır (R04, R05);
   `keycloak.events` exchange'i ve `core.keycloak` bağları topolojide.
2. Keycloak env sekmesine yukarıdaki `KK_TO_RMQ_*` referansları, Keycloak
   `sky-lab-production-events` ağında, bu imaj (3.2.0) yayında. Keycloak
   sürümü Touch ID kapısından geçer.
3. Reconciler bir kez `KEYCLOAK_RABBITMQ_EVENTS=on` ile koşar (kalıcı olsun diye
   reconciler ortamına da yazılır); dinleyici yalnız `e-skylab` realm'inde açılır.
4. Duman testi: bir profil güncellemesi `core.keycloak` kuyruğuna bir mesaj
   düşürür, `unrouted` boş kalır.

**Geri alma:** reconciler `KEYCLOAK_RABBITMQ_EVENTS=off` ile koşar (dinleyici
kalkar, olay çıkmaz). `KK_TO_RMQ_*` değerleri kalabilir: dinleyici yokken
sağlayıcı bağlantı bile açmaz.

## Testler

- `rabbitmq-provider` birim testleri (imaj derlemesinde koşar): katalog,
  daraltma, boş liste, hata olayları, gövdenin alanları, `message-id`, admin
  temsilinin ve yazarının gitmemesi, geri alınan işlemde yayın olmaması.
- `tests/run-integration.sh` RabbitMQ sözleşmesi (her grup): realm güncellemesi
  yayımlanmaz, Admin API'siyle açılan kullanıcı tek bir `USER CREATE` mesajı
  olarak gelir; gövde yalnız kimlik, `message-id` olay deposundaki kimlik,
  adres/ad/IP yok; kanal sızıntısı yok.
- `tests/sign-up-by-email-code.sh`: e-posta koduyla kayıt (ADR-0063) tek bir
  `REGISTER` mesajı üretir (`KK.EVENT.CLIENT.e-skylab.SUCCESS.<istemci>.REGISTER`,
  `message-id` = depolanan `REGISTER` olayının kimliği); kayıttan sonraki
  `LOGIN`'ler broker'a gitmez; hiçbir mesajda adres, kullanıcı adı, ad ya da
  istemci IP'si yok.
- `tests/event-retention.sh`: reconciler `off` dinleyiciyi kaldırır, `on`
  geri koyar, `keep` yalnız raporlar; sandbox realm'inde `on` ve geçersiz değer
  reddedilir.
