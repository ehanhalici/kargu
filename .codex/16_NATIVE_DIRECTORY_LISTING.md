# Dördüncü dilim: native list_files

## Kapsam ve küçük commit sırası

Onaylı Rust planı Aşama 2'nin sıradaki read portu: önce native directory
listing ve kabul testleri, commit; ardından mevcut `list_files`/`ls`/`dir`
çağrılarını asenkron Rust portuna yönlendirme ve eski Elisp taramasını silme,
regresyon ve commit. API migration veya dört harici uygulama adapter'ı bu
dilimde uygulanmış sayılmaz. `todo.md` G11/G13'ün kalan yükümlülükleri korunur.

## Native sözleşme

`workspace/listFiles` yalnız application/session scope'lu bir read service'tir.
`workspace_list_files` capability'si açıkça ilan edilir. Find/list operasyonları
kapalı `WorkspaceRead`/`ReadResult` enum'larıyla aynı dört worker limitini ve
tek mailbox completion yayıncısını paylaşır; ikinci cancellation/owner deposu
kurulmaz. IO actor üzerinde bekletilmez. Cancel, deadline ve kapanan owner
başarı yayınına izin vermez; gerçek drain öncesi worker slot'u bırakılmaz.

`ListFilesInput -> TryFrom<ListFilesPlan> -> consuming execute -> ListFilesResult`.
Entry visit limiti/sayacı ve output byte sayacı ayrı private domain tipleridir.
Root ve target için lexical `..`/boyut reddi IO öncesindedir. Root absolute
olmalıdır; target root-relative veya contained absolute directory olabilir.

Workspace, `O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC` ile açılır. Öğrenim: sıradan
`File::open` sonrası `is_dir` kontrolü, FIFO root'ta daha kontrole ulaşmadan
writer bekleyebilir. `O_DIRECTORY` bunu açılışta reddeder. Ortak Workspace
capture bu nedenle sıkılaştırıldı; kontrollü FIFO root/target testi eklendi.

Canonical target'ın bileşenleri held root fd'sinden `openat(O_DIRECTORY |
O_NOFOLLOW)` ile tek tek açılır. Directory descriptor pinlenir; entry metadata
`fstatat(AT_SYMLINK_NOFOLLOW)` ile okunur. `nix` 0.31.3'ün safe `dir/fs` portları
kullanılır; unsafe/raw-fd sahiplik dönüşümü yoktur. Root/target identity ve
canonical path capture ve execute'in giriş/sonuç sınırında yeniden kontrol edilir.
Bu, directory snapshot atomicity veya OS sandbox garantisi değildir; eşzamanlı
entry değişimi normal IO hatası olabilir. Bloklanan filesystem syscall'ı zorla
öldürme iddiası yoktur; iptal OS çağrıları arasında kooperatiftir.

## Görünür davranış ve sınırlar

- Yalnız doğrudan entries; recursive tarama ve file content read yoktur.
- `[DIR]  path` / `[FILE] path`, label/path sıralaması, relative path, hidden
  entries ve `(empty directory)` legacy davranışı korunur. Derleme/yedek
  dosyaları listelenir: bu `find_files` artifact filtresi değildir.
- Ortak skip basenames, eskisi gibi aynı isimli dosyaları da gizler.
- Symlink hedefi izlenmez, broken/outside/cyclic link `[LINK]` gösterilir;
  socket/FIFO/device `[OTHER]` olur. Eski Elisp'in symlink'i hedef türüyle
  etiketlemesi bilinçli olarak değiştirilir, hedef içeriği/ismi döndürülmez.
- Max 200 retained result ve 64 KiB raw text bütçesi; entry visit hard cap
  100.000. Dot entries bütçeye sayılmaz; excluded entries sayılır. Incomplete
  listing açık `truncated` + omission metni taşır; sahte empty/complete yoktur.
- Unicode korunur; invalid UTF-8/newline record reddedilir. Negotiated frame'e
  sığmayan sonuç connection'ı düşürmeyen scoped resource error'dur.

## Rust kabul kanıtı

47 Rust test + 2 compile-fail doctest başarılı. Yeni kapsam: sekiz listing
fixture'ı; FIFO, symlink, root/target replacement, output/entry limit, exact/
zero/empty ayrımı, fd cleanup. Gerçek stdio listing + ping, strict DTO,
foreign/closed owner ve small-frame error testleri eklendi. Ortak ledger'da
find/list toplam kapasitesi, request-scoped cancel, late expired/closed owner
publication reddi test edilir. Önceki process/approval testleri de korunur.

Aşağıdaki ilk regresyon native commit öncesinin kaydıdır; frontend cutover
ve final kabul sonraki bölümde kayıtlıdır.

Native dilim sonrası mevcut full ERT: **1137/1137 expected, 0 unexpected**,
47.52 s. Bu koşuda listeleme tüketicisi henüz eski Elisp yoludur; yeni native
servis eşdeğerliği Rust/gerçek-stdio testleriyle doğrulanmıştır. Locked fmt ve
strict all-target Clippy temiz. Henüz frontend cutover yapılmış gibi sunulmaz.

## Emacs cutover ve legacy silme

Native servis/test dilimi `3fa1a45` ile commit'lendi. Ardından `list_files`,
`ls` ve `dir`, mevcut tool gate/mode/schema/alias zinciri üzerinden Rust'a
yönlendirildi. `kargu-search-list-files` içindeki `directory-files`, entry türü
kararı, label/sort ve join engine'i silindi. Ortak find/list adapter'ı yalnız
argüman snapshot'ı, startup, callback ve owner cleanup yürütür; domain taraması
ve formatlama Rust'tadır. `kargu-fs-walk` ve grep'in canlı tüketicileri silinmedi.

Public tool adları, alias'ları ve schema korunur. Lisp façade adı ve ilk PATH
argümanı kalır, sonuç callback ile gelir: `(kargu-search-list-files path callback)`.
Callback'siz eski senkron çağrı açık hata döndürür; Emacs'te Rust bekleyen bir
sync bridge eklenmez. `kargu-search-list-max-entries` varsayılan 2000, max
100.000 ayrı entry budget'tır. Find/list aynı parent task + captured buffer
temizliğini paylaşır; Stop kendi RPC'sini iptal eder, geç output teslim edilmez.
Capability'siz eski binary'de açık unavailable vardır, eski scanner'a replay yoktur.

Eşdeğerlik kanıtı: eski `kargu-search-list-files-test` aynı etiket/sıra çıktısını
gerçek core callback'inden denetler. Rust domain testleri immediate/subdirectory,
hidden/compiled/backup ve configurable exclusion davranışını korur. Yeni ERT
`list_files`/`ls`/`dir` adlarını dört mode'da gerçek gate üzerinden çalıştırır;
file target error, empty/partial/link ve scope cleanup test edilir. Kontrollü
façade testinde `directory-files` çağrısı hata üretecek şekilde kapalıdır; sonuç
yine native porttan alınır. Duplicate/malformed callback, missing binary/capability,
late result ve parent cancellation testleri eklenmiştir. Listing-only capability
bulunan peer de read-service startup yapabilir; find capability zorunlu değildir.

Final kabul: **1146/1146 full ERT expected, 0 unexpected, 0 skipped**.
Son full koşu güncel binary ve .elc olmadan kaynaklardan: **47.79 saniye**.
Odaklı bridge/search: **39/39**; bunun **20** testi bağımsız bridge suite'indedir.
Rust: **47 test + 2 compile-fail doctest**. Locked fmt/strict all-target Clippy,
warning-as-error byte compilation ve checkdoc geçer. TLA+ modelleri değiştirilmedi;
bu read-service uygulaması için yeni model/refinement kanıtı iddia edilmez.
Uzak CI ve gerçek provider/CLI/MCP testi bu dilimde çalıştırılmadı.
