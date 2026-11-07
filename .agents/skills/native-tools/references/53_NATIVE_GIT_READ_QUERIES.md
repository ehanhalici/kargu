# Todo 2 ilk tüketici dilimi: native Git log/ref sorguları — 2026-10-26

Todo 2 `d27e8b9` ile alt işlere ayrıldı. Bu dilim `git_log`, `git_branches`,
`git_stashes` gerçek tüketicilerini taşır; üst grup ve diff/blame/mutation/read_file/
skill/toolchain/webfetch işleri açık kalır. Kullanıcı 07/shell.nix değişiklikleri
korunur. Canlı Emacs reload, gerçek repo mutation, kurulum, uzak model/hesap turu,
credential taşıma veya merge/push yapılmaz; test mutation'ları geçici repo fixture'ıdır.

## Native sınır ve modülerlik

`workspace/git/repository.rs` mevcut status'ın repository/executable/environment/
RunSettings hazırlığını paylaşır; `query.rs` yalnız kapalı log/branches/stashes
DTO'su ve presentation adapter'ıdır. Git parser/history/repo/branch motoru yeniden
yazılmaz. `CommitLimit` 1..10000, `RepositoryPath` ve mevcut typed `OutputLimit` /
timeout kullanılır. DTO'larda arbitrary argv/program veya safety etiketi yoktur.
Unknown alanlar unit-variant serde boşluğunu önlemek için `{}` struct variant'larda
da reddedilir; adversarial `branches + arguments=--delete` fixture'ı bunu sınar.

`git/read` + `git_read` capability mevcut `Commands` single-writer reservation,
off-mailbox preparation, native canonical registry, ExecutionGate ve ProcessSupervisor
zincirindedir. SafeReadOnly factory crate-private'dır; aynı adla generic process
göndermek bu sınıfı vermez. Core run gate'i, PGID TERM/grace/KILL/reap, explicit
environment, cancellation ve actual drain admission'ı paylaşılır. Yeni process
runner, shell veya ikinci approval ledger yoktur. Bu standalone read-service
scope'udur; gerçek native agent run cutover'ı değildir.

Status ile ortak root/worktree/.git capture korunur. Log pathspec `--` ile ayrılır,
`--literal-pathspecs` wildcard/magic yorumunu kapatır. Deleted/missing path için
en yakın mevcut ancestor canonicalize edilir ve root dışı symlink reddedilir;
history'de silinmiş dosya okunabilir. Native `CommandSpec` artık en çok sekiz
read target descriptor'ı tutabilir: .git ve path/ancestor kimliği birlikte digest'e
count/length framing ile girer ve spawn öncesi yeniden doğrulanır. Bu canlı repo
okumasıdır; atomic file-content/repo snapshot veya filesystem/OS sandbox değildir.
Linked worktree object store'u Git'in sorumluluğudur; outside-object containment
iddiası yoktur. Executable invocation/argv[0] multicall semantiği korunur.

## Helper ve çıktı politikası

`--no-pager`, `core.fsmonitor=false`, `core.untrackedCache=false`, optional locks=0,
explicit worktree/env ve host config/ignore input'ları mevcut status ile paylaşılır.
Yeni query log/stash için `--no-show-signature --no-patch`; branch için no-color
kullanır. Status ve query'lerde `--no-lazy-fetch` promisor remote'un örtük fetch'ini
kapatır. Bilinmeyen bu global flag'de eski Git başarısız olur; flagsiz retry veya
sessiz env-only fallback yapılmaz. Test ortamı Git 2.54.0'dır; evrensel eski sürüm
uyumluluğu vaat edilmez. Resmî dayanak:
[Git global flags/environment](https://git-scm.com/docs/git),
[Git diff helper flags](https://git-scm.com/docs/git-diff).

`CapturePolicy::Complete` iki stream byte sınırını ve gerçek drain'i korur.
`GitReadReport` kendi capture capacity'sini kullanır, genel 64 KiB prefix'e düşmez;
70 KiB commit-subject fixture'ı 128 KiB bütçede tam döner. Complete UTF-8 olmayan
çıktı success değildir. Text trim/empty marker yalnız presentation'dır; Git output
yeniden structured history'ye çevrilmez. Oversize IPC reply scoped error olur.
Nil timeout mevcut explicit unlimited semantiğini korur; Stop/owner/EOF kapanışı
gene PGID ve reap ile sınırlıdır. Genel timeout veya çıktı retention politikası
değiştirilmez.

## Neden diff/blame bu commit'te değil?

Gerçek positive-control fixture, `.gitattributes` + `filter.fixture.clean` script'i
ile `git diff --no-ext-diff --no-textconv` çağrısının marker yazdığını kanıtlar.
Bu bayraklar clean/process filtrelerini kapatmaz. Bu yüzden diff/blame enum'da ve
SafeReadOnly registry'de yayınlanmadı; native query bu operation'ları reddeder.
Elisp diff/blame consumer'ı henüz taşınmadı/silinmedi. Filter/config capture,
immutable action ve yürütme sınıfı ayrı açık alt iştir; güvenli classification
kurulmadan sırf native port olsun diye arbitrary code'a read-only yetki verilmez.

GPG için fake-signed gerçek commit ve `gpg.program` marker'ı kullanıldı: normal
`--show-signature` positive control helper'ı çalıştırırken native log çalıştırmaz.
Gerekli platform/versiyon flag'leri test edilen CLI davranışına dayalıdır;
uydurulmuş program veya Git algoritması yoktur.

## Editor consumer ve bulunan lifecycle açıkları

`tools/git/native.el` raw DTO/timeout/output capture yapar; `tools/git.el` log ve
branch/stash list argv/report motorları silindi. Diff/blame ve changing `--run` /
`--result` / stash immutable-object yolları son tüketicileri nedeniyle kaldı.
Public callback/tool adları ve ask/plan görünürlüğü korunur; missing capability /
binary hiçbir legacy read runner'ını çalıştırmaz.

Ortak `bridge/read.el` startup öncesi DTO'yu detached JSON'a çevirir; initiating
application/session, origin buffer/mode, parent ve take-once RPC cleanup saklar.
Closed/expired parent core başlatamaz; startup veya success callback'i gecikmişse
absolute deadline timer dispatch'ten önce kontrol edilir. Origin kill/mode değişimi
Root'u derhal iptal eder; stale session callback'i yeni konuşmaya yayın yapamaz.
Foreign application aktifken callback kendi application bağlamında çalışır.
Bu düzeltmeler find/list/grep/status consumer'larında da regresyonla sınandı.

## Doğrulama

**1274/1274 full source ERT**, 0 unexpected, **148.078585 s**, **20:35:56
Europe/Istanbul** geçti (`/tmp/kargu-git-queries-verified-source-ert.log`).
**298 native + 24 compile-fail = 322** locked test / **32 suite** temiz
(`/tmp/kargu-git-queries-native-verified.log`); yedi yeni gerçek Git/pipe testi ve
altı yeni ERT var. Eski status'ın yedi gerçek-pipe regresyonu da geçti.
Locked normal build/fmt ve strict Clippy sıfır uyarı
(`/tmp/kargu-git-queries-build-verified.log`, `...-clippy-verified.log`). Değişen
beş Elisp dosyası Werror bytecompile/checkdoc temiz; elc yalnız task-specific /tmp
dizinlerinde (`...-bytecompile-verified.log`, `...-checkdoc.log`). Connection TLC
**602836 / 101708**, queue 0, depth 22 (**20:33:28**); transport **1810 / 693**,
queue 0, depth 13 (**20:33:29**) temiz. Bounded TLC modelleri yalnız mevcut
lifecycle regresyonlarıdır; yeni Git/config/OS adapter'ının formal
refinement veya bütün `.codex/01` kurallarının ispatı sayılmaz. Genel credential
process lifecycle, egress/log privacy ve kalan todo 2 motorları açık kalır.
