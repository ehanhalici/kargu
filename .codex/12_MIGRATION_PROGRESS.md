# Rust geçişi: uygulama günlüğü

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
