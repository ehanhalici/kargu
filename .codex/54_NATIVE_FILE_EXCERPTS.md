# Todo 2: native read_file ve canlı belge sınırı — 2026-10-26

Bu dilim yalnız read_file alt işini kapatır. Todo 2'nin Git diff/blame/mutation,
skill/toolchain/dependency, webfetch ve son ortak köprü temizliği açık kalır.
Kullanıcı 07/shell.nix değişiklikleri korunur; canlı Emacs reload, kurulum,
credential/gerçek kullanıcı repo mutation, uzak model/hesap turu veya push yoktur.

## Modüler native sınır

- `workspace/file/mod.rs`: closed DTO → TryFrom domain; private LineNumber,
  Window, DisplayPath/FilePath ve ayrı disk-byte/scan-char/output-char limitleri.
  Malformed/unknown fields ve lexical escape worker I/O'sundan önce reddedilir.
- `read.rs`: yalnız owned disk capture. İlk 1000 decoded karakter binary probe'u
  dar bir range/output bütçesiyle atlanamaz. Prefix incremental okunur; baştan
  geometric reread yoktur. `bytes_read` gerçek harcanan disk bytes'ıdır.
- `decode.rs`: incremental strict UTF-8 (optional BOM), BOM UTF-16LE/BE;
  scalar/surrogate chunk sınırları corpus testli. Ara text/byte/unit tamponları
  zeroizing; raw input/content Debug/Serialize/log yolu eklenmez. Invalid ve
  diğer encoding'ler açık hata: eski Emacs coding autodetection emüle edilmez.
- `render.rs`: aynı source-independent numbered formatter; CRLF normalizasyonu,
  inclusive range, tek terminal-newline kuralı, empty file line 1, unknown total
  ve bounded truncation. EOF toplamı için istenmeyen tail taranmaz.
- `security/file.rs`: mevcut config reader'dan ayrılan ortak fd-rooted regular
  capture. O_PATH/NOFOLLOW directory walk, pinned inode üzerinden /proc FD reopen,
  nonblocking regular reader; dev/ino/size/mode/mtime/ctime ve original canonical
  identity başlangıç/son kontrolde eşleşir. Config'in ayrı 64 KiB sınırı korunur.

`workspace/readFile` Host ReadScope ve mevcut bounded ReadTools tek mailbox
writer'ını kullanır. Filesystem işi spawn_blocking'de; cancel/stale/deadline
başarıyı revoke eder ama slot ancak gerçek join'den sonra bırakılır. Özel dosya
O_RDONLY açılmaz; FIFO/device/outside symlink reddedilir. Bu bir OS sandbox veya
filesystem snapshot garantisi değildir: blocked filesystem syscall zorla
kesilemez; metadata kontrolleri privileged ABA adversary'ye atomic izolasyon
iddiası taşımaz. Directory/descriptor ve cooperative I/O sözleşmesi aynıdır.

## Elisp consumer cutover

`kargu/files/async.el` yalnız initiating app/session/run/root/strict/owner ve canlı
belge interop'unu tutar. Widen/save-excursion altında bounded line motion ve raw
slice + ilk 1000 karakter probe'u alınır; full buffer copy/split, disk IO veya
numbered presentation yoktur. Rust aynı window/budget'i tekrar domain'e parse
eder. Snapshot push modelidir; çekirdeğin editöre yaptığı yeni reverse RPC yoktur.
Canlı source identity/modification tick RPC cevabında yeniden kontrol edilir.

Gecikmiş disk cevabı geldiğinde yeni bir live source varsa bounded native editor
snapshot çağrısı yapılır; eski disk text'i yayınlanmaz. Bir live snapshot sürerken
source değişirse eski revision açık hata verir. Read root invalidation child'ın
callback'ini susturduğunda parent root da cleanup ile kapanır; pending task sızıntısı
kalmaz. Origin kill/mode hook'ları ve ortak bridge take-once/deadline portu korunur.

`read_symbol` son senkron model-read tüketicisiydi; async file portuna taşındı.
Eski `kargu-file-read`, `kargu-file-read-window`, `kargu-diff-read-file`, disk
geometric reader, numbered formatter ve model worker dispatch silindi. Batch'in
gizli senkron fallback'i de yoktur; yalnız test helper'ı async sonucu bekler.
Kalan `kargu-file-text` tam edit snapshot'ıdır (todo 3); `files/worker.el` artık
yalnız Dape source consumer'ını kabul eder (todo 4). Kullanıcının aktif/live
Emacs oturumuna reload uygulanmadı; restart/reload sonrası yeni API geçerlidir.

## Kabul ve öğrenilenler

Native real-pipe fixture: Unicode/quoted filename, CRLF, UTF-16LE/BE, final newline,
empty file, past EOF, narrow actual bytes, 6000. satır, long line, byte/scan/output
cap, first-line isteğinden sonraki binary probe, invalid UTF-8/surrogate, FIFO,
device/outside symlink, malformed/unknown DTO, foreign owner, editor snapshot.
Unit: tüm UTF-8/UTF-16 chunk width'leri, inode replacement ve in-place revision;
actual join öncesi cancel edilmiş file read slotu yeniden kullanılamaz.

ERT gerçek read_file/read alias/direct + ask/plan ve LSP consumer'ını kullanır.
Native reply tutularak editor-thread disk/process fallback, yeni live source,
changed tick, session/root/run/strict/cancel/close, missing capability, malformed
result, duplicate callback, captured limits ve hook cleanup testlenir. Ortak read
portunun önceki application/expired-parent/deadline corpus'u full regression'dadır.
Eski disk-engine mock testleri native real-pipe/unit karşılıklarıyla değiştirildi.

Testte strict-mode değişimini lexical bind etmemek diğer security fixture'larına
sızıyordu; scope düzeltildi. İki izole module fixture'ı callback ve explicit test
binary sözleşmesine geçirildi. `test-tools`'daki artık var olmayan Elisp circuit
motoruna ait iki inert lexical binding de Werror sırasında tespit edilip silindi.

Final: **1272/1272 source ERT**, **148.064004 s**, **22:06:56**, 0 unexpected;
**305 native + 24 compile-fail = 329** locked test. Locked normal build, fmt,
strict Clippy all-targets/unwrap/expect/panic ve değişen 14 Elisp dosyasında Werror
bytecompile temiz; checkdoc temiz. Elc yalnız task-specific /tmp dizinindedir.
Kayıtlar `/tmp/kargu-file-native-final-{ert,rust,build,clippy,bytecompile,checkdoc}.log`.

Mevcut bounded modeller: Connection TLC **602836 / 101708**, queue 0, depth 24
(21:52:50); transport **1810 / 693**, queue 0, depth 13 (21:52:51). Model değişmedi;
bu regresyon sonuçları somut file/OS refinement veya bütün 01 için formal ispat
olarak sunulmaz. Read-only filesystem portunun safe sınıfı yapısal olarak kapalı
DTO'dur; todo 2'nin tüm aileleri kapsayan son gate/registry kabulü hâlâ açıktır.
