# Native katalog hedefi / auth kararı — 2026-10-26

## Tamamlanan tüketici geçişi

Todo 1'in katalog endpoint/public-auth alt işi tamamlandı. Rust
`providers/catalog_target/{mod,domain}.rs` policy'nin tek sahibidir.
`provider/catalogTarget` + `provider_catalog_target` capability'si altında
default/dedicated/custom/native-models path ve public/provider-auth kararı üretir.
Elisp'teki `kargu-catalog-request--url`, `kargu-provider-native-models-path` ve
`kargu-provider-public-models-p` silindi. Registry verisi artık yalnız captured
DTO'dur; ikinci endpoint/auth engine veya legacy fallback yoktur.

CapturedApiBase, ModelsPath, CompatibleSuffix ve ConfigurationRevision özel
alanlı domain tipleridir; serde/TryFrom boundary'si, kapalı auth enum'u,
bounded kaynaklar ve consuming resolve(self) kullanılır. Yeni para/token float,
unsafe, unchecked indexing, unwrap/expect/panic veya bağımlılık eklenmedi.
Normal projection bir FSM'e dönüştürülmedi. URL/template metadata ile geçerli
runtime HTTP hedefi ayrıdır; default template explicit custom base'i bozmaz.
Query'nin sonundaki slash override karşılaştırmasında yutulmaz; yalnız path
sonundaki slash eşdeğer kabul edilir. URL query/userinfo hata mesajına eklenmez.

Global host yalnız ready, id'li ve doğru connection epoch'lu saf projection'ı
kabul eder. Actor/mailbox yeni IO beklemez; session/application/metadata veya
config publication oluşturulmaz. Dönen revision editor snapshot'ının echo'sudur,
native config authority veya approval token değildir. Katalog config parser/
precedence/env/keyless migration'ının tamamlandığı iddia edilmez.

## Editor lifecycle ve GET pinning

`bridge/catalog.el` bounded/cancellable readonly porttur. Girdi strings ve
container'ları startup yield'inden önce ayrılır; caller mutasyonu intent'i
değiştiremez. İlk startup paylaşılabilir; mevcut application lease'inin kayıp
epoch'u kendiliğinden yeniden açılmaz. Pure projection yeni native app yaratmaz;
aktif :starting/:ready lease'i paylaşabilir, kapanmış/değişmiş lease reddedilir.

Provider/base/revision/wire/header/application capture'ından sonra gerçek native
policy beklenir. Config/base/session/known native owner tekrar kontrol edilmeden
credential çözümü başlamaz. Header assembly ve gerçek HTTP Rust'ta kalır;
credential interop ortak connection resolver'ındadır. Public dedicated hedef
credentials atlar, custom override dedicated public iznini miras almaz; derived
URL byte olarak aynı olsa bile custom dal private kalır.

Yeni native policy yield'i ile GET arasında connection kaybı olabileceği için
transport'un dar :connection portu eklendi. Hedefi hesaplayan aynı connection
GET'i yürütür; global current connection'a geçiş veya stale app lease'ini başka
connection'a sessiz rebinding yoktur. Cancel/kill/mode/deadline yalnız kendi
waiter/forward request'ini bırakır; shared startup/core kapanmaz. Credential
scope/request key cleanup'ı önceki portta kalır. Eski core capability yoksa
key lookup/application startup/GET'ten önce açık hata verir; binary rebuild ve
core restart gerekir. Kullanıcının canlı Emacs'i otomatik reload edilmedi.

## Yeni bulgu ve kalan alt iş

Takip: aşağıdaki tarihsel upstream base-selector bulgusu sonraki dar tüketici
geçişinde kapatıldı; ham base ve native chat hedefi ayrıntıları .codex/47'de.
Genel native config/schema/precedence üst işi yine açıktır.

Eski string concat, query içeren base'e `/models` ekini query içinde ekliyordu.
Native URL path operation query'yi korur; gerçek loopback GET bunu denetler.
Bir başka sınır da görünür oldu: `config/key.el` içindeki eski base selector
`kargu--strip-trailing-slashes`, native porttan önce tüm URL sonundaki slash'ı
silebilir; query değeri de etkilenir. Bu upstream normalize hatası todo 1'e
açık alt iş olarak eklendi. Native input query'sinin korunması, o consumer'ın
geçişi veya tam URL/base policy cutover'ı tamamlanmış sayılmaz.

## Kanıt

Yedi yeni Rust testi dedicated/public/private, public URL'ye denk gelen custom
override, native/compatible/custom tamamlanmış model path, opaque query,
unresolved default template, exact u64 revision, malformed DTO/path ve gerçek
host ready/request/epoch kapısını denetler. Dokuz yeni ERT gerçek pipe'ta held
reply, DTO mutation during startup, config/base/native-owner/cancel/kill/mode/
deadline, registry/application değişimi, old-core capability, bozuk projection,
lost epoch sonrası sıfır reconnect, kapalı parent sonrası sıfır startup ve gerçek
query GET'ini kapsar.

Eski transport callback fixture'ları artık gerçek native target projection'ını
açıkça bekler. Bu yalnız test helper'ıdır; production synchronous yapılmadı,
Rust policy mock'lanmadı ve metadata actor testleri gerçek core kullanmaya devam
eder. Eski public helper assertion'ı native negatif auth + gerçek public/custom
consumer testlerine taşındı; module-boundary bütçesi genişletilmedi.

Final gate: **1245/1245 full source ERT**, 0 unexpected, **137.00 s**, 00:51:37
Europe/Istanbul. Önceki 1243/1244 taramaları da geçti; DTO capture/kapalı parent
fixture'ları eklendikten sonra son kaynak yeniden tamamen tarandı. **266 native +
16 compile-fail**, fmt, locked build, strict all-targets Clippy geçti. Dört üretim
Elisp, test helper ve yeni test Werror bytecompile/checkdoc temiz; kaynakta elc yok.
Mevcut connection/transport bounded
TLC tekrarları regression'dır: yeni target DTO ve epoch pinning'in somut
refinement ispatı veya tüm 01 uyumluluk sertifikası değildir. 01, shell.nix/07
kullanıcı değişiklikleri korunur; yeni dependency, harici model/hesap/CLI turu,
kurulum, credential taşıma, merge veya push yapılmadı.
