# Aşama 2 — Tipli yürütme, onay ve Linux süreç sahipliği

Güncel bağlantı: 18_COMMAND_EXECUTION_BRIDGE.md ile standalone program/argv
wire portu ve Emacs reverse approval presenter'ı eklendi; 19'daki GNU ls aynı
process/gate yolunu kullanır. Aşağıdaki library-only/henüz-wire-yok ifadeleri
bu ilk dilimin tarihsel durumudur. Genel Bash/job cutover'ı hâlâ açıktır.

Güncel ek: sonraki dilimde native read-service capability'si ve ilk `find_files`
portu eklendi (15_NATIVE_FIND_FILES.md). Aşağıdaki lifecycle-only kapsam ifadesi
bu library diliminin tarihsel durumudur; arbitrary execution hâlâ wire'da yoktur.

2026-10-24. Kullanıcının güncel `01_RUST_CORE_PATTERNS.md` dosyası tamamen
okunarak uygulandı; dosyanın kendisi değiştirilmedi. Bu dilim Rust library
servislerini ekler. Stdio capability'leri hâlâ lifecycle-only'dir; Emacs'ten
shell çalıştırma/onay capability'si henüz ilan edilmez.

## Tip ve hata disiplini

- Paylaşılan limit, süre, protokol sürümü, capability, yöntem ve hata kodları
  `src/constants.rs` altında tek kaynaktan gelir. IPC frame limiti ByteLimit,
  pending scope RequestScope oldu; wire şekli değişmedi.
- `src/domain.rs`: private Application/Session/Run/Claim/ToolCall/Approval/Job
  kimlikleri; ConfigRevision, PolicyRevision, Generation, TokenCount ve ayrı
  input/output/cached/reasoning token birimleri; StepCount, RetryAttempt,
  ToolCallLimit, MicroUsd, LineNumber, ByteOffset, ColumnIndex ve ToolName.
- Invariant'lar TryFrom + serde(try_from) ile korunur. LineNumber sıfırı ve
  ByteLimit/ToolCallLimit sıfır limiti reddeder. Sayaçlar checked_add/next ile
  taşmayı typed hata yapar; fiyat/usage hesabı henüz bağlanmadı.
- BoundedFloat finite ve range kontrolünü parse sınırında yapar. ReasoningEffort
  kapalı enum'dır; provider default ile explicit off ayrıdır. Model bazlı wire
  çevirisi/capability doğrulaması 10 belgesindeki sonraki network dilimine aittir.
- CoreError durumları string parse edilmez. Tool budget hatası ToolCallLimit
  ve StepCount taşır; resource capacity ile token bütçesi yerine kullanılmaz.
- Compile-fail testleri farklı birimlerin karışmasını ve yürütme izninin
  clone/replay edilmesini derleme aşamasında reddeder. Bu TLA+ ispatı değildir.

## Sahiplik ve karar zinciri

Host artık session kimliklerini ikinci bir tabloda tutmaz: ApplicationActor'ın
session kaydı kanonik kaynaktır. Actor tek aktif run, monoton generation,
ayrı claim ve immutable settings/scope tutar. Config/policy revision, mode,
root ve run deadline yakalanır; henüz bir model connection hazırlığı yoktur.

Actor yöntemleri I/O task sonucu beklemez. Kaynak lease'i approval -> execution
grant -> process task -> terminal completion boyunca taşınır. Completion
teslimi actor tarafından bir kez yapılır. Aktif/undelivered kaynaklar drain
olmadan finish veya yeni admission mümkün değildir. Cleanup kanıtlanamazsa
run quarantine olur; yeni run sessizce kabul edilmez.

ToolRegistry canonical/alias çözümlemesini yapar. Bu dilimde kayıtlı executor
ailesi process'tir; etkisi daima ExecutesArbitraryCode'dur. Ask/Plan/Debug
modunda genel shell yetkisi verilmez. Registry adı veya shell regex'i komutu
read-only ilan etmez. Her process açık onay gerektirir.

ExecutionGate, typed CommandSpec'i owner/mode/budget/path kontrollerinden sonra
approval ledger'a koyar. Approval identity, run scope, config/policy revision,
canonical tool, argv, environment, cwd/executable identity, deadline ve digest
ile bağlıdır. Argüman ve environment bölümleri ayrı uzunluk/count alanlarıyla
hash'lenir; salt UUID veya eşit display metni izin sayılmaz.

Approved komut private alanlı, non-Clone AuthorizedCommand'a dönüşür. Yalnız
security modülü bunu oluşturabilir. Başlatma öncesi owner, deadline, mode,
workspace ve executable revision tekrar denetlenir. Değişen ya da replay
edilen onay komutu başlatamaz. Missing UI için karar Rejected'dır; bu dilimde
Emacs presenter'ı bağlanmadı, testler kararı explicit fixture olarak verir.

## Process supervisor

- Linux ilk hedef. Explicit executable + argv + cwd + timeout alınır.
  Environment env_clear + onayda yakalanan immutable map ile kurulur; parent'ın
  credential ortamı sessizce miras alınmaz. Command/approval/environment
  Debug/Serialize ile plaintext dökmez.
- Workspace/executable identity açık handle ile pinlenir; executable metadata
  revision değişimi de reddedilir. Bunlar shell'in proje dışına erişimini
  önleyen OS sandbox değildir. File edit/read confinement ayrı servistir.
- Startup'ta host slot ve run slot ayrılır (16 host, 4/run), call ledger'da
  started kaydı alınır, process_group(0) ile spawn yapılır. Runtime yokluğu
  veya spawn/capacity hatası panic ya da asılı tool call üretmez.
- stdout/stderr ayrı ve eşzamanlı drain edilir: 1 MiB/stream/job, 8 MiB/run.
  Limitte process öldürülmez veya pipe okumak bırakılmaz; truncation ve byte
  cursor açıkça döner. Sayfalar/input chunk'ları 32 KiB, stdin kuyruğu 8'dir.
- stdin write, EOF, status, list, cancel, wait/collect ve terminal archive
  forget owner-scoped'dur. Wait future iptal edilirse job tablodan düşmez.
  Başka run'ın job'ına erişim ve sibling cancellation reddedilir.
- TERM -> grace -> KILL ve pipe/task drain direct child wait/reap'ten önce
  yürür. Lider WNOWAIT ile gözlenir; son group sinyali atılana kadar reap
  edilmez. Böylece sinyal yetkisi eski/reuse edilmiş lider PID'sine dayanmaz.
- ProcessSupervisor::new açıkça Linux child-subreaper kurar. Bu process-wide
  seçim core process ömrü boyunca kalır; caller runtime policy'sidir. Adopted
  torunlar yalnız sahip olunan PGID ile wait edilir; waitpid(-1) kullanılmaz.
  Normal PGID kill tek başına torun zombi süreçlerin reap edildiğini kanıtlamaz.
- setsid ile gruptan kaçış ve host'un SIGKILL/power-loss ile ölümü için cgroup/
  dış supervisor ayrı capability'dir. Drop normal çalışan runtime'da cleanup'ı
  tetikler; ani process ölümünde Rust destructor garantisi iddia edilmez.

## Native tool ledger ve onarım sınırı

Actor kabul edilen call kimliklerini giriş sırasıyla tutar. Cancel/timeout
sonrası eksik sonuçlar tek sefer, is_error=true ve güvenli kullanıcı iptal/
timeout bildirimiyle kapatılır. Gerçek sonuç korunur. Başlatıldığı bilinen
ama sonucu teslim edilmemiş iş outcome_unknown olur; otomatik replay yoktur.

Bu native ledger, provider'a serialize edilen tam HistoryRepair/compaction
servisi değildir. SSE fragment, çoklu tool-call batch, multimodal metadata,
provider signature ve persistence recovery Aşama 4 yükümlülüğü olarak kalır.

## Doğrulama

- 16 execution integration testi: tip/invariant/overflow, alias/mode/foreign
  owner/replay, cancelled approval sweep, tool budget, stale root/executable,
  runtime yokluğu, stdin/EOF, nonzero exit, 4/run sınırı, bounded stdout/stderr,
  8 MiB ortak run bütçesi, deadline, cancelled wait ve supervisor drop.
- Gerçek OS testleri TERM'i yok sayan leader + child ve erken çıkan leader
  senaryolarında PID'nin /proc'tan kalktığını, torunların da reap edildiğini
  doğrular. Sadece process-live-p/timeout mock'u kullanılmadı.
- Rust toplamı: 25 integration testi + 2 compile-fail doctest.
- Bounded TLC yeniden çalıştırıldı, hatasız: application 6151 generated /
  1681 distinct, approval 8194/1536, process 535/179, process-session 129/42.
  Bunlar mevcut bounded modellerin sonuçlarıdır; gerçek Linux davranışının
  veya Rust refinement'ının tam ispatı olarak sunulmaz.
- Son fmt, locked Clippy `--all-targets -- -D warnings` ve full ERT başarılı:
  1129/1129 expected, 0 unexpected, 46.75 saniye. Yeni binary ile gerçek bridge
  testleri çalıştı; Emacs kaynakları bu dilimde değiştirilmedi.

## Sıradaki bağlama işi

Emacs approval presenter ve Rust reverse-RPC orchestration; connection/owner
kapanışında gate expiry + supervisor drain + actor completion sırası. Aktör
mailbox'ında HTTP/onay/job sonucu beklenmeyecek. Native tool/execute capability
ancak bu yol gerçek pipe üzerinden doğrulanınca açılacak. Ardından read/search/
Git/egress ve edit transaction adapter'ları taşınacak. Eski Elisp yürütücü
henüz bu library servislerine yönlendirilmedi.
