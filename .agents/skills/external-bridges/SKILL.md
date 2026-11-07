---
name: external-bridges
description: Specifications, protocols, and integration topologies for external agent backends (Codex, Antigravity, Claude Code, OpenCode) and MCP server communication in Kargu. Use when implementing, debugging, or auditing external backend adapters.
---

# External Bridges & Agent Adapters

This skill defines the integration requirements, headless execution protocols, and session mappings for external agent runtimes and the Model Context Protocol (MCP) in Kargu.

## 1. Supported Backend Ecosystem

Kargu supports four primary external agent adapters alongside its internal native loop:
1. **Google Antigravity**: Discovers workspace intelligence, custom skills (`.agents/skills/`), rules (`.agents/rules/`), and MCP servers.
2. **OpenAI Codex**: Uses `AGENTS.md` at root and standard CLI/app-server topologies.
3. **Anthropic Claude Code**: Headless mode protocols and stream management.
4. **OpenCode**: Modular runtime interop.

---

## 2. Architecture & Invariants

- **Single Active Run (ARCH-01)**: An external backend session is bound to an owned `kargu-application` instance. Multiple concurrent loops are forbidden.
- **Fail-Closed Security**: External adapters inherit the strict approval gates of Kargu. Destructive operations require explicit confirmation.
- **Protocol Normalization**: External thread and turn identifiers are mapped deterministically to native `SessionId` and `RunId` handles.

---

## 3. Specifications & Reference Architecture

For detailed cutover proofs, API parameters, and official headless CLI integration notes, see:
- [03_EXTERNAL_BRIDGES.md](references/03_EXTERNAL_BRIDGES.md): Comprehensive external bridge specifications for Codex, Antigravity, Claude, and OpenCode.
