# Açık sorunlar

Not: Bulgular statik incelemeye dayanır; doğrulanamayan veya geçersiz çıkan kayıtlar kaldırılır. Yalnız açık sorunlar tutulur.

### Modül: `tools/process.el` & `tools/bash/`
3. **[K - Orta] Standard Error (stderr) ile stdout ayrıştırılmadan birleştiriliyor.**
   - **Dosya / Satır:** `kargu/tools/process.el:120-122`, `159`
   - **Sorun:** stdout ve stderr aynı arabelleğe yazılıyor. Yapılandırılmış çıktı bekleyen tüketicilerde (örn. `git status`, `rg --json`) komut satırından gelen stderr uyarıları (örn. `warning: LF will be replaced by CRLF`) veriyi bozar.
4. **[D - Düşük] Büyük çıktılarda artımlı filtre maliyeti.**
   - **Dosya / Satır:** `kargu/tools/process.el:76`
   - **Sorun:** Her gelen parçada `(position-bytes (point-max))` çağrılıyor; çok baytlı büyük arabelleklerde bu hesaplama parçalı akışta işlemci yükü oluşturabilir.

---

### Modül: `tools/diff.el` & `tools/diff/`
2. **[K - Orta] `apply_patch` atomik değildir.**
   - **Dosya / Satır:** `kargu/tools/diff.el:450-456`
   - **Sorun:** Patch planı önceden doğrulansa bile yazma aşamasında `maphash` sırayla dosyaları yazar. Dosyalardan biri yazılırken disk hatası veya kilit oluşursa önceki dosyalar diske yazılmış kalır, rollback tetiklenmez.
5. **[D - Düşük] `read_file` bellek tüketimi.**
   - **Dosya / Satır:** `kargu/tools/diff.el:147-154, 175-180`
   - **Sorun:** `from_line`/`to_line` aralığı verilmiş olsa dahi dosya önce tamamen arabelleğe okunur ve `split-string` ile tüm satır listesi oluşturulur. Çok büyük dosyalarda (100MB+) gereksiz bellek ve GC yükü oluşturur.
---

### Modül: `tools/search.el` & `tools/webfetch.el`
1. **[K - Orta] `workspace_grep` `rg --max-count` parametresi dosya başına uygulanır.**
   - **Dosya / Satır:** `kargu/tools/search.el:142`
   - **Sorun:** Ripgrep sözdiziminde `--max-count <cap>`, tüm arama için değil, her bir dosya içindeki maksimum eşleşme sayısıdır. 100 dosyalık bir depoda `cap=50` verildiğinde ripgrep 5000 eşleşme üretebilir; her ne kadar Elisp tarafında sonradan budansa da gereksiz disk I/O ve işlemci harcanır.
2. **[K - Yüksek] `webfetch` macOS, BSD ve Alpine konteynerlerinde `getent` yokluğu nedeniyle çalışmaz.**
   - **Dosya / Satır:** `kargu/tools/webfetch.el:91-105`
   - **Sorun:** IP çözümlemesi yalnızca harici `getent ahosts <host>` komutuna bağlanmıştır. macOS, FreeBSD veya minimal Docker (Alpine) ortamlarında `getent` bulunmaz (`exit 127`). `nslookup`, `host`, `dig` veya Emacs dahili `dns-lookup-host` alternatifi tanımlanmadığından bu sistemlerde webfetch %100 başarısız olur.
3. **[K - Yüksek] `webfetch` SSRF adres normalizasyonu eksikliği (IPv6 ve alternatif IPv4 formatları).**
   - **Dosya / Satır:** `kargu/tools/webfetch.el:40-62`
   - **Sorun:** `kargu-webfetch--internal-host-p` denetimi yalnızca `fe80:`, `fc`, `fd` öneklerini ve `localhost`, `::1` gibi sabitleri arar. `::ffff:127.0.0.1` (IPv4-mapped IPv6), `0:0:0:0:0:0:0:1` (açık IPv6 loopback), tamsayı IPv4 (`2130706433`), eksik noktalı IPv4 (`127.1`) veya `0` adresleri bu kontrolden geçerek `nil` döner (meşru sayılır) ve curl bu adreslere yerel bağlantı kurar.

---

### Modül: `json.el` & `fs.el`
1. **[K - Yüksek] Boş JSON Nesnesi (`{}`) decode/encode döngüsünde `null`'a dönüşür.**
   - **Dosya / Satır:** `kargu/json.el:216-223`
   - **Sorun:** Boş bir JSON nesnesi `"{}"` decode edildiğinde Elisp `nil` döner. Ancak `kargu--json-encode`, `(null object)` gördüğünde doğrudan `"null"` üretir. OpenAI ve Anthropic API'lerinde `arguments: {}` bekleyen araç çağrılarında `null` gitmesi `400 Bad Request` hatasına neden olur.
2. **[K - Yüksek] 2 boyutlu listeler JSON nesnesi (Alist) olarak kodlanır.**
   - **Dosya / Satır:** `kargu/json.el:41-51, 231-238`
   - **Sorun:** `kargu--object-p`, her elemanın `(consp cell)` ve `(car cell)`'in string/symbol olduğunu denetler. İki elemanlı string listelerinden oluşan matrisler (örn. `'(("a" "b") ("c" "d"))`), `("a" . ("b" . nil))` yapısında olduğu için nesne sanılır ve `{"a": ["b"], "c": ["d"]}` olarak hatalı kodlanır.
3. **[D - Orta] Varsayılan dizin dışlaması meşru kod dizinlerini gizleyebilir.**
   - **Dosya / Satır:** `kargu/fs.el:31-38`
   - **Sorun:** `kargu-fs-skip-dirs` listesi `build`, `vendor`, `dist`, `out` gibi dizinleri koşulsuz dışlar. Projenin kaynak kodları `src/vendor/` veya `src/build/` altında yer alıyorsa bu dosyalar aramalarda ve listelemelerde görünmez.

---

### Modül: `api/` (İstekler, Devre Kesici, Yeniden Deneme)
1. **[D - Orta] Model istek yükünde `max_tokens` ve `max_completion_tokens` çakışması.**
   - **Dosya / Satır:** `kargu/api/request.el:73-74`
   - **Sorun:** Her iki alan da aynı anda yüklenir. OpenAI'ın yeni muhakeme modelleri (o1, o3-mini) veya katı OpenAI uyumlu proxy'ler `max_tokens` alanını görünce isteği reddeder. Benzer şekilde muhakeme modellerinde `temperature` gönderilmesi `400` hatası verebilir.
2. **[K - Düşük] Devre kesici (Circuit Breaker) çift başarı kaydı.**
   - **Dosya / Satır:** `kargu/api/http.el` & `kargu/loop/machine.el:395, 405, 415, 422`
   - **Sorun:** HTTP 200 yanıtı alındığında HTTP katmanı `kargu-circuit-record-success` çağırır; döngü makinesinde `on-tools`, `on-thought`, `on-answer` da tekrar çağırır. Half-open durumunda sayaçlar tutarsız ilerleyebilir.
4. **[K - Düşük] `func-arity` kırılganlığı.**
   - **Dosya / Satır:** `kargu/loop/machine.el:158`, `kargu/api/tools.el:323`
   - **Sorun:** `&optional` veya `&rest` içeren lambda fonksiyonlarında `(cdr (func-arity cb))` beklenen 1 değerini vermeyebilir, delta iletimi yanlış kola sapabilir.

---

### Modül: `config/` (Yapılandırma & Anahtarlar)
1. **[K - Orta] `config/toml.el` eksik TOML spesifikasyon desteği.**
   - **Dosya / Satır:** `kargu/config/toml.el:51-68, 148-156`
   - **Sorun:** (a) Sayılar ve boolean değerler dize (`"100"`) olarak ayrıştırılır; (b) Yalnızca `[provider.X]` veya üst düzey atamalar okunur, diğer tablolar `skip` edilir; (c) `"""` çok satırlı dizeler veya satır içi tablolar desteklenmez.
2. **[K - Orta] `auth-source-search` ana iş parçacığını dondurabilir.**
   - **Dosya / Satır:** `kargu/providers/registry.el:292`, `kargu/config/key.el:134`
   - **Sorun:** GPG şifreli `.authinfo.gpg` kullanan sistemlerde `auth-source-search` pinentry veya disk beklemesi nedeniyle Emacs UI'ını senkron olarak kilitler. `kargu-connected-providers` fonksiyonu bu aramayı katalogdaki 160+ sağlayıcı için döngüde çalıştırır.
---

### Modül: `chat/`, `history/` & `core/` (Oturum İzolasyonu ve Bellek)
1. **[K - Yüksek] Çoklu sohbet tamponlarında Global Değişken Çakışması.**
   - **Dosya / Satır:** `kargu/core/session.el:34-42`, `kargu/history/protocol.el:23`, `kargu/state/store.el:18-31`
   - **Sorun:** `kargu--session`, `kargu--message-history` ve merkezi durum deposu `kargu--state-store` global `defvar` olarak tutulmaktadır. Kullanıcı iki ayrı projede iki ayrı Kargu tamponu açtığında sayaçlar, mesaj geçmişleri, `:mode`, `:status` ve `:busy` bayrakları birbirini ezer. Bir tampondaki işlem diğer tüm tamponların durumunu bozar.
3. **[K - Orta] `kargu-history-char-count` her turda tüm geçmişi JSON'a çevirerek karakter sayar.**
   - **Dosya / Satır:** `kargu/history/compact.el:63-71`
   - **Sorun:** `(+ (length (kargu--json-encode (vconcat kargu--message-history))) ...)` çağrısı her adımda ve her sıkıştırma eşiği kontrolünde tüm mesaj geçmişini baştan sona JSON string'e çevirir. Yüzlerce mesajlık oturumlarda yüksek CPU tüketimi ve gereksiz GC baskısı oluşturur.
4. **[K - Orta] $O(N^2)$ Geçmiş Bellek Ayırma (Cons Allocation).**
   - **Dosya / Satır:** `kargu/history/protocol.el:39`, `kargu/api/response.el:225`
   - **Sorun:** Her mesaj eklendiğinde `(setq kargu--message-history (append kargu--message-history (list msg)))` ile liste baştan kopyalanır. Yüzlerce adımlı uzun oturumlarda gereksiz Garbage Collection (GC) duraksamalarına yol açar.
5. **[K - Orta] Senkron JSON Oturum Okuma.**
   - **Dosya / Satır:** `kargu/chat/session.el:284-306`
   - **Sorun:** `kargu-session-list`, projedeki tüm `.json` oturum dosyalarını diskten senkron okur ve ayrıştırır. Dosya sayısı arttıkça Emacs donar.
6. **[K - Düşük] Proje İçi `.kargu/sessions/` Dizininde Git İhlali.**
   - **Dosya / Satır:** `kargu/chat/session.el:155-158`
   - **Sorun:** Proje kökünde `.kargu/sessions` varsa oturumlar buraya yazılır. `.kargu/` varsayılan `.gitignore` şablonlarında hariç tutulmadığı için hassas sohbet verileri yanlışlıkla git'e eklenebilir.
---

### Modül: `loop/` & `plan/`
2. **[K - Orta] Durdurulan koşularda dosya tüketim sızıntısı.**
   - **Dosya / Satır:** `kargu/loop/heal.el:50-51`
   - **Sorun:** LSP tanıları beklenirken koşu durdurulursa (`kargu-loop-stop`), `(when (kargu-loop--live-p run) (kargu-diff-consume-file path))` atlanır. Düzenlenen dosya `kargu-diff--changed` tablosunda kalır ve sonraki koşunun bitiş raporuna `:pending-files` olarak sızar.
3. **[K - Orta] Plan durumunun global olması.**
   - **Dosya / Satır:** `kargu/plan/dispatch.el:45, 51`
   - **Sorun:** `kargu-plan--decision-pending` ve `kargu-plan--current-plan` globaldir; farklı projelerdeki plan tamponları birbirinin durumunu ezer.
7. **[K - Yüksek] `run` kaydında `:mode` tutulmaz; global `kargu--state-store` okunur ve tek bir koşu tüm Emacs kiplerini kilitler.**
   - **Dosya / Satır:** `kargu/loop.el:224-232, 106-108, 122-144`, `kargu/state/transitions.el:39-40`
   - **Sorun:** (a) `kargu-loop--new-run` oluşturulurken `:mode` kaydı tutulmaz; araç izinleri (`kargu-loop--gate-tool`) doğrudan merkezi `(kargu-state-mode)`'u sorgular. (b) `kargu-state-set-mode`, `(kargu-loop-running-p)` aktif olduğu sürece `user-error` fırlatarak kip değişimini Emacs genelinde engeller. Bir projede arka planda uzun bir agent koşusu varken diğer projelerde `ask`/`plan`/`debug` kiplerine geçilemez.
   - **Öneri:** `run` nesnesine immutable `:mode` alanı eklenmeli, araç denetimleri bu alandan yapılmalı ve kip kilitleri proje/oturum düzeyine indirgenmelidir.

---

### Modül: `tools/git.el`
---

### Modül: `tools/dape/`
1. **[K - Yüksek] Hedef tampon ve canlı bağlantı çalışma alanı sınırına kilitli değil.**
   - **Dosya / Satır:** `kargu/tools/dape/session.el:65-95, 104-112`
   - **Sorun:** `kargu-dape--target-buffer`, `buffer-list` içerisindeki herhangi bir `prog-mode` tamponunu seçer; seçilen tamponun `kargu-permission-project-root` sınırları içinde olduğunu doğrulamaz. Başka bir projeden açık kalmış bir dosya debug hedefi yapılabilir. Benzer şekilde `kargu-dape--raw-connection`, `dape--live-connections` listesinden projeye bakılmaksızın ilk veya durdurulmuş bağlantıyı alır; farklı projelerdeki hata ayıklama oturumları birbirine karışabilir.
2. **[K - Orta] `kargu-dape--verified` küreseldir; çoklu projede doğrulama durumunu ezer.**
   - **Dosya / Satır:** `kargu/tools/dape/preflight.el:23, 64-80, 126`
   - **Sorun:** Dape adaptör doğrulama sonucu (`kargu-dape--verified`) tek bir global `defvar`'da saklanır ve `(list (kargu-permission-project-root) ...)` anahtarıyla kıyaslanır. Proje A'da debug kipi başarıyla doğrulandıktan sonra Proje B'de debug oturumu açılırsa veya doğrulanırsa `kargu-dape--verified` ezilir. Tekrar Proje A'ya dönüldüğünde `(equal kargu-dape--verified (kargu-dape--config-key config))` eşleşmeyerek `"Debugger project or configuration changed; select debug again"` hatası verir ve kullanıcıyı gereksiz onay döngüsüne sokar.
   - **Öneri:** Doğrulama durumu proje kök dizinine göre indekslenen bir hash tablosunda tutulmalıdır.

---

### Modül: `languages/` (Dil Profilleri)
---

### Modül: `tools/lsp/` (LSP & Tanı Araçları)
1. **[K - Orta] `buffer-chars-modified-tick` uçuştaki istekleri iptal eder.**
   - **Dosya / Satır:** `kargu/tools/lsp/context.el:284-293`
   - **Sorun:** Tamponda herhangi bir karakter değiştiğinde (`tick` değişimi), uçuştaki LSP isteği geçersiz sayılır. Hızlı ardışık işlemlerde tanı/sembol istekleri düşebilir.
3. **[K - Düşük] Açık olmayan (visiting edilmemiş) dosyalar için LSP tanıları alınamaz.**
   - **Dosya / Satır:** `kargu/tools/lsp/diagnostics.el:23-24, 95-101`
   - **Sorun:** `kargu-lsp-get-diagnostics`, `(find-buffer-visiting path)` kontrolü yapar; `kargu-lsp--flymake-diags` Flymake tanılarını yalnızca dosya Emacs'te canlı bir arabellekte açıksa (`(buffer-live-p buffer)`) alabilir. Arabelleğe alınmamış bir dosya için `lsp_diagnostics` çağrıldığında `"%s: no diagnostics available (file is not open in Emacs; open it or use read_file first)"` mesajı döner ve tanı denetimi yapılamaz.
   - **Öneri:** Açık olmayan dosyalar için geçici olarak `find-file-noselect` ile arabellek oluşturulup tanıların okunması veya otomatik açılma desteği eklenmelidir.

---

### Yeni inceleme bulguları

- **Araç çıktı arşivinde toplam bellek sınırı yok.** `kargu/api/tools.el` büyük sonuçları `*kargu-output-*` tamponlarında tutuyor. Sayı ve toplam karakter kotası, eski çıktılar için tahliye politikası ve kotayı aşan tek çıktının kısmen saklandığını doğru anlatan bir sonuç sözleşmesi gerekiyor. Kullanıcının düzenlediği veya dosyaya dönüştürdüğü tamponlar otomatik silinmemeli.
- **Dosya yazma ve rollback yolu daraltılmış/kirli tamponları güvenli yönetmiyor.** `diff/stage.el` içindeki `kargu-diff--file-text` ve proposal snapshot'ı yalnız erişilebilir bölgeyi okuyor; tam dosya yerine eksik rollback metni saklanabilir. Otomatik yazma `erase-buffer`/`save-buffer` ile kullanıcının kaydedilmemiş değişikliklerini de kaydediyor ve save-hook dönüşümlerini başarı sonucuyla uzlaştırmıyor. Tampon daraltması/point korunmalı; kullanıcı değişiklikleri, diskte dış değişiklik, kodlama ve başarısız kaydetme için açık işlem/geri alma sözleşmesi ve testler gerekiyor.
