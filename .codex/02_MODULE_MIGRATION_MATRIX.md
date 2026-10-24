# 02. MODÜL GÖÇ MATRİSİ VE DAVRANIŞ ENVANTERİ

Kök yol `kargu/` olarak okunur. Alt aileler yalnız isim sayısını azaltmak için
silinmez. Her aile mevcut public komut/alias/schema/policy ve test fixture'ıyla
eşlenip 04'teki kapıdan geçer. Façade'lar son tüketici geçene kadar kalır.

| Mevcut aile | Nihai sahip | Sözleşme / korunacak davranış |
| --- | --- | --- |
| api.el, api/client, request, prepare, transport, wire, http, sse, stream, response | Rust network + ince Elisp çağrı façade'ı | Wire-family codecs, terminal stream doğrulama; 07/08 |
| api/retry, circuit, cache, catalog, parameters, select | Rust metadata/resilience; Emacs picker | Snapshot, cache scope, tek probe, capability; 01/10 |
| api/tools, tool-calls; tools/registry, execution | Rust registry/execution gate | Public ad, alias, şema, mode/policy, duplicate ID; 01/08 |
| providers.el, providers/registry, catalog; models/service, store; selection.el | Rust | Custom provider, endpoint namespace, discovery/override, selection revision; 10 |
| Yeni uygulama backend/discovery adapter'ları (legacy Elisp karşılığı yok) | Rust; provider picker sunumu Emacs | Codex, Antigravity, Claude Code, OpenCode; API'den ayrı typed seçim, kurulum/uygunluk, stream/cancel/session; 03/06/10 |
| config.el, config/toml, schema, service, connection, worker, key | Hibrit | Rust parse/schema/snapshot; Emacs config UI ve gerektiğinde auth-source/callable credential port; 08 |
| loop.el, loop/machine, tools, heal, compact; state.el, state/store, transitions, selectors | Rust; UI projection Emacs | Single run, typed transitions, bounded healing/compaction; 01/08 |
| application/coordinator, execution, budget, mode, reset | Rust; Emacs mode-preflight adapter | Claim-before-effect, reset/drain, mevcut ask/plan/debug/agent modları |
| async.el; state/hooks; core/observers | Hibrit | Rust structured tasks; Emacs yerel callback/timer/hook ve view lifecycle; 07/11 |
| core.el, core/data, session, custom, group, log; contract/*, json.el | Hibrit | Rust domain/result/accounting; Emacs defcustom/log/DTO sınırları; 01/07 |
| history.el, history/store, protocol, compact, repair | Rust | Typed bloklar, call/result kimliği, journal ve onarım; 08/11 |
| chat/session/*, chat/session.el | Hibrit | Rust storage/validation/import; Emacs restore/view/owner; 06/08 |
| permission.el, permission/policy, guards, bash, execute | Rust gate + Emacs execution revalidation | Tek approval ledger, path/egress, shell risk; 06/08 |
| confirm.el, ui/confirm.el | Hibrit | Rust karar/expiry; Emacs cancellable presenter; missing UI reject |
| tools/bash, bash/jobs, process, process/session | Rust | Interactive stdin, output cursor, EOF, polling, owner cancel/reap; 08/11 |
| tools/git, search, fs.el, files.el, files/async, worker | Rust + canlı buffer adapter | Path guard, bounded read/search, dirty/narrowed file windows; 08/09 |
| tools/webfetch; net/address, resolve | Rust | Redirect/DNS/TLS/SSRF/body limit ve explicit local endpoint policy; 08 |
| tools/deps, toolchain, skill; prompt.el, prompt/default.txt | Hibrit | Rust template/skill/discovery/OS probe; Emacs paket/major-mode capability; mevcut öncelik ve izinler |
| tools/diff, diff/track, stage, context, review; edit.el | Hibrit | Rust proposal/hunk/review; Emacs buffer/undo/save transaction; 06 |
| tools/lsp.el, lsp/* | Hibrit | Emacs revision/publication/Xref; Rust aggregation ve araç şeması; 05 |
| tools/dape.el, dape/* | Hibrit | Emacs connection/stop/thread/frame/readiness; Rust policy/scheduling; 05 |
| languages.el, languages/* | Emacs + metadata export | Major-mode, Eglot/Dape config, dil bazlı startup ve toolchain |
| chat.el, chat/render, header, transcript, prompt, stream, routing | Emacs + Rust stream/accounting | Session buffer map, draft/Markdown/scroll; 06/07 |
| chat/select, tune, complete, attach | Hibrit | Emacs picker/completion/live context; Rust selection/effort/parser; 09/10 |
| plan.el, plan/store, context, dispatch; chat/plan, plan/buffer | Hibrit | Rust domain/claim; Emacs review artifact ve lifecycle; 06 |
| ui.el, ui/notify, transient, loop/ui; kargu.el | Emacs composition | Optional UI, public commands/keymap/autoload, start/stop/core binary yönetimi |

Eski matristeki `core/redact.el` mevcut bir dosya değildir; logging/credential
hijyeni mevcut core/log ve network/config sınırlarından taşınır.

Uygulamaya başlamadan makine üretimli envanter kaydedilir: her tracked Elisp
kaynak -> bu ailelerden biri; her tool canonical/alias/schema/policy -> Rust
definition veya explicit kaldırma kararı; her public komut -> uyumluluk façade'ı.
Yeni envanter, eksik modülleri gizlemek için test baseline'ını yeniden üretmez.

2026-10-24 uygulama durumu: `find_files` eşdeğer Rust/IPC testlerinden sonra
taşındı; `tools/search.el` içindeki glob parser, formatter ve fd/rg/Elisp glob
engine'leri silindi. Public araç/alias/schema ve eski tool gate façade'sı kalır.
Sonraki dilimde `list_files`/`ls`/`dir` Rust'a taşındı ve eski senkron Elisp
directory scanner silindi; ilk dilim 16'dadır. Güncel listing sözleşmesi
özel native scanner değil GNU ls adapter'ıdır (19).
20–25 sonrasında Bash ve interactive process/session OS engine'leri Rust job
portuna bağlandı; Elisp spawn/signal/idle timer kodları silindi. Editor view ve
source/runtime revalidation adapter'ları korunur. Shared process.el, diğer
Git/diff/webfetch tüketicileri taşınmadığı için henüz kaldırılmaz.
26–27 ardından `workspace_grep` rg/GNU grep adapter'ına bağlandı; eski Elisp
grep argv/runner/formatter engine'i kaldırıldı. 28'de `git_status` da native Git
adapter'ına bağlandı; eski status parser/runner/formatter kaldırıldı. Diğer Git
komutları, `fs.el` tüketicileri ve kalan
aileler henüz taşınmış sayılmaz. Ayrıntı: 15_NATIVE_FIND_FILES.md.

Davranış kanıtları: architecture-contracts.md, docs/modularity.md,
docs/connection-ownership.md, tests/run-tests.el ve proof/README.md.
Bunlar mevcut/amaçlanan sözleşmeleri anlatır; her özellik tamamlanmış kabul
edilmez. todo.md'deki açık işler de taşınır ve Rust'a geçince kendiliğinden kapanmaz.
