# Rust geçişi: uygulama günlüğü

## 2026-10-27 — Todo 2 tamamen kapandı: Git mutations, probes, webfetch ve son bridge audit

Kullanıcı todo 2'nin tamamlanmasını istedi. Kalan mutation araçları closed
`git/mutate` / `git_mutation` ile shared native approval/process portuna bağlandı.
Layout→scope evidence→object resolution→review→single write zinciri kullanılır;
index/HEAD/ref/config/selected path revision değişimi stale approval'ı reddeder.
Unstage verified unborn/immutable HEAD arasında bir kez seçer, fallback yoktur.
Hook/signing arbitrary-code approval ve actual descendant drain testli; issued
cancel/frame/output/decode belirsizliği replay edilmez, outcome_unknown taşır.

`workspace/probe` / `workspace_probe` executable metadata/access ve bounded
project/toolchain seçimini yürütmesiz yapar. Declarative profile DSL, native
JS/Java/Elisp kararları ve owned project→connection→skills preparation bağlandı.
Eksik mandatory CLI model/connection/unsent-history öncesi reddedilir. Passive
buffer/session/root/settings observation detached ve unknown-aware'dir. Eski
Elisp filesystem/executable/script-choice motorları silindi.

`workspace/webfetch` / `workspace_webfetch` aynı actual-join read pool'unda native
DNS/numeric policy, per-hop address pin, no proxy/manual redirects, bounded strict
UTF-8 body/deadline/cancellation yürütür. cfg(test) fixture dışında local egress
bypass yoktur. Eski curl/getent/Emacs resolver, Elisp policy/HTTP/parser silindi.
OS NSS/FS cancellation cooperative'dir; worker slotu actual join'e kadar kalır.

Job service source buffer/session/project'a bağlandı; default service/global job,
foreground/counter aynaları silindi. Same-project/reused-session-label foreign
chat ID isolation gerçek native testlidir. Legacy process helper yalnız diff
Git-apply (todo 3), Dape context/preflight/source (todo 4), session listing worker
(todo 7) için kalır; native tool fallback'i değildir. Ayrıntı ve tüm kabul/sınırlar:
[58_NATIVE_TOOLS_COMPLETE.md](58_NATIVE_TOOLS_COMPLETE.md).

Final **1271/1271 full source ERT**, 0 unexpected/skip, **163.740942 s**,
**08:09:15 +0300**. **344 native + 24 compile-fail = 368** locked test / 36 suite;
normal locked build, fmt/strict Clippy ve 42 Elisp Werror bytecompile/production
checkdoc temiz. Message whitespace regression eski core'da red, sonra **36/36 Git
ERT** ve final full suite green; hook/signer actual drain native corpus'ta testli.
Proxy env altında controlled HTTP corpus **6/6** geçti.

Exhaustive application TLC project→connection→skills **17545/4624**, queue0,
depth37; approval **8194/1536** depth11; process **535/179** depth9; connection
**602836/101708** depth23; transport **1810/693** depth14; hepsi hata/queued state
olmadan bitti. Bounded soyut model kanıtıdır; OS/Git/network formal refinement
veya tüm 01 mimari uyum sertifikası değildir. Environment OpenPGP autoload uyarısı
önceden vardı; byte compiler/checkdoc yeni uyarı üretmedi.

Kullanıcı07/shell.nix korundu; canlı Emacs reload, hesap/credential migration,
kurulum, merge/push yoktur. Todo 2 üstü ve bütün alt maddeleri [x]; diğer todo
grupları açık kalır.

## 2026-10-27 — Todo 2: native skill discovery/read ve owned run preparation

`workspace/skills` / `workspace_skills` ortak actual-join read havuzuna bağlandı.
Editor explicit project/user grant ve callback/owner adapter'ıdır; no-follow
metadata-first scan, pinned regular UTF-8 capture, string frontmatter ve render
Rust'tadır. Tool-capable run connection→skill preparation bekler; Stop/owner/
root/session/settings/deadline ve newest-intent guard'ları eski metni yayınlatmaz.
Passive catalog/list yalnız buffer/session last-completed observation okur;
named load native'den yeniden okur. Eski Elisp scanner/parser/read/render ve
TTL global cache silindi. Loop runtime autoload ile modül sınırlarını korur.
Tool-free prompt skill rehberi içermez. Ayrıntı [57_NATIVE_SKILLS.md](57_NATIVE_SKILLS.md).

Final **1286/1286 source ERT**, 0 unexpected, **152.532591 s**, **02:40:09 +0300**;
**324 native + 24 compile-fail = 348** locked test / 34 suite temiz. Locked build,
fmt/strict Clippy ve değişen Elisp Werror bytecompile/production checkdoc temiz.
Application TLC connection→skills barrier'larıyla **13099/3481**, queue0, depth33;
RunningPrepared/PreparationOrder temiz. Connection **602836/101708**, queue0,
depth22; transport **1810/693**, queue0, depth12 temiz. Bounded soyut modellerdir;
concrete FS/parser/worker formal refinement veya tam Rust göçü iddiası yoktur.

Todo 2 skill alt işi [x]; Git mutations/toolchain/webfetch/son bridge audit'i
ve diğer göç grupları açık. Kullanıcı07/shell.nix korundu. Testler yalnız geçici
project/user root ve synthetic config kullanır; user skill dizini/canlı hesap,
Emacs reload/kurulum/credential migration/merge/push yoktur.

## 2026-10-26 — Todo 2: native diff/blame ve status clean-filter güvenlik düzeltmesi

`f2ef8e6` proof'u native consumer'a bağlandı: git_worktree_read cap'li owned
layout/config→actual drain→final query; original executable config yerine
private safe snapshot. Status'ın same-size clean-filter açığı da kapandı.
SHA-1/SHA-256 × files/reftable × main/linked actual native pipe; late unsafe config,
TERM-ignoring child/reap/reservation, output/invalid/foreign/missing kabulü geçti.
Prepared/Running resource typestate, join edilen Finalizing/Discarding cleanup;
eski Elisp diff/blame argv/range/report silindi. Submodule kapsamı açık text+
coverage ile dışarıda; unsupported layout/symlink HEAD unsafe fallback yapmaz.
Shared Peer artık EOF/graceful drain öncesi core'u öldürmez. Ayrıntı .codex/56.

Final 1274/1274 source ERT, 0 unexpected, 155.077287 s (23:35:10); 315 native +24
compile-fail =339 locked test. Build/fmt/strict Clippy ve dört Elisp Werror/checkdoc
temiz; mevcut bounded TLC regresyonları temiz, Git/FS formal refinement iddiası yok.
Todo 2 read-only Git alt grubu [x]; mutations/skill/toolchain/webfetch ve final bridge
audit açık. Kullanıcı07/shell.nix korundu; canlı reload/credential/kurulum/push yok.

## 2026-10-26 — Todo 2: read_file disk/presentation ve LSP consumer cutover

`workspace/readFile` / `workspace_read_file` kapalı typed domain'i ortak owned
ReadTools pool'una bağlandı. Regular-file fd capture config reader ile paylaşıldı;
byte/scan/output bounds, revision recheck, strict UTF-8/BOM UTF-16, CRLF, binary
probe ve numbered/unknown-total presentation native. Elisp yalnız bounded raw
live snapshot/tick ve owner interop'u taşır. Gecikmiş disk sonucuna yeni unsaved
buffer üstün gelir; değişmiş live revision ve foreign/stale owner yayınlanmaz.
Son sync consumer read_symbol async'e geçti; eski file/diff sync API, disk reader,
numbered formatter ve model worker yolu silindi. Edit snapshot / Dape source
tüketicileri kendi todo 3/4 işleri için kaldı. Ayrıntı .codex/54.

Final 1272/1272 source ERT, 0 unexpected, 148.064004 s (22:06:56); 305 native +
24 compile-fail =329 locked test. Normal locked build/fmt/strict Clippy, 14 değişen
Elisp dosyasında Werror bytecompile/checkdoc temiz. Mevcut connection/transport
bounded TLC regresyonları temiz; file/OS formal refinement iddiası yoktur.
Read_file alt işi [x]; todo 2 üst grubu ve diğer aileler açık. Kullanıcı07/shell.nix
korundu; canlı Emacs reload, gerçek kullanıcı dosyası/credential mutation veya
kurulum/uzak API/push yoktur.

## 2026-10-26 — Todo 2: native Git log/branch/stash ve ortak read ownership

`d27e8b9` ile todo 2 gerçek tüketici dilimlerine ayrıldı. `git_log`,
`git_branches`, `git_stashes` closed `git/read`/`git_read` portuyla mevcut native
ExecutionGate ve PGID/process supervisor'a bağlandı. Eski Elisp log/list argv ve
empty-report motorları silindi; mutation/diff/blame tüketicileri nedeniyle genel
Git runner kaldı. `workspace/git/repository.rs` status ve query'nin aynı root,
worktree, executable/env, complete-output ve RunSettings hazırlığını paylaşır;
Git motoru/parser'ı yazılmadı. Ayrıntı .codex/53.

Literal/deleted/missing path, typed CommitLimit, descriptor-bound .git + target,
complete UTF-8/captured byte/IPC sınırları; no-pager/no-signature/no-lazy-fetch
politikası gerçek Git ile testlendi. Unknown-field fixture serde unit variant'ın
fazla alanları kabul ettiğini yakaladı; boş struct variant ile kapandı. 70 KiB
subject testi adapter'ın genel 64 KiB command prefix'e düşmediğini doğrular.
Origin buffer/session/application, DTO capture ve cleanup ortak read portunda
sertleştirildi; closed/expired parent ve startup/cevap sonrası delayed timer
yarışları core/RPC/başarı yayını başlamadan reddedilir.

Ek açık alt iş: gerçek positive-control, `git diff --no-ext-diff --no-textconv`
çağrısının `.gitattributes` clean filtresiyle executable çalıştırabildiğini gösterdi.
Bu nedenle native read enum/registry'ye diff/blame eklenmedi; config/filter
snapshot ve doğru execution sınıfı kurulmadan SafeReadOnly yetkisi verilmez.
Fake-signed commit + GPG marker positive-control'ü signature engelini de sınar.

Final **1274/1274 source ERT**, 0 unexpected, **148.078585 s**, **20:35:56**;
**298 native + 24 compile-fail = 322** locked test / 32 suite temiz. Locked normal
build/fmt/strict Clippy ve beş değişen Elisp dosyasında Werror bytecompile/checkdoc
temiz; elc yalnız task-specific /tmp dizinlerinde. Kayıtlar
`/tmp/kargu-git-queries-{verified-source-ert,native-verified,build-verified,
clippy-verified,bytecompile-verified,checkdoc}.log` dosyalarında. Connection TLC
**602836 / 101708**, queue 0, depth 22 (**20:33:28**); transport **1810 / 693**,
queue 0, depth 13 (**20:33:29**) temiz. Bunlar bounded regresyon; somut Git/OS
refinement veya tüm 01 uyumluluğunun formal ispatı değildir.

Todo 2 üst grup açık; üç Git tüketicisi ve ortak read lifecycle alt işleri `[x]`.
read_file/diff/blame/mutation/skill/toolchain/webfetch ve son global bridge cleanup
açık kalır. Kullanıcı 07/shell.nix değişiklikleri korunur; canlı Emacs reload,
gerçek kullanıcı repo/credential mutation, upstream/login/kurulum veya push yoktur.

## 2026-10-26 — Todo 1 tamamen kapandı: native config authority ve gerçek consumer cutover

`ff96691` typed native temelinden sonra gerçek config/connection/setup/catalog ve
provider picker `configuration_policy` portuna geçti. Application actor tek
publication/revision writer; Elisp yalnız committed private DTO gözlemi, UI niyeti
ve owned credential interop taşır. Elisp config publication/revision increment,
credential/env/endpoint precedence ve eligibility/default-selection motorları
silindi; eski parser/file reader zaten kaldırılmıştı. Memory-only UI reader'da
gizli RPC/env/file IO veya credential unlock yoktur. `kargu-set-provider` async
task/optional Result callback sözleşmesine geçti; UI modeli native ACK'ten sonra
seçer. Current README ve connection ownership belgesi güncellendi; ayrıntı .codex/52.

Expiring owner/session ticket ve exact-revision resolve/select; geç prepare
acquisition abort; lost commit ACK'te rollback/retry yerine fail-closed eski
receipt ve explicit refresh reconciliation; aynı epoch'ta replaced session ret
testlendi. Source identity artık başka session'ın seçimini revision değişikliği
saymaz; count/length framing collection ambiguity'sini engeller. Ortam/options
ilk yield öncesi bounded private capture'dır; yalnız native-requested env değerleri
IPC'ye gider, capture completion/cancel'da temizlenir. Profile -> ReadyProfile
consuming typed sınırı endpoint/model uygunluğunu credential interop'tan önce
kurar; domain içinde JSON alanları tekrar okunup karar üretilmez.

Full source **1268/1268 ERT**, 0 unexpected, **147.335395 s**, **19:54:29
Europe/Istanbul** geçti (`/tmp/kargu-policy-verified-source-ert.log`). Altı yeni
authority regresyonu ayrıca geçti (`/tmp/kargu-policy-authority-verified.log`).
**291 native + 24 compile-fail = 315** locked test / 31 suite temiz
(`/tmp/kargu-policy-cutover-native-all.log`); locked normal build, fmt ve strict
Clippy sıfır uyarı (`...-final-build.log`, `...-cutover-clippy.log`). Değişen
**26 Elisp** üretim/test dosyasında Werror bytecompile/checkdoc temiz
(`/tmp/kargu-policy-bytecompile-verified.log`, `...-checkdoc-verified.log`);
elc yalnız task-specific /tmp dizinlerinde. Connection TLC **602836 generated /
101708 distinct**, queue 0, depth 22 (**12:50:48**); transport **1810 / 693**,
queue 0, depth 13 (**12:50:49**) temiz. Bunlar bounded lifecycle regresyonudur;
somut config actor refinement veya tüm 01 standartlarının formal ispatı değildir.

Todo 1 ve alt kutuları `[x]`; todo 2 ve diğer göç/G03/G05 işleri açık kalır.
Auth-source/callable worker editor interop olarak gereklidir; genel process
PGID/drain ve log-egress denetimleri bu dar cutover ile kapatılmaz. IPC/JSON/GC
kopyalarında fiziksel erasure garantisi yoktur. Kullanıcının 07/shell.nix
değişiklikleri korunur; canlı Emacs reload, gerçek credential dosyalarına erişim,
hesap/ücretli upstream, kurulum, credential migration, merge/push yapılmadı.

## 2026-10-26 — Gerçek config dosya okumasının native tüketici geçişi

Candidate selection, bounded regular-file capture ve parser/digest aynı
`configuration/read` işinde Rust'a geçti. Modüler `configuration/read` domain/
file/entry katmanları mevcut parser'ı ve dört slotlu read worker havuzunu kullanır.
Connection epoch-bound typed completion actor'den yayınlanır; editor config
service tek publication/revision writer'ı olarak kalır. Native config actor/
authority ve env/keyless/credential precedence/provider/model seçim politikaları
todo 1'de açık. Yeni framework/subprocess veya ikinci parser yoktur.

Root-anchored no-follow fd walk + pinned regular inode/read descriptor, bounded
UTF-8, before/after file revision, late owner/cancel/deadline ve gerçek join'de
slot release kontrolleri eklendi. Linux/procfs bağımlılığı açıktır. Dosya IO
cooperative'dir; kernel-blocked syscall hard interruption garantisi verilmez.
Ham source artık editor child/argv/IPC'ye taşınmaz; Zeroizing source/chunk ve
generic Debug/Serialize'sız private editor handoff korunur. Parsed config key'leri
mevcut private editor projection'a girer; fiziksel erasure iddiası yoktur.

Gerçek refresh native porta bağlandıktan sonra Elisp file script/decoder/loaded
handoff/parse bridge ve file-only stdout override silindi. Credential interop
worker son tüketicileri nedeniyle kaldı. Cold absent explicit refresh core
başlatır; passive UI getter sıfır IO/RPC'dir. Missing core/capability veya ilk
mevcut invalid/unreadable dosya last-good publication'ı temizlemez. Ayrıntı .codex/51.

Gerçek provider picker testi `~/.emacs.d` fallback spelling'ini yakaladı:
path editor capture sınırında genişletildi, native absolute-path kuralı esnetilmedi.
İlk full ERT'de tek callback tutan metadata startup test double'ı kırıldı; iki
gerçek startup waiter'ını koruyacak şekilde uyarlandı. Exact captured metadata
revision assertion'ları ve üretim hazırlık yolu aynı kaldı.

Final **1261/1261 full source ERT**, 0 unexpected, **137.224415 s**, **09:50:38
Europe/Istanbul** geçti (`/tmp/kargu-config-read-verified-source-ert.log`).
**280 native + 20 compile-fail = 300** test, locked build/fmt ve strict Clippy
temiz (`/tmp/kargu-config-read-native-verified.log`, `...-clippy-verified.log`).
Değişen dokuz Elisp üretim/test dosyasında Werror bytecompile/checkdoc temiz;
elc yalnız task-specific /tmp dizinlerine çıktı. Connection TLC **602836 generated
/ 101708 distinct**, queue 0, depth 22 (**09:42:10**); transport **1810 / 693**,
queue 0, depth 13 (**09:42:11**) temiz. Mevcut bounded lifecycle modelleridir;
concrete filesystem refinement veya tüm 01 uyumluluk ispatı sayılmaz.

Todo 1'de native file IO alt işi `[x]`, kısmi üst grup açık. Kullanıcının
07/shell.nix değişiklikleri korunur; canlı Emacs reload, hesap/ücretli upstream,
kurulum, credential migration, merge/push yoktur.

## 2026-10-26 — Config refresh admission/generation ve sabit deadline

Native parser concurrency incelemesinde bulunan race kapandı: kapalı parent
altında çağrılan refresh IO başlatmasa da generation'ı artırıp başka canlı
refresh'in cevabını stale saydırabiliyordu. Generation artık yalnız admitted,
canlı root için ayrılır; inactive owner task/timer cleanup'ı hemen yapılır.
Mutlak parent deadline geçmişse timer dispatch beklenmeden ret verilir;
worker/core/generation başlamaz. `timeout=0` ile dosya reader deadline'ını
kaldırma yolu da kapandı: invalid/nonpositive default bound'a döner, büyük
değer uzatamaz, kısa pozitif ve parent deadline kazanır.

Üç yeni ERT gerçek native parse reply'ı bekleterek eski canlı publication'ın
korunmasını, sıfır admission yan etkisini, expired parent error'ını ve timeout
matrisini denetler. İlk regresyon eski kodda generation `1 -> 2` ile kırıldı.
**1260/1260 full source ERT**, 0 unexpected, **137.91 s**, **08:32:36
Europe/Istanbul** geçti. İki değişen Elisp Werror bytecompile/checkdoc temiz;
elc yalnız task-specific /tmp dizininde. Connection TLC **602836 / 101708**,
queue 0, depth 22; transport **1810 / 693**, queue 0, depth 13 ile **08:30:42**'de
temiz. Bunlar bounded lifecycle regression'ıdır; somut admission/refinement
veya tüm 01 ispatı değildir. Rust değişmedi; `0fc7cf6` tabanındaki 274 native +
18 compile-fail/fmt/Clippy kanıtı korunur. Ayrıntı .codex/50'de.

Todo 1'in ek admission alt işi `[x]`; native IO/config publication/precedence/
env/keyless/selection üst işi açık. Kullanıcı 01/07/shell.nix ve gerçek config/
credential dosyaları korunur; uzak API/hesap, kurulum, merge/push veya canlı
Emacs reload yoktur.

## 2026-10-26 — Provider switch endpoint/query log sızıntısının kapatılması

Native parser cutover'ında bulunan todo 1 güvenlik alt işi kapandı:
`kargu-set-provider` artık tam API-base'i log/echo message'a yazmaz ve raporlama
için endpoint'i okumaz. Provider/model/no-model seçimi, endpoint/config ve
prefetch hedefi aynı kalır. Yeni URL redaction/parser engine eklenmedi.

Sentetik query key/tenant regresyonu eski kodda endpoint okumasında kırıldı,
düzeltmeden sonra geçti. Seçim açık/kapalı model dalında gerçek fonksiyondan
geçer; doğru prefetch hedefi offline stub ile sayılır, gerçek upstream yoktur.
**1257/1257 full source ERT**, 0 unexpected, **139.06 s**, **08:25:10
Europe/Istanbul** geçti. İki değişen Elisp Werror bytecompile/checkdoc temiz,
elc yalnız task-specific /tmp dizininde. Rust kaynağı değişmedi; önceki
`0fc7cf6` native parser tabanındaki 274 native + 18 compile-fail/fmt/Clippy
kanıtları yeni Rust özelliği diye sunulmaz. Ayrıntı .codex/49'da.

Native file IO/publication/precedence/env/keyless/provider/model selection ve
genel log-egress kabulü açık; bu dar düzeltme onları kapatmaz. Kullanıcı
01/07/shell.nix ve gerçek config/credential dosyaları korunur; kurulum, uzak
API/hesap turu, canlı Emacs reload, merge/push yoktur.

## 2026-10-26 — Native TOML/schema/legacy-import tüketici geçişi

Gerçek config refresh artık `configuration/parse` portunu kullanır. Native
`configuration/{mod,domain,document}.rs` typed/Zeroizing source, closed schema ve
review enum, legacy import, digest ve payload-free line diagnostics sahibidir.
221 satırlık Elisp `config/toml.el`, ilgili require'lar ve parser apply helper'ı
silindi; UI review mode yalnız başarılı publication'da uyarlanır. TOML engine
yeniden yazılmadı; locked toml crate'inin parse/serde/std feature'ları kullanılır.

Eski parser'ın scalar `provider` + `[provider.NAME]` uyumu, standard TOML öncesi
dar header spelling normalize ile korundu. Değerler/satır sınırları değişmez,
digest orijinal source'tan gelir. Boş key/model fallback, sıralı provider ve
quoting/Unicode/arrays korunur; malformed schema partial yayınlanmaz.

Source 64 KiB, provider 512, provider models 4096, projection 512 KiB ile bounded.
Private source/text'e genel Serialize/Debug yoktur; private editor credential
handoff'u açıkça ayrıdır, IPC/GC için fiziksel erasure iddiası yoktur. Source'un
Serialize/Debug olmayışı iki compile-fail fixture ile korunur. Native host saf
epoch-bound parse sırasında IO/app/session/config actor yaratmaz; generation
editor ordering echo'sudur, native config authority değildir.

Editor root deadline file child + startup + parser'ı kapsar; source ilk yield
öncesi ayrılır ve task cleanup'ta silinir. Timer henüz dispatch edilmemiş olsa
bile mutlak parser deadline geçtiyse publication reddedilir. Stale generation,
iki application, cancel, supersession, lost lease, malformed reply, missing
capability, source mutation, absent file ve kapalı parent testlidir.

Soğuk setup fixture'ı artık her seferinde yeni core açar: shared bridge'in bir
standalone read-service application/session bootstrap'ını, editor application's
native lease acquisition'ından ayırır. Bir readonly parse, sıfır editor lease/
model/metadata/HTTP ve credential cleanup denetlenir; warm core'un eksik cold
startup assertion'ını gizlemesine izin verilmez. .codex/48 ayrıntıları içerir.

File candidate/IO ve publication service hâlâ editor portudur; native config
authority/env/keyless/credential/provider/model seçim işi açık. Yeni bulgu:
provider switch tam API-base/query'yi log/UI'a yazabiliyor; sentetik secret
regresyonuyla kapatılacak ayrı alt iş todo 1'e eklendi. Kullanıcının 01/07/
shell.nix değişiklikleri korunur; gerçek kullanıcı config/credential taşıma,
uzak API/hesap turu, uygulama kurulumu, merge/push veya canlı Emacs reload yoktur.

Final kaynak **1256/1256 full source ERT**, 0 unexpected, **140.65 s**,
**08:21:18 Europe/Istanbul** geçti. Önceki warm-start 1256 taraması da geçti;
son sürüm ayrıca zorunlu cold startup ve mutlak deadline regresyonunu içerir.
Kesilen ara tarama başarı sayılmadı. **274 native + 18 compile-fail**, locked
build, fmt, strict all-targets Clippy temiz. Sekiz üretim + dört test Elisp
Werror bytecompile/checkdoc temiz; kaynakta elc yoktur. Connection TLC
**602836 / 101708**, queue 0, depth 22, 01:27:37; transport **1810 / 693**, queue 0,
depth 13, 01:27:38'de temiz. Bounded regression'dır; somut yeni parse/publication
refinement'ı veya tüm 01 uyumluluk sertifikası değildir.

## 2026-10-26 — Ham API-base ve native sohbet hedefi tüketici geçişi

Önceki dilimde açılan upstream query kaybı kapatıldı. `kargu--api-base` artık
ham spelling'i korur; tüm URL sonunu kırpan `kargu--strip-trailing-slashes`
silindi. Ham base üstüne chat path concat eden `kargu-api-chat-url` da silindi;
normal client yalnız base + chat intent taşır. Path türetme Rust wire katmanında
özel alanlı bounded/serde-TryFrom `ChatPath` ve kapalı POST-only `RequestTarget`
ile yapılır. Yalnız URL path değişir; origin/query/encoded değerler korunur.
Final endpoint continuation ve HTTP authority capture'ından önce oluşturulur;
immutable request retry'larda aynı hedefi taşır, path tekrar eklenmez.

Normal send `api_chat_target` capability'si ister; eski core owner startup/HTTP
öncesi reddedilir, Elisp fallback yoktur. Explicit low-level URL istekleri Exact
semantiğinde, katalog GET önceki native target/auth + epoch pinning portunda
kalır. Yeni actor/senkron sorgu/config writer/IO engine veya dependency yoktur.

Üç native test packaged/default/custom path, encoded base path/query, malformed
path/profile ve final uzunluk sınırını denetler. Dört ERT gerçek geçici TOML
refresh + mock'lanmamış base reader + native port + loopback GET/OpenAPI/Anthropic
POST zincirini, old-core rejection/cleanup ve silinen helper'ları kapsar. Mevcut
gerçek retry fixture'ı query'li base ile güçlendirildi; config/wire sonradan
değişse bile iki attempt ilk hedef/key/body'yi korur. Ayrıntılar .codex/47'de.

**1249/1249 full source ERT**, 0 unexpected, **137.84 s**, **01:06:43
Europe/Istanbul** geçti. **269 native + 16 compile-fail**, fmt, locked build,
strict all-targets Clippy temiz. Beş üretim + üç test dosyası Werror bytecompile/
checkdoc temiz; elc yalnız task-specific /tmp dizininde. Mevcut connection TLC
**602836 / 101708**, queue 0, depth 22; transport **1810 / 693**, queue 0, depth 12
ile 01:04:27/28'de hatasızdır. Bunlar bounded lifecycle regression'ıdır; yeni URL
policy/refinement veya tüm 01 uyumluluk ispatı değildir.

Todo'da iki URL consumer alt işi `[x]`; native config/schema/precedence/env/keyless,
genel run/history ve dört application backend'i açık. Kullanıcının 01/07/shell.nix
değişiklikleri korunur; kurulum, gerçek uzak API/hesap/CLI turu, credential taşıma,
merge/push veya canlı Emacs/core reload yapılmadı.

## 2026-10-26 — Native katalog URL/public-auth policy consumer cutover

Katalog hedefi artık `providers/catalog_target` typed Rust domain'inde çözülür.
Özel alanlı CapturedApiBase/ModelsPath/CompatibleSuffix/ConfigurationRevision,
serde/TryFrom, closed auth enum ve consuming resolve(self) kullanılır.
Global ready host'taki epoch-bound `provider/catalogTarget` salt okunurdur:
IO/credential beklemez, app/session/config/model state'i yaratmaz veya değiştirmez.
UI revision echo'su native config authority değildir. Provider raw registry
facts'ı yalnız DTO'dur; Elisp URL/public/native-path karar fonksiyonları silindi.

Küçük bounded/cancellable `bridge/catalog.el` portu eklendi. Intent DTO'su ilk
startup yield'inden önce ayrılır. Config/base/session/known native lease guard'ı
credential öncesi tekrar kontrol edilir. GET hedefi hesaplayan connection'a
pinlidir; kayıp/değişmiş epoch'ta ensure/reconnect/rebinding veya legacy replay
yoktur. Missing capability credential veya application startup'tan önce reddeder.
Kapalı parent'la çağrılan port startup başlatmaz. Credential interop, auth/header
assembly, HTTP ve metadata publication mevcut tek port/actor'lerinde kalır.

String concat'ın query içine path ekleme hatası giderildi: native URL path'i
değişir, query korunur. Public comparison query sonundaki slash'ı yutmaz; custom
base derived URL'si public endpoint'le aynı olsa bile provider-auth dalındadır.
Kalan `config/key.el` raw trailing-slash base selector'ı native'den önce query
sonunu hâlâ değiştirebilir; somut takip alt işi todo 1'e eklendi. Target cutover
ve query/path düzeltmesi `[x]`; genel native config/base/precedence üst işi açık.

7 yeni native policy/host + 9 yeni ERT fixture eklendi. Eski callback fixture'ları
yalnız test helper'ında gerçek native target portunu açıkça bekler; engine mock'u,
production busy wait, module baseline genişletme veya eski assert silerek geçiş
yoktur. Yeni native target/URI facts gerçek pipe ve loopback GET ile doğrulanır.
Detay .codex/46'da. Final **1245/1245 full source ERT**, 0 unexpected, **137.00 s**,
**00:51:37 Europe/Istanbul** geçti. Önceki 1243/1244 taramaları da geçti; son
capture/closed-parent fixture'ları sonrası kaynak yeniden tamamen tarandı.
**266 native + 16 compile-fail**, fmt, locked build, strict all-targets Clippy
temiz. Dört üretim Elisp, test helper ve yeni test Werror bytecompile/checkdoc
temiz; bytecode task-specific /tmp dizinindedir, kaynakta elc yoktur.

Mevcut connection TLC **602836 generated / 101708 distinct**, queue 0, depth 22;
transport TLC **1810 / 693**, queue 0, depth 12 ile 00:45:17'de hatasız tamamlandı.
Bu bounded modellerin regression taramasıdır; yeni somut target DTO/epoch pinning
refinement'ı veya tüm 01 uyumluluk ispatı değildir. Genel run/history, native
config/base, hard monetary reservation ve dört application backend'i açık.
01 ve shell.nix/07 kullanıcı değişiklikleri korunur. Yeni dependency, harici
model/hesap/CLI turu, login, credential taşıma, kurulum, merge/push yoktur.
Yeni core capability'si gerekir; kullanıcının canlı Emacs/core'u reload edilmedi.

## 2026-10-26 — Setup ortak connection portu ve duplicate async facade silme

Todo 1'in setup alt işi tamamlandı: command dar autoload `config/setup.el`
adapter'ında config + credential için tek origin-owned root/deadline kullanır.
Mevcut connection resolver'ına bağlandı; son tüketicisi taşındığı için eski
key-only async facade/dispatch/delivery ve onlara özel imports kaldırıldı.
Kill/mode/timeout/replacement child'ları bırakır; stale selection sonucu yeni
provider'la eski key'i raporlayamaz. Başka application veya bound chat snapshot'ı
kontrolü yönlendiremez. Callback hata verse/discard edilse bile owned scope ve
raporun key kopyası temizlenir. Setup model/metadata isteği veya sidecar başlatmaz.

Yeni güvenlik bulgusu da kapatıldı: placeholder warning sonu `...` olan key'in
kendisini logluyordu; yalnız generic uyarı kaldı. Todo'da iki alt madde `[x]`,
native config/endpoint üst grubu açık; kalan consumer alt işleri ayrıldı.
Setup `ready` raporunun native readiness olmadığını release kabulünde doğrulamak
için todo 10'a bir alt iş eklendi. Ayrıntılar .codex/45'te.

10 yeni setup testi ve **1236/1236 full source ERT**, 0 unexpected, **137.45 s**,
**00:12:44 Europe/Istanbul** geçti. **259 native + 16 compile-fail**, fmt,
strict all-targets Clippy temiz. Üç üretim Elisp ve yeni test dosyası Werror
bytecompile/checkdoc temiz; bytecode yalnız task-specific /tmp dizininde.
Mevcut connection TLC exhaustive tekrar **602836 generated / 101708 distinct**,
queue 0, depth 22 ile 00:12:58'de hatasız tamamlandı. Bu bounded modele aittir;
somut yeni setup UI/refinement/secure-erasure ispatı değildir. Rust üretim
kaynağı değişmedi; native testleri yeni Rust config özelliği diye sunulmaz.

Kullanıcının tamamlananları silmek yerine `[x]` tutma isteği todo çalışma
kuralına işlendi. 01, shell.nix/07 kullanıcı değişiklikleri ve module baseline
korundu; kurulum, gerçek uzak API/CLI model turu, login/credential taşıma,
merge/push yapılmadı. Genel native config/endpoint, run/history, hard monetary
reservation ve dört backend hâlâ açık.

## 2026-10-25 — Katalog credential consumer cutover ve senkron Elisp temizliği

Katalog GET hazırlığı `api/catalog/request.el` altında ayrıldı ve mevcut owned
async connection/credential portuna bağlandı. HTTP/header assembly ve canonical
catalog/metadata motorları native kalır. Provider/URL/public kararı/wire/header
binding/application credential yield'inden önce yakalanır; yabancı chat snapshot'ı
ödünç alınmaz. Public URL ile custom override ayrımı korunur. Katalog published
config'i okur; explicit UI/config refresh dışında gizli disk okuması yapılmaz.

Origin kill/mode change, cancel ve deadline child/transport/publication cleanup'ını
kapatır; GET yalnız kalan root süresini kullanır. Provider selection/agent Stop
bağımsız discovery'yi kapatmaz. Genel connection resolver'ın revision kontrolü
ve callback'i initiating application'a sabitlendi; current başka application veya
foreign bound connection sonucu yönlendiremez. Raw adapter hatası UI'a sızmaz;
kapanış private scope ve request'e ait key kopyasını siler, tüm bellek kopyaları
için fiziksel erasure garantisi iddia edilmez.

Artık üretim tüketicisi kalmayan sync `resolve-api-key`/`config-api-key`/
`config-resolve-api-key-result`, UI auth-source search/callable secret yolu,
nonblocking flag ve onlara özel yardımcılar kaldırıldı. Fixture'lar memory-only
precedence veya gerçek async credential portunu kullanır. Setup'ın tükettiği async
facade ve Emacs auth-source interop child'ı gereksizmiş gibi silinmedi. Detay 44'te.

Altı yeni test gerçek plaintext child -> Rust -> loopback GET, gerçek slow child
kill, iki application, frozen wire/header, foreign chat, stale config/session,
cancel/timeout/late callback ve cleanup'ı kapsar. **1226/1226 full source ERT**,
0 unexpected, **137.18 s**, **23:49:13 Europe/Istanbul** geçti. **259 native +
16 compile-fail**, fmt ve strict all-targets Clippy temiz. Beş üretim Elisp
dosyası ve yeni test dosyası Werror bytecompile/checkdoc temiz; elc çıktıları
yalnız task-specific /tmp dizinindedir. Rust üretim kodu değişmedi; native gate
yeni Rust özelliği kanıtı değil mevcut core'un yeniden çalıştırılmış regresyonudur.
Yeni TLC/refinement ispatı iddia edilmez. İlk yeni testte inherited Emacs hook'larına
fazla geniş assertion düzeltildi; lint/docstring ve test syntax hataları final
gate'ten önce giderildi. Assertions veya module baseline gevşetilmedi.

Katalogun senkron credential discovery portu kapandı. Genel run/history, native
config/endpoint policy, setup facade son-tüketici birleştirmesi, G08 hard monetary
reservation ve dört uygulama backend'i açık; tüm Rust/API göçü tamamlanmadı.
Kullanıcının shell.nix/07 değişiklikleri ve 01 korunur. Harici hesap/API/CLI model
turu, login, credential taşıma, kurulum, merge/push yapılmadı.

## 2026-10-25 — Public metadata writer/UI consumer cutover ve Elisp engine silme

Public metadata put/property/refusal/clear setter'ları mevcut native actor'e
bağlandı; artık async publication ticket döndürür, callback (VIEW FAILURE) alır.
Katalog tek native replace_catalog ile atomik yayınlanır. Genel UI reader,
request settings ve inspector native DTO tüketir; Elisp entry/table, alias
arama, override merge, retain/prune writer, refusal hash ve field/effort/
capability/fiyat parse engine'leri kaldırıldı. Property inspector commit ACK'i
gelmeden başarı mesajı vermez. Float fiyat/kapasite girdisi reddedilir; native
exact fiyat etiketi kullanılır ve invalid9 artık free olmaz.

Önceki ticket yoksa gerçek connection preparation başlangıçta readonly observe
ticket'ını yakalar, native head/pages alır; metadata update yapmadan revision 0
gözlenebilir. Passive UI için küçük Rust-owned models-empty.json asset'i eklendi;
bir native test bu dosyayı ModelStore::new() görünümüyle bire bir karşılaştırır.
Bu bootstrap canlı lease veya başarısız native hazırlık yerine kullanılamaz.
Kaybolan epoch yeniden bağlanmaz, belirsiz commit explicit reconcile gerektirir.
DTO-only weak indexes büyük kataloglarda her UI satırı için bütün vektörü tekrar
taramaz; field-only okuyucular büyük inspector açıklamasını kopyalamaz.

Katalog generation değişimi commit öncesi upload'ı revoke/abort/drain eder;
gönderilmiş commit'i geri alınmış saymaz. Eski revision tek writer'da tamamlanır,
ardından yeni katalog uygulanır. Her GET kendi callback'ini alır, stale reply
yeni cache'i diriltemez. Kaynak/lease kaybı sonrası fail-closed kuralı korunur.

Dört yeni gerçek public consumer fixture ve native bootstrap equality testi
eklendi. Eski senkron fixture'lar gerçek Rust public işlemlerini açıkça bekler;
üretim API'si bloklanmadı, metadata engine mock'la değiştirilmedi. Native owner'lar
test sonunda iptal/drain/close edilir; eski hash snapshot assertion'ları detached
native receipt'e taşındı. Simüle circuit peer ile gerçek metadata yazılamadığı
için birleşik ownership fixture'ı gerçek core lease kullanır. Hiçbir module
baseline veya davranış assertion'ı yeşil sonuç uğruna düşürülmedi.

Son gate: **1220/1220 full source ERT**, 0 unexpected, **136.26 s**, 23:01:46
Europe/Istanbul geçti. Önceki 1220 taramaları da geçti; ilk diagnostic taramadaki
dört eski sync/fake-peer fixture hatası düzeltilip tam suite yeniden çalıştırıldı.
**259 native + 16 compile-fail**, fmt, strict all-targets Clippy ve locked build
temiz. On üretim Elisp dosyası Werror bytecompile/checkdoc temiz; çıktılar
/tmp/kargu-public-cutover-bytecompile.CVaC11 altına yönlendirildi, kaynakta elc yok.
Somut metadata protokolü için yeni TLC refinement kanıtı iddia edilmez; mevcut
abstract modeller bu revision/queue ayrıntılarını içermiyor. Detay 43'te.

Bu public metadata dilimi tamamlandı; genel run/history, katalog credential
discovery portu, G08 hard monetary reservation ve dış uygulama backend'leri
açık. Tüm Rust/API göçü tamamlandı iddiası yoktur. Kullanıcının shell.nix/07 ve
01'i korunur; harici hesap/API/CLI model turu, kurulum, merge veya push yapılmadı.

## 2026-10-25 — Config sağlayıcı listesinin gerçek UI girişinde yenilenmesi

Kullanıcının raporu yeniden üretildi: ortamda config.yaml yok, asıl dosya
~/.config/kargu/config.toml ve beş provider içeriyor. Dosya doğru okunuyor fakat
footer provider selector ilk config refresh'i başlatmıyordu; memory-only reader
bu yüzden boş publication görüyordu. Ayrıca config'te tanımlı özel provider ID'leri
yalnız registered-ID listesinden üretilen authenticated adaylara giremiyordu.

Explicit UI girişine ayrı küçük chat/select/config lifecycle portu bağlandı.
Mevcut bounded worker asenkron yeniler; passive reader'a IO veya ikinci parser
eklenmedi. Popup application/session/selection/generation/focus/draft/point ve
idle guard'larıyla açılır. Tek view'in tekrar açılması/kill/mode change yalnız
onun refresh/child'ını iptal eder. Custom configured ID'ler de fast credential/
keyless filtresine girer; registry'ye yeni kalıcı kayıt veya auth unlock yoktur.

Dört yeni fixture, 32/32 focused test ve **1216/1216 full source ERT**, 0 unexpected,
**129.27 s**, 18:57:14 Europe/Istanbul geçti. Üç üretim dosyası Werror bytecompile/
checkdoc temiz; geçici elc'ler full source öncesi /tmp altına taşındı. Kullanıcının
gerçek dosyasıyla read-only UI doğrulaması beş provider'ı da döndürdü; dosyaya veya
anahtarlara dokunulmadı. Detay 42'de. 01/module baseline/shell.nix/07 korunur.

Bu bir config UI consumer düzeltmesidir; native config parser veya public model
metadata setter/catalog/reader cutover'ı tamamlandı sayılmaz. Rust üretim kaynağı
değişmediğinden önceki 258 native + 16 compile-fail kapısı yeni rerun diye sunulmaz.

## 2026-10-25 — İlk publication intent'i ve owned startup

Explicit bridge publisher artık ilk sidecar startup yield'inden önce captured
ticket'ı application'a kaydeder. Gerçek connection preparation bu ilk intent'i
bekler; sonradan kuyruğa giren yazım onu değiştirmez. Startup/lease acquisition
ayrı bridge/models/start modülündedir; metadata semantiği veya ikinci queue/store
yoktur. Mevcut API lease'i ilk metadata yazımında bile değiştirilmez; kayıp epoch
ve eksik capability yeni owner/revision-zero/replay yolunu açmaz.

Lease öncesi iptal yalnız o startup waiter'ını söker, belleği bırakır ve sıradaki
işe izin verir; ortak core/sibling startup kapatılmaz. Geç/duplicate ready callback
iptal edilmiş owner yaratamaz. Allocation başladıktan sonraki mevcut abort/ACK/
drain sözleşmesi korunur. Snapshot/capture/reconcile core başlatmaz.

Beş yeni gerçek editor/native fixture dahil **1212/1212 full source ERT**,
0 unexpected, **128.38 s**, 18:41:34 Europe/Istanbul geçti. Bu sayı discovery
hassasiyet regression'ını da içerir. Dört dokunulan üretim Elisp dosyası Werror
bytecompile/checkdoc temiz; geçici elc'ler kaynakta bırakılmaz. Native gate bu
turn'de **258 native + 16 compile-fail**, fmt, strict Clippy ve locked build geçti.
İlk focused catalog denemesi eksik test bootstrap'ı nedeniyle başlayamadı;
require kargu ile 6/6 yeniden geçti, hiçbir assertion zayıflatılmadı.

Public setter/catalog producer + genel UI reader consumer cutover ve onların
Elisp semantic engine'lerini silme hâlâ açıktır. Bunlar tamamlanmadığından tüm
metadata/API göçü bitti iddiası yoktur. 01, module baseline ve kullanıcının
shell.nix/07 değişiklikleri korunur; harici API/CLI hesabı kullanılmadı.

## 2026-10-25 — Discovery kapasite lexeme kaybının kapatılması

Native discovery snapshot artık ayrı fiyat dönüştürücü yerine metadata'nın
ortak RawMetadata sınırını kullanır. Bütün context/output alias'ları, nested
top_provider ve tek-object wrapper'ları exact kalır: u64 literal integer türünü
korur; fraction/exponent/overflow kaynak metni string taşınır. Böylece canonical
GET cevabı tekrar native store'a verildiğinde 9007199254740992.5 geçerli integral
kapasiteye yuvarlanamaz. Yinelenen price conversion kodu silindi; bilinen nested
control object duplicate-key sözleşmesi discovery için de uygulanır.

İki yeni native regression, genişletilen gerçek HTTP fixture ve bir yeni gerçek
editor GET testi geçti. **258 native + 16 compile-fail**, fmt, locked build ve
strict all-targets Clippy temiz. **6/6 focused real catalog ERT** geçti. Bu dilim
için henüz yeni full ERT iddiası yok; önceki 1206 gate tarihsel kanıttır. Public
setter/catalog writer ve genel UI reader cutover/silme hâlâ açıktır. Kullanıcı
shell.nix/07 değişiklikleri korunur; 01 değiştirilmedi.

## 2026-10-25 — Owned async editor metadata ve captured-ticket hazırlık bariyeri

bridge/models state/transfer/queue modülleri native RPC'yi gerçek editör hattında
tüketir. DTO'lar yield öncesi kopyalanır; 32 queued command/16 MiB queued byte,
8 MiB source, bounded UTF-8 ACK/page ve ticket deadline sınırları vardır.
İptalden sonra geç gelen upload exact ID ile abort edilir, ACK/drain olmadan
sıradaki iş başlamaz. Per-RPC take-once latch duplicate callback'i etkisiz yapar.
Gönderilmiş commit iptal edildi varsayılmaz: bilinmeyen sonuç eski UI görünümünü
korur fakat yeni hazırlığı reddeder. Explicit reconcile yalnız aynı lease'teki
gerçek head'i okur; update replay/reset/reconnect veya zero revision tahmini yok.

Committed DTO'lar private symbol cell'dedir; snapshot/receipt/waiter getter'ları
detached kopya verir. Connection preparation config sonrası, credential öncesi
başlangıçta yakaladığı ticket'ı bekler; revision/fields/tools/metadata ve exact-ID
request parameters o görünümden dondurulur. Daha yeni queue tail'ı ödünç alınmaz.
Stop yalnız hazırlık waiter'ını söker; shared metadata publication devam eder.
Native failure'da legacy fallback yoktur. Native publication'a giren application
legacy record/override/prune/refusal writer'ını açıkça reddeder; iki engine aynı
sahipte sessizce çalışamaz.

**15 yeni gerçek editor/native fixture** dahil **1206/1206 full source ERT**,
0 unexpected, **127.77 s** geçti (18:16:39 Europe/Istanbul). Önceki tarama
1204/1204'tü; son iki fixture dahil yeni source rerun tamamlandı. Dokunulan dokuz
üretim Elisp dosyası Werror bytecompile ve checkdoc temiz; dokuz geçici elc test
öncesi /tmp/kargu-publication-final-elc.2uFPX2 altına taşındı, kaynakta elc yok.
Native kaynak 8412d50'den beri değişmedi: **256 native + 16 compile-fail**,
fmt/locked build/strict all-targets Clippy kanıtı geçerlidir. Module baseline ve
eski assertion'lar değiştirilmedi; 01 ve kullanıcı shell.nix/07 korunur.

Bu, default public producer cutover'ının tamamı değildir: public setter'lar,
katalog publisher ve genel UI reader hâlâ legacy uygulamalar için eskidir.
Native-intent application için hazırlık hattı bağlandı; native producer sonrası
karşılık gelen public consumer'lar geçirilmeden çalışan Elisp semantic kodu
silinmedi. Sonraki dilim bu public sözleşmeleri async completion'a geçirip
capacity source lexeme kaybını önlemek ve legacy writer/readers'ı kaldırmaktır.
G08 monetary hard-cap ve tüm Rust göçü açık; dış API/hesap/CLI model turu yok.

## 2026-10-25 — Canonical native UI ve bilinmeyen model projection'ı

model_metadata_projection capability; display/defaults/alias/refusal permission
DTO'ları eklendi. UI için exact fiyat etiketi native üretilir: 1e-38 sıfıra
yuvarlanmaz, u128::MAX rate'in 1M etiketi de integer multiplication taşması
olmadan decimal text shift ile hazırlanır. Missing/invalid fiyat label/badge
üretmez; input-zero etiketi monetary hard-cap kanıtı değildir.

Unknown model defaults ve alias tools permission native üretilir; request
parameters için exact model şartı korunur. İki yeni fixture ile **256 native +
16 compile-fail**, fmt, locked build ve strict all-targets Clippy geçti. Bu native
DTO dilimi tek başına mevcut public Elisp setter/UI reader cutover'ı değildir;
o tüketicinin invalid9/free düzeltmesi tamamlandı iddiası yoktur. 01 ve kullanıcı
shell.nix/07 korunur. Dış hesap/API/uygulama model turu çalıştırılmadı.

## 2026-10-25 — Application-owned native metadata publication RPC

model_metadata capability ve models/begin/append/commit/abort/snapshot/read
metotları eklendi. Store application actor'ünün tek writer alanıdır; upload
session'a, rastgele typed kimliğe ve base revision'a bağlıdır. Commit'e kadar
veri görünmez. 60s absolute validity (sonraki çağrıda lazy reap), 8 MiB upload,
16 KiB fragment ve 16 MiB snapshot sınırları vardır. Snapshot bir kez serialize
edilir; escaped Unicode ve minimum 1 KiB negotiated frame dahil paged okunur.
Yeni revision eski page isteğini reddeder; session/app close staging'i bırakmaz.

Altı gerçek stdio testi ve iki deterministik expiry/cap testi eklendi. Refusal
clear'ın all-provider scope'u ve effort-spec bağımsızlığı ayrıca doğrulandı.
**254 native + 16 compile-fail**, fmt, locked build ve strict all-targets Clippy
geçti. Güncel normal binary ile **1191/1191 full source ERT**, 0 unexpected,
**125.91 s** geçti (17:17:56 Europe/Istanbul). Elisp üretim kaynağı değişmedi;
bytecompile/semantik consumer cutover iddiası yoktur, .elc üretilmedi.

Editor async setter/last-committed projection ve captured-intent preparation
bariyeriyle gerçek consumer cutover sıradadır. HTTP discovery'nin capacity
lexeme'lerini de o cutover'da kayıpsız taşı; generic decode'dan geçmiş fraction'ı
native'a geri yükleyerek exact deneme. Aktif Elisp writer/reader'ı bu yüzden
henüz silme. Mevcut UI invalid9/free hatası kapandı iddiası, monetary hard-cap
veya model refinement kanıtı yoktur. Detay 41'de; 01 ve kullanıcı shell.nix/07
korunur; dış API hesabı/uygulama/model turu çalıştırılmadı.

## 2026-10-25 — Atomik revisioned native metadata store

models/store artık private MetadataRevision, parse-once ModelUpdate ve tüketilen
PreparedUpdate ile tek writer domain'i sağlar. Commit token hem özgün store
sahibine hem base revision'a bağlıdır; speculative veri snapshot'a çıkmaz.
Provider-local unique alias, canonical override, explicit false, opaque ID case,
last-record/first-ID sırası, provider-only prune ve override-only kayıt korunur.
Refusal tuple'ları ayrı kalır; ham metadata provider/id ile sahiplik değiştiremez.
Numeric source orijinal RawValue'dan gelir; tek-object legacy wrapper dahil fiyat
ve fractional token inspector projection'ı float'a gitmez. Güncelleme/aggregate
record/byte ve snapshot sınırları taşmada atomik hata verir.

Yedi store fixture'ı + consuming-commit compile-fail; **245 native + 16 compile-
fail**, fmt ve strict all-targets Clippy geçti. Bu saf domain diliminde editor
consumer hâlâ eski store'u kullanır; native actor/RPC ve async publication henüz
cutover edilmedi. Bu nedenle Elisp writer/reader silinmedi. ERT'nin son full
1191/1191 sonucu yeni bir rerun olarak sunulmaz. 01/shell.nix/07 korunur.

## 2026-10-25 — Async metadata sözleşmesi onayı ve canonical field temeli

Kullanıcı async setter + son committed UI snapshot sözleşmesini onayladı;
önceki bekleyen karar çözüldü. models/metadata altında exact RawValue sınırı,
Missing/Invalid/Known gözlemleri, ayrı cache-read/cache-write rate tipleri,
kapasite/flag/parameter/vision/label ve declared effort path normalizasyonu
eklendi. Path/list sınırları ve duplicate semantic key reddi korunur; model
adından yetenek çıkarılmaz. Fractional >2^53 token ve invalid9/submicro fiyat
fixture'ları dahil yedi native test; iki yeni compile-fail birim kanıtı vardır.
**238 native + 15 compile-fail**, fmt ve strict all-targets Clippy geçti.

Bu dilim domain temelidir: default editor setter/store/field consumer henüz
değişmedi, üretimdeki legacy invalid9/free hatasının kapandığı iddiası yoktur.
Native revisioned owner, async publication/preparation barrier ve ardından
Elisp semantic writer/reader silme işi devam eder. 01, kullanıcının shell.nix
ve 07 değişiklikleri korunur; dış hesap/API/uygulama model turu çalıştırılmadı.

## 2026-10-25 — Metadata JSON feature etkileşimi için native regresyon kapısı

Gerçek strict IPC decoder üzerinden yeni test ordinary float temperature,
u64 quantity, literal private-number-key nesnesi ve nested duplicate-key
reddinin ayrı kaldığını doğrular. Global arbitrary_precision açık negatif
kontrolde test beklendiği gibi başarısız olur; decoder esnetilmez. Ardından
normal feature setiyle **231 native + 13 compile-fail**, fmt/strict Clippy ve
locked build; restore edilen normal binary ile **12/12 gerçek default chat/
catalog ERT** geçti. Son üretim kaynağı 8331fd5; onun **1191/1191 full source
ERT** kanıtı geçerlidir, bu test-only dilim için yeni full ERT iddiası yoktur.
Scoped raw_value manifest'te kalır; Cargo.lock/version değişmez. 01 ve kullanıcı
shell.nix/07 korunur. Tam metadata store geçişi için sorulan async setter/UI
last-committed snapshot kararı bekleniyor; mevcut senkron davranış değişmedi.

## 2026-10-25 — /models discovery envelope native consumer cutover

Default katalog GET'i api_model_catalog capability ve GET-only response profile
ister. data/models/items/bare liste/string ID dönüşümü, typed ModelId, explicit
boşluk, duplicate control key ve resource sınırları models/catalog altındadır.
Bilinen fiyat lexeme'leri generic float decode öncesinde kayıpsız string olur.
Eski Elisp extract-models/catalog-response parser'ları silindi; editör yalnız
canonical vector DTO ve captured provider/generation/owner teslimi yapar.

**230 native + 13 compile-fail**, fmt/locked build/strict Clippy; **90/90 focused
ERT**, iki üretim dosyası Werror bytecompile/checkdoc ve iki geçici elc silme
sonrası **1191/1191 full source ERT**, 0 unexpected, **126.19 s** geçti. Ham
envelope assertion'ları native pure/socket ve beş gerçek public GUI testine
eşlendi; cache/override/freshness/owner assertion'ları korunur. 1 MiB frame limiti
artmadı; büyük katalog paging ve exact-price text gerçek hatta doğrulandı.

Tam field/rate/capability normalizasyonu, native revisioned store/override ve
preparation bariyeri açıktır; invalid9/free legacy reader hatası kapandı iddiası
yoktur. Senkron setter sözleşmesi bu dilimde değiştirilmedi; sonraki async
completion/UI last-committed snapshot kararı kullanıcıya soruldu. Detay 41'de;
01, kullanıcı shell.nix/07 korunur. Gerçek hesap/API/CLI model turu yoktur.

## 2026-10-25 — Metadata için kesin native sayısal alan tipleri

models/numeric altında ayrı context/output capacity ve input/output USD/token
rate tipleri eklendi. Parse/serde sınırları, checked u128 ondalık katsayı,
0–38 scale ve 128-byte literal sınırı vardır; float/yuvarlanan token veya
underflow-to-free yoktur. Altı fixture + üç yeni compile-fail; toplam **221
native + 13 compile-fail**, locked build/fmt/strict Clippy ve yeni binary ile
**1186/1186 full source ERT**, 0 unexpected, **124.97 s** geçti.

Global arbitrary_precision deneyi gerçek IPC duplicate-key visitor ile
uyumsuz çıktı ve kaldırıldı; key denetimi gevşetilmedi. Yalnız metadata
RawValue sınırı için raw_value feature açılır; lock/version değişmedi. Bu
domain temeli mevcut Elisp field/store consumer'ının taşındığı veya invalid9
fiyat hatasının üretimde kapandığı anlamına gelmez. Ayrıntı/öğrenimler 41'de.
Kullanıcı 01/shell.nix/07 değişmedi; gerçek hesap/API/CLI model turu yok.

## 2026-10-25 — Sonraki metadata sınırının kanıtlı incelemesi

Metadata extraction/store/request snapshot tüketicileri incelendi. Fresh Emacs
salt-okuma deneyi "invalid9" fiyatının 0/free, 1.5 token değerinin 2 olduğunu;
geçerli fiyatın float'a gittiğini doğruladı. Bunlar henüz düzeltilmiş değildir.
Senkron custom setter/UI getter sözleşmesi nedeniyle yalnız parser RPC'si
eklemek yeterli değildir: revision'lı native publication, detached UI okuması
ve preparation bariyeri birlikte tasarlanmalıdır. 41'de somut owner/tüketici,
kesin rate/amount birim ayrımı ve fixture/kabul sırası kaydedildi. Üretim kodu
71dc32d'den beri değişmez; full ERT 1186/1186 kanıtı geçerlidir. 01 ve kullanıcı
shell.nix/07 değişmedi; bu not metadata göçü tamamlandı iddiası değildir.

## 2026-10-25 — Default API resilience native; legacy motorlar silindi

Plain/stream chat tek native logical exchange, captured retry/circuit/budget
ve owned UI observer ACK kullanır. Retry timer/backoff/Retry-After parser ve
HTTP/curl/metin sınıflandırması; circuit admission/sayaç/legacy mirror/probe
motoru ve logical retry/stream timer alanları silindi. plz DTO/require/paket ve
run bağımlılığı kaldırıldı. Terminal native category/code/status/reason/partial
Result'a çevrilir; run deadline budget-exhausted kalır. Manuel model/compaction
retry, verilen native reset'in ACK'ini bekler; cache admission hakkı vermez.

Son kaynaklarla **1186/1186 full source ERT**, 0 unexpected, **127.48 s** geçti;
önceki geçiş taraması 1183/1183, ardından 8/8 focused native default/reset testi
de geçti. 16 üretim dosyası Werror bytecompile temiz; 16 geçici elc kaldırıldı.
Checkdoc temiz (ortam OpenPGP autoload mesajı hariç); locked strict all-targets
Clippy tekrar geçti. Native kaynaklar 1f8de6f'ten beri değişmedi: son native
gate **215 + 10 compile-fail**. Dokuz silinen engine-özel ERT'nin native policy/
stdio ve gerçek GUI socket/debit/ACK test eşlemesi 40'ta; assertion/baseline
gevşetilmedi. README/todo/roadmap güncellendi. Model metadata ve genel run/history/
uygulama backend geçişi açık; tüm göç tamamlandı iddiası yok. 01 ile kullanıcının
shell.nix/07 değişiklikleri korunur; gerçek hesap/API/CLI model turu çalışmadı.

## 2026-10-25 — Native terminal hata kategorileri

Rust ApiError artık kapalı FailureCategory üzerinden additive category üretir;
api_failure capability eklendi. Code/status metadata korunur; logical run
deadline budget-exhausted/reason=deadline, fiziksel timeout'tan ayrıdır. Kategori
yalnız UI projection'dır; retry/probe hakkı vermez. Elisp default consumer henüz
bu dilimde değiştirilmedi. **215 native + 10 compile-fail**, fmt/build/strict
Clippy; son wire assertion ile **7/7 budget stdio**, güncel binary ile **16/16
focused native GUI** geçti. Son full ERT önceki loop dilimindeki 1187/1187'dir.
Detay ve kalan consumer adımları 40'ta; kullanıcı shell.nix/07 korunur.

## 2026-10-25 — Default resilience: ikinci loop retry motoru silindi

Loop'un upstream sınıflandırma/handler/timer/sayaç/cleanup motoru kaldırıldı.
Terminal HTTP hatası yeni otomatik istek açmaz; açık kullanıcı recovery kararı
korunur. Eski loop retry ayarı tek API retry limitinin obsolete alias'ıdır;
çarpan etkisi kaldırıldı ve config assignment semantiği 40'a yazıldı. Native
default API cutover henüz bu dilimde yapılmadı; sıradaki typed failure/consumer
bağlantısına hazırlıktır. Eski compatibility testleri public dispatch/manual
recovery sınırına eşlendi; assertion veya modül baseline'ı gevşetilmedi.

**1187/1187 full ERT**, 0 unexpected, **165.14 s**; Werror bytecompile temiz,
üç geçici elc kaldırıldı. Güncellenen ana bounded TLA+ taraması **537324349
generated / 63188083 distinct / depth45**, 7m42s, 0 queue ile hatasız tamamlandı.
Bound ve bütün safety invariant'lar korunur; native retry refinement kanıtı
değildir. Rust business kodu bu dilimde değişmez; shell.nix/07 korunmuştur.

## 2026-10-25 — 01 audit: command typestate ve açık effect sınıfı

Command registry'deki ikinci Option<Stage> kaldırıldı; modüler execution/state
altında Preparing/Reviewing/Running kaynak sahibi tiplerdir. Prepare/launch/
collect doğru concrete phase'i tüketir; genel transition helper private kalır,
yalnız izin verilen named geçiş metotları açılır (API retry'de de aynı kural).
Owner terminal intent join/poll/geçiş boyunca taşınır; mailbox'a yeni await veya
erken slot release eklenmedi. Otomatik onay tool adına değil, gate'in registry
ve command ile doğruladığı immutable ToolSafetyLevel'a bağlıdır. Read-only adı
taşıyan arbitrary executor regresyonu ve safety relabel compile-fail eklendi.

Son kaynaklar **212 native test + 10 compile-fail**, locked build/fmt/strict
Clippy ve son binary ile **1185/1185 full source ERT**, 0 unexpected,
**123.99 s** geçti. 39'daki somut audit bulguları giderildi; bütün Rust ağacı
veya migration için tam uyum/tamamlanma sertifikası değildir. Sonraki asıl geçiş
high-level API/loop default retry/circuit consumer ve legacy Elisp silmesidir.
Kullanıcının 01 kuralları, shell.nix ve 07 değişiklikleri korunmuştur.

## 2026-10-25 — 01 audit: checked indexing ve üretim lint kapısı

Cache'teki iki raw string range erişimi checked get oldu; Unicode/tekrarlanan
marker/empty/start-boundary regresyonları eklendi. Yeni üretim indexing_slicing
kapısı ayrıca 18 JSON IndexMut yazımını yakaladı: cache, stream, wire, error ve
IPC projection'lar Map::insert/checked object erişimine geçirildi. Gate üretim
kütüphanesinde zorunludur; unsafe forbid esnetilmedi. **211 native test + 9
compile-fail**, locked build/fmt/strict Clippy ve son binary ile **1185/1185
full source ERT**, 0 unexpected, **124.52 s** geçti. todo göç özeti güncellendi.
Bulgu/kanıt ve kalan command phase audit'i 39'da; bütün göç tamamlandı iddiası
yoktur. Kullanıcının shell.nix/07 değişiklikleri korunmuştur.

## 2026-10-25 — 01 audit: HTTP altında ikinci replay politikası kapatıldı

Reqwest retry::never explicit ayarlandı; replay actor/budget/observer dışında
yetkilendirilemez. Manifest minimumu zaten locked olan 0.12.28'i beyan eder;
lock/feature değişmedi. Bugünkü build h2/h3 kullanmadığı için gözlenen gizli
replay hatası iddiası yoktur. Tam POST sonrası 503 veya belirsiz bağlantı
kopuşunda ikinci socket olmadığı gerçek fixture ile doğrulanır. **25 focused
HTTP/retry/circuit testi** ve strict Clippy geçti; son full native **209+9** ve
ERT **1185/1185**, önceki typestate dilimindendir. Kanıt/sınırlar 39'da.

## 2026-10-25 — 01 audit: kaynak sahibi retry typestate

Independent retry/stage/charge Options ve optional admission tuple kaldırıldı.
DTO TryFrom'da Single/Retry intent'e ayrılır; her phase kendine ait ticket veya
reverse correlation taşır ve geçiş önceki phase'i tüketir. Mailbox heterojen
saklama enum'u korunur, boş stage yoktur. Yeni compile-fail örnekleri yanlış
aşamada replay/observer ve aynı replay hakkının tekrar kullanımını reddeder.
IO, budget/owner/ACK kararları ve gerçek drain actor sınırında korunur; 39'da
detaylar vardır. **209 native + 9 compile-fail**, fmt/build/strict Clippy ve
**1185/1185 full source ERT**, 0 unexpected, **128.51 s** geçti. 01 ve kullanıcı
shell.nix/07 değişiklikleri değiştirilmedi.

## 2026-10-25 — 01 audit: API sayfa boyutu alan tipi

Raw usize ve tekrarlanan zero/progress kontrolü kaldırıldı; `ApiPageBytes`
TryFrom sınırında framing rezervi, üst limit ve UTF-8 ilerlemesini garanti eder.
Yanlış birim compile-fail ve minimum sayfada kayıpsız Unicode regresyonu eklendi.
**208 native test + 6 compile-fail**, fmt/strict Clippy geçti; son bağımsız full
ERT **1185/1185**. Diğer somut audit bulguları ve açık sınırlar 39'a kaydedildi;
01 değiştirilmedi, kullanıcı shell.nix/07 değişiklikleri korunuyor.

## 2026-10-25 — Native circuit GUI projection/reset köprüsü

GUI yalnız exact application/connection/scope altındaki bounded, detached native
görünümü tutar; connection sequence eski snapshot'ın reset'i geri almasını
engeller. Reset mevcut lease üzerinden explicit RPC'dir; core başlatmaz. Yeni
Elisp admission/counter/probe motoru yoktur. High-level varsayılan cutover henüz
açıktır. **1185/1185 full source ERT**, 0 unexpected, **126.66 s**; touched Werror
bytecompile/checkdoc ve **206 native + 5 compile-fail**/fmt/build/strict Clippy
geçti. Ana eski bounded TLC de 84.273.208 distinct state/depth45 ile hatasız
tamamlandı; Rust refinement kanıtı değildir. Ayrıntılar 38'de.

Kullanıcının yeni 01 uyarısı önceliklendirildi: retry phase/charge Option
kombinasyonları ve raw page-byte birimi somut audit bulgularıdır; sonraki dilim
bunları düzeltir, kurallar gevşetilmez. shell.nix/07 kullanıcı değişiklikleri korunur.

## 2026-10-25 — Native circuit registry / logical retry lease composition

api_circuit capability, owned snapshot/reset ve bounded native registry eklendi.
Probe tüm mantıksal retry boyunca tutulur; her fiziksel attempt ayrıca debit
edilir. Model değişimi circuit'i sıfırlamaz; auth/endpoint/app değişimleri
izole kalır. Reset geç sonuçları etkisizleştirir; capacity unsafe eviction yapmaz.
Malformed model HTTP 200 probe'u healthy yapmaz. Admission/worker modüler ayrıldı.

**206 Rust testi + 5 compile-fail**, locked build/fmt/strict Clippy ve **1178/1178
full source ERT**, 0 unexpected, **164.26 s** geçti. Ana eski bounded TLC scan
bu commit sırasında sürüyor; henüz verdict yok, native registry refinement
kanıtı sayılmayacak. Detay, kalan GUI/loop cutover ve sınırlar 38'dedir.
Kullanıcı shell.nix/07 değişiklikleri korunmuştur; gerçek dış hesap çağrısı yok.

## 2026-10-25 — GUI native retry observer köprüsü

Bridge exact forward/scope/epoch/owner'a observer teslim eder, callback sonrası
yeniden kontrol edip ACK verir. Duplicate/stale/reentrant cancel veya consumer
hatası replay yetkisi vermez. Transport :retry/:on-retry ile native policy ve
budget projection'ını bağlar; yeni Elisp retry timer/karar motoru yoktur.

**1178/1178 full source ERT**, 0 unexpected, **125.46 s**, touched Werror
bytecompile/checkdoc temiz ve .elc kaldırıldı. Native son kaynaklarıyla tam
**197 test + 5 compile-fail** yeniden geçti. High-level API varsayılan cutover
ve loop/machine'deki ikinci retry consumer henüz açıktır; 37'ye not edildi.
Kullanıcı shell.nix/07 değişiklikleri korunmuştur.

## 2026-10-25 — Native retry actor ve reverse observer consumer

Gerçek api/request retry consumer eklendi; api_retry capability ilan edilir.
Her socket actor budget gate'inden geçer; backoff/observer kaynakları gerçek
join'e kadar slot/owner tutar. Observer ACK yeni IO'dan önce zorunludur; yanlış/
geç yanıt, owner close, shutdown/EOF, deadline ve unknown capped usage fail-closed.
Typed policy + immutable request yeniden parse edilmez. Detay ve açık sınırlar
37'dedir. Bu kesimde GUI henüz retry seçeneğini kullanmaz; eski Elisp motoru
native circuit/UI consumers taşınmadan silinmedi.

**197 Rust testi + 5 compile-fail** geçti; son okunabilirlik-only extraction
sonrasında **55 focused native test**, locked build/fmt/strict Clippy yeniden
geçti. Son bağımsız full editor baseline **1172/1172**. Gerçek dış uygulama,
hesap/login/ücretli API veya kurulum çağrısı yok; yalnız loopback fixture'ları.

## 2026-10-25 — Mantıksal budget retention ve typed admission

Native API kaydı budget kimliğini fiziksel ticket'tan bağımsız tutar. Close,
sıfır HTTP charge olsa da mantıksal referans tahliye olmadan ack vermez. Open
budget preflight sayaç tüketmeden ortak gate'i kullanır; reservation değildir,
admit tekrar kontrol eder. IPC hata enum'u yalnız wire sınırında Fault'a döner.
Detay 37'dedir; henüz native retry consumer veya capability açılmadı.

**187 Rust testi + 5 compile-fail**, locked build/fmt/strict Clippy geçti.
Bağımsız son UI regresyonu **1172/1172**. Kullanıcı shell.nix/07 korunmuştur.

## 2026-10-25 — Root tool budget projection / pre-start lease kapanışı

Run.:budget artık context/application ile aynı projection nesnesidir; gerçek
root-run testi tool-context constructor'ından da geçer. Native tool/run claim
birleştirme hâlâ açıktır; bu UI lifetime bağlantısı ikinci ledger değildir.
İlk ensure öncesi sealed/expired budget RPC veya phantom starting lease yaratmaz.
Late/reentrant allocation davranışı korunur. Detay ve kapsam 36'dadır.

**1172/1172 full source ERT**, 0 unexpected, **127.16 s**; touched Werror
bytecompile/checkdoc temiz ve .elc kaldırıldı. Native baseline bu UI-only kesim
başında **184 + 5 compile-fail** idi. Kullanıcı shell.nix/07 korunmuştur.

## 2026-10-25 — Değişmez HTTP attempt snapshot paylaşımı

HTTP port captured request'i ödünç alabilir; IPC worker aynı immutable Arc'ı
tutar. Secret-bearing request/secret için Clone eklenmedi. Gerçek iki socket
testi aynı endpoint/auth/request byte'larını kanıtlar. Her execute hâlâ tek
fiziksel attempt'tir; native retry consumer henüz açılmadı. Detay 37'dedir.

**184 Rust testi + 5 compile-fail**, locked build/fmt/strict Clippy ve **26/26
focused source stream/budget ERT** geçer. Son full ERT **1171/1171** önceki
dilimindir; bu borrowing-only kesimde yeniden çalıştırılmadı. Kullanıcı
shell.nix/07 değişiklikleri kapsam dışı korundu.

## 2026-10-25 — Retry-After typed IO capture ve erken replay koruması

Native HTTP header'ı tek kez typed seconds/date/invalid/exceeded olarak ayrıştırır;
ham header metni tutulmaz. Numeric overflow veya capture sınırı artık yokmuş gibi
kaybolmaz. Native policy aynı değeri tüketir; geçici legacy adapter exceeded
bound için erken replay'i reddeder. Tam native retry/circuit consumer portu
değildir; valid Retry-After legacy clamp motoru henüz açıktır. Detay 37'dedir.

**183 Rust testi + 5 compile-fail**, locked build/fmt/strict Clippy geçer.
**1171/1171 full source ERT**, 0 unexpected, **124.03 s**; yeni gerçek HTTP ve
Emacs→core→503 regresyonları dahildir. Touched Werror bytecompile/checkdoc temiz;
geçici .elc kaldırıldı. Full native önce 26'daki scheduling varsayımını yakaladı;
bu ayrı test-contract düzeltmesinden sonra bütün native suite geçti. Kullanıcı
shell.nix/07 değişiklikleri yine korunmuştur; hesap/ücretli/kurulum çağrısı yok.

## 2026-10-25 — Record-output testindeki scheduling varsayımı

Tam native koşuda prefix doğruyken omission flag'i beklenenden farklı geldi.
26'daki OutputPage sözleşmesiyle incelendi: omission yalnız gerçekten gözlenen
discard byte'ıdır; TERM üçüncü shell write'ından önce gelebilir. Production
process/retention davranışı değiştirilmeden test daha güçlü cursor/EOF invariant'ına
bağlandı; deterministik chunk sınırı false→true geçişini kanıtlar. 29 execution
testi + 2 record testi + 15 tekrar ve strict Clippy geçti. Grep cap+1 aynıdır.
Bu bir test silme, baseline değiştirme veya gerçek omission'ı gizleme değildir.

## 2026-10-25 — Typed retry / single-probe circuit domain foundation

`api/resilience/` typed policy, bounded unbiased Full Jitter, RFC Retry-After ve
move-only circuit outcome lease uygular. Foreign same-revision lease, pre-reset/
pre-open geç sonuç ve probe cancel sınırları testlidir. Bu kesim henüz canlı
consumer portu değildir; capability ilan edilmedi, legacy retry/circuit hâlâ
canlıdır. Mailbox budget/observer/probe kompozisyon yükümlülükleri 37'dedir.

**182 Rust testi + 5 compile-fail**, locked build/fmt/strict Clippy geçer.
**1170/1170 full source ERT**, 0 unexpected, **124.27 s**; 36'daki deadline
regresyonu da bu full koşuya dahildir. getrandom 0.4.3 mevcut transitive'den
explicit dependency oldu; yeni tek çözümlenen paket httpdate 1.0.3'tür. Resmî
protokol/kütüphane ve yerel lock kaynakları kontrol edildi; ücretli/harici
uygulama çağrısı yok. Büyük Retry-After alanının mevcut IO capture'da kaybı,
canlı port öncesi düzeltilmesi gereken açık yükümlülük olarak 37'ye eklendi.

## 2026-10-25 — Budget deadline / upstream timeout ayrımı

Native `run_deadline`, fiziksel attempt `deadline`'ından ayrıldı. Owner budget
süresinin dolması artık provider circuit failure sayılmaz; collection sırasında
deadline refusal hemen project edilir. Real held-socket editor regresyonu bu
sızıntıyı kapsar. 13 focused budget ERT + 20 native budget testi, locked build,
strict Clippy ve touched bytecompile/checkdoc geçer. Önceki full ERT 1169/1169;
bu yeni regresyon ayrıca geçti. Retry/circuit motoru henüz taşınmış değildir.

## 2026-10-25 — Gerçek root-run budget cutover ve legacy motor kaldırma

Root run budget intent'i async hazırlıktan önce yakalar; logical API/retry aynı
native ID'yi kullanır. Standalone API lifetime ayrı tutulur. Native sayaçlar
tek kez project edilir; eski Elisp debit/refusal/token toplama motoru silindi.
Tool text artık provider usage diye işaretlenmez. Epoch kaybında sıfır ledger
ile yeniden açılma yoktur. Geç/reentrant allocation ve seal/drain korunur.

**1169/1169 full source ERT**, 0 unexpected, **125.26 s**, touched Werror byte
compile/checkdoc temiz; üretilen .elc kaldırıldı. 12 editor budget testi ve
gerçek root-run/HTTP path dahildir. Native baseline **170 + 4 compile-fail**.
Önceki policy testlerinin native karşılıkları ve private bulk/token-debit
helper'ının sınırı 36'da açıkça eşlenmiştir; baseline tablosu değiştirilmedi.
Constructor/seal normal-loop wiring açığı kapandı; G08 hard reservation/pricing,
native genel claim/tool/run birliği, retry/breaker ve agent/history hâlâ açık.
Kullanıcı shell.nix/07 değişiklikleri commit dışındadır.

## 2026-10-25 — Native HTTP budget admission ve drain

`ipc/api/` modülerleştirildi; `api_budget` capability ve owned open/snapshot/
close servisleri eklendi. API POST her fiziksel denemeyi IO öncesinde native
kapıdan geçirir; mevcut budget'ı atlama, foreign ID, overlap ve yeniden canlanan
closed ID reddedilir. Close yalnız charged HTTP işi join/collect olduktan sonra
yanıtlanır. Deadline admission/network/final-body egress için ortaktır; gerçek
usage bir kez toplanır. Ayrıntılı sınırlar ve kalan işler 36'dadır.

**170 Rust testi + 4 compile-fail**, locked build, fmt ve strict Clippy geçer.
**1170/1170 full source ERT**, 0 unexpected, **124.77 s**. Yedi yeni real
stdio/socket ve iki mailbox testi dahildir. Yeni bağımlılık/ücretli çağrı yok.
Henüz editor root-run consumer cutover değildir; eski Elisp budget motoru bir
sonraki bağlantı kesimine kadar korunur. Native genel claim/agent/history,
retry/breaker ve G08 reservation/pricing hâlâ açıktır.

## 2026-10-25 — Native API budget domain foundation

Typed budget meter eklendi: bounded attempt/compaction limits, checked exact
usage, missing/partial/zero ayrımı, consumed seal ve move-only completion
ticket. 13 yeni native test ve iki compile-fail sözleşmesi geçti; strict Clippy
ve fmt temiz. Önceki bütün Rust testleri de geçer. Detaylar 36'dadır.
Bu kesim henüz live consumer cutover değildir: capability ilan edilmedi,
Elisp budget silinmedi; HTTP admission/run binding ve G08 reservation açık.

## 2026-10-25 — Editor application lease API consumer cutover

POST ve model GET artık editor application'a ait native service scope'uyla
çalışır; root standalone scope'una sessiz fallback yoktur. Thin lease portu
coalescing, detached strings, late acquisition/close, reentrant observer ve owner
startup cancellation sınırlarını korur. Cyclic owner graph DTO gibi deep-copy
edilmez; nested startup cleanup'ları stack'te tutulur. Detaylar 35'tedir. Bu,
henüz native user-history/run import'u değildir; diğer tool service tüketicileri
eski explicit standalone scope'ta kalır.

**1169/1169 full source ERT**, 0 unexpected, **125.41 s**; son reentrant failure
guard'ı sonrası **47/47** focused source ERT geçer. Touched checkdoc ve
warning-as-error bytecompile temiz; geçici .elc kaldırıldı. Rust baseline aynı
**148 + 2 compile-fail**'dır. Real stdio API scope isolation ve drain kabulü
dahildir. Canlı hesap/ücretli CLI/kurulum yok. Antigravity resmî `agy` headless
protokol dokümanı bulundu; güncel izin/cumulative-usage/Ready koşulu 03 bölüm 4'e
eklendi. PATH'te codex/opencode var, agy/antigravity/claude görünmedi; bu yalnız
read-only presence kontrolüdür, sürüm/auth/Ready kanıtı değildir.

Bütçe ön incelemesi yeni bir wiring açığını doğruladı: budget.el constructor/
seal normal loop tarafından çağrılmıyor; HTTP/tool'da yalnız optional context
tüketicileri ve testler var. Native API budget geçişi canonical sayacı gerçek
run'a bağlamalı; helper testlerini taşımak tek başına kapanış değildir. Native
genel claim/budget/retry/breaker, model store ve agent/history hâlâ açıktır.
Kullanıcı shell.nix/07 değişiklikleri commit dışındadır.

## 2026-10-25 — Drain-before-release application close ve API fairness

Native `application/close` public stdio consumer'a bağlandı. Host `Live`/
`Draining` entry ile admission/publication'ı geri alır; HTTP/read/command/job/IO
ve actor ledger boşalmadan closed reply veya application slot release yoktur.
Önkoşul 34'te anlatılır; henüz editor application/run consumer'ı taşınmış sayılmaz.

Continuous foreign delta üretiminin completed API join'ini starve ettiği testle
yeniden üretildi (önce kırmızı). Joined worker'ın sonlu FIFO-prefix+terminal
barrier batch'i ile düzeltildi; yeni foreign event'ler batch'i uzatamaz. Network
16 + retirement 17 sınırı explicit, body-before-terminal ve cancel/drain korunur.

**148 Rust testi + 2 compile-fail**, locked build/test, fmt, strict Clippy temiz.
**1160/1160 full source ERT**, 0 unexpected, **124.68 s**. Real pipe/socket,
sibling isolation, stale rejection, 80 close/recreate, revoked review/late reply,
process reap-before-close ve shutdown ordering testlidir. TLC application
6151/1681/depth25; transport 1810/693/depth13 hatasız. Concrete refinement
ispatı iddia edilmez. Canlı hesap/ücretli çağrı yok; shell.nix/07 kullanıcı
değişiklikleri commit dışındadır. Native run/budget/retry, metadata ve agent
portları, ayrıca dört app backend'i hâlâ açıktır.

## 2026-10-25 — Native auth/header assembly

Bearer/x-api-key seçimi, format defaults, case-insensitive provider overrides
ve header bindings Rust api/auth sınırına geçti. Elisp auth/header üretim
motorları silindi; credential çözümleme UI portunda kaldı. Client POST, catalog
GET ve immutable retry auth capture kullanır. Header injection/ambiguity/bounds
HTTP öncesi reddedilir. Credential/tenant değişince opaque continuation scope'u
da değişir; detay ve fingerprint sınırı 33_NATIVE_AUTH_HEADERS.md'dedir.

**141 Rust testi + 2 compile-fail**, locked build/test, fmt ve strict Clippy
temiz. **1160/1160 full source ERT**, 0 unexpected, **124.50 s**. Ek **82/82**
focused test; gerçek loopback auth/header GET/POST ve queued secret mutation
dahil. Warning-as-error bytecompile ve touched checkdoc temiz; geçici .elc
çıktıları kaldırıldı. Build tamamlanmadan başlatılan bir ERT koşusu old-binary
DTO mismatch ile reddedildi; rebuild sonrası tekrar geçer. Gerçek hesap/ücretli
çağrı yok. Native budget/claim/retry/breaker, model store, agent/history ve app
backend'leri roadmap'te açık. Kullanıcı shell.nix/07 commit dışında korunur.

## 2026-10-25 — Native request-policy cutover

Sampling/cap/reasoning policy ve default/format/provider merge `api/policy/`
altına taşındı. Elisp parameters.el ile request/registry karar motorları silindi;
UI yalnız exact metadata ve raw tuning snapshot'ını gönderir. Explicit null,
tek cap alanı, finite temperature, positive limit ve extras bypass reddi
native'dir. Model-specific capability doğrulaması hâlâ açıktır; ayrıntı 32'dedir.

**136 Rust testi + 2 compile-fail**, locked build/test, fmt ve strict Clippy
temiz. **1159/1159 full source ERT**, 0 unexpected, **124.46 s**; high-level chat
POST gerçek loopback native policy kabulü dahil. Warning-as-error bytecompile
ve touched checkdoc temiz. Son common POST/extras guard değişikliği ardından
21 focused Rust testi tekrar geçer. Geçici .elc çıktıları kaldırıldı. Canlı
hesap/ücretli çağrı yapılmadı. Native retry/breaker/budget, model store ve core
agent/history hâlâ açık; kullanıcı shell.nix/07 commit dışında korunur.

## 2026-10-25 — Native wire ve prompt-cache cutover

HTTP admission artık captured typed formatı kullanır; request/response blocks,
cache sınırları ve checked cache usage Rust'a taşındı. `api/cache.el` ve wire
codec engine'leri silindi; UI canonical DTO/metadata projection kalır. Opaque
continuation endpoint/model/provider/format revision'ına bağlıdır. Detay ve
eski testlerin native eşlemesi 31_NATIVE_WIRE_AND_CACHE.md'dedir.

**130 Rust testi + 2 compile-fail**, locked build/test, fmt ve strict Clippy
temiz. **1163/1163 full source ERT**, 0 unexpected, **124.50 s**. Bytecompile
warning-as-error ve touched checkdoc temiz; geçici .elc çıktıları kaldırıldı.
Ek 3/3 focused test son doc/test-call cleanup'ını doğrular. Real Emacs→Rust→
loopback wire/cache round-trip dahildir; canlı hesap/ücretli çağrı yoktur.
Request policy, retry/breaker, model metadata ve core agent/history henüz açık;
API + dört uygulama backend kapsamı değişmedi. Kullanıcı shell.nix/07
değişiklikleri commit dışında tutulur.

## 2026-10-24 — Provider catalog ve model HTTP/SSE cutover

Kullanıcının yeni API önceliğiyle ilk kesim `36e0e1a`: 162-provider/5-wire
baseline Rust asset ve validated provider/catalog snapshot'a taşındı. Eski
1416 satırlık Elisp literal catalog kaldırıldı; core ready öncesinde editor
projection beslenir, explicit kullanıcı kayıtları ezilmez. Synchronous startup
aynı Rust asset'ini okur; ayrı metadata kopyası yoktur. Detay/öğrenim 29'dadır.

İkinci kesim: gerçek chat/model-discovery GET/POST ve SSE IO Rust api/stream/
ve owned ipc/api service'e bağlandı. Elisp SSE parser/accumulator, HTTP
watchdog/flush ve redirect helper engine'leri silindi; plz HTTP çağrısı yoktur.
Plz yalnız henüz taşınmamış retry hata DTO'ları için kalır. Curl global API
prerequisite değildir. Bounded final body pages frame limitini yükseltmeden
1.2MiB katalog aktarır; owner/cancel/shutdown/EOF socket drain testlidir.
copy-tree'nin string alias'ı mutation testiyle yakalanıp explicit URL/body/
header string capture ile düzeltildi. Secret/timeout/limit sınırları 30'dadır.

**122 Rust testi + 2 compile-fail**, locked build/test, fmt ve strict Clippy
temiz. **1165/1165 full source ERT**, 0 unexpected, **123.39 s**. Eski Elisp
parser/pressure engine testleri Rust contract fixture'larına taşındı; sayıdaki
azalma engine testlerinin iki dilde yinelenmesinin kaldırılmasıdır. Yeni real
loopback/capture/consumer testleri dahildir. Warning-as-error bytecompile ve
checkdoc temiz. Bounded TLC transport 1810/693/depth12 hatasız; bu HTTP portu
için concrete refinement ispatı değildir. Gerçek hesap/ücretli API çağrısı yok.
Son callback guard değişiklikleri ardından ek **74/74** source ERT geçer;
geçici bytecompile çıktıları kaldırıldı. Sistem DNS syscall preemption ve
sağlayıcı tarafı faturalama iptali garantisi verilmez (30'daki sınırlar).

Kalan wire/request policy, model metadata normalization/store, retry/circuit
ve editor history/agent orchestration henüz Rust'ta değildir; API geçişinin
tamamı bitmiş sayılmaz. Registry bu tüketicilerin UI/config facade'ı olarak
kalır. API + dört installed-app backend kapsamı değişmez. Kullanıcı shell.nix
ve 07 fence değişiklikleri commit dışında korunur.

## 2026-10-24 — Native Git status ve complete-output portu

`0cbd4a5` ardından `git_status` fixed-argv Git/Rust portuna bağlandı; Elisp
porcelain parser, file-status struct ve section formatter kaldırıldı. Mevcut
Magit-tarzı rapor/Unicode/NUL/rename/conflict davranışı Rust'a taşındı. Diğer
Git komutları/mutation ve shared process runner henüz kaldırılmaz. Search ve
Git için owned editor read task `bridge/read.el` içinde tekleştirildi.

Complete capture iki stream'de byte overflow'u Failed yapar; malformed NUL/UTF-8
InvalidToolOutput'tur ve completion actor'a teslim edilmeden success düşürülür.
Stop-on-bytes exact digest/review'a bağlıdır. Optional index locks kapalı,
executable fsmonitor disabled, worktree root explicit; host-global ignore ve
linked worktree korunur. Detay/öğrenim/sınırlar 28_NATIVE_GIT_STATUS.md'dedir.

**105 Rust testi + 2 compile-fail**, locked build/test, fmt ve strict Clippy
temiz. İndeks byte/inode/mtime değişmeme testi + ordinary-status pozitif
kontrolü, fsmonitor marker ve external core.worktree scope fixture'ları dahil.
**1185/1185 full source ERT**, 0 unexpected, **121.68 s**; 17 odaklı integration
ve 2 yeni capture/parent-cancel testi. Warning-as-error bytecompile/checkdoc
temiz, geçici .elc kaldırıldı. Bounded TLC process-session 129/42/depth7,
approval 8194/1536/depth11, transport 1810/693/depth12 hatasız; yeni concrete
Git/complete-output hattı için refinement ispatı değildir. API + dört app
backend kapsamı açık; kullanıcı shell.nix/07 değişiklikleri commit dışında.

## 2026-10-24 — workspace_grep native consumer cutover

`6506899` record-budget prerequisite ardından rg/GNU grep adapter, scoped
workspace/grep capability, immutable result context ve owned Elisp façade
bağlandı. Eski Elisp grep argv/runner/truncation/formatter engine'i silindi.
GNU fallback, global cap+1 lookahead, no-match=1, byte/timeout failure ve
config capture korunur. Root/cwd yanında target descriptor identity de spawn
öncesi doğrulanır. Ayrıntılar 27_NATIVE_WORKSPACE_GREP.md'dedir.

Gerçek test rg positive-glob sırasının eski negative exclusion'ı geçersiz
kılabildiğini yakaladı: user include önce, literal exclusions sonra uygulanır.
Stderr byte overflow da record-capture failure'dır; late overflow sahte başarı
üretemez. timeout=nil native ve forward-waiter düzeyinde unlimited kalır;
owner/Stop/disconnect cleanup korunur. API ve dört application backend açık.

**93 Rust testi + 2 compile-fail**, locked build/test, fmt ve strict Clippy
temiz. Forced rg/GNU matrix, oversized frame/ping, slow unlimited search cancel
ve actual /proc reap testleri dahil. **1183/1183 full source ERT**, 0 unexpected,
**121.60 s**; odaklı 8 real-pipe/public regression + 3 capture/lifecycle testi.
Warning-as-error bytecompile/checkdoc temiz, geçici .elc kaldırıldı. Bounded TLC
approval 8194/1536/depth11, transport 1810/693/depth13, process-session
129/42/depth7 hatasız; concrete adapter için refinement iddiası yoktur.
Shared process.el Git/diff/webfetch ve diğer tüketiciler için kalır. Kullanıcı
shell.nix ve 07 fence değişiklikleri commit dışında korunur.

## 2026-10-24 — Ortak record-capture bütçesi

`workspace_grep` için prerequisite: typed prefix record budget, bounded watch
observation ve supervisor-owned intentional stop; byte exhaustion ayrı failure.
Accepted exit-code policy exact action digest/review'a bağlıdır; genel komut
default'u değişmez. Detay ve scope sınırları 26_RECORD_CAPTURE_BUDGET.md'de.
Elisp grep henüz kesilmediği için engine bu commit'te korunur.

**81 Rust testi + 2 compile-fail**, locked build/test, fmt ve strict Clippy
temiz. **1180/1180 full source ERT**, 0 unexpected, **116.39 s**; yeniden
build edilmiş binary ile odaklı exact-review testi de geçti. Warning-as-error
bytecompile/checkdoc temiz, geçici .elc kaldırıldı. Bounded TLC process-session
129/42/depth8 ve approval 8194/1536/depth11 hatasız; yeni concrete record
observer için formal refinement iddiası yoktur. Kullanıcı shell.nix/07
değişiklikleri kapsam dışında korunur.

## 2026-10-24 — Interactive session consumer cutover

Native idle prerequisite `a843d7b` ardından session OS spawn/stdin/EOF/signal,
PID/PGID ve idle timer engine'i Elisp'ten kaldırıldı. `bridge/command.el`
ortak immutable editor capture'dır; Bash ve session aynı environment/policy/
mode-revision freshness kontrolünü kullanır. Ayrıntılar 25'tedir.

Owner callback lease kill hook'tan önce revoke edilir; buffer-live-p tek
başına yeterli değildir. Geç ack/receipt, source loss, sibling isolation ve
unknown cleanup/legacy zero ayrımı sınandı. Start artık on-ready ile async;
eski sync engine veya fallback yoktur. Shared process.el diğer OS consumer'lar
taşınmadığı için korunur. API + dört uygulama backend kapsamı açık kalır.

**1180/1180 full source ERT**, 0 unexpected, **117.01 s**; odaklı 19/19;
warning-as-error bytecompile/checkdoc temiz, geçici .elc kaldırıldı. Rust
değişmedi: önceki **74 test + 2 compile-fail** kanıtı geçerlidir. Bounded TLC
process-session 129/42/depth7, approval 8194/1536/depth11 ve transport
1810/693/depth13 yeniden hatasız; yeni refinement iddiası yoktur. Kullanıcı
shell.nix ve 07 fence değişiklikleri commit dışında korunur.

## 2026-10-24 — Native idle policy prerequisite

Bash cutover `a7ecdfa` ardından `IdleTimeout` ayrı tip, exact digest/review,
`process_idle_timeout` capability ve bounded I/O observation eklendi. Süreç
pipe kodu `process/io.rs`, idle observation `process/activity.rs` içine ayrıldı.
Partial stdin write da activity sayılır; late/coalesced pulse eski timeout'u
canlandıramaz. Ayrıntı ve yeni kanıt sınırı 24_NATIVE_IDLE_POLICY.md'dedir.

**74 Rust testi + 2 compile-fail**; locked build/test, fmt, strict Clippy
temiz. **1170/1170 full source ERT**, 0 unexpected, **94.48 s**; warning-as-error
bytecompile/checkdoc başarılı, geçici .elc kaldırıldı. Yeni idle modeli için
formal refinement iddiası yoktur. Ayrı Elisp interactive session motoru henüz
bu porta bağlanmadığından korunur; sıradaki kesimde adapter'a dönüşecektir.

## 2026-10-24 — Bash OS engine cutover

`eb59416` owned job client/claim/merged pipe; `5f5994d` incremental UTF-8
polling ve shared permission snapshot ardından Bash gerçek Rust job portuna
bağlandı. Elisp Bash spawn/PID/PGID/signal motoru kaldırıldı; editor log,
cached UI routing/pruning ve presentation korunur. No fallback. Ayrıntı ve
callback/approval uyumluluk sınırı 23_NATIVE_BASH_CUTOVER.md'dedir.

Nix 202 env entry bulgusu: 512-entry bounded capture, mevcut 64KiB byte
sınırı korunarak test edildi. Shutdown RPC 5s -> 12s; dış kapanış 15s.
TERM-ignore child testi gerçek drain cevabı ve /proc temizliğini denetler.

**1168/1168 full ERT expected**, 0 unexpected, **93.02 s**; **66 Rust testi +
2 compile-fail**; fmt, locked build/test, strict Clippy, warning-as-error
bytecompile ve checkdoc başarılı. .elc çıktıları kaldırıldı. Bounded process
535/179/depth9, process-session 129/42/depth7, approval 8194/1536/depth11
yeniden hatasız; yeni concrete runtime için refinement ispatı değildir.

Kalan shared process/session, policy parser ve read/search/Git tüketicileri
taşınmadan silinmez. API -> Rust + dört application backend açık kapsamdır.
Kullanıcıya ait shell.nix ve 07 fence değişiklikleri commit dışında korunur.

## 2026-10-24 — Persistent execution ve owned job köprüsü

Kullanıcının devam/commit döngüsüyle üç küçük dilim:

1. `5c787da`: gerçek unlimited deadline ve bounded rolling-tail archive;
   timeout/retention action digest'e bağlı. Ayrıntılar 20'de.
2. `db5aeb6`: ayrı lifetime'lı process jobs, aynı actor/gate/supervisor,
   bounded nonblocking stdin/read ve scoped wire. Ayrıntılar 21'de.
3. Owned Emacs job client, receipt/claim lease, source close drain, gerçek
   merged stderr pipe ve environment değerlerini gizleyen exact approval.
   Ayrıntılar 22'de. Bash consumer henüz eski engine'den kesilmedi.

Güncel kaynak ERT **1156/1156**, 0 unexpected, **65.07 s**; Rust **65 test +
2 compile-fail**; fmt, locked build/test ve strict Clippy sıfır uyarı.
Warning-as-error bytecompile/checkdoc başarılı, geçici .elc kaldırıldı.
Yeni concrete job tablosu/lease için formal refinement iddiası yoktur.
Kullanıcıya ait shell.nix ve 07 fence değişikliği commit dışında korunur.
API -> Rust ve dört uygulama backend'i açık kapsam olarak devam eder.

## 2026-10-24 — Unix/GNU bileşimi, klasörleme ve canlı command/approval köprüsü

Kullanıcı kararı: her araç kendi işini yapar; Rust `ls`/`rg`/`git` motorlarını
yeniden yazmaz. İlke ve argv[0]/multicall öğrenimi 17'de; komut/onay wire ve
Emacs presenter ayrıntıları 18'de; native scanner yerine GNU ls sözleşmesi 19'dadır.

Küçük commit sırası:

1. `39d2666`: `.codex` bileşim kararı ve davranış değiştirmeyen klasörleme.
   `src` altında application/host, domain, ipc, process, security ve workspace
   sorumlulukları ayrıldı; yalnız composition/shared constants/error kökte kaldı.
2. `9c9698a`: standalone `tool/execute`, exact-action reverse approval,
   shared supervisor, nonblocking completion ve cancel/EOF/drain.
3. `5988320`: özel Rust directory scanner ve artık tüketilmeyen fd-walking kodu
   silindi; mevcut Elisp `list_files`/`ls`/`dir` ortak Rust gate üzerinden GNU ls
   çıktısı döndürüyor. Scanner testleri yeni sözleşmeye eşlendi; engine fallback yok.
4. Ardından owned Emacs approval presenter, public `kargu-bridge-execute`,
   unsolicited/replayed/stale UI reddi ve negotiated approval frame sınırı eklendi.

Güncel doğrulama: **1151/1151 full ERT expected, 0 unexpected**, **49.56 s**;
güncel binary + kaynaklar (.elc yok). **52 Rust testi + 2 compile-fail**;
locked build/test, fmt ve katı all-target Clippy sıfır uyarı. Değişen Elisp
üretim/test dosyaları warning-as-error bytecompile ve checkdoc temiz.
Geçici compile çıktıları kaldırıldı. Nix OpenPGP autoload ortam bildirimi
derleme/test hatası değildir; kontrollerin exit kodu 0'dır.

Bounded TLC yeniden hatasız: application 6151 generated/1681 distinct/depth25;
approval 8194/1536/depth11; process 535/179/depth9; transport 1810/693/depth13.
Bu mevcut soyut modellerin regresyon kapısıdır; gerçek Rust/Emacs/OS davranışının
refinement veya sınırsız-state ispatı değildir. Remote CI, gerçek provider,
harici uygulama/login ve ücretli CLI/MCP testi yapılmadı.

Güncel sınırlar: `find_files` geçici olarak native motorunu kullanır; sıradaki
arama portlarında harici araç bileşimi esastır. Genel Bash/job executor hâlâ
Elisp'tedir; interactive stdin/status/output/poll/continuation adapter'ları
tamamlanmadan silinmez. Yeni program/argv portu explicit timeout ve EOF stdin
ile noninteractive'dir; full agent/provider run cutover'ı değildir. Sabit GNU
ls salt-okunur tüm modlarda, genel komut Agent + explicit approval yolundadır.
Eski fd-rooted listing garantisi güncel ls çıktısına atfedilmez.

01 generic standartları değiştirilmedi. `todo.md` G03–G13, API -> Rust ve dört
uygulama backend'i kapsamı açık kalır. Kullanıcının `shell.nix` ve çalışma
sırasında görülen `.codex/07_GECIS_3.md` fence değişikliği korunup commit dışında
bırakıldı. Aşağıdaki önceki dilim kayıtları tarihsel kanıttır, güncel strateji
veya implementasyon durumunun yerine geçmez.

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
