# Kayıt bütçesi: Unix arama adapter'ı için ortak process politikası

2026-10-24. `workspace_grep` consumer cutover'ından önceki prerequisite.
Regex/glob eşleştirmesi Rust'a taşınmaz; `rg` veya GNU `grep` yapar.

## Sözleşme

`CapturePolicy::Records(RecordLimit)` stdout'un ilk N LF-sonlu kaydını
saklar; N'inci LF'de prefix donar. Supervisor'a bounded watch observation
gider. I/O task sinyal göndermez veya actor/tool state değiştirmez. Supervisor
TERM -> tam grace -> KILL -> reap/drain tamamlanmadan sonucu yayımlamaz.
Süreç kapatılırken gelen ek stdout okunup atılır; absolute byte cursor bunu
hesaplar. Normal prefix/tail job davranışı değişmez; record-plus-tail geçersiz
kombinasyonu enum ile oluşturulamaz. Sonda LF olmayan çıktı doğal exit'e
kadar saklanır, kendiliğinden tamamlanmış kayıt sayılmaz.

`CaptureStop::Records` bilinçli **kısmi** capture başarısıdır; tüm workspace
taranmış garantisi değildir. `CaptureStop::Bytes`, istenen prefix tamamlanmadan
byte/run archive bütçesinin bitmesidir ve hatadır. Ham exit/signal ayrıca
korunur. Cancel, timeout, unknown cleanup ve bilinen doğal failure, sonradan
gözlenen capture nedeniyle başarıya dönemez. Record stop canlı producer'dan
gelmişse sinyal exit'i beklenen intentional-stop sonucu olarak sınıflandırılır.

`SuccessCodes::ZeroOrOne` yalnız adapter'ın açıkça seçtiği arama semantiğidir;
genel komut default'u hâlâ yalnız exit=0. Capture limiti, etkin retention ve
accepted-exit policy immutable action digest/review metadata'ya bağlanır.
Genel execution JSON DTO'suna arbitrary record/read-only yetkisi eklenmez.
Elisp reverse-review bilinmeyen/farklı record veya exit policy'yi reddeder.

## Neden rg --max-count veya head pipeline değil?

`rg --max-count` dosya başına sınırdır, mevcut global hit bütçesi değildir.
`head` sonrası shell pipeline producer'ın bitmesini bekleyebilir; sonuç hata
durumları da ayrıca korunmalıdır. Yerel bounded diagnostikte no-match=1,
invalid-regex=2 ve pipe kapatılınca rg=1 gözlendi. Bu nedenle kayıt/byte hesabı
eşleştirme motoru değil, ortak output/lifetime politikasıdır. Shell wrapper,
PID borçlanması veya premature leader reap eklenmez.

Mevcut Elisp grep engine'i bu prerequisite sırasında silinmez. Yeni native
adapter + editor cutover + davranış testleri tamamlandığında kaldırılacaktır.
Shared process runner diğer tüketiciler taşınana kadar kalır. API göçü ve
dört application backend bu çalışma nedeniyle tamamlanmış sayılmaz.

## Kanıt sınırı

Yeni testler exact digest, typed limit parse, canlı producer/grace/reap,
byte-before-record failure, explicit no-match exit, UTF-8/record chunk split,
freeze/discard cursor ve geç capture önceliklerini kapsar. Bounded eski TLC
modelleri regresyondur; yeni record observer için formal refinement iddiası
yoktur. Tam suite sayıları 12_MIGRATION_PROGRESS.md'de kaydedilir.
