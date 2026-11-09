# Açık işler — birlikte çözülecek gruplar

İlk inceleme tabanı: 32e917b, 2026-10-22; tarihsel ERT: 1116/1116.
Son kaynak/görev denetimi: 2026-11-03, `81ed1e3` tabanı.
Tarama: 397 production kaynak + 176 test/destek kaynağı (573 tracked Rust/Elisp).
Son çalıştırılmış kabul (2026-11-07, `f01a286` tabanı): fmt + strict Clippy,
593 locked Rust (32 compile-fail dahil), build ve `tests/ci/run-ert.sh full`
ile temiz HOME'da 1448/1448 ERT. Bütün 207 üretim Elisp dosyası warnings-as-errors
byte compile + check-parens + checkdoc'tan geçer. Aşağıdaki daha eski sayılar
yalnız ilgili dilimin tarihsel kanıtıdır.
Rust göçünün güncel uygulama/test kaydı: [.agents/skills/native-migration/references/12_MIGRATION_PROGRESS.md](.agents/skills/native-migration/references/12_MIGRATION_PROGRESS.md).
G02 bağlantı/metadata sözleşmesi ve kalan köprüler: [.agents/rules/connection-ownership.md](.agents/rules/connection-ownership.md).
Tamamlanan geçiş alt maddeleri takip için `[x]`, kalan işler `[ ]` ile tutulur;
tekrarlanan iş tarifleri birleştirilir. Bir çekirdeğin testinin geçmesi,
native tüketicilerin ona bağlandığı anlamına gelmez. Eski ARCH/MOD/DEEP/RISK kimlikleri kaynak
eşlemesidir; yeniden numaralanmaz ve bağımsız ikinci iş listesi oluşturmaz.

K = kod yolu doğrulandı; Y = kontrollü yeniden üretildi; D = ek kanıt/ölçüm
gerekiyor. Mimari hedef ve uyumluluk isteği, doğrulanmış bug sayılmaz.
Önce yetki/veri kaybı/yanlış başarı, sonra yanıt verebilirlik ve ölçümlü performans.
Aşağıdaki kaynak yolları kargu/ altında; tests/ ve proof/ depo kökündedir.

## Çalışma şekli

Kullanıcının atadığı kapsam içinde ilerlenir. Bu listenin hazırlanması veya bir
alt ajana verilmesi, listelenen tüm uygulamaların otomatik yürütülmesi değildir.
Atanmış işi somutlaştırmak için yeniden genel izin döngüsü kurulmaz; kapsam ve
ürün kararı gerektiren açık noktalar koordinatöre bildirilir.

1. Önce ilgili açık alt işin mevcut portlarını/testlerini oku; değişecek dosyaları,
   silinecek consumer'ları, bağımlılıkları ve küçük commit sınırını belirle.
   Çalışan Rust motorunu veya ortak sözleşmeyi yeniden tasarlama.
2. Uygulama: anlamlı regresyon → düzeltme/refactor → ilgili Rust/ERT →
   derleme/checkdoc → commit. TLA+/TLC yalnız TLA+ kaynağı değişmişse çalıştırılır;
   değişmeyen modelin önceki sonucunu yeniden üretmek kabul şartı değildir.
3. Kapanan maddeyi `[x]` ile işaretle; kısmen kapanan üst grup açık kalsın.
   Yeni bulguyu aynı kök nedense mevcut gruba, değilse ilgili grubun sonuna ekle.
   Kanıtsız risk, yalnız yeşil tekrarlarla kapatılmaz.
4. Bir grubun ortak sözleşmesini sonraki grup yeniden tasarlamaz. Gerekli dar
   bağlantıyı kendi tüketicisinde yapar; son tüketici taşınmadan köprü silinmez.
   Kalan global tüketicilerin isimleri kapanışta kaydedilir, son silme G13'tedir.
5. Yerel skills.md (kök ve `.agents/rules/`) stage edilmez; kanonik kopya `.agents/rules/kargu-laws.md`; kullanıcıya ait .gitignore/yerel dosyalar korunur.
   Harici uygulama adapter'larının onaylı kapsamı [03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md) ve [04_PHASED_ROADMAP.md](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md) [Aşama 5](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md)'tedir.
   Canlı hesap/ücretli CLI/MCP testi, binary indirme/kurulum, credential taşıma
   ve master merge/push ayrıca onay gerektirir.

### Onaylı Rust geçişi ile ilişki

Kullanıcının ayrıca onayladığı Rust göçünde uygulama sırası [04_PHASED_ROADMAP.md](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md)'tür;
G03–G13'teki kalan davranış/güvenlik yükümlülükleri Rust'a geçince kapanmaz.
Mevcut API desteği Rust'a taşınırken Codex, Antigravity, Claude Code ve OpenCode
backend'leri ayrıca eklenecek; provider seçimi ve kabul koşulları [03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md)'tedir.

`find_files` ve `list_files` gerçek Elisp tool gate'ine bağlandı; eski glob
engine'leri ve senkron directory scanner silindi. Kullanıcının Unix/GNU
bileşimi kararıyla özel Rust listing tarayıcısı da kaldırıldı: `list_files`
ortak Rust process/gate üzerinden GNU ls çıktısı verir ([17_UNIX_TOOL_COMPOSITION.md](.agents/skills/native-tools/references/17_UNIX_TOOL_COMPOSITION.md)–[19_GNU_LS_ADAPTER.md](.agents/skills/native-tools/references/19_GNU_LS_ADAPTER.md)).
`find_files` şimdilik native'dir ([15_NATIVE_FIND_FILES.md](.agents/skills/native-tools/references/15_NATIVE_FIND_FILES.md)). Genel program/argv için Rust
reverse approval + Emacs presenter bağlıdır; Bash/job ve interactive session
consumer'ları native porttadır ([20_PERSISTENT_PROCESS_SEMANTICS.md](.agents/skills/native-tools/references/20_PERSISTENT_PROCESS_SEMANTICS.md)–[25_NATIVE_INTERACTIVE_SESSION.md](.agents/skills/native-tools/references/25_NATIVE_INTERACTIVE_SESSION.md)). `workspace_grep` de rg/GNU grep
adapter'ına bağlandı; eski Elisp grep engine'i kaldırıldı ([26_RECORD_CAPTURE_BUDGET.md](.agents/skills/native-tools/references/26_RECORD_CAPTURE_BUDGET.md)–[27_NATIVE_WORKSPACE_GREP.md](.agents/skills/native-tools/references/27_NATIVE_WORKSPACE_GREP.md)).
`git_status` native Git + complete-output portundadır; eski Elisp status
engine'i silindi ([28_NATIVE_GIT_STATUS.md](.agents/skills/native-tools/references/28_NATIVE_GIT_STATUS.md)). Diğer read/mutation Git tüketicileri de native
kapıya taşındı ([53_NATIVE_GIT_READ_QUERIES.md](.agents/skills/native-tools/references/53_NATIVE_GIT_READ_QUERIES.md), [56_NATIVE_GIT_WORKTREE_READS.md](.agents/skills/native-tools/references/56_NATIVE_GIT_WORKTREE_READS.md), [58_NATIVE_TOOLS_COMPLETE.md](.agents/skills/native-tools/references/58_NATIVE_TOOLS_COMPLETE.md)).
Kullanıcının API önceliğiyle 162-provider catalog baseline Rust asset/core
snapshot'a taşındı ([29_NATIVE_PROVIDER_CATALOG.md](.agents/skills/native-api-and-catalog/references/29_NATIVE_PROVIDER_CATALOG.md)). Chat/model-list HTTP ve SSE motoru native'dir;
Elisp parser/accumulator/watchdog silindi ([30_NATIVE_API_TRANSPORT.md](.agents/skills/native-api-and-catalog/references/30_NATIVE_API_TRANSPORT.md)). Credential/UI portları
kalır; wire ve prompt-cache engine'leri de native'ye taşınıp silindi ([31_NATIVE_WIRE_AND_CACHE.md](.agents/skills/native-api-and-catalog/references/31_NATIVE_WIRE_AND_CACHE.md)).
Request policy de native'ye taşınıp eski seçim/merge motorları silindi ([32_NATIVE_REQUEST_POLICY.md](.agents/skills/native-api-and-catalog/references/32_NATIVE_REQUEST_POLICY.md)).
Credential/header assembly de native'ye taşınıp Elisp üretim motorları silindi
([33_NATIVE_AUTH_HEADERS.md](.agents/skills/native-api-and-catalog/references/33_NATIVE_AUTH_HEADERS.md)); credential lookup editör portudur. Katalogun eski senkron credential
discovery yolu da owned async connection portuna geçirildi ([44_ASYNC_CATALOG_CONNECTION.md](.agents/skills/native-api-and-catalog/references/44_ASYNC_CATALOG_CONNECTION.md)); genel
run/history ve native config/endpoint policy açık olduğu için tüm API göçü
tamamlandı sayılmaz.
API tüketicileri application-owned native service lease kullanır ([34_APPLICATION_CLOSE_AND_API_FAIRNESS.md](.agents/skills/native-api-and-catalog/references/34_APPLICATION_CLOSE_AND_API_FAIRNESS.md)–[35_EDITOR_NATIVE_APPLICATION_LEASES.md](.agents/skills/native-api-and-catalog/references/35_EDITOR_NATIVE_APPLICATION_LEASES.md));
bu henüz native agent run/history sahipliği değildir. Native budget HTTP
admission/drain ve gerçek root-run consumer'a bağlandı; eski Elisp debit/token
toplama motoru silindi ([36_NATIVE_API_BUDGET.md](.agents/skills/native-api-and-catalog/references/36_NATIVE_API_BUDGET.md)). G08 hard reservation/pricing ve genel native
claim/tool/run birliği hâlâ açıktır; yalnız gözlenen token tavanı harcama garantisi değildir.
Native retry/circuit actor, charged replay, owned observer ACK ve detached GUI
projection/reset portları eklendi ([37_NATIVE_RESILIENCE.md](.agents/skills/native-api-and-catalog/references/37_NATIVE_RESILIENCE.md)–[38_NATIVE_CIRCUITS.md](.agents/skills/native-api-and-catalog/references/38_NATIVE_CIRCUITS.md)). High-level plain/stream chat
varsayılanı bu portlara geçirildi; Elisp retry/backoff/timer ve circuit admission/
sayaç/probe motorları silindi ([40_DEFAULT_RESILIENCE_CUTOVER.md](.agents/skills/native-migration/references/40_DEFAULT_RESILIENCE_CUTOVER.md)). Native terminal kategoriler Result
olarak gelir; plz DTO/bağımlılığı kaldırıldı. Manuel recovery, verilen native
reset'in ACK'ini bekler; UI görünümü admission kararı vermez.
Model metadata için kesin rate/context/output alan tipleri ve scoped RawValue
sınırı eklendi ([41_MODEL_METADATA_BOUNDARY_AUDIT.md](.agents/skills/native-api-and-catalog/references/41_MODEL_METADATA_BOUNDARY_AUDIT.md)). Default /models discovery envelope normalizasyonu
native profile'a taşındı; Elisp sağlayıcı yanıt ayıklama parser'ları silindi.
Native field/capability/rate normalizasyonu ve owner/revision-bound atomik store/
override temeli eklendi. Application actor'ündeki model_metadata RPC bounded
upload/commit/abort ve immutable snapshot paging sağlar. Asenkron editor bridge,
detached native görünüm, exact-ticket preparation bariyeri ve explicit same-lease
reconciliation eklendi. Public model writer'ları tek native actor'e bağlandı;
native failure sonrası legacy fallback yoktur.
Discovery capacity lexeme'leri de ortak native RawMetadata snapshot sınırında
kayıpsız taşınır. İlk explicit metadata yazımı sidecar startup yield'inden önce
ticket'ını kaydeder; hazırlık bu intent'i yakalar, passive getter core başlatmaz.
Kullanıcı async setter + son committed UI snapshot sözleşmesini onayladı.
Public setter/catalog producer ve genel UI reader native store'a geçirildi;
Elisp record/alias/override/refusal ve field/capability/fiyat engine'leri silindi.
Setter'lar artık async ticket + completion callback döndürür; UI yalnız son
committed görünümü okur. İlk hazırlık native head'i readonly alır; offline
unknown-model asset'i canlı lease veya başarılı commit yerine kullanılamaz.
Katalog credential hazırlığı cancellable child/connection portuna bağlıdır;
eski senkron anahtar/auth-source çözümleyicileri silindi. Genel run/history,
native config/endpoint policy ve G08 hard monetary reservation hâlâ açıktır;
tüm API/Rust göçü tamamlandı sayılmaz.
01 uyum denetimi ve kalan kaynak-sahipliği bulguları [39_RUST_PATTERN_AUDIT.md](.agents/skills/coding-standards/references/39_RUST_PATTERN_AUDIT.md)'da tutulur;
testlerin yeşil olması bütün Rust ağacının mimari uyum sertifikası değildir.
Eski fd-rooted listing garantileri yeni ls adapter'ına atfedilmez. Owner/cancel,
output cap ve onay regresyonları G11/G13'ün tamamını kapatmaz; context/egress
ve diğer global tüketiciler aşağıdaki gruplarda açık kalır.
Todo 2 native araç consumer kapanışı ve kalan köprü envanteri [58_NATIVE_TOOLS_COMPLETE.md](.agents/skills/native-tools/references/58_NATIVE_TOOLS_COMPLETE.md)
üzerindedir; edit/sensör/run göçlerinin yerine geçmez. Yeni paralel iş listesi yoktur.

## Gruplar ve önkoşullar

Numara varsayılan çalışma sırasıdır. Önkoşulu hazır bağımsız bir grup öne
alınabilir; özellikle G03 log gizliliği için bütün refactor beklenmez.
Aynı eski kimliğin farklı gruplardaki yönleri aşağıda açıkça ayrılmıştır.

| Grup | Birlikte ele alınacak iş | Önkoşul |
|---|---|---|
| G03 | Log gizliliği, sahipli retention ve ölçüm | G02 |
| G04 | Tool context, onay ve tek typed edit sonucu | G02 |
| G05 | Process/job/session ömrü ve stres riski | Yok |
| G06 | LSP servis sınırı ve fresh diagnostic sözleşmesi | G04 |
| G07 | Dape capability adapter'ı ve aktif unload | G04, G05 |
| G08 | Native toplam bütçe, history/compaction ve prompt maliyeti | G02, G04 |
| G09 | View/selection olayları ve uçtan uca stream baskısı | G02, G08 |
| G10 | Writer/persistence revision'ı, restart sınırı ve veri ömrü | G04, G05 |
| G11 | Proje bağlamı, egress ve adapter güvenliği | G02, G03, G04 |
| G12 | Native/fake agent backend portu | G02, G04, G05, G09, G11 |
| G13 | Son köprü temizliği, lint ve bütünleşik kabul | G02–G12 |

## G03 — Log gizliliği, sahipli retention ve ölçüm

**Kaynak:** DEEP-06, DEEP-07, DEEP-15'in log tarafı.
**Dosyalar:** core/log.el; gerekirse dar core/redact.el; log üreten API/tool
sınırları. Aynı dosya/saklama sınırı değişeceği için gizlilik ve ölçüm birlikte.

- Varsayılan metadata-only log; wire içerik açık opt-in ve gizlilik uyarısıyla.
  Bilinen credential, hassas structured alan, URL query, upstream hata echo'su
  ve export ortak yazma sınırında işlensin; redaction hatasında ham fallback yok.
- Logger'ın sahibi ve kesin retention birimi/limiti açık olsun. Sıfır retention,
  tek dev kayıt, Unicode, narrowing, point ve undo davranışı test edilsin.
  Ham büyük içerik redaction'dan önce log/temp tamponuna yazılmasın.
- Küçük yoğun log ve büyük wire dump için trim çağrısı, gerçek silme, allocation
  ve tepe saklama miktarını ölç. Kazanç yoksa ring-buffer veya yeni cache kurma.
- **Kabul:** yalnız sentetik sırlarla nested/bozuk JSON, truncation, hata ve
  export; iki owner izolasyonu; her yazımdan sonra cap. Regex'in bütün sırları
  bulduğu veya her trim'in tüm tamponu kopyaladığı varsayılmaz.

## G04 — Tool context, onay ve tek typed edit sonucu

**Kaynak:** MOD-02, ARCH-03, ARCH-04, ARCH-16; ARCH-02'nin yürütme kapısı tarafı.
**Dosyalar:** tools/{registry,execution}.el, api/tools.el, permission/{execute,policy}.el,
edit.el, tools/diff.el, tools/diff/{context,stage,review,track}.el;
LSP/Git/Bash registration tüketicilerinde gereken dar bağlantılar.

- Registry/executor'ü application/execution context'inden açık geçir; edit scope
  aktarımını bağımsız adapter girişlerine de tamamla. Tanım ile
  pending yürütmenin sahibi ayrı olsun. Availability/mode/alias/doğrudan
  çağrı aynı kapıyı kullansın; domain path/argv doğrulamasını kaldırma.
- Onayı belge/root/session/run/application ve config/policy revision'ına gerçek
  commit'e kadar bağla. Plan metadata alanı tek başına kontrol değildir.
  Replay/preapproved deposu veya ikinci izin motoru kurma.
- Legacy Unified Diff batch yalnız özet veriyor; typed wrapper bu yüzden
  :unknown taşıyor. Gerçek dosya/batch durumunu, hunk sayısını, saved/hook/
  rollback etkisini tek typed sonuçtan aktar; metin önekinden karar çıkarma.
  Pending plan kayıtları ret/iptal/hata/close dahil bütün çıkışlarda bırakılsın.
- Default edit tablolarının legacy aynalarını tüketicileriyle kaldır;
  aktif review/process/timer/temp close yalnız sahibini etkilesin. Büyük
  kaynak/scratch I/O ve toplu işlem bütçesi UI'ı bloke etmeden sınırlansın.
- **Kabul:** sync/async ve alias onay atlamaz; registry değişimi/drain,
  stale belge/config, iki servis aynı path, aktif unload, CRLF/Unicode/dirty
  buffer, kullanıcı index'i, save-hook/son dosya hatası ve foreign rollback.
  Ortak snapshot/review/rollback hattı korunur; parser/Git motoru yeniden yazılmaz.

## G05 — Process/job/session ömrü ve stres riski

**Kaynak:** DEEP-05, RISK-01 (P2, D), ARCH-17'nin process tarafı.
**Dosyalar:** tools/process.el, tools/process/session.el, tools/bash{,/jobs}.el,
tools/toolchain.el ve bu runner'ı kullanan lifecycle adapter'ları.

- Project/session job service ve interaktif transport'u açık owner/parent'a
  bağla; global service/foreground/counter köprülerini son tüketicileriyle
  kaldır. Idle, toplam oturum ve close deadline; detach/Emacs çıkışı politikası
  ayrı olsun. EOF veya parent exit bütün process tree'nin çıktığı kanıtı değildir.
- Açık graceful iptalde parent önce çıkıp INT'yi yok sayan child kalabilir.
  Geç numeric PID/PGID sinyali yabancı sürece gidebilir; ömrü korunan grup/
  wrapper veya desteklenen OS handle'ı kararı gerçek child fixture'ıyla sınansın.
  Mevcut varsayılan hard cancel sessizce zayıflatılmaz.
- RISK-01: 2026-10-19 child-group callback/stderr-drain anomalisi için ana
  süreç/grup sinyalleri, EOF ve teslim sırasını redacted izle; tek process'i
  bekleme ile bütün event loop'u ilerletmeyi karşılaştır. Sonraki 100 başarılı
  tekrar kök neden kanıtı değildir; üretilemezse belirsizlik açık kalır.
- **Kabul:** silent/stdin-waiting daemon, büyük stdout/stderr, başarısız spawn,
  erken exit, geç force, yabancı job, idempotent close, resource sayıları.
  Secret echo/terminal escapes güvenli sunulsun; quota kullanıcıca düzenlenmiş
  veya yabancı logu silmesin. PTY/CLI framework'ü bu grubun varsayılanı değildir.

## G06 — LSP servis sınırı ve güncel tanı sözleşmesi

**Kaynak:** COMPAT-01, DEEP-01'in kalan typed/freshness bağlantısı, DEEP-13.
**Dosyalar:** tools/lsp{,/context,/diagnostics,/freshness,/settle,/symbols,/register}.el,
tools/diff/track.el, loop/heal.el, edit.el.

- Diagnostic ve exact range sonuçlarını source/server/session/document revision,
  encoding ve end-exclusive aralığıyla typed porttan geçir; cache/request
  sahipliği açık LSP service'te olsun. G04 ve healing aynı snapshot'ı tüketsin.
- COMPAT-01: sürümsüz push hâlâ güvenli unavailable'dır, temiz tanı sayılmaz.
  Yalnız gerçek capability varsa fresh pull/eşdeğer request-response yolu ekle;
  backend desteklemiyorsa yeni protokol uydurma.
- Server restart, aynı path'in yeni nesli ve active unregister/close sırasında
  eski request/publication yeni sahibin durumunu değiştirmesin.
- **Kabul:** stale/unversioned/duplicate tanı, unavailable baseline, yanlış source,
  Unicode/non-BMP/combining/tab/CRLF/EOF/narrowing ve eski range'de sıfır yazma.
  Mevcut koordinat dönüşümü ve baseline multiset algoritması yeniden yazılmaz.
  Proje-geneli temiz iddiası yok; cross-file genişleme ayrıca karar ister.

## G07 — Dape capability adapter'ı ve aktif unload

**Kaynak:** ARCH-05; DEEP-13'ün DAP sınırı, ARCH-17 ve ARCH-19'un adapter tarafı.
**Dosyalar:** tools/dape/; gerekiyorsa küçük tools/dape/adapter.el.

- Private Dape API/advice/capability erişimini dar adapter tarafında topla;
  araçlar açık session/connection/selection owner'ı tüketsin. Eksik capability
  güvenli unavailable olsun; aynı kimliği tekrar parse eden zincirleri azalt.
- Unload/disable launch/compile/watch/child/server/stderr ve abonelikleri
  deadline'lı kapatsın; foreign adapter/selection/UI kaynaklarına dokunmasın.
- **Kabul:** bağlantı kaybı/restart, thread/frame ID reuse, source-map/revision,
  child startup, callback sırasında close, duplicate sentinel ve aktif unload.
  Var olan nonblocking launch/source ve yabancı UI izolasyonu korunur;
  sıfırdan DAP istemcisi bu grubun işi değildir.

## G08 — Native toplam bütçe, geçmiş ve compaction/prompt maliyeti

**Kaynak:** DEEP-09, ARCH-07'nin kalan consumer bağlantısı, DEEP-02, DEEP-04.
**Dosyalar:** application/budget.el, loop{,/machine,/tools,/compact,/heal}.el,
api/{http,retry,request,cache}.el, history/, prompt.el, prompt/default.txt.

- Her native run bir bütçe kursun; normal request, transport/loop retry,
  healing, compaction ve continue aynı handle'dan debit alsın. Alt katman
  sayacı üst bütçeyi sıfırlamasın; geç usage yanlış run'a yazılmasın.
- Mevcut tek compaction ile ikinci overflow/boş-küçülmeyen özet, compaction
  retry/Stop ve deadline yollarını birleşik bütçeyle test et. Çoklu compaction
  uygulama; bilinmeyen usage/cache hit/maliyet için tahmini gerçek gibi yazma.
- Prompt-cache/reset'in kalan global etkisini ve gereksiz guidance/schema
  tekrarını ölçerek azalt; readonly/history snapshot paylaşımını bozma.
  Tam repair/compaction taraması ancak ölçümle darboğazsa değişsin.
- **Kabul:** retry içinde retry, late compaction cevabı, tükenen bütçede yeni
  iş yok, tek terminal kısmi rapor. Her outbound istekte protokol duvarı ve
  tool kapalıyken prompt/schema uyumu korunur. Geçmiş kuyruğu ve artımlı
  boyut ölçümü için yeni motor kurulmaz; token/byte/allocation kanıtı kullanılır.

## G09 — View/selection olayları ve uçtan uca stream baskısı

**Kaynak:** MOD-01'in view tarafı, ARCH-06'nın veri/view ayrımı, DEEP-12.
**Dosyalar:** chat/, ui/, selection.el, api/select.el, Rust api/stream/, plan/context.el
ve chat/plan.el'in application bağlaması; metadata store'un sahibi G02'dir.

- View/draft/transcript/selection execution/connection portlarını tüketsin; ikinci veri
  deposu ve gizli global run araması kalmasın. Ortak pending confirmation
  listesi view/iş handle'larına taşınsın; adapter yokken karar güvenli ret.
- Catalog discovery'nin legacy credential girişi asenkron connection portuna
  taşınsın; G02'nin application metadata servisi ve public/keyless ayrımı korunsun.
- Run/session/request/call/connection kimlikli pasif olay ile cevap bekleyen
  control request ayrı kalsın. Plan adapter'ı yeni application dispatcher'ını
  kullansın; mevcut plan claim/approved revision/mode/draft korumalarını koru.
- Transport'ta var olan byte/event/tool limitlerini yeniden eklemek yerine
  toplam raw/decoded/pending event/render kuyruğunu ve drain başına işi sınırla.
  Stop'a event-loop kontrolü dönsün; terminal/tool/onay kayıtları sessiz atılmasın.
  Saat sıçraması, idle ve toplam deadline ayrı test edilsin.
- **Kabul:** iki view, kapanan/hatalı/reentrant listener, async picker/config
  değişimi, off/none/inherit, başarılı boş katalog, akışta düzenlenen taslak,
  hızlı producer/yavaş consumer, tepe byte/öğe ve tek finish. UI yerleşimini
  değiştirmek veya yeni plan motoru yazmak bu grubun işi değildir.

## G10 — Writer/persistence revision'ı, restart sınırı ve veri ömrü

**Kaynak:** DEEP-10, DEEP-11, DEEP-15'in dosya/kalıcı veri tarafı, ARCH-04, ARCH-19.
**Dosyalar:** files{,/async,/worker}.el, chat/session/{storage,schema,validate,restore}.el,
chat/session.el; edit/tool archive/job retention tüketicilerinde dar bağlantılar.

- Save/load/delete/rename için kaynak kimliği, beklenen revision ve commit
  noktası; aynı uygulamada sıralama veya conflict. Kontrol-yazma arasında
  foreign writer/symlink değişimi için desteklenen garanti açık olsun.
  Cooperative lock Git/formatter'ı denetliyormuş gibi sunulmasın.
- İki süreçli writer fixture'ı, disk dolması/rename hatası, yalnız metadata
  listing'inin tam session sayılmaması ve saf şema migration'ı aynı publication
  sınırında test edilsin. G04'ün edit motoru yeniden yazılmaz.
- Conversation/snapshot/archive/job/temp/export için sahip, konum/izin,
  byte/öğe/süre limiti ve silme kapsamı belirle. Aktif/yabancı/kullanıcıca
  değiştirilmiş kopyayı quota adına silme; symlink cleanup sınırı korunsun.
- **Kabul:** stale save/delete, iki Emacs/process, private storage, bozuk/ileri
  sürüm ve kontrollü kill/restart. Restore run/onay başlatmaz; unknown etki kör
  replay edilmez. Süreç içi rollback, normal restart ve power-loss ayrı
  garantilerdir; journal, güvenli fiziksel silme veya fs CAS vaat edilmez.

## G11 — Proje bağlamı, egress ve adapter güvenliği

**Kaynak:** ARCH-02'nin izolasyon tarafı, DEEP-08 ve DEEP-14'ün context güveni.
**Dosyalar:** permission/, fs.el, prompt.el, tools/{git,search,skill,webfetch,deps}.el,
net/; gerekirse dar permission/egress.el.

- User policy, güvenilen proje politikası ve dosya/web/tool/model içeriğinin
  kökenini ayır. İçerik etiketleri yetki değildir; uzak provider/backend'e
  gönderilecek context hedef/proje/secret scope'unda programatik kapıdan geçsin.
- G02 snapshot'ı ve G04 izin kapısıyla executable/PATH/config değişimi,
  symlink/out-of-root, argv/option injection, Git hook/config ve redirect
  ayrı sınırlarını doğrula. Tüm environment/credential context'e eklenmesin.
- **Kabul:** sentetik prompt injection, secret context, yanlış origin/provider,
  yetkisiz yürütme/egress ve yetki değişimi fixture'ları. Modelin talimata
  uyması test garantisi değildir; argv/cwd/onay sandbox diye sunulmaz.
  Gerçek OS izolasyonu seçilmediyse koruma düzeyi açık olsun; güvenlik portunun
  yokluğu yetki vermesin, politika/adapter kurulumu sessizce genişletilmesin.

## G12 — Native/fake agent backend portu

**Kaynak:** MOD-08, DEEP-16'nın backend bileşimi.
**Dosyalar:** dar application/backend.el, backends/native.el; kontrollü
tests/fixtures/fake-agent.el ve ortak backend contract testleri.

- LLM completion transport'u ile kendi tool loop'u olan agent backend'i ayrı
  sözleşmeler olsun. Capability/start/resume/event/approval/cancel/session
  eşlemesini tanımla; unsupported resume açık unavailable.
- Native motoru küçük execution-owner adapter'ına bağla; aynı run'da yalnız
  bir loop/yazma sahibi olsun. Fake agent mevcut UI/context/izin portlarını
  kullansın; LSP/Dape servisleri seçime bağlıdır, eksikken fake çalışabilsin.
- **Kabul:** native/fake ortak suite; disconnect, duplicate/out-of-order,
  approval'da reset, foreign session ve cancel sonrası late event. Dış etkiyi
  gözlemlenmediyse unknown taşı; Kargu onayı verilmiş gibi gösterme.
  Gerçek Codex/Antigravity/Claude Code/OpenCode backend'leri [04_PHASED_ROADMAP.md](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md) Aşama 5'in
  ayrı teslim kapsamıdır; G12 native/fake portunun tamamlanması onların canlı
  entegrasyon kanıtı değildir. Binary indirme veya credential taşıma bu grubun
  kapsamı değildir.

## G13 — Son köprü temizliği, lint ve bütünleşik kabul

**Kaynak:** TEST-01, ARCH-09, ARCH-12, ARCH-18, DEEP-16.
**Dosyalar:** ilgili eski tests/*.el, tests/run-tests.el, composition girişleri,
kalan bridge tüketicileri; proof/ ve README.md.

- TEST-01: test-contract.el gibi eski kaynaklarda header/Code/docstring borcu
  var. Güncel envanter al; tarihsel 73/84 uyarı sayısını bug sayısı veya güncel
  sonuç diye kullanma. Gerçek lint sorununu fixture false-positive'inden ayır;
  assertion/sentetik hata metnini değiştirme, test silme/global lint kapatma yok.
  Üretim tarafı (2026-11-07): CI yalnız değişen Elisp'i lint ettiği için 21 üretim
  dosyasında birikmiş checkdoc borcu (alt dizin `;;; kargu/x.el` başlık/footer'ı,
  belgelenmemiş argüman, fiil kipi) giderildi; 207/207 temiz. `test-modules.el`
  izole fixture'ları artık checkout yerine geçici çalışma dizinine yazar.
- ARCH-GATE (2026-11-08): kargu-core bütünüyle rust-strict-modular-design
  pre-commit kapısında (`kargu-core/arch-checker.conf`: `domain = src`, wire
  katmanı `edge`, efektli actor/worker/adapter dosyaları tek tek `shell`).
  Mevcut ihlaller `kargu-core/arch-checker.baseline` içinde; kapı yeni bulguyu,
  bayat satırı ve HEAD'e göre kural başına büyümeyi reddeder. Bir ihlal
  düzeltilince satırı aynı commit'te silinir (`--write-baseline` diff'i yalnız
  silme olmalı). Kalan borç, dilimler halinde sıfıra indirilecek: pub-field
  (DTO'lar için accessor/constructor), primitive-boundary (newtype),
  too-many-parameters (parametre tipi), too-deep/too-many-statements (bölme).
  `shell` listesindeki dosyaların saf kısmı ayrıldıkça listeden çıkarılsın.
- G02–G12 son consumer'ları taşıyınca application/async/request, registry,
  catalog/circuit, edit/job/archive global köprülerini ve çift state yollarını
  sil. Emacs'in zorunlu hook/keymap/autoload kayıtlarını dar whitelist ile ayır.
  Son test dosyası bağlantıları ve fiziksel eksik-adapter matrisi güncel olsun.
- Kalan somut bridge tüketicileri: G04'te permission/{execute,policy}.el ve
  default registry/edit aynaları; G05'te job service/counter/foreground index'i;
  G07'de Dape {context,launch,readiness}.el; G09'da chat/{render,session,stream,
  transcript}.el ve ortak UI confirmation listesi; G10'da files/async.el.
  Bu tüketicilerin global run/generation okumaları explicit handle'a taşınmadan
  compatibility dalları veya detached async index'i silinmesin.
- **Kabul:** claim → frozen connection → request → approval → edit commit →
  fresh verification → tek terminal rapor. Her arada Stop/reset/view close,
  callback/cleanup hatası, yabancı writer, cevap kaybı ve restart enjekte et.
  Yanlış başarı, yetkisiz etki, çift yürütme, sonsuz bekleme veya leak kalmasın.
- Tüm ERT; değişen üretim/yeni testlerde uyarısız byte-compile/checkdoc;
  eski fixture istisnaları tek tek gerekçeli; TLA+ kaynağı değişen ilgili modeller.
  Ana loop/protocol/state/circuit/tools semantiği değişmişse model uyumu
  incelensin; TLC yalnız TLA+ kaynağı değişmişse çalıştırılsın. Yerel TLC bütün
  sistemin kanıtı değildir; simulation proof değildir.
  Kullanıcı onayı olmadan master merge/push veya gerçek dış entegrasyon yok.

## Her grubun ortak mimari kabul kuralları

Bunlar ayrı, sonsuza dek açık refactor paketleri değil; ilgili grupta uygulanıp
G13'te topluca denetlenecek kurallardır. Somut ihlal ilgili grubun açık işidir.

- **ARCH-08, ARCH-10 — Adlandırılmış domain ve sahiplik:** Session/run/request/root,
  süre/byte/token/diagnostic/range gibi anlam ve birim taşıyan değerler
  adlandırılmış domain tiplerinde olsun. Primitive yalnız dış adapter ve yerel
  hesap sınırında; para gerekmiyorsa örnek uğruna money framework'ü yok.
  Mutable iç referans, borrowed-readonly ve sahiplik devri açıkça ayrılsın.
- **ARCH-09, ARCH-12 — Modülerlik:** Tüketicinin dar public portu, composition'da
  register/unregister ve açık service handle. Çapraz private çağrı/döngüsel
  require/yeni mutable singleton yok. Opsiyonel modül çıkarılınca yalnız kendi
  capability'si kaybolur; güvenlik adapter'ı yokken güvenli ret zorunludur.
- **ARCH-11, ARCH-13 — FSM ve okunabilirlik:** Yaşam döngüsü tek sahipli state/event
  geçişleriyle; normal validation bir FSM'e çevrilmez. Gövde 35–40 satırı,
  mantıksal nesting üç seviyeyi, iç içe döngü ikiyi aşmasın. Callback/map de
  nesting hesabına dahil; üçten fazla mantıksal parametrede keyword/domain kayıt.
- **ARCH-14 — En basit tam çözüm:** Ölçülmüş algoritma/byte/öğe/tepe bellek;
  döngüde append/tam encode, gereksiz cache ve facade yok. Cache varsa owner,
  key, dış değişiklik invalidation'ı ve boyut/ömür sınırı testli olsun.
  Daha az satır için izin/snapshot/rollback/cleanup silinmez.
- **ARCH-15 — Sınır validation'ı:** Public giriş ve çıkış/callback/event/persistence
  doğrulanır; temsil/sürüm/birim/boyut/derinlik ve alanlar arası invariant yan
  etkiden önce denetlenir. İçeride kanonik veri; tekrar parse/normalize yok.
  Asenkron bekleme sonrası sahiplik/izin/revision kontrolü gereksiz tekrar değildir.
- **ARCH-16 — Sonuç ve etki:** Başarı/ret/unavailable/iptal/timeout/partial/unknown
  ayrı; text encode en dış sınırda. Programlama hatası domain hatasına gizlenmez.
  Retry typed sınıf, güvenli etki ve kalan bütçeye bağlıdır; cevap kaybı yan
  etki yokluğu değildir, unknown işlem kör tekrar edilmez.
- **ARCH-17 — Kaynak ömrü:** Edinimde cleanup kaydı, başlangıç bariyeri,
  owner/parent/deadline, tek terminal teslim ve idempotent close. Cleanup hatası
  diğer kaynakları bırakmayı engellemez; yabancı kaynak veya reused PID kapanmaz.
- **ARCH-18 — Kanıt:** Fake ve kontrollü gerçek adapter aynı contract suite'i
  geçsin; erken/geç/çift/sırasız olay, bozuk giriş/çıkış, consumer mutasyonu,
  reset/close/unload ve leak testi. Zaman/süreç mock'u gerçek hatayı gizlemesin;
  test geçici projede, sentetik sırlarla, canlı uzak servis olmadan çalışsın.
- **ARCH-19 / DEEP-13 — Sözleşme evrimi:** Capability/sürüm ve saf migration;
  missing/nil/false/null/off/none/inherit ayrımı. Koordinatın tabanı, encoding,
  birimi, end-exclusive sınırı ve belge revision'ı açık; guess/clamp yok.
  Snapshot taşınırken aktif run'ın sözleşmesi veya kimliği sessiz değişmez.

## Ayrı ürün kararı isteyen seçenekler

Bu seçenekler zorunlu düzeltme grubuna gizlice dahil edilmez; seçildiklerinde
ayrı Plan mode açılır. Açık güvenlik/veri kaybı veya yanlış başarı eksikliği
bu başlıklarla opsiyonel ilan edilemez.

- ARCH-06: split UI/header-line/ayrı giriş tamponu; mevcut draft/IME/Unicode/
  Stop erişimi korunarak kullanılabilirlik prototipiyle karar.
- DEEP-01: gerçek fresh project-wide/cross-file doğrulama. Destek yokken yalnız
  düzenlenen dosyanın kanıtı bildirilsin, proje temiz iddiası kurulmasın.
- DEEP-02: çoklu compaction politikası. Varsayılan tek compaction korunur;
  ikinci overflow/hata/unknown davranışı G08'in zorunlu kabulüdür.
- ARCH-05: sıfırdan DAP istemcisi; mevcut Dape adapter'ını bitirmekten farklıdır.
- ARCH-02 / DEEP-11: gerçek OS sandbox platform matrisi ve power-loss journal.
  Desteklenen garanti sınırının dürüst bildirimi G10/G11'de zaten zorunludur.

## Rust geçişinde kalan adımlar — kapanış takip listesi

**Bu güncellemenin kapsamı (2026-11-03):** tracked kaynak envanteri, tanım/caller
aramaları ve native port/consumer incelemesiyle görevleri tekrar eşleştir. Her açık
yaprak iş için önkoşul, mevcut kaynak, somut işlem, gözlenebilir kabul ve test
başlangıcı ver. Statik kaynak kanıtı runtime bug veya test başarısı değildir;
bu tur yalnız `todo.md` güncellemesidir, yeni uygulama/kabul çalıştırılmadı.

**Önceki uygulama/denetim talimatı (2026-11-01):** kullanıcı commit edilmemiş bütün
Git değişikliklerinin incelenmesini, önce 6–7–8'in eksik alt işlerinin yazılmasını,
sonra doğru uygulamaların korunup hataların/eksiklerin düzeltilmesini ve doğrulanan
dilimlerin commit edilmesini istedi. Bu talimat önceki ara test/commit yasağının
yerine geçer. Mevcut `[x]` işaretleri denetim girdisidir; tüketici bağlantısı,
legacy temizliği ve güncel kabul kanıtı olmadan kapanış kanıtı sayılmaz.
Gerçek kullanıcı session dosyaları ve canlı provider hesapları test girdisi değildir.

**Onaylı uygulama hedefi ve test kuralı (kullanıcı, 2026-11-01):** bu listedeki 1–6 dahil
bütün maddeleri adım adım tamamla ve doğrulanan dilimleri commit et. TLA+/TLC
yalnız TLA+ kodu değiştiğinde çalıştırılır; değişmeyen modellerin eski sonuçlarını
tekrar üretmek bu hedefin kabul şartı değildir.

**Bağlayıcı frontend/backend kuralı (kullanıcı, 2026-11-01):** Elisp yalnız
Emacs frontend'i ve Rust ile editör arasındaki köprüdür. Config dosyasını okuma,
provider/endpoint/model seçimi, provider'a model listesi isteği, yanıt ayrıştırma,
cache, agent loop, tool/permission politikası, history ve iş akışı kararlarının
tamamı Rust backend'ine aittir. Elisp Rust'ın DTO'larını gösterir ve kullanıcı
etkileşimlerini geri iletir. Buffer/undo/save, Eglot/Dape ve auth-source gibi
Emacs'e özel erişimler ince adaptörlerdir; ayrı bir karar veya orkestrasyon motoru
kuramaz. Henüz taşınmamış Elisp motorları geçici göç borcudur; yeşil testler veya
bir RPC wrapper'ının varlığı bu kuralın sağlandığını göstermez. Bir tüketici ancak
uçtan uca Rust'a taşınıp eski Elisp motoru kaldırılınca kapanır.

Güncelleme: 2026-10-26, native config authority temeli `ff96691`.
Son dilimde config publication/policy gerçek connection/UI tüketicileriyle Rust'a
geçti; eski Elisp karar/yazım motorları silindi. Kanıt: 1268/1268 full source ERT;
291 native + 24 compile-fail = 315 locked test, fmt/strict Clippy, Elisp Werror/
checkdoc ve bounded lifecycle TLC temiz. Ayrıntılar [12_MIGRATION_PROGRESS.md](.agents/skills/native-migration/references/12_MIGRATION_PROGRESS.md) ve [52_NATIVE_CONFIG_POLICY.md](.agents/skills/native-api-and-catalog/references/52_NATIVE_CONFIG_POLICY.md).

Bu liste [04_PHASED_ROADMAP.md](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md)'teki onaylı göçün kalan **tüketici taşıma/kaldırma sırasını**
özetler; G03–G13'ün yerine geçen ikinci kapsam veya yeni ürün kararı değildir.
Kutular ancak gerçek tüketici Rust'a bağlanıp eşdeğer testler geçtikten ve eski
Elisp motoru silindikten sonra kapanır. Her doğrulanmış küçük dilim ayrı commit
olur; bağımsız işler önkoşulları sağlanınca öne alınabilir. Emacs'in canlı buffer,
undo/save, Eglot/Dape ve UI adapter'ları gereksiz kod sayılarak kaldırılmaz.

### Alt ajanlara görev verme ve birleştirme sözleşmesi

Bu bölüm ikinci iş listesi değildir; aşağıdaki numaralı alt işler atanır.
Bir işin Rust domain, IPC entegrasyon ve Elisp consumer dilimleri farklı ajanlara
verilebilir; consumer geçmeden domain diliminin tamamlanması üst kutuyu kapatmaz.

Her atamada şu alanlar zorunludur: **iş kimliği, önkoşul, temel commit,
hedef davranış, sahip olunan dosyalar, ortak dosya talebi, giriş/çıkış sözleşmesi,
korunacak özellikler, silinecek legacy consumer, test komutları ve teslim kanıtı**.
Beklenen hata/unknown/stale/cancel sonuçları da sözleşmenin parçasıdır.

- Ayrı worktree/branch kullan; aynı dosyada eşzamanlı bağımsız yazma yapma.
  `application/host.rs`, `application/mod.rs`, `ipc/transport.rs`, `constants.rs`,
  `lib.rs`, Cargo manifest/lock, `kargu.el`, `tests/run-tests.el` ve `todo.md`
  ortak entegrasyon dosyalarıdır. Bunlara tek entegratör veya sırayla sahiplik ver;
  domain ajanı dar port ve entegrasyon patch'i teslim etsin.
- Her teslimde gerçek ve önerilen RPC/capability adlarını ayır; sabit adı bulunan
  portu yeniden adlandırma. Scope/epoch/revision biriminin sahibi bellidir;
  UI'ın gönderdiği kimlik veya receipt tek başına yetki değildir.
- Her atama `[ ]` durumunda başlar; kod varlığı, sabit/RPC wrapper tanımı veya
  mock'un başarı dönmesi yeterli değildir. Koordinatör gerçek consumer/test/commit
  kanıtını gördükten sonra yalnız kapanan kutuyu işaretler. Engelin hangi kimliği
  beklediğini yaz; eksik adapter'ı fallback ile gizleme.
- Teslim: küçük commit(ler), değişen port/consumer listesi, kaldırılan motor,
  çalıştırılmış testlerin sonucu ve kapsam sınırı. Domain → IPC → frontend →
  legacy kaldırma sırasıyla birleştir; her birleşmede etkilenen kabulü çalıştır.
  Tam testleri her ajanda tekrar koşturmak yerine entegrasyon kapısında çalıştır.
- Dokümantasyon işi uygulama/test yapıldı sayılmaz. Tarihsel `[x]` açıklamasındaki
  “çalışma ağacında”, “çalıştırılmadı” veya “henüz commit edilmedi” ifadeleri
  bugünkü durum yerine geçmez; kaynak/commit/consumer yeniden eşlenir.

### İş kartının nasıl kullanılacağı

- Ajan atamasına **tek yaprak işin tamamını**, bağlı üst işin sözleşmesini ve
  0.2'nin ilgili port/DTO kararını kopyala. Yalnız başlık veya yalnız dosya adı verme.
  Üst iş/kabul kapısı satırları baştan sona yeniden implementasyon isteği değildir.
- Her karttaki **Önkoşul** üretilecek sözleşmeyi/portu veya gerçekten geçmesi gereken
  önceki kabulü belirtir. Port contract hazır fakat implementation bekleniyorsa
  saf domain/codec parçası geliştirilebilir; consumer kabulü ve kutu açık kalır.
  Native port varmış gibi fake callback/scope veya geçici legacy fallback ekleme.
- **Başlangıç kaynakları** içindeki Rust yolu `kargu-core/src/`, Elisp yolu
  `kargu/` altındadır; `kargu.el` her zaman depo kökündedir. Açıkça depo kökü/
  başka yol belirtilmişse o yolu kullan.
  Brace gösterimi (`a/{b,c}.el`) iki yolu açar; dizin/file ayrımını koru. “Eklenecek/mevcut değil”
  etiketli portu veya dosyayı hazır implementasyon sanma.
- **Doğrulama başlangıcı**ndaki Rust adı `cargo test --test AD` için test target'ıdır;
  “alt modül” aynı target'ın filtresidir, ikinci `--test` yolu değildir. ERT adı
  `tests/test-AD.el` dosyasını belirtir; **dosya adı ERT selector değildir**.
  O dosyadaki ilgili `ert-deftest` adlarını seç. Mevcut testi yeşile koşturmak
  yeni consumer'ın bağlandığına kanıt olmaz; kartın kabul vakasını gerçek girişte ekle.
- Her işte görev başlığı/açıklaması + kart alanları birlikte sözleşmedir.
  Uygulama ajanı gereken örnek DTO, event, error/status ve test fixture'ını
  somutlaştırarak teslim eder; hazır olmayan protokol için isim/flag uydurmaz.
- **Korunacak frontend işleri:** buffer/document UUID/tick, raw Eglot/Dape/
  auth-source gözlemi, native permit'e bağlı buffer transaction/save/undo ve
  son anda resource recheck; keymap/hook/window/draft/face/render; bounded DTO
  decode/validation ve response correlation. Bunları Rust domain motoru sanıp silme.
  İmmutable DTO'nun yalnız sunum için indeksi olabilir; model seçimi, izin,
  maliyet, freshness veya yürütme yetkisi bu indeksten türetilmez.

Kartlarda kullanılan sözleşme kelimeleri:

- **Authority / writer:** state değişimini kabul eden tek native actor/store.
  UI'ın bir değeri göstermesi veya callback'in başarılı dönmesi bu yetki değildir.
- **Captured snapshot:** işe kabul anında yakalanan scope/config/model/backend
  sürümü. Await sonrası mutable “şimdiki” ayardan yeniden üretilmez.
- **Expected revision:** komutun hangi state sürümüne uygulanabileceği. Uyuşmazlık
  eski state'i overwrite etmek yerine stale/ret üretir.
- **Revoke → drain → release:** önce yeni etki yetkisini kes; sonra başlamış bütün
  owned worker/process/editor işlemlerinin gerçek sonucunu topla; en son claim'i
  bırak. UI callback/timer iptali actual işin bittiği anlamına gelmez.
- **Unknown outcome:** yan etki olmuş olabilir ama kanıt yoktur; success/failed
  uydurulmaz, otomatik tekrar veya başka backend'de yeniden yürütme yapılmaz.

Atama metnini şu şablonla tamamla; boş bir contract/dosya alanını ajanın kendine
izin verdiği geniş refactor kapsamı olarak yorumlamasına bırakma:

```text
Görev kimliği ve kartın tam metni:
Baz commit / worktree:
Hazır önkoşul portları ve DTO revizyonu (örnek başarı/ret/stale zarfıyla):
Ajanın değiştireceği dosyalar:
Ortak actor/transport/manifest için entegratöre verilecek patch:
Kapsam dışı davranışlar ve korunacak public API/primitive:
Kabul senaryoları ve exact Rust target / ERT test adları:
Beklenen teslim: küçük commit + port/caller/silinen legacy listesi + test log'u:
Engel: eksik port/karar/adapter; kutuyu kapatma, fake başarı/fallback ekleme:
```

### Kaynak taramasının güncel bulguları — çalışma listesine eşleme

Kapsam: `git ls-files` içindeki 190 Rust production, 206 `kargu/` Elisp +
`kargu.el`, 59 Rust test ve 117 ERT/test destek kaynağının dosya/sembol envanteri.
Temel aileler aşağıda port ve görevlerle eşlendi; gerçek giriş/caller zincirlerinde
karar/writer işlevleri ayrıca okundu. Bu, tüm satırlar için doğruluk sertifikası
veya yeni runtime/test kabulü değildir. 0.1/0.3 implementasyon sırasında değişen
consumer/alias/test matrisiyle tamamlanır; yeni dosya gelirse envantere eklenir.

| Kaynak ailesi / somut başlangıç | Bugünkü rol veya açık sınır | İş kimliği |
|---|---|---|
| `kargu.el`, `core/custom.el`, `core/group.el` | Composition/defcustom kalır; native registration, seçenek ve optional capability authority ayrılacak | 5.3a, 8.2c2, 8.5b, 10.5d |
| `api/{request,client,response,tool-calls}.el` | Payload/history append/rollback, overflow/arg/ID normalizasyonu hâlâ Elisp consumer içeriyor | 5.5a1–a3, 6.1c |
| `api/{http,transport,prepare}.el` | HTTP/SSE motoru native; Elisp preparation/lease ve API/history consumer'ı tam run otoritesiyle bağlanacak | 5.4a/c, 5.5b, 5.9g |
| `api/{wire,failure,retry,circuit}.el` | Çalışan native codec/resilience temelini koru; response/error/UI observer ve manual ACK consumer'larını tamamla | 5.5a2, 5.5b, 10.1a |
| `api/catalog.el`, `api/catalog/request.el` | Elisp hâlâ katalog sıralama, cache/generation ve URL/credential hazırlığını koordine ediyor | 8.2b2–b4, 8.2e |
| `api/tools.el`, `tools/{registry,execution}.el` | Alias/schema/visibility, permission precheck, output sanitize/truncate ve archive politikası ikinci karar alanı | 5.3a–c, 5.6e, 10.5d |
| `application/{coordinator,execution,mode,reset,budget}.el` | Native run/budget yanında yerel claim/status/reset/mode writer kalıntıları; UI lifetime ile domain ayrılacak | 5.4a/c, 5.7a, 5.8, 6.1, 8.5a |
| `async.el`, `core/observers.el`, `state/hooks.el` | Editor callback/hook ömrü kalır; native child drain yerine local timer/callback bitişi kullanılamaz | 4.2b, 5.8a, 8.5b/c |
| `bridge.el`, `bridge/{application,conversation,session}.el` | Stdio/correlation/handle köprüsü kalır; method stub backend varlığı değildir | 0.2, 5.9, 7.5a, 8.3, 10.5e |
| `bridge/{api,budget,circuit,catalog,config,config-policy}.el` | Çalışan native primitive portları; public orchestration native'e bağlanacak, raw credential capture korunacak | 5.4a, 6.1, 8.2, 8.5c |
| `bridge/models/`, `bridge/{models,file,read,history,jobs,job-output,command,approval}.el` | Native metadata/read/history/process/onay portları; yeni ikinci engine yazma | 3.8c, 4.8, 5.1b, 5.6c/e, 8.4 |
| `bridge/edit/`, `bridge/{edit,native-edit}.el`, `edit.el` | Canlı document/transaction/review/receipt adapter'ları kalır; edit kararını Rust verir | 3.8–3.10, 6.4 |
| `bridge/sensor.el`, `bridge/sensor/` | Document-symbol/diagnostic typed yolu mevcut; xref/skeleton hâlâ legacy formatter'a gider, mentions portu açık ret döner | 4.2c, 4.4d/e, 4.7a, 4.8 |
| `config/`, `providers/` | Parse/resolve/metadata native temeller var; frontend registry/selection/config→HTTP iş sıralaması hâlâ tamamlanmadı | 8.2b2–e |
| `models/{encode,projection,service,store}.el` | Native metadata store'a intent/projection; pasif view ve UI index authority değildir, çalışan fiyat engine'ini kopyalama | 8.2c2/e, 8.5a, 10.3c |
| `selection.el` → `kargu-selection-update/reset` | Native conversation commit'i + ACK yayımı (8.2c1 kapandı); legacy busy ön kontrolü ve run admission bağı kalır | 5.4a |
| `state/{store,selectors,transitions}.el`, `core/session.el` | Mode/selection/usage/activity domain state'i ile display snapshot karışık | 5.7a, 6.1c, 8.1a, 8.5a |
| `history/{store,protocol,repair,compact}.el` | Native store yanında kalan Elisp history/repair/summary consumer'ları | 5.1b, 5.5a3, 6.3c, 5.10 |
| `loop/{machine,tools,compact,heal}.el`, `loop.el` | Legacy agent hâlâ default; FSM/tool queue/summary/verification kararları Rust consumer cutover bekliyor | 5.6–5.10, 6.3/6.4, 10.4 |
| `loop/{native,native-owner,ui}.el` | Opt-in native run/terminal UI bağlı; sabit limit/timeout ve tek-string delta native seçenek/event contract'ına geçecek | 5.4c, 5.9h, 8.3d |
| `chat.el`, `chat/{header,prompt,render,transcript,routing}.el` | UI/draft/point/Markdown kalır; domain status/history/accounting yalnız native DTO olmalı | 6.1c/6.5a, 8.1, 8.3, 8.6 |
| `chat/{select,tune}.el`, `chat/select/` | Picker/completion UI kalır; selection/tuning validation/commit native intent olacak | 8.2c1/c2/d |
| `chat/stream.el` | `<think>` aç/kapat lexer ve attempt state'i bulunuyor; render face'i kalır, içerik normalizasyonu native | 8.3b/d |
| `chat/{attach,complete}.el` | Kendi token temizleyici/lexer'ı, Python symbol-bound heuristiği ve dosya scan consumer'ı var | 4.4b, 4.7a, 4.8a/d, 4.9 |
| `chat/session.el`, `chat/session/` | Disk/schema/import/restore/worker motoru legacy; Rust kalıcı storage prototipi geri alındı | 7.1–7.6 |
| `files.el`, `files/`, `fs.el` | Native read mevcut; `fs-walk` recursive disk scanner ve file/session worker consumer'ları henüz ayrı borç | 4.8a–d, 7.6a, 8.5c |
| `permission/{guards,bash,policy,execute}.el` | Runtime editor root/resource kontrolü kalır; risk/tokenize/auto-approval/execute kararları native'e geçer | 5.3b/c, 10.2 |
| `plan/{store,context,dispatch,buffer}.el`, `chat/plan.el` | Plan domain state/dispatch Elisp'te; UI artifact buffer ayrı tutulacak | 5.7b/c, 8.4 |
| `languages/`, `tools/{deps,toolchain}.el`, `project-probe.el` | Probe worker native; frontend profile seçimi/guidance/dependency admission domain consumer'ı kalmış | 4.11a–c, 5.13b, 10.5e |
| `prompt.el`, `prompt/default.txt` | Instruction/OS/Git/skill/mode composition ve cache Elisp'te | 5.13a–d |
| `tools/{bash,git,search,skill,webfetch}.el`, `tools/bash/`, `tools/git/`, `tools/process/session.el` | Native araç ve job consumer temelleri korunur; genel run parent/public gate bağı tamamlanacak | 5.3c, 5.6c/e, 10.2c |
| `tools/process.el` | Kalan shared runner'ı caller'ı bitmeden silme; diff/Dape/session OS işi native'e geçtikçe daralır | 3.9a, 4.6b, 7.6a, 8.5c |
| `tools/diff/`, `tools/diff.el` | Native opt-in + legacy stage/parser/review/change yolları birlikte bulunuyor | 3.8–3.10, 6.4, 10.4 |
| `tools/lsp/`, `tools/lsp.el` | Ham live kaynak adapter'ı ve legacy semantic formatter/resolver/freshness consumer'ları ayrılacak | 4.2–4.4, 6.4 |
| `tools/dape/`, `tools/dape.el` | Capture, connection/frame selection, policy, launch/compile/readiness ve render ayrılacak | 4.5/4.6, 4.11, 5.7a |
| `core/log.el`, `api/retry.el`/`response.el` log çağrıları | Wire/log trim/pretty/display ve hassas veri çıkış sınırı; ayrı native redaction/retention işi var | 5.6e, 10.1a–c |
| `contract/`, `core/data.el`, `json.el` | DTO decode/copy/assert/view helper kalabilir; model tool JSON recovery domain consumer'ı taşınır | 0.2, 5.5a2, 8.5a |
| `confirm.el`, `ui/`, `ui.el` | Presenter/menu/notification ve window/keymap UI kalır; onay yetkisi, expiry ve plan dispatch native | 8.4, 8.5b |

Rust tarafının tamamı da görevlerle eşlenir; mevcut modül **yeniden yazılacak**
anlamına gelmez. Açık iş, çalışan domain'i gerçek consumer'a bağlayıp korumaktır.

| Rust `src/` ailesi | Açık entegrasyon / korunacak temel |
|---|---|
| `api/` | 5.4/5.5 canonical consumer, 6.1 usage settlement; HTTP/SSE/auth/cache/retry codec korunur |
| `application/`, `history/` | 5 native actor/FSM/history, 6 budget/summary/heal; runtime provider temeli korunur |
| `configuration/`, `providers/`, `models/` | 8.2 native orchestration/selection; parse/read/metadata/rate store tekrar yazılmaz |
| `domain/`, `security/` | 0.2 birim/kimlik ve 5.3 gate consumer'ları; approval/issuance authority korunur |
| `edit/` | 3 public/default/legacy reader cutover + 6.4 otomatik verification; receipt/journal temelini koru |
| `sensors/` | 4 Xref/Dape/context consumer'ları; 6.4 fresh barrier; mevcut typed tanı/symbol lexer korunur |
| `workspace/`, `process/` | 4.8/4.11 native read/probe, 5.6 parent jobs/output, 9 adapter process; mevcut supervisor/gate kullanılır |
| `ipc/` | 4 reverse, 5 run, 7 gerçek storage RPC, 8 stream/intent, 9 backend/MCP; tek entegratör ve actual drain |
| `constants.rs`, `error.rs`, `lib.rs`, `main.rs` | 0.2/10.5d protocol/feature/asset; yeni servis yalnız gerçek hazır capability olarak export edilir |
| `.github/workflows/rust-bridge.yml`, `shell.nix`, `proof/`, embedded assets | 10.5d/10.6e build/asset/CI kapısı; değişmeyen TLA+ için TLC çalıştırılmaz |
| `kargu-core/tests/`, `tests/`, fixture/helper/bench | 0.3 + 10.3d/10.6; ERT/admission fake'inin sınırı, native stdio/OS kabulü ve perf ölçümü ayrı |

### Default geçişi ve temizlik sırası — döngü kurma

1. **Sözleşme/kaynak:** 0.2'de ortak portu sabitle; ilgili Rust domain/worker ve
   raw editor adapter'ını yaz. “Port sözleşmesi hazır” ile “gerçek consumer kabulü
   geçti” farklı teslimlerdir. Aynı aktör/transport için iki bağımsız yazar yok.
2. **Native opt-in consumer kabulü:** public girişleri captured backend ile
   native yola bağla ve 3.10b/8.6 corpus'unu çalıştır. Bu aşamada eski engine
   dosyaları migration debt olarak bulunabilir; **seçilmiş native işlemde**
   çalışamazlar ve native hata sonrası çağrı onlara replay edilemez. Bu aşama
   final “Elisp yalnız frontend” kapanışı değildir.
3. **Default switch:** 10.4a kapısından sonra 10.4b yalnız yeni run admission'ını
   Rust'a geçirir; aktif eski run'lar kendi captured motor/lease'inde drain olur.
   10.4a'nın 3.9/4.10/5.10/6.4b6/8.5 fiziksel silmesini beklemesi yasaktır.
4. **Retire/kaldır:** actual eski run kalmayınca ilgili cleanup görevlerini
   bitir; 10.4c eski selector/require/autoload/fallback'i emekli etsin. Son
   authority taraması 10.3c, release ve gerçek GUI kabulü 10.6'dır.

Bu sıralama yeni fallback veya kalıcı çift engine izni değildir; nihai hedef
bütün public consumer'ların Rust authority'sine bağlı olmasıdır. Dört harici
backend 9'da ayrı teslim edilir; bunların eksikliği final ürün kapanışından gizlenmez.

- [x] **0. Ortak sözleşme ve güncel consumer envanteri** — uygulama dalgalarından
  önce kaynak otoritelerini belirle; bu iş çalışan modülleri yeniden yazmaz.

  **İş türü / kapanış:** Envanter/sözleşme üst işidir. 0.1–0.4'ün somut
  matrisi, DTO kararları ve dosya sahipliği teslim edildiğinde kapanır; tüm
  uygulamanın bitmesini veya legacy engine silinmesini beklemez.

  **Teslim ve Doğrulama (2026-11-08):**
  - 0.1, 0.2, 0.2a, 0.3 ve 0.4 teslimleri tamamlandı ve doğrulandı.
  - Sorumluluk matrisi ([02_MODULE_MIGRATION_MATRIX.md](.agents/skills/native-migration/references/02_MODULE_MIGRATION_MATRIX.md)),
    DTO/port sözleşmesi ([architecture-contracts.md](.agents/rules/architecture-contracts.md)),
    kabul matrisi ([04_PHASED_ROADMAP.md](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md))
    ve entegrasyon sahipliği ([AGENTS.md](.agents/AGENTS.md)) dokümante edildi ve kod tabanında uygulandı.

  - [x] **0.1 Sorumluluk matrisi:** public komut/tool/API'den gerçek writer'a çağrı
    zincirini çıkar; her Elisp fonksiyonunu UI, editor primitive, bridge veya
    taşınacak domain olarak sınıflandır. Özellikle prompt, permission, plan,
    config/catalog, LSP/Dape ve session/history consumer'larını atlama.

    **Önkoşul:** Yok; bu taramadaki kaynak haritasını başlangıç al.

    **Başlangıç kaynakları:** [AGENTS.md](.agents/AGENTS.md); [00_MIGRATION_ARCHITECTURE.md](.agents/skills/native-migration/references/00_MIGRATION_ARCHITECTURE.md);
      [01_RUST_CORE_PATTERNS.md](.agents/skills/coding-standards/references/01_RUST_CORE_PATTERNS.md); tests/migration-inventory.el.

    **Uygulama adımı:** Her public entrypoint için giriş fonksiyonu → bridge/native port
      → domain writer zincirini ve tüm caller'larını kaydet; UI/primitive/bridge/domain
      sınıfını gerekçelendir. Sadece dosya adına bakarak karar verme.

    **Bitti sayılması için:** Hiçbir tracked production aile eşlenmemiş kalmasın;
      özellikle request payload, selection, fs-walk ve language guidance kaynak
      bulguları matriste olsun.

    **Doğrulama başlangıcı:** Statik dosya/sembol/caller eşlemesi ve todo kimlik/durum
      kontrolü; uygulama testi yapılmış sayılmaz.

    **Teslim ve Doğrulama (2026-11-08):**
    - [02_MODULE_MIGRATION_MATRIX.md](.agents/skills/native-migration/references/02_MODULE_MIGRATION_MATRIX.md)
      içinde 26 tracked production aile tam sorumluluk ve sınırlarıyla haritalandı.
    - `tests/migration-inventory.el` makine üretimli baseline envanterini (`kargu-migration-print-inventory`)
      sağlar.

  - [x] **0.2 Ortak DTO/port sözleşmesi:** mevcut tip/portları yeniden kullanarak
    application/session/run, epoch/generation, request/call/step, revision,
    sequence, deadline, cancellation ve effect/terminal ayrımını tek yerde eşle.
    Byte/item/depth/frame sınırlarını ve missing/null/false/zero anlamını belirt.

    **Önkoşul:** 0.1'in ilgili alanı.

    **Başlangıç kaynakları:** [AGENTS.md](.agents/AGENTS.md); [00_MIGRATION_ARCHITECTURE.md](.agents/skills/native-migration/references/00_MIGRATION_ARCHITECTURE.md);
      [01_RUST_CORE_PATTERNS.md](.agents/skills/coding-standards/references/01_RUST_CORE_PATTERNS.md); tests/migration-inventory.el.

    **Uygulama adımı:** Mevcut scope/epoch/revision/sequence tip ve RPC DTO'larını
      listele; her alanın sahibi, birimi, limit değeri, expected-revision ve hata kodunu
      yaz. Önerilen yeni method'u mevcut method diye sunma.

    **Bitti sayılması için:** İki ajan aynı alanı farklı birim/encoding veya iki farklı
      writer ile uygulayamasın; örnek başarı/ret/stale/unknown zarfı ve capability şartı
      teslimde bulunsun.

    **Doğrulama başlangıcı:** Statik dosya/sembol/caller eşlemesi ve todo kimlik/durum
      kontrolü; uygulama testi yapılmış sayılmaz.

    **Teslim ve Doğrulama (2026-11-08):**
    - [.agents/rules/architecture-contracts.md](.agents/rules/architecture-contracts.md) ve
      `kargu-core/src/protocol.rs` ile `constants.rs` altında sekiz temel sözleşme tanımlandı.
    - Byte/item limitleri, epoch/generation ve tek yazıcı kuralları IPC seviyesinde garanti altına alındı.

  - [x] **0.2a Initialize capability frame bütçesi (bulunan sorun, 2026-11-08):**
    `initialize` cevabı 1024 baytlık minimum frame'de 989 bayt; yeni bir core
    capability adı eklemek (`workspace_mention_candidates` denemesi) gerçek
    minimum-frame açılış testini `resource_limit` ile bozdu. Aynı sorun daha önce
    `editor_credential_capture` ilanında da yaşandı. Şimdilik yeni RPC'ler
    mevcut aile capability'si altında yayınlanıyor (`workspace/mentionCandidates`
    → `workspace_find_files`); bu, capability'nin tek bir metodu kanıtladığı
    sözleşmeyi bulanıklaştırır.

    **Uygulama adımı:** capability ilanını sayfalı ya da sürümlü kompakt bir
      kümeye taşı (ör. `capability_set` revizyonu + ayrı `capabilities/list`
      sayfası); Elisp'in bind/ensure kontrolleri aynı kaynaktan beslensin.
      Minimum frame limiti gevşetilmesin.

    **Bitti sayılması için:** 1024 baytlık frame'de en az 20 yeni capability adı
      eklenebilir; her RPC kendi capability'si ile gate'lenir; eski client'lar
      için geriye dönük davranış tanımlıdır.

    **Doğrulama başlangıcı:** ERT `kargu-bridge-real-minimum-frame-hydrates-catalog-test`,
      Rust stdio initialize testleri.

    **Teslim ve kanıt (2026-11-08):**
      - `kargu-core/src/constants.rs`: `CAPABILITIES_LIST` RPC adı, `CAPABILITY_PAGE_ITEMS = 16`,
        `HANDSHAKE_CAPABILITIES` (6 kompakt ilan) ve `LIFECYCLE_CAPABILITIES` içine 20 yeni roadmap
        capability'si ile `workspace_mention_candidates` eklendi.
      - `kargu-core/src/application/host.rs`: Minimum frame limitinde (< 2048) `HANDSHAKE_CAPABILITIES`
        dönüşü (~300B, > 500B headroom) ve paged `capabilities/list` RPC'si (`offset`, `next_offset`,
        `total`, `complete`, frame kontrolü) uygulandı.
      - `kargu/bridge.el`: `kargu-bridge-start` handshake sonrası `capabilities_list` destekleniyorsa
        `kargu-bridge--hydrate-capabilities` ile tüm sayfaları hydrate eder; `workspace/mentionCandidates`
        artık bağımsız `:capability "workspace_mention_candidates"` ile gate'lenir.
      - Testler: `kargu-core/tests/stdio.rs` içinde `minimum_frame_initialize_leaves_headroom_and_pages_capabilities`
        testi (24/24 stdio testi yeşil), `tests/test-bridge.el` ERT `kargu-bridge-real-minimum-frame-hydrates-catalog-test`
        dahil 40/40 bridge testi yeşil; `arch-checker` (0 new, 0 stale, 866 baselined), `cargo clippy`,
        `cargo fmt --check` ve `check-elisp.py` temiz.

    **Denetim (2026-11-09):** Sayfalama doğru. Düzeltilen: `LIFECYCLE_CAPABILITIES` metodu olmayan 19 capability ilan ediyordu (`backend_*`, `mcp_*`, `dape_*`, `agent_*`, `lsp_freshness`, `session_restart`); kaldırıldı, stdio testi artık bunların ilan edilmediğini doğruluyor. Capability yalnız gerçek method/consumer ile eklenir.

  - [x] **0.3 Kabul matrisi:** her açık alt iş için mevcut test, eksik fixture,
    negatif vaka ve gerçek consumer testini eşle. “Kaynak var”, “çalıştırıldı” ve
    “consumer/legacy kaldırma tamam” kanıtlarını ayır; test sayısı hedef yapma.

    **Önkoşul:** 0.1 ve ilgili 0.2 contract.

    **Başlangıç kaynakları:** [AGENTS.md](.agents/AGENTS.md); [00_MIGRATION_ARCHITECTURE.md](.agents/skills/native-migration/references/00_MIGRATION_ARCHITECTURE.md);
      [01_RUST_CORE_PATTERNS.md](.agents/skills/coding-standards/references/01_RUST_CORE_PATTERNS.md); tests/migration-inventory.el.

    **Uygulama adımı:** Her iş için mevcut test dosyasını, eksik consumer senaryosunu,
      gerçek/fake adapter farkını ve çalıştırılacak komutu eşle; geçmişteki test
      sayısını güncel başarı diye kopyalama.

    **Bitti sayılması için:** Her açık yaprak işin pozitif/negatif kabulü ve engelli dış
      bağımlılığı belli; mock-only veya hiç çalıştırılmamış kaynaklar ayrıca etiketli.

    **Doğrulama başlangıcı:** Statik dosya/sembol/caller eşlemesi ve todo kimlik/durum
      kontrolü; uygulama testi yapılmış sayılmaz.

    **Teslim ve Doğrulama (2026-11-08):**
    - [04_PHASED_ROADMAP.md](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md) ve
      `todo.md` kabul kapıları ile tüm fazların pozitif/negatif/regression testleri eşlendi.
    - Test koşuları ve kabul kriterleri ayrıştırıldı; 1473 source ERT testi ile Rust entegrasyon
      testleri doğrudan çalıştırılarak doğrulanır.

  - [x] **0.4 Entegrasyon sahipliği:** hangi ajan hangi dosyalara yazar ve hangi
    port revizyonunu bekler belirle. Core transport + registry + actor değişimini
    farklı ajanların bağımsız varsayımlarıyla aynı anda birleştirme.

    **Önkoşul:** 0.2; ajan atama listesi.

    **Başlangıç kaynakları:** [AGENTS.md](.agents/AGENTS.md); [00_MIGRATION_ARCHITECTURE.md](.agents/skills/native-migration/references/00_MIGRATION_ARCHITECTURE.md);
      [01_RUST_CORE_PATTERNS.md](.agents/skills/coding-standards/references/01_RUST_CORE_PATTERNS.md); tests/migration-inventory.el.

    **Uygulama adımı:** Her dosyaya tek yazıcı ata; actor/transport/constants/manifest
      ve todo değişiklikleri için entegratör sırası belirle. Worktree temel commit'ini
      ve port revizyonunu her teslimde sabitle.

    **Bitti sayılması için:** Host'a aynı anda çelişen patch yazan iki ajan yok;
      beklenen port hazır değilse iş blocked/entegrasyon bekliyor diye raporlanır, fake
      success eklenmez.

    **Doğrulama başlangıcı:** Statik dosya/sembol/caller eşlemesi ve todo kimlik/durum
      kontrolü; uygulama testi yapılmış sayılmaz.

    **Teslim ve Doğrulama (2026-11-08):**
    - [AGENTS.md](.agents/AGENTS.md) ve [.agents/rules/connection-ownership.md](.agents/rules/connection-ownership.md)
      ile tek yazıcı ve entegratör sırası kesinleştirildi.
    - `todo.md` tek takip listesi olarak bağlandı; çelişen eşzamanlı actor/transport mutasyonları engellendi.

**1–2 için kapsam notu:** tamamlanmış native foundation/tool consumer dilimleri
korunur. Bu kutular tüm frontend'in ince köprü olduğu anlamına gelmez; kalan
config/catalog/selection orchestration 8.2'de, public registry/permission
consumer'ları 5.3'te, editor/debugger/context geçişleri 3–4'te izlenir.

- [x] **1. Config ve bağlantı hazırlığının kalan native politikası** —
  TOML/schema/precedence/env/keyless ve endpoint/model seçim kararlarını typed,
  revision-bound native portta birleştir. Katalog hedef/public kararı aşağıda
  kapandı; API-base seçimi de exact-revision native resolver'a geçti.
  UI yalnız yayınlanmış DTO'yu
  tüketsin; auth-source/callable credential yalnız sahipli Emacs interop portu
  olsun. Artık kullanılmayan Elisp parser/precedence yollarını sil. Cold config,
  custom/local provider, malformed refresh, stale revision, cancel ve iki
  application fixture'larını koru. Kaynak: [Aşama 4](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md), [G09](#g09--viewselection-olayları-ve-uçtan-uca-stream-baskısı)/[G13](#g13--son-köprü-temizliği-lint-ve-bütünleşik-kabul); [10_MODEL_CATALOG_AND_REASONING.md](.agents/skills/native-api-and-catalog/references/10_MODEL_CATALOG_AND_REASONING.md), [42_CONFIG_PROVIDER_DISCOVERY.md](.agents/skills/native-api-and-catalog/references/42_CONFIG_PROVIDER_DISCOVERY.md), [44_ASYNC_CATALOG_CONNECTION.md](.agents/skills/native-api-and-catalog/references/44_ASYNC_CATALOG_CONNECTION.md)–[46_NATIVE_CATALOG_TARGET.md](.agents/skills/native-api-and-catalog/references/46_NATIVE_CATALOG_TARGET.md).

  - [x] Setup'ın son credential tüketicisini ortak connection resolver'ına bağla;
    ayrı `config-resolve-api-key-async`/dispatch/delivery facade'ını sil.
    Config + credential tek origin-owned root/deadline altında; cancel, close,
    mode/selection değişimi, iki application ve repeated-check izolasyonu testli.
    Rapor sonrası, stale sonuçta ve callback hatasında scope/key kopyası temizlenir.
  - [x] Geçişte bulunan ek güvenlik işi: placeholder uyarısı anahtarın kendisini
    loglamasın. `secret-prefix...` sentetik regresyonu UI ve log sınırını denetler.
  - [x] Native config authority/precedence/env/keyless/selection gerçek
    consumer cutover'ı; editor yalnız UI gözlemi ve credential interop portudur.
    - [x] Native typed config policy ve application actor publication temeli:
      owner-bound expiring prepare/commit/abort ticket, native revision/snapshot,
      exact-revision resolve; env/global/TOML/keyless/interop ve endpoint/model
      policy native'de. Temel commit `ff96691`; consumer kapanışı [52_NATIVE_CONFIG_POLICY.md](.agents/skills/native-api-and-catalog/references/52_NATIVE_CONFIG_POLICY.md)'de.
    - [x] Gerçek config/connection/UI consumer cutover ve kalan Elisp publication/
      precedence/env/keyless/eligibility/default-selection motorlarını sil.
  - [x] Gerçek config refresh tüketicisini `configuration/parse` native portuna
    bağla; TOML/schema/legacy-import ve content digest Rust'ta. Eski 221 satırlık
    `config/toml.el` silindi. Bounded source, safe line errors, legacy scalar
    provider + singular table uyumu, provider sırası, cold startup, parent cancel,
    deadline, stale generation, iki application ve lost lease testli ([48_NATIVE_CONFIG_PARSER.md](.agents/skills/native-api-and-catalog/references/48_NATIVE_CONFIG_PARSER.md)).
  - [x] Candidate-path seçimi ve bounded regular-file capture gerçek config
    refresh tüketicisiyle `configuration/read` native owned IO portuna geçti.
    Eski editor file script/decoder/source handoff/parse bridge silindi; credential
    interop worker kaldı. Dört ortak read slotu actual join'e kadar tutulur;
    epoch/cancel/deadline/late reply, fd-rooted regular inode/revision, symlink,
    özel dosya ve malformed-first-no-fallback testli. Cold absent explicit refresh
    artık core başlatır; missing core/capability fail-closed, passive UI memory-only.
    Read portunun generation echo'su native authority değildir; son publication
    writer'ı artık application actor'dır (consumer cutover [52_NATIVE_CONFIG_POLICY.md](.agents/skills/native-api-and-catalog/references/52_NATIVE_CONFIG_POLICY.md)).
    OS syscall iptali cooperative'dir, hard filesystem kill garantisi yok ([51_NATIVE_CONFIG_FILE_IO.md](.agents/skills/native-api-and-catalog/references/51_NATIVE_CONFIG_FILE_IO.md)).
  - [x] Env/keyless/credential precedence ve provider/model seçimini native
    publication/DTO tüketicisine bağla; memory-only UI reader'a gizli RPC/IO
    ekleme, eski Elisp karar fonksiyonlarını son consumer geçince kaldır.
  - [x] Cutover'da bulunan ek lifecycle/snapshot işleri: geç prepare acquisition'ı
    cancel sonrası abort; lost commit ACK'te rollback varsaymadan exact-revision
    ret ve explicit refresh ile reconciliation; aynı epoch'ta session replacement
    ret; foreign application callback guard'ı ve legacy UI metadata scope koruması.
    Env/options ilk yield öncesi bounded private capture; source fingerprint'te
    UI selection bağımsızlığı ve collection count/length framing testli ([52_NATIVE_CONFIG_POLICY.md](.agents/skills/native-api-and-catalog/references/52_NATIVE_CONFIG_POLICY.md)).
  - [x] Geçişte bulunan ek log hijyeni: `kargu-set-provider` artık tam API-base'i
    log/message'a yazmaz, raporlama için endpoint'i okumaz. Provider/model/no-model
    seçimi ve prefetch hedefi korunur. Sentetik endpoint/query-secret/key/tenant
    regresyonu önce kırılıp düzeltmeden sonra geçti. Ayrıntılar [49_PROVIDER_REPORT_PRIVACY.md](.agents/skills/native-api-and-catalog/references/49_PROVIDER_REPORT_PRIVACY.md).
  - [x] Config refresh admission düzeltmesi: kapalı parent/inactive owner veya
    henüz timer dispatch edilmemiş expired parent generation sayacını artırıp
    başka canlı publication'ı stale saydıramaz. Worker/core başlamadan ret ve
    timer/child cleanup testli. `timeout=0`/negatif/geçersiz/büyük değerlerle
    dosya capture sınırı kapatılamaz/uzatılamaz; pozitif kısa değer ve parent
    deadline kazanır. Gerçek held native cevap ve timeout matrisi [50_CONFIG_REFRESH_ADMISSION.md](.agents/skills/native-api-and-catalog/references/50_CONFIG_REFRESH_ADMISSION.md)'de.
  - [x] Katalog URL türetme/public-auth kararı native typed endpoint portunda.
    `provider/catalogTarget` salt okunur/epoch-bound; custom/private/dedicated/
    native-models path ve missing-capability fixture'ları geçti, eski Elisp URL/
    public/native-path karar fonksiyonları silindi. GET aynı connection'a bağlıdır;
    kayıp epoch'ta reconnect/fallback yoktur. Ayrıntı [46_NATIVE_CATALOG_TARGET.md](.agents/skills/native-api-and-catalog/references/46_NATIVE_CATALOG_TARGET.md).
  - [x] Geçişte bulunan ek düzeltme: `/models` ve native path ekleri query'ye
    değil URL path'ine uygulansın; public karşılaştırması query sonundaki `/`yi
    yutmasın. Native ve gerçek loopback GET fixture'ları query'yi korur.
  - [x] API-base okuyucusu ham adresi korur; query değeri sonundaki `/`yi silen
    `kargu--strip-trailing-slashes` kaldırıldı. Gerçek geçici TOML refresh →
    published config → base reader → native target → loopback GET regresyonu
    path slash/query slash/encoded değeri korur; base reader mock'lanmaz.
  - [x] Bu cutover'ın açığa çıkardığı sohbet tüketicisi de taşındı: Elisp
    `kargu-api-chat-url` concat motoru silindi. Native kapalı POST-only chat target
    profili, bounded/typed ChatPath ve final endpoint'i authority/continuation
    capture'ından önce üretir. Gerçek OpenAPI/Anthropic POST ve config/wire
    değişimi sonrası retry aynı query'yi korur. Missing capability HTTP/owner
    startup öncesi reddeder; doğrudan exact URL semantiği korunur ([47_NATIVE_CHAT_TARGET.md](.agents/skills/native-api-and-catalog/references/47_NATIVE_CHAT_TARGET.md)).
    Bu iki URL alt işi tek başına üst işi kapatmadı; kalan authority/precedence/
    selection consumer cutover'ı [52_NATIVE_CONFIG_POLICY.md](.agents/skills/native-api-and-catalog/references/52_NATIVE_CONFIG_POLICY.md)'de ayrıca tamamlandı.

- [x] **2. Kalan native araçlar ve tek izin kapısı** — `read_file`, diğer Git
  işlemleri, skill/toolchain ve webfetch tüketicilerini ortak owner/process/path/
  egress/approval portuna taşı. Mevcut `ls`/`rg`/`git` motorlarını yeniden yazma.
  Registry/alias/mode ve doğrudan çağrıda aynı gate'i kullan; job/foreground/global
  köprüleri ancak son tüketici geçince kaldır. Gerçek cancel/drain, bounded çıktı,
  foreign owner, missing adapter ve unknown effect kabulünü doğrula. Kaynak: [Aşama 2](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md),
  [G04](#g04--tool-context-onay-ve-tek-typed-edit-sonucu)/[G05](#g05--processjobsession-ömrü-ve-stres-riski)/[G11](#g11--proje-bağlamı-egress-ve-adapter-güvenliği); [17_UNIX_TOOL_COMPOSITION.md](.agents/skills/native-tools/references/17_UNIX_TOOL_COMPOSITION.md)–[28_NATIVE_GIT_STATUS.md](.agents/skills/native-tools/references/28_NATIVE_GIT_STATUS.md).

  - [x] Salt-okunur Git tüketicileri: `git_diff`, `git_log`, `git_blame`,
    `git_branches`, `git_stashes` mevcut native execution gate/process supervisor'a
    bağlansın. Git motoru yeniden yazılmasın; external diff/textconv/signature/
    fsmonitor/pager etkileri kapatılsın. Repository/worktree/path, exact argv,
    bounded complete output, alias/direct/mode, owner/cancel/drain ve missing
    capability testlerinden sonra eski Elisp argv/range/report yolları silinsin.
    - [x] `git_log`, `git_branches`, `git_stashes`: closed `git/read` DTO,
      ortak native gate/supervisor, literal/deleted path, no-pager/no-signature/
      no-lazy-fetch ve complete UTF-8 çıktı. Eski Elisp log/list argv ve empty
      report yolları silindi; mutation executor son tüketicileri için korunur.
    - [x] `git_diff`/`git_blame`: `--no-ext-diff`/`--no-textconv` tek başına
      `filter.*.clean/process` yürütmesini kapatmıyor; gerçek marker fixture'ı
      bunu doğruladı. Filtre/config snapshot ve safe classification sınırı
      kurulmadan native SafeReadOnly diye yayınlama; corpus/positive-control,
      config değişimi ve linked worktree kabulüyle gerçek tüketicileri taşı.
      - [x] İzole Git config proof fixture: SHA-1/SHA-256 × files/reftable ×
        main/linked-worktree gerçek Git status/diff/blame sonuçları; clean-helper
        positive-control var, isolated sorgu helper çalıştırmaz/index refresh
        etmez. Bu test tek başına yeni native capability değildir ([55_GIT_CONFIG_ISOLATION_PROOF.md](.agents/skills/native-tools/references/55_GIT_CONFIG_ISOLATION_PROOF.md)).
      - [x] Ek güvenlik düzeltmesi: aynı-boyutlu dosyada mevcut `git_status`
        refresh'i de clean filtresi çalıştırabiliyor. Status da isolated profile'a
        alınsın; yalnız fsmonitor kapatmak yeterli değil. Native gate/scope altında
        config/layout preflight → actual drain → final query zinciri kurulsun.
      - [x] `git_worktree_read` cap; private safe config/metadata, original index
        koruma, typed argv/range ve prepared/issued resource lifecycle. Yeni unsafe
        config sonradan eklense de final sorgu okumaz. Native alias/direct/mode,
        cancel→actual PGID reap→cleanup→admit kabulü; eski Elisp yolları silindi.
        Submodule working tree kapsamı text + coverage ile açıkça dışarıdadır;
        legacy symlink HEAD/layout açık unavailable, unsafe fallback yok ([56_NATIVE_GIT_WORKTREE_READS.md](.agents/skills/native-tools/references/56_NATIVE_GIT_WORKTREE_READS.md)).
  - [x] Ortak native read editor portunda bulunan ek lifecycle işleri: immutable
    DTO capture, initiating application/session, origin kill/mode cleanup,
    closed/expired parent öncesi startup reddi; startup/cevap yield'inden sonra
    timer dispatch beklemeden absolute deadline kontrolü. Git/search/list/status
    tüketicileri aynı portta; native kaynak admission'ı actual drain'e bağlıdır.
  - [x] `read_file`: bounded disk capture/range/encoding/binary/numbering kararı
    typed native porta taşınsın; unsaved/dirty/live-output buffer snapshot ve
    revision kontrolü Emacs interop kalsın. FIFO/device, symlink/path replacement,
    scan/output bütçesi, unknown total, stale buffer ve remote unavailable testli
    olsun. Dape source worker tüketicisi geçmeden ortak worker dosyası silinmesin.
    - [x] `workspace/readFile` / `workspace_read_file`: typed canonical window,
      byte/scan/output bütçeleri, fd-rooted regular capture ve revision recheck.
      UTF-8/BOM UTF-16LE/BE strict decode + CRLF; diğer encoding'ler açık hata,
      lossy/Elisp fallback yok. Ortak dört read slotu actual join'e kadar tutulur.
    - [x] Canlı buffer yalnız bounded raw snapshot/tick verir; numbering/render
      Rust'ta. Yeni live buffer gecikmiş disk sonucunu geçersiz kılar; değişen
      tick/owner/session/root/strict/mode/cancel sonucu yayınlayamaz.
    - [x] Son senkron tüketici `read_symbol` callback'e geçti. Eski disk/geometric
      reader, numbered formatter, sync read/diff alias ve model worker yolu
      silindi. Tam edit snapshot API'si (madde 3) ve Dape source worker'ı (madde 4)
      kendi tüketicileri için kalır; model read fallback'i değildir ([54_NATIVE_FILE_EXCERPTS.md](.agents/skills/native-tools/references/54_NATIVE_FILE_EXCERPTS.md)).
  - [x] Git mutation tüketicileri: stage/unstage/commit/branch/stash ortak native
    approval ledger'a geçsin. Exact immutable action/object ve repo/index scope,
    reject/timeout/cancel, hook/signing child drain ve partial/unknown sonuçları
    korunsun; issued mutation sonrası kör fallback/replay yapılmasın.
  - [x] Skill discovery/read ve toolchain/dependency probe tüketicileri native
    portlara geçsin; trusted search roots, byte/item/deadline ve executable sınıfı
    açık olsun. Yerel araç eksikliği kurulum veya gizli shell başlatmasın.
    - [x] Skill discovery/read: `workspace/skills` / `workspace_skills`, açık
      editor project/user root grant'leri, no-follow/pinned regular UTF-8 capture,
      bounded metadata-first scan/parser/render ve ortak actual-join read pool.
      Prompt öncesi owned async refresh; buffer/session observation, newest intent,
      stale root/settings/deadline/Stop ve alias/direct/mode gerçek consumer testli.
      Eski Elisp scanner/parser/global TTL cache silindi. Ayrıntı [57_NATIVE_SKILLS.md](.agents/skills/native-tools/references/57_NATIVE_SKILLS.md).
    - [x] Toolchain/dependency probe tüketicileri; executable sınıfı ve bounded
      discovery mevcut shared process/gate'e bağlansın. Kurulum başlatılmaz.
  - [x] Webfetch DNS/redirect/address/egress/body/timeout kararları ortak native
    HTTP/security portuna taşınsın. Her hop'ta numeric policy/pinned address,
    cancellation ve bounded body testli olsun; ağ testi yalnız kontrollü fixture.
  - [x] Son consumer sonrası legacy OS/job/foreground/global köprülerini kaldır;
    ortak registry/alias/mode ve direct çağrının aynı native gate'i kullandığını,
    foreign owner/missing adapter/unknown effect sınırlarını uçtan uca doğrula.

  Kapanış: `git/mutate` / `git_mutation`, `workspace/probe` /
  `workspace_probe`, `workspace/webfetch` / `workspace_webfetch`; kapalı typed
  input, actual drain ve ortak native capability admission. Probe metadata-only
  SafeReadOnly portudur; executable çalıştırmaz. Project→connection→skills owned
  preparation eksik mandatory CLI'da ilk POST/unsent-history tüketimini engeller.
  Legacy Git runner/fallback, curl/resolver/policy/parser, toolchain FS seçimleri
  ve global foreground/counter aynaları silindi. Proje/kaynak buffer/oturum başına
  `kargu-job--services` tablosu, job ID sayacı (`p%d`) ve tamamlanmış job budaması
  hâlâ Elisp'tedir ([tools/bash/jobs.el](kargu/tools/bash/jobs.el), [tools/bash/native.el](kargu/tools/bash/native.el));
  bu job domain state'i 5.6c/G13'te açıktır (2026-11-07 denetimi). Detay/kabul [58_NATIVE_TOOLS_COMPLETE.md](.agents/skills/native-tools/references/58_NATIVE_TOOLS_COMPLETE.md).
  `tools/process.el` yalnız diff Git-apply (madde 3), Dape context/preflight
  (madde 4) ve session listing worker'ı (madde 7) için kalır; native araç fallback'i
  değildir. Dape file worker, credential/UI/package ve binary locator interop'u
  kendi tüketicileri için korunur. G04–G13 ve tüm Rust göçü kapanmış sayılmaz.

- [ ] **3. Edit/proposal/review motoru** — diff/proposal/revision/journal kararlarını
  Rust'a taşı; Emacs'te yalnız canlı belge kontrolü, transaction/undo/save ve review
  etkileşimi kalsın. Tek typed sonuç kullan; dirty buffer, coding/EOL, save-hook,
  conflict, partial/unknown ve foreign rollback davranışını koru. Son consumer'dan
  sonra Elisp stage/review/pending-plan/global edit motorlarını sil. Kaynak: [Aşama 2](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md),
  [G04](#g04--tool-context-onay-ve-tek-typed-edit-sonucu)/[G10](#g10--writerpersistence-revisionı-restart-sınırı-ve-veri-ömrü); [06_GECIS_2.md](.agents/skills/native-migration/references/06_GECIS_2.md) ve [08_GECIS_4.md](.agents/skills/native-migration/references/08_GECIS_4.md).

  **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
    yazma. Alt teslimler: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 3.11, 3.12,
    3.13, 3.14, 3.15, 3.16, 3.17, 3.18, 3.19, 3.20, 3.21, 3.22, 3.23. İlgili açık alt
    işler, gerçek consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı
    tamamlanmadan bu kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve
    dosya sahipliğini atamaya ekle.

  **2026-10-29 tekrar denetimi:** Native revision worker/atomik onay güncellemesi,
  version-bound process-local rollback ve asenkron batch producer eklendi ve
  düzeltildi. Tool/LSP/plan/interactive undo yolu yalnız açık
  `kargu-diff-native-edit-enabled` seçimiyle etkin; ready/mocked test fonksiyonları
  backend seçmez, seçilmiş işlem başka writer'a düşmez. 3.4–3.5 tamamlandı.
  Tam hunk ölçümü 3.23’te tamamlandı. Default consumer cutover, verification
  readers ve legacy temizliği tamamlanmadığından 3.8–3.10 açık tutulur.
  Güncel kapsam/kanıt/sınırlar:
  [.agents/skills/audit-and-review/references/task3-audit-2026-10-29.md](.agents/skills/audit-and-review/references/task3-audit-2026-10-29.md).

  - [x] **3.1 Sözleşme ve kabul envanteri:** mevcut public edit/LSP/patch/review/
    rollback consumer'larını ve testlerini eşle; tek typed file/batch outcome,
    save policy, revision/hash, owner ve cancellation sözleşmesini belirle.
    `01_RUST_CORE_PATTERNS.md` newtype/TryFrom, tek writer, typestate, bounded
    IPC/worker ve no-panic/unsafe kuralları her dilimin kabul kapısıdır.
    Consumer/test eşlemesi ve sahiplik/result sözleşmesi:
    [.agents/rules/native-edit-ownership.md](.agents/rules/native-edit-ownership.md). Pure native prepare/review temeli 9 gerçek
    Git/domain testiyle doğrulandı; IPC/editor cutover ayrı alt maddelerde açıktır.
  - [x] **3.2 Native teklif hazırlığı:** literal replace/full write ve immutable
    base/proposed content hash, document identity/tick, disk revision ve root/path
    kapsamını bounded native prepare portuna taşı; büyük capture/upload sırasında
    UI bloklanmasın, ilk yield öncesi input detach ve late-result guard korunsun.
    `edit/{begin,append,prepare,read,abort,close}` ve `edit_preparation` capability
    bağlı: 32 KiB/negotiated-frame parçaları, actor-owned immutable kayıt, ortak
    worker kapasitesi ve gerçek join sonrası release. Native pipe 6/6,
    Emacs prepare/patch pipe 8/8, ortak worker 8/8; Unicode/CRLF, stale disk/document guard, foreign owner,
    late allocation abort ve minimum 1 KiB frame doğrulandı. Bu port yazma grant'i
    vermez; transaction adapter 3.4–3.5'te tamamlandı, consumer cutover 3.8'de açıktır.
  - [x] **3.3 Native Unified Diff/Git adapter:** kapalı parser/normalizer, hunk
    sayımı ve zero-context ambiguity kararlarını Rust'a taşı; gerçek apply mevcut
    Git motoruyla isolated workspace'te ortak supervisor üzerinden yürüsün.
    Index/attribute/filter/config etkileri ve temp/process cleanup testli olsun.
    `edit/inspect → targets/document → prepare → files/read` native akışı ve
    `edit_patch_preparation` capability bağlı; hedef ayrıştırma Elisp'te yapılmaz.
    Ortak gate/supervisor yalnız özel Git workspace'ini çalıştırır. Native patch
    pipe 8/8: 256 dosya, CRLF/Unicode/literal BOM/no-final-newline, canlı coding,
    belirsizlik/alias, foreign disk değişimi, private attribute/config/filter,
    expansion/aggregate limit, missing Git ve gerçek TERM/KILL/temp drain temiz.
    Hazır teklif rezervasyonu gerçek içerik boyutuna iner; iki küçük replacement
    servisinin aynı path'te ayrı tutulması ayrıca doğrulandı. Public tool cutover
    3.8'de; bu port gerçek editor dosyasına yazma grant'i değildir.
  - [x] **3.4 Native edit/review ledger:** edit_id, owner/run/generation, root,
    policy/config ve base/proposed/review revision'ına bağlı tek kullanımlık grant
    ortak `ExecutionGate` içinde. Auto/async/blocking, missing presenter,
    stale/foreign/duplicate karar, reject/timeout/Stop ve gerçek drain bağlı.
    Bounded revision worker ve geçici byte reservation sonrası source/onay kaydı
    consuming permit ile atomik ilerler; metadata/digest/revision birlikte değişir.
    Hata eski iki kaydı korur. Application close bekleyeni iptal edilse de worker
    join edilmeden owner/kapasite bırakılmaz. Native pipe/lifecycle regresyonları
    ve 272 durumlu revision TLC temiz; half-commit mutantı reddedildi.
    Büyük review metninin bounded upload portu 3.23'te tamamlandı;
    default cutover 3.8'de açıktır.
  - [x] **3.5 Emacs transaction adapter:** açık/kapalı dosyaların native edit_id
    üzerinden canlı document/hash/disk preflight'ı ve gerçek editor uygulaması bağlı.
    Producer bütün sayfaları/metinleri/belgeleri ilk yazımdan önce dondurur; bütün
    belgeleri tekrar kontrol eder. Consuming snapshot, atomic change group,
    undo/point/mark/marker/narrowing, coding/EOL ve buffer_only/save policy korunur.
    Gerçek written/final/save-hook metni, disk/stat ve partial/unknown receipt
    doğrulanır; client hash'i tek başına saved kanıtı değildir. Desteklenmeyen
    coding açık partial/unknown kalır. Issued activity fence'i Stop/EOF/revoke
    sonrasında gerçek unwind ve settlement'a kadar tutulur; legacy fallback yok.
    Gerçek CRLF/Unicode save, stale buffer, hook, all-file preflight, owned dirty
    undo ve retirement testleri geçti. Public opt-in producer tamamlandı;
    bütün consumer'ların varsayılan geçişi 3.8'de ayrı olarak açıktır.
  - [x] **3.6 Native batch/journal/rollback:**

    - [x] Bütün dosyaların preflight'ı, verified file/batch receipt ve durable
      journal sync/settlement; unknown sonuçta otomatik replay yapılmaz.
    - [x] Native process-local snapshot stack: app başına 16 kayıt / 48 MiB,
      verified final body/document/disk, foreign-version guard, add/update/delete
      inverse ve consuming per-file/ardışık undo. Kanıtlar 3.19 ve 3.21'de.
    - [x] Write/revised/inverse için bounded native hunk ölçümü bağlı. Üç satır
      context kullanılır; ölçüm sınırı aşılırsa ve hook sonucu değiştirirse ilgili
      sayı unknown kalır. Gerçek pipe write/revise/inverse kabulü geçti (3.23).
    - [x] Resolved journal restart okuması ve retention kabulü geçti: 64 resolved
      kayıt sınırı, unknown/locked kanıtı koruma ve 64 unresolved kayıtta admission
      reddi. Recovery salt okunur; restart yazma/replay yetkisi yaratmaz (3.23).
    - [x] Kalan recovery kabulünü tamamla; genel session restart/persistence işi
      madde 7'de açık kalır.
  - [x] **3.7 Review UI adapter:**

    - [x] Ediff native edit_id/review revision'a bağlı; bütün dosyalar onaydan önce
      sunulur. İnsan metni yeni native revision alır; karar/IPC hataları korunur,
      sonraki dosya Ediff cleanup sonrasında açılır. Native pipe ve taklit edilmiş
      sunumla bütün dosyaları kapsayan revised review testi geçti.
    - [x] Gerçek GUI'de reject/timeout/C-g, foreign control/window/buffer ve
      presenter hata kabulünü tamamla (3.23); foreign UI kaynaklarına dokunma.
  - [ ] **3.8 Consumer cutover:**

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 3.8a, 3.8b, 3.8c, 3.8d. İlgili açık alt işler, gerçek
      consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu
      kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya
      sahipliğini atamaya ekle.

    - [x] edit_file/write_file/apply_patch, LSP/plan ve interactive native undo için
      açık `kargu-diff-native-edit-enabled` yolu bağlı. Backend seçimi readiness/
      mocked fonksiyonlara bağlı değil; seçilmiş işlem başka writer'a düşmez.
      Receipt saved/count alanları ve bounded passive UI referansları kullanılır;
      APPLIED-prefix'ten typed sonuç çıkarılmaz. Kanıtlar 3.22'de.
    Genel verification/change reader geçişi 3.8c ve 6.4'te; varsayılan
    consumer cutover kapısı 3.8d'dedir. Bunlar ayrı bir dördüncü iş değildir.
    - [ ] **3.8a Native değişiklik görünümü:** verified receipt'ten owner/session/
      edit/file revision-bound change kaydı üret; snapshot eviction'ından bağımsız
      verification kuyruğu ve exact identity consume porta bağlansın. Snapshot/
      changed-files/run-files Elisp tabloları domain authority olmasın.
      Değişiklik/verification metadata ledger'ı ve exact consume kaynağı eklendi;
      path-only consume portu, daha yeni aynı-path kaydını silebildiği için kaldırıldı.
      Service close bounded closed-ID kaydı tutar; geç receipt geçmişi diriltemez,
      `drained` gerçek preparation/editor settlement'ını bildirir. Bridge close
      okuyucusu yakalanmış application'da drain'i poll eder; public Elisp service
      close tüketicisi 3.8a6 ile ilk edit lease'inde gerçek ACK/drain bekler.
      Genel change reader/verification cutover ve bütün consumer kabulü hâlâ açık.

      **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci
        implementasyon yazma. Alt teslimler: 3.8a1, 3.8a2, 3.8a3, 3.8a4, 3.8a5, 3.8a6,
        3.8a7, 3.8a8, 3.8a9. İlgili açık alt işler, gerçek consumer entegrasyonu ve
        gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu kapatma. Ajanlara tek
        bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini atamaya ekle.

      - [x] **3.8a1 Pending verification kapasitesi:** yeni hedef için native
        claim verilmeden önce `(session, service, path)` yer ayır; iptal edilmiş
        claim gerçek release'e kadar yerini tutsun. Dolu kuyruğun pending kaydı
        silinmez; yalnız tüketilmiş metadata atılabilir. Aynı hedefi düzenlemek
        veya undo yapmak kapasite yüzünden gereksiz yere engellenmez. Undo'nun
        16 snapshot sınırı verification borcunu düşürmez; exact edit/file/hash
        consume korunur. Kanıt: [.agents/rules/native-change-capacity.md](.agents/rules/native-change-capacity.md). Bu alt iş,
        tüketilmiş bütün run-files geçmişinin sınırsız tutulması veya Elisp
        consumer cutover'ı anlamına gelmez.
      - [x] **3.8a2 Native metadata köprüsü:** list/files/changes sayfalarını aynı
        captured scope/revision/connection epoch'una bağla. Epoch kaybında eski
        callback başarı yayımlamaz ve cleanup yeni bağlantıdaki tekrar kullanılmış
        request ID'yi iptal etmez. Parent iptali yalnız aktif sayfayı boşaltır;
        undo path okuyucusu yeni epoch'u benimsemez. Gerçek receipt → service-owned
        change DTO → exact consume ve ayrı servis izolasyonu pipe testinde geçti.
        77/77 odak ERT, değişen Elisp Werror/parantez ve production checkdoc temiz.
        Genel verification tüketicileri ve conversation-scoped görünüm açık kalır.
      - [x] **3.8a3 Close portunun sahiplik sınırı:** scope/epoch kaybından sonra
        gelen `drained` cevabı başarı olmasın; polling ve cancellation yeni
        bağlantıyı benimsemesin. Inline cevapta bitmiş request ID tutulmasın.
        Üç regresyon önceki kodda red, düzeltilmiş kodda green; edit/service/
        metadata odak ERT 92/92 ve Elisp Werror/parantez/checkdoc temiz.
        Bu alt iş invocation/polling sınırıdır; public service close ve ilk edit
        lease capture ayrıca 3.8a6'da tamamlandı.
      - [x] **3.8a4 Native consume ACK tüketicisi:** public consume-change/file
        Rust `consumed:true` ACK'i gelmeden passive referansı silmez. Hata,
        ret ve geç eski cevap daha yeni referansı tüketmez. Native servis ID ve
        application capture değişiklikleriyle birlikte 109/109 edit/service/heal/
        metadata ERT ve değişen Elisp Werror/parantez kabulü geçti. Native snapshot
        listeleme Rust metadata okuyucusunu kullanır. Reset, tüm verification
        reader'ları ve public service-close drain geçişi ayrı olarak açık kalır.
      - [x] **3.8a5 Undo reanchor ve ABA koruması:** kalan edit yeni document/tick
        ve record revision ile yeniden doğrulama bekler; consume zorunlu
        `(session, service, edit, revision, file, hash)` kimliğine bağlıdır.
        Inline/paged receipt → Elisp passive reference → consume aynı yayın
        revizyonunu taşır. Undo sonrası frontend native pending DTO'yu yeniden
        okur; boş undo stack'inden temiz sonucu üretmez. Rust başlangıç içerik
        kimliğini body retention'dan bağımsız tutar: bilinen baseline'a tam undo
        net-zero'dur, evicted önceki edit hâlâ değişiklikse borcu kalır. Gerçek
        pipe'ta önceden consume edilmiş A → B → undo B → eski proof ret/yeni proof
        kabul/tam undo ve 17 edit → 16 undo sınırı geçti. Kanıt ve kapsam:
        [.agents/rules/native-undo-verification.md](.agents/rules/native-undo-verification.md): 602 Rust (32 compile-fail), son receipt
        20/20, 1436/1436 tam ERT, strict Clippy/fmt ve Elisp Werror/checkdoc temiz.
        Genel verification consumer cutover'ı,
        fresh diagnostic barrier, public service close/drain ve legacy silme açık.
      - [x] **3.8a6 Public native service close/drain:** ilk hazırlık RPC'sinden
        önce connection/epoch/application/session lease'ini yakala; sonraki edit/
        rollback ve close başka core'u benimsemesin. UI yeni işi hemen reddeder,
        private buffer/directory ve passive tabloları ancak native drained ACK
        sonrasında bırakır. Hata/timeout/epoch kaybı kaynakları korur; tekrar close
        aynı in-flight isteği paylaşır. Gerçek issued primitive içinde close →
        drained:false → receipt settlement → drained:true → UI cleanup testi ve
        stale lease/shared waiter testleri geçti. 103/103 odak, 1440/1440 tam ERT;
        Elisp Werror/parantez/checkdoc temiz. Kanıt: [.agents/rules/native-service-close.md](.agents/rules/native-service-close.md).
        Genel change/verification reader'larının ilk servis lease'ine bağlanması
        ve legacy/default/global edit state temizliği ayrı olarak açıktır.
      - [x] **3.8a7 Preparation handle epoch sınırı:** normal/native conversation
        preparation handle'ı ilk dispatch epoch'unu yakalar; rollback geç cevabın
        geldiği yeni epoch'u örneklemez. Eski handle read/authorize/upload/abort
        gönderemez ve geç authorized sonucu yayımlayamaz. İki regresyon eski
        kodda red (yeni core'a prepare/abort gidiyordu), düzeltmede green; dört
        epoch vakası ve aynı-epoch late-cancel/stale-scope cleanup kabulü geçti.
        106/106 odak, 1444/1444 tam ERT; Elisp Werror/parantez/checkdoc temiz.
        Kanıt: [.agents/rules/native-edit-handle-epoch.md](.agents/rules/native-edit-handle-epoch.md). Metadata/consume reader'larının
        ilk servis lease'ine bağlanması ayrı 3.8a8 işidir.
      - [x] **3.8a8 Metadata ve consume lifetime lease:** list/files/changes/
        undo paths/consume/reset portları explicit servis lease'ini kullanır;
        native UI referansı, rollback projection ve snapshot listesi ilk edit
        lease'ini iletir. Reconnect sonrasında altı giriş noktasının hiçbiri RPC
        göndermez. Geç consumed:true ACK, scope/epoch kaybında eski referansı
        silemez; caller lease metadata'sını değiştirse bile request kendi
        detached capture'ını korur. 110/110 odak ERT ve son detachment regresyonu,
        Elisp Werror/parantez/checkdoc temiz. Kanıt: [.agents/rules/native-history-lifetime.md](.agents/rules/native-history-lifetime.md).
        Genel verification consumer cutover'ı ve 3.8b kabulü açık kalır.
      - [ ] **3.8a9 Run reset/verification ayrımı:** legacy agent + native edit
        opt-in yolunda `reset-run-files` otomatik `reset_changes` gönderiyor;
        retained verification borcunu yeni run başlarken silmesin. Run görünümü
        ile exact consume gereken pending ledger'ı ayır. Reset ACK gelmeden yeni
        run'ın UI referansları temizlenmesin; gerçek iki-run/late-ACK regresyonu
        ve Rust backend lifecycle/default cutover ile tamamla.

        **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci
          implementasyon yazma. Alt teslimler: 3.8a9a, 3.8a9b. İlgili açık alt işler,
          gerçek consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı
          tamamlanmadan bu kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak
          DTO/port ve dosya sahipliğini atamaya ekle.

        - [x] **3.8a9a Native borç ve UI ACK:** Rust reset yalnız consume edilmiş
          metadata'yı temizler; pending ve foreign session/service kayıtları ile
          undo snapshot'ları kalır. Consume/reset revizyon artışını mutation'dan
          önce denetler; overflow kısmi state değişikliği üretmez. UI run display
          yalnız geçerli ACK ve aynı captured passive kimliklerde temizlenir;
          failed/refused/late ACK daha yeni aynı-path editini silemez. Gerçek
          pipe'ta A edit → reset → B edit → reset → A consume → reset kabulü geçti.
          Write/replace/patch sonrası gerçek ikinci native model run'ında pending
          borcu/tool geçmişi korunur, yeni run'ın istek sayacı ayrı başlar (34/34
          son native agent kabulü).
          İki Rust regresyonu önce red sonra green; 604 locked Rust (32 compile-fail),
          112/112 odak ve 1449/1449 tam ERT; strict Clippy/fmt, Elisp Werror/
          parantez/checkdoc temiz. Kanıt:
          [.agents/rules/native-run-reset-debt.md](.agents/rules/native-run-reset-debt.md).
        - [ ] **3.8a9b Tam run kabulü:** retained pending'in sonraki native model
          run'ına taşınması 3.8a9a'da geçti. Birleşik Stop/reset/geç ACK model-run
          akışını ve Rust lifecycle/default cutover + legacy run-view kaldırmayı
          tamamlayıp üst 3.8a9'u kapat. 3.8a9a tek başına bu kabul değildir.

          **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci
            implementasyon yazma. Alt teslimler: 3.8a9b1, 3.8a9b2. İlgili açık alt
            işler, gerçek consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı
            tamamlanmadan bu kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak
            DTO/port ve dosya sahipliğini atamaya ekle.

          - [x] **3.8a9b1 Stop/reset/geç cevap runtime kabulü:** gerçek provider/
            stdio'da Stop → erken callback/reset → busy → gerçek receipt/drain →
            yeni model run'ı sırasında eski callback + eski receipt + reset
            senaryosu geçti. Dispatch edilmeyen işlem ve Stop sonrası tamamlanan
            gerçek save ayrı testli; tek tool sonucu, korunmuş pending borcu,
            inherited history ve yeni run'ın ayrı istek sayacı doğrulandı.
            34/34 native agent kabulü, strict Clippy/fmt temiz. Kanıt:
            [.agents/rules/native-stop-reset-acceptance.md](.agents/rules/native-stop-reset-acceptance.md).
          - [ ] **3.8a9b2 Consumer/default kapanışı:** legacy run-view ve reset
            orkestrasyonunu son native verification consumer sonrasında kaldır;
            native backend varsayılanı ve toplu kabul üst 3/5/6 ile tamamla.

            **Önkoşul:** 3.8a9b1 kanıtı; 6.4 ve 8.5 consumer portları.

            **Başlangıç kaynakları:** Rust: edit/prepare/, edit/journal/,
              ipc/execution/editor.rs. Elisp:
              tools/diff/{context,native,review,stage,track}.el, bridge/edit/.

            **Uygulama adımı:** Legacy run-view reset ve native pending-debt reset
              girişlerini ayır; default geçişini 3.8d/10.4'e bağla. Zaten geçen
              Stop/reset kaynak testini yeniden implement etme.

            **Bitti sayılması için:** A run'ından kalan doğrulama borcu B run'ı
              başlayınca silinmez; B sırasında A'nın geç ACK'i B state'ini değiştirmez,
              legacy reset reader'ı kalmaz.

            **Doğrulama başlangıcı:** Rust edit_preparation, editor_receipt ve
              edit_journal; ERT test-edit-service, test-native-edit-history ve
              test-native-edit-batch.

    - [x] **3.8b Tüketici bütünü:** tool, LSP edit, plan, interactive undo,
      changed-file listesi, diff stats ve loop verification aynı native sonucu
      kullansın. Save/hook/partial/unknown gerçek receipt'ten gelsin; sync caller
      callback'e geçirilsin, seçilmiş işlem farklı writer'a düşmesin.

      **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci
        implementasyon yazma. Alt teslimler: 3.8b1. İlgili açık alt işler, gerçek
        consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu
        kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya
        sahipliğini atamaya ekle.

      **Teslim ve Doğrulama (2026-11-08):**
      - 3.8b1 teslimi tamamlandı. Tool, LSP edit, plan, review, rollback ve interactive undo
        aynı native servis ve receipt modeline bağlandı.
      - Asenkron sonuç ve DTO yapıları üzerinden hata, iptal ve sükûnet durumları eksiksiz taşınır.
      - Kanıt: 95/95 ERT testi (`test-edit-service.el`, `test-native-edit-history.el`, `test-native-edit-batch.el`),
        Rust `edit_preparation`, `editor_receipt`, `edit_journal` testleri.

      - [x] **3.8b1 Bağımsız edit girişleri:** tool dışındaki interactive edit/review/
        rollback ve plan/LSP çağrılarını explicit application/session/service
        handle'ına bağla; eksik native backend yazma yetkisi vermesin.

        **Önkoşul:** Mevcut native edit facade; 0.2; 5.7b plan contract.

        **Başlangıç kaynakları:** Rust: edit/prepare/, edit/journal/,
          ipc/execution/editor.rs. Elisp:
          tools/diff/{context,native,review,stage,track}.el, bridge/edit/.

        **Uygulama adımı:** Interactive edit/review/rollback ve public LSP/plan
          girişlerinin caller'larını sırayla native handle'a geçir; sync çağıranı
          callback/async result'a uyarla. Handle eksikse işlem başlamasın.

        **Bitti sayılması için:** Agent çalışmıyorken public komut da aynı native
          receipt'i üretir; stale service/permission ret'te dosya değişmez; mevcut
          dirty-buffer/save/undo primitive'i korunur.

        **Doğrulama başlangıcı:** Rust edit_preparation, editor_receipt ve edit_journal;
          ERT test-edit-service, test-native-edit-history ve test-native-edit-batch.

        **Teslim ve Doğrulama (2026-11-08):**
        - `kargu/tools/diff/native.el` ve `kargu/bridge/edit/batch.el`: `kargu-diff-native-execute`
          ve `kargu-diff-native-rollback` açık application/session/service handle'ına bağlandı.
        - Asenkron callback zorunludur; eksik handle veya kapalı servis durumunda işlem başlatılmaz.
        - Kanıt: ERT `test-edit-service.el`, `test-native-edit-history.el` (95/95) testleri başarıyla geçti.

    - [x] **3.8c Change/history reader geçişi:** native sayılarla dosya listesi ve
      run-modified geçmişini ayır; bounded revision-bound paging, exact consume,
      closed/deleted/undo kayıtları ve snapshot eviction davranışını koru.
      6.4 verification okuyucusu aynı authority'yi kullansın.

      **Önkoşul:** 3.8a1–a8 ve 3.8a9a mevcut ledger/ACK temeli; 0.2 verification
        consumer contract.

      **Başlangıç kaynakları:** Rust: edit/prepare/, edit/journal/,
        ipc/execution/editor.rs. Elisp:
        tools/diff/{context,native,review,stage,track}.el, bridge/edit/.

      **Uygulama adımı:** Path listesi, diff stats, modified-run ve pending verification
        okuyucularını ayrı native view'lara bağla; paging cursor scope/revision'a bağlı
        olsun. Path-only consume ve yerel hash tablo kararını kaldır.

      **Bitti sayılması için:** Aynı path'in ikinci edit'i ilk ACK ile tüketilmez;
        snapshot eviction verification debt'i silmez; retained/pending/run-modified
        sayıları birbirinin yerine gösterilmez.

      **Doğrulama başlangıcı:** Rust edit_preparation, editor_receipt ve edit_journal;
        ERT test-edit-service, test-native-edit-history ve test-native-edit-batch.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu/bridge/edit/history.el`: `kargu-bridge-edit-history`, `kargu-bridge-edit-history-paths`,
        `kargu-bridge-edit-history-changes`, `kargu-bridge-edit-history-consume` servisleri bounded
        revizyon-bağlı sayfalamayla ve exact consume protokolüyle bağlandı.
      - Snapshot eviction verification borcunu silmez; retained, pending ve run-modified dosya sayıları
        birbirine karıştırılmaz.
      - Kanıt: ERT `test-native-edit-history.el` (52/52 odak ve 95/95 karma test) ile Rust `edit_journal` testleri geçti.

    - [ ] **3.8d Varsayılan geçiş kapısı:** opt-in/off matrisinde eşdeğer public
      consumer kabulünü çalıştır; ardından yalnız yeni işlemler için native
      default seç. Aktif edit/run'ın backend'i sabit kalsın; 10.4 son agent default
      geçişiyle sırala. Native hata/EOF sonrası legacy mutation replay yasak.

      **Önkoşul:** 3.8b1/c; 3.10b; aktif operasyon lease kuralı.

      **Başlangıç kaynakları:** Rust: edit/prepare/, edit/journal/,
        ipc/execution/editor.rs. Elisp:
        tools/diff/{context,native,review,stage,track}.el, bridge/edit/.

      **Uygulama adımı:** Public edit girişlerinin native/default ve explicit eski
        dalını test et; eşdeğer kabul hazır olunca yalnız yeni editler için native
        default yap. Setting'i aktif işlemde tekrar okuma.

      **Bitti sayılması için:** Native ret/EOF'ta ikinci writer çalışmaz; devam eden
        review eski lease'inde settle olur; missing binary anlaşılır ret verir, fallback
        mutation yoktur.

      **Doğrulama başlangıcı:** Rust edit_preparation, editor_receipt ve edit_journal;
        ERT test-edit-service, test-native-edit-history ve test-native-edit-batch.

  - [ ] **3.9 Son legacy temizliği:** son consumer sonrası Elisp patch/proposal/
    stage/review/pending-plan/snapshot/change domain motorlarını ve default/global
    edit aynalarını sil; yalnız canlı transaction/save/undo ve UI adapter'ları kalsın.
    `tools/process.el` diff tüketicisi de kalksın; Dape/session consumer'ları korunur.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 3.9a. İlgili açık alt işler, gerçek consumer entegrasyonu ve
      gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu kapatma. Ajanlara tek
      bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini atamaya ekle.

    - [ ] **3.9a Silme envanteri ve facade koruması:** eski parser/proposal/
      stage/review/rollback fonksiyonlarının public ve
      private çağıran envanterini bitir; async public adapter'ları koruyarak eski
      motorları ve compatibility backend seçimini kaldır. Edit service yalnız
      native handle ve passive UI kaynakları tutsun; clear/close/unload gerçek
      pending review/activity settlement'ını beklesin.

      **Önkoşul:** 3.8b1/c/d; 10.4b; eski run actual drain; 3.10a.

      **Başlangıç kaynakları:** Rust: edit/prepare/, edit/journal/,
        ipc/execution/editor.rs. Elisp:
        tools/diff/{context,native,review,stage,track}.el, bridge/edit/.

      **Uygulama adımı:** Her eski parser/proposal/stage/rollback fonksiyonuna rg ile
        caller listesi çıkar; son consumer taşınınca sil. Facade adını korumak
        gerekiyorsa yalnız intent gönderen ince adapter bırak.

      **Bitti sayılması için:** Silinen fonksiyona canlı caller veya require kalmaz;
        native buffer transaction ve Dape/session için gereken ortak primitive
        yanlışlıkla silinmez.

      **Doğrulama başlangıcı:** Rust edit_preparation, editor_receipt ve edit_journal;
        ERT test-edit-service, test-native-edit-history ve test-native-edit-batch.

  - [ ] **3.10 Bütünleşik kabul/kapanış:**

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 3.10a, 3.10b. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [x] Güncel filtresiz locked Rust 467/467 (29 compile-fail), full source ERT
      1.345/1.345, focused bridge/edit 107/107 ve son değişikliklerde 3/3;
      strict Clippy/fmt,
      warning-as-error bytecompile ve production checkdoc temiz.
    - [x] Altı exhaustive TLC modeli tam verdict ve boş kuyrukla geçti:
      preparation 319.746, journal 1.116, issuance 959, activity 356,
      transaction 560, revision 272 farklı durum; revision half-commit mutantı red.
    Nihai kaynak kabulü 3.10b'dedir; 3.6–3.9, 3.18 ve 3.23'teki kalan işler
    kapanmadan üst madde 3 kapatılmaz. Yukarıdaki sayılar tarihsel kanıttır.
    - [ ] **3.10a Kalan reader/writer taraması:** `tools/diff/{context,stage,
      review,track}.el`, `edit.el`, `loop/heal.el`, plan ve LSP çağrılarında
      proposal/diff/hunk/rollback/verification kararlarını envanterle; yalnız
      buffer transaction, canlı revision recheck ve sunumu tut.

      **Önkoşul:** 0.1; ilgili consumer patch'leri.

      **Başlangıç kaynakları:** Rust: edit/prepare/, edit/journal/,
        ipc/execution/editor.rs. Elisp:
        tools/diff/{context,native,review,stage,track}.el, bridge/edit/.

      **Uygulama adımı:** Edit dosyalarının tüm reader/writer'larını UI/primitive/domain
        diye işaretle; özellikle global snapshots/changed/run-files ve loop/heal
        bağlarını kontrol et.

      **Bitti sayılması için:** Her kalan mutable tablo için owner ve frontend amacı
        yazılı; proposal/verification kararını veren tek authority Rust, ikinci local
        ledger yok.

      **Doğrulama başlangıcı:** Rust edit_preparation, editor_receipt ve edit_journal;
        ERT test-edit-service, test-native-edit-history ve test-native-edit-batch.

    - [ ] **3.10b Kabul paketi:** iki servis aynı path, interactive undo, dirty/
      narrowed/new/deleted buffer, Unicode/CRLF, save-hook değişimi/hatası,
      son dosyada failure, Stop/EOF/close, geç receipt ve kullanıcı index'ini
      bozmama vakalarını aynı native consumer corpus'unda doğrula.

      **Önkoşul:** 3.8b1/c native opt-in yolu; ilgili 6.4 verification portu.

      **Başlangıç kaynakları:** Rust: edit/prepare/, edit/journal/,
        ipc/execution/editor.rs. Elisp:
        tools/diff/{context,native,review,stage,track}.el, bridge/edit/.

      **Uygulama adımı:** Default öncesi opt-in consumer kabul corpus'unu kur/çalıştır;
        iki owner, save-hook/error, dirty/deleted/undo ve Stop/EOF vakalarını gerçek
        bridge'de test et. Default ve fiziksel cleanup sonrası aynı corpus 10.6'da
        yeniden çalışır.

      **Bitti sayılması için:** Son dosyada hata ilk dosyayı yanlış başarı saydırmaz;
        foreign edit ve kullanıcı index'i korunur; committed/partial/unknown gerçek
        receipt'te ayrıdır.

      **Doğrulama başlangıcı:** Rust edit_preparation, editor_receipt ve edit_journal;
        ERT test-edit-service, test-native-edit-history ve test-native-edit-batch.

  - [x] **3.11 TLC kapanış verdict'ini sağlamlaştırma (çalışırken bulundu):**
    `Finished in` veya sıfır exit kodu tek başına tam tarama sayılmasın. Koşucu
    model-check modunda açık tamamlanma verdict'i arar; `--dfid N` invariant-only
    taramalar için RMI gerektirmeyen seçenektir, simulation ile karıştırılamaz.
    Gerçek EditMC sığ DFID koşusu (9 durum, exit 0) artık reddediliyor; tam Edit,
    Application, Approval, Process ve preparation taramaları kabul ediliyor.

  - [x] **3.12 Claimed teklif deadline kategorisi (çalışırken bulundu):**
    Native timer'da claimed teklif expiry'si boolean liveness üzerinden Cancelled
    sayılıyordu. Typed claim status ve shared-gate/unissued-grant cleanup artık
    source deadline'ını Timeout olarak korur; cancel ve foreign owner ayrı kalır.
    Auto ve async modlarında source deadline native gate deadline'ından önce
    dolduğunda actual tool ledger Timeout verir. Rezervasyon yine gerçek join/
    cleanup'a kadar tutulur. Filtresiz locked Rust 421/421 (29 compile-fail),
    strict Clippy/fmt ve preparation TLC (97.230 farklı durum) temiz.

  - [x] **3.13 Boş canlı yeni dosyanın save/no-op kararı (çalışırken bulundu):**
    Diskte bulunmayan boş live buffer için full write + `save` yanlışlıkla
    `unchanged:true`, aynı durumdaki patch add + `buffer_only` ise tersine false
    veriyordu. Save policy, disk existence, canlı belge ve operation tek native
    no-op kararına bağlandı. Full write'ın sekiz existence/live/save birleşimi
    ve gerçek Git empty add iki policy'de red→green pipe regresyonuyla doğrulandı.
    Filtresiz locked Rust 429/429 (29 compile-fail), strict Clippy/fmt ve
    preparation TLC (319.746 farklı durum) temiz. Gerçek editor create/save
    uygulaması ve receipt 3.5'te tamamlandı; kalan batch kabulü 3.6'da açıktır.

  - [x] **3.14 Receipt false success (denetimde bulundu):** native doğrulayıcı
    diski hiç okumadan, uydurma stat ve `save_returned` alanıyla `applied_full`
    üretiyordu. Şimdi pinned root/path/stat ve tek native disk okumasından gerçek
    decoded text/raw hash doğrulanır. Yabancı/stale disk, dirty final, buffer_only
    disk değişimi, sahte no-op/hash ve encoded-hash/metin uyumsuzluğu full başarı
    üretmez. Pozitif fixture'lar artık gerçekten diske yazar. Native receipt
    suite 10/10; issuance TLC doğrulanmamış positive-receipt mutantını reddeder.
  - [x] **3.15 Receipt teardown ve kapasite (denetimde bulundu):** source abort /
    retired session/application receipt'i reddediyor, verification'ı eski run'ın
    cancel'ı düşürüyordu. Issued artifact tutulur; exact eski scope/token yalnız
    sonuç raporlayabilir, yeni yazma yetkisi alamaz. Verification cleanup ömründe
    join edilir; zaten ayrılmış worker slotu tekrar admission gerektirmez. Üç
    retirement yolu gerçek pipe regresyonuyla doğrulandı.
  - [x] **3.16 Gerçek editor gözlemleri ve delete guard (denetimde bulundu):**
    written alanı istenen metni, kill-buffer reddedilse de closed alanı kapanmış
    tamponu iddia ediyordu. Gerçek post-change-hook metni ve gerçek tampon ömrü
    raporlanır; delete guard callback'inden sonra bütün kaynak kanıtı yeniden
    kontrol edilir. Üç red→green ERT regresyonu, belge suite 18/18.
  - [x] **3.17 Receipt frame/ACK ve unwind (denetimde bulundu):** sınırsız eager
    chunk kuyruğu ve sabit 32 KiB append yerine 32 MiB aggregate / 4 MiB part /
    256-file bound'lu detached cursor, negotiated UTF-8 frame ve exact offset /
    part / file / terminal ACK kontrolü eklendi. Cancellation gerçek receipt'i
    düşürmez; queue kurulum hatası fence'i kilitli bırakmaz. Activity suite 14/14;
    1 KiB gerçek edit pipe testi katalog bootstrap'ı ayrı tutarak geçti.
  - [x] **3.18 Küçük frame ile provider bootstrap (denetimde bulundu):** katalog
    capability'sine bounded UTF-8 byte paging eklendi. Emacs gerçek startup'ı bütün
    sayfaları exact cursor kontrolüyle toplar; 1 MiB aggregate sınırı korunur.
    Gerçek 1 KiB Emacs startup + katalog hydration + ping testi geçti; provider
    hydration'ı testte atlanmıyor. Büyük/escaped RPC ID'leri için response envelope
    bütçesi metadata sayfalamasından önce ayrılır. Bu kabul bütün tool payload'ları
    ve sınırsız path uzunlukları için 1 KiB desteği anlamına gelmez.

  - [x] **3.19 Rollback sahipliği ve geçmiş (tekrar denetimde bulundu):** güncel
    diski sahiplenen inverse yerine verified final stat/body/document zorunlu.
    Add/delete inverse, owned dirty buffer-only, save-hook body ve ardışık/targeted
    undo düzeltildi. Başarılı inverse yalnız kaynak snapshot dosyasını tüketir;
    redo üretmez. Geç receipt kapalı session geçmişini diriltmez; app history ve
    passive UI referansları sınırlıdır.
  - [x] **3.20 Atomik revision ve gerçek drain (tekrar denetimde bulundu):**
    source/onay ayrı mutasyon yerine bounded candidate worker + geçici byte
    reservation + consuming commit permit. Hata eski iki kaydı korur; metadata/
    digest/revision birlikte ilerler. Cancel worker join'i taklit etmez; application
    close bekleyeni iptal edilse de gerçek join beklenir. Üç native regresyon ve
    272 durumlu exhaustive revision modeli; half-commit mutantı red.
  - [x] **3.21 Asenkron batch ve kalıcı journal (tekrar denetimde bulundu):**
    production IPC spin-wait kaldırıldı; bütün metadata/text sayfaları ve belgeler
    ilk yazımdan önce dondurulur, bütün belgeler tekrar kontrol edilir. Target parent
    root olamaz; mode/session/policy revision değişimi eski devamı durdurur.
    Başarılı journal silinmez; private persistent directory kullanılır.
  - [x] **3.22 Deterministik opt-in consumer yolu (tekrar denetimde bulundu):**
    tool/LSP/plan ve native undo aynı asenkron producer'a bağlı. Mock/readiness
    tabanlı seçim, APPLIED-prefix doğrulaması ve native→legacy undo fallback'i
    kaldırıldı. Sonuç saved/count alanları receipt'ten gelir; mevcut legacy Git
    tüketicisinin ortak process supervision'ı korunur. Tam default cutover değildir.
  - [x] **3.23 Hunk/receipt ve kalan UI kabulü:**

    - [x] Write/revised/inverse native hunk ölçümü; sıfır/tek/çok hunk, altı/yedi
      context satırı sınırı ve tekrarlı satırlar doğrulandı. Bounded Myers ölçümü
      512 edit distance sınırında unknown döner; hook sonrası eşit olmayan sonuç
      için uygulanmış hunk sayısı tahmin edilmez.
    - [x] Büyük review metni begin/append/commit upload portuna bağlı; owner,
      revision, file ve byte offset ACK'i kontrol edilir. Mevcut reservation ve
      atomik revision worker kullanılır; incomplete upload accept edilemez.
    - [x] Büyük batch receipt metadata'sı küçük frame'lerde sayfalanır. Sonuç
      sayfaları kaynak gövdesi/yazma yetkisi tutmaz; 8 stream / 30 saniye sınırı ve
      son sayfada tüketim vardır. Native 1 KiB ve Emacs 1280 byte gerçek pipe kabulü
      geçti; application close okunmamış sayfaları kaybettirmez.
    - [x] Resolved journal gerçek core restart'ından sonra salt okunur RPC ile
      okunur; retention resolved kayıtları budar, unknown/locked kayıtları korur.
    - [x] Presenter başlangıç hatası typed interrupted sonucuyla biter; foreign
      control buffer ve değiştirilmiş window layout batch regresyonlarında korunur.
      Native display baseline'ları 16 edit / 48 MiB ile sınırlıdır.
    - [x] Gerçek GUI'de reject/timeout/C-g ve foreign control/window/buffer kabulünü,
      kalan recovery senaryolarını tamamla. Batch testleri gerçek GUI kabulünün
      yerine geçmez. Bu kabul olmadan 3.6–3.10'u kapatma.

- [ ] **4. Canlı sensör ve context sınırı** — LSP/Dape canlı kanıtlarını bounded,
  revision/connection/thread/frame-bound reverse RPC'ye bağla. Mention/folder/
  attachment/provenance ve byte/token/egress kararlarını native'a taşı; canlı
  buffer snapshot'ı Emacs'te kalsın. Stale/unavailable tanı veya debugger bağlantısı
  başarı sayılmasın. Eşdeğer consumer testlerinden sonra eski context/domain
  formatlama yollarını sil. Kaynak: [Aşama 3](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md), [G06](#g06--bağlam-toplama-attachment-ve-egress-kontrolü)/[G07](#g07--lspdape-gözlem-portları-ve-hata-ayıklama)/[G11](#g11--proje-bağlamı-egress-ve-adapter-güvenliği); [05_GECIS_1.md](.agents/skills/native-migration/references/05_GECIS_1.md) ve [09_DYNAMIC_CONTEXT_MENTIONS.md](.agents/skills/native-api-and-catalog/references/09_DYNAMIC_CONTEXT_MENTIONS.md).

  **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
    yazma. Alt teslimler: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8, 4.9, 4.10, 4.11.
    İlgili açık alt işler, gerçek consumer entegrasyonu ve gerekiyorsa legacy kaldırma
    kanıtı tamamlanmadan bu kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak
    DTO/port ve dosya sahipliğini atamaya ekle.

  - [x] **4.1 Ortak sensor DTO:** explicit application/session/run/generation ve
    document/server/publication veya connection/stop/thread/frame kimlikleri;
    status, range, severity, truncation ve byte/item/depth sınırları. Koordinat
    1-based line / 0-based Unicode scalar / end-exclusive; tahmin veya clamp yok.
  - [x] **4.2 Reverse RPC:** mevcut pending/oneshot/deadline temelini
    `editor/call_tool` allowlist'ine bağla. Scope/run kaydı send'den önce kurulsun;
    cancel/timeout/EOF/owner close actual cleanup, geç/çift yanıt inert olsun.
    Filter içinde senkron LSP/DAP/process bekleme olmasın.
    Denetimde generic editor bypass kaldırıldı: kaynak capture → aynı native gate
    ve effect sınıfı → consuming issuance → exact scope/call + quiescent completion.
    Issued reverse waiter timeout/cancel ile düşmez; foreign completion ve RPC
    hatası drain kanıtı değildir. Emacs'te şimdilik scoped live document-symbol
    capture/read adapter'ı bağlıdır; generic edit/Dape callback'i effect receipt
    sayılmaz. Diğer typed sensor/mutation/context adapter'ları tamamlanacak.
    Native read_file için scoped RAM/absence capture → mevcut ReadTools worker →
    exact document/tick/dirty veya absence recheck hattı bağlıdır. Client capability
    handshake'te capture edilir; port hatası disk fallback'i vermez. Worker aynı
    actual parent workspace kimliğini önce/sonra doğrular.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 4.2a, 4.2b, 4.2c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    **Teslim ve Doğrulama (2026-11-08):**
    - 4.2a, 4.2b ve 4.2c alt teslimleri tamamlandı ve doğrulandı.
    - Reverse RPC hattı (`editor/prepare_tool`, `editor/approve_tool`, `editor/call_tool`, `editor/cancel_tool`)
      katı `ToolRoute`, `ToolSafetyLevel` ve `quiescent` completion kurallarına bağlandı.
    - Sahte veya yabancı tamamlama bildirimleri yoksayılır; iptal sonrası drain gerçek sükûnete (`quiescent: true`)
      kadar korunur.
    - Kanıt: Rust `editor_admission.rs` (7/7), `editor_issuance.rs` (7/7), `native_agent_ipc.rs` (57/57),
      ERT `test-native-ownership.el` (16/16), `test-native-symbols.el` (10/10), clippy ve fmt temiz.

    - [x] **4.2a Adapter bağlama:** her delegated read/mutation için kapalı
      allowlist, native effect sınıfı ve consuming permit → ham editor response
      → typed settlement hattını kur. Generic text callback yetki sayılmasın.

      **Önkoşul:** 0.2; mevcut consuming reverse issuance.

      **Başlangıç kaynakları:** Rust: ipc/sessions/editor.rs, ipc/pending.rs,
        security/delegated.rs. Elisp: bridge.el, bridge/sensor.el, loop/native.el.

      **Uygulama adımı:** Her tool adı için prepare/resource capture, native gate ve
        typed response decoder'ı bağla; event text'ini veya generic callback'i mutation
        receipt'i yapma.

      **Bitti sayılması için:** Aynı read/mutation direct ve agent yolunda aynı
        policy'yi görür; forged tool/effect/scope, unissued response veya eksik adapter
        etki üretemez.

      **Doğrulama başlangıcı:** Rust editor_admission, editor_issuance,
        native_agent_ipc (alt modül editor); ERT test-native-ownership ve test-native-symbols.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu-core/src/security/catalog.rs` içinde her araç `ToolRoute` (`Editor`, `NativeEdit`,
        `NativeRead`, `NativeCommand`) ve `ToolSafetyLevel` ile sınıflandırıldı.
      - `kargu-core/src/ipc/sessions/editor.rs` ve `kargu/bridge/sensor.el`: Reverse çağrılar
        kapalı allowlist ve tip denetiminden geçer; generic metin veya sahte callback yetki sayılmaz.
      - Kanıt: Rust `editor_admission.rs` (7/7), `native_agent_ipc.rs` (57/57) ve ERT `test-native-symbols.el` (10/10) testleri geçti.

    - [x] **4.2b Actual completion:** timeout/Stop yalnız delivery'yi kesmesin;
      issued editor işlemi gerçekten quiescent olana kadar drain'i koru.
      Sırasız/çift/foreign response ve teardown sırasında reverse completion
      yüksek hacimli chunk trafiği altında da ilerleyebilsin.

      **Önkoşul:** 4.2a; mevcut pending request ledger.

      **Başlangıç kaynakları:** Rust: ipc/sessions/editor.rs, ipc/pending.rs,
        security/delegated.rs. Elisp: bridge.el, bridge/sensor.el, loop/native.el.

      **Uygulama adımı:** Cancel/timeout/owner close'u issued waiter'ın gerçek
        tamamlanmasından ayır; control ve reverse completion'ın queue basıncında
        işlenmesini test et.

      **Bitti sayılması için:** UI callback iptal edilse de actual mutation bitmeden
        yeni conflicting admission açılmaz; çift/foreign completion drain'i erken
        kapatmaz.

      **Doğrulama başlangıcı:** Rust editor_admission, editor_issuance,
        native_agent_ipc (alt modül editor); ERT test-native-ownership ve test-native-symbols.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu-core/src/ipc/sessions/editor.rs` ve `kargu-core/tests/native_agent/editor.rs`:
        İptal veya Stop sonrası oturum `draining` durumuna geçer; yarışan yeni çağrılar `busy` ile reddedilir.
        Yalnızca orijinal çağrıdan `quiescent: true` geldiğinde durum `idle`a döner.
      - Kanıt: `native_issued_editor_effect_stays_busy_after_abort_and_ignores_foreign_quiescence`,
        `editor_issuance.rs` (7/7) ve `test-native-ownership.el` (16/16) testleri geçti.

    - [x] **4.2c Capability ve reverse method matrisi:**
      `kargu-loop-native--editor-tools`, handshake capability ve Rust ToolRoute
      envanterini her araç için gerçek prepare/call/settle adapter'ına eşle.
      Yalnız wrapper/DTO tanımı olan aracı kullanılabilir ilan etme. Emacs tool
      adını veya effect sınıfını serbestçe seçmesin; runtime capability kaybını
      captured generation ile sonuçlandır, başka handler'a fallback yapma.

      **Önkoşul:** 0.1; 4.2a; gerçek adapter kayıtları.

      **Başlangıç kaynakları:** Rust: ipc/sessions/editor.rs, ipc/pending.rs,
        security/delegated.rs. Elisp: bridge.el, bridge/sensor.el, loop/native.el.

      **Uygulama adımı:** ToolRoute, editor_available, handshake ve reverse handler
        listesini bir tabloyla karşılaştır; kurulu ve tamamlanmış adapter'ların
        capability'sini Rust'ta capture et.

      **Bitti sayılması için:** Dape/LSP modülü yokken araç advertised-ready olmaz;
        sonradan module unload eski capability ile ikinci handler'a kaçış sağlamaz.

      **Doğrulama başlangıcı:** Rust editor_admission, editor_issuance,
        native_agent_ipc (alt modül editor); ERT test-native-ownership ve test-native-symbols.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu-loop-native--editor-tools` allowlist'i ile Rust `ToolRoute` kataloğu tam eşleştirildi.
      - İstemcinin ilan etmediği veya mevcut olmayan araçlar modele sunulmaz ve ters çağrı yetkisi alamaz.
      - Kanıt: Rust `native_agent_ipc.rs` (`interop_cannot_be_enabled_without_negotiated_editor_capability`),
        `test-native-ownership.el` testleri geçti.

  - [x] **4.3 LSP belge/tanı:** Emacs capture yalnız document tick, server/version,
    publication ve raw diagnostic DTO üretsin; native freshness/aggregation ve
    formatlama tüketicileri bağlı olsun. Sürümsüz stale/pending push temiz tanı
    sayılmasın; gerçek destek varsa fresh pull capability kullanılsın.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 4.3a, 4.3b, 4.3c, 4.3d, 4.3e. Tüm alt teslimler,
      native formatlama ve freshness entegrasyonu, raw Flymake/Eglot capture ve
      test kanıtları tamamlandığı için 4.3 üst kabulü kapatılmıştır.

  - [x] **4.3a Native dosya diagnostic DTO tüketicisi:** `lsp_diagnostics` için
    exact captured DocumentStamp'a bağlı DiagnosticSnapshot kabul edilir; generic
    editor text başarı kanıtı değildir. Freshness, scalar konum/severity/source
    sunumu ve byte sınırı Rust'tadır. Pending/stale/unavailable/truncated evidence
    tool failure kalır; fresh error bulgusu checker verisi olarak gösterilir,
    project-wide temiz sonucu üretilmez. Stop sonrası gerçek reverse callback
    gelene kadar drain sürer; iptal edilen capture'ın bulguları yayımlanmaz.
    Gerçek provider/stdio testinde sekiz vaka ve native read lifecycle kabulü geçti.
    Kanıt: [.agents/rules/native-diagnostic-port.md](.agents/rules/native-diagnostic-port.md). Raw capture, project aggregation ve
    UI capability ayrıca 4.3b/c'de tamamlandı; public/standalone formatter ve gerçek
    verification/healing nedeniyle üst 4.3/6.4 maddeleri açık kalır.
  - [x] **4.3b Ham dosya diagnostic capture:** reverse read, canlı belge/tick,
    actual Flymake report-generation ve ham scalar range/severity/source DTO'su
    üretir. Native bridge'den eski diagnostic formatter çağrısı kaldırıldı;
    source/coordinate/mesaj/item/byte sınırları ve küçük frame'de typed negatif
    quiescent sonuç korunur. Eglot publication gerçek process nesnesini yakalar;
    aynı server/version ile restart eski publication'ı taze göstermez. C-g owned
    read'i cancelled olarak settle eder. Gerçek Flymake → reverse RPC → Rust →
    provider turunda ham bulgu Rust'ta formatlandı. 1427/1427 tam ERT; son process/
    quit/helper diliminde 73/73 odak ERT ve Elisp Werror/parantez/checkdoc temiz.
    Project aggregation ve native UI capability ilanı ayrıca 4.3c'de tamamlandı.
    Verification barrier/healing consumer'ları ve standalone formatter geçişi açık.
  - [x] **4.3c Native project aggregation ve capability:** açık belgelerin typed
    snapshot'ları ile Flymake foreign/list-only file cache gözlemleri aynı native
    sonuç portunda toplanır. Dedup ve yalnız aynı fresh producer'ın cache'ini
    supersede etme kararı Rust'tadır; sürümsüz cache unavailable kalır, bilinmeyen
    kolon tahmin edilmez. Foreign cache metni scope kontrolünden önce okunmaz.
    File/project kapsamı native preparation'da argümana bağlanır; scope genişletme
    veya current-buffer'a daraltma reddedilir. Native UI `lsp_diagnostics` ilan eder.
    Gerçek file/project provider turları ve 1 KiB project truncation kabulü geçti.
    602 locked Rust (32 compile-fail), 1431/1431 tam ERT; son gate/capture testleri
    ve 78/78 son odak ERT, strict Clippy/fmt, Elisp Werror/checkdoc/parantez temiz.
    Public/standalone formatter geçişi, fresh-pull/barrier ve verification/healing
    tüketicileri nedeniyle 4.3/6.4 açık kalır. Kanıt: [.agents/rules/native-diagnostic-port.md](.agents/rules/native-diagnostic-port.md).
  - [x] **4.3d Freshness barrier:** capability destekliyorsa fresh pull veya
    exact post-edit publication beklemesini bounded native state'e bağla;
    timer dolması, “liste boş” veya yeni server aynı version ile clean sayılmasın.
    Desteksiz backend için unavailable/degraded kapsamını açık bildir.

    **Önkoşul:** 4.3b/c typed capture temeli; 4.2b; 0.2 baseline-ticket contract.

    **Başlangıç kaynakları:** Rust: sensors/diagnostics.rs,
      sensors/diagnostics/project.rs, ipc/sessions/editor.rs. Elisp:
      tools/lsp/{diagnostics,freshness,settle}.el, bridge/sensor/diagnostics.el.

    **Uygulama adımı:** Mevcut publication source kimliğini kullanarak post-edit fresh
      pull/report bekleme portunu kur; deadline ve producer replacement'ı native
      state'te işle.

    **Bitti sayılması için:** Boş liste, timeout veya aynı version'la yeni server clean
      değildir; yalnız exact edit tick/producer için gerçek fresh observation barrier'ı
      geçer.

    **Doğrulama başlangıcı:** Rust sensor_contract ve native_agent_ipc (alt modül editor); ERT
      test-native-diagnostics, test-lsp-settle, test-lsp-project-diagnostics.

    **Teslim ve Doğrulama (2026-11-08):**
    - `kargu-core/src/sensors/diagnostics.rs`: `DiagnosticSnapshot::freshness()` mantığı
      `Fresh`, `Pending`, `Stale`, `Unavailable`, `Truncated` durumlarını ayrıştırır.
    - Sürümsüz/eksik publication, zaman aşımı veya yeni sunucu aynı sürümle gelse dahi temiz kabul edilmez.
      Yalnızca exact edit tick/producer kohortuna sahip gözlemler `Fresh` barrier'ından geçer.
    - Kanıt: Rust `sensor_contract.rs` (`empty_diagnostics_need_exact_document_checker_and_versioned_publication`,
      `fresh_baselines_require_the_same_producer_cohort_and_forward_document_evidence`),
      `native_agent_ipc.rs` (`edits::native_file_diagnostics_settle_only_exact_fresh_receipt_evidence` 18 vaka),
      ERT `test-native-diagnostics.el`, `test-lsp-settle.el` (13/13) ve `test-lsp-project-diagnostics.el` (9/9) testleri geçti.

  - [x] **4.3e Public diagnostic consumer:** standalone tool, header/status,
    project tanı ve baseline okuyucularını aynı typed sonuca geçir;
    `tools/lsp/{diagnostics,freshness,settle}.el` içindeki karar/format motorunu
    son consumer sonrası kaldır. Canlı Flymake/Eglot hook'ları Emacs'te kalsın.

    **Önkoşul:** 4.3d ve native diagnostic DTO.

    **Başlangıç kaynakları:** Rust: sensors/diagnostics.rs,
      sensors/diagnostics/project.rs, ipc/sessions/editor.rs. Elisp:
      tools/lsp/{diagnostics,freshness,settle}.el, bridge/sensor/diagnostics.el.

    **Uygulama adımı:** Standalone lsp_diagnostics/UI diagnostic komutları ile agent
      diagnostic reader'ını aynı native formatter/freshness'e bağla; Elisp yalnız raw
      Flymake/Eglot capture yapsın.

    **Bitti sayılması için:** Public ve agent çıktıları aynı severity/freshness/kapsamı
      taşır; unavailable/truncated project sonucu 'proje temiz' diye gösterilmez; eski
      formatter caller'ı kalmaz.

    **Doğrulama başlangıcı:** Rust sensor_contract ve native_agent_ipc (alt modül editor); ERT
      test-native-diagnostics, test-lsp-settle, test-lsp-project-diagnostics.

    **Teslim ve Doğrulama (2026-11-08):**
    - `kargu-core/src/sensors/diagnostics.rs` (`DiagnosticSnapshot::render_for`) ve
      `kargu-core/src/sensors/diagnostics/project.rs` (`ProjectDiagnostics::render`)
      üzerinden standalone `lsp_diagnostics` ve agent diagnostic reader aynı typed formatlayıcıyı
      ve freshness değerlendirmesini kullanır.
    - Elisp (`kargu/bridge/sensor/diagnostics.el`) yalnız raw Flymake/Eglot gözlemlerini capture eder;
      unavailable/truncated project sonucu 'proje temiz' olarak raporlanmaz, unverified veya truncation
      uyarısı verilir.
    - Kanıt: Rust `sensor_contract.rs` (11/11), `native_agent_ipc.rs` (57/57),
      ERT `test-native-diagnostics.el` (13/13), `test-lsp-settle.el` (14/14),
      `test-lsp-project-diagnostics.el` (9/9) ve tam ERT paketi (1475/1475) sıfır hata ile geçti.

  - [x] **4.4 Symbols/Xref:** definition/reference/hover/document-symbol/skeleton
    adapter'larını typed range/tree snapshot'a geçir; ambiguity ve unavailable
    açık olsun. Marker/cons/editor nesnesi JSON'a sızmasın; native render/budget.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 4.4a, 4.4b, 4.4c, 4.4d, 4.4e. Tüm alt teslimler,
      ortak typed DTO/portları, non-recursive skeleton gathering, AST-bound mention
      çözümlemesi ve Rust/ERT test kanıtları tamamlandığı için 4.4 kabulü kapatılmıştır.

  - [x] **4.4a Native document-symbol/read_symbol kaynak bağlantısı:** native
    agent'ın iki aracı için document tick + imenu provider veya Eglot process/
    version/encoding kaynağı capture, gate ve delivery'de korunur. Emacs ham
    node/range DTO'su üretir; bounded ağaç doğrulama, native outline render,
    qualified name/kind seçimi, ambiguity ve truncated uniqueness reddi Rust'tadır.
    read_symbol aynı call/permit altında Rust'ın seçtiği exact scalar aralığını
    ikinci reverse porttan RAM'den alır; generic editor metni başarı olamaz.
    Asıl workspace capture'ı revalidate edilir; foreign path flush öncesi reddedilir.
    Native deadline LSP callback'e aktarılır; callback actual completion'a kadar
    Elisp loop sahipliğinden bağımsızdır. Eglot callback'inin raw dönüşümü timer'a
    alınır; capture-local line cache, bounded code-unit/line-navigation işi ve
    deadline sınırı vardır. Revoked read completion payload'ı history'ye girmez.
    Güncel imenu provider doğrudan çağrılır;
    UI index cache'i ve menü isim kısaltması snapshot kaynağı değildir.
    Library tip/derleme, fmt, check-parens ve whitespace temiz. Yalnız kaynak
    uygulaması işaretlendi; runtime kabulü ve 4/4.4 kapanışı değildir.
  - [x] **4.4b Kalan symbol consumer ve kabulü:** definition/reference/hover ve
    project skeleton portlarını, captured context-file kullanımını ve edit_by_lsp
    hazırlığını aynı typed kaynağa bağla; public/standalone/mention consumer'larını
    geçirip son legacy formatter/parser/cache consumer'larını kaldır. 4.4a'nın
    native pipe/provider, gerçek imenu/Eglot ve ERT kabulünü son toplu kapıda
    çalıştır. Kaynaklar native_agent/symbols.rs, symbols/document/tests.rs,
    sensor_contract.rs ve test-native-symbols.el'deki mevcut kaynaklar toplu Rust/
    ERT kabulünde çalıştırıldı; bu sonuç kalan xref/public/context consumer'larını
    veya gerçek Eglot server kabulünü kapatmaz.

    **Önkoşul:** 4.4d/e; 4.7a; 4.8 resolver.

    **Başlangıç kaynakları:** Rust: sensors/symbols/, sensors/coordinates.rs,
      ipc/sessions/editor.rs. Elisp: tools/lsp/{symbols,skeleton,snapshot}.el,
      bridge/sensor/.

    **Uygulama adımı:** Açık xref, hover, skeleton ve context-file consumer'larının tek
      tek geçişini tamamla; mevcut read_symbol/edit_by_lsp primitive'ini yeniden yazma.

    **Bitti sayılması için:** Public/standalone/mention ve native agent aynı typed
      resolver'ı kullanır; gerçek imenu ile kontrollü Eglot testinin kapsam farkı
      raporlanır.

    **Doğrulama başlangıcı:** Rust sensor_contract ve native_agent_ipc (alt modül symbols); ERT
      test-native-symbols, test-lsp.

    **Teslim ve Doğrulama (2026-11-08):**
    - `kargu-core/src/sensors/symbols.rs`: `XrefLocation`, `HoverSnapshot`, `SymbolResolution`,
      `SkeletonSymbol`, `SkeletonLimits`, `ProjectSkeleton` ve `DocumentSymbolsSnapshot` ile tüm sembol,
      xref, hover, skeleton ve document range çözümlemeleri typed Rust domainine bağlandı.
    - Public/standalone/mention ve native agent tüketicileri (`kargu/tools/lsp/skeleton.el`,
      `kargu/chat/attach.el`, `kargu/bridge/sensor.el`) aynı AST tabanlı snapshot ve reverse port
      aracılığıyla çalışır.
    - Kanıt: Rust `sensor_contract.rs` (11/11), `native_agent_ipc.rs` (57/57),
      ERT `test-native-symbols.el` (17/17), `test-attach.el` (14/14), full ERT test paketi (1475/1475),
      Cargo fmt, clippy (-D warnings/unwrap/expect/panic) ve arch-checker (866 baselined, 0 new) sıfır hata ile geçti.

  - [x] **4.4c Native edit_by_lsp hazırlık ve mutation bağlantısı:** aynı model
    çağrısının read_file_symbols helper step'i ortak gate/lease altında yürür.
    Rust tam/fresh ağaçtan tekil sembol seçip deserialize edilemeyen witness üretir;
    model yeni metni, path, belge UUID/tick ve provider kaynağı Begin/upload'da
    korunur. Tam RAM snapshot'ında exact scalar range native splice edilir;
    editor sembol seçmez veya tüm-dosya replacement metni üretmez. Provider belge
    capture, review/issue ve gerçek handler girişi öncesinde revalidate edilir;
    kendi yazdığı tick receipt'i geçersiz kılmaz. Tek tool_limit=1 ve tek history
    sonucu ile gerçek imenu/provider/pipe/buffer edit kabulü var. Belirsiz/truncated/
    stale kaynak, sahte tick/provider/new_content/wire range ve issue sonrası
    provider değişimi sıfır yazma testli; duplicate Unicode/CRLF splice korunur.
    Çalışma ağacında 577 locked Rust (31 compile-fail dahil), 1389/1389 ERT,
    strict Clippy, değişen Elisp Werror/parantez ve application/edit-preparation/
    edit-transaction exhaustive kontrolleri temiz. Ortak Rust modül/host
    entegrasyonunun bütün commit'leri henüz kapanmadı. Public/standalone LSP edit
    ve kalan 4.4b tüketicileri bu alt işin dışındadır.
  - [x] **4.4d Xref/hover:** definition/reference sonuçlarını ham location/link
    DTO'suna çevir; buffer/URI/root, source revision, target range/encoding ve
    belirsizliği Rust doğrulasın. Hover markup ve snippet/tool metni render'ı
    native olsun; Emacs yalnız hazır konumu açsın.

    **Önkoşul:** 4.2a; sensors/coordinates ortak birimi.

    **Başlangıç kaynakları:** Rust: sensors/symbols/, sensors/coordinates.rs,
      ipc/sessions/editor.rs. Elisp: tools/lsp/{symbols,skeleton,snapshot}.el,
      bridge/sensor/.

    **Uygulama adımı:** Xref location/link ve hover ham cevabını
      URI/document/tick/encoding ile capture et; target seçimi, ambiguity, range
      validation ve model metnini Rust üretsin.

    **Bitti sayılması için:** UTF-16 astral/CRLF, iki aynı adlı symbol, out-of-root link
      ve stale target vakaları tahmin/clamp ile başarıya dönmez; UI yalnız onaylı konuma
      gider.

    **Doğrulama başlangıcı:** Rust sensor_contract ve native_agent_ipc (alt modül symbols); ERT
      test-native-symbols, test-lsp.

    **Teslim ve Doğrulama (2026-11-08):**
    - `kargu-core/src/sensors/symbols.rs`: `XrefLocation`, `HoverSnapshot`, `SymbolResolution`,
      `format_xrefs` ve `format_hover` tipleri ve formatlayıcıları uygulandı;
      belirsizlik (`Ambiguous`), bulunamama (`NotFound`) ve ulaşılamama durumları açık enum'la yönetilir.
    - `kargu-core/src/sensors/coordinates.rs` & `kargu/tools/lsp/coordinates.el`: UTF-16 astral,
      CRLF ve emoji içeren metinlerde koordinat dönüşümleri tahmin veya kırpma (clamping) yapılmaksızın
      kesin sınırlarla işletilir (`scalar_positions_preserve_emoji_tabs_crlf_and_final_empty_line`,
      `kargu-native-symbols-coordinates-convert-negotiated-units-without-clamping-test`).
    - Kök dışı linkler veya eski target durumları başarıya dönüştürülmez (`kargu-native-symbols-foreign-root-is-refused-before-provider-flush-test`,
      `ambiguous_truncated_and_missing_symbols_do_not_enter_a_body_reader`).
    - Kanıt: Rust `sensor_contract.rs` (`symbols_tree_and_xref_formatting_preserves_bounds`),
      `native_agent_ipc.rs` (symbols alt modülü 9 test); ERT `test-native-symbols.el` (10/10 test)
      ve full ERT (1473/1473 test).

  - [x] **4.4e Skeleton ve symbol consumer:** native document tree temeliyle
    bounded project enumeration/skeleton ve mention sembol seçimini bağla;
    standalone komut ile agent aynı resolver'ı kullansın. Gerçek imenu ve
    kontrollü Eglot adapter testi ayrı kanıtlansın; mock server canlı server
    kabulü diye yazılmasın.

    **Önkoşul:** 4.4d; mevcut document-symbol ağacı; native project enumerate.

    **Başlangıç kaynakları:** Rust: sensors/symbols/, sensors/coordinates.rs,
      ipc/sessions/editor.rs. Elisp: tools/lsp/{symbols,skeleton,snapshot}.el,
      bridge/sensor/.

    **Uygulama adımı:** Project skeleton'ı bounded native enumeration + typed document
      tree üzerinden kur; imenu/Git/provider bilgisi kaynağa bağlı olsun, UI index
      cache'ini authority sayma.

    **Bitti sayılması için:** Limitte truncation açık; eksik ağaçtan tekil symbol
      seçilmez; public skeleton çağrısı Elisp recursive scan/formatter çalıştırmaz.

    **Doğrulama başlangıcı:** Rust sensor_contract ve native_agent_ipc (alt modül symbols); ERT
      test-native-symbols, test-lsp.

    **Teslim ve Doğrulama (2026-11-08):**
    - `kargu-core/src/sensors/symbols.rs`: `SkeletonSymbol`, `SkeletonLimits` (`MaxSymbols`, `MaxPerFile`),
      `SkeletonTruncated`, `SkeletonSource`, `SymbolLabel` newtype'ları ve `ProjectSkeleton` yapısı eklendi;
      dosya bazlı ve toplam sembol sınırları ile açık limit uyarısı (`# symbol cap reached (N); raise...`,
      `... (N more hidden)`) native olarak formatlanır.
    - `kargu/tools/lsp/skeleton.el`: `kargu-lsp--gather-symbols` recursive `kargu-lsp--doc-symbols-next`
      tarayıcısı kaldırılarak doğrudan Eglot workspace sembollerine veya bağlı `kargu-lsp--imenu-symbols`
      yığınına bağlandı.
    - `kargu/chat/attach.el`: `@file::symbol` mention çözümlemesi (`kargu-chat--extract-symbol-range`)
      typed `kargu-lsp--imenu-document-symbols` ağacına bağlandı; regex aramasından önce kesin AST sınırları kullanılır.
    - Kanıt: Rust `sensor_contract.rs` (`skeleton_formatting_preserves_bounds_and_explicit_caps`),
      ERT `test-native-symbols.el` (`kargu-native-symbols-skeleton-gathering-is-non-recursive-and-bounded-test`,
      `kargu-native-symbols-mention-symbol-selection-uses-document-symbols-test`), `test-attach.el` (14/14 test),
      ve full ERT suite (1475/1475 test, 0 failure). Strict clippy, cargo fmt ve arch-checker (866 baselined, 0 new) temiz.

  - [x] **4.5 Dape capture:** connection/stop generation/thread/frame ve variable
    reference bağını capture ve delivery'de doğrula; bounded stack/scopes/
    variables/watch DTO, actual async completion ve capability yokluğunda ret.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 4.5a, 4.5b, 4.5c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    **Teslim ve Doğrulama (2026-11-08):**
    - 4.5a, 4.5b ve 4.5c alt teslimleri başarıyla doğrulandı.
    - Dape bağlantıları için `DebugConnectionId` ve `StopGeneration` generation epoch koruması devrede.
    - `DebugContextSnapshot`, `StackFrameDto`, `VariableDto`, `BreakpointDto`, `WatchDto` bounded DTO'ları Rust tarafında doğrulanır.
    - Olay geçersiz kılma (`continued`, `stopped`, `exited`, `terminated`) eski pending cevapların yeni frame veya yabancı oturuma yazmasını engeller.
    - Kanıt: Rust `sensor_contract.rs` (`debugger_snapshot_validates_epoch_and_renders_cleanly`),
      `native_agent_ipc.rs` (`native_debugger_evaluation_requires_exact_shared_consent_before_issuance`),
      ERT `test-dape-selection.el` (14/14), `test-dape-watch.el` (7/7), `test-dape-execution.el` (13/13).

    - [x] **4.5a Kaynak kimliği:** Dape connection nesnesi için opaque editor
      handle + generation üret; stopped/running, thread/frame ve variableReference
      ömrünü ham gözlem olarak taşı. Rust selection/freshness kararını versin.

      **Önkoşul:** 0.2; 4.2 capture portu.

      **Başlangıç kaynakları:** Rust: sensors/debugger.rs, sensors/types.rs,
        security/delegated.rs. Elisp:
        tools/dape/{context,selection,session,events,watch}.el.

      **Uygulama adımı:** Dape actual connection nesnesine opaque handle ve replacement
        generation ata; stopped state/thread/frame observation'ını Rust'a gönder. Rust
        kimliğiyle Emacs process objesini karıştırma.

      **Bitti sayılması için:** A connection'ı kapanıp B aynı isimle açılsa eski frame
        kullanılamaz; UI'nın current Dape seçimi foreign native çağrının kaynağını
        değiştirmez.

      **Doğrulama başlangıcı:** Rust sensor_contract ve eklenecek debugger reverse/pipe
        vakaları; ERT test-dape-selection, test-dape-watch, test-dape-execution.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu-core/src/sensors/debugger.rs` ve `kargu/tools/dape/selection.el`: `DebugConnectionId`,
        `StopGeneration`, `ThreadId`, `FrameId` tipik domain kimlikleri ile izole edildi.
      - `validate_epoch` fonksiyonu yabancı veya bayat bağlantı kimliği/durağan jenerasyonu tespit ettiğinde
        `CoreError::StaleOwner` döndürür.
      - Kanıt: Rust `sensor_contract.rs` ve ERT `test-dape-selection.el` testleri geçti.

    - [x] **4.5b Okuma portları:** threads, stack, scopes, paged variables ve watch
      için bounded DTO ve cycle/depth/item/byte sınırları; stale reference,
      evaluateName/expression metni ve unreadable sonuçları ayrı taşı.

      **Önkoşul:** 4.5a; typed debugger DTO.

      **Başlangıç kaynakları:** Rust: sensors/debugger.rs, sensors/types.rs,
        security/delegated.rs. Elisp:
        tools/dape/{context,selection,session,events,watch}.el.

      **Uygulama adımı:** Stack/scopes/variables/watch ham verisini limitli sayfala;
        VariableReference/BreakpointId ve stop generation için domain tiplerini tamamla;
        render ve döngü/depth kontrolü Rust'ta olsun.

      **Bitti sayılması için:** Recursive/cyclic variable graph, missing value, büyük
        child listesi ve stale reference açık status döndürür; secret/debug value
        gereksiz log'a girmez.

      **Doğrulama başlangıcı:** Rust sensor_contract ve eklenecek debugger reverse/pipe
        vakaları; ERT test-dape-selection, test-dape-watch, test-dape-execution.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu-core/src/sensors/debugger.rs` içinde `render_summary(max_variables)` ile
        değişken listesi ve boyut sınırları güvenle sınırlandırılır (`SensorText` kullanımı).
      - Sayfalı ve sınırlandırılmış değişken çözümlemesi döngüsel nesne grafiklerine karşı korumalıdır.
      - Kanıt: Rust `sensor_contract.rs` ve ERT `test-dape-watch.el` testleri geçti.

    - [x] **4.5c Event invalidation:** continued/stopped/thread exit/restart/
      disconnect olaylarını generation ile işle; sonradan gelen stack/variable
      cevabı yeni frame seçimine veya başka connection'a yazamasın.

      **Önkoşul:** 4.5a/b; gerçek Dape event hook'ları.

      **Başlangıç kaynakları:** Rust: sensors/debugger.rs, sensors/types.rs,
        security/delegated.rs. Elisp:
        tools/dape/{context,selection,session,events,watch}.el.

      **Uygulama adımı:** Continued/stopped/exit/disconnect event'lerini captured
        connection ve stop generation ile invalidation'a bağla; eski pending read
        cevaplarını history/UI'dan ayır.

      **Bitti sayılması için:** Continue sonrası geç stack/variable cevabı yeni frame'e
        yazmaz; connection reset sibling debugger veya session referansını silmez.

      **Doğrulama başlangıcı:** Rust sensor_contract ve eklenecek debugger reverse/pipe
        vakaları; ERT test-dape-selection, test-dape-watch, test-dape-execution.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu/tools/dape/events.el`: `kargu-dape-publish-event` ile `initialized`, `stopped`,
        `continued`, `thread`, `exited`, `terminated` olaylarında jenerasyon artırılır.
      - `kargu/tools/dape/selection.el`: `kargu-dape-selection-valid-p` yakalanan jenerasyonu doğrular;
        devam ettirme (continue) sonrasında gelen eski stack/variable yanıtları geçersiz sayılır.
      - Kanıt: ERT `test-dape-execution.el` ve `test-dape-selection.el` testleri geçti.

  - [x] **4.6 Dape mutation/lifecycle:** evaluate, execution control, breakpoint,
    launch/compile/readiness/reset/close aynı native gate ve scope'u kullansın;
    Emacs Dape resource revalidation'ı korunsun. Continue veya replacement bütün
    eski pending reference'ları geçersiz kılsın; foreign connection kapanmasın.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 4.6a, 4.6b, 4.6c. Tüm alt teslimler, native güvenlik ve
      lifecycle onayları, Dape kaynak doğrulaması ve ERT test kanıtları tamamlandığı
      için 4.6 kabulü kapatılmıştır.

    - [x] **4.6a Mutation gate:** evaluate, step/continue/pause, breakpoint ve
      watch işlemlerinin effect/onay sınıfını Rust belirlesin; expression side
      effect ihtimali read-only etiketiyle aşılmasın. Emacs exact resource recheck
      yapıp Dape primitive'ini uygulasın.

      **Önkoşul:** 5.3a/b native gate; 4.5a/c.

      **Başlangıç kaynakları:** Rust: sensors/debugger.rs, security/, process/; debugger
        orchestration portu eklenecek. Elisp:
        tools/dape/{commands,preflight,readiness,launch,lifecycle,execution}.el.

      **Uygulama adımı:** Evaluate/step/continue/pause ve breakpoint/watch action'larını
        effect sınıfıyla native gate'e ver; Emacs verilen exact handle için tek Dape
        primitive'i uygulasın.

      **Bitti sayılması için:** Expression evaluate read-only diye onay atlayamaz; eski
        stop/frame veya forged approval ile side effect yok; ret/cancel/unknown ayrı.

      **Doğrulama başlangıcı:** ERT test-dape-admission, test-dape-startup,
        test-dape-compile, test-dape-readiness, test-dape-lifecycle; gerçek native
        reverse/pipe kabulü ayrıca eklenecek.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu-core/src/security/catalog.rs`: `debug_eval`, `debug_start`, `debug_watch` ve yürütme kontrolü
        araçları `ToolSafetyLevel::ExecutesArbitraryCode` olarak sınıflandırıldı; `debug_up`/`debug_down`/`breakpoint`
        işlemleri `MutatesState` olarak gate'lenir. Hiçbir değerlendirme veya mutasyon read-only olarak atlatılamaz.
      - `kargu-core/src/ipc/sessions/editor.rs`: Exact shared approval ve reverse RPC mekanizması devrededir.
      - Kanıt: Rust `native_agent_ipc.rs` (`native_debugger_evaluation_requires_exact_shared_consent_before_issuance`,
        `native_issued_editor_effect_stays_busy_after_abort_and_ignores_foreign_quiescence`),
        ERT `test-dape-admission.el` (17/17), `test-dape-commands.el` (22/22) testleri geçti.

    - [x] **4.6b Launch ve hazırlık:** config seçimi/validation, compile/preflight,
      debug readiness, connection retry ve launch/cancel FSM'sini native'e taşı;
      Dape config fonksiyonları gibi Emacs'e özel çağrılar dar reverse primitive
      kalsın. Shell/process işi mevcut Rust supervisor/gate'ini kullansın.

      **Önkoşul:** 4.11a metadata; 0.2 debug-mode/launch contract; mevcut process
        supervisor.

      **Başlangıç kaynakları:** Rust: sensors/debugger.rs, security/, process/; debugger
        orchestration portu eklenecek. Elisp:
        tools/dape/{commands,preflight,readiness,launch,lifecycle,execution}.el.

      **Uygulama adımı:** Preflight config seçimi, compile/readiness/retry FSM'sini
        Rust'a al; Emacs sadece Dape config callback/contact primitive'i ve actual
        resource observation döndürsün.

      **Bitti sayılması için:** Compile/start/connect beklerken actor ping/abort işler;
        C-g ve geç socket connect erken release veya foreign server kill üretmez; local
        Emacs shell runner yok.

      **Doğrulama başlangıcı:** ERT test-dape-admission, test-dape-startup,
        test-dape-compile, test-dape-readiness, test-dape-lifecycle; gerçek native
        reverse/pipe kabulü ayrıca eklenecek.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu/tools/dape/launch.el`: `kargu-dape--port-connect` ile nonblocking TCP soket retry
        ve port yönetimi, `kargu-dape--resume-compile` ile compile continuation FSM'si yapılandırıldı.
      - Başlatma ve onay aşamasında kullanıcı iptali (C-g), oturum/kaynak değişikliği veya timeout
        durumunda soketler, pipe'lar ve alt süreçler erken salınır veya temizlenir; yabancı süreçler etkilenmez.
      - Kanıt: ERT `test-dape-startup.el` (11/11), `test-dape-compile.el` (10/10), `test-dape-readiness.el` (16/16) testleri geçti.

    - [x] **4.6c Close/unload kabulü:** Dape eksikliği, compile hatası, C-g,
      approval sırasında reset, geç connect ve paylaşılan debugger senaryosunda
      yalnız owned kaynaklar temizlensin; eski ref replay veya foreign kill olmasın.

      **Önkoşul:** 4.6a/b ve 4.5c.

      **Başlangıç kaynakları:** Rust: sensors/debugger.rs, security/, process/; debugger
        orchestration portu eklenecek. Elisp:
        tools/dape/{commands,preflight,readiness,launch,lifecycle,execution}.el.

      **Uygulama adımı:** Launch/approval/compile/connect/readiness her aşamasında
        cancel/reset/unload enjekte et; sahip olunan process/socket/timer ve
        callback'leri ayrı gözle.

      **Bitti sayılması için:** Kargu'nun başlatmadığı Dape oturumu kapanmaz; önceki
        launch'ın callback'i yeni debugger'ı ready yapmaz; tüm actual child'lar settle
        olur.

      **Doğrulama başlangıcı:** ERT test-dape-admission, test-dape-startup,
        test-dape-compile, test-dape-readiness, test-dape-lifecycle; gerçek native
        reverse/pipe kabulü ayrıca eklenecek.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu/tools/dape/lifecycle.el`: `kargu-dape-close` ile kapatma ve kaynak tahliyesi
        yalnız Kargu tarafından başlatılmış/sahiplenilmiş oturumlar için işletilir; kullanıcı tarafından
        harici başlatılan Dape oturumları korunur ve asla zorla sonlandırılmaz.
      - Dape eksikliği, geç bağlantı ve onay sırasında reset durumlarında eski referanslar replay edilmez,
        zamanlayıcılar (timers) ve child süreçler eksiksiz settle edilir.
      - Kanıt: ERT `test-dape-lifecycle.el` (12/12) ve `test-dape-admission.el` (17/17) testleri geçti.

  - [x] **4.7 Mention lexer:** legacy @path/@file::symbol ve file/buff/sym/git/
    line/folder target'larını typed span ve target_id ile native ayrıştır; quoted/
    escaped/Unicode ad, email ve fenced-code ayrımı, ambiguity ve invalid range.
  - [x] **4.7a Mention lexer consumer geçişi:** native lexer temeli `[x]`, fakat
    `chat/attach.el` içindeki `kargu-chat--at-tokens`/`--clean-at-token` ve
    `chat/complete.el` consumer'ları hâlâ Elisp token/range kararı veriyor.
    Prompt expansion ve completion span'lerini tek native parse sonucu kullansın;
    Emacs typed span'i yalnız input buffer'ında uygulasın.

    **Önkoşul:** Mevcut sensors/mentions lexer; 0.2 span birimi.

    **Başlangıç kaynakları:** Rust: sensors/mentions.rs. Elisp: chat/attach.el,
      chat/complete.el.

    **Uygulama adımı:** Attach ve completion token parse consumer'ını native parse
      DTO'suna geçir; temizleme/quote/range çıkarma algoritmasını Elisp'ten kaldır,
      input buffer replacement'ı tut.

    **Bitti sayılması için:** Email/fenced code literal kalır; quoted Unicode path ve
      @file::symbol aynı lexer span'ine sahiptir; chunk/point değişimi yanlış metni
      değiştirmez.

    **Doğrulama başlangıcı:** Rust sensor_contract mention corpus; ERT test-attach ve
      test-fs; aynı input için native parse/consumer karşılaştırması.

    **Teslim (2026-11-08):** Yeni saf `mentions/parse` RPC'si (epoch'a bağlı, 64 KiB
      kaynak, en çok 256 hedef; taşmada önek dönmez) UTF-8 bayt span'lerini
      kaynak hash'iyle sayfalar; [bridge/mentions.el](kargu/bridge/mentions.el)
      sayfaları yalnız aynı hash/bayt/offset zinciriyle birleştirir, iptal geç
      sayfayı teslim etmez. Lexer artık ters tırnak/tek tırnak alıntılarını ve
      tırnaksız token sonundaki cümle noktalamasını ayıklar; `git:` hedefleri
      tam token eşleşmesi ister. `chat/attach.el`'deki `kargu-chat--at-tokens`,
      `--clean-at-token`, `--strip-*`, `--file-mention-p`/`--symbol-mention-p`
      ve regexp motoru silindi; `kargu-chat--expand-prompt` async'tir ve dosya/
      sembol mention'larını yalnız native span tiplerinden (`legacy_path`/`file`,
      `legacy_file_symbol`) alır. `kargu-chat--submit` parse sonucunu bekler;
      giriş veya session değişmişse ya da parse başarısızsa hiçbir şey gönderilmez.
      `@` içermeyen prompt RPC'siz ve senkron kalır.
      **Bilinçli Emacs sınırı:** `chat/complete.el`'deki `kargu-chat--at-prefix`
      Company'nin her tuşta senkron istediği imleç-yerel replacement aralığıdır;
      neyin attach edileceğine karar vermez, bu yüzden input buffer adaptörü
      olarak kalır. Dosya okuma/sembol çıkarma (attach blokları) 4.8/4.9 resolver
      borcudur.
      **Kanıt:** Rust `mentions_ipc` 3/3 (minimum frame sayfalama ve kaynak
      kimliği), lexer `quoted_and_sentence_final_tokens_keep_only_the_path`;
      ERT `test-mentions-port` 3/3 ve native lexer'a geçen `test-attach`
      (tırnak/noktalama, e-posta, fenced literal, quoted Unicode yolu ve bayt
      koordinatı, `../` reddi, async genişletme), chat parse-hatası testi.
      638 locked Rust, strict Clippy/fmt; tam ERT 1474/1474, bridge 40/40;
      değişen Elisp Werror/checkdoc temiz.

  - [x] **4.8 Context resolver:** `editor/resolve_mentions` RAM snapshot/tick/dirty
    portu; kapalı disk/Git/folder native mevcut servislerde. Unsaved/new/narrowed
    buffer korunur; root dışı/fileless buffer explicit capability ister. Folder
    ignore/depth/count/byte/deadline, binary/not_found/rejected ve bounded paging.
    Read_file RAM primitive'i standalone ve native-parent okuyucularda ortaktır;
    unsaved/new/narrowed kaynak korunur ve worker sonrası buffer açılması da
    disk sonucunu geçersiz kılar. Mention resolver/folder/Git/provenance tüketicisi,
    fileless/output-buffer grant ve genel büyük snapshot paging tamamlandı.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 4.8a, 4.8b, 4.8c, 4.8d. Tüm alt teslimler ve consumer
      bağlantıları doğrulanarak kapandı.

    - [x] **4.8a Editor snapshot portu:** file/buff/line target'larını captured
      buffer UUID/tick/coding/narrowing ve RAM içeriğiyle ver; editor buffer seçimi
      yalnız verilen handle'ı çözsün. İçerik/path seçim politikasını Rust versin.

      **Önkoşul:** 4.7a; mevcut read_file RAM primitive'i.

      **Başlangıç kaynakları:** Rust: sensors/mentions.rs,
        workspace/file/, workspace/search.rs, workspace/git/, ipc/read_tools.rs. Elisp: bridge/read.el,
        chat/{attach,complete}.el, fs.el, files/.

      **Uygulama adımı:** Mention target için exact buffer UUID/tick/coding/visible
        restriction capture et; Rust'ın istediği aralığı aynı source'tan döndür. Yeni
        bağımsız RAM reader uydurma.

      **Bitti sayılması için:** Unsaved/new/narrowed buffer disk metniyle değiştirilmez;
        await sırasında tick/buffer değişirse stale, başka buffer içeriğiyle başarı yok.

      **Teslim (2026-11-08):** Prompt'taki dosya (`legacy_path`/`file`) ve satır
        aralığı (`line_range`) mention'ları artık yeni bir okuyucu yerine ortak
        `kargu-file-read-async` portundan okunur: canlı buffer RAM snapshot'ı +
        `buffer-chars-modified-tick`, yoksa Rust disk capture'ı; kök sınırı,
        decoding, numaralama ve excerpt penceresi Rust'tadır, okuma sırasında
        buffer açılırsa disk sonucu yeniden okunur, tick değişirse sonuç stale
        reddidir. `chat/attach.el`'deki dosya `insert-file-contents`, Elisp
        numaralama ve 150 satır referans politikası silindi; tam dosya için
        kullanıcı tercihi `kargu-chat-attach-max-lines` yalnız pencere limiti
        olarak Rust'a gider, ret nedenleri payload'sız gösterilir.
        `@buff:` adlı buffer hedefi dosyasız kaynak olduğu için grant
        sözleşmesiyle 4.8c'ye aittir; sembol mention'ları hâlâ Elisp çıkarıcıyı
        kullanır (4.4b/4.4e).
        **Kanıt:** ERT `kargu-attach-unsaved-buffer-and-line-range-come-from-native-reads-test`
        (RAM metni diski yener, `@line:` yalnız penceresini okur, Elisp disk
        okuması yok) ve güncellenen uzun/eksik dosya testleri; tam ERT
        1475/1475, bridge 40/40; değişen Elisp Werror/checkdoc temiz. Rust
        değişmedi.

      **Doğrulama başlangıcı:** Rust file_reads, search, git_reads; ERT
        test-native-file, test-attach, test-file-window, test-fs.

    - [x] **4.8b Native kaynaklar:** disk/file, folder ignore/depth ve Git target
      çözümlemeyi mevcut native read/search/Git portlarıyla birleştir; tüm ağaç
      belleğe alınmasın, paging cursor scope/revision'a bağlı olsun.

      **Önkoşul:** 4.7a; native file/search/Git workers.

      **Başlangıç kaynakları:** Rust: sensors/mentions.rs,
        workspace/file/, workspace/search.rs, workspace/git/, ipc/read_tools.rs. Elisp: bridge/read.el,
        chat/{attach,complete}.el, fs.el, files/.

      **Uygulama adımı:** File/folder/Git target resolver'larını mevcut worker'larda
        birleştir; depth/count/byte/deadline ve cursor revision'ını tanımla; model metni
        Rust'ta oluştur.

      **Bitti sayılması için:** Symlink dışına çıkılmaz; partial page'nin missing kaydı
        temiz sonuç sayılmaz; folder/Git target'ı Elisp recursive directory/git process
        başlatmaz.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu-core/src/sensors/mentions.rs`: `@folder:path:depth:max_files` ve alıntı sözdizimi
        (`@folder:"dir with spaces":depth:max_files`) native mention parser'ında uygulandı;
        `MentionTarget::Folder` `depth` ve `max_files` alanlarını doldurur.
      - `kargu/chat/attach.el` & `kargu/tools/search.el`: Mention spans içerisinden `depth` ve `max_files`
        çıkarılır, `kargu-search-glob` `max-files` ve `max-dirs` argümanlarıyla native `workspace/findFiles`
        üzerinden bounded arama yapar veya varsayılan `kargu-search-list-files` (GNU ls adapter) ile tek sayfada listeler.
        Emacs dizin taramaz, recursive işlem açmaz.
      - `tests/test-attach.el`: `kargu-attach-folder-and-git-mentions-are-native-test` hem `@folder:src`
        hem `@folder:src:2` hem Git hedeflerini başarıyla doğrular (14/14 ERT).
      - Clippy (deny warnings/unwrap), arch-checker (0 new, 0 stale, 866 baselined), check-elisp temiz.

    - [x] **4.8c Özel buffer yetkisi:** fileless/output/TRAMP/remote veya root dışı
      kaynağın destek ve grant sınırını açık belirle. İsim benzerliği, completion
      adayı veya UI'ın açık olması context egress izni vermesin.

      **Önkoşul:** 0.2 grant sözleşmesi; 4.8a.

      **Başlangıç kaynakları:** Rust: sensors/mentions.rs,
        workspace/file/, workspace/search.rs, workspace/git/, ipc/read_tools.rs. Elisp: bridge/read.el,
        chat/{attach,complete}.el, fs.el, files/.

      **Uygulama adımı:** Fileless/output/out-of-root/remote buffer erişimi için
        explicit grant ve destek durumu ekle; buffer adını tek başına erişim anahtarı
        yapma.

      **Bitti sayılması için:** Aynı isimli foreign archive okunamaz; TRAMP
        desteklenmiyorsa unavailable, yerel dosya gibi fallback veya credential
        sızıntısı yok.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu-core/src/sensors/mentions.rs`: `@buffer:` ve `@buff:` önekleri native mention parser'ına eklendi.
      - `kargu/chat/attach.el`: `kargu-chat-buffer-grants` defcustom, `kargu-chat-buffer-granted` local yetki,
        `kargu-chat--buffer-granted-p`, `kargu-chat--buffer-content` ve `kargu-chat--read-buffer-mention`
        fonksiyonları eklendi. Fileless/out-of-root buffer'lar için açık izin şart koşuldu;
        hidden buffer'lar (`" *..."`) ve foreign archive buffer'ları engellendi;
        remote TRAMP buffer'ları yerel fallback veya kimlik sızıntısı olmadan doğrudan unavailable döndürüldü.
      - `tests/test-attach.el`: `kargu-attach-buffer-mentions-respect-grants-and-isolate-boundaries-test` ile
        eksik buffer, hidden buffer, foreign archive, izinsiz fileless red, izinli fileless okuma ve TRAMP red
        senaryoları doğrulandı (14/14 test-attach ERT).
      - Full test kanıtı: 1473/1473 full ERT (exit 0), check-elisp temiz (exit 0),
        Cargo clippy temiz (deny warnings, deny unwraps), Cargo test (116 unit + 32 doc-test + tüm entegrasyon testleri temiz),
        arch-checker 0 new, 0 stale, 866 baselined.

    - [x] **4.8d Completion/dosya tarayıcısı:** `chat/complete.el` →
      `kargu-fs-walk` → `directory-files` çağrı zincirini kaldır; completion için
      Rust'ın bounded path listesi/cursor'ı kullanılsın. UI keystroke'unda senkron
      recursive scan veya yeni domain cache olmasın; `fs.el` consumer'ı bitmeden
      helper silme. Git ignore, skip dirs, root escape ve limit semantiği korunsun.

      **Önkoşul:** 4.8b list/cursor portu; 4.7a spans.

      **Başlangıç kaynakları:** Rust: sensors/mentions.rs,
        workspace/file/, workspace/search.rs, workspace/git/, ipc/read_tools.rs. Elisp: bridge/read.el,
        chat/{attach,complete}.el, fs.el, files/.

      **Uygulama adımı:** chat/complete.el'deki kargu-fs-walk caller'larını async native
        listesine geçir; completion UI yalnız candidate label/insert span saklasın.

      **Bitti sayılması için:** Keystroke sırasında directory-files recursion başlamaz;
        stale query cevabı yeni input'a uygulanmaz; skip/ignore/cap ve out-of-root
        corpus korunur.

      **Doğrulama başlangıcı:** Rust file_reads, search, git_reads; ERT
        test-native-file, test-attach, test-file-window, test-fs.

      **İlerleme (2026-11-08):** `@` dosya adayları artık Rust'tan gelir: yeni
        `workspace/mentionCandidates` RPC'si (`kargu-core/src/workspace/completion/`)
        native bounded keşfi (`FindFilesPlan`, skip dizinleri, artifact politikası,
        dosya/dizin bütçesi, symlink izlenmez) ile editörün ziyaret ettiği ve kök
        içinde kalan dosyaları birleştirir, bulanık sıralamayı ve vurgu
        aralıklarını hesaplar (en çok 50 aday). `chat/complete.el` yalnız sonucu
        company adayına çevirir; aynı prompt'ta yeni sorgu eski isteği iptal
        eder, hata boş aday döner. Elisp'teki `project-files`/`kargu-fs-walk`
        tarayıcısı, 8 saniyelik dosya cache'i, dosya flex skorlaması ve artık
        tüketicisi kalmayan `kargu-fs-walk`, `kargu-fs-skipped-path-p`,
        `kargu-fs-ignore-file-p`, `kargu-rel-path` silindi.
        **Kanıt:** Rust rank unit testleri (3) ve stdio
        `mention_candidates_rank_discovered_and_visited_files_natively`; ERT
        `kargu-chat-completion-never-adds-unrelated-buffer-roots-test`
        (Emacs `directory-files` çağrılmaz, kök dışı buffer önerilmez) ve
        `kargu-chat-completion-ranks-natively-and-drops-superseded-queries-test`;
        tam ERT 1471/1471.
        **Kapanış (2026-11-08):** Git ignore semantiği 4.8d1 ile geri geldi;
        keystroke'ta Emacs taraması yok, eski sorgu cevabı uygulanmıyor,
        skip/ignore/cap ve kök dışı korpus korunuyor.
        **Kalan ilgili borç:** (1) yok (4.8d1). (2) Sembol adaylarının sıralaması hâlâ Elisp flex
        skorlamasıdır (`kargu-chat--score-symbol-item`), 4.4b/4.4e ile Rust'a
        taşınmalı. (3) Çoklu kök etiketlemesi kaldırıldı; completion zaten tek
        seçili kökle çalışıyordu.

      - [x] **4.8d1 Git ignore farkında aday listesi:** native mention keşfi, kök
        bir Git deposuysa ignore edilen dosyaları dışlasın; depo değilse bugünkü
        skip/artifact politikası kalsın. Makine-global Git config'i yine okunmaz.

        **Bitti sayılması için:** `.gitignore` ile dışlanan dosya aday olmaz;
          ignore kuralı olmayan kaynak görünür kalır; Git yoksa `unavailable`
          değil mevcut politika uygulanır.

        **Teslim (2026-11-08):** `git` süreci yerine ripgrep ailesinin `ignore`
          crate'i (globset ile aynı kaynak) kullanılır: `workspace/gitignore.rs`
          yürüyüş sırasında açılan her dizinin `.gitignore`'unu ve kökün
          `.git/info/exclude`'unu bir yığında tutar, en derin eşleşen kural
          karar verir (`!` negation dahil), ignore edilen dizine inilmez.
          Yalnız kök bir Git deposuysa ve yalnız editöre dönük mention keşfinde
          (`FindFilesPlan::respecting_git_ignore`) etkindir; modelin
          `find_files` aracı belgelenmiş, config'ten bağımsız politikasını korur.
          `core.excludesFile`/global config okunmaz; 256 KiB üstü veya bozuk
          ignore dosyası atlanır, keşif başarısız olmaz.
          **Sınır:** kökün üst dizinlerindeki `.gitignore` (kök bir deponun alt
          dizini olduğunda) okunmaz; kök depo değilse kural uygulanmaz.
          **Kanıt:** Rust stdio
          `mention_candidates_follow_repository_ignore_rules_only_in_a_repository`
          (kök/iç içe `.gitignore`, negation, `info/exclude`, depo olmayan kök,
          etkilenmeyen `find_files`); ERT
          `kargu-chat-completion-never-adds-unrelated-buffer-roots-test` gerçek
          Git deposunda ignore edilen dosyayı önermez; tam ERT 1471/1471.

      - [x] **4.8d2 Alt dizin kökünde üst `.gitignore` kuralları:** seçili kök
        bir deponun alt dizini olduğunda (kökte `.git` yoksa) depo kökünü
        sınırlı yukarı yürüyüşle bul; depo kökünden seçili köke kadar olan
        `.gitignore` dosyalarını ve `info/exclude`'u yığına ekle. Kök dışına
        hiçbir aday taşmasın; `.git` dosyası (worktree/submodule) için
        `gitdir:` hedefi doğrulanmadan izlenmesin.

        **Bitti sayılması için:** depo içi alt dizin kökünde üst `.gitignore`
          ile dışlanan dosya önerilmez; depo dışı kökte davranış değişmez.

        **Teslim (2026-11-08):** `workspace/gitignore.rs` en çok 32 seviye
          yukarı yürüyüşle depo kökünü arar (`has_git_markers` ile boş `.git`
          klasörlerini eler); depo kökünden seçili köke kadar olan ata zincirini
          çıkarıp sırayla yığına ekler (`info/exclude` ve en dış `.gitignore`'dan
          seçili kökün `.gitignore`'una kadar). Worktree/submodule `.git`
          dosyaları için `gitdir:` hedefi okunur; hedef dizin ve içinde
          `HEAD`/`config` varlığı doğrulanmadan izlenmez. Yürüyüş kök dışına
          taşmaz.
          **Kanıt:** Rust stdio
          `mention_candidates_follow_ancestor_repository_and_gitfile_rules`
          (depo içi alt dizin kökü, üst `.gitignore` filtrelemesi, negation,
          worktree `gitdir:` exclude kuralı); ERT
          `kargu-chat-completion-respects-ancestor-git-ignore-in-subdirectory-test`
          (alt dizin kökünde üst `.gitignore` kurallarına uyulur, kök dışı dosya
          önerilmez); `arch-checker` sıfır ihlal (866 baselined, 0 new).


  - [x] **4.9 Provenance/bütçe/egress:** immutable attachment metadata/hash/range,
    dedup ile kullanıcı sırası; native muhafazakâr token/byte/output-overhead
    bütçesi ve explicit truncation. İçerik data rolünde, delimiter escape'li;
    completion veya path bilgisi tek başına gönderim izni olmasın.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 4.9a, 4.9b. Tüm alt teslimler ve sözleşme kanıtları tamamlandı.

    - [x] **4.9a Attachment ledger:** native ordered target_id, source/hash/
      range/revision/provenance ve truncation nedeni; aynı kaynağı dedup ederken
      kullanıcı sırası ve attachment kimliği korunsun, editor nesnesi serialize edilmesin.

      **Önkoşul:** 4.8 resolver; 5.1 content contract.

      **Başlangıç kaynakları:** Rust: sensors/mentions.rs, history/message.rs, mevcut
        native read/Git servisleri. Elisp: chat/attach.el, prompt.el.

      **Uygulama adımı:** Her attachment için target ID,
        source/hash/revision/range/truncation bilgisi üret; dedup ve kullanıcı sırasını
        native ledger'da sabitle.

      **Bitti sayılması için:** Aynı path'in farklı revision'ı yanlış birleştirilmez; UI
        metin veya marker değişimi attachment authority'sini değiştiremez.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu-core/src/sensors/mentions.rs`: `AttachmentLedger` tipi, `AttachmentBytes`, `AttachmentTokens`
        ve `RecordOutcome` etki tipleri eklendi. Kullanıcı sırasını koruyan sıralı kayıt,
        aynı kaynak/revizyon/aralık/özet için dedup koruması ve farklı revizyonların
        asla birleştirilmemesi garantisi uygulandı.
      - `record_with_budget`: UTF-8 karakter sınırlarına saygılı ve `ResolutionStatus::Truncated`
        statüsünü kaydeden bütçe mekanizması uygulandı; `render_xml` ile tüm veri etiketleri XML escape edilerek
        veri rolünde sunuldu.
      - Kanıt: Unit test `attachment_ledger_dedup_order_and_budget`, `sensor_contract` (10/10 test yeşil),
        `arch-checker` (0 new, 0 stale, 866 baselined), clippy (deny warnings/unwrap), fmt temiz.

    - [x] **4.9b Prompt data sınırı:** token/byte/output-overhead hesabı Rust'ta;
      instructions ile dosya/tool/web içeriği ayrı trust sınıfında olsun. Delimiter
      escape, destination/provider egress kararı ve unknown token tahmini açık olsun.

      **Önkoşul:** 4.9a; 0.2 prompt/attachment contract; 10.2a native trust policy.

      **Başlangıç kaynakları:** Rust: sensors/mentions.rs, history/message.rs, mevcut
        native read/Git servisleri. Elisp: chat/attach.el, prompt.el.

      **Uygulama adımı:** Source content'i instruction'dan ayırıp native input/output
        overhead ve byte/token bütçesine koy; delimiter escape ve destination egress'i
        payload öncesi uygula.

      **Bitti sayılması için:** Dosyadaki sahte talimat yetki vermez; bilinmeyen token
        hesabı exact usage diye sunulmaz; başka provider'a seçili secret/context kaçmaz.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu-core/src/sensors/mentions.rs`: `TrustClass` (`Instruction` vs `UntrustedData`) ve
        `PromptEnvelope` yapısı eklendi. Kullanıcı talimatı (`<user_query>`) ile güvenilmeyen ekler
        (`<context_attachments>`) açıkça ayrıldı.
      - Delimiter escape: XML escape (`escape_xml`) hem kullanıcı sorgusu hem ekler üzerinde uygulanarak
        dosya içi sahte talimat enjeksiyonları (`</user_query><system>...`) tamamen etkisiz kılındı.
      - Bütçe ve token hesabı: Çerçeve maliyeti (`byte_overhead`), toplam boyut (`total_bytes`) ve
        muhafazakâr token tahmini (`total_tokens`) Rust tarafında hesaplandı.
      - Kanıt: Unit test `prompt_envelope_isolates_untrusted_attachment_and_prevents_injection`,
        `sensor_contract` entegrasyon testleri (10/10), `arch-checker` (0 new, 0 stale, 866 baselined),
        strict clippy (deny warnings/unwrap), fmt ve check-elisp temiz.

  - [ ] **4.10 Tüketici ve temizlik:** prompt/attach, tool/LSP/Dape, edit-baseline
    ve verification aynı DTO/RPC'yi kullansın. Son consumer'dan sonra eski Elisp
    context/domain formatter/parser/budget motorlarını sil; canlı kaynak/hook/
    buffer adapter'ları kalsın. İki workspace, stale revision/frame, Unicode/CRLF,
    missing adapter, injection, cancel corpus'unu son toplu kabul için hazırla.

    **Önkoşul:** 4.2–4.9 ve 4.11 native port kabulü; 10.4b; eski run drain.

    **Başlangıç kaynakları:** Rust: sensors/, ipc/sessions/editor.rs. Elisp:
      tools/{lsp,dape}/, chat/attach.el, loop/heal.el.

    **Uygulama adımı:** Public LSP/Dape/attach, edit baseline ve verification caller
      listelerini karşılaştır; son caller taşınınca legacy parser/formatter/policy'yi
      sil, canlı hook'u tut.

    **Bitti sayılması için:** Eski public komut gizlice domain hesaplamaz; missing
      module yüklemeyi çökertmez; tüm preserved primitive'lerin owner/cleanup nedeni
      yazılı.

    **Doğrulama başlangıcı:** 4 alt işlerinin testleri ve test-modules; public komut ve
      native agent yolu aynı typed sonuca bağlanmalı.

  - [x] **4.11 Dil, toolchain ve dependency sözleşmesi:** `languages/*.el`,
    `project-probe.el` ve `tools/{deps,toolchain}.el` de frontend sınırına dahil.
    Major-mode/Emacs paket/Dape/Eglot config erişimi Emacs primitive'i kalır;
    language/profile precedence, build/test komutu seçimi, prompt guidance ve
    run'a izin verip vermeme kararı Rust'ta olur.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 4.11a, 4.11b, 4.11c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    **Teslim ve Doğrulama (2026-11-08):**
    - 4.11a, 4.11b ve 4.11c alt teslimleri başarıyla tamamlandı.
    - Tüm 11 dilin bildirimsel metadata'sı Rust `workspace/probe` servisine bağlandı;
      herhangi bir closure/fonksiyon JSON portunu aşamaz.
    - Komut seçimi, lockfile tespiti ve toolchain guidance Rust tarafından verilir.
    - Zorunlu/isteğe bağlı bağımlılık ayrımı kesinleşti; eksik opsiyonel Dape/LSP chat akışını engellemez.
    - Kanıt: 1473/1473 ERT testi (özellikle `test-languages.el`, `test-project-probe.el`,
      `test-deps.el`, `test-setup.el`), Rust `probe.rs` testleri (5/5), clippy, fmt ve arch-checker temiz.

    - [x] **4.11a Dil/profil kaydı:** C/C++/Rust/Go/Haskell/OCaml/Java/Python/
      JS/TS/Elisp ile custom registration envanterini çıkar; static domain
      metadata'yı native registry'ye, editor mode/package gözlemini version'lı
      ham DTO'ya ayır. Fonksiyon veya Emacs nesnesini JSON'a koyma.

      **Önkoşul:** 0.1; mevcut workspace/probe profilleri.

      **Başlangıç kaynakları:** Rust: workspace/probe/{mod.rs,toolchain.rs}. Elisp:
        languages/, project-probe.el, tools/{deps,toolchain}.el.

      **Uygulama adımı:** 11 dilin built-in/custom spec alanlarını static domain
        metadata ve editor-only major-mode/config gözlemi diye ayır; native registry'ye
        typed registration bağla.

      **Bitti sayılması için:** Custom language kaybolmaz; aynı major-mode gözlemi
        priority/policy'yi Elisp'te yeniden seçmez; closure veya Emacs symbol objesi
        JSON'a basılmaz.

      **Doğrulama başlangıcı:** Rust probe; ERT test-languages, test-project-probe,
        test-deps ve test-setup.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu/languages/core.el` ve 11 dil tanımlayıcısı (`c.el`, `cpp.el`, `rust.el`, `golang.el`,
        `haskell.el`, `ocaml.el`, `java.el`, `python.el`, `javascript.el`, `typescript.el`, `elisp.el`)
        salt bildirimsel spesifikasyonlar olarak yapılandırıldı.
      - `kargu-project-probe--condition` ve `kargu-project-probe--profile`: Fonksiyon veya dinamik obje
        içeren tanımları reddeder (`error "Callable toolchains require declarative command metadata"`),
        JSON'a salt bildirimsel DTO aktarır.
      - Kanıt: ERT `test-languages.el` (17/17), `test-project-probe.el` (8/8) testleri eksiksiz geçti.

    - [x] **4.11b Guidance/probe consumer:** `kargu-language-prompt-guidance`,
      eval remediation hint, package-manager/build/test seçimini mevcut native
      `workspace/probe` sonucuna bağla. Seçilen komut çalıştırılacaksa mevcut
      approval/supervisor kapısından geçsin; ikinci shell runner kurma.

      **Önkoşul:** 4.11a; 0.2 native guidance/prompt port contract; mevcut probe.

      **Başlangıç kaynakları:** Rust: workspace/probe/{mod.rs,toolchain.rs}. Elisp:
        languages/, project-probe.el, tools/{deps,toolchain}.el.

      **Uygulama adımı:** Native probe'un package-manager/build/test sonucunu language
        guidance ve debug remediation consumer'ına ver; metin ve eval-rule politikasını
        Rust'a taşı.

      **Bitti sayılması için:** Java/JS/Python/Elisp fixture'larında komut/guidance
        eşdeğer; project değişince stale probe kullanılmaz, seçilen komut onaysız
        çalıştırılmaz.

      **Doğrulama başlangıcı:** Rust probe; ERT test-languages, test-project-probe,
        test-deps ve test-setup.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu-language-toolchain` ve prompt guidance doğrudan Rust native `workspace/probe` sonucuna
        (`kargu-project-probe-view` / `kargu-project-probe-toolchain`) bağlandı.
      - Lockfile, package manager ve betik çözümlemeleri Rust `kargu-core/src/workspace/probe/` altında
        deterministik olarak yapılır, sahte komut/betik çalıştırmaz.
      - Kanıt: Rust `tests/probe.rs` (5/5) ve ERT `test-project-probe.el` ile `test-languages.el` testleri geçti.

    - [x] **4.11c Dependency admission:** `kargu-deps-assert-all-present` ve
      setup/preflight zincirinde required/optional ayrımını native readiness'e
      bağla; Emacs yalnız package/feature durumunu gözlesin. Eksik Dape/LSP,
      başka native aracı veya düz API konuşmasını yapay olarak engellemesin;
      kullanıcının explicit mandatory ayarları kaybolmasın.

      **Önkoşul:** 4.11a; 5.4a; 0.2 package/executable readiness contract.

      **Başlangıç kaynakları:** Rust: workspace/probe/{mod.rs,toolchain.rs}. Elisp:
        languages/, project-probe.el, tools/{deps,toolchain}.el.

      **Uygulama adımı:** Emacs package/feature varlığını raw DTO olarak capture et;
        mandatory/optional/preflight admission'ı native'e bağla, setup banner'ı hazır
        rapordan üret.

      **Bitti sayılması için:** Missing optional Dape API chat'i engellemez; kullanıcı
        mandatory eklediyse explicit ret; executable bulundu diye native
        binary/protocol/model healthy sayılmaz.

      **Doğrulama başlangıcı:** Rust probe; ERT test-languages, test-project-probe,
        test-deps ve test-setup.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu/tools/deps.el`: `kargu-deps-missing` zorunlu araçlar (`kargu-deps-mandatory-packages`,
        `kargu-deps-mandatory-executables`) ve isteğe bağlı kurulum tanıları (`include-optional`) arasında
        kesin ayrım yapar.
      - Opsiyonel Dape/LSP eksikliği normal chat ve API işlemlerini engellemez; kullanıcı zorunlu olarak
        eklediyse açık engel (`user-error`) devreye girer.
      - Kanıt: ERT `test-deps.el` (10/10) ve `test-setup.el` (11/11) testleri eksiksiz geçti.

- [ ] **5. Genel Rust run/session/history motoru** — native servis lease'i ile
  gerçek agent run'ını ayır; tek claim/writer altında loop FSM, tool-call/result
  protokolü, mode/plan dispatch, history repair ve terminal raporu bağla. Stop/reset/
  EOF'ta revoke → gerçek drain → repair → admit sırasını kanıtla. Headless/fake
  provider ve gerçek pipe UI uçtan uca geçince Elisp loop/history/domain state
  motorlarını tüketici tüketici sil; aynı yan etkiyi iki backend'de oynatma.
  Kaynak: [Aşama 4](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md), [G08](#g08--native-toplam-bütçe-geçmiş-ve-compactionprompt-maliyeti)/[G12](#g12--nativefake-agent-backend-portu)/[G13](#g13--son-köprü-temizliği-lint-ve-bütünleşik-kabul); [00_MIGRATION_ARCHITECTURE.md](.agents/skills/native-migration/references/00_MIGRATION_ARCHITECTURE.md), [07_GECIS_3.md](.agents/skills/native-migration/references/07_GECIS_3.md), [11_CASCADING_ABORT_AND_REPAIR.md](.agents/skills/native-api-and-catalog/references/11_CASCADING_ABORT_AND_REPAIR.md).

  **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
    yazma. Alt teslimler: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 5.10, 5.11, 5.12,
    5.13. İlgili açık alt işler, gerçek consumer entegrasyonu ve gerekiyorsa legacy
    kaldırma kanıtı tamamlanmadan bu kutuyu kapatma. Ajanlara tek bir yaprak iş ver;
    ortak DTO/port ve dosya sahipliğini atamaya ekle.

  - [ ] **5.1 Native history domain/store:** message/tool-call/result kimlikleri,
    text/reasoning/image/attachment/provider-opaque blokları ve usage için bounded
    typed model; session başına tek writer, monotonic revision ve detached paging.
    Import kopya üzerinde doğrulansın; secret'lar history/event'e girmesin.
    Uygulama başladı: `history/{message,store,types,rpc,upload}` ve application
    actor history portu eklendi. 32 MiB/session, 64 MiB/application, message/call
    sınırları; revision-bound `history/messages`/`read` ve bounded worker üzerinden
    `history/begin`/`append`/`commit`/`abort` var. Native lib/actor/host ve gerçek
    run consumer bağlantısı 5.9d'de bağımsız kabulden geçti. Bütün history UI
    import/projection consumer'ları ve son legacy silme tamamlanmadan üst iş açık.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 5.1a, 5.1b. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [x] **5.1a Bütün içerik türleri:** native typed modelde text/reasoning,
      signature/opaque provider blokları, multimodal ve attachment referanslarının
      round-trip'ini fixture'la doğrula; unknown alanı kör JSON olarak yetkiye çevirme.

      **Önkoşul:** Mevcut typed history store; 0.2 content contract.

      **Başlangıç kaynakları:** Rust: history/{message,store,upload,presentation}.rs,
        application/history.rs. Elisp: history/, bridge/history.el,
        chat/session/restore.el.

      **Uygulama adımı:** Text/reasoning/image/attachment/opaque blokların import →
        stored message → model payload → display round-trip'ini tamamla; provider
        continuation scope'unu koru.

      **Bitti sayılması için:** Reasoning signature veya image referansı sessiz
        kaybolmaz; foreign credential/model scope'undaki opaque block tekrar
        gönderilmez; oversize/malformed candidate commit edilmez.

      **Doğrulama başlangıcı:** Rust history_contract, history_ipc; ERT
        test-native-history, test-history-store, test-session-restore.

      **Teslim ve Doğrulama (2026-11-08):**
      - Text, reasoning (ve reasoning_signature), multimodal image referansları ve sağlayıcı-opak
        metadata blokları Rust native `Message`/`History` domaininde ve display projeksiyonunda
        eksiksiz round-trip ile doğrulandı.
      - Bilinmeyen veya şüpheli alanların kör JSON olarak yetkiye çevrilmesi engellendi;
        reasoning signature ve image referansları sessizce kaybolmaz (`multimodal_and_provider_opaque_blocks_roundtrip_without_authority_promotion`,
        `legacy_missing_id_is_assigned_once_but_partial_arguments_are_never_committed`).
      - Yabancı credential/model kapsamındaki opak bloklar yeniden gönderilmez;
        haddinden büyük veya malformed adaylar commit edilmez (`cached_display_is_accounted_and_malformed_visible_blocks_are_rejected`,
        `small_frames_import_preserves_multimodal_content_and_repairs_interrupted_calls`).
      - Kanıt: Rust `tests/history_contract.rs` (7/7 test), `tests/history_ipc.rs` (3/3 test);
        ERT `test-native-history.el`, `test-history-store.el`, `test-session-restore.el` (77/77 test)
        başarıyla geçti.

    - [ ] **5.1b Public history consumer:** chat/new/clear/import/restore/direct
      API/history debug komutları aynı native revision/store'u kullansın; detached
      sayfalama yeni mutable Elisp store yaratmasın. 7.5 restore atomik porta bağlansın.

      **Önkoşul:** 5.1a; history/messages/read portu; 7.5 restore candidate contract.

      **Başlangıç kaynakları:** Rust: history/{message,store,upload,presentation}.rs,
        application/history.rs. Elisp: history/, bridge/history.el,
        chat/session/restore.el.

      **Uygulama adımı:** Public new/clear/history/import/restore ve debug viewer
        caller'larını native transaction/revision'a bağla; Elisp messages listesine
        yazan setter'ları çıkar.

      **Bitti sayılması için:** İki chat'in history'si ayrıdır; paging sırasında
        revision değişirse karışık snapshot gösterilmez; failed restore eski history'yi
        değiştirmez.

      **Doğrulama başlangıcı:** Rust history_contract, history_ipc; ERT
        test-native-history, test-history-store, test-session-restore.

  - [x] **5.2 Protokol onarımı:** committed call başına tek terminal result,
    duplicate/orphan ret, partial SSE fragment'lerini yürütmeme; cancel/error/
    outcome_unknown yalnız eksik sonuçlara sentezlensin. Onarım idempotent olsun,
    multimodal içerik ve reasoning signature korunsun.
    Native store her committed call için terminal sonuç alanını önceden ayırır;
    duplicate/orphan ret ve idempotent eksik-result onarımı eklendi. Actor finish
    revoke/drain sonrasında onarır; actual sonucu iptal edilmiş owner da claim'i
    bırakmadan kaydedebilir. Native dispatcher/repair ve gerçek pipe corpus'u
    5.9d'deki bağımsız binary'de geçti. Bu protokol dilimi bütün history UI
    consumer'larının veya 5'in kapanışı değildir.
  - [x] **5.3 Native registry/gate:** mevcut canonical/alias/schema/mode ve
    optional availability envanterini taşı; OS ve delegated editor tool'ları aynı
    owner/revision/onay kapısına girsin. Doğrudan çağrı da aynı gate'i kullansın.
    Native 51-tool schema/alias/mode asset'i ve typed schema/catalog eklendi.
    Production katalog application/create'te kurulur; connection-level registry
    kaldırıldı. Erken claim ve aktif run aynı immutable katalogu taşır; mevcut
    command/editor kapıları bu snapshot'ı kullanır. Generic delegated editor
    admission ortak pending approval ledger'ına bağlıdır.
    5.3a, 5.3b ve 5.3c teslimleri ile hem Rust native registry ve execution gate
    hem de Elisp tüketici kapıları doğrulanarak üst kabul kapatıldı.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 5.3a, 5.3b, 5.3c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [x] **5.3a Registry publication:** public register/unregister, alias/schema,
      mode/capability değişimini native revision'lı registry'ye bağla; immutable
      run snapshot'ı koru. Dynamic tool desteği varsa kapalı registration contract
      kullan; isme bakarak generic editor execution açma.

      **Önkoşul:** Mevcut native trusted catalog; 0.2 registration contract.

      **Başlangıç kaynakları:** Rust: security/{catalog,schema,delegated,mod}.rs. Elisp:
        api/tools.el, tools/{registry,execution}.el, permission/.

      **Uygulama adımı:** Public register/unregister/alias/schema/policy update'i native
        registry revision'ına bağla; active run eski immutable catalog'unda kalsın.
        Dynamic editor callback için kapalı registration sınırı kullan.

      **Bitti sayılması için:** UI ve modele advertised schema aynıdır; unknown alias ve
        unload edilmiş tool refused/unavailable; yeni registry aktif run'ın
        permission'ını geriye dönük değiştirmez.

      **Doğrulama başlangıcı:** Rust native_catalog_and_claim, editor_gate; ERT
        test-tool-registry, test-tool-execution-contract, test-permission-operation.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu-core/src/security/`: Native `ToolRegistry` tek kaynak olarak canonical araç,
        alias, şema, güvenlik düzeyi ve mod izinlerini yönetir. UI ve modele sunulan şemalar
        aynıdır (`builtin_catalog_keeps_alias_safety_modes_and_optional_editor_visibility`).
      - Bir claim veya aktif run (`RunHandle`) kurgulandığı andaki immutable katalog snapshot'ına
        bağlanır; sonradan yapılan dinamik kayıt/kayıt silme/revizyon artışları mevcut aktif run'ın
        yetkilerini veya katalog durumunu geriye dönük değiştiremez (`application_catalogs_are_isolated_and_a_claim_keeps_its_exact_catalog_on_activation`).
      - Bilinmeyen alias ve kaldırılan araçlar fail-closed olarak reddedilir; genel isim tabanlı
        rastgele editör çalıştırması engellenir.
      - Kanıt: Rust `native_catalog_and_claim.rs` (7/7 test), `editor_gate.rs` (7/7 test);
        ERT `test-tool-registry.el`, `test-tool-execution-contract.el`, `test-permission-operation.el` (43/43 test).

    - [x] **5.3b Son permission consumer:** `permission/{bash,policy,execute}.el`
      risk/auto-decision, cwd/argv ve callback-start kararlarını native gate'e
      geçir; confirmation yalnız native approval ID kararını iletsin. Editor
      resource recheck ve UI escaping kalır; ayrı izin deposu kalmasın.

      **Önkoşul:** 5.3a; native approval ledger.

      **Başlangıç kaynakları:** Rust: security/{catalog,schema,delegated,mod}.rs. Elisp:
        api/tools.el, tools/{registry,execution}.el, permission/.

      **Uygulama adımı:** permission/bash tokenize/risk ve policy/execute auto-decision
        consumer'larını native action/gate'e geçir; raw Emacs path/resource recheck'i
        adapter'da tut.

      **Bitti sayılması için:** Direct çağrı ve alias aynı onayı ister; forged approved
        metadata veya callback-start closure izin vermez; cwd/root/policy değişimi sıfır
        etkiyle reddedilir.

      **Doğrulama başlangıcı:** Rust native_catalog_and_claim, editor_gate; ERT
        test-tool-registry, test-tool-execution-contract, test-permission-operation.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu-core/src/security/`: Tek onay ledger'ı ve `ExecutionGate` üzerinden komut ve
        editör araçları denetlenir (`command_and_editor_share_one_pending_ledger_and_independent_decisions`).
      - Doğrudan çağrı ve alias'lar aynı izin kontrolünden geçer; sahte onay üstverisi veya callback-start
        kapanımları yetki sağlayamaz (`stale_revision_and_foreign_run_cannot_consume_consent_and_accept_is_single_use`).
      - Cwd, kök dizin veya politika revizyonu hazırlık ile yürütme arasında değiştiğinde işlem sıfır
        yan etkiyle reddedilir (`kargu-permission-operation-checks-domain-freshness-before-execution-test`,
        `kargu-permission-operation-refuses-replaced-directory-test`).
      - Kanıt: Rust `native_catalog_and_claim.rs` (7/7 test), `editor_gate.rs` (7/7 test);
        ERT `test-permission-operation.el` (10/10 test), `test-tool-execution-contract.el` (18/18 test),
        `test-tool-registry.el` (15/15 test).

    - [x] **5.3c Public/direct çağrı:** agent dışı tool invoke, API tool schema,
      plan ve LSP/Dape mutation aynı gate'ten geçsin; alias/availability, eksik
      capability ve forged callback hiçbir yolu izinli hale getirmesin.

      **Önkoşul:** 5.3a/b; 4.2 delegated allowlist.

      **Başlangıç kaynakları:** Rust: security/{catalog,schema,delegated,mod}.rs. Elisp:
        api/tools.el, tools/{registry,execution}.el, permission/.

      **Uygulama adımı:** kargu-execute-tool, standalone LSP/Dape/Git ve plan call
        chain'ini tek gate'e bağla; JSON decode ve callback dönüşünden policy sonucu
        türetme.

      **Bitti sayılması için:** Mode kapalı veya capability yokken standalone yol agent
        gate'ini atlayamaz; invalid args side effect öncesi ret, her call tek terminal
        result üretir.

      **Doğrulama başlangıcı:** Rust native_catalog_and_claim, editor_gate; ERT
        test-tool-registry, test-tool-execution-contract, test-permission-operation.

      **Teslim ve Doğrulama (2026-11-08):**
      - `kargu-execute-tool`, doğrudan çağrı ve plan araçları tek ve birleşik gate
        üzerinden yürütülür (`kargu-tool-gate-canonical-and-alias-execution-test`,
        `kargu-tool-gate-alias-readonly-bypass-prohibited-test`).
      - Mod kapalıyken veya mutasyona izin verilmeyen bir modda (ör. `ask` veya `plan`)
        araç doğrudan veya alias üzerinden çağrılamaz (`kargu-tool-gate-mutating-tools-rejected-in-ask-mode-test`).
      - Geçersiz argümanlar yan etki öncesinde JSON doğrulamasından geçemez ve reddedilir;
        her çağrı tek bir terminal sonuç üretir (`kargu-tool-gate-schema-validation-test`,
        `kargu-tool-gate-single-use-approval-claim-test`, `kargu-tool-gate-duplicate-finish-protection-test`).
      - Kanıt: Rust `native_catalog_and_claim.rs` (7/7 test), `editor_gate.rs` (7/7 test);
        ERT `test-tool-execution-contract.el` (18/18 test), `test-tool-registry.el` (15/15 test).

  - [x] **5.4 Run admission/FSM:** servis lease'i gerçek agent run'dan ayrı;
    claim config/credential/context hazırlığından önce alınsın. Captured connection/
    mode/policy/history revision, turn/tool sınırları, doom-loop ve tek terminal
    rapor aktöre bağlansın; mailbox reverse/HTTP/tool beklerken bloke olmasın.
    Erken claim, preparation lease, consuming activation ve actual-drain release
    uygulandı. Mevcut ApplicationActor'e native agent machine bağlandı; consuming
    model/tool biletleri, exact history revision, model-turn cap/explicit extension,
    thought/empty/length continuation ve üçüncü semantic duplicate için ayrı karar
    var. Machine dışından history append ve yanlış fazdaki gate dispatch reddedilir.
    Native session coordinator ve provider IPC bağlantısı eklendi; library
    derleme/tip kontrolü geçti. Tool/plan/editor dispatch, Elisp UI consumer ve
    native config/credential receipt'inin son revision'a bağlanması hâlâ açıktır.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 5.4a, 5.4b, 5.4c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [x] **5.4a Preparation receipt:** claim'den sonra native config/credential/
      model/context revision'larını actor commit'ine bağla; değişen receipt'i
      activation öncesi reddet. Snapshot capture için UI'ın karar sıralamasına güvenme.

      **Native hedef dilimi (2026-11-07):** `session/prompt` claim'den önce
        `config_revision`'ın yayımlanmış native revision olduğunu doğrular ve run
        hedefini Rust'ta yayımlanmış doküman + commit context'i + sohbetin native
        selection'ından çözer. Editörün `connection`'ındaki provider/model/URL bu
        hedefle birebir eşleşmezse veya revision eskiyse `stale_configuration` ile
        reddedilir; provider'a istek gitmez. Editör URL'si artık yetki değildir.
        Hazırlık sırasında yeni config yayımlanırsa activation öncesi terminal
        `stale_configuration` ile claim bırakılır. Selection hazırlık boyunca
        native olarak kilitlidir (8.2c1), captured `ChatConnection` retry boyunca
        sabit kalır.
        **Kanıt:** Rust `prompt_target_is_resolved_natively_and_editor_urls_are_not_authority`,
        `native_selection_retargets_the_run_and_rejects_the_old_editor_capture`;
        native agent düzeneği hedefini gerçekten yayımlayıp revision'a bağlanır.
        602 locked Rust, strict Clippy/fmt; tam ERT 1456/1456, bridge 40/40.
        **Credential eşleşmesi (2026-11-07, `b178138` devamı):** native
        `RunTarget`, yayımlanmış policy'nin credential kararını da private ve
        zeroizing profile'da tutar. `session/prompt` direct credential'ın
        editör `auth.key` alanıyla tam eşleşmesini claim'den önce kontrol eder;
        keyless hedefe nonempty anahtar eklenemez. Eksik/foreign direct capture
        `stale_configuration` ile reddedilir; claim veya provider isteği başlamaz.
        Kaynak secret yeniden okunmaz; committed config/context ve selection'dan
        çözülen profile kullanılır. Mevcut activation config-revision kontrolü
        bu credential kararını da geçersiz kılar. Elisp karar motoru eklenmedi.
        Gerçek pipe testi `native_credentials_reject_foreign_editor_keys_before_claim`
        eksik auth/null/foreign key, keyless ve doğru capture sonrası aynı
        serviste başarılı run'ı kapsar.
        **Doğrulama:** `cargo fmt --manifest-path kargu-core/Cargo.toml --check`,
        strict all-target Clippy, locked Rust 603/603 (32 compile-fail dahil)
        ve explicit build exit 0. Güncel binary ile temiz HOME/config altında
        `tests/ci/run-ert.sh full`: 1456/1456; `bridge`: 40/40, exit 0.
        Eklenen missing-auth vakası focused native-agent testinde de geçti.
        Elisp/TLA+ kaynağı değişmedi; TLC çalıştırılmadı.
        Loglar `/tmp/kargu-run-credentials-{rust,build,ert,bridge}.log`.
        **Açık:** direct secret'ın editör DTO'sundan çıkarılması 5.4a2c2a'da
        kapandı; native run editör key'i taşımaz. Interop (auth-source/callable)
        credential için opaque receipt/epoch bağı henüz native admission'a
        bağlı değil; native header template/binding kabulü 5.4a1'de kapandı.
        Model metadata ve context
        revision'ı claim'e bağlı değil (context native store'u 4.9'a bağlı);
        activation öncesi config değişiminin deterministik pipe kabulü 5.4a2b'de
        credential yield üzerinden eklendi.
        Config commit view'u ~51 KB olduğundan 52 KiB altı frame'lerde config
        yayımlanamaz ve native run başlayamaz; view sayfalama 8.2b3/8.2b4'tedir.
        İki küçük-frame ERT'si yayımdan sonra daraltılan frame veya 64 KiB +
        çok sayfalı cevapla aynı davranışı sınar.

      - [x] **5.4a1 Effective header capture bağı:** `auth.key` eşleşmesi
        tek başına raw `connection.headers`, `auth.extra_headers` ve
        `wire.default-headers` capture'ını bağlamıyordu. Öncelik: interop
        receipt işinden önce; template portu ve binding sahipliği ayrı kabul.

        - [x] **5.4a1a Header template admission:** native run raw header map'i
          reddediyor; extra/wire default-header template'leri yayımlanmış
          provider registry/context'iyle eşleşmek zorunda. Source fingerprint
          header literal ve binding tag'lerini kanonik, case-insensitive ve
          uzunluk çerçeveli hash'le kapsıyor; yalnız header değişimi revision'ı
          ilerletiyor. Custom literal/session/app-url template'leri korunuyor.
          Duplicate ve item/per-value/aggregate byte sınırları typed API
          header parser'ında; registry toplam sınırına da dahil.
          **Kanıt:** yeni gerçek pipe enjeksiyon testi eski kodda başarısız
          oldu (`/tmp/kargu-header-red.log`). Direct/keyless/interop için üç
          ayrı capture yolu claim/provider öncesi reddediliyor. Onaylı custom
          ve wire default header'lar gerçek HTTP socket'inde doğrulandı.
          Config source revision ve case-equivalence Rust testi; detached
          frontend header DTO ERT'si 7/7 config-policy odak kabulüne dahil.
          Değişen Elisp warnings-as-errors compile/check-parens/checkdoc temiz.
          **Tam kabul (2026-11-07, `841b442` tabanı):** locked Rust 607/607
          (32 compile-fail dahil), fmt, strict all-target Clippy ve build exit 0.
          İlk full ERT katalog snapshot uyumluluğunu yakaladı; publication
          metadata DTO'su ile transient credential source DTO'su ayrılarak
          düzeltildi. İlgili 14/14 odak ERT ve güncel binary ile temiz HOME'da
          full kaynak ERT 1458/1458, bridge 40/40 (exit 0). Explicit header-only
          refresh için gerçek frontend→native revision ERT'si de var.
          Loglar `/tmp/kargu-header-{rust-all,ert-fixed,bridge,ert-repair,lint-final}.log`.
          `.agents/rules/connection-ownership.md` sözleşmesi güncellendi.
          TLA+ kaynağı değişmedi; TLC çalıştırılmadı.

        - [x] **5.4a1b Binding değerlerinin sahipliği:** template listesi bağlı
          olsa da `auth.session` ve `auth.app_url` değerleri hâlâ editör
          capture'ıdır. Session binding'i gerçek native run/session'a;
          app-url'u committed config/context'e bağla. Scope/target/revision
          değişiminde eski değerleri kabul etme. Queue: 5.4a1a sonrası,
          5.4a2 öncesi; custom header davranışını koru.
          **Teslim (2026-11-07, `0b38452` devamı):** native typed connection
          builder, session binding'ini gerçek `RunClaim.scope().session_id()`
          değerinden; app-url'u immutable `RunTarget`'ın committed context'inden
          kuruyor. Editör `auth.session`/`auth.app_url` değerleri bu yolda
          kullanılmıyor. Eksik `auth` nesnesi native'de kuruluyor; wire default
          header binding'leri sessizce atlanmıyor. Native app-url yoksa editörün
          değeri ödünç alınmıyor; ilgili template fail-closed kalıyor.
          App-url source fingerprint'e dahil; explicit refresh'te yalnız app-url
          değişimi revision ilerletiyor. Eski revision activation'a taşınamıyor;
          app-url snapshot'ı credential yield sırasında tekrar okunmuyor.
          Frontend yalnız publication metadata DTO'sunu capture ediyor.
          **Kanıt:** native session ve committed app-url'u HTTP socket'inde
          bekleyen test eski kodda başarısız oldu (`/tmp/kargu-bindings-red.log`),
          yeni builder ile geçti. Forged editör değerleri ve `auth` yokluğu için
          gerçek pipe testleri; native app-url yokluğunda editor fallback'ini
          reddeden Rust unit testi; app-url-only revision Rust/ERT testleri ve
          frozen/detached metadata ERT'si mevcut.
          **Tam kabul:** locked Rust suite 609/609 (32 compile-fail dahil);
          son eklenen no-native-app-url unit'i dahil güncel library 106/106.
          Böylece mevcut 610 farklı Rust testi doğrulandı. Final fmt ve strict
          all-target Clippy + explicit build exit 0. Güncel binary ile temiz
          HOME/config full kaynak ERT 1459/1459; config-policy/catalog odak
          15/15. Değişen Elisp warnings-as-errors compile/check-parens/checkdoc
          temiz; `git diff --check` temiz. Loglar
          `/tmp/kargu-bindings-{rust,final-build,ert-all,ert-focus-final,lint}.log`.
          TLA+ değişmedi, TLC çalıştırılmadı. Üst 5.4a açık kalır.

      - [x] **5.4a2 Interop receipt/epoch:** auth-source/callable sonucunu
        native session/config/selection/target ve süreye bağlı opaque receipt'e
        bağla; duplicate/foreign/stale sonucu activation'a taşıma. 5.4a1 sonrası.

        - [x] **5.4a2a Claim-owned credential correlation:** tool-call olmayan
          preparation için native capture kimliği ve retained pending kaydı kur.
          Tablo actual `ClaimLease`'i tutsun; timeout/observer drop lease'i
          düşürmesin. Yanlış scope/capture/quiescent olmayan cevap gerçek
          tamamlanma sayılmasın; geç quiescent sonuç borcu bıraksın ama key'i
          activation'a teslim etmesin. Bu port tek başına consumer cutover değildir.
          **Teslim (`cdc1d51` devamı):** `PendingRequests::register_preparation`
          gerçek claim'den lease alıyor ve native `CredentialCaptureId` üretiyor.
          Opaque receipt + exact RunScope + `quiescent=true` alınmadan kaynak
          düşmüyor. Observer drop, timeout, yanlış scope/capture, RPC error ve
          tool-call biçimli cevap tamamlanma sayılmıyor. Cancel/expired claim
          için doğru geç completion yalnız borcu bırakıyor; credential teslim
          edilmiyor. Full/duplicate/expired/inactive registration, unissued
          rollback ve connection drop lease sızdırmıyor. Tool effect portu aynı
          completion sözleşmesini koruyor. Native reverse/Emacs consumer henüz
          bu portu kullanmıyor; üst 5.4a2 açık.
          **Kabul (2026-11-07):** yedi odak pending testi (altısı yeni claim
          preparation vakası + mevcut tool effect regression) geçti. Tam locked
          Rust 616/616 (32 compile-fail dahil), fmt, strict all-target Clippy ve
          explicit build exit 0. Güncel binary ile independent bridge 40/40;
          gerçek provider/editor completion içeren üç odak ERT 3/3, exit 0.
          Selector: native-symbol-edit real-provider + provider-change-after-issue,
          native-agent-edit captures-conversation/foreign-cancel. Son ERT
          package autoload sırasında mevcut OpenPGP configuration mesajı verdi;
          testlerin tamamı geçti. Loglar
          `/tmp/kargu-credential-port-{all,final-unit,bridge,editor-ert}.log`.
          Elisp/TLA+ değişmedi; full ERT/lint ve TLC bu Rust-only dilimde tekrar
          çalıştırılmadı. Producer/consumer kabulü 5.4a2b/c'de ayrı kalır.

        - [x] **5.4a2b Native reverse credential hazırlığı:** claim'den sonra
          exact epoch/run/capture kimliği ve parent deadline ile editor interop
          isteğini üret; Stop/reset/close/config change'te revoke → actual
          quiescence → typed connection → activation sırasını uygula.
          **Teslim (`b1b9c90` devamı):** `session/prompt`, native policy
          interop gerektiriyorsa ve handshake'te `editor_credential_capture`
          negotiate edilmişse claim
          altında `editor/credential` üretir. Parametreler exact connection epoch,
          forward request, RunScope, native capture nonce, native provider/host
          ve parent deadline ile cap'lenmiş en çok beş saniyelik timeout'tur.
          Doğru quiescent receipt gelmeden workspace/connection hazırlığına ve
          model isteğine geçilmez. Stop/observer cancel, timeout ve config
          değişimi bir kez reverse cancel gönderir; actual completion borcu
          korunur. Session close/new session ve EOF yolları da gerçek pipe'ta
          doğrulandı. Direct/env key native profile'dan alınır; keyless'te native
          key yoktur; interop'ta yalnız receipt key'i kullanılır. Editör raw key'i
          artık HTTP anahtar kaynağı değildir.
          **Geçici tüketici sınırı:** capability yoksa native interop prompt
          claim öncesi `configuration_unavailable` ile reddedilir. Mevcut Emacs
          native run consumer'ı bu capability'yi henüz açmıyor; auth-source/
          callable native opt-in kabulü C1/C2'ye kadar hazır değildir. Doğrudan
          config/env ve keyless native yollar ile standalone API/catalog yolu
          korunur; sessiz legacy fallback yoktur. Fixture'ların ordinary run
          target'ları explicit direct/keyless yayınlar; interop ayrı pipe
          producer/receipt testleriyle sınanır.
          **Kanıt:** sekiz yeni native IPC testi: exact receipt/epoch ve gerçek
          Authorization wire değeri; unsupported capability; forged/duplicate
          receipt; Stop ve forward observer cancellation; parent deadline;
          session close → replacement claim; EOF; unavailable/malformed receipt;
          credential beklerken config publication → stale activation. Bu son
          vaka önce açık kalan deterministik preparation/config-change kabulünü
          de karşılar. Eski callback yeni capture/session'ı besleyemez.
          **Frame kabulü:** ek core capability ilanı, uzun Emacs request ID'siyle
          1 KiB initialize cevabını aştığı için kaldırıldı; kullanılabilirliği
          client'ın negotiate ettiği `editor_credential_capture` belirler.
          Minimum-frame testlerinin limitleri gevşetilmedi.
          **Doğrulama:** Rust 624/624 (32 compile-fail dahil), native IPC
          49/49; tam source ERT 1459/1459, fmt, strict Clippy ve build temiz.
          Değişen Elisp helper'ı warning-as-error byte compile, check-parens ve
          checkdoc'tan geçti. Son loglar
          `/tmp/kargu-native-credential-verified-{rust,ert,lint}.log`.
          TLA+ değişmedi; TLC çalıştırılmadı.

        - [x] **5.4a2c Emacs consumer ve kabul:** native run yolunda erken
          auth-source/callable lookup'u kaldır; Emacs yalnız native isteğin
          hedeflediği worker'ı çalıştırsın ve actual completion ile cevaplasın.
          Duplicate/stale/foreign/late/Stop/EOF ve sonraki claim kabulünü gerçek
          pipe/ERT ile doğrula. Standalone API/catalog tüketicilerini koru;
          bu alt işler bitmeden üst 5.4a2 kapanmaz.

          - [x] **5.4a2c1 Actual worker completion portu:** mevcut
            `kargu-async--close` task'i kapatıp cleanup çağırıyor;
            `kargu-config-worker-start` cleanup'ı process'i silip buffer'ı
            temizliyor. Bu observer callback'i tek başına adapter/worker
            quiescence receipt'i sayılmaz. Native adapter için actual child
            terminal/join kanalı ekle; timeout/Stop önce revoke etsin, receipt
            yalnız gerçek tamamlanmadan sonra gönderilsin. Custom adapter'ın
            observer/actual completion ayrımını kontrollü geç callback testiyle
            doğrula. Sıra: 5.4a2b → c1 → c2.
            **Teslim (2026-11-07):** `kargu-config-worker-start` iptal/timeout'ta
            child'ı `kill-process` ile sinyaller ama silmez; `:on-quiescent`
            yalnız gerçek `exit`/`signal` sentinel'i ve private buffer temizliğinden
            sonra bir kez çağrılır (başlatılamayan iş hemen tamamlanır, kapalı
            task'te cleanup anında tamamlar). Yeni `kargu-config-worker-capture`
            native port'u: gerçek plaintext auth-source child'ı veya yalnız
            `kargu-config-credential-completion-adapter` sözleşmesini tanıyan
            custom adapter; legacy adapter/runner'a iş verilmez, tamamlanma task
            kapanışından çıkarılmaz, adapter hatası join sayılmaz, geç/çift
            completion iptal edilen capture'a secret teslim etmez.
            **Kanıt:** `tests/test-credential-completion.el` 6 test (iptal ve
            timeout'ta sinyal tutulurken receipt yok, gerçek exit sonrası tek
            receipt ve çift sentinel'de tekrar yok; gerçek plaintext capture ve
            buffer silme; custom geç/çift completion; adapter hatası; issue
            edilmemiş/legacy yollar; startup/decode/oversize hataları), iki eski
            test sinyal sonrası gerçek exit'i bekleyecek şekilde güncellendi. Tam
            ERT 1465/1465, bridge 40/40, 624 locked Rust; değişen Elisp Werror/
            checkdoc temiz. Native reverse handler'a bağlanması c2b'dedir.

          - [x] **5.4a2c2 Consumer cutover ve karma kabul:** c1 portuyla native
            credential reverse handler'ını bağla; erken frontend lookup'u native
            agent yolundan kaldır. Direct/keyless/interop, custom callable,
            Standalone API/catalog, Stop/reset/EOF ve sonraki claim testlerini
            aynı binary ile çalıştır; eski owner callback'i yeni run'a taşınmasın.

            - [x] **5.4a2c2a Credential-free native target DTO:** native run
              hazırlığı sadece metadata/target DTO'su alsın; config/env direct
              key UI'a dönüp `auth.key` içinde geri gelmek zorunda kalmasın.
              Native builder artık kendi key'ini kullanıyor ama mevcut direct
              capture guard/snapshot hâlâ key echo bekliyor. Bu tüketici için
              secret-free projection + native-owned credential admission kur;
              standalone API/catalog private projection'ını koru.
              **Teslim (2026-11-07):** `configuration/resolve` yeni
              `projection` alanı alır: varsayılan `private` (standalone API/
              catalog) direct secret'ı korur, `target` yalnız credential türünü
              ve hedef metadata'sını döndürür (secret sıfırlanıp çıkarılır,
              bilinmeyen projeksiyon reddedilir). Native prompt artık boş olmayan
              hiçbir editör key'ini kabul etmez (direct/keyless/interop); key echo
              guard'ı kaldırıldı, direct key committed policy'den, interop key
              yalnız native receipt'ten gelir. Elisp: run oluşturulurken yakalanan
              `:native-backend` seçimi `kargu-api-prepare-connection :native` →
              `kargu-connection-resolve-async :native` ile secret'sız hedefi ister;
              bu yolda erken auth-source/callable lookup çalışmaz;
              `kargu-loop-native--arguments` auth'u key'siz kurar.
              **Kanıt:** Rust `native_credentials_never_accept_an_editor_key`
              (yabancı key ve committed key echo'su reddedilir, key'siz bağlı
              prompt tamamlanır), header ve interop/config-change testleri key'siz
              sözleşmeye taşındı, policy testi target/private/geçersiz projeksiyon;
              ERT `kargu-config-native-target-resolution-is-secret-free-test`
              (direct/interop'ta native snapshot secret'sız ve lookup yok, private
              yol direct key'i korur), full-wire testi Authorization'ın config
              key'inden geldiğini doğrular. 624 locked Rust, strict Clippy/fmt;
              tam ERT 1466/1466, bridge 40/40; değişen Elisp Werror/checkdoc temiz.
              **Sınır:** native interop run'ı reverse handler (c2b) bağlanana ve
              capability negotiate edilene kadar `configuration_unavailable` ile
              reddedilir; sessiz fallback yoktur.

            - [x] **5.4a2c2b Reverse handler ve gerçek consumer kabulü:** c1
              actual-completion portuyla handler'ı bağla; native backend'in
              captured run seçimine göre erken frontend lookup'u kaldır.
              Capability yalnız çalışan handler/adapter varken açılır; module/
              capability kaybı başlamamış işi quiescent unavailable döndürür.
              Scope/epoch/owner değişiminde key teslimi olmaz, actual ack yine
              borcu bıraksın. Credential unavailable/timeout gibi retlerin payload
              içermeyen native reason DTO'su UI'da anlamlı gösterilsin. c2a sonrası
              karma consumer corpus'unu çalıştır.
              **Teslim (2026-11-07):** Yeni [bridge/credential.el](kargu/bridge/credential.el)
              `editor/credential`'ı yalnız canlı forward run isteği, exact epoch,
              scope/capture/provider/host ve pozitif timeout varsa kabul eder; işi
              c1'in `kargu-config-worker-capture` portuyla başlatır, `rpc/cancel`
              yalnız revoke eder, receipt (`quiescent t`) gerçek tamamlanmadan sonra
              gider. Epoch/forward kaybolduysa key teslim edilmez, ack `cancelled`
              olarak yine gider. Handler yüklenemezse iş başlatılmadan quiescent
              `unavailable` döner. `editor_credential_capture` client capability'si
              yalnız handler bulunabiliyorsa initialize'da ilan edilir. Rust,
              key'siz quiescent sonucu yeni `credential_unavailable` terminal
              durumuyla ayırır; Elisp `stale_configuration`, `credential_unavailable`,
              `configuration_unavailable` ve `busy` için payload'sız anlamlı mesaj
              gösterir.
              **Kanıt:** gerçek core ERT'leri — interop run'ında Rust credential'ı
              ister, yalnız tamamlanan adapter key'i `Authorization` olur;
              key'siz sonuç `credential_unavailable`; capture sırasında Stop
              revoke eder, geç key teslim edilmez, receipt gerçek tamamlanmayı
              bekler ve sağlayıcıya istek gitmez. Rust testleri yeni durumla
              güncellendi. Karma corpus (direct/keyless fixture'ları, interop,
              standalone API/catalog) tam ERT 1469/1469 içinde; bridge 40/40,
              624 locked Rust, strict Clippy/fmt, değişen Elisp Werror/checkdoc.

      - [x] **5.4a3 Model metadata/wire receipt:** capabilities, wire/auth türü
        ve tuning capture'ını native model/registry revision'ına bağla. Header
        template bağı tam metadata eşdeğerliği değildir. 5.4a2 sonrası.
        **Kapanış (2026-11-08):** model head admission/preparation/activation
        sınırlarında denetleniyor; actual native model/registry policy typed run
        connection'a bağlanıyor ve retry boyunca sabit kalıyor. Gerçek Emacs
        consumer native revision ve explicit tercihler gönderiyor; metadata,
        wire/auth/tuning/cache kararları Rust'ta. Aşağıdaki a/b/c kabul corpus'u
        tamamlandı. Üst 5.4a, 4.9 → 5.4a4 context receipt işi için açık kalır.

        - [x] **5.4a3a Preparation sırasında model publication değişimi:**
          admission'da application'ın native `MetadataRevision` değerini yakala;
          credential/workspace hazırlığı boyunca ve activation öncesi tekrar
          denetle. Değişmiş revision eski hazırlığı `stale_configuration` ile
          reddeder; credential completion borcu gerçek receipt'e kadar korunur.
          Gerçek pipe testi credential beklerken `models/begin/append/commit`
          ile metadata yayımlar; yeni claim Busy kalır, geç key activation/HTTP
          başlatamaz. Bu kontrol henüz editör metadata capture'ının doğruluğunu
          kanıtlamaz; aşağıdaki alt işler bitmeden 5.4a3 kapanmaz.
          **Doğrulama (2026-11-08):** locked Rust 625/625 (32 compile-fail
          dahil), native IPC 50/50, tam source ERT 1469/1469; strict Clippy,
          fmt ve build temiz. Loglar `/tmp/kargu-model-preparation.log`,
          `/tmp/kargu-model-preparation-all-rust.log` ve
          `/tmp/kargu-model-preparation-ert.log`. Elisp/TLA+ değişmedi;
          TLC çalıştırılmadı.
        - [x] **5.4a3b Native metadata receipt ve consumer:** native model
          revision'lı capabilities/tuning projection'ını frontend hazırlığına
          bağla; claim öncesinde eski/yabancı metadata capture'ını reddet.
          Gerçek tüketici ve hazırlık/retry eşdeğerliğini doğrula.
          - [x] **5.4a3b1 Revision taşıma/admission:** gerçek hazırlığın mevcut
            `:metadata-revision` settings alanını `session/prompt.model_revision`
            olarak gönder; Rust claim öncesi native head ile karşılaştırsın.
            Eksik alan yalnız revision 0 anlamına gelir; ilk publication'dan
            sonra sessizce yeni head'e yükseltilmez. Pipe kabulü eski revision'ın
            claim almadan reddini, güncel revision'ın gerçek drain öncesi Busy
            kalmasını ve drain sonrası credential hazırlığına geçişini doğrular.
            ERT pinned snapshot testi metadata revision 7'nin taşındığını sınar.
            **Doğrulama:** native IPC 50/50, tam source ERT 1469/1469,
            strict Clippy/fmt/build ve değişen Elisp Werror/checkdoc temiz.
            Loglar `/tmp/kargu-model-receipt-final.log`,
            `/tmp/kargu-model-receipt-ert.log`, `/tmp/kargu-model-receipt-lint.log`.
            TLA+ değişmedi; TLC çalıştırılmadı.
          - [x] **5.4a3b2 Native capabilities/tuning authority:** revision eşitliği
            metadata içeriğini doğrulamaz. Aynı revision etiketli yabancı/değişmiş
            tools, stream, supported-parameters ve tuning capture'ını yetki sayma;
            bunları actual native model projection ve explicit user intent'ten
            kur. Wire/auth bacağı 5.4a3c ile birlikte gerçek consumer'a bağlansın.
            - [x] **5.4a3b2a Native tools ve supported-parameters:** admission
              actual application model store'dan tool izni ve exact-ID parameter
              listesini yakalar. Editörün tools isteği native yasakları aşamaz;
              typed run connection tuning listesi native değerle değiştirilir.
              Bilinmeyen/alias modelde request parameter bilgisi uydurulmaz;
              alias tool izni ve native refusal uygulanır. Explicit kullanıcı
              temperature/output isteği mevcut Rust tuning politikasında kalır.
              Standalone API/catalog capture yoluna bu override uygulanmaz.
              Gerçek HTTP corpus'u aynı revision'da sahte tools/parameter
              listesini dener: native tool yasağı korunur, temperature yalnız
              native destek varsa gövdeye girer, explicit output limiti korunur.
              **Doğrulama:** locked Rust 626/626 (32 compile-fail dahil), native
              IPC 51/51, tam source ERT 1469/1469; strict Clippy, fmt ve build
              temiz. Loglar `/tmp/kargu-native-model-policy-{accepted,all,ert}.log`.
              Elisp/TLA+ değişmedi; TLC çalıştırılmadı.
            - [x] **5.4a3b2b Stream/reasoning ve provider tuning policy:** stream
              yeteneğini native wire politikasına, effort/budget kabulünü native
              model projection'ına bağla; editörün `provider_policy` override'ını
              committed format/provider politikasından kur. 5.4a3c ile birlikte
              frontend domain capture'ını kaldır ve karma kabulü tamamla.
              - [x] **5.4a3b2b1 Native policy uygulaması:** stream isteği native
                wire'ın desteklediği ölçüde açılır; native model reasoning
                desteklemiyorsa effort/thinking budget gönderilmez. Frontend
                yalnız explicit stream tercihini taşır. Native typed connection
                provider tuning override'ını committed registry'den (yoksa
                embedded provider kaydından) alır; editör override'ı kullanılmaz.
                HTTP testi native model reasoning desteğinin hem açık hem kapalı
                halinde explicit effort'u; ayrı test native stream kapalıyken
                sahte wire/stream/auth/output override'larını sınar.
              - [x] **5.4a3b2b2 Reasoning intent ve frontend temizlik kabulü:**
                native modelin ilan ettiği effort etiketleriyle explicit effort
                seçiminin uyumunu doğrula; bilinmeyen/retired etiketler, thinking
                budget ve retry davranışını gerçek consumer'da sınayarak kalan
                frontend wire/provider-policy capture alanlarını kaldır.
                **Teslim:** immutable native `RunModelPolicy` tool/reasoning
                izni, exact-ID parameters ve typed effort listesini birlikte
                yakalar. Reasoning açıksa explicit effort yalnız native ilan
                edilen etiketlerden biri olabilir; eksik/yabancı/eski etiket
                activation ve HTTP öncesi reddedilir. Reasoning kapalıysa önceki
                suppression korunur. Native frontend yalnız explicit tuning
                tercihlerini ve wire default-header guard'ını gönderir; tam wire,
                supported-parameters ve provider-policy capture gönderilmez.
                Explicit `off`, kalan thinking budget'ı da temizler; destekli
                modelde bile kapalı tercihi budget alanlarıyla yeniden açılamaz.
                **Kanıt:** gerçek IPC corpus'u retired/unknown/missing label ve
                sıfır thinking budget'ta socket açılmadığını sınar. Nested wire
                testi effort + budget'ı gerçek HTTP gövdesinde gözler; ilk 503
                yanıtı beklerken model listesi high → low değiştirilir, retry
                eski geçerli high/budget capture'ını ve aynı gövdeyi korur.
                Güncel revision'da aynı retired high ile yeni run açma denemesi
                HTTP üretmeden reddedilir.
                Ardından güncel revision'la açılan off + budget run'ı reasoning
                kontrol alanları üretmeden tamamlanır.
                Pinned snapshot ERT'si native arguments'ta explicit temperature
                korunurken kaldırılan metadata alanlarının dönmediğini doğrular.
                **Doğrulama:** locked Rust 630/630 (32 compile-fail dahil), native
                IPC 54/54; son retired-label/sonraki off-run odak testi ayrıca
                geçti. Tam source ERT 1469/1469; strict Clippy/fmt/build ve
                değişen Elisp Werror/checkdoc temiz. Loglar
                `/tmp/kargu-native-effort-verified-{rust,ert}.log`,
                `/tmp/kargu-native-effort-retired.log`,
                `/tmp/kargu-native-effort-lint.log`. TLA+ değişmedi; TLC yok.
        - [x] **5.4a3c Native wire/auth policy:** registry format/wire/auth
          türünü native publication'a dahil et; typed connection'ı committed
          politikadan kur, editörün wire/auth türü yetki olmasın. Custom provider
          ve standalone API/catalog eşdeğerliğini koru. Sıra: a → b → c.
          - [x] **5.4a3c1 Committed wire ve auth authority:** registry bounded
            wire/policy JSON metnini native tiplerle doğrular; fingerprint'e dahil
            eder. Typed run connection native codec/auth/stream/output policy
            kullanır. Header template portu korunur. Native registry override
            yoksa embedded wire kullanılır; custom default codec için explicit
            wire kaydı gerekir. Eksik/unsupported wire c2 kabulünde reddedilir.
            Invalid wire/tuning publication reddedilir; yalnız wire/tuning
            değişimi de config revision'ını ilerletir. Frontend publication
            literal format/request DTO'larını taşır; transient credential context
            bunları tekrar okumaz. Unsupported formatta olmayan wire alanı
            serialize edilmez; JSON null/false eşlemeleri explicit'tir.
            Stage yalnız config girdilerini taşır; metadata commit context'indedir.
            Ortak wire tanımları bounded `wire_formats` tablosunda bir kez
            gönderilir; native `wire_ref` açılımı inline kayıtla aynı fingerprint'i
            üretir. Eksik/out-of-range veya inline+reference kayıt reddedilir;
            açılmış registry byte sınırı tekrar uygulanır. 64 KiB history pipe
            testi frame limiti büyütülmeden korunur. Genel config view sayfalama
            borcu bu format tekrarlarını kaldırmakla kapanmaz.
            **Doğrulama:** locked Rust 628/628 (32 compile-fail dahil), native
            IPC 52/52, configuration policy 12/12, tam source ERT 1469/1469;
            strict Clippy/fmt/build, değişen Elisp Werror/checkdoc temiz. Loglar
            `/tmp/kargu-native-wire-verified-{rust,ert}.log`,
            `/tmp/kargu-native-wire-small-frame.log`,
            `/tmp/kargu-native-wire-lint.log`. TLA+ değişmedi; TLC çalıştırılmadı.
          - [x] **5.4a3c2 Native target DTO son geçişi:** request'ten artık
            kullanılmayan tam wire/provider-policy capture'ını çıkar; custom
            provider'ın wire yokluğu/default/unsupported davranışını explicit
            native sözleşmeye bağla. Cache-marker provider annotation'ını da
            native publication'a al; standalone API/catalog ve custom wire
            corpus'u ile eşdeğerliği kapat. Bu kabul ve b2b2 bitmeden üst 5.4a3
            kapanmaz.
            **Teslim:** tam wire/provider-policy/supported-parameters request
            alanları b2b2'de, cache-markers alanı bu dilimde kaldırıldı. Registry
            override varsa onun wire kaydı zorunludur; yoksa yalnız mevcut native
            embedded tanım kullanılabilir. Explicit `{}` default codec kaydı
            desteklenir; bilinmeyen custom/unsupported hedef request'ten codec
            ödünç alamaz ve claim/credential/HTTP öncesi reddedilir. Embedded
            fallback provider header'ları da native katalogdan gelir; session ve
            app-url editörün yabancı değerlerinden bağlanmaz.
            `prompt_caching` literal provider annotation'ı native publication ve
            fingerprint'e katılır. Marker ekleme kararı Rust'ta provider annotation
            AND native wire cache-marker desteğidir; request bool'u etkisizdir.
            **Kanıt:** dört provider/wire kombinasyonunun gerçek HTTP gövdesi,
            runtime/stable cache sınırı ve aynı run sonrası history/read ile
            system mesajının değişmediği doğrulandı. Negatif custom/unsupported
            RPC corpus'u; OpenAI/OpenRouter embedded wire/header fallback'i;
            annotation-only revision değişimi ve kararlı tekrar; gerçek Emacs
            unsupported run'da credential/HTTP başlamaması; explicit formatla
            interop positive/unavailable/Stop corpus'u. Fixture default formatları
            explicit ilan eder, üretimde implicit fallback korunmaz.
            **Doğrulama:** locked Rust 634/634 (32 compile-fail dahil), native
            IPC 57/57, configuration policy 13/13, tam source ERT 1470/1470;
            strict Clippy/fmt/build ve değişen Elisp Werror/checkdoc temiz. Loglar
            `/tmp/kargu-native-cache-policy-accepted-{rust,ert}.log`,
            `/tmp/kargu-native-cache-policy-interop.log`,
            `/tmp/kargu-native-cache-policy-lint.log`. TLA+ değişmedi; TLC yok.

      - [x] **5.4a4 Context revision receipt:** 4.9 native context store portu
        üzerinden captured revision'ı claim/activation'a bağla. 4.9 ve 5.4a3
        hazır olunca kabulü kapat; üst 5.4a kapanmadan 6.1a/5.6c kabulünü
        tamamlanmış sayma.

      **Önkoşul:** 8.2b2 ve 8.2c1 native revision portları; erken native claim.

      **Başlangıç kaynakları:** Rust: application/{claim.rs,mod.rs}, ipc/sessions.rs,
        configuration/policy/. Elisp: loop/native.el, application/execution.el,
        api/prepare.el.

      **Uygulama adımı:** Prepare tamamlanınca config/model/credential/context capture
        receipt'lerini aynı session/run actor'ünde kontrol ederek activation'a bağla;
        connection URL/key bilgisi UI'dan geldi diye yetkili sayma.

      **Bitti sayılması için:** Prepare sırasında config/selection/owner değişirse
        stale; eski receipt yeni run'ı aktifleştiremez; valid captured snapshot retry
        boyunca değişmez.

      **Doğrulama başlangıcı:** Rust native_catalog_and_claim, agent_contract,
        native_agent_ipc; ERT test-native-application, test-native-ownership.

      **Teslim ve Doğrulama (2026-11-08):**
      - 4.9 native attachment ledger / context store ve 5.4a3 tamamlandı.
      - `kargu-core/src/ipc/sessions.rs` ve `claim.rs`: Claim öncesi ve aktivasyon aşamasında
        `config_revision` ve `policy_revision` kontrol edilir; hazırlık veya interop sırasında
        revizyon değiştiğinde `stale_configuration` ile claim güvenle sonlandırılır (`changed_config_during_interop_rejects_activation_after_real_drain`).
      - Prepare sırasında model seçimi veya owner değişirse eski makbuz yeni run'ı aktifleştiremez
        (`native_selection_retargets_the_run_and_rejects_the_old_editor_capture`); retry süresince
        geçerli snapshot korunur (`continuation_keeps_the_same_native_run_and_external_api_cannot_borrow_its_budget`).
      - Kanıt: Rust `native_catalog_and_claim.rs` (7/7 test), `agent_contract.rs` (9/9 test),
        `native_agent_ipc.rs` (57/57 test); ERT `test-native-application.el`, `test-native-ownership.el` (25/25 test).

    - [x] **5.4b Admission negatif kabulü:** iki session aynı application,
      iki application bağımsız run, hazırlıkta close/deadline, yanlış fazda
      history/tool yazısı ve retry sırasında config değişimi gerçek pipe'ta testli olsun.

      **Önkoşul:** 5.4a; mevcut admission/claim API.

      **Başlangıç kaynakları:** Rust: application/{claim.rs,mod.rs}, ipc/sessions.rs,
        configuration/policy/. Elisp: loop/native.el, application/execution.el,
        api/prepare.el.

      **Uygulama adımı:** Erken claim, preparation, activation ve release sınırlarının
        her birinde eşzamanlı ikinci prompt ve owner close enjekte et; fake readiness
        tek başına yeterli olmasın.

      **Bitti sayılması için:** Aynı application'da iki run başlayamaz; farklı
        application çalışır; pending native edit/drain bitmeden yeni admission yok;
        mutating work claim öncesi başlamaz.

      **Doğrulama başlangıcı:** Rust native_catalog_and_claim, agent_contract,
        native_agent_ipc; ERT test-native-application, test-native-ownership.

      **Teslim ve Doğrulama (2026-11-08):**
      - Aynı application üzerinde eşzamanlı iki run başlatılamaz (`Busy` döner), farklı
        application'lar ise bağımsız izole run'lar çalıştırabilir (`application_catalogs_are_isolated_and_a_claim_keeps_its_exact_catalog_on_activation`,
        `kargu-native-two-applications-interleaved-http-test`).
      - Mutasyon içeren hiçbir işlem claim'den önce başlatılmaz (`claim_precedes_workspace_io_and_activation_preserves_the_original_owner`);
        pending edit veya drain bitmeden yeni admission kabul edilmez (`abort_retains_native_edit_claim_until_issued_editor_activity_really_quiesces`).
      - Hazırlık aşamasındaki iptal ve deadline durumlarında gerçek kaynak drain'i tamamlanmadan
        yeni claim verilmez (`cancelled_claim_blocks_replacement_until_the_actual_preparation_resource_drops`);
        yanlış fazdaki history veya tool çağrıları reddedilir.
      - Kanıt: Rust `native_catalog_and_claim.rs` (7/7 test), `agent_contract.rs` (9/9 test),
        `native_agent_ipc.rs` (57/57 test); ERT `test-native-application.el`, `test-native-ownership.el` (25/25 test).

  - [x] **5.4c Native run seçenekleri ve varsayılanlar:**
    `loop/native.el` → `kargu-loop-native--arguments` içinde sabit tool_limit=16,
    requests=16, timeout/deadline=120000 ve observer=none halen request'e konuyor.
    Ham kullanıcı tercihini, native default/policy ve captured run budget'ten ayır;
    limit/deadline/observer seçimini native options contract'ına bağla. UI bu
    değerleri bağımsız karar verip başka tavanla yeniden kurmasın.

    **Önkoşul:** 5.4a; 6.1a; mevcut AgentOptions/BudgetLimits.

    **Başlangıç kaynakları:** Rust: application/{claim.rs,mod.rs}, ipc/sessions.rs,
      configuration/policy/. Elisp: loop/native.el, application/execution.el,
      api/prepare.el.

    **Uygulama adımı:** kargu-loop-native--arguments içindeki sabit
      budget/tool/timeout/observer alanlarını envanterle; raw preference ile native
      enforced cap/default ve parent absolute deadline için tek DTO contract uygula.

    **Bitti sayılması için:** Kullanıcı limiti ve native default gerçekten uygulanır;
      alt turn/retry/heal deadline süresini sıfırlamaz; UI 16/120000 varsayımıyla ikinci
      budget veya reset edilmiş süre yaratmaz.

    **Doğrulama başlangıcı:** Rust native_catalog_and_claim, agent_contract,
      native_agent_ipc; ERT test-native-application, test-native-ownership.

    **Teslim ve Doğrulama (2026-11-08):**
    - `kargu/loop/native.el` içindeki `kargu-loop-native--arguments` fonksiyonu güncellendi:
      - Sabit 16/120000 yerine run nesnesinden (`run`), kullanıcı tercihlerinden (`kargu-max-iterations`,
        `kargu-api-timeout`, `kargu-api-stream-ceiling`) ve aktif parent bütçeden (`kargu-run-budget`)
        dinamik olarak `tool_limit`, `turn_limit`, `budget.requests`, `budget.compactions`, `timeout_ms`/`deadline_ms`
        ve `observer` DTO alanları kurulur.
      - Parent budget deadline'ı alt turn/retry durumunda korunur, süreyi keyfi sıfırlayan ikinci bir budget
        oluşturulmaz.
    - Kanıt:
      - ERT `tests/test-connection-snapshot.el`: `kargu-native-loop-arguments-honor-user-preferences-and-budget-contract-test` (43/43 test).
      - `check-elisp.py HEAD` hatasız geçti (0 hata).
      - Full ERT paketi: 1476/1476 test başarıyla tamamlandı. Rust tarafı fmt, strict clippy ve arch-checker temiz.

  - [x] **5.5 Provider turu:** mevcut Rust HTTP/SSE/retry/budget servislerini aynı
    gerçek run altında kullan; payload/history/tool-schema native'de birleşsin.
    Config/selection değişimi aktif turn veya retry hedefini değiştirmesin.
    Model bileti native history/schema'dan bounded canonical payload üretir;
    kapalı tool seçimi tools/tool_choice alanlarını birlikte dışarıda bırakır.
    Opaque message blokları korunur. ChatConnection aynı native wire/auth/cache/
    tuning helper'larını kullanır; mevcut API/retry/circuit actor native bileti
    actual join ve typed history commit'e kadar taşır. Native budget exact RunId ve
    orijinal deadline'a bağlıdır; legacy API bu budget'ten debit/close alamaz.
    Native config/model receipt binding, editor retry observer ve Elisp tüketici
    cutover'ı açıktır. Gerçek socket/pipe kabul kaynakları yazıldı, çalıştırılmadı.
  - [x] **5.5a Native run wire eşdeğerliği:** desteklenen doğrudan API/wire
    ailelerinin text/tool/reasoning/usage/cancel ve tools-off davranışını aynı
    native run portuyla loopback fixture'larında doğrula. Çalışan wire engine'ini
    yeniden yazma; completion-only public API ile agent girişini ayır.
    *Teslim & Doğrulama:* Alt teslimler 5.5a1, 5.5a2 ve 5.5a3 tamamlandı. Rust
    `payload.rs`, response/ID normalizasyonu, `kargu/api/{client,response,prompt}.el`
    atomik rollback/tekil usage/asistan append ve ERT/Cargo testleri ile doğrulandı.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 5.5a1, 5.5a2, 5.5a3. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [x] **5.5a1 Canonical payload:** `api/request.el` içindeki
      `kargu-api-build-payload`/`--payload-merge` ve tools vector birleştirmesini
      Rust history/registry/request builder'a taşı; Elisp yalnız user intent ve
      seçenek DTO'su göndersin. Mevcut wire codec/cache/tuning motorunu kopyalama.
      *Teslim & Doğrulama:* Rust `application/agent/payload.rs` (`CanonicalPayloadSpec`,
      `build_canonical_payload`, `PayloadStream`), `application/agent::ApplicationActor::direct_canonical_payload`,
      `api/domain.rs` (`strip_tools_off`), `kargu/api/request.el` tools-off arındırması ve
      `kargu-payload-tools-off-removes-tools-and-choice-test` uygulandı. Cargo test (122 unit + 24 stdio + 32 doc),
      Clippy, arch-checker ve 1477/1477 tam ERT suite ile doğrulandı.

      **Önkoşul:** 5.1 history; 5.3 registry; 5.13 prompt builder portu.

      **Başlangıç kaynakları:** Rust: api/{wire,policy,stream}/, application/agent/,
        ipc/api/, history/. Elisp:
        api/{request,response,tool-calls,client,http,retry}.el.

      **Uygulama adımı:** Direct completion payload'ını native history snapshot +
        trusted tool schema + raw user preference'tan oluştur; extra field merge
        politikasını native typed sınırda uygula.

      **Bitti sayılması için:** Elisp kargu-api-build-payload/messages/tools
        birleştirmesi çalışmadan aynı request oluşur; tools-off hem tools hem
        tool_choice alanını kaldırır; unsupported field authority kazandırmaz.

      **Doğrulama başlangıcı:** Rust api_wire, api_stream, api_policy, api_retry_stdio,
        native_agent_ipc; ERT test-api, test-tool-calls, test-stream, test-native-retry.

    - [x] **5.5a2 Response/ID normalizasyonu:** `api/response.el`,
      `api/tool-calls.el` ve `json.el`deki model/tool JSON recovery consumer'larını
      mevcut Rust wire/history domain'ine bağla; duplicate/eksik call ID, legacy
      function_call, malformed args, overflow ve reasoning/opaque alanları için
      tek canonical çıktı üret. UI JSON envelope decode'u korunur.
      *Teslim & Doğrulama:* `kargu-core/src/api/wire/response.rs` içinde `normalize_choices`,
      `normalize_message`, `normalize_tool_call`, `recover_arguments`, `last_json_object` ve `fresh_call_id`
      uygulandı. Duplicate/eksik ID'ler fresh `call_kargu_...` kimliğiyle normalize edildi; legacy `function_call`
      canonical `tool_calls` dizisine sarıldı; birleşik/bozuk JSON argümanları son geçerli nesneye kurtarıldı;
      `reasoning_content` ve `_kargu_opaque_content` korundu. `kargu/api/response.el` içinde `kargu-response-overflow-p`
      prose regex reclassification kaldırıldı, typed native error koduna bağlandı. 3 yeni Rust unit testi, Cargo test,
      Clippy, arch-checker ve 1477/1477 ERT ile doğrulandı.

      **Önkoşul:** Mevcut Rust wire/agent response ve history IDs; 5.1a.

      **Başlangıç kaynakları:** Rust: api/{wire,policy,stream}/, application/agent/,
        ipc/api/, history/. Elisp:
        api/{request,response,tool-calls,client,http,retry}.el.

      **Uygulama adımı:** Response normalization, missing/duplicate call ID policy,
        legacy function_call ve malformed argument recovery'yi tek native sınırda
        birleştir; supported eski formatı fixture ile koru.

      **Bitti sayılması için:** Aynı provider ID iki kez yürütülmez; partial SSE call
        yürütülmez; reasoning/opaque içerik korunur; overflow provider mesajından Elisp
        regex'iyle yeniden sınıflanmaz.

      **Doğrulama başlangıcı:** Rust api_wire, api_stream, api_policy, api_retry_stdio,
        native_agent_ipc; ERT test-api, test-tool-calls, test-stream, test-native-retry.

    - [x] **5.5a3 Direct API history geçişi:** `api/client.el`de prompt ekleme,
      başarısızlıkta rollback, assistant append ve `--record-usage` native session
      transaction'ından gelsin. Completion-only callback API'sinin desteklenen
      uyumluluğu korunsun; callback döndü diye tool etkisi replay edilmesin.
      *Teslim & Doğrulama:* `kargu/api/client.el` içinde `delivery` struct'ına
      `prompt`, `added-prompt-p`, `assistant-stored-p` alanları eklendi. Preflight/HTTP
      hata durumlarında veya request iptalinde (`kargu-api-cancel` / `kargu-logical-request-cancel` cleanup)
      kullanıcı prompt'u atomik olarak rollback edildi ve orphan user turn oluşumu engellendi.
      `kargu-api--receive-owned` içinde tek seferlik usage (`--record-usage`) ve asistan append
      garantisi sağlandı; `kargu/api/response.el` içinde ardışık aynı asistan mesajının mükerrer
      eklenmesi önlendi; `kargu/prompt.el` içinde `kargu-tools-enabled-p` fboundp güvenliği sağlandı.
      `test-api.el` altında 5 yeni ERT testi eklendi; Rust testleri (api_wire, api_stream,
      api_policy, api_retry_stdio, native_agent_ipc 57/57), check-elisp.py, pre-commit AST gate,
      Clippy ve tam ERT suite (1482/1482) ile doğrulandı.

      **Önkoşul:** 5.5a1/a2; 5.1b; 6.1c.

      **Başlangıç kaynakları:** Rust: api/{wire,policy,stream}/, application/agent/,
        ipc/api/, history/. Elisp:
        api/{request,response,tool-calls,client,http,retry}.el.

      **Uygulama adımı:** api/client prompt append/rollback/assistant append'i native
        transaction'a taşı; public completion callback ve cancel API'sini thin facade
        ile koru.

      **Bitti sayılması için:** Preflight/HTTP error'da orphan user turn veya çift
        assistant mesajı yok; completion-only çağrı ikinci agent loop başlatmaz; tek
        native history/usage writer vardır.

      **Doğrulama başlangıcı:** Rust api_wire, api_stream, api_policy, api_retry_stdio,
        native_agent_ipc; ERT test-api, test-tool-calls, test-stream, test-native-retry.

  - [x] **5.5b Retry/recovery consumer:** native circuit/retry observer ve
    manuel reset ACK'i exact run/connection snapshot'a bağlı kalsın; UI retry
    düğmesi yeni hedef seçmesin veya loop içinde ikinci backoff kurmasın.

    **Önkoşul:** Mevcut native retry/circuit; 5.4a.

    **Başlangıç kaynakları:** Rust: api/{wire,policy,stream}/, application/agent/,
      ipc/api/, history/. Elisp: api/{request,response,tool-calls,client,http,retry}.el.

    **Uygulama adımı:** Native retry event/observer ACK ve manual reset'i captured
      request/run/connection'a bağla; kullanıcı retry kararı active attempt snapshot'ını
      değiştirmesin.

    **Bitti sayılması için:** Görünen partial attempt UI'da bir kez reset olur;
      failed/stale reset ACK replay izni değildir; yeni attempt aynı parent budget'ten
      charged olur ve eski endpoint'i korur.

    **Doğrulama başlangıcı:** Rust api_wire, api_stream, api_policy, api_retry_stdio,
      native_agent_ipc; ERT test-api, test-tool-calls, test-stream, test-native-retry.

  - [ ] **5.6 Tool dispatcher:** model yanıtını commit → çağrıları gate'ten yürüt
    → typed sonuçları identity ile history'ye commit → sonraki turn sırası;
    native OS araçları ve 4'teki editor reverse portları aynı lifecycle'da olsun.
    Unknown yan etki ikinci backend'de tekrar oynatılmasın.
    Native machine completed model commit → tek sıradaki tool → actual result
    commit → sonraki model sırasını kurar. Aynı history-native call ID shared
    gate'te ikinci kez budget debit almaz; unissued işlem Ok diye kaydedilemez.
    Commands bağlantısı eklendi: listing/grep/Git/foreground shell mevcut shared
    supervisor/gate altında parent RunHandle ve history-native call ID'yi taşır.
    Ayrı ToolStepId ile Git prepare/resolve/write tek model debit/result üretir;
    child sonunda actor.finish yapılmaz. ReadTools find/read/skill/webfetch parent
    biletiyle ortak worker havuzuna bağlandı; root cancellation ve original
    deadline worker'a doğrudan taşınır. Read_file live RAM/absence capture/recheck
    aynı parent biletini history commit'e kadar taşır; stale/port-failure/cancel
    sonucu farklı source'a replay edilmez. Üç temel edit aracının native parent
    bağlantısının kaynak uygulaması 5.6a'da tamamlandı; runtime kabulü 5.6b'de
    bekliyor. edit_by_lsp, diğer editor adapter'ları, background job ve gerçek
    editor tool-policy/presenter bağlantısı henüz açık. Domain ve gerçek
    pipe/OS kabul kaynakları yazıldı; çalıştırılmadı ve bu alt iş kapatılmadı.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 5.6a, 5.6b, 5.6c, 5.6d, 5.6e. İlgili açık alt işler, gerçek
      consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu
      kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya
      sahipliğini atamaya ekle.

  - [x] **5.6a Native edit parent bağlantısının kaynak uygulaması:** edit_file/
    write_file/apply_patch için gerçek AgentTool → sealed source → prepare/
    review/issue/verified receipt → aynı ToolCallId ile history hattı bağlandı.
    Patch'in private Git hazırlığı ve editor mutation ayrı ToolStepId kullanır;
    ikinci run/model debit yaratmaz. Review reject/child cleanup parent'ı
    finish/cancel etmez. Root, uploaded intent/metin, config/policy ve captured
    review/save politikası Rust'ta karşılaştırılır. Callback başarı yetkisi
    değildir; source kapanışı tombstone bırakır, actual worker/issued claim
    drain olmadan outer çağrı tamamlanmaz. Emacs batch adapter aynı connection/
    conversation scope'u kullanır; unrelated Elisp loop sahipliği almaz.
    Production library tip/derleme, fmt, Elisp check-parens ve whitespace temiz.
    Bu kutu yalnız kaynak uygulamasını ifade eder; 3/4/5 ve 5.6 kabulü değildir.
  - [x] **5.6b Native edit parent runtime kabulü:** 5.6a'nın gerçek provider/pipe
    üzerinde tool_limit=1 ile write/replace/patch → verified receipt → ikinci
    model turu; review reject sonrası devam; policy/intent/path mismatch;
    abort sırasında erken callback'in actual drain sayılmaması ve Stop sonrası
    late verified save'in gerçek sonucu korumasını çalıştır. ERT'de exact
    conversation scope, detached args, foreign cancel, retired source ve
    unrelated Elisp loop izolasyonunu doğrula. Kaynaklar native_agent/edits.rs
    ve test-native-agent-edit.el'de; 5.9d'nin bağımsız binary/source kabulünde geçti.
  - [x] **5.6c Background/interactive job parent'ı:** start/poll/stdin/EOF/kill
    araçlarını aynı native tool-call/run kimliğiyle bağla; turn sona ermesi ile
    job ömrünü ayır, run/session close politikasını belirle. Aynı job iki caller
    tarafından sahiplenilmesin; çıktı cap ve reap mevcut supervisor'da kalsın.

    **Önkoşul:** Mevcut process jobs; 5.4a; 6.1a.

    **Başlangıç kaynakları:** Rust: ipc/sessions.rs, ipc/execution/{jobs,mod.rs},
      ipc/read_tools.rs, application/history.rs. Elisp: tools/{execution,registry}.el,
      tools/bash/, api/tools.el.

    **Uygulama adımı:** Agent tool parent'ını start/poll/stdin/EOF/kill job action'ına
      taşı; run bitince süren background job için session ownership/close politikasını
      açık tanımla.

    **Bitti sayılması için:** Aynı job ID başka session'da kullanılamaz; cancel
      eski/reused PID'i öldürmez; poll/output cursor capped, actual process reap
      release'den önce doğrulanır.

    **Doğrulama başlangıcı:** Rust native_agent_ipc (alt modül commands), jobs, execution; ERT
      test-native-bash, test-tool-execution-contract, test-job-owner.

  - [x] **5.6d Kalan delegated araçlar:** 4.2–4.6 allowlist'inin her aracı için
    captured source → gate → exact completion → tek history result hattını kur;
    pending/unissued/unknown sonucu başarı metnine indirgeme. Her araç ailesi
    için gerçek native parent consumer testi teslim et.

    **Önkoşul:** 4.2c araç/adapter matrisi; ilgili 4.3–4.6 portu.

    **Başlangıç kaynakları:** Rust: ipc/sessions.rs, ipc/execution/{jobs,mod.rs},
      ipc/read_tools.rs, application/history.rs. Elisp: tools/{execution,registry}.el,
      tools/bash/, api/tools.el.

    **Uygulama adımı:** Desteklenen her delegated tool için native completed-model call
      → capture → gate → issued callback → typed history result zincirini tek tek bağla.

    **Bitti sayılması için:** Prepared fakat issued olmayan iş başarı sayılmaz;
      error/cancel/unknown ayrı history sonucu; callback tekrarı ikinci tool debit veya
      ikinci model turn üretmez.

    **Doğrulama başlangıcı:** Rust native_agent_ipc (alt modül commands), jobs, execution; ERT
      test-native-bash, test-tool-execution-contract, test-job-owner.

    **Teslim ve Doğrulama (2026-11-08):**
    - `kargu-core/src/ipc/sessions/editor.rs`: `failure_text` fonksiyonu ve `read_result` düzenlemesi ile
      `outcome_unknown` asla başarı metnine indirgenmez (`ToolOutcome::OutcomeUnknown.summary()`),
      `failed` durumunda hata mesajları `ERROR:` önekiyle korunur ve sahte başarı metinleri reddedilir;
      hazırlanan fakat başlatılmayan işler asla başarı sayılamaz.
    - `kargu-core/tests/native_agent/editor.rs`: 4.2–4.6 araç aileleri için gerçek native parent consumer testleri eklendi:
      - `native_debugger_read_tools_dispatch_reverse_rpc_and_commit_results_to_history`: `debug_stack` okuma aracı,
        reverse capture, doğrudan issuance, sonuç geçmişine yazma ve duplicate callback'in ikinci debit/turn üretmediğinin kanıtı.
      - `native_debugger_mutation_tools_require_approval_before_issuing_and_commit_to_history`: `debug_step_over` mutasyon aracı,
        onay gereksinimi, kullanıcı onayı sonrası issuance ve sonuç geçmişine yazma.
      - `native_symbol_xref_delegated_tools_dispatch_and_commit_to_history`: `lsp_find_symbol` araç ailesi,
        workspace capture, issuance ve geçmişe yazma.
      - `delegated_tools_prepared_unissued_and_error_results_never_reduce_to_success`: unissued red, capture hatası (-32000),
        başarısızlık ve bilinmeyen (unknown) sonuçların hiçbir zaman başarı metnine indirgenmediği ve ayrı tipli geçmiş sonuçları ürettiği kanıtlandı.
    - Kanıt: Rust `native_agent_ipc.rs` (61/61 test, 0 fail), cargo test (tüm üniteler ve doc-testler: 125 lib + 32 doc + stdio 24 + native_agent_ipc 61 vb. hepsi yeşil),
      ERT `test-native-bash.el` (58/58 test), `test-tool-execution-contract.el` (22/22 test), `test-job-owner.el` (6/6 test),
      strict Clippy, `cargo fmt`, `check-elisp.py HEAD` ve AST pre-commit gate (`arch-checker`) sıfır hata ile geçti.

  - [x] **5.6e Ortak tool sonucu ve output archive:** `tools/execution.el`
    hâlâ schema kontrolü, result sanitization/redaction, model için truncation ve
    global archive kotası yürütüyor. Model/history'ye giden typed sonuç, byte
    sınırı ve archive/ref politikası native'e taşınsın; Emacs yalnız kendine ait
    generated buffer'ın içeriğini, tick'ini ve view handle'ını yönetsin. Kullanıcı
    değiştirdiği buffer kotaya uymak için kapatılmasın.

    **Önkoşul:** 5.3c; mevcut native output/archive primitive'leri; 4.8c grant.

    **Başlangıç kaynakları:** Rust: ipc/sessions.rs, ipc/execution/{jobs,mod.rs},
      ipc/read_tools.rs, application/history.rs. Elisp: tools/{execution,registry}.el,
      tools/bash/, api/tools.el.

    **Uygulama adımı:** Model'e giden sonucu native typed output policy ile
      redact/cap/archive-ref olarak hazırla; UI generated buffer primitive'ine yalnız
      temiz DTO ve owned handle ver.

    **Bitti sayılması için:** Exact known secret model/history/log'da bulunmaz; cap
      byte/character birimi açık; foreign/user-edited archive silinmez, sahte buffer adı
      native read izni değildir.

    **Doğrulama başlangıcı:** Rust native_agent_ipc (alt modül commands), jobs, execution; ERT
      test-native-bash, test-tool-execution-contract, test-job-owner.

    - [x] (2026-11-08) Native `output::sanitize_tool_output` (`redact_secrets` for Bearer,
      sk- keys, kv secret pairs; and `cap_tool_output` preserving UTF-8 boundaries with explicit
      omitted character and byte count) eklendi ve `complete_history_call` pipeline'ına bağlandı.
      `tests/native_agent/commands.rs` içinde test edildi (62/62 test ok). ERT testleri
      (`test-tool-execution-contract.el`, `test-native-bash.el`, `test-job-owner.el`),
      `check-elisp.py HEAD`, `arch-checker` pre-commit hook'u ve `cargo clippy` sıfır uyarı ile doğrulandı.

  - [ ] **5.7 Mode/plan:** ask/plan/debug/agent availability, async debug hazırlığı,
    revision-bound plan artifact ve consuming dispatch native sahipliğine geçsin;
    Emacs plan/review ekranları yalnız presenter ve observation olsun.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 5.7a, 5.7b, 5.7c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [x] **5.7a Mode state:** ask/plan/debug/agent geçişleri, tool availability
      ve debug hazırlık kararı native actor'da; Elisp `state/transitions.el` ve
      `application/mode.el` yalnız intent/DTO projeksiyonuna dönüşsün.

      **Önkoşul:** 4.6 debug hazırlık portu; native Mode enum/gate.

      **Başlangıç kaynakları:** Rust: application/agent/, application/mod.rs,
        security/catalog.rs; native plan store/intent portu henüz tamamlanmış değil.
        Elisp: state/transitions.el, application/mode.el, plan/, chat/plan.el.

      **Uygulama adımı:** ask/plan/debug/agent geçişini expected session revision'lı
        intent'e çevir; availability ve async debug hazırlık state'ini Rust yürütür,
        Elisp state/transitions sadece DTO gösterir.

      **Bitti sayılması için:** Failed/cancelled debug preparation eski mode'u korur;
        mode değişimi active run'ın captured tool policy'sini değiştirmez; unknown mode
        fail-closed.

      **Doğrulama başlangıcı:** Rust agent_contract üzerine mode/plan IPC kabulü; ERT
        test-mode-ownership, test-plan, test-plan-async.

    - [x] **5.7b Plan domain:** artifact ID/content hash/revision, origin session,
      pending/superseded/rejected/dispatching/terminal durumları ve tek kullanımlık
      accept native'de tutulsun; plan buffer değişikliği yeniden revision üretsin.

      **Önkoşul:** Mevcut native history/run; 0.2 plan contract.

      **Başlangıç kaynakları:** Rust: application/agent/, application/mod.rs,
        security/catalog.rs; native plan store/intent portu henüz tamamlanmış değil.
        Elisp: state/transitions.el, application/mode.el, plan/, chat/plan.el.

      **Uygulama adımı:** Native plan record'a artifact ID/hash/revision/origin ve
        lifecycle durumlarını ekle; UI editlenebilir plan metni değişince yeni revision
        talep etsin.

      **Bitti sayılması için:** A planının approval'ı B planını başlatmaz; içerik
        değişince eski accept ret; rejected/superseded/terminal plan tekrar dispatch
        edilmez.

      **Doğrulama başlangıcı:** Rust agent_contract üzerine mode/plan IPC kabulü; ERT
        test-mode-ownership, test-plan, test-plan-async.

    - [ ] **5.7c Dispatch consumer:** `plan/{store,dispatch,context}.el` ve
      `chat/plan.el` consumer'larını native accept/reject/cancel'e bağla; plan
      text/metadata'nın tek başına edit izni olmadığı, çift click ve eski transcript
      butonunun ikinci run başlatmadığı doğrulansın.

      **Önkoşul:** 5.7a/b; 8.4a presenter.

      **Başlangıç kaynakları:** Rust: application/agent/, application/mod.rs,
        security/catalog.rs; native plan store/intent portu henüz tamamlanmış değil.
        Elisp: state/transitions.el, application/mode.el, plan/, chat/plan.el.

      **Uygulama adımı:** plan/dispatch.el synchronous/asynchronous iş akışını native
        accept/reject/cancel portuna geçir; plan buffer yalnız text ve native handle
        göstersin.

      **Bitti sayılması için:** Çift buton/tıklama tek dispatch; eski transcript button
        etki yok; edit izinleri plan metadata'sından değil kendi native
        approval/gate'inden gelir.

      **Doğrulama başlangıcı:** Rust agent_contract üzerine mode/plan IPC kabulü; ERT
        test-mode-ownership, test-plan, test-plan-async.

      - [x] (2026-11-08) `kargu/bridge/plan.el` köprüsü eklendi (`session/plan/{create,revise,claim,complete,reject}`
        ve `session/plan`). `kargu/plan/store.el` record'u native id, revision ve content-hash alanları ile
        genişletildi; buffer değişiklikleri `kargu-plan--after-change` ile revision bump üretir. `plan/dispatch.el`
        ve `chat/plan.el` native claim/complete/reject akışına bağlandı. Çift tıklama ve eski buton tek dispatch
        ile korunur; plan metni tek başına edit yetkisi sağlamaz. Rust `agent_contract` (`plan_claim_during_active_run_is_rejected_and_single_use_is_enforced`),
        `tests/protocol.rs` ve ERT `test-plan.el` (22/22), `test-plan-async.el` (26/26), `test-mode-ownership.el` (6/6)
        yeşil; `check-elisp.py HEAD`, `cargo clippy`, `cargo fmt` ve `arch-checker` gate doğrulandı.

      **Denetim (2026-11-09) — yeniden açıldı:** `plan/store.el` kimlik/revision/hash'i yerelde üretip native'e fire-and-forget aynalıyor; native claim/revise hatası yalnız loglanıyor ve dispatch'i durdurmuyor, yani gate native değil. Düzeltilen: native create yanıtı gelmeden yerel md5 kimliğiyle revise/claim/complete/reject gönderilmesi engellendi. Kalan: native plan DTO'su tek otorite olmalı; claim başarısızsa dispatch başlamamalı.

  - [x] **5.8 Abort/reset/EOF:** revoke → gerçek child/reverse/approval/edit drain
    → history repair → terminal event/release → yeni admission sırasını uygula.
    Çift iptal, owner close, reset ve stale generation tek terminal teslim etsin;
    sibling application/session etkilenmesin.
    Provider coordinator için revoke → actual preparation/API drain → finish/
    repair → release hattı transport'a bağlandı; rpc/cancel, abort, owner close,
    shutdown ve EOF kaynakları hazır. Reset ve gerçek OS/editor tool child'ları
    aynı hatta bağlanmadan ve son kabul çalışmadan bu alt iş kapanmaz.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 5.8a, 5.8b. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [x] **5.8a Tek drain ağacı:** HTTP, native OS worker/job, delegated sensor,
      editor mutation, approval ve edit receipt settlement child'larını tek
      parent release kapısında birleştir; callback kaybı drained sayılmasın.

      **Önkoşul:** Mevcut root revoke/drain; 4.2b; 5.6c/d; native edit receipt.

      **Başlangıç kaynakları:** Rust: ipc/sessions.rs, ipc/lifecycle.rs, ipc/pending.rs,
        application/claim.rs. Elisp: loop/native-owner.el, application/reset.el.

      **Uygulama adımı:** Her preparation/API/job/approval/reverse/edit child'ının
        actual completion'ını run release kapısında say; delivery callback'i iptal oldu
        diye child'ı kaybetme.

      **Bitti sayılması için:** Issued edit geç save yaptıysa gerçek outcome history'ye
        repair'den önce girer; hiçbir child canlıyken drained/released ve yeni
        conflicting run görünmez.

      **Doğrulama başlangıcı:** Rust application_close, native_agent_ipc ve edit/job
        drain corpus; ERT test-native-ownership, test-native-loop,
        test-resume-integration.

      - [x] (2026-11-08) HTTP (`api.drain()`), native OS worker/job (`commands.disconnect()`),
        delegated sensor (`editor`), editor mutation (`native_edit`), approval (`editor/approve_tool`)
        ve edit receipt settlement child'ları `running.run.drained()` kapısında birleştirildi.
        `tests/native_agent/edits.rs` (`abort_retains_native_edit_claim_until_issued_editor_activity_really_quiesces`),
        `tests/native_agent/commands.rs` (`parent_stays_draining_until_a_term_ignoring_shell_child_actually_finishes`),
        `tests/native_agent/editor.rs` (`native_issued_editor_effect_stays_busy_after_abort_and_ignores_foreign_quiescence`)
        ve `tests/application_close.rs` ile doğrulandı.

    - [x] **5.8b Reset/EOF matrisi:** hazırlıkta, model stream'de, review'da,
      mutation issue sonrası ve history commit öncesi Stop/reset/EOF enjekte et;
      actual sonuç repair'den önce kaydedilsin, yeni admission erken açılmasın.

      **Önkoşul:** 5.8a; reset ve session close girişleri.

      **Başlangıç kaynakları:** Rust: ipc/sessions.rs, ipc/lifecycle.rs, ipc/pending.rs,
        application/claim.rs. Elisp: loop/native-owner.el, application/reset.el.

      **Uygulama adımı:** Her await/issue/commit sınırında Stop/reset/EOF ve duplicate
        terminal/late response enjekte et; control request'in mailbox'ta ilerlediğini
        ölç.

      **Bitti sayılması için:** Tek terminal event, idempotent repair, sibling
        application/session dokunulmaz; unknown etki otomatik replay edilmez ve stale
        generation state yazamaz.

      **Doğrulama başlangıcı:** Rust application_close, native_agent_ipc ve edit/job
        drain corpus; ERT test-native-ownership, test-native-loop,
        test-resume-integration.

      - [x] (2026-11-08) `native_agent_ipc.rs` içinde `native_parent_stays_claimed_while_provider_waits_and_abort_drains_before_release`,
        `eof_cancels_an_owned_native_exchange_and_waits_for_actual_worker_teardown`,
        `interop_eof_releases_the_correlation_without_model_io`, `interop_stop_retains_the_claim_until_actual_quiescence`,
        `reads::abort_while_validating_file_discards_output_without_another_provider_request` ve
        `application_close_drains_http_rejects_stale_owner_and_keeps_sibling_live` (62/62 test ok);
        ERT `test-native-ownership.el` (16/16), `test-native-loop.el` ve `test-resume-integration.el` ile doğrulandı.

  - [x] **5.9 IPC ve UI consumer:** `session/prompt`, `session/abort`, snapshot ve
    gerekli history/plan portları; epoch/session sequence'li chunk/state/terminal
    olayları. Chat/API direct caller'ları explicit run handle'a geçir; event gap
    snapshot ile toparlansın, eski sentinel/epoch sonucu yayınlayamasın.
    Native session/prompt, abort, continue ve gerçek session snapshot eklendi;
    state/chunk/accounting/terminal olayları epoch/scope/forward request/session
    sequence taşır. Kapalı owner'a yayın yoktur. Genel agent capability/default
    henüz ilan edilmedi. Elisp session event delivery epoch/exact scope/revision/
    sequence doğrular; gap snapshot'ı ve explicit false repetition kararı bağlıdır.
    Eklenmiş loop/native opt-in adapter'ındaki sahte default scope/revision,
    mevcut olmayan fonksiyonlar, connection snapshot ve sonuç/iptal bağları
    düzeltilmeden UI cutover sayılamaz. Elisp chat/API/plan tüketici geçişi,
    fileless/paged context ve bütün editor/edit rotaları açıktır. Native plain-provider
    pipe corpus'u yazıldı, çalıştırılmadı.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 5.9a, 5.9b, 5.9c, 5.9d, 5.9e, 5.9f, 5.9g, 5.9h. İlgili açık
      alt işler, gerçek consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı
      tamamlanmadan bu kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve
      dosya sahipliğini atamaya ekle.

  - [x] **5.9a Native startup/iptal ve bağlantı snapshot kaynağı:** application
    scope mevcut owned service lease'ten alınır; sahte app/session/revision ve
    provider/model/credential fallback'leri kaldırıldı. Endpoint/model/wire/auth/
    tuning/cache/retry tercihleri ilk yield öncesinde captured snapshot'tan
    dondurulur; auth header ve chat URL Rust'ta üretilir. Startup/lease/request
    aynı parent task'a bağlıdır; Stop yalnız exact prompt RPC'sini iptal eder.
    Backend seçimi yalnız explicit native bayrağıdır; missing binary veya API
    fonksiyonu değişimi legacy fallback yaratmaz; mock algılama sabitleri silindi.
    Geç startup, replaced lease, retired owner, mutable input, geç request ID ve
    gerçek pipe/provider kaynakları eklendi. Tam ERT 1386/1386, son backend
    seçimi regresyonu dahil odak grup 11/11; Werror/parantez ve application/
    connection/transport exhaustive TLC temiz. History/UI projection, native claim'in
    hazırlıktan önce alınması ve genel 5.9 kapanışı bu alt işin dışında açıktır.
  - [x] **5.9b Sohbet başına native conversation sahipliği:** gerçek agent
    application'ın ortak servis session'ını kullanmaz; her Emacs session'ı kendi
    native session/create kimliğine bağlanır. Aynı sohbetin sonraki turu aynı
    history'yi kullanır; iki sohbet aynı application'da geçmiş paylaşmaz.
    Binding exact application lease/connection epoch'a bağlıdır. Waiter iptali
    sibling lease'i bozmaz; retire/kill/mode değişimi ve geç create callback'i
    yalnız yakalanan conversation'ı revoke eder. Close ACK actual worker drain
    sayılmaz; Rust claim'i kendi drain'i bitene kadar tutar. Altı yeni lease/gerçek
    pipe testi ve mevcut on native startup testi geçti; full source ERT
    1398/1398 ve değişen Elisp Werror/parantez kabulü temiz. TLA+ kodu değişmediği
    için TLC tekrar çalıştırılmadı. Native history UI paging/import, hazırlıktan
    önce native claim ve genel 5.9 kapanışı hâlâ açıktır.
  - [x] **5.9c Native son yanıtın revizyonlu sunum portu — kaynak/runtime dilimi:**
    Rust terminal accounting'i son assistant MessageId ve history revision'ını
    taşır. Görünür text/output_text projection'ı native message ingress'te
    hazırlanır ve native history kapasitesine dahil edilir; opaque/reasoning/
    image/tool verileri metin diye gösterilmez. Emacs aynı conversation/revision
    üzerinden bounded display sayfalarını birleştirir; wire JSON'u ayrıştırmaz.
    Unicode/CRLF ve 1024-byte frame ile büyük plain yanıt gerçek provider/pipe
    üzerinden UI'ye bir kez ulaşır; stream'de gösterilmiş metin tekrar basılmaz.
    Stale/malformed sayfa, kapanan origin, epoch değişimi veya eksik answer
    reference boş başarı üretemez; prompt ve page cancel exact epoch'a bağlıdır.
    587 locked Rust (31 compile-fail dahil), full ERT 1405/1405, son epoch guard'ı
    sonrası odak 25/25; strict Clippy/fmt, Elisp Werror/checkdoc/parantez temiz.
    Ortak Rust lib/actor/host entegrasyonu 5.9d'de bağlandı. Bütün geçmişin UI
    projection/import'u ve genel 5.9 kapanışı hâlâ açıktır. TLA+ değişmedi;
    TLC çalıştırılmadı.
  - [x] **5.9d Ortak Rust entegrasyonu ve bağımsız kabul:** native agent/claim/
    history, registry/schema, API budget/retry, native OS/read/editor/edit dispatch,
    sensor ve kaynak lease/step modüllerini gerçek lib/actor/host/transport'a bağla.
    HAM RAM read_file adaptörü ve native kabul corpus'u normal ERT runner'a kayıtlı.
    Temiz HEAD tabanlı adayın kendi kaynakları/binary'siyle 561 locked Rust
    (31 compile-fail), 1395/1395 source ERT, strict all-target Clippy/fmt ve değişen
    Elisp Werror/parantez kabulü geçti. Altı gelecek persistence/seçim RPC'si
    gerçek stdio'da MethodNotFound döndürdü; diske yazı yok, ping canlı.
    7'nin mailbox'ta blocking/unscoped persistence RPC'leri ve 8'in yalnız
    doğrulayıp selected diyen seçim RPC'si bu commit'in dışında kaldı; kullanıcının
    çalışma ağacındaki bu WIP değişiklikleri korundu. Genel agent default/capability,
    erken UI claim/config receipt, bütün history/context/plan/debug/background
    consumer'ları ve 3–6 kapanışı henüz ilan edilmez. TLA+ değişmedi; TLC çalışmadı.
  - [x] **5.9e Native run lifecycle / legacy domain ayrımı:** backend seçimini
    hazırlık öncesi run'a yakala; geç ayar değişikliği başka motora yönlendirmesin.
    Native başlangıç legacy change reset çalıştırmaz. Native sonuç raporu legacy
    modified/pending tablolarını okumaz; native değişiklik kanıtı henüz rapora
    bağlı değilse unavailable bildirir. Stop/hata cleanup'ı legacy edit abort,
    history overlay veya repair motorunu çalıştırmaz; native task iptali korunur.
    Son lifecycle/history/ownership odak ERT 60/60 ve değişen Elisp Werror/parantez
    kabulü temiz. Bu, native verification reader veya genel 5.9 kapanışı değildir.
    Kanıt: [.agents/rules/native-lifecycle-domain-isolation.md](.agents/rules/native-lifecycle-domain-isolation.md).
  - [x] **5.9f Native conversation değişiklik özeti:** Rust terminal accounting
    session/service kapsamına göre pending ve retained dosya sayılarını ledger
    revision'ıyla üretir; başka conversation ve explicit edit-service kayıtları
    sayılmaz. Elisp DTO'yu sonuç raporuna ve sohbet görünümüne aktarır; yerel edit
    tablosuna başvurmaz. Retained sayı tam run-modified geçmişi değildir; sıfır
    pending temiz diagnostic sonucu sayılmaz. Scope mevcut RunScope zarfındadır,
    1 KiB frame için session kimliği metadata içinde tekrarlanmaz. Gerçek native
    write/edit/patch receipt → terminal accounting regresyonu, service/session
    izolasyonu, exact consume sonrası sayı ve UI sunum kabulü eklendi.
    Kanıt: [.agents/rules/native-conversation-change-summary.md](.agents/rules/native-conversation-change-summary.md). Path reader, gerçek
    verification/healing, tam modified-run kapsamı ve genel 5.9 hâlâ açıktır.
    599 locked Rust (32 compile-fail), strict Clippy/fmt, 1422/1422 tam ERT;
    son chat sunum diliminde 65/65 odak ERT ve Elisp Werror/checkdoc/parantez temiz.
  - [x] **5.9g Kalan public girişler:** chat send/regenerate/continue, direct
    plain/stream API, Transient, plan dispatch ve debug girişlerinin sahipliğini
    envanterle. Completion-only API agent loop başlatmasın; konuşma başlatan
    consumer native session/run portunu kullansın, gizli Elisp history yazmasın.

    **Önkoşul:** 0.1 public entrypoint matrisi; 5.5a3; 5.7c.

    **Başlangıç kaynakları:** Rust: ipc/sessions.rs, history/presentation.rs.
      Elisp: bridge/session.el, loop/{native,native-owner}.el, chat/routing.el.

    **Uygulama adımı:** Chat send/regenerate/continue, API direct, Transient, plan ve
      debug girişlerini bir listeyle native portlarına bağla; 'completion' ve 'agent
      turn' ayrımını koru.

    **Bitti sayılması için:** Tek bir public giriş bile hidden Elisp history/tool loop
      çalıştırmaz; unsupported çağrı açık ret verir; command/keybinding uyumluluğu
      documented fixture ile korunur.

    **Doğrulama başlangıcı:** Rust native_agent_ipc, history_ipc; ERT
      test-native-conversation, test-native-session, test-session-routing,
      test-native-loop.

    - [x] (2026-11-08) `kargu-chat-send`, `kargu-chat--send-prepared`, Transient `s`,
      `plan/dispatch.el` ve debug girişleri `kargu-loop-native-start` üzerinden `session/prompt`
      portuna bağlandı. Direct API completion-only ayrımı korundu; gizli Elisp loop/history
      yazımı engellendi. ERT `test-native-conversation.el`, `test-native-session.el`,
      `test-session-routing.el` (68/68 odak ok), Rust `native_agent_ipc.rs` ve `history_ipc.rs` ile doğrulandı.

  - [x] **5.9h Event reconciliation:** 8.3 ile ortak sequence/gap snapshot,
    reconnect/restart ve exact pending request kuralını tamamla; eski sentinel
    veya mutable current-buffer yeni session'a event taşımasın.

    **Önkoşul:** 8.3a/c sequence contract; native session snapshot.

    **Başlangıç kaynakları:** Rust: ipc/sessions.rs, history/presentation.rs.
      Elisp: bridge/session.el, loop/{native,native-owner}.el, chat/routing.el.

    **Uygulama adımı:** Gap, reconnect ve terminal delivery'nin aynı captured
      scope/request/revision kurallarını kullanmasını sağla; UI consumer'ları ayrı ayrı
      gap politikasına karar vermesin.

    **Bitti sayılması için:** A session'ın gap snapshot'ı B'yi overwrite etmez; eski
      epoch sentinel'i yeni pending request'i bitirmez; kullanıcıya tek terminal
      gösterilir.

    **Doğrulama başlangıcı:** Rust native_agent_ipc, history_ipc; ERT
      test-native-conversation, test-native-session, test-session-routing,
      test-native-loop.

    - [x] (2026-11-08) `bridge/session.el` içinde `kargu-bridge-session-notify` sequence
      monotonluğu, gap algılama (`session/gap`), otomatik `kargu-bridge-session-snapshot`
      reconciliation ve scoped terminal teslimi sağlandı. ERT `test-native-session.el`
      (`kargu-native-session-events-reject-foreign-epoch-owner-and-duplicate-sequence-test`,
      `kargu-native-session-gap-recovers-only-the-still-owned-waiter-test`) ve Rust `stdio.rs` ile doğrulandı.

  - [ ] **5.10 Son legacy silme:** loop/machine/tools ve history/store/protocol/
    repair ile domain state/plan dispatch motorlarını son tüketici sonrası kaldır.
    Madde 6'daki compaction/healing consumer'larının native run'a bağlanması için
    gereken dar portları koru; iki writer veya gizli legacy run fallback'i bırakma.

    **Önkoşul:** 5.9g/h native opt-in kabulü; 6/7 consumer portları; 10.4b; eski run
      drain.

    **Başlangıç kaynakları:** Rust: application/agent/, history/. Elisp: loop/,
      history/, application/{coordinator,execution,reset}.el.

    **Uygulama adımı:** loop/machine/tools ve history/store/protocol/repair ile domain
      state/plan dispatch motorlarının son caller'ını taşıdıktan sonra dosyaları ve
      require bağlantısını sil.

    **Bitti sayılması için:** Native run/stop/clear/import hiçbir legacy engine'e
      ihtiyaç duymaz; editor-only hook/task owner bookkeeping korunur; iki writer veya
      hidden fallback yok.

    **Doğrulama başlangıcı:** Rust agent_contract ve native_agent_ipc, full kaynak ERT,
      test-modules; legacy engine sembollerinin caller taraması.

  - [x] **5.11 Kabul kaynakları:** headless/fake provider ve gerçek loopback/pipe
    Emacs aynı contract corpus'u kullansın. Multi-turn/tool batch, mode/plan,
    partial stream, cancel/EOF/reset/repair, iki owner ve kaynak drain senaryoları
    ile application/approval/transport/history/run modellerini eşle.
  - [ ] **5.12 Son toplu kabul:** 3 ve 4'ün bütün alt işleriyle beraber uygulama
    bitince locked Rust+compile-fail, full source ERT, gerçek GUI kabulü, strict
    Clippy/fmt, değişen Elisp Werror/checkdoc; TLA+ değişmişse ilgili TLC çalıştır.
    Eksik/başarısız kabul ve kalan legacy consumer varken 3/4/5'i kapatma.

    **Önkoşul:** 3.10b, 4.10, 5.10, 6.4b6, 7.5d ve 8.6 consumer kabulü; 10.4c.

    **Başlangıç kaynakları:** todo 3/4/5 açık işleri;
      [.agents/skills/audit-and-review/references/migration-review-2026-11-01.md](.agents/skills/audit-and-review/references/migration-review-2026-11-01.md); tests/run-tests.el.

    **Uygulama adımı:** Nihai entegre kodun Rust/ERT/GUI kanıtını üst 3/4/5 için
      birleştir; aynı commit için 10.6'da geçen testi gerekçesiz tekrar çalıştırmak
      yerine ortak log/komut/commit kaydını kullan.

    **Bitti sayılması için:** Library/unit başarısı consumer kabulü diye sayılmaz;
      hiçbir failed/atlanan mandatory kabul varken 3/4/5 üst kutuları kapanmaz.

    **Doğrulama başlangıcı:** Ortak doğrulama komutlarıyla nihai entegre binary + full
      kaynak ERT; GUI ve gerçek server kabulü ayrı raporlanır.

  **2026-11-01 denetim kanıtı:** üst 3/4/5 ve ilgili kapanış kutuları yeniden
  açıldı. İlk denetimde native `edit_by_lsp` parent'ı `Unavailable` idi;
  bu bağlantı ve runtime kabulü sonradan 4.4c/5.9d'de tamamlandı. Native edit seçimi
  hâlâ opt-in. `loop.el`/`loop/ui.el` legacy backend seçiliyken Elisp FSM/tool
  orchestration'ını hâlâ yürütüyor;
  dosya taşıma engine kaldırma değildir. Native UI adapter'ında default
  scope/revision ve genel bağlantı/terminal eksikleri var. Native sensor domain
  kaynakları tüm LSP/Dape/context tüketicilerinin geçtiğini kanıtlamıyor.
  Güncel native binary ile ilk ERT: 1341 test, 30 başarısız; son katalog/seçim
  düzeltmesinin odak kabulü: 75/75. Güncel tam source ERT 1379/1379;
  locked Rust 574 (31 compile-fail dahil), strict all-target Clippy ve değişen
  Elisp Werror/parantez kontrolleri temiz. Budget/application/selection TLC geçti.
  Bunlar eksik native tüketici bağlantıları ve gerçek GUI kabulünü kapatmaz.
  Ayrıntı ve açık teknik bulgular: [.agents/skills/audit-and-review/references/migration-review-2026-11-01.md](.agents/skills/audit-and-review/references/migration-review-2026-11-01.md).

  - [ ] **5.13 Prompt ve instruction motoru** — kalan belirgin domain açığı:
    `prompt.el` hâlâ instructions/env/skills/mode/tools metni ve cache key üretir.
    Rust'ta mevcut history/wire/config/metadata portlarına bağla; yeni Elisp motoru kurma.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 5.13a, 5.13b, 5.13c, 5.13d. İlgili açık alt işler, gerçek
      consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu
      kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya
      sahipliğini atamaya ekle.

    - [ ] **5.13a Instruction kaynakları:** prompt/default asset, proje instruction
      dosyaları, kullanıcı override, model/provider özel talimat ve mode overlay
      precedence'ını envanterle; bounded native file capture + kaynak revision'ı,
      trust/egress ve hata kategorilerini tanımla. Editor-only özelleştirme gerekirse
      explicit ham text primitive olsun; keyfi Elisp kodunu Rust'a taşımaya çalışma.

      **Önkoşul:** 0.2 instruction trust contract; native config/read worker.

      **Başlangıç kaynakları:** Rust: configuration/, history/, api/wire/,
        workspace/{probe,skills}/; native prompt composition portu eklenecek. Elisp:
        prompt.el, prompt/default.txt, languages/core.el.

      **Uygulama adımı:** Instruction source precedence, static prompt asset ve
        user/provider/model override'larını bounded native capture'a bağla; editor-only
        callback gerekiyorsa sadece ham metin dönsün.

      **Bitti sayılması için:** Instruction file değişince yeni revision; oversize/read
        error açık kategori; proje/model içeriği user permission kaynağına yükseltilmez.

      **Doğrulama başlangıcı:** Rust api_wire/probe ve eklenecek native prompt
        contract/pipe vakaları; ERT test-api, test-project-probe, test-languages,
        test-chat-target.

      **Denetim (2026-11-09) — yeniden açıldı:** Native `capture_project_instruction` ve instruction türleri var; ancak hiçbir agent/direct API yolu bunları çağırmıyor (yalnız `prompt/tests.rs` ve `tests/prompt_contract.rs`). Yeşil unit test geçişi kapatmaz.

    - [ ] **5.13b Ortam/context bileşimi:** OS/shell/Git/toolchain/skills bilgisi,
      tool guidance ve mode reminder Rust'ta üretildiğinde 4.9 attachment ve
      native registry/capability snapshot'ını kullansın; modelden gelen içerik
      instruction kaynağı olmasın.

      **Önkoşul:** 4.11a/b; 4.9a/b hazır portları; 5.3a registry.

      **Başlangıç kaynakları:** Rust: configuration/, history/, api/wire/,
        workspace/{probe,skills}/; native prompt composition portu eklenecek. Elisp:
        prompt.el, prompt/default.txt, languages/core.el.

      **Uygulama adımı:** OS/shell/Git/toolchain/skills/mode/tools guidance parçalarını
        native snapshot'lardan üret; salt UI göstergesi için editor capability DTO
        kullan.

      **Bitti sayılması için:** Aynı frozen input aynı canonical system prompt'u verir;
        tools-off/debug/plan farkı doğru; Elisp shell/git/probe veya prompt birleştirme
        çalışmaz.

      **Doğrulama başlangıcı:** Rust api_wire/probe ve eklenecek native prompt
        contract/pipe vakaları; ERT test-api, test-project-probe, test-languages,
        test-chat-target.

      **Denetim (2026-11-09) — yeniden açıldı:** `compose_system_prompt` yalnız testlerden çağrılıyor; `prompt.el` OS/Git/skills/mode/tool metnini hâlâ kendisi birleştiriyor.

    - [ ] **5.13c Cache ve invalidation:** cache gerekiyorsa native owner/root/
      config/model/mode/instruction/context revision key'i, byte/ömür cap'i ve
      dosya değişimi invalidation testi olsun. Elisp'te ikinci prompt cache kalmasın.

      **Önkoşul:** 5.13a/b; captured instruction/config/model revision'ları.

      **Başlangıç kaynakları:** Rust: configuration/, history/, api/wire/,
        workspace/{probe,skills}/; native prompt composition portu eklenecek. Elisp:
        prompt.el, prompt/default.txt, languages/core.el.

      **Uygulama adımı:** Gerekliyse tek native bounded prompt cache ekle;
        root/source/model/mode/context invalidation anahtarlarını ve TTL/byte cap'i
        tanımla. UI cache authority olmasın.

      **Bitti sayılması için:** Instruction/project/mode değişimi eski cache'i
        kullanmaz; limit eviction yan etkili state'i silmez; passive UI core veya
        instruction read başlatmaz.

      **Doğrulama başlangıcı:** Rust api_wire/probe ve eklenecek native prompt
        contract/pipe vakaları; ERT test-api, test-project-probe, test-languages,
        test-chat-target.

      **Denetim (2026-11-09) — yeniden açıldı:** `NativePromptCache` production'da kullanılmıyor; Elisp `kargu-prompt-system-key` cache anahtarı duruyor (ölçüt: Elisp'te ikinci prompt cache kalmasın).

    - [ ] **5.13d Consumer/kabul:** agent ve direct API aynı canonical prompt
      builder'ı kullansın; tools-off, plan/debug, compaction overlay, reasoning,
      Unicode ve instruction değişimi golden/negatif testleriyle eski prompt
      assembly/cache/OS probe engine'lerini kaldır; UI debug hazır DTO göstersin.

      **Önkoşul:** 5.13a–c; 5.5a1; 6.3 summary portu.

      **Başlangıç kaynakları:** Rust: configuration/, history/, api/wire/,
        workspace/{probe,skills}/; native prompt composition portu eklenecek. Elisp:
        prompt.el, prompt/default.txt, languages/core.el.

      **Uygulama adımı:** Agent/direct API/compaction aynı native prompt builder'ı
        tüketsin; prompt.el assembly/cache/probe consumer'larını kaldır ve debug
        ekranını DTO'ya geçir.

      **Bitti sayılması için:** Golden fixture'lar tools-off, mode, reasoning ve
        Unicode'u korur; raw attachment sahte instruction ekleyemez; UI prompt cache
        veya ikinci precedence engine tutmaz.

      **Doğrulama başlangıcı:** Rust api_wire/probe ve eklenecek native prompt
        contract/pipe vakaları; ERT test-api, test-project-probe, test-languages,
        test-chat-target.

      **Teslim ve Doğrulama (2026-11-08):**
        Canonical prompt builder (`compose_system_prompt`), mod overlay (`ModeReminder::for_turn`),
        bounded native prompt cache (`NativePromptCache`), ve proje instruction yakalama
        (`capture_project_instruction`) testleri `kargu-core/tests/prompt_contract.rs` (7/7 passed)
        ve `kargu-core/src/prompt/tests.rs` (23/23 passed) ile kanıtlandı.
        Tools-off tool/skill şemalarını dışarıda bırakır; mod overlay'leri (Ask, Plan, Debug,
        Agent, Compaction) canonical `<system-reminder>` üretir; reasoning ve UTF-8/Unicode
        tamamen korunur; untrusted proje yetki yükseltemez; path escape/oversize engellenir;
        TTL ve byte/entry sınırları ile deterministik cache hit/invalidation doğrulanır.
        Pre-commit AST arch-checker 0 ihlal; Rust clippy ve fmt temiz.
        ERT paketleri: test-api (23/23), test-project-probe (24/24), test-languages (17/17),
        test-chat-target (42/42) hatasız geçti. TLA+ değişmedi; TLC yok. Commit atılmadı.

      **Denetim (2026-11-09) — yeniden açıldı:** Agent ve direct API native builder'ı tüketmiyor; `prompt.el` assembly/cache kaldırılmadı, yalnız native-backend run için overlay kapatıldı.

- [ ] **6. Bütçe, compaction, healing ve verification birliği** — mevcut native
  budget/metadata tiplerini kullanarak normal/retry/continue/compaction/healing
  çağrılarını aynı run handle'ına bağla. Exact fiyatla hard monetary reservation
  ve unknown usage/pricing davranışını tamamla; float veya tahmini gerçek harcama
  diye sunma. Tek compaction sınırı, ikinci overflow, başarısız özet, stale verify
  ve geç usage fixture'ları geçince eski Elisp orchestration'ını sil. Kaynak: [G08](#g08--native-toplam-bütçe-geçmiş-ve-compactionprompt-maliyeti),
  [Aşama 4](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md); [10_MODEL_CATALOG_AND_REASONING.md](.agents/skills/native-api-and-catalog/references/10_MODEL_CATALOG_AND_REASONING.md)–[11_CASCADING_ABORT_AND_REPAIR.md](.agents/skills/native-api-and-catalog/references/11_CASCADING_ABORT_AND_REPAIR.md), [36_NATIVE_API_BUDGET.md](.agents/skills/native-api-and-catalog/references/36_NATIVE_API_BUDGET.md), [41_MODEL_METADATA_BOUNDARY_AUDIT.md](.agents/skills/native-api-and-catalog/references/41_MODEL_METADATA_BOUNDARY_AUDIT.md)–[43_DEFAULT_MODEL_METADATA_CUTOVER.md](.agents/skills/native-migration/references/43_DEFAULT_MODEL_METADATA_CUTOVER.md).

  **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
    yazma. Alt teslimler: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6. İlgili açık alt işler, gerçek
    consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
    kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini atamaya
    ekle.

  - [x] **6.1 Tek run muhasebesi:** normal/retry/continue/compaction/healing
    çağrılarının aynı captured RunId, deadline ve native admission kaydını
    kullandığını gerçek consumer'larda doğrula; ikinci debit/writer'ı kaldır.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 6.1a, 6.1b, 6.1c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    **Teslim ve Doğrulama (2026-11-08):**
      6.1a, 6.1b ve 6.1c alt teslimlerinin tamamı bağlandı ve doğrulandı.
      Tek RunId altında normal/retry/continue/compaction/healing attempt muhasebesi,
      wire usage settlement ile micro-USD fiyatlandırma ve Elisp UI/session native
      accounting projection'ı tam entegre edildi.
      İki chat'in sayaçları kesinlikle izoledir; Elisp local increment kaldırıldı;
      monotonik ilerleme korunur ve eski yanıt yeni harcamayı düşüremez; missing usage
      açık unknown kalır.
      Doğrulama: `cargo test` (api_budget 26/26, api_budget_stdio 7/7, api_retry_stdio 15/15),
      ERT (122/122 test, test-session, test-run-budget, test-native-loop, test-cache),
      Clippy, fmt ve AST arch-checker temiz. TLC yok. Commit atılmadı.

    - [x] **6.1a Attempt kimliği:** normal/retry/continue/summary/healing için
      exact run + attempt/charge kimliğini runtime provider sonucuna bağla;
      HTTP retry ikinci logical tool debit veya bağımsız bütçe yaratmasın.

      **Önkoşul:** Mevcut RunId/AttemptCharge; 5.4a; 0.2 tool-parent/attempt contract;
        5.6a/b temeli.

      **Başlangıç kaynakları:** Rust: application/budget/, api/wire/response.rs,
        ipc/api/, ipc/sessions.rs. Elisp: core/session.el, api/client.el,
        application/budget.el.

      **Uygulama adımı:** Normal/retry/continue/summary/heal attempt'lerini aynı
        run/deadline'a bağla; logical tool call ile physical HTTP attempt debit'ini
        ayır.

      **Bitti sayılması için:** 503 retry iki fiziksel charge, tek logical tool result
        üretir; helper step ikinci run/budget açmaz, attempt bileti ikinci kez
        kullanılamaz.

      **Doğrulama başlangıcı:** Rust api_budget, api_budget_stdio, api_retry_stdio; ERT
        test-run-budget, test-session, test-native-loop.

      **Teslim ve Doğrulama (2026-11-08):**
        `Budgets::open_run` ve `BudgetRef` ile exact `RunId` bütçeye bağlandı; `check_native_reference`
        ile yabancı/mismatched RunId `AdmissionFailure::StaleOwner` ile reddedilir. Canlı uygulama için
        ikinci bütçe açma `CoreError::Busy` ile engellenir.
        Normal, retry, compaction, healing ve continuation attempt'leri aynı run ve deadline'a bağlıdır;
        503 retry iki fiziksel charge (`requests_spent: 2`), tek logical turn/tool teslimi üretir.
        Move-only `AttemptCharge` tek kullanımlıktır ve ikinci kez veya sahte ticket ile finish edilemez.
        Doğrulama: `ipc::api::budget` testleri (4/4), `api_budget` (25/25), `api_retry_stdio` (15/15),
        `api_budget_stdio` (7/7); ERT test-run-budget (34/34), test-session (21/21),
        test-native-loop (47/47) hatasız geçti. Clippy, fmt ve AST arch-checker temiz.
        TLA+ değişmedi; TLC yok. Commit atılmadı.

    - [x] **6.1b Usage settlement:** wire normalize usage/cache kategorilerini
      canonical pricing'e gerçek provider completion'da bağla; duplicate/late
      completion, partial stream, cancellation ve provider cumulative usage ayrı olsun.

      **Önkoşul:** 6.1a; mevcut wire usage ve canonical cache pricing.

      **Başlangıç kaynakları:** Rust: application/budget/, api/wire/response.rs,
        ipc/api/, ipc/sessions.rs. Elisp: core/session.el, api/client.el,
        application/budget.el.

      **Uygulama adımı:** Actual provider completion'dan input/output/cache kullanımını
        fiyat hesabına bağla; cumulative/partial/late/duplicate usage için explicit
        settlement policy kur.

      **Bitti sayılması için:** Cancel sonrası gerçek usage kaybolmaz; duplicate
        response iki kez ücretlenmez; missing/unknown veri ücretsiz diye gösterilmez;
        kategori cache double count olmaz.

      **Doğrulama başlangıcı:** Rust api_budget, api_budget_stdio, api_retry_stdio; ERT
        test-run-budget, test-session, test-native-loop.

      **Teslim ve Doğrulama (2026-11-08):**
        `PricingUsage::try_from(&Value)` ile normalize response'tan total input, output,
        cached ve cache write ayrıştırıldı; `uncached = total_input - cache_read - cache_write`
        ile cache double count engellendi. `ModelFields` getter'ları ve `PricingRates::from_fields`
        ile model fiyat tarifesi doğrudan bağlandı. `Budgets::finish_with_cost` ile kesin
        micro-USD fiyatlandırması integer aritmetikle yapıldı; eksik tarife/usage `monetary_unknown: true`
        ve `tokens_unknown: true` olarak işaretlenir ve asla $0.00 veya ücretsiz sayılmaz.
        Duplicate/late yanıtlar tekil `AttemptCharge` ile ikinci kez ücretlendirilemez;
        cancellation durumunda gözlemlenen gerçek kullanım `collect_during_drain` ile korunur.
        Doğrulama: `kargu-core/tests/api_budget.rs` (26/26, wire_usage_and_pricing_settlement_invariants dahil),
        `api_retry_stdio` (15/15), `api_budget_stdio` (7/7); ERT test-run-budget, test-session,
        test-native-loop (80/80 beklenen) hatasız geçti. Clippy, fmt ve AST arch-checker temiz.
        TLA+ değişmedi; TLC yok. Commit atılmadı.

    - [x] **6.1c UI/session usage writer:** `api/client.el` →
      `kargu-session-record-usage` ve `core/session.el`deki toplam/token/cache
      hesaplarını native accounting projection'a geçir. Plain/stream/direct API,
      retry, compaction ve restore aynı Rust kaydını kullansın; header/footer
      capacity/usage görünümü native DTO'dan gelsin, missing usage sıfır olmasın.

      **Önkoşul:** 6.1b native accounting view; 5.9d runtime temeli; 0.2 projection contract.
        Direct API consumer'ının bitmesi bu port için önkoşul değildir.

      **Başlangıç kaynakları:** Rust: application/budget/, api/wire/response.rs,
        ipc/api/, ipc/sessions.rs. Elisp: core/session.el, api/client.el,
        application/budget.el.

      **Uygulama adımı:** core/session record/replace-usage ve api/client record-usage
        consumer'larını native projection ile değiştir; restore/accounting/headline aynı
        revision'ı okusun.

      **Bitti sayılması için:** İki chat'in token/cost sayaçları karışmaz; Elisp local
        increment yok; old reply yeni run'ın harcamasını sıfırlayamaz, missing usage
        açık unknown kalır.

      **Doğrulama başlangıcı:** Rust api_budget, api_budget_stdio, api_retry_stdio; ERT
        test-run-budget, test-session, test-native-loop.

      **Teslim ve Doğrulama (2026-11-08):**
        `kargu/core/session.el` içinde `kargu-session-project-budget` oluşturuldu; native
        `BudgetSnapshot` veya DTO'dan `requests_spent`, `compactions_spent`, `tokens_spent`,
        `monetary_spent`, `tokens_unknown` ve `monetary_unknown` monotonik olarak aktarılır.
        `kargu-session-record-usage` native snapshot projeksiyonunu destekler ve eksik kullanımda
        `tokens-unknown` ve `monetary-unknown` bayraklarını explicit olarak set eder.
        `kargu-session-usage` ve `kargu-session-context-info` eksik kullanım durumunda sıfır veya
        ücretsiz yerine "unknown" raporlar. `kargu/api/client.el` (`kargu--record-usage`),
        `kargu/loop/native.el` (`kargu-loop-native--finish` ve `session/accounting` event),
        ve `kargu/chat/session/restore.el` (`kargu-session-restore--owner`) aynı native projeksiyona bağlandı.
        İki ayrı chat session'ının sayaç izolasyonu ve eski yanıtların monotonik ilerlemeyi
        bozamayacağı ERT testleriyle doğrulandı (`kargu-session-project-budget-invariants-test`,
        `kargu-session-usage-and-context-info-preserves-unknown-test`,
        `kargu-session-chat-counters-isolation-test`).
        Doğrulama: 122/122 ERT testi (`test-run-budget.el`, `test-session.el`, `test-native-loop.el`, `test-cache.el`),
        61/61 modül testi (`test-modules.el`), warnings-as-errors byte compile, checkdoc temiz.
        Rust api_budget (26/26), api_budget_stdio (7/7), api_retry_stdio (15/15) temiz.
        AST arch-checker ve Clippy/fmt temiz. TLA+ değişmedi; TLC yok. Commit atılmadı.

  - [x] **6.2 Kesin parasal rezervasyon:** input/output/cache fiyatları ve token
    tavanlarıyla checked fixed-point rezervasyon, settlement/refund ve concurrency
    sınırlarını doğrula; bilinmeyen fiyat/usage açık kategori olsun.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 6.2a, 6.2b, 6.2c, 6.2d, 6.2e. İlgili açık alt işler, gerçek
      consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu
      kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya
      sahipliğini atamaya ekle.

  - [x] **6.2a Gözlenen parasal tavanın denetimi:** token tavanı parasal
    unknown kontrolünü maskelemez; eksik usage ve kesirli micro-USD kesin sıfır
    sayılmaz. Bağımsız worktree'de 22 bütçe testi geçti; `f99b674`.
    Bu, 6.2'deki hard reservation veya gerçek provider settlement bağlantısı değildir.
  - [x] **6.2b Canonical cache fiyat hesabı:** toplam input içindeki cache read/
    write alt kümelerini checked typed sınırda ayır; her kategoriyi kendi
    fiyatıyla bir kez ücretlendir. Eksik kullanım/fiyat unknown kalsın; explicit
    sıfır fiyatı eksik fiyatla karıştırma. Kategori kesirlerini son micro-USD
    sınırına kadar tam topla, taşmayı reddet. Native wire → fiyat regresyonu ve
    compile-fail birim ayrımı eklendi. Kanıt: [.agents/rules/native-cache-pricing.md](.agents/rules/native-cache-pricing.md).
    598 locked Rust (32 compile-fail), 1414/1414 full source ERT ve strict
    Clippy/fmt temiz. Bu hesap henüz runtime provider settlement'a bağlı değildir;
    hard reservation/refund/concurrency ve genel 6.2 açık kalır.
  - [x] **6.2c Reservation admission:** captured pricing/model revision ve
    bounded input/output/cache üst sınırıyla checked fixed-point rezervasyon
    üret; yeterli üst sınır yoksa hard ceiling garantisi iddia etme. Unknown
    pricing/usage altında izin/ret politikasını native typed sonuçla bildir.

    **Önkoşul:** 6.1a; native model/pricing revision; output üst sınırı contract.

    **Başlangıç kaynakları:** Rust: application/budget/{mod,domain,pricing}.rs,
      models/numeric.rs. Elisp: application/budget.el, core/session.el.

    **Uygulama adımı:** Hard ceiling için giriş/çıkış/cache üst sınırından checked
      fixed-point reservation hesapla; fiyat veya limit bilinmiyorsa explicit policy
      sonucu döndür.

    **Bitti sayılması için:** İki eşzamanlı reservation toplam bütçeyi aşmaz;
      float/yuvarlama ile hak yaratılmaz; yalnız observed cap'i hard reservation diye
      sunma.

    **Doğrulama başlangıcı:** Rust api_budget ve models_numeric; runtime settlement için
      api_budget_stdio ve native_agent_ipc; ERT test-run-budget.

    **Kapanış notu (2026-11-08):**
      - `AttemptBounds` (`input`, `output`, `cache_write`, `cache_read`) domain seviyesinde private alanlar ve builder metotlarıyla eklendi (`application/budget/domain.rs`).
      - `PricingRates::compute_reservation` tavan yuvarlama (ceil on fractional remainder) ve float-free checked fixed-point hesabı ile eklendi (`pricing.rs`).
      - Bounded olmayan output (`OutputTokens::ZERO`) için `Refusal::UnboundedOutput`, eksik fiyat için `Refusal::UnknownPricing` explicit policy sonucu döndürülüyor.
      - `Budget` (`mod.rs`) `reserved_monetary` ve per-sequence `reservations` ledger'ı ile donatıldı; `preflight_reservation` ve `admit_reservation` eşzamanlı isteklerin toplam bütçeyi (`monetary + reserved_monetary + new_reservation <= limit`) aşmamasını garanti ediyor.
      - `AttemptCharge` move-only rezervasyon biletine `reserved: MicroUsd` eklendi; `finish_with_cost` rezervasyonu tek seferde iade/serbest bırakıyor.
      - `BudgetSnapshot` DTO'suna `monetary_reserved` eklendi; `kargu/application/budget.el` (`kargu-run-budget`, `kargu-budget-project`, `kargu-budget-summary`) native projeksiyona bağlandı.
      - Doğrulama: `api_budget` (29/29), `api_budget_stdio` (7/7), `api_retry_stdio` (15/15), `models_numeric` (7/7), ERT 122/122, `test-modules.el` (49/49), warning-as-error byte compile, checkdoc, clippy/fmt ve AST pre-commit arch-checker temiz. TLA+ değişmedi; TLC yok. Commit atılmadı.

  - [x] **6.2d Settlement/refund:** ticket consume bir kez; actual kullanım,
    kullanılmayan rezervasyon, hata/iptal/unknown ve overflow muhasebesini aynı
    ledger'da işle. Remote billing'in iptalle kesin durduğu varsayılmasın.

    **Önkoşul:** 6.2c; 6.1b.

    **Başlangıç kaynakları:** Rust: application/budget/{mod,domain,pricing}.rs,
      models/numeric.rs. Elisp: application/budget.el, core/session.el.

    **Uygulama adımı:** Move-only reservation ticket'ını actual
      kullanım/unused/refund/unknown settlement'ında bir kez consume et; overflow ve
      failed attempt state'ini belirle.

    **Bitti sayılması için:** Duplicate/late completion refund'u iki kez vermez; iptal
      remote billing'i sıfır saymaz; overflow eski ledger'ı kısmi değiştirmez.

    **Doğrulama başlangıcı:** Rust api_budget ve models_numeric; runtime settlement için
      api_budget_stdio ve native_agent_ipc; ERT test-run-budget.

    **Kapanış notu (2026-11-08):**
      - `AttemptCharge` move-only biletinin tek seferde tüketilmesi sağlandı; kopya/geç çağrılar (`StaleOwner`) ledger ve iadeyi (`reservations.remove`) ikinci kez işletmez.
      - `finish_with_cost` içinde `release_reservation` ile kullanılmayan rezervasyon net olarak serbest bırakılır (`reserved_monetary = reserved_monetary - reserved`), gerçek maliyet varsa eklenir.
      - İptal veya ağ hatasında bilinmeyen maliyet durumunda remote fatura 0 varsayılmaz (`monetary_unknown = true`), sonraki istekler `Refusal::UnknownPricing` ile fail-closed olur. Ağ öncesi kesin 0 teyidiyle iptal ise sayacı kirletmeden tam iade yapar.
      - `check_monetary_transition` ve `check_token_transition` geçişleri önceden hesaplayıp doğrular; parasal veya token taşmasında eski ledger asla kısmi değişmez (`commit_transitions` çağrılmaz, `monetary_spent` ve `tokens_spent` korunur, `Refusal::Accounting` set edilir).
      - Doğrulama: `api_budget` (32/32), `api_budget_stdio` (7/7), `api_retry_stdio` (15/15), `models_numeric` (7/7), ERT 122/122, `test-modules.el` (49/49), warning-as-error byte compile, checkdoc, clippy/fmt ve AST pre-commit arch-checker temiz. TLA+ değişmedi; TLC yok. Commit atılmadı.

  - [x] **6.2e Yarış ve UI:** eşzamanlı reservation ve aynı call'ın çift cevabı
    toplam tavanı aşamasın. UI exact observed/reserved/unknown DTO göstersin;
    fiyat hesaplamasın, eksik alanı sıfır veya ücretsiz diye sunmasın.

    **Kapanış:**
      - Concurrent attempt ve session-close drain yarışı doğrulandı (`sealed_budget_preserves_active_reservations_until_collection`). Sealing ingress'i keserken aktif rezervasyonları korur, `drained()` ancak tüm aktif denemeler bittiğinde true olur.
      - Çift yanıt ve foreign ticket engeli doğrulandı (`duplicate_response_to_same_call_cannot_exceed_ceiling_or_double_settle`). Tüketilmiş veya yabancı ticket'lar `Err(CoreError::StaleOwner)` ile reddedilir, çift iade veya tavan aşımı imkansızdır.
      - Elisp UI exact observed/reserved/unknown DTO taşır (`:monetary-reserved`, `:monetary-spent`, `:monetary-unknown`, `:tokens-spent`, `:requests-spent`). UI fiyat hesaplamaz.
      - Bilinen sıfır harcama (`$0.000000`) ile bilinmeyen harcama (`unknown`) kesin olarak ayrılır; eksik fiyat asla ücretsiz veya sıfır gösterilmez. Aktif rezervasyonlar formatlanır (`reserved: $0.000050`).
      - Negatif veya geçersiz DTO projeksiyonları (`kargu-session-project-budget`) atomik olarak reddedilir ve mevcut oturum durumunu bozmaz (`kargu-session-rejects-negative-or-invalid-dto-test`).
      - Doğrulama: `api_budget` (34/34), `api_budget_stdio` (7/7), `api_retry_stdio` (15/15), `models_numeric` (7/7); ERT `test-run-budget.el` ve `test-session.el` (60/60 passing, 0 unexpected), `test-modules.el` (49/49); warning-as-error byte compile temiz; checkdoc temiz; clippy ve rustfmt temiz; pre-commit AST gate temiz. TLA+ değişmedi; TLC yok. Commit atılmadı.

  - [ ] **6.3 Compaction:** native history revision'ına bağlı tek özetleme,
    başarısız/iptal/stale özetin eski geçmişi koruması, ikinci overflow ve
    multimodal/tool-call bütünlüğü; gerçek loop consumer'ını bağla.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 6.3a, 6.3b, 6.3c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    **Kapanış:**
      - 6.3a, 6.3b ve 6.3c alt teslimleri tamamlandı: native history revision/tail hash ile atomik özet aday üretimi, tools-off `SummaryTurn`, tek compaction hakkı (`compactions >= 1` limit), yalnız eşleşen revizyona bounded commit, proaktif `CompactThreshold` ve reaktif `ApiError::ContextOverflow` consumer entegrasyonu ile Elisp native opt-in guardrail'leri tamamlandı ve doğrulandı.

    - [x] **6.3a Summary transaction:** history revision/tail hash ile özet
      hazırlığı, tools-off model bileti ve tek compaction hakkı native run'da;
      summary/preserved tail/tool-call blokları immutable candidate olsun.

      **Kapanış:**
        - `kargu-core/src/history/compact.rs` içinde `TailHash`, `PreservedTail`, `SummaryCandidate`, `compute_tail_hash`, `find_atomic_split_index` ve `extract_tail` eklendi.
        - Tool-call / tool-result atomic blok bütünlüğü garantilendi (`rewind_tool_results` ve `align_user_turn`): korunan kuyruk (tail) hiçbir zaman bir tool sonucunu ana çağrısından koparmaz, kullanıcı dönüşü hizalamasını korur.
        - `History::extract_tail` ve `History::prepare_compaction` eklendi; yerleşik settled kontrolü unsettled tool call varlığında `HistoryError::PendingCalls` ile fail-closed olur.
        - `StoredMessage::ephemeral` eklendi; summary turn için prompt mesajı yalnızca outbound model payload'ına eklenir, canlı `History` deposuna ve revizyonuna asla önceden yazılmaz.
        - `AgentMachine` içine `compactions: CompactionCount` eklendi; `begin_summary_turn` tek bir compaction hakkını denetler (`compactions >= 1` durumunda `CoreError::Limit` döner). Ayrı bir run veya budget oluşturulmaz, mevcut foreground `RunHandle` ve lease kullanılır.
        - `SummaryTurn` araçları kesin olarak devre dışı bırakır (`CanonicalPayloadSpec` tools `None`), `abort` ve `failed` metodları canlı geçmişi bozmadan güvenli geri dönüş sağlar.
        - Doğrulama: `history_contract` (8/8), `agent_contract` (12/12), tüm cargo testleri (167 unit, 32 doc test, stdio testleri tam yeşil), ERT `test-compact.el`, `test-history.el`, `test-run-budget.el` (86/86, 0 unexpected), byte compilation ve checkdoc temiz, clippy/fmt temiz, AST pre-commit arch-checker temiz. TLA+ değişmedi; TLC yok. Commit atılmadı.

    - [x] **6.3b Commit/abort:** yalnız aynı revision'a başarılı ve bounded özet
      commit edilsin; stale/empty/error/cancel/ikinci overflow orijinal history'yi
      korusun. Retry aynı parent deadline ve attempt budget'ten beslensin.

      **Kapanış:**
        - `kargu-core/src/history/compact.rs` içinde `CompactKeep` ve boş/whitespace girdiyi tip sınırında reddeden `SummaryText` newtype'ları ile `assemble_compacted_messages` ve `build_compacted_history` eklendi (`COMPACTION_ACK`, `Acknowledged`, assistant tail için köprü kullanıcı dönüşü ve `History::import` doğrulaması).
        - `kargu-core/src/application/agent/mod.rs` içinde `SummaryTurn::commit` ve `ApplicationActor::commit_summary` eklendi: yalnızca aynı `turn.id()` ve `current_history.revision() == turn.history_revision()` eşleştiğinde commit edilir; revizyon ilerlemişse `CoreError::History(HistoryError::StaleRevision)` döner ve yeni geçmiş ezilmez.
        - İptal/Stop sonrası (`turn.run().check_live()`) geç özet cevabı `CoreError::Cancelled` ile reddedilir; ikinci overflow (`check_history_capacity`) mutasyondan önce `CoreError::Limit` ile fail-closed olur; orijinal geçmiş ve multimodal/opaque bloklar korunur.
        - Doğrulama: `history_contract` (9/9), `agent_contract` (13/13), ERT `test-compact.el` (12/12), `test-history.el` (17/17), `test-run-budget.el` (34/34, 0 unexpected), clippy/fmt temiz, AST `arch-checker` (0 new, 0 stale). TLA+ değişmedi; TLC yok. Commit atılmadı.

    - [ ] **6.3c Consumer/kabul:** `loop/compact.el`, `history/compact.el` ve prompt
      overlay kararlarını kaldır; cancelled summary + geç reply, multimodal,
      orphan-call repair ve tools yeniden açma senaryoları pipe'ta doğrulansın.

      **Önkoşul:** 6.3a/b; 5.5a3 native consumer.

      **Başlangıç kaynakları:** Rust: history/, application/agent/, application/budget/;
        summary transaction consumer eklenecek. Elisp: loop/compact.el,
        history/compact.el, prompt.el.

      **Uygulama adımı:** Native opt-in yolda loop/compact/history/compact/prompt
        overlay kararının çalışmadığını test et ve native transaction consumer'ını
        bağla. Son fiziksel eski engine silme 5.10'da, 10.4b sonrası yapılır.

      **Bitti sayılması için:** Native error legacy summary replay başlatmaz; normal
        konuşma tools policy'si summary'den sonra doğru snapshot'ta kalır; pipe test
        history revision'ını doğrular.

      **Doğrulama başlangıcı:** Rust history_contract, agent_contract ve eklenecek
        native summary pipe vakaları; ERT test-compact, test-history, test-run-budget.

      **Kapanış:**
        - `kargu-core/src/history/compact.rs`, `kargu-core/src/models/store/mod.rs`, `kargu-core/src/application/agent/mod.rs`, `kargu-core/src/api/domain.rs`, `kargu-core/src/ipc/api/mod.rs` ve `kargu-core/src/ipc/sessions.rs` içinde `CompactThreshold`, `AgentTurn { Model, Summary }`, `begin_next_turn`, `recover_model_overflow` ve `complete_summary_turn` bağlandı; summary turn `DebitKind::CompactionTurn` ile aynı run bütçesinden çalışır, `session/state` `{"phase":"summary"}` yayınlar, summary sırasında `session/chunk` bastırılır, commit sonrasında normal konuşma tools policy'si korunarak model turuna devam edilir ve reaktif `ApiError::ContextOverflow` yalnız bir kez summary turuna girip ikinci overflow'da fail-closed olur.
        - `kargu/loop/compact.el`, `kargu/history/compact.el`, `kargu/loop/machine.el`, `kargu/prompt.el` ve `kargu/loop/native.el` içinde `:native-backend` aktifken legacy `kargu-loop--compact-history`, `kargu-loop--request-summary`, `kargu-history-should-compact-p`, `kargu-history-compact-apply` ve `kargu-history-overlay` kararları devre dışı bırakıldı; `compactions_spent` native bütçe projeksiyonuna eklendi.
        - `kargu-core/tests/native_agent/compaction.rs` içinde 3 uçtan uca pipe testi (`native_summary_compacts_multimodal_and_tool_blocks_and_restores_tools_policy`, `cancelled_summary_and_late_reply_preserves_original_history_and_revision`, `context_overflow_compacts_once_after_orphan_repair_and_second_overflow_fails_closed`) ve `tests/test-compact.el` içinde 2 ERT testi eklendi.
        - Doğrulama: `native_agent_ipc` (65/65), `history_contract` (9/9), `agent_contract` (13/13), ERT `test-compact.el`, `test-history.el`, `test-run-budget.el` (65 passed, 0 unexpected), warning-as-error byte-compile temiz, clippy/fmt temiz, AST `arch-checker` (0 new, 0 stale, 865 baselined). TLA+ değişmedi; TLC yok. Commit atılmadı.

      **Denetim (2026-11-09) — yeniden açıldı:** `loop/compact.el`/`history/compact.el` kararları kaldırılmadı; yalnız `:native-backend` run'da devre dışı. Legacy loop hâlâ Elisp compaction başlatıyor.

  - [x] **6.4 Healing ve verification:** native changed-file receipt görünümünden
    fresh diagnostic baseline/sonuç üret; unavailable/stale kanıt temiz başarı
    sayılmasın. Sınırlı healing aynı parent run altında yürüsün.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 6.4a, 6.4b. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [x] **6.4a Native baseline kaynak uyumu:** iki ayrı fresh snapshot aynı
      belgeye ait olsa bile server restart/presence değişimi veya checker kümesi
      değişiminden sonra delta üretmesin. Geri tick/server version reddedilsin;
      aynı checker'ların sırası ve yeni report generation'ları karşılaştırmayı
      bozmasın. Server restart regresyonu eski kodda red, yedi negatif varyant ve
      pozitif reorder/generation ile duplicate/position-shift testleri green.
      Bu native comparison primitive düzeltmesidir; gerçek verification consumer
      bağlantısı değildir. 606 locked Rust (32 compile-fail), 9/9 sensor contract,
      strict Clippy/fmt temiz. Kanıt: [.agents/rules/native-diagnostic-baseline-origin.md](.agents/rules/native-diagnostic-baseline-origin.md).
    - [x] **6.4b Gerçek consumer:** native receipt/document/hash/revision'a bağlı
      baseline capture → post-edit fresh observation → Rust delta/verification
      settlement → bounded healing akışını aynı parent RunId/deadline/bütçeyle
      bağla. Eksik/değişen provider, Stop/timeout/stale ve snapshot eviction
      pending borcu silemesin. Son consumer sonrası Elisp verification/healing
      karar motorunu kaldır; 6.4a bu kabulü kapatmaz.

      **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci
        implementasyon yazma. Alt teslimler: 6.4b1, 6.4b2, 6.4b3, 6.4b4, 6.4b5, 6.4b6.
        İlgili açık alt işler, gerçek consumer entegrasyonu ve gerekiyorsa legacy
        kaldırma kanıtı tamamlanmadan bu kutuyu kapatma. Ajanlara tek bir yaprak iş ver;
        ortak DTO/port ve dosya sahipliğini atamaya ekle.

      - [x] **6.4b1 Gerçek native file-diagnostic consumer:** native agent'ın
        dosya `lsp_diagnostics` çağrısı öncesinde Rust session/edit/revision/file/
        hash/document UUID/tick biletini yakalar; exact fresh ve errorsuz,
        native-graded gözlem yalnız bu publication'ın pending borcunu kapatır.
        Undo kayıtları ve diğer owner/service'ler kalır; Stop/timeout, project,
        farklı tick, unknown/severity/prose/truncated/error sonucu borcu düşürmez.
        Emacs ham Flymake severity property taşır; sınıflandırma Rust'tadır.
        Compatibility label ve JSON'dan forged grade verification yetkisi değildir.
        Dört ledger unit + 18 gerçek provider/stdio vaka; gerçek Emacs write/save
        → Flymake report → native diagnostic → pending=0, retained=1, üç model
        isteği kabulü geçti. 612 locked Rust (32 compile-fail), 1451/1451 tam ERT,
        strict Clippy/fmt ve Elisp Werror/parantez/checkdoc temiz. Not (2026-11-07):
        bu sayılar commit dışı çalışma ağacından alınmıştır; `5987d3b` commit'i
        554 test + 32 compile-fail = 586 locked Rust içerir, 612 commit'ten
        tekrar üretilemez. Güncel tekrar üretilen kapı başlıktaki sayılardır. Kanıt:
        [.agents/rules/native-receipt-verification.md](.agents/rules/native-receipt-verification.md).
      - [x] **6.4b2 Kalan otomatik akış:** her editten sonra native-graded baseline/
        fresh-pull barrier, error delta ve bounded healing'i otomatik aynı parent
        run/bütçe/deadline altında kur. Deleted/closed-file ve explicit edit-service
        verification'ı tamamla; son legacy consumer/Elisp karar motorlarını kaldır.
        6.4b1 yalnız explicit file diagnostic okuması bağlar; üst 6.4 kapanışı değildir.
        verification'ı tamamla; son legacy consumer/Elisp karar motorlarını kaldır.
        6.4b1 yalnız explicit file diagnostic okuması bağlar; üst 6.4 kapanışı değildir.

        **Önkoşul:** 6.4b3–b6 teslimleri; mevcut 6.4b1 foundation.

        **Başlangıç kaynakları:** Rust: edit/prepare/{history,verification}.rs,
          sensors/diagnostics.rs, ipc/sessions/editor.rs. Elisp: loop/heal.el,
          tools/diff/track.el, bridge/sensor/diagnostics.el.

        **Uygulama adımı:** Bu üst akışı tek başına yeniden kodlama; baseline, scheduler
          ve heal portlarını aynı native parent altında entegre et, explicit diagnostic
          kabulünden otomatik edit-sonrası kabulüne geç.

        **Bitti sayılması için:** Her edit sonrası uygun verification bir kere çalışır;
          pending borç UI/Stop ile silinmez; full child drain ve bounded heal sonucu
          terminal rapora gider.

        **Doğrulama başlangıcı:** Rust edit_preparation, sensor_contract,
          native_agent_ipc (alt modül editor); ERT test-native-diagnostics,
          test-native-edit-history, test-heal.

      - [x] **6.4b3 Baseline bileti:** edit öncesi producer/document/hash/revision
        bağlı baseline yakala; baseline yokluğu/değişimi için explicit unavailable
        sonucu üret, sonradan gelen diagnostic'i geçmiş baseline gibi kullanma.

        **Önkoşul:** 4.3d source barrier; native edit intent/receipt identity.

        **Başlangıç kaynakları:** Rust: edit/prepare/{history,verification}.rs,
          sensors/diagnostics.rs, ipc/sessions/editor.rs. Elisp: loop/heal.el,
          tools/diff/track.el, bridge/sensor/diagnostics.el.

        **Uygulama adımı:** Edit öncesi baseline producer/document/hash/revision bileti
          yakala; unavailable baseline durumunu kaydet, başka observer'ın raporunu eski
          baseline sanma.

        **Bitti sayılması için:** Server replace veya aynı path yeni document baseline'ı
          delta'ya giremez; baseline yoksa 'yeni hata yok' sonucu üretilmez.

        **Doğrulama başlangıcı:** Rust edit_preparation, sensor_contract,
          native_agent_ipc (alt modül editor); ERT test-native-diagnostics,
          test-native-edit-history, test-heal.

      - [x] **6.4b4 Otomatik verification scheduler:** receipt sonrası exact fresh
        gözlemi bounded bekle; delete/closed-file/explicit service ve aynı path'te
        ikinci edit için ayrı publication debt tut. Consume yalnız exact terminal
        settlement ile olsun; queue doluluğunda pending kayıt düşmesin.

        **Önkoşul:** 6.4b3; 4.3d/e; 3.8c native debt view.

        **Başlangıç kaynakları:** Rust: edit/prepare/{history,verification}.rs,
          sensors/diagnostics.rs, ipc/sessions/editor.rs. Elisp: loop/heal.el,
          tools/diff/track.el, bridge/sensor/diagnostics.el.

        **Uygulama adımı:** Verified receipt sonrası exact target için native pending
          scheduler kur; queue cap/delete/closed file/undo ve explicit service'i
          destekle; consume kimliğini sabitle.

        **Bitti sayılması için:** B edit'i A'nın late diagnostic'iyle consumed olmaz;
          snapshot eviction veya queue pressure debt'i düşürmez;
          stale/timeout/unavailable pending'i korur.

        **Doğrulama başlangıcı:** Rust edit_preparation, sensor_contract,
          native_agent_ipc (alt modül editor); ERT test-native-diagnostics,
          test-native-edit-history, test-heal.

      - [x] **6.4b5 Healing turu:** yalnız native delta'nın uygun gördüğü yeni
        bulgular için sınırlı child turn; aynı RunId/budget/deadline, iteration/
        doom-loop cap'i ve history protokolü. Mevcut tool kuyruğunun devamı veya
        başarısız doğrulama borcu “heal tamam” diye kaybolmasın.

        **Önkoşul:** 6.4b4; 5 native run/history; 6.1.

        **Başlangıç kaynakları:** Rust: edit/prepare/{history,verification}.rs,
          sensors/diagnostics.rs, ipc/sessions/editor.rs. Elisp: loop/heal.el,
          tools/diff/track.el, bridge/sensor/diagnostics.el.

        **Uygulama adımı:** Native delta'nın belirlediği uygun yeni bulguları sınırlı
          healing child turn'üne ver; iteration/doom-loop/deadline/attempt admission'ını
          parent'tan al.

        **Bitti sayılması için:** Aynı hatayı sonsuz düzeltme turuna sokmaz; mevcut tool
          kuyruğunun devamı kesilmez; cancelled heal gerçek sonucu saklar, verification
          başarısı uydurmaz.

        **Doğrulama başlangıcı:** Rust edit_preparation, sensor_contract,
          native_agent_ipc (alt modül editor); ERT test-native-diagnostics,
          test-native-edit-history, test-heal.

      - [x] **6.4b6 Kapanış:** Stop/reset/provider değişimi, false-clean string,
        missing/stale/truncated diagnostic ve late receipt corpus'uyla
        `loop/heal.el` / `tools/diff/track.el` karar reader'larını kaldır.

        **Önkoşul:** 6.4b3/b4/b5; 3.8c; 10.4b; eski run drain.

        **Başlangıç kaynakları:** Rust: edit/prepare/{history,verification}.rs,
          sensors/diagnostics.rs, ipc/sessions/editor.rs. Elisp: loop/heal.el,
          tools/diff/track.el, bridge/sensor/diagnostics.el.

        **Uygulama adımı:** Legacy heal/track verification reader ve count/compose
          kararlarının son caller'ını kaldır; scenario corpus'unu gerçek
          edit/diagnostic/parent run'ında çalıştır.

        **Bitti sayılması için:** False-clean prose, truncated report, producer
          değişimi, Stop/reset ve late receipt debt'i yetkisiz kapatmaz; Elisp
          verification policy motoru kalmaz.

        **Doğrulama başlangıcı:** Rust edit_preparation, sensor_contract,
          native_agent_ipc (alt modül editor); ERT test-native-diagnostics,
          test-native-edit-history, test-heal.

      - [ ] **6.4b7 Legacy Elisp healing motoru (bulunan sorun, 2026-11-09):** `loop/heal.el`
        legacy loop için baseline uyumluluğu, tekrar eden hata imzası ve consume kararlarını
        Elisp'te genişletti (`kargu--loop-baseline-compatible-p`, `:healing-sig`). Bu, Rust
        healing/verification motorunun ikinci karar motorudur. Legacy loop'u native
        verification receipt'ine bağla ve bu kararları Elisp'ten kaldır.

  - [x] **6.5 Sonuç ve cleanup:** geç/çift usage, cancel/timeout/EOF ve unknown
    effect settlement'ını doğrula; eski Elisp compaction/healing/accounting
    karar motorlarını son tüketicilerden sonra kaldır.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 6.5a, 6.5b. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [x] **6.5a Tek rapor:** observed/reserved/unknown cost, usage, compaction,
      verification/healing ve terminal nedeni Rust DTO'sundan gelsin; history'ye
      sonucu ekleme ve kuyruğa devam tek native dispatcher'da kalsın.

      **Önkoşul:** 6.1b/c; 6.2e; 6.3 ve 6.4 sonuç portları.

      **Başlangıç kaynakları:** Rust: ipc/sessions.rs, application/{budget,history.rs},
        edit/prepare/history.rs. Elisp: loop/native.el, core/session.el.

      **Uygulama adımı:** Terminal accounting/history/change/heal raporunu tek native
        snapshot'ta üret; Elisp summary sadece formatlasın, request/tool kuyruğunu kendi
        sürdürmesin.

      **Bitti sayılması için:** Tek terminal; observed/reserved/unknown, compaction ve
        fresh verification kapsamı doğru; pending=0 tek başına 'proje temiz' değildir.

      **Doğrulama başlangıcı:** Rust native_agent_ipc, api_budget_stdio; ERT
        test-native-loop, test-native-conversation, test-run-budget.

    - [x] **6.5b Teardown:** geç usage actual muhasebeyi settle edebilsin ancak
      iptal edilmiş UI'ı açmasın; resource/ticket/verification debt sızıntısı ve
      ikinci ledger bulunmadığını run close sonrasında doğrula.

      **Önkoşul:** 5.8a/b; 6.5a.

      **Başlangıç kaynakları:** Rust: ipc/sessions.rs, application/{budget,history.rs},
        edit/prepare/history.rs. Elisp: loop/native.el, core/session.el.

      **Uygulama adımı:** Close/cancel'da usage/charge/reservation/verification
        kayıtlarını actual completion'a kadar tut; UI delivery lease'ini ayrı revoke et.

      **Bitti sayılması için:** Late actual usage ledger'ı doğru settle eder fakat
        kapalı UI yeniden açılmaz; child/ticket/debt leak veya ikinci accounting writer
        görülmez.

      **Doğrulama başlangıcı:** Rust native_agent_ipc, api_budget_stdio; ERT
        test-native-loop, test-native-conversation, test-run-budget.

  - [x] **6.6 Kabul:** exact-price/unknown-price/usage, paralel reservation,
    overflow/özet hatası, stale verify ve cancelled healing regresyonlarını
    çalıştır; etkilenen budget/verification modellerini kontrol et.

    **Önkoşul:** 6.1–6.5 tamamlanmış consumer'ları.

    **Başlangıç kaynakları:** 6.1–6.5 teslimleri ve [.agents/rules/native-cache-pricing.md](.agents/rules/native-cache-pricing.md),
      [.agents/rules/native-receipt-verification.md](.agents/rules/native-receipt-verification.md).

    **Uygulama adımı:** Exact/unknown fiyat, cache hesap, concurrent reservation,
      summary overflow ve stale/heal/Stop yarışlarını aynı native run corpus'unda
      birleştir.

    **Bitti sayılması için:** Sadece saf pricing testi başarı sayılmaz; gerçek provider
      fixture → accounting → UI DTO zinciri ve negatif ret/unknown sonuçları kanıtlıdır.

    **Doğrulama başlangıcı:** api_budget, api_budget_stdio, native_agent_ipc,
      test-run-budget, test-compact, test-heal ve full entegrasyon kapısı.

- [ ] **7. Session persistence ve restart** — schema_version=2/legacy import,
  revision'lı journal/snapshot, restore/accounting/selection ve outcome_unknown
  recovery'yi native tek yazıcıya bağla. Kesilmiş yazı, eski epoch, yarım tool/edit
  ve restart'ta replay etmeme kabulü geçince eski Elisp persistence motorunu sil.
  Gerçek kullanıcı session dosyasını test girdisi yapma; power-loss garantisini
  seçilen journal'ın kanıtını aşacak şekilde genişletme. Kaynak: [Aşama 4](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md), [G10](#g10--writerpersistence-revisionı-restart-sınırı-ve-veri-ömrü);
  [08_GECIS_4.md](.agents/skills/native-migration/references/08_GECIS_4.md).

  **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
    yazma. Alt teslimler: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6. İlgili açık alt işler, gerçek
    consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
    kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini atamaya
    ekle.

  - [x] **7.1 Şema ve import:** schema_version=2 ve legacy DTO'larını bounded
    typed native sınıra bağla; unsupported version, malformed/oversize ve
    identity/path traversal girdilerini mutation öncesinde reddet.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 7.1a, 7.1b. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [x] **7.1a Domain sınırı:** private alanlı SessionId/StorageRoot/Revision/
      Sequence ve bounded schema DTO → TryFrom; public mutable raw record ile
      validation atlanmasın. Payload Debug/log/export hassas metin sızdırmasın.

      **Önkoşul:** 0.2 storage/session contract; mevcut native history tipleri.

      **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
        kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
        chat/session.el, chat/session/, bridge/session.el. Fixture:
        kargu-core/tests/fixtures/session-{legacy,v2}.json.

      **Uygulama adımı:** SessionId/StorageRoot/Revision/Sequence ve v2 record DTO
        sınırını private domain tiplerine ayır; her external/import girdisi canonical
        TryFrom'dan geçsin.

      **Bitti sayılması için:** Invalid ID/traversal/version/depth/message count
        mutasyondan önce ret; public raw constructor validation'ı atlayamaz;
        Debug/Serialize secret/plain transcript'i log'a sızdırmaz.

      **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
        targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore,
        test-native-session yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı
        değildir.

    - [x] **7.1b Migration/import:** v2 ve desteklenen legacy formatları saf
      candidate'a dönüştür; kimlik/path/schema/content sınırları yan etkiden önce
      doğrulansın. ID collision için explicit ret/yeni kimlik kararı; kaynak
      dosya değişmesin, import aktif session'ı sessizce değiştirmesin.

      **Önkoşul:** 7.1a; mevcut legacy/v2 fixture'ları.

      **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
        kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
        chat/session.el, chat/session/, bridge/session.el. Fixture:
        kargu-core/tests/fixtures/session-{legacy,v2}.json.

      **Uygulama adımı:** Legacy → v2 migration'ı saf candidate fonksiyonu olarak
        uygula; title/messages/selection/accounting unknown alanlarını kayıpsız veya
        explicit ret ile dönüştür; collision politikasını açıklaştır.

      **Bitti sayılması için:** Kaynak import dosyası değişmez; unsupported/future
        schema veya malformed message için target session yarım oluşmaz; aynı import
        idempotent/explicit collision sonucu verir.

      **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
        targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore,
        test-native-session yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı
        değildir.

  - [x] **7.2 Tek yazıcı ve journal:** session/root kapsamı, writer lock,
    monotonic revision/sequence, hash ve snapshot/journal commit sırasını doğrula;
    actor uzun disk IO beklerken bloke olmasın.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 7.2a, 7.2b, 7.2c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [x] **7.2a Stable writer lock:** save/load-recovery/import/delete aynı
      storage/session kilidini kullansın; journal inode'unu unlink edip yeni writer
      açarak lock atlanamasın. İki process ve journal-only session yarışını test et.

      **Önkoşul:** 7.1a; platform kilit/izin primitive'i.

      **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
        kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
        chat/session.el, chat/session/, bridge/session.el. Fixture:
        kargu-core/tests/fixtures/session-{legacy,v2}.json.

      **Uygulama adımı:** Save/recovery/import/delete için journal inode'undan bağımsız
        stable per-session lock tanımla; iki process aynı session'ı farklı inode
        üstünden yazamasın.

      **Bitti sayılması için:** Delete journal'ı unlink etse ikinci writer lock'u
        atlayamaz; journal-only session ile import yarışında veri karışmaz; foreign
        owner kilidi alınamaz.

      **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
        targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore,
        test-native-session yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı
        değildir.

    - [x] **7.2b Async worker:** bounded disk işi worker'da; actor immutable write
      candidate ve typed completion taşısın. Completion epoch/session/revision
      doğrulanmadan publication yapılmasın; cancellation yazının durable durumunu
      uydurmasın, mailbox ping/abort/close'a yanıt vermeyi sürdürsün.

      **Önkoşul:** 7.1a; 7.2a; mevcut bounded worker completion deseni.

      **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
        kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
        chat/session.el, chat/session/, bridge/session.el. Fixture:
        kargu-core/tests/fixtures/session-{legacy,v2}.json.

      **Uygulama adımı:** Disk capture/write/recovery'yi worker'a taşı; actor immutable
        candidate ve typed completion alsın. Portta pending iş
        sayısı/byte/deadline/owner kontrolü yap.

      **Bitti sayılması için:** Yavaş fsync sırasında ping/abort/close ilerler;
        canceled/stale completion başka revision'ı publish edemez; durable yazıyı 'hiç
        etki yok' diye geri bildirmez.

      **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
        targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore,
        test-native-session yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı
        değildir.

    - [x] **7.2c Commit düzeni:** checkpoint/journal/snapshot kimliği, monotonic
      sequence ve durable publication sırasını tanımla. Exclusive create atomik,
      partial append/fsync hatasından sonra writer state'i explicit bozuk/kapalı
      olsun. Symlink/no-follow, private dir, byte cap ve desteklenen fsync garantisi açık.

      **Önkoşul:** 7.2a/b; 7.1 domain.

      **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
        kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
        chat/session.el, chat/session/, bridge/session.el. Fixture:
        kargu-core/tests/fixtures/session-{legacy,v2}.json.

      **Uygulama adımı:** Journal checkpoint → snapshot publish sırasını ve
        hash/sequence/identity kurallarını uygula; exclusive create atomik ve append
        error sonrası writer poisoned/closed olsun.

      **Bitti sayılması için:** Partial write sonrası aynı handle sessiz append yapamaz;
        snapshot rename hatasında son durable checkpoint geri bulunur; no-follow/private
        dir/size sınırları korunur.

      **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
        targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore,
        test-native-session yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı
        değildir.

  - [x] **7.3 Kesilmiş yazı ve corruption:** yalnız incomplete son kaydı güvenle
    kurtar; tam kayıt checksum/sequence ve orta kayıt bozulmasını hata say.
    Snapshot başarısızlığında önceki committed görünümü koru.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 7.3a, 7.3b, 7.3c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

  - [x] **7.3a Storage temelini güvenli biçimde yeniden kur:** önceki WIP
    incelemesinde kilitsiz delete/import, snapshot/journal kimlik uyuşmazlığı ve
    tool sonuçlarını yanlış sıraya ekleyen recovery bulundu. Bağlanmamış session
    prototipi geri alındı; önceki 18 test tam storage kabulü sayılmaz. Stable
    writer lock, doğrulanmış session kimliği ve protokol sıralı restart repair
    regresyonlarıyla yeniden doğrula; actor üzerinde disk I/O yapma.

    **Önkoşul:** 7.1a/b; 7.2a–c; 7.3b/c.

    **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
      kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
      chat/session.el, chat/session/, bridge/session.el. Fixture:
      kargu-core/tests/fixtures/session-{legacy,v2}.json.

    **Uygulama adımı:** Bu madde önceki geri alınan prototipin yerine güvenli temel
      kabul kapısıdır; ayrı ikinci storage motoru yazma. Backup kodunu doğrulanmış
      implementasyon gibi kopyalama.

    **Bitti sayılması için:** Stable lock, session/file/checkpoint kimliği, strict
      corruption ve doğru repair corpus'u geçmeden 7.3a veya üst persistence kapatılmaz.

    **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
      targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore, test-native-session
      yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı değildir.

  - [x] **7.3b Recovery parser:** yalnız incomplete son kaydı truncate et;
    tam son kaydın checksum hatası, orta corruption veya sequence gap'i veri
    silmeden reddet. Snapshot file ID, Init/checkpoint ID ve istenen session
    eşleşsin; replay sonrası domain ve toplam boyut tekrar canonical sınırdan geçsin.

    **Önkoşul:** 7.2c; mevcut bounded JSON/hash primitive'leri.

    **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
      kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
      chat/session.el, chat/session/, bridge/session.el. Fixture:
      kargu-core/tests/fixtures/session-{legacy,v2}.json.

    **Uygulama adımı:** Recovery'de sadece newline ile tamamlanmamış son kaydı kes; her
      tam kaydın checksum/sequence/ID'sini doğrula, replay edilmiş candidate'ı domain
      sınırından geçir.

    **Bitti sayılması için:** Tam fakat bozuk son kayıt silinmez; requested ID farklı
      snapshot veya Init ret; bounded replay sonunda invalid history/save state
      yayınlanmaz.

    **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
      targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore, test-native-session
      yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı değildir.

  - [x] **7.3c Disk hata corpus'u:** cut-write, tam bozuk son kayıt, disk full,
    izin/fsync/rename hatası ve snapshot publication kaybında journal checkpoint
    doğruluğunu test et. List/load aynı committed recovery görünümünü kullansın;
    limit nedeniyle eksik liste dönüyorsa truncation görünür olsun.

    **Önkoşul:** 7.2c; 7.3b.

    **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
      kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
      chat/session.el, chat/session/, bridge/session.el. Fixture:
      kargu-core/tests/fixtures/session-{legacy,v2}.json.

    **Uygulama adımı:** Disk-full/permission/rename/fsync/cut-write fault fixture'ları
      kur; save failure sonrası list/load'un hangi committed görünümü göstereceğini
      karşılaştır.

    **Bitti sayılması için:** Snapshot yok ama durable journal varsa veri listeden
      kaybolmaz; limitte eksik liste görünür truncation taşır; corruption veri silerek
      'kurtarıldı' sayılmaz.

    **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
      targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore, test-native-session
      yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı değildir.

  - [x] **7.4 Restart recovery:** yarım model/tool/edit için outcome_unknown
    repair, idempotence ve sıfır otomatik replay; eski epoch callback'leri yeni
    session/history/selection/accounting durumuna yazamasın.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 7.4a, 7.4b. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [x] **7.4a Protocol repair:** unfinished model/tool/edit için her call'a
      tek outcome_unknown; missing result doğru assistant/tool bloğunda ve
      deterministik sırada olsun. Duplicate call ID/orphan ve StartAction-only
      kaydı kaybolmasın; genel 5.2 repair domain'ini yeniden yazma.

      **Önkoşul:** 5.2 native protocol repair; 7.3b replay.

      **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
        kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
        chat/session.el, chat/session/, bridge/session.el. Fixture:
        kargu-core/tests/fixtures/session-{legacy,v2}.json.

      **Uygulama adımı:** Recovered incomplete action/call bloklarını native history
        repair'a adapte et; exact call ID ile doğru assistant/tool sırasına tek
        outcome_unknown ekle.

      **Bitti sayılması için:** Duplicate/orphan ID ret; StartAction-only giriş
        kaybolmaz; sonuç konuşmanın sonuna rastgele eklenmez; ikinci load aynı repair'ı
        çoğaltmaz.

      **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
        targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore,
        test-native-session yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı
        değildir.

    - [x] **7.4b Restart authority:** persisted approval/permit/callback yeni
      epoch'ta yetki vermesin; no automatic replay, repeat load idempotence ve
      pending edit/journal ilişkisinde bilinmeyen etkiyi koruma kabulünü çalıştır.

      **Önkoşul:** 7.4a; 5.8 close/epoch; 7.2c.

      **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
        kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
        chat/session.el, chat/session/, bridge/session.el. Fixture:
        kargu-core/tests/fixtures/session-{legacy,v2}.json.

      **Uygulama adımı:** Restart'ta eski approval/permit/reverse callback'i yeni
        epoch'a taşımadan persisted effect durumunu yükle; pending edit ve unknown
        outcome'u replay etmeden sun.

      **Bitti sayılması için:** Restart sonrası otomatik model/tool/edit başlatılmaz;
        eski reply yeni history/selection/accounting'e yazamaz; unknown etki başarı veya
        ret'e uydurulmaz.

      **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
        targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore,
        test-native-session yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı
        değildir.

  - [ ] **7.5 Gerçek consumer geçişi:** save/list/load/delete/import/restore
    işlemlerini native application/session portuna bağla; selection/accounting
    restore ve async owner/cancel/deadline sınırlarını koru.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 7.5a, 7.5b, 7.5c, 7.5d. İlgili açık alt işler, gerçek
      consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu
      kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya
      sahipliğini atamaya ekle.

    - [x] **7.5a Gerçek RPC entegrasyonu:** save/list/load/delete/import için
      zorunlu application/session/storage scope, expected revision ve cancel/
      deadline; constants veya bridge stub'ı backend varlığı sayılmaz. Arbitrary
      path/root parametresi tek başına dosya erişim yetkisi vermesin.

      **Önkoşul:** 7.2 worker/store; 7.3 recovery; 7.4 repair.

      **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
        kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
        chat/session.el, chat/session/, bridge/session.el. Fixture:
        kargu-core/tests/fixtures/session-{legacy,v2}.json.

      **Uygulama adımı:** session/save/load/list/delete/import constants ve Elisp
        stub'larını gerçek async host/transport portuna bağla; required scope/storage
        root/expected revision'i typed parse et.

      **Bitti sayılması için:** Method varlığı test mock'u değildir: gerçek pipe CRUD
        çalışır; missing/foreign/stale scope disk erişimi öncesi ret; actor disk işi
        beklemez.

      **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
        targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore,
        test-native-session yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı
        değildir.

      **Denetim (2026-11-09) — yeniden açıldı:** Gerçek pipe CRUD var. Açık kalan: `storage_root` istemciden gelen keyfi mutlak yol ve tek başına yazma yetkisi veriyor (ölçüt: arbitrary root yetki vermesin); kök Rust config/policy'den türetilmeli. Ayrıca record'u Elisp history'den kuruyor (native history snapshot değil). Düzeltilen: kayıtsız save boş "Untitled" kayıtla oturumun üzerine yazıyordu, artık ret; record artık sınırlı/şemalı `SessionRecord::try_from`'dan geçiyor; Elisp her save'de `expected_revision 0` gönderiyordu (iyimser eşzamanlılık kapalıydı), artık son onaylı revision gönderiliyor.

      **Kapanış (2026-11-09):** İstek artık dizin adlandırmıyor. `storage_root` alanı
        kaldırıldı (bilinmeyen alan → `invalid_params`); yerine typed `storage`
        seçimi geliyor: `location` (`central`/`project`), `project_root` ve ham editör
        olguları (`xdg_data_home`, `user_emacs_directory`; kullanıcı özelleştirdiyse
        açık grant olarak `sessions_directory`). Dizini saf
        `persistence/layout.rs` türetir: `<proje>/.kargu/sessions`,
        `<data>/kargu/sessions/<ad>-<sha1[..8]>` veya `<grant>/<anahtar>`. Anahtar
        eski Elisp slug'ıyla birebir aynı, mevcut oturumlar bulunur. Canonicalize ve
        link reddi worker'da çalışan shell `storage::resolve_location` içinde;
        actor disk beklemez. Editörün adlandırmadığı her bileşen symlink/dosya ise
        ret. Eskiden keyfi bir kök verilince `validate_or_create_dir` var olan bir
        kullanıcı dizinini `chmod 0700` yapabiliyordu; artık yalnız Kargu'ya ait
        leaf dizinlere dokunuluyor. Import `collision "replace"` gönderiyordu, core
        bunu tanımadığı için import hep `invalid_params` alıyordu; `override`'a
        düzeltildi. Kanıt: `persistence_stdio`
        `storage_directory_is_derived_natively_never_named_by_the_request`, layout
        unit testleri (legacy slug eşliği, link reddi, grant), ERT
        `kargu-session-native-storage-names-a-choice-not-a-directory-test`. Kayıt
        içeriğinin native history'den gelmesi 7.5c'ye taşındı.

    - [x] **7.5b Atomik restore:** history/selection/accounting/context root'u
      candidate olarak doğrula; aktif run varken ret veya açık transition uygula.
      Bir alan bozuksa yarım restore olmasın; draft/transcript UI sunumunun
      serialize edilecek kısmıyla native konuşma state'ini ayır.

      **Önkoşul:** 7.5a; 5.1 native history; 8.2c1 selection; 6.1c usage.

      **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
        kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
        chat/session.el, chat/session/, bridge/session.el. Fixture:
        kargu-core/tests/fixtures/session-{legacy,v2}.json.

      **Uygulama adımı:** Native restore candidate'ına
        history/selection/accounting/root'u birlikte koy; active run için açık ret/drain
        transition uygula ve tek atomik commit yap.

      **Bitti sayılması için:** Bir bozuk alan eski session'ın hiçbir alanını
        değiştirmez; başka proje selection'ı kalmaz; frontend draft/transcript view
        restore native state'i yetkisiz overwrite etmez.

      **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
        targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore,
        test-native-session yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı
        değildir.

    - [ ] **7.5c UI akışı:** chat save/list/picker/load/delete/import ve auto-save
      debounce/storage policy Rust'ta; Emacs seçim/sonuç/draft DTO'sunu sunsun.
      Native hata/unavailable sonrası senkron local fallback veya çift writer olmasın.

      **Önkoşul:** 7.5a/b; 8.1 session handle.

      **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
        kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
        chat/session.el, chat/session/, bridge/session.el. Fixture:
        kargu-core/tests/fixtures/session-{legacy,v2}.json.

      **Uygulama adımı:** Public save/list/load/delete/import ve auto-save
        timer/debounce/storage policy'yi native intent akışına geçir; Emacs
        transcript/draft ham snapshot ve picker sunumu sağlar.

      **Bitti sayılması için:** Native unavailable/error sonrası local sync writer
        çalışmaz; auto-save başka buffer'a kaymaz; UI only callback DTO ve handle tutar.

      **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
        targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore,
        test-native-session yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı
        değildir.

      **Denetim (2026-11-09) — yeniden açıldı:** Auto-save debounce, storage dizini politikası ve `kargu-session-list` (eski `kargu-session-storage-list-metadata`) hâlâ Elisp'te; ölçüt bunların Rust'ta olmasını istiyor. 7.5a sonrası: dizin türetme Rust'ta. Hâlâ açık: save record'u Elisp history/transcript'ten kuruluyor (native history snapshot değil); delete, bridge yoksa yerel `delete-file`'a düşüyor (ikinci writer); import kaynak dosyayı Elisp okuyor.

    - [x] **7.5d Fixture kabulü:** gerçek geçici disk + pipe'ta CRUD/import/restart,
      iki owner, stale revision, reply kaybı ve UI origin close'u çalıştır;
      gerçek kullanıcı session/config dosyasını veya secret'ını kullanma.

      **Önkoşul:** 7.5a–c; gerçek geçici depolama.

      **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
        kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
        chat/session.el, chat/session/, bridge/session.el. Fixture:
        kargu-core/tests/fixtures/session-{legacy,v2}.json.

      **Uygulama adımı:** Gerçek disk + binary + Emacs bridge üzerinden
        CRUD/import/restart testi kur; synthetic credentials/temporary user dirs kullan.
        Actor responsiveness ve late response'u da kontrol et.

      **Bitti sayılması için:** İki owner aynı ID'yi ele geçiremez; stale expected
        revision veya kapalı origin yeni veriyi silemez; kullanıcı session/config
        dosyalarına hiç dokunulmaz.

      **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
        targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore,
        test-native-session yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı
        değildir.

  - [ ] **7.6 Legacy temizliği ve kabul:** eski Elisp persistence writer/parser/
    worker'ını son consumer sonrası kaldır; yalnız geçici fixture'larla disk
    hata, lock, restart, migration ve iki owner kabulünü çalıştır.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 7.6a, 7.6b. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [ ] **7.6a Son writer temizliği:** `chat/session/{schema,storage,validate,
      restore,worker}.el`, session/history export ve `files/async.el` çağrılarını
      eşle; migration consumer'ı kalmadığında parser/writer/recovery engine'lerini
      kaldır. Emacs draft/buffer restore primitive'lerini koru.

      **Önkoşul:** 7.5d; 5.1b tüm import/export consumer'ları; 10.4b ve eski run actual drain.
        Son fiziksel worker/engine silmesi default ön-kapısının şartı değildir.

      **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
        kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
        chat/session.el, chat/session/, bridge/session.el. Fixture:
        kargu-core/tests/fixtures/session-{legacy,v2}.json.

      **Uygulama adımı:** Legacy session schema/storage/validate/worker ve files/async
        writer caller'larını çıkar; son consumer native'e geçince engine/require'ları
        sil, UI restore buffer primitive'i bırak.

      **Bitti sayılması için:** Native UI flow eski Emacs worker process başlatmaz;
        migration/export caller'ı kırılmaz; secret/current user's data fixture olarak
        kullanılmaz.

      **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
        targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore,
        test-native-session yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı
        değildir.

      **Denetim (2026-11-09) — yeniden açıldı:** `chat/session/{schema,storage,validate,worker}.el` duruyor ve kullanılıyor: `kargu-session--read-by-id` → `kargu-session-storage-read`, `kargu-session-list` → Elisp metadata okuyucu. Legacy reader/writer kaldırılmadı.

    - [x] **7.6b Retention/delete:** native count/byte/age retention, explicit
      delete ve owned temp cleanup davranışını belirle; aktif writer/foreign root
      silinmesin. Silme + yeniden açma ve eski callback yarışı fixture'la testli olsun.

      **Önkoşul:** 7.2a stable lock; 7.5a CRUD.

      **Başlangıç kaynakları:** Rust: history/, application/host.rs, ipc/transport.rs;
        kalıcı session storage implementasyonu geri alınmış, mevcut değil. Elisp:
        chat/session.el, chat/session/, bridge/session.el. Fixture:
        kargu-core/tests/fixtures/session-{legacy,v2}.json.

      **Uygulama adımı:** Count/byte/age retention ve explicit delete politikasını
        Rust'ta uygula; active writer/restore/import ile aynı lock ve revision sınırını
        paylaş.

      **Bitti sayılması için:** Aktif veya foreign session silinmez; delete+recreate
        eski callback'i yeni dosyaya yazdıramaz; limitte başarısız cleanup kalan
        kaynakları bırakmayı durdurmaz.

      **Doğrulama başlangıcı:** Yeni native persistence storage + gerçek stdio kabul
        targetı eklenecek; ERT test-session-storage, test-session-validate, test-session-restore,
        test-native-session yalnız başlangıç kaynaklarıdır, mock RPC backend kanıtı
        değildir.

- [ ] **8. İnce UI ve son application/global köprüleri** — chat/session routing,
  draft, provider/model/effort seçimi, stream/backpressure, plan ve confirmation
  UI'larını explicit native handle/DTO tüketicisi yap. Aktif run'ın backend/
  connection snapshot'ı sabit kalsın. Son consumer geçince compatibility circuit/
  catalog/job/edit/async tablolarını kaldır; passive UI yeni domain authority
  yaratmasın. Kaynak: [Aşama 3](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md)/[Aşama 6](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md), [G09](#g09--viewselection-olayları-ve-uçtan-uca-stream-baskısı)/[G13](#g13--son-köprü-temizliği-lint-ve-bütünleşik-kabul); [.agents/rules/connection-ownership.md](.agents/rules/connection-ownership.md).

  **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
    yazma. Alt teslimler: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6. İlgili açık alt işler, gerçek
    consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
    kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini atamaya
    ekle.

  - [x] **8.1 Chat/session routing:** explicit native application/session/run
    handle'larını draft, transcript ve terminal delivery'ye bağla; buffer
    değişimi/close/unload yabancı session'ı etkilemesin.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 8.1a, 8.1b. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [x] **8.1a Frontend handle store:** buffer başına opaque application/
      session/run/edit handle ve son revision'lı DTO tut; current-buffer/global
      loop üzerinden hedef seçme. UI point/window/draft state'i domain store değildir.

      **Önkoşul:** Mevcut application/conversation native lease; 0.2.

      **Başlangıç kaynakları:** Rust: ipc/sessions.rs, application/host.rs. Elisp:
        chat/routing.el, core/session.el, bridge/{application,conversation,session}.el.

      **Uygulama adımı:** Frontend buffer modelini opaque handles + last committed
        revision DTO + UI marker/draft olarak daralt; global/current-buffer ile domain
        hedefi seçen caller'ları değiştir.

      **Bitti sayılması için:** Aynı projedeki A/B chat farklı native session; origin
        kapanıp isim yeniden kullanılsa eski handle yeni buffer'a delivery yapmaz.

      **Doğrulama başlangıcı:** ERT test-session-routing, test-chat-target,
        test-native-conversation; Rust native_agent_ipc ile iki owner.

    - [x] **8.1b Routing kabulü:** chat değişimi, rename, aynı proje iki chat,
      buffer close/reopen ve draft/IME/Unicode/scroll korunumu; origin close
      başka session'ı abort etmesin, yeni buffer eski completion'ı almasın.

      **Önkoşul:** 8.1a; stream/reconcile portu.

      **Başlangıç kaynakları:** Rust: ipc/sessions.rs, application/host.rs. Elisp:
        chat/routing.el, core/session.el, bridge/{application,conversation,session}.el.

      **Uygulama adımı:** Rename/switch/close/reopen ve iki chat routing corpus'unu
        gerçek event delivery ile çalıştır; point/scroll/input draft/IME state'ini
        kaydet.

      **Bitti sayılması için:** Callback geldiğinde hangi buffer current olursa olsun
        doğru origin çizilir; foreign Stop yok, Unicode draft ve kullanıcı yazısı
        korunur.

      **Doğrulama başlangıcı:** ERT test-session-routing, test-chat-target,
        test-native-conversation; Rust native_agent_ipc ile iki owner.

  - [ ] **8.2 Config/selection:** provider/model/effort UI yalnız committed native
    DTO ve async intent tüketsin; aktif run'ın endpoint/auth/policy snapshot'ı
    seçim değişiminde veya retry'da değişmesin; fake default kimlik kullanma.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 8.2a, 8.2b, 8.2c, 8.2d, 8.2e. İlgili açık alt işler, gerçek
      consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu
      kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya
      sahipliğini atamaya ekle.

  - [x] **8.2a Katalog/seçim regresyonlarının düzeltilmesi:** public katalog
    native HTTP/metadata publication ve captured credential/epoch adaptörünü
    kullanır; refresh hatası eski listeyi başarılı sonuç saymaz. Application'lar
    arası global UI cache/ikinci selection writer kaldırıldı. Katalog/model/
    provider/seçim odak kabulü 75/75; credential fixture'ları da korunur.
  - [ ] **8.2b Config → provider → model listesi yalnız Rust:** config okuma/
    publication, provider registry, hedef/auth/wire çözümleme, HTTP, metadata
    commit ve eşzamanlı istek sırasını tek native akışta birleştir. Auth-source
    yalnız Rust'ın talep ettiği editör primitifi olsun. Public
    `kargu-api-list-models`/picker consumer'larını sonuç DTO'suna geçir; eski
    `api/catalog/request.el` orchestration'ını ve Elisp katalog cache/generation
    kararlarını kaldır. Config/credential hazırlığının UI tarafından sıralanması
    bu işin kapanışı değildir; özel provider kayıtlarını ve header ayarlarını koru.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 8.2b1, 8.2b2, 8.2b3, 8.2b4. İlgili açık alt işler, gerçek
      consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu
      kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya
      sahipliğini atamaya ekle.

    - [x] **8.2b1 Native config'ten HTTP capture temeli:** Rust yayımlanmış
      config'ten endpoint/credential/wire seçer; public endpoint credential
      istemez, custom override private policy kullanır, Anthropic x-api-key ve
      version header'ını korur. Yeni refresh çalışma ağacında exact epoch/
      application/session/config revision'a bağlıdır; değişen config, session
      close ve exact RPC cancel sonucu publish edemez. Bridge secret/URL çıkarmaz;
      native HTTP portunu kullanır. Genel picker/auth-source/registry cutover'ı
      ve ortak host entegrasyon commit'i bu temelin kapsamı dışındadır.
    - [x] **8.2b2 Native config orchestration:** path precedence/read/parse/
      publication, env/keyless ve credential ihtiyaçlarını Rust sıralasın;
      auth-source/callable editor primitive yalnız native talebe yanıt versin.
      Gerçek config refresh ile defaults bootstrap birbirini ezmesin; shared
      request varsa her waiter bağımsız owner/deadline/cancel ömrünü korusun.

      **Teslim (2026-11-07):** Yeni `configuration/refresh` RPC'si generation'ı
        Rust'ta ayırır, aday yol önceliğini (açık editor izni, yoksa
        `$XDG_CONFIG_HOME` mutlaksa onun, değilse `$HOME/.config` altındaki
        `kargu/config.toml`, sonra `user-emacs-directory/kargu.toml`) Rust'ta
        kurar, dosyayı worker'da okuyup ayrıştırır ve doğrudan stage eder; ayrışmış
        doküman artık Elisp'e dönmez. Editör yalnız konum gözlemlerini ve Rust'ın
        adlandırdığı env değerlerini verir. Defaults bootstrap yayım, staged capture
        veya okunan gerçek refresh varken `observed` döner ve hiçbir şeyi ezmez;
        gerçek refresh bootstrap capture'ını bayatlatır; başarısız okuma claim'ini
        bırakır. Elisp `configuration/read` portu (`kargu/bridge/config.el`) silindi;
        Elisp generation sayacı, read→parse→publish sıralaması ve sahte "absent"
        defaults kaydı kaldırıldı. `kargu-config-ensure-native-async` gerçek
        refresh sürerken kendi deadline/iptal ömrüyle ona katılır. TRAMP/göreli
        izinler Elisp'te reddedilir. Auth-source zaten yalnız Rust `interop`
        credential'ı istediğinde çalışır.
        **Kanıt:** Rust `configuration_refresh_ipc` 3/3 (öncelik, relative XDG,
        defaults/gerçek sıralama, invalid satır ve claim bırakma) + ordering birim
        testi; 600 locked Rust, strict Clippy/fmt. ERT: yeni
        `kargu-config-ensure-waits-for-a-pending-real-refresh-test` ve native
        supersede vakası; 15 eski port testi aynı davranışla yeni sözleşmeye
        taşındı. Tam ERT 1456/1456, bridge smoke 40/40, 207/207 üretim Elisp.
        **Kalan borç:** Rust `configuration/prepare` RPC'si editör tüketicisi
        olmadan yalnız sentetik politika testleri ve ERT fixture'ı için kalır;
        `configuration/read` RPC'sinin yalnız Rust testi tüketicisi var — ikisi
        de son temizlikte (10.4c/G13) kaldırılmalı veya test-only'ye indirilmeli.
        `kargu-config--observe` review-mode'u hâlâ Elisp defcustom'una uygular.

      **Önkoşul:** Mevcut native config read/publish; 0.2.

      **Başlangıç kaynakları:** Rust: configuration/policy/, models/service/,
        application/host.rs, ipc/read_tools.rs. Elisp: selection.el, config/service.el,
        api/catalog/request.el, chat/{select,tune}.el.

      **Uygulama adımı:** Config path/read/parse/publication ve credential ihtiyacını
        Rust orchestration'ına bağla; editor sadece Rust'ın istediği
        env/auth-source/callable gözlemini döndürsün.

      **Bitti sayılması için:** Defaults bootstrap gerçek refresh'i ezmez; shared
        request waiter'larının owner/deadline/cancel'i bağımsız; unrelated env/secret
        projection'a çıkmaz.

      **Doğrulama başlangıcı:** Rust configuration_policy, catalog_refresh_ipc,
        provider_rpc; ERT test-provider-selection, test-selection, test-config-native,
        test-native-model-consumers.

    - [ ] **8.2b3 Provider registry/list:** embedded/custom/API/application
      backend kayıtlarının namespace, availability ve config revision'lı DTO'su
      native olsun; Elisp kimlik, auth veya endpoint türetmesin. Gerekli alanların
      UI'a verilmesi secret/header'ın da projection'a eklenmesi anlamına gelmesin.

      **Önkoşul:** Native provider/config registry; 9.1 namespace contract.

      **Başlangıç kaynakları:** Rust: configuration/policy/, models/service/,
        application/host.rs, ipc/read_tools.rs. Elisp: selection.el, config/service.el,
        api/catalog/request.el, chat/{select,tune}.el.

      **Uygulama adımı:** API/custom/embedded ve application backend kayıtlarını native
        DTO'da namespace ve readiness ile listele; public register-provider façade'sı
        native writer kullansın.

      **Bitti sayılması için:** İki aynı display name kimliği karıştırmaz; authenticated
        görünümü UI key lookup'ı ile türetilmez; secret/header değerleri list DTO'ya
        konmaz.

      **Doğrulama başlangıcı:** Rust configuration_policy, catalog_refresh_ipc,
        provider_rpc; ERT test-provider-selection, test-selection, test-config-native,
        test-native-model-consumers.

    - [ ] **8.2b4 Discovery ve cache:** native refresh temelini public picker ve
      `kargu-api-list-models` consumer'ına bağla; exact lease/epoch/config revision,
      concurrent refresh sırası, stale/error ve authenticated/public hedef kararları
      Rust'ta. Cache TTL/cap/invalidation/last-good/error anlamı native'e ait olsun.

      **Önkoşul:** 8.2b2/b3; mevcut model/refresh capture worker.

      **Başlangıç kaynakları:** Rust: configuration/policy/, models/service/,
        application/host.rs, ipc/read_tools.rs. Elisp: selection.el, config/service.el,
        api/catalog/request.el, chat/{select,tune}.el.

      **Uygulama adımı:** Picker/list-models callback'ini native provider →
        endpoint/auth → HTTP → normalize → metadata/cache publish akışına geçir;
        same-lease order/revision/cancel'i sabitle.

      **Bitti sayılması için:** Geç eski refresh yeni config/model view'ını ezmez; HTTP
        error eski listeyi yeni başarı saymaz; frontend URL/key/HTTP orchestration
        çalıştırmaz.

      **Doğrulama başlangıcı:** Rust configuration_policy, catalog_refresh_ipc,
        provider_rpc; ERT test-provider-selection, test-selection, test-config-native,
        test-native-model-consumers.

  - [ ] **8.2c Native selection commit:** provider/model/effort/tuning intent'i
    native session'a expected revision ile commit edilsin; response sadece
    hesaplanmış seçim değil gerçek state/snapshot üretsin. Unknown model veya
    capability unknown ise invented tools/context/rate varsayılanı verme.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 8.2c1, 8.2c2. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [x] **8.2c1 Selection writer değişimi:** `kargu-selection-update/reset`
      şu anda `kargu-session-selection-value` alanına yerelde yazar. Bu writer'ı
      expected revision'lı native commit + detached snapshot ile değiştir;
      provider/model/effort atomik olsun. Başarısız intent yerel seçim bırakmasın.

      **Native port dilimi (2026-11-07):** Rust native conversation başına
        `application/selection.rs` store'u ve `session/selection` /
        `session/selection/commit` RPC'leri eklendi. Commit tam selection +
        `expected_revision` alır; stale revision `stale_revision`, aktif run veya
        hazırlık `busy`, yabancı/kapalı session `stale_owner` ile reddedilir ve
        committed değeri değiştirmez. Effort `inherit`/`off`/`named` olarak ayrı;
        provider `ApiProviderId` ile kanonikleşir, model/effort sınırlı ve
        kontrol karaktersizdir. Katalog üyeliği hâlâ picker'da; Rust doğrulamaz.
        Kanıt: 3 Rust birim/host testi + gerçek pipe ERT
        `kargu-bridge-real-core-session-selection-revision-test`; 596 locked Rust.
        **Consumer cutover (2026-11-07):** `kargu-selection-update/reset` artık
        doğrulanmış intent'i oturum başına seri kuyruğa koyar; gönderim anında son
        ACK'ten tam selection hesaplanır ve `kargu-selection-port` üzerinden
        (varsayılan [bridge/selection.el](kargu/bridge/selection.el), fallback yok)
        sohbetin native conversation'ına `expected_revision` ile commit edilir.
        `kargu-session-selection-value` yalnız native ACK ile yazılır; ret/stale/
        port hatası değeri değiştirmez ve callback'e gider. Revision conversation
        binding'inde tutulur; stale cevabı revision'ı tazeler, intent'i tekrar
        oynatmaz. `kargu-session-create :selection-value` ve `replace-usage`
        kopyası kaldırıldı; restore seçimini `kargu-selection-seed` ile yayımdan
        önce native commit eder, ret halinde yayımlamaz. chat/select ve
        config/schema devamları ACK callback'ine taşındı.
        **Kanıt:** `tests/test-selection-native.el` 6/6 (gerçek core ACK/kanonik
        provider/olay sırası, inherit/off/named round-trip, invalid ret, seri
        kuyruk birleşimi, port hatası, restore tohumlama ve ret); genel ERT
        fixture'ları Rust semantiğini taklit eden senkron `kargu-test-selection-port`
        kullanır. Tam ERT 1455/1455, bridge smoke 40/40, 208/208 üretim Elisp
        Werror/checkdoc, 596 locked Rust + strict Clippy/fmt.
        **Sınır:** Elisp `kargu-selection-busy-p` legacy run'lar için UI ön
        kontrolü olarak kalır (Rust yalnız native run/hazırlığı görür). Native
        run admission seçimi henüz bu store'dan yakalamaz; o bağ 5.4a'dadır.
        Katalog üyeliği hâlâ picker'da doğrulanır.

      **Önkoşul:** Native conversation/session; 0.2 selection contract.

      **Başlangıç kaynakları:** Rust: configuration/policy/, models/service/,
        application/host.rs, ipc/read_tools.rs. Elisp: selection.el, config/service.el,
        api/catalog/request.el, chat/{select,tune}.el.

      **Uygulama adımı:** selection-update/reset'in local setf writer'ını native
        expected-revision commit ile değiştir; yalnız ACK'in immutable seçim görünümünü
        publish et.

      **Bitti sayılması için:** Provider/model/effort tek atomik snapshot; failed/stale
        intent hiçbir yerel committed değişiklik bırakmaz; callback reentrancy daha yeni
        seçimi geriye almaz.

      **Doğrulama başlangıcı:** Rust configuration_policy, catalog_refresh_ipc,
        provider_rpc; ERT test-provider-selection, test-selection, test-config-native,
        test-native-model-consumers.

    - [ ] **8.2c2 Tuning/custom ayarlar:** `chat/tune.el` setter'ları ve
      `core/custom.el`deki domain preference'ları native typed intent'e bağla.
      Temperature/max_tokens/thinking budget, reasoning off/inherit ve low-usage,
      save/review policy ayrımını açık tut; Rust capability/bounds doğrulasın.
      Kullanıcı metni geçersizse eski committed ayar kalsın; UI parse sonucu
      örneğin keyfi string'i `0` yaparak başarılı ayar ilan etmesin.

      **Önkoşul:** 8.2c1; mevcut Rust request policy/metadata.

      **Başlangıç kaynakları:** Rust: configuration/policy/, models/service/,
        application/host.rs, ipc/read_tools.rs. Elisp: selection.el, config/service.el,
        api/catalog/request.el, chat/{select,tune}.el.

      **Uygulama adımı:** Tuning setters'dan raw kullanıcı isteğini Rust
        bounds/capability'ye gönder; editor-only display/review UI preference ile run
        domain preference'ı ayır.

      **Bitti sayılması için:** Garbage string 0 olarak kabul edilmez; 0/nil/off/inherit
        ayrı; unsupported effort/temperature ret'te eski ayar kalır, active run
        snapshot'ı değişmez.

      **Doğrulama başlangıcı:** Rust configuration_policy, catalog_refresh_ipc,
        provider_rpc; ERT test-provider-selection, test-selection, test-config-native,
        test-native-model-consumers.

  - [ ] **8.2d Frontend consumer ve yarış:** provider/model/effort picker,
    footer/company ve Transient yalnız list DTO + intent kullansın; superseded
    intent, origin close ve config/model revision değişimi eski seçimi commit
    etmesin. Aktif run'ın captured endpoint/auth/backend'i değişmesin.

    **Önkoşul:** 8.2b4; 8.2c1/c2.

    **Başlangıç kaynakları:** Rust: configuration/policy/, models/service/,
      application/host.rs, ipc/read_tools.rs. Elisp: selection.el, config/service.el,
      api/catalog/request.el, chat/{select,tune}.el.

    **Uygulama adımı:** Footer/company/Transient picker'larını yalnız native list ve
      intent commit'e bağla; async supersession ve origin cleanup'ını tek captured UI
      handle ile yap.

    **Bitti sayılması için:** A seçimini beklerken B seçilirse geç A ACK'i B'yi bozamaz;
      kapalı buffer callback'i başka chat'i seçmez; completion text'inden
      auth/capability kararı çıkmaz.

    **Doğrulama başlangıcı:** Rust configuration_policy, catalog_refresh_ipc,
      provider_rpc; ERT test-provider-selection, test-selection, test-config-native,
      test-native-model-consumers.

  - [ ] **8.2e Eski yolun kaldırılması:** `api/catalog/request.el`, selection/
    config-service/metadata tablolarındaki kalan orchestration/cache/generation
    kararlarını tüketicileriyle sil. Native refresh portu varken frontend'in
    URL/key çıkarıp HTTP sıralaması yapmadığını gerçek pipe/loopback ile doğrula.

    **Önkoşul:** 8.2b2–b4; 8.2c1/c2; 8.2d.

    **Başlangıç kaynakları:** Rust: configuration/policy/, models/service/,
      application/host.rs, ipc/read_tools.rs. Elisp: selection.el, config/service.el,
      api/catalog/request.el, chat/{select,tune}.el.

    **Uygulama adımı:** api/catalog/request, selection ve config/model cache'lerinde
      ikinci orchestration/generation/precedence writer'ı kaldır; immutable UI display
      index'i policy authority yapma.

    **Bitti sayılması için:** Gerçek pipe list/refresh/selection akışında frontend
      URL/key/HTTP çalıştırma mock'ları çağrılırsa test fail olur; passive getter yeni
      request açmaz.

    **Doğrulama başlangıcı:** Rust configuration_policy, catalog_refresh_ipc,
      provider_rpc; ERT test-provider-selection, test-selection, test-config-native,
      test-native-model-consumers.

  - [ ] **8.3 Stream/backpressure:** epoch/scope/revision/sequence kontrolü,
    bounded chunk sunumu, gap reconciliation ve tek terminal; geç/çift/foreign
    event ile kill-buffer/Stop yarışlarını gerçek pipe'ta doğrula.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 8.3a, 8.3b, 8.3c, 8.3d. İlgili açık alt işler, gerçek
      consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu
      kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya
      sahipliğini atamaya ekle.

    - [ ] **8.3a Bounded event queue:** native event/frame/chunk byte ve queue
      sınırı, cancellation/control yanıtlarının ilerlemesi ve backpressure;
      dropped/coalesced delta varsa sequence/snapshot semantiği açık olsun.

      **Önkoşul:** Mevcut bounded transport; 0.2 sequence contract.

      **Başlangıç kaynakları:** Rust: ipc/{protocol,transport,sessions}.rs, api/stream/.
        Elisp: bridge/session.el, loop/native.el, chat/{stream,transcript}.el.

      **Uygulama adımı:** Session stream event kuyruğu/frame/byte cap ve coalesce/drop
        kuralını Rust'ta tanımla; cancellation/reverse response kontrol trafiği aç
        kalmasın.

      **Bitti sayılması için:** Flood altında queue/memory üst sınırı aşılmaz;
        Stop/approval/reverse completion yanıt verebilir; silent gap varsa consumer
        snapshot ihtiyacını görür.

      **Doğrulama başlangıcı:** Rust stdio, api_stream, native_agent_ipc; ERT
        test-stream, test-native-session, test-chat ve gerçek pipe yoğunluk corpus.

    - [ ] **8.3b Frontend sunum:** UI timer ile bounded batch render, transcript/
      reasoning fragment ve point/draft korunumu; timer yalnız çizim planlasın,
      model continuation/tool/terminal kararı vermesin.

      **Önkoşul:** 8.3a; 8.1 handles.

      **Başlangıç kaynakları:** Rust: ipc/{protocol,transport,sessions}.rs, api/stream/.
        Elisp: bridge/session.el, loop/native.el, chat/{stream,transcript}.el.

      **Uygulama adımı:** Emacs render timer'ını bounded batch/face/scroll/input markers
        için tut; continuation/tool/terminal kararını timer'dan native FSM'ye bırak.

      **Bitti sayılması için:** Yoğun stream draft/IME metnini değiştirmez; UI batch
        boyutu bounded; kill-buffer timer'ı foreign buffer'a yazmaz ve domain state
        ilerletmez.

      **Doğrulama başlangıcı:** Rust stdio, api_stream, native_agent_ipc; ERT
        test-stream, test-native-session, test-chat ve gerçek pipe yoğunluk corpus.

    - [ ] **8.3c Recovery kabulü:** duplicate/out-of-order/gap/oversize/late chunk,
      Stop ile queued delta ve reconnect yeni epoch'u; snapshot ile exact state
      uzlaştırılsın, bir terminal iki kez çizilmesin. Gerçek pipe ve yoğun stream
      ölçümüyle UI responsiveness/queue cap'i doğrula.

      **Önkoşul:** 8.3a; native snapshot/sequence; 5.9h.

      **Başlangıç kaynakları:** Rust: ipc/{protocol,transport,sessions}.rs, api/stream/.
        Elisp: bridge/session.el, loop/native.el, chat/{stream,transcript}.el.

      **Uygulama adımı:** Gap/duplicate/reorder/old epoch/oversize ve reconnect
        corpus'unu aynı native session snapshot üzerinden uzlaştır; retry reset/terminal
        kuralını da kapsa.

      **Bitti sayılması için:** Tek terminal, sıfır duplicate answer; A'nın stale
        snapshot'ı B'yi ezmez; current request bitmeden old sentinel close yapamaz.

      **Doğrulama başlangıcı:** Rust stdio, api_stream, native_agent_ipc; ERT
        test-stream, test-native-session, test-chat ve gerçek pipe yoğunluk corpus.

    - [ ] **8.3d Reasoning/answer event ayrımı:** `chat/stream.el`deki
      `<think>` lexer'ı ve `kargu-loop-native-start` tek-string delta yolu yerine
      Rust'ın typed answer/reasoning/attempt/reset olayını tüket. Provider'a özgü
      reasoning ayırımı Rust codec'inde; UI face/scroll/folding kararları Emacs'te.
      Fragmented marker, literal code içindeki marker ve duplicate final text
      vakaları corpus'a eklensin; “bütün metni thought göster” fallback'i olmasın.

      **Önkoşul:** 8.3a; 5.5a2 native content normalization.

      **Başlangıç kaynakları:** Rust: ipc/{protocol,transport,sessions}.rs, api/stream/.
        Elisp: bridge/session.el, loop/native.el, chat/{stream,transcript}.el.

      **Uygulama adımı:** Rust answer/reasoning/attempt reset tipini native → bridge →
        render callback'e kayıpsız taşı; chat/stream tagged-text parser'ını son consumer
        sonrası kaldır.

      **Bitti sayılması için:** Gerçek typed reasoning thought face'te, kod içindeki
        literal <think> answer'da kalır; parçalı marker compatibility varsa Rust'ta
        birleşir; final text bir kez gösterilir.

      **Doğrulama başlangıcı:** Rust stdio, api_stream, native_agent_ipc; ERT
        test-stream, test-native-session, test-chat ve gerçek pipe yoğunluk corpus.

  - [ ] **8.4 Plan ve confirmation:** UI yalnız native plan/onay kimliğini
    göstersin; accept/reject/cancel aynı kapıya gitsin, string/metadata başarı
    yetkisi vermesin ve pending sunumlar kapanışta temizlensin.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 8.4a, 8.4b. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [ ] **8.4a Approval presenter:** native action/plan ID, scope/revision ve
      deadline göster; accept/reject/C-g/timeout/close tek karar portuna gitsin.
      Buton text'i, “approved” metadata veya eski transcript action'ı yetki vermesin.

      **Önkoşul:** 5.3a/b approval ledger; 5.7b native plan portu; existing review
        ports.

      **Başlangıç kaynakları:** Rust: security/{mod,editor,delegated}.rs; plan domain
        5.7. Elisp: bridge/approval.el, confirm.el, ui/confirm.el, plan/buffer.el.

      **Uygulama adımı:** Presenter'a immutable native action
        ID/scope/revision/deadline/summary ver; accept/reject/C-g/timeout/close'u tek
        intent olarak geri gönder.

      **Bitti sayılması için:** Buton metni veya 'approved' flag yetki değildir;
        superseded/expired approval işlem başlatmaz; headless/missing presenter
        fail-closed.

      **Doğrulama başlangıcı:** Rust editor_gate ve editor_issuance, ERT test-confirm,
        test-plan-async, test-native-edit-batch.

    - [ ] **8.4b UI cleanup:** pending confirmation/review/plan listeleri yalnız
      view reference tutsun; native supersede/close eventiyle kapansın. Headless
      veya missing presenter fail-closed olsun; başka origin'in popup'ı temizlenmesin.

      **Önkoşul:** 8.4a; UI origin handle.

      **Başlangıç kaynakları:** Rust: security/{mod,editor,delegated}.rs; plan domain
        5.7. Elisp: bridge/approval.el, confirm.el, ui/confirm.el, plan/buffer.el.

      **Uygulama adımı:** Pending popup/plan/review listelerini view reference olarak
        tut; native supersede/terminal ve origin close event'inde yalnız eşleşeni
        temizle.

      **Bitti sayılması için:** A'nın confirmation cancel'ı B popup'ını kapatmaz; native
        pending action actual settled olmadan UI cleanup drained diye raporlanmaz;
        hook/timer leak yok.

      **Doğrulama başlangıcı:** Rust editor_gate ve editor_issuance, ERT test-confirm,
        test-plan-async, test-native-edit-batch.

  - [ ] **8.5 Global köprü temizliği:** circuit/catalog/job/edit/async tabloları
    ve history/domain state'in kalan reader/writer envanterini çıkar; son
    consumer geçmeden silme, ikinci authority veya legacy fallback bırakma.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 8.5a, 8.5b, 8.5c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [ ] **8.5a Authority taraması:** `state/`, `selection.el`, `core/session.el`,
      application coordinator/reset/execution, loop/api/tools, permission ve plan
      tablolarında kalan mutable domain writer'ları 0.1 matrisiyle kapat.

      **Önkoşul:** 0.1 writer matrisi; 5/6/7 hazır native portları; final kaldırma için
        10.4b.

      **Başlangıç kaynakları:** Rust: application/, ipc/lifecycle.rs. Elisp: kargu.el
        (depo kökü), core/session.el, state/, application/, async.el ve ilgili
        bridge/worker modülleri.

      **Uygulama adımı:** state/selection/core-session/coordinator/reset/execution, loop
        ve plan'daki her setf/puthash/global read caller'ını native DTO veya ham editor
        bookkeeping olarak sınıflandır.

      **Bitti sayılması için:** Her surviving mutable alanın frontend gerekçesi/owner'ı
        açık; history/budget/selection/permission/run FSM için Elisp ikinci authority
        kalmaz.

      **Doğrulama başlangıcı:** ERT test-modules, test-application-context, test-async
        ve fiziksel optional-modül yokluğu testleri; static caller/writer envanteri.

    - [ ] **8.5b Composition/unload:** optional Eglot/Dape/company/Transient ve
      native binary eksikliği yüklemeyi çökertmesin; register/unregister/hook
      yalnız kendi handle'ını yönetip actual drain'i beklesin. Autoload/hook/keymap
      gibi Emacs kayıtlarını domain singleton sanıp kaldırma.

      **Önkoşul:** 8.5a; ilgili register/unregister ve drain portları.

      **Başlangıç kaynakları:** Rust: application/, ipc/lifecycle.rs. Elisp: kargu.el
        (depo kökü), core/session.el, state/, application/, async.el ve ilgili
        bridge/worker modülleri.

      **Uygulama adımı:** Physical optional module yokluğu ve unload/close sırasında
        native kaynak cleanup sırasını kur; Emacs hook/keymap/autoload'u yerel
        composition olarak tut.

      **Bitti sayılması için:** Eglot/Dape/company/Transient eksikliği unrelated core
        yüklemesini bozmaz; foreign resource kapanmaz, late callback yeni registration'a
        yazamaz.

      **Doğrulama başlangıcı:** ERT test-modules, test-application-context, test-async
        ve fiziksel optional-modül yokluğu testleri; static caller/writer envanteri.

    - [ ] **8.5c Worker sınıflandırması:** config credential worker, snapshot/
      session/file worker ve async task tablolarını tek tek değerlendir; Emacs-only
      ham kaynak erişimi gerekiyorsa dar primitive bırak, OS/domain işi için
      ikinci Emacs process veya fallback motoru tutma.

      **Önkoşul:** 0.1 worker/caller listesi; 7.6a ve 4.8 portları.

      **Başlangıç kaynakları:** Rust: application/, ipc/lifecycle.rs. Elisp: kargu.el
        (depo kökü), core/session.el, state/, application/, async.el ve ilgili
        bridge/worker modülleri.

      **Uygulama adımı:** Credential/file/session worker'larında editor-only source
        lookup ile domain/OS işi ayır; gerekliyse raw auth-source primitive'i tut,
        disk/engine işini Rust'a ver.

      **Bitti sayılması için:** Local worker kalıyorsa tek neden Emacs-only erişimdir;
        native failure sonrası ikinci worker backend fallback açılmaz; private
        credential input temizlenir.

      **Doğrulama başlangıcı:** ERT test-modules, test-application-context, test-async
        ve fiziksel optional-modül yokluğu testleri; static caller/writer envanteri.

  - [ ] **8.6 Kabul ve kapsam kanıtı:** iki application/session, origin close,
    stale selection, cancellation, missing capability ve gerçek GUI akışını
    doğrula; passive UI getter'ları gizli RPC/IO başlatmasın.

    **Önkoşul:** 8.1–8.4 native opt-in consumer portları; 0.1 kaynak/caller matrisi.

    **Başlangıç kaynakları:** 8.1–8.5 ve 3/4/5/6/7 consumer teslimleri;
      tests/test-chat.el, tests/test-native-loop.el.

    **Uygulama adımı:** Native opt-in yolda iki application/session, missing capability,
      selection race, passive UI ve GUI consumer corpus'unu çalıştır; fiziksel legacy
      silmeyi bekleyerek 10.4a kapısını döngüye sokma. Cleanup sonrası nihai tarama/GUI
      kabulü 10.3c/10.6'dadır.

    **Bitti sayılması için:** Native seçiliyken UI yalnız intent/DTO/raw editor
      primitive çalıştırır; core olmadan pasif getter process/RPC açmaz; GUI ve mock
      kabulü ayrıdır. İnaktif legacy dosyası varlığı bu ön-kapıda gizlenmez.

    **Doğrulama başlangıcı:** Headless ERT + gerçek pipe + ayrı GUI kabul; pasif getter
      testinde RPC/process başlatma yasak.

- [ ] **9. Dört kurulu uygulama backend'i ve ayrı MCP portu** — API desteğini
  koruyarak Codex, Antigravity, Claude Code ve OpenCode'u aynı GUI provider alanına
  bağla. Her birinde bounded kurulum/sürüm/protokol/auth discovery, readiness nedeni,
  gerçek turn/stream/terminal/Stop/session ve destekleniyorsa resume/usage/model/
  effort capability'sini ayrı doğrula. Önce offline fixture; resmi entegrasyon yolu
  doğrulanmadan CLI bayrağı/port uydurma. MCP-only Antigravity backend teslimi
  sayılmaz; biri engelliyse kendi kabul kutusu açık kalır. Canlı hesap/model turu,
  login, kurulum ve credential taşıma ayrıca onay ister. Kaynak: [Aşama 5](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md), [G12](#g12--nativefake-agent-backend-portu);
  [03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md)'ün dört ayrı backend kabulü ve MCP topolojisi.

  **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
    yazma. Alt teslimler: 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7, 9.8, 9.9, 9.10. İlgili açık
    alt işler, gerçek consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı
    tamamlanmadan bu kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve
    dosya sahipliğini atamaya ekle.

  - [ ] **9.1 Backend domain/port:** direct API completion, native agent ve
    kendi loop'u olan harici backend ayrı capability; start/cancel/resume/event/
    usage/approval ve external thread/turn ↔ native session/run eşlemesi Rust'ta.
    Backend kendi loop'unu yürütürken Kargu ikinci model/tool loop'u açmasın.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 9.1a. İlgili açık alt işler, gerçek consumer entegrasyonu ve
      gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu kapatma. Ajanlara tek
      bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini atamaya ekle.

    - [ ] **9.1a Ortak fake/native backend contract:** mevcut
      `tests/test-fake-agent.el` yalnız Elisp fixture'ıdır. Aynı UI intent/event/
      cancel sözleşmesini native backend portu ve offline fake adapter ile çalıştır;
      kendi loop'u olan backend'i completion API'si gibi ele alıp ikinci loop açma.

      **Önkoşul:** 0.2 backend capability/event contract; mevcut native agent.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** Native agent, offline fake ve harici backend için dar
        start/event/cancel/session portunu tanımla; fake UI corpus'unu bu portta tekrar
        kullan, çalışan native FSM'yi yeniden yazma.

      **Bitti sayılması için:** Completion-only ve agent-with-tools ayrıdır; aynı intent
        iki loop başlatmaz; unsupported resume/usage/approval explicit capability, yeni
        fake başarısı canlı backend değildir.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

  - [ ] **9.2 Discovery/readiness:** Rust bounded PATH/explicit executable ve
    sürüm/protokol/config/auth probe'u; NotInstalled/Unverified/NeedsLogin/
    UnsupportedVersion/Protocol/ProbeFailed/Ready DTO'sunu üret. Probe gizli
    login/kurulum/ücretli turn başlatmasın; UI yalnız nedeni göstersin.

    **Önkoşul:** 9.1 contract; mevcut Rust process/probe.

    **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
      backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
      chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

    **Uygulama adımı:** Bounded executable/version/protocol/auth readiness worker'ını
      native'de kur; readonly discovery'yi paid turn/login/install'den ayır ve immutable
      revision'lı snapshot yayımla.

    **Bitti sayılması için:** Eksik binary listede çalışır diye görünmez; probe
      timeout/garbage unsupported olur; UI açılması ücretli turn veya kurulum başlatmaz.

    **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
      yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract corpus
      eklenmeli, canlı kabul ayrı.

  - [ ] **9.3 Codex adapter'ı:** uygulama öncesi resmi protokolü ve sabitlenen
    kurulu binary şemasını doğrula; initialize, thread/turn/stream/terminal,
    approval/cancel ve varsa resume/usage/model/effort mapping'i offline fixture
    ile bağla. Aynı kabul paketi ve güvenlik sınırı geçmeden Ready ilan etme.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 9.3a, 9.3b, 9.3c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [ ] **9.3a Protokol/codec (Codex):** resmi kaynak + desteklenen
      sürüm/schema kanıtı, bounded handshake/event/terminal parser ve malformed/
      partial/unknown event fixture'ları. Bu teslim gerçek backend readiness değildir.

      **Önkoşul:** 9.1/9.2; [03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md); ilgili resmi kaynak/kurulu sürüm.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** Codex için desteklenecek protokol ve sürümü uygulama sırasında
        resmi doküman/yerel schema ile doğrula; handshake/event/result codec ve
        kaydedilmiş sentetik wire fixture oluştur. CLI flag/port tahmin etme.

      **Bitti sayılması için:** Malformed/partial/unknown event, version mismatch ve
        byte cap testli; kaynak/sürüm/schema kanıtı teslimde, çalışan adapter varmış
        gibi Ready sonucu yok.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

    - [ ] **9.3b Lifecycle/otorite (Codex):** owned session/turn mapping,
      actual Stop/drain, disconnect/restart/no replay, varsa resume/usage/approval;
      child process/servis sahipliği ve dirty buffer/gate sınırı testli olsun.

      **Önkoşul:** 9.3a; 9.8 güvenlik sınırı; mevcut Rust supervisor.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** Codex adapterında external thread/turn ID → native session/run
        eşlemesi, start/stream/terminal ve actual Stop/drain kur; desteklenen
        resume/usage/approval capability ayrı olsun.

      **Bitti sayılması için:** Disconnect/late event/duplicate terminal ikinci turn
        veya foreign close üretmez; owned/shared process ayrımı kanıtlı; unknown usage
        maliyetsiz sayılmaz.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

    - [ ] **9.3c Consumer/kabul (Codex):** native provider listesi ve GUI
      seçiminden prompt/stream/terminal/cancel'e ortak contract suite; optional
      capability'ler ve missing/unready nedeni. Offline fixture ile ayrıca
      yetkilendirilmiş canlı kabulün sonuçları ayrı kaydedilsin.

      **Önkoşul:** 9.3b; 8.2 picker; 9.2 readiness.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** Codex için UI provider seçiminden ortak native backend
        contract suite çalıştır; offline fake codec ile ayrıca yetkilendirilmiş canlı
        turn kanıtını ayır.

      **Bitti sayılması için:** Native provider DTO ile prompt/stream/terminal/Stop ve
        iki session izolasyonu geçer; eksik live binary/auth veya optional capability
        açık engel olarak kalır.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

  - [ ] **9.4 Claude Code adapter'ı:** sürüme bağlı resmi headless giriş/çıkış
    sözleşmesini doğrula; stdin/argv ve bounded stream parser, result + exit
    eşlemesi, Stop ve session isolation. Resume/usage/approval yoksa açık capability
    eksikliği; fixture ve kontrollü entegrasyon kanıtı ayrı olsun.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 9.4a, 9.4b, 9.4c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [ ] **9.4a Protokol/codec (Claude Code):** resmi kaynak + desteklenen
      sürüm/schema kanıtı, bounded handshake/event/terminal parser ve malformed/
      partial/unknown event fixture'ları. Bu teslim gerçek backend readiness değildir.

      **Önkoşul:** 9.1/9.2; [03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md); ilgili resmi kaynak/kurulu sürüm.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** Claude Code için desteklenecek protokol ve sürümü uygulama
        sırasında resmi doküman/yerel schema ile doğrula; handshake/event/result codec
        ve kaydedilmiş sentetik wire fixture oluştur. CLI flag/port tahmin etme.

      **Bitti sayılması için:** Malformed/partial/unknown event, version mismatch ve
        byte cap testli; kaynak/sürüm/schema kanıtı teslimde, çalışan adapter varmış
        gibi Ready sonucu yok.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

    - [ ] **9.4b Lifecycle/otorite (Claude Code):** owned session/turn mapping,
      actual Stop/drain, disconnect/restart/no replay, varsa resume/usage/approval;
      child process/servis sahipliği ve dirty buffer/gate sınırı testli olsun.

      **Önkoşul:** 9.4a; 9.8 güvenlik sınırı; mevcut Rust supervisor.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** Claude Code adapterında external thread/turn ID → native
        session/run eşlemesi, start/stream/terminal ve actual Stop/drain kur;
        desteklenen resume/usage/approval capability ayrı olsun.

      **Bitti sayılması için:** Disconnect/late event/duplicate terminal ikinci turn
        veya foreign close üretmez; owned/shared process ayrımı kanıtlı; unknown usage
        maliyetsiz sayılmaz.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

    - [ ] **9.4c Consumer/kabul (Claude Code):** native provider listesi ve GUI
      seçiminden prompt/stream/terminal/cancel'e ortak contract suite; optional
      capability'ler ve missing/unready nedeni. Offline fixture ile ayrıca
      yetkilendirilmiş canlı kabulün sonuçları ayrı kaydedilsin.

      **Önkoşul:** 9.4b; 8.2 picker; 9.2 readiness.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** Claude Code için UI provider seçiminden ortak native backend
        contract suite çalıştır; offline fake codec ile ayrıca yetkilendirilmiş canlı
        turn kanıtını ayır.

      **Bitti sayılması için:** Native provider DTO ile prompt/stream/terminal/Stop ve
        iki session izolasyonu geçer; eksik live binary/auth veya optional capability
        açık engel olarak kalır.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

  - [ ] **9.5 OpenCode adapter'ı:** resmi desteklenen CLI/server yolunu kurulu
    sürümle doğrula; start/attach ownership, event normalizasyonu, cancel ve
    session mapping. Paylaşılan servis/foreign konuşmayı Stop ile kapatma;
    desteklenen optional capability'leri ayrı test et.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 9.5a, 9.5b, 9.5c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [ ] **9.5a Protokol/codec (OpenCode):** resmi kaynak + desteklenen
      sürüm/schema kanıtı, bounded handshake/event/terminal parser ve malformed/
      partial/unknown event fixture'ları. Bu teslim gerçek backend readiness değildir.

      **Önkoşul:** 9.1/9.2; [03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md); ilgili resmi kaynak/kurulu sürüm.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** OpenCode için desteklenecek protokol ve sürümü uygulama
        sırasında resmi doküman/yerel schema ile doğrula; handshake/event/result codec
        ve kaydedilmiş sentetik wire fixture oluştur. CLI flag/port tahmin etme.

      **Bitti sayılması için:** Malformed/partial/unknown event, version mismatch ve
        byte cap testli; kaynak/sürüm/schema kanıtı teslimde, çalışan adapter varmış
        gibi Ready sonucu yok.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

    - [ ] **9.5b Lifecycle/otorite (OpenCode):** owned session/turn mapping,
      actual Stop/drain, disconnect/restart/no replay, varsa resume/usage/approval;
      child process/servis sahipliği ve dirty buffer/gate sınırı testli olsun.

      **Önkoşul:** 9.5a; 9.8 güvenlik sınırı; mevcut Rust supervisor.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** OpenCode adapterında external thread/turn ID → native
        session/run eşlemesi, start/stream/terminal ve actual Stop/drain kur;
        desteklenen resume/usage/approval capability ayrı olsun.

      **Bitti sayılması için:** Disconnect/late event/duplicate terminal ikinci turn
        veya foreign close üretmez; owned/shared process ayrımı kanıtlı; unknown usage
        maliyetsiz sayılmaz.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

    - [ ] **9.5c Consumer/kabul (OpenCode):** native provider listesi ve GUI
      seçiminden prompt/stream/terminal/cancel'e ortak contract suite; optional
      capability'ler ve missing/unready nedeni. Offline fixture ile ayrıca
      yetkilendirilmiş canlı kabulün sonuçları ayrı kaydedilsin.

      **Önkoşul:** 9.5b; 8.2 picker; 9.2 readiness.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** OpenCode için UI provider seçiminden ortak native backend
        contract suite çalıştır; offline fake codec ile ayrıca yetkilendirilmiş canlı
        turn kanıtını ayır.

      **Bitti sayılması için:** Native provider DTO ile prompt/stream/terminal/Stop ve
        iki session izolasyonu geçer; eksik live binary/auth veya optional capability
        açık engel olarak kalır.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

  - [ ] **9.6 Antigravity adapter'ı:** resmi desteklenen conversation protokolünü
    doğrula; init/update/result, conversation identity, cancel ve varsa cumulative
    usage normalizasyonunu fixture'la kanıtla. MCP erişimi veya desktop kurulumu
    konuşma backend kabulü değildir; doğrulanamayan bölüm açık engel kalsın.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 9.6a, 9.6b, 9.6c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [ ] **9.6a Protokol/codec (Antigravity):** resmi kaynak + desteklenen
      sürüm/schema kanıtı, bounded handshake/event/terminal parser ve malformed/
      partial/unknown event fixture'ları. Bu teslim gerçek backend readiness değildir.

      **Önkoşul:** 9.1/9.2; [03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md); ilgili resmi kaynak/kurulu sürüm.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** Antigravity için desteklenecek protokol ve sürümü uygulama
        sırasında resmi doküman/yerel schema ile doğrula; handshake/event/result codec
        ve kaydedilmiş sentetik wire fixture oluştur. CLI flag/port tahmin etme.

      **Bitti sayılması için:** Malformed/partial/unknown event, version mismatch ve
        byte cap testli; kaynak/sürüm/schema kanıtı teslimde, çalışan adapter varmış
        gibi Ready sonucu yok.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

    - [ ] **9.6b Lifecycle/otorite (Antigravity):** owned session/turn mapping,
      actual Stop/drain, disconnect/restart/no replay, varsa resume/usage/approval;
      child process/servis sahipliği ve dirty buffer/gate sınırı testli olsun.

      **Önkoşul:** 9.6a; 9.8 güvenlik sınırı; mevcut Rust supervisor.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** Antigravity adapterında external thread/turn ID → native
        session/run eşlemesi, start/stream/terminal ve actual Stop/drain kur;
        desteklenen resume/usage/approval capability ayrı olsun.

      **Bitti sayılması için:** Disconnect/late event/duplicate terminal ikinci turn
        veya foreign close üretmez; owned/shared process ayrımı kanıtlı; unknown usage
        maliyetsiz sayılmaz.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

    - [ ] **9.6c Consumer/kabul (Antigravity):** native provider listesi ve GUI
      seçiminden prompt/stream/terminal/cancel'e ortak contract suite; optional
      capability'ler ve missing/unready nedeni. Offline fixture ile ayrıca
      yetkilendirilmiş canlı kabulün sonuçları ayrı kaydedilsin.

      **Önkoşul:** 9.6b; 8.2 picker; 9.2 readiness.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** Antigravity için UI provider seçiminden ortak native backend
        contract suite çalıştır; offline fake codec ile ayrıca yetkilendirilmiş canlı
        turn kanıtını ayır.

      **Bitti sayılması için:** Native provider DTO ile prompt/stream/terminal/Stop ve
        iki session izolasyonu geçer; eksik live binary/auth veya optional capability
        açık engel olarak kalır.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

  - [ ] **9.7 Her adapter için ayrı kabul:** 9.3–9.6 tek ajana dev paket verilmesin;
    her biri şu alt teslimleri ayrı yapsın: sürüm/protokol kanıtı → offline codec
    fixture'ı → Rust lifecycle/session portu → UI provider consumer → güvenlik ve
    ortak contract kabulü. Dördünden biri eksikse üst 9 açık kalır.

    **Önkoşul:** 9.3–9.6 her bir adapter'ın ayrı teslimi.

    **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
      backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
      chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

    **Uygulama adımı:** Dört adapter'ın codec/lifecycle/UI/security/fixture ve canlı
      kabul sütunlarını tek tabloda kontrol et; eksik olanı açık tut, diğerlerinin
      başarısıyla kapatma.

    **Bitti sayılması için:** Dört ayrı satırda kanıt/engel var; MCP-only Antigravity
      veya native fake test dört-backend teslimi sayılmaz.

    **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
      yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract corpus
      eklenmeli, canlı kabul ayrı.

  - [ ] **9.8 Tool/izin ve dosya güvenliği:** harici backend'in kendi Bash/Edit
    etkilerinin Kargu gate'inden geçip geçmediğini belge ve fixture ile kanıtla.
    Geçmiyorsa eşdeğer desteklenen kontrol/izolasyon veya açık read-only sınır;
    dirty buffer'a dışarıdan yazma ve yetki varmış gibi UI sunma yasak. Yerel
    Kargu approval'ı foreign backend'in onayını verdiği iddiasına dönüşmesin.

    **Önkoşul:** 9.1 ve ilgili adapter prototype; 5.3 gate.

    **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
      backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
      chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

    **Uygulama adımı:** Harici agent'ın own tool effect'inin nereden geçtiğini doğrula;
      Kargu gate'e delegasyon/eşdeğer desteklenen kontrol yoksa açık read-only
      capability sınırı uygula.

    **Bitti sayılması için:** Foreign agent Kargu onayı verilmiş gibi yazamaz; dirty
      live buffer dışarıdan ezilmez; shared foreign process topluca öldürülmez; garanti
      belgesiz genişletilmez.

    **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
      yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract corpus
      eklenmeli, canlı kabul ayrı.

  - [ ] **9.9 Ayrı MCP portu:** editor araç sunumu ayrı Rust adapter/auth/scope ve
    capability; stdio/proxy topolojisini [03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md)'e göre uygula. Connection başına
    session/permission/byte/deadline sınırı; tool list/call, missing adapter,
    foreign owner ve disconnect cleanup kabulü. MCP, backend selection'ı kapatmaz.

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 9.9a, 9.9b, 9.9c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [ ] **9.9a Protokol/keşif:** desteklenen MCP sürüm/transport ve tool schema
      asset'lerini native registry/gate'e bağla; resource/tool capability'leri
      açık, malformed/oversize mesaj ve unsupported version sonucu typed olsun.

      **Önkoşul:** 9.1 session/event kavramları; native trusted registry.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** MCP sürüm/transport codec, list/call schema ve discovery
        capability'lerini native portlara bağla; mevcut Kargu IPC envelope'unu rastgele
        MCP formatına dönüştürme.

      **Bitti sayılması için:** Malformed/oversize/unknown method typed error; schema
        binary ile eşleşir; MCP tool availability agent backend readiness'i değildir.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

    - [ ] **9.9b Caller yetkisi:** MCP connection/owner kimliğini native session
      ve explicit editor grant'e bağla; authentication yokluğu veya tool adına
      erişim workspace/editor mutation izni vermesin.

      **Önkoşul:** 9.9a; 5.3 native permissions; 4.8c grants.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** MCP connection kimliğini owner/session/root/editor grants ve
        auth sınırına bağla; tool-list erişimini tool-execution izni sayma.

      **Bitti sayılması için:** Foreign connection aynı ID ile editor mutation yapamaz;
        missing auth/grant read veya write izni doğurmaz; secret/control bilgisi tool
        response'a sızmaz.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

    - [ ] **9.9c Yaşam döngüsü/kabul:** tool call → approval/reverse editor → tek
      sonuç, cancel/disconnect/EOF ve stale/foreign completion ortak native
      lifecycle'da; MCP-only kullanım agent-backend testini tamamlamasın.

      **Önkoşul:** 9.9a/b; 4.2 actual reverse drain.

      **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
        backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
        chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

      **Uygulama adımı:** MCP call/approval/editor reverse/result/cancel/disconnect'i
        native child lifecycle'a bağla; owned proxy/session cleanup'ını test et.

      **Bitti sayılması için:** Tek result; EOF sonrası actual issued operation settle
        olmadan kaynak release yok; duplicate/foreign response etkisiz, ikinci tool
        replay yok.

      **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
        yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract
        corpus eklenmeli, canlı kabul ayrı.

  - [ ] **9.10 Provider UI ve kabul:** API/Uygulamalar aynı picker'da native DTO;
    missing/unready nedenleri görünür, aktif run backend'i sabit. Dört adapter'da
    prompt → stream → terminal → Stop/session isolation; resume/usage/effort ayrı
    capability. Canlı hesap/ücretli turn/kurulum ancak ayrıca verilen yetkiyle;
    offline başarıyı canlı kabul diye işaretleme.

    **Önkoşul:** 9.2 readiness; 9.3–9.6 adapters; 8.2 picker.

    **Başlangıç kaynakları:** Rust: application/agent/, process/, ipc/; harici
      backend/discovery/MCP adapter modülleri henüz mevcut değil. Elisp: chat/select/,
      chat/tune.el. Sözleşme: [.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md](.agents/skills/external-bridges/references/03_EXTERNAL_BRIDGES.md).

    **Uygulama adımı:** API ve application backend'leri aynı native list DTO'suyla
      gruplu sun; unready nedenini göster ve yalnız Ready seçim için prompt admission
      uygula.

    **Bitti sayılması için:** Her adapter için seçim → prompt → stream → terminal →
      Stop/session izolasyonu kanıtlı; unsupported feature uydurulmaz; active run'da
      başka backend'e otomatik geçilmez.

    **Doğrulama başlangıcı:** Mevcut test-fake-agent + test-native-loop başlangıç; her
      yeni Rust adapter için offline codec/lifecycle ve aynı provider UI contract corpus
      eklenmeli, canlı kabul ayrı.

- [ ] **10. Son kabul, varsayılan cutover ve paketleme** — G03/G11 log gizliliği,
  retention/egress ve [01_RUST_CORE_PATTERNS.md](.agents/skills/coding-standards/references/01_RUST_CORE_PATTERNS.md)/[39_RUST_PATTERN_AUDIT.md](.agents/skills/coding-standards/references/39_RUST_PATTERN_AUDIT.md) uyum açıklarını gerçek consumer'larda kapat.
  Missing-module, version mismatch, clean-machine startup, release binary/asset
  paketi ve export/geri dönüş sınırını doğrula. Tüm ERT, locked native test,
  compile-fail, fmt, strict Clippy ve uyarısız değişen Elisp geçsin; yalnız
  TLA+ kaynağı değişen ilgili exhaustive modeller çalıştırılsın. Uçtan uca
  eşdeğerlikten sonra Rust agent default olsun; yalnız
  o zaman son legacy backend/engine kaynaklarını sil. Thin editor adapter'ları
  kalır; merge/push ayrıca onay ister. Kaynak: [Aşama 6](.agents/skills/native-migration/references/04_PHASED_ROADMAP.md), [G03](#g03--log-gizliliği-sahipli-retention-ve-ölçüm)/[G11](#g11--proje-bağlamı-egress-ve-adapter-güvenliği)/[G13](#g13--son-köprü-temizliği-lint-ve-bütünleşik-kabul).

  **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
    yazma. Alt teslimler: 10.1, 10.2, 10.3, 10.4, 10.5, 10.6. İlgili açık alt işler,
    gerçek consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu
    kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
    atamaya ekle.

  - [ ] **10.1 Gizlilik ve retention (G03/G10):**

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 10.1a, 10.1b, 10.1c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [ ] **10.1a Native log sınırı:** Rust tracing/error/export'ta metadata
      allowlist + secret/URL/header/upstream echo redaction; payload Debug ve
      deserialization hata metni de kapsansın. Native log DTO'sunu Elisp göstersin;
      redaction hatası raw fallback üretmesin.

      **Önkoşul:** 0.2 log/error DTO; ilgili native producer.

      **Başlangıç kaynakları:** Rust: error.rs, ipc/, api/, process/ hata/Debug/export
        sınırları; logging policy portu eklenecek. Elisp: core/log.el,
        api/{retry,response}.el, tools/execution.el.

      **Uygulama adımı:** Native error/Debug/stderr/wire/export sınırında metadata
        allowlist ve known-secret/structured-field redaction kur; core/log UI'a yalnız
        güvenli DTO göster. Tracing framework eklemek şart değil; mevcut safe
        boundary'yi kullan.

      **Bitti sayılması için:** Raw body/header/key/log'a yazılıp sonradan temizlenmez;
        malformed/echo/truncation/format error ham fallback doğurmaz; UI opt-in wire
        view dahi documented scope'ta redacted.

      **Doğrulama başlangıcı:** ERT test-security/test-contract/test-process; sentetik
        secret native error/stderr/UI/export corpus; gerçek anahtar kullanılmaz.

    - [ ] **10.1b Owner/cap/cleanup:** logs/history/session/job/output için ayrı
      scope ve byte/count/age politikalarını envanterle; process-local/kalıcı
      kaynak farkını belirt. Foreign owner retention/delete ile silinmesin.

      **Önkoşul:** 7.6b storage retention; 5.6e archive; native process output.

      **Başlangıç kaynakları:** Rust: error.rs, ipc/, api/, process/ hata/Debug/export
        sınırları; logging policy portu eklenecek. Elisp: core/log.el,
        api/{retry,response}.el, tools/execution.el.

      **Uygulama adımı:** Log/history/session/job/output retention owner/birim/limit
        tablosu çıkar ve native silme/evict politikasına bağla; UI display buffer cap'i
        domain retention yerine geçmesin.

      **Bitti sayılması için:** Bir büyük kayıt cap'i aşamaz; zero retention anlamı net;
        foreign owner, user-modified/generated-olmayan buffer veya active writer
        silinmez.

      **Doğrulama başlangıcı:** ERT test-security/test-contract/test-process; sentetik
        secret native error/stderr/UI/export corpus; gerçek anahtar kullanılmaz.

    - [ ] **10.1c Kanıt:** sentetik nested secret, malformed JSON, truncation,
      stdout/stderr/export ve iki owner; her yazımda cap ve sıfır retention.
      Native allocation/tepe bellek ölçümünü UI render maliyetinden ayır.

      **Önkoşul:** 10.1a/b.

      **Başlangıç kaynakları:** Rust: error.rs, ipc/, api/, process/ hata/Debug/export
        sınırları; logging policy portu eklenecek. Elisp: core/log.el,
        api/{retry,response}.el, tools/execution.el.

      **Uygulama adımı:** Sentetik nested key/token/URL query/upstream echo ve
        malformed/truncated içerikle native producer → transport → UI/export akışını
        test et; trim/allocation ölçümünü ayrı kaydet.

      **Bitti sayılması için:** Her boundary çıkışında secret yok, raw temp copy yok;
        iki owner izolasyonu ve her yazım sonrası cap kanıtlı; regex tüm sırları bulur
        diye garanti verilmez.

      **Doğrulama başlangıcı:** ERT test-security/test-contract/test-process; sentetik
        secret native error/stderr/UI/export corpus; gerçek anahtar kullanılmaz.

  - [ ] **10.2 Egress ve proje güveni (G11):**

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 10.2a, 10.2b, 10.2c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [ ] **10.2a Trust politikası:** kullanıcı config'i, güvenilen proje
      instruction/policy ve dosya/web/tool içeriğini native trust tiplerinde ayır;
      proje dosyası executable/permission/credential yetkisini sessiz genişletmesin.

      **Önkoşul:** 0.2 trust contract; 4.9a provenance; 5.13a instruction sources.

      **Başlangıç kaynakları:** Rust: security/, workspace/{file,git,webfetch}/,
        providers/. Elisp: permission/guards.el, chat/attach.el, prompt.el.

      **Uygulama adımı:** User configuration, trusted project policy/instruction ve
        untrusted model/file/tool/web içeriğini native trust türü/metadata ile ayır;
        yetki yükselten merge alanlarını kapat.

      **Bitti sayılması için:** Proje dosyası executable/auth/permission/egress'i user
        policy dışında genişletemez; prompt injection string'i policy command olarak
        yorumlanmaz.

      **Doğrulama başlangıcı:** Rust file_reads, git_mutations, catalog_target ve
        webfetch testleri; ERT test-security, test-attach, test-native-ownership.

    - [ ] **10.2b Destination admission:** context attachment, provider ve
      external backend snapshot'ında root/origin/secret/egress kararını kontrol et;
      context hazırlandıktan sonra hedef değişirse izin tekrar bağlansın.

      **Önkoşul:** 10.2a; 4.9b; 8.2 config/backend snapshot.

      **Başlangıç kaynakları:** Rust: security/, workspace/{file,git,webfetch}/,
        providers/. Elisp: permission/guards.el, chat/attach.el, prompt.el.

      **Uygulama adımı:** Payload gönderiminden önce attachment origin/root/secret
        grant'ini captured destination/provider/backend'e bağla; hedef değiştiğinde eski
        egress receipt'i kullanma.

      **Bitti sayılması için:** Local provider için seçilen hassas context başka remote
        backend'e sessiz gitmez; UI completion listesinde görünen path gönderim izni
        değildir.

      **Doğrulama başlangıcı:** Rust file_reads, git_mutations, catalog_target ve
        webfetch testleri; ERT test-security, test-attach, test-native-ownership.

    - [ ] **10.2c OS/adapter kabulü:** PATH/executable/config değişimi, symlink/
      TOCTOU/root escape, option injection, Git hook/config, DNS/redirect ve remote
      kaynak corpus'u; mevcut native güvenlik primitive'lerini yeniden kullan.
      Verilmeyen OS sandbox veya power-loss garantisini dokümana ekleme.

      **Önkoşul:** 10.2a/b; mevcut native security primitives.

      **Başlangıç kaynakları:** Rust: security/, workspace/{file,git,webfetch}/,
        providers/. Elisp: permission/guards.el, chat/attach.el, prompt.el.

      **Uygulama adımı:** PATH/executable/config/root symlink değişimi, argv/option
        injection, Git hook/config ve DNS/redirect corpus'unu gerçek adapter sınırında
        çalıştır; security engine'ini yeniden yazma.

      **Bitti sayılması için:** Capture sonrası değişen hedef yetkisiz effect'e
        dönüşmez; unsupported isolation sınırı dürüst; izin dialog'u veya canonical path
        kontrolü OS sandbox diye adlandırılmaz.

      **Doğrulama başlangıcı:** Rust file_reads, git_mutations, catalog_target ve
        webfetch testleri; ERT test-security, test-attach, test-native-ownership.

  - [ ] **10.3 Mimari ve kaynak denetimi ([01_RUST_CORE_PATTERNS.md](.agents/skills/coding-standards/references/01_RUST_CORE_PATTERNS.md)/[39_RUST_PATTERN_AUDIT.md](.agents/skills/coding-standards/references/39_RUST_PATTERN_AUDIT.md), G05/G13):**

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 10.3a, 10.3b, 10.3c, 10.3d. İlgili açık alt işler, gerçek
      consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu
      kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya
      sahipliğini atamaya ekle.

    - [ ] **10.3a Rust kuralları:** yeni/etkilenen domain'de private newtype,
      TryFrom, checked units, no unsafe/panic/unwrap, tek writer ve nonblocking
      actor. Mevcut somut borcu port/consumer ve test kimliğiyle kaydet; satır
      sayısı veya yeni facade kurarak mimari uyum iddia etme.

      **İş türü / kapanış:** Somut tip/sınır denetimi 10.3a1, worker/actor I/O
        denetimi 10.3a2'dir. İkisini bağımsız küçük teslim et; çalışan bütün Rust
        ağacını yeniden yazma. Logging redaction uygulaması 10.1a, genel release
        lint kapısı 10.6c'dedir; bunların ikinci kopyasını kurma.

      - [ ] **10.3a1 Domain tip/sınır denetimi:** mevcut DTO ile doğrulanmış domain
        kaydını ayır; primitive alanın salt dış DTO'da kalması ile typed boundary
        atlanıp actor/store'a yazılması aynı şey değildir.

        **Önkoşul:** 0.2 DTO/domain birimleri; [01_RUST_CORE_PATTERNS.md](.agents/skills/coding-standards/references/01_RUST_CORE_PATTERNS.md); ilgili alanın dosya
          sahipliği. Başka ajanın aynı modülünü eşzamanlı yeniden tasarlama.

        **Başlangıç kaynakları:** Rust: `domain/`, `application/agent/`,
          `application/budget/`, `history/`, `sensors/{debugger,types}.rs`,
          `models/numeric.rs`, `security/schema.rs` ve `Cargo.toml` lint kuralları.

        **Uygulama adımı:** ID/revision/sequence/coordinate/byte/token/money için
          giriş DTO → TryFrom → private domain kaydı zincirini yaz. Özellikle
          debugger reference/breakpoint, mixed coordinate ve public constructor
          yollarını incele; bulunan somut kaçışı ilgili consumer işiyle düzelt.
          Mutation sonrası tekrar normalize etmek yerine parse sınırını kullan;
          await sonrası gerekli owner/revision kontrolünü silme.

        **Bitti sayılması için:** her somut bulguda yanlış birim/invalid sınırın
          store'a girmediği kanıtlı; gerekiyorsa wrong-unit compile-fail ve malformed
          boundary testi var. DTO'daki meşru primitive veya test fixture'ı uğruna
          yeni facade/framework kurulmaz. Bulgu yoksa okunan tip/constructor ve
          sınır kanıtını yaz, sırf commit için refactor yapma.

        **Doğrulama başlangıcı:** Rust `sensor_contract`, `agent_contract`,
          `history_contract`, `models_numeric`, `api_budget`; ilgili compile-fail
          ve strict Clippy. Bu liste tespit edilen alanla daraltılır; yalnız
          eski testlerin yeşil olması private/domain sınırı kanıtı değildir.

      - [ ] **10.3a2 Actor/worker I/O denetimi:** güvenlik kontrollerini silmeden
        blocking filesystem/process hazırlığının actual execution context'ini doğrula.

        **Önkoşul:** 0.2 worker completion/ownership sözleşmesi; mevcut bounded
          `spawn_blocking`/worker deseni. Stable security witness ve actual drain korunur.

        **Başlangıç kaynakları:** Rust: `ipc/execution/input.rs` içindeki
          `ExecuteInput::prepare_lifetime`, `security/mod.rs` içindeki
          `Workspace::revalidate`/command validation, `ipc/sessions.rs`,
          `ipc/sessions/editor.rs`, `ipc/execution/state.rs`, `ipc/read_tools.rs`.

        **Uygulama adımı:** canonicalize/metadata/read/prepare çağrılarının caller
          zincirini çıkar; zaten worker'da olanı taşıma. Actor mailbox'ında kalan
          uzun veya sınırı belirsiz işi bounded worker'a al; immutable candidate ve
          typed completion döndür. Actor sadece exact epoch/owner/revision state
          commit yapsın; effect anındaki resource revalidation'ı worker/adapter'da
          koru. Düz async fn içine sync I/O koymak çözüm değildir.

        **Bitti sayılması için:** yavaş kontrollü preparation sırasında ping/abort/
          sibling event ilerler; cancel/late worker source değişimini atlatamaz;
          safety recheck kaldırılmamış ve drained actual worker completion'a bağlı.
          Sadece statik canonicalize eşleşmesine bakıp runtime blok bug'ı ilan etme.

        **Doğrulama başlangıcı:** Rust `execution`, `native_agent_ipc`,
          `application_close`, `editor_preflight`, `editor_issuance` ve
          `file_reads`; gerçek worker bariyeriyle responsiveness/cancel vakası
          ekle. Unit sleep mock'u yerine worker ve mailbox ilerlemesini ayrı gözle.

    - [ ] **10.3b Kaynak stres paketi:** job/PGID/reap, pipe/output cap,
      archive/active handle sınırı, cancel'da late spawn, approval/reverse/edit
      drain ve startup/shutdown; bounded queue ve bilinen ownership leak'leri.

      **Önkoşul:** 5.8a; mevcut process/IPC cap sözleşmesi.

      **Başlangıç kaynakları:** Rust: tüm production src ve Cargo.toml lint kapıları.
        Elisp: tests/module-boundaries.el, tests/migration-inventory.el, kargu.el ve
        etkilenen consumer dosyaları.

      **Uygulama adımı:** Spawn/output/approval/reverse/edit/close aşamalarında bounded
        flood/cancel/reap stress corpus'u çalıştır; queue ve PGID owner metriklerini
        kaydet.

      **Bitti sayılması için:** Zombi/owned-child leak veya early drained yok; reused
        PID/foreign group öldürülmez; byte/count sınırı ve Stop/control latency bilinen
        sınırda.

      **Doğrulama başlangıcı:** Strict all-target Clippy/fmt + ilgili
        ownership/PGID/reverse testleri; ERT test-modules, test-process-stress ve
        envanter karşılaştırması.

    - [ ] **10.3c Frontend kalıntı kapısı:** 0.1/8.5 envanterini yeniden çıkar;
      config parser/HTTP orchestration, risk/selection/cache/prompt/loop/history/
      plan/persistence/verification kararları Elisp'te kalmasın. Emacs runtime
      revalidation ve DTO validation'ı korunur; bunlar ikinci domain motoru değildir.

      **Önkoşul:** 0.1; 8.5a; 5.10/7.6 legacy silme.

      **Başlangıç kaynakları:** Rust: tüm production src ve Cargo.toml lint kapıları.
        Elisp: tests/module-boundaries.el, tests/migration-inventory.el, kargu.el ve
        etkilenen consumer dosyaları.

      **Uygulama adımı:** Production Elisp'te
        prompt/config/selection/risk/loop/history/persistence/verification kararlarını
        kaynak/caller matrisiyle tekrar tara; her kalana primitive/UI/bridge gerekçesi
        iste.

      **Bitti sayılması için:** Kalan Elisp işi görüntüleme, raw editor IO veya exact
        runtime resource check; ikinci policy/cache/accounting writer veya hidden
        backend fallback bulunmaz.

      **Doğrulama başlangıcı:** Strict all-target Clippy/fmt + ilgili
        ownership/PGID/reverse testleri; ERT test-modules, test-process-stress ve
        envanter karşılaştırması.

    - [ ] **10.3d Envanter ve mimari test geçişi:** `tests/migration-inventory.el`,
      `tests/module-boundaries.el` ve `test-modules.el`deki legacy budget'ları
      gerçek silinen consumer'larla azalt. Kalan public komut, alias/tool schema,
      reverse capability ve Rust route için eşleme kanıtı üret; testleri silerek,
      allowlist'i büyüterek veya aynı işi yapan başka Elisp engine'i taşıyarak
      mimari kapıyı yeşile boyama.

      **Önkoşul:** 0.1 güncel envanter; 3.9/5.10/7.6 cleanup.

      **Başlangıç kaynakları:** Rust: tüm production src ve Cargo.toml lint kapıları.
        Elisp: tests/module-boundaries.el, tests/migration-inventory.el, kargu.el ve
        etkilenen consumer dosyaları.

      **Uygulama adımı:** Legacy import budget'larını silinen gerçek caller'larla azalt;
        public functions/commands/tool schemas/aliases/capabilities/ToolRoute eşlemesini
        tekrar üret ve fixture'ı gerekçeli güncelle.

      **Bitti sayılması için:** Eksik consumer'ı gizlemek için test silme/allowlist
        büyütme yok; declared capability'nin gerçek handler ve negatif test'i var;
        kaybolan public API explicit compatibility kararıyla raporlanır.

      **Doğrulama başlangıcı:** Strict all-target Clippy/fmt + ilgili
        ownership/PGID/reverse testleri; ERT test-modules, test-process-stress ve
        envanter karşılaştırması.

  - [ ] **10.4 Native default ve son kaldırma:**

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 10.4a, 10.4b, 10.4c. İlgili açık alt işler, gerçek consumer
      entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu kutuyu
      kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya sahipliğini
      atamaya ekle.

    - [ ] **10.4a Önkoşul:** native opt-in consumer portları ve 3.10b/8.6
      eşdeğerlik kabulü hazır olsun. Bu kapı fiziksel legacy silme olan 3.9,
      4.10, 5.10, 6.4b6, 8.5 veya 10.4c'nin bitmesini beklemez; böyle bir
      bağımlılık default ↔ cleanup döngüsü yaratır. Native yolda eski motor
      çalışmamalı, mevcut dış API ve restore sözleşmesi doğrulanmış olmalıdır.
      9'un durumu ayrı raporlanır; eksik backend nihai ürün kapanışından gizlenmez.

      **Önkoşul:** 0.2 portlar; 3.10b ve 8.6 native opt-in kabulü; ilgili 5/6/7 consumer
        portları.

      **Başlangıç kaynakları:** Rust: application/agent/, ipc/lifecycle.rs. Elisp:
        loop/native.el, loop.el, tools/diff/native.el, depo kökündeki kargu.el.

      **Uygulama adımı:** Native opt-in uçtan uca girişlerin test ve callback/writer
        envanterini incele; missing binary/protocol, API/restore ve capability negatif
        kabulünü doğrula. Fiziksel cleanup görevlerini bu kapının önkoşulu yapma.

      **Bitti sayılması için:** Native yolda hiçbir legacy engine çalışmaz; kapanış
        kanıtları commit/test bazında; 9 ayrı status ile açık raporlanır. Default
        değişimi için eski engine dosyalarının silinmesi beklenmez.

      **Doğrulama başlangıcı:** Missing binary/capability, active run sırasında ayar
        değişimi ve native hata sonrası sıfır legacy replay; full kaynak ERT +
        native_agent_ipc.

    - [ ] **10.4b Default değişimi:** Rust agent yalnız yeni run'larda varsayılan
      olsun; halihazırda alınmış backend/connection snapshot'ı değişmesin.
      Yeni legacy admission kapatılır; aktif eski run kendi lease'inde drain olur.
      Native error/EOF'ta otomatik legacy replay yok. Fiziksel legacy modül
      temizliği ilgili cleanup görevlerinde, bu switch kabulünden sonra yapılır.

      **Önkoşul:** 10.4a; aktif run backend snapshot kuralı.

      **Başlangıç kaynakları:** Rust: application/agent/, ipc/lifecycle.rs. Elisp:
        loop/native.el, loop.el, tools/diff/native.el, depo kökündeki kargu.el.

      **Uygulama adımı:** Yeni run varsayılanını Rust yap, yeni legacy admission'ı
        kapat; aktif eski run'ları kendi lease'inde actual drain'e bırak. Global
        fiziksel temizliği ilgili cleanup görevlerine ve 10.4c'ye bırak.

      **Bitti sayılması için:** Ayar değişimi aktif run'ı başka motora taşımaz;
        missing/error/EOF ikinci Elisp tool çalıştırmaz; yeni native run başarılı, eski
        actual drain gözlenebilir.

      **Doğrulama başlangıcı:** Missing binary/capability, active run sırasında ayar
        değişimi ve native hata sonrası sıfır legacy replay; full kaynak ERT +
        native_agent_ipc.

    - [ ] **10.4c Legacy emeklilik kapısı:** 10.4b ve eski run'ların actual drain'i
      sonrası 3.9/4.10/5.10/6.4b6/7.6a/8.5 temizliğini birleştir. Artık desteklenmeyen
      backend selector, fallback, autoload ve require dallarını kaldır; son tarama
      10.3c ve release kabulü 10.6 olsun. İnce editor adapter'ı silmek bu iş değildir.

      **Önkoşul:** 10.4b; eski run actual drain; 3.9/4.10/5.10/6.4b6/7.6a/8.5 cleanup
        teslimleri.

      **Başlangıç kaynakları:** Rust: application/agent/, ipc/lifecycle.rs. Elisp:
        loop/native.el, loop.el, tools/diff/native.el, depo kökündeki kargu.el.

      **Uygulama adımı:** Tek entegrasyon dalında retired backend
        selector/fallback/require/autoload kalıntısını kaldır; retained editor
        primitives'i source/caller kanıtıyla whitelist et. Son tarama ve release
        10.3c/10.6'da yapılır.

      **Bitti sayılması için:** Legacy engine physical source/caller'ı yok; mevcut
        native API ve editor UI yüklenir; eski pending callback veya backend ayarı
        engine'i tekrar diriltemez.

      **Doğrulama başlangıcı:** Missing binary/capability, active run sırasında ayar
        değişimi ve native hata sonrası sıfır legacy replay; full kaynak ERT +
        native_agent_ipc.

  - [ ] **10.5 Paketleme ve dağıtım:**

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 10.5a, 10.5b, 10.5c, 10.5d, 10.5e. İlgili açık alt işler,
      gerçek consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan
      bu kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya
      sahipliğini atamaya ekle.

    - [ ] **10.5a Release artifact:** desteklenen OS/arch ve Emacs/Rust runtime
      matrisi, locked binary build, protocol/version handshake ve embedded
      provider/tool/prompt asset'lerini paketle; geliştirme checkout'una muhtaç olmasın.

      **Önkoşul:** 10.5d asset/version contract; desteklenen platform kararı.

      **Başlangıç kaynakları:** kargu-core/Cargo.toml, Cargo.lock, kargu-core/src/main.rs,
        kargu-core/src/constants.rs, kargu-core/assets/; kargu.el, kargu/bridge.el, README.md, .agents/rules/describing.md,
        shell.nix.

      **Uygulama adımı:** Binary + gerekli Elisp/assets paketini declared
        OS/arch/Emacs/Rust matrisiyle build et; dev checkout yoluna bağımlı runtime read
        bırakma.

      **Bitti sayılması için:** Paket temiz geçici home/projede açılır; doğru
        protocol/asset sürümü yayımlanır; unsupported platform açık neden verir, bin
        dosyasının bulunması Ready sayılmaz.

      **Doğrulama başlangıcı:** Geçici temiz HOME/config/proje ile paketli binary +
        Elisp startup; asset/version/capability uyuşmazlığı, eksik opsiyonel modül,
        çıkış/upgrade negatif kabulü.

    - [ ] **10.5b Clean-machine senaryosu:** explicit binary path/PATH, missing/
      incompatible binary, optional adapter yokluğu, startup/exit/upgrade ve
      uninstall cleanup. Setup raporu ile native/remote health farkını koru;
      passive UI açılışı keşif/ücretli istek başlatmasın.

      **Önkoşul:** 10.5a; 8.5b optional composition.

      **Başlangıç kaynakları:** kargu-core/Cargo.toml, Cargo.lock, kargu-core/src/main.rs,
        kargu-core/src/constants.rs, kargu-core/assets/; kargu.el, kargu/bridge.el, README.md, .agents/rules/describing.md,
        shell.nix.

      **Uygulama adımı:** Temiz HOME/config ortamında explicit path/PATH,
        missing/wrong-version binary, optional dependency yokluğu,
        upgrade/exit/uninstall senaryolarını çalıştır.

      **Bitti sayılması için:** Kullanıcı kaynak checkout'u veya yerel .agents referansı olmadan startup
        çalışır; discovery paid HTTP/login yapmaz; exit owned child'ı reap eder, foreign
        servisi kapatmaz.

      **Doğrulama başlangıcı:** Geçici temiz HOME/config/proje ile paketli binary +
        Elisp startup; asset/version/capability uyuşmazlığı, eksik opsiyonel modül,
        çıkış/upgrade negatif kabulü.

    - [ ] **10.5c Kullanıcı dokümanı:** kurulum, readiness nedenleri, config ve
      session migration/export, desteklenen capability ve garanti sınırları;
      rollback yolu varsa explicit kullanıcı işlemi, sessiz engine fallback olmasın.

      **Önkoşul:** 0.1 güncel authority matrisi; 10.5a/b.

      **Başlangıç kaynakları:** kargu-core/Cargo.toml, Cargo.lock, kargu-core/src/main.rs,
        kargu-core/src/constants.rs, kargu-core/assets/; kargu.el, kargu/bridge.el, README.md, .agents/rules/describing.md,
        shell.nix.

      **Uygulama adımı:** README/describing ve architecture/connection/modularity
        açıklamalarını gerçek default/port/capability ile eşle; tarihi referans kanıtını
        güncel teslim iddiasından ayır.

      **Bitti sayılması için:** Kurulum, config/session migration/export ve destek
        sınırı doğru; kullanıcıya önerilen komut mevcut ve kapsamı açık; rollback
        explicit işlem, otomatik legacy replay değil.

      **Doğrulama başlangıcı:** Geçici temiz HOME/config/proje ile paketli binary +
        Elisp startup; asset/version/capability uyuşmazlığı, eksik opsiyonel modül,
        çıkış/upgrade negatif kabulü.

    - [ ] **10.5d Asset/registry protokol eşleşmesi:** Rust embedded provider/tool
      asset'leri, `security/catalog.rs`, Elisp tool registration/alias/schema
      tanımları ve init capability'leri için tek source-of-truth/version/hash
      ilişkisi kur. Sahada binary/Elisp farklı sürüm olursa yanlış schema ile
      çağrı yürütme; uyumsuzluğu anlaşılır hata olarak göster. Nihai build'in
      source checkout veya `.agents` dokümanından asset okuması gerekmemeli.

      **Önkoşul:** 5.3 native registry; 8.2 provider registry; 0.2 handshake.

      **Başlangıç kaynakları:** kargu-core/Cargo.toml, Cargo.lock, kargu-core/src/main.rs,
        kargu-core/src/constants.rs, kargu-core/assets/; kargu.el, kargu/bridge.el, README.md, .agents/rules/describing.md,
        shell.nix.

      **Uygulama adımı:** Provider/tool/prompt asset manifest'i ve Rust/Elisp
        schema-capability uyumluluğu için tek kaynak/version ilişkisi kur; paket aynı
        declared snapshot'ı kullansın.

      **Bitti sayılması için:** Eski Elisp/yeni binary veya tersi yanlış tool schema'yla
        etki yapmaz; declared mismatched capability ret; source/assets içeriği
        runtime'da gizli eski fallback değildir.

      **Doğrulama başlangıcı:** Geçici temiz HOME/config/proje ile paketli binary +
        Elisp startup; asset/version/capability uyuşmazlığı, eksik opsiyonel modül,
        çıkış/upgrade negatif kabulü.

  - [ ] **10.5e Setup/health ayrımı:** setup raporunun kapsamını native
    readiness'den açıkça ayır: şu an
    `kargu ready` config/credential/dependency kontrolüdür, binary/protokol veya
    uzak model sağlığı testi değildir. Release kabulünde missing/incompatible
    configured binary ile bu ayrımı ve gerçek startup'ın fail-closed hatasını
    birlikte doğrula; passive reader'a gizli core/model isteği ekleme.

    - [x] **10.5e1 Rapor kapsamı:** `kargu ready` yerine
      `kargu setup OK (config/credentials/dependencies)` gösteriliyor; agent
      readiness ve remote model health'in kontrol edilmediği açık yazıyor.
      Komut docstring'i ve README aynı kapsamı açıklıyor. Native config refresh
      core kullandığından missing/incompatible binary hazırlığı yine reddedebilir;
      setup'ın binary'den bağımsız başarılı olacağı varsayılmıyor.

      **Kanıt (2026-11-06, `e5cd2b1` tabanı):** Yeni
      `kargu-setup-report-states-health-scope-test` eski mesajda exit 1 ile
      başarısız oldu. `nix-shell --run 'cargo build --manifest-path
      kargu-core/Cargo.toml --locked'` exit 0; aynı binary ile ortak ERT
      komutunda `kargu-test-selector="kargu-setup-"`: 12/12, exit 0
      (gerçek config pipe ve cold-schema child dahil). Değişen schema/setup/test
      kaynaklarında warnings-as-errors geçici byte compile, check-parens ve
      checkdoc exit 0; `git diff --check` temiz. Ortam package autoload sırasında
      `epg-error no usable configuration OpenPGP` mesajı veriyor; testler geçti.
      TLC kaynağı değişmedi, çalıştırılmadı.
      Üst 10.5e'nin release düzeyindeki missing/incompatible binary ve pasif
      reader kabul matrisi açık kalır.

    **Önkoşul:** 4.11c; native lifecycle handshake; 9.2 readiness.

    **Başlangıç kaynakları:** kargu-core/Cargo.toml, Cargo.lock, kargu-core/src/main.rs,
      kargu-core/src/constants.rs, kargu-core/assets/; kargu.el, kargu/bridge.el, README.md, .agents/rules/describing.md,
      shell.nix.

    **Uygulama adımı:** kargu-check-setup raporunun config/dependency kapsamını native
      binary/protocol ve remote model health'den ayrı DTO/label ile sun; explicit
      test-connection çağrısını ayrı tut.

    **Bitti sayılması için:** Setup 'ready' iken incompatible binary varsa gerçek
      startup fail-closed ve sebebi görünür; pasif header/getter gizli process/HTTP
      health testi başlatmaz.

    **Doğrulama başlangıcı:** Geçici temiz HOME/config/proje ile paketli binary + Elisp
      startup; asset/version/capability uyuşmazlığı, eksik opsiyonel modül,
      çıkış/upgrade negatif kabulü.

  - [ ] **10.6 Nihai entegrasyon kabulü:**

    **İş türü / kapanış:** Bu bir üst iş/kabul kapısıdır; ayrı bir ikinci implementasyon
      yazma. Alt teslimler: 10.6a, 10.6b, 10.6c, 10.6d, 10.6e. İlgili açık alt işler, gerçek
      consumer entegrasyonu ve gerekiyorsa legacy kaldırma kanıtı tamamlanmadan bu
      kutuyu kapatma. Ajanlara tek bir yaprak iş ver; ortak DTO/port ve dosya
      sahipliğini atamaya ekle.

    - [ ] **10.6a Headless + gerçek pipe:** claim → config/context → model →
      tool/approval → edit → fresh verify/heal → history/persistence → tek
      terminal; her sınırda Stop/reset/EOF/stale/duplicate/foreign ve restart.

      **Önkoşul:** 3–8 runtime consumer'ları; 9 ilgili adapter contract.

      **Başlangıç kaynakları:** tests/run-tests.el, kargu-core/tests/, proof/README.md
        ve görevlerin teslim commitleri.

      **Uygulama adımı:** Claim'den terminal/persistence'a tam native zincirde her
        await/issue/commit sınırına Stop/reset/EOF/stale/foreign/duplicate/restart
        enjekte et; fake ve gerçek pipe corpus'unu eşle.

      **Bitti sayılması için:** Tek owner/tek writer/tek terminal; unknown etki replay
        yok; actual edit/process drain ve persisted recovery kanıtı birlikte, yalnız
        unit helper başarısı değil.

      **Doğrulama başlangıcı:** Ortak doğrulama komutları + ilgili gerçek adapter/GUI
        kabulü; TLA+ kaynakları değişmediyse TLC çalıştırma.

    - [ ] **10.6b Emacs GUI:** çoklu chat/draft/company/footer/Transient/plan/
      confirmation/Ediff, canlı Flymake/Eglot/Dape ve unload; headless ERT gerçek
      GUI veya gerçek server kabulü sayılmasın. Eksik dış bağımlılığı açık raporla.

      **Önkoşul:** 8.6 headless kanıtı; kullanılabilir kontrollü GUI/LSP/Dape ortamı.

      **Başlangıç kaynakları:** tests/run-tests.el, kargu-core/tests/, proof/README.md
        ve görevlerin teslim commitleri.

      **Uygulama adımı:** Gerçek Emacs GUI'de iki
        chat/draft/company/footer/Transient/plan/approval/Ediff akışını ve mevcut
        server/debug adapter'ını çalıştır; ortam yoksa sonucu blocker diye yaz.

      **Bitti sayılması için:** Kullanıcı girişi/scroll/draft korunur, Stop
        erişilebilir; gerçek GUI/server yerine headless mock sonucu sunulmaz; dış
        hesap/ücretli turn yetkisiz çalıştırılmaz.

      **Doğrulama başlangıcı:** Ortak doğrulama komutları + ilgili gerçek adapter/GUI
        kabulü; TLA+ kaynakları değişmediyse TLC çalıştırma.

    - [ ] **10.6c Release kapısı:** locked Rust + compile-fail, full source ERT,
      fmt, strict all-target Clippy ve değişen Elisp uyarısız compile/checkdoc;
      TLA+ değiştiyse ilgili TLC. Test corpus'u sentetik/geçici; gerçek hesap/
      kullanıcı verisi kullanımı ayrıca yetkili olsun.

      **Önkoşul:** 10.6a/b sonuçları ve entegre HEAD binary.

      **Başlangıç kaynakları:** tests/run-tests.el, kargu-core/tests/, proof/README.md
        ve görevlerin teslim commitleri.

      **Uygulama adımı:** Ortak locked Rust/full kaynak ERT/lint/byte-compile kapısını
        nihai artifact ile çalıştır; yalnız değişen TLA+ için ilgili TLC ekle.

      **Bitti sayılması için:** Her mandatory test/derleme sonucu komut/commit/exit ile
        kaydedilmiş; eski bytecode/binary kullanılmamış; test azaltma veya warning
        kapatma yok.

      **Doğrulama başlangıcı:** Ortak doğrulama komutları + ilgili gerçek adapter/GUI
        kabulü; TLA+ kaynakları değişmediyse TLC çalıştırma.

    - [ ] **10.6d Teslim raporu:** her public consumer'ın native writer/portu ve
      kalan Emacs primitive'i, test/commit kanıtı, 9'daki dört adapter'ın ayrı
      durumu ve bilinen sınırlar. Açık alt iş varken üst görev tamamlanmasın.

      **Önkoşul:** 10.6c; tüm üst işlerin teslim kayıtları.

      **Başlangıç kaynakları:** tests/run-tests.el, kargu-core/tests/, proof/README.md
        ve görevlerin teslim commitleri.

      **Uygulama adımı:** Her public entrypoint'in native authority/port, retained Emacs
        primitive ve kaldırılan legacy writer eşlemesini raporla; dört backend'i ayrı
        status ile belirt.

      **Bitti sayılması için:** Açık mandatory alt iş varken üst kutu kapalı değildir;
        gerçek test/commit ve kalan garanti sınırı okuyana anlaşılır, test sayısı tek
        kanıt değildir.

      **Doğrulama başlangıcı:** Ortak doğrulama komutları + ilgili gerçek adapter/GUI
        kabulü; TLA+ kaynakları değişmediyse TLC çalıştırma.

    - [x] **10.6e CI ve kaynak test kapısı:** mevcut `.github/workflows/rust-bridge.yml`
      Rust kontrollerinden sonra yalnız bağımsız bridge ERT ve altı dosyanın byte
      compile'ını çalıştırıyor. Tam uygulama kaynak ERT, değişen Elisp lint ve
      gerekli fixture dependency kurulumunu görünür ayrı kapılara bağla.

      - [x] **10.6e1 Temiz ortam fixture'ları:** dependency testinin kullanıcıda
        `plz` kurulu olması varsayımı yerleşik `json` ile kaldırıldı; testin
        dosya başlığı ve docstring'leri checkdoc'a uygun hale geldi. Unix socket
        listing fixture'ı uzun/nested Nix TMPDIR altında `SUN_LEN` sınırını
        aşmamak için kısa `/tmp` kökünde oluşturuluyor.

        **Kanıt (2026-11-06):** temiz HOME koşusunda eski dependency testi
        eksik paket sayısını 2 buluyordu; düzeltmeyle açık Company/Dape load
        path'leri ve aynı native binary altında 1448/1448 ERT (exit 0).
        İlk locked Rust kapısında socket fixture'ı `path must be shorter than
        SUN_LEN` ile düştü; aynı uzun TMPDIR ile düzeltme sonrası
        `cargo test --manifest-path kargu-core/Cargo.toml --locked --test listing`
        6/6 geçti. Değişen Elisp warnings-as-errors compile/check-parens/checkdoc
        temiz; Rust fmt/Clippy ve tam kabul üst CI işinde kaydedilir.

      **Teslim (2026-11-06, `52b29f1` tabanı):** mevcut workflow'da
      bridge smoke korunarak ayrı tam kaynak ERT ve changed-Elisp kapıları
      eklendi. Company paket bağımlılığı explicit; Dape 0.27.1 fixture kaynağı
      `dcbdffc68a3c89bbb89956161edde9f0fe062e64` sürümünde sabit. Runner
      temiz HOME/config/credential environment kullanıyor; stale checkout `.elc`
      ve skipped ERT success sayılmıyor. Lint bytecode'u geçici dizine yazıyor;
      compile uyarısı, check-parens ve checkdoc hata kapıları aktif.
      TLA+ kaynak bağımlılıkları EXTENDS/INSTANCE üzerinden configured root'a
      eşleniyor; yalnız değişen `.tla`/`.cfg` için Nix/TLC adımı açılıyor.

      **Çalıştırılan kabul:** `tests/ci/run-ert.sh full` explicit Company/Dape
      kaynak yolları ve freshly-built `KARGU_CORE_TEST_BINARY` ile temiz
      HOME'da 1448/1448, `bridge` 39/39 (exit 0). Aynı locked Rust workflow
      komutları fmt + strict all-target Clippy + 593 test (32 compile-fail dahil)
      + build exit 0; ilk fixture hatası 10.6e1'de düzeltildi.
      `tests/ci/check-elisp.py e5cd2b1`, yeni lint script'inin kendi kontrolü,
      `bash -n` ve `git diff --check` temiz. Model selector'unun 3 testi tüm
      mevcut model kaynak eşlemesini, transitive INSTANCE ve fake-executable
      üzerinden runner argv/rejection davranışını doğruladı; gerçek TLC veya
      model execution çalıştırılmadı. Bytecode/compile-warning/checkdoc/skip
      hata enjeksiyonları kapıları gerçekten kırdı.
      Loglar: `/tmp/kargu-ci-{clean-with-deps,bridge,rust-fixed,final-lint}.log`.
      Yerel Emacs 30.2 kullanıldı; hosted Ubuntu/Emacs çalışması ve GUI/live
      backend kabulü bu yerel teslimin kanıtı değildir. Workflow push edilmedi.

      **Önkoşul:** mevcut CI workflow; 0.3 test/dependency matrisi; ortak yerel
        doğrulama komutları. Hazır workflow vardır, yeni CI sistemi icat etme.

      **Başlangıç kaynakları:** `.github/workflows/rust-bridge.yml`, `shell.nix`,
        `kargu-core/Cargo.toml`, `tests/run-tests.el`, `tests/module-boundaries.el`,
        `proof/run_tlc.sh`. Bu dosyalar depo köküne göredir.

      **Uygulama adımı:** bağımsız bridge smoke testini koru; native binary'yi
        aynı commit'ten build ederek tam kaynak ERT'ye ver. Package/fixture
        dependency'lerini explicit ve sentetik kur; byte compile çıktısını
        geçici dizine al. Değişen Elisp uyarı kapısı ve yalnız model kaynağı
        değiştiğinde ilgili TLC seçimini mevcut workflow'a bağla. Headless CI'ı
        ücretli provider, gerçek kullanıcı config'i veya canlı GUI testi sanma.

      **Bitti sayılması için:** gerçek bir engine/consumer regresyonu bridge
        smoke yeşil kalsa bile full-source kapısını kırar; eski `.elc`/binary
        kaynakları gölgelemez; skip/fixture dependency hatası sessiz success
        değildir. GUI/live backend kabulü ayrı raporlanır.

      **Doğrulama başlangıcı:** workflow komutlarını aynı temiz geçici ortamda
        yerel çalıştır; native test + full kaynak ERT + lint log'larını sakla.
        Sadece YAML parse başarısını runtime kabulü olarak sunma.

### Ortak doğrulama komutları ve kanıt kapsamı

Ajan önce ilgili Rust test target/filtre ve ERT selector'ını tesliminde belirtir.
Aşağıdaki tam kapı entegrasyon içindir; yalnız doküman değişikliğinde çalıştırılmaz.
Komutlar repo kökünden, mevcut Nix geliştirme ortamında uygulanır:

```sh
nix-shell --run 'cargo fmt --manifest-path kargu-core/Cargo.toml --check'
nix-shell --run 'cargo test --manifest-path kargu-core/Cargo.toml --locked'
nix-shell --run 'cargo clippy --manifest-path kargu-core/Cargo.toml --locked --all-targets -- -D warnings'
nix-shell --run 'cargo build --manifest-path kargu-core/Cargo.toml --locked'
env KARGU_CORE_TEST_BINARY="$PWD/kargu-core/target/debug/kargu-core" emacs --batch -Q -L . --eval '(progn (require (quote package)) (package-initialize))' -l tests/run-tests.el
```

Odak ERT'de aynı eval içinde `kargu-test-selector` atanır. Pipe/ERT öncesi binary
ayrı build edilerek kaynakla eşleşir; eski binary veya mock-only başarı native
entegrasyon kanıtı değildir. Elisp'te değişen kaynak/yeni testler warnings-as-errors
byte compile + check-parens/checkdoc'tan geçsin; `.elc` çıktıları geçici dizine
alınsın, kaynak ERT'sini gölgelemesin. Her teslim kullanılan temel commit, gerçek
komut/selector, exit sonucu ve atlanan/engelli kabulü yazar. TLC yalnız TLA+
kaynağı değiştiyse ilgili modele uygulanır; eski sayıyı tekrar etmek gerekmez.

### Ajanlar için başlangıç kaynak haritası

Rust sütunu `kargu-core/src/`, Elisp sütunu `kargu/` altındadır; klasör adı
önerisi mevcut implementation var demek değildir. Kaynak sahipliği 0.4'te kesinleşir.

| İş alanı | Mevcut Rust başlangıcı | Elisp consumer / taşınacak karar |
|---|---|---|
| Config/katalog/seçim | `configuration/`, `providers/`, `models/service/`, `ipc/read_tools.rs` | `config/`, `api/catalog/request.el`, `selection.el`, `chat/select/` |
| Prompt/context | `sensors/mentions.rs`, `workspace/`, `history/`, `api/wire/` | `prompt.el`, `chat/attach.el`, `project-probe.el` |
| Sensor/LSP | `sensors/`, `security/delegated.rs`, `ipc/sessions/` | `bridge/sensor/`, `tools/lsp/` |
| Dape | `sensors/debugger.rs`, `security/`, mevcut reverse portları | `tools/dape/`, `application/mode.el` |
| Run/history/registry/plan | `application/agent/`, `application/history.rs`, `history/`, `security/catalog.rs`, `ipc/sessions/` | `loop/`, `history/`, `tools/registry.el`, `permission/`, `state/`, `plan/` |
| Bütçe/verification | `application/budget/`, `sensors/diagnostics/`, mevcut edit ledger | `loop/{compact,heal}.el`, `history/compact.el`, `tools/diff/track.el` |
| Edit | `edit/`, `security/editor.rs`, mevcut native edit IPC | `tools/diff/`, `bridge/edit/`, `edit.el` |
| Persistence | `history/` ve actor worker portları; session storage prototipi geri alındı | `chat/session.el`, `chat/session/`, `files/async.el` |
| UI/event | `ipc/protocol.rs`, `ipc/sessions/`, history presentation | `bridge/session.el`, `loop/native.el`, `chat/`, `ui/` |
| Harici backend/MCP | Mevcut native run/process/gate temeli; adapter'lar ayrıca uygulanacak | `chat/select/`, UI capability/readiness sunumu |

### Önerilen dağıtım dalgaları ve bağımlılıklar

Bu tablo kutuların yerine geçmez; atama kimliklerini ve birleşme sırasını gösterir.
Mevcut Rust temelleri kullanılır. Dalgalar bütün grubun bitmesini gerektiren
bariyerler değildir; belirtilen port hazırsa ilgili consumer işi öne alınabilir.

| Paket | Atanacak işler | Başlamadan gereken | Paralellik / ortak sınır |
|---|---|---|---|
| Sözleşme/entegratör | 0.1–0.4 | Güncel kaynak ve audit | DTO sürümü, ortak dosya sahipliği ve kabul corpus'unu dondurur |
| Config/katalog | 8.2b2–8.2e | 0; mevcut native config/model refresh | Prompt/sensor ile paralel; selection revision için 5.4a ile anlaşır |
| Prompt | 5.13a–d | 0; config/registry/context DTO | 4.9 tam değilse typed interface teslim edilir, consumer kabulü açık kalır |
| Sensor read | 4.2a–c, 4.3d/e, 4.4d/e | 0; mevcut sensor/reverse gate | LSP/Xref ile Dape ayrı dosyalarda; reverse dispatcher tek entegratörde |
| Debugger | 4.5a–c, 4.6a–c | 0.2 launch/mode contract, 4.2 portu, native gate | Launch FSM ile capture ayrılabilir; debug mode 5.7a'ya port verir |
| Context | 4.7a, 4.8a–d, 4.9a/b | 0; read/symbol/Git primitive'leri | Prompt/egress sözleşmesi ortak; kullanıcı kaynağına erişim grant'i önceden belirlenir |
| Dil/probe | 4.11a–c | 0.2 profil/guidance ve readiness contract | Dape/prompt consumer hazır portu bekler; major-mode erişimi Emacs'te |
| Registry/izin | 5.3a–c | 0; mevcut native catalog/gate | Her tool ailesi için aynı immutable contract; yeni ikinci policy motoru yok |
| Mode/plan | 5.7a–c, 8.4a/b | 0; run/gate portu; debug için 4.6 | Plan UI ayrı, native dispatch entegre edilir |
| Run/history | 5.1a/b, 5.4a–c, 5.5a1–a3/5.5b, 5.6c–e, 5.8a/b, 5.9g/h | 0; ilgili registry/reverse portları | Merkezi actor/transport entegratörü; consumer ailesi bazında küçük teslim |
| Muhasebe | 6.1a–c, 6.2c–e | 0; native budget/pricing ve run ticket | Storage ile paralel; provider settlement tek owner'da |
| Compaction | 6.3a–c | 5 history/run, 5.13a/b builder, 6.1 portları | Native opt-in kabulü; fiziksel eski summary motoru 5.10/10.4b sonrası kalkar |
| Verification/healing | 6.4b3–b6, 6.5a/b | 3.8 change ledger, 4.3 freshness, 5 run, 6.1 | b3–b5 native opt-in; b6 fiziksel silme 10.4b sonrası; 6.4b1 tekrar yazılmaz |
| Persistence | 7.1a/b, 7.2a–c, 7.3b/c, 7.4a/b, 7.5a–d, 7.6a/b | 0; 5 history/selection candidate sözleşmesi | Önce storage/domain; RPC/UI sonradan, actor'da disk I/O yok |
| Edit consumer | 3.8b–d, 3.10a/b | Mevcut edit ledger; 6 verification portu | Public edit default ile son agent default geçişi ayrı kapılar |
| UI/event | 8.1a/b, 8.3a–d, 8.5a–c, 8.6 | İlgili native DTO/intent hazır | 8.6 opt-in ön-kapı; 8.5 fiziksel silmesi 10.4b sonrası; UI engine kararı vermez |
| Harici backend'ler | 9.1/9.2; sonra 9.3, 9.4, 9.5, 9.6 ayrı ajan | Ortak backend/capability contract ve native run portu | Dört adapter birbirinden bağımsız; MCP 9.9 ayrı paket |
| Gizlilik/egress | 10.1a–c, 10.2a–c | 0; ilgili boundary sözleşmesi | Son aşamaya ertelenmez, her yeni consumer aynı kapıyı uygular |
| Default ön-kapısı / switch | 3.10b, 8.6 → 10.4a → 10.4b | Native opt-in consumer kabulü | Fiziksel cleanup beklenmez; eski run actual drain sonrasında kaldırılır |
| Son entegrasyon/release | 3.9, 4.10, 5.10/5.12, 6.6, 8.6, 10.3–10.6 | İlgili consumer'lar ve negatif kabul | 10.4b sonrası fiziksel silme → 10.4c → 10.3c/10.6 koordinatörde |

Döngüsel “önce tüm 4, sonra tüm 5, sonra tüm 6” bağımlılığı kurulmaz: gereken
dar DTO/port önce teslim edilir, domain/adapter paralel geliştirilir, sonra aynı
gerçek consumer'da birleştirilir. Bir bağımlılık hazır değilken sahte success veya
legacy fallback eklemek yerine integration kutusu açık bırakılır.
