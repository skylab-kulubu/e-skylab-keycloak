# E-posta kodunda hesap başına kalıcı ardışık hata sınırı (bilet 24)

Bu değişiklik altı haneli kodun mevcut günlük yaklaşık 10 yanlış tavanına ek olarak, yerel
hesabın ardışık yanlış kod sayısını veritabanında saklar. Sınır **100**: o hesaba yeni kod
postalanmaz ve eldeki kodlarla yeni tahmin yapılmaz. Ekran, HTTP yanıtı ve kod başına kalan
deneme davranışı hesap bulunmayan sahte kod yoluyla aynı kalır. Günlük, adres, oturum ve IP
sınıfı bütçeleri; on dakika TTL, beş deneme, amaç/oturum bağlama ve TOTP koşulları sürer.

Henüz hesabı olmayan kayıt adresi için bu sayaç yaratılmaz. Mevcut hesaba kayıt kapısından
istenen kod bu hesabın sayacına tabidir. Doğrulanmış mevcut-hesap bildiriminin “Devam et” adımı
da sınırı yeniden denetler; proof beklerken başka oturum 100'e ulaştıysa giriş yapılamaz.
Kayıt kodu postalandıktan sonra adrese hesap açılırsa, sonraki karşılaştırmalar güncel hesap ve
kod hedefi eşliğiyle bu hesabın kalıcı ve günlük sayacına katılır; adresin önceki günlük bütçesi de sürer.
Hesabı kanıtlayıp girişe ulaştıran LINK kodu da aynı guard'ı gönderimde, karşılaştırmada ve
TOTP sonrası proof oluşturulurken kullanır. Native bağlantıyı kaydeden ayrı HTTP callback'i,
`proof.method=email_code` için kullanıcı kilidi altında sınırı tekrar okur. Kod kanıtı ile callback
arasında başka istek 100'e çıkarsa bağlantı ve giriş tamamlanmaz. Parola/passkey kanıtı ile
native YTÜ ve mevcut A6 bağlantı akışı bu e-posta sınırıyla engellenmez.
Sudo mode bu değişikliğin kapsamına girmez.

## Kalıcılık ve eşzamanlılık

- `user_attribute.skyEmailCodeConsecutiveFailures`, sıfırda eksik kayıt; yanlış karşılaştırmada
  1–100. Gün, zaman aşımı veya Keycloak/JVM yeniden başlatmasıyla sıfırlanmaz. Bozuk/çoğul
  değer 100 gibi kapalı kabul edilir; tamamlanan başarılı giriş veya bakım reseti toparlar.
- Her gönderim kontrolü ve karşılaştırma, `realmId` + `userId` ile seçilen `UserEntity` satırının
  `PESSIMISTIC_WRITE` kilidinde yapılır. Aynı kilit artırma ve reseti de sıralar. Kilit transaction
  bitene kadar sürer; JVM kilidi veya süreli cache lease'i yoktur. Diğer hesaplar aynı kilidi paylaşmaz.
- Kilitten **sonra** scalar JPQL attribute okuması yapılır; UserModel ve JPA L1 nesnelerindeki eski
  değer güvenlik kararına girmez. Yazı bulk JPQL veya `UserAttributeEntity.persist` ile yapılır;
  yeni entity/migration yoktur. ORM tablo/schema eşlemesi korunur. Aktif JDBC bağlantısı
  `READ_COMMITTED` değilse doğrulama güvenli biçimde kapanır.
- Normal yazılar kullanıcı cache invalidasyonunu kaydeder. Başarılı LOGIN resetinin JPA bağlantısı
  ve realm kimliği listener oluşturulurken hazırlanır; event callback yalnız kullanıcı kimliğini
  kaydeder, provider/DB/cache çağırmaz. `prepare` aşamasında yeni provider enlist edilmez. Resetin
  SQL'i aynı kullanıcı kilidindedir. Başarılı LOGIN ve bakım SQL resetleri cache'i temizlemez; güvenlik kararı
  her seferinde SQL'den okunduğu için cache'te eski 100 kalması giriş kararını değiştirmez.

## Başarılı giriş ve alarm

Global `sky-email-code-failures` listener, event deposu kapalı olsa veya realm'in listener listesi
değişse de çalışır. Yalnız hatasız `LOGIN` sayılır; yanlış kod, yarım e-posta kanıtı, TOTP bekleme,
kayıt formu ve refresh-token olayı sayacı sıfırlamaz. Kod, parola, passkey, YTÜ veya diğer gerçek
başarılı girişin tamamlandığı transaction'ın **prepare** aşamasında reset olur.

Keycloak 26.7.4, `EventBuilder.onEvent` hatalarını yutar. Bu yüzden callback içinde hiçbir
DB/provider/cache işi yapılmaz; listener oluşturma hatası token üretilmeden dışarı çıkar. Yalnız `rollbackOnly`, hazırlanmış HTTP
yanıtını mutlaka hataya çevirmediğinden resetin SQL hatası prepare aşamasından dışarı taşar:
DB ve after-completion işleri rollback edilir. Request'in daha önce rollbackOnly olması ayrı
bir yoldur; bu tasarım callback'te provider çağırmayarak onu önler. Gerçek SQL reset hatasında
Direct Grant 500/noJWT ve browser 500/noCode, onarım sonrasında kullanılabilir token doğrulanır.
Mevcut RabbitMQ listener'ı kendi `EventListenerTransaction` işini `enlistAfterCompletion` ile
kaydeder; bu değişiklik ona dokunmaz. Sayaç reseti JPA commit'inden önceki prepare fazında,
RabbitMQ yayını ise yalnız başarılı DB commit'inden sonraki fazda kalır.

99→100 geçişi bir kişisiz immutable alarm bildirimi hazırlar. Yalnız commit olursa mevcut
`/ADMIN` gönderim yolu `skyLoginCodeAlarmConsecutiveSubject` ile uyarır; kişi, adres, kod, IP ve
UA içermez. Aynı kapalı durumdaki sonraki denemeler yeni alarm üretmez. Yeni bir başarılı girişten
sonra tekrar 100'e ulaşılırsa yeni alarm olabilir. Mail teslimi mevcut diğer alarmlar gibi best-effort;
kalıcı mail outbox'ı değildir. Executor reddi/gönderim hatası tamamlanmış transaction'ı bozmaz.

## Yetkili bakım reseti

Normal Account/UserProfile API ile sayaç değiştirilmez. Realm'in gözden geçirilmiş User Profile
sözleşmesi `unmanagedAttributePolicy=ADMIN_VIEW`: sayaç kullanıcı tarafından görünmez/yazılamaz,
normal yönetim arayüzünde salt okunur. Counter adını yönetilebilir bir profile attribute olarak
eklemek veya unmanaged policy'yi `ENABLED`/`ADMIN_EDIT` yapmak bu güvenceyi bozar; böyle bir
operatör değişikliği yapılmamalıdır. Genel Admin REST kullanıcı JSON'u ile reset desteklenmez.

Yetkili veritabanı operatörü, doğrulanmış realm/kullanıcı UUID'siyle
`config/reset-email-code-failures.sql` dosyasını `psql -X --set=ON_ERROR_STOP=1` üzerinden çalıştırır.
Bağlantı, Keycloak'ın doğru DB'sine ve schema search_path'ine bağlanmalıdır. Kimlikler çalışma
anında sorulur; dosyaya, shell geçmişine veya komut satırı argümanına gerçek değer yazılmaz.
Kimlik yanlış realm'e aitse exit 3, değişiklik yoktur. Aynı kullanıcı satırı kilitlenir; lock timeout
beş saniyedir. Yalnız kalıcı ardışık sayaç silinir; günlük/gönderim bütçeleri sıfırlanmaz.

Üretimde çalıştırma bu PR'ın parçası değildir; ayrı yayın/ops yetkisi gerekir. Önce yeni
`keycloak.login-code-alarm` şablonu seed edilmelidir; eski şablon bilinmeyen subjectKey'yi
günlük yarı-sınır uyarısı gibi gösterir. Sonra bütün Keycloak örnekleri yeni SPI'ye geçmelidir.
Eski ve yeni SPI birlikte hizmet verirken 100 sınırı bütün isteklere uygulanmış sayılmaz.
Kayıt canlı bayrağı bu ve mevcut diğer önkoşullar doğrulanmadan açılmamalıdır.

İlk yayında eksik attribute sıfırdan başlar; geçmiş günlük/bellek sayaçları ardışık sayaca
aktarılmaz. Yeni sayaç ilk yayından sonraki yanlış karşılaştırmaları biriktirir. Geri alınan eski
SPI attribute'u koruyabilir, fakat bu sınırı uygulamaz; eski imaja dönüş güvenlik güvencesini de geri alır.

## Kaynak ve doğrulama kapıları

Sözleşme Keycloak **26.7.4** kaynaklarına bağlıdır:
[EventBuilder](https://github.com/keycloak/keycloak/blob/26.7.4/server-spi-private/src/main/java/org/keycloak/events/EventBuilder.java),
[transaction manager](https://github.com/keycloak/keycloak/blob/26.7.4/services/src/main/java/org/keycloak/services/DefaultKeycloakTransactionManager.java),
[session kapanışı](https://github.com/keycloak/keycloak/blob/26.7.4/services/src/main/java/org/keycloak/services/DefaultKeycloakSession.java),
[UserAdapter](https://github.com/keycloak/keycloak/blob/26.7.4/model/jpa/src/main/java/org/keycloak/models/jpa/UserAdapter.java),
[UserCacheSession](https://github.com/keycloak/keycloak/blob/26.7.4/model/infinispan/src/main/java/org/keycloak/models/cache/infinispan/UserCacheSession.java)
ve [PostgreSQL READ COMMITTED](https://www.postgresql.org/docs/18/transaction-iso.html#XACT-READ-COMMITTED).

Yayın kapısı: birim testlerine ek gerçek PostgreSQL + Keycloak'ta iki instance, 99→100 eşzamanlı
karşılaştırma/tek alarm, restart/gün bağımsızlığı, diğer kullanıcı izolasyonu, gerçek LOGIN reseti,
UserProfile overwrite/omission/empty-map negatifleri ve reset-fault sonrası token reddi kanıtı.
Bunlar doğrulanmadan yalnız birim testlerinden replika veya token güvenliği sonucu çıkarılmaz.

16 Ekim baseline doğrulaması (SPI 1.23 bazındaki bu sayaç değişikliği): 595 birim testi ve
`tests/login-code-persistent.sh` gerçek PostgreSQL 18 + iki Keycloak 26.7.4 koşusunda 70 assertion,
149 saniye, exit 0. İki replika/tek alarm/izolasyon; KC+PG process restart; başarılı parola/e-posta/TOTP
resetleri; event deposu/listener listesi kapalı global reset; browser kodu redeem 200; gerçek Account
ve Admin UserProfile pozitif/negatifleri; SQL reset hatasında Direct Grant 500/noJWT ve browser 500/noCode;
onarım sonrası 200/reset ve exact bakım SQL'i geçti. Bu koşu B12 LINK adapter'ını içermez.

B12'nin donmuş kodu normal merge edildikten sonraki SPI **1.26.0**: 64 suite / 640 birim testi.
`tests/existing-account-counter.sh` gerçek PostgreSQL 18 + Keycloak 26.7.4 üzerinde 19 assertion ve
bir native passkey browser testiyle 118 saniyede exit 0 tamamlandı. LINK gönderim/karşılaştırma 100
reddi, 99→100 tek alarm, doğru kodun 100'de reddi, TOTP bekleyen kanıtın yeniden kontrolü ve ayrı
callback'te 100/gerçek SQL hatası nedeniyle native insert rollback'i geçti. Başarılı kod, parola,
passkey, native YTÜ ve mevcut A6 LOGIN yolları reseti doğruladı. Passkey testinde 100, credential
kaydından **sonra** yazılır; yanlış hedef denemesi 100'ü korur, doğru LOGIN sıfırlar. Test-only
callback/probe sınıfları üretim JAR'ına girmez.

CI'daki ayrı `email-code-persistent-counter` işi, yeni 1.26 JAR'ıyla hem 70 temel assertion'ı hem
LINK paketini tekrar çalıştırır; eski tam login/B12 regresyonlarının kontrolleri korunur. Yerel
baseline ve 1.26 LINK kanıtları ayrı tutulur. Bu yeni CI işi, optimize imaj derlemesi ve bağımsız
inceleme yeşil olmadan yayın kapısı tamamlanmış sayılmaz. Bu değişiklik henüz canlıya yayımlanmadı.
