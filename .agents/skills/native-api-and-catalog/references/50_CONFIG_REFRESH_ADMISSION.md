# Config refresh admission / deadline kapanışı — 2026-10-26

Native parser portunun son concurrency incelemesinde üç somut açık kapatıldı.

1. Config refresh root yaratılmadan generation sayacı ilerliyordu. Parent zaten
   kapalıysa IO başlamasa bile henüz canlı olan başka refresh'in native cevabı
   stale sayılabiliyordu. Generation artık sadece canlı, kabul edilmiş root için
   ayrılır; admission öncesi nil kalır. Geçersiz owner'ın task/timer'ı da hemen
   iptal edilir. Kabul edilmeyen istek config state'ini değiştirmez.
2. Parent deadline geçmiş ama timer henüz dispatch edilmemişse pending state
   hâlâ true olabiliyordu. Root girişte mutlak deadline'ı denetler; bu durumda
   file worker/core startup/generation ilerlemesi olmadan hata verir. Canlı eski
   refresh native yanıtını normal yayınlayabilir.
3. `:timeout 0` eski root deadline'ını devre dışı bırakabiliyordu. Config refresh
   artık mevcut sabit 5 saniyelik worker sınırını daima korur. Pozitif timeout
   yalnız kısaltabilir; sıfır/negatif/geçersiz değer default bound'a döner,
   büyük değer sınırı uzatamaz. Parent'ın daha kısa deadline'ı yine kazanır.

Bu editor admission adapter'ındaki dar bir düzeltmedir; native file IO/config
publication/actor veya selection authority cutover'ı diye sunulmaz. Rust parser,
schema, private source tipi ve readonly epoch portu değişmedi. State reservation
ve IO sırası yeni domain motoruna çoğaltılmadı; mevcut tek service writer'ında
korunur. Genel async task davranışı veya başka caller timeout API'leri değişmedi.

Üç yeni ERT gerçek native parse yanıtını bekletir. Kapalı parent ve inactive
owner sıfır IO/startup/callback/timer ve aynı generation bırakır; eski held
cevap başarıyla yayınlanır. Timer-delivery gecikmesi testi aynı sonucu expired
parent için denetler ve root'a açık hata döner. Timeout matrisi nil/0/negatif/
geçersiz/çok büyük/kısa pozitif değerlerde hiçbir sınırsız reader bırakmaz.
İlk regresyon eski kodda generation `1 -> 2` assertion'ında kırıldı; fix sonrası
gerçek config reverse-completion ve cancellation testleriyle birlikte geçti.

Final **1260/1260 full source ERT**, 0 unexpected, **137.91 s**, **08:32:36
Europe/Istanbul** geçti. Kapalı parent-only ilk tam tarama da 1258 geçti;
son sürüm expired-parent/timeout/inactive-owner sınırlarını da içerir. İki değişen
Elisp Werror bytecompile/checkdoc temiz; elc yalnız task-specific /tmp dizininde.
Connection TLC **602836 generated / 101708 distinct**, queue 0, depth 22;
transport **1810 / 693**, queue 0, depth 13 ile **08:30:42**'de temiz tamamlandı.
TLC mevcut bounded lifecycle model regression'ıdır; concrete editor admission
veya tüm 01 uyumluluk/refinement ispatı değildir. Rust kaynağı değişmediği için
önceki 274 native + 18 compile-fail/fmt/Clippy tabanı korunur, yeni Rust özelliği
kanıtı diye sunulmaz. Kullanıcı 01/07/shell.nix ve gerçek config/credential
dosyaları korunur; kurulum, uzak API/hesap turu, merge/push veya canlı Emacs reload
yapılmadı.
