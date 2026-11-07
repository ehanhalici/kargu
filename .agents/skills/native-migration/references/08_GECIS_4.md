# 08. KATMAN 4: ÇEKİRDEK İŞ MANTIĞI VE NİHAİ KABULLER

01 domain kurallarını, 07 IPC'yi, 11 cancellation'ı belirler. Bu belge iş
servislerinin kapsamını ve mevcut Elisp davranışlarının korunmasını tanımlar.

## 1. Core düzeni ve composition

```text
kargu-core/
  Cargo.toml, Cargo.lock, rust-toolchain.toml
  src/lib.rs, src/main.rs
  src/domain/        kimlikler, revision, result, cost
  src/application/   admission, ownership, mode, reset
  src/ipc/           codec, schema, router, pending
  src/engine/        machine, dispatcher, budget, heal, verify
  src/security/      policy, approval, path, egress
  src/history/       types, store, compactor, repair, migration
  src/config/        parse, schema, credential port, snapshot
  src/models/        catalog, discovery, capability, pricing
  src/network/       provider adapters, SSE, request/response
  src/resilience/    breaker, retry
  src/tools/         fs/read, search, git, process/jobs, webfetch, skills
  src/edit/          proposal, review, transaction journal
  src/context/       mentions, attachment budget
  src/sensors/       editor DTO ve capability'leri
  src/bridges/       harici backend ve MCP adapter'ları
  assets/, tests/fixtures/
```

Concrete adapter'lar composition root'ta kurulur. Domain/core Emacs, chat UI,
Eglot, Dape veya harici binary'ye bağımlı değildir. Missing capability ilgili
aracı kaldırır veya typed unavailable verir; güvenlik kapısını devre dışı bırakmaz.

## 2. Admission, reset ve bağlantı

application/coordinator, execution, budget, mode, reset ve loop/state tek actor
akışına taşınır. Claim credential/config hazırlığından önce alınır. Callback
origin application/session/run/claim'i taşır. Cancel/drain bitmeden claim
bırakılmaz. Pre-admission hata mevcut history/edit/draft'ı değiştirmez.

Run immutable connection snapshot'ı provider/model, endpoint, wire family,
model metadata generation, reasoning/sampling, headers ve config revision ile
yakalar. Retry aynı snapshot'ı kullanır; live seçimden yeniden okunmaz.

Config TOML/schema Rust'ta parse edilir. Mevcut dosya seçim/öncelik ve özel
provider/model kayıtları fixture ile korunur. Emacs auth-source/callable secret
gerekiyorsa explicit credential port üzerinden, iptal edilebilir hazırlıkta
çözümlenir. Secret config update/event/history içine karıştırılmaz.
Config veya selection değişince eski hazırlık sonucu yayınlanamaz.

Reset: yeni admission'ı kapat -> owned request/job/approval/edit işlerini iptal
ve drain et -> history/counters/breaker/session reset -> view notification.
Başka application/session verisi temizlenmez; observer hatası reset'i yarıda
bırakmaz. Reentrant startup reset bariyerini aşamaz.

## 3. Güvenlik ve egress

Path policy root'u explicit canonical workspace'ten gelir. Root çözümlenemiyorsa
`.` fallback'i yasaktır. Relative path explicit cwd/root ile çözülür. Yeni
dosyada mevcut ancestor doğrulanır; symlink, lexical prefix, rename target ve
yürütme anı path replacement test edilir. Güçlü confinement gereken işlemler
descriptor-relative güvenli API kullanır; salt canonicalize check yarışlara
karşı sandbox garantisi değildir.

Shell parsing ve yıkıcı komut listesi risk sınıflandırmasıdır; güvenlik
sandbox'ı değildir. `python -c`, interpreter, executable, redirection,
substitution, env, function, shell startup ve network etkileri basit regex'le
güvenli ilan edilemez. Bilinmeyen komut açık policy/onay ister. Güvenilir
read-only yerel işlemler mümkünse doğrudan argv/API ile uygulanır.
Arbitrary shell, root dışına erişimi OS izolasyonu olmadan engellediğini iddia
etmez; bu capability/limit UI'da açıkça belirtilir.

Native araç, alias, LSP edit, Dape evaluate ve MCP çağrısı aynı gate'ten geçer.
Onay action digest, scope, policy/config revision ve deadline'a bağlıdır;
tek sefer consume edilir ve execution öncesi yeniden doğrulanır.
Kayıtlı UUID tek başına kriptografik mühür değildir.

webfetch ve model endpoint policy'leri ayrıdır. Webfetch scheme/host/port,
DNS sonucundaki bütün IPv4/IPv6 adresleri, loopback/private/link-local/
metadata adresleri ve redirect hedeflerini denetler. DNS-rebinding için
doğrulanmış bağlantı adresi kullanılır; redirect başına yeniden policy yapılır.
Explicit yerel model endpoint izni webfetch'e genel localhost izni vermez.
Credential taşıyan model istekleri redirect takip etmez; TLS doğrulama açıktır.
Timeout/response/body/decompression boyutları sınırlıdır.

## 4. Process ve job servisi

Bash/process tek servis altında çalışır; mevcut interactive process session,
stdin write, read output, wait/poll, EOF, job listing/cancel ve owner gate
özellikleri korunur. Shell execute tek String sonucu ile bu özellikleri
kaybedemez. Exit code, signal, stdout/stderr ve truncation ayrı alanlardır.

Her subprocess admission/startup bariyeriyle kaydedilir; group kimliği spawn
anında yakalanır. stdout/stderr eşzamanlı bounded drain edilir. Retained çıktı
1 MiB/stream/job, toplam 8 MiB/run ile sınırlıdır; devam pagination cursor'ı
taşır. Aşım truncation üretir; pipe drain durdurulup deadlock oluşturulmaz.
İşlem süresi, concurrency (varsayılan 4/run) ve byte limitleri config ile
doğrulanır; global host limiti de bulunur.

Blocking filesystem/search/git işlemleri bounded worker/`spawn_blocking`
üzerindedir. `ignore` tek başına text arama motoru değildir; eşleme ve byte/
dosya/zaman limitleri ayrıca uygulanır. Cancellation per file/chunk kontrol
edilir. Process cleanup ayrıntısı 11'dedir.

## 5. History, compaction ve persistence

Domain mesajı yalnız role/content değildir. MessageId, role, text/reasoning/
image/attachment block'ları, tool_call_id/name/arguments, tool_result/error,
provider metadata/signature ve usage bilgilerini taşır. Sağlayıcıya özel
opaque bloklar desteklenen roundtrip için korunur. Araç kimlikleri turn ve
batch boyunca doğrulanır; duplicate ingress reddedilir.

Compaction açık tool call ve karşılıklarını kimlikle gruplar; sadece role'a
göre geriye yürümek yeterli değildir. System/developer yönergesi, son kullanıcı
isteği ve devam için zorunlu atomic block'lar korunur. Output reserve + tool
schema + attachment + protocol overhead context hesabına girer.
Zorunlu içerik sığmıyorsa boş history gönderilmez, typed context_budget_exceeded
döner. Özetleme model çağrısı aynı run bütçesi ve cancellation'a tabidir.

Mevcut session JSON **schema_version=2** ve sürümsüz legacy import korunur.
Fixture: history, counters, provider/model, effort, root ve selection. İleri
bilinmeyen sürüm reddedilir. Import kopya üzerinde validate/migrate eder;
eski dosyayı ezmez. Kullanıcıya eski backend ile dönülebilecek snapshot kalır.

Yeni store versioned append-only journal + atomic snapshot kullanır.
Session başına tek writer/lock, monotonic sequence, record length/hash,
private file mode ve açık flush/fsync politikası vardır. Terminal outcome
publish edilmeden ilgili journal kayıtları kalıcılık politikasına göre commit
edilir. Startup recovery yalnız eksik son record'u ayrı işaretleyip kurtarır;
ortadaki bozulma sessizce atlanmaz. Log compaction yeni dosya + rename ile
yapılır; orijinal recovery kopyası korunur. Credential serialize edilmez.
Chat metninin hassas olabileceği saklama konumunda ve retention ayarında ele alınır.

Crash sonrası yan etkisi belirsiz shell/edit otomatik yeniden yürütülmez.
`started` olup terminal kaydı olmayan işlem `outcome_unknown` olarak restore
edilir; history protokolü bu bilgiyle onarılır. Journal çok dosyalı OS işlemini
kendiliğinden crash-atomic yapmaz.

## 6. Provider transport ve verification

OpenAI Chat Completions/Responses, Anthropic, Gemini ve mevcut yerel/custom
wire aileleri ayrı codec/adapter'dır; tek SSE parser tüm payload farklarını
çözmez. HTTP başarı/finish nedeni/terminal event sözleşmesi doğrulanmadan
yarım tool args çalıştırılmaz. Ağ EOF tek başına başarı değildir.
SSE event/line/args buffer limitlidir; partial JSON, Unicode, usage ve
reasoning/tool delta'ları fixture'larla doğrulanır. Provider/model capability
10'dan gelir; API parametreleri tahmin edilmez.

Healing: schema/args düzeltme döngüsü bounded'dır; permission denial,
cancellation veya belirsiz yan etki generic retry ile aşılmaz.
Verification: edit sonrası exact document revision için diagnostic bariyeri
kurulur. Timeout/unavailable/stale durumlar clean/verified sayılmaz.

## 7. Çıkış ölçütü

Mevcut contract/ownership/transport/budget/permission/process/edit/history/
restore test davranışları Rust service ve IPC integration testlerine eşlenir.
Tek başına `cargo check` veya birkaç ping testi eşdeğerlik değildir.
İlgili bounded TLA+ modelleri değişen actor/claim/drain geçişlerine göre
güncellenir; somut pipe/OS/save-hook davranışı integration testleriyle sınanır.
