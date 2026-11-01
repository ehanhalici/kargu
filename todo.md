# Açık işler — birlikte çözülecek gruplar

İnceleme tabanı: 32e917b, 2026-10-22. İnceleme ERT baseline'ı: 1116/1116,
2026-10-23. Rust göçünün güncel uygulama/test kaydı: .codex/12_MIGRATION_PROGRESS.md.
G02 bağlantı/metadata sözleşmesi ve kalan köprüler: docs/connection-ownership.md.
Tamamlanan geçiş alt maddeleri takip için `[x]`, kalan işler `[ ]` ile tutulur;
tekrarlanan iş tarifleri birleştirilir. Bir çekirdeğin testinin geçmesi,
native tüketicilerin ona bağlandığı anlamına gelmez. Eski ARCH/MOD/DEEP/RISK kimlikleri kaynak
eşlemesidir; yeniden numaralanmaz ve bağımsız ikinci iş listesi oluşturmaz.

K = kod yolu doğrulandı; Y = kontrollü yeniden üretildi; D = ek kanıt/ölçüm
gerekiyor. Mimari hedef ve uyumluluk isteği, doğrulanmış bug sayılmaz.
Önce yetki/veri kaybı/yanlış başarı, sonra yanıt verebilirlik ve ölçümlü performans.
Aşağıdaki kaynak yolları kargu/ altında; tests/ ve proof/ depo kökündedir.

## Çalışma şekli

Her grup için ayrı **Plan mode → onay → Default mode** döngüsü uygulanır.
Bu belge gruplamadır; aşağıdaki uygulamalar henüz onaylanmış sayılmaz.

1. Plan mode: yalnız kalan açığı doğrula; mevcut portları/testleri oku, gerekli
   dosyaları, silinecek eski yolları, küçük commit sırasını ve kabul testlerini
   belirle. Yeni framework veya zaten çalışan motoru yeniden yazma.
2. Default mode: onaylanan grubu regresyon → düzeltme/refactor → ilgili/tam ERT
   → derleme/checkdoc → etkilenen exhaustive TLC → commit sırasıyla uygula.
   Her grup tek dev commit olmak zorunda değildir.
3. Kapanan maddeyi `[x]` ile işaretle; kısmen kapanan üst grup açık kalsın.
   Yeni bulguyu aynı kök nedense mevcut gruba, değilse ilgili grubun sonuna ekle.
   Kanıtsız risk, yalnız yeşil tekrarlarla kapatılmaz.
4. Bir grubun ortak sözleşmesini sonraki grup yeniden tasarlamaz. Gerekli dar
   bağlantıyı kendi tüketicisinde yapar; son tüketici taşınmadan köprü silinmez.
   Kalan global tüketicilerin isimleri kapanışta kaydedilir, son silme G13'tedir.
5. skills.md stage edilmez; kullanıcıya ait .gitignore/yerel dosyalar korunur.
   Harici uygulama adapter'larının onaylı kapsamı .codex/03 ve 04 Aşama 5'tedir.
   Canlı hesap/ücretli CLI/MCP testi, binary indirme/kurulum, credential taşıma
   ve master merge/push ayrıca onay gerektirir.

### Onaylı Rust geçişi ile ilişki

Kullanıcının ayrıca onayladığı Rust göçünde uygulama sırası .codex/04'tür;
G03–G13'teki kalan davranış/güvenlik yükümlülükleri Rust'a geçince kapanmaz.
Mevcut API desteği Rust'a taşınırken Codex, Antigravity, Claude Code ve OpenCode
backend'leri ayrıca eklenecek; provider seçimi ve kabul koşulları .codex/03'tedir.

`find_files` ve `list_files` gerçek Elisp tool gate'ine bağlandı; eski glob
engine'leri ve senkron directory scanner silindi. Kullanıcının Unix/GNU
bileşimi kararıyla özel Rust listing tarayıcısı da kaldırıldı: `list_files`
ortak Rust process/gate üzerinden GNU ls çıktısı verir (.codex/17–19).
`find_files` şimdilik native'dir (.codex/15). Genel program/argv için Rust
reverse approval + Emacs presenter bağlıdır; Bash/job ve interactive session
consumer'ları native porttadır (.codex/20–25). `workspace_grep` de rg/GNU grep
adapter'ına bağlandı; eski Elisp grep engine'i kaldırıldı (.codex/26–27).
`git_status` native Git + complete-output portundadır; eski Elisp status
engine'i silindi (.codex/28). Diğer read/mutation Git tüketicileri de native
kapıya taşındı (.codex/53, 56, 58).
Kullanıcının API önceliğiyle 162-provider catalog baseline Rust asset/core
snapshot'a taşındı (.codex/29). Chat/model-list HTTP ve SSE motoru native'dir;
Elisp parser/accumulator/watchdog silindi (.codex/30). Credential/UI portları
kalır; wire ve prompt-cache engine'leri de native'ye taşınıp silindi (.codex/31).
Request policy de native'ye taşınıp eski seçim/merge motorları silindi (.codex/32).
Credential/header assembly de native'ye taşınıp Elisp üretim motorları silindi
(.codex/33); credential lookup editör portudur. Katalogun eski senkron credential
discovery yolu da owned async connection portuna geçirildi (.codex/44); genel
run/history ve native config/endpoint policy açık olduğu için tüm API göçü
tamamlandı sayılmaz.
API tüketicileri application-owned native service lease kullanır (.codex/34–35);
bu henüz native agent run/history sahipliği değildir. Native budget HTTP
admission/drain ve gerçek root-run consumer'a bağlandı; eski Elisp debit/token
toplama motoru silindi (.codex/36). G08 hard reservation/pricing ve genel native
claim/tool/run birliği hâlâ açıktır; yalnız gözlenen token tavanı harcama garantisi değildir.
Native retry/circuit actor, charged replay, owned observer ACK ve detached GUI
projection/reset portları eklendi (.codex/37–38). High-level plain/stream chat
varsayılanı bu portlara geçirildi; Elisp retry/backoff/timer ve circuit admission/
sayaç/probe motorları silindi (.codex/40). Native terminal kategoriler Result
olarak gelir; plz DTO/bağımlılığı kaldırıldı. Manuel recovery, verilen native
reset'in ACK'ini bekler; UI görünümü admission kararı vermez.
Model metadata için kesin rate/context/output alan tipleri ve scoped RawValue
sınırı eklendi (.codex/41). Default /models discovery envelope normalizasyonu
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
01 uyum denetimi ve kalan kaynak-sahipliği bulguları .codex/39'da tutulur;
testlerin yeşil olması bütün Rust ağacının mimari uyum sertifikası değildir.
Eski fd-rooted listing garantileri yeni ls adapter'ına atfedilmez. Owner/cancel,
output cap ve onay regresyonları G11/G13'ün tamamını kapatmaz; context/egress
ve diğer global tüketiciler aşağıdaki gruplarda açık kalır.
Todo 2 native araç consumer kapanışı ve kalan köprü envanteri .codex/58
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
  Gerçek Codex/Antigravity/Claude Code/OpenCode backend'leri .codex/04 Aşama 5'in
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
  eski fixture istisnaları tek tek gerekçeli; ilgili exhaustive modeller.
  Ana loop/protocol/state/circuit/tools semantiği değişmişse ana model de
  taransın. Yerel TLC bütün sistemin kanıtı değildir; simulation proof değildir.
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

**Aktif denetim talimatı (2026-11-01):** kullanıcı commit edilmemiş bütün
Git değişikliklerinin incelenmesini, önce 6–7–8'in eksik alt işlerinin yazılmasını,
sonra doğru uygulamaların korunup hataların/eksiklerin düzeltilmesini ve doğrulanan
dilimlerin commit edilmesini istedi. Bu talimat önceki ara test/commit yasağının
yerine geçer. Mevcut `[x]` işaretleri denetim girdisidir; tüketici bağlantısı,
legacy temizliği ve güncel kabul kanıtı olmadan kapanış kanıtı sayılmaz.
Gerçek kullanıcı session dosyaları ve canlı provider hesapları test girdisi değildir.

**Aktif hedef ve test kuralı (kullanıcı, 2026-11-01):** bu listedeki 1–6 dahil
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
checkdoc ve bounded lifecycle TLC temiz. Ayrıntılar .codex/12/52.

Bu liste .codex/04'teki onaylı göçün kalan **tüketici taşıma/kaldırma sırasını**
özetler; G03–G13'ün yerine geçen ikinci kapsam veya yeni ürün kararı değildir.
Kutular ancak gerçek tüketici Rust'a bağlanıp eşdeğer testler geçtikten ve eski
Elisp motoru silindikten sonra kapanır. Her doğrulanmış küçük dilim ayrı commit
olur; bağımsız işler önkoşulları sağlanınca öne alınabilir. Emacs'in canlı buffer,
undo/save, Eglot/Dape ve UI adapter'ları gereksiz kod sayılarak kaldırılmaz.

- [x] **1. Config ve bağlantı hazırlığının kalan native politikası** —
  TOML/schema/precedence/env/keyless ve endpoint/model seçim kararlarını typed,
  revision-bound native portta birleştir. Katalog hedef/public kararı aşağıda
  kapandı; API-base seçimi de exact-revision native resolver'a geçti.
  UI yalnız yayınlanmış DTO'yu
  tüketsin; auth-source/callable credential yalnız sahipli Emacs interop portu
  olsun. Artık kullanılmayan Elisp parser/precedence yollarını sil. Cold config,
  custom/local provider, malformed refresh, stale revision, cancel ve iki
  application fixture'larını koru. Kaynak: Aşama 4, G09/G13; .codex/10, 42, 44–46.

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
      policy native'de. Temel commit `ff96691`; consumer kapanışı .codex/52'de.
    - [x] Gerçek config/connection/UI consumer cutover ve kalan Elisp publication/
      precedence/env/keyless/eligibility/default-selection motorlarını sil.
  - [x] Gerçek config refresh tüketicisini `configuration/parse` native portuna
    bağla; TOML/schema/legacy-import ve content digest Rust'ta. Eski 221 satırlık
    `config/toml.el` silindi. Bounded source, safe line errors, legacy scalar
    provider + singular table uyumu, provider sırası, cold startup, parent cancel,
    deadline, stale generation, iki application ve lost lease testli. .codex/48.
  - [x] Candidate-path seçimi ve bounded regular-file capture gerçek config
    refresh tüketicisiyle `configuration/read` native owned IO portuna geçti.
    Eski editor file script/decoder/source handoff/parse bridge silindi; credential
    interop worker kaldı. Dört ortak read slotu actual join'e kadar tutulur;
    epoch/cancel/deadline/late reply, fd-rooted regular inode/revision, symlink,
    özel dosya ve malformed-first-no-fallback testli. Cold absent explicit refresh
    artık core başlatır; missing core/capability fail-closed, passive UI memory-only.
    Read portunun generation echo'su native authority değildir; son publication
    writer'ı artık application actor'dır (consumer cutover .codex/52).
    OS syscall iptali cooperative'dir, hard filesystem kill garantisi yok. .codex/51.
  - [x] Env/keyless/credential precedence ve provider/model seçimini native
    publication/DTO tüketicisine bağla; memory-only UI reader'a gizli RPC/IO
    ekleme, eski Elisp karar fonksiyonlarını son consumer geçince kaldır.
  - [x] Cutover'da bulunan ek lifecycle/snapshot işleri: geç prepare acquisition'ı
    cancel sonrası abort; lost commit ACK'te rollback varsaymadan exact-revision
    ret ve explicit refresh ile reconciliation; aynı epoch'ta session replacement
    ret; foreign application callback guard'ı ve legacy UI metadata scope koruması.
    Env/options ilk yield öncesi bounded private capture; source fingerprint'te
    UI selection bağımsızlığı ve collection count/length framing testli. .codex/52.
  - [x] Geçişte bulunan ek log hijyeni: `kargu-set-provider` artık tam API-base'i
    log/message'a yazmaz, raporlama için endpoint'i okumaz. Provider/model/no-model
    seçimi ve prefetch hedefi korunur. Sentetik endpoint/query-secret/key/tenant
    regresyonu önce kırılıp düzeltmeden sonra geçti. Ayrıntılar .codex/49.
  - [x] Config refresh admission düzeltmesi: kapalı parent/inactive owner veya
    henüz timer dispatch edilmemiş expired parent generation sayacını artırıp
    başka canlı publication'ı stale saydıramaz. Worker/core başlamadan ret ve
    timer/child cleanup testli. `timeout=0`/negatif/geçersiz/büyük değerlerle
    dosya capture sınırı kapatılamaz/uzatılamaz; pozitif kısa değer ve parent
    deadline kazanır. Gerçek held native cevap ve timeout matrisi .codex/50'de.
  - [x] Katalog URL türetme/public-auth kararı native typed endpoint portunda.
    `provider/catalogTarget` salt okunur/epoch-bound; custom/private/dedicated/
    native-models path ve missing-capability fixture'ları geçti, eski Elisp URL/
    public/native-path karar fonksiyonları silindi. GET aynı connection'a bağlıdır;
    kayıp epoch'ta reconnect/fallback yoktur. Ayrıntı .codex/46.
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
    startup öncesi reddeder; doğrudan exact URL semantiği korunur. .codex/47.
    Bu iki URL alt işi tek başına üst işi kapatmadı; kalan authority/precedence/
    selection consumer cutover'ı .codex/52'de ayrıca tamamlandı.

- [x] **2. Kalan native araçlar ve tek izin kapısı** — `read_file`, diğer Git
  işlemleri, skill/toolchain ve webfetch tüketicilerini ortak owner/process/path/
  egress/approval portuna taşı. Mevcut `ls`/`rg`/`git` motorlarını yeniden yazma.
  Registry/alias/mode ve doğrudan çağrıda aynı gate'i kullan; job/foreground/global
  köprüleri ancak son tüketici geçince kaldır. Gerçek cancel/drain, bounded çıktı,
  foreign owner, missing adapter ve unknown effect kabulünü doğrula. Kaynak: Aşama 2,
  G04/G05/G11; .codex/17–28.

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
        etmez. Bu test tek başına yeni native capability değildir. .codex/55.
      - [x] Ek güvenlik düzeltmesi: aynı-boyutlu dosyada mevcut `git_status`
        refresh'i de clean filtresi çalıştırabiliyor. Status da isolated profile'a
        alınsın; yalnız fsmonitor kapatmak yeterli değil. Native gate/scope altında
        config/layout preflight → actual drain → final query zinciri kurulsun.
      - [x] `git_worktree_read` cap; private safe config/metadata, original index
        koruma, typed argv/range ve prepared/issued resource lifecycle. Yeni unsafe
        config sonradan eklense de final sorgu okumaz. Native alias/direct/mode,
        cancel→actual PGID reap→cleanup→admit kabulü; eski Elisp yolları silindi.
        Submodule working tree kapsamı text + coverage ile açıkça dışarıdadır;
        legacy symlink HEAD/layout açık unavailable, unsafe fallback yok. .codex/56.
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
      kendi tüketicileri için kalır; model read fallback'i değildir. .codex/54.
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
      Eski Elisp scanner/parser/global TTL cache silindi. Ayrıntı .codex/57.
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
  ve job/foreground/counter global aynaları silindi. Detay/kabul .codex/58.
  `tools/process.el` yalnız diff Git-apply (madde 3), Dape context/preflight
  (madde 4) ve session listing worker'ı (madde 7) için kalır; native araç fallback'i
  değildir. Dape file worker, credential/UI/package ve binary locator interop'u
  kendi tüketicileri için korunur. G04–G13 ve tüm Rust göçü kapanmış sayılmaz.

- [ ] **3. Edit/proposal/review motoru** — diff/proposal/revision/journal kararlarını
  Rust'a taşı; Emacs'te yalnız canlı belge kontrolü, transaction/undo/save ve review
  etkileşimi kalsın. Tek typed sonuç kullan; dirty buffer, coding/EOL, save-hook,
  conflict, partial/unknown ve foreign rollback davranışını koru. Son consumer'dan
  sonra Elisp stage/review/pending-plan/global edit motorlarını sil. Kaynak: Aşama 2,
  G04/G10; .codex/06 ve 08.

  **2026-10-29 tekrar denetimi:** Native revision worker/atomik onay güncellemesi,
  version-bound process-local rollback ve asenkron batch producer eklendi ve
  düzeltildi. Tool/LSP/plan/interactive undo yolu yalnız açık
  `kargu-diff-native-edit-enabled` seçimiyle etkin; ready/mocked test fonksiyonları
  backend seçmez, seçilmiş işlem başka writer'a düşmez. 3.4–3.5 tamamlandı.
  Tam hunk ölçümü, default consumer cutover, verification readers ve legacy
  temizliği tamamlanmadığından 3.6–3.10 kalan işleriyle açık tutulur.
  Güncel kapsam/kanıt/sınırlar:
  `docs/task3-audit-2026-10-29.md`.

  - [x] **3.1 Sözleşme ve kabul envanteri:** mevcut public edit/LSP/patch/review/
    rollback consumer'larını ve testlerini eşle; tek typed file/batch outcome,
    save policy, revision/hash, owner ve cancellation sözleşmesini belirle.
    `01_RUST_CORE_PATTERNS.md` newtype/TryFrom, tek writer, typestate, bounded
    IPC/worker ve no-panic/unsafe kuralları her dilimin kabul kapısıdır.
    Consumer/test eşlemesi ve sahiplik/result sözleşmesi:
    `docs/native-edit-ownership.md`. Pure native prepare/review temeli 9 gerçek
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
  - [x] **3.8 Consumer cutover:**

    - [x] edit_file/write_file/apply_patch, LSP/plan ve interactive native undo için
      açık `kargu-diff-native-edit-enabled` yolu bağlı. Backend seçimi readiness/
      mocked fonksiyonlara bağlı değil; seçilmiş işlem başka writer'a düşmez.
      Receipt saved/count alanları ve bounded passive UI referansları kullanılır;
      APPLIED-prefix'ten typed sonuç çıkarılmaz. Kanıtlar 3.22'de.
    - [x] Loop verification/change reader'larını aynı native servis/sonuca geçir;
      bütün consumer kabulü sonrasında varsayılan native cutover'ı tamamla.
    - [x] **3.8a Native değişiklik görünümü:** verified receipt'ten owner/session/
      edit/file revision-bound change kaydı üret; snapshot eviction'ından bağımsız
      verification kuyruğu ve exact identity consume porta bağlansın. Snapshot/
      changed-files/run-files Elisp tabloları domain authority olmasın.
      Değişiklik/verification metadata ledger'ı ve exact consume kaynağı eklendi;
      path-only consume portu, daha yeni aynı-path kaydını silebildiği için kaldırıldı.
      Service close bounded closed-ID kaydı tutar; geç receipt geçmişi diriltemez,
      `drained` gerçek preparation/editor settlement'ını bildirir. Elisp close
      yakalanmış application'ı kullanır ve drain'i bekler. Gerçek change reader
      cutover, eviction coverage ve bütün consumer kabulü hâlâ açık.
    - [x] **3.8b Tüketici bütünü:** tool, LSP edit, plan, interactive undo,
      changed-file listesi, diff stats ve loop verification aynı native sonucu
      kullansın. Save/hook/partial/unknown gerçek receipt'ten gelsin; sync caller
      callback'e geçirilsin, seçilmiş işlem farklı writer'a düşmesin.
  - [x] **3.9 Son legacy temizliği:** son consumer sonrası Elisp patch/proposal/
    stage/review/pending-plan/snapshot/change domain motorlarını ve default/global
    edit aynalarını sil; yalnız canlı transaction/save/undo ve UI adapter'ları kalsın.
    `tools/process.el` diff tüketicisi de kalksın; Dape/session consumer'ları korunur.
    - [x] Eski parser/proposal/stage/review/rollback fonksiyonlarının public ve
      private çağıran envanterini bitir; async public adapter'ları koruyarak eski
      motorları ve compatibility backend seçimini kaldır. Edit service yalnız
      native handle ve passive UI kaynakları tutsun; clear/close/unload gerçek
      pending review/activity settlement'ını beklesin.
  - [ ] **3.10 Bütünleşik kabul/kapanış:**

    - [x] Güncel filtresiz locked Rust 467/467 (29 compile-fail), full source ERT
      1.345/1.345, focused bridge/edit 107/107 ve son değişikliklerde 3/3;
      strict Clippy/fmt,
      warning-as-error bytecompile ve production checkdoc temiz.
    - [x] Altı exhaustive TLC modeli tam verdict ve boş kuyrukla geçti:
      preparation 319.746, journal 1.116, issuance 959, activity 356,
      transaction 560, revision 272 farklı durum; revision half-commit mutantı red.
    - [x] 3.6–3.9, 3.18 ve 3.23'teki kalan kabul/geçiş işleri tamamlanınca bütün
      kontrolleri nihai kodda tekrar doğrula; üst madde 3'ü en son kapat.
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
  formatlama yollarını sil. Kaynak: Aşama 3, G06/G07/G11; .codex/05 ve 09.

  - [x] **4.1 Ortak sensor DTO:** explicit application/session/run/generation ve
    document/server/publication veya connection/stop/thread/frame kimlikleri;
    status, range, severity, truncation ve byte/item/depth sınırları. Koordinat
    1-based line / 0-based Unicode scalar / end-exclusive; tahmin veya clamp yok.
  - [ ] **4.2 Reverse RPC:** mevcut pending/oneshot/deadline temelini
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
  - [ ] **4.3 LSP belge/tanı:** Emacs capture yalnız document tick, server/version,
    publication ve raw diagnostic DTO üretsin; native freshness/aggregation ve
    formatlama tüketicileri bağlı olsun. Sürümsüz stale/pending push temiz tanı
    sayılmasın; gerçek destek varsa fresh pull capability kullanılsın.
  - [ ] **4.4 Symbols/Xref:** definition/reference/hover/document-symbol/skeleton
    adapter'larını typed range/tree snapshot'a geçir; ambiguity ve unavailable
    açık olsun. Marker/cons/editor nesnesi JSON'a sızmasın; native render/budget.
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
  - [ ] **4.4b Kalan symbol consumer ve kabulü:** definition/reference/hover ve
    project skeleton portlarını, captured context-file kullanımını ve edit_by_lsp
    hazırlığını aynı typed kaynağa bağla; public/standalone/mention consumer'larını
    geçirip son legacy formatter/parser/cache consumer'larını kaldır. 4.4a'nın
    native pipe/provider, gerçek imenu/Eglot ve ERT kabulünü son toplu kapıda
    çalıştır. Kaynaklar native_agent/symbols.rs, symbols/document/tests.rs,
    sensor_contract.rs ve test-native-symbols.el'deki mevcut kaynaklar toplu Rust/
    ERT kabulünde çalıştırıldı; bu sonuç kalan xref/public/context consumer'larını
    veya gerçek Eglot server kabulünü kapatmaz.
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
  - [ ] **4.5 Dape capture:** connection/stop generation/thread/frame ve variable
    reference bağını capture ve delivery'de doğrula; bounded stack/scopes/
    variables/watch DTO, actual async completion ve capability yokluğunda ret.
  - [ ] **4.6 Dape mutation/lifecycle:** evaluate, execution control, breakpoint,
    launch/compile/readiness/reset/close aynı native gate ve scope'u kullansın;
    Emacs Dape resource revalidation'ı korunsun. Continue veya replacement bütün
    eski pending reference'ları geçersiz kılsın; foreign connection kapanmasın.
  - [x] **4.7 Mention lexer:** legacy @path/@file::symbol ve file/buff/sym/git/
    line/folder target'larını typed span ve target_id ile native ayrıştır; quoted/
    escaped/Unicode ad, email ve fenced-code ayrımı, ambiguity ve invalid range.
  - [ ] **4.8 Context resolver:** `editor/resolve_mentions` RAM snapshot/tick/dirty
    portu; kapalı disk/Git/folder native mevcut servislerde. Unsaved/new/narrowed
    buffer korunur; root dışı/fileless buffer explicit capability ister. Folder
    ignore/depth/count/byte/deadline, binary/not_found/rejected ve bounded paging.
    Read_file RAM primitive'i standalone ve native-parent okuyucularda ortaktır;
    unsaved/new/narrowed kaynak korunur ve worker sonrası buffer açılması da
    disk sonucunu geçersiz kılar. Mention resolver/folder/Git/provenance tüketicisi,
    fileless/output-buffer grant ve genel büyük snapshot paging hâlâ açık.
  - [ ] **4.9 Provenance/bütçe/egress:** immutable attachment metadata/hash/range,
    dedup ile kullanıcı sırası; native muhafazakâr token/byte/output-overhead
    bütçesi ve explicit truncation. İçerik data rolünde, delimiter escape'li;
    completion veya path bilgisi tek başına gönderim izni olmasın.
  - [ ] **4.10 Tüketici ve temizlik:** prompt/attach, tool/LSP/Dape, edit-baseline
    ve verification aynı DTO/RPC'yi kullansın. Son consumer'dan sonra eski Elisp
    context/domain formatter/parser/budget motorlarını sil; canlı kaynak/hook/
    buffer adapter'ları kalsın. İki workspace, stale revision/frame, Unicode/CRLF,
    missing adapter, injection, cancel corpus'unu son toplu kabul için hazırla.

- [ ] **5. Genel Rust run/session/history motoru** — native servis lease'i ile
  gerçek agent run'ını ayır; tek claim/writer altında loop FSM, tool-call/result
  protokolü, mode/plan dispatch, history repair ve terminal raporu bağla. Stop/reset/
  EOF'ta revoke → gerçek drain → repair → admit sırasını kanıtla. Headless/fake
  provider ve gerçek pipe UI uçtan uca geçince Elisp loop/history/domain state
  motorlarını tüketici tüketici sil; aynı yan etkiyi iki backend'de oynatma.
  Kaynak: Aşama 4, G08/G12/G13; .codex/00, 07, 11.

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
  - [ ] **5.3 Native registry/gate:** mevcut canonical/alias/schema/mode ve
    optional availability envanterini taşı; OS ve delegated editor tool'ları aynı
    owner/revision/onay kapısına girsin. Doğrudan çağrı da aynı gate'i kullansın.
    Native 51-tool schema/alias/mode asset'i ve typed schema/catalog eklendi.
    Production katalog application/create'te kurulur; connection-level registry
    kaldırıldı. Erken claim ve aktif run aynı immutable katalogu taşır; mevcut
    command/editor kapıları bu snapshot'ı kullanır. Generic delegated editor
    admission ortak pending approval ledger'ına bağlıdır; gerçek reverse adapter
    ve public Elisp registry/schema consumer cutover'ı henüz tamamlanmadı.
  - [ ] **5.4 Run admission/FSM:** servis lease'i gerçek agent run'dan ayrı;
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
  - [ ] **5.7 Mode/plan:** ask/plan/debug/agent availability, async debug hazırlığı,
    revision-bound plan artifact ve consuming dispatch native sahipliğine geçsin;
    Emacs plan/review ekranları yalnız presenter ve observation olsun.
  - [ ] **5.8 Abort/reset/EOF:** revoke → gerçek child/reverse/approval/edit drain
    → history repair → terminal event/release → yeni admission sırasını uygula.
    Çift iptal, owner close, reset ve stale generation tek terminal teslim etsin;
    sibling application/session etkilenmesin.
    Provider coordinator için revoke → actual preparation/API drain → finish/
    repair → release hattı transport'a bağlandı; rpc/cancel, abort, owner close,
    shutdown ve EOF kaynakları hazır. Reset ve gerçek OS/editor tool child'ları
    aynı hatta bağlanmadan ve son kabul çalışmadan bu alt iş kapanmaz.
  - [ ] **5.9 IPC ve UI consumer:** `session/prompt`, `session/abort`, snapshot ve
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
  - [ ] **5.10 Son legacy silme:** loop/machine/tools ve history/store/protocol/
    repair ile domain state/plan dispatch motorlarını son tüketici sonrası kaldır.
    Madde 6'daki compaction/healing consumer'larının native run'a bağlanması için
    gereken dar portları koru; iki writer veya gizli legacy run fallback'i bırakma.
  - [x] **5.11 Kabul kaynakları:** headless/fake provider ve gerçek loopback/pipe
    Emacs aynı contract corpus'u kullansın. Multi-turn/tool batch, mode/plan,
    partial stream, cancel/EOF/reset/repair, iki owner ve kaynak drain senaryoları
    ile application/approval/transport/history/run modellerini eşle.
  - [ ] **5.12 Son toplu kabul:** 3 ve 4'ün bütün alt işleriyle beraber uygulama
    bitince locked Rust+compile-fail, full source ERT, gerçek GUI kabulü, strict
    Clippy/fmt, değişen Elisp Werror/checkdoc ve etkilenen exhaustive TLC çalıştır.
    Eksik/başarısız kabul ve kalan legacy consumer varken 3/4/5'i kapatma.

  **2026-11-01 denetim kanıtı:** üst 3/4/5 ve ilgili kapanış kutuları yeniden
  açıldı. Native edit seçimi hâlâ opt-in; `edit/prepare/parent.rs` native
  `edit_by_lsp` için açık `Unavailable` döndürüyor. `loop.el`/`loop/ui.el`
  silinen dosyalardaki Elisp FSM/tool orchestration'ını hâlâ yürütüyor;
  dosya taşıma engine kaldırma değildir. Native UI adapter'ında default
  scope/revision ve genel bağlantı/terminal eksikleri var. Native sensor domain
  kaynakları tüm LSP/Dape/context tüketicilerinin geçtiğini kanıtlamıyor.
  Güncel native binary ile ilk ERT: 1341 test, 30 başarısız; son katalog/seçim
  düzeltmesinin odak kabulü: 75/75. Güncel tam source ERT 1379/1379;
  locked Rust 574 (31 compile-fail dahil), strict all-target Clippy ve değişen
  Elisp Werror/parantez kontrolleri temiz. Budget/application/selection TLC geçti.
  Bunlar eksik native tüketici bağlantıları ve gerçek GUI kabulünü kapatmaz.
  Ayrıntı ve açık teknik bulgular: `docs/migration-review-2026-11-01.md`.

- [ ] **6. Bütçe, compaction, healing ve verification birliği** — mevcut native
  budget/metadata tiplerini kullanarak normal/retry/continue/compaction/healing
  çağrılarını aynı run handle'ına bağla. Exact fiyatla hard monetary reservation
  ve unknown usage/pricing davranışını tamamla; float veya tahmini gerçek harcama
  diye sunma. Tek compaction sınırı, ikinci overflow, başarısız özet, stale verify
  ve geç usage fixture'ları geçince eski Elisp orchestration'ını sil. Kaynak: G08,
  Aşama 4; .codex/10–11, 36, 41–43.

  - [ ] **6.1 Tek run muhasebesi:** normal/retry/continue/compaction/healing
    çağrılarının aynı captured RunId, deadline ve native admission kaydını
    kullandığını gerçek consumer'larda doğrula; ikinci debit/writer'ı kaldır.
  - [ ] **6.2 Kesin parasal rezervasyon:** input/output/cache fiyatları ve token
    tavanlarıyla checked fixed-point rezervasyon, settlement/refund ve concurrency
    sınırlarını doğrula; bilinmeyen fiyat/usage açık kategori olsun.
  - [x] **6.2a Gözlenen parasal tavanın denetimi:** token tavanı parasal
    unknown kontrolünü maskelemez; eksik usage ve kesirli micro-USD kesin sıfır
    sayılmaz. Bağımsız worktree'de 22 bütçe testi geçti; `f99b674`.
    Bu, 6.2'deki hard reservation veya gerçek provider settlement bağlantısı değildir.
  - [ ] **6.3 Compaction:** native history revision'ına bağlı tek özetleme,
    başarısız/iptal/stale özetin eski geçmişi koruması, ikinci overflow ve
    multimodal/tool-call bütünlüğü; gerçek loop consumer'ını bağla.
  - [ ] **6.4 Healing ve verification:** native changed-file receipt görünümünden
    fresh diagnostic baseline/sonuç üret; unavailable/stale kanıt temiz başarı
    sayılmasın. Sınırlı healing aynı parent run altında yürüsün.
  - [ ] **6.5 Sonuç ve cleanup:** geç/çift usage, cancel/timeout/EOF ve unknown
    effect settlement'ını doğrula; eski Elisp compaction/healing/accounting
    karar motorlarını son tüketicilerden sonra kaldır.
  - [ ] **6.6 Kabul:** exact-price/unknown-price/usage, paralel reservation,
    overflow/özet hatası, stale verify ve cancelled healing regresyonlarını
    çalıştır; etkilenen budget/verification modellerini kontrol et.

- [ ] **7. Session persistence ve restart** — schema_version=2/legacy import,
  revision'lı journal/snapshot, restore/accounting/selection ve outcome_unknown
  recovery'yi native tek yazıcıya bağla. Kesilmiş yazı, eski epoch, yarım tool/edit
  ve restart'ta replay etmeme kabulü geçince eski Elisp persistence motorunu sil.
  Gerçek kullanıcı session dosyasını test girdisi yapma; power-loss garantisini
  seçilen journal'ın kanıtını aşacak şekilde genişletme. Kaynak: Aşama 4, G10;
  .codex/08.

  - [ ] **7.1 Şema ve import:** schema_version=2 ve legacy DTO'larını bounded
    typed native sınıra bağla; unsupported version, malformed/oversize ve
    identity/path traversal girdilerini mutation öncesinde reddet.
  - [ ] **7.2 Tek yazıcı ve journal:** session/root kapsamı, writer lock,
    monotonic revision/sequence, hash ve snapshot/journal commit sırasını doğrula;
    actor uzun disk IO beklerken bloke olmasın.
  - [ ] **7.3 Kesilmiş yazı ve corruption:** yalnız incomplete son kaydı güvenle
    kurtar; tam kayıt checksum/sequence ve orta kayıt bozulmasını hata say.
    Snapshot başarısızlığında önceki committed görünümü koru.
  - [x] **7.3a Storage kaynak düzeltmesi ve odak kabulü:** tekrarlanan save
    journal sequence'i sıfırlamaz; tamamlanmış bozuk son kayıt silinmez; recovery
    aktif writer'ın flock'ını atlayamaz. Public storage ID traversal kontrolü,
    bounded/no-follow okuma, atomic exclusive snapshot ve tam journal checkpoint
    eklendi. Dört kırmızı regresyondan sonra toplam 18 session testi geçti.
    Host RPC'nin async/scope/revision bağları ve tam 7.3 kapanışı hâlâ açıktır.
  - [ ] **7.4 Restart recovery:** yarım model/tool/edit için outcome_unknown
    repair, idempotence ve sıfır otomatik replay; eski epoch callback'leri yeni
    session/history/selection/accounting durumuna yazamasın.
  - [ ] **7.5 Gerçek consumer geçişi:** save/list/load/delete/import/restore
    işlemlerini native application/session portuna bağla; selection/accounting
    restore ve async owner/cancel/deadline sınırlarını koru.
  - [ ] **7.6 Legacy temizliği ve kabul:** eski Elisp persistence writer/parser/
    worker'ını son consumer sonrası kaldır; yalnız geçici fixture'larla disk
    hata, lock, restart, migration ve iki owner kabulünü çalıştır.

- [ ] **8. İnce UI ve son application/global köprüleri** — chat/session routing,
  draft, provider/model/effort seçimi, stream/backpressure, plan ve confirmation
  UI'larını explicit native handle/DTO tüketicisi yap. Aktif run'ın backend/
  connection snapshot'ı sabit kalsın. Son consumer geçince compatibility circuit/
  catalog/job/edit/async tablolarını kaldır; passive UI yeni domain authority
  yaratmasın. Kaynak: Aşama 3/6, G09/G13; docs/connection-ownership.md.

  - [ ] **8.1 Chat/session routing:** explicit native application/session/run
    handle'larını draft, transcript ve terminal delivery'ye bağla; buffer
    değişimi/close/unload yabancı session'ı etkilemesin.
  - [ ] **8.2 Config/selection:** provider/model/effort UI yalnız committed native
    DTO ve async intent tüketsin; aktif run'ın endpoint/auth/policy snapshot'ı
    seçim değişiminde veya retry'da değişmesin; fake default kimlik kullanma.
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
    - [x] **8.2b1 Native config'ten HTTP capture temeli:** Rust yayımlanmış
      config'ten endpoint/credential/wire seçer; public endpoint credential
      istemez, custom override private policy kullanır, Anthropic x-api-key ve
      version header'ını korur. Yeni refresh çalışma ağacında exact epoch/
      application/session/config revision'a bağlıdır; değişen config, session
      close ve exact RPC cancel sonucu publish edemez. Bridge secret/URL çıkarmaz;
      native HTTP portunu kullanır. Genel picker/auth-source/registry cutover'ı
      ve ortak host entegrasyon commit'i bu temelin kapsamı dışındadır.
  - [ ] **8.3 Stream/backpressure:** epoch/scope/revision/sequence kontrolü,
    bounded chunk sunumu, gap reconciliation ve tek terminal; geç/çift/foreign
    event ile kill-buffer/Stop yarışlarını gerçek pipe'ta doğrula.
  - [ ] **8.4 Plan ve confirmation:** UI yalnız native plan/onay kimliğini
    göstersin; accept/reject/cancel aynı kapıya gitsin, string/metadata başarı
    yetkisi vermesin ve pending sunumlar kapanışta temizlensin.
  - [ ] **8.5 Global köprü temizliği:** circuit/catalog/job/edit/async tabloları
    ve history/domain state'in kalan reader/writer envanterini çıkar; son
    consumer geçmeden silme, ikinci authority veya legacy fallback bırakma.
  - [ ] **8.6 Kabul ve kapsam kanıtı:** iki application/session, origin close,
    stale selection, cancellation, missing capability ve gerçek GUI akışını
    doğrula; passive UI getter'ları gizli RPC/IO başlatmasın.

- [ ] **9. Dört kurulu uygulama backend'i ve ayrı MCP portu** — API desteğini
  koruyarak Codex, Antigravity, Claude Code ve OpenCode'u aynı GUI provider alanına
  bağla. Her birinde bounded kurulum/sürüm/protokol/auth discovery, readiness nedeni,
  gerçek turn/stream/terminal/Stop/session ve destekleniyorsa resume/usage/model/
  effort capability'sini ayrı doğrula. Önce offline fixture; resmi entegrasyon yolu
  doğrulanmadan CLI bayrağı/port uydurma. MCP-only Antigravity backend teslimi
  sayılmaz; biri engelliyse kendi kabul kutusu açık kalır. Canlı hesap/model turu,
  login, kurulum ve credential taşıma ayrıca onay ister. Kaynak: Aşama 5, G12;
  .codex/03'ün dört ayrı backend kabulü ve MCP topolojisi.

- [ ] **10. Son kabul, varsayılan cutover ve paketleme** — G03/G11 log gizliliği,
  retention/egress ve .codex/01/39 uyum açıklarını gerçek consumer'larda kapat.
  Missing-module, version mismatch, clean-machine startup, release binary/asset
  paketi ve export/geri dönüş sınırını doğrula. Tüm ERT, locked native test,
  compile-fail, fmt, strict Clippy, uyarısız değişen Elisp ve etkilenen exhaustive
  modeller geçsin. Uçtan uca eşdeğerlikten sonra Rust agent default olsun; yalnız
  o zaman son legacy backend/engine kaynaklarını sil. Thin editor adapter'ları
  kalır; merge/push ayrıca onay ister. Kaynak: Aşama 6, G03/G11/G13.

  - [ ] Setup raporunun kapsamını native readiness'den açıkça ayır: şu an
    `kargu ready` config/credential/dependency kontrolüdür, binary/protokol veya
    uzak model sağlığı testi değildir. Release kabulünde missing/incompatible
    configured binary ile bu ayrımı ve gerçek startup'ın fail-closed hatasını
    birlikte doğrula; passive reader'a gizli core/model isteği ekleme.
