## Açık sorunlar


## Önceki kayıtlar için inceleme notları

- Streaming timeout: Güncel kod normal istek timeout'u ile streaming stall/ceiling sınırlarını ayırıyor. Eski logdaki 90 saniyelik curl timeout'u mevcut sürümde canlı sağlayıcıyla yeniden üretilmedi; kayıt açık bırakıldı.
- Yalnız düşünceyle biten yanıt: Döngüde artık ayrı `thought` sınıflandırması var. Eski sağlayıcı örneğinin tekrar doğrulanması gerekiyor.
- Araç hedefinin gösterimi: Güncel başlık kodu dosya/komut/URL gösteriyor ve dosya yolu için test var. Sorun sürerse araç adı, gerçek arguments ve görünen başlık birlikte kaydedilmeli.
- Akışı cümle bazında gösterme: Bu bir davranış/performans işi olarak açık. UI güncellemelerini birleştirmek sağlayıcının gönderdiği ağ verisini azaltmaz; metin/düşünce sırasını ve son parçanın flush edilmesini korumalı.

## 2026-10-18 kod okuması: olası bug / hata karmaşası bulguları

Not: Bu bölüm büyük ölçüde statik okumadan çıktı; yalnız "Test çalıştırma sonuçları" bölümündeki maddeler çalıştırılarak doğrulandı. Her madde için "Kesinlik": **K** = kodda doğrudan görülüyor, **D** = davranış sağlayıcıya/ortama bağlı, doğrulanmalı. Okunmayan alanlar en altta.

### Yüksek öncelik

### Orta öncelik

- **Yeniden denemede kısmi akış UI'da yinelenir.** (K) `kargu/api/http.el:376-382`: akış içinden gelen retry edilebilir hata (`overloaded` vb.) UI'ya kısmi metin delta'ları gittikten sonra yeniden denemeye yol açar; yeni akış aynı metni baştan yazar. Retry öncesi UI'da bu turun çıktısı geri alınmalı/işaretlenmeli.
- **Doom-loop tespiti meşru tekrarları keser.** (K) `kargu/loop/tools.el:45-51`: imza turlar arası global; düzenle→test→düzenle döngüsünde aynı `bash`/`lsp_diagnostics` komutu 3 kez çağrılınca onay ister veya koşuyu durdurur. İmza, araya mutasyon girdiğinde sıfırlanmalı (ürün kararı).
- **`apply_patch` atomik değil ve inceleme kipinde yanlış başarı bildirir.** (D) `kargu/tools/diff.el:447-468`: önce hepsi planlanıyor (iyi), sonra dosyalar sırayla yazılıyor; ortada biri hata verirse öncekiler diske yazılmış kalır. `blocking`/`async` modda `kargu-diff-apply-proposal` callback'siz çağrılıyor (diff/stage.el okunmadı); insan onayından önce "Patch successfully applied" dönebilir ve `delete` yalnız `auto`'da desteklenir. Doğrulanmalı.
- **`process.el`: sınır aşımı sonucu hataya çevirir; belge yanlış.** (K) `kargu/tools/process.el:62-80,90-93`: çıktı kotasında `kill-process` ile süreç öldürülüyor, çıkış kodu sinyal numarası oluyor; `git diff`/`git blame`/`rg` gibi çağıranlar (`tools/git.el:177,360`, `tools/search.el:131`) `:truncated` bayrağına bakmıyor, 4 MB üstü çıktıda içerik yerine "failed (exit 9)" hatası alırsınız. `kargu-process-cancel` belgesi "ve süreç grubu" diyor ama yalnız süreci öldürüyor (alt süreçler kalır). `kargu-process-failure` mesajı çağrının özel timeout'unu değil global `kargu-process-timeout`'u yazar. Kodlama `utf-8` sabit; ikili çıktı bozulur. `kargu-process-run` komut yoksa callback'i senkron çağırıyor, diğer durumda asenkron (tutarsız).
- **Git komutları 30 sn sınırıyla öldürülür.** (K) `kargu/tools/git.el:51-66` varsayılan `kargu-process-timeout` kullanıyor. Hook'lu veya GPG imzalı `git commit` (pinentry) bu sürede bitmeyebilir, öldürülünce `.git/index.lock` kalabilir. `git_branch list` ve `git_stash list` `kargu-loop-mutating-tools`'ta olduğu için ask/plan kipinde de kullanılamaz (salt okunur eylemler için de yazma kapısı). Boş depoda `unstage` yedeği (`reset HEAD`) da başarısız olur; `git rm --cached` gerekir.
- **Webfetch IPv6 adreslerini normalize etmiyor.** `kargu/tools/webfetch.el` özel ağ denetimini metin önekleriyle yapıyor. IPv4-mapped IPv6 (`::ffff:127.0.0.1`, `::ffff:7f00:1`), genişletilmiş loopback (`0:0:0:0:0:0:0:1`), link-local aralığının `fe80:` dışındaki gösterimleri ve NAT64 aralıkları ayrıca ele alınmalı. Hostname veya DNS sonucu önce doğrulanmış sayısal adrese dönüştürülmeli, ardından IPv4/IPv6 CIDR politikası uygulanmalı; alternatif gösterimlerin eşdeğerliği ve yönlendirmelerin her adımındaki adres sabitlemesi için test gerekiyor.
- **Varsayılan dizin dışlaması meşru kaynak adlarını da gizleyebilir.** Ortak `kargu-fs-skip-dirs` listesi ve `rg` globları `src/build/`, `src/vendor/` gibi adları da dışlıyor. Hangi dışlamaların proje `.gitignore` dosyasına bırakılacağı ve hangilerinin kullanıcı tarafından ayarlanacağı netleştirilmeli.
- **Proje becerilerinin güven politikası belirsiz.** Klonlanan depodaki beceri açıklamaları ve seçilen becerilerin talimatları otomatik keşfediliyor. Kaynak güveni, kullanıcı onayı ve proje/kullanıcı becerileri arasındaki öncelik için açık bir politika gerekiyor; metadata'yı kaçışlamak tek başına anlamsal prompt enjeksiyonunu engellemez.
- **`json.el` kodlama belirsizlikleri.** (K) `kargu/json.el:196-243`: boş liste `null` olarak kodlanır (`[]` olmalı); örn. `required: []` veya boş `tools`. Bu `git.el` şemalarında `("properties" . ())` ile `{}` yerine `null` gönderebilir (sağlayıcıya bağlı, D). `kargu--object-p` `((a b) (c d))` gibi liste listesini nesne sayar.
- **İstek yükü sağlayıcıya göre bozulabilir.** (D) `kargu/api/request.el:101-105`: `max_tokens` ve `max_completion_tokens` birlikte gönderiliyor; OpenAI o-seri/yeni modeller `max_tokens`'ı reddeder, katı uçlar bilinmeyen alanı reddeder. `temperature` muhakeme modellerinde (yalnız 1) 400 verir.
- **`read_file` kayıtları.** (K) `kargu/tools/diff.el:161-188`: dosya sonundaki `\n` yüzünden `split-string` fazladan boş satır sayıyor (10 satırlık dosya "of 11" gösterir, `11 | ` satırı). Disk içeriği okunuyor; kaydedilmemiş (inceleme bekleyen) tampon değişiklikleri görünmez. Pencere verilince (`from/to`) sınır yok, yalnız genel `kargu-tool-output-limit`.
- **`diff.el` yükleme zamanı yapılandırması.** (D) `kargu/tools/diff.el:570-575`: `kargu--config-plist` dosya yüklendiğinde okunuyor; yapılandırma sonra yüklenirse `review-mode` yok sayılır; `mode-str` string değilse `string-trim` hata verir.

### Düşük öncelik / temizlik

- `kargu/api/retry.el`: 429 (kota bitti/`insufficient_quota`) de yeniden deneniyor; HTTP düzeyi (`kargu-api-retry-max`) × döngü düzeyi (`kargu-loop-upstream-retries`) çarpılıyor, toplam bekleme belirsiz uzun olabilir. `Retry-After` HTTP-tarih biçimi desteklenmiyor.
- `kargu/api/http.el`: akış stall `delete-process` sonrası `plz` `:else` yolunun nasıl tetiklendiği doğrulanmalı (`kargu-http--fail-request` bayrağa göre ayrıştırıyor, güvenli görünüyor).
- `kargu/loop/compact.el` + `history/compact.el`: koşu başına tek sıkıştırma; ikinci taşmada kullanıcıya soruluyor. `COMPACTION_*` ile başlayan kullanıcı iletisi kuyruktan sessizce atılır.
- `kargu/loop.el:279`: `kargu-diff-changed-files` `fboundp` korumasız, komşu çağrılar korumalı (tutarsız).

### Ürün/iş kararı gerektirenler (koda dokunmadan not)

- Eglot yoksa "bash ile ara" yönlendirmesi var ama `bash` yalnız agent kipinde açık (`kargu-loop-mutating-tools`); ask/plan kipinde LSP olmayan bir dilde yapısal arama araçsız kalır. Salt okunur bir `bash` alt kümesi (veya `workspace_grep`/`find_files` öne çıkarma) kararı.
- `kargu-permission-confirm-bash nil` ve `strict-mode nil` birlikte "korumasız" kip; belgelensin veya birleştirilsin.
- Üç özdeş çağrı kuralı (doom-loop) düzenle/test döngüsünü de keser; eşik/sıfırlama politikası.
- Eğer `describing.md`/`skills.md` tasarımı Eglot-sonrası durumu anlatıyorsa güncel olup olmadığı kontrol edilmeli (okunmadı).

### Test çalıştırma sonuçları

Komut: `emacs -Q --batch --eval "(package-initialize)" -l tests/run-tests.el` → **380 test, 373 geçti, 7 başarısız**.

- **Gerçek bug (doğrulandı): `kargu-process-cancel` süreç grubunu öldürmüyor.** `tests/test-process.el:95` `kargu-process-cancel-terminates-child-process-group-test` başarısız: `sh -c "sleep 30 & ...; wait"` iptalden sonra 2 sn içinde callback gelmiyor; torun süreç boruyu açık tuttuğu için sentinel tetiklenmiyor. Etkisi: bash `kill pN`/stop/cancel yalnız kabuğu öldürür, alt süreçler (dev sunucusu vb.) öksüz kalır, iş "running" görünür ve sonucu teslim edilmez (`tools/bash/jobs.el`, `tools/process.el:90-93`). Çözüm: `setsid`/`start-process` ile ayrı süreç grubu ve `(signal-process (- pid) 'TERM)` sonra `KILL`; callback'in iptalde garanti teslimi.
- **Test kırılganlığı (ortamsal): 6 `kargu-permission-*` testi** (`within-project`, `assert-within-project`, `file-tools-rejection`, `search-tools-rejection`, `bash-command-external-paths-rejection`, `bash-command-redirection-rejection`). Bu makinede `/tmp/.git` var; `/tmp/kargu-scratch-*` kökü `project-current` ile `/tmp/` olarak bulunuyor ve `/tmp` "proje içi" sayılıyor. Testler `/tmp`'nin VCS deposu içinde olmadığını varsayıyor. Çözüm: `tests/test-helpers.el` `kargu-test--isolate` içinde proje kökünü açıkça (`kargu-permission--override-root`) sabitle veya temp dizini VCS'siz bir yere kur. (Ayrıca üretim tarafı: `/tmp/.git` gibi üst dizin deposu, proje kökünü beklenenden geniş yapabilir; geniş kök = geniş yazma izni.)

### Ek bulgular (ikinci okuma turu)

#### Yüksek / orta

- **`jobs.el`: öldürme/iptal yalnız kabuğu öldürür** (yukarıdaki test). Ek: önplan işin callback'i iptalde hiç gelmeyebilir; yalnız tek önplan süreç izleniyor (`kargu-bash--active-async-proc`); kuyruk çıktısı (4 MB'a kadar) kısaltılmadan modele aktarılmadan önce bellekte tutulur; biten arka plan iş tamponları yalnız 20'den fazlasında temizlenir.
- **`diff/stage.el`: `kargu-diff--apply-auto` tüm tamponu silip yeniden yazar, sonra `save-buffer`.** (K) Kullanıcının kaydedilmemiş düzenlemeleri de sessizce kaydedilir; `before-save-hook` (formatlayıcı, boşluk temizleme) içeriği değiştirir ama araç "APPLIED" der; "file changed on disk" ve "dizin yok, oluşturulsun mu?" soruları `y-or-n-p` ile bloklar veya hata verir. `write_file` yeni dizine yazarsa `make-directory` yok: snapshot itilmiş, tampon kirli kalır (D). `find-file-noselect` tamponları sonsuza kadar açık tutar, major-mode/eglot kancalarını tetikler, büyük dosyada soru sorar.
- **`diff/review.el`: reddedilen inceleme boş (no-op) snapshot bırakır;** `:created-new` ile sonraki `kargu-diff-rollback` aynı yolda artık kullanıcıya ait olabilecek dosyayı siler. `kargu-diff--ediff-quit` oturumu A tamponuyla eşler; kullanıcının aynı tampondaki kendi ediff'ini kapatması oturumu bitirebilir (kenar durum).
- **`diff/track.el`: snapshot yığınları (`kargu-diff--snapshots`) koşu başına sıfırlanmaz** (yalnız `run-modified-files` sıfırlanır). "İlk durum" rollback'i, Emacs oturumundaki ilk ajan düzenlemesinin durumudur; koşular arasında kullanıcının elle yaptığı düzenlemeleri siler. Her düzenleme için tam dosya içeriği tutulur (sınırsız bellek). Açık olmayan dosyalarda rollback `write-region` ile varsayılan kodlama kullanır (CRLF/kodlama bozulabilir). `kargu-diff-changed-files` global (koşu/proje başına değil).
- **`lsp/context.el`: `kargu-lsp--request` `:valid-p` `buffer-chars-modified-tick` karşılaştırır;** tamponda herhangi bir değişiklik (ajanın kendi düzenlemesi, kullanıcı yazısı) uçuştaki isteği "Connection or document changed" ile iptal eder. `kargu-lsp-request-timeout` iki kez uygulanır (jsonrpc `:timeout` + görev zamanlayıcısı). `kargu-lsp--field` alist/plist belirsizliği kırılgan.
- **`lsp/diagnostics.el`: yanlış "Verification passed" riski.** (K) Ayar süresi (3 sn) dolunca anlık görüntü boşsa (polls≥1, snapshot nil, meşgul değil) LSP henüz yayınlamadan "settled" ilan edilir. `kargu-lsp-get-diagnostics` dosya açık değilse "no diagnostics available (file is not open...)" metni döner; `heal.el` bunu temiz metin sayar. Denetleyici yoksa `kargu-lsp-wait-diagnostics` anında döner. `kargu-lsp--flymake-diags` `:character 1` sabit (sütun kaybı). `string-prefix-p root (expand-file-name fn)` symlink/truename uyumsuzluğunda dosyaları kaçırır. Yalnız ziyaret edilmiş tamponlarda tanı var; açılmamış dosya "temiz" ile ayırt edilemez.
- **`lsp/symbols.el`: `kargu-lsp--splice-symbol-content` satır aralığı kullanır;** CRLF/`\r`, çok baytlı karakter, dosya sonu satırı belirsiz; `string-trim-right new-content "[\r\n]+"` kasıtlı boş satırları siler. `kargu-lsp--symbol-named-p` büyük/küçük harfe duyarsız (`Foo` ve `foo` belirsiz/yanlış eşleşir). Sembol aralığı LSP/imenu anlık görüntüsünden gelir, arada düzenleme olursa bayat; `end-of-defun` imenu yedeği Lisp dışı modlarda yanlış aralık verir. `kargu-lsp-edit-symbol` callback yolunda `kargu-lsp-get-file-symbols` callback'i içindeki hatalar yakalanmaz. `kargu-lsp-find-definition` callback'siz çağrıda `kargu-lsp--ws-symbols`'ı senkron çağırır (D).
- **`lsp/register.el`:** `lsp_diagnostics` ve `list` türü araçlar senkron çalışır (callback yok); `kargu-lsp--tool-aliases` `outline` gibi genel adlar içerir (çakışma riski).
- **`config/toml.el` (K):** (a) Yalnız `api/apikey/model/models` bölüm anahtarları okunur, diğerleri sessizce atılır; (b) sayı/boolean değerler dize olarak döner (`max_tokens = 100` → `"100"`); (c) `"""` çok satırlı dizeler, `\uXXXX` kaçışı, satır içi tablolar desteklenmiyor (sessizce yanlış okunur); (d) çok satırlı dizide yorum satırı (`# "x"`) içindeki tırnaklı metin öğe sayılır; (e) bölüm adı büyük/küçük harf korunur ama `kargu--api-base`/`kargu--resolve-api-key` `downcase` ile arar → `[provider.OpenAI]` bulunamaz; `kargu--provider-plist` ise `name`'i olduğu gibi arar (tutarsız); (f) yinelenen bölüm sessizce birleşir; (g) ayrıştırma hatası ilgili satırı belirtmez, bozuk dosya yarım yapılandırma verir.
- **`config/key.el`:** `kargu--expand-env-refs` tanımsız `${VAR}` için nil döner ve sessizce env/auth-source'a düşer (kullanıcı yanlış yazımı fark etmez, uyarı yok). `kargu--auth-source-api-key` `auth-source-search` GPG/pinentry ile sohbet sırasında bloklayabilir ve her çağrıda yeniden sorgular (önbellek yok; her istekte). `kargu--api-key-placeholder-p` `...` ile biten gerçek anahtarı (nadir) placeholder sayar.
- **Onay sonrası thunk yeniden çalıştırma sözleşmesi.** `permission/policy.el` onaydan sonra araç gövdesini baştan çalıştırıyor. Bir araç ikinci onayı ilk yan etkiden sonra isterse önceki adımlar tekrarlanabilir. Mevcut "bütün onayları yan etkilerden önce iste" sözleşmesinin çok adımlı araçlarda denetlenmesi veya replay yerine açık devam adımlarına taşınması gerekiyor.

### Üçüncü okuma turu: Kod tabanının tamamı (kapsamlı tarama ve tespit edilen tüm olası sorunlar)

Kod tabanındaki tüm dosyalar (`ui/`, `async.el`, `api/`, `providers/`, `chat/`, `plan/`, `state/`, `languages/`, `tools/dape/`, `core/`, `contract/`) baştan sona taranmış ve aşağıdaki sorunlar tespit edilmiştir:

#### 1. Kritik Hatalar (Çökme, Deadlock, Veri Kaybı)
#### 2. Yüksek / Orta Öncelikli Sorunlar
- **`providers/registry.el:286`: 160+ sağlayıcı için senkron auth-source araması (Emacs Donması).** `kargu-connected-providers`, katalogdaki 160'tan fazla sağlayıcının her biri için döngü içinde `(auth-source-search :host host :max 1)` çalıştırır. Kullanıcının `auth-sources` yapılandırmasında GPG şifreli dosya varsa Emacs UI iş parçacığı saniyelerce donar veya pinentry pencereleriyle kilitlenir.
- **Native wire biçiminde çok modlu içerik dönüşümü eksik.** `kargu-api--text-blocks` text bloklarını ve cache işaretlerini koruyor, fakat OpenAI `image_url` gibi blokları native Messages `image/source` biçimine çevirmiyor. Görsel/dosya içerik tipleri için ayrı adaptör ve round-trip testleri gerekiyor.
- **`chat/session.el:284-306`: Senkron büyük JSON okuma donması.** `kargu-session-list`, dizindeki tüm `.json` oturum dosyalarını diskten tek tek senkron okur ve `json-read` ile ayrıştırır. Çok sayıda veya büyük oturum dosyası olduğunda Emacs'i kilitler.
- **`plan/dispatch.el:45, 51`: Çoklu oturumlarda global durum çakışması.** `kargu-plan--decision-pending` ve `kargu-plan--current-plan` değişkenleri globaldir (buffer-local değildir). Farklı projelerde veya tamponlarda aynı anda plan çalıştırıldığında durumlar birbirini ezer.

#### 3. Dil Profilleri ve Araç Zinciri Sorunları (`languages/`)

#### 4. Çekirdek ve Sözleşme Sorunları (`core/`, `contract/`)
#### 5. Protokol, Geçmiş ve Devre Kesici Derin Analizi (`history/`, `circuit.el`, `loop/`, `git.el`)
- **`loop/heal.el:50`: İptal Edilen Koşularda Dosya Tüketim Sızıntısı (Unconsumed Changed Files).** `kargu--loop-verify-next` içinde LSP tanıları beklenirken kullanıcı koşuyu durdurursa (`kargu-loop-stop`), callback içindeki `(when (kargu-loop--live-p run) (kargu-diff-consume-file path) ...)` bloğu atlanır. Düzenlenen dosya `kargu-diff-changed-files` listesinden silinmez ve bir sonraki koşuya bayat dosya uyarısı olarak sarkar.
- **`loop/machine.el:207, 362-368`: Sınırsız Düşünce Döngüsü (Unbounded Reasoning Loop).** Model yalnızca düşünce (reasoning/thinking) üretip yanıt veya araç çağrısı vermediğinde `thought` olayı tetiklenir ve `kargu-loop--on-thought` çalışır. Boş yanıtlarda (`empty-retries`) ve üst akış hatalarında (`upstream-retries`) sayaç bulunmasına rağmen `thought` için hiçbir retry sayacı veya bütçe tanımlanmamıştır; model her adımda yalnızca düşünce verirse gereksiz token tüketimiyle döngüde kalır.
- **`tools/git.el:314-322`: `git_stash` İndeks Belirtememe ve Yanlış Stash Uçurma.** `kargu-git-stash` komutunda `pop` ve `drop` eylemleri için herhangi bir stash indeksi (örn. `stash@{1}`) desteği yoktur. Sabit olarak en üstteki (`stash@{0}`) yığın öğesini siler veya açar; bu durum kullanıcının daha önce kaydettiği kendi stash'lerini kazara ezmesine veya kaybetmesine yol açar.
#### 6. Ağ, Web Erişimi, Beceriler ve Otomatik Tamamlama (`tools/webfetch.el`, `tools/skill.el`, `chat/complete.el`, `chat/transcript.el`)
- **`tools/webfetch.el:94-100`: macOS / BSD / Minimal Linux Ortamlarında `getent` Yokluğu Nedeniyle Webfetch Çökmesi (K).** SSRF koruması için IP çözümlemesi yalnızca `getent ahosts <host>` komutuna bağlanmıştır. macOS, FreeBSD, OpenBSD veya minimal Docker konteynerlerinde (Alpine) `getent` komutu bulunmaz (`exit 127`). Kodda `nslookup`, `host`, `dig` veya Emacs dahili `dns-lookup-host` gibi hiçbir yedek çözümleyici tanımlanmadığından, bu sistemlerde `webfetch` tüm URL isteklerinde istisnasız `%100` başarısız olur (`ERROR: webfetch cannot resolve the host: getent not found`).
- **Büyük projelerde dosya tamamlamasının senkron taraması.** `chat/complete.el` seçili proje için `project-files` veya sınırlı dosya yürüyüşünü tamamlamanın içinde çalıştırıyor. Büyük/uzak depolarda önbelleğin arka planda yenilenmesi ve güncellik bildirimi tasarlanmalı; aday sayısını kısıtlamak `project-files` listesinin oluşturulma maliyetini sınırlamıyor.

#### 7. İstem Montajı, Önbellekleme ve Bellek Performansı (`prompt.el`, `history/protocol.el`, `providers/registry.el`)
- **`prompt.el:340-365`: Debug Modunda Her Turda Tüm Proje İskeletinin Kullanıcı Mesajına Eklenmesi (K).** `kargu-prompt-debug-message`, her kullanıcı mesajına eklenen `<system-reminder>` içine her turda senkron olarak `(kargu-lsp-build-skeleton)` ile oluşturulan tam proje sembol iskeletini gömer. Büyük projelerde 10-20 bin karakteri bulan bu iskelet, 10 turluk bir debug oturumunda her turda tekrar tekrar kullanıcı mesajı olarak geçmişe eklenerek yüzbinlerce gereksiz jeton (token) tüketimine ve context window'un erkenden dolmasına yol açar.
- **`prompt.el:321-325`: `kargu-prompt-system-key` Eksikliği Nedeniyle Talimat ve Beceri Değişikliklerinin Fark Edilmemesi (K).** Sistem isteminin güncelliğini denetleyen `kargu-prompt-system-key`, yalnızca mod, model, eglot ve kompaksiyon durumunu kontrol eder. Oturum sırasında projedeki `AGENTS.md`, `CLAUDE.md` veya `SKILL.md` dosyaları değiştirilse dahi anahtar değişmediği için sistem istemi yenilenmez (`kargu--history-system-current-p` t döner); model güncellenen talimatları veya yeni eklenen becerileri göremez.
- **`prompt.el:50-52` & `providers/registry.el:58-77`: Tanımsız `:prompt-for` Kuralları ve Model Taban İstem Dosyası Eksikliği.** Kod dokümantasyonunda belirtilen modele özgü sistem istemi dosyası (`prompt/*.txt`) mimarisi fiilen çalışmamaktadır; çünkü `providers/catalog.el` içindeki hiçbir model/sağlayıcı tanımında `:prompt-for` anahtarı yer almaz ve `kargu/prompt/` dizininde `default.txt` dışında hiçbir dosya (`anthropic.txt`, `openai.txt`, vb.) bulunmaz.
- **`history/protocol.el:39`: $O(N^2)$ Geçmiş Bellek Ayırma (Cons Allocation).** `kargu--history-add` fonksiyonu her mesaj eklendiğinde `(setq kargu--message-history (append kargu--message-history (list msg)))` çağrısıyla tüm geçmiş listesini baştan kopyalar. Yüzlerce araç çağrısı ve adımdan oluşan uzun oturumlarda veya `/goal` kurgularında $O(N^2)$ liste tahsisi nedeniyle yoğun Emacs Garbage Collection (GC) duraksamaları ve bellek şişmesi meydana gelir.

#### 8. Çoklu Oturum İzolasyonu, Kullanıcı Giriş Kaybı ve Arayüz Kırılganlığı (`chat.el`, `core/session.el`, `chat/tune.el`, `tools/deps.el`)
- **`core/session.el:34-43, 124-148`: Global `kargu--session` ve `kargu--message-history` Nedeniyle Çoklu Tampon Çakışması (K).** `kargu--session` ve mesaj geçmişi global değişkenlerde tutulur. Kullanıcı iki ayrı projede iki ayrı Kargu sohbet tamponu açtığında sayaçlar birbirine karışır; bir tampondaki `kargu-session-reset` diğer projedeki tüm sohbet geçmişini ve devre kesici durumunu sessizce sıfırlar.
- **`chat/session.el:155-158`: Proje İçi `.kargu/sessions/` Dizininde Hassas Veri Sızıntısı ve Git İhlali.** Eğer proje kökünde `.kargu/sessions` dizini varsa, oturum dosyaları merkezi `~/.config/` yerine doğrudan proje köküne yazılır. Kargu'nun varsayılan `.gitignore` şablonunda veya depolarında `.kargu/` hariç tutulmadığından, tüm sohbet geçmişi, API yanıtları ve özel prompt verileri git'e commit edilebilir hale gelir.
#### 10. JSON Ayrıştırma/Kodlama, Dosya Sistemi Gezinmesi ve Dizin Dışlama Hataları (`json.el`, `fs.el`)
- **`json.el:216-223, 122-130`: Boş JSON Nesnesi (`{}`) Çözülüp Geri Kodlandığında `null`'a Dönüşmesi ve API 400 Hataları (K).**
  - `kargu--json-decode`, boş bir JSON nesnesi olan `"{}"` metnini Emacs Lisp'in boş listesi `nil` olarak çözer.
  - Ancak `kargu--json-encode`, `(null object)` durumunda doğrudan `"null"` string'ini döner (yalnızca `:json-empty-object` veya `:empty-object` sembollerini `{}` yapar).
  - Sonuç: Boş bir nesne (`{}`) decode edilip tekrar encode edildiğinde `"null"` olarak serileştirilir. OpenAI ve Anthropic API'lerinde `arguments: {}` veya `parameters: {}` bekleyen uçlar, `null` gönderildiğinde `400 Bad Request: expected object, got null` hatası vererek isteği reddeder.
- **`json.el:41-51`: İki Boyutlu Dizi / Liste Listelerinin Hatalı Şekilde JSON Nesnesi (Alist) Olarak Kodlanması (K).**
  - `kargu--object-p` yüklemi, `cl-every` ile her elemanın `(consp cell)` ve `(or (stringp (car cell)) (symbolp (car cell)))` olduğunu denetler.
  - Dizi içinde 2 elemanlı string alt listeleri bulunan matris veya komut parametreleri (örneğin `'(("git" "status") ("git" "diff"))` veya `'(("header1" "value1") ("header2" "value2"))`), `("git" "status")` hücresi `(cons "git" (cons "status" nil))` şeklinde olduğundan bu denetimden geçer ve bir JSON nesnesi sayılır.
  - `kargu--json-encode` bu listeyi `[["git", "status"], ["git", "diff"]]` dizisi yerine `{"git": ["status"], "git": ["diff"]}` nesnesi olarak bozuk kodlar.
#### 11. Planlama, Oturum Durumu ve Dape Yaşam Döngüsü Detayları (`plan/dispatch.el`, `tools/dape/session.el`, `tools/dape/execution.el`, `state/hooks.el`)

#### 12. Dil Belirleme Eksiklikleri ve UI Onay Motoru Kilitlenmeleri (`languages/core.el`, `languages/*.el`, `ui/confirm.el`)

#### 13. Arama ve Git Araçlarındaki Yol/Regex Uyuşmazlıkları (`tools/search.el`, `tools/git.el`)
- **`tools/search.el:140-141`: `rg --max-count` Parametresinin Dosya Başına Sınır Olarak Çalışması (K).**
  - `kargu-search--grep-rg`, çağrıya `--max-count <cap>` argümanı ekler.
  - Ripgrep spesifikasyonunda `--max-count`, arama genelinde toplam eşleşme sayısını değil, **her bir dosya içindeki** maksimum eşleşme sayısını sınırlar.
  - Yüzlerce dosyanın bulunduğu bir depoda `cap` 50 olarak verilse dahi, her dosyadan 50'şer eşleşme toplanarak binlerce satırlık çıktı üretilir ve süreç gereksiz CPU/bellek tüketir.
- **`tools/git.el:86-103`: Git Porcelain Çıktısında Tırnaklı (Quoted) Yolların ve Çakışmaların (Conflicts) Yanlış İşlenmesi (K).**
  - `kargu-git--parse-porcelain-status`, satırın ilk 3 karakterinden sonrasını `(substring line 3)` ile doğrudan alır. Boşluklu veya UTF-8/Unicode karakterli dosya adlarında git yolu çift tırnak (`"path with spaces"`) içine alır; tırnaklar temizlenmediği için sonraki `git_stage` veya `git_unstage` çağrıları `fatal: pathspec did not match any files` hatasıyla başarısız olur.
  - Ayrıca `UU` (unmerged/conflict) durumundaki çakışan dosyalar `staged` ve `unstaged` listelerine dağıtılır; ayrıştırıcıda çakışma (`:conflict`) sınıflandırması bulunmadığından model merge çakışmasını fark edemez.

#### 14. Formal Protokol İhlalleri ve Geçmiş Onarım Tutarsızlıkları (`history/repair.el`, `proof/KarguProtocol.tla`)

#### 15. Bash Yetki ve Güvenlik Denetleyicisi Atlatma Açıkları (`permission/bash.el`, `permission/guards.el`)
- **`permission/guards.el:74-83`: Üst Dizinlerdeki `.git` Nedeniyle Çalışma Alanı Sınırının `/tmp` veya Ev Dizinine Taşması (K).**
  - `kargu-permission-context-root`, kök dizini belirlerken `(project-current)` kullanır. `project.el`, mevcut dizinden yukarı doğru tarama yaparak en yakın VCS deposunu bulur.
  - Eğer `/tmp` veya kullanıcının ev dizini (`~`) içinde geçmişten kalma bir `.git` deposu varsa, `/tmp/scratch` içinde çalışan bir işlem için `project-current` kökü `/tmp/` veya `~` olarak tespit eder.
  - Bu durumda `kargu-permission-within-project-p` tüm `/tmp/` veya tüm ev dizinini "proje içi" kabul eder; Kargu'nun dosya kısıtlama kuralları tamamen işlevsiz hale gelerek sisteme geniş yazma izni verir.

#### Debug araçlarının kapsamını genişletme

- İşlev/veri/koşullu breakpoint, exception filtreleri, değişken atama, bellek ve disassembly için adaptör capability'sine bağlı şemalar eklenmeli. Ham, sınırsız DAP isteği yerine ayrı doğrulanan araçlar; hedefi değiştiren işlemlerde açık onay ve callback testleri gerekiyor.
- Dape oturum sahipliği proje köküne bağlanmalı; başka projede açılmış global oturum, seçilen projenin debug oturumu sayılmamalı. Kaynak tamponu seçimindeki diğer-proje fallback'i de bu sınırla birlikte ele alınmalı.
- Kargu ön kontrolü asenkron olsa da Dape'nin bazı adapter `ensure`/`fn` adımları senkron dış komut/Eglot isteği çalıştırıyor. Tüm dillerde kilitlenmeme için adaptör başlatma katmanının ayrıca tasarlanması gerekiyor; kurulu Dape paketine geçici yama yapılmamalı.

#### Yeni inceleme: ertelenmiş sohbet ve plan başlangıcının sahipliği

- **Geciken debug başlangıcı yanlış sohbete gönderim yapabiliyor.** `kargu-chat--send-prepared` içindeki devam, başlangıçtaki sohbeti saklamak yerine callback anında `kargu-chat--buffer` ve `kargu-chat-show` ile yeniden seçiyor. Çevrimdışı mock ile doğrulandı: A tamponundan başlatılan debug hazırlığının devamında tampon çözümleyici B'yi döndürünce `submit` B içinde çalışıyor. Başlangıç sohbeti, proje, sağlayıcı/model ve iptal nesli birlikte sahiplenilmeli; başka sohbet açılması, başlangıç tamponunun kapanması veya beklerken yeni koşu başlaması yanlış projeye gönderim yapmamalı. Global geçmiş/oturum izolasyonu maddesiyle birlikte ele alınmalı.
- **Başlangıç reddedilince planın yeniden onaylanması engelleniyor.** `kargu-plan-approve`, `kargu-chat-prompt` başarıyla koşu başlatmadan önce `kargu-plan--take-decision` çağırıyor ve onaylandı mesajını yazıyor. Çevrimdışı mock ile doğrulandı: gönderim `user-error` verince `decision-pending` nil kalıyor; aynı planı yeniden onaylamak mümkün olmuyor. Sohbetin gönderim kabulü, senkron ret ve ertelenmiş debug hazırlığı için açık bir sonuç sözleşmesi gerekiyor. Regresyon: ret sonrası plan yeniden denenebilsin; gerçekten başlayan koşu ise çift tıklamayla ikinci kez gönderilmesin.

#### Kabuk izolasyonu için kalan kapsam

- Kabuk metni denetimi işletim sistemi sandbox'ı değildir. Build/test scriptleri, Git hook ve yapılandırmaları, bilinmeyen yürütücüler veya dolaylı dosya erişimleri metinden tam çıkarılamaz. Gerçek izolasyon için Linux/bubblewrap zorunluluğu, isteğe bağlı destek veya çapraz platform kapsamı kararlaştırılmalı; seçilen politika araç açıklamaları ve bağımlılık kontrolüne de yansıtılmalı. Sözdizimi denetimini bir OS güvenlik sınırı olarak sunmamak gerekiyor.

- **Elisp profilinin doğrulama komutları gerçek dosya/test yüklemiyor.** `languages/elisp.el` içindeki `batch-byte-compile` dosya argümanı olmadan, `check-parens` boş batch tamponunda, ERT ise test dosyası yüklemeden öneriliyor. Profil proje runner'ını tanımalı; genel derleme/lint komutu gerçekten hedef dosyaları kontrol etmeli ve test altyapısı yokken başarı varsaymamalı.
