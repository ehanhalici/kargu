# Setup son-tüketici bağlantısı ve credential facade silme — 2026-10-26

## Kapsam

Todo 1'in setup alt işi tamamlandı; native config/endpoint policy üst maddesi
tamamlanmadı. Bu bir Rust parser/credential reader uygulaması değildir. Setup,
native API tüketicilerinin mevcut ortak connection/credential interop portuna
bağlandı. Emacs'in zorunlu auth-source ve UI adapter'ı korunur; yeni HTTP,
credential dispatch veya metadata motoru kurulmadı.

`config/setup.el` küçük, autoload edilen origin-owned UI lifecycle adapter'ıdır.
Config refresh ve credential child aynı root/parent/deadline altındadır. Root
agent Stop'tan bağımsızdır; tekrar kontrol yalnız aynı buffer'ın eski root'unu
iptal eder. Kill/mode/timeout bütün child'ları kapatır; session/selection veya
application-owner değişimi geç başarı raporunu reddeder. Kontrol mevcut chat'in
bound connection'ını kullanmaz. Raporda provider/model frozen snapshot'tan gelir;
başka application current olsa bile ilk owner korunur.

Root terminal cleanup'ı callback'ten önce çalıştığından credential scope'u erken
cleanup'a bağlayıp rapora boş key geçirmek doğru değildir. Resolver callback'i
`unwind-protect` ile snapshot scope'unu rapor/discard sonrasında kapatır; reporter
ayrıca kendi accessor kopyasını temizler. Rapor exception'ı veya stale selection
bu temizliği atlayamaz. Bu yalnız sahip olunan kopyalar içindir; config, worker,
transport, debugger veya GC'deki bütün bellek için secure erasure iddiası yoktur.

## Silinen Elisp ve yeni bulgu

Setup, key-only async facade'ın son production tüketicisiydi. Artık şu ayrı
yollar yoktur:

- `kargu-config-resolve-api-key-async`
- `kargu-config--dispatch-key`
- `kargu-config--deliver-key-result`
- key.el içinde bu yollara özel imports ve revision declaration'ı.

Eski credential fixture aynı unsupported/cancel/late-result davranışını ortak
connection portunda denetler; silinen facade test uğruna tutulmaz. Cold schema
autoload gerçek ayrı Emacs process'inde API facade yüklemeden çalışır.

İncelemede `_setup-problems`, sonu `...` olan credential'ı placeholder sayıp
tam metnini warning'e koyuyordu. Genel placeholder metnine geçirildi; sentetik
`secret-prefix...` testi hem UI hem log'un key'i içermediğini denetler. G03'ün
diğer redaction/retention/export yükümlülükleri bundan dolayı kapanmaz.

Bir başka takip sınırı: mevcut setup `ready` raporu native binary/protokol veya
upstream model sağlığı kanıtı değildir. Setup model/metadata isteği başlatmaz;
binary denetimi gerçek bridge startup'ındadır. Bu ayrım release kabulü altında
todo 10'a açık alt iş olarak eklendi; sessiz probe veya yeni ürün kararı alınmadı.

## Doğrulama

- 10 yeni setup ERT: staged iki aşama, cancel/kill/mode/deadline, iki application,
  ayrı buffer/replacement, stale selection, redacted failure, callback exception,
  gerçek config child, cold autoload ve deleted-facade absence.
- **1236/1236 full source ERT**, 0 unexpected, **137.45 s**, 00:12:44 +0300.
- **259 native + 16 compile-fail**, fmt ve strict all-targets Clippy geçti.
  Rust production kaynağı değişmedi; bu sayılar tekrar çalıştırılan mevcut
  core regresyonudur, yeni Rust config implementation kanıtı değildir.
- Üç production Elisp + yeni test Werror bytecompile/checkdoc temiz.
  Elc çıktıları /tmp task dizinine gider, kaynakta bytecode bırakılmaz.
- Mevcut `--connection` TLC exhaustive: **602836 generated / 101708 distinct**,
  queue 0, depth 22; 00:12:58 +0300, hatasız. Bu bounded hazırlık modelinin
  tekrar taramasıdır; yeni UI facade'ın somut refinement/secure-erasure ispatı
  veya tüm Rust/01 uygunluk sertifikası değildir.

İlk repeated-check fixture with-temp-buffer'ın exit davranışını normal UI
kill-hook'u sanıyordu. Explicit oluşturulan/kapatılan gerçek origin'e geçirildi;
izolasyon assertion'ı düşürülmedi. Mevcut metadata/config/connection/optional
module fixture'ları korunur; module dependency baseline genişletilmedi.
Kullanıcının shell.nix/07 değişiklikleri ve 01 korunur. Uzak model/hesap/CLI
turu, credential taşıma, kurulum, merge veya push yapılmadı.
