# Todo 2: native status/diff/blame, isolated config ve owned cleanup — 2026-10-26

`f2ef8e6` proof'undan sonra gerçek consumer cutover tamamlandı. Todo 2'nin
salt-okunur Git ve read_file alt işleri kapalı; mutation/skill/toolchain/webfetch
ve son bridge audit'i açık. Gerçek kullanıcı repo mutation/credential/network/
kurulum, canlı Emacs reload veya push yoktur. Test mutation'ları tmp fixture'dır;
kullanıcı 07/shell.nix değişiklikleri korunur.

## Güvenlik sınırı ve gerçek Git

`git_status` da clean filter çalıştırabiliyordu: same-size refresh positive-control
bu açığı her SHA-1/SHA-256 × files/reftable × main/linked-worktree kombinasyonunda
gösterdi. Native status/diff/blame artık `git_worktree_read` cap'iyle aynı kapalı
pipeline'a gider. Eski yalnız git_status/git_read cap'li core'a yeni editor bu
işlemler için RPC göndermez. Literal/deleted path, staged/ref diff ve single-ended
blame line window native domain'de parse edilir; arbitrary argv/program yoktur.

Git algoritmaları yeniden yazılmadı. Önce Git'in bounded complete layout cevabı,
sonra fixed-regexp safe-config cevabı alınır. Final query, private common/worktree
metadata view'inde kendi config'ini okur; özgün executable config'i yeniden açmaz.
SafeKey closed domain (core EOL/filemode/ignore/attributes vb., diff algoritma/
rename, status untracked); 64 kayıt, value 4096 bytes, preflight output 64 KiB.
Config değerleri quoted/escaped veri olarak yazılır; filter/include/remote/hook/
signature/textconv tanımı kopyalanamaz. Ara config/HEAD bytes/text zeroizing'dir;
ham capture Debug/Serialize/log yüzeyi eklenmedi.

HEAD regular/bounded fd snapshot'ı; original objects/refs/reftable/packed-refs/
shallow ve info veri dosyaları Git'e bağlanır. Physical commondir korunur. Original
index explicit seçilir; optional locks/auto-refresh kapalıdır. Source admin root
FD evidence ve private config revision gate/spawn öncesi yeniden kontrol edilir;
gitfile in-place değişimi ve snapshot duplicate eskisini yenileyemez. Immutable
target mode/size/mtime/ctime action digest'e de bağlıdır. Source repo state canlı
okumadır: atomic repo snapshot veya OS containment garantisi verilmez.

Executable clean filtreleri uygulanmadığı için worktree raw/built-in dönüşüm
semantiğindedir. Submodule alt süreçleri kendi config'ini okuyabileceğinden
status/diff submodule working tree'lerini incelemez. Bu kapsam her sonuçta açık
text ve `coverage=main_worktree_without_submodules` olarak bulunur; sessiz clean
veya tam-coverage iddiası yoktur. Tam/nested/plugin-aware Git için ayrı explicit
approval gerekir. Legacy symlink HEAD, unknown layout veya unsupported Git
özelliği açık hata verir; unsafe retry/fallback yoktur. Minimum Git sürümü
uydurulmadı; fixture'da kurulu Git 2.54.0 kullanıldı.

## Modülerlik / tek writer / yaşam döngüsü

- `git/query.rs`: DTO→domain, line/ref/path limitleri ve report tipi.
- `git/query/capture.rs`: owned layout→configuration→final intent geçişleri.
- `git/query/execute.rs`: yalnız final fixed Git argv; motor/parser Git'tedir.
- `git/profile.rs`: safe config ve Captured→Prepared→Running metadata lifetime.
- `git/repository.rs`: shared fixed flags/environment/settings/admin evidence.
- `security/read_target.rs`: live veya immutable pinned evidence; clone aynı
  revision'ı tutar, yetki veya yeni capture değildir. Alanlar private kalır.

Commands reservation her phase boyunca aynı app/session request'e aittir.
Metadata/config process'leri aynı ExecutionGate ve PGID supervisor'dan geçer.
Process exit yetmez: capture, TERM/grace/KILL, reap ve gerçek join tamamlanır;
ancak bundan sonra yeni blocking prepare başlar. Tek bir query deadline'ı
preflight'lar arasında yeniden başlamaz; independent metadata preparing bound 30s.

Preparing worker cancellation token/deadline/drop guard ve checkpoint taşır.
Final output render + private metadata deletion ayrı Finalizing worker'ındadır;
JobCompletion lease'i bu join'e kadar tutulur. Child başlamadan owner/gate/spawn
reddi ise Discarding worker'ına gider; onun join'i öncesi reservation/run bırakılmaz.
Application state'i yalnız mailbox writer günceller; I/O worker actor tutmaz.
Private metadata sadece confirmed drain/no-spawn discard ile kaldırılır.
Uncertain/abandoned issued resource unlink edilmez; cleanup failure quarantine/
transport failure'dır, başarı/yeni admission değildir. Source filesystem syscall
hard-interrupt veya arbitrary setsid child containment iddiası yapılmaz.

Elisp diff/blame argv/ref/range/report motorları kaldırıldı. Public read entry'leri
yalnız immutable editor intent yakalar; parse/range hataları async ERROR gelir.
Legacy mutation executor hâlâ kendi gerçek tüketicileri içindir; bu dilimde silinmez.

## Kabul ve fixture hijyeni

Real native pipe tests: 8 layout/worktree kombinasyonu; clean/textconv/fsmonitor/
signature marker'ları; staged/commit/literal path; single-ended blame; invalid
range/ref/unknown fields için Git process başlamama; foreign/missing Git;
complete UTF-8/byte limits ve next read reuse. Config preflight sonrasında gerçek
repo'ya yeni filter ekleyen wrapper final sorguda helper çalıştıramaz; özgün Git
positive-control aynı helper'ı çalıştırır. Nested repo helper kontrolünde
coverage açık kalır. Private TMPDIR gerçek completion'da boştur.

TERM'i ignore eden gerçek final query/child: ping ilerler; cancel sinyalinde
private metadata ve app reservation kalır; sibling read Busy; /proc leader/child
reap sonrası metadata silinir ve next read kabul edilir. Prepared cancellation/
drop, immutable evidence ve unknown cleanup unit corpus'u da eklendi.

İlk fixture yanlışlıkla `cancel` gönderiyordu (doğru method rpc/cancel). Test
başarısızlığında eski Peer destructor core'u anında SIGKILL ettiği için iki
controlled fixture process'i orphan kaldı. Exact PID/PGID/argv read-only doğrulanıp
TERM→grace→KILL ile temizlendi; /proc/ps'de kalmadıkları kontrol edildi. Shared Peer
şimdi PGID lideri ve destructor önce EOF verir, real drain için 12s bekler; core'u
ilk adımda öldürmez. Kullanıcı süreci veya dosyası hedeflenmedi.

ERT: old-cap no-send/no-fallback, gerçek diff/blame/status ve read-only mode/direct
consumer; önceki shared application/session/startup/late timer corpus'u full
regression'da. Bütün bu kontroller yalnız bounded implementation regression'dır;
mevcut TLA+ modelleri yeni Git/private-FS lifecycle'ının formal refinement'ı değildir.

Final doğrulama: **1274/1274 source ERT**, 0 unexpected, **155.077287 s**,
**23:35:10**; **315 native + 24 compile-fail =339** locked test. Normal locked build,
fmt, strict all-targets Clippy/unwrap/expect/panic, dört değişen Elisp dosyasında
Werror bytecompile ve production checkdoc temiz. Elc task-specific /tmp'dadır.
Kayıtlar `/tmp/kargu-git-profile-final-{ert,rust,build,clippy,bytecompile}.log` ve
`/tmp/kargu-git-profile-checkdoc.log`. Connection TLC **602836/101708**, queue 0,
depth22; transport **1810/693**, queue0, depth12 (**23:26:53**) temiz.
