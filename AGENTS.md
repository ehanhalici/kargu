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
- [rust-strict-modular-design](.agents/skills/rust-strict-modular-design/SKILL.md): Single-responsibility modules and functions, `pub fn`-only module boundaries, compile-time invariants (newtypes, const-generic bounds, typestate, witness types, sealed traits) and Result-based effect isolation behind ports; with a verified reference crate and a pre-commit AST gate (arch-checker, ratchet baseline) that covers kargu-core.

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
- **Architecture & Roadmap** ([native-migration/references](.agents/skills/native-migration/references/)):
  - [00_MIGRATION_ARCHITECTURE.md](.agents/skills/native-migration/references/00_MIGRATION_ARCHITECTURE.md)
  - [02_MODULE_MIGRATION_MATRIX.md](.agents/skills/native-migration/references/02_MODULE_MIGRATION_MATRIX.md)
  - [04_PHASED_ROADMAP.md](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md)
  - [05_GECIS_1.md](.agents/skills/native-migration/references/05_GECIS_1.md)
  - [06_GECIS_2.md](.agents/skills/native-migration/references/06_GECIS_2.md)
  - [07_GECIS_3.md](.agents/skills/native-migration/references/07_GECIS_3.md)
  - [08_GECIS_4.md](.agents/skills/native-migration/references/08_GECIS_4.md)
  - [12_MIGRATION_PROGRESS.md](.agents/skills/native-migration/references/12_MIGRATION_PROGRESS.md)
  - [13_MIGRATION_BASELINE.json](.agents/skills/native-migration/references/13_MIGRATION_BASELINE.json)
  - [40_DEFAULT_RESILIENCE_CUTOVER.md](.agents/skills/native-migration/references/40_DEFAULT_RESILIENCE_CUTOVER.md)
  - [43_DEFAULT_MODEL_METADATA_CUTOVER.md](.agents/skills/native-migration/references/43_DEFAULT_MODEL_METADATA_CUTOVER.md)
  - [45_SETUP_CONNECTION_CUTOVER.md](.agents/skills/native-migration/references/45_SETUP_CONNECTION_CUTOVER.md)
- **Rust Core Patterns** ([coding-standards/references](.agents/skills/coding-standards/references/)):
  - [01_RUST_CORE_PATTERNS.md](.agents/skills/coding-standards/references/01_RUST_CORE_PATTERNS.md)
  - [39_RUST_PATTERN_AUDIT.md](.agents/skills/coding-standards/references/39_RUST_PATTERN_AUDIT.md)
- **External Bridges** ([external-bridges/references](.agents/skills/external-bridges/references/)):
  - [03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md) (Codex, Antigravity, Claude, OpenCode)
- **Audit & Review Logs** ([audit-and-review/references](.agents/skills/audit-and-review/references/)):
  - [task3-audit-2026-10-29.md](.agents/skills/audit-and-review/references/task3-audit-2026-10-29.md)
  - [migration-review-2026-11-01.md](.agents/skills/audit-and-review/references/migration-review-2026-11-01.md)
- **Native Tools & Process Supervisor** ([native-tools/references](.agents/skills/native-tools/references/)):
  - [14_EXECUTION_FOUNDATIONS.md](.agents/skills/native-tools/references/14_EXECUTION_FOUNDATIONS.md)
  - [15_NATIVE_FIND_FILES.md](.agents/skills/native-tools/references/15_NATIVE_FIND_FILES.md)
  - [16_NATIVE_DIRECTORY_LISTING.md](.agents/skills/native-tools/references/16_NATIVE_DIRECTORY_LISTING.md)
  - [17_UNIX_TOOL_COMPOSITION.md](.agents/skills/native-tools/references/17_UNIX_TOOL_COMPOSITION.md)
  - [18_COMMAND_EXECUTION_BRIDGE.md](.agents/skills/native-tools/references/18_COMMAND_EXECUTION_BRIDGE.md)
  - [19_GNU_LS_ADAPTER.md](.agents/skills/native-tools/references/19_GNU_LS_ADAPTER.md)
  - [20_PERSISTENT_PROCESS_SEMANTICS.md](.agents/skills/native-tools/references/20_PERSISTENT_PROCESS_SEMANTICS.md)
  - [21_PROCESS_JOB_WIRE.md](.agents/skills/native-tools/references/21_PROCESS_JOB_WIRE.md)
  - [22_OWNED_JOB_CLIENT.md](.agents/skills/native-tools/references/22_OWNED_JOB_CLIENT.md)
  - [23_NATIVE_BASH_CUTOVER.md](.agents/skills/native-tools/references/23_NATIVE_BASH_CUTOVER.md)
  - [24_NATIVE_IDLE_POLICY.md](.agents/skills/native-tools/references/24_NATIVE_IDLE_POLICY.md)
  - [25_NATIVE_INTERACTIVE_SESSION.md](.agents/skills/native-tools/references/25_NATIVE_INTERACTIVE_SESSION.md)
  - [26_RECORD_CAPTURE_BUDGET.md](.agents/skills/native-tools/references/26_RECORD_CAPTURE_BUDGET.md)
  - [27_NATIVE_WORKSPACE_GREP.md](.agents/skills/native-tools/references/27_NATIVE_WORKSPACE_GREP.md)
  - [28_NATIVE_GIT_STATUS.md](.agents/skills/native-tools/references/28_NATIVE_GIT_STATUS.md)
  - [53_NATIVE_GIT_READ_QUERIES.md](.agents/skills/native-tools/references/53_NATIVE_GIT_READ_QUERIES.md)
  - [54_NATIVE_FILE_EXCERPTS.md](.agents/skills/native-tools/references/54_NATIVE_FILE_EXCERPTS.md)
  - [55_GIT_CONFIG_ISOLATION_PROOF.md](.agents/skills/native-tools/references/55_GIT_CONFIG_ISOLATION_PROOF.md)
  - [56_NATIVE_GIT_WORKTREE_READS.md](.agents/skills/native-tools/references/56_NATIVE_GIT_WORKTREE_READS.md)
  - [57_NATIVE_SKILLS.md](.agents/skills/native-tools/references/57_NATIVE_SKILLS.md)
  - [58_NATIVE_TOOLS_COMPLETE.md](.agents/skills/native-tools/references/58_NATIVE_TOOLS_COMPLETE.md)
- **Native API, Transport & Config** ([native-api-and-catalog/references](.agents/skills/native-api-and-catalog/references/)):
  - [09_DYNAMIC_CONTEXT_MENTIONS.md](.agents/skills/native-api-and-catalog/references/09_DYNAMIC_CONTEXT_MENTIONS.md)
  - [10_MODEL_CATALOG_AND_REASONING.md](.agents/skills/native-api-and-catalog/references/10_MODEL_CATALOG_AND_REASONING.md)
  - [11_CASCADING_ABORT_AND_REPAIR.md](.agents/skills/native-api-and-catalog/references/11_CASCADING_ABORT_AND_REPAIR.md)
  - [29_NATIVE_PROVIDER_CATALOG.md](.agents/skills/native-api-and-catalog/references/29_NATIVE_PROVIDER_CATALOG.md)
  - [30_NATIVE_API_TRANSPORT.md](.agents/skills/native-api-and-catalog/references/30_NATIVE_API_TRANSPORT.md)
  - [31_NATIVE_WIRE_AND_CACHE.md](.agents/skills/native-api-and-catalog/references/31_NATIVE_WIRE_AND_CACHE.md)
  - [32_NATIVE_REQUEST_POLICY.md](.agents/skills/native-api-and-catalog/references/32_NATIVE_REQUEST_POLICY.md)
  - [33_NATIVE_AUTH_HEADERS.md](.agents/skills/native-api-and-catalog/references/33_NATIVE_AUTH_HEADERS.md)
  - [34_APPLICATION_CLOSE_AND_API_FAIRNESS.md](.agents/skills/native-api-and-catalog/references/34_APPLICATION_CLOSE_AND_API_FAIRNESS.md)
  - [35_EDITOR_NATIVE_APPLICATION_LEASES.md](.agents/skills/native-api-and-catalog/references/35_EDITOR_NATIVE_APPLICATION_LEASES.md)
  - [36_NATIVE_API_BUDGET.md](.agents/skills/native-api-and-catalog/references/36_NATIVE_API_BUDGET.md)
  - [37_NATIVE_RESILIENCE.md](.agents/skills/native-api-and-catalog/references/37_NATIVE_RESILIENCE.md)
  - [38_NATIVE_CIRCUITS.md](.agents/skills/native-api-and-catalog/references/38_NATIVE_CIRCUITS.md)
  - [41_MODEL_METADATA_BOUNDARY_AUDIT.md](.agents/skills/native-api-and-catalog/references/41_MODEL_METADATA_BOUNDARY_AUDIT.md)
  - [42_CONFIG_PROVIDER_DISCOVERY.md](.agents/skills/native-api-and-catalog/references/42_CONFIG_PROVIDER_DISCOVERY.md)
  - [44_ASYNC_CATALOG_CONNECTION.md](.agents/skills/native-api-and-catalog/references/44_ASYNC_CATALOG_CONNECTION.md)
  - [46_NATIVE_CATALOG_TARGET.md](.agents/skills/native-api-and-catalog/references/46_NATIVE_CATALOG_TARGET.md)
  - [47_NATIVE_CHAT_TARGET.md](.agents/skills/native-api-and-catalog/references/47_NATIVE_CHAT_TARGET.md)
  - [48_NATIVE_CONFIG_PARSER.md](.agents/skills/native-api-and-catalog/references/48_NATIVE_CONFIG_PARSER.md)
  - [49_PROVIDER_REPORT_PRIVACY.md](.agents/skills/native-api-and-catalog/references/49_PROVIDER_REPORT_PRIVACY.md)
  - [50_CONFIG_REFRESH_ADMISSION.md](.agents/skills/native-api-and-catalog/references/50_CONFIG_REFRESH_ADMISSION.md)
  - [51_NATIVE_CONFIG_FILE_IO.md](.agents/skills/native-api-and-catalog/references/51_NATIVE_CONFIG_FILE_IO.md)
  - [52_NATIVE_CONFIG_POLICY.md](.agents/skills/native-api-and-catalog/references/52_NATIVE_CONFIG_POLICY.md)

