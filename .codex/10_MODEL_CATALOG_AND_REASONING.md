# 10. MODEL KATALOĞU, REASONING VE PARAMETRE POLİTİKASI

Mevcut providers/catalog, providers/registry, models/service/store,
api/catalog/parameters/cache ve chat/tune davranışları tek metadata servisine
taşınır. Emacs seçim/effort UI'sını sunar; kanonik değer Rust'tadır.

## 1. Katalog ve keşif

Embedded manifest offline başlangıç verisidir; include_str JSON parse maliyetini
ortadan kaldırmaz. Manifest schema/version/source_date taşır ve build/test'te
doğrulanır. Yerel custom kayıtlar ve remote discovery ayrı katmanlardır.
Merge önceliği: embedded < doğrulanmış remote metadata < explicit kullanıcı
override. Remote yanıt explicit ayarı sessizce değiştiremez.

Model anahtarı yalnız model_id değildir; provider/endpoint namespace + model_id
kullanılır. Custom provider string kimliği desteklenir; kapalı provider enum'ı
mevcut sağlayıcı genişletmesini engellemez. Wire family ayrı typed özelliktir.
Cache/discovery/breaker servisi application tarafından sahiplenilir; geç callback
başka application'ın deposuna yazamaz. Run metadata generation snapshot'ı alır.

Manifest context/output limit, tool/vision capability, tokenizer/estimate policy,
wire family, pricing kaynağı ve tarihi, reasoning/sampling kuralları taşır.
Remote models/list bu bilgilerin hepsini vermeyebilir; bilinmeyen değerler
tahmin edilip kesinmiş gibi sunulmaz. Özel models.toml schema'sı named
`models` tablosu/array-of-tables içerir; bare root Vec<T> varsayılmaz.
Dosya parse/size/timeout ve unknown-field hataları typed'dır.

## 2. Reasoning modeli

UI seviyesi ile wire parametresi ayrıdır. Tercih `ProviderDefault`,
`Disabled`, `Effort(model-supported value)` veya `Budget(TokenCount)` olur.
Absent/default ile explicit off aynı şey değildir. Low/medium/high gibi
etiketler ancak model capability izin verirse seçilebilir; max sessizce high'a
düşürülmez, custom budget medium'a çevrilmez.

Her model kaydı accepted efforts, default/disable desteği, min/max budget,
output reserve ilişkisi ve temperature/top_p çatışma kurallarını bildirir.
Payload oluşturma typed validated DTO üzerinde `Result` döner; rastgele
serde_json Value indekslemesiyle panic veya yanlış şekil üretilmez.

Wire örneği düzeyinde OpenAI Responses `reasoning.effort`, Chat Completions
`reasoning_effort` kullanır; destek model bazında doğrulanır. Tek provider
enum match'i bütün modellerin sözleşmesi değildir.
Kaynak: [OpenAI reasoning dokümantasyonu](https://developers.openai.com/api/docs/guides/reasoning)
(2026-10-24 kontrolü). Kabul edilen model değerleri uygulama sırasında resmi
doküman + sabit fixture ile doğrulanır.

Anthropic thinking budget/adaptive effort ve Gemini thinking budget/level
farkları adapter/model capability kaydında tutulur. Evrensel 1024/4096/32768
tablosu sabitlenmez. Seçilen model için desteklenmeyen ayar erken reddedilir.
Native tool desteklenmiyorsa UI ve registry bunu gösterir; API 400 beklenmez.

Reasoning içerik/signature/opaque blokları provider'ın continuation sözleşmesine
göre korunur; iç düşünce metni varmış gibi uydurulmaz. UI yalnız sağlayıcının
sunulabilir olarak verdiği içeriği gösterir. Harici backend reasoning seçenekleri
kendi capability/şemasından gelir; REST payload'ı CLI'ya uygulanmaz.

## 3. Pricing ve accounting

Fiyat decimal/rational, hesap MicroUsd + kesir artığıyla yapılır (01).
Input/output, cache read/write ve reasoning birimlerinin billing anlamı açıkça
kaydedilir. Fiyat bilinmiyorsa `unknown`; sıfır ücret varsayılmaz.
Usage final/partial/estimated durumu ve attempt kimliği taşır.
Streaming usage tekrarları çift sayılmaz; iptal edilen istek ücretsiz değildir.

## 4. Kabul kapısı

Mevcut test-model-store, dynamic-models, metadata, providers, parameters,
selection, connection-snapshot/native ve run-budget davranışları korunur.
İki endpoint'te aynı model_id, stale discovery, user override, bozuk manifest,
off/default ayrımı, desteklenmeyen effort, sampling çatışması, kesirli fiyat ve
duplicate usage fixture'ları eklenir. Canlı API testi ayrı ve opt-in'dir;
offline fixture başarısı güncel sağlayıcı kabulü olarak sunulmaz.
