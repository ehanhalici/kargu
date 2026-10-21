# Kargu — paralel mimari dönüşüm ve inceleme planı

## 1. Başlangıç noktası ve kapsam

Başlangıç kod revision'ı: `988dd9685515e2008d0c80d3126f8a4deb402748`.
Bu belge gelecekteki ajanlara iş dağıtımıdır; görevler henüz başlatılmadı.
İş takibinin kaynağı `todo.md`, uygulama kuralları yerel `skills.md`'dir.

İncelenen sıra:

| Commit | Getirdiği sınır | Henüz kapanmayan bölüm |
|---|---|---|
| `3864789` | Worker üzerinden metadata listesi; seçim kurallarının servise alınması; credential adapter girişi | Varsayılan credential yolu hâlâ senkron `auth-source`/callable secret çalıştırıyor: CONFIG-01. Keşif ve request aynı bağlantı revision'ını yakalamalı. |
| `06a9df2` | Application/logical-request kayıtları, run snapshot ve hedefli reset | `kargu-application--context` varsayılan singleton'ı ve `kargu--loop-run`/busy/generation/process köprüleri duruyor. Struct eklenmesi açık context aktarımını tek başına tamamlamıyor. |
| `5c492b0` | Asenkron Dape port launch/source worker; yabancı adapter UI izolasyonu | Sürüm bağımlı Dape private API/advice sınırı ve bütün kaynakların aktif unload testi ayrıca incelenecek. Kapanmış hatalar kanıtsız yeniden açılmayacak. |
| `988dd96` | Yarım edit paketi: izole Unified Diff, ortak snapshot/review/commit, güvenli batch rollback, revision-bound sembol değiştirme ve baseline karşılaştırması | Diff kayıtlarının servis sahipliği, onay/config revision'ı, çapraz yazıcı garantisi ve veri ömrü açık. Rollback, crash recovery veya filesystem CAS değildir. |

Doğrulanan taban: **942/942 ERT**, değişen üretim kodu/yeni testlerde
uyarısız byte-compile ve checkdoc; değişen eski testlerde uyarısız
byte-compile; `git diff --check` temiz. Yeni sınırlı edit modeli TLC:
425 üretilen / 160 farklı durum, derinlik 10; verification modeli:
439 / 68, derinlik 6; ikisi exhaustive ve hatasız. Ana büyük modelin
bu turda yeniden tarandığı iddia edilmiyor.

Gerçek Codex/Claude Code/Cursor/OpenCode bağlantısı, master'a merge ve push
bu planın uygulama yetkisinde değildir. Önce fake backend ile portlar ve
merge kapıları tamamlanır. Dış ürünlerin resmi protokolleri entegrasyon
aşamasında ayrıca doğrulanır; desktop uygulamasına keyfi bağlanma varsayılmaz.

## 2. Çalıştırma düzeni: koordinatör + en fazla üç işçi

Aynı dalgadaki üç görev paraleldir; dalgalar arası kabul kapısı seridir.
Tek bir Emacs uygulamasında yine **tek aktif run** vardır. Geliştirme
ajanlarının paralel olması Kargu'nun çalışma zamanı politikasını değiştirmez.

| Dalga | İşçi 1 | İşçi 2 | İşçi 3 | Geçiş kapısı |
|---|---|---|---|---|
| 0 | Koordinatör: sözleşmeler ve fixture tabanı | — | — | Girdi/çıktı, sahiplik ve uyumluluk kararları sabit |
| 1 | A: application/async/bütçe temeli | B: düzenleme servisi | C: credential/config bağlantı snapshot'ı | Üç port bağımsız; mevcut davranış regresyonsuz |
| 2 | D: araç yürütme/izin | E: transport/stream | F: süreç ve job sahipliği | Tek yürütme kapısı, bounded transport, izole iptal |
| 3 | G: native loop/history | H: sohbet/seçim/metadata | I: log gizliliği ve ölçüm | Headless motor, view izolasyonu, güvenli tanı |
| 4 | J: LSP/tanı/koordinat | K: Dape adapter sınırı | L: persistence/dosya/veri ömrü | Sökülebilir adapter'lar, açık writer/recovery garantisi |
| 5 | M: fake agent backend portu | N: egress ve güvenlik bileşimi | O: eski test lint borcu | Bütünleşik fault/eksik-modül matrisi ve son inceleme |

Her dalga bir öncekinin **entegre edilmiş revision'ından** başlar. Erken
biten işçi sonraki dalgaya kendiliğinden geçmez. Paketler, tek dev commit
yerine aşağıda belirtilen küçük mantıksal commit'lerle teslim edilir.

### Ortak işçi talimatı

1. Başlamadan `skills.md`'nin tamamını, `todo.md`'yi, bu belgedeki kendi görevini ve ilgili public portları oku. `skills.md`'yi stage etme. Alt ajanla bölme gerekiyorsa önce koordinatörden görev/dosya sahipliği iste; kontrolsüz iç delegasyon yapma.
2. Her işçi ayrı branch/worktree kullanır; worktree kurulumu koordinatöre aittir. Paylaşılan çalışma ağacında çalışmak zorunluysa yalnız izinli dosyalara yaz; başka ajanın unstaged değişikliklerini commit etme. `git add -A` kullanma.
3. Aşağıdaki dosya listeleri **yazma allowlist'idir**, hepsini değiştirme zorunluluğu değildir. Bütün depo okunabilir. Listede olmayan üretim/test/proof dosyasını değiştirmek yerine gereken API/değişikliği koordinatöre bildir.
4. Aynı anda ortak sözleşme veya başka ajanın kaydını değiştirme. İhtiyaç: çağıran, beklenen semantik, örnek test ve dosya adıyla raporlanır. Koordinatör sözleşmeyi yayımlayıp yeni tabanı bildirir.
5. Tek callback, Stop/deadline, stale owner/revision, başlangıç bariyeri ve cleanup testlerini success testinden önce yaz. Eksik güvenlik adapter'ı yazmaya izin vermez. Observer bir yürütme/onay portu değildir.
6. Sınırda decode/validate → kanonik domain kayıtları → doğrulanmış sonuç → dış adapter'da encode/metin. İçeride tekrar tekrar plist/string normalize etme. Zamanla değişen izin/sahiplik/revision kontrollerini kaldırma.
7. Yeni mutable singleton, genel DI/event-bus framework'ü, model adı regex'i, gereksiz facade veya varsayımsal cache ekleme. Mevcut portu kullan; yeni katman ancak somut kabul testi gerektiriyorsa eklenir. Yeni domain alanının sahibi/birimi açık olsun.
8. Yeni bulgu kolay ve kendi kapsamındaysa regresyonla çöz; kapsam dışı/zorsa hassas veri içermeyen bir bulgu notu teslim et. `todo.md`'ye yalnız koordinatör yazar. Tamamlanan/false-positive kaydı kanıtla öner; belgeden kendin silme.
9. Küçük commit, odaklı ERT, değişen üretim/yeni testlerde sıfır byte-compile/checkdoc uyarısı ve diff kontrolü zorunlu. Mevcut test fixture mesajlarını linter susturmak için değiştirme. FSM değişirse kendi modeli ve exhaustive tarama gerekir.
10. Teslim: commit hash'leri; değişen dosyalar; kaldırılan eski yollar; public API farkı; test komutları/sonuçları; TLC kapsamı; açık risk; başka göreve gereken bağlantı. “Testler yeşil” bütün TODO'nun kapandığı anlamına gelmez.

## 3. Dalga 0 — koordinatörün sabitleyeceği ortak sınırlar

Yalnız koordinatörün yazdığı ortak dosyalar:

- `kargu.el`, `kargu/core.el`, `kargu/contract.el`, `kargu/contract/assert.el`, `kargu/contract/constants.el`, `kargu/contract/types.el`, `kargu/contract/result.el`, `kargu/contract/history.el`, `kargu/contract/selection.el`, `kargu/contract/file-window.el`, `kargu/json.el`, `kargu/core/custom.el`, `kargu/core/group.el`.
- `tests/run-tests.el`, `tests/test-helpers.el`, `tests/test-modules.el`, `tests/test-laws.el`, `tests/test-integration.el`.
- `proof/run_tlc.sh`, `proof/README.md`, `proof/KarguState.tla`, `proof/KarguContract.tla`, `proof/MC.tla`, `proof/MC.cfg`.
- `README.md`, `todo.md`, `parallel-plan.md`; yeni ortak sözleşme envanteri için `architecture-contracts.md`.

`skills.md`, `.gitignore`, `.agents/` bu uygulama işlerinin yazma/stage alanı
değildir. Kullanıcının mevcut değişiklikleri korunur. Yukarıdaki testlerden
Dalga 5/O'ya geçici verilen lint dosyaları o dalgada koordinatörce yazılmaz.

Dalga 0'da B'nin çapraz private çağrısını kaldırabilmesi için koordinatör
`kargu/files.el` içinde mevcut revision okuyucusunu public, doğrulanan
`kargu-file-current-revision` sınırıyla açabilir. Yeni disk okuma motoru veya
ikinci revision tipi oluşturmaz. Bu dar bootstrap değişikliği Dalga 1'den
önce commit edilir; dosyanın sonraki yazma sahipliği Dalga 4/L'ye geçer.
Diğer public API ihtiyacı da aynı biçimde, ilgili işçi başlamadan kesinleşir.

Koordinatör küçük bir envanter yayımlar; önce bütün projeyi yeni tip sistemine
çevirmez. Her port için üretici/tüketici, zorunlu/opsiyonel bağımlılık,
girdi/çıktı tipi, validation sahibi, state/event, iptal ve kaynak ömrü yazılır.
Aşağıdaki adlar **hedef sözleşme adlarıdır**, mevcut API varmış gibi çağrılmaz;
gerçek imzalar ilk consumer testleriyle burada sabitlenir:

| Sınır | Sabitlenecek sözleşme |
|---|---|
| Application | Açık `application` handle + session/run/request kimlikleri; claim önce, görünüm bildirimi sonra; release yalnız aynı claim'i bırakır. UI komutu handle'ı composition'dan alır, alt servis singleton aramaz. |
| Async scope | Sahip/parent/task, deadline ve cancel/close. İptal isteği, process exit ve terminal teslim ayrı olaylar; erken tamamlanma kurulum bariyerini atlayamaz. |
| Edit | Açık edit service; tam kaynak revision'ı ve config/policy revision'ı; block/symbol/Unified Diff aynı işlem sonucuna ulaşır. `applied`, `staged`, `conflict`, `partial/unknown` ayrıdır. |
| Connection | Provider/model/endpoint/format/config-capability revision snapshot'ı; credential yalnız bu hedefe bağlı. Secret argv/log/session kaydına konmaz. |
| Tool | Registry + execution context + args + completion → cancel handle; alias/direct çağrı dahil aynı gate. Tanım ve mutable yürütme kaydı farklı sahiplerdir. |
| Budget | Run'a ait tek toplam request/deadline/token muhasebesi; normal istek/retry/compaction/heal aynı debit kapısını kullanır. Bilinmeyen kullanım `0` değildir. |
| Events | Minimum run/session/request/call/connection kimliği; immutable payload; pasif bildirim ile cevap bekleyen control request ayrı. UI/taşıma bunu aynı anlamda kullanır. |
| Results | Mevcut `contract/result.el` üzerinde domain hata kodları ve etki durumu; ikinci bir Result framework'ü yok. Metin parse ederek retry/başarı kararı yok. |

İlk kapı: iki izole application fixture'ı birbirini değiştirmez; aynı
application'da ikinci run reddedilir; opsiyonel modül yüklenmeden public
sözleşmeler yüklenir. Salt tanım envanteri kod garantisi sayılmaz.

## 4. Dalga 1

### A — açık application/async sahipliği ve ortak bütçe temeli

**TODO:** ARCH-01/11/12/16/17, MOD-05/07, DEEP-09'un muhasebe temeli.

**Üretim dosyaları:** `kargu/application/coordinator.el`, `kargu/application/mode.el`, `kargu/application/reset.el`, `kargu/core/session.el`, `kargu/async.el`, `kargu/state.el`, `kargu/state/store.el`, `kargu/state/selectors.el`, `kargu/state/transitions.el`, `kargu/state/hooks.el`.
**İzinli yeni dosya:** `kargu/application/budget.el`.
**Testler:** `tests/test-state.el`, `tests/test-async.el`, `tests/test-mode-ownership.el`; yeni `tests/test-application-context.el`, `tests/test-run-budget.el`.
**Proof:** `proof/KarguMode.tla`, `proof/ModeMC.tla`, `proof/ModeMC.cfg`; yeni `proof/KarguBudget.tla`, `proof/BudgetMC.tla`, `proof/BudgetMC.cfg`.

1. Coordinator'ı başka globalden okuyan store olmaktan çıkar: handle alan claim/transition/release; status için izinli geçiş tablosu ve explicit request generation. Yeni global `engine` ile yeniden paketleme yapma.
2. Session identity/epoch ile application claim'i ayır. Resetin kritik sırasını tut; yabancı run/request/circuit veya session sayaçları temizlenmesin. Async scope açık owner/parent alsın; legacy wrapper yalnız composition sınırında kalsın.
3. Saf ve küçük bütçe kaydı/consume API'si kur. Request adedi ve toplam deadline kesin; token/maliyet bilgisi unknown taşıyabilir. E/G bu portu aynı anlamla tüketecek. Varsayılan tek compaction politikasını değiştirme.
4. Son consumer taşınmadan eski köprüleri körlemesine silme. Kalan consumer dosyalarının kesin listesini koordinatöre ver; son köprü silme işi bütün dalgalar sonrası koordinatöre ait.

**Kabul:** iki application + iki session; aynı app'te çift claim; erken/çift callback; reset/close/reentrant listener; başka app'in timer/process'inin korunması; bütçenin alt işte sıfırlanmaması. Mode ve yeni bütçe modeli exhaustive geçer.
**Commit sırası:** context/claim → async/reset geçişi → bütçe çekirdeği.

### B — tek sahipli düzenleme servisi ve onay kimliği

**TODO:** ARCH-03/04/08/10/15/17, MOD-07; DEEP-10/11/15 için açık işlem kanıtı.

**Üretim:** `kargu/edit.el`, `kargu/tools/diff.el`, `kargu/tools/diff/stage.el`, `kargu/tools/diff/review.el`, `kargu/tools/diff/track.el`.
**Yeni:** `kargu/tools/diff/context.el`.
**Test:** `tests/test-patch.el`, `tests/test-edit-transaction.el`; yeni `tests/test-edit-service.el`.
**Proof:** `proof/KarguEdit.tla`, `proof/EditMC.tla`, `proof/EditMC.cfg`.

1. Snapshot/change/review tablolarını, pending callback ve geçici alanları explicit edit-service kaydına taşı. İşlem planı/outcome/review kimliklerini typed kayıt yap; global tabloları ikinci kez aynalama. Genel edit portu somut diff adapter'ını yüklemesin.
2. Plan, kaynak revision'ı yanında session/run/application ve review/auto-save/policy revision'ını yakalasın. Bekleme sonrası belge ve yetki yeniden doğrulansın; yeni kip/config eski onayı devralmasın.
3. Başarılı save-hook sonucunu, başarısız yazının etkisini ve rollback conflict'ini tek sonuçta tut. Observer Stop/reset yaptığında sonraki batch dosyası yazılmasın. Partial hunk kararı ile batch iptalinin farkı açık kalsın.
4. İzole Git uygulamasını ve kullanıcı index'ine dokunmama garantisini koru. Parser yalnız sınırlı framing/target doğrulaması yapsın; Git hunk eşleştirmesini yeniden yazma. Scratch/source boyut ve cleanup sınırlarını ölç; `git apply` UI yolunda asenkron kalsın.
5. Servis close/unload yalnız kendi review/process/timer/temp alanlarını kapatsın. İki servisin aynı path'i kullanmasında sahiplik karışmasın. Crash journal ve OS kilidi bu göreve gizlice eklenmez; L ile revision/etki sözleşmesi üzerinden bağlanır.

**Kabul:** mevcut 13 edit regresyonu + aynı/farklı path iki servis; onay sırasında config/session değişimi; aktif review/process close; staged index fixture'ı; dirty/narrowed/CRLF/Unicode; son save hatası ve foreign writer; tek callback ve sıfır kaynak sızıntısı. Edit modeli güncellenip exhaustive geçer.
**Commit:** kayıt sahipliği → frozen approval/transaction → aktif close ve bütçeler.

### C — gerçek asenkron credential/config ve bağlantı snapshot'ı

**TODO:** CONFIG-01, ARCH-15/19, DEEP-14; MOD-03'ten kalan I/O sınırı.

**Üretim:** `kargu/config.el`, `kargu/config/key.el`, `kargu/config/schema.el`, `kargu/config/toml.el`, `kargu/providers/registry.el`.
**Yeni:** `kargu/config/connection.el`, `kargu/config/worker.el`.
**Test:** `tests/test-config.el`, `tests/test-providers.el`; yeni `tests/test-connection-snapshot.el`.
**Yeni proof:** `proof/KarguConnection.tla`, `proof/ConnectionMC.tla`, `proof/ConnectionMC.cfg`.

1. CONFIG-01'i sentetik callable secret ve yavaş/uzak kaynak fixture'ıyla kilitle. UI/discovery'de `auth-source-search` veya secret fonksiyonu çalışmasın. Bellek/direct/keyless sonucu hızlı olabilir; desteklenmeyen encrypted/interactive backend açık unavailable döner.
2. Desteklenen disk çözümünü cancellable worker/adapter'a taşı. Secret'ı command-line argümanına koyma; auth unlock işlemini timer'a koyup asenkron diye sunma. Timeout/Stop gerçekten uygulanabilsin; worker başlatma/cevap sınırı bounded olsun.
3. Config parse/migration saf; I/O ayrı; yeni config bütünü doğrulanmadan yayımlanmasın. Provider/model/endpoint/protokol/config revision ve credential scope tek immutable connection snapshot'ında bağlansın. Metadata capability handle'ı dışarıdan verilebilsin; store içlerine uzanma.
4. Gecikmiş discovery/config değişiminde stale sonucu kullanma. Aynı snapshot retry'da korunacak; E'ye redacted immutable bağlantı sözleşmesini teslim et. Secret saklama ve cleanup politikası L/I ile ortak sınıra uysun.

**Kabul:** öncelik sırası ve keyless korunur; off/none/inherit bozulmaz; callable secret UI'da çağrılmaz; encrypted backend güvenli unavailable; endpoint/key değişimi, yanlış owner, erken/çift sonuç ve process cleanup. Sentetik credential yanlış host/argv/log'a çıkmaz.
**Commit:** yan etkisiz keşif → sahipli resolver → revision-bound connection.

## 5. Dalga 2

### D — registry/izin/araç yürütme için tek kapı

**TODO:** MOD-02, ARCH-02/03/09/15/16/17/19.

**Üretim:** `kargu/api/tools.el`, `kargu/tools/registry.el`, `kargu/permission.el`, `kargu/permission/guards.el`, `kargu/permission/policy.el`, `kargu/permission/bash.el`, `kargu/permission/execute.el`, `kargu/confirm.el`.
**Yeni:** `kargu/tools/execution.el`.
**Test:** `tests/test-tool-registry.el`, `tests/test-permission.el`, `tests/test-permission-operation.el`; yeni `tests/test-tool-execution-contract.el`.
**Proof:** `proof/KarguApproval.tla`, `proof/ApprovalMC.tla`, `proof/ApprovalMC.cfg`, `proof/KarguTools.tla`.

- Registry instance'ı composition'dan gelir; definition/alias/revision ile pending execution ayrı sahiplerdir. Unregister/disable çalışan kaynağı drain/cancel etmeden kodu unload etmez.
- Context taşıyan async executor; eski sync handler yalnız sınır adapter'ı. Mode/schema/availability, alias/direct çağrı, output budget, redaction ve terminal delivery aynı gate'den geçer. Domain path/argv kontrolleri yerinde kalır.
- Captured approval tek kullanımlık; environment/root/config revision ve capability ile bağlanır. Replay/preapproved deposu geri eklenmez. Argv sandbox değildir; OS izolasyonu yoksa doğru koruma düzeyi bildirilir.
- Feature adapter'larının registration değişikliklerini kendi dosyaları dışında yapma; gerekli imzayı koordinatöre bildir. K/J/F/N kendi sahip oldukları adapter'ları taşır; diğerleri son composition commit'inde taşınır.

**Kabul:** fake ve gerçek kontrollü handler aynı contract suite; sync/async/erken/çift/late; alias readonly bypass yok; confirmation yokken ret; observer hatası/reentrancy; unregister sırasında pending iş; snapshot şemasının consumer mutasyonundan korunması. Approval/tools proof kapsamı güncellenir.
**Commit:** owned registry → execution gate → approval/unload.

### E — bağımsız, bounded ve güvenilen hedefe bağlı transport

**TODO:** MOD-04, RISK-02, DEEP-09/12/14, ARCH-15/16/17/19.

**Üretim:** `kargu/api.el`, `kargu/api/client.el`, `kargu/api/http.el`, `kargu/api/request.el`, `kargu/api/retry.el`, `kargu/api/response.el`, `kargu/api/parameters.el`, `kargu/api/sse.el`, `kargu/api/stream.el`, `kargu/api/wire.el`, `kargu/api/tool-calls.el`, `kargu/api/cache.el`, `kargu/api/circuit.el`.
**Test:** `tests/test-api.el`, `tests/test-stream.el`, `tests/test-tool-calls.el`, `tests/test-parameters.el`, `tests/test-cache.el`; yeni `tests/test-transport-contract.el`, `tests/test-stream-pressure.el`.
**Proof:** `proof/KarguCircuit.tla`; yeni `proof/KarguTransport.tla`, `proof/TransportMC.tla`, `proof/TransportMC.cfg`.

- A/C portlarıyla request oluştur; taşıma loop/UI/busy singleton'ını değiştirmesin. Tek logical handle bütün process/retry/watch kaynaklarının sahibi olsun. Retry aynı yetkili endpoint/credential snapshot'ını kullansın.
- Her attempt, normal gönderim ve retry dahil A'nın ortak bütçesinden izin alsın. Bütçe/check sonrası reentrant observer yeni yetki yaratmasın; side-effect unknown durumda kör retry yapılmasın. Circuit provider/connection kapsamlı olsun.
- Raw buffer, eksik UTF-8/satır, SSE event ve tool-call birikimini ayrı ve toplam sınırla denetle. Uzun parse işi bounded drain ile event loop'a dönsün; terminal/tool/onay kayıtları sessiz atılmasın. Limit ihlalinde tek terminal hata ve cleanup.
- Transport-independent callback sonucu typed; string hata sınıflandırmasını boundary'ye al. TLS/redirect/başka origin'e credential taşıma davranışını kontrollü fixture ile doğrula; TLS kapatma/sessiz provider fallback ekleme.
- RISK-02 için somut sürümlü sentetik hata/sözleşme fixture'ı yoksa kaydı açık bırak. Capability varsa tek yerde yorumla; provider/model adı regex'i uydurma. Dış belge doğrulaması gerekirse yalnız resmi/primary kaynağı kaydet.

**Kabul:** loop/chat yüklenmeden start/stream/finish/cancel; spawn/init/backoff/stall/EOF yarışı; byte-byte emoji; newline'sız büyük event; hızlı producer/yavaş consumer; saat sıçraması; duplicate finish; budget üst sınırı; wrong-origin header sıfır. Yeni transport FSM'i/circuit değişirse exhaustive TLC.
**Commit:** explicit request/connection → budget/retry/circuit → bounded parser/drain → güvenlik fixtures.

### F — süreç/job sahipliği ve stres anomalisinin ayrıştırılması

**TODO:** RISK-01, DEEP-05/12/15, ARCH-17/18.

**Üretim:** `kargu/tools/process.el`, `kargu/tools/bash.el`, `kargu/tools/bash/jobs.el`, `kargu/tools/toolchain.el`.
**İzinli yeni:** `kargu/tools/process/session.el` — yalnız fake/yerel interaktif stdin fixture'ı mevcut batch portunun yetmediğini gösterirse.
**Test:** `tests/test-process.el`, `tests/test-tools.el`; yeni `tests/test-job-owner.el`, `tests/test-process-stress.el`, gerekirse `tests/test-process-session.el`.
**Proof:** `proof/KarguProcess.tla`, `proof/ProcessMC.tla`, `proof/ProcessMC.cfg`.

- RISK-01'i ana süreç/grup sinyalleri, stdout/stderr EOF ve callback zamanlarıyla redacted izle. Yalnız ana process'i beklemekle bütün event loop'u ilerletmeyi karşılaştır. Yeşil tekrar veya timeout artışıyla kapatma.
- Job tablosu/counter/foreground process'i açık project/session service'e taşı. İptal yalnız sahipli process tree'yi etkilesin; graceful close, deadline ve force kill ayrışsın. Startup bariyeri/stderr drain tek sonuçtan önce korunsun.
- Batch stdin EOF davranışını değiştirmeden uzun oturum ihtiyacını küçük portla sınırla. CLI entegrasyonu/PTY framework'ü kurma. Detach ve Emacs çıkışı politikasını açık seç; sırlar ve terminal escapes output sınırından güvenli geçsin.
- Bounded tail/archive saklama ve quota yalnız sahipli veriye uygulanır. F'nin output/retention portu I/L'ye aktarılır.

**Kabul:** gerçek yerel fixture + deterministik olay sıraları; orphan child yok; foreign job korunur; silent/stdin-waiting/large stderr/early exit; stop-reset-close; bir cleanup hatası diğer kaynağı bırakmayı engellemez. RISK-01 gözlenemezse kanıt ve belirsizlikle açık bırakılır.
**Commit:** anomaly harness → owned job lifecycle → gerekiyorsa küçük session transport.

## 6. Dalga 3

### G — native loop, history ve ortak bütçe tüketimi

**TODO:** MOD-01, ARCH-07/08/11/14/16, DEEP-01/02/04/09.

**Üretim:** `kargu/loop.el`, `kargu/loop/machine.el`, `kargu/loop/tools.el`, `kargu/loop/ui.el`, `kargu/loop/heal.el`, `kargu/loop/compact.el`, `kargu/history.el`, `kargu/history/store.el`, `kargu/history/protocol.el`, `kargu/history/repair.el`, `kargu/history/compact.el`, `kargu/prompt.el`, `kargu/prompt/default.txt`.
**Test:** `tests/test-loop.el`, `tests/test-history.el`, `tests/test-history-store.el`, `tests/test-heal.el`, `tests/test-compact.el`, `tests/test-fake-agent.el`; yeni `tests/test-headless-events.el`, `tests/test-budget-composition.el`.
**Proof:** `proof/KarguLoop.tla`, `proof/KarguProtocol.tla`, `proof/KarguVerification.tla`, `proof/VerificationMC.tla`, `proof/VerificationMC.cfg`.

- A'nın application/run context'i, D'nin execution gate'i ve E'nin request portuyla motoru bağla. Motor chat helper'ı/global UI pending listesi aramasın. Event kimlikleri frozen context'ten; tek finish, minimum payload, güvenli observer teslimi.
- Retry/heal/compaction/continue aynı bütçeyi tüketir. İkinci overflow ve başarısız/boş özet yolunu test et. Tek-compaction varsayılanını koru; çok aşamalı politika ayrı kullanıcı kararıdır.
- Geçmişin sahipli kuyruğunu koru; her outbound request yine protokol duvarından geçer. Yeni tur maliyetini tekrar bütün geçmişi encode etmeden ölç. Repair/compaction'ı ancak traversal/allocation kanıtıyla sadeleştir.
- Tanı baseline unavailable ise unknown; mevcut hata yeni hata sayılmaz. J'nin tanı portunu tüketmek için gereken değişikliği koordinatöre bildir; J bu dosyayı aynı anda değiştiremez.
- Cache prefix/guidance tekrarlarını davranış testiyle azalt; tool kapalıyken araç adı sızmasın. Usage bilinmiyorsa cache hit/maliyet uydurma.

**Kabul:** chat/UI kaynakları fiziksel olarak yokken fake modelle tool turu; iki view/close/reentrant Stop; protocol duplicate/orphan yarım çağrı; eski compact cevabı; toplam bütçe aşılmaz; baselines bilinmiyorken sahte clean/new-regression yok. Ana loop/protocol FSM değişirse ana exhaustive tarama merge kapısıdır; simulation yeterli değildir.
**Commit:** event/context → ortak bütçe → history/prompt için ölçümlü sadeleşme.

### H — view, seçim ve metadata servislerini sahipli portlara taşıma

**TODO:** MOD-01/06/07, ARCH-01/06/09/12/19; ARCH-08 domain sahipliği.

**Üretim:** `kargu/chat.el`, `kargu/chat/routing.el`, `kargu/chat/render.el`, `kargu/chat/stream.el`, `kargu/chat/transcript.el`, `kargu/chat/prompt.el`, `kargu/chat/header.el`, `kargu/chat/select.el`, `kargu/chat/complete.el`, `kargu/chat/attach.el`, `kargu/chat/tune.el`, `kargu/chat/plan.el`, `kargu/selection.el`, `kargu/api/select.el`, `kargu/api/catalog.el`, `kargu/models/store.el`, `kargu/providers.el`, `kargu/providers/catalog.el`, `kargu/plan.el`, `kargu/plan/context.el`, `kargu/plan/store.el`, `kargu/plan/dispatch.el`, `kargu/plan/buffer.el`, `kargu/ui.el`, `kargu/ui/confirm.el`, `kargu/ui/notify.el`, `kargu/ui/transient.el`.
**Test:** `tests/test-chat.el`, `tests/test-chat-state.el`, `tests/test-selection.el`, `tests/test-model-store.el`, `tests/test-metadata.el`, `tests/test-dynamic-models.el`, `tests/test-confirm.el`, `tests/test-plan.el`, `tests/test-plan-async.el`, `tests/test-attach.el`; yeni `tests/test-view-lifetime.el`.
**Proof:** `proof/KarguSelection.tla`, `proof/SelectionMC.tla`, `proof/SelectionMC.cfg`, `proof/KarguPlan.tla`, `proof/PlanMC.tla`, `proof/PlanMC.cfg`.

- Bu geniş sahiplik **tek commit** değildir: önce metadata/seçim, sonra view/stream, sonra plan/confirmation. Her alt adımda ilgili mevcut testler çalışır.
- Catalog generation/cache/refusal tablolarını explicit provider/model service'e taşı. Capability revision'ı C/E snapshot'ıyla bağlansın; snapshot consumer'ı mutable metadata'yı tekrar okumasın. Off/none/inherit ve successful-empty katalog ayrımı korunsun.
- UI, A/G portlarını görsün; transcript/draft/selection ikinci state deposu olmasın. UI render kuyruğu bounded/coalesced; Stop erişilebilir. Ortak pending confirmation listesi yerine view/iş sahibi handle'lar; yokken güvenli ret.
- Plan dispatcher native motorun özel fonksiyonunu değil application portunu çağırır; claim/approved revision/draft/mode hazırlığı korunur. Close abonelik/cleanup ve owned model picker kaynaklarını bırakır.
- Split-buffer/header-line yerleşim deneyi bu göreve dahil değil. Marker'ları sırf satır sayısı için kaldırma; mevcut UX'i koru.

**Kabul:** iki proje/view; seçim/geç cevap odağı çalmaz; stream sırasında draft/point/narrowing/IME Unicode korunur; observer Stop; confirmation close; model service izolasyonu; async plan preparation/duplicate approval; adapter yokken yükleme. Selection/plan modelleri exhaustive.
**Commit:** metadata service → owned selection → view stream/confirmation → plan adapter/close.

### I — log gizliliği, kesin retention ve ölçümlü sadelik

**TODO:** DEEP-06/07, ARCH-14/15/16; DEEP-15 log kapsamı.

**Üretim:** `kargu/core/log.el`; yeni `kargu/core/redact.el`.
**Yeni testler:** `tests/test-log-privacy.el`, `tests/test-log-retention.el`.

- Varsayılan metadata-only log; wire content açık opt-in ve gizlilik uyarısı. Bilinen credential ve hassas structured alanlar ortak yazma sınırında maskelenir. Ham içerik maskelemeden önce log/temp tamponuna eklenmez; redactor hatasında ham fallback yok.
- URL/query, upstream error echo ve export dahil sentetik sır fixtures. Serbest kaynak metninde kusursuz secret tanıma iddiası yok; esas güvence veri minimizasyonu.
- Logger/runtime retention açık sahipli handle'da; registry/global runtime store ekleme. Retention her yazıdan sonra kesin cap sağlar; sıfır retention, tek dev kayıt, Unicode/narrowing/undo davranışı test edilir.
- Küçük yoğun log / büyük wire dump benchmark'ında trim çağrısı, gerçek silme, allocation ve tepe miktarı ayrı ölç. Kazanç yoksa ring buffer/framework ekleme. C/F/L'nin credential/job/storage politikalarına dar public portla bağlan.

**Kabul:** keyless/nested/bozuk JSON/truncated/error/export; kapalı logda içerik yok; observer hatası ham sırrı açmaz; cap hiçbir yazımda aşılmaz; iki logger owner izolasyonu. Değişen çağıranlar E/G dosyalarındaysa koordinatör bağlar.
**Commit:** minimizasyon/redaction → owned bounded retention → gerekliyse ölçümlü optimizasyon.

## 7. Dalga 4

### J — LSP capability, fresh diagnostics ve koordinat sınırı

**TODO:** COMPAT-01, DEEP-01/13, ARCH-09/15/17/19.

**Üretim:** `kargu/tools/lsp.el`, `kargu/tools/lsp/context.el`, `kargu/tools/lsp/diagnostics.el`, `kargu/tools/lsp/freshness.el`, `kargu/tools/lsp/settle.el`, `kargu/tools/lsp/symbols.el`, `kargu/tools/lsp/skeleton.el`, `kargu/tools/lsp/register.el`.
**Test:** `tests/test-lsp.el`, `tests/test-lsp-settle.el`, `tests/test-lsp-project-diagnostics.el`; yeni `tests/test-lsp-contract.el`.
**Proof:** `proof/KarguDiagnostics.tla`, `proof/DiagnosticsMC.tla`, `proof/DiagnosticsMC.cfg`.

- Checker/server/session/source revision içeren diagnostic snapshot ve range sonuçlarını typed port yap. B'nin edit planına exact end-exclusive aralık aktar; line-only fallback yok. Encoding gerçek adapter capability'sinden alınır; destek bilinmiyorsa clamp/guess değil unavailable.
- Cache ve request ownership explicit LSP service'te; aynı path/server restart/eski callback yeni nesle taşınmaz. İptal, publication listener ve registry unload test edilir; diff/UI gerekmeyen okuma çalışır.
- COMPAT-01 için yalnız capability gerçekten varsa pull/versioned alternatif ekle; sürümsüz push'u güvenilir sayma. Capability yokken mevcut unavailable doğru sonuçtur.
- Proje geneli fresh tanı desteklenmiyorsa yalnız düzenlenen dosya için kanıt bildir. Proje temiz iddiası ekleme. Project-wide kontrol eklenirse bounded/cancellable ve source/version ilişkisi testli olsun.

**Kabul:** emoji/non-BMP/combining/Türkçe/tab/CRLF/EOF/empty/long-line/narrowed; range round-trip; eski request/tick/server; stale/unversioned push; unavailable baseline; duplicate diagnostics; cross-file effect fixture. G/heal tüketici bağlantısını koordinatör yapar.
**Commit:** typed coordinates/snapshot → owned lifecycle → capability varsa pull/project verification.

### K — Dape'yi değiştirmeden debugger adapter sınırını tamamla

**TODO:** ARCH-05/09/17/19, DEEP-13/16. Kapanmış DAPE işleri regresyon tabanıdır.

**Üretim:** `kargu/tools/dape.el`, `kargu/tools/dape/commands.el`, `kargu/tools/dape/context.el`, `kargu/tools/dape/events.el`, `kargu/tools/dape/execution.el`, `kargu/tools/dape/launch.el`, `kargu/tools/dape/lifecycle.el`, `kargu/tools/dape/policy.el`, `kargu/tools/dape/preflight.el`, `kargu/tools/dape/readiness.el`, `kargu/tools/dape/register.el`, `kargu/tools/dape/render.el`, `kargu/tools/dape/selection.el`, `kargu/tools/dape/session.el`, `kargu/tools/dape/watch.el`, `kargu/tools/dape/workspace.el`.
**Yeni:** `kargu/tools/dape/adapter.el` — private Dape erişiminin küçük capability sınırı gerekiyorsa.
**Test:** `tests/test-dape-commands.el`, `tests/test-dape-lifecycle.el`, `tests/test-dape-workspace.el`, `tests/test-dape-startup.el`, `tests/test-dape-watch.el`, `tests/test-dape-execution.el`, `tests/test-dape-selection.el`, `tests/test-dape-admission.el`, `tests/test-dape-readiness.el`, `tests/test-dape-compile.el`.
**Proof:** `proof/KarguDebugClose.tla`, `proof/DebugCloseMC.tla`, `proof/DebugCloseMC.cfg`, `proof/KarguDebugStartup.tla`, `proof/DebugStartupMC.tla`, `proof/DebugStartupMC.cfg`, `proof/KarguDebugExecution.tla`, `proof/DebugExecutionMC.tla`, `proof/DebugExecutionMC.cfg`, `proof/KarguDebugWatch.tla`, `proof/DebugWatchMC.tla`, `proof/DebugWatchMC.cfg`, `proof/KarguDebugSelection.tla`, `proof/DebugSelectionMC.tla`, `proof/DebugSelectionMC.cfg`, `proof/KarguDebugReadiness.tla`, `proof/DebugReadinessMC.tla`, `proof/DebugReadinessMC.cfg`.

- Önce public debugger portu/private Dape çağrıları/capability envanteri. Yeni DAP istemcisi yazma. Version-dependent access tek adapter tarafında; eksik capability güvenli unavailable.
- A context/async ve D tool registry'yi tüket; kaynak owner'ını global run aramasından kurtar. Aynı bağlantı/stop/frame kimliklerini tekrar parse eden kontrolleri azalt; asenkron geçiş sonrası gerekli freshness guard'larını tut.
- 5c492b0 launch/source/foreign UI izolasyonunu gerçek yerel process + fake DAP ile koru. Özellikle server restart, thread/frame ID reuse, child startup, source map ve coordinate revision'ını doğrula.
- Disable/unload önce launch/compile/watch/child/server/stderr kaynaklarını asenkron deadline ile kapatsın; foreign adapter/selection/UI'ya dokunmasın. Advice yalnız kendi resource/capability'si için çalışır ve kaldırılır.

**Kabul:** mevcut bütün Dape ERT; iki adapter/proje, foreign UI, compile Stop, callback sırasında close, duplicate sentinel, bağlantı kaybı, aktif unload; timer/process/listener sayıları tabana döner. Değişen debugger modelleri exhaustive; ilgili olmayan model yeniden yazılmaz.
**Commit:** capability sınırı → explicit owner ve sadeleşme → aktif close/unload.

### L — dosya/persistence writer sözleşmesi ve veri ömrü

**TODO:** DEEP-10/11/15, ARCH-15/17/19; ARCH-04'ün durability sınırı.

**Üretim:** `kargu/files.el`, `kargu/files/async.el`, `kargu/files/worker.el`, `kargu/chat/session.el`, `kargu/chat/session/storage.el`, `kargu/chat/session/schema.el`, `kargu/chat/session/validate.el`, `kargu/chat/session/restore.el`.
**İzinli yeni:** `kargu/files/writer.el`, `kargu/chat/session/retention.el`.
**Test:** `tests/test-file-window.el`, `tests/test-session.el`, `tests/test-session-storage.el`, `tests/test-session-validate.el`, `tests/test-session-restore.el`, `tests/test-session-routing.el`; yeni `tests/test-writer-conflicts.el`, `tests/test-data-lifetime.el`.
**Proof:** `proof/KarguRestore.tla`, `proof/RestoreMC.tla`, `proof/RestoreMC.cfg`; yeni writer FSM varsa `proof/KarguWriter.tla`, `proof/WriterMC.tla`, `proof/WriterMC.cfg`.

- File revision/public snapshot API'si private yardımcıya çapraz çağrı gerektirmesin. Restore/listing worker protokolü bounded ve versiyonlu; metadata seçimi tam session kaydı sayılmasın. Save/load/delete/rename için kaynak ve beklenen revision/commit noktası açık.
- Aynı uygulama içinde çakışan writer'lar sıralansın veya conflict ile reddedilsin; onay beklerken kilit tutulmasın. İki süreçli read-check-write yarışını test et; cooperative lock'ın yabancı formatter/Git'i engellemediğini açık bildir. B'nin edit motorunu yeniden yazma; ortak public writer sonucu koordinatörce B'ye bağlanır.
- Süreç içi rollback, restart uzlaştırması ve power-loss durability farklıdır. Önce desteklenen garanti ve safe conflict/unknown davranışını belgeleyip test et. Otomatik replay, eski approval'ı diriltme veya veri kopyalayan journal ekleme. Recovery gerçekten seçilirse minimum metadata ve restart fixture'ıyla ayrı commit; seçilmediyse açık kapsam sınırı.
- Session, edit snapshot, archive/job/log için veri envanteri; konum/izin/süre/boyut/export/silme kapsamı. Yalnız kendi storage/temp artığını temizle; symlink takip ederek yabancı veri silme. Proje storage opt-in; index/gitignore otomatik değiştirilmez.

**Kabul:** iki Emacs/process aynı kayıt; external replacement/symlink; stale save/delete; disk full/rename hatası; private file mode; kontrollü kill/restart; restore run başlatmaz; pending approval geri gelmez; quota yabancı/aktif veriyi silmez. Normal delete fiziksel secure erase diye sunulmaz.
**Commit:** revision/writer conflict → persistence atomic publication → açık retention/restart politikası.

## 8. Dalga 5

### M — dış entegrasyon yazmadan fake agent backend portu

**TODO:** MOD-08, DEEP-05/16, ARCH-09/16/19.

**Yeni üretim:** `kargu/application/backend.el`, `kargu/backends/native.el`.
**Yeni test/fixture:** `tests/test-backend-contract.el`, `tests/fixtures/fake-agent.el`.
**Yeni proof:** `proof/KarguBackend.tla`, `proof/BackendMC.tla`, `proof/BackendMC.cfg`.

- Önce mevcut G/native motoru küçük bir execution-owner adapter'ı arkasına al. LLM completion transport'u ile kendi tool loop'u olan agent backend'i ayrı sözleşmelerdir; E portunun adını değiştirip aynı sayma.
- Capability/start/resume/events/approval/cancel/session eşlemesi; unsupported resume unavailable. Aynı run'da yalnız bir execution owner; iki loop aynı dosyaları yönetmez. Native adapter mevcut onay/edit/rollback kapılarını korur.
- Fake agent fixture aynı event/approval/Stop/UI sözleşmesini sağlasın. Native/backend seçimi ve UI binding'i koordinatör yapar; M diğer dosyalara “küçük bağlantı” adıyla yazmaz. Test fixture bir üçüncü taraf binary bağımlılığı değildir.
- MCP/IPC/gerçek CLI, credential keşfi veya executable indirme yok. Dış değişikliği Kargu onayından geçmiş gibi gösterme; effect unknown durumunu taşı.

**Kabul:** native/fake aynı contract suite; tek run; disconnect; duplicate/out-of-order; approval'da reset; unsupported resume; foreign session; cancel sonrası late event; LLM transport yokken fake backend UI akışı. Model kapsamı açık ve exhaustive.
**Commit:** port/native adapter → fake contract/fault suite. Gerçek adapter ayrı sonraki plan.

### N — bağlam/egress, shell ve endpoint güvenliğinin bileşimi

**TODO:** ARCH-02, DEEP-08/14/16; MOD-08 için izinli context sınırı.

**Üretim:** `kargu/fs.el`, `kargu/tools/search.el`, `kargu/tools/git.el`, `kargu/tools/skill.el`, `kargu/tools/webfetch.el`, `kargu/net/address.el`, `kargu/net/resolve.el`, `kargu/tools/deps.el`.
**Yeni:** `kargu/permission/egress.el`.
**Test:** `tests/test-security.el`, `tests/test-fs.el`, `tests/test-git.el`, `tests/test-webfetch.el`, `tests/test-address.el`, `tests/test-deps.el`; yeni `tests/test-egress-policy.el`.

- Proje talimatı/dosya/web/tool sonucu kökenini trusted user policy'den ayır. Etiketleme tek başına güvenlik değildir: izin ve egress programatik kapıda uygulanır. Request'e bütün environment/credential veya kapsam dışı dosya eklenmez.
- C'nin connection snapshot'ı ve D'nin izin kapısıyla context paylaşımı provider/backend hedefi ve project scope'a bağlanır. Symlink, out-of-root ve redirect ayrı sınırlarını korur. Read-only, veriyi uzak hedefe göndermeye sınırsız yetki değildir.
- Yapılandırılmış git/search argv; `--`, option injection, hook/config, executable/PATH kimliği ve canonical root testleri. Serbest shell analizini sandbox gibi sunma. OS izolasyonu capability'si yoksa açık protection-level/unavailable; desteklenmeyen platforma tahmini wrapper yazma.
- Gerçek OS sandbox özelliği gerekiyorsa desteklenen platform ve izinli mount/ağ/secret politikası ayrı kabul kararıdır; salt approval güvenlik testi onun yerine geçmez. G/prompt, E/request ve C/config bağlantı değişikliklerini koordinatör bağlar.

**Kabul:** sentetik injection içeren dosya/tool; secret context; yanlış provider/origin; symlink/option injection; ağ/ortam kapsamı; key/config/executable değişimi. Modelin talimata uymasını değil, yetkisiz yürütme/egress'in kapıda reddini test et.
**Commit:** provenance/egress → yapılandırılmış adapter trust → sistem fault fixtures.

### O — eski testlerde gerçek lint borcunu temizleme

**TODO:** TEST-01; ARCH-18 ve değişiklik disiplini.

**Yalnız test dosyaları:** `tests/test-api.el`, `tests/test-async.el`, `tests/test-attach.el`, `tests/test-chat.el`, `tests/test-compact.el`, `tests/test-confirm.el`, `tests/test-contract.el`, `tests/test-dynamic-models.el`, `tests/test-fake-agent.el`, `tests/test-heal.el`, `tests/test-history.el`, `tests/test-languages.el`, `tests/test-loop.el`, `tests/test-lsp.el`, `tests/test-metadata.el`, `tests/test-permission.el`, `tests/test-session.el`, `tests/test-state.el`.

- 2026-10-21 güncel checkdoc envanterinde 23 dosyada 84 uyarı var; tarihsel 22 dosya/73 uyarı kaydı farklı tarama kapsamına aittir, sayılar tek başına regresyon kanıtı değildir. Envanteri kendi entegre tabanında tekrar al; gerçek doc/header borcunu fixture false-positive'inden ayır.
- N ile aynı dalgada yazılabilen `tests/test-deps.el`, `tests/test-git.el`, `tests/test-security.el`, `tests/test-webfetch.el` O'nun alanında değildir; onların lint bulgularını N'ye/koordinatöre raporla. `tests/test-integration.el` koordinatörde kalır. Böylece 23 dosyalık envanterin bütün sahipleri bellidir.
- Başlık/Code/docstring/quoted symbol sorunlarını düzelt. Sentetik hata metni, beklenen çıktı, assertion veya test mantığını sırf checkdoc susturmak için değiştirme; global checkdoc kapatma yok. Gerekli dar istisna kanıtıyla raporlanır.
- Üretim kodu veya test helper davranışı değişmez. Kaybolan/yeniden adlanan test sayısını raporla; test silerek borç kapatma.

**Kabul:** aynı ERT sözleşmeleri; byte-compile sıfır uyarı; gerçek checkdoc borcu sıfır veya tek tek gerekçeli fixture false-positive listesi; kapsam/test sayısı kaybı yok.
**Commit:** başlıklar → gerçek docstring sorunları; fixture sınıflandırma notu teslimi.

## 9. Her dalganın entegrasyon kapısı — yalnız koordinatör

1. Commit/file allowlist denetimi. Worktree'deki kullanıcı değişikliklerini koru; skills/agents/gitignore stage edilmediğini doğrula. Çakışan bir sözleşme varsa iki implementasyonu üst üste taşımak yerine önce tek doğru sahip seç.
2. O dalgadaki public portları composition root'ta bağla. Ajanların kapsam dışında bildirdiği ince adapter bağlantılarını yap; ikinci state/result/registry deposu oluşturma. Eski consumer kalmadıkça global köprüyü silme; son consumer taşınınca hem declaration hem writer'ı kaldır.
3. Yeni testleri `tests/run-tests.el`'e ekle; helpers yalnız ilgili sahiplik fixture'ını izole etsin, üretime mock algılama ekleme. Yanlış davranışı tekrar üretmeyen “test yeşil olsun” mock'u kabul edilmez.
4. Taze batch Emacs'te odaklı + tam ERT; uyarısız değişen üretim/yeni test derlemesi/checkdoc; eski test lint baseline karşılaştırması; `git diff --check`. Opsiyonel adapter'ları fiziksel çıkarmış paket ağacıyla headless/exclusion matrisi.
5. Etkilenen TLA+ modelini test kapsamıyla eşleştir. Yeni model flag/config'ini ortak runner'a ekle; exhaustive taramayı çalıştır. Ana loop/protocol/state/circuit/tools modeli semantik olarak değiştiyse ana model de son merge kapısında exhaustive geçmeli; uzun süreceği için atlanmışsa kapı açık kalır.
6. `todo.md`'den yalnız kapanış kanıtı tamamlanan kayıtları sil. Geniş mimari kayıt kısmen kaldıysa sadece kalan sınırı yaz; K/Y/D ayrımı korunsun. RISK-01/02, unsupported capability veya seçilmemiş deney, sırf testler yeşil diye kapatılmaz.
7. Dar composition/integration commit'i ve dalga teslim raporu yayımla. Sonraki üç işçi bu revision'ı alır; eski tabanla devam etmez.

### Son bütünleşik kabul senaryoları

- Run claim → frozen session/connection → request → approval → edit commit → fresh verification → tek terminal rapor; her noktada Stop/reset/view close/failure enjekte edilir.
- Approval sırasında config/endpoint/root/session/registry revision değişimi; commit sonrası cevap kaybı; rollback sırasında foreign writer; stream bitişinde kapanan view; compile sırasında Stop; restart sonrası eski event.
- LSP/Dape/chat/diff/Bash/Git/search/skill/webfetch modülleri ayrı ve birlikte yokken bağımsız işlevler devam eder; güvenlik adapter'ı yokken yetkisiz write/egress olmaz.
- İki session ve iki test application izolasyonu; tek uygulamada ikinci run reddi; başka adapter'ın process/UI/selection'ı korunur; aktif disable/unload sahipli kaynakları bırakır.
- Tepe byte/öğe/kuyruk, parse/encode/traversal sayıları ve cleanup kaynakları ölçülür. Flaky zaman eşiklerini, sahte başarıyı veya consumer mutasyonunu gizleyen broad mock kullanılmaz.
- Yeni runtime mutable global yok; kalan her global consumer ve framework whitelist kalemi envanterde. Bütün global alanları tek global struct'a taşımak kapanış değildir.

## 10. TODO kapsam eşlemesi ve karar isteyen işler

| Kayıt | Asıl sahibi / kabul bağlantısı |
|---|---|
| CONFIG-01 | C; E/C bağlantı snapshot fixture'ı |
| RISK-01 | F; yeniden üretim/iz kanıtı yoksa açık |
| RISK-02 | E; somut resmi sözleşme/fixture yoksa açık |
| COMPAT-01 | J; yalnız capability destekliyorsa alternatif |
| ARCH-01/11/12 | A → G/H → koordinatörde son bridge silme |
| ARCH-02/03 | D/N ve B'nin frozen edit approval'ı |
| ARCH-04 | B/L; process-local sınır ile writer/durability ayrımı |
| ARCH-05 | K; doğrudan DAP prototipi kapsam dışı |
| ARCH-06 | H veri/view ayrımı; split UI deneyi ayrıca karar |
| ARCH-07 | G; protokol duvarı ve ölçümlü history |
| ARCH-08/09/10/13/14/15/16/17/18/19 | Her görevin tip/bağımlılık/validation/FSM/kaynak/karmaşıklık review kapısı; birine havale edilip diğerlerinde atlanmaz |
| MOD-01/02 | G/H ve D |
| MOD-03 | Aktif TODO başlığı yok; eski seçim/keşif devamı C/H |
| MOD-04/05/06/07 | E / A / H / A+B+D+H |
| MOD-08 | M + koordinatör; gerçek dış adapter'lar sonra |
| DEEP-01/02/04 | G/J; çok aşamalı compaction davranışı ayrıca karar |
| DEEP-03 | `988dd96` ile kapanan process-local batch işinin tekrarı yok |
| DEEP-05/06/07/08/09 | F / I / I / N / A+E+G |
| DEEP-10/11 | L; B ile ortak effect/revision sözleşmesi |
| DEEP-12/13/14/15/16 | E+H+F / J+K / C+E+N / I+F+L / koordinatör bütünleşik kabul |
| TEST-01 | O; N/koordinatöre ait dosyalar aynı dalgada çakışmaz |

Otomatik varsayılmayacak ürün kararları: yeni UI yerleşimi, sıfırdan DAP,
çoklu compaction politikası, gerçek OS sandbox'ın platform matrisi,
power-loss journal/durability ve gerçek agent/CLI entegrasyonları. Bu işler
reddedilmiş veya bitmiş sayılmaz; desteklenen garanti sınırı açık yazılır.
Seçilmemiş opsiyonel özellik merge'i tek başına bloke etmez; açık güvenlik,
veri kaybı, yanlış başarı veya kaynak sahipliği kusuru opsiyonel diye gizlenmez.

Son teslim, her ajan için hash/dosya/test/proof/bulgu raporu ile koordinatörün
bütünleşik kontrolüdür. Kullanıcı ayrıca onay vermeden master merge/push
yapılmaz. Gerçek üçüncü taraf entegrasyon planı bundan sonra hazırlanır.
