# Native sohbet hedefi ve ham API-base — 2026-10-26

## Tamamlanan tüketici geçişi

Todo 1'deki upstream query kaybı kapatıldı: `kargu--api-base` artık yakalanmış
adresi metin değişikliği yapmadan döndürür. `kargu--strip-trailing-slashes`
silindi. Path sonundaki slash'ın normalize edilmesi, query değeri sonundaki
slash'ın silinmesi değildir; genel URL üstünde suffix regex kullanılamaz.

Ham base'i korumak tek başına yeterli değildi: normal sohbet tüketicisi eski
`kargu-api-chat-url` ile URL sonuna chat path ekliyordu. Bu fonksiyon da silindi.
Client artık yakalanmış base + chat-target intent gönderir; Elisp HTTP adapter'ı
yalnız bu intent'i mevcut transport'a taşır. Yeni bir editor URL engine'i,
senkron core sorgusu, actor veya metadata/config yazıcısı oluşturulmadı.

`api/request` DTO'sundaki kapalı `RequestTarget::{Exact,Chat}` sınırı chat'i
POST ve raw chat response profile'ıyla sınırlar. Eksik target `Exact` demektir:
doğrudan açık URL'ye çalışan low-level tüketiciler ve katalog GET değiştirilmez.
Normal client chat hedefi için `api_chat_target` capability'si ister. Eksik
capability application startup veya HTTP öncesinde hata verir; Elisp fallback
yoktur. Core rebuild + restart gerekir; canlı Emacs/core reload edilmedi.

## 01'e uygun domain sınırı

`api/wire/target.rs` içindeki özel alanlı `ChatPath`, serde/TryFrom sırasında
ayrıştırılır; sonraki path türetme fonksiyonu primitive string kabul etmez.
Statik path <=1024 byte, tek başlangıç slash'ı ve ASCII alnum `/ - . _ ~`
karakterleriyle sınırlıdır. Interior empty/dot segment, encoded path, query,
fragment, template, whitespace ve foreign-origin girişleri reddedilir.
Custom query parametreleri chat-path'e değil base'e yazılır. Eksik chat-path'in
varsayılanı `/chat/completions`, paketli Anthropic path'i `/messages` kalır.

URL crate yalnız path'i değiştirir; base origin, query, query sonundaki slash ve
encoded değerler korunur. Türetilen yeni endpoint toplam ApiEndpoint sınırından
geçer. **Final endpoint**, wire continuation scope ve API authority capture'ından
önce üretilir; native immutable HttpRequest retry'larda aynı değeri taşır. Path
her retry'da tekrar eklenmez. Salt projection için yapay lifecycle FSM yoktur;
I/O/actor/drain/cancel/admission motorları mevcut tek sahiplerinde kalır.

Yeni Debug/Display/Serialize secret yüzeyi, float, unchecked indexing, unsafe,
unwrap/expect/panic veya bağımlılık eklenmedi. Hatalar payload/query/key içermez.
Bu dar geçiş config parser/precedence/env/keyless veya provider/model seçiminin
native'e taşındığı anlamına gelmez; todo 1'in üst grubu açık kalır.

## Test sınırı

Üç yeni native test paketli/default/custom format path'lerini, base root/path
slash'larını, percent-encoded base path/query'yi, query sonundaki slash'ı,
malformed path/closed profile ve composition limitini kapsar. Eski endpoint
assertion'ları Elisp helper yerine bu gerçek native policy sınırına taşındı.

Dört yeni ERT gerçek geçici TOML refresh -> published config -> **mock'lanmamış
base reader** -> native port -> gerçek loopback GET/POST zincirini denetler.
OpenAPI ve Anthropic sohbeti, sorgu ve encoded değer kaybı olmadan tamamlanır;
snapshot raw base'i korur. Eski core capability testi sıfır owner startup/forward
call ve cleanup'ı, negatif fonksiyon testi silinen iki helper'ı denetler.
Mevcut gerçek retry testi de query/trailing slash ile güçlendirildi: config ve
format değişse bile iki HTTP isteği aynı ilk endpoint/key/body'yi kullanır.

Bounded connection/transport TLC modelleri regression içindir; yeni concrete
RequestTarget/ChatPath semantiğinin refinement ispatı veya tüm 01 sertifikası
değildir. Genel native config, run/history ve dört application backend'i açık.
Kullanıcının 01/07/shell.nix değişiklikleri korunur. Harici API/hesap/CLI turu,
login, credential taşıma, kurulum, merge/push yapılmadı.

## Doğrulama

**1249/1249 full source ERT**, 0 unexpected, **137.84 s**, **01:06:43
Europe/Istanbul** geçti. **269 native + 16 compile-fail** test, locked build,
fmt check ve strict all-targets Clippy temiz. Beş değişen üretim Elisp ve üç
değişen/yeni test dosyası Werror bytecompile + checkdoc temiz; bytecode yalnız
task-specific /tmp dizininde, kaynak ağacında elc yoktur. Ortamın OpenPGP autoload
mesajı derleyici uyarısı değildir; kapı sonuçları sıfır uyarıdır.

Mevcut connection TLC **602836 generated / 101708 distinct**, queue 0, depth 22
ile 01:04:27; transport TLC **1810 / 693**, queue 0, depth 12 ile 01:04:28'de
hatasız tamamlandı. Somut URL policy/model refinement ispatı iddia edilmez.
