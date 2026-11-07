# Model HTTP/SSE core cutover

36e0e1a ile catalog single-source olduktan sonra chat GET/POST ve model
discovery ağ yolu Rust api/{domain,http,stream/} portuna bağlandı. Elisp
api/sse.el, api/stream.el ve HTTP watchdog/flush/parser engine'i silindi.
Transport.el artık yalnız owned editor delivery ve bounded body projection
adapter'ıdır. Network subprocess/curl/plz çağrısı ve engine fallback yoktur.
Plz henüz taşınmamış retry hata DTO uyumluluğu için kalır; HTTP yapmaz.
Curl global model-run prerequisite olmaktan çıktı; webfetch ayrı kalır.

## Capture, lifetime ve güvenlik

API provider/model/sampling/wire capture mevcut immutable connection portunda
kalır. HttpRequest typed URL/method/header/body/timer/limit admission yapar.
Öğrenim: Elisp copy-tree t, cons/vector kopyalasa da mutable string'leri
kopyalamaz. URL, body ve header key/value string'leri startup beklenmeden
ayrı kopyalanır; in-place mutation regresyonu bunu sınar.
SecretString zeroizing bellekte tutulur; Debug/Display ***, Serialize yoktur.
HeaderValue sensitive işaretlidir. Reqwest kendi HTTP buffer'larında kopya
tutabilir; tüm process belleği için zeroization veya encryption iddiası yoktur.
TLS doğrulaması açık, redirect policy none, automatic Referer kapalıdır.
Çözülmemiş URL template/userinfo/fragment ve override Host/Content-Length/
Transfer-Encoding/Connection/Proxy-Authorization/header injection reddedilir.
Model endpoint açıkça yakalanır; localhost model sunucuları webfetch egress
kurallarıyla yanlışlıkla engellenmez. Bu bir genel OS/network sandbox değildir.

Single-writer IPC API service en çok 8 deneme sahiplenir; IO worker Host'u
değiştirmez. Worker completion toplanmadan admission slot bırakılmaz. Cancel,
session close, shutdown, EOF ve writer failure socket/future'ı bırakır; geç
event publish edilmez. Bu servis eski editor run coordinator'unun portudur,
native agent run admission/History/AgentLoop'un taşındığı anlamına gelmez.
Shutdown response IO drain arkasındadır; ping/cancel mailbox'ı bloke olmaz.
Socket drop sağlayıcı tarafındaki üretim/faturalamanın durduğunu garanti etmez.
Sistem DNS resolver'ı OS blocking lookup kullanabilir. Connect/first-byte
await sınırıdır; OS resolver syscall'ını zorla kesme/refinement garantisi
verilmez. Bu sınır yerel-IP socket testleriyle kapatılmış sayılmaz.

Connect / first-byte / idle / absolute deadline ayrı tiplerdir. Connect
10s, first-byte 30s editor ayarıdır; idle/total explicit null ile kapanabilir.
HTTP denemesinin içine gizli retry konulmadı: eski budget debit her denemede
hala geçerlidir. Retry/circuit nihai kesimde native budget/lease ile birlikte
taşınmalıdır; iki retry motoru paralel çalıştırılmaz.

## Stream ve IPC sınırları

Raw 4MiB, line 64KiB, event 1MiB, calls 64, per-call args 512KiB üst
sınırdır; captured editor ayarları bunları yalnız düşürebilir. UTF-8 complete
line'da çözülür; multiline data/comments/CRLF, decimal tool indexes, legacy
function_call, complete argument snapshots, reasoning/content blocks korunur.
Finish reason veya DONE olmadan EOF başarısızdır; error latch canlanmaz,
terminal sonrası content/calls yok sayılır, trailing usage kabul edilir.
Tool fragments UI olayıdır; çalıştırılabilir sonuç yalnız final completion'dır.

Bounded channel 16 event tutar. Actual writer byte capacity network publish'i
backpressure eder, actor cancel/owner-close alabilir. Büyük final JSON body
32KiB veya negotiated frame'e göre daha küçük UTF-8 sayfalarla gider; frame
1MiB kalır, editor body assembly 8MiB ile sınırlıdır. Body-transfer ayrı 30s
deadline'a tabidir. UI consumer exception yalnız kendi waiter'ını iptal eder.
Any published delta sonrası failure otomatik replay'e kapalıdır.

HTTP hata gövdeleri/URL/credential log veya error DTO'ya taşınmaz. Bounded
64KiB / 1s error decode yalnız context-overflow sınıfını çıkarır; provider'ın
input-too-long mesajları içerik olarak iletilmez. Token-rate/output-token
hatası context overflow değildir. 200 error code/type için explicit overloaded
ve rate-limit mapping vardır; bilinmeyen hata generic protocol error'dur.

## Kanıt ve kalan sınır

Rust api_stream testleri eski Elisp parser/pressure/UTF-8/fragment/terminal
regresyonlarını alır; ERT aynı test engine'ini tutmaz. Yerel socket fixture'ları
GET/POST/SSE/redirect/timeouts/cancel/backpressure/context classes'ı sınar.
Real stdio ping, cancel/session-close/shutdown/EOF ve socket drain testlidir.
Real Emacs -> stdio -> Rust -> loopback, 1.2MiB model-body pagination ve owned
callback/capture testleri de vardır. Gerçek hesap/ücretli model çağrısı yoktur.
OpenAI resmi Chat Completions streaming reference indexed fragments ve usage
chunk sözleşmesini doğrulamak için açıldı; model/endpoint upgrade yapılmadı.

Kalan: Elisp wire/request-policy dönüşümleri, model-discovery metadata
normalization/store, retry/circuit ve editor history/agent orchestration.
Provider registry halen bu okuyucuların UI/config facade'ıdır; literal katalog
ve HTTP/SSE motoru içermez. Bunlar taşınmadan topluca silinmez. API + dört app
backend kapsamı ve canlı hesap testlerine ilişkin ayrı onay sınırı değişmedi.
TLC transport modeli yeniden taranabilir; bu yeni HTTP implementation için
concrete refinement ispatı değildir.
