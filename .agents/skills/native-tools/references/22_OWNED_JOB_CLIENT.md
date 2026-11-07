# Owned Emacs job adapter ve startup handoff

2026-10-24. 21'in üzerine ince istemci adapter'ı; Bash engine cutover'ı değildir.

`kargu/bridge/jobs.el` yalnız native UUID, captured connection/session/root,
source hook ve cleanup timer tutar. OS process, signal, PID authority veya
output archive sahipliği Elisp'e geri taşınmaz. Source kapanınca yalnız o job
cancel/drain edilir, terminal completion görülmeden archive forget edilmez.
Transport kaybı / cleanup deadline gerçek drain başarısı diye sunulmaz.
Forgotten handle yeniden RPC göndermez veya başka connection'a bağlanmaz.

Startup receipt kaybı için Rust'ta beş saniyelik explicit claim lease vardır.
İstemci source cleanup'ını receipt -> claim arasına kurar. Onaydan sonra source
kapanmışsa receipt sahiplenilmez; lease temizler. Aynı forward RPC id'nin
sonradan kullanılabilmesi nedeniyle eski RPC id job cancel yetkisi olamaz.

Legacy Bash'in stderr merge davranışı Rust'ta güvenli `nix::pipe2` / OwnedFd
üzerinden gerçek ortak pipe ile korunabilir. Ek shell wrapper veya komut
metnini değiştirme yoktur. Default structured tools ayrı stdout/stderr tutar.
Zero-output dahil output limit/retention/stderr exact onayda karşılaştırılır.

Environment değerleri çalıştırma için explicit ve immutable aktarılır fakat
onay ekranında yalnız anahtarlar gösterilir. Değerlerin görüntülenmemesi tam
eşitlik kontrolünü gevşetmez. Ham environment/payload loglanmaz.

Doğrulama: 65 Rust testi + 2 compile-fail; locked build/test, fmt ve strict
all-target Clippy başarılı. Yeni gerçek-core ERT testleri stdin/Unicode/EOF,
source close sibling isolation ve gerçek /proc temizliği, receipt sonrası
owner kaybı, environment değerlerinin ekranda görünmemesi ve forgotten handle
inertliğini kapsar. Full kaynak ERT 1156/1156 expected, 0 unexpected, 65.07 s.
Değişen üretim/test Elisp dosyaları warning-as-error bytecompile ve checkdoc
temiz; geçici .elc dosyaları kaldırıldı. Yeni job map/claim lease için eski
bounded modellerin refinement ispatı olduğu iddia edilmez.

İkinci küçük commit öncesi tamamlanan prerequisite: `bridge/job-output.el`
native byte page/status poll eder. Aynı anda tek read/status zinciri vardır;
en fazla üç incomplete UTF-8 byte tutulur, archive tekrar Elisp'te kopyalanmaz.
Output callback yalnız editor presentation içindir; terminal callback native
EOF + gerçek exited/drained sonucunu bekler. Consumer freshness callback'i
onay açılırken ve karar geldiğinde yeniden sınanır. Legacy permission snapshot
capture tek fonksiyona ayrıldı; eski approval yolları aynı snapshot'ı kullanır.
Sekiz odaklı job/output testi ve full ERT 1159/1159, 0 unexpected, 65.87 s;
warning-as-error bytecompile/checkdoc temiz, geçici .elc dosyaları kaldırıldı.

Sonraki dilim Bash consumer'dır: native output poll + incremental UTF-8,
editor output buffer presentation, foreground callback/background receipt,
project-scoped list/status/cancel ve owner cleanup. Eski Bash OS engine'i
ancak bu davranışlar aynı cutover'da bağlanınca silinir. Shared process.el ve
interactive session tüketicileri henüz taşınmadığı için silinmez.
