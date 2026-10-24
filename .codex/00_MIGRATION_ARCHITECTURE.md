# 00. RUST GEÇİŞ MİMARİSİ VE KAPSAM SÖZLEŞMESİ

Durum: **Rust IPC/Emacs bridge, execution library temelleri ve ilk native
`find_files` geçişi uygulandı; eski Elisp glob engine'leri kaldırıldı** (2026-10-24).
Uygulama kanıtı ve kalan işler: [12_MIGRATION_PROGRESS.md](12_MIGRATION_PROGRESS.md).
Hedef, mevcut Kargu yeteneklerini ve güvenlik/sahiplik sözleşmelerini koruyarak
agent motorunu Rust'a taşımak; Emacs'i canlı editör adapter'ı ve UI olarak
tutmaktır. Nihai uygulama aşama kapılarıyla doğrulanır; bu belge bir üretim
hazırlığı veya hatasızlık garantisi değildir.

Kesin ürün kapsamı: mevcut **doğrudan API desteği Elisp'ten Rust'a taşınarak
korunur**; yanına **Codex, Antigravity, Claude Code ve OpenCode** uygulama
backend'leri eklenir. Kullanıcı aynı GUI **provider alanından** API sağlayıcısı
veya kurulu uygulama seçer. Bunlar alternatif yürütme yollarıdır; uygulama
desteği API'yi kaldırmaz. Kurulum/uygunluk ve dört-backend kabul koşullarının
tek kaynağı [03_EXTERNAL_BRIDGES.md](03_EXTERNAL_BRIDGES.md) bölüm 0/6'dır.

## 1. Neden Rust, hangi sınırlarla?

Rust tip sistemi geçersiz veri ve bazı iç geçiş hatalarını derlemede yakalar.
Tokio ağ/process I/O'sunu Emacs event loop'undan ayırır; bounded kanallar ve
batch render editör üzerindeki baskıyı azaltır. Sıfır gecikme veya tüm runtime
hatalarının ortadan kalkması vaat edilmez.

TLA+ modelleri bounded safety/liveness kanıtıdır; Rust typestate bu modellerin
otomatik ispatı veya yerine geçeni değildir. IPC, cancellation, sahiplik,
diagnostic tazeliği, OS süreçleri ve save-hook davranışı runtime/integration
testleri gerektirir. Ayrıntılar 01 ve proof/README.md ile eşlenir.

## 2. Nihai sorumluluk dağılımı

| Katman | Sahip | Görev |
| --- | --- | --- |
| Domain/application | Rust | Claim/single-run, session/history, mode, plan dispatch, budget, tool gate |
| Network/OS | Rust | Provider adapter, SSE, retry/breaker, process/job, read/search/Git/webfetch |
| Güvenlik | Rust + Emacs runtime revalidation | Policy/approval/path/egress; editör kaynağına dokunmadan önce canlı kimlik/revision kontrolü |
| Edit/review | Hibrit | Rust proposal/diff/review; Emacs buffer/undo/save transaction |
| Canlı sensör | Emacs | Eglot/Flymake publication, Xref/symbol/range; Dape connection/thread/frame/stop |
| Görünüm/etkileşim | Emacs | Chat/draft/routing, Markdown/scroll/header, picker/completion, review/approval UI |
| Harici köprü | Rust uygulama adapter'ları; ayrı MCP adapter'ı | Codex, Antigravity, Claude Code, OpenCode; agent backend ve MCP tool sunumu ayrı capability |

Emacs'in runtime kanıtı olan document tick, diagnostic publication, debugger
connection/stop generation ve buffer/window sahipliği Rust'a taşınıp disk
mtime veya bir timer ile ikame edilmez. İnce istemcinin satır sayısı kotası yoktur.

## 3. Sahiplik ve çalışma modeli

İlk hedef Linux + Emacs'in başlattığı stdio child `kargu-core` sürecidir.
Rust library/bin ayrımıyla headless test edilir; başlangıçta kendiliğinden
paylaşılan sistem daemon'ı kurulmaz. MCP erişimi ayrı proxy kanalıdır (03).

```text
Emacs client instance
  -> CoreHost
       -> ApplicationActor (application başına tek aktif run)
            -> Session history/accounting/selection
            -> RunScope (claim, generation, budget, connection snapshot)
                 -> HTTP / tool / job / approval / edit / reverse RPC
```

Birden çok chat session'ı bulunabilir; bu aynı application'da eşzamanlı agent
run'larına izin vermez. Core her session'a tek yazıcı sağlar. Foreign/obsolete
callback, owner closure ve reset eski sonucu başka session'a taşıyamaz.

Rust agent backend cutover'ı henüz yapılmadı; Elisp agent default kalır.
Taşınan `find_files` artık yalnız Rust tarafından yürütülür; missing binary
durumunda eski Elisp engine'e dönülmez. Bu read portu agent backend seçimi
değildir. Aktif run boyunca backend/connection snapshot
sabitlenir. Legacy ve Rust aynı yan etkiyi veya state'i birlikte yönetmez;
başarısız Rust mutation'dan sonra otomatik Elisp replay yapılmaz.

## 4. Korunacak özellikler

- Doğrudan API: Elisp API uygulaması Rust'a taşınır; mevcut OpenAI uyumlu/
  custom/yerel, Anthropic ve diğer kayıtlı wire ailelerinin model seçimi,
  streaming, tool calls, usage ve retry davranışı korunur.
  Responses/Chat Completions gibi farklı wire şekilleri ayrı adapter'dır.
- Tool registry: canonical ad, alias, JSON schema, mode/availability ve ortak
  permission gate. Native OS ve delegated editor araçları aynı kapıdan geçer.
- LSP: definition, references, symbols/skeleton, project diagnostics,
  exact-revision post-edit verification; eksik/stale sensör başarı sayılmaz.
- Dape: startup/compile/preflight/readiness, connection/thread/frame seçimi,
  scopes/variables/watch/breakpoint ve execution control. evaluate/continue
  salt okunur sensör değildir; izin ve runtime kimlik denetimi gerekir.
- OS araçları: Bash ve interactive process sessions, stdin/output/poll/EOF,
  owner-scoped jobs/cancel, Git, read/search, skill/toolchain/dependency probes,
  webfetch ve egress policy.
- Edit: unified diff, staged proposal, accept/reject ve revizyonlu review,
  canlı dirty buffer, undo/save-hook/coding/EOL koruyan transaction, conflict
  ve foreign edit'i ezmeyen rollback.
- Plan/mod: mevcut ask/plan/debug/agent modları; plan artifact/revision,
  tek kullanımlık dispatch ve asenkron debug mode hazırlığı.
- History: atomic tool-call/result blokları, context compaction, bounded
  healing, cancelled/unknown sonuç onarımı, typed multimodal/provider metadata.
- Session: schema_version=2 ve legacy import, yeni journal/snapshot recovery,
  session isolation, draft ve seçim/accounting restore.
- Model/config: embedded + discovered + explicit custom metadata, immutable
  connection snapshot, auth-source/callable credential port, model bazlı
  reasoning/sampling capability ve kesir artıklı MicroUsd muhasebesi.
- UI: çoklu chat buffer, Markdown/code, role/transcript, scroll, header,
  completion/model/effort picker, Transient ve cancellable confirmation.
  Provider alanı API ve kurulu uygulamaları aynı seçim arayüzünde sunar;
  discovery/uygunluk nedeni görünürdür, aktif run'da backend değiştirilmez.
- Dinamik context: legacy @path/@file::symbol ile yeni file/buff/sym/git/line/
  folder etiketleri; RAM snapshot, provenance ve byte/token bütçesi.
- Uygulama backend'leri: Codex, Antigravity, Claude Code ve OpenCode için
  Kargu'dan konuşma/turn başlatma, stream/terminal sonuç ve Stop/iptal desteği.
  MCP üzerinden editor araçlarını sunmak ayrı özelliktir; özellikle Antigravity
  için MCP-only entegrasyon backend teslimi sayılmaz. Protokol doğrulanamıyorsa
  ilgili adapter açık teslim engeli kalır; dört-uygulama kapsamı sessizce daraltılmaz (03).

## 5. Taviz verilmeyen güvenlik ve lifecycle kuralları

1. Claim/config preparation/notification sırası korunur. Run başına tek bütçe,
   tek terminal teslim ve revoke -> drain -> release sırası vardır.
2. Shell komut analizi risk sınıflandırmasıdır; gerçek OS sandbox değildir.
   Canonical path check tek başına symlink/TOCTOU yarışlarını çözmez.
   Verilmeyen izolasyon garantisi UI/dokümantasyonda iddia edilmez.
3. Approval exact action/scope/revision/deadline'a bağlı, sunucu kayıtlı ve tek
   kullanımlıktır. Headless/missing adapter reddeder; C-g/timeout/reject ayrıdır.
4. Edit güncel base revision/hash ile uygulanır. Kör erase/save, dirty buffer
   üstüne disk yazısı ve sabit tempfile yasaktır. Çok dosyalı crash atomicity
   journal olmadan vaat edilmez.
5. Byte/time/item/queue limitleri her sınırda uygulanır. Cancellation ve reverse
   response render basıncında aç kalmaz. Ham request/secret loglanmaz.
6. HTTP stream'i kapatmak sağlayıcı faturalamasını kesin kesmez. PGID kullanımı
   reap zorunluluğunu veya process group'tan kaçan child sınırını ortadan kaldırmaz.
7. Optional UI/LSP/Dape/Git/backend eksikliği core'u yüklenemez yapmaz;
   unavailable/stale bilgi clean/verified veya izin verilmiş sayılmaz.

## 6. Belgelerin yetki ve okuma sırası

Bu dosya kapsamı belirler. Ayrıntıda 07 wire'ın, 06 edit/approval/plan'ın,
05 canlı runtime kanıtının, 08 persistence/security/provider composition'ın,
11 cancellation/repair'ın, 10 model parametrelerinin, 09 context'in tek kaynağıdır.
01 ortak domain/sahiplik kurallarını, 02 modül envanterini, 03 harici capability
sınırını belirler. **Uygulama sırasının tek kaynağı 04 yol haritasıdır.**

`.codex` içindeki eski tutorial kod blokları nihai implementasyon diye
kopyalanmamalıdır; incelemede derlenmemiş/eksik örnekler kaldırılmış, yerine
bu sözleşmeler ve kabul testleri yazılmıştır. Nihai Rust/Elisp kaynakları
uygulama sırasında derlenebilir testleriyle üretilir.

Mevcut architecture-contracts.md, docs/modularity.md,
docs/connection-ownership.md, tests/ ve proof/ korunacak davranışların
dayanağıdır. todo.md'deki açık yükümlülükler Rust'a geçince otomatik kapanmaz.
Bir uyuşmazlıkta mevcut güvenlik/sahiplik kuralı sessizce gevşetilmez;
değişiklik gerekçesi, model/test eşlemesiyle ayrıca kaydedilir.

Uygulama sırası: [04_PHASED_ROADMAP.md](04_PHASED_ROADMAP.md).
İlk IPC dilimi mevcut Elisp motorundan bağımsızdı. Güncel ilk tool portu ve
legacy kaldırma kanıtı: [15_NATIVE_FIND_FILES.md](15_NATIVE_FIND_FILES.md).
Agent run/provider/history ve diğer tool aileleri henüz Elisp'tedir.
