# Todo 1: native publication ve çözümleme geçişi — 2026-10-26

Kullanıcı todo 1'in bütünüyle bitirilmesini istedi. İlk doğrulanmış dilim native
domain/actor/RPC temelidir; gerçek Elisp consumer cutover ve eski policy/helper
silme işleri kapanmadan üst grup işaretlenmez.

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
hazırlayıp frame/resource sınırından sonra atomik yazar; aynı projection revision'ı
artırmaz. Yeni generation eski ticket'ı supersede eder; generation echo'su tek
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

## Bu commit'in doğrulama kapsamı

Beş yeni native integration test gerçek Host ve native parser üzerinden selection/
global key/file key/env/keyless/interop sırasını, single-pass expansion ve missing
isimleri, query korumayı, invalid endpoint'i, staged publication/revision reuse ve
foreign session/abort/revoke sınırlarını kapsar. **285 native + 20 compile-fail =
305** locked test geçti (`/tmp/kargu-policy-native-verified.log`); fmt ve strict
Clippy temiz (`/tmp/kargu-policy-core-clippy-final.log`). Bu native temel tek
başına gerçek UI consumer'ının taşındığı ya da todo 1'in bittiği iddiası değildir.

Devam eden tüketici dilimi: owned config publication bridge, UI-only revision
observation, revision-bound connection resolution; eski Elisp precedence,
env expansion, keyless/eligibility, local publication ve fallback selection
motorlarının son tüketicileriyle silinmesi. API root/cancel/deadline/session/
selection/metadata receipt ve cold/custom/local/two-owner regresyonları korunmalı.
Kullanıcının 07/shell.nix değişiklikleri stage edilmez. Canlı Emacs reload,
credential migration, ücretli/upstream tur, kurulum ve merge/push yoktur.
