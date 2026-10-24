# Git status: read-only Unix adapter ve complete-output sözleşmesi

2026-10-24. `workspace_grep` cutover `0cbd4a5` ardından ilk Git consumer portu.

`workspace/git/mod.rs` fixed-argv Git status hazırlığı; `status.rs` yalnız
mevcut Magit-tarzı raporun bounded porcelain-v1 sunumudur. Git index, branch,
rename, conflict veya repository motoru yeniden yazılmaz. Public git_status
şeması/callback ve Head/Tracking/Root/staged/unstaged/untracked/conflicts
bölümleri korunur. NUL kayıtlar, rename source, leading/trailing whitespace ve
Unicode/newline adları kaybolmaz; control/quote/backslash adları tek satırlık
escaped gösterilir. Geçersiz UTF-8 veya eksik/bozuk kayıt scoped invalid_output
verir; lossily değiştirilmiş bir dosya adı başarılı rapor diye sunulmaz.

## Read-only demek yalnız "git status" demek değildir

- Git status optional index refresh yazabilir. Explicit GIT_OPTIONAL_LOCKS=0
  ve core.untrackedCache=false kullanılır; gerçek fixture index içeriği,
  inode/mtime kimliği değişmediğini doğrular. Pozitif kontrol, aynı fixture'ın
  policy olmadan status ile index refresh yaptığını gösterir.
  Fixture mtime'ı FileTimes ile açıkça farklı saniyeye ayarlar; 2ms write/sleep
  bazı Git/filesystem stat karşılaştırmalarında pozitif kontrolü tetiklemedi.
- Repo fsmonitor config'i executable çalıştırabilir. core.fsmonitor=false
  CLI override'ı ve --no-pager sabittir; synthetic executable marker'ı
  çalıştırılmadığı gerçek Git ile sınanır. Bu bir OS sandbox değildir.
- Root'ta .git directory/gitfile gereklidir; nested root üst repo'yu sessizce
  keşfetmez. Canonical --git-dir ve explicit --work-tree=root repo config'indeki
  farklı core.worktree değerinin çalışma alanı dışını taramasını önler. Linked
  worktree gitfile'ını Git kendi çözer; Rust .git dosyası parser'ı eklenmez.
- Root/cwd/executable ve .git target descriptor identity spawn öncesi yeniden
  doğrulanır. Gitfile'ın external object store'u linked-worktree desteğidir;
  recursive OS containment veya immutable repo snapshot garantisi değildir.
- env_clear sonrası explicit PATH/LC_ALL ve yukarıdaki policy kullanılır.
  HOME/XDG_CONFIG_HOME ve host Git config kaynakları değişmeden capture edilir;
  global excludesFile/ignore davranışı korunur. GIT_DIR/GIT_WORK_TREE,
  credentials ve diğer keyfi host environment alınmaz. Config değerleri loglanmaz.

## Complete output, exact action ve ledger

Yeni `CapturePolicy::Complete`, record saymadan iki stream'de byte overflow
gözler. Sınıra sığmayan producer TERM/grace/KILL/reap ile durdurulur ve Failed
olur. Bash prefix/tail ile record-budget aramanın sözleşmeleri değişmez.
Stop-on-bytes policy digest/review'a bağlıdır; genel JSON execution DTO'suna
keyfi read-only/complete yetkisi eklenmez. Reverse UI farklı byte-stop
politikasını reddeder. OutputLimit domain tipi korunur; ReadTimeout ortak
workspace command sınırına ayrıldı. Missing timeout 30s, explicit null unlimited'dır.

Git status ancak cleanup complete + process success + tam, valid UTF-8/NUL
protokolü sonrası biçimlenir. Structured decode failure için ayrı
InvalidToolOutput vardır; actor'a completion teslim edilmeden result Failed'a
indirilir. Bu hata successful ledger entry bırakmaz ve sonraki run'ı kilitlemez.
JSON frame'e sığmayan metin scoped error olur; eksik başarı veya transport
reset değildir. Elisp timeout/output-byte config'i her istek için capture edilir.

## Kaldırma ve kalan kapsam

Elisp status spawn/porcelain parser/file-status struct/section formatter
kaldırıldı. `tools/git/native.el` input capture; `bridge/read.el` search ve Git
için ortak parent/owner/take-once editor adapter'ıdır. Search'e ait kopya async
read dispatcher kaldırıldı. Genel Git --run/result/change/diff/log/branch/
stash/blame ve shared process.el diğer consumer'lar taşınana kadar durur.
Git mutation onayları bu portla değiştirilmez. API/provider + dört application
backend kapsamı hâlâ açıktır.

## Kanıt ve öğrenim

Rust matrix: gerçek status/index, fsmonitor, forced worktree scope, linked
worktree/detached HEAD, host-global ignore, complete-byte failure, missing Git,
foreign scope/argv injection, malformed NUL/UTF-8 ve ping. Unit fixture'ları
eski Elisp raw path/rename/conflict testini ve branch/invalid-record vakalarını
eşler; complete capture canlı stdout/stderr producer + actor ledger ile sınanır.
ERT gerçek merge-conflict/Unicode/newline/public callback testleri taşındı;
legacy removal, settings capture ve parent-cancel/late-result kontrolleri var.
Tam suite sayıları 12'de; bounded TLC yalnız eski soyut modellerin regresyonudur.

İncelemede session/snapshot wire'ının hâlâ placeholder idle/active_run=null
ürettiği görüldü (Aşama 4 açık). Bunu süreç terminal kanıtı olarak kullanma:
testler gerçek completion, ping responsiveness ve /proc reap'e dayanır.
