# Async katalog bağlantısı ve eski credential yolunu silme

## Kapanan dilim

`api/catalog/request.el` katalog GET hazırlığının dar adapter'ıdır. Mevcut
`connection-resolve-async` ve bounded credential child portunu kullanır;
HTTP/auth/header assembly hâlâ Rust'tadır. Yeni ağ, auth-source veya metadata
motoru eklenmedi. Canonical cevap mevcut tek native metadata actor'üne gider.

Katalog published config'i tüketir. Disk refresh explicit config/UI girişinin
işidir; katalog getter'ına gizli dosya okuma eklenmez. Böylece eşzamanlı
catalog GET'leri birbirlerinin config refresh generation'ını geçersiz kılmaz.
Provider, URL, public kararı, wire, raw header binding ve application ilk
credential yield'inden önce yakalanır. Bekleyen sonuç başka provider'a veya
application'a yönlendirilmez. Aktif chat'in bound connection'ı bağımsız katalog
isteğine endpoint/wire/anahtar ödünç veremez.

Yalnız registry'nin tam public models URL'si credential lookup'ı atlar. Custom
endpoint public iznini miras almaz. Private dedicated models URL için mevcut
provider API-host credential seçimi korunur; bu adım yeni bir host trust/egress
politikası tanımlamaz. Native redirect/TLS ve header kontrolleri değişmez.

Origin close/mode change, explicit cancel ve deadline root'un credential child,
transport ve metadata publication cleanup'ını kapatır. GET için yeni tam süre
başlatılmaz; root deadline'ın kalan süresi aktarılır. Selection değişimi veya
agent Stop bağımsız discovery'yi iptal etmez. Session/config/endpoint değişimi
credential kabulünde GET'ten önce reddedilir. Geç/çift cevap yeniden iş açmaz.
Kapanış private credential scope'u ve ona ait request key kopyasını temizler;
transport/config/GC/debugger kopyalarının tamamı için fiziksel silme iddiası yok.

## Yeni bulgu: application-bound credential doğrulaması

Genel connection resolver'ın geç callback'indeki config revision kontrolü
önceden o anda current olan application'ın config servisini okuyabiliyordu.
Valid-p ve callback artık başlatan application'a bağlıdır. Kontrol başka bir
dinamik bound connection'ın endpoint'ini de kullanmaz. İki application farklı
revizyonlardayken ilk application's credential'ı yalnız ilk owner için kabul
edilir. Gerçek metadata/publication bariyeri veya chat selection kuralı gevşetilmedi.

## Silinen eski Elisp

- `kargu--resolve-api-key`, `kargu-config-api-key`,
  `kargu-config-resolve-api-key-result` senkron girişleri.
- `kargu--auth-source-search-safe`, `kargu--auth-source-api-key`, nonblocking
  bayrağı ve yalnız eski yolda kullanılan backend/endpoint yardımcıları.
- Eski katalog GET/credential assembly gövdesi ve artık kullanılmayan declarations.

Precedence/global key owner/explicit empty key/env fixture'ları memory-only
portu kullanır. Encrypted/unsupported backend fixture'ı gerçek async portta
typed unavailable sonucunu denetler; silinen API'yi test için yeniden tutmaz.
Production auth-source araması yalnız fixed child script'inde kalır.
Setup'ın async facade'ı hâlâ tüketicilidir; last consumer taşınmadan silinmedi.

## Kanıt ve sınır

Altı yeni test: delayed immutable target + iki application, cancel/kill/mode/
deadline/config/session matrisi, redacted error + late completion, foreign chat
connection izolasyonu, gerçek plaintext child -> Rust -> loopback GET ve gerçek
slow child'ın origin kill ile kapanması. Mevcut public metadata, ordering,
projection, connection ve config regresyonları korunur. İlk yeni fixture'ın
hook assertion'ı Emacs'in inherited global hook'larını yanlışlıkla sahipleniyordu;
yalnız adapter'ın eklediği hook'un kaldırılmasını denetleyecek şekilde düzeltildi.

Final gate sonuçları 12'de tutulur. Bu dilimde Rust production kodu değişmedi;
native suite tekrar mevcut motorun regresyon kapısı olarak çalıştırıldı.
Somut yeni TLC/refinement ispatı iddia edilmez. Genel run/history, native config
ve endpoint policy, G08 hard monetary reservation ve dört uygulama backend'i
açıktır. Credential interop child'ı Rust config motoru tamamlanmış sayılmaz.
Kullanıcının shell.nix/07 değişiklikleri ve 01 korunur; gerçek uzak API/CLI
model turu, hesap/login, credential taşıma, kurulum, merge veya push yapılmadı.
