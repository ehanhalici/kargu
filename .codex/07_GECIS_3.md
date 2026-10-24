# 07. KATMAN 3: IPC VE WIRE SÖZLEŞMESİ v1

Bu belge Emacs <-> Rust özel protokolünün tek kaynağıdır. MCP, sağlayıcı API'leri
ve Codex app-server ayrı adapter protokolleridir. Rust DTO'ları, JSON Schema ve
Emacs fixture'ları aynı alan isimlerini kullanır.

## 1. Süreç topolojisi ve handshake

İlk çalışan dilim (2026-10-24): yalnız application_lifecycle, session_lifecycle
ve ping capability'leri vardır. Restore/prompt/tool/review yöntemleri henüz
uygulanmaz, method-not-found/unavailable döner. İlk initialize params'ında
capabilities string array; limits.max_frame_bytes 1024..1048576 aralığındadır.
application/create params {}, session/create application_id, snapshot/close
application_id + session_id alır. Snapshot RAM lifecycle projection'ıdır;
history restore desteği olduğu anlamına gelmez. rpc/cancel foundation bu
dilimde request_id + scope string taşır; run adapter'ları kendi structured
scope sözleşmesiyle eklendiğinde capability/version ile genişletilecektir.

İlk hedef Linux'tur. Her Emacs client instance bir `kargu-core --stdio` child
sahiplenir; core içinde explicit application/session'lar bulunur. Başka
Emacs süreci bu stdio kanalını paylaşmaz. MCP erişimi 03'teki ayrı proxy'dir.

`make-process`: pipe, UTF-8 Unix coding, ayrı stderr buffer ve process-local
connection state kullanır. stdout sadece protokol taşır. Filter/sentinel
proc + connection epoch kimliğini doğrular; eski process sentinel'ı yenisini
sıfırlayamaz. EOF/crash otomatik model isteği yeniden oynatma nedeni değildir.

İlk istek `initialize`; params protocol_major/minor, client_version,
capabilities ve limits taşır. Result core_version, seçilen protocol sürümü,
connection_epoch, capabilities ve negotiated limits döner. İstemci
`initialized` bildirimi yollar. Uyuşmayan major sürümde çalışma açılmaz.
Ardından application/session create veya restore yapılır. Handshake öncesi
yan etkili çağrılar reddedilir.

## 2. JSON-RPC doğrulama

- JSON-RPC 2.0 envelope: request = method + id; notification = method ve id yok;
  response = id ve tam olarak result/error alanlarından biri. `result: null`
  geçerli yanıttır; yok alanla karıştırılmaz.
- Kargu tarafından üretilen request id'ler `e:<epoch>:<counter>` ve
  `r:<epoch>:<counter>` string'lerdir. Giriş codec'i string/integer JSON-RPC
  kimliklerini ayırıp aynen döndürür; null yeni request için kabul edilmez.
- Eksik/yanlış jsonrpc, method/params tipi, duplicate JSON key ve çelişkili
  envelope reddedilir. Batch v1'de desteklenmez, Invalid Request döner.
- Dispatcher önce envelope alanlarını inceler; gevşek untagged enum ile bir
  notification'ın response diye parse edilmesine izin vermez.
- Parse error -32700; Invalid Request -32600; method not found -32601;
  invalid params -32602; internal error -32603. Geçerli notification'a yanıt
  dönülmez. Parse edilemeyen istekte id null'dır; ham satır loglanmaz.
- Domain durumları typed result/error.data içindedir; C-g veya conflict
  `method not found` olarak raporlanmaz. JSON false/null/empty array Emacs'te
  ayrı temsillerle encode/decode edilir.

## 3. Kanonik yöntemler

| Yön | Yöntemler | Anlam |
| --- | --- | --- |
| Emacs -> Core | initialize, initialized | Sürüm/capability anlaşması |
| Emacs -> Core | application/create, session/create, session/restore, session/snapshot, session/close | Explicit yaşam döngüsü |
| Emacs -> Core | session/prompt | Admission; hızlı accepted/run_id yanıtı |
| Emacs -> Core | session/abort | Belirli run'ı iptal; hızlı accepted/already_terminal |
| Emacs -> Core | config/update, models/list, session/select | Revision'lı seçim ve config |
| Emacs -> Core | tool/execute | Geçişte eski Elisp çağıranları için ortak gate |
| Emacs -> Core | edit/review_decision, plan/dispatch | Tek kullanımlık review/plan kararı |
| Core -> Emacs | editor/call_tool | Allowlist tool_name + typed arguments |
| Core -> Emacs | editor/resolve_mentions | 09 bağlam snapshot'ı |
| Core -> Emacs | editor/request_approval | 06 approval sözleşmesi |
| Core -> Emacs | editor/apply_buffer_patch | 06 edit transaction |
| Core -> Emacs | event/chunk, event/state_changed, event/status_update, event/diff_available, event/run_finished | Sıralı UI olayları |
| Çift yön | rpc/cancel | request_id ve scope ile pending iş iptali |
| Emacs -> Core | shutdown, exit | Drain ardından kontrollü kapanış |

Sensörler için ikinci bir `editor/sensor/*` veya `editor/dape_get_scopes`
metot ailesi yoktur; `editor/call_tool` kullanılır. Job/stream continuation
operasyonları tool registry şemaları üzerinden mevcut public adları korur.

Her session işlemi explicit application_id/session_id taşır. Aktif run'a ait
işlemler, reverse çağrılar ve olaylar ayrıca run_id/generation taşır.
Core üretimi event'ler connection_epoch ve session başına artan sequence taşır.
Snapshot son sequence'i içerir; boşlukta UI snapshot ister. Duplicate/eski
sequence veya eski epoch event'i uygulanmaz. Aktif seçimden owner çıkarılmaz.

Normal akış örneği (handshake ve session/create sonrasında):

```json
{"jsonrpc":"2.0","id":"e:c1:4","method":"session/prompt","params":{"application_id":"a1","session_id":"s1","prompt":"Refactor this function","context":{"file":"src/main.rs","line":42,"col":0}}}
{"jsonrpc":"2.0","id":"e:c1:4","result":{"status":"accepted","run_id":"run1","generation":1}}
{"jsonrpc":"2.0","method":"event/chunk","params":{"connection_epoch":"c1","application_id":"a1","session_id":"s1","run_id":"run1","generation":1,"sequence":1,"delta":"Merhaba"}}
{"jsonrpc":"2.0","id":"r:c1:7","method":"editor/call_tool","params":{"application_id":"a1","session_id":"s1","run_id":"run1","generation":1,"tool_name":"diagnostics","arguments":{"file":"src/main.rs"}}}
```

Araç adları örnektir; gerçek canonical ad/alias listesi mevcut register.el
envanterinden export edilir. Prompt kabulü nihai başarı değildir;
`event/run_finished` cleanup sonrası tek terminal outcome taşır.

## 4. Framing, limit ve backpressure

Her mesaj UTF-8, tek fiziksel satır + LF'dir; string newline'ları JSON escape
edilir. Kısmi satır ve birleşik satırlar iki uçta da desteklenir. Emacs coding
decoder parçalanmış UTF-8'i korur; partial state connection başınadır.

Başlangıç limitleri handshake'de en fazla bu değerlerle seçilir:

| Kaynak | v1 üst sınırı |
| --- | --- |
| Tek wire frame | 1 MiB UTF-8 byte |
| Pending request | Yön başına 128 |
| Kontrol outbound kuyruğu | 128 mesaj / toplam 1 MiB |
| Render outbound kuyruğu | 256 mesaj / toplam 4 MiB |
| Tek token delta batch | 32 KiB; en çok 50 ms bekletme |
| Emacs dispatch dilimi | En çok 100 mesaj veya 5 ms |
| Sensor deadline | 10 s |
| Approval deadline | 300 s |
| Normal request deadline | 30 s; operation'a göre explicit override |

Rust `LinesCodec::new_with_max_length` veya eşdeğer bounded decoder kullanır;
`LinesCodec::new()` sınırsız tampon koruması sağlamaz. Emacs byte limitini
newline gelmeden kontrol eder. Aşan frame bağlantıyı fail-closed kapatır ve
pending çağrılar kapanır. EOF'taki yarım frame protokol hatasıdır.
Büyük dosya/tool output/context sonuçları pagination veya bounded attachment
referansıyla taşınır; sınırsız JSON frame'e çevrilmez.

Tek stdout writer vardır. Kontrol ve render kuyrukları ayrıdır; cancellation
ve reverse response render yükünün arkasında aç kalmaz. Token parçaları
birleştirilebilir; terminal, approval ve edit olayları düşürülemez.
`broadcast` lag sessiz token kaybına yol açamaz. Slow consumer'da sınırlı
backpressure uygulanır; limit aşımında typed error + drain yapılır.

Filter sadece framing/queue işini yapar. UI/sensör/confirmation dış event
döngüsünde dispatch edilir. Rust reader yanıt bekleyen run'dan bağımsızdır;
aktör inbox'ı reverse çağrı beklerken kilitlenmez. Sink kilidi pending yanıt
beklerken tutulmaz. Senkron `accept-process-output` polling yoktur.

## 5. Pending request ve bağlantı kapanması

Pending kaydı send'den önce kurulur; callback/oneshot, deadline, owner,
connection epoch ve cleanup saklar. Başarı/hata, send failure, timeout, cancel
ve process death aynı take-once terminal yolunu kullanır. Geç yanıt inert'tir.
Emacs response gönderirken core'u otomatik yeniden başlatmaz.

Stop, owner closure ve EOF bütün ilgili pending işleri/timer'ları kapatır;
UI approval'ı da dismiss eder. shutdown yeni admission'ı kapatır, 11'e göre
run/job'ları drain eder, son yanıtı flush eder ve exit/EOF ile kapanır.
Core crash sonrası snapshot/journal üzerinden recovery sunulur; yazıların
uygulanıp uygulanmadığı belirsizse `outcome_unknown` raporlanır.

## 6. Kabul kapısı

Gerçek pipe kullanan ERT + Rust harness: her byte sınırında frame bölünmesi,
çoklu frame, UTF-8/CRLF, result:null, false/[], unknown method, duplicate key,
malformed/oversize frame, simultaneous reverse RPC, late/duplicate response,
timeout, queue saturation, slow reader, old sentinel/new process ve EOF.
Deadline/cancel sırasında pending sayısı ve çocuk task'lar sıfıra iner.
