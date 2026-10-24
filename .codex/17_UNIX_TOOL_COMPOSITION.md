# Unix/GNU araç bileşimi ve Rust yürütme sınırı

2026-10-24 — Kullanıcının onayladığı yön değişikliği.

## İlke

Her araç kendi işini yapar. Dizin listeleme `ls`, içerik arama `rg`, Git
işlemleri `git` tarafından yapılır. Rust bu araçların seçeneklerini veya
motorlarını yeniden uygulamaz; executable + argv adapter'ı ve ortak süreç
yöneticisi kullanır. Serbest betikler açık shell aracı üzerinden çalışır.
Bu belge GNU araçlarının tümünün aynı platformda bulunduğunu varsaymaz:
gerekli binary eksikse anlaşılır unavailable hatası verilir; kurulum veya
gizli native/Elisp fallback yapılmaz.

Rust'ın işi: typed girişler, owner/mode/policy, exact-action onay, explicit
environment, bounded stdout/stderr, timeout, cancel, PGID ve drain/reap.
Çıktı yalnız modelin okuyacağı metinse tekrar parse edilip özel dizin ağacına
çevrilmez. Native uygulama ancak somut ek gereksinimle gerekçelendirilir.

## İzin sınırı

- Sabit, uygulamanın kurduğu salt-okunur argv ile genel shell farklı
  yetkilerdir. Modelin gönderdiği komut, adı `ls` olsa bile SafeReadOnly sayılmaz.
- Genel program/argv ve shell betikleri mevcut mode + açık onay kapısından
  geçer. Onay immutable executable/argv/cwd/environment/owner'a bağlıdır.
- cwd ve canonical path kontrolü OS sandbox değildir. `ls` çıktısı önceki
  fd-rooted metadata taramasının atomik veya no-follow eşdeğeri diye sunulmaz.
- `list_files` şeması ile `bash {command: "ls -lah"}` ayrıdır. İlki sabit
  adapter'dır; ikinci yol GNU seçeneklerini değiştirmeden shell'e aktarır.

## Uygulama sırası ve dizinler

1. Davranış değiştirmeden application/host, domain, security, process,
   workspace ve ipc sorumluluklarını klasörle; fmt/test/Clippy ardından commit.
2. Ortak process + execution gate'i asenkron IPC/onay yoluna bağla. Mailbox
   onay veya child sonucu beklemez; cancel/EOF önce revoke sonra drain eder.
3. Özel listing tarayıcısını `ls` adapter'ıyla değiştir; eski motoru ve yalnız
   ona ait testleri yeni sözleşme/regresyon testleriyle eşleyerek kaldır.
4. `find_files` mevcut native motoru geçici kalır; sonraki dilimde uygun
   harici discovery adapter'ına taşınır. Yeni özel grep/Git motoru yazılmaz.

Her doğrulanmış dilim ayrı commit'tir. API göçü ve dört uygulama backend'i
kapsamı değişmez. Bu not tamamlanmış uygulama veya tüm araçların taşındığı
iddiası değildir; güncel kanıt 12_MIGRATION_PROGRESS.md içinde tutulur.

## Doğrulamada öğrenilen: argv[0] da davranışın parçasıdır

Nix ortamında `ls`, canonicalize edildiğinde multicall `coreutils` binary'sine
çözülebiliyor. Sadece canonical executable + argv çalıştırmak `ls -lAh` yerine
`coreutils -lAh` çalıştırdı ve gerçek entegrasyon testi bunu yakaladı.
Orijinal çağrı adı (`argv[0]`) korunmalı, onayda gösterilmeli ve action digest'e
katılmalıdır. Canonical path executable kimliğini, invocation ise multicall
davranışını belirler; ikisi aynı kavram değildir. Bu bulgu diğer Unix adapter'ları
ve BusyBox benzeri dağıtımlar için de geçerlidir.
