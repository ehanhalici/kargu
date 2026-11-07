# 33. Native auth/header assembly ve credential-aware continuation

2026-10-25. Credential çözümleme editor portunda kalır; Rust capture'a raw key,
extra-header tanımları ve session/app-url binding değerleri gelir. Format'ın
bearer/x-api-key seçimi, default header'lar, provider overrides ve Content-Type
üretimi tek native `api/auth.rs` sınırındadır. Elisp request.el auth/header
motorları silindi. Client POST ve catalog GET bu yolu kullanır; retry aynı
captured auth intent/connection'ı taşır. `api_auth` capability yoksa yeni capture
ile request başlamaz. Raw :headers yalnız explicit transport callers içindir.

Header adı/değeri/binding DTO'da typed ayrıştırılır. Override default'a karşı
case-insensitive'dir. Fakat aynı katmandaki case-collision, raw+extra collision,
generated auth ile explicit aynı auth header'ı ambiguity olarak reddedilir.
CRLF, yasak Host/hop/framing header'ları, unknown/missing binding ve aggregate
count/byte sınırları HTTP öncesi fail-closed'dur. Public/keyless model GET boş
anahtarda Authorization üretmez. Explicit custom auth key yokken korunur.

SecretString ve Bearer ara buffer'ı zeroizing'dir; HeaderValue sensitive'dir.
Raw credential/header değerleri diagnostics veya result DTO'ya kopyalanmaz.
HTTP kütüphanesinin veya editör GC/JSON buffer'larının bütün kopyalarının
silindiği iddia edilmez. URL/body wire logging sınırları 30 ve G03'teki gibidir.

Yeni bulgu: yalnız endpoint/model/provider/format revision'ına bağlamak,
credential veya tenant header'ı değişince opaque signed continuation'ı yeniden
kullandırabiliyordu. Final captured header bağlamı artık length-framed SHA256
scope hesabına girer; secret JSON/log ara çıktısı oluşturulmaz. Sabit u64 length
framing mimariler arası deterministiktir. Native regression farklı key ve tenant
için reddi, aynı capture için imza korunmasını doğrular. Bu digest bir yetki
token'ı veya düşük entropili credential için password hash'i değildir; scope
metadata'sı kaydedildiğinde offline fingerprint niteliği taşır. Native
application/session isolation sonraki run/history portunun ayrı yükümlülüğüdür.

Native auth testleri bearer/x-api-key/keyless/custom auth, overrides/bindings,
unsafe/ambiguous inputs, generated-header aggregate caps ve credential/tenant
continuation izolasyonunu kapsar. Real Emacs→Rust→loopback testi POST ve model
GET header'larını, OpenRouter attribution, OpenCode session, Anthropic version,
custom override ve public/keyless davranışını denetler. Queued key/header
mutation capture'ı değiştiremez. Eski public/custom provider ERT testleri raw
intent projection'a uyarlandı; karşılık gelen native engine testleri korunur.

Bir doğrulama koşusu eski binary ile yeni DTO'nun eşzamanlı çalışması nedeniyle
Invalid params verdi. Build tamamlanmadan native ERT başlatılmamalıdır; rebuild
ardından odaklı testler geçer. Bu bir old-core silent fallback nedeni değildir.

Retry/breaker HTTP worker'a gizlice eklenmedi: her deneme ortak run budget ve
single-writer owner/deadline kapısından geçmelidir. Native budget/admission,
model metadata/store, core agent/history ve dört app backend hâlâ roadmap'tedir.
