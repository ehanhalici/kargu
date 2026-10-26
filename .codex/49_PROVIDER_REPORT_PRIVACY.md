# Provider değiştirme raporunda endpoint gizliliği — 2026-10-26

Native config geçişinde bulunan todo 1 alt işi kapatıldı: `kargu-set-provider`
tam API-base'i hem log hem echo-area message'a yazıyordu. Endpoint query'sine
konan key/tenant değerleri normal credential sarmalayıcısını atlayarak bu yoldan
görünebilirdi. Endpoint bilgisi rapordan tamamen çıkarıldı; yeni URL parse,
redaction regex'i veya ikinci bir policy engine eklenmedi. Log/UI yalnız mevcut
provider ve model kimliğini bildirir, raporlama için API-base okunmaz.

Provider/model seçimi, no-model davranışı, mevcut endpoint/config ve prefetch
hedefi değişmez. Native request/URL/credential motorları aynı portlarda kalır.
Bu bir config migration güvenlik düzeltmesidir; native selection/file IO
cutover'ının veya bütün log-egress kabulünün tamamlandığı anlamına gelmez.

Tek yeni ERT, model seçimi açık/kapalı iki dalı gerçek seçim fonksiyonundan
geçirir. Sentetik endpoint query/key/tenant config'i kullanır; raporların endpoint
okumasını da yasaklar, log ve UI'da hiçbir endpoint/credential değeri kalmadığını
denetler. Prefetch offline stub'dır ve doğru provider'a bir kez çağrıldığını
assert eder; gerçek upstream istek yoktur. Test eski kodda `Reports must not
read the endpoint` ile kırıldı, production düzeltmesinden sonra geçti.

Final **1257/1257 full source ERT**, 0 unexpected, **139.06 s**, **08:25:10
Europe/Istanbul** geçti. İki değişen Elisp dosyası Werror bytecompile/checkdoc
temizdir; elc yalnız task-specific /tmp dizinindedir. Rust kaynağı değişmedi;
önceki native parser commit'indeki 274 native + 18 compile-fail, fmt ve strict
Clippy kanıtları yeni bir Rust özelliği gibi sunulmaz. Kullanıcının 01/07/shell.nix
değişiklikleri ve gerçek config/credential dosyaları korunur; kurulum, uzak API/
hesap/CLI turu, merge/push veya canlı Emacs reload yoktur.
