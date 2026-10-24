# Kalıcı job geçişi: süre ve çıktı sözleşmesi

2026-10-24. Kullanıcı loop halinde küçük, test edilen commit'lerle göçe devam
edilmesini ve tüketici taşınınca eski Elisp uygulamasının silinmesini istedi.

## Korunan davranış ve ilk prerequisite

Mevcut Bash `timeout=nil` ile gerçekten sınırsız süreli işler çalıştırır;
canlı log başlangıcı değil son çıktıyı tutar. 18'deki tek-atımlık Rust portunu
aynen kullanmak bu davranışları kaybettirirdi. İlk library dilimi:

- `domain/deadline.rs`: ExecutionTimeout/Deadline özel alanlı tipleri;
  sınırsız süre far-future bir sayı değildir. Cancel, output ve process/owner
  kotaları devam eder. Approval 300 s, TERM/grace/drain ayrı sınırlıdır.
- `RunSettings::persistent` açık bir servis ömrü seçer. Finite run deadline
  varsa sınırsız command onu aşamaz. Eski bounded constructor korunur.
- `process/archive.rs`: bounded prefix ve VecDeque rolling tail. Tail yeni
  verilerle eski byte'ları değiştirir; run output bütçesi saklanan kapasitenin
  büyümesini sayar, her rewrite'ta tekrar düşülüp log durdurulmaz.
- OutputPage `start_cursor`/`next_cursor` ile atlanan eski interval'i açıklar;
  byte sayfaları kayıpsızdır, UTF-8 parçalarını birleştirmek tüketici işidir.
- Command timeout ve retention action digest'e dahildir. Yeni output policy
  eski onayla yürütülemez. Existing tek-atımlık wire portu henüz genişletilmez.

Bu yalnız prerequisite'tir: Bash/session public tüketicileri taşınmadığı için
Elisp process/session/jobs dosyaları bu dilimde silinmez. Sahte migration
tamamlandı iddiası veya işleyen sync davranışa gizli fallback eklenmez.

## Sonraki dilimlerin ownership kararı

Background job agent'ın tek aktif turn claim'ini süresiz tutamaz. Job'lar
aynı kanonik ApplicationActor altında, parent session'a bağlı ayrı servis
scope'larıyla izlenecek; tek aktif agent turn kuralı gevşetilmeyecek ve her
job için sahte yeni application açılmayacak. Aynı mailbox yazıcısı admission,
onay, job completion ve session revoke durumunu yönetecek.

Ardından capability-gated start/status/read/write/eof/cancel/forget portları,
bounded stdin acknowledgement ve owner kontrolü eklenecek. Mailbox stdin/child
beklemeyecek; sonuçlar typed completion olarak alınacak. Live/tail UI yalnız
adapter olacak; Elisp'in OS spawn/signal/output-retention motoru eşdeğerlik
testlerinden sonra kaldırılacak. Diğer Git/search/process tüketicileri kendi
portları taşınmadan silinmeyecek.

## İlk prerequisite doğrulaması

55 Rust testi + 2 compile-fail; locked fmt/build ve strict all-target Clippy
temiz. Güncel binary ile source-only full ERT: 1151/1151, 0 unexpected,
48.94 s. Üç yeni test persistent stdin/approval bound, rolling-tail byte gap
ve retention değişiminde farklı action digest'i doğrular. Mevcut bounded
deadline/prefix/output-budget/PGID/replay testleri korunur.
Bounded TLC process 535 generated/179 distinct/depth9, process-session
129/42/depth8 hatasız; unlimited gerçek OS ömrünün formal refinement ispatı
değildir. Kullanıcının shell.nix ve 07 belgesi değişiklikleri korunur.
