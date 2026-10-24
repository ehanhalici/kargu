# 03. HARİCİ BACKEND VE MCP KÖPRÜLERİ

Harici agent backend'i, doğrudan model API adapter'ı ve Emacs araçlarını sunan
MCP server üç ayrı capability'dir. Birine sahip olmak diğerini sağlamaz.
Her adapter opsiyoneldir; eksik binary/login/sürüm `unavailable` döner.
Hiçbiri çekirdek Rust geçişini bloke etmez.

## 1. Ortak backend sözleşmesi

Backend start_turn, event stream, cancel, resume, usage ve approval
capability'lerini açıkça bildirir. Harici thread/turn kimlikleri Kargu
session/run kimlikleriyle sahipli bir tabloda eşlenir. Backend zaten agent
döngüsünü yürütüyorsa Rust ikinci bir model/tool döngüsü başlatmaz.

Kargu politikası sadece Kargu execution gate'inden geçen araçlara uygulanır.
Harici agent'ın kendi Bash/Edit araçları otomatik olarak bu kapıya girmez.
Yazabilen backend için kendi araçları kapatılarak Kargu üzerinden delegasyon
veya eşdeğer izin/OS izolasyonu belgelenip test edilmelidir. Bu sağlanamıyorsa
adapter yalnız salt okunur öneri modunda sunulur. Dirty buffer dosyalarına
harici agent'ın doğrudan yazması desteklenmez.

## 2. Claude Code

Headless CLI adapter sürüm sabitlenmiş `claude -p` ve belgelenmiş JSON stream
seçeneklerini kullanır. Prompt stdin'den verilir; shell interpolation yapılmaz.
Argümanlar, partial-event seçenekleri ve resume davranışı seçilen CLI sürümüne
ait fixture'larla doğrulanır. Exit code ile final result olayı birlikte
incelenir. stdout/stderr, process group, timeout, cancellation ve output cap
08/11 kurallarına tabidir. Login kullanıcıya aittir; credential kopyalanmaz.

MCP ayrı yöndür: Claude Kargu araçlarını çağırabilir; bu tek başına Claude'u
Emacs'ten chat backend olarak çalıştırmak anlamına gelmez.

Kaynak: [Claude Code programmatic kullanım](https://code.claude.com/docs/en/headless)
(2026-10-24 kontrolü).

## 3. Codex

Doğrudan OpenAI API adapter'ı Codex CLI entegrasyonu değildir. Editör entegrasyonu
için `codex app-server` adapter'ı planlanır. Sabitlenen binary'nin ürettiği
JSON Schema kullanılır; initialize/initialized, thread/turn, reverse approvals
ve iptal olayları Kargu sözleşmesine çevrilir. App-server wire formatındaki
`jsonrpc` alanı farkı adapter'da ele alınır; Emacs <-> Kargu protokolü değişmez.
Deneysel özellikler varsayılan açılmaz; paketlenen sürüm ve desteklenen
yöntemler release notlarında yazılır.

Kaynak: [OpenAI Codex App Server](https://learn.chatgpt.com/docs/app-server)
(2026-10-24 kontrolü). Uygulamada binary şeması yeniden doğrulanır.

## 4. Google Antigravity

Belgelenmiş başlangıç noktası MCP üzerinden Kargu araçlarını sunmaktır.
`/tmp/antigravity.sock` veya belli bir WebSocket portu varsayılmaz. MCP desteği,
Antigravity konuşmasını Emacs'ten başlatma ya da plan olaylarını alma API'sinin
kanıtı değildir. Chat backend capability'si ancak resmi protokol, sürüm ve
uçtan uca fixture ile doğrulanırsa eklenir; o zamana kadar `unsupported` kalır.

Kaynak: [Google Antigravity MCP](https://antigravity.google/docs/mcp)
(2026-10-24 kontrolü).

## 5. MCP topolojisi ve erişim

İlk sunum stdio MCP'dir. Harici istemcinin başlattığı `kargu-mcp` proxy süreci,
Emacs'in sahip olduğu mevcut core'a application/session kapsamlı, kısa ömürlü
capability ile bağlanır. Yeni headless core başlatıp canlı editör varmış gibi
davranmaz. Yerel IPC Unix socket'i kullanıcıya özel runtime dizininde, 0700
dizin/0600 socket ve kimlik doğrulama ile açılır. Peer ve capability birlikte
kontrol edilir; socket yolu tek başına yetki değildir. Session kapanınca grant
iptal olur. Emacs yoksa delegated araçlar `unavailable` döner.

MCP initialize/capability negotiation, tools/list, tools/call, cancellation ve
tool result sözleşmeleri sabitlenen MCP sürümüyle test edilir. Tool list
yalnız izinli capability'leri gösterir; yürütme anında yeniden gate uygulanır.
Streamable HTTP eklenirse Origin doğrulaması, authentication ve loopback bind
zorunludur. Kargu özel IPC yöntemleri MCP standardı gibi sunulmaz.

Kaynak: [MCP transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).

Kabul: iki MCP istemcisinin session karıştıramaması, replay/foreign scope reddi,
Emacs kapanması, geç approval, backend crash, kirli tampon ve cancel sonrası
geç olay testleri. Gerçek ürün smoke testleri sürüm/tarihle kaydedilir; offline
fixture başarısı canlı ürün desteği olarak sunulmaz.
