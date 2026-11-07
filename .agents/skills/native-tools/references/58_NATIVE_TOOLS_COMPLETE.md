# Todo 2: kalan native araç tüketicilerinin kapanışı — 2026-10-27

Kullanıcı todo 2'nin tümünü bitirmeyi açıkça istedi. Önceki read/search/status,
Git read, file ve skill portları korundu; kalan Git mutations, toolchain/deps,
webfetch ve son consumer audit'i tamamlandı. Edit/sensör/run/backend grupları
kapatılmadı. Kullanıcının 07 ve shell.nix değişiklikleri kapsam dışı tutuldu.

## Git: tek kapalı niyet → tek onay → tek yazma

`git/mutate` / `git_mutation` kapalı sorguları stage/unstage/commit, branch
create/switch/delete ve stash push/explicit apply'dır. Model root, program veya
argv seçemez. Agent dışındaki kipler ve geçersiz model yolları preflight child
başlamadan reddedilir. Mesaj/branch/literal path/stash selector tipleri boundary'de
ayrıştırılır. Native builder gerçek Git'i kullanır, Git motoru yeniden yazılmaz.

Mevcut Commands Preparing/Review/Running/Finalizing/Discarding durumları ve
ExecutionGate/ProcessSupervisor paylaşılır. Layout preflight drain olur; bounded
repo/index/HEAD/ref/config evidence yakalanır, object resolution aynı evidence ile
çalışır ve final scope tekrar doğrulanır. Shared Arc<ActionSnapshot> nesnesi
ön-onay/son-launch arasındaki scope'u korur; yeni bir onay deposu yoktur. Var/yok,
inode/content revision ve dizin üyeliği/selected path kanıtı action digest'e
bağlanır. Normal symlink dosyalarında link'in kendi lstat revision/bytes'ı alınır;
hedefine traversal yapılmaz. Mutasyon paths literal'dir, .git/escape reddedilir.

Final review actual executable/argv/environment/cwd, session/run/config/policy,
timeout/output ve orijinal root/query intent'ini bağlar. Generic command review'ın
exact comparison'ı gevşetilmedi; Git adapter'ı native closed intent + displayed
actual argv'yi doğrular, ikinci bir Elisp argv engine'i kurmaz. PATH/environment
ilk yield öncesi yakalanır; repo yönlendiren GIT_* override'ları çıkarılır,
explicit global/system config ve author/committer settings korunur. Mutations
hooks/filters/signing çalıştırabileceğinden ExecutesArbitraryCode sınıfındadır;
SafeReadOnly sayılmaz. Salt-okunur Git'in isolated profile'ı değiştirilmedi.
Mesaj boşluğu doğrulanır fakat metin trim edilmez: orijinal query, onay intent'i
ve gösterilen argv aynı byte dizisini korur; baş/son boşluk gerçek ERT testlidir.

Unstage varsa captured HEAD'e reset, gerçek unborn branch ise cached rm seçer.
Eksik OID tek başına unborn kanıtı değildir: bounded pinned HEAD symbolic ref
okunur; `show-ref --exists` yalnız missing exit 2 ile unborn'a izin verir.
Corrupt HEAD/ref başka write'a veya kör fallback'e dönüşmez. Stash apply review'da
immutable commit OID gösterir; reflog reorder o OID'yi değiştirmez. Apply entry'yi
silmez; pop/drop yoktur. Branch/ref/index değişikliği delayed approval'ı reddeder.

Nil Git timeout unlimited command lifetime'dır; review 300 saniyelik ayrı sınırda
kalır. Finite command timeout execution'a uygulanır. Cancel/reject/deadline ve
missing capability legacy write başlatmaz. Issued mutation hiçbir terminal yolda
replay edilmez; iptal/publication/frame/UTF-8 hatası sonrasında `outcome_unknown`
döner. Nonzero/timeout/quota result'ı da partial/unknown metni taşır, başarı prefix'i
sayılmaz. Hook/signer descendant'ları TERM/grace/KILL/reap drain olmadan native
owner/admission bırakılmaz. Bir Git lock kalmış olabilir; otomatik rollback yoktur.

Sınır: metadata revision evidence filesystem lock değildir. `.` gibi toplu paths
bütün worktree dosya içeriklerinin atomik snapshot'ını iddia etmez. User/global
hook/config davranışı onaylı arbitrary-code işidir; OS sandbox kurulmadı. Bounded
4096-entry evidence ve cooperative OS metadata checks unsupported/oversized scope'u
explicit hata yapar. SHA-1/SHA-256 × files/reftable × main/linked gerçek Git testli.

## Toolchain ve dependency: yürütmesiz native metadata

`workspace/probe` / `workspace_probe`, aynı dört read slotu ve gerçek blocking
worker join sahipliğini kullanır. Metadata-only SafeReadOnly sınıfı, command/shell
çalıştırma yetkisi taşımaz. CLI presence yalnız captured explicit exec-path içindeki
regular-file metadata ve X_OK access kontrolüdür; --version, package script, installer veya gizli
shell başlamaz. Canlı Eglot/package/library gerçekleri editör interop'udur.

Kapalı declarative detector DSL path, any/all, root-only/recursive extension'dır.
Recursive detection mevcut FindFilesPlan'ı paylaşır; yeni genel tarayıcı yoktur.
Profile/detector/path/command/list/depth/visit limitleri boundary'de sınırlıdır;
profile ID tekrarına izin verilmez. File/directory visit limitleri ayrı tiplerdir.
JavaScript lockfile/script-presence, TypeScript fallback, Java Gradle/Maven/wrapper
ve Elisp gerçek runner seçimi Rust'tadır. package.json pinned, strict bounded
256 KiB capture'dır; script body sonuç/log'a taşınmaz. Bozuk/oversized metadata veya
scan cap `complete=false` verir; passive language/toolchain bunu başarılı tam
classification saymaz. Elisp'te runner yoksa test command yoktur; sıfır yüklü test
başarısı uydurulmaz. Custom callable detector/resolver açık dönüşüm hatasıdır;
user metadata artık declarative profiles/static commands olarak verilmelidir.

Run claim'den sonra project→connection→skills hazırlanır. Eksik mandatory CLI,
credential/model/ilk POST ve unsent history commit öncesi run'ı reddeder. Chat'in
senkron admission'ı yalnız Emacs package facts kullanır; eski CLI cache yeni
native probe'u engelleyemez. Setup aynı async portu bağımsız schema-only açılışta
da kullanır; optional API facade yüklenmez. Test root grant'i explicit'tir;
parent /tmp projesinin tesadüfi keşfi fixture'ı kirletmez.

Editor observation buffer/session/root/settings/source ve newest intent'e bağlıdır;
inputs ilk yield öncesi detach edilir. Callback/public getter kopyaları native
cache'i değiştiremez. Kill/mode/Stop/elapsed absolute deadline ve closed parent
late result'ı yayınlatmaz. Passive getter filesystem/IPC başlatmaz; CLI bilginin
olmaması :unknown'dır. Origin key path spellings yalnız memory'de normalize edilir;
root'un slash farkı aynı native observation'ı yanlışlıkla geçersiz kılmaz.

## Webfetch: native policy + owned HTTP

`workspace/webfetch` / `workspace_webfetch` public unauthenticated HTTP(S) GET'tir.
Kapalı URL/character/deadline tipleri aynı read pool'una girer. Numeric host native
IP parser/policy'den geçer; named host her hop'ta yeniden native DNS ile çözülür.
Yalnız public numeric address seçilip reqwest resolve override ile pinlenir; URL
host normalized/pin key ile aynı tutulur (trailing-dot bypass yok). Host ve TLS
identity korunur, proxy inheritance ve automatic redirects kapalıdır. Userinfo,
local names, private/special-use IPv4/IPv6, mapped/NAT64/transition ranges reddedilir.
Resolver argv/Elisp code injection yüzeyi kaldırıldı; getent/curl/Emacs child yoktur.

En fazla beş redirect; her relative/absolute location yeniden URL/address gate'inden
geçer. 5,000,000-byte stream limiti content-length olsa da olmasa da uygulanır.
UTF-8/NUL kontrolü ve character truncation native'dir. HTTP error body başarılı
belge olarak dönmez. İlk headers/body/cancellation total deadline içinde; connect
5 s, configured DNS ve total deadline ayrı ayrı 1..30000 ms'dir. Bounded body,
status/empty/informational response, relative redirect/host, same-host rebinding,
DNS mixed/private/numeric bypass, quota/invalid UTF-8/cancel/timeout testlidir.

OS NSS blocking resolver çağrısı güvenle kill edilemez. Owned spawn_blocking join
cancel/deadline'da bırakılmaz; sonuç geçse bile yalnız actual join sonrası worker
slotu serbest kalır. Bu cooperative DNS/FS sınırı hard wall-clock OS interrupt
iddiası değildir. Emacs starter/callback asenkrondur. Test transport override'ı
private cfg(test) kapsamındadır; production IPC'de local address bypass yoktur.
Ağ corpus'u yalnız controlled loopback fixture'larına dial eder. Bozuk proxy env
ile de aynı corpus geçer; canlı internet/hizmet hesabı kullanılmadı.

## Son consumer / köprü envanteri

Silinenler: Elisp Git generic runner/argv/ref/path/fallback/mutation engine,
webfetch HTTP/parser/redirect/egress ve net/address/net/resolve, toolchain dosya/
package-script/executable karar motorları ve artık tüketicisiz fs-has-file/
fs-has-extension helpers. Eski engine'e bağlı testler native corpus/consumer'a
aktarıldı; adres/HTTP parser unit sayısındaki azalma kabul kapsamının silinmesi
olarak kullanılmadı. Ortak registry/alias/mode gate değişmedi.

Shell view service key'i canonical root + source buffer + session identity'dir.
Global default service, job aggregate, foreground handle ve counter aynaları
silindi. Her service kendi p1 sayacını/table'ını taşır; output view yalnız exact
job handle'ını iptal eder. Aynı project/session label'da iki chat foreign job'a
ulaşamaz. Source close/mode kendi service/hook'larını bırakır; yeni service admission'ı
retired session service'lerini kapatır; eski session view yeni owner'a taşınmaz. Native handle dispose actual
supervisor drain'in yerine geçmez; native owner drain'i korur.

Sonraki gruplar için kalan gerçek tüketiciler (native tool fallback'i değil):

- tools/process.el: tools/diff.el Git apply/journal hazırlığı (todo 3),
  tools/dape/{context,preflight}.el (todo 4), chat/session.el bounded listing
  worker'ı (todo 7).
- files/worker.el ve files/async.el: Dape source capture (todo 4); full edit
  snapshot/transaction editor adapter'ı (todo 3).
- Credential/auth-source worker ve package/live Eglot/Magit/UI portları native'ın
  erişemediği editor interop'tur. Bridge/builtin Bash shell binary locator'ı da
  executable launch interop'udur; toolchain discovery veya legacy tool runner
  değildir. Genel G03–G13 global retention/log/context/edit/run açıkları kapatılmadı.

## Kabul kaydı

- Full source ERT: 1271/1271 expected, 0 unexpected/skip; 163.740942 s,
  08:09:15 +0300. Son whitespace-message fix'i 36/36 Git ERT'de
  ayrıca doğrulandı; eski binary ile önce red üretildi.
- Locked Rust: 344 native + 24 compile-fail = 368; 36 suite, sıfır failed/ignored.
  Gerçek hook ve signer TERM-ignoring descendant fixture'ları da içerilir.
- `cargo fmt --check`, locked strict Clippy all-targets + unwrap/expect/panic
  deny; 42 değişen Elisp dosyasında Werror bytecompile ve production checkdoc temiz.
- Controlled webfetch corpus bozuk HTTP_PROXY/HTTPS_PROXY/ALL_PROXY ve boş
  NO_PROXY altında da 6/6; gerçek curl/resolver fallback'i yoktur.
- Exhaustive application TLC project→connection→skills: 17545 generated / 4624
  distinct, queue0, depth37. Approval 8194/1536 depth11; process 535/179 depth9;
  connection 602836/101708 depth23; transport 1810/693 depth14; hepsi queue0,
  hata yok. Bounded soyut modellerdir; concrete OS/network/Git formal proof değil.
 Testler repository temp roots, synthetic credentials/config,
explicit approvals ve controlled local HTTP kullanır. Canlı Emacs reload,
credential migration, araç indirme/kurulum, hesap çağrısı, merge veya push yoktur.
01 audit'i bu değişikliklerin typed boundary, no unsafe/panic/indexing,
resource-owning continuation ve zero-warning kapılarını kapsar; tüm eski Rust
kaynaklarının mimari uyum sertifikası veya OS/TLS/Git formal refinement değildir.
