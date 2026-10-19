# Açık işler

Yalnız açık kayıtlar tutulur; kapanan ve yanlış pozitif kayıtlar silinir.
2026-10-19 incelemesi: 698/698 ERT geçti. Yeşil testler kapsanmayan hataları
çürütmez. K = kod yolu doğrulandı; Y = kontrollü yeniden üretildi;
D = ortam/ölçüm kanıtı gerekiyor. Kimlikler yeniden numaralanmaz.
P1 güvenlik/doğruluk, P2 yanıt verebilirlik/performans önceliğidir.

## Doğrulanmış hatalar — düzeltme sırası

### LSP-01 · P1 · Y — Proje raporuna yabancı dosya tanıları girebiliyor

- **Yer/kanıt:** `kargu/tools/lsp/diagnostics.el`, `kargu-lsp--collect-project-diagnostics`: native Flymake kayıtları sınır denetimi olmadan yayınlanıyor; kontrollü dış dosya kaydı raporda görüldü. Açık tampon adaylarında yalnız metinsel yol öneki var.
- **Beklenen/gerçek:** Yalnız yakalanmış kanonik proje kökü raporlanmalı; yabancı dosya/symlink kayıtları sızabiliyor.
- **Yeniden üretme/kapanış:** Native dış dosya, açık kaçan symlink, benzer isimli komşu kök. Yabancı adaylar içerik okunmadan/yayınlanmadan elenmeli; proje içi symlink korunmalı. Dosyalar örtük açılmamalı.

### LSP-02 · P1 · Y — Farklı sütun tanıları kayboluyor

- **Yer/kanıt:** `kargu/tools/lsp/diagnostics.el`, `kargu-lsp--group-diagnostics-by-file`: tekrar anahtarında sütun yok. Aynı dosya/satır/önem/mesaj ve iki farklı sütun tek kayıt verdi.
- **Beklenen/gerçek:** Ayrı konumlar ayrı kalmalı; farklı sütunlar birleştiriliyor.
- **Yeniden üretme/kapanış:** Sütun 1 ve 8 ayrı, tam tekrar tek olmalı. Alanlar metinsel ayraç çakışması olmadan karşılaştırılmalı.

### DAPE-01 · P1 · K — Seçili thread için durmuş/canlı olma izni eksik

- **Yer/kanıt:** `kargu/tools/dape/session.el` herhangi bir durmuş thread arıyor; `selection.el` seçili thread'i durumundan bağımsız yakalıyor. Dape 0.27.1 `dape--current-thread` durum kontrol etmiyor; `events.el` thread olaylarını nesle katmıyor.
- **Beklenen/gerçek:** İnceleme yakalanmış canlı/durmuş thread'e ait olmalı; başka thread durmuşken çalışan thread'in eski frame önbelleği kullanılabilir.
- **Yeniden üretme/kapanış:** Çalışan seçili thread + durmuş ikinci thread, `allThreadsStopped = false`, kısmi continue/exit, thread kimliği yeniden kullanımı ve geç stack/scopes/variables cevapları. Sessizce başka thread'e geçilmemeli.

### DAPE-02 · P1 · Y — Başlangıç bekleyicisi yabancı stop ile tamamlanıyor

- **Yer/kanıt:** `kargu/tools/dape/session.el`, `kargu-dape--wait-for-session-ready`: global stop kancası koşulsuz ready yayınlıyor. Bağlantı yokken global hook ile ready callback'i üretildi.
- **Beklenen/gerçek:** Yakalanmış proje/oturum/başlatma kimliğinin bağlantısı beklenmeli; yabancı start/stop beklemeyi etkileyebiliyor.
- **Yeniden üretme/kapanış:** Yabancı olay, kök/oturum değişimi, adapter değiştirme, kapatılan kaynak tamponu, Stop ve timeout; callback en fazla bir kez, timer/hook temizliği her çıkışta.

### DAPE-03 · P1 · K — Ertelenmiş compile devamı başlangıç sahipliğinden kopuyor

- **Yer/kanıt:** `kargu/tools/dape/preflight.el`, `kargu-dape-launch-config`: doğrulamadan sonra Dape çağrılıyor. Dape 0.27.1 compile callback'i bağlantıyı daha sonra Kargu sahipliğini yeniden doğrulamadan açıyor.
- **Beklenen/gerçek:** İptal edilmiş veya kökü/oturumu değişmiş başlatma bağlantı açmamalı; eski compile devamı açabilir.
- **Yeniden üretme/kapanış:** Compile callback'ini tut, koşuyu iptal et/kökü değiştir, callback'i bırak. İptal edilebilir başlatma kimliği ve compile sonrası doğrulama gerekli; yabancı compilation tamponu/kancası etkilenmemeli.
- **Bağımlılık:** DAPE-02 ile ortak başlatma sahipliği.

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

### CHAT-01 · P1 · K — Sohbet geçmişi ve sayaç sahipliği ayrılmamış

- **Yer/kanıt:** `kargu/core/session.el` sayaçları ve `kargu/history/protocol.el` geçmişi global. `kargu-chat-new` bağımsız sohbet açıyor; seçim aktivasyonu geçmiş/sayaç sahipliğini taşımıyor. Restore global değerleri değiştiriyor.
- **Beklenen/gerçek:** Sohbetler kendi geçmiş/sayaçlarını korumalı; ortak değerler ezilebiliyor. Global busy/aktif koşu tek-koşu sözleşmesidir, tek başına hata değildir.
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

- **Yer/kanıt:** `kargu/tools/diff.el`, `kargu-diff--resolve-read-target` tam metni alıyor; `kargu-diff-read-file` tüm metne `split-string` uyguluyor. Algoritma doğrulandı; belirli 100 MB eşiği/donma süresi ölçülmedi.
- **Beklenen/gerçek:** Küçük aralık tüm satır listesini gerektirmemeli; maliyet dosya boyutuyla büyüyor.
- **Yeniden üretme/kapanış:** Büyük dosyada dar aralık, uzun satır, büyüme, EOF, boş dosya, UTF-8 ve kirli/daraltılmış tampon; ölçümlü bellek/çıktı bütçesi ve unavailable/truncation sözleşmesi.

### PERF-02 · P2 · K — Geçmiş boyutu her kontrolde tam JSON ile hesaplanıyor

- **Yer/kanıt:** `kargu/history/compact.el`, `kargu-history-char-count`: bütün geçmiş `vconcat` ve `kargu-json-encode-record` üzerinden geçiyor.
- **Beklenen/gerçek:** Değişmeyen geçmişte hesap tekrar kullanılmalı; her kontrolde tam metin ayrılıyor. UI gecikmesinin büyüklüğü ölçülmeli.
- **Yeniden üretme/kapanış:** Sabit/büyüyen geçmişte serileştirme sayısı/bellek; repair, compaction, reset, restore ve içerik değişimlerinde önbellek doğruluğu.
- **Bağımlılık:** CHAT-01; PERF-03 ile ortak sahipli kuyruk sınırı.

### PERF-03 · P2 · K — Mesaj ekleme geçmiş listesini tekrar kopyalıyor

- **Yer/kanıt:** `kargu/history/protocol.el`, `kargu--history-add`; `kargu/api/response.el` asistan ekleme yolu. Sona `append` eski cons zincirini kopyalıyor; uzun ekleme dizisi O(N²).
- **Beklenen/gerçek:** Sahipli kuyruğa ekleme sabit maliyetli olmalı; toplam allocation karesel büyüyor.
- **Yeniden üretme/kapanış:** Uzun oturum allocation ölçümü; sıra/protokol, snapshot paylaşımı, repair/compaction/reset/restore. Sahiplik ayrılmadan `nconc` kullanılmamalı.
- **Bağımlılık:** CHAT-01.

### PERF-04 · P2 · K — Oturum listesi bütün kayıtları senkron ayrıştırıyor

- **Yer/kanıt:** `kargu/chat/session.el`, `kargu-session-list`: directory-files + döngüde `kargu-session-storage-read`. Tek dosya boyut sınırı toplam maliyeti sınırlamıyor.
- **Beklenen/gerçek:** Çok kayıt UI'ı meşgul etmemeli; bütün JSON içerikleri çağıranın iş parçacığında okunuyor. Gecikme ölçümü gerekli.
- **Yeniden üretme/kapanış:** Çok kayıt, bozuk/büyük kayıt, iptal, proje değişimi ve sıralama; asenkron listeleme veya metadata indeksi, eski sonuçlar yayınlanmamalı.

### PERF-05 · P2 · K — Sınırlı Dape kaynak disk işlemleri hâlâ senkron

- **Yer/kanıt:** `kargu/tools/dape/context.el` yol/metadata/sınırlı içerik okumasını çağıranın iş parçacığında yapıyor. 64 KiB disk / 65.536 canlı karakter sınırı mevcut; sınırsız büyük dosya okuma iddiası artık geçerli değil.
- **Beklenen/gerçek:** Yavaş/askıda yerel mount UI'ı bekletmemeli; byte sınırı süre garantisi değil.
- **Yeniden üretme/kapanış:** Kontrollü geciken yol/metadata/okuma, iptal, kaynak tampon nesli değişimi. Disk işi iptal edilebilir yardımcı süreçte; callback proje/oturum/koşu ve kaynak nesline bağlı, canlı tampon güncelliği korunmalı.

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
