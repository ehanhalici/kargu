# 11. İPTAL, DRAIN VE GEÇMİŞ ONARIMI

İptal run'ın kaynaklarını kapatan, yan etkileri sınıflandıran ve history'yi
geçerli hale getiren idempotent bir işlemdir. HTTP stream drop sağlayıcı
tarafındaki üretim/faturalamanın kesin durduğunu garanti etmez.

## 1. İptal protokolü

Emacs chat/approval komutları C-g'yi explicit owner/run bağlamıyla
`session/abort` isteğine çevirir. Parametreler application_id, session_id,
run_id, generation ve reason'dır; method id taşıyan normal request'tir.
Global `keyboard-quit` bütün Emacs oturumlarını iptal edecek şekilde değiştirilmez.
Komutun interactive tanımı aktif chat sahibini çözer; eksik argümanla çökmez.

Core önce generation/publication yetkisini iptal eder ve admission'ı kapatır;
abort'a hızlı accepted/already_terminal yanıtı verir. Ardından child task'lar,
SSE, subprocess, reverse RPC ve approval'lara cancellation yayılır.
Run outcome ancak drain/history commit sonrası `event/run_finished` ile döner.
Bir child'ın iptali başka run veya application'a yayılmaz.

CancellationToken'ı taşımak yeterli değildir: her task select/checkpoint ile
izler; blocking worker cooperatively cancel edilir. Root task JoinSet/handle'ları
sahiplenir. Drop edilen future arka plandaki işi otomatik temizlemiş sayılmaz.

## 2. Süreç grubu kapatma

Spawn'da yeni Unix process group oluşturulur; PGID ve ownership kaydı child
çıkmadan yakalanır. Leader sonradan çıkmış olsa bile kayıt drain bitene kadar
korunur. İptalde:

1. Kayıtlı gruba SIGTERM gönder; stdout/stderr drain devam etsin.
2. Config'teki graceful shutdown süresini (varsayılan 5 s) bekle. Shell
   leader'ın çıkışı bütün descendant'ların bittiği anlamına gelmez.
3. Sahipliği hâlâ geçerli grupta kalan süreçlere SIGKILL uygula.
4. Direct child için `wait`/reap tamamla; pipe drain task'larını deadline ile
   bitir ve resource kaydını tek sefer kaldır.

Sadece `wait_with_output` future'ını timeout'ta drop etmek yeterli değildir.
Child handle supervisor'da kalır. SIGKILL sonrası da wait gerekir.
ESRCH zaten bitmiş olabilir; EPERM veya temizlenemeyen kaynak typed cleanup
hatası olarak raporlanır. Eski PID/PGID başka job'a yanlış sinyal gönderemez.

Process group, setsid ile kaçan veya daemonize olan bütün süreçleri kapsayan
OS sandbox değildir. İlk Linux hedefinde garantiler sıradan aynı-group
descendant'larla sınırlıdır; daha güçlü tree containment ayrı cgroup/supervisor
capability'si gerektirir. Core crash'i Drop ile temizlemek garanti değildir:
Emacs EOF/owner death ve process supervisor davranışı gerçek OS testleriyle
doğrulanır; recovery belirsiz kalan işleri `outcome_unknown` olarak işaretler.

## 3. Pending RPC, onay ve edit

Run'a ait pending request'ler take-once cancellation yolundan kapanır.
`rpc/cancel` karşı tarafa request_id ve scope ile bildirilir; yalnız Rust
oneshot'ını drop etmek açık minibuffer'ı kapatmaz. Emacs adapter'ı request'e ait
timer/hook/confirmation UI'yı kapatır. Geç approval/response/event inert'tir.
Sonuç göndermek için ölmüş core yeniden başlatılmaz.

Edit commit kritik bölgesinde cancellation sonucu doğrulanır: henüz uygulama
yoksa cancelled; tamamlandıysa actual revision ile applied; sonucu bilinmiyorsa
outcome_unknown. Uygulanmış dosya sırf C-g geldi diye uygulanmamış sayılmaz.
Rollback yalnız transaction'ın hâlâ sahip olduğu içerikte yapılır (06).

## 4. History onarımı

Onarım yalnız son mesaja bakmaz. Committed assistant batch'lerindeki çağrı
kimlikleri ve karşılıkları ledger üzerinden karşılaştırılır:

- Her committed tool_call_id için **tam bir** terminal sonuç bulunur.
- Zaten bitmiş sonuç korunur; cancel, error veya unknown sonuç yalnız eksik
  çağrılara sentezlenir. Paralel batch'te bir sonuç gelmişse diğerleri bulunur.
- Truncated SSE'deki tamamlanmamış arguments/tool-call fragment'i committed
  çağrı gibi yürütülmez. Provider adapter'ı interrupted stream durumunu korur.
- Sentetik sonuç sağlayıcı formatında serialize edilir; yalnız metin role'ü
  eklemek yeterli değildir. Complete assistant text, reasoning signature ve
  attachment blokları keyfi temizlenmez.
- Onarım ikinci kez çalıştırıldığında yeni sonuç eklemez. Gerçek sonuç ile
  sentetik sonuç yarışı ledger'ın tek yazıcısında çözülür.
- Unknown effect ile `hiç çalışmadı` ayrıdır; shell/edit otomatik tekrar edilmez.
  Kullanıcıya işlemin gerçek sonucu belirsiz olduğu söylenir.

Consecutive user veya boş assistant içerikleri evrensel olarak hatalı ilan
edilmez; wire family kuralları uygulanır. Tool çağrısı olan boş-text assistant
mesajı korunur. Sırf content boş diye geçerli multimodal mesaj silinmez.

## 5. Kabul kapısı

C-g şu noktalarda denenir: config/credential hazırlığı, SSE partial tool args,
approval, LSP/Dape pending request, process startup, bir kısmı bitmiş tool batch,
edit apply/save, compaction, verification ve reset. Tek/çift abort, timeout
yarışı, owner close, EOF ve core crash ayrı senaryolardır.

OS fixture: leader erken çıksın, descendant pipe'ı açık tutsun veya SIGTERM'i
yoksaysın. Direct child reap, output task drain, sıfır pending/approval/timer,
foreign job dokunulmazlığı ve tekrar kullanılabilir session doğrulanır.
TLA+ Application/Approval/Process/ProcessSession/Transport modelleri ilgili
geçişlerle eşlenir; gerçek OS kanıtının yerine geçirilmez.
