# Ortak komut yürütme ve ters onay köprüsü

Güncel ek: aşağıdaki ilk Rust diliminin ardından Emacs owned presenter da
bağlandı; sondaki bölüm ve 12'deki güncel doğrulama kaydı esas alınır.

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

## Emacs presenter bağlantısı

`kargu-bridge-execute` explicit program/argv DTO'sunu derin kopyalayarak mevcut
source buffer/session ve varsa async parent'a bağlar. Bu opt-in, noninteractive
public bridge portudur; Bash registry/jobs tüketicileri hâlâ eski executor'dadır.
`kargu/bridge/approval.el` yalnız ilgili çağrıda yüklenir; sıradan bridge load'u
onay UI'sını veya process'i başlatmaz.

Reverse request yalnız canlı forward request_id kaydıyla eşleşirse sunulur.
Canonical executable, invocation/argv[0], argv, cwd, explicit environment,
application/session ve config/policy revision birebir karşılaştırılır.
Eksik UI, unsolicited/malformed review ve keyboard quit reddir. Bir forward
request yalnız bir review sunabilir; aynı UI kararının replay'i etkisizdir.
Snapshot DTO sonradan değişen caller hash-table/vector'larını paylaşmaz.

300 saniyelik UI timer, source buffer kill/major-mode, async parent cancel,
forward timeout/finish, reverse rpc/cancel ve connection close yalnız ilgili
opaque confirmation handle'ını kapatır. Geç click response gönderemez; hiçbir
yanıt ölü core'u yeniden başlatmaz. Grace + drain 10 saniyeye çıkabileceğinden
bridge stop hard-close penceresi 5'ten 15 saniyeye çıkarıldı.

Somut wire öğrenimi: serde OsString'in varsayılan JSON gösterimi string argv
değildir; IPC DTO'sunda argv açık string array'e çevrildi ve gerçek pipe testi
bunu kontrol eder. Bu port UTF-8 girdi kullanır; canonical executable/cwd UTF-8
değilse typed hata verir, onay ekranına lossy path ile yetki taşınmaz.

Negotiated frame'e sığmayan reverse approval gönderilmez: pending grant/claim
iptal edilip scoped resource_limit döner; kullanıcı 300 saniye bekletilmez.
Regresyon fixture'ı ardından session close/admission'ın serbest kaldığını sınar.
`nix` crate'inin yalnız silinen scanner'a ait `dir` feature'ı da kaldırıldı.

Beş yeni Emacs regresyonu: gerçek approve/exact immutable capture/double click,
missing UI/quit, source owner close, Rust session revoke ve unsolicited review.
TLA+ application/approval/process/transport bounded modelleri yeniden hatasız
çalıştı; gerçek OS/Emacs adapter'ının formal refinement ispatı değildir.
