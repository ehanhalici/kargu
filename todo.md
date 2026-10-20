# Açık işler

Yalnız açık kayıtlar tutulur; kapanan ve yanlış pozitif kayıtlar silinir.
2026-10-19 incelemesi: 698/698 ERT geçti. Yeşil testler kapsanmayan hataları
çürütmez. K = kod yolu doğrulandı; Y = kontrollü yeniden üretildi;
D = ortam/ölçüm kanıtı gerekiyor. Kimlikler yeniden numaralanmaz.
P1 güvenlik/doğruluk, P2 yanıt verebilirlik/performans önceliğidir.

## Doğrulanmış hatalar — düzeltme sırası

### DAPE-04 · P1 · K — Yaşam döngüsü global temizlik ve senkron shutdown kullanıyor

- **Yer/kanıt:** `kargu/tools/dape/commands.el` quit/disconnect global Dape yardımcılarını çağırıyor. Dape 0.27.1 `dape-quit` bütün kök bağlantıları, `dape-disconnect-quit` global tamponları temizliyor; `dape--shutdown` `accept-process-output nil 0.2` ve `jsonrpc-shutdown` ile bekliyor.
- **Beklenen/gerçek:** Yalnız yakalanmış bağlantı, UI'ı bekletmeden yönetilmeli; yabancı oturum/UI etkileniyor ve callback sarmalı iç beklemeyi kaldırmıyor.
- **Yeniden üretme/kapanış:** İki proje/adapter, yabancı seçim, kaybolan bağlantı, geç/çift cevap, Stop/deadline. Sahipli olay tabanlı sonlandırma/ayrılma; yabancı kaynaklara dokunulmamalı.

### DIFF-01 · P1 · K — Daraltılmış/kirli tampon ve rollback sözleşmesi güvenli değil

- **Yer/kanıt:** `kargu/tools/diff/stage.el`, `kargu-diff--file-text` ve proposal erişilebilir `buffer-string` alıyor. Auto yazma `erase-buffer`/`save-buffer` kullanıyor; save-hook dönüşümleri sonuçla uzlaştırılmıyor.
- **Beklenen/gerçek:** Snapshot tam dosya olmalı, kullanıcı değişiklikleri/point/narrowing korunmalı; eksik snapshot ve örtük kaydetme mümkün.
- **Yeniden üretme/kapanış:** Daraltılmış/kirli tampon, dış disk değişikliği, kodlama, save-hook dönüşümü ve kaydetme hatası. Kullanıcı değişikliğini silmeyen yazma/geri alma sözleşmesi gerekli.

### DIFF-02 · P1 · K — Çok dosyalı patch için ortak işlem geri alma yok

- **Yer/kanıt:** `kargu/tools/diff.el`, `kargu-diff--commit-patch`/`--stage-patch-file`: dosyalar ayrı uygulanıyor; hata batch sonucuna yazılıyor, önceki başarılı dosyalar otomatik geri alınmıyor.
- **Beklenen/gerçek:** Disk/tampon/snapshot ve insanın kısmi kabulü açısından işlem sınırı açık olmalı; yalnız ön doğrulama atomiklik sağlamıyor.
- **Yeniden üretme/kapanış:** Son dosyada disk/kaydetme hatası ve kısmi insan kabulü/reddi; araya giren kullanıcı değişiklikleri korunarak geri alma/sonuç sözleşmesi test edilmeli.
- **Bağımlılık:** DIFF-01.

### CHAT-01 · P1 · K — Canlı seçim ve uygulama durumu oturumlara ayrılmamış

- **Yer/kanıt:** `state/store.el` seçim/toplamları ve canlı provider/model override'ları hâlâ global. `kargu-chat-new` bağımsız sohbet açıyor; restore ortak seçimi değiştiriyor. Kimlik, sayaç ve tek geçmiş kuyruğu artık buffer-owned `kargu-session` kaydında; ikinci chat message kopyası kaldırıldı.
- **Beklenen/gerçek:** Sohbetler kendi seçim verisini korumalı; ortak değerler ezilebiliyor. Geçmiş/sayaç ayrımı seçim izolasyonunu tamamlamaz. Global busy/aktif koşu tek-koşu sözleşmesidir, tek başına hata değildir.
- **Yeniden üretme/kapanış:** Aynı/farklı projede iki sohbet, farklı geçmiş/sayaç, reset/restore ve geç kip hazırlığı callback'leri; eski callback yeni oturum/seçime yazmamalı, tek aktif koşu korunmalı.

### CHAT-02 · P1 · K — Geçerli oturum restore işlemi atomik değil

- **Yer/kanıt:** `kargu/chat/session.el`, `kargu-session-load`: doğrulamadan sonra tampon silinip değişken/sayaç/seçim değişiyor. Render hatasına ortak rollback yok; kip hatası yakalanıp yutuluyor.
- **Beklenen/gerçek:** Başarısız restore eski taslak, geçmiş, sayaç ve seçimi bırakmalı; kısmi yeni durum yayınlanabiliyor.
- **Yeniden üretme/kapanış:** Geçerli kayıt + daraltılmış sohbet, render/footer hatası, debug hazırlığında iptal/kök değişimi. Hazırlanmış görünüm ve tek yayınlama/geri alma sınırı gerekli.
- **Bağımlılık:** CHAT-01.

### CONFIG-01 · P2 · K — Anahtar keşfinde senkron kimlik deposu erişimi

- **Yer/kanıt:** `kargu/providers/registry.el`, `kargu-connected-providers`; `kargu/config/key.el`, `kargu--auth-source-api-key` doğrudan `auth-source-search` ve secret fonksiyonunu çağırıyor. Üst öncelikli anahtar varsa bu yola girilmeyebilir; her sağlayıcıda GPG açıldığı iddiası doğru değil.
- **Beklenen/gerçek:** Sağlayıcı keşfi UI'da pinentry/disk beklememeli; alt katman senkron bekleyebilir. Gerçek gecikme ortama bağlı.
- **Yeniden üretme/kapanış:** Kontrollü geciken kimlik deposu/secret, iptal, öncelik/keyless ve gizli veri sızıntısı testleri; listeleme örtük toplu kilit açmamalı.

### PERF-01 · P2 · K — Satır aralığında bile read_file tam dosyayı kopyalıyor

- **Yer/kanıt:** `kargu/files.el`, `kargu-file--resolve-read-target` tam metni alıyor; `kargu-file-read` tüm metne `split-string` uyguluyor. Algoritma doğrulandı; belirli 100 MB eşiği/donma süresi ölçülmedi. Okuma modülünün diff'ten ayrılması bu performans işini kapatmaz.
- **Beklenen/gerçek:** Küçük aralık tüm satır listesini gerektirmemeli; maliyet dosya boyutuyla büyüyor.
- **Yeniden üretme/kapanış:** Büyük dosyada dar aralık, uzun satır, büyüme, EOF, boş dosya, UTF-8 ve kirli/daraltılmış tampon; ölçümlü bellek/çıktı bütçesi ve unavailable/truncation sözleşmesi.

### PERF-04 · P2 · K — Oturum listesi bütün kayıtları senkron ayrıştırıyor

- **Yer/kanıt:** `kargu/chat/session.el`, `kargu-session-list`: directory-files + döngüde `kargu-session-storage-read`. Tek dosya boyut sınırı toplam maliyeti sınırlamıyor.
- **Beklenen/gerçek:** Çok kayıt UI'ı meşgul etmemeli; bütün JSON içerikleri çağıranın iş parçacığında okunuyor. Gecikme ölçümü gerekli.
- **Yeniden üretme/kapanış:** Çok kayıt, bozuk/büyük kayıt, iptal, proje değişimi ve sıralama; asenkron listeleme veya metadata indeksi, eski sonuçlar yayınlanmamalı.

### PERF-05 · P2 · K — Sınırlı Dape kaynak disk işlemleri hâlâ senkron

- **Yer/kanıt:** `kargu/tools/dape/context.el` yol/metadata/sınırlı içerik okumasını çağıranın iş parçacığında yapıyor. 64 KiB disk / 65.536 canlı karakter sınırı mevcut; sınırsız büyük dosya okuma iddiası artık geçerli değil.
- **Beklenen/gerçek:** Yavaş/askıda yerel mount UI'ı bekletmemeli; byte sınırı süre garantisi değil.
- **Yeniden üretme/kapanış:** Kontrollü geciken yol/metadata/okuma, iptal, kaynak tampon nesli değişimi. Disk işi iptal edilebilir yardımcı süreçte; callback proje/oturum/koşu ve kaynak nesline bağlı, canlı tampon güncelliği korunmalı.

### CHAT-03 · P1 · Y — Oturum seçimi/restore başka projenin varsayılan adlı sohbetini eziyor

- **Yer/kanıt:** `kargu/chat/session.el`, `kargu-chat-sessions` ve `kargu-session-load`: hedef tampon sohbet kipinde değilse veya verilmediyse sabit `kargu-chat-buffer-name` (`*kargu-chat*`) aranıyor/oluşturuluyor; tamponun hangi projeye ait olduğu (`kargu-chat--project-root`) karşılaştırılmıyor. Yeniden üretildi: proje A `*kargu-chat*` tamponunda `A-PRIVATE-TRANSCRIPT` varken B proje kod tamponundan `kargu-chat-sessions` çalıştırıldı; sonuçta A tamponu `kargu-chat--project-root` olarak B'yi aldı, A metni silindi, B oturumu yazıldı. Yönlendirme için `kargu-chat-find-buffer` (`chat/routing.el`) zaten var ama bu yolda kullanılmıyor.
- **Beklenen/gerçek:** Restore, çağıran projenin kendi sohbetine (yoksa yeni tampona) yazmalı; başka projenin sohbet metni/taslağı/oturum kimliği silinmemeli. Gerçekte kullanıcı çıktısı kayboluyor ve tampon yanlış projeye bağlanıyor.
- **Yeniden üretme/kapanış:** İki proje, A varsayılan adlı sohbeti tutarken B'den seçim/restore; `kargu-session-load` hedefsiz çağrısı; ilgili sohbet yoksa yeni tampon, varsa yalnız eşleşen kök. A'nın transcript/geçmiş/session-id değerleri değişmemeli (regresyon testi: yukarıdaki senaryo).
- **Bağımlılık:** CHAT-01/CHAT-02 ile ortak sohbet sahipliği; CHAT-02'nin atomik restore sınırı bu düzeltmeden önce hedef tamponu seçmeli.

### PERM-01 · P1 · Y — Tanımsız kabuk değişkeni proje sınırı doğrulamasını ve risk uyarısını atlatıyor

- **Yer/kanıt:** `kargu/permission/bash.el`, `kargu-permission--expand-environment` ve `kargu-permission-command-risks`: `getenv` nil dönen `$ADI` olduğu gibi bırakılıyor; doğrulayıcı `$ADI/etc/passwd` belirtecini `/` ile başlamadığı için göreli sayıyor. Risk düzenli ifadesi yalnız `$(`, `${`, `` ` ``, `$'`, `$"` yakalıyor; düz `$ADI` yakalanmıyor. Yeniden üretildi (güçlü kip, proje kökü geçici dizin): `cat $NOPE_VAR/etc/passwd` → `validate-command` hatasız geçti, `command-risks` = nil. Karşılaştırma: `cat /etc/passwd` reddedildi, `${NOPE_VAR}` biçimi risk uyarısı verdi. Komut `bash -c` ile çalıştığı için (`tools/bash/jobs.el`) tanımsız değişken boş genişler ve `cat /etc/passwd` olur.
- **Beklenen/gerçek:** Emacs ortamında bulunmayan/çalışma anında kabukta farklı olabilecek değişken, doğrulamada sınır dışı yol olarak reddedilmeli veya risk olarak onay metnine yazılmalı. Gerçekte uyarısız geçiyor; `kargu-permission-confirm-bash` nil iken (belgelenmiş vazgeçme) komut hiç sorulmadan çalışıyor, varsayılanda ise onay iletişiminde WARNING görünmüyor.
- **Yeniden üretme/kapanış:** `$VAR`, `"$VAR"`, `$VAR$VAR2`, kök dışı yola ekleme, `$PWD`/`$OLDPWD` (kabuk-yerel), tanımlı ve tanımsız değişken ayrımı, `confirm-bash` t/nil. Regresyon: tanımsız değişken içeren yol ya reddedilir ya risk listesine girer; tanımlı basit değişken davranışı ve `${...}` uyarısı korunur.

### TOOL-01 · P2 · Y — `read_file` aralık argümanları yanlış yorumlanıyor / sessizce yok sayılıyor

- **Yer/kanıt:** `kargu/tools/diff.el` içindeki `read_file` yürütücüsü ve `kargu/files.el` içindeki `kargu-file-read` (`kargu-diff-read-file` uyumluluk alias'ı). 3000 satırlık dosyayla yeniden üretildi: (a) yalnız `limit=3` → `lines 1-3000` (limit `from` olmadan yok sayılıyor: `(and from limit ...)`); (b) `offset=0, limit=2` → `lines 1-1`, yani 1 satır (`to = f + n - 1` hesabı `from` 1'e sıkıştırılınca kayıyor); (c) `from_line="abc"` → 1'den başlıyor, `to_line="abc"` → dosya sonuna kadar (`kargu-to-int` nil dönünce varsayılana düşülüyor), hata verilmiyor.
- **Beklenen/gerçek:** Şema `limit`'i "from_line'dan itibaren en fazla satır" olarak tanımlıyor; yalnız `limit` ilk N satırı, `offset=0` ile `limit=N` tam N satırı döndürmeli; bozuk tam sayı reddedilmeli. Gerçekte model yanlış/çok geniş aralık alıyor (çıktı yalnız global `kargu-tool-output-limit` ile kısılıyor) ve girdi hatasını fark etmiyor.
- **Yeniden üretme/kapanış:** limit tek başına, offset 0/1 + limit, `from_line` 0/negatif/ondalık/sayısal olmayan, `to_line` sayısal olmayan/0/dosya sonunu aşan, `limit` 0/negatif, boş dosya. Beklenen aralık ve hata metinleri test edilmeli; alias (`offset`) sözleşmesi tek yerde belgelenmeli.
- **Bağımlılık:** PERF-01 ile aynı fonksiyon; aralık normalizasyonu ayrı çözülmeli.

### DAPE-05 · P2 · K — Port üzerinden adapter oluşturma hâlâ senkron bekliyor

- **Yer/kanıt:** `kargu/tools/dape/launch.el` son sahiplik kontrolünden sonra Dape 0.27.1 `dape--create-connection` çağırıyor. Dape'nin `port` yolu `make-network-process` bağlantısını 30 denemelik döngüde `sleep-for 0.100` ile bekliyor; uzak dizin yolunda ayrıca `sleep-for 0.300` var. Bu kod yolu doğrulandı; gerçek süre/platform davranışı ölçülmedi.
- **Beklenen/gerçek:** Adapter bağlantısı UI'ı bekletmeden, iptal/deadline ve proje/oturum/koşu sahipliğiyle kurulmalı. Derleme devamı artık bağlantı oluşturma sınırında doğrulanıyor; ancak Dape'nin oluşturucu içindeki beklemesi asenkron hâle gelmedi. Bekleme sırasında reentrant iptal/kimlik değişimi ayrıca korunmalı.
- **Yeniden üretme/kapanış:** Kontrollü geciken veya hiç açılmayan port, server process, uzak dizin ve süreç çıkışı; bağlantı kurulurken Stop/deadline/kök değişimi. Olay tabanlı bağlantı hazırlığı, yakalanmış server/socket/stderr sahipliği ve geç/çift tamamlanmada sızıntısız temizlik gerekli; yabancı adapter veya compilation kaynağı kapatılmamalı.
- **Bağımlılık:** DAPE-04 ile ortak asenkron adapter kaynak yaşam döngüsü; derleme devamı koruması oluşturucunun iç beklemesini çözmez.

## Doğrulama bekleyen riskler

### RISK-01 · P2 · D — Süreç iptali / stderr kapanışı stres anomalisi

- **Kanıt:** 2026-10-19 eşzamanlı ERT/derleme turunda child-process-group iptal callback'i 2 saniyede gelmedi; stderr-drain deadline testi erken başarı gördü. Sonraki eşzamanlı 100 tekrar (300 test) geçti; kök neden ayrıştırılmadı.
- **Doğrulama/kapanış:** `tests/test-process.el` ilgili iki testi ana süreç/stderr durumları ve sinyallerle izle; yalnız ana süreci bekleyen `accept-process-output` test yoluyla karşılaştır. Kör timeout artışı veya yalnız yeşil tekrar kaydı kapatmaz.

### RISK-02 · P2 · D — Sampling / reasoning koşullu uyumluluğu

- **Kanıt:** `kargu/api/parameters.el` düz destek listesi/politikadan sampling seçiyor; etkin reasoning ayarına bağlı destek koşulu arayüzü yok. Bu incelemede somut başarısız sağlayıcı isteği yeniden üretilmedi.
- **Doğrulama/kapanış:** Tarihi/sürümü belirli sağlayıcı sözleşmesi veya gizli veri içermeyen hata fixture'ı ile uyumsuz kombinasyonu göster. Gerekirse capability tek noktada yorumlanmalı; model adı regex'i/sağlayıcı listesi eklenmemeli. `none`, kapalı ve belirtilmemiş effort ayrımı korunmalı.

## Uyumluluk / geliştirme işleri

### COMPAT-01 · P2 — Sürümsüz Eglot push için alternatif doğrulama

- **Yer/kanıt:** `kargu/tools/lsp/freshness.el` sürümsüz push'u güncel saymıyor; `settle.el` timeout/unavailable ile bitiyor. Bu güvenli davranış hata değildir.
- **Hedef/kapanış:** Capability tabanlı pull veya eşdeğer istek-cevap güncellik sözleşmesi olan backend'lerde doğrulama. Sürümsüz/eski push temiz düzenleme kanıtı sayılmamalı; destek yoksa unavailable korunmalı.

## Düzeltme disiplini

Her mantıksal iş: yeniden üret → regresyon → düzelt → ilgili/tam ERT,
uyarısız byte-compile/checkdoc ve diff kontrolü → kaydı sil → ayrı commit.
FSM/protokol değişirse ilgili biçimsel model ve exhaustive TLC güncellenir.
Yeni zor bulgular ilgili bölümün sonuna eklenir; aynı kök neden çoğaltılmaz.
`skills.md` stage edilmez; mevcut `.gitignore` değişikliği korunur.

## Mimari Disiplin ve Sadeleştirme Fırsatları (Accidental Complexity Analizi)

2026-10-20 kod incelemesi: Bu bölüm ve devamı uygulanacak mimari planı tutar; her kayıt doğrulanmış çalışma zamanı hatası değildir. **Kod bulgusu**, **tasarım kararı** ve **ölçüm/doğrulama gereği** ayrılır. Dosya/fonksiyon referansları inceleme anına aittir; satır sayısı veya modül sayısı tek başına kötü mimari kanıtı değildir.

Kısaltılmış kaynak yolları `kargu/` altına göredir; `tests/` ve `proof/` yolları depo köküne göredir. ARCH/MOD/DEEP kimlikleri korunur; aynı hata için üst bölümdeki kayıt ikinci kez çoğaltılmaz.

Korunacak sözleşmeler: uygulama genelinde tek aktif koşu, koşu kaydı yayımlanmadan çalışıyor görünmemesi, aktif koşunun kipinin değişmemesi, her istekte protokol duvarı, varsayılan izin/inceleme ve geri alma politikası, asenkron tek teslim, geç cevapların sahiplik kontrolü. Tek-koşu kuralı global mutable değişken gerektirmez: koordinasyonun tek sahibi uygulama context'i olur (ARCH-12). Sadeleştirme bu garantileri kaldırmak değil, tek ve açık bir sahibin arkasında toplamak demektir. Uygulama aşamasında küçük commit, regresyon, uyarısız byte-compile/checkdoc ve değişen FSM için ilgili exhaustive TLC gerekir.

### ARCH-01 · Oturum Sahipliği: Sohbet Verisi ile Global Koşu Koordinasyonunu Ayır

- **Dosyalar / kalan sınır:** `core/session.el` kimlik/sayaçları ve `history/store.el` tek mesaj kuyruğunu lazy/buffer-owned `kargu-session` kaydında tutuyor; API delivery/run bu handle'ları yakalıyor. Geçici ping geçmişi ayrı, history snapshot'ları detached; foreign-buffer Stop/HTTP cevabı sahibine dönüyor. Canlı seçim, `state/store.el` merkezi durum deposu ve global `kargu--loop-run` koordinasyonu hâlâ application/session sahipliğine ayrılmalı. Buffer-local kimlik/proje kökü tek başına bu aktarımı tamamlamaz.
- **Karar:** Kimlik, geçmiş, sayaç ve sohbet seçimini sahipli bir oturum kaydında topla; sohbet tamponu bu kayda referans versin. Headless kullanımda da açık oturum referansı sağlanabilsin. Global varsayılan ayarlar ile oturuma ait canlı seçim ayrışsın; aktif koşu, başlarken yakaladığı oturum/proje/kip/seçim snapshot'ına bağlansın.
- **Sınır:** Buffer-local değişken tek başına gecikmiş callback'i doğru tampona yönlendirmez. Açık sahiplik ve oturum nesli kontrolü korunsun. Proje bazlı sohbet bulma/oluşturma hâlâ gereklidir; routing tamamen kaldırılmasın. Tek aktif koşu ve aktif koşunun kip kilidi korunsun; çoklu sohbet, eşzamanlı çoklu ajan çalıştırma yetkisi değildir. Mevcut global koordinatör geçiş hedefi değil, taşınacak mevcut durumdur; yeni mutable singleton kurulmasın (ARCH-12).
- **Kapanış / bağımlılık:** Aynı/farklı projede iki sohbet, headless oturum, seçim aktivasyonu, reset/restore, kapatılan tampon ve eski callback testleri; CHAT-01/02/03. İkinci bir durum deposu kurmak yerine mevcut seçici/geçiş API'sini sahipli kayda taşı.

### ARCH-02 · Komut Güvenliği: Argv, Politika ve Gerçek İzolasyonu Birbirine Karıştırma

- **Dosyalar / kod bulgusu:** `permission/bash.el` kabuk metnini sınırlı analiz ediyor; PERM-01 somut açık kayıt. `tools/process.el` argv tabanlı runner zaten var; Git/arama gibi yapılandırılmış araçlarda mevcut doğrudan süreç yolları yeniden icat edilmesin.
- **Karar:** Yapılandırılmış araçlar program + argv kullansın; izin verilen işlemler, seçenekler, kanonik yollar ve ortam ayrıca doğrulansın. Program destekliyorsa kullanıcı yollarından önce `--` kullan; option injection, symlink, programın hook/config çalıştırması ve alt süreç davranışını tehdit modeline kat.
- **Sınır:** Argv kabuk açılımını önler; path traversal veya keyfi program davranışını imkânsız kılmaz. `cwd` proje sınırı değildir; insan onayı da sandbox değildir. Serbest kabukta mevcut analiz sınırlı bir risk/ret katmanı olarak kalsın; tam güvenlik kanıtı gibi sunulmasın. OS izolasyonu ayrıca capability/platform bazlı tasarlansın: dosya yazma, ağ, ortam sırları, süreçler ve izin verilen mount'lar açık olsun. İzolasyon yoksa sessizce eşdeğer güvenlik iddiasıyla devam edilmesin.
- **Kapanış / bağımlılık:** PERM-01 regresyonları; argv seçenekleri, mutlak/göreli yol, symlink ve kontrol-sonrası yol değişimi, kabuk açılımları, ağ/ortam erişimi, sandbox yokluğu ve onay reddi. Politika kullanıcıya gerçek koruma düzeyini bildirsin; mevcut izin varsayılanları zayıflatılmasın.

### ARCH-03 · İnsan Onayı: Replay Yerine Yakalanmış İşleme Bağlı Devam

- **Dosyalar / kod bulgusu:** `permission/policy.el`, `ui/confirm.el`; `kargu-permission-call-async` ertelenmiş onaydan sonra thunk'ı tekrar çalıştırıyor. Mevcut sözleşme onayın yan etkiden önce alınmasını şart koşuyor; replay varlığı bütün çağıranlarda çift yan etki üretildiğini kanıtlamaz.
- **Karar:** Hazırlık → değişmez onay isteği → sahiplik/güncellik doğrulama → tek kullanımlık yürütme devamı şeklinde açık akışa geç. Komut, kanonik dizin, yollar, riskler ve ilgili belge/config nesilleri onaylanan işin kimliğine bağlansın; değişen iş için eski onay yeniden kullanılmasın.
- **Sınır:** Replay kaldırılırken preapproved eşleştirmesi, erken/senkron cevap bariyeri, ret, Stop/deadline ve callback tek teslim garantileri kaybolmasın. Sonradan gelen onay, iptal edilmiş/yeni oturuma taşınmış işi başlatmasın. Geçiş tamamlanana kadar replay çağıranlarında onay öncesi yan etkisizlik denetlensin.
- **Kapanış:** Çok aşamalı onay, erken/geç/çift cevap, reentrant consumer, onay sırasında dosya/kök/koşu değişimi ve kaynak temizliği testleri. Her çağıranı taşıdıktan sonra defer/replay uyumluluk yolu kaldırılabilir.

### ARCH-04 · Düzenleme Motoru: Üç Standart Giriş, Tek Güvenli İşlem Hattı

- **Dosyalar:** `kargu/tools/diff.el`, `kargu/tools/diff/stage.el`, `kargu/tools/diff/review.el`, `kargu/tools/diff/track.el`, `kargu/tools/lsp/symbols.el`, `kargu/tools/lsp/register.el`.
- **Mevcut durum / gerekçe:** Özel `*** Add/Update/Delete File` sözdizimi ve hunk ayrıştırıcısı bakım yükü oluşturuyor. Ancak benzersiz `old_string` → `new_string` değişimi (`kargu-diff-apply-replace`) ve sembol tabanlı düzenleme (`edit_by_lsp` / `kargu-lsp-edit-symbol`) zaten var; bunlar sıfırdan yeniden yazılmamalı. DIFF-01 ve DIFF-02'nin snapshot, tampon sahipliği ve çok dosyalı işlem sorunları parser kaynaklı olmak zorunda değil; format değişimi bu sorunları kendiliğinden çözmez.
- **Karar:** Girdi biçimini, değişikliği güvenle uygulama sorumluluğundan ayır. Bütün girişler aynı sahipli düzenleme planına dönüşsün ve ortak snapshot → güncellik doğrulama → inceleme/onay → uygulama → sonuç/geri alma hattını kullansın. Hiçbir giriş doğrudan bu hattı atlayarak dosyaya veya kullanıcı Git index'ine yazmasın.
- **Üç düzenleme girişi:**
  1. **Yapısal düzenleme:** Fonksiyon, metot, sınıf ve struct için ayrı araçlar çoğaltmak yerine tek bir `replace_symbol` sözleşmesi ve isteğe bağlı `kind` filtresi kullan; mevcut `edit_by_lsp` bunun temeli olsun. LSP/Eglot capability'si veya doğrulanabilir yerel sembol desteği yoksa bu girişi unavailable olarak bildir. Belirsiz hedefte tahmin etme; nitelikli ad veya yeniden seçim iste. Tam karakter aralığını belge sürümü/modification tick ve kaynak kimliğiyle bağla; yalnız satır numarasına güvenme. Tanım/gövde, yorum ve decorator sınırları açık olsun. Eski metni modelin yeniden üretmesi gerekmez; fakat küçük değişiklik için bütün tanımı yeniden üretmenin token maliyeti ayrıca değerlendirilir.
  2. **Benzersiz blok değiştirme:** Küçük metinsel değişikliklerde mevcut literal, büyük/küçük harfe duyarlı `old_string` → `new_string` yolunu koru. Boş veya birden fazla eşleşen eski metni reddet. Metin eşleştirme yalnız düzenleme planını üretir; izin, inceleme, kaydetme ve geri alma garantilerinin yerine geçmez.
  3. **Standart Unified Diff:** Toplu yamalar ve gelecekteki üçüncü taraf ajan çıktıları için standart biçimi kabul et. Yamayı canlı proje üzerinde değil, güncel kaynak snapshot'larından hazırlanmış izole geçici çalışma alanında `git apply` gibi standart bir backend ile asenkron doğrula/uygula; sonucu ortak düzenleme planına dönüştür. Gerçek kullanıcı index'inde `git apply --cached` kullanma: bu seçenek çalışma dosyalarını güncellemez ve kullanıcının stage ettiği değişikliklere müdahale eder. Git deposu olmayan projeler için destek açıkça tanımlansın; alternatif backend varsa aynı sözleşme/testleri sağlasın. Hatalı yamayı sessizce kısmen uygulama; fuzz, whitespace düzeltmesi veya üç yönlü birleştirme ile belirsizliği otomatik gizleme.
- **Ortak güvenlik ve işlem sözleşmesi:**
  - Tam, daraltılmamış canlı tampon içeriği; kirli durum, kodlama/satır sonları ve disk kimliği birlikte yakalansın. Proje sınırı ve symlink doğrulaması bütün girişlerde aynı noktadan yapılsın. Yeni/silinen dosyalar da açık işlem türleri olsun; desteklenmeyen binary/metadata işlemleri reddedilsin.
  - İnceleme veya backend çalışması sırasında dosya/tampon, proje, oturum ya da koşu değişirse eski sonuç yazılmasın. Kullanıcı değişiklikleri örtük kaydedilmesin veya ezilmesin. Save-hook dönüşümleri ve kaydetme hataları yayımlanan sonuçla uzlaştırılsın.
  - Çok dosyalı değişiklikte uygulama sınırı, insanın kısmi kabulü/reddi ve hata sonrası geri alma davranışı açıkça tanımlansın. Geri alma, araya giren kullanıcı değişikliğini ezmesin; güvenli geri alma mümkün değilse çatışma/kısmi sonuç doğru raporlansın. Git'in uygulanamayan hunk için tüm yamayı reddetmesi, Emacs tamponları/disk/save-hook'lar arasında ortak transaction veya sonradan undo garantisi değildir; çökme dayanıklılığı ayrıca tasarlanmadan vaat edilmesin.
  - Kaynaklar iptal/deadline ile sahipli temizlensin; callback yalnız bir kez teslim edilsin. Geçici alan dışında yabancı dosya, tampon veya index değişmesin. Mevcut `auto`/onay politikaları, fark gösterimi ve rollback snapshot zorunluluğu korunsun.
- **Uygulama sırası:** Önce DIFF-01/DIFF-02 kapsamında ortak snapshot ve işlem sözleşmesini sağlamlaştır; mevcut blok/sembol girişlerini bu sınıra taşı. Ardından izole Unified Diff backend'ini ekle ve özel patch sözdizimini, çağıranlar/araç şemaları/testler taşındıktan sonra kaldır. Geçiş sırasında ikinci bir onay veya geri alma motoru oluşturma.
- **Kapanış ölçütleri:** Üç giriş aynı inceleme/uygulama/geri alma testlerini geçsin. Kirli/daraltılmış tampon, CRLF/LF ve UTF-8, eşleşmeyen/tekrarlı blok, belirsiz/eski sembol aralığı, yeni/silinen dosya, sınır dışı/symlink hedef, kısmi insan kabulü, son dosyada kaydetme hatası, save-hook dönüşümü, dış disk değişimi, Stop/deadline ve geç/çift callback senaryoları kapsansın. Kullanıcının index'i ve bağımsız değişiklikleri değişmeden kalsın; süreç çağrıları UI'ı bekletmesin. İşlem FSM'i değişirse ilgili biçimsel model de güncellensin.
- **Bağımlılık:** DIFF-01, DIFF-02 ve LSP sembol aralığı/güncellik sözleşmesi. Standart parser kullanımı, ortak güvenli uygulama katmanını kaldırma gerekçesi değildir.

### ARCH-05 · Debugger Sınırı: Dape Adaptörü Arkasında Sahipli Bağlantı Yaşam Döngüsü

- **Dosyalar / kod bulgusu:** `tools/dape/`; Dape'nin global seçimi/UI yardımcıları ile Kargu'nun proje/koşu sahipliği farklı sözleşmelerdir. DAPE-04 ve DAPE-05 açık; önceki readiness ve deferred compile korumaları mevcut. Çok dosya veya nesil kontrolü bulunması tek başına gereksiz karmaşıklık değildir.
- **Karar:** Uygulamanın kullandığı küçük debugger portunu tanımla: capability/context, inspect, control, start ve close. Dape'ye özel private API/advice/metadata erişimi portun adaptör tarafında kalsın. Bağlantı kimliği ve olay nesli ortak kaynak katmanında tutulup araçlarca tüketilsin; denetimler silinmek yerine tekrarları azaltılsın.
- **Sınır:** Tek dev adapter dosyası veya sıfırdan DAP istemcisi zorunlu hedef değildir. Doğrudan DAP; taşıma, initialization, child session, source mapping, breakpoint, shutdown ve UI entegrasyonunu yeniden üstlenir; ancak somut gereksinim ve karşılaştırmalı prototiple ayrı karar olabilir. Dape global quit/selection temizliği yabancı oturumları etkilememeli; süreç/port/shutdown beklemeleri asenkron olmalı.
- **Kapanış / bağımlılık:** İki proje/adapter, foreign selection, kaybolan bağlantı, thread/frame yeniden kullanımı, geç/çift cevap, Stop/deadline, compile devamı ve child session testleri. Mevcut debugger proof/regresyonları korunarak DAPE-04/05 ve PERF-05 çözülmeli; daha önce kapanan sahiplik hataları yeniden açılmamalı.

### ARCH-06 · Sohbet Görünümü: Veri Sahipliğini Yerleşimden Ayır, UI Değişimini Ölç

- **Dosyalar / kod bulgusu:** `chat/prompt.el`, `chat/transcript.el`, `chat/render.el`; tek tampondaki transcript, taslak ve footer marker gerektiriyor. Marker kullanımı tek başına hata değildir; split UI da odak, pencere ve yaşam döngüsü yönetimi gerektirir.
- **Karar:** Oturum/draft modelini görünümden ayır. Footer'ın header-line/mode-line'a, çok satırlı girdinin ayrı tampona taşınmasını bağımsız prototip olarak değerlendir; minibuffer'ı zorunlu tek giriş yapma. Önce CHAT-01/02/03 ve mevcut prompt sınırları güvenli hâle gelsin.
- **Sınır:** Akış sırasında yazılan taslak, geçmişe gitme, Company seçimi, IME/Unicode, klavye/fare erişimi, read-only transcript, erişilebilir Stop ve point/narrowing/pencere konumu korunsun. Yeni yerleşim veri kaybını çözmüş kabul edilmesin; eski ve yeni görünüm ortak oturum API'sini kullansın.
- **Kapanış:** Aynı stream/approval/draft senaryolarını iki görünümde karşılaştır; kullanılabilirlik ve bakım yükü kanıtıyla yerleşim seç. Kullanıcıya dönük davranış değişimini belgeleyerek geç; bu deney güvenlik düzeltmelerini veya headless sınırı bloke etmesin.

### ARCH-07 · Geçmiş: Yazma Anında Değişmezler, Her İstekte Protokol Duvarı

- **Dosyalar / kalan sınır:** `history/store.el` tek sahipli kuyruk/snapshot sınırı; `history/protocol.el`, `history/repair.el`, `history/compact.el` protokol geçişleri. Sona ekleme yalnız yeni mesajı kopyalıyor; 1000/2000 ekleme ölçümünde cons tahsisi 58,076/116,076 (eski append: 502,573/2,005,082). Boyut ölçümü senkron/sahipli cursor ile yalnız yeni mesajları kodluyor; replacement eski ölçümü/cursor'u temizliyor, şema maliyeti canlı okunuyor. Repair/compaction hâlâ tam geçmişi işler. Geçmiş her anda gönderilebilir değildir: asistan tool-call turunun sonuçları henüz gelmemiş olabilir.
- **Karar:** Sahipli geçmiş API'sinde ekleme, tool-result eşleştirme, reset/restore ve compaction geçişlerini tamamla. Mevcut senkron kuyruk cursor'unu koru; ileride asenkron ölçüm eklenirse sahiplik/yazma nesli doğrulaması olmadan eski sonuç yayınlanmasın. Değişmez payload snapshot'ını `nconc` veya iç içe mutasyonla bozma.
- **Sınır:** Gönderim öncesi protokol duvarını kaldırma. İptal sonrası eksik sonuçlar, dış restore, legacy kayıtlar ve farklı wire biçimleri hâlâ doğrulanmalı/normalize edilmeli. Sentetik hata sonucu gerçek araç başarısı diye raporlanmamalı. Ortak iç protokol ile sağlayıcıya özgü kodlama kısıtları ayrı sınırlarda yaşasın.
- **Kapanış / bağımlılık:** CHAT-01, MOD-05; restore/repair/compaction, duplicate/orphan tool ID, yarım tur, iptal ve nested içerik paylaşımı testleri. İsteğin duvarı atlayamaması ve mevcut protokol/law testleri korunmalı; protokol modeli değişirse TLC güncellenmeli.

### ARCH-08 · Veri Modeli: Tek Koleksiyon Türü Değil, Tek Anlam ve Açık Sahiplik

- **Dosyalar / kod bulgusu:** `contract/types.el`, `json.el`, `api/wire.el` ve sahipli kaynak modülleri; alist, plist, hash table ve struct farklı amaçlarla kullanılıyor. Bu çeşitlilik kendi başına dönüşüm hatası veya performans sorunu kanıtı değildir.
- **Karar:** Oturum/koşu/istek/onay/işlem gibi kimlik ve yaşam döngüsü taşıyan kayıtları tiplendir; okuma/geçiş API'leriyle mutasyon sahibini sınırla. Mesaj/tool-call için kanonik iç sözleşme ve wire sınırında açık dönüştürücüler belirle. Domain değerleri ve seçenek kayıtları ARCH-10'daki adlandırılmış tiplerle ifade edilsin; indeksin hash table olması veya dış JSON'un alist olması iç domain API'sini isimsiz koleksiyonlara dönüştürmesin.
- **Sınır:** Bütün projeyi tek seferde struct'a çevirme; mevcut doğru JSON sınırlarını ve sağlayıcıya özgü bilinmeyen alanları koru. Eksik alan, açık nil, false, null, boş nesne ve boş dizi ayrımı kaybolmasın. Mutable iç referanslar dışarı sızmasın; persistence sürümü/legacy migration açık olsun.
- **Kapanış:** Kaynak sahipliği ve JSON round-trip testleri; iç içe dizi/nesne, Unicode, bilinmeyen metadata, kayıt yükleme ve kopya izolasyonu. Her taşıma bağımsız commit olsun; salt biçim birliği için yeni genel framework eklenmesin.

### ARCH-09 · Modül Bağımsızlığı: Ters Bağımlılık ve Sökülebilir Özellikler

- **Hedef:** Her özellik modülü kendi domain'ine sahip olsun; başka somut modülün iç yapısını, global tablosunu veya UI tamponunu bilmesin. Tüketici ihtiyacı olan küçük portu tanımlar; sağlayıcı adapter'ı bu porta uyar. Bağlama/kayıt işlemi modül gövdesinde değil uygulamanın composition noktasında yapılır. Ortak sözleşme katmanı somut adapter'ları yüklemez.
- **Bağımlılık kuralları:** Modüller arası döngüsel `require`, çapraz private çağrı ve başkasının kaydına doğrudan yazma yasak. Bağımlılık yalnız public sözleşme ve açıkça verilen servis/handle üzerinden kurulsun. Her modül zorunlu sözleşmelerini, opsiyonel capability'lerini, sağladığı portları ve register/unregister/close davranışını bildirsin; her dosya için ayrı interface üretmek gerekmez.
- **Silme/eksiklik sözleşmesi:** Bir özellik adapter'ı silindiğinde veya kapatıldığında yalnız ilgili capability ve araçlar unavailable olsun; alakasız modüller yüklenip çalışabilsin. Örneğin Dape yokken sohbet/arama, LSP yokken metinsel düzenleme, chat UI yokken headless motor çalışabilsin. İzin kapısı gibi güvenlik-kritik bir bileşenin yokluğu yazmayı yetkisiz sürdürme gerekçesi değildir: gerekli işlemler güvenli ret versin, bağımsız yardım/okuma işlevleri çalışmaya devam etsin. Asgari bootstrap/sözleşme çekirdeğinin zorunlu bağımlılık olması açıkça belgelenir; onu silince her şeyin çalışacağı vaat edilmez.
- **Yükleme ve kaldırma:** Eksik adapter'ın sembollerini yükleme anında çağırma; unavailable sonucu, yanlış başarılı sonuçtan farklı olsun. Canlı kaldırma önce sahipli işlerin drain/cancel edilmesini ve kaynakların kapanmasını gerektirir; yalnız hook silmek yeterli değildir. Callback'i kalmış modülün kodu güvenli kapanmadan unload edilmesin.
- **Kalan kapsam:** LSP/Dape/arama/Bash/Git/skill/webfetch kaynaklarının ayrı veya birlikte çıkarılması ve chat/plan/UI/diff kaynakları olmadan sahte modelle motor koşusu fiziksel eksik-paket testinden geçiyor; bu bütün modüllerin ayrıştığı anlamına gelmez. Motor ve LSP diff'e değil `kargu/edit` portuna bağlı; okuma `kargu/files` içinde. Kalan işler uygulama/oturum sahipliği, diff'in paylaşılan kayıtlarının sahipliği ve bütün adapter'ların aktif kaynak/kayıt kapanışı. Yerleşik taşıma başlangıçta plz/curl gerektiriyor; gelecekteki backend portunda zorunlu altyapı da seçilen yürütme sahibine bağlanmalı. Asgari çekirdek ile opsiyonel özelliklerin bileşim matrisi genişletilmeli.
- **Kapanış / bağımlılık:** MOD-01..08. Taze batch Emacs'te her modülü sahte portlarla tek başına yükle; opsiyonel adapter'ları fiziksel olarak içermeyen geçici paket ağacıyla eksik-modül matrisi çalıştır. Ayrıca portu fake ile değiştir, register/unregister'ı tekrarla, aktif işte disable/close dene. Test yalnız `fboundp` mock'uyla eksikliği gizlemesin; zorunlu bağımlılıkta açık ret, bağımsız özelliklerde devam kanıtlansın.

### ARCH-10 · Domain Tipleri: Primitive Obsession Yerine Adlandırılmış Değerler

- **Hedef:** Domain anlamı taşıyan her değer ve modüller arası giriş/çıkış, amacı adında görünen bir tip olsun. `string`/`integer` veya rastgele plist tek başına `session-id`, `request-id`, `project-root`, `duration`, `byte-limit`, `token-count`, `diagnostic-snapshot` veya `money` sözleşmesi yerine geçmesin. Kimlik/birim karışabilecek scalar değerler de adlandırılmış `cl-defstruct` değer nesnesinde taşınsın; yalnız değişkene anlamlı ad vermek yeterli değildir.
- **Örnek:** Para gerekiyorsa `kargu-money` kaydı `minor-units` ve `currency` alanları taşısın; içte tamsayı bulunabilir ama public işlem çıplak tamsayı kabul etmesin. `kargu-duration` birimi açık süre, `kargu-byte-count` byte miktarı, `kargu-token-count` token miktarı olsun. Farklı para birimleri/birimler örtük toplanmasın; dönüşüm açık fonksiyon ve doğrulamayla yapılsın. Domain'de para ihtiyacı yokken örnek uğruna para modülü eklenmesin.
- **Kurucu ve doğrulama:** Public kurucular temsil, aralık, birim, kanonik yol ve required/optional alanları doğrulasın; geçersiz kayıt üretimi normal çağrı yolu olmasın. Elisp `cl-defstruct` tek başına C'nin statik tip denetimini sağlamaz; `-p` predicate'leri, kurucu/geçiş kontrolleri ve negatif testler zorunludur. Yapısal kopyalama ile sahiplik devri ayrı sözleşmeler olsun; mutable iç alanlara kontrolsüz yazılmasın.
- **Primitive sınırı:** Wire/persistence/Emacs API adapter'ında domain değeri açıkça scalar/JSON'a çevrilebilir; dıştan gelen scalar önce doğrulanıp domain tipine alınsın. Fonksiyon içi döngü indeksi veya geçici metin birleştirme parçası gibi domain kimliği taşımayan yerel hesap değişkenleri primitive kalabilir. Bu istisna public API'de `value`/`data` torbası taşımak için kullanılamaz. İç koleksiyonlar eleman tipini ve değişiklik sahibini belirtmeli; her cons hücresini sarmalayan generic type framework kurulmasın.
- **Kapanış / bağımlılık:** ARCH-08 ve ilgili domain kayıtları. Request ID yerine session ID, byte yerine karakter/token, yanlış birim ve geçersiz path verilmesi sınırda reddedilsin; JSON null/false/eksik ayrımı ile legacy restore korunsun. Tip envanterinde ad, temsil, invariant, sahip, kurucu, dönüştürücü ve tüketici listelensin; sarmalama maliyeti ölçülüp gereksiz tekrar dönüşümleri kaldırılmış olsun.

### ARCH-11 · Durum Yönetimi: Tek Durum Alanı ve Açık Geçiş Tablosu

- **Hedef:** Yaşam döngüsü iç içe `if/else` ve bağımsız `started/done/cancelled/busy` bayraklarıyla kurulmasın. Her kaynak için sahibi belirli bir state machine, adlandırılmış durum/olaylar ve izin verilen geçişler bulunsun. Tek bir dev makine yerine run, request, approval, process ve transaction kendi ömürlerini yönetsin; aralarındaki sahiplik/iptal ilişkisi açık olsun.
- **Geçiş sözleşmesi:** `(state, event) -> (next-state, effects/result)` tanımlansın; `pcase` veya küçük bir geçiş tablosu seçilsin. Kimlik/nesil guard'ı, etkileri başlatma sırası, erken callback bariyeri ve terminal cleanup tek geçiş kapısında toplansın. `busy`, `done` gibi türetilebilir göstergeler state'ten hesaplansın; ikinci bir doğruluk kaynağı olmasın. Geçersiz veya tekrarlı olayın ret/no-op davranışı açık olsun.
- **Sınır:** Her sıradan koşul için state machine kurma. Girdi doğrulayan `unless`, sahiplik guard'ı veya iki algoritmadan birini seçen basit koşul serbesttir; yasak olan yaşam döngüsünü bu dallara dağıtmaktır. Bağımsız capability ve veri alanları state adı içine kombinasyon patlamasıyla gömülmesin; gerekli paralel durumlar ayrı sahipli kayıtlarda modellenebilir.
- **Kapanış:** Her state/event çifti, terminal tekrarlar, illegal geçiş, erken/geç/çift callback, iptal, timeout, cleanup hatası ve observer reentrancy test edilsin. İlgili formal model gerçek geçiş sırasıyla güncellenip exhaustive TLC çalıştırılsın; yalnız `if` yerine `pcase` yazmak kapanış sayılmasın.

### ARCH-12 · Global Mutable Runtime Durumu Yasak: Açık Sahip ve Context

- **Hedef:** Üretim runtime verisi global mutable `defvar`/`setq` tablosunda tutulmasın. History, sayaçlar, aktif request/run, process/job listesi, onay, cache ve değişen seçim kendi adlandırılmış session/service/application kaydına ait olsun. Modüller uygulama singleton'ını gizlice aramasın; ihtiyaç duydukları dar context/servis constructor veya işlem argümanıyla verilsin.
- **Tek-koşu koordinasyonu:** Uygulama genelindeki tek aktif koşuyu bir application coordinator kaydı korur; global `kargu--loop-run` bunu sağlamak için zorunlu değildir. Bootstrap sahibi uygulama ömrünü yönetir; sohbet/buffer veya açık headless handle ilgili sahipli kayda referans taşır. Buffer-local referans da açık bir sahiplik bağıdır; başka modülün buffer-local değişkeni gizli servis bulucu olarak okunmasın. Kaynak sahibi kapanınca listener, timer ve süreçler belirlenen politika ile serbest bırakılsın.
- **Emacs sınırı:** Değişmez `defconst`, kullanıcı ayarı `defcustom`, Emacs'in isimle beklediği keymap/hook/autoload kayıt noktaları ve yalnız teste özgü dinamik mock binding'leri runtime singleton yasağından ayrılır. Bunlar sınırlı whitelist olsun; hook üzerinden session verisi veya `defconst` içindeki liste/hash üzerinde mutasyon gizlenmesin. Mutable registration gerekiyorsa sahipli servis yönetsin; framework zorunluluğu ve unload temizliği belgelenmeden yeni global istisna açılmasın.
- **Geçiş disiplini:** Mevcut global alanların envanterini çıkar; yeni kullanım eklemeyi durdur, tüketicileri public context API'sine kademeli taşı, son tüketici taşınınca eski global/uyumluluk köprüsünü sil. Sadece adını değiştirmek veya bütün global alanları bir `kargu-engine` globalinin içine doldurmak çözüm değildir. Bridge dönemi çift yazma/iki doğruluk kaynağı yaratmasın.
- **Kapanış / bağımlılık:** ARCH-01, MOD-04/05/07. İki bağımsız oturum ve izole uygulama fixture'ı birbirinin verisini değiştiremesin; tek uygulamada ikinci aktif koşu reddedilsin. Statik global yazma envanteri ile dinamik reset/close/leak testleri birlikte çalışsın; whitelist dışı global mutation ve testi geçen gizli singleton kalmasın.

### ARCH-13 · Okunabilirlik Sınırı: En Fazla İki Döngü, Sığ Kontrol Akışı

- **Hedef:** Bir fonksiyonda üç veya daha çok iç içe döngü yasak; normal tercih tek döngü veya erken çıkışlı düz akıştır. `mapcar`, `seq-*`, `cl-loop`, callback ve yerel fonksiyonla yazılmış tekrarlar da mantıksal nesting hesabına dahildir. Uzun bir satıra sıkıştırmak veya iç döngüyü isimsiz lambda'ya taşımak yasağı aşmış sayılmaz.
- **Yapı:** Fonksiyon bir iş yapsın; 35–40 gövde satırını aşmasın, kontrol dalları üç seviyeyi geçmesin. Guard clause ile geçersiz girdiyi erkenden ayır; üçten fazla mantıksal parametrede keyword argüman veya doğru domain kaydı kullan. Derin kararlar anlamlı yardımcı/stratejiye, tekrar eden arama bir kez kurulan indeks veya tek geçişli algoritmaya dönüştürülsün. Parçalama, çağrı zincirini anlamsız delegasyonlarla uzatmasın.
- **Sınır:** İki döngü otomatik O(N²) demek olmadığı gibi ayrı fonksiyonlara bölünmüş üç tarama da ucuz olmak zorunda değildir; algoritmik maliyet ARCH-14'te ayrıca değerlendirilir. Derin veri ağacında recursion gerekiyorsa derinlik/öğe bütçesi veya açık stack gibi güvenli dolaşım tanımlansın; dış girdiye bağlı sınırsız recursion eklenmesin.
- **Kapanış:** Değişen fonksiyonlar için gövde uzunluğu/nesting denetimi ve review listesi çalışsın; yalnız metinsel parantez sayan kontrol yeterli olmasın. Refactor öncesi/sonrası sıra, hata, point/narrowing/match-data ve callback davranışı aynı testlerle doğrulansın. Eşik aşımını “yardımcıya taşıdım” diye saklamayan çağrı grafiği incelemesi yapılsın.

### ARCH-14 · Tam Çözümün En Basiti: Doğruluk, Algoritma ve Ölçüm Birlikte

- **Hedef:** Önce problemin giriş/çıkış, hata, yan etki, sahiplik, iptal ve kaynak sınırlarını yaz; bu sözleşmenin tamamını sağlayan en az mekanizmalı çözümü seç. Daha az satır uğruna doğrulama/rollback/cleanup atlamak veya gelecekteki varsayımsal ihtiyaçlar için framework kurmak sadelik değildir.
- **Algoritma disiplini:** Değişen sıcak yol için giriş büyüklüklerini (`N` mesaj, `B` byte, `F` dosya gibi) ve zaman/ek bellek maliyetini belirt. Sona tekrar `append`, döngü içinde bütün geçmişi JSON'a çevirme, her sonuçta yeniden `buffer-list` tarama veya dar aralık için bütün dosyayı kopyalama gibi büyüme kaynaklarını incele. Uygun yerde sahipli kuyruk/indeks, tek geçiş, bounded okuma ve artımlı ölçüm kullan; paylaşılan snapshot'ı bozarak performans kazanma.
- **Tercih kuralı:** Küçük ve açık bir standart algoritma yeterliyse onu kullan. Cache ancak sahiplik, anahtar, invalidation, boyut/ömür ve eşdeğerlik testleriyle eklenebilir; aksi hâlde karmaşıklığı artırır. Asenkron yürütme O(N²) algoritmayı düzeltmez; lineer algoritma da yavaş disk/ağ çağrısını UI thread'inde güvenli yapmaz. Doğruluk için gerçekten gerekli maliyet belgelenir; evrensel “her şey O(N)” hedefi konmaz.
- **Dış değişiklik ve cache:** Invalidation yalnız Kargu'nun kendi yazma araçlarına bağlanmasın; kullanıcı düzenlemesi, başka süreç/Emacs, Git checkout, LSP server restart ve config değişimi de ilgili revision'ı etkiler. Geçersizleştirme olayı güvenilir değilse yeniden doğrula veya sonucu açıkça eski snapshot/unknown olarak etiketle. Salt TTL, aynı tool adı/argümanı veya read-only sınıfı güncellik kanıtı değildir; cache aynı işlevin farklı veri neslini karıştırmasın.
- **Doğrulama:** Küçük/normal/büyük girdi, uzun satır/mesaj, boş/bozuk veri, bounded çıktı ve iptal senaryolarında süre, allocation, tepe bellek ve çıktı miktarını karşılaştır. Flaky süre eşiği yerine mümkün olduğunda taranan byte, traversal/encode sayısı ve nesne paylaşımı gibi deterministik sayaçları test et. Özel karmaşık algoritmayı ancak basit seçeneğin yetersizliği ölçülmüşse seç.
- **Kapanış / bağımlılık:** ARCH-04/07/13, PERF-01..05 ve DEEP-07/09. “Problem tamamen çözüldü” iddiası kabul ölçütleri, başarısızlık yolları ve mevcut law/protokol testleriyle desteklensin; başarı yalnız happy-path testi veya düşük satır sayısıyla ilan edilmesin. Her yeni katman için hangi zorunlu problemi çözdüğü ve neden mevcut mekanizmanın yetmediği açıklansın.

### ARCH-15 · Defensive Programming: Sınırda Doğrula, İçeride Kanonik Veriyle Çalış

- **Temel sözleşme:** Her modül aldığı veriyi public girişinde, verdiği veriyi public çıkışında doğrulasın. Buna normal dönüş değeri kadar callback sonucu, event payload'ı, stream kaydı ve persistence çıktısı da dahildir. Public kurucu/decode sınırı ham veriyi doğrulanmış domain tipine dönüştürsün; iç yardımcılar açık önkoşulları olan kanonik tiplerle çalışsın. Aynı veriyi her yardımcıda yeniden parse/normalize/doğrulayan zincir kurulmasın.
- **Giriş sırası:** Yan etkiden ve hassas veriyi loglamadan önce temsil/tip, sözleşme sürümü, required/optional alanlar, aralık/birim, boyut/derinlik/öğe bütçesi ve alanlar arası invariant'lar denetlensin. Büyük veya bozuk veri sınırsız parse/kopyalamadan önce sınırlandırılsın. Yol, capability ve yetki gibi domain kuralları ilgili güven sınırında ayrıca uygulansın. Geçersiz girdide örtük `0`, boş metin veya “OK” üretip ilerlemek yerine adlandırılmış hata dönsün; şemada belgelenmiş varsayılan ile bozuk girdinin sessiz düzeltilmesi ayrışsın.
- **Çıkış sırası:** Modül sonucu dışarı yayımlamadan önce türünü, durum/payload uyumunu, kimlik ve kaynak ilişkisini, çıktı bütçesini ve başarı iddiasının kanıtını doğrulasın. Başarısız/unknown sonuç başarı payload'ı taşımasın; mutable iç referans dışarı kaçmasın. Consumer kendi giriş sözleşmesini yine kontrol etsin; aynı değişmez tip/sürüm için bitişik sınırlar ortak kurucu/predicate kullansın, gereksiz ikinci derin ağaç taraması yapmasın. Dış süreç, disk, eklenti veya wire verisi yalnız “üretici doğrulamıştır” varsayımıyla kabul edilmesin.
- **Dönüşüm disiplini:** Decode → doğrulama/kanonikleştirme → domain işlemi → doğrulanmış sonuç → encode hattı açık olsun. Alist/plist/string/struct dönüşümü yalnız temsil sınırında yapılsın; yardımcıların her biri “her türü kabul eden” normalize fonksiyonu olmasın. Aynı domain kuralının kopyaları yerine tek sahibi ve ortak testli doğrulayıcısı bulunsun. Saf hesaplama/karar yardımcıları disk/ağ/kimlik deposuna gizlice erişmesin; I/O adapter'ı sonucu doğrulanmış snapshot olarak sağlasın.
- **Gerekli tekrar ile gereksiz tekrar ayrımı:** Şema/temsil doğrulaması, zamanla değişebilen sahiplik/izin/güncellik kontrolü değildir. Onay veya asenkron bekleme sonrasında run/session/connection nesli, belge revision'ı ve işlem öncesi yetki tekrar doğrulanmalı; bunlar “içeride validation yasak” diye silinmesin. Salt `validated` bayrağı, struct etiketi veya eski bir path kontrolü güncellik/güvenlik kanıtı olmasın. Immutable snapshot ve değişiklik sahibi garantisi yoksa iç invariant kontrolü gerekli olabilir; gerekçesi sözleşmede yazılsın.
- **Hata politikası:** Caller'ın bozuk girdisi ile modülün kendi bozuk çıktısı farklı hata sınıfları olsun. Public çıkış invariant'ı bozulursa sonuç yayımlanmasın; sahipli iş güvenli kapatılsın, redacted tanı üretilebilsin. Yan etki başlamışsa sonucu “hiçbir şey olmadı” diye gizleme: ARCH-16'nın kısmi/belirsiz sonuç sözleşmesini kullan. Test/debug assertion'ı üretimde gereken güvenlik kapısının yerine geçmesin.
- **Kapanış / bağımlılık:** ARCH-08/10/11 ve MOD-02/04. Her port için girdi/çıktı şeması, doğrulama sahibi, kanonik tip, hata davranışı ve güven/temsil sınırı envanterlensin. Bozuk girişte sıfır yetkisiz yan etki, bozuk çıkışta sıfır sahte başarı; yanlış tip/sürüm/birim, aşırı büyük/derin veri, duplicate kimlik, eksik/false/null alanlar, stale callback ve consumer mutasyonu test edilsin. Parse/normalize/derin doğrulama sayaçlarıyla tekrar işin kaldırıldığı, gerekli sahiplik kontrollerinin korunduğu gösterilsin.

### ARCH-16 · Hata Modeli: String Yorumlama Yerine Adlandırılmış Sonuçlar

- **Hedef:** İç modül API'leri `ERROR:` öneki, nil/boş metin veya exception mesajını parse ederek kontrol akışı kurmasın. Domain'e uygun adlandırılmış sonuç kaydı; durum, değer veya hata, işlem kimliği ve gerekiyorsa kısmi etki bilgisini taşısın. Başarı, ret, unavailable, iptal, timeout, doğrulanamayan durum ve iç invariant ihlali birbirine karıştırılmasın.
- **Sorumluluk:** Beklenen domain hatası typed sonuçla, programlama/invariant hatası açık tanıyla iletilsin; public asenkron adapter bu ayrımı tek terminal sonuca dönüştürsün. Hataya köken ve güvenli neden zinciri eklenebilsin; credential/ham payload tanıya sızmasın. Kullanıcı/model metni en dış adapter'da üretilsin; mevcut string tabanlı araç API'si kademeli uyumluluk facade'ıyla taşınsın.
- **Retry sınırı:** Retry kararı hata mesajı kelimelerine değil doğrulanmış hata sınıfına, işlem güvenliğine ve kalan bütçeye dayansın. Onay reddi veya validation hatası retry edilmesin. Yan etkili istekte cevap kaybı “iş başarısız oldu” kanıtı değildir; idempotency veya uzlaştırma yoksa kör tekrar yerine belirsiz sonucu bildir. Duplicate/late sonuç terminal durumu değiştirmesin.
- **Kapanış / bağımlılık:** ARCH-15, MOD-04 ve DEEP-09. Bütün terminal sonuçlar, hatadan metne dönüşüm, exception/callback hatası, kısmi dosya/süreç etkisi ve aynı metne sahip farklı hata kodları test edilsin. Başarısızlık sessizce yutulmasın; UI failure'ı domain işlemini ikinci kez çalıştırmasın.

### ARCH-17 · Kaynak Sözleşmesi: Tek Sahip, Yapılandırılmış İptal ve Tek Temizlik

- **Hedef:** Her process, timer, listener, geçici dosya/tampon ve pending callback için adlandırılmış bir sahip ve edinme/bırakma yolu bulunsun. İş/alt iş ilişkisi context'te açık olsun; ebeveyn kapanınca alt işlerin hangisinin iptal edileceği, hangisinin açıkça devredildiği belirlensin. Sahipsiz background iş veya gizli ömür uzatma olmasın.
- **Edinme ve yayımlama:** Temizlik hakkı kaynak edinimiyle beraber kaydedilsin; kısmi initialization hatası da temizlensin. Tam kurulum yayımlanmadan erken callback terminal sonucu consumer'a sızdırmasın. Başlatma, kapanma ve iptal FSM geçişleri olsun; scope helper veya `unwind-protect` yalnız uygun senkron kapsamda kullanılsın, asenkron kaynağı fonksiyon dönüşünde yanlışlıkla kapatmasın.
- **İptal ve close:** Close/cancel idempotent olsun; iki çağrı yeni hata/yan etki üretmesin. İptal isteği, kaynağın gerçekten durduğu ve sonucun teslim edildiği olaylardan ayrışsın. Asenkron graceful kapanma deadline ile sınırlansın; gerektiğinde yalnız sahipli kaynak zorla kapatılsın. Bir cleanup hatası diğer kaynakların bırakılmasını engellemesin; yabancı veya yeni sahibine devredilmiş kaynak kapatılmasın. Uzak işlemin durduğu kanıtlanamıyorsa bilinmiyor raporlansın.
- **Kapanış / bağımlılık:** ARCH-11/12, MOD-04/05, DAPE-04/05 ve DEEP-05. Her edinme adımında hata enjekte et; erken completion, timeout/Stop/reset, çift close, kapanırken yeni olay, consumer hatası ve açık devir testleri çalışsın. Bitişte sahipli timer/listener/process/temp alan sayısı beklenen değere dönsün; test yalnız callback geldiğini değil kaynakların bırakıldığını da doğrulasın.

### ARCH-18 · Test Edilebilir Sınırlar: Contract Suite, Sahte Zaman ve Hata Enjeksiyonu

- **Hedef:** Her public port tek bir yeniden kullanılabilir contract test takımına sahip olsun. Fake adapter kadar gerçek adapter'ın kontrollü yerel fixture'ı da aynı sözleşmeyi geçsin; sadece mock'un doğru davranması modülü doğrulamaz. Domain testleri UI veya canlı uzak sağlayıcı gerektirmesin.
- **Deterministik yürütme:** Zaman, transport, süreç ve kimlik üretimi gereken sınırda küçük portlarla kontrol edilebilsin; global mock/DI framework kurulmasın. Asenkron test gerçek süreyi beklemek yerine timer/olay sırasını açıkça ilerletsin. Erken/geç/çift ve sırası değişmiş olaylar, kurulum/cleanup hatası ve observer reentrancy sistematik kapsansın. Gerçek OS stres testi ayrı tutulup deterministik FSM testiyle karıştırılmasın.
- **Özellik tabanlı kontroller:** Decode/encode round-trip, validation'ın yan etkisizliği, normalization'ın idempotence'ı, snapshot izolasyonu ve cancel/close'un idempotence'ı sınansın. Fuzz/property girdileri boyut/derinlik bütçeli, tekrar üretilebilir seed'li ve yalnız sentetik veriyle çalışsın. Sürüm migrasyonu, unavailable capability ve silinen modül de contract testinin parçası olsun.
- **Kapanış / bağımlılık:** ARCH-09/15/16/17. Testler geçici proje/kayıt alanı kullansın; ağa, kullanıcının credential deposuna veya çalışma dosyalarına dokunmasın. Başarısız test izolasyonu sıradaki testi etkilemesin; leak ve global mutation kontrolleri bulunsun. Model sınırları ve test kapsamı açık raporlansın; yeşil test veya TLC sonucu bütün olası platformlar için mutlak doğruluk iddiasına çevrilmesin.

### ARCH-19 · Sözleşme Evrimi: Sürümleme, Capability ve Saf Migration

- **Hedef:** Modül API'si, disk oturum kaydı ve dış backend mesajlarının değişimi açık uyumluluk kararıyla yapılsın. Şema/semantik değiştiğinde desteklenen sürüm veya capability belirtilsin; yalnız alan adının bulunmasına bakıp yeni anlam varsayılmasın. Birbirinden bağımsız her private yardımcıya sürüm numarası ekleyen framework kurulmasın.
- **Dönüşüm sınırı:** Legacy → güncel domain migration'ı temsil sınırında bir kez yapılsın; saf, doğrulanan ve test edilebilir olsun. Migration süreç çalıştırmasın, credential açmasın veya kullanıcı dosyasını örtük yeniden yazmasın. Desteklenmeyen sürüm okunabilir hata versin; bozuk kaydı varsayılanlarla “başarılı restore” etmesin. Yazma gerekiyorsa eski kaydı koruyan mevcut persistence/transaction sözleşmesine uysun.
- **Capability ve bilinmeyenler:** Dış veride bilinmeyen alanı koruma/ret davranışı şemaya göre açık olsun; bilinmeyen alan yürütme yetkisi doğurmasın. Eksik, false, null ve unsupported ayrımları korunsun. Yeni adapter eski consumer'a, yeni consumer eski adapter'a bağlandığında fallback ancak anlamı ve güvenliği eşdeğerse yapılsın; aksi unavailable olsun. Yeni mesaj/şema geldi diye aktif run'ın yakalanmış sözleşmesi sessizce değişmesin.
- **Kapanış / bağımlılık:** ARCH-08/10/15, CHAT-02 ve MOD-08. Eski fixture, ileri sürüm, bilinmeyen alan, yanlış capability, migration hatası ve round-trip testleri; registry/config revision değişirken aktif iş ve restore senaryoları kapsansın. Geçiş bitince gereksiz legacy köprüleri kaldırılıp iki paralel domain temsili bırakılmasın.

## Modüller Arası İletişim ve Bağımsızlık Analizi (Tak-Çıkar / Plug-and-Play Modül Mimarisi)

Amaç her dosyayı ayrı paket yapmak değil; UI, ajan motoru, taşıma ve Emacs araçları arasında test edilebilir, gerektiğinde değiştirilebilir küçük sınırlar kurmaktır. Standart Emacs hooks/callback'leri ve mevcut public API'ler önce kullanılır; merkezi event bus, DI container veya her modülü bilen büyük engine nesnesi baştan zorunlu değildir.

### Genel Teşhis: Mevcut Sınırları Tamamla, Olmayan Bir Altyapıyı Varmış/Yokmuş Sayma

`state/hooks.el` bildirim/abonelik sunuyor; `loop` delta/finish callback'leri ve araç/stream observer'ları, `api/tools.el` public kayıt API'si, `async.el` görev sahipliği/iptali, `plan/store.el` typed plan kaydı zaten var. “Hiç arayüz veya headless çalışma yok” teşhisi fazla geniştir. Kalan sorunlar somut UI/loop geri bağımlılıkları, global runtime veri sahipliği ve facade ile altyapı sorumluluklarının karışmasıdır. Aşağıdaki maddeler mevcut sınırları tamamlar; aynı işi yapan ikinci katman kurmaz.

### MOD-01 · Döngü/UI Ayrımı: Mevcut Olayları Tamamla, Kontrol İsteklerini Ayrıştır

- **Dosyalar / kalan sınır:** `loop.el`, `loop/tools.el`, `loop/machine.el`, `loop/ui.el`, `chat/render.el`, `chat/stream.el`. Araç başlangıç/bitiş ve stream kancaları chat tarafından dinleniyor. Çekirdek kip komutu artık chat çağırmıyor; footer listener'ını composition mevcut `state-mode-hook` üzerine kuruyor, unload aboneliği kaldırıyor. Gereksiz global chat buffer listesi silindi; canlı görünüm listesi Emacs'ten türetiliyor. Motor/izin UI'yı yüklemeyen `kargu/confirm` portunu kullanıyor; adapter yokken karar güvenli ret. Kalan bağımlılıklar proje helper'ı ve bildirim bilgisi, olay kimlikleri ve uygulama/oturum sahipliği; mevcut UI pending listesi hâlâ paylaşılıyor.
- **Karar:** Mevcut delta/finish ve observer sözleşmelerini kullan; olaya run/session/request/call kimliği ve gerekli minimum payload ekle. Sonlandırma tek ve tutarlı rapor üretsin. Onay/turn-limit gibi cevap bekleyen kontrol istekleri ayrı asenkron porta gitsin; pasif observer sonucu yürütme yetkisi sayılmasın.
- **Sınır:** Observer hatası diğer dinleyicileri veya sonucu engellemesin; observer Stop/reset yaparsa sonrasında sahiplik tekrar denetlensin. Aboneliklerin ekleme/çıkarma ömrü ve event sırası açık olsun; ham sırlar varsayılan olay payload'ına konmasın. UI aboneliği olmadan karar gerektiren iş güvenli ret ile bitmeli, sessiz onay almamalı.
- **Kapanış:** Chat fonksiyonları stub'lanmadan headless engine testi; iki view, kapanan view, hatalı/reentrant listener, retry stream reset, tek finish ve prompt korunması. Yalnız kullanılmayan declaration'ları silmek işi kapatmaz.

### MOD-02 · Araç Sözleşmesi: Asenkron SPI ve Tek Yürütme Kapısı

- **Dosyalar / kalan sınır:** `tools/registry.el` açık handle alan typed kayıt servisi; `api/tools.el` public register/execute/policy uyumluluk kapısıdır. Araç modülleri geniş `api` facade'ını artık yüklemiyor; ancak varsayılan kayıt referansı hâlâ global, yürütme context'i ve modül close/unload sahipliği tamamlanmadı. Süreç, LSP ve onay callback gerektiriyor; yalnız senkron handler varsayımı geçerli değil.
- **Karar:** Mevcut kayıt API'sini dar bir tool portuna taşı; tanım (ad, şema, capability/etki politikası) ile kayıt/çalıştırma işlemini ayır. Yürütücü açık context ve tamamlanma callback'i alsın; iptal tanıtıcısı ile erken/geç sonuç davranışı tanımlansın. Eski senkron araçlar sınır adaptörüyle uyumlu kalabilir.
- **Sınır:** Ortak kapı availability/mode/schema, onay, log maskeleme, çıktı bütçesi, hata ve tek teslimi uygulasın. Aracın kendine özgü yol/argv/domain doğrulamasını “middleware var” diye kaldırma. Görünürlük yürütme yetkisi değildir; gizli/alias/doğrudan çağrı da kapıdan geçsin. Üçüncü taraf handler ve şema yüklemek güvenilmeyen kod için sandbox sağlamaz.
- **Kapanış:** Bağımsız handler testleri ve gerçek executor sözleşme testleri; sync/async/erken/çift cevap, eksik araç, alias, readonly kip, unavailable, iptal, kayıt çakışması ve unload. Top-level kayıt etkilerini composition noktasında idempotent register/unregister ile yönet; her aracı ayrı kütüphane yapmak şart değil.

### MOD-03 · Seçim UI'si ile Sağlayıcı/Model Durum Geçişini Ayır

- **Dosyalar / kod bulgusu:** `chat/select.el` Company/footer UI'si ile seçim uygulama mantığını birlikte içeriyor; `api/select.el` yalnız compatibility girişidir. `state/hooks.el` model/provider bildirimleri zaten var. Yeni paralel bir `model-changed-hook` yaratmak yerine bunlar değerlendirilmeli.
- **Karar:** Aday keşfi ve seçim doğrulaması UI'dan bağımsız servis olsun; chat/UI adapter'ı yalnız etkileşim ve görünümü yönetsin. Sağlayıcı/model/effort'un tutarlı seçimi tek doğrulanmış geçişle yayımlansın; oturum kaydı aynı seçimi görsün.
- **Sınır:** Aday listesi dışı değer reddi, effort yokluğu ile açık kapatma ayrımı, metadata capability'leri ve stale katalog nesli korunsun. Yapılandırılmış keşif örtük auth-source/pinentry beklemesine dönüşmesin (CONFIG-01). Arka plan keşfi başka sohbetin seçimini veya kullanıcının point'ini değiştirmesin.
- **Kapanış / bağımlılık:** ARCH-01, CHAT-01/02, CONFIG-01; headless seçim, iki sohbet, başarısız discovery/restore ve geç cevap testleri. İmleç taşıma yalnız açık kullanıcı etkileşimine ait UI adapter'ında kalsın.

### MOD-04 · Taşıma Portu: Döngüden Bağımsız İstek Ömrü

- **Dosyalar / kalan sınır:** `api/http.el` artık loop/chat çağırmıyor veya uygulama state'ini değiştirmiyor. Ham taşıma cleanup/cancel API'si ile client facade'ının legacy durum politikası ayrıldı; usage yalnız facade'ın single-delivery claim'inde sayılıyor. Client/loop/chat/UI kaynakları çıkarılmış paketle ham cleanup testi var. Kalan iş mevcut global request/generation/busy verisini sahipli logical-request handle'ına taşıma ve facade'ın aktif-koşu kararını uygulama context'ine bağlama; request kaydı, stream watch, retry ve geç/çift cevap korumaları korunmalı.
- **Karar:** Taşıma tek bir isteğin start/stream/finish/cancel sözleşmesini sunsun. UI/busy/loop durumu uygulama facade'ında yönetilsin; iptal handle'ı bir logical request'in bütün retry process/timer/SSE kaynaklarına sahip olsun. Mevcut `async` ve request korumalarını sadeleştirerek kullan, bir process nesnesini bütün isteğin kimliği sayma.
- **Sınır:** Eski isteğin cleanup'ı yeni isteği kapatmasın. Terminal SSE/EOF doğrulaması, başlangıç bariyeri, backoff, stall/deadline, circuit canary ve single-delivery korunmalı. Transport retry ile loop retry'nin bütçesi beraber sayılmalı (DEEP-09); sırlar handle loglarına sızmamalı.
- **Kapanış:** Loop/chat yüklenmeden fake transport testleri; init hatası, erken tamamlanma, iptal-backoff yarışı, kesik stream ve geç/çift cevap. Uyumluluk facade'ı taşındıktan sonra düşük seviye loop/UI referansları kaldırılsın.

### MOD-05 · Reset: Sıralı Koordinasyon ile Bildirim Kancalarını Ayır

- **Dosyalar / kalan sınır:** Resetin kritik sırası `application/reset.el` içinde: aktif loop/API iptali → yakalanmış hedef oturum temizliği → history/circuit/state → izole view bildirimi. `core/session.el` başka modülün verisine yazmıyor; chat reset listener'ını composition ile alıyor. İptal yeni iş/oturum başlatırsa reset eski hedefi yeniden doğrulayıp veri temizliğini reddediyor; bağımsız API cevabı nesille geçersizleşiyor. Geçmiş artık oturuma ait; kalan iş paylaşılan seçim/coordinator verisini açık context'e taşımak. History domain'indeki legacy cancel/prompt-cache etkisi, kritik ara adım hatasında atomik yayın/rollback ve provider/oturum kapsamında reset hâlâ tamamlanmadı.
- **Karar:** Uygulama composition katmanı resetin kritik sırasını koordine etsin: hedefi doğrula → sahipli işleri iptal/geçersiz kıl → yeni oturum neslini ve tutarlı başlangıç verisini yayımla → görünümü bilgilendir. Çekirdek genel reset API'si sunsun; opsiyonel modüller kapsamı belirli lifecycle bildirimleri dinleyebilsin.
- **Sınır:** Bütün reseti sırasız hook listesine taşımak atomiklik sağlamaz. Kritik geçiş hatası ile best-effort bildirim hatası ayrılmalı. Başka oturumun history/job/diff incelemesi ve sağlayıcı kapsamlı circuit verisi körlemesine sıfırlanmasın; politika kapsamı açık olsun.
- **Kapanış:** Aktif request/tool/approval/plan/compile varken reset; hook hatası, reentrancy, iki sohbet ve eski callback testleri. Headless reset chat oluşturmasın; başarısızlıkta yarım yayımlanmış durum kalmasın.

### MOD-06 · Planlama: Sahipli Plan Kaydını Dispatcher Portuyla Tamamla

- **Dosyalar / kalan sınır:** `plan/store.el` sahipli kayıt ve claim geçişlerini koruyor; kök/oturum ve current/preflight/dispatch/publish callback'leri readonly `kargu-plan-context` içinde. Plan çekirdeği chat/loop/state yüklemiyor; somut kimlik, kip hazırlığı ve transcript sunumu `chat/plan.el` composition adapter'ında. Headless dispatcher, başlangıç reddi/yeniden deneme ve tek claim kaynakları fiziksel olarak çıkarılmış paketle test ediliyor. Kalan iş asenkron kip hazırlığının açık tamamlanma/iptal sözleşmesi ve uygulama/oturum koordinatörüne bağlanması.
- **Karar:** Planı hazırlama/karar/dispatch sözleşmesini chat render'ından ayır. Yakalanmış plan kaydı ve uygulama dispatcher'ı, onaylanan plan revizyonunu bir kez yürütmeye aktarabilsin; chat ve ilerideki başka view'lar aynı portu kullansın.
- **Sınır:** Kullanıcı planı düzenleyebilme, iki kez onayı claim ile reddetme, kaynak oturum/kök kontrolü, kip hazırlığı ve başarısız başlangıçta taslağı koruma davranışları taşınmalı. Callback eklemek mevcut planın sahiplik korumalarını silme gerekçesi olmasın; aktif pencere yeni hedef seçmesin.
- **Kapanış:** Headless dispatcher, edit/approve/reject, geç kip hazırlığı, Stop/reset, kapatılan view, duplicate ve reentrant karar testleri; mevcut plan TLC ve regresyonları korunmalı.

### MOD-07 · Runtime Context: İzolasyonu Sağla, Gereksiz Çoklu Engine Tasarlama

- **Dosyalar / kod bulgusu:** `state/store.el`, `api/tools.el`, `providers/registry.el`. Global kayıt tanımları ile sohbet geçmişi/aktif istek gibi mutable runtime verisi aynı sahiplik sorunu değildir.
- **Karar:** ARCH-01 oturum kaydı, yakalanmış run context'i ve küçük servis portlarını kullan. Değişmez provider/tool tanımları paylaşılabilir; capability/kimlik bilgisi/istek sonucu/önbellek doğru provider/model/proje/oturum nesliyle anahtarlansın. Kayıt değişiklikleri revision ile izlenip çalışan run'a etkisi açıkça belirlenmeli.
- **Sınır:** Bu plan eşzamanlı çoklu ajan hedeflemiyor; uygulama genelindeki tek-koşu kuralı korunur, koordinatörün mutable durumu ARCH-12 uyarınca sahipli application context'ine taşınır. Her tabloyu kopyalayan veya bütün modülleri alan bir `kargu-engine` god object'i kurulmasın. İzole test fixture'ı ile birden fazla gerçek aktif koşu farklı gereksinimlerdir.
- **Kapanış / bağımlılık:** ARCH-01/08, MOD-02/04; iki oturumda seçim/geçmiş/önbellek ayrımı, kayıt değişimi, test restore ve kaynak leak kontrolleri. Gereken izolasyon en küçük context ile sağlansın; yeni instance API'si ancak somut tüketici gerektirirse eklensin.

### MOD-08 · Hibrit İstemci Hazırlığı: LLM Taşıması ile Tam Ajan Backend'ini Ayır

- **Durum / kapsam:** Gelecekteki üçüncü taraf ajan entegrasyonları için eksik mimari sözleşmedir; bu aşamada herhangi bir CLI/desktop entegrasyonu uygulanmaz. `loop`, `api`, tool portu, Emacs context servisleri ve UI arasındaki sınır hedeflenir.
- **Karar:** Doğrudan LLM completion/stream sağlayıcısı ile kendi tool loop'unu yürüten ajan backend'i ayrı portlar olsun. İkincisi capability keşfi, start/resume, olay akışı, approval, cancel ve oturum eşlemesini tanımlasın. Aynı işte yürütme sahibi ya Kargu loop'u ya dış ajan olsun; iki bağımsız loop aynı dosyaları eşzamanlı yönetmesin.
- **Sınır:** Emacs LSP/Dape bağlamı ve izinli araçlar isteğe bağlı servisler olarak sunulsun. Dosya yazımı, onay, debugger ve rollback sahibinin kim olduğu açık olsun; harici ajan Kargu'nun kontrol edemediği değişiklik yaparsa bunu Kargu onayından geçmiş gibi gösterme. MCP/IPC erişimi açık yetki, dar proje kapsamı ve bağlantı kimliği gerektirsin. Checkpoint/resume desteklenmiyorsa varmış gibi davranılmasın.
- **Kapanış / merge kapısı:** Önce yalnız fake LLM ve fake agent backend'leriyle aynı UI, tek global koşu, bağlantı kopması, duplicate/out-of-order olay, approval/Stop ve yabancı oturum testleri. Refactoring branch'in gerekli güvenlik/sahiplik kapıları tamamlanıp master'a merge edilmesinden sonra gerçek entegrasyonlar, o tarihte doğrulanmış resmi protokol/capability'lerle ayrı işler olsun; hepsinin “tek satır ayarla” değiştirilebilir olduğu vaat edilmesin.

### Modüler Dönüşüm Yol Haritası (Bağımlılık ve Kapanış Kapıları)

1. **Sözleşme ve kanıt:** Mevcut law/FSM, public API, olaylar, kaynak sahipleri ve headless yolları envanterle. ARCH-09..19 kurallarını değişen modüller için review/kapanış kapısı yap: bağımlılık matrisi, domain tip envanteri, giriş/çıkış validation sınırı, hata/uyumluluk sözleşmesi, geçiş tablosu, kaynak ömrü, global mutation whitelist'i, nesting ve algoritmik maliyet kaydı birlikte tutulsun. Contract suite ve hata enjeksiyonu bu kayıtların kabul ölçütü olsun. Kod bulgusu, yeniden üretilmiş hata ve ölçüm isteyen hipotezi ayır; kapalı DAPE işlerini yeniden hata listesine alma.
2. **Sahiplik ve güvenlik temeli:** ARCH-01/MOD-07 ile CHAT-01/02/03; ARCH-02/03 ile PERM-01; ARCH-05 ile DAPE-04/05. Önce veri kaybı/yetki ve stale callback riskleri; davranış koruyan küçük adımlar, tek-koşu sözleşmesi sabit.
3. **Portları tamamla:** MOD-01/03/04/05/06 ile mevcut hook/callback'leri tutarlı hâle getir; MOD-02 ile araç kayıt/yürütme kapısını ayır. Yapılandırma ve discovery disk/kimlik deposu beklemeleri CONFIG-01 ve PERF-04/05 kapsamında asenkron/iptal edilebilir olsun.
4. **Düzenleme işlemi:** DIFF-01/02 ve ARCH-04; üç girişi tek sahipli uygulama/inceleme/geri alma katmanında birleştir. DEEP-03 ikinci checkpoint motoru kurmaz. DEEP-01 baseline'ı aynı düzenleme planına bağlansın.
5. **Ölçümlü iyileştirmeler:** ARCH-07/08, PERF-01/02/03, TOOL-01 ve DEEP-04/07; süre/allocation/çıktı bütçesi ölç, hedefli değiştir. DEEP-02/05/09 yeni davranışlarını sınırlı politika ve FSM değişiklikleriyle ayrı uygula; ARCH-06 yerleşim deneyi zorunlu altyapı işi değildir.
6. **Merge ve sonraki entegrasyon:** Zorunlu güvenlik, sahiplik ve ortak port kapılarının açık engelleri kalmadığı; ilgili/tam ERT, byte-compile/checkdoc ve değişen modellerin exhaustive TLC sonucu ile belgelenmeli. Performans hipotezleri/opsiyonel UI deneyleri ayrı izlenebilir; kapanmamış güvenlik işini “opsiyonel” diye saklama. Kullanıcı onayıyla refactoring → master merge sonrasında MOD-08'in gerçek dış ajan adapter'ları ayrı planlanır; bu belge merge/push işlemini kendi başına başlatmaz.

DEEP-10..16, bu kapıların sistem düzeyindeki kabul senaryolarını tamamlar: çoklu yazıcı, çökme, kuyruk baskısı, koordinat dönüşümü, bağlantı güveni, veri ömrü ve modüllerin birlikte çalışması. Bunlar varsayımsal bir dağıtık sistem framework'ü kurma gerekçesi değildir. Önce desteklenen platform/özellik için garanti düzeyini seç; doğrulanmış veri kaybı/yetki risklerini zorunlu kapı, isteğe bağlı dayanıklılık yeteneklerini açık kapsam kararı olarak izle.

## İleri Seviye Sistemik Eksikler ve Gizli Karmaşıklık Analizi (Derinlemesine İnceleme)

Aşağıdaki kayıtlar üstteki işleri yok sayan yeni bir hata listesi değildir. Aynı kök neden çapraz referansla izlenir; yeni davranış gereksinimleri ve ölçüm isteyen riskler açıkça ayrılır. Varsayımsal maliyet/donma/sızıntı rakamları yeniden üretim olmadan kesin sonuç sayılmaz.

### DEEP-01 · Düzenleme Sonrası Doğrulama: Güncel Baseline ve Proje Etkisi

- **Dosyalar / kod bulgusu:** `loop/heal.el` error sayımı düzenlenen dosyanın bütün hatalarını sayıyor; footer modelden bunları düzeltmesini veya pre-existing olduğunu açıklamasını istiyor. Eski hata ile yeni regresyonun ayrı bir baseline karşılaştırması yok.
- **Karar:** Düzenleme öncesi güncel tanı snapshot'ını ve sonraki yerleşmiş snapshot'ı kaynak/sürüm/proje/oturum kimliğiyle bağla. Yeni/artan, önceden var olan, giderilen ve doğrulanamayan tanıları ayrı raporla. Baseline yoksa veya eskiyse “yeni hata yok/temiz” sonucuna düşme.
- **Sınır:** Yalnız düzenlenen satırlardaki hatalarla sınırlama: bir imza/import değişimi başka dosyalarda veya satırlarda hata yaratabilir. Konum kaymasını, duplicate tanıları ve source/code/message kimliğini hesaba kat; delta tek başına kesin nedensellik kanıtı değildir. Mevcut hataları gizleme veya kullanıcı kapsamını otomatik genişletme; healing adım/bütçe sınırı korunsun.
- **Kapanış / bağımlılık:** ARCH-04 ve diagnostic freshness; eski hatalı dosyada yorum değişimi, taşınan tanı, aynı sayıda ama farklı hata, çapraz dosya regresyonu, sürümsüz/eski push, unavailable ve iptal testleri. Baseline edinimi UI'ı bekletmesin; güvenilir kanıt yoksa unknown raporlansın.

### DEEP-02 · Sıkıştırma Politikası: Tek Limitten Sınırlı, İlerleme Ölçen Çok Aşamalı Tasarıma

- **Dosyalar / kod bulgusu:** `loop/compact.el` koşu başına bir compaction sınırı koyuyor; bu mevcut `skills.md`/FSM sözleşmesidir. Uzun koşularda ikinci taşmanın gerçekten hangi sonuç yoluna girdiği ayrı test ister; her zaman kontrolsüz 400/çökme olduğu iddiası kanıtlanmış değildir.
- **Karar:** Önce ikinci eşik/overflow davranışını test et. Çok aşamalı sıkıştırma istenirse açık, sınırlı bir politika olarak ekle: compaction adedi, token/zaman/istek bütçesi, minimum küçülme ve yeniden deneme histerezisi birlikte tanımlansın. Mevcut tek-compaction varsayılanı, yeni politika ve model onaylanmadan sessizce kaldırılmasın.
- **Sınır:** Sonsuz özetleme yok; küçülmeyen/boş/hatalı özet güvenli sonlansın. Kullanıcının amacı, açık tool-call/result çiftleri ve gerekli kanıtlar korunsun; özet talimat yetkisi kazanmasın. Retry, compaction ve devam sayaçları tek run bütçesini paylaşsın; Stop her aşamada çalışsın.
- **Kapanış:** İki ayrı bağlam taşması, bilinmeyen context kapasitesi, tek mesajın pencereyi aşması, compaction'ın kendisinin overflow olması, başarısız özet, geç cevap ve bütçe tükenmesi. Bu davranış değişiminde loop/compaction TLA+ ve exhaustive TLC güncellenmeli; salt limit silmek yeterli değildir.

### DEEP-03 · Çok Dosyalı İşlem: ARCH-04 ile Tek Kayıt, Yıkıcı Global Geri Dönüş Yok

- **Dosyalar / kod bulgusu:** `tools/diff/stage.el` inceleme politikasına bağlı çalışıyor, `diff/track.el` dosya snapshot'ları tutuyor; “her çağrı hemen yazar, hiç rollback yok” ifadesi yanlış. Eksik ortak batch sözleşmesi DIFF-01/02 ve ARCH-04'te izleniyor.
- **Karar:** Bu kayıt bağımsız bir Git stash/checkpoint motoru oluşturmaz; aynı düzenleme transaction'ına referanstır. Dosya/batch/koşu sınırları ayrı tanımlansın; başarısız koşu, daha önce insanın kabul ettiği bütün işleri otomatik geri alma yetkisi değildir.
- **Sınır / kapanış:** Otomatik `git reset --hard`, `git clean` veya kullanıcının index/stash alanını geri sarma yok. Git dışı dosyalar, untracked/kirli tamponlar ve araya giren kullanıcı değişiklikleri korunmalı. Git checkpoint'i ancak isteğe bağlı, kapsamı açık bir kolaylık olabilir; ARCH-04'ün snapshot/güvenli rollback testlerini geçmeden bu iş kapanmaz.

### DEEP-04 · İstem Boyutu ve Cache: Mevcut Sabit Öneki Koru, Tasarrufu Ölç

- **Dosyalar / kod bulgusu:** `prompt.el` dinamik ortamı `kargu-cache-runtime-boundary` sonuna koyuyor; `api/cache.el` sabit prefix ve araçlar için özel payload kopyasında cache işaretleri üretiyor. `tests/test-cache.el` bu ayrımı sınar. “Aktif dosya değişince bütün önbellek sıfırlanır” genellemesi mevcut yapıyı yansıtmıyor. Araç açıklamaları ise guidance içinde de tekrar ediliyor.
- **Karar:** Sabit politika/araç sıralaması ile değişken ortamı ayıran mevcut sınırı koru. Gereksiz araç açıklaması tekrarını, gerçekten gerekli kısa kullanım rehberinden ayır; capability kapalıyken araç adlarının istemden de çıkması garantisi kalsın. Ortam snapshot'ı yakalanmış run context'inden gelsin; her UI odağı değişimi yeni bağlam seçmesin.
- **Sınır:** Sistem politikasını sırf cache için kullanıcı mesajına taşıyarak talimat önceliğini bozma. Cache davranışı sağlayıcı/format metadata'sı ve gerçek usage ölçümüyle doğrulansın; bilinmeyen hit/maliyet sıfır sayılmasın. TTL dolması iç cache anahtarını değiştirebilir; içerik gerçekten değişmeden wire prefix bozulup bozulmadığını ayrıca ölç.
- **Kapanış:** Aynı içerik/yenilenen TTL, değişen ortam, değişen tool schema/model/kip ve wire format testleri; gönderilen token/byte ile bilinen cache kullanımını ölç. 15–20 bin token veya 3–4 kat hız iddiaları ölçüm olmadan kullanılmasın. İstem değişikliği davranış ve güvenlik regresyonlarıyla değerlendirilsin.

### DEEP-05 · Süreçler: Mevcut Job Yönetimini İnteraktif Oturum Sözleşmesiyle Tamamla

- **Dosyalar / kod bulgusu:** `tools/process.el` varsayılan timeout'u override etmeyi ve açık nil ile kapatmayı destekliyor; stdin normal batch süreçlerinde EOF ile kapanıyor. `tools/bash/jobs.el` zaten job ID/tablosu, foreground/background, bounded tail log ve cancel sunuyor. “Arka plan yönetimi hiç yok, her süreç katı 30 saniye” teşhisi çıkarıldı.
- **Karar:** Batch runner'ı bozmadan uzun yaşayan agent/CLI servisleri için ayrı session transport portu tanımla: start, bounded stream/read, isteğe bağlı send-input, graceful close ve kill. PTY yalnız gerçek ihtiyaç/capability varsa kullanılsın; EOF, idle süresi ve toplam deadline batch işinden farklı açık politikalar olsun.
- **Sınır:** Child PID'leri ve süreç grupları, stderr drainage, saklanan çıktı, başlatma bariyeri ve tek terminal sonuç korunmalı. Stop/reset/Emacs çıkışı/detach sonrası hangi sahipli işlerin yaşayacağı açık olsun; yabancı süreç öldürülmesin. Ham girişte parola/secret echo ve kaçış dizileri log/UI için güvenli işlenmeli.
- **Kapanış / bağımlılık:** Mevcut job API'siyle uzun test, sessiz daemon, stdin bekleyen CLI, başarısız spawn, çıktı taşması, child exit ve geç cancel; kontrollü fake/yerel süreç testleri. RISK-01 ayrı stres kanıtı ister; bu kayıt onu çözülmüş saymaz. MOD-08 gerçek entegrasyonundan önce session transport sözleşmesi test edilmeli.

### DEEP-06 · Günlük Gizliliği: Önce Veri Minimizasyonu, Sonra Katmanlı Maskeleme

- **Dosyalar / kod bulgusu:** `core/log.el` wire dump'ı içerik maskelemeden yazıyor; `api/retry.el` `kargu--log-out-payload` yalnız payload serileştiriyor, headers'ı özellikle dışarıda bırakıyor. Authorization header'larının bu yoldan doğrudan loglandığı gösterilmedi; ama prompt/tool sonucu veya upstream hata gövdesindeki sırlar logda kalabilir.
- **Karar:** Varsayılan loglar yalnız gerekli metadata'yı taşısın; wire içerik açık opt-in, sınırlı boyut/ömür ve kullanıcıya gizlilik uyarısıyla açılsın. Bilinen credential değerleri ve hassas yapılandırılmış alanlar, normal log/error/trace/export yollarının ortak sınırında yazılmadan önce maskelensin. URL query ve tool argümanları da değerlendirilsin.
- **Sınır:** `sk-`/Bearer regex'i bütün sırları yakalama garantisi değildir. Serbest kaynak metni için en güvenli seçenek kaydetmemektir; heuristik maskeleme ek savunmadır. Maskeleme hatasında ham veriye fallback yapma; exception/debug çıktısı da aynı politikaya tabi olsun. Sırlar üzerinde işlem yapan testler yalnız sentetik değer kullansın.
- **Kapanış:** Bilinen key, keyless istek, nested JSON, düz metin/bozuk JSON, upstream echo, URL ve secret içeren büyük/truncated içerik; log kapalı/açık, maskeleme hatası ve export testleri. Gizli veri örneklerini TODO/test fixture'ına gerçek değerleriyle ekleme.

### DEEP-07 · Log Performansı: Maliyet Hipotezini Ölç, Kesin Saklama Sınırını Koru

- **Dosyalar / kod bulgusu:** `core/log.el` normal log ve wire block sonrası `kargu--log-trim-buffer` çağırıyor; `delete-region` yalnız kapasite aşılınca çalışıyor. Her satırın bir milyon karakteri yeniden ayırdığı veya her çağrıda O(N) kopya yaptığı iddiası ölçüm olmadan doğru kabul edilemez.
- **Karar:** Yoğun küçük log ve tek büyük wire dump senaryolarında süre/allocation ölç. Darboğaz varsa her trim'de daha büyük eski bir parçayı silip düşük su seviyesine inmek veya bounded kayıt kuyruğu kullanmak değerlendirilsin; tercih benchmark ile yapılsın.
- **Sınır:** “Sınırı %20 aşana kadar bekle” mevcut kesin retention cap'ini sessizce gevşetmesin. Boyut/öğe/byte politikasını açık tanımla; sıfır retention, tek aşırı büyük mesaj, Unicode, fontification/undo ve point/narrowing davranışı korunsun. Redaction'dan önce ham büyük içeriği geçici/log tamponuna yazma (DEEP-06).
- **Kapanış:** Kırpma çağrısı ile gerçek silme sayısını ayrı ölç; izin verilen saklama sınırını her yazım sonrası test et. Performans kazancı gösterilemiyorsa daha karmaşık ring-buffer motoru ekleme; mevcut doğruluk testlerini koru.

### DEEP-08 · Bağlam Güven Sınırı: Proje Metni veya Araç Çıktısı Yetki Değildir

- **Durum / dosyalar:** Mimari güvenlik gereksinimi; bu incelemede yeni bir exploit doğrulanmadı. `prompt.el` talimat dosyaları, `history` mesajları, araç/ağ çıktıları ve gelecekteki MOD-08 context aktarımı birlikte ele alınmalı.
- **Karar:** Kullanıcı talimatı, açıkça güvenilen proje politikası, model önerisi ve dış içerik ayrı köken/scope ile taşınsın. Proje talimatlarının güven politikası görünür olsun; araç sonucu/web/dosya içindeki “kuralları değiştir/şunu çalıştır” metni onay veya yüksek öncelikli talimata dönüşmesin. Yürütme yetkisi her zaman programatik tool/izin kapısında denetlensin.
- **Sınır:** Prompt etiketleri tek başına sandbox değildir. Salt okuma da veri sızdırabilir: hangi dosya/secrets'in hangi uzak sağlayıcıya veya agent servisine gönderileceği açık bağlam/egress politikasıyla sınırlandırılsın; symlink ve dış MCP servisleri kapsamı büyütmesin. Yanlışlıkla bütün process environment/credential context'e eklenmesin.
- **Kapanış:** Sentetik prompt-injection içerikli dosya/tool sonucu, güvenilmeyen proje talimatı, dış köke yönlendirme, secret bağlamı ve backend değişimi fixture'ları. Testler modelin itaatini güvenlik garantisi saymasın; yetkisiz yürütme/veri aktarımı kapıda reddedilebilsin.

### DEEP-09 · Birleşik Bütçe: İç İçe Retry, Healing ve Compaction Çarpanını Sınırla

- **Dosyalar / kod bulgusu:** `api/retry.el`, `loop/machine.el`, `loop/compact.el` ve `loop/heal.el` farklı limitler tutuyor. Her biri sınırlı olsa da birleşik istek/zaman/token maliyeti ayrıca tanımlanmalı; somut “maliyet patlaması” bu turda ölçülmedi.
- **Karar:** Run'a ait toplam istek sayısı, geçen süre, çıktı/context ve biliniyorsa token bütçesi tanımla. Normal istek, transport retry, loop retry, healing, compaction ve devam aynı muhasebeye girsin; bir alt katmanın sayacı sıfırlaması üst bütçeyi yenilemesin.
- **Sınır:** Bilinmeyen usage/maliyet uydurulmasın; gözlenen tüketim ile tahmin ayrı raporlansın. Bütçe bitince yeni iş başlatma, sahipli işleri iptal/sonlandır ve kullanıcıya kısmi sonucu doğru bildir. İnsanın açık devam kararı belirli bütçeyi genişletebilir; Stop ve circuit-breaker korumasını devre dışı bırakmasın.
- **Kapanış / bağımlılık:** MOD-04, DEEP-01/02/05; retry içinde retry, compaction retry, healing, geç usage ve Stop/deadline testleri. Deterministik fake zaman/transport ile üst sınırların aşılmadığı doğrulansın; bütçe FSM'i değişiyorsa ilgili TLC modeli güncellensin.

### DEEP-10 · Birden Fazla Yazıcı: Tek Koşu, Kaynak Üzerinde Tek Yazıcı Demek Değildir

- **Durum / eksik sınır:** Mimari tutarlılık gereksinimi; yeni bir yarış bu turda yeniden üretilmedi. ARCH-01/12 tek uygulamadaki aktif koşuyu sınırlar, fakat kullanıcı, formatter, Git, başka Emacs veya dış ajan aynı dosya/oturum kaydını değiştirebilir. Bütün girdilerin geçerli olması, iki geçerli yazmanın doğru sırayla uygulanacağını garanti etmez.
- **Karar:** Her değişebilir kaynak için kimlik, beklenen revision ve commit noktası tanımla. Aynı uygulamada çakışan yazmaları kaynak sahibi sıraya alsın veya conflict ile reddetsin. Snapshot hazırlanırken değil, değişiklik yayımlanmadan hemen önce de beklenen sürümü doğrula; restore/save/rename/delete ve session kaydı güncellemesi bu sözleşmeye dahil olsun. Birden çok kaynakta kilit gerekiyorsa tutarlı edinme sırası ve iptal davranışı belirlensin; insan onayı beklerken uzun süreli kilit tutulmasın.
- **Sınır:** Tek `buffer-chars-modified-tick`, mtime veya uygulama içi kilit dış yazıcıyı bütünüyle denetlemez. İki süreçte read-check-write arasındaki yarış, kanonik path'in yeniden atanması ve symlink değişimi ayrıca ele alınmalı. Kullanılan dosya sistemi/API atomik compare-and-swap veya eşdeğer koruma sağlamıyorsa bu açıkça bildirilsin; “kesin atomik” iddiası yerine desteklenen garanti ve conflict/unknown davranışı yazılsın. Yabancı writer'ın işbirliği yapmadığı durumda sessiz overwrite çözüm değildir.
- **Kapanış / bağımlılık:** ARCH-04/15/17, CHAT-02 ve DEEP-03. İki Emacs/süreçle aynı kaydı kaydetme, onay sırasında formatter/checkout, silinip yeniden oluşturulan hedef, rename/symlink değişimi, çok kaynaklı işlemde ters sıra ve iptal testleri. Stale veri yeni veriyi ezmemeli; kilit veya conflict başka projenin bağımsız okumasını gereksiz bloke etmemeli.

### DEEP-11 · Çökme ve Yeniden Başlatma: Rollback, Crash Recovery Yerine Geçmez

- **Dosyalar / kod bulgusu:** `chat/session/storage.el` özel geçici dosya + rename ile tek kayıt yayımlıyor ve hata halinde eski kaydı koruyor. Bu değerli sınır; ancak tek dosyanın atomic publication'ı çok dosyalı batch, güç kaybı dayanıklılığı veya dış backend işleminin tamamlandığını birlikte garanti etmez. ARCH-04 de çökme garantisini ayrıca tasarlamadan vaat etmiyor.
- **Karar:** Desteklenen garanti düzeyini seç: süreç içi geri alma, normal yeniden başlatmada toparlanma ve güç kaybına dayanıklılık farklı hedeflerdir. Yarım işlem bilgisi tutulacaksa minimum gerekli revision/işlem/etki durumunu güvenli biçimde kaydet; bütün kaynak içeriğini ve sırları gereksiz journal'a kopyalama. Açılışta pending/committed/unknown ayrımı yapılsın; kullanıcıya uzlaştırma/inceleme seçeneği sunulsun. Journal zorunlu değilse yarım iş otomatik devam ettirilmesin ve kapsamın sınırı açık bildirilsin.
- **Sınır:** Process kill veya timeout, uzak işlemin başarısız olduğunu kanıtlamaz. Önceki onayları ve yazma komutlarını açılışta kör replay etme; restore edilmiş conversation çalışan run değildir. Yetki yeniden doğrulansın; idempotency/etki sorgusu yoksa belirsizlik korunsun. Durability isteniyorsa veri/dizin flush sırası, disk dolması ve dosya sistemi kısıtları platform bazında test edilsin; rename'e dayanarak güç kesilmesine karşı garanti verilmesin.
- **Kapanış / bağımlılık:** ARCH-04/16/17/19, MOD-05/08 ve DEEP-10/15. Geçici dosya oluşturma, birinci/sonuncu dosya commit'i, kayıt yayımlama ve backend cevabı öncesi/sonrası kontrollü süreç sonlandırma; eksik/bozuk kayıt, disk dolması ve yeniden başlatma testleri. Recovery mevcut kullanıcı değişikliklerini ezmesin, eski onayı diriltmesin, gizli veriyi açığa çıkarmasın; cleanup yalnız sahipliği kanıtlanan artıkları kapsasın.

### DEEP-12 · Backpressure: Tekil Limitler, Toplam Kuyruk ve UI Gecikmesini Sınırlamaz

- **Dosyalar / kod bulgusu:** `api/sse.el` ham cevabı process buffer'a eklerken eksik satırı ayrıca biriktiriyor; `api/stream.el` ve `chat/stream.el` de ayrı toplama/sunum aşamaları içeriyor. Tool/archive/log boyut sınırları başka katmanlara ait. Buradan ölçülmüş bir bellek taşması sonucu çıkarılmadı; bütün boru hattının toplam sınırı ayrıca doğrulanmalı.
- **Karar:** Raw byte, eksik UTF-8/satır, tek SSE event, birikmiş text/tool-call, pending event sayısı ve UI render kuyruğu için ayrı üst sınırlar ve toplam bütçe tanımla. Üretici tüketiciden hızlıysa bounded batch/coalescing, desteklenen transport backpressure veya güvenli iptal seçilsin. UI drain işi event-loop'a düzenli kontrol bıraksın; Stop/deadline uzun parse/render döngüsünün arkasında aç kalmasın.
- **Sınır:** İlerleme/token görüntüsü birleştirilebilir; onay, tool-call, protokol sonu ve terminal hata olayları sessizce atılamaz. Protocol zorunlu kaydı sığmıyorsa kontrollü hata ver; truncated içeriği geçerli JSON/başarılı araç sonucu gibi yürütme. Kuyruk bütçesi scope'lar birleşince aşılmasın. Idle ve toplam deadline ayrışsın; geçen süre mümkün olan yerde monoton zamanla ölçülsün, duvar saati değişimi negatif süre veya sınırsız bekleme yaratmasın.
- **Kapanış / bağımlılık:** ARCH-14/15/17, MOD-01/04 ve DEEP-05/09. Newline'sız/çok büyük event, byte byte Unicode, hızlı üretici-yavaş consumer, bloke/hatalı listener, event fırtınası ve saat ileri/geri sıçraması testleri. Sadece final string uzunluğu değil tepe birikim, pending sayısı, drain adımı ve Stop'a dönüş süresi de ölçülsün; limit ihlali tek terminal sonuç ve temiz kaynaklarla bitsin.

### DEEP-13 · Koordinat Sistemleri: Doğru Tip, Doğru Metin Konumu Demek Değildir

- **Durum / kapsam:** Mimari doğruluk gereksinimi; bu turda yeni konum hatası yeniden üretilmedi. ARCH-04 tam karakter aralığı ister, ARCH-10 birimleri adlandırır; Emacs point/karakter, dosya byte offset'i, LSP position encoding'i, DAP satır/sütunu ve diff satırı arasındaki dönüşüm de tek ve açık sözleşme gerektirir.
- **Karar:** Her adapter, koordinatın başlangıç tabanını, end-exclusive/inclusive sınırını, encoding/birimini ve ait olduğu belge revision'ını belirtip ortak kanonik aralığa dönüştürsün. Dönüşüm aynı snapshot üzerinde yapılsın; narrowing, satır sonu normalizasyonu veya disk/live buffer farkı gizlice ikinci metin oluşturmasın. Byte/karakter, UTF-16/diğer negotiated encoding ve satır/sütun dönüşümü domain işleminin içine dağıtılmasın.
- **Sınır:** Sembol adı ve satır numarası tek başına kimlik değildir. Range doğru göründüğü hâlde başka belge nesline ait olabilir; revision guard'ı kalsın. İmkânsız/sınır dışı koordinatı sessizce en yakın konuma sıkıştırarak başka kodu düzenleme; unsupported encoding açık unavailable/validation hatası versin. Sadece tanı göstermek ile o aralıkta yazma yapmak farklı güven gerektirir.
- **Kapanış / bağımlılık:** ARCH-04/10/15, LSP/Dape adapter'ları ve DEEP-01. Emoji/non-BMP karakter, combining işaretler, Türkçe karakter, tab, CRLF/LF, son newline yokluğu, boş dosya, çok uzun satır, daraltılmış/kirli tampon ve değişmiş revision fixture'ları. İleri/geri dönüşüm ve tam hedef metin testleri yapılsın; yanlış konumda sıfır yazma kanıtlansın.

### DEEP-14 · Bağlantı Güveni: Endpoint, Credential ve Capability Aynı Snapshot'a Bağlansın

- **Dosyalar / kapsam:** `config/key.el`, `api/client.el`, provider registry ve gelecekteki MOD-08 agent/MCP bağlantıları. Key/endpoint keşfi ve capability sahipliği ayrı ayrı ele alınıyor; bunların aynı güvenilen hedefe ait değişmez bağlantı sözleşmesiyle birlikte doğrulanması tamamlayıcı gereksinimdir. Credential sızıntısı veya endpoint saldırısı bu turda yeniden üretilmedi.
- **Karar:** Provider/model, protokol sürümü, endpoint veya yerel executable kimliği, credential kapsamı ve capability revision'ı request/connection snapshot'ında birlikte yakalansın. Retry aynı yetkili hedefi kullansın; config değişiminde eski onay/key yeni host'a veya farklı executable'a otomatik taşınmasın. Bağlantı yeniden kurulunca endpoint kimliği ve yetki kapsamı yeniden doğrulansın; oturum ID'sinin eşitliği tek başına eski güveni devralmasın.
- **Sınır:** TLS doğrulamasını kapatma, cross-origin redirect'te credential iletme veya hata üzerine başka sağlayıcıya sessiz fallback güvenli varsayılan değildir. Localhost adresi yerel servisin kimlik doğrulaması yerine geçmez; IPC/stdio/HTTP için kimlik ve erişim politikası ayrı belirlensin. Executable/PATH veya yerel config başka program çalıştırabiliyorsa açık güven sınırı olsun. Bu gereksinim webfetch SSRF doğrulamasını veya OS sandbox'ını kaldırmaz; aynı problem diye birleştirilmesin.
- **Kapanış / bağımlılık:** ARCH-02/15/19, MOD-03/04/08 ve DEEP-08. Gecikmiş keşif sırasında endpoint/key değişimi, başka origin'e redirect, yanlış TLS kimliği, capability kaybı, yeniden başlayan yerel servis ve executable değişimi fake/yerel fixture'larla sınansın. Testte gerçek credential kullanılmasın; yanlış hedefe veri/header gitmemesi doğrulansın. Gerçek backend entegrasyonunda resmi protokolün o tarihteki güven modeli ayrıca doğrulansın.

### DEEP-15 · Veri Ömrü: Log Maskeleme, Diskteki Bütün Kopyaları Yönetmez

- **Dosyalar / kapsam:** `chat/session/storage.el`, diff snapshot'ları, tool çıktı arşivleri, job tamponları ve gelecekteki recovery/session transport verisi. Session storage'ın yeni dosyaları özel oluşturması mevcut korumadır; bütün kullanıcı verisinin world-readable olduğu iddiası yoktur. DEEP-06 yalnız log yollarını kapsar; diğer kalıcı/geçici kopyalar ayrıca envanter ister.
- **Karar:** Her veri sınıfı için toplama amacı, konum, sahip, erişim izni, saklama süresi/boyutu ve silme/export davranışı belirlensin. Credential mümkünse yalnız işlem ömründe tutulsun; conversation, process environment veya ham wire kaydı yanlışlıkla persistence'a girmesin. Proje içi storage açık opt-in olarak kalsın; Git ignore veya kullanıcı index'i örtük değiştirilmesin.
- **Sınır:** Recovery, yedek, auto-save, temp alan, clipboard/export ve arşiv aynı verinin başka kopyalarını yaratabilir; “sohbeti sil” komutunun kapsamı açık olsun. Başka projenin, kullanıcının veya çalışan işin verisini quota/cleanup adına silme. Çökme artığı temizlenmeden sahiplik doğrulansın; symlink takip ederek yabancı dosya silinmesin. Normal dosya silme fiziksel güvenli silme garantisi değildir; şifreleme gerekiyorsa anahtar ömrü ayrı tasarlansın, varsayımsal kripto katmanı eklenmesin.
- **Kapanış / bağımlılık:** ARCH-17/19, DEEP-06/08/11. Sentetik sırlarla kayıt, export, quota, silme, reset, restart ve kullanıcı değişikliği testleri; storage mode/izinleri desteklenen platformda doğrulansın. Silinen/kalan kopyalar kullanıcıya doğru bildirilsin; retention değişikliği gizli veri birikimi veya sessiz veri kaybı üretmesin.

### DEEP-16 · Bileşim Doğruluğu: Doğru Modüller Kendiliğinden Doğru Sistem Oluşturmaz

- **Durum / eksik garanti:** ARCH-18 her portun sözleşmesini, ARCH-11 her makinenin geçişini test eder. Buna rağmen iki doğru FSM'in olay sırası, onay/commit noktası veya iptal semantiği uyumsuzsa sistem deadlock, çift etki veya yanlış başarı üretebilir. Bu kayıt yeni bir kanıtlanmış bug değil; ayrı test/proof sonuçlarının kapsamını yanlış genişletmeme gereğidir.
- **Karar:** Kritik kullanıcı senaryoları için uçtan uca invariant ve etki sırası yaz: tek run kabulü → sahipli context → doğru hedefe request → onaylı tool/diff commit → güncel verification → tek terminal rapor. “Mesaj ulaştı”, “istek kabul edildi”, “dosya değişti” ve “değişiklik doğrulandı” farklı kanıtlardır; UI/model raporu gerçekleşmemiş aşamayı olmuş saymasın. Approval identity ve veri revision'ı gerçek commit'e kadar izlenebilsin.
- **Sınır:** Tek callback teslimi, dış yan etkinin exactly-once gerçekleştiği anlamına gelmez; ARCH-16/DEEP-11 belirsiz sonucu korusun. Observer ve kontrol callback'leri birbiriyle cevap bekleyen çevrim kurmasın. Port sözleşmeleri minimum gerekli sıralamayı tanımlasın; her token için dağıtık event bus veya kalıcı event-sourcing zorunlu hâle getirilmesin. Redacted işlem kimliği/state izleri test ve tanıya yeterli olabilir.
- **Kapanış / bağımlılık:** ARCH-11/15/16/18, MOD-01..08 ve DEEP-10..15. Gerçek modüllerin fake dış sistemlerle birlikte koştuğu fault senaryoları: approval anında reset, commit sonrası cevap kaybı, compile sırasında Stop, stream biterken view kapanması, restart ve eski event, verification unavailable. Yetkisiz etki, çifte yürütme, sonsuz bekleme ve yanlış temiz/başarılı rapor oluşmasın. Değişen makine bileşimleri için sınırları açık entegrasyon modeli/TLC veya eşdeğer sistematik olay-sıralama taraması ekle; yerel proof'u bütün sistemin kanıtı diye sunma.

### TEST-01 · Eski ERT kaynaklarında checkdoc borcu

- **Kanıt:** 2026-10-20 bootstrap temizliğinde taranan 22 test dosyası, değişiklikten önce ve sonra aynı 73 checkdoc uyarısını verdi; yeni uyarı oluşmadı. `test-contract.el` gibi dosyalarda eksik `;;; Code:` bölümü, `test-fake-agent.el` yardımcılarında docstring'de anılmayan argümanlar ve tırnaksız fonksiyon referansları var. Bu sayı 73 çalışma zamanı hatası demek değildir; sentetik hata mesajlarına ilişkin linter yanlış pozitifleri de içerir. Byte-compile uyarılarıyla karıştırılmamalı.
- **İş / kapanış:** Gerçek başlık/docstring sorunlarını düzelt; fixture metinlerine ilişkin yanlış pozitifleri ayrıca sınıflandır. Test girdilerini, beklenen hata metinlerini veya test gövdelerini yalnız linter'ı susturmak için değiştirme; paket genelinde checkdoc kapatma. Gerçek uyarılar temizlensin, zorunlu istisnalar dar ve gerekçeli olsun; aynı ERT kapsamı ve uyarısız byte-compile korunsun.
