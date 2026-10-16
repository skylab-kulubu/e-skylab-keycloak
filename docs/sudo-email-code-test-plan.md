# E-posta ile Sudo — yerel / sandbox kabul planı

Bu plan canlı kullanıcıya kod göndermez. Yerel JUnit testleri fake posta ve
single-use store ile çalışır; Account center BFF/UI testleri mock SPI kullanır.
Gerçek Keycloak için ağır runtime yuvası ayrıca koordine edilir.

1. #106 ile parolasız yeni hesap oluştur: doğrulanmış kişisel/birincil adres,
   rol/grup varsayılanları, password/passkey/TOTP yok. Identity capability true.
2. my. hassas işlem → e-posta sekmesi. Yanlış kod 5 kez: her biri brute-force
   sayacına gider, sonrasında doğru eski kod çalışmaz. 10 dakika ve tam expiry
   sınırını, tek kullanımı, 3/saat gönderimi, 10/15dk doğrulamayı doğrula.
3. Aynı kod başka realm, kullanıcı ve `sid` oturumunda çalışmaz. Login/link/signup
   ve personal-email kodları Sudo için kabul edilmez. Logout + yeni giriş eski
   kodu kullanamaz.
4. Sudo maili o anki verified primary'ye gider. Yeni personal-email değişiklik
   isteği beklerken Sudo maili o yeni adrese gitmez. Primary değişirse eski kod
   çalışmaz. Null/unverified/malformed primary → 409, capability false.
5. Password veya TOTP veya passkey bulunan kullanıcı send/verify → 403. Send
   sonrası faktör ekle → eski kod artık kullanılamaz, tekrar methods okumasında
   e-posta yolu kaybolur. Parolası olmayan YTÜ bağlantılı kullanıcıya e-posta ve
   Microsoft birlikte sunulur; YTÜ bağlantısız kişiye Microsoft sunulmaz.
6. Yeni hesap → my. → kodla Sudo → YTÜ hesabımı bağla → passkey ekle. Daha sonra
   Sudo isterken yalnız mevcut güçlü faktörler görünür. BFF yeniden açılan
   pencerede no-store yöntem okuması ve securityView'da güncel capability kullanır.
7. Klavyeyle aç/gönder/kod/doğrula/yeniden gönder; sekmelerde oklar ve Home/End;
   Tab pencerede kalır, Escape iptal eder ve açan öğeye odak döner. Ekran okuyucu
   başlık/açıklama/sekme/alan ipucunu, status gönderimini ve alert hatasını okur.
   Desktop ve dar mobilde taşma/axe kontrolü yapılır.
8. Başarılı Sudo 5dk, sub+sid bağlı; tarayıcı yanıtta kod veya Sudo token görmez.
   Mail failure, 429 ve kilit yanıtı tekrar deneme davranışını korur.

Yayın: purpose=sudo SkyMail şablonu hazır → Keycloak (fiziksel Touch ID dahil
mevcut kapılar) → Account center. Üretim e-posta gönderimi, template seed,
realm akışı açma ve yayın bu kod değişikliğinin parçası değildir.
