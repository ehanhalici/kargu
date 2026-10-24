# 32. Native request-policy cutover

2026-10-25. Native HTTP admission, captured raw UI tercihleri, exact model
parameter metadata'sı ve typed format/provider patches kullanır. `api/policy/`
tek output-cap alanını, sampling ve effort/nested/thinking wire konumunu seçer.
Default → format patch → explicit provider patch sırası Rust'tadır. Missing ile
explicit null farklıdır; null sampling default'u geri açmaz. Sağlayıcı/model
adına göre regex veya model ailesi tahmini yoktur.

Elisp `api/parameters.el`, request.el reasoning/parameter seçim motorları ve
registry request-default merge kaldırıldı. Editor raw intent'i snapshot'a alır;
transport encoder nested strings/containers'ı startup'tan önce ayırır. Retry
aynı connection snapshot'ını korur. `api_request_policy` capability yoksa yeni
editor tuning isteği gönderilmez. Standalone POST'ta tuning verilmemesi explicit
extras validation'ını bypass etmez.

`Temperature` finite [0,2], output/thinking caps positive integer; geçersiz
değerler HTTP öncesi reddedilir, sıfır budget silently ignore edilmez. Exact
model metadata bir cap desteklemiyorsa explicit limit düşürülmez; iki cap alanı
birlikte olamaz. Explicit extras aynı tip ve supported-sampling kapısından
geçer. Messages codec max_completion_tokens alanını sessizce atamaz: çelişen
custom wire/policy fail-closed'dur. Bu genel cap/sampling sınırı, her modelin
daha dar temperature/budget/effort kabulünü doğruladığımız anlamına gelmez.

`none` gerçek effort adıdır; `off` effort göndermez; absent/provider default
ayrıdır. Legacy independent thinking-budget tercihi varsa nested/thinking
formatlarında korunur; bu kesim yeni bir model capability veya universal budget
min/max/default uydurmaz. Model-specific accepted effort/budget ilişkileri 10'daki
metadata/run kapsamıyla birlikte hâlâ açık ve tamamlandı sayılmaz.

Saf policy ERT sözleşmeleri `tests/api_policy.rs`'ye taşındı: cap aliases,
unknown/empty metadata, explicit nil patch, no supported cap, invalid settings,
conditional temperature, reasoning shapes ve extras collision. Elisp tests/
test-parameters.el exact provider/alias isolation ve frozen raw capture'ı korur.
test-stream gerçek high-level chat POST→Rust→loopback yolunda OpenAI,
OpenRouter, Anthropic ve synthetic conditional policy'yi; UI mutation isolation
ve invalid policy'nin socket açmamasını test eder.

OpenAI Docs becerisiyle resmî Chat Completions şeması kontrol edildi:
https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create
temperature [0,2], max_completion_tokens/max_tokens ayrımı ve model-specific
reasoning desteği dikkate alındı. Model yükseltmesi/real account çağrısı yoktur.

Model metadata normalization/store, credential/header assembly, native run
budget, retry/breaker ve agent/history hâlâ taşınacaktır. API + dört installed
application backend kapsamı değişmez; MCP tek başına Antigravity turn protokolü
veya Ready backend sayılmaz. Protokol dokümanı kullanıcıya non-blocking soruldu.
