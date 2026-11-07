# 06. KATMAN 2: UI, PLAN VE EDİT TRANSACTION

Rust domain state'in tek yazıcısıdır. Emacs buffer/window/marker/undo ve
kullanıcı etkileşimi durumunun sahibidir. İnce istemci hedefi satır sayısı
kotası değildir; doğruluk için gereken adapter mantığı korunur.

## 1. Chat ve kullanıcı komutları

chat/render, header, transcript, prompt, select, complete, tune ve UI/Transient
sunumu Emacs'te kalır. Rust model seçiminin/config'in kanonik değerini tutar;
Emacs picker'ı ve completion arayüzünü gösterir. Buffer routing Emacs
session_id -> live buffer eşlemesidir; agent kararı değildir.

Her event application/session/run/generation/sequence taşır (07).
Eski run parçaları kapatılan buffer'ı yeniden açmaz ve yeni yanıta eklenmez.
Markdown/code highlighting, transcript rolleri, prompt draft, scroll ve
pencere başına konum korunur. Render timer ile byte/zaman bütçeli batch
çalışır; JSON filter doğrudan token başına tüm pencereleri dolaşmaz.
TokenCount wire'da sayıdır; UI `350 tokens tokens` gibi iki kez etiketlemez.

Transcript ve log retention sınırlıdır: varsayılan chat view 2 MiB/session,
stderr/log view 1 MiB/connection tutar. Eski transcript sayfaları Rust session
store'dan istenir; view kırpılması history'yi silmez. Tek büyük event de limite
tabidir; overflow/truncation görünürdür. Kullanıcı değişiklikleri bulunan tool
output buffer'ı archive cleanup sırasında sahiplik doğrulanmadan silinmez.

Session persistence Rust'a taşınırken görünüm restore modeli 08'e göre
üretilir. Kullanıcının gönderilmemiş taslağı admission/credential hatasında
kaybolmaz. Backend seçimi session sahibinde kalır.

### Provider alanında API ve uygulama seçimi

Mevcut provider alanı kaldırılmaz; aynı picker içinde `API` ve `Uygulamalar`
grupları gösterilir. Rust'a taşınan doğrudan API sağlayıcıları korunur. Kurulu
Codex, Antigravity, Claude Code ve OpenCode uygulamaları ayrı backend
kayıtlarıdır; API endpoint takma adı değildir. Kanonik kayıt ve uygunluk
Rust'tan gelir; kurulum/probe/login işi Emacs process filter'ında yapılmaz.

Kurulu ve `Ready` uygulama seçilince prompt o adapter'a yönlenir. Kurulu ama
hazır olmayan kayıt görünür kalır; sürüm/protokol/login/probe nedeni ve gerekli
adım gösterilir, prompt gönderimi engellenir. Kurulu olmayan uygulama çalışır
seçim gibi sunulmaz. Durumların tek kaynağı 03 bölüm 0'dır. Picker açılması
yavaş probe yüzünden donmaz; refresh ve geç snapshot session/revision ile korunur.

Model/effort alanı seçilen backend'in capability'sinden üretilir; uygulamaya API
model listesi veya REST parametresi zorla uygulanmaz. Aktif run'da provider/
backend değişimi reddedilir; iptal ve drain tamamlanmadan yeni backend turn'ü
başlatılmaz. Idle seçiminde opaque external thread/history başka backend'de
kendiliğinden kullanılmaz; session binding/uyumluluk kararı açıkça uygulanır.
Kurulu uygulama desteği ve MCP tool sunumu UI'da birbirinin yerine gösterilmez.

## 2. Plan modu ve mod değişimi

plan/store, context, dispatch domain kuralları Rust'a taşınır; plan/buffer ve
chat/plan presenter Emacs'te kalır. Plan artifact_id, owner, source revision,
review revision, mode ve tek kullanımlık dispatch claim taşır. Kaynak/review
kapanması, major-mode değişmesi veya supersede approval'ı geçersiz kılar.
Dispatch başarısızsa approval tüketilmez; kabul edilmiş dispatch presenter
hatasıyla geri alınmaz. Eski buton yeni planı çalıştıramaz.

application/mode'daki debug preflight, read-only ve diğer mevcut modlar
isim/semantik eşlemesiyle korunur. Mode değişimi asenkron hazırlanır; geç
hazırlık sonucu başka selection/session'a uygulanmaz. Başarılı preflight
olmadan debug capability ilan edilmez.

## 3. Edit service: tek transaction sınırı

tools/diff, edit.el ve LSP symbol edit aynı edit servisini kullanır.
Rust diff/patch parsing, hunk ve review domain kaydını; Emacs canlı metin
değişimini yönetir. Diff üretimi patch uygulama/validation yerine geçmez.

Her teklif `edit_id`, owner/run/generation, canonical root, dosya listesi,
base content hash, disk identity/revision, varsa document_id + buffer tick,
proposed hash/content ve explicit save policy içerir. Approval ve review bu
değişmez teklife bağlıdır. Dosya kapsamı veya içerik değişince tekrar review
gerekir. Çok dosyalı işlem preflight edilmeden ilk dosya değiştirilmez.

`editor/apply_buffer_patch` yalnız gate tarafından yetkilendirilmiş edit_id ile
çağrılır. Emacs şu sırayı uygular:

1. Scope, canonical path, canlı tampon kimliği, read-only durumu, buffer tick,
   base hash ve disk revizyonunu yeniden doğrular.
2. Dirty buffer'ın güncel metnini kaynak kabul eder. Eşleşmiyorsa `conflict`
   döner; otomatik erase/overwrite/save yapılmaz.
3. Daraltılmış tamponda widen eder; atomic change group içinde kontrollü
   replacement uygular. Undo/point/marker/coding/EOL davranışı korunur.
4. Save policy `buffer_only` veya `save` açıkça belirtilir. Save-hook'un
   değiştirdiği son içerik/hash ayrıca raporlanır; hook hatası başarı değildir.
5. Terminal sonuçta uygulanan/uygulanmayan dosyaları ve yeni revizyonları döner.
   Rollback yalnız hâlâ transaction'ın yazdığı revizyondaysa yapılır;
   sonradan oluşmuş kullanıcı değişikliği ezilmez.

İlk geçişte açık/kapalı **bütün editör dosyaları** Emacs edit adapter'ından
geçer; Rust'ın paralel disk yazma yolu açılmaz. Headless kullanımda ayrı bir
disk edit adapter'ı seçilebilir; canlı editör sahibi yokluğu açıkça bilinmelidir.
Bu adapter aynı dizinde unique create_new tempfile, mode koruma, doğrulama,
rename ve uygun sync kullanır; sabit `.kargu_tmp` dosyası kullanmaz.
Canonicalize + rename işlemi tek başına filesystem CAS değildir. Symlink
yarışı ve çok dosyalı crash atomicity garantisi kanıt olmadan verilmez.

Çok dosyalı transaction process-local koordinasyon/geri alma sağlar; crash
anında kısmi uygulama olasılığı journal ve recovery ile raporlanır. Save veya
network filesystem hatası bütün batch başarılıymış gibi gizlenmez.

## 4. Review ve confirmation

Diff buffer edit_id ve review revision'a bağlıdır; accept/reject Rust'a karar
gönderir, core sonucu alınmadan `uygulandı` yazmaz. Ediff sadece sunum değildir;
orada düzenlenen içerik yeni proposed revision olarak tekrar doğrulanır.
smerge yalnız gerçek conflict-marker içerikleri için kullanılır.

Approval `approval_id`, scope, action digest, cwd/root, args, config/policy
revision, deadline ve kararı taşır. Sunucu tek kullanımlık kayıt tutar;
rastgele UUID'nin kendisi kriptografik komut imzası sayılmaz.
Karar sonrası yürütme anında koşullar yeniden doğrulanır. Headless/missing UI
reddeder. Reject, timeout ve C-g ayrıdır. Sonuç metnini eşleştirerek karar verilmez.

Onay sunumu process filter dışında zamanlanır. Async presenter veya iptal/
timeout temizliği olan minibuffer kullanılır. Aynı anda gelen onaylar UI'da
sıraya alınır; iç içe y-or-n-p açılmaz. Geç yanıt iptal edilmiş grant'i canlandırmaz.
300 saniye yalnız approval deadline'dır; sensörler 10 saniyelik ayrı deadline taşır.

## 5. Kabul kapısı

test-chat*, test-plan*, test-confirm, test-mode-ownership, test-patch,
test-edit-service ve test-edit-transaction kapsamı korunur. Yeni fixture'lar
stale review, dirty buffer, undo, save-hook mutation/failure, foreign edit,
partial multi-file failure, owner closure ve duplicate apply'ı test eder.
Duplicate edit_id önceki sonucu verir veya stale döner; ikinci kez uygulanmaz.

Provider kabulü: aynı picker'da API ve dört uygulama; kurulu/kurulu değil,
ready/needs-login/unsupported/probe-failure görünümleri, backend'e göre model
seçenekleri, aktif run'da değişim reddi ve iki session'da bağımsız seçim.
Antigravity MCP-only bağlantısı seçilebilir chat backend başarısı sayılmaz.
