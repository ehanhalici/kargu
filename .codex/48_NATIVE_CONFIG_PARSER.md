# Native TOML/schema/legacy-import tüketici geçişi — 2026-10-26

## Tamamlanan dar sınır

Gerçek `config-refresh-async` tüketicisi `configuration/parse` RPC'sine bağlandı;
221 satırlık Elisp `config/toml.el` ve production require'ları silindi. Sadece
parser eklenip eski yol bırakılmadı. Review-mode değişimi hâlâ UI adapter'ında,
yalnız başarılı publication sonrası uygulanır; parser side effect üretmez.

`configuration/{mod,domain,document}.rs` bounded source, alan tipleri, kapalı
schema/review enum, legacy import, content digest ve sanitized line diagnostic
sahibidir. TOML lexer/parser yeniden yazılmadı: resmi
[toml serde parser](https://docs.rs/toml/latest/toml/) kullanılır. Cargo.lock
`toml 1.1.8+spec-1.1.0` ve yalnız gereken parse/serde/std feature'larını sabitler.
Span bilgisi için [Spanned](https://docs.rs/toml/latest/toml/struct.Spanned.html)
ve [error span](https://docs.rs/toml/latest/toml/de/struct.Error.html) kullanıldı;
dependency error Display/Debug'si hiçbir sonuç/log sınırına taşınmaz.

Eski tailored parser'ın önemli bir uyumluluğu bulundu: `provider='x'` ile
`[provider.x]` birlikte kabul ediliyordu; standart TOML scalar/table çakışması
sayar. Native import yalnız satır başı legacy header spelling'ini `[providers.`
yapar; değerleri ve satır sınırlarını değiştirmez. Sonra gerçek TOML parser ve
schema çalışır. Duplicate alias/table yine reddedilir. Digest orijinal source'tan,
hata satırı normalize edilmiş ama aynı satırları taşıyan source'tan hesaplanır.

Top-level provider/model/name/api/apikey/review_mode, provider api/apikey/model/
models, boş key, legacy default-provider/model fallback, ilk provider sırası,
digit-first/quoted ID, multiline array/comment/Unicode/string quoting korunur.
Multiline string, inline provider table, bilinmeyen schema/yanlış tip/duplicate
ve malformed refresh başarı sayılmaz. Şema artık TOML crate'inin standard key
spelling kurallarını kullanır; bu tam bir eski regex grammar klonu değildir.

## 01 ve lifecycle sınırları

Source/ConfigText özel alanlı Zeroizing sarmalayıcılardır; genel Serialize,
Debug/Display yoktur. Source ve text serde/TryFrom sınırında kabul edilir.
RefreshGeneration, SourceLine ve provider adı farklı tiplerdir. Source 64 KiB
UTF-8, provider tabloları 512, provider models 4096, projection 512 KiB sınırında.
İki compile-fail fixture source'a generic serialization/Debug eklenmesini engeller.
Sadece gerekli private editor config/credential handoff'u plaintext DTO üretir;
bu credential-free public metadata projection değildir. IPC/JSON/GC kopyaları
için fiziksel erasure veya tüm kullanıcı config'ini taşımış olma iddiası yoktur.

Global host sadece ready/id'li/doğru epoch'lu bounded pure parse kabul eder;
IO veya credential beklemez, application/session/config/model actor yaratmaz.
Editor refresh generation echo'su native config revision/grant değildir.
Salt projection için yapay FSM ve ikinci state writer eklenmedi. Parser tüketimi
source intent'ini tüketir; hatalar kapalı thiserror enum'u ve safe line ile taşınır.
Yeni float, unsafe, unchecked indexing, unwrap/expect/panic yoktur.

Mevcut file worker artık yalnız bounded text yakalar, TOML parse etmez. Config
worker stdout sınırı JSON escape genişlemesine göre ayrıdır; credential worker'ın
64 KiB varsayılanı büyütülmez. Root deadline file child + startup + parser'ı
kapsar, her aşamada resetlenmez. Missing file core başlatmadan nil publication
olur. Missing capability, malformed/foreign-generation reply ve lost/replaced
known lease publication öncesi reddedilir; fallback yoktur.

`bridge/config.el` ilk yield öncesi source'u ayırır, task cleanup'ta private
kopyayı siler; service file-result kopyasını handoff'tan sonra temizler. Startup
waiter detach ve forward cancellation yalnız kendi intent'ini bırakır. Parent
önceden kapalıysa file worker veya core startup başlatılmaz. Geç yanıtın başka
application'a yazamaması ve eski generation'ın yeni publication'ı ezememesi
gerçek pipe'ta testlidir. Ortak readonly lease kontrolü bridge/application'a
taşındı; katalog portu aynı kontrolü kullanmayı sürdürür.

Setup artık mevcut dosya için readonly native parsing yapabilir; bu model/API/
metadata discovery veya native application yaratma izni değildir. Gerçek setup
fixture'ı zorunlu cold bridge startup altında bir parse, sıfır model/metadata/HTTP
ve sıfır editor application lease ile rapor/key cleanup'ını denetler. Shared
bridge'in mevcut standalone read-service application/session bootstrap'ı ayrıdır;
soğuk test bunu bir kez sayar, parser bunu kendisi yaratmaz. `ready` upstream sağlık veya tam native run readiness
sertifikası değildir; todo 10'daki ayrı kabul maddesi açık kalır.

## Kalan consumer işleri

Bu adım native config publication/actor, file candidate/precedence/read,
environment/keyless/credential precedence veya provider/model selection
cutover'ını kapatmaz. File worker ve trusted editor snapshot/service bu dar
geçişte korunur. Sonraki native IO adımı bounded regular-file read, path authority,
last-open/TOCTOU, cancel/deadline ve tek publication writer'ı sağlamalıdır;
editor worker'ı ancak gerçek tüketici o porta geçince kaldırılmalıdır.

Kullanıcının 01/07/shell.nix değişiklikleri korunur. Dependency build dışında
uygulama/CLI kurulumu, gerçek user config/credential taşıma, uzak API/hesap turu,
login, merge/push veya canlı Emacs/core reload yapılmadı.

## Kanıt

Beş native test strict schema/redaction, model/table/import order ve legacy scalar
provider uyumu, bounded input/digest/exact generation ve host epoch/ready/id
kapısını kapsar. Yedi ERT file -> real parser -> private editor publication,
late cancellation/deadline/supersession/lease close, iki application,
bozuk reply, old-core capability, source mutation during startup, missing file,
closed parent ve deleted parser sınırlarını denetler. Eski doğrudan parser
testleri gerçek refresh tüketicisine taşındı; assert'lar atılarak kapı gevşetilmedi.

Final kaynak: **1256/1256 full source ERT**, 0 unexpected, **140.65 s**,
**08:21:18 Europe/Istanbul** geçti. Önceki warm-start taraması da 1256 geçti;
son sürüm ayrıca cold-start setup'ı zorunlu kılar ve mutlak deadline gecikmesini
kapsar. Kesilen ara tarama başarı sayılmadı. **274 native + 18 compile-fail**,
locked build, fmt ve strict all-targets Clippy temiz. Sekiz üretim Elisp ve dört
test dosyası Werror bytecompile/checkdoc temiz; bytecode task-specific /tmp'de,
kaynakta elc yoktur. OpenPGP autoload ortam mesajı derleyici uyarısı değildir.

Mevcut bounded connection TLC **602836 generated / 101708 distinct**, queue 0,
depth 22, 01:27:37; transport **1810 / 693**, queue 0, depth 13, 01:27:38'de temiz.
Bunlar regression'dır; yeni concrete parse DTO/publication refinement'ı veya tüm
01 uyumluluk ispatı değildir.
