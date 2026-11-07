# Native config dosya I/O tüketici geçişi — 2026-10-26

`configuration/read` ve `configuration_read` capability gerçek
`kargu-config-refresh-async` tüketicisine bağlandı. Rust yalnız parser temelini
sunmuyor: ilk mevcut aday seçimi, regular-file capture, UTF-8/source bound,
TOML/schema/legacy import ve digest aynı owned worker'da yürütülüyor. Mevcut
parser tekrar kullanılıyor; ikinci parser veya config actor yazılmadı.

## Yetki, kaynak ve iptal sınırı

- Domain `configuration/read/{domain,file,mod}.rs` altında. `ConfigurationPath`,
  `CandidatePaths`, `ReadTimeout` serde/TryFrom sınırında parse edilir. En çok
  sekiz yerel/absolute aday, path başına 4096 byte, 1–5000 ms timeout ve önceki
  64 KiB UTF-8 source sınırı vardır. Parent'ın kalan deadline'ı IPC'ye geçirilir.
- Bunlar editörün açık verdiği config okuma grant'leridir: config dosyaları
  çoğunlukla workspace dışındadır. Model/workspace tool path sandbox'ı gevşetilmez;
  bu RPC tool registry'ye bağlanmaz. Native relative/parent traversal/control
  paths reddeder; Elisp TRAMP adayını startup öncesi reddeder.
- Canonical symlink hedefleri desteklenir. `/` fd'sinden `openat` + no-follow
  directory yürüyüşü, final `O_PATH` pin ve regular-file metadata kontrolü
  uygulanır. FIFO/device/directory veri okumak için açılmaz. Linux procfs
  `/proc/self/fd` yalnız tutulan regular inode'u read descriptor'a yükseltir;
  onaylanan pathname yeniden açılmaz. Dev/inode/size/mode/mtime/ctime ve current
  canonical path capture öncesi/sonrası kontrol edilir. Atomic replacement,
  symlink replacement ve gözlenen in-place revision değişimleri reddedilir.
  Linux/procfs bağımlılığı açıktır; privileged filesystem adversary'ye karşı
  transaction/snapshot garantisi iddia edilmez.
- Yeni process/actor/runtime veya sınırsız worker yoktur. `ipc/read_tools.rs`
  mevcut dört slotu workspace ve config okumaları arasında paylaşır. Tipli
  operation/completion ve session/connection owner ayrımı vardır. Worker Host
  state'i yazmaz; actor tek completion publisher'dır. Config owner ready
  connection epoch'tur; native editor application lease yaratılmaz.
- Cancellation/deadline/shutdown geç gelen başarıyı actor yayınından önce
  keser. Slot, iptal sinyalinde değil gerçek blocking-worker join'inde bırakılır;
  EOF/shutdown mevcut drain hattını kullanır. OS file I/O cooperative'dir:
  kontrol noktaları OS adımları/chunk'lar arasındadır. Kernel'de takılan bir
  filesystem syscall'ını token interrupt edemez; hard real-time drain iddiası
  yoktur. Yeni subprocess olmadığı için yeni PGID yaşam döngüsü de yoktur.
- Source/chunk buffer'ları Zeroizing'dir. `ReadOutput` genel Debug/Serialize
  alamaz (iki compile-fail test); yalnız private editor handoff'u açılır.
  Dosya source'u Elisp/child argv/IPC'ye dönmez. Parsed credential mevcut private
  editor projection'a kasıtlı aktarılır; IPC/JSON/GC fiziksel erasure iddiası yoktur.

## Gerçek tüketici ve silinen yollar

Elisp root tek config publication/revision writer'ı olarak kalır. İlk yield
öncesi candidate list/string'ler ayrılır ve editor `~` yolu genişletilir; native
reply path'i captured adaylardan biri olmalıdır. Generation, absolute deadline,
application/known lease ve malformed projection kontrolleri korunur.

`kargu-config--file-script`, `--decode-file`, `--loaded`,
`kargu-bridge-config-parse`, source-bound bridge sabiti ve file-only worker stdout
parametresi silindi. `config/worker.el` silinmedi: auth-source/plaintext ve callable
credential interop hâlâ gerçek tüketicidir. Native saf `configuration/parse`
primitive'i korunur; `configuration/read` aynı engine'i çağırır.

İlk mevcut dosya invalid/unreadable/oversized/nonregular ise fallback yapılmaz,
eski başarılı publication kalır. Hepsi absent ise ilk path ile empty publication
gelir. Bu nedenle explicit refresh absent durumda da core başlatır; passive
getters hâlâ sıfır RPC/IO/startup'tır. Missing binary/capability fail-closed'dur;
editor file/parser fallback yoktur. Shared bootstrap read application/session,
editor application lease acquisition'ı değildir.

Gerçek provider picker regresyonu ilk uygulamada `invalid_params` ile kırıldı:
`locate-user-emacs-file` ikinci adayı `~/.emacs.d/kargu.toml` olarak bırakabiliyor.
Rust'un absolute-path sınırı gevşetilmedi; editor path capture sınırında
`expand-file-name` kullanıldı. Düzeltme sonrası cold picker custom/local provider
listesini gerçek XDG dosyasından tekrar besliyor; upstream HTTP yoktur.

İlk tam ERT taramasında model intent/startup fixture'ı da kırıldı: eski test
double'ı yalnız bir callback sakladığından yeni synchronous config-startup
registration'ı model waiter'ını eziyordu. Production shared-startup zaten çoklu
waiter destekler. Fixture iki ayrı waiter'ı tutup ikisini de serbest bırakacak
şekilde düzeltildi; exact first-intent revision ve sonraki revision assertion'ları
korundu. Odaklı regresyon bu değişiklikten sonra geçti; yeni config IO veya
metadata preparation üretim koduna test için bypass eklenmedi.

## Kabul kanıtı ve açık kapsam

Native pipe fixture'ları first-existing + symlink original-path, absent,
malformed-first-no-fallback, oversized/non-UTF8/directory/FIFO/device ve input/
epoch/notification sınırlarını denetler. Unit fixture'ları captured file değişimi,
pre-IO cancel/deadline, ortak capacity ve late completion/actual collection
sınırını denetler. Held gerçek native cevaplı ERT cancel/deadline/supersession/
lost lease/two-application ve provider view close/mode durumlarını kapsar.
Missing binary, unsupported capability, cold absent ve startup sırasında aday
mutation fixture'ları vardır. Bunlar stalled kernel syscall'ına hard kill kanıtı
değildir; mevcut bounded TLC modelleri concrete filesystem refinement sayılmaz.

Final **1261/1261 source ERT**, 0 unexpected, **137.224415 s**, **09:50:38
Europe/Istanbul** geçti. **280 native + 20 compile-fail**, locked build/fmt ve
strict Clippy temiz. Dokuz değişen Elisp dosyası Werror/checkdoc temiz; elc
yalnız /tmp'dadır. Connection TLC **602836 / 101708**, queue 0, depth 22;
transport **1810 / 693**, queue 0, depth 13 ile temiz. Log yolları ve kapsam
aynı commit'in .codex/12 kaydındadır. Native config
publication authority, env/keyless/credential precedence ve provider/model
selection hâlâ todo 1'de açıktır. Bu dilim bütün API/Rust göçünü veya tüm 01
uyumluluğunu kapatmaz. Gerçek config/credential dosyası, canlı hesap/ücretli API,
kurulum, canlı Emacs reload, merge/push ve kullanıcının 07/shell.nix değişiklikleri
bu çalışmaya dahil değildir.
