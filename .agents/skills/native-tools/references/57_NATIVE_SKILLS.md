# Todo 2: native skill discovery/read — 2026-10-27

Onaylı göçte bağımsız skill tüketicisi tamamlandı. Git mutation,
toolchain/dependency probe, webfetch ve son bridge audit'i açık kalır.
Kullanıcının 07/shell.nix değişiklikleri korunur; bu dilime alınmaz.

## Sözleşme ve sınırlar

`workspace/skills` / `workspace_skills` iki kapalı sorgu kabul eder: catalog ve
isimle load. Model kök/yol/program seçemez. Editor proje kökünü ve opsiyonel
XDG_CONFIG_HOME/kargu/skills (varsayılan ~/.config/kargu/skills) grant'ini verir.
Yok user kökü olağan yokluktur; diğer root hataları açık native hatadır.
Standard project skills/skill/.agents/.claude/.codex dizinleri önce incelenir;
genel proje keşfi yalnız skill(s) altındaki SKILL.md dosyalarını alır.
Sıralı project kaydı, aynı adlı user kaydından önce gelir; ilk isim kazanır.

Bu traversal, GNU ls/rg/Git motoru veya genel find_files yerine yeni bir motor
değildir. Somut domain gereksinimi asset dosyaları çokken kardeş metadata'nın
öncelikli bulunması ve executable/transformation handler kullanmadan no-follow
regular-file capture'dır. Listeleme/grep/Git portları değişmez. Shared PinnedFile,
ReadTools mailbox ve actual-join admission kullanılır; yeni dependency yoktur.

Directory traversal pinli fd + openat/O_NOFOLLOW kullanır. Bekleyen directory
yolları bounded queue'dadır; her kardeş için açık fd tutulmaz. Metadata olmayan
asset'ler açılıp okunmaz. Bulunan file/directory symlink'leri takip edilmez.
PinnedFile inode/size/mode/mtime/ctime evidence ve read öncesi/sonrası revision
kontrolleri shared reader'dan gelir. FIFO/device, invalid UTF-8/NUL, oversized
ve bozuk string metadata okunabilir başarılı skill sayılmaz. Hatalı dosyanın
ham içeriği/hata echo'su log'a yazılmaz; yalnız skipped sayısı sunulur.

Strict UTF-8 (opsiyonel BOM), CRLF normalization, ilk name/description alanı,
JSON çift tırnak/single quote, plain comment ve literal/folded block scalar
uyumu korunur. Tam YAML parser/evaluation değildir. Body içeriği instruction
olarak korunur; metadata ve base-directory XML alanları escape edilir.

Limitler: dört ortak worker, 30 saniye total; per-file 0..1 MiB (default 256 KiB),
aggregate source 4 MiB, 128 unique skill, name 1024 / description 8192 bytes,
body 0..32768 characters (default 12000), presentation 128 KiB. Directory budget
0..20000 (default 2000), hard global entry 100000 ve depth 128. Project/user
ordinary asset sayısı 400/100 eşiğine gelince daha derine inilmez; doğrudan
metadata incelemesi bu asset'lerden önce gelir. Bunlar atomik repo/FS snapshot
veya stalled kernel syscall için hard-cancel garantisi değildir. Output sınırı
aşılırsa kısmi metin başarı diye dönmez; traversal/record/source limitleri ile
skipped metadata ise açık incomplete notice taşır.

## Gerçek editor tüketicisi

Tool-capable run connection preparation'dan sonra kendi child read task'inde
catalog refresh bekler. İlk model isteği/active history ancak ardından başlar.
Stop, owner close, mode/session değişimi ve deadline pending RPC'yi iptal eder.
Read slotu native actual join'e kadar kalır. Tool-free run skill IO yapmaz ve
prompt skill-tool rehberi içermez. Loop skill ailesini load sırasında zorunlu
yüklemez; runtime autoload mevcut modül-removal sözleşmesini korur.

`kargu-skill-refresh(callback)` Result verir. Last-completed catalog buffer/session
observation'dır; passive list/catalog getter'ları disk/core/RPC başlatmaz.
Newest admitted intent kazanır; eski completion yeni view'i değiştiremez.
Closed/expired parent başka canlı refresh'in intent'ini geçersiz kılamaz.
Root/settings snapshot'ı ilk yield öncesi kopyalanır; in-place string değişimi,
source context, geç timer dispatch ve changed root native text'i yayınlayamaz.
Failed refresh last-good observation'ı korur; başarısız run bundan devam etmez.
Prompt cache key tamamlanan katalog metnini de içerir.

`kargu-skill-load(name, callback)` her çağrıda native discovery/read yapar;
body stale editor cache'inden gelmez. Callback'siz çağrı açık async hata verir.
Public skill list plists artık yalnız name/description/path metadata taşır;
body ve TTL global cache yoktur. Skill/alias/direct çağrılar ortak mode/tool
gate'inden geçer. Eski Elisp scanner, metadata parser, read ve renderer silindi;
eksik capability için fallback yoktur. Eski core rebuild/restart ister.

## Kanıt

- **1286/1286 full source ERT**, 0 unexpected, **152.532591 s**, 02:40:09 +0300.
- **324 native + 24 compile-fail = 348** locked test, 34 suite, 0 failure.
- Locked build, fmt ve strict all-target Clippy/unwrap/expect/panic temiz.
- Değişen Elisp üretim/test kaynakları Werror bytecompile; üretim checkdoc temiz.
  Elc yalnız task-specific /tmp altında; repo'ya build artifact yazılmaz.
- Application TLC yeni connection→skills barrier'larıyla **13099 generated /
  3481 distinct**, queue 0, depth 33; RunningPrepared/PreparationOrder temiz.
  Connection **602836/101708**, queue 0, depth22; transport **1810/693**, queue0,
  depth12 regresyonları temiz. Bunlar bounded soyut modellerdir; concrete FS,
  metadata parser veya native worker join'lerinin formal refinement'ı değildir.

Eski yedi skill fixture'ı gerçek native pipe consumer testlerine eşlendi.
Native corpus: metadata-first assets, user/project duplicate precedence,
Unicode/CRLF/quotes/blocks, fresh named load, symlink/FIFO/invalid/oversized,
record/aggregate/presentation bounds, foreign owner/unknown fields ve ping reuse.
Editor corpus: actual config→skill pipe→ilk request, held reply/Stop, başarısız
preparation'da unsent history, owner close/foreign current buffer, session/root/
mode/settings değişimi, mutasyondan ayrık DTO, stale timer, duplicate/old reply,
passive no-IO, alias/mode/direct gate ve missing-cap no-send/no-fallback.
Genel loop testleri explicit empty offline skill hazırlığını mock'lar; skill
consumer fixture'ları gerçek hazırlığı ayrıca seçer. User skill dizini testlerde
problanmaz; native user-root kanıtı geçici fixture kullanır.

Kayıtlar `/tmp/kargu-skills-final-{ert,native,clippy}.log`,
`/tmp/kargu-skills-build.log`, `/tmp/kargu-skills-elisp-checks.log` ve
`/tmp/kargu-skills-tlc-{application,connection,transport}.log`.
Canlı Emacs reload/uzak model/login/kurulum/credential migration veya push yoktur.
