# Todo 1: native publication ve çözümleme geçişi — 2026-10-26

Kullanıcı todo 1'in bütünüyle bitirilmesini istedi. İlk doğrulanmış dilim native
domain/actor/RPC temelidir; gerçek Elisp consumer cutover ve eski policy/helper
silme işleri kapanmadan üst grup işaretlenmez.

## Gerçek consumer cutover

Native temel `ff96691` sonrasında gerçek refresh, connection, setup, katalog ve
provider picker native authority'ye bağlandı. `bridge/config-policy.el` yalnız
owned prepare/commit/abort ve exact-revision resolve/select DTO portudur.
`config/service.el` native revision'ı gözlemler; kendisi artırmaz. Pending refresh
generation hâlâ UI sıralama niyetidir, publication yetkisi değildir. Parser/file IO
önceki native read pool'da kalır; yeni process veya ikinci parser eklenmedi.

`config/key.el` artık memory-only native projection reader'ıdır. Eski
`config-publish`, `config-bump-revision`, `--provider-plist`,
`--provider-toml-plist`, `--resolve-direct-api-key`, `--expand-env-refs`,
`--provider-env-api-key`, `--url-host` ve `provider-valid-key-p` silindi.
Registry auth/keyless/local/connected okuyucuları native DTO flag/list tüketir;
env, endpoint veya credential precedence çalıştırmaz. Setup'ın placeholder
etiketi yalnız UI sunumudur; kimlik kaynağı/uygunluk yetkisi değildir.

`kargu-set-provider` artık cancellable async task döndürür; üçüncü opsiyonel
callback native selection ACK'inden sonra Result alır. Configured model,
no-model ve batch cached-model kararı Rust'tadır. UI provider/model adımı bu ACK'i
bekler; sonradan gelen eski seçim farklı session/buffer/selection'a yazamaz.
Cold standalone catalog/selection native defaults publication yapabilir, dosya
probe etmez: bu projection gerçek dosya yokluğu kanıtı değildir. Normal send,
setup ve provider picker explicit file refresh yapar.

Editor options/registry ve en çok 16384 entry / 2 MiB environment, publication
ve connection portunun ilk yield'inden önce private capability'de dondurulur.
Yalnız Rust'ın istediği isimlerin değerleri IPC'ye gönderilir; unrelated env
değerleri local kalır. Capture'lar completion/cancel'da temizlenir; normal
record/closure yazdırımı için private storage symbol-cell arkasındadır.
Native environment ayrıca 2048 isim / 256 KiB ile sınırlıdır. `${...}` lexer'ı
256 byte'a kadar isim tarar; nested/unterminated reference'larda quadratic
`split_once('}')` araması yoktur. Unicode ve digit-first catalog env ayrımı korunur.

Native `Profile` tipli karar sonucudur; domain içinde JSON alanı okuyup eligibility
veya URL kararı tekrar türetilmez. Consuming `TryFrom<Profile> -> ReadyProfile`
tek parse edilmiş endpoint witness'ını ve model kimliğini gerektirir. Invalid
config UI preview'da kalabilir ama credential interop/connection hazırlığına
geçemez. `PolicyTarget`/document Debug veya Serialize değildir; dört ek
compile-fail testi bu yüzeyleri kapatır.

Source fingerprint path/digest/document/global options/requested env/registry
değerlerini count/length framing ile hash'ler. Registry sırası ve başka session'ın
UI seçimi revision artırmaz; credential/source değişikliği artırır. Boundary
framing testi models/env koleksiyonları arasındaki adversarial eşit diziyi ayırır.
Per-request context native head'i değiştirmez; immutable connection snapshot ve
retry hedefi korunur. Katalog native config resolve'dan API-base alır ve external
credential lookup'tan önce expected endpoint'i denetler.

Cancel sonrası geç prepare acquisition'ı abort edilir. Commit gönderildiyse
lost ACK rollback değildir: UI eski receipt'i tutabilir ama native exact-revision
resolve bunu reddeder; explicit yeni refresh gözlemi uzlaştırır. Kör commit retry
yoktur. Same-connection session replacement da exact scope guard ile reddedilir.
Native staging deadline/sweep ve küçük frame testleri kısmi head/revision/generation
yazımı olmadığını doğrular. Auth-source/callable yalnız owned Emacs interop'tur;
external yield sonrası native head yeniden kontrol edilir. Foreign application
callback guard'ları origin application altında çalışır; global legacy UI metadata
tablosuna ait compatibility seçimi yanlışlıkla değiştirilmez.

Test fixture'ları ikinci bir Elisp policy engine kullanmaz; sentetik config
yayınları gerçek native actor'den geçer. Her fixture provider environment'ını
temizler ve gerçek auth-source dosyalarını kapatır. Async teslim/scope/revision
sözleşmeleri await edilir; port/resource double'ları native kararı taklit etmez.

## Native temel

`configuration/policy/{domain,environment,resolve,service}.rs` closed normalized
config, bounded registry ve environment capture, literal/single-pass env reference
expansion, endpoint/provider/model ve direct/keyless/interop source precedence
kararlarının sahibidir. Editor globals/env değerleri snapshot input'tur; Rust
process'inin startup environment'ı sonradan değişen editor environment yerine
kullanılmaz. Tüm env değerlerini göndermek yerine native istenen isimleri verir.
Catalog env names digit-first olabilir (`302AI_API_KEY`); `${NAME}` grammar'ı
ayrı olarak alpha/underscore ile başlar. Unicode reference isimleri desteklenir.

Native `ApplicationActor.configuration` tek config publication writer'ıdır.
`configuration/prepare` owner/session-bound expiring opaque ticket ayırır ve env
isimlerini verir. `configuration/commit` yalnız geçerli ticket ile bütün görünümü
hazırlayıp frame/resource sınırından sonra atomik yazar; aynı source fingerprint
revision'ı artırmaz. Yeni generation eski ticket'ı supersede eder; generation echo'su tek
başına yetki değildir. `abort`, `snapshot`, exact-revision `resolve` RPC'leri vardır.
Staging TTL transport tick'inde de tahliye edilir; owner revoke/drop private
config/credential storage'ı bırakır. Worker state yazmaz; actor I/O beklemez.
Core capability `configuration_policy`'dir. Eski config read/parser portları
geriye uyumlu kalır; son Elisp consumer geçince legacy engine silinir.

Reader ve publication boundary aynı `ConfigurationPath` tipini kullanır.
Katalog provider/env/local/keyless verisi native immutable catalog'dan gelir;
runtime registry capture açık input'tur. Seçilen endpoint typed HTTP(S) olmadan
resolve edilemez; raw query/path spelling korunur. Malformed source/options,
foreign session, eski revision ve eski/aborted/consumed ticket fail-closed'dur.
Bu transfer UI'ın trusted editor normalized DTO'sunu taşır; raw TOML parser'ı
ve file capture core'dadır. Native publication projection'ı credential içeren
private handoff'tur; diagnostic veya public Serialize/Debug yüzeyi değildir.

## İlk native temel commit'inin doğrulama kapsamı

Beş yeni native integration test gerçek Host ve native parser üzerinden selection/
global key/file key/env/keyless/interop sırasını, single-pass expansion ve missing
isimleri, query korumayı, invalid endpoint'i, staged publication/revision reuse ve
foreign session/abort/revoke sınırlarını kapsar. **285 native + 20 compile-fail =
305** locked test geçti (`/tmp/kargu-policy-native-verified.log`); fmt ve strict
Clippy temiz (`/tmp/kargu-policy-core-clippy-final.log`). Bu native temel tek
başına gerçek UI consumer'ının taşındığı ya da todo 1'in bittiği iddiası değildir.

Consumer cutover bu belgenin üstündeki bölümde tamamlandı; final doğrulama
kayıtları aşağıdadır. Bu dilim genel G03 log-egress veya G05 credential-process
PGID/drain denetiminin tamamlandığı iddiası değildir. Fiziksel IPC/JSON/GC erasure,
concrete TLA refinement veya bütün 01 kurallarının formal ispatı verilmez.
Kullanıcının 07/shell.nix değişiklikleri stage edilmez. Canlı Emacs reload,
credential migration, ücretli/upstream tur, kurulum ve merge/push yoktur.

## Final consumer doğrulaması ve kapanış

**1268/1268 full source ERT**, 0 unexpected, **147.335395 s**, **19:54:29
Europe/Istanbul** (`/tmp/kargu-policy-verified-source-ert.log`); altı authority
testi ayrıca temiz (`/tmp/kargu-policy-authority-verified.log`). **291 native +
24 compile-fail = 315** locked test / 31 suite
(`/tmp/kargu-policy-cutover-native-all.log`), locked normal build, fmt ve strict
Clippy temiz. Değişen **26 Elisp** dosyası Werror bytecompile/checkdoc temiz;
elc yalnız task-specific /tmp dizinlerinde. Connection TLC **602836 / 101708**,
queue 0, depth 22 (**12:50:48**); transport **1810 / 693**, queue 0, depth 13
(**12:50:49**) temiz. Todo 1 gerçek tüketici/silme/doğrulama koşullarıyla `[x]`.
Sonraki migration grupları açık; kullanıcı 07/shell.nix değişiklikleri dahil edilmez.
