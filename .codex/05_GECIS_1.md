# 05. KATMAN 1: CANLI EDİTÖR ADAPTER'LARI

Bu dosya katman tanımıdır; uygulama sırası 04 yol haritasındadır. İlk yapılacak
iş sensörleri silmek değildir. Mevcut LSP/Dape adapter'ları reverse RPC arkasına
alınır; davranış eşdeğerliği kanıtlandıktan sonra sadeleştirilir.

## 1. Sorumluluk sınırı

Rust policy, deadline, aggregation ve LLM formatını yönetir. Emacs canlı
belge sürümü, Eglot/Flymake publication, Dape connection/thread/frame kimliği,
hook ve callback sahipliğinin kaynağıdır. Rust'taki metadata veya bekleme
süresi bu runtime kanıtlarının yerine geçemez.

Her çağrı 07'deki scope'u, explicit file/document kimliğini ve gerekiyorsa
debug connection/thread/frame + stop generation bilgisini taşır. Asenkron
callback, kaydettiği kaynağın hâlâ aynı olduğunu yanıt öncesi doğrular.
Geçersiz hedefte `current-buffer` fallback'i yoktur. İmleç veya pencere
değişmesi istek sahibini değiştirmez.

Eglot, Dape, Xref ve completion UI bağımlılıkları opsiyoneldir. Yokluk
`unavailable` üretir; boş ve başarılı sensör sonucu gibi gösterilmez.
Private Emacs API erişimi sürüm kontrollü adapter içinde tutulur.

## 2. LSP / Flymake

| Mevcut kaynak | Nihai sahiplik |
| --- | --- |
| lsp/diagnostics.el, freshness.el | Emacs document tick, server/document version, backend/report generation ve publication kanıtı; Rust aggregation ve deadline |
| lsp/settle.el | Emacs asynchronous observation/cleanup; Rust bekleme bütçesi |
| lsp/symbols.el, skeleton.el | Emacs typed sembol/range snapshot; Rust formatlama ve token kırpma |
| lsp/context.el, register.el | Emacs hedef yakalama; Rust araç şeması/prompt |
| languages/* | Emacs major-mode/LSP/DAP ayarları; Rust'a yalnız serializable capability metadata |

`std::fs::metadata` kaydedilmemiş tamponun diagnostik tazeliğini belirleyemez.
Verification ancak istenen belge revizyonuna ait yeni raporla temiz sayılır.
Henüz rapor gelmemiş boş Flymake listesi `pending/stale` durumudur.
Sırf debounce süresi doldu diye `verified` yayımlanmaz.

Wire konumu: 1 tabanlı satır, 0 tabanlı Unicode scalar sütun. Emacs
char/byte, LSP'nin negotiated UTF-16/UTF-8 konumları ve DAP sütunları adapter'da
dönüştürülür. Tab genişliği ve görsel sütun konum sayılmaz. Uç değerler ve
satır sonunu aşan sütun reddedilir.

Diagnostic nesnesi file/document_id, revision, source, publication generation,
range, severity (`error/warning/note/info`) ve message taşır. Flymake
`:error` sembolü wire'a `":error"` olarak sızmaz. Konum, diagnostic'in
kendi buffer'ında `save-restriction/widen/save-excursion` ile hesaplanır.

Xref location alt tipleri normalize edilir; her location'ın file-location
olduğu varsayılmaz. Definitions, references ve document_symbols desteklenir.
Imenu marker/cons ve Dape/Eglot nesneleri doğrudan JSON serileştirilmez.
Sembol için name/kind/range/selection_range/children DTO'su üretilir.

## 3. Dape

Mevcut execution, lifecycle, preflight, policy, readiness, workspace, session,
commands, events, launch, context, selection ve watch sorumlulukları korunur.
Rust debug state'in tek gerçek kaynağı olmaz; Emacs'teki connection/stop event
kimliğini izler. Kullanıcı debugger'ı elle çalıştırınca eski snapshot geçersizdir.

- Launch/config seçimi, compile/startup ve readiness ayrı aşamalardır. Rust
  shell derlemeyi sahiplenebilir; Emacs Dape bağlantısını oluşturur ve doğrular.
- Komut allowlist'i: mevcut register.el'deki araçlar ve alias'lar export edilir.
  Step/continue/pause/restart/close, breakpoint ve watch desteği kaybolmaz.
- `evaluate` ve execution_control yan etkili kabul edilir; Rust gate'i ve
  Emacs'in connection/thread/frame revalidation kontrolü zorunludur.
- Frame/variables references sadece bağlı connection ve stop generation'da
  geçerlidir. Gecikmiş scopes/variables başka frame'e yapıştırılamaz.
- Büyük değişkenler depth/item/byte limiti ve truncation bilgisiyle döner.
  Async DAP yanıtı bitmeden işlem başarılı sayılmaz.
- Owner buffer kapanması, connection replacement, continue, reset ve timeout
  pending callback/hook/timer'ları temizler; tek terminal teslim yapılır.

Kanonik snapshot alanları: `connection_id`, `stop_generation`, `thread_id`,
`current_frame`, `local_variables`. Frame file/range ve variable name/value/
var_type/children_reference DTO'larıdır. `frame/scopes` şeklinde ikinci,
uyumsuz bir JSON şeması kullanılmaz.

## 4. Kabul kapısı

Mevcut test-lsp*, test-dape*, test-languages ve test-mode-ownership senaryoları
RPC adapter'ı üzerinden de çalışır. Özellikle iki workspace, yanlış thread,
geç frame yanıtı, Dape startup/compile failure, dirty buffer, stale diagnostics,
emoji/CRLF konumları, eksik adapter ve cancel test edilir. Emacs filter içinden
senkron LSP bekleme veya call-process çalıştırılmaz. Rust timeout'u bloke olmuş
Emacs event loop'unu kendi başına düzeltemez.
