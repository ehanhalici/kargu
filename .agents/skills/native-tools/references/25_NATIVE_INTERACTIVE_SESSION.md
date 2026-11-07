# Interaktif session: Native job, owned editor adapter

2026-10-24. 24'teki native idle policy ardından consumer cutover'ı.

## Silinen engine, korunan görünüm

`tools/process/session.el` içindeki make-process, process-send-string/EOF,
PID/PGID, sentinel, idle timer ve OS signal/cancel implementasyonu kaldırıldı.
Session artık `bridge/jobs` + `bridge/job-output` üzerinden actual native
handle tutar. Rust bounded stdin/output, idle policy ve TERM/grace/KILL/reap
sahibidir. Elisp yalnız private output buffer, decoded callback, byte cursor,
source lifetime ve terminal presentation adapter'ıdır. Engine fallback yoktur.

`bridge/command.el` Bash ve session için ortak editor snapshot capture'dır:
explicit environment first-entry/unset semantiği, root/cwd identity, original
source/session/run, exec-path, strict policy, registry ve mode revision.
Mode Agent -> Ask -> Agent olsa bile eski revision'daki onay canlanamaz.
Capture execution authority değildir; Rust exact-action gate yine zorunludur.

## Asenkron API ve hata sözleşmesi

- `kargu-process-session-start` bir :starting handle döndürür. Yeni :on-ready
  callback'i gerçek onay + receipt/claim sonrasıdır. O zamandan önce send/EOF
  açık hata verir; UI thread'i senkron IPC beklemez. Agent mode gereklidir.
- Send tek çağrıda en çok 32768 UTF-8 byte kabul eder. Opsiyonel callback
  (RESULT ERROR) actual acknowledgement alır. send-eof yalnız başarılı write
  acknowledgement sonrası gönderilir; uncertain input asla otomatik replay
  edilmez. Büyük input açık limit hatasıdır, silent truncation değildir.
- EOF :closing yapar; output/drain bitmez. Kill de :closing'dir; private view
  ancak gerçek native terminal result veya açık transport/owner failure ile
  kapanır. Local close, OS child öldü iddiası değildir.
- on-exit legacy code/signal alır; unknown cleanup nil, timeout/cancel sonrası
  parent exit=0 ise -1 olur. Unknown/timeout sahte legacy başarı zero olamaz.
  result/failure accessor'ları gerçek typed sonucu ve cleanup evidence tutar.
- 0..4MiB output retention, Unicode carry, actual native byte cursor, EOF,
  callback take-once, private buffer release ve reader narrowing korunur.
  Empty poll output callback üretmez. Idle süreyi Emacs timer'ı değil native
  I/O observation yeniler. Legacy grace argümanı native policy'yi değiştirmez.

## Öğrenim: buffer-live-p kill hook içinde yeterli değildir

Emacs kill-buffer-hook çalışırken buffer-live-p hâlâ true olabilir. Dolayısıyla
yalnız bu predicate, kapanış sırasında son input/exit callback'inin editor
state değiştirmesini engellemez. Session'ın -100 depth source hook'u callback
lease'ini ordinary RPC cleanup'tan önce revoke eder; sonra native owner drain
yolu çalışır. Hook ve timer kaynakları kendi capture'ına aittir; sibling
session'a, replacement connection'a veya current buffer'a ödünç verilmez.
Major-mode değişimi de aynı revocation'dır. Session identity ayrıca sınanır.

## Test eşlemesi ve sınırlar

Eski beş interactive testi gerçek core/explicit approval fixture'larına
eşlendi; natural-exit/spawn-error resume testleri de async native boundary'ye
taşındı. Yeni testler startup race, send/EOF order, owner close + /proc cleanup
ve sibling status, stale wire ack, late receipt disposal, rejection, oversized
input/no replay, empty poll ve unknown legacy exit ayrımını kapsar. Synchronous
startup veya premature :closed bekleyen eski test beklentileri yeni gerçek
lifetime'a göre güncellendi; davranış kapsamı silinmedi.

Generic shared `tools/process.el` diğer Git/search/diff/webfetch tüketicileri
taşınmadığı için durur; session/Bash artık onun OS runner'ını çağırmaz. Ortak
byte-tail helper editor presentation içindir, ikinci execution archive değildir.
API/provider run ve dört application backend bu port nedeniyle tamamlanmış
sayılmaz.

Doğrulama: 19 odaklı native session/resume/Bash testi; kaynak + güncel binary
full ERT **1180/1180 expected**, 0 unexpected, **117.01 s**. Değişen üretim ve
test dosyaları warning-as-error bytecompile/checkdoc temiz; geçici .elc
kaldırıldı. Rust kaynakları önceki 24 commit'inden değişmedi: **74 test +
2 compile-fail**, locked build/test, fmt ve strict Clippy kanıtı oradadır.
Bounded TLC yeniden hatasız: process-session 129/42/depth7, approval
8194/1536/depth11, transport 1810/693/depth13. Bunlar mevcut soyut modellerin
regresyonudur; yeni editor hook/runtime için formal refinement ispatı değildir.
