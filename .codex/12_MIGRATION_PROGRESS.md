# Rust geçişi: uygulama günlüğü

## 2026-10-25 — Gerçek root-run budget cutover ve legacy motor kaldırma

Root run budget intent'i async hazırlıktan önce yakalar; logical API/retry aynı
native ID'yi kullanır. Standalone API lifetime ayrı tutulur. Native sayaçlar
tek kez project edilir; eski Elisp debit/refusal/token toplama motoru silindi.
Tool text artık provider usage diye işaretlenmez. Epoch kaybında sıfır ledger
ile yeniden açılma yoktur. Geç/reentrant allocation ve seal/drain korunur.

**1169/1169 full source ERT**, 0 unexpected, **125.26 s**, touched Werror byte
compile/checkdoc temiz; üretilen .elc kaldırıldı. 12 editor budget testi ve
gerçek root-run/HTTP path dahildir. Native baseline **170 + 4 compile-fail**.
Önceki policy testlerinin native karşılıkları ve private bulk/token-debit
helper'ının sınırı 36'da açıkça eşlenmiştir; baseline tablosu değiştirilmedi.
Constructor/seal normal-loop wiring açığı kapandı; G08 hard reservation/pricing,
native genel claim/tool/run birliği, retry/breaker ve agent/history hâlâ açık.
Kullanıcı shell.nix/07 değişiklikleri commit dışındadır.

## 2026-10-25 — Native HTTP budget admission ve drain

`ipc/api/` modülerleştirildi; `api_budget` capability ve owned open/snapshot/
close servisleri eklendi. API POST her fiziksel denemeyi IO öncesinde native
kapıdan geçirir; mevcut budget'ı atlama, foreign ID, overlap ve yeniden canlanan
closed ID reddedilir. Close yalnız charged HTTP işi join/collect olduktan sonra
yanıtlanır. Deadline admission/network/final-body egress için ortaktır; gerçek
usage bir kez toplanır. Ayrıntılı sınırlar ve kalan işler 36'dadır.

**170 Rust testi + 4 compile-fail**, locked build, fmt ve strict Clippy geçer.
**1170/1170 full source ERT**, 0 unexpected, **124.77 s**. Yedi yeni real
stdio/socket ve iki mailbox testi dahildir. Yeni bağımlılık/ücretli çağrı yok.
Henüz editor root-run consumer cutover değildir; eski Elisp budget motoru bir
sonraki bağlantı kesimine kadar korunur. Native genel claim/agent/history,
retry/breaker ve G08 reservation/pricing hâlâ açıktır.

## 2026-10-25 — Native API budget domain foundation

Typed budget meter eklendi: bounded attempt/compaction limits, checked exact
usage, missing/partial/zero ayrımı, consumed seal ve move-only completion
ticket. 13 yeni native test ve iki compile-fail sözleşmesi geçti; strict Clippy
ve fmt temiz. Önceki bütün Rust testleri de geçer. Detaylar 36'dadır.
Bu kesim henüz live consumer cutover değildir: capability ilan edilmedi,
Elisp budget silinmedi; HTTP admission/run binding ve G08 reservation açık.

## 2026-10-25 — Editor application lease API consumer cutover

POST ve model GET artık editor application'a ait native service scope'uyla
çalışır; root standalone scope'una sessiz fallback yoktur. Thin lease portu
coalescing, detached strings, late acquisition/close, reentrant observer ve owner
startup cancellation sınırlarını korur. Cyclic owner graph DTO gibi deep-copy
edilmez; nested startup cleanup'ları stack'te tutulur. Detaylar 35'tedir. Bu,
henüz native user-history/run import'u değildir; diğer tool service tüketicileri
eski explicit standalone scope'ta kalır.

**1169/1169 full source ERT**, 0 unexpected, **125.41 s**; son reentrant failure
guard'ı sonrası **47/47** focused source ERT geçer. Touched checkdoc ve
warning-as-error bytecompile temiz; geçici .elc kaldırıldı. Rust baseline aynı
**148 + 2 compile-fail**'dır. Real stdio API scope isolation ve drain kabulü
dahildir. Canlı hesap/ücretli CLI/kurulum yok. Antigravity resmî `agy` headless
protokol dokümanı bulundu; güncel izin/cumulative-usage/Ready koşulu 03 bölüm 4'e
eklendi. PATH'te codex/opencode var, agy/antigravity/claude görünmedi; bu yalnız
read-only presence kontrolüdür, sürüm/auth/Ready kanıtı değildir.

Bütçe ön incelemesi yeni bir wiring açığını doğruladı: budget.el constructor/
seal normal loop tarafından çağrılmıyor; HTTP/tool'da yalnız optional context
tüketicileri ve testler var. Native API budget geçişi canonical sayacı gerçek
run'a bağlamalı; helper testlerini taşımak tek başına kapanış değildir. Native
genel claim/budget/retry/breaker, model store ve agent/history hâlâ açıktır.
Kullanıcı shell.nix/07 değişiklikleri commit dışındadır.

## 2026-10-25 — Drain-before-release application close ve API fairness

Native `application/close` public stdio consumer'a bağlandı. Host `Live`/
`Draining` entry ile admission/publication'ı geri alır; HTTP/read/command/job/IO
ve actor ledger boşalmadan closed reply veya application slot release yoktur.
Önkoşul 34'te anlatılır; henüz editor application/run consumer'ı taşınmış sayılmaz.

Continuous foreign delta üretiminin completed API join'ini starve ettiği testle
yeniden üretildi (önce kırmızı). Joined worker'ın sonlu FIFO-prefix+terminal
barrier batch'i ile düzeltildi; yeni foreign event'ler batch'i uzatamaz. Network
16 + retirement 17 sınırı explicit, body-before-terminal ve cancel/drain korunur.

**148 Rust testi + 2 compile-fail**, locked build/test, fmt, strict Clippy temiz.
**1160/1160 full source ERT**, 0 unexpected, **124.68 s**. Real pipe/socket,
sibling isolation, stale rejection, 80 close/recreate, revoked review/late reply,
process reap-before-close ve shutdown ordering testlidir. TLC application
6151/1681/depth25; transport 1810/693/depth13 hatasız. Concrete refinement
ispatı iddia edilmez. Canlı hesap/ücretli çağrı yok; shell.nix/07 kullanıcı
değişiklikleri commit dışındadır. Native run/budget/retry, metadata ve agent
portları, ayrıca dört app backend'i hâlâ açıktır.

## 2026-10-25 — Native auth/header assembly

Bearer/x-api-key seçimi, format defaults, case-insensitive provider overrides
ve header bindings Rust api/auth sınırına geçti. Elisp auth/header üretim
motorları silindi; credential çözümleme UI portunda kaldı. Client POST, catalog
GET ve immutable retry auth capture kullanır. Header injection/ambiguity/bounds
HTTP öncesi reddedilir. Credential/tenant değişince opaque continuation scope'u
da değişir; detay ve fingerprint sınırı 33_NATIVE_AUTH_HEADERS.md'dedir.

**141 Rust testi + 2 compile-fail**, locked build/test, fmt ve strict Clippy
temiz. **1160/1160 full source ERT**, 0 unexpected, **124.50 s**. Ek **82/82**
focused test; gerçek loopback auth/header GET/POST ve queued secret mutation
dahil. Warning-as-error bytecompile ve touched checkdoc temiz; geçici .elc
çıktıları kaldırıldı. Build tamamlanmadan başlatılan bir ERT koşusu old-binary
DTO mismatch ile reddedildi; rebuild sonrası tekrar geçer. Gerçek hesap/ücretli
çağrı yok. Native budget/claim/retry/breaker, model store, agent/history ve app
backend'leri roadmap'te açık. Kullanıcı shell.nix/07 commit dışında korunur.

## 2026-10-25 — Native request-policy cutover

Sampling/cap/reasoning policy ve default/format/provider merge `api/policy/`
altına taşındı. Elisp parameters.el ile request/registry karar motorları silindi;
UI yalnız exact metadata ve raw tuning snapshot'ını gönderir. Explicit null,
tek cap alanı, finite temperature, positive limit ve extras bypass reddi
native'dir. Model-specific capability doğrulaması hâlâ açıktır; ayrıntı 32'dedir.

**136 Rust testi + 2 compile-fail**, locked build/test, fmt ve strict Clippy
temiz. **1159/1159 full source ERT**, 0 unexpected, **124.46 s**; high-level chat
POST gerçek loopback native policy kabulü dahil. Warning-as-error bytecompile
ve touched checkdoc temiz. Son common POST/extras guard değişikliği ardından
21 focused Rust testi tekrar geçer. Geçici .elc çıktıları kaldırıldı. Canlı
hesap/ücretli çağrı yapılmadı. Native retry/breaker/budget, model store ve core
agent/history hâlâ açık; kullanıcı shell.nix/07 commit dışında korunur.

## 2026-10-25 — Native wire ve prompt-cache cutover

HTTP admission artık captured typed formatı kullanır; request/response blocks,
cache sınırları ve checked cache usage Rust'a taşındı. `api/cache.el` ve wire
codec engine'leri silindi; UI canonical DTO/metadata projection kalır. Opaque
continuation endpoint/model/provider/format revision'ına bağlıdır. Detay ve
eski testlerin native eşlemesi 31_NATIVE_WIRE_AND_CACHE.md'dedir.

**130 Rust testi + 2 compile-fail**, locked build/test, fmt ve strict Clippy
temiz. **1163/1163 full source ERT**, 0 unexpected, **124.50 s**. Bytecompile
warning-as-error ve touched checkdoc temiz; geçici .elc çıktıları kaldırıldı.
Ek 3/3 focused test son doc/test-call cleanup'ını doğrular. Real Emacs→Rust→
loopback wire/cache round-trip dahildir; canlı hesap/ücretli çağrı yoktur.
Request policy, retry/breaker, model metadata ve core agent/history henüz açık;
API + dört uygulama backend kapsamı değişmedi. Kullanıcı shell.nix/07
değişiklikleri commit dışında tutulur.

## 2026-10-24 — Provider catalog ve model HTTP/SSE cutover

Kullanıcının yeni API önceliğiyle ilk kesim `36e0e1a`: 162-provider/5-wire
baseline Rust asset ve validated provider/catalog snapshot'a taşındı. Eski
1416 satırlık Elisp literal catalog kaldırıldı; core ready öncesinde editor
projection beslenir, explicit kullanıcı kayıtları ezilmez. Synchronous startup
aynı Rust asset'ini okur; ayrı metadata kopyası yoktur. Detay/öğrenim 29'dadır.

İkinci kesim: gerçek chat/model-discovery GET/POST ve SSE IO Rust api/stream/
ve owned ipc/api service'e bağlandı. Elisp SSE parser/accumulator, HTTP
watchdog/flush ve redirect helper engine'leri silindi; plz HTTP çağrısı yoktur.
Plz yalnız henüz taşınmamış retry hata DTO'ları için kalır. Curl global API
prerequisite değildir. Bounded final body pages frame limitini yükseltmeden
1.2MiB katalog aktarır; owner/cancel/shutdown/EOF socket drain testlidir.
copy-tree'nin string alias'ı mutation testiyle yakalanıp explicit URL/body/
header string capture ile düzeltildi. Secret/timeout/limit sınırları 30'dadır.

**122 Rust testi + 2 compile-fail**, locked build/test, fmt ve strict Clippy
temiz. **1165/1165 full source ERT**, 0 unexpected, **123.39 s**. Eski Elisp
parser/pressure engine testleri Rust contract fixture'larına taşındı; sayıdaki
azalma engine testlerinin iki dilde yinelenmesinin kaldırılmasıdır. Yeni real
loopback/capture/consumer testleri dahildir. Warning-as-error bytecompile ve
checkdoc temiz. Bounded TLC transport 1810/693/depth12 hatasız; bu HTTP portu
için concrete refinement ispatı değildir. Gerçek hesap/ücretli API çağrısı yok.
Son callback guard değişiklikleri ardından ek **74/74** source ERT geçer;
geçici bytecompile çıktıları kaldırıldı. Sistem DNS syscall preemption ve
sağlayıcı tarafı faturalama iptali garantisi verilmez (30'daki sınırlar).

Kalan wire/request policy, model metadata normalization/store, retry/circuit
ve editor history/agent orchestration henüz Rust'ta değildir; API geçişinin
tamamı bitmiş sayılmaz. Registry bu tüketicilerin UI/config facade'ı olarak
kalır. API + dört installed-app backend kapsamı değişmez. Kullanıcı shell.nix
ve 07 fence değişiklikleri commit dışında korunur.

## 2026-10-24 — Native Git status ve complete-output portu

`0cbd4a5` ardından `git_status` fixed-argv Git/Rust portuna bağlandı; Elisp
porcelain parser, file-status struct ve section formatter kaldırıldı. Mevcut
Magit-tarzı rapor/Unicode/NUL/rename/conflict davranışı Rust'a taşındı. Diğer
Git komutları/mutation ve shared process runner henüz kaldırılmaz. Search ve
Git için owned editor read task `bridge/read.el` içinde tekleştirildi.

Complete capture iki stream'de byte overflow'u Failed yapar; malformed NUL/UTF-8
InvalidToolOutput'tur ve completion actor'a teslim edilmeden success düşürülür.
Stop-on-bytes exact digest/review'a bağlıdır. Optional index locks kapalı,
executable fsmonitor disabled, worktree root explicit; host-global ignore ve
linked worktree korunur. Detay/öğrenim/sınırlar 28_NATIVE_GIT_STATUS.md'dedir.

**105 Rust testi + 2 compile-fail**, locked build/test, fmt ve strict Clippy
temiz. İndeks byte/inode/mtime değişmeme testi + ordinary-status pozitif
kontrolü, fsmonitor marker ve external core.worktree scope fixture'ları dahil.
**1185/1185 full source ERT**, 0 unexpected, **121.68 s**; 17 odaklı integration
ve 2 yeni capture/parent-cancel testi. Warning-as-error bytecompile/checkdoc
temiz, geçici .elc kaldırıldı. Bounded TLC process-session 129/42/depth7,
approval 8194/1536/depth11, transport 1810/693/depth12 hatasız; yeni concrete
Git/complete-output hattı için refinement ispatı değildir. API + dört app
backend kapsamı açık; kullanıcı shell.nix/07 değişiklikleri commit dışında.

## 2026-10-24 — workspace_grep native consumer cutover

`6506899` record-budget prerequisite ardından rg/GNU grep adapter, scoped
workspace/grep capability, immutable result context ve owned Elisp façade
bağlandı. Eski Elisp grep argv/runner/truncation/formatter engine'i silindi.
GNU fallback, global cap+1 lookahead, no-match=1, byte/timeout failure ve
config capture korunur. Root/cwd yanında target descriptor identity de spawn
öncesi doğrulanır. Ayrıntılar 27_NATIVE_WORKSPACE_GREP.md'dedir.

Gerçek test rg positive-glob sırasının eski negative exclusion'ı geçersiz
kılabildiğini yakaladı: user include önce, literal exclusions sonra uygulanır.
Stderr byte overflow da record-capture failure'dır; late overflow sahte başarı
üretemez. timeout=nil native ve forward-waiter düzeyinde unlimited kalır;
owner/Stop/disconnect cleanup korunur. API ve dört application backend açık.

**93 Rust testi + 2 compile-fail**, locked build/test, fmt ve strict Clippy
temiz. Forced rg/GNU matrix, oversized frame/ping, slow unlimited search cancel
ve actual /proc reap testleri dahil. **1183/1183 full source ERT**, 0 unexpected,
**121.60 s**; odaklı 8 real-pipe/public regression + 3 capture/lifecycle testi.
Warning-as-error bytecompile/checkdoc temiz, geçici .elc kaldırıldı. Bounded TLC
approval 8194/1536/depth11, transport 1810/693/depth13, process-session
129/42/depth7 hatasız; concrete adapter için refinement iddiası yoktur.
Shared process.el Git/diff/webfetch ve diğer tüketiciler için kalır. Kullanıcı
shell.nix ve 07 fence değişiklikleri commit dışında korunur.

## 2026-10-24 — Ortak record-capture bütçesi

`workspace_grep` için prerequisite: typed prefix record budget, bounded watch
observation ve supervisor-owned intentional stop; byte exhaustion ayrı failure.
Accepted exit-code policy exact action digest/review'a bağlıdır; genel komut
default'u değişmez. Detay ve scope sınırları 26_RECORD_CAPTURE_BUDGET.md'de.
Elisp grep henüz kesilmediği için engine bu commit'te korunur.

**81 Rust testi + 2 compile-fail**, locked build/test, fmt ve strict Clippy
temiz. **1180/1180 full source ERT**, 0 unexpected, **116.39 s**; yeniden
build edilmiş binary ile odaklı exact-review testi de geçti. Warning-as-error
bytecompile/checkdoc temiz, geçici .elc kaldırıldı. Bounded TLC process-session
129/42/depth8 ve approval 8194/1536/depth11 hatasız; yeni concrete record
observer için formal refinement iddiası yoktur. Kullanıcı shell.nix/07
değişiklikleri kapsam dışında korunur.

## 2026-10-24 — Interactive session consumer cutover

Native idle prerequisite `a843d7b` ardından session OS spawn/stdin/EOF/signal,
PID/PGID ve idle timer engine'i Elisp'ten kaldırıldı. `bridge/command.el`
ortak immutable editor capture'dır; Bash ve session aynı environment/policy/
mode-revision freshness kontrolünü kullanır. Ayrıntılar 25'tedir.

Owner callback lease kill hook'tan önce revoke edilir; buffer-live-p tek
başına yeterli değildir. Geç ack/receipt, source loss, sibling isolation ve
unknown cleanup/legacy zero ayrımı sınandı. Start artık on-ready ile async;
eski sync engine veya fallback yoktur. Shared process.el diğer OS consumer'lar
taşınmadığı için korunur. API + dört uygulama backend kapsamı açık kalır.

**1180/1180 full source ERT**, 0 unexpected, **117.01 s**; odaklı 19/19;
warning-as-error bytecompile/checkdoc temiz, geçici .elc kaldırıldı. Rust
değişmedi: önceki **74 test + 2 compile-fail** kanıtı geçerlidir. Bounded TLC
process-session 129/42/depth7, approval 8194/1536/depth11 ve transport
1810/693/depth13 yeniden hatasız; yeni refinement iddiası yoktur. Kullanıcı
shell.nix ve 07 fence değişiklikleri commit dışında korunur.

## 2026-10-24 — Native idle policy prerequisite

Bash cutover `a7ecdfa` ardından `IdleTimeout` ayrı tip, exact digest/review,
`process_idle_timeout` capability ve bounded I/O observation eklendi. Süreç
pipe kodu `process/io.rs`, idle observation `process/activity.rs` içine ayrıldı.
Partial stdin write da activity sayılır; late/coalesced pulse eski timeout'u
canlandıramaz. Ayrıntı ve yeni kanıt sınırı 24_NATIVE_IDLE_POLICY.md'dedir.

**74 Rust testi + 2 compile-fail**; locked build/test, fmt, strict Clippy
temiz. **1170/1170 full source ERT**, 0 unexpected, **94.48 s**; warning-as-error
bytecompile/checkdoc başarılı, geçici .elc kaldırıldı. Yeni idle modeli için
formal refinement iddiası yoktur. Ayrı Elisp interactive session motoru henüz
bu porta bağlanmadığından korunur; sıradaki kesimde adapter'a dönüşecektir.

## 2026-10-24 — Bash OS engine cutover

`eb59416` owned job client/claim/merged pipe; `5f5994d` incremental UTF-8
polling ve shared permission snapshot ardından Bash gerçek Rust job portuna
bağlandı. Elisp Bash spawn/PID/PGID/signal motoru kaldırıldı; editor log,
cached UI routing/pruning ve presentation korunur. No fallback. Ayrıntı ve
callback/approval uyumluluk sınırı 23_NATIVE_BASH_CUTOVER.md'dedir.

Nix 202 env entry bulgusu: 512-entry bounded capture, mevcut 64KiB byte
sınırı korunarak test edildi. Shutdown RPC 5s -> 12s; dış kapanış 15s.
TERM-ignore child testi gerçek drain cevabı ve /proc temizliğini denetler.

**1168/1168 full ERT expected**, 0 unexpected, **93.02 s**; **66 Rust testi +
2 compile-fail**; fmt, locked build/test, strict Clippy, warning-as-error
bytecompile ve checkdoc başarılı. .elc çıktıları kaldırıldı. Bounded process
535/179/depth9, process-session 129/42/depth7, approval 8194/1536/depth11
yeniden hatasız; yeni concrete runtime için refinement ispatı değildir.

Kalan shared process/session, policy parser ve read/search/Git tüketicileri
taşınmadan silinmez. API -> Rust + dört application backend açık kapsamdır.
Kullanıcıya ait shell.nix ve 07 fence değişiklikleri commit dışında korunur.

## 2026-10-24 — Persistent execution ve owned job köprüsü

Kullanıcının devam/commit döngüsüyle üç küçük dilim:

1. `5c787da`: gerçek unlimited deadline ve bounded rolling-tail archive;
   timeout/retention action digest'e bağlı. Ayrıntılar 20'de.
2. `db5aeb6`: ayrı lifetime'lı process jobs, aynı actor/gate/supervisor,
   bounded nonblocking stdin/read ve scoped wire. Ayrıntılar 21'de.
3. Owned Emacs job client, receipt/claim lease, source close drain, gerçek
   merged stderr pipe ve environment değerlerini gizleyen exact approval.
   Ayrıntılar 22'de. Bash consumer henüz eski engine'den kesilmedi.

Güncel kaynak ERT **1156/1156**, 0 unexpected, **65.07 s**; Rust **65 test +
2 compile-fail**; fmt, locked build/test ve strict Clippy sıfır uyarı.
Warning-as-error bytecompile/checkdoc başarılı, geçici .elc kaldırıldı.
Yeni concrete job tablosu/lease için formal refinement iddiası yoktur.
Kullanıcıya ait shell.nix ve 07 fence değişikliği commit dışında korunur.
API -> Rust ve dört uygulama backend'i açık kapsam olarak devam eder.

## 2026-10-24 — Unix/GNU bileşimi, klasörleme ve canlı command/approval köprüsü

Kullanıcı kararı: her araç kendi işini yapar; Rust `ls`/`rg`/`git` motorlarını
yeniden yazmaz. İlke ve argv[0]/multicall öğrenimi 17'de; komut/onay wire ve
Emacs presenter ayrıntıları 18'de; native scanner yerine GNU ls sözleşmesi 19'dadır.

Küçük commit sırası:

1. `39d2666`: `.codex` bileşim kararı ve davranış değiştirmeyen klasörleme.
   `src` altında application/host, domain, ipc, process, security ve workspace
   sorumlulukları ayrıldı; yalnız composition/shared constants/error kökte kaldı.
2. `9c9698a`: standalone `tool/execute`, exact-action reverse approval,
   shared supervisor, nonblocking completion ve cancel/EOF/drain.
3. `5988320`: özel Rust directory scanner ve artık tüketilmeyen fd-walking kodu
   silindi; mevcut Elisp `list_files`/`ls`/`dir` ortak Rust gate üzerinden GNU ls
   çıktısı döndürüyor. Scanner testleri yeni sözleşmeye eşlendi; engine fallback yok.
4. Ardından owned Emacs approval presenter, public `kargu-bridge-execute`,
   unsolicited/replayed/stale UI reddi ve negotiated approval frame sınırı eklendi.

Güncel doğrulama: **1151/1151 full ERT expected, 0 unexpected**, **49.56 s**;
güncel binary + kaynaklar (.elc yok). **52 Rust testi + 2 compile-fail**;
locked build/test, fmt ve katı all-target Clippy sıfır uyarı. Değişen Elisp
üretim/test dosyaları warning-as-error bytecompile ve checkdoc temiz.
Geçici compile çıktıları kaldırıldı. Nix OpenPGP autoload ortam bildirimi
derleme/test hatası değildir; kontrollerin exit kodu 0'dır.

Bounded TLC yeniden hatasız: application 6151 generated/1681 distinct/depth25;
approval 8194/1536/depth11; process 535/179/depth9; transport 1810/693/depth13.
Bu mevcut soyut modellerin regresyon kapısıdır; gerçek Rust/Emacs/OS davranışının
refinement veya sınırsız-state ispatı değildir. Remote CI, gerçek provider,
harici uygulama/login ve ücretli CLI/MCP testi yapılmadı.

Güncel sınırlar: `find_files` geçici olarak native motorunu kullanır; sıradaki
arama portlarında harici araç bileşimi esastır. Genel Bash/job executor hâlâ
Elisp'tedir; interactive stdin/status/output/poll/continuation adapter'ları
tamamlanmadan silinmez. Yeni program/argv portu explicit timeout ve EOF stdin
ile noninteractive'dir; full agent/provider run cutover'ı değildir. Sabit GNU
ls salt-okunur tüm modlarda, genel komut Agent + explicit approval yolundadır.
Eski fd-rooted listing garantisi güncel ls çıktısına atfedilmez.

01 generic standartları değiştirilmedi. `todo.md` G03–G13, API -> Rust ve dört
uygulama backend'i kapsamı açık kalır. Kullanıcının `shell.nix` ve çalışma
sırasında görülen `.codex/07_GECIS_3.md` fence değişikliği korunup commit dışında
bırakıldı. Aşağıdaki önceki dilim kayıtları tarihsel kanıttır, güncel strateji
veya implementasyon durumunun yerine geçmez.

## 2026-10-24 — Dördüncü dilim: list_files native cutover

Onaylı Aşama 2'ye devam edildi; `todo.md` G11/G13 kalan kabul yükümlülükleri
korundu. Küçük commit sırası:

1. `3fa1a45`: typed `ListFilesPlan`, fd-rooted/no-follow directory capture,
   bounded native listing ve shared read mailbox; Rust/gerçek-stdio testleri.
2. `6d73867`: `list_files`/`ls`/`dir` mevcut Elisp tool gate'inden Rust'a
   bağlandı; senkron Elisp scanner, entry classification ve display engine'i silindi.

Detay ve eşdeğerlik/uyumluluk sınırı:
[16_NATIVE_DIRECTORY_LISTING.md](16_NATIVE_DIRECTORY_LISTING.md).
Tool şeması ve alias'ları korunur; Lisp entry point sonucu artık callback ile
verir. Callback'siz çağrıyı bekleten bir sync bridge veya Elisp fallback yoktur.
Glob/listing aynı task/owner/cancel adapter'ını ve dört-worker toplam kotasını
paylaşır. Legacy `kargu-fs-walk`/grep tüketicileri henüz taşınmadığı için korunur.

Öğrenim: root'u normal File::open ile açıp sonra dizin kontrolü yapmak FIFO'da
daha kontrole ulaşmadan bekleyebilir. Workspace `O_DIRECTORY | O_NOFOLLOW`
ile açılır; root/target FIFO, symlink ve directory replacement testleri vardır.
Symlink hedefi takip edilmez, `[LINK]` gösterilir; special entry `[OTHER]` olur.
İncomplete sonuç sahte empty/complete olarak sunulmaz. Scope ve limitler,
atomic filesystem snapshot veya OS sandbox garantisi diye adlandırılmaz.

Final güncel binary + kaynaklardan (.elc yok) ERT: **1146/1146 expected,
0 unexpected, 0 skipped**, **47.79 s**. Odaklı bridge/search **39/39**, bağımsız
bridge **20/20**. Rust **47 test + 2 compile-fail doctest**; locked fmt/build,
strict all-target Clippy, warning-as-error Elisp/test byte compilation ve
checkdoc temiz. Doğrulama için üretilen beş .elc kaldırıldı. TLA+ modelleri
değişmedi; yeni refinement/uzak CI/canlı provider veya CLI/MCP kanıtı iddia edilmez.

`todo.md` güncel Rust planına bağlandı, fakat açık G03–G13 grupları bu read
portu nedeniyle kapatılmadı. API -> Rust ve dört uygulama backend'i gereksinimi
aynen korunur; onlar uygulanmış sayılmaz. Generic 01 ve kullanıcının mevcut
`shell.nix` değişikliği değiştirilmedi. Sıradaki read portu `workspace_grep`;
ardından kalan read/Git/skill/webfetch ve execution/approval presenter bağlantısı.

Aşağıdaki önceki dilim kayıtları tarihsel kapsam ve test sonuçlarıdır.

## 2026-10-24 — API + dört uygulama kapsamının netleştirilmesi

Kullanıcı kararı: mevcut Elisp API desteği Rust'a taşınarak korunacak; yanına
Codex, Antigravity, Claude Code ve OpenCode backend'leri gelecek. Aynı GUI
provider alanından API veya kurulu uygulama seçilecek. Dört uygulama nihai
ürün kapsamıdır; opsiyonellik kullanıcının yerel kurulumuna aittir.

03 tek sözleşme kaynağı olarak güncellendi; kapsam (00), modül matrisi (02),
yol haritası (04), provider UI (06) ve typed metadata/config ayrımı (10) buna
uyarlandı. OpenCode ayrı adapter/kabul maddesi kazandı. Antigravity için MCP
sunumu chat backend teslimi sayılmıyor; uygun turn/stream/cancel protokolü
doğrulanamazsa ilgili iş açık teslim engeli kalıyor. Kapsam sessizce daraltılmaz.
Installed/unverified/login/version/protocol/probe/ready ayrımı, immutable
selection snapshot ve hatada sessiz API/backend replay yasağı yazıldı.

Bu adım yalnız plan değişikliğidir: runtime/adapter kodu uygulanmadı, yeni
ürün/protokol keşfi veya canlı uygulama testi yapılmadı. Protokol doğrulaması
uygulama öncesi kabul işi olarak açık bırakıldı; önceki test sonuçları yeniden
çalıştırılmış gibi sunulmaz. Generic 01 standardı ve kullanıcının `shell.nix`
değişikliği değiştirilmedi. Plan tutarlılığı, Markdown link/fence ve whitespace
kontrolleri bu adımın doğrulamasıdır.

## 2026-10-24 — Üçüncü dilim: ilk canlı tool portu ve commit zinciri

Kullanıcının güncel, generic 01 standardı değişmeden korundu. Rust tool safety
adı `MutatesState` ile hizalandı; library/bin explicit `forbid(unsafe_code)`
kullanıyor. Her tamamlanmış dilim doğrulandıktan sonra ayrı commit'lendi:

1. `ae24967`: Rust library/bin, tipli execution/process ve IPC temelleri.
2. `104451b`: Emacs lifecycle bridge, testler ve CI.
3. `3d7a8e6`: bounded owner-scoped native file discovery ve Rust kabul testleri.
4. `084fd96`: mevcut Elisp tool gate -> bridge -> native `find_files`, ardından
   eski fd/rg/Elisp glob engine'lerinin kaldırılması.

Detay, bilinçli normalize edilen arama politikası, cancellation sınırı ve
eski test -> yeni test eşlemesi: [15_NATIVE_FIND_FILES.md](15_NATIVE_FIND_FILES.md).
Agent/provider/history motoru henüz Rust'a geçmiş sayılmaz. Shared read-service
adapter identity, kullanıcı conversation'ı veya core agent run değildir.

Final doğrulama: **1137/1137 full ERT expected, 0 unexpected, 0 skipped**, 47.08 s;
**35 Rust test + 2 compile-fail doctest**; locked fmt/strict all-target Clippy;
değişen Elisp/test dosyalarında warning-as-error compile ve checkdoc temiz.
Bridge tek başına **17/17 ERT** ile gerçek native service startup/discovery de
doğrulandı. Oluşturulan altı .elc tekrar üretilebilir build artifact'ı kaldırıldı.
Uzak CI ve yeni TLA+ refinement çalıştırılmadı; model kanıtı iddiası eklenmedi.

Planlar ve çalışma notları, her adımı commit'leme talebi kapsamında `.codex`
altında sürüm kontrolüne alındı; yerel exclude ayarı değişmedi. Kullanıcının
önceden var olan `shell.nix` değişikliği commit'lere alınmadı ve değiştirilmedi.

Sıradaki güvenli dilimler: aynı lifecycle/permission modeliyle `list_files` ve
`workspace_grep` portları; ardından execution/approval presenter ve genel
`tool/execute` entegrasyonu. Her özellikte eşdeğerlik testi -> caller yönlendirme
-> yalnız artık tüketilmeyen Elisp domain kodunu silme -> commit sırası korunur.
Aşağıdaki önceki dilim kayıtları tarihseldir; güncel kapsamı bu başlık belirler.

## 2026-10-24 — İkinci dilim: execution library temelleri

Güncel 01_RUST_CORE_PATTERNS.md korunarak merkezi constants, doğrulanan domain
tipleri, CoreError, ApplicationActor/RunScope, canonical tool registry,
tek kullanımlık approval gate ve Linux process supervisor eklendi.
Teknik kararlar, öğrenilenler, test/model eşlemesi ve kalan sınırlar
[14_EXECUTION_FOUNDATIONS.md](14_EXECUTION_FOUNDATIONS.md) içinde kayıtlıdır.

Önemli öğrenim: PGID'ye sinyal göndermek torunların reap edildiğini tek başına
sağlamıyor. Linux subreaper + scoped wait eklendi; WNOWAIT ile son grup
sinyaline kadar leader PID'si pinleniyor. Gerçek OS senaryoları test ediliyor.

Rust testleri: **25/25 integration + 2/2 compile-fail başarılı**. Dört ilgili
bounded TLC modeli hatasız tamamlandı. Final fmt ve locked Clippy
`--all-targets -- -D warnings` başarılı. Mevcut full ERT regresyonu:
**1129/1129 expected, 0 unexpected**, exit 0, 46.75 saniye; gerçek Rust binary
ile bridge senaryoları da çalıştı. Shell/approval henüz stdio üzerinden ilan edilmez; mevcut Emacs
motoru ve public tool davranışı değiştirilmedi. Kullanıcının 01 belgesi ve
önceden var olan shell.nix değişikliği korunmuştur.

## 2026-10-24 — İlk dilim: baseline ve IPC

### Uygulananlar

- `kargu-core/`: Rust 1.95.0, edition 2024, library/bin ayrımı, Cargo.lock.
  Tokio bounded stdio transport, strict JSON-RPC envelope ve recursive duplicate
  key rejection. stdout yalnız protokol; hata mesajları payload içermez.
- Per-connection handshake/epoch; application ve session kimlikleri private,
  doğrulanan farklı tiplerdir. Session snapshot/close foreign owner'ı reddeder.
  Core yalnız application_lifecycle/session_lifecycle/ping capability ilan eder.
  Session'lar bu dilimde RAM'dedir; persistence/restore henüz yoktur.
- Frame limiti 1 MiB; init'te 1024 byte ile 1 MiB arasında negotiate edilir.
  Kontrol kuyruğu 128 mesaj/1 MiB; blocked writer deadline 5 saniyedir.
  Eksik EOF frame ve oversize stream fail-closed kapanır.
- Reverse request ledger foundation: 128 pending, owner scope, deadline,
  take-once reply/cancel/timeout/disconnect. Henüz editor tool çağrısı üretilmez;
  sensör ve approval capability'si ilan edilmez.
- `kargu/bridge.el`: opt-in start/status/stop; process-local state, ayrı stderr,
  bounded partial/dispatch, callback deadline/owner cleanup ve stale sentinel
  izolasyonu. Paket yüklenmesi core başlatmaz; mevcut Elisp loop değiştirilmedi.
- Bağımsız bridge ERT ve gerçek Rust binary/pipe testleri; Rust checks + bridge
  için CI workflow. README build/test/start komutlarını açıklar.
- Read-only `tests/migration-inventory.el` exporter ile
  `13_MIGRATION_BASELINE.json` kaydedildi: 166 source, 108 loaded public command,
  1130 loaded public function/accessor, 51 canonical + 53 alias = 104 tool kaydı.
  Envanter yüklü opsiyonel adapter'ları ve üç yeni bridge autoload komutunu da
  içerir; her export bütün koşullarda aynı feature set'i kanıtlamaz.
- Synthetic legacy ve schema-v2 JSON session fixture'ları eklendi; mevcut Elisp
  validator ile legacy inherit/off ayrımı, tool-call pair, Unicode/multimodal
  içerik, counter ve input immutability kontrol edilir. Gerçek session açılmadı.

### Öğrenilenler / kararlar

1. Native Emacs JSON parser hash-table modunda duplicate key'leri sessizce ezer.
   Bridge string-key alist parse + recursive unique-key normalization kullanır;
   arrays/null/false/empty object ayrı tutulur. Rust da aynı sınırı uygular.
2. LinesCodec EOF'ta newline'sız son metni normal satır kabul edebilir. Kargu
   bunun için strict EOF decoder kullanır; yarım frame başarılı sayılmaz.
3. Slow reader testi writer JoinHandle'ın hata sonrası ikinci poll edilmesini
   yakaladı. Terminal join yolları ayrıldı. Parent future iptal edildiğinde
   writer'ın detach kalmaması için AbortOnDropHandle ve gerçek drain testi eklendi.
4. Timer'ın event loop'ta gecikmesi deadline'ı uzatmaz: response tesliminde de
   deadline kontrol edilir. Geç yanıt bekleyen işi canlandıramaz.
5. Bu Nix ortamında cargo/rustc/rustfmt 1.95 çalışıyor, mevcut rustup toolchain
   binary'leri doğrudan çalışmıyor. Clippy `nix-shell -p clippy --run 'cargo
   clippy --manifest-path kargu-core/Cargo.toml --locked --all-targets -- -D
   warnings'` ile doğrulanır. Kullanıcının shell.nix değişikliği korunmuştur.
6. stderr'in sır içermediği genel olarak kanıtlanamadığından bridge raw stderr
   saklamaz; bounded log'a sanitized diagnostic bildirimi yazar. Debug için ham
   payload logging açılmadı.
7. ERT/package initialization ortamda OpenPGP autoload uyarısı veriyor; test
   başlangıcını engellemiyor. Plz kullanan full suite/byte compilation için
   package-initialize gerekir; bağımsız bridge bundan bağımsızdır.

### Doğrulama

- Son full regression: **1129/1129 expected, 0 unexpected**, exit 0, 48.70 s.
  Rust binary env ile verildi; üç gerçek-core ERT testi skip edilmedi.
  Eklenen kapsam: 12 bridge ERT + 1 shared session fixture testi.
- Rust: **9/9 test başarılı**; protocol/ownership/pending, gerçek pipe lifecycle, UTF-8/CRLF, malformed
  input, oversize/partial EOF, slow reader ve parent cancellation testleri.
- `cargo fmt --check`, locked Clippy `--all-targets -- -D warnings` ve locked
  Rust tests başarılı. Yeni/değişen Elisp kaynaklarının warning-free byte
  compilation ve dört yeni Elisp dosyasının checkdoc kontrolü başarılı.
  Derleme sırasında üretilen altı .elc dosyası doğrulama sonrası kaldırıldı.
- `.github/workflows/rust-bridge.yml` Rust + bağımsız bridge kontrollerini
  CI için tanımlar; uzak CI henüz çalıştırılmadı. Mevcut Nix shell'in önceden
  var olan trailing whitespace'i kapsam dışı bırakıldı; yeni kaynaklar temiz.
- TLA+ modelleri değiştirilmedi; mevcut Elisp loop/claim geçişleri değiştirilmediği
  için eski bounded kanıtlar Rust implementation'ın kanıtı olarak kullanılmadı.

### Sonraki dilim

Aşama 2: typed execution context + ortak policy gate ve scoped approval; ardından
process/job supervisor, bounded output/stdin/cancel ve read/search/Git/edit
adapter'ları. Admission ve generation/run scope kurulmadan yeni Rust araçları
eski Elisp loop'a bağlanmayacak. Henüz agent/backend seçimi için Rust default
seçeneği yoktur: bu dilim yalnız opt-in bridge lifecycle altyapısıdır.

`.codex/` halen `.git/info/exclude` ile gizlidir. Bu günlük ve envanter diskte
saklanır; Git index/exclude değiştirilmemiştir.
