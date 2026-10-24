# Ortak komut yürütme ve ters onay köprüsü

2026-10-24. 17'deki araç bileşimi kararının ilk yürütme dilimi.

## Rust wire temeli

`tool/execute`, `command_execute` capability'siyle standalone program + argv
çalıştırır. `scope` mevcut application/session kimliğidir. `arguments` alanı:
root, mode, program (absolute), arguments (string array), cwd (nullable),
timeout_ms (1..86400000), environment (explicit string map), config_revision,
policy_revision. Bu port agent/provider run cutover'ı veya interaktif Bash job
şemasının taşındığı anlamına gelmez; eski Bash executor henüz Elisp'tedir.

`ipc/execution/{mod,input}.rs` tek mailbox yazıcısıdır. Bounded hazırlık işleri
filesystem capture'ı blocking worker'da yapar. Application başına bir komut
reservation'ı, host başına 16 vardır; terminal sonuç/drain gelmeden yeni komut
kabul edilmez. Hazırlık sonucu kapanmış owner adına run başlatamaz.

Actor admission -> ExecutionGate -> editor/request_approval -> tek kullanımlık
grant -> mevcut ProcessSupervisor zinciri kullanılır. Reverse isteği orijinal
request_id, approval_id, tam run scope ve immutable program/argv/cwd/environment
taşır. Yalnız tam `{approved: true}` kararı kabul edilir; eksik/bozuk UI yanıtı
reddir. Mode Ask/Plan/Debug genel komut çalıştıramaz.

Mailbox child veya onay beklemez: pending oneshot ve tamamlanan job'lar timer
tick'inde nonblocking poll edilir. Bu ilk port noninteractive'dir: stdin EOF
olur; stdout/stderr ayrı, her sonuç için en çok 64 KiB prefix ile döner.
Supervisor'ın daha geniş archive/run bütçesi ve pipe drain'i korunur.
Çıktı kesilmesi açık `truncated`, nonzero exit typed `failed` olur.

Session close owner'ı derhal revoke eder, aktif actor drain için tutulur.
Cancel/EOF/shutdown/write failure yeni yayın yetkisini kapatır; grant expiry,
PGID TERM/grace/KILL/reap ve actor completion ardından claim bırakılır.
Hazırlıktaki blocking OS çağrısı zorla abort edilemez; slot gerçek bitişe kadar
tutulur. setsid/cgroup/ani SIGKILL sınırları 14'tekiyle aynıdır.

## Bu dilimin doğrulaması

- Rust: 53 test + 2 compile-fail; locked fmt ve katı Clippy sıfır uyarı.
- Altı yeni gerçek-pipe regresyonu: onay sırasında ping; exact karar/replay;
  ret/bozuk karar ve yeni admission; owner close/geç onay; read-only mod ve
  traversal reddi; bounded output/typed timeout; çalışan child'da cancel/EOF
  ardından `/proc` kaydının kalkması. İlgili senaryolar altı test fonksiyonuna
  gruplandı; mevcut OS descendant fixture'ları da korunur.
- Full mevcut ERT: 1146/1146, 0 unexpected, 49.96 s. Bu noktada Emacs approval
  presenter henüz bağlı değildir; sonraki dilimde eklenecektir.
- Genel executable capture FIFO'da bloklamayan open kullanır; normal dosya ve
  executable izinleri kontrol edilir. Bu executable replacement için OS CAS
  garantisi değildir; spawn öncesi metadata revalidation korunur.

Sonraki dilim: Emacs owned approval presenter ve sabit `ls` adapter'ı;
önceki listing tarayıcısı/testleri yeni sözleşmeyle değiştirilir. API ve dört
uygulama backend'i kapsamı değişmedi.
