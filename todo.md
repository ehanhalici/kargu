# Açık işler — birlikte çözülecek gruplar

İnceleme tabanı: 32e917b, 2026-10-22. İnceleme ERT baseline'ı: 1116/1116,
2026-10-23. Rust göçünün güncel uygulama/test kaydı: .codex/12_MIGRATION_PROGRESS.md.
G02 bağlantı/metadata sözleşmesi ve kalan köprüler: docs/connection-ownership.md.
Yalnız açık işler tutulur; tamamlanan alt maddeler ve tekrarlanan iş tarifleri
çıkarılmıştır. Bir çekirdeğin testinin geçmesi, native tüketicilerin ona
bağlandığı anlamına gelmez. Eski ARCH/MOD/DEEP/RISK kimlikleri kaynak
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
3. Kapanan maddeyi sil. Kısmen kapanan grubun yalnız kalan kapsamını bırak.
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

Native `find_files` ve `list_files` portları gerçek Elisp tool gate'ine bağlandı;
eski glob engine'leri ve senkron directory scanner silindi. G11'in bu read
tüketicileri için bounded traversal, no-follow directory capture, owner/cancel
ve çıktı limitleri test edildi (.codex/15 ve 16). Bu kısmi kanıt G11/G13'ün
tamamını kapatmaz; kalan grep/read/Git/skill/webfetch, egress/context ve diğer
global tüketiciler aşağıdaki gruplarda açık kalır. Yeni paralel iş listesi yoktur.

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
**Dosyalar:** chat/, ui/, selection.el, api/{select,sse,stream}.el, plan/context.el
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
