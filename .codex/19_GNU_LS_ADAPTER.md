# GNU ls adapter'ı: özel listing motorunun kaldırılması

Güncel ek: bu ls diliminin ardından Emacs reverse approval presenter'ı da
bağlandı (18). Son toplam test/commit durumu 12'deki en üst kayıttadır.

2026-10-24. 17'deki kullanıcı kararı uygulandı. 16 belgesi önceki native
tarayıcının tarihsel kaydıdır; aşağıdaki sözleşme onun yerini alır.

`workspace/listFiles` artık ortak `ipc/execution` -> ExecutionGate ->
ProcessSupervisor yolunu kullanır. `workspace_list_files_ls` capability'si
wire değişikliğini açıkça ayırır; eski binary yeni istemciye uygun sayılmaz.

`workspace/listing.rs` yalnız sabit `ls -lAh --numeric-uid-gid --color=never
--quoting-style=shell-escape [--ignore=...] -- .` argv'sini hazırlar. `cwd`
istenen contained canonical directory'dir. `LC_ALL=C` explicit env'dir;
credential env miras alınmaz. `ls` trusted host PATH'ten bulunur; eksik binary
unavailable olur. Desteklenmeyen GNU seçenekleri nonzero process sonucudur;
gizli native/Elisp motoru veya otomatik binary kurulumu yoktur.

Exclusion basenames GNU --ignore için literal escape edilir; modelden serbest
flag veya shell metni bu read-only portuna alınmaz. Registry sınıfı ile command
capture sınıfı eşleşmeden grant üretilemez. Sabit listing bütün modlarda
SafeReadOnly'dir; genel program/shell çağrısı hâlâ Agent + explicit approval ister.

Çıktı ham `ls` metnidir; Rust bunu entries/kind tablosuna tekrar parse etmez.
Eski `[DIR]`/`[FILE]` etiketleri, `(empty directory)` bildirimi ve entry-count
konfigürasyonu kaldırıldı. Empty directory `total 0` döner; entry budget yerine
ortak process timeout/retained-output bütçeleri vardır. `ls` kendi sıralama ve
metadata işini yapar; büyük dizinin ls içi memory/sort maliyeti için native
entry-count limiti varmış gibi garanti verilmez.

307 satırlık özel tarayıcı ve ona ait fd-rooted ReadDirectory/openat kodu
kaldırıldı. Eski native listing testleri yeni ls/path/output/injection
sözleşmesine eşlendi; process replacement/cancel/descendant testleri ortak
execution suite'inde korunur. fd-rooted metadata snapshot/no-follow garantisi
artık iddia edilmez. Path identity revalidation OS sandbox/atomic cwd değildir.

Kanonik `list_files` ve `ls`/`dir` tool alias'ları aynı JSON path şemasını
kullanır. `ls` alias'ı CLI parser değildir; özel seçenekler mevcut `bash`
aracındaki tam komutla kullanılır. Genel Bash job cutover'ı bu dilimde yapılmadı.

Doğrulama: 51 Rust testi + 2 compile-fail, katı locked Clippy ve fmt temiz.
Full ERT 1146/1146 expected, 0 unexpected, 49.34 s; gerçek core binary ile
alias/mod/subdirectory/empty/symlink/exclusion/owner/cancel kontrolleri geçti.
Beş değişen Elisp dosyası warning-as-error bytecompile ve checkdoc'tan geçti.
Nix multicall argv[0] bulgusu 17'de kaydedildi; invocation action digest ve
approval payload'ına katılır. Sonraki dilim Emacs reverse approval presenter'ıdır.
