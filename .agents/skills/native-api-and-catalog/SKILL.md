---
name: native-api-and-catalog
description: Specifications and runbooks for LLM provider discovery, model catalog hydration, HTTP/SSE network transport, wire caching, prompt token budgeting, circuit breakers, and TOML configuration in Kargu. Use when working on API communication or config systems.
---

# Native API Transport, Catalog & Configuration

This skill covers the native network engine, model metadata catalogue, and configuration subsystem in Kargu.

## 1. Subsystem Architecture & Responsibilities

### 1.1 Provider & Model Catalog
- **Discovery**: Resolves models from OpenAI, Anthropic, OpenRouter, Google Gemini, Ollama, LM Studio, etc.
- **Reasoning Models**: Preserves `reasoning_content` and handles thinking token schemas without corrupting standard conversation turns.
- **Provider Filtering**: Only providers with valid credentials or active local endpoints are exposed to the user.

### 1.2 HTTP / SSE Transport & Wire Normalization
- **Asynchronous Wire**: All network I/O executes on Tokio asynchronous pools; the Emacs UI thread is never blocked.
- **Prompt Caching**: Accurately accounts for cache reads and creations without double-charging token budgets.
- **Circuit Breaker**: Detects repeated upstream failures and gracefully opens the circuit to avoid spamming endpoints.

### 1.3 Configuration Management
- **TOML Parsing in Rust**: `~/.config/kargu/config.toml` is parsed, verified, and mapped to domain structs exclusively in Rust.
- **Credential Precedence**: Resolves API keys via environment variables, configuration overrides, and Emacs `auth-source`.

---

## 2. Technical Specifications & References

Detailed architectural contracts, wire schemas, and acceptance tests:
- [09_DYNAMIC_CONTEXT_MENTIONS.md](references/09_DYNAMIC_CONTEXT_MENTIONS.md): Mentions and context attachments
- [10_MODEL_CATALOG_AND_REASONING.md](references/10_MODEL_CATALOG_AND_REASONING.md): Catalog & reasoning tokens
- [11_CASCADING_ABORT_AND_REPAIR.md](references/11_CASCADING_ABORT_AND_REPAIR.md): Cascading aborts & repairs
- [29_NATIVE_PROVIDER_CATALOG.md](references/29_NATIVE_PROVIDER_CATALOG.md): Provider catalog
- [30_NATIVE_API_TRANSPORT.md](references/30_NATIVE_API_TRANSPORT.md): Asynchronous transport
- [31_NATIVE_WIRE_AND_CACHE.md](references/31_NATIVE_WIRE_AND_CACHE.md): Wire framing and caching
- [32_NATIVE_REQUEST_POLICY.md](references/32_NATIVE_REQUEST_POLICY.md): Request policy
- [33_NATIVE_AUTH_HEADERS.md](references/33_NATIVE_AUTH_HEADERS.md): Auth headers
- [34_APPLICATION_CLOSE_AND_API_FAIRNESS.md](references/34_APPLICATION_CLOSE_AND_API_FAIRNESS.md): Application closure
- [35_EDITOR_NATIVE_APPLICATION_LEASES.md](references/35_EDITOR_NATIVE_APPLICATION_LEASES.md): Application leases
- [36_NATIVE_API_BUDGET.md](references/36_NATIVE_API_BUDGET.md): Budget limits
- [37_NATIVE_RESILIENCE.md](references/37_NATIVE_RESILIENCE.md): Resilience and retries
- [38_NATIVE_CIRCUITS.md](references/38_NATIVE_CIRCUITS.md): Circuit breakers
- [41_MODEL_METADATA_BOUNDARY_AUDIT.md](references/41_MODEL_METADATA_BOUNDARY_AUDIT.md): Metadata audit
- [42_CONFIG_PROVIDER_DISCOVERY.md](references/42_CONFIG_PROVIDER_DISCOVERY.md): Discovery mechanisms
- [44_ASYNC_CATALOG_CONNECTION.md](references/44_ASYNC_CATALOG_CONNECTION.md): Async connection port
- [46_NATIVE_CATALOG_TARGET.md](references/46_NATIVE_CATALOG_TARGET.md): Catalog targets
- [47_NATIVE_CHAT_TARGET.md](references/47_NATIVE_CHAT_TARGET.md): Chat targets
- [48_NATIVE_CONFIG_PARSER.md](references/48_NATIVE_CONFIG_PARSER.md): TOML parser
- [49_PROVIDER_REPORT_PRIVACY.md](references/49_PROVIDER_REPORT_PRIVACY.md): Report privacy
- [50_CONFIG_REFRESH_ADMISSION.md](references/50_CONFIG_REFRESH_ADMISSION.md): Refresh admission
- [51_NATIVE_CONFIG_FILE_IO.md](references/51_NATIVE_CONFIG_FILE_IO.md): Config file I/O
- [52_NATIVE_CONFIG_POLICY.md](references/52_NATIVE_CONFIG_POLICY.md): Config policy
