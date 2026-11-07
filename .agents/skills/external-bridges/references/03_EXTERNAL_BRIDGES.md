# 03. HARİCİ BACKEND VE MCP KÖPRÜLERİ

## 0. Kesin ürün kapsamı ve provider seçimi

2026-10-24 kullanıcı kararı: mevcut doğrudan API desteği **Elisp'ten Rust'a
taşınacak ve korunacak**. Buna ek olarak **Codex, Antigravity, Claude Code ve
OpenCode** uygulamaları üzerinden çalışma desteği gelecek. Uygulama desteği
API'nin yerine geçmez; aynı Kargu GUI'sindeki **provider alanından** iki yol
da seçilir. Dört uygulama nihai teslim kapsamındadır; yalnız bazılarını ekleyip
diğerlerini listeden çıkarmak bu gereksinimi karşılamaz.

Harici agent backend'i, doğrudan model API adapter'ı ve Emacs araçlarını sunan
MCP server üç ayrı capability'dir. Birine sahip olmak diğerini sağlamaz.
Bir uygulamanın yalnız Kargu MCP araçlarını çağırması, o uygulamanın Kargu'da
seçilebilir konuşma backend'i olduğu anlamına gelmez.

Adapter'lar **kurulum/çalıştırma bağımlılığı olarak opsiyoneldir**, ürün kapsamı
olarak değil: kullanıcının dört uygulamayı da kurması gerekmez. Eksik veya
bozuk bir uygulama API yolunu ve diğer backend'leri devre dışı bırakmaz.
Desteklenmeyen bir uygulama protokolü ilgili adapter'ın açık teslim engelidir;
API göçünü durdurmaz ama dört-backend gereksinimi tamamlandı sayılmaz. Kapsam
daraltma ancak kullanıcının açık kararıyla yapılır.

Rust discovery servisi bilinen kurulum yollarını/PATH'i ve explicit kullanıcı
executable/connection ayarını inceler; Emacs yalnız snapshot'ı gösterir.
Keşif chat penceresinin açılmasını bloke etmez; probe'lar bounded output,
deadline ve owner/generation ile çalışır. Keşif kendiliğinden turn başlatmaz,
login/kurulum yapmaz veya onay ayarlarını gevşetmez.

Provider picker aynı alanda `API` ve `Uygulamalar` gruplarını ayırt eder.
Kurulu uygulamalar adlarıyla görünür; kullanılabilir olan seçilip prompt
gönderilebilir. Kurulu fakat hazır olmayan kayıt görünür kalır; neden ve
gerekli kullanıcı adımı gösterilir, prompt gönderimi engellenir. Kurulu
olmayan kayıt çalışabilir seçim gibi gösterilmez; isteğe bağlı kurulum
bilgisinde `not_installed` olarak listelenebilir.

Keşif/uygunluk durumu typed'dır: `NotInstalled`, `InstalledUnverified`,
`NeedsLogin`, `UnsupportedVersion`, `UnsupportedProtocol`, `ProbeFailed`,
`Ready`. Login gerekmeyen backend'e yapay login koşulu konmaz; belirsiz
durum `Ready` sayılmaz. Yalnız binary bulunması veya pencerenin açık olması
çalışır entegrasyon kanıtı değildir. Uygulama yolu/sürümü/protokolü, gerekli
auth/config ve güvenlik capability'leri doğrulandıktan sonra `Ready` yayımlanır.
Otomatik, yan etkisiz probe yeterli değilse kullanıcıya explicit bağlantı testi
sunulur; model isteği veya ücretli turn keşif sırasında gizlice başlatılmaz.

Core, doğrudan API seçimini ve yerel uygulama seçimini farklı domain tipleri
ile taşır; API provider namespace'i uygulama kimliğiyle çakışmaz. Eski provider
config'i API kaydı olarak korunur; sessizce başka yürütme yoluna çevrilmez.
Aktif run'da backend değiştirilemez. Selection session'a aittir; admission'da
backend/config/capability revision snapshot'ı alınır. Uygulamanın kendi
model/effort seçenekleri kullanılır; REST model kataloğu zorla uygulanmaz.

Kurulu uygulamayla çalışma, başkasının açık GUI konuşmasına otomatik bağlanma
anlamına gelmez. Adapter, desteklenen protokolle Kargu'nun sahip olduğu ayrı
oturumu başlatır veya açıkça yapılandırılmış servise bağlanır. Mevcut GUI
oturumuna attach ancak ilgili protokol ve sahiplik kanıtı destekliyorsa yapılır.
Kargu'nun başlatmadığı paylaşımlı uygulama/servis Stop ile topluca öldürülmez.

## 1. Ortak backend sözleşmesi

Backend start_turn, event stream, cancel, resume, usage ve approval
capability'lerini açıkça bildirir. Harici thread/turn kimlikleri Kargu
session/run kimlikleriyle sahipli bir tabloda eşlenir. Backend zaten agent
döngüsünü yürütüyorsa Rust ikinci bir model/tool döngüsü başlatmaz.

Her uygulamada asgari kabul: Kargu provider alanından seçim, prompt/turn
başlatma, akışın normalize edilmesi, başarı/hata terminal sonucu, Stop/iptal
ve session izolasyonu. Resume, usage, model/effort ve approval desteği ayrıca
capability ile bildirilir; olmayan özellik varmış gibi gösterilmez, bilinmeyen
usage/fiyat sıfır sayılmaz. Aktif backend kaybolursa hata açıkça gösterilir;
başka backend/API'ye sessiz geçiş veya yan etkili turn replay yapılmaz.

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

2026-10-25 güncellemesi: resmî Antigravity CLI (`agy`) headless dokümanı bulundu.
Konuşma adayı stdin/stdout stream-json'dur; `/tmp/antigravity.sock` veya keyfî port
varsayılmaz. `init`/`step_update`/`result` ayrımı, explicit conversation kimliği ve
session-cumulative usage için per-turn fark hesabı fixture'la sabitlenir. `agy`
bu makinenin PATH'inde yoktur; desktop kurulumu CLI/auth/protokol kanıtı değildir.

Headless input `control_request`/`control_response` kabul etmez. Onay isteyen
araçlar soft-deny olabilirken workspace yazıları varsayılan olarak izinlidir;
exit 0 tek başına başarı/yan-etkisizlik değildir. Ask/Plan güvenliği ve interaktif
review bağlantısı ayrıca doğrulanmalıdır. `--dangerously-skip-permissions`
otomatik eklenmez; kullanıcı ayarları sessizce değiştirilmez. Sürüm, model/auth,
izin profili, cancellation/drain ve gerçek ürün smoke kabulü bitmeden `Ready`
ilan edilmez. MCP-only destek yine konuşma backend'i teslimi sayılmaz.

Kaynak: [Google Antigravity MCP](https://antigravity.google/docs/mcp)
(2026-10-24 kontrolü); [resmî CLI headless](https://www.antigravity.google/docs/cli/headless/)
(2026-10-25 kontrolü). Dört backend kapsamı daraltılmadı.

## 5. OpenCode

OpenCode ayrı bir yerel uygulama backend'i olarak aynı provider alanına
eklenir; bir OpenAI-compatible API endpoint takma adı sayılmaz. Kurulum ve
explicit executable/connection ayarı diğer uygulamalarla aynı discovery
sözleşmesine tabidir.

Uygulamaya geçmeden seçilen OpenCode sürümünün resmi headless/server/SDK
entegrasyon yolu doğrulanıp wire şeması ve olay fixture'ları sabitlenir;
doğrulanmamış komut bayrağı, port veya oturum protokolü varsayılmaz. Gerekirse
Kargu'ya ait child servis başlatma ile kullanıcının yapılandırdığı mevcut
servise bağlanma ayrı sahiplik modelleri olarak uygulanır. Başlatılan child
08/11 process/drain kurallarına tabidir; borrowed servis global olarak
öldürülmez. Login/config kullanıcıya aittir, credential kopyalanmaz.

Prompt/stream/terminal/cancel/session eşlemesi ortak backend sözleşmesine
çevrilir. Kendi agent döngüsü varsa Kargu paralel bir tool/model döngüsü
başlatmaz. Native tool yetkileri ve dirty-buffer politikası diğer üç backend
ile aynı kabul kapısından geçer. Bu bölüm hedef sözleşmesidir; henüz canlı
OpenCode entegrasyonu veya doğrulanmış protokol desteği iddiası değildir.

## 6. Uygulama backend'leri için kabul kapısı

- API yolu ve dört uygulama aynı provider picker fixture'ında yer alır;
  yalnız kurulu olanlar, eksik binary, uyumsuz sürüm, login gereksinimi ve
  başarısız/timeout probe durumları görünür ve doğru sınıflandırılır.
- Codex, Antigravity, Claude Code ve OpenCode için ayrı discovery, adapter
  wire/stream ve gerçek Kargu -> Rust -> uygulama -> stream/terminal smoke
  testleri bulunur. Her sonuç binary/ürün sürümü ve tarihle kaydedilir.
- Model/effort capability, desteklenmeyen seçenek, bilinmeyen usage, aktif
  run'da seçim değiştirme, restart/crash ve geç keşif/turn event'i test edilir.
- İki application/session arasında history/thread/turn, credential ve approval
  karışmaz; Stop yalnız sahibini iptal eder. İptal sonrası geç başarı reddedilir.
- Backend'in kendi Bash/Edit yetkisi, onay delegasyonu/izolasyonu ve dirty
  buffer güvenliği kanıtlanmadan yazabilen mod açılmaz. Yalnız read-only
  kullanılabiliyorsa UI bu sınırı açıkça gösterir; tam mod eşdeğerliği sayılmaz.
- Antigravity için MCP-only başarı bu kapıyı kapatmaz. Dört adapter'dan biri
  doğrulanamıyorsa ilgili kutu açık kalır; API desteği çalışmaya devam eder.

## 7. MCP topolojisi ve erişim

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
