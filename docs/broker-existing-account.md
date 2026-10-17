# İlk YTÜ girişinde mevcut hesabı bağlama

`sky-existing-account-prompt`, ilk Microsoft/OBS girişinde yeni hesap açılmadan önce
"Zaten bir SKY LAB hesabın var mı?" diye sorar. Kişi açıkça yeni hesap açmayı seçebilir
veya mevcut hesabını e-posta kodu, parola ya da passkey ile kanıtlayıp bağlayabilir.
Mevcut hesabın TOTP'si varsa bu kanıttan sonra ayrıca sorulur. Bağlama mevcut hesabın
birincil adresini ve adresin doğrulama durumunu değiştirmez. Okul adresi, bölüm ve
üniversite mevcut eşleyicilerden gelir; bu yolda kilitlenecek ad/soyad Microsoft'un
kanıtladığı değerlerden alınır.

## Açma ve geri alma

Uzlaştırıcı bayrağı `KEYCLOAK_EXISTING_ACCOUNT_PROMPT=keep|on|off`; varsayılan `keep`.
İlk kurulumda `keep` hiçbir adım eklemez. Kurulu korumada `keep` bilinen biçimi korur.
`on` yalnız `KEYCLOAK_YTU_FIRST_LOGIN=on` ile kurulmuş, realm'in etkin kullandığı
`sky first broker login` kopyasında çalışır. Yerleşik akışa veya browser akışına
yazmaz. Bilinmeyen akış biçiminde değişiklik yapmayı reddeder.

`on` üç adımı kurar:

- REQUIRED `sky-existing-account-prompt`: YTÜ adımından sonra, profil incelemesinden önce.
- REQUIRED `sky-broker-review-profile`: yerleşik profil incelemesinin yapılandırmasını
  koruyan dar sarmalayıcı; yalnız kanıtlanmış mevcut hesapta incelemeyi atlar.
- ALTERNATIVE `sky-existing-account-proven`: native create-or-link alt akışında
  kullanıcı oluşturma alternatifinden önce; yalnız geçerli kanıtla hedef seçer.

Native Confirm Link, parola/passkey ve koşullu OTP adımları korunur. Native
"Verify Existing Account By Email" kapalı kalır; bağlantıyla hesap kanıtı açılmaz.
`off` yalnız bu üç değişikliği geri alır ve profil incelemesinin ayarlarını koruyarak
yerleşik sağlayıcısını geri koyar. Pending B12 kanıtları da callback'te reddedilir.
Tek başına B12 `off`, YTÜ akış bağlamasını geri almaz; bunun ayrı bayrağı
`KEYCLOAK_YTU_FIRST_LOGIN`'dır.

Bu özellik PostgreSQL gerektirir; üretim hedefi PostgreSQL 17 ve Keycloak 26.7.4'tür.
Kapalıyken H2 dahil mevcut native davranış değişmez. Açıkken PostgreSQL'in dar
transaction kilidi kullanılamıyorsa bağlantı güvenli biçimde reddedilir; kilitsiz
fallback yoktur. Sandbox yürüyüşü ve yayın onayı tamamlanmadan kayıt özelliği
canlıda açılmaz. Bu belge bir yayın onayı değildir.

IdP alias kaynağı bütün yeni adımlarda `SKY_ACCOUNT_YTU_IDP_ALIAS`, yoksa `OBS`'dir. Bu
özellik için ayrı SPI component alias ayarı desteklenmez. OBS'nin etkin first-broker
flow override'ının başka bir akışa çevrilmesi pending B12 kanıtını geçersiz kılar.

## Kanıt ve callback sınırı

`EXISTING_USER_INFO` yalnız native aday notudur; kimlik kanıtı değildir. Gerçek
federated linki Keycloak kendi callback transaction'ında ekler. Yeni kod execution
sonuçlarını elle SUCCESS yapmaz ve native link ekleme işlemini yeniden uygulamaz.

Link kodu altı hanelidir, yalnız hedef hesabın güncel primary adresine gider ve
`Purpose=link` taşır. Login/sign-up kodlarından ayrı single-use namespace kullanır.
Kod on dakika ve beş denemeyle sınırlıdır; mevcut session/IP sınıfı/adres/günlük ve
hesap yanlış-kod bütçeleri paylaşılır. Bilinmeyen veya bağlanmaya uygun olmayan
hesap aynı kod ekranını görür, posta gönderilmez. Form yalnız kişinin yazdığı
tanımlayıcıyı gösterir; hesap profili, canonical username veya primary adresi
kanıttan önce gösterilmez. Her kanıt ekranında açık yeni-hesap kaçışı bulunur.

Kod ve son kanıt realm, root authentication session, tab, client, IdP alias,
Microsoft subject, okul adresi, hedef user ID, primary ve Microsoft ad/soyadına
bağlıdır. Tüm faktörlerden sonra verilen son kanıt tek kullanımlıdır; sabit ömrü en
fazla 120 saniye ve ilk faktörün on dakikalık son tarihi kadardır. Yeniden render,
OTP veya callback bekleyişi bu süreyi uzatmaz. Reset/kaçış önce code/proof'u siler,
orijinal broker e-postasını geri koyar ve native reset sonrası broker bağlamını korur.

Native callback ayrı HTTP isteğidir. `SkyMicrosoftIdentityProvider.updateBrokeredUser`
hook'u, native JPA link insertinden sonra aynı transaction'da kanıtı atomik tüketir;
güncel target row'u `FOR UPDATE NOWAIT`, mevcut OTP row'larını da `FOR UPDATE NOWAIT`
ile tutar. Cache yerine yeni scalar sorgularla primary, enabled, normal hesap,
OTP snapshot ve etkin akış yapılandırmasını yeniden denetler. Süre kilitlerden sonra
ve Keycloak transaction prepare aşamasında tekrar denetlenir. Hata native link
inserti dahil transaction'ı rollback eder. Burada global realm/ownership kilidi
alınmaz ve data-marshaller getter'ına yan etki eklenmez.

Keycloak 26.7.4'ün federated identity PK'si `(provider, local user)`'dır; external
subject indeksi unique değildir. Bu yüzden özellik açıkken mevcut native/A6 dahil
bütün SKY Microsoft callback'leri `(realm, alias, external subject)` için PostgreSQL
transaction advisory **try**-lock ve güncel owner sorgusuna katılır. Kilit doluysa
beklemek yerine rollback edip yeniden deneme gerekir. Böylece native insertin
aldığı FK kilidinden sonra başka callback'i bekleyen bir kilit döngüsü kurulmaz.
Özellik kapalıyken bu ek ortak guard çalışmaz. A6'ya B12 code/proof şartı eklenmez.

## Doğrulama

- `spi/`: `mvn verify`; single-use/replay, binding, native mechanics, escape/reset,
  factor bookkeeping, bozuk marker, fixed TTL, callback rollback ve strict akış planı.
- `theme/`: `npm test`, `npm run build-keycloak-theme`, `npm run test:browser`;
  soru, tanımlayıcı, kod ve native kanıt ekranlarının kaçışı.
- `tests/existing-account-link.sh`: gerçek PostgreSQL 17 + Keycloak 26.7.4,
  üretim User Profile, ayrı test-only Microsoft transport ve transaction barrier
  fixture JAR'ı. `B12_SPI_JAR` önceden derlenmiş SPI JAR'ın mutlak yoludur.
  İmajlar Dockerfile ve harness'te pinlidir; test `--pull=never` kullanır.
  Geçici DB tmpfs'tedir; yalnız loopback portları yayınlanır. Fixture üretim
  JAR'ına veya imajına girmez. Kanıt çıktısı adres, IP, kod veya token içermez.
