# 04. KADEMELİ GEÇİŞ VE KABUL KAPILARI

Sıra: baseline -> IPC -> OS/güvenlik -> canlı adapter -> core run -> köprüler
-> legacy kaldırma. 05–08 dosya numaraları **katman numarasıdır**, uygulama
sırası değildir. Hafta tahminleri kabul ölçütünün yerine geçmez.

Kesin teslim kapsamı: **Elisp API -> Rust API göçü + yanında Codex,
Antigravity, Claude Code, OpenCode uygulama backend'leri**. Aynı GUI provider
alanından API/kurulu uygulama seçimi yapılır (03/06/10). Aşağıdaki geçici
`elisp`/`rust` implementation cutover seçimi bu nihai API/uygulama seçimiyle
karıştırılmaz. Dört uygulamadan birinin protokolü doğrulanamıyorsa ilgili
kabul kutusu açık kalır; API göçü ilerler, ürün kapsamı tamamlandı sayılmaz.

## Aşama 0: Davranış baseline'ı ve paketleme kararı

- [x] 02'ye göre kaynak/public command/tool/schema/alias/policy envanteri ve
  mevcut failing/skipped test listesi kaydedilsin.
- [x] Mevcut ERT suite çalıştırılsın; ortam bağımlılıkları ve sonuç saklansın.
  İlgili bounded TLC sonuçları tarih/sürümle kaydedilsin; eski sayılar yeni
  implementation'ın kanıtı diye taşınmasın.
- [x] Linux ilk hedefi, Rust edition/MSRV, toolchain, Cargo.lock, CI ve binary
  install/discovery yolu sabitlensin. `kargu-core` PATH veya explicit defcustom
  ile seçilsin; eksik/uyumsuz binary anlaşılır hata versin.
- [x] Oturum schema_version=2/legacy import ve geri dönüş snapshot fixture'ları
  alınsın; gerçek kullanıcı session dosyası test girdisi olarak değiştirilmesin.
- [ ] Backend seçimi başlangıçta `elisp` default, Rust opt-in olsun. Aktif run
  içinde backend değişimi yasaklansın. Her servis/run için tek owner/yazıcı olsun.
- [x] Kullanıcının her adımda commit talebiyle `.codex` geçiş belgeleri explicit
  force-add ile sürüm kontrolüne alındı. Yerel `.git/info/exclude` değiştirilmedi;
  diğer yerel dosyalar bu karara dâhil değildir.

## Aşama 1: Library/bin iskeleti, IPC ve lifecycle

- [x] tokio/serde/serde_json/tokio-util codec feature'ları; bounded router ve
  tek writer. 07 handshake, schema, correlation, timeout ve epoch uygulansın.
- [x] Emacs bridge process-local state, ayrı stderr, partial frame, async
  dispatch ve sentinel cleanup ile kurulsun.
- [x] initialize, session create/snapshot/close, ping fixture'ı, shutdown/EOF
  çalışsın; bilinmeyen capability fail-closed olsun.
- [x] Gerçek pipe testi: fragmented UTF-8, malformed/oversize frame,
  response:null, reverse request, send failure, restart, slow reader.
- [x] Gate: zero pending/resource leak, sürüm uyumsuzluğunda yan etki yok.

İlk dilim kanıtı: 12_MIGRATION_PROGRESS.md. Rust agent backend seçimi henüz
sunulmaz; Elisp agent default kalır. İlk dilim yalnız opt-in lifecycle idi;
güncel native `find_files` portu aşağıdaki Aşama 2 durumunda ayrıca belirtilir.
Git tracking kararı sonraki commit talebiyle kapatıldı; plan/notlar da tracked.

## Aşama 2: Güvenlik, process/job, read/search/git ve edit temeli

Güncel öncelik (2026-10-24 kullanıcı kararı): 17_UNIX_TOOL_COMPOSITION.md.
Yeni native tarayıcı yazılmayacak. Önce modül klasörleme ve ortak komut/onay
bağlantısı; ardından mevcut özel listing motoru `ls` adapter'ıyla değiştirilir.
`workspace_grep` sonraki adapter'dır; aşağıdaki native read maddeleri önceki
dilimlerin tarihsel kanıtını korur, yeni araç stratejisinin tanımı değildir.

2026-10-24: typed execution/approval ve process supervisor library dilimi
uygulandı; ayrıntılar 14_EXECUTION_FOUNDATIONS.md. Process stdin/EOF/status,
bounded output, PGID/subreaper cleanup ve actor drain testleri geçti. Bu
servisler henüz Emacs tool/execute akışına bağlanmadığı için aşağıdaki uçtan
uca aşama kutuları açık tutuluyor. Egress/read/search/Git/edit adapter'ları
ve approval presenter bu aşamanın kalan işleridir.

İlk canlı read adapter tamamlandı: `find_files` ve alias'ları mevcut Elisp tool
gate üzerinden `workspace/findFiles` Rust portuna gider. Eski fd/rg/Elisp glob
engine'leri silindi; diğer `kargu-fs-walk` tüketicileri korunur. Bu port standalone
read servisidir; genel `tool/execute`, agent run veya shell capability'si diye
ilan edilmez. Kanıt ve test eşlemesi: 15_NATIVE_FIND_FILES.md.

İkinci canlı read adapter `list_files` ve `ls`/`dir` alias'larıdır. Listeleme
Rust'ta fd-rooted/no-follow ve bounded çalışır; eski Elisp directory scanner
silindi. Public tool şeması korunur, Lisp sonuç teslimi asenkrondur. Kanıt:
16_NATIVE_DIRECTORY_LISTING.md. G11/G13'ün kalan todo.md yükümlülükleri kapanmaz.

- [ ] Ortak execution gate, path/egress policy, scoped approval ledger ve
  asenkron Emacs approval presenter kurulsun. UI 300 s ve sensör 10 s ayrı olsun.
  - [x] Standalone `tool/execute` Rust reverse approval + process drain portu
    (18); sabit `list_files` GNU ls adapter'ı aynı execution yolunda (19).
  - [x] Emacs owned reverse approval presenter ve gerçek pipe public
    `kargu-bridge-execute` adapter testi (18). Bu port noninteractive'dir.
  - [ ] Genel Bash/job consumer cutover; interactive stdin/status/output/poll
    sözleşmesi taşınmadan eski Elisp executor kaldırılmaz.
- [ ] Process startup barrier, group supervision, bounded stdout/stderr,
  interactive stdin/poll/EOF/cancel ve TERM/KILL/reap uygulansın.
- [ ] Read/search/Git/skill/webfetch portları ve capability discovery taşınsın.
  Text reader diff adapter'ından bağımsız kalsın.
  - [x] Native `find_files`, bounded discovery, actual Emacs tool gate/alias/mode
    entegrasyonu ve eşdeğer testlerden sonra eski Elisp implementation kaldırma.
  - [x] Native `list_files`/`ls`/`dir`, owner/cancel ve fd-rooted/no-follow
    directory capture; async tüketici cutover ve eski Elisp scanner kaldırma.
  - [ ] `workspace_grep`, read/Git/skill/webfetch kalan portları.
- [ ] Diff parser/generator + revision'lı proposal/journal ve Emacs transaction
  adapter'ı 06'ya göre kurulsun; review callback'i placeholder kalmasın.
- [ ] Eski Elisp loop opt-in adapter üzerinden `tool/execute` çağırabilsin.
  Aynı araç hem Elisp hem Rust tarafından yürütülmesin.
- [ ] Gate: izin/foreign owner/interactive job/edit conflict ve rollback
  fixture'ları geçsin. Cancellation ve crash senaryoları bu aşamada başlasın.

## Aşama 3: Canlı sensör, context ve UI/plan adapter'ları

- [ ] Mevcut LSP/Dape uygulamaları typed reverse RPC arkasına alınsın.
  Önce davranış korunsun; ardından gereksiz domain formatlama taşınsın.
- [ ] 05'teki publication/version ve connection/thread/frame kanıtı,
  optional-source absence ve stale callback senaryoları geçsin.
- [ ] 09 mention grammar/legacy/folder, live buffer revision, attachment
  bütçesi ve context provenance uygulansın.
- [ ] Chat/session routing, draft, model/effort picker, plan artifact/review,
  undo/diff UI ve cancel bağlantıları korunsun.
- [ ] Gate: dirty buffer, diagnostics freshness, debugger startup/compile,
  plan supersede, iki application, missing adapter testleri geçsin.

## Aşama 4: Rust core run, provider ağı ve persistence

- [ ] Mevcut doğrudan API desteği, custom/yerel sağlayıcılar ve wire aileleri
  korunarak Elisp'ten Rust'a taşınsın; uygulama backend'leri API'nin yerine geçmesin.
- [ ] application claim/single-run, session actor, mode preparation, immutable
  connection/config/metadata snapshot ve ortak budget taşınsın.
- [ ] Her mevcut provider wire ailesi fixture'la uygulansın; capability/
  reasoning/sampling, terminal SSE, usage, retry ve tek-probe breaker eklensin.
- [ ] Typed history, compaction, bounded healing, edit verification ve
  11 cancellation/repair zinciri birlikte entegre edilsin.
- [ ] Versioned journal/snapshot, legacy import, interrupted restore ve
  outcome_unknown recovery 08'e göre doğrulansın.
- [ ] Aynı offline fixture'lar iki backend'de karşılaştırılsın: tool/result
  sırası, public schema, policy kararı, terminal outcome, history ve usage.
  Timing/UUID farkları normalize edilsin; gerçek shell/edit/model isteği
  shadow olarak iki kez yürütülmesin.
- [ ] Gate: headless fake-provider run ve gerçek pipe Emacs -> Rust -> fake HTTP
  -> native/delegated tool -> verification -> persistence uçtan uca geçsin.
  Cancel/EOF/crash/output saturation/late callback testleri dâhil olsun.

## Aşama 5: Harici backend ve MCP

- [ ] Typed API/uygulama backend ayrımı, legacy provider config uyumluluğu ve
  session-owned seçim/revision snapshot'ı kurulsun; aktif run'da değişim reddedilsin.
- [ ] Codex, Antigravity, Claude Code ve OpenCode için bounded yerel kurulum/
  sürüm/protokol/auth discovery uygulansın. GUI provider alanında API ve kurulu
  uygulama grupları, hazır olmayan kayıtların nedeni ve refresh davranışı test edilsin.
- [ ] Codex adapter'ı: doğrulanmış binary/şema ve gerçek Kargu turn/stream/
  terminal/cancel/session smoke testi; ek capability'ler açıkça bildirilsin.
- [ ] Claude Code adapter'ı: doğrulanmış binary/stream şeması ve gerçek Kargu
  turn/stream/terminal/cancel/session smoke testi; ek capability'ler bildirilsin.
- [ ] OpenCode adapter'ı: resmi entegrasyon yolu/sürümü uygulama öncesi
  doğrulansın; discovery, ownership ve gerçek Kargu turn/stream/terminal/cancel/
  session smoke testleri geçsin. Tahmini port/CLI bayrağı kullanılmasın.
- [ ] Antigravity adapter'ı: konuşma/turn kontrolü sağlayan desteklenen yol
  doğrulansın ve gerçek Kargu turn/stream/terminal/cancel/session smoke testi
  geçsin. MCP-only sunum bu kutuyu kapatmaz; uygun protokol bulunamazsa açık
  engel kaydedilsin, kapsam ancak kullanıcının açık kararıyla değişsin.
- [ ] 03'teki proxy/session capability topolojisi ve MCP handshake uygulansın.
- [ ] Her backend'de model/effort, login/config, approval, usage ve resume
  capability'leri ayrı bildirilsin; desteklenmeyen/bilinmeyen bilgi uydurulmasın.
- [ ] Dört uygulamanın ayrı kurulumu/eksikliği, incompatible version/protocol,
  needs-login, probe timeout/crash, session izolasyonu, geç olay ve Stop testleri
  geçsin. Bir uygulama hatası API'ye/başka backend'e sessiz replay başlatmasın.
- [ ] Gate: harici native tool policy sınırı ve dirty buffer yazı politikası
  kanıtlansın; iki istemci scope/replay/isolation testleri geçsin.
  Opsiyonel köprü hatası doğrudan API çekirdeğini kullanılamaz yapmasın.

Buradaki opsiyonellik kullanıcının yerel kurulumuna aittir. Nihai kapsamın
kabulü dört uygulama için ayrı kanıt ister; biri eksikken aşama kapatılmaz.

## Aşama 6: Varsayılanı değiştirme ve legacy kaldırma

- [ ] Rust opt-in bütün kapsam için eşdeğerlik kapılarını geçince default olsun.
  Son legacy tüketici geçmeden `api/loop/state/history` kaynakları silinmesin.
- [ ] Legacy backend'e geri dönüşte session snapshot/export yolu doğrulansın;
  yeni journal eski Elisp'e uyumluymuş gibi açılmasın. Active effect replay yok.
- [ ] Paketleme/install/upgrade/version mismatch ve clean-machine startup
  testi yapılsın. Rust binary + Elisp client sürüm uyumu release'e bağlansın.
- [ ] Legacy uyumluluk testi ancak eşdeğer Rust/IPC testiyle eşlendikten sonra
  taşınsın. Test silerek veya module-boundaries baseline yenileyerek geçiş yapılmasın.
- [ ] İlgili TLA+ modelleri actor/drain/refinement ile güncellensin; sınırlar,
  checked invariants ve somut test yükümlülükleri release kaydına yazılsın.

## Ortak doğrulama

Mevcut offline ERT komutu:

```sh
emacs --batch -Q -L . --eval '(progn (require (quote package)) (package-initialize))' -l tests/run-tests.el
```

Rust projesi kurulduktan sonra:

```sh
cargo fmt --manifest-path kargu-core/Cargo.toml --check
cargo clippy --manifest-path kargu-core/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path kargu-core/Cargo.toml --locked
```

Her aşamada baseline ERT + ilgili service/IPC integration + warning-free
byte compilation çalışır. Bounded TLC yalnız ilgili model/transition değişince
yeniden çalıştırılır; uzun ana model ayrı CI kapısında yürütülebilir. Canlı
sağlayıcı ve harici login testleri ücret/hesap gerektirdiği için opt-in'dir.

Geçiş ancak ilgili checkbox'lar kanıtla tamamlanınca ilerler. Bu belgelerin
incelenmiş olması Rust uygulamasının tamamlandığı anlamına gelmez.

## 2026-10-24 plan incelemesi kanıtı

- Yukarıdaki mevcut ERT komutu: **1116/1116 expected, 0 unexpected**, exit 0,
  47.68 saniye. Bu sonuç mevcut Elisp baseline'ıdır; henüz Rust eşdeğerliği değildir.
- 00–11 belgeleri mevcut kaynak aileleri, architecture-contracts.md,
  docs/modularity.md, docs/connection-ownership.md ve proof/README.md ile
  karşılaştırıldı. Markdown fence ve whitespace kontrolleri geçti.
- Yalnız plan dosyaları düzenlendi. Mevcut shell.nix değişikliği korunmuştur.
  Rust projesi oluşturulmadı; Rust/TLC doğrulaması bu incelemede çalıştırılmadı.
- Harici ürün kaynakları 03/10 içinde tarih ve bağlantıyla kaydedildi. MCP
  capability'si ile chat backend desteği ayrıldı; gerçek login/smoke testleri
  uygulama aşamasına bırakıldı.
