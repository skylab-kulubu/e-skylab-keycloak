# Parola kara listesi

`skylab-yaygin-parolalar.txt`, realm parola politikasındaki `passwordBlacklist(skylab-yaygin-parolalar.txt)`
kuralının okuduğu listedir (`config/account-center-realm-security.json`). İmaj dosyayı
`/opt/keycloak/password-blacklists/` altına koyar ve Keycloak'a
`KC_SPI_PASSWORD_POLICY__PASSWORD_BLACKLIST__BLACKLISTS_PATH` ile gösterir (`Dockerfile`). Dosya
`data/` altında değildir; oraya bağlanan bir birim listeyi gizleyemez.

Listedeki bir parola (büyük/küçük harf fark etmez) kayıtta, parola sıfırlamada, Hesap Merkezi'nde
ve yönetici parola atamasında reddedilir. Kişi temanın Türkçe cümlesini görür:
"Bu parola çok yaygın; başka bir parola seç." (`theme/src/login/i18n.ts`,
`invalidPasswordBlacklistedMessage`). En az uzunluk 8 kalır (sektör denetimi 2026-11-24, K2).
Dış servise (Have I Been Pwned API'si) istek yapılmaz; kontrol Keycloak'ın içinde, bellekteki bir
Bloom süzgeciyle yapılır.

## Kaynaklar

| Kaynak | Ne | Lisans |
| --- | --- | --- |
| [SecLists](https://github.com/danielmiessler/SecLists) `Passwords/Common-Credentials/100k-most-used-passwords-NCSC.txt`, commit `fcde9140df969b1e4d7bb056122646dace4ed4cc` | Birleşik Krallık NCSC'nin Have I Been Pwned verisinden (Troy Hunt ile) yayımladığı en sık sızan 100.000 parola | SecLists MIT; Pwned Passwords verisinde lisans ya da atıf şartı yok |
| SecLists `Passwords/Common-Credentials/Language-Specific/Turkish_Pwdb_common-password-list-top-150.txt`, aynı commit | Sızıntılarda en sık görülen 150 Türkçe parola ([Pwdb-Public](https://github.com/ignis-sec/Pwdb-Public)) | SecLists MIT, Pwdb-Public MIT |
| `turkce-ve-baglam.txt` (bu depo) | Kulüp, okul, takım, şehir ve sık Türkçe kelimeler; `build.mjs` her birine sayı ve yıl ekleri ekler (NIST SP 800-63B: hizmetin adı ve bağlama özgü kelimeler) | bu depo |

`build.mjs` iki dosyayı commit'e sabitli adreslerden indirir, SHA-256'larını doğrular, kök
kelimeleri genişletir; hepsini küçük harfe çevirir, 8 karakterden kısaları atar (o parolaları
`length(8)` zaten reddeder), tekrarları ayıklar ve sıralar. Yaklaşık 50.000 satır, 500 KB;
Keycloak'ın bellekteki süzgeci yaklaşık 120 KB'tır.

```bash
node password-blacklists/build.mjs          # listeyi yeniden yazar
node password-blacklists/build.mjs --check  # depodaki liste kaynaklardan üretilenle aynı mı
```

`tests/check-version-consistency.sh` her CI koşusunda dosyanın biçimini, imaja girdiğini ve
politikanın onu adlandırdığını denetler. Entegrasyon testi (`tests/run-integration.sh`,
`tests/sky-account-contract.sh`) listedeki parolanın gerçekten reddedildiğini ve Türkçe cümleyi
denetler.

## Geri dönüş

Listeyi taşımayan bir imaj, politikasında `passwordBlacklist` olan bir realm'i okuyamaz
(Keycloak listeyi bulamayınca hata verir). Bu değişiklikten önceki bir imaja dönmeden önce iki
realm'in (production ve sandbox) parola politikası `length(8) and notUsername and notEmail`
yapılır; sonra imaj döner.
