# Süreç job portu: ayrı lifetime, ortak gate/supervisor

Güncel consumer durumu: Bash OS engine cutover'ı 23'te tamamlandı. Opsiyonel
idle policy ve `process_idle_timeout` capability'si 24'te tanımlıdır. Aşağıdaki
ilk wire diliminin sayıları ve o sıradaki açık işler tarihsel kayıttır.

2026-10-24. 20'deki prerequisite sonrasında Rust wire dilimi.

## Ownership ve ömür

ApplicationActor tek agent/foreground claim'ini korur; explicit process-job
scope'ları aynı actor'ın ayrı bounded tablosunda tutulur (`application/jobs.rs`).
RunScope purpose=agent_turn/process_job action digest'e dahildir. Job completion
başka aktif turn'ü bırakamaz. Aynı application'da en çok dört live/draining
job; supervisor host kotası 16, terminal archive dahil toplam job kotası 64'tür.
Session revoke/drop bağlı job'ları da iptal eder. Yeni application uydurulmaz.

`ipc/execution/jobs/{mod,io}.rs` aynı mailbox writer'ında çalışır. Startup
reverse onay ve grant tüketimi, önceki ExecutionGate/ProcessSupervisor yoludur.
`job/start` sonucu yalnız startup receipt'tir; child terminal sonucu değildir.
Foreground RPC waiter bitince job lifetime kaybolmaz. Genel tek-atımlık
`tool/execute` ve sabit ls portu korunur; henüz Bash consumer cutover'ı yoktur.

## Capability ve DTO

Capability `process_jobs`. `job/start` önceki explicit command DTO'sunu kullanır:
scope + arguments(root, mode, absolute program, string argv, cwd, timeout_ms,
explicit environment, config_revision, policy_revision). Job için timeout_ms
null gerçek unlimited'dır; genel tool/execute null süreyi reddetmeye devam eder.
İsteğe bağlı output_bytes per-stream kapasitedir: 0..4194304; yoksa 1048576.
Tail policy seçilir. Timeout/retention/output_bytes onay metadatasına ve digest'e
bağlıdır; ordinary prefix capture varsayılanı değişmez.

Başlangıç sonucu job_id + process_id (display-only) + state=awaiting_claim'dir.
İstemci owner cleanup'ını kurduktan sonra 5 saniye içinde `job/claim`
({owner,job_id}) göndermelidir. Receipt kaybolursa unclaimed job revoke/drain
edilip unutulur; RPC id yeniden kullanımını startup sahipliğiyle karıştırmayız.
Sonraki portlar:

- `job/list`: {owner}; sonuç {jobs:[snapshot...]}.
- `job/status`, `job/eof`, `job/cancel`, `job/forget`: {owner,job_id}.
- `job/read`: {owner,job_id,stream:stdout|stderr,cursor}; sonuç
  {data:[byte...],start_cursor,next_cursor,truncated,eof}.
- `job/write`: {owner,job_id,text}; UTF-8 chunk en çok 32768 byte.

owner = {scope:{application_id,session_id},root:captured canonical project}.
Başka session/proje bilinen job_id ile read/write/cancel yapamaz. List yalnız
eşleşen kayıtları döndürür. Forget gerçek terminal completion/drain'den önce
reddedilir; görünür log veya process kullanıcıdan habersiz unutulmaz.

Read sayfası frame bütçesine göre daralır. Byte array kasıtlıdır: UTF-8 codepoint
iki sayfaya bölünse de byte kaybı olmaz. stdout/stderr varsayılan olarak ayrıdır.
İsteğe bağlı stderr=merge aynı OS pipe'ını iki fd'ye bağlar; shell metnine
redirection eklenmez. Policy exact approval ve action digest'e dahildir.

## Bounded devam işlemleri

Stdin kuyruğu ve acknowledgement kayıtları bounded'dır. Mailbox pipe write
beklemez; oneshot acknowledgement ve contended archive read timer tick'inde
poll edilir. 10 saniye ayrı continuation deadline'ıdır; process çalışma süresi
değildir. Request cancel sibling job'ları veya job'ın kendisini öldürmez.
Queued stdin iptal edildiğinde byte'lar child'a ulaşmış olabilir: typed
outcome_unknown/-32010 döner; otomatik replay yapılmaz. Cancel yazılmış byte'ı
geri almaz. Gerçek process iptali job/cancel ile TERM/grace/KILL/reap yoludur.

## Kanıt ve kalan sınır

Gerçek pipe fixture'ları unlimited stdin/EOF ve Unicode byte round-trip,
sibling job + aynı application foreground command, yabancı proje/session,
quota/re-admission, owner close -> shutdown reply öncesi /proc temizliği,
zero/custom output retention ve blocked stdin sırasında responsive ping'i
test eder. Ayrı library regresyonu job completion'ın agent claim'ini
bırakmadığını sınar. Klasik approval/replay/PGID/byte-budget testleri korunur.

Öğrenim: env_clear altında Nix shell'in default PATH'inde `sleep` bulunması
garanti değildir. Harici komut fixture'ı yalnız PATH'i explicit capture eder;
credential env sessizce miras alınmaz. Gerçek Bash adapter'ı environment
sözleşmesini açıkça aktaracak; generic port parent env kopyalamayacak.

Eski bounded process/application modelleri yeni job tablosunun refinement
ispatı değildir. Bu wire dilimi için yeni formal proof iddia edilmez; runtime
testleri somut kanıttır. Emacs Bash/session/jobs tüketicileri henüz bu yeni
portları kullanmadığından silinmez; sıradaki dilim owned client adapter'ıdır.

Son doğrulama: 63 Rust testi + 2 compile-fail; locked fmt/build ve strict
all-target Clippy sıfır uyarı. Güncel binary + kaynak full ERT 1151/1151,
0 unexpected, 49.43 s. Yeni runtime job tablosu için formal refinement
iddiası yoktur. Önceki 20 diliminde çalıştırılan bounded modeller tarihsel
regresyon kanıtı olarak kalır; yeni tabloyu otomatik ispatlamaz.
