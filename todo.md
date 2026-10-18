## Uygulama kaydı

- [x] Başlangıç refactoring'i: LSP/DAP, HTTP ve sohbet sorumlulukları ayrıldı; süreç, oturum izolasyonu ve akış regresyonları giderildi. Doğrulama: 362/362 çevrimdışı ERT testi.
- [ ] Eglot'u isteğe bağlı yap; proje kapsamlı ortak araç yetenek kapısı.
- [ ] LSP isteklerini ve tüketicilerini asenkronlaştır.
- [ ] DAP callback zincirlerinde tek sonuç, hata ve iptal temizliği.
- [ ] Süresiz, izlenebilir ve iptal edilebilir Bash işleri.
- [ ] Debug ön koşulları, adapter yetenekleri ve araç kapsamı.
- [ ] OpenCode model kataloğu ve eşzamanlı istek teslimi.
- [ ] Sağlayıcıya özgü özel params özelliğini kaldır.
- [ ] Kararlı cache öneki, doğru wire işaretleri ve isteğe bağlı düşük tüketim.

Her adım testleriyle ayrı commit olarak kaydedilir. `skills.md` yereldir ve Git'e eklenmez. Ürün kararı gerektiren belirsizlikler aşağıda açık bırakılır.

## 2026-10-18 refactoring sırasında doğrulanan kapsamlı işler

### LSP isteklerini callback tabanlı hale getir

- Konum: `kargu/tools/lsp/context.el`, `kargu-lsp--request` ve `kargu-lsp--eglot-request`.
- Bulgu: Araçlar Eglot'un senkron istek yolunu veya `jsonrpc-request` kullanıyor. `kargu-lsp-request-timeout` beklemeyi sınırlar; isteği asenkron yapmaz. Yavaş dil sunucusunda araç ve istek hazırlama akışı yanıt bekler.
- Etkilenen akışlar: Proje iskeleti, belge sembolleri, tanım bulma, sembol okuma/düzenleme ve bunları kullanan tamamlama/istem hazırlığı.
- Yeniden üretim: Gecikmeli veya yanıt vermeyen bir dil sunucusunda `lsp_project_skeleton` ya da `read_file_symbols` çağır; mevcut çağrı timeout veya yanıt gelmeden sonuçlanmaz.
- Çözüm kapsamı: `jsonrpc-async-request` ile başarı/hata/timeout callback'leri; ardından çağıranların, araç executor'larının, önbelleklerin ve iptal kontrolünün birlikte taşınması. Yalnız `run-at-time` içine almak senkron beklemeyi çözmez.
- Kabul: Gecikmeli sahte sunucuda başlatıcı hemen döner; sonuç tam bir kez teslim edilir; iptal edilmiş koşunun sonucu uygulanmaz; araç izinleri ve çıktı biçimleri korunur.

### Gecikmeli DAP callback hatalarında araç sonucunu mutlaka tamamla

- Konum: `kargu/tools/dape/context.el`, özellikle `kargu-dape-get-context` içindeki stack → scopes → variables zinciri; aynı desen diğer DAP komutlarında da incelenmeli.
- Doğrulanan yeniden üretim: Sahte `dape--stack-trace` callback'ini sakla; `kargu-dape-get-context` döndükten sonra callback'i çalıştır ve `dape--scopes` içinde `adapter disconnected` hatası üret. Hata dışarı taşar; aracın sonuç callback'i çağrılmaz.
- Neden: Dıştaki `condition-case` yalnız ilk başlatma sırasında etkin. Daha sonra çalışan callback'in hatasını yakalamıyor. Ajan araç sonucunu beklerken kalabilir.
- Çözüm kapsamı: DAP zincirlerinde ortak hata teslimi, koşu/bağlantı geçerlilik kontrolü, tek teslim kapısı ve zincirin tamamı için timeout/temizlik. Her asenkron adımın başarısızlık yolu ele alınmalı.
- Kabul: Adapter bağlantısı her aşamada kesildiğinde veya istek hata verdiğinde tam bir ERROR sonucu teslim edilir; sonraki geç callback ikinci sonuç üretmez; koşu durdurulduğunda bekleyen iş temizlenir.

### Uzun surecek isler icin 30 sn sinirini esnet
- Su anda bir bash script cagrilacagi zaman sure siniri konuluyor, ama bu cok yanlis, belki saatler surecek bir script calisabilir
- bu scriptin calismasi kullanici tarafindan takip edilip iptal edilebilmeli, ama ne kadar uzun surerse sursun kargu bunu desteklemeli

### eglot zorunlulugunu kaldir
- bazi dillerin lsp serveri hic yok, eglot a bakarak lsp zorunlulugu verirsek bazi dillerde karguyu hic kullanamayiz
- eglot aktif degilse kullaniciya bir uyari yazisi goster, eglot aktif degil, lsp ile ilgili tool kullanimi ai a verilemeyecek de
- eglot aktif degilken lsp toollarinin kullanimini ai promtundan cikart, artik ai lsp toollarini kullanamasin onun yerine bash scriptleri ile aradigini bulsun

### debug icin dape ve kullanacagi dile ozel tool yoksa kullaniciya mesaj verdir ve debug moduna sokturtma
- debug modundan once kontrol yapilsin ve gerekli aracalar yoksa debug mododuna sokturtmasin
- debug modu su anda hicbir ai agent yoneticisi tarafindan desteklenmiyor, o yuzden mevzunun ne oldugunu cok iyi acikla ki ai bu toollari iyi kullanabilsin
- debug sirasinda kullanilabilecek tum ozellikleri tool olarak ai a saglayalim

### opencode hatasi
- opencode u provider olarak sectigimde modelleri listeleyemiyorum, bir bakar misin

### params tarafinda duzenleme
- istekleri ozellestirmek icin konulmustu ama ozellikle openrouter ustunden yapildi
- ancak her provider bunu desteklemeyebilir, kod karmasasi da olsuturdugu icin bu ozelligi kaldiralim
- openrouter ile bu ayarlari yapmak istersek zaten preset belirleyebiliyoruz, geri kalan da zaten bu ozellikleri az destekliyor, yani kaldir gitsin

### Koddaki karmasa
- kodda karmasa olabilir, state machine tarzi ve moduller arasi iletisimle bu sorunu coz,
- bussiness tarafinda ciddi bir karmasa varsa buraya not olarak al ona sonra karar verelim

### Cache hit
- cache hit oranini arttirmak ve dusuk tuketim modunda is yaptirmak icin sektor standardi tum teknikleri kullan

## Önceki kayıtlar için inceleme notları

- Streaming timeout: Güncel kod normal istek timeout'u ile streaming stall/ceiling sınırlarını ayırıyor. Eski logdaki 90 saniyelik curl timeout'u mevcut sürümde canlı sağlayıcıyla yeniden üretilmedi; kayıt açık bırakıldı.
- Yalnız düşünceyle biten yanıt: Döngüde artık ayrı `thought` sınıflandırması var. Eski sağlayıcı örneğinin tekrar doğrulanması gerekiyor.
- Araç hedefinin gösterimi: Güncel başlık kodu dosya/komut/URL gösteriyor ve dosya yolu için test var. Sorun sürerse araç adı, gerçek arguments ve görünen başlık birlikte kaydedilmeli.
- Akışı cümle bazında gösterme: Bu bir davranış/performans işi olarak açık. UI güncellemelerini birleştirmek sağlayıcının gönderdiği ağ verisini azaltmaz; metin/düşünce sırasını ve son parçanın flush edilmesini korumalı.
