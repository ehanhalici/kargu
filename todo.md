# Açık sorunlar

Not: Yalnız açık sorunlar tutulur. K = kodda gözlenen durum; D = ortam, sağlayıcı veya ölçümle doğrulanması gereken risk. Kapsamlı işler için gerekli sözleşme/test notları eklenmiştir.

### Modül: `tools/diff.el` & `tools/diff/`

1. **[K - Orta] `apply_patch` atomik değildir.**
   - **Dosya / Satır:** `kargu/tools/diff.el:450-456`
   - **Sorun:** Patch planı önceden doğrulansa bile yazma aşamasında `maphash` sırayla dosyaları yazar. Dosyalardan biri yazılırken disk hatası veya kilit oluşursa önceki dosyalar diske yazılmış kalır, rollback tetiklenmez.
   - **Gereken:** Disk/tampon/snapshot için ortak işlem kaydı; son dosyada kaydetme hatası ve insanın kısmi kabulü/reddi için açık atomiklik sözleşmesi. Geri alma, kullanıcının araya giren değişikliklerini silmemeli.
2. **[D - Düşük] `read_file` bellek tüketimi.**
   - **Dosya / Satır:** `kargu/tools/diff.el:147-154, 175-180`
   - **Sorun:** `from_line`/`to_line` aralığı verilmiş olsa dahi dosya önce tamamen arabelleğe okunur ve `split-string` ile tüm satır listesi oluşturulur. Çok büyük dosyalarda (100MB+) gereksiz bellek ve GC yükü oluşturur.

---

### Modül: `tools/search.el` & `tools/webfetch.el`

1. **[K - Orta] `workspace_grep` `rg --max-count` parametresi dosya başına uygulanır.**
   - **Dosya / Satır:** `kargu/tools/search.el:142`
   - **Sorun:** Ripgrep sözdiziminde `--max-count <cap>`, tüm arama için değil, her bir dosya içindeki maksimum eşleşme sayısıdır. 100 dosyalık bir depoda `cap=50` verildiğinde ripgrep 5000 eşleşme üretebilir; her ne kadar Elisp tarafında sonradan budansa da gereksiz disk I/O ve işlemci harcanır.
2. **[D - Yüksek] `webfetch` yalnız `getent ahosts` çözümleyicisine bağlı.**
   - **Dosya / Satır:** `kargu/tools/webfetch.el:91-105`
   - **Sorun:** `getent` veya `ahosts` veritabanı olmayan sistemlerde DNS çözümü yapılamaz. Platform adını sabitlemek yerine mevcut çözümleyici yetenekleri keşfedilmeli; alternatif de asenkron çalışmalı ve curl için doğrulanmış sayısal IP üretmeli.
3. **[D - Yüksek] `webfetch` sayısal adres/CIDR politikasının kapsamı eksik.**
   - **Dosya / Satır:** `kargu/tools/webfetch.el:40-62`
   - **Sorun:** `kargu-webfetch--internal-host-p` IPv6'yı metin önekleriyle denetliyor; genişletilmiş loopback, IPv4-mapped, link-local aralığının diğer önekleri ve NAT64 eşdeğerleri için sayısal normalizasyon/CIDR testleri yok. `getent` bazı alternatif gösterimleri normalize edip mevcut IP sabitlemesiyle engelleyebilir; yalnız yardımcı fonksiyona bakarak uçtan uca SSRF kanıtlanmış sayılmamalı. Çözümleyici çıktısı ve her redirect adımı için çevrimdışı uçtan uca testler gerekiyor.

---

### Modül: `api/` (İstekler, Devre Kesici, Yeniden Deneme)

1. **[D - Orta] Model istek yükünde `max_tokens` ve `max_completion_tokens` çakışması.**
   - **Dosya / Satır:** `kargu/api/request.el:73-74`
   - **Sorun:** Her iki alan da aynı anda yüklenir. OpenAI'ın yeni muhakeme modelleri (o1, o3-mini) veya katı OpenAI uyumlu proxy'ler `max_tokens` alanını görünce isteği reddeder. Benzer şekilde muhakeme modellerinde `temperature` gönderilmesi `400` hatası verebilir.
   - **Gereken:** Token sınırı alanı ve desteklenen sampling parametreleri sağlayıcı biçimi/model metadata'sından tek yerde seçilmeli; model adı regex'i veya sağlayıcı adı listesi eklenmemeli.

---

### Modül: `config/` (Yapılandırma & Anahtarlar)

1. **[K - Orta] `auth-source-search` ana iş parçacığını dondurabilir.**
   - **Dosya / Satır:** `kargu/providers/registry.el:292`, `kargu/config/key.el:134`
   - **Sorun:** GPG şifreli `.authinfo.gpg` kullanan sistemlerde `auth-source-search` pinentry veya disk beklemesi nedeniyle Emacs UI'ını senkron olarak kilitler. `kargu-connected-providers` fonksiyonu bu aramayı katalogdaki 160+ sağlayıcı için döngüde çalıştırır.

---

### Modül: `chat/`, `history/` & `core/` (Oturum İzolasyonu ve Bellek)

1. **[K - Yüksek] Çoklu sohbet tamponlarında Global Değişken Çakışması.**
   - **Dosya / Satır:** `kargu/core/session.el:34-42`, `kargu/history/protocol.el:23`, `kargu/state/store.el:18-31`
   - **Sorun:** `kargu--session`, `kargu--message-history` ve merkezi durum deposu `kargu--state-store` global `defvar` olarak tutulmaktadır. Kullanıcı iki ayrı projede iki ayrı Kargu tamponu açtığında sayaçlar, mesaj geçmişleri, `:mode`, `:status` ve `:busy` bayrakları birbirini ezer. Bir tampondaki işlem diğer tüm tamponların durumunu bozar.
2. **[K - Orta] `kargu-history-char-count` her turda tüm geçmişi JSON'a çevirerek karakter sayar.**
   - **Dosya / Satır:** `kargu/history/compact.el:63-71`
   - **Sorun:** `(+ (length (kargu--json-encode (vconcat kargu--message-history))) ...)` çağrısı her adımda ve her sıkıştırma eşiği kontrolünde tüm mesaj geçmişini baştan sona JSON string'e çevirir. Yüzlerce mesajlık oturumlarda yüksek CPU tüketimi ve gereksiz GC baskısı oluşturur.
3. **[K - Orta] $O(N^2)$ Geçmiş Bellek Ayırma (Cons Allocation).**
   - **Dosya / Satır:** `kargu/history/protocol.el:39`, `kargu/api/response.el:225`
   - **Sorun:** Her mesaj eklendiğinde `(setq kargu--message-history (append kargu--message-history (list msg)))` ile liste baştan kopyalanır. Yüzlerce adımlı uzun oturumlarda gereksiz Garbage Collection (GC) duraksamalarına yol açar.
   - **Gereken:** Kuyruk/karakter önbelleği; repair, compaction, reset ve restore sırasında geçersizleştirme. Doğrudan `nconc` kullanmak, diğer sohbetin paylaştığı liste/snapshot'ı değiştirebileceğinden önce sahiplik ayrılmalı.
4. **[K - Orta] Senkron JSON Oturum Okuma.**
   - **Dosya / Satır:** `kargu/chat/session.el:284-306`
   - **Sorun:** `kargu-session-list`, projedeki tüm `.json` oturum dosyalarını diskten senkron okur ve ayrıştırır. Dosya sayısı arttıkça Emacs donar.
5. **[K - Düşük] Proje İçi `.kargu/sessions/` Dizininde Git İhlali.**
   - **Dosya / Satır:** `kargu/chat/session.el:155-158`
   - **Sorun:** Proje kökünde `.kargu/sessions` varsa oturumlar buraya yazılır. `.kargu/` varsayılan `.gitignore` şablonlarında hariç tutulmadığı için hassas sohbet verileri yanlışlıkla git'e eklenebilir.
   - **Karar:** Yerel depolama açık opt-in olmalı veya uygulamanın ürettiği oturum klasörü Git'ten dışlanmalı. Geçiş/eski oturumları bulma davranışı belirlenmeli; önceden izlenen kullanıcı dosyaları otomatik olarak Git'ten çıkarılmamalı.

---

### Modül: `loop/` & `plan/`

1. **[K - Orta] Durdurulan koşularda dosya tüketim sızıntısı.**
   - **Dosya / Satır:** `kargu/loop/heal.el:50-51`
   - **Sorun:** LSP tanıları beklenirken koşu durdurulursa (`kargu-loop-stop`), `(when (kargu-loop--live-p run) (kargu-diff-consume-file path))` atlanır. Düzenlenen dosya `kargu-diff--changed` tablosunda kalır ve sonraki koşunun bitiş raporuna `:pending-files` olarak sızar.
2. **[K - Orta] Plan durumunun global olması.**
   - **Dosya / Satır:** `kargu/plan/dispatch.el:45, 51`
   - **Sorun:** `kargu-plan--decision-pending` ve `kargu-plan--current-plan` globaldir; farklı projelerdeki plan tamponları birbirinin durumunu ezer.

---

### Modül: `tools/dape/`

1. **[K - Yüksek] Hedef tampon ve canlı bağlantı çalışma alanı sınırına kilitli değil.**
   - **Dosya / Satır:** `kargu/tools/dape/session.el:65-95, 104-112`
   - **Sorun:** `kargu-dape--target-buffer`, `buffer-list` içerisindeki herhangi bir `prog-mode` tamponunu seçer; seçilen tamponun `kargu-permission-project-root` sınırları içinde olduğunu doğrulamaz. Başka bir projeden açık kalmış bir dosya debug hedefi yapılabilir. Benzer şekilde `kargu-dape--raw-connection`, `dape--live-connections` listesinden projeye bakılmaksızın ilk veya durdurulmuş bağlantıyı alır; farklı projelerdeki hata ayıklama oturumları birbirine karışabilir.
   - **Gereken:** `kargu-dape--connection` da doğrudan global Dape bağlantısı seçiyor. Bağlantı, hedef tampon, durma/başlama kancaları ve komutlar aynı yakalanmış proje/bağlantı kimliğinden geçmeli; yalnız önbelleği veya tek getter'ı filtrelemek yeterli değil.

---

### Modül: `tools/lsp/` (LSP & Tanı Araçları)

1. **[K - Düşük] Açık olmayan (visiting edilmemiş) dosyalar için LSP tanıları alınamaz.**
   - **Dosya / Satır:** `kargu/tools/lsp/diagnostics.el:23-24, 95-101`
   - **Sorun:** `kargu-lsp-get-diagnostics`, `(find-buffer-visiting path)` kontrolü yapar; Flymake tanıları yalnız ziyaret edilmiş tamponlardan alınır. Açılmamış dosya veya denetleyici yokluğu için tanılar kullanılamaz. Salt okunur `read_file` dosyayı ziyaret etmez ve bir checker başlatmaz.
   - **Öneri:** Açık olmayan dosyalar için geçici olarak `find-file-noselect` ile arabellek oluşturulup tanıların okunması veya otomatik açılma desteği eklenmelidir.

---

### Yeni inceleme bulguları

- **Dosya yazma ve rollback yolu daraltılmış/kirli tamponları güvenli yönetmiyor.** `diff/stage.el` içindeki `kargu-diff--file-text` ve proposal snapshot'ı yalnız erişilebilir bölgeyi okuyor; tam dosya yerine eksik rollback metni saklanabilir. Otomatik yazma `erase-buffer`/`save-buffer` ile kullanıcının kaydedilmemiş değişikliklerini de kaydediyor ve save-hook dönüşümlerini başarı sonucuyla uzlaştırmıyor. Tampon daraltması/point korunmalı; kullanıcı değişiklikleri, diskte dış değişiklik, kodlama ve başarısız kaydetme için açık işlem/geri alma sözleşmesi ve testler gerekiyor.
- **Tanı raporunun güncelliği ve bekleyen poll sahipliği.** `kargu-lsp-wait-diagnostics`, checker var fakat henüz yeni rapor yayımlamamışsa boş veya iki eşit snapshot'ı yerleşmiş kabul edebiliyor. Belge sürümü/report-generation bariyeri ve çalışmayı başlatan tampon/kökü yakalayan, iptal edilebilir tek-teslimli bir bekleyici gerekiyor. Backend geç yanıtı, buffer kapanması, proje değişimi ve run stop birlikte test edilmeli.
- **Oturum JSON şemasının tümü yüklemeden önce doğrulanmıyor.** `kargu-session-load` mesaj/transkript/sayaç türlerinin tamamını, boyut ve derinlik sınırlarını doğrulamadan tamponu silip restore işlemine başlıyor. Bozuk `transcript` veya `messages` gibi alanlar yarı yüklenmiş sohbet bırakabilir. Önce tüm veriyi doğrulama, sonra atomik yayınlama ve başarısızlıkta eski taslağı/geçmişi koruma gerekiyor.
