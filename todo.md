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

### Modül: `api/` (İstekler, Devre Kesici, Yeniden Deneme)

1. **[D - Orta] Sampling desteğinin muhakeme ayarına bağlı koşulları temsil edilmiyor.**
   - **Dosya:** `kargu/api/parameters.el`, `kargu/api/catalog.el`
   - **Sorun:** Statik `supported_parameters` listesi bir alanı destekli saysa bile belirli reasoning-effort/thinking ayarlarıyla birlikte desteklemeyebilir. [Resmi OpenAI uyumluluk notu](https://developers.openai.com/api/docs/guides/deployment-checklist) buna örnek veriyor. Bilinmeyen OpenAI modelleri için sampling zaten ihtiyatlı biçimde atlanıyor; ancak açık metadata ile etkinleştirildiğinde koşul denetimi yok.
   - **Gereken:** Model/biçim capability kaydına koşullu parametre desteği eklenmeli ve etkin reasoning ayarıyla birlikte tek yerde yorumlanmalı. Model adı regex'i veya sağlayıcı adı listesi kullanılmamalı; `none`, kapalı ve belirtilmemiş effort ayrımı korunmalı.

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
   - **Gereken:** Kip hazırlığı/restore geri çağrıları da proje, oturum ve seçim nesline bağlı olmalı; başarısız plan başlangıcında eski `debug` kipine asenkron dönüş yeni bir sohbete sızmamalı.
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

---

### Modül: `loop/` & `plan/`

1. **[K - Orta] Durdurulan koşularda dosya tüketim sızıntısı.**
   - **Dosya / Satır:** `kargu/loop/heal.el:50-51`
   - **Sorun:** LSP tanıları beklenirken koşu durdurulursa (`kargu-loop-stop`), `(when (kargu-loop--live-p run) (kargu-diff-consume-file path))` atlanır. Düzenlenen dosya `kargu-diff--changed` tablosunda kalır ve sonraki koşunun bitiş raporuna `:pending-files` olarak sızar.

---

### Modül: `tools/dape/`

1. **[K - Yüksek] Asenkron Dape bekleyicileri ve global komutlar tam sahiplik taşımıyor.**
   - **Dosyalar:** `kargu/tools/dape/session.el`, `execution.el`, `commands.el`
   - **Sorun:** Başlatma/durma bekleyicileri global kancaları dinliyor; başka bir bağlantının olayı beklemeyi bitirebilir. `debug_quit` bütün Dape oturumlarını kapatıyor ve `debug_disconnect` global Dape tamponlarını temizliyor.
   - **Gereken:** Bekleyici, komut ve rapor aynı yakalanmış proje/oturum/bağlantı kimliğini kullanmalı. Yabancı stop/start/exit olayları, bağlantı değişimi ve kökün yeniden atanması birlikte test edilmeli. Global Dape UI temizliği proje dışı oturumları etkilememeli.

---

### Modül: `tools/lsp/` (LSP & Tanı Araçları)

1. **[K - Düşük] Açık olmayan (visiting edilmemiş) dosyalar için LSP tanıları alınamaz.**
   - **Dosya / Satır:** `kargu/tools/lsp/diagnostics.el:23-24, 95-101`
   - **Sorun:** `kargu-lsp-get-diagnostics`, `(find-buffer-visiting path)` kontrolü yapar; Flymake tanıları yalnız ziyaret edilmiş tamponlardan alınır. Açılmamış dosya veya denetleyici yokluğu için tanılar kullanılamaz. Salt okunur `read_file` dosyayı ziyaret etmez ve bir checker başlatmaz.
   - **Öneri:** Açık olmayan dosyalar için geçici olarak `find-file-noselect` ile arabellek oluşturulup tanıların okunması veya otomatik açılma desteği eklenmelidir.

---

### Yeni inceleme bulguları

- **Dosya yazma ve rollback yolu daraltılmış/kirli tamponları güvenli yönetmiyor.** `diff/stage.el` içindeki `kargu-diff--file-text` ve proposal snapshot'ı yalnız erişilebilir bölgeyi okuyor; tam dosya yerine eksik rollback metni saklanabilir. Otomatik yazma `erase-buffer`/`save-buffer` ile kullanıcının kaydedilmemiş değişikliklerini de kaydediyor ve save-hook dönüşümlerini başarı sonucuyla uzlaştırmıyor. Tampon daraltması/point korunmalı; kullanıcı değişiklikleri, diskte dış değişiklik, kodlama ve başarısız kaydetme için açık işlem/geri alma sözleşmesi ve testler gerekiyor.
- **Doğrulanmış oturumun yüklenmesi henüz atomik bir yayınlama işlemi değil.** Girdi şeması, boyut/derinlik ve kimlik artık sohbet değiştirilmeden doğrulanıyor; ancak geçerli kayıt yüklenirken UI/footer çizimi veya kip hazırlığı başarısız olursa önceki taslak, geçmiş, sayaç ve seçim için ortak geri alma yok. Özellikle daraltılmış sohbet tamponu, render hatası ve asenkron `debug` kip hazırlığı sırasında iptal/proje değişimi test edilmeli. Oturum/state sahipliği ayrıldıktan sonra önceden hazırlanmış görünüm ve tek işlem sınırı gerekiyor.
- **[D - Orta] Süreç iptali / stderr kapanışı stres altında yeniden incelenmeli.** 2026-10-19 tam ERT ve eşzamanlı derleme turunda `kargu-process-cancel-terminates-child-process-group-test` iptal callback'ini 2 saniyede alamadı; `kargu-process-deadline-covers-stderr-drain-test` ise 50 ms deadline yerine erken başarılı sonuç gördü. Sonraki tam turla eşzamanlı 100 tekrar (300 test) geçti; ancak özellikle erken başarılı stderr kapanışının nedeni henüz ayrıştırılmadı. Ana süreç/stderr durumları ve dış sinyaller kontrollü stres testinde kaydedilmeli, `accept-process-output` ile yalnız ana süreci bekleyen test yolu da karşılaştırılmalı. Süreleri körlemesine uzatarak kapatılmamalı.
- **Dape yaşam döngüsü yardımcısı ana iş parçacığında bekleyebiliyor.** Yerel Dape 0.27.1'de `dape-kill` / `dape-disconnect-quit` yolu `dape--shutdown` üzerinden `accept-process-output nil 0.2` ve `jsonrpc-shutdown` çağırıyor. Kargu'nun dış API'yi callback ile başlatması bu iç beklemeyi asenkron yapmıyor. Bağlantı sahipliğini koruyan, olay tabanlı sonlandırma/ayrılma sözleşmesi gerekiyor; Dape'nin bütün tamponlarını veya diğer projelerin bağlantılarını temizleyen sarmalayıcılar kullanılmamalı.
- **Sürüm bildirmeyen Eglot sunucularında otomatik tanı doğrulaması tamamlanamıyor.** Güvenli belge/rapor bariyeri bu sunucuların push önbelleğini taze saymaz; bekleme timeout/unavailable ile biter. Capability tabanlı pull/istek-cevap doğrulaması veya eşdeğer bir backend güncellik sözleşmesi gerekiyor. Çözüm, eski ya da sürümsüz bir push'u düzenlenmiş belgenin temiz olduğuna kanıt saymamalı.
- **Dape kaynak alıntıları büyük dosyalarda Emacs'i meşgul edebilir.** `context.el` içindeki `kargu-dape--source-line` ve `--source-snippet`, tek satır veya birkaç satır için bile proje içindeki dosyanın tamamını senkron okuyor. Snippet ayrıca hedef satıra kadar Lisp döngüsüyle ilerliyor. Büyük/üretilmiş dosyalar için byte/süre bütçesi, açık unavailable/truncation sonucu ve arayüzü kilitlemeyen sınırlı okuma stratejisi gerekiyor. Çözüm, eksik okunmuş metni tam kaynak veya güncel canlı tampon görüntüsü diye sunmamalı; dosya büyümesi, uzun satır ve daraltılmış/kirli tamponlar test edilmeli.
