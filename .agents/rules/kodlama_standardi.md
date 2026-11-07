# 🛠️ DİREKTİF: RUST ÇEKİRDEK MİMARİSİ VE SİSTEM TASARIM STANDARTLARI

Bu belge; Rust ile geliştirilen arka plan servisleri, CLI araçları, editör köprüleri (sidecar/daemon) ve agentic çalışma zamanları için **tavizsiz mimari ve kodlama yasalarını** tanımlar. Buradaki direktifler, çalışma zamanı (runtime) belirsizliklerini derleme zamanı (compile-time) garantilerine dönüştürmeyi ve sistemi taşınabilir, yüksek performanslı ve deterministik kılmayı hedefler.

---

## 1. Tip Sistemi, Alan Modellemesi ve "Parse, Don't Validate"

* **İlkel Tip Takıntısı Yasağı (No Primitive Obsession):**
* Çıplak `u32`, `usize`, `u64`, `String` gibi ilkel tipler alan mantığı taşıyan yerlerde serbestçe kullanılamaz.
* Kimlikler (`Id`), koordinatlar, sayaçlar, boyutlar, revizyonlar ve limitler için **özel alanlı Newtype** yapıları kullanılır.
* *Kural:* İki farklı kavramsal değer (örneğin satır numarası ile sütun indeksi veya adım sayısı ile yeniden deneme hakkı) yanlışlıkla birbirinin yerine parametre olarak geçilememelidir.


* **Ayrıştır, Doğrulama Yapma (Parse, Don't Validate):**
* DTO'lardan (JSON, CLI argümanı vb.) domain tiplerine dönüşüm daima `TryFrom` / `FromStr` sınırında yapılır.
* Bir tip sisteme başarıyla kabul edildikten sonra (invariants sağlandıktan sonra), fonksiyonların içinde aynı değer için mükerrer `if x <= 0` gibi doğrulamalar yazılmaz; tipin varlığı doğruluğun teminatıdır.
* `serde(try_from)` kullanılarak geçersiz durumların doğrudan serileştirme aşamasında reddedilmesi sağlanır.


* **Sayısal Disiplin ve Taşma Güvenliği:**
* Para, bütçe, token gibi kesinlik gerektiren değerlerde kayan noktalı sayılar (`f32`/`f64`) kesinlikle yasaktır; sabit noktalı (fixed-point) tamsayılar veya rasyonel yapılar kullanılır.
* Sıcaklık (temperature), olasılık gibi mecburi float alanlarda `NaN` ve `Infinity` engellenmeli, doğrulanmış aralık tipleri (`BoundedFloat<MIN, MAX>`) uygulanmalıdır.
* Sayaç ve aritmetik işlemlerde çıplak operatörler yerine taşma korumalı (`checked_*`, `saturating_*`) metotlar tercih edilir.


* **Sıfır Panik Kuralı (Zero Panics in Library Code):**
* Kütüphane ve çekirdek kodunda `unwrap()`, `expect()` veya `panic!()` kullanımı yasaktır.
* Dizi/vektör indeks erişimlerinde çıplak `[i]` yerine `.get(i)` kullanılır. Hatalar string mesajlarla değil, `thiserror` tabanlı kapalı `enum` tipleriyle (`CoreError`) taşınır.



---

## 2. Durum Makineleri, Sahiplik ve Yaşam Döngüsü

* **Typestate Pattern ile Derleme Zamanı Geçiş Güvencesi:**
* Deterministik sıralı aşamalar (örneğin: `Initial -> Ingesting -> Executing -> Completed`), önceki durumu tüketen (`self` alan) ve yalnızca geçerli sonraki durumu döndüren **Typestate Pattern** ile modellenir.
* Geçersiz bir durumdayken alakasız bir fonksiyonun (örneğin `Idle` durumundaki bir oturumda `approve_step()` fonksiyonunun) çağrılması derleme anında engellenmelidir.


* **Tek Yazıcı İlkesi (Single Writer Principle):**
* Her oturum veya işlem bağlamının durumunu güncelleyen **yalnızca tek bir aktör/görev (Actor Loop)** bulunur.
* I/O görevleri (network, disk, subprocess) durumu doğrudan değiştiremez; yalnızca aktörün kuyruğuna (mailbox) tipli tamamlama mesajları iletir.
* Aktör; harici RPC yanıtlarını, kullanıcı onaylarını veya uzun I/O işlemlerini beklerken kendi olay döngüsünü (mailbox) asla bloke etmez.


* **Olay Tamamlanması vs. Oturum Yaşam Döngüsü:**
* Tek bir görevin/adımın tamamlanması (veya hata/onay reddi ile sonlanması) oturumun kendisini sonlandırmaz; sistem temiz bir şekilde başlangıç/bekleme durumuna geri döner.


* **Basamaklı İptal ve Kaynak Tahliyesi (Cascading Teardown & Drain):**
* İptal (`Cancel`) sinyali geldiğinde sistem doğrudan duramaz; hiyerarşik bir boşaltma (`Draining`) evresinden geçer:
1. Aktif ağ akışları (`CancellationToken` ile) derhal düşürülür.
2. Bekleyen asenkron yanıt kanalları iptal edilir.
3. Protokol geçmişinde cevapsız kalan istekler (örneğin yarım kalan araç çağrıları) protokol şartnamesini bozmamak adına **sentetik iptal hatalarıyla** kapatılır.
4. Tüm kaynaklar tahliye edilmeden sistem yeni bir işlem kabul etmez.





---

## 3. Süreç Yönetimi, İzolasyon ve İşletim Sistemi Hijyeni

* **Süreç Grubu (Process Group / PGID) İzolasyonu:**
* İşletim sistemi seviyesinde çalıştırılan tüm alt süreçler (shell komutları, testler, derleyiciler), bağımsız bir Süreç Grubu (`setpgid(0)`) lideri olarak ayağa kaldırılır.
* İptal veya zaman aşımı durumunda yalnızca ana PID değil; o süreç tarafından çatallandırılmış (fork) tüm alt süreç ağacı (`-pgid` hedeflenerek) temizlenir.
* Kapatma sırası daima: `SIGTERM -> lütuf süresi (grace period) -> SIGKILL` olmalıdır. Sistemde asla yetim (zombie) süreç bırakılamaz.


* **Dosya Sistemi Sandboxing ve TOCTOU Koruması:**
* Dışarıdan veya modelden gelen tüm dosya yolları, izin verilen çalışma alanı köküne göre kanonikleştirilir (`canonicalize()`). Dizin dışına çıkma (`../` traversal) girişimleri I/O öncesinde kesin olarak reddedilir.
* Parse anında yapılan doğrulamanın yürütme anında değişebileceği (TOCTOU - Time of Check to Time of Use) unutulmamalı; kritik dosya manipülasyonlarında atomik işlemler ve son an kontrolleri uygulanmalıdır.


* **Araç ve Yan Etki Sınıflandırması:**
* Bir aracın güvenliği yalnızca isminden çıkarılamaz. Her araç açık bir güvenlik seviyesi bildirir:
* `SafeReadOnly` (Yan etkisiz, disk/durum değiştirmeyen sorgular).
* `MutatesState` (Dosya yazan, konfigürasyon değiştiren operasyonlar).
* `ExecutesArbitraryCode` (Kabuk komutu, dinamik kod çalıştırma).


* Yıkıcı yetkiye sahip işlemler açık bir onay bariyerinden (`ApprovalGate`) geçmeden yürütülemez.



---

## 4. İletişim Hattı (IPC), Çerçeveleme ve Tersine Çağrılar

* **Sınırlı Tampon ile Çerçeveleme (Framing & Bounded Buffer):**
* Standart girdi/çıktı (`stdio`) veya soket üzerinden yapılan satır bazlı mesajlaşmalarda (NDJSON / JSON-RPC), parçalı gelen paketleri birleştiren tamponun (buffer) **kesin bir üst sınırı (max line limit)** olmalıdır.
* Sonsuz veya bozuk bir satır akışı bellek tüketerek (OOM) sistemi çökertecek boyuta ulaşmadan önce protokol hatası üretilerek bağlantı sıfırlanmalıdır.


* **Tersine RPC (Reverse Call / Delegated Tool) Mimarisi:**
* Çekirdek motorun harici istemciden (örneğin editörden veya masaüstü uygulamasından) canlı veri talep ettiği durumlarda:
* İstek tekil bir `RequestId` ile etiketlenir.
* Yanıt, bir `tokio::sync::oneshot` kanalı üzerinden asenkron olarak beklenir.
* Her ters çağrının katı bir zaman aşımı (`timeout`) olmak zorundadır. Karşı taraf yanıt vermezse çekirdek motor kilitlenemez.




* **Girdi/Çıktı Normalizasyonu:**
* Farklı istemcilerden veya sağlayıcılardan gelen heterojen veriler, çekirdeğin sınırında tek bir standart olay/mesaj formatına dönüştürülür. Çekirdek içi karar mekanizmaları üçüncü parti formatları doğrudan tanımaz.



---

## 5. Ağ Dayanıklılığı ve Hata Toleransı

* **Hiyerarşik Zaman Aşımı (Timeout Hierarchy):**
* Ağ işlemlerinde tek bir global zaman aşımı kullanılamaz; aşamalı süreler tanımlanır:
* *Bağlantı Zaman Aşımı (Connect Timeout):* Sunucuya erişim sınırı.
* *İlk Bayt Zaman Aşımı (Time to First Byte):* İlk cevabın gelme sınırı.
* *Akış Boşta Kalma Zaman Aşımı (Stream Idle Timeout):* Token/paket akışı sırasında iki bayt arasındaki azami sessizlik.
* *Toplam Görev Süresi (Deadline):* İşlemin tamamlanması için tanınan nihai sınır.




* **Devre Kesici (Circuit Breaker):**
* Dış servis bağımlılıkları `Closed -> Open -> HalfOpen` durum makinesiyle izlenir.
* `HalfOpen` durumundayken servise yalnızca **tek bir deneme hakkı (probe lease)** tanınır; arka arkaya istek yığılması engellenir.
* Kullanıcı iptalleri veya istemci taraflı hatalar devre kesiciyi tetikleyen "servis hatası" olarak sayılamaz.


* **Geri Çekilme ve Yeniden Deneme (Retry & Jitter):**
* Geçici ağ hatalarında rastgele gecikmeli üstel geri çekilme (`Exponential Backoff with Full Jitter`) uygulanır. Varsa `Retry-After` başlığına riayet edilir.
* Yan etki üretmiş (non-idempotent) işlemler (örneğin kısmen yürütülmüş bir araç çağrısı) körlemesine yeniden oynatılamaz.



---

## 6. Güvenlik, Gizlilik ve Derleme Standartları

* **Hassas Veri Maskeleme (Secret Hygiene):**
* API anahtarları, kimlik bilgileri veya özel jetonlar bellekte özel sarmalayıcılarla (`SecretString`) tutulur.
* Bu tiplerin `Debug`, `Display` veya `Serialize` uygulamaları asla düz metin (plaintext) basamaz; veriyi `***` şeklinde maskeler.
* Yapılandırılmış loglarda (`tracing`), istek gövdeleri veya ham veri paketleri allowlist dışındaysa varsayılan olarak loglanamaz.


* **Katı Derleme Kapıları (Zero-Warning Policy):**
* Tüm üretim kodlarında `#![forbid(unsafe_code)]` bayrağı esnetilemez bir kuraldır. Düşük seviyeli işletim sistemi etkileşimlerinde dahi güvenli sarmalayıcı crate'ler (`nix`, `tokio`) kullanılır.
* Kod tabanı aşağıdaki kontrollerden sıfır uyarı ile geçmek zorundadır:
```bash
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings \
    -D clippy::unwrap_used \
    -D clippy::expect_used \
    -D clippy::panic
cargo test --locked

```

---

### Direktif Özeti

1. **Tipler:** Anlamsal ayrım için Newtype, doğrulama yerine parse (`TryFrom`), float yerine tamsayı/sınırlandırılmış tip.
2. **Durum:** Derleme anında doğrulanan Typestate, tek yazıcılı aktör, drainsiz bitmeyen iptal zinciri.
3. **Süreç:** Bağımsız PGID lideri, tüm süreç ağacına yayılan temizlik sinyali, zombi süreç yasağı.
4. **IPC:** Üst sınırlı satır çerçevelemesi (bounded buffer), zaman aşımlı tersine RPC, kilitlenmeyen mailbox.
5. **Ağ:** Çok katmanlı zaman aşımı, tek kiralı (probe lease) devre kesici, rastgele jitter'lı backoff.
6. **Hijyen:** Maskelenmiş sırlar, sıfır `unsafe`, sıfır `unwrap/panic`, sıfır Clippy uyarısı.