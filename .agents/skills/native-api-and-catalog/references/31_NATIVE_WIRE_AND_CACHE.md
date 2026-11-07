# 31. Native wire ve prompt-cache cutover

2026-10-25. Format metadata önce typed `WireSpec`'e ayrıştırılır; HTTP admission
aynı endpoint/model/provider/format revision'ına bağlı bir `WireCodec` yakalar.
Editor canonical chat DTO gönderir. Cache sınırları ve Messages dönüşümü Rust'ta
bir kez uygulanır; HTTP/SSE sonucu aynı captured codec ile normalize edilir.
Custom format alanları korunur, sağlayıcı adından format tahmin edilmez.

`api/cache.el` ve `api/wire.el` içindeki request/response/cache engine'leri
silindi. Wire facade yalnız UI metadata erişimi ve henüz taşınmamış history
tool-ID adapter'ını içerir. Provider projection ters DTO encoder'ı bir policy
motoru değildir. `api_wire` capability yoksa yeni request başlamaz.

Cache işaretleri message envelope'a değil content block'a konur. Değişken
`<runtime_environment>` suffix'i stable system prefix'ten ayrıdır. Son insan
mesajı işaretlenmez; tamamlanmış tool result işaretlenebilir; son canonical tool
definition marker'ı native dönüşümde korunur. Stored history değişmez.

Reasoning signature ve bilinmeyen provider continuation blokları opaque tutulur;
yalnız tam endpoint/model/provider/format-revision eşleşmesinde geri gönderilir.
Internal metadata compatible API'ye sızdırılmaz. Bu bağlam digest'i güvenilmeyen
bir istemciye karşı kriptografik authorization token'ı değildir; IPC güven sınırı
değişmedi. Application/history sahipliği sonraki core run kesiminde taşınır.

Native cache usage input/cache toplamları checked integer arithmetic kullanır.
Bilinmeyen sayaçlar zero yapılmaz; negatif/kesirli/taşan değer başarı sayılmaz.
ModelId, OutputLimit ve field adları parse sınırında typed'dır. Blocks stream
desteği metadata false ise HTTP öncesi reddedilir; yeni protokol eklenmedi.

Eski ERT pure engine sözleşmelerinin native karşılıkları `tests/api_wire.rs`:
system lift, tool call/result/definition, grouping, copy keys, finish mapping,
usage, invalid arguments/rules, custom DSL, opaque scope isolation, cache stable
prefix/purity/completed assistant/latest human/empty tools/native tool result.
Elisp testleri canonical delivery ve immutable capture sınırını denetler.
`tests/test-stream.el` gerçek Emacs→stdio→Rust→loopback HTTP yolunda native ve
compatible formatları, cache on/off/empty-tools ve old-core refusal'ı doğrular.

Resmî Chat Completions şeması bu kesimde kontrol edildi:
https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create
Model yükseltmesi veya yeni capability varsayılmadı. max_tokens ile
max_completion_tokens ayrımı ve reasoning desteğinin model-bazlı olması sonraki
request-policy cutover'ında korunmalıdır. Canlı hesap/ücretli model çağrısı yok.

Bu kesim tam API veya tam migration tamamlanması değildir. Request parameter
policy/header assembly, retry/breaker, model metadata store, core agent/history,
kalan tool portları ve dört uygulama backend'i hâlâ roadmap'teki kapsamdır.
