# workspace_grep: rg/GNU grep + ortak Rust process owner

2026-10-24. 26'daki record-capture prerequisite ardından consumer cutover.

## Taşınan sorumluluk

Yeni `workspace/grep` adapter'ı fixed executable/argv, typed regex/glob girdisi,
global `MatchLimit` ve immutable reporting context hazırlar. Regex veya glob
motoru yazılmaz. Host'un absolute PATH girişlerinden executable `rg` seçilir;
yoksa GNU `grep` kullanılır. İkisi de yoksa scoped unavailable; kurulum,
network veya Elisp replay yoktur. `-- pattern target`, env_clear + LC_ALL=C,
rg --no-config, line-buffered output ve explicit cwd kullanılır.

`workspace/grep` RPC + `workspace_grep` capability, aynı owner/run/gate/
supervisor'dan geçer. Read-only sınıf yalnız built-in command factory'sindedir;
model genel komuta aynı adı vererek veya JSON'a program ekleyerek onu alamaz.
Hazırlık off-mailbox, completion/formatter aynı immutable action'a aittir.
`ipc/execution/reply` display işini lifecycle'dan ayırır. ls ile ortak host
executable lookup/literal exclusion helper'ı `workspace/command` içindedir.

Hedef root içinde canonical file/directory olmalıdır; parent traversal,
external symlink ve FIFO/device reddedilir. Root/cwd/executable yanında hedef
O_PATH descriptor kimliği tutulur; device/inode/path digest'e bağlıdır ve spawn
öncesi tekrar kontrol edilir. Bu canlı dosya okumasıdır, content snapshot
onayı değildir. Revalidation ile executable'ın gerçek path open'ı arasındaki
yarış ortadan kalkmaz; recursive traversal OS sandbox veya atomik snapshot
değildir. Default rg ve grep -r recursive symlink'leri takip etmez.

## Korunan bütçe ve sonuç

Public tool adı, alias, şema, tüm modlarda availability ve callback API kalır.
Global max_matches için cap+1 complete stdout record yakalanır, ilk cap kayıt
sunulur; lookahead varsa mevcut omitted note eklenir. Dosya başına rg
--max-count kullanılmaz. Tam cap kadar eşleşmede omission yoktur, toplam sayı
uydurulmaz. Raw stdout/stderr, capture_stop, exit/signal ve cleanup ayrı kalır.

Exit=1 no-match'tir, exit=2 regex/araç hatasıdır. Byte-before-record failure,
timeout/cancel ve unknown cleanup başarıya çevrilmez. Yeni stderr byte observer
aynı capture politikasında resource-stop üretir; geç stderr overflow daha önce
gelen record stop'u da failure'a çevirir. Normal Bash prefix/tail davranışı
değişmez. Intentional stop sonucu ancak tam TERM/grace/KILL/reap sonrası gelir;
mevcut default grace 5s olduğundan capped search bu kadar gecikebilir.

Elisp `kargu-process-max-bytes` ve `kargu-process-timeout` capture edilir.
Forward RPC timeout finite command + 11s cleanup payıdır. timeout=nil gerçek
unlimited native deadline + timersız forward waiter'dır; Stop, buffer kill,
major-mode change ve disconnect hâlâ waiter'ı revoke eder. Reverse approvals
sınırlı kalır. DTO finite timeout üst sınırı 24 saat, pattern/glob 1024 byte,
max_matches 1..1,000,000 ve output 0..4MiB'dir. Negotiated IPC frame'e sığmayan
sonuç scoped error verir; transport kapanmaz ve eksik metin başarı sayılmaz.

## Öğrenilen: rg glob sırası bir policy kararıdır

Gerçek test, pozitif user glob'un önceki negative directory glob'larını
yeniden include edebildiğini yakaladı. User include önce, literal skip-directory
exclusion'ları sonra eklenir. Wildcard/basename escaping eşleştirme motoru
değildir; yalnız adapter argümanındaki literal policy'yi korur. GNU fallback'in
eski basename-only --include semantiği bilerek korunur; rg ile tam glob
eşdeğerliği iddia edilmez. İki engine'in kendi regex/ignore semantiği değişmez.

## Legacy kaldırma ve test eşlemesi

Elisp search--run, --rg-exclude-args, --truncate-lines, --grep-report,
--grep-rg ve --grep-gnu kaldırıldı. Search.el yalnız input capture, canlı
project path kontrolü, owned async callback ve UI/tool registration taşır.
Shared process.el Git/diff/webfetch ve diğer tüketiciler için kalır; arama artık
çağırmaz. Genel API/provider agent göçü ve dört application backend açık kalır.

Eski both-engine raw/output/flags assertions Rust gerçek pipe matrix'ine taşındı:
zorlanmış rg/GNU fallback, global/exact cap, distinct files/lookahead, no-match/
invalid regex, literal exclusion, glob, recursive links, byte failure, invalid
DTO/path, foreign scope, missing tools ve oversized reply/ping. Yavaş synthetic
rg fixture'ı unlimited request boyunca ping responsiveness ve cancel sonrasında
/proc leader'ın gerçek reap'ini denetler. ERT public callback ve no-legacy-runner
kontrolleri devam eder. Source-only full regression sayıları 12'de tutulur;
bounded eski TLC modelleri yeni adapter için refinement ispatı değildir.
