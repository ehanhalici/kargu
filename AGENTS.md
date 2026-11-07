# Bağlayıcı mimari kuralı

Kullanıcının 2026-11-01 talimatı: Rust backend'dir; Elisp yalnız Emacs frontend'i
ve Rust ile editör arasındaki köprüdür. Bütün iş mantığı ve orkestrasyon Rust'ta
yaşamalıdır.

- Config dosyasını Rust okur ve doğrular. Provider/model keşfi, bunlara HTTP
  isteği atılması, cache, seçim ve istek politikası Rust'a aittir. Elisp yalnız
  Rust'ın verdiği DTO'ları listeler ve kullanıcı eylemlerini iletir.
- Loop, permission, tool dispatch, edit/review kararları, history, persistence,
  bütçe, compaction, healing ve verification Rust'ın sorumluluğudur. Elisp'te
  bunların ikinci bir karar motorunu veya domain state aynasını ekleme.
- Emacs'e özel buffer kimliği/metin yakalama, native yetkiye bağlı canlı
  transaction/save/undo, UI sunumu, Eglot/Dape gözlemleri ve auth-source erişimi
  ince editör adaptörleri olarak kalabilir. İşlem kararı Rust'a geri döner.
- Var olan eski Elisp motorları geçiş borcudur. Gerçek tüketicileri native yola
  geçirip eşdeğerliği doğruladıktan sonra kaldır; dosya taşıma veya yeşil unit
  testi tek başına geçişi kapatmaz.

Uygulama kuralları: [.agents/skills/native-migration/references/00_MIGRATION_ARCHITECTURE.md](.agents/skills/native-migration/references/00_MIGRATION_ARCHITECTURE.md)
ve [.agents/skills/coding-standards/references/01_RUST_CORE_PATTERNS.md](.agents/skills/coding-standards/references/01_RUST_CORE_PATTERNS.md).
İşlerin ve kabulün tek takip listesi [todo.md](todo.md) dosyasıdır.

Kullanıcının test talimatı: TLA+/TLC yalnız TLA+ kodu değiştiğinde çalıştırılır.
Değişmeyen modelin önceki sonucunu tekrar elde etmek için TLC çalıştırma.
Değişikliğe uygun Rust/ERT, lint ve derleme kontrollerini uygula; yalnız gerçekten
doğrulanan dilimleri kapsamına uygun commit et. Kullanıcının diğer staged ve
unstaged çalışmalarını koru.

---

# Kargu `.agents/` Hub & Customizations Guide

This repository organizes all agent intelligence, architectural rules, and operational skills under `.agents/`.

## 1. Skills (`.agents/skills/`)
Skills provide progressive runbooks for key agent workflows:
- [coding-standards](.agents/skills/coding-standards/SKILL.md): Non-negotiable Rust core patterns (no unwrap, newtypes, bounded buffers, single writer) and thin-Elisp UI bridge rules.
- [verification-and-testing](.agents/skills/verification-and-testing/SKILL.md): Testing procedures (Cargo, ERT, Clippy, Checkdoc) and strict TLA+/TLC execution policy.
- [native-migration](.agents/skills/native-migration/SKILL.md): Incremental migration workflow from legacy Elisp to Rust backend based on `todo.md`.
- [native-edit-and-diagnostics](.agents/skills/native-edit-and-diagnostics/SKILL.md): Native edit transactions, shadow buffers, LSP diagnostic freshness tickets, and undo verification.
- [audit-and-review](.agents/skills/audit-and-review/SKILL.md): Milestone review and audit procedures, referencing task audit logs.
- [external-bridges](.agents/skills/external-bridges/SKILL.md): External backend adapters (Codex, Antigravity, Claude, OpenCode) and MCP server integration.
- [native-tools](.agents/skills/native-tools/SKILL.md): Filesystem traversal, execution foundations, process management, grep, and Git queries.
- [native-api-and-catalog](.agents/skills/native-api-and-catalog/SKILL.md): Provider/model discovery, HTTP/SSE streaming, wire caching, and configuration.

## 2. Rules (`.agents/rules/`)
Directory-based and path-scoped rules enforcing architectural contracts and invariants:
- [architecture_principles.md](.agents/rules/architecture_principles.md): Core simplicity and isolation rules.
- [kodlama_standardi.md](.agents/rules/kodlama_standardi.md): Comprehensive Rust core coding standard.
- [architecture-contracts.md](.agents/rules/architecture-contracts.md): Authoritative 8 core boundary contracts.
- [describing.md](.agents/rules/describing.md): Operating logic, modes, protocol firewall invariants.
- [kargu-laws.md](.agents/rules/kargu-laws.md): Fundamental laws, modules, modes, and change discipline (formerly `skills.md`).
- [connection-ownership.md](.agents/rules/connection-ownership.md): Connection and metadata ownership specification.
- [native-edit-ownership.md](.agents/rules/native-edit-ownership.md): Native edit transaction ownership.
- [native-diagnostic-port.md](.agents/rules/native-diagnostic-port.md): Typed native file diagnostic result port.
- [native-receipt-verification.md](.agents/rules/native-receipt-verification.md): File diagnostic verification consumer.
- [native-undo-verification.md](.agents/rules/native-undo-verification.md): Native undo verification identity.
- [native-change-capacity.md](.agents/rules/native-change-capacity.md): Retention debt under capacity pressure.
- [native-history-lifetime.md](.agents/rules/native-history-lifetime.md): Edit metadata lifetime leases.
- [native-edit-handle-epoch.md](.agents/rules/native-edit-handle-epoch.md): Edit handle epoch ownership.
- [native-lifecycle-domain-isolation.md](.agents/rules/native-lifecycle-domain-isolation.md): Lifecycle domain isolation.
- [native-run-reset-debt.md](.agents/rules/native-run-reset-debt.md): Preserving verification debt across resets.
- [native-service-close.md](.agents/rules/native-service-close.md): Edit service closure leases.
- [native-stop-reset-acceptance.md](.agents/rules/native-stop-reset-acceptance.md): Stop, reset, and late edit completion.
- [native-cache-pricing.md](.agents/rules/native-cache-pricing.md): Canonical cache pricing specification.
- [native-conversation-change-summary.md](.agents/rules/native-conversation-change-summary.md): Native conversation change evidence.
- [native-diagnostic-baseline-origin.md](.agents/rules/native-diagnostic-baseline-origin.md): Diagnostic baseline origin compatibility.
- [modularity.md](.agents/rules/modularity.md): Module boundaries and structural slicing.

## 3. Migration Blueprints & Cutover Specifications (Organized under Skills)
Authoritative migration architecture, technical specifications, and phased cutover proofs are organized under their respective workflow skills:
- **Architecture & Roadmap**: [00_MIGRATION_ARCHITECTURE.md](.agents/skills/native-migration/references/00_MIGRATION_ARCHITECTURE.md), [02_MODULE_MIGRATION_MATRIX.md](.agents/skills/native-migration/references/02_MODULE_MIGRATION_MATRIX.md), [04_PHASED_ROADMAP.md](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md), [12_MIGRATION_PROGRESS.md](.agents/skills/native-migration/references/12_MIGRATION_PROGRESS.md), [13_MIGRATION_BASELINE.json](.agents/skills/native-migration/references/13_MIGRATION_BASELINE.json)
- **Rust Core Patterns**: [01_RUST_CORE_PATTERNS.md](.agents/skills/coding-standards/references/01_RUST_CORE_PATTERNS.md), [39_RUST_PATTERN_AUDIT.md](.agents/skills/coding-standards/references/39_RUST_PATTERN_AUDIT.md)
- **External Bridges**: [03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md) (Codex, Antigravity, Claude, OpenCode)
- **Native Tools & Process Supervisor**: Specifications 14–28, 53–58 under [native-tools/references](.agents/skills/native-tools/references/)
- **Native API, Transport & Config**: Specifications 09–11, 29–38, 41–52 under [native-api-and-catalog/references](.agents/skills/native-api-and-catalog/references/)

