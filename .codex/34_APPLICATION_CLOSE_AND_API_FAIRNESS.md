# 34. Application close, native kapasite ve API retirement fairness

2026-10-25. Bu kesim native application/run ownership bağlantısının önkoşuludur;
henüz Elisp agent/history loop'unun taşındığı veya servis session'ının gerçek
user conversation olduğu iddia edilmez. `application_close` capability'si ile
`application/close {application_id}` gerçek stdio RPC'ye bağlandı.

Host application entry'si `Live` veya `Draining` varyantıdır; bağımsız closing
registry ile çelişkili durum tutulmaz. Kapanış bütün session admission/publication
yetkisini hemen geri alır, active run/job cancellation token'larını iptal eder.
Ledger actor'da kalır. Lifecycle service; API pending/worker, read worker,
command preparation/review/running, job record ve job IO yok olmadan entry'yi
silmez, host kapasitesini bırakmaz veya `closed` sonucu döndürmez.

Süreç sonuçları actor'a teslim ve finish/reap sonrası kapanır. Başka application
devam edebilir. Cancel edilmiş close waiter yalnız kendi final reply'ını
bastırır; revocation geri alınmaz, drain atlanmaz. Owner-close RPC actor mailbox'ı
IO bekleyerek bloke etmez. Shutdown reply da pending application close'un
arkasındadır. Duplicate live correlation ID normal framing sınırına dahildir.

Yeni bulgu / kırmızıdan yeşile regresyon: API queue'sunu event-first biased
poll etmek, bir başka stream event kanalını sürekli doldurunca bitmiş worker
join'ini süresiz erteleyebiliyordu. `continuous_foreign_deltas_cannot_starve_join
_or_overtake_body` eski kodda başarısız oldu. Artık joined completion önceliklidir;
join öncesinde enqueued olan sonlu FIFO prefix ve terminal barrier birlikte
alınır. O prefix boşalmadan başka join batch alınmaz. Böylece body/delta sırası
korunur, yeni foreign event'ler terminali geriye itemez.

Queue sınırı explicit'tir: network channel 16, captured retirement batch en çok
17 (prefix + terminal); ikisi toplam en çok 33 event. Bu sınırsız bir backlog
değildir. Pending capacity terminal delivery'ye kadar tutulur; cancel/EOF drain
ready buffer ve kanalı da boşaltır. UI/writer basıncı altında wall-clock response
garantisi verilmez; writer deadline/connection teardown sınırları değişmedi.

Kabul testleri: gerçek iki socket ve sibling owner isolation; stale owner/session
create reddi; 80 create/close çevriminde kapasite reuse; pending review'ın explicit
reverse cancel'ı ve inert late approval; claimed process job'un close reply'dan
önce /proc'tan kaybolması; close→shutdown sıra kontrolü. Unit testleri drain
boyunca uygulama slotunun dolu kalmasını ve cancelled waiter semantiğini doğrular.

Mevcut bounded TLC application 6151/1681/depth25, transport 1810/693/depth13
hatasızdır. Bunlar yeni application-close/finite-prefix kodunun concrete refinement
ispatı değildir; gerçek pipe/OS ve kırmızıdan yeşile queue testleri ayrı kanıttır.

Sıradaki tüketici editor application→native scope lease eşlemesidir. Sonra ortak
native run claim/budget, retry/breaker, model metadata ve agent/history bağlanır.
Bu önkoşul için henüz çalışan bir Elisp application motoru silinmedi; karşılık
gelen live agent consumer taşınmadan silmek doğru değildir. API + dört installed
app backend kapsamı açık kalır; canlı hesap/ücretli CLI çağrısı yapılmadı.
