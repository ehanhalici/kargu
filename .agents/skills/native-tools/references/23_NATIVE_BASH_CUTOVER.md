# Bash: Rust process engine, ince Emacs görünümü

2026-10-24. 20–22 prerequisite'leri ardından canlı Bash consumer cutover'ı.

## Tek engine ve modüler sınır

`kargu/tools/bash/native.el` mevcut tool schema/alias ve editor `exec-path`
seçimini koruyup explicit shell + ["-c", command] argv'sini Rust job portuna
aktarır. Shell betiği değiştirilmez. Rust onay, spawn, PGID, stdin EOF,
timeout, bounded rolling archive, TERM/grace/KILL ve reap/drain sahibidir.
`bash.el` ve `bash/jobs.el` içindeki eski OS runner, process/pid/pgid alanı,
process-live-p kontrolü ve signal/cancel implementasyonu kaldırıldı.
Missing core durumunda Elisp replay/fallback yoktur.

Elisp'te kalanlar editor adapter'ıdır: pN görünüm etiketleri ve UI cache,
buffer/header/keymap, completion, list/status/kill UI komutlarının yönlendirmesi,
visible/modified/visiting log koruma ve pruning. Native UUID tek execution
authority'dir; görünüm etiketi veya gösterilen PID signal yetkisi değildir.
Status cached view'dır, atomik OS snapshot diye sunulmaz. Policy/path parser'ın
geri kalan migration'ı ayrı iştir; bu cutover onları taşınmış saymaz.

## Davranış ve bilinçli async sınırı

- Foreground callback gerçek native EOF + terminal drain sonucunu bekler.
  Background callback gerçek startup receipt/claim sonrası ID/PID verir;
  parent turn bitse de captured source buffer/session kapanana kadar yaşar.
- Artık background başlangıcı da CALLBACK gerektirir. Senkron IPC bekleme
  veya receipt gelmeden sahte "started" sonucu yoktur. Eski callback'siz
  list/status/kill UI sorguları korunur.
- Genel komut Agent + explicit native approval ister. Eski confirm-bash=nil
  native arbitrary execution'a otomatik onay vermez. Eksik UI fail-closed'dur.
  Rejection command/cwd/root/no-repeat guidance bilgisini korur.
- Captured editor environment ve exec-path, mode, root/cwd inode/device,
  session/run, strict policy ve registry revision onay kararında yeniden
  kontrol edilir. Native exact action ayrıca argv/env/output/deadline bağlar.
  Environment değerleri onay ekranında veya loglarda basılmaz.
- UI output UTF-8 carry ile decode edilir; tek poll zinciri vardır. Dolu
  sayfalarda hemen sonraki sayfa, boş okumada 50ms idle poll kullanılır.
  Editor buffer da captured byte sınırında kalır; point/narrowing ve kullanıcı
  edit flag'i korunur. Unmodified generated log gereksiz yere edited sayılmaz.
- İptal isteği :cancelling'dir; ancak Rust drain sonucu :cancelled olur.
  Kill komutu sonucu "terminated" diye erken sunulmaz, log drain boyunca
  korunur. Startup receipt bilinmiyorsa :failed/unconfirmed gösterilir.
  Cancelled late receipt sahiplenilse bile yalnız o native handle dispose edilir.

## Gerçek entegrasyonda öğrenilenler

Nix geliştirme oturumu 202 environment entry içerdi; 128-entry generic port
sınırı Bash parity'yi bozdu. Limit 512 yapıldı, toplam environment 64KiB sınırı
aynen korundu. Fazla entry veya byte reddi Rust regresyon testindedir. Hiçbir
değişken sessizce atılmaz. Emacs first-entry/unset semantiği explicit capture'da
korunur. Daha büyük ortam kontrollü limit hatasıdır, sınırsız capture değildir.

Shutdown RPC timeout'u 5s iken native TERM grace 5s + drain 5s idi. Erken RPC
timeout core'u cleanup bitmeden kapatabiliyordu. RPC 12s, dış transport sınırı
15s'dir. TERM-ignore gerçek child testi shutdown cevabı alınmadan core'un
kapatılmadığını ve /proc child kaydının temizlendiğini denetler.

## Kabul kanıtı ve açık işler

Eski Bash testleri tools/process/metadata/permission dosyalarından
`tests/test-native-bash.el` içindeki gerçek core fixture'larına eşlendi;
test kapsamı silinmedi. Live/cancel, background list/status/kill, foreground
callback, output cap, no-default-timeout, explicit timeout, zero retention,
Unicode/merged stderr, rejection detail, mode/callback, stale environment,
unavailable/no-fallback, startup cancel ve editor view davranışları kapsanır.
Ownership testleri fake OS process yerine exact native handle/queued startup
sınırını sınar. Diğer process/session tüketicileri taşınmadan silinmez.

Rust: 66 test + 2 compile-fail, locked build/test, fmt ve strict all-target
Clippy temiz. Warning-as-error bytecompile/checkdoc temiz; .elc çıktıları
kaldırıldı. Güncel binary + source-only full ERT: **1168/1168 expected,
0 unexpected, 93.02 s**. TERM-ignore shutdown testi bu toplamın içindedir.
Bounded TLC: process 535 generated/179 distinct/depth9; process-session
129/42/depth7; approval 8194/1536/depth11 hatasız. Bunlar soyut model regresyonu;
yeni native job tablosu/claim veya sınırsız process ömrünün refinement ispatı
değildir. Remote CI veya gerçek provider/uygulama/login testi yapılmadı.

Shared `tools/process.el` Git/search/diff gibi kalan tüketiciler için durur.
`tools/process/session.el` interactive idle-timeout davranışı native'a
taşınmadan silinmez. API -> Rust ve dört application backend kapsamı değişmez.
