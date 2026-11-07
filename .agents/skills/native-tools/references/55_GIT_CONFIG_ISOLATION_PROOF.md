# Todo 2: Git config izolasyonu proof fixture — 2026-10-26

Bu commit yalnız gerçek Git fixture'ını ve takip işlerini ekler. Yeni native
diff/blame capability'si veya status güvenlik düzeltmesi henüz yayınlanmaz.
Production kodu değişmedi; son native read_file consumer commit'i `cd435c5`.

## Doğrulanan bulgular

1. `git diff --no-ext-diff --no-textconv` executable clean filtresini çalıştırır.
   Aynı boyutlu bir çalışma dosyasında `git status --porcelain=v1` de index refresh
   sırasında filtreyi çalıştırır. Marker positive-control her format/worktree
   kombinasyonunda yürütmeyi gerçekten doğrular. Mevcut native status bu nedenle
   ayrıca sertleştirilecek; sadece üst-level fsmonitor=false yeterli değildir.
2. Private geçici Git common/worktree metadata görünümü, kendi config'i, copied
   HEAD, özgün objects/refs/reftable/packed-refs/shallow bağlantıları ve explicit
   GIT_INDEX_FILE ile Git algoritmalarını yeniden yazmadan status/diff/blame verir.
   Global/system config devre dışı ve executable filter tanımları bu config'te
   yoktur. `GIT_OPTIONAL_LOCKS=0` / diff.autoRefreshIndex=false ile özgün index byte
   içeriği sorgu öncesi/sonrası aynı kalır. Bu bir OS sandbox değildir.
3. Physical `commondir` dosyası gereklidir; yalnız GIT_COMMON_DIR, ref backend'inin
   aynı ortak refstore'u bulduğunu garanti etmez. HEAD'in absolute dosya symlink'i
   de geçerli repository signature sayılmaz. Fixture ikisini gerçek Git hataları
   (`not a repository`, `no such ref: HEAD`) üzerinden yakalayıp düzeltir.
4. SHA-1 / SHA-256 object formatı ve files / reftable ref backend'i, main ve linked
   worktree'de (8 kombinasyon) aynı engine üzerinden çalışır. Henüz format/version
   desteği veya tüm Git config semantiği için genel bir garanti verilmez.

Git fixture'ı yalnız tmp repo/metadata alanlarını kullanır; her test alt süreci
PGID lideridir. Kullanıcının gerçek reposuna mutation/credential lookup/kurulum,
network veya canlı Emacs reload yoktur.

## Native cutover'dan önce gerekenler

- Tek owner reservation içinde kapalı layout/config preflight, bounded complete
  output, cooperative preparing cancellation ve preflight'ın actual drain'inden
  sonra final query. IPC mailbox üzerinde filesystem/subprocess bekleme yok.
- Config'i isim bazlı patch etmek yerine final query'nin özgün executable config'i
  tekrar okuyamaması; yalnız açık safe config alanlarının captured snapshot'ı.
  HEAD capture regular/bounded/revision-bound olsun; linked worktree ayrı kalsın.
- Private metadata lifetime'ı process actual drain'e bağlı tutulsun; temizliği
  belirsiz child sonrası yeni admission veya kör fallback yapılmasın.
- Submodule alt süreçlerinin kendi config'ini okuyabileceği ayrı sınır açıkça
  ele alınsın; inspect edilmemiş durum sessizce clean/empty diye sunulmasın.
- Native status/diff/blame gerçek consumer, config değişimi, alias/direct/mode,
  malformed/foreign owner/missing Git, output budget ve cancel/drain kabulü.

Kaynak doğrulaması (yalnız Git'in resmi doküman/kaynakları):
[gitattributes](https://git-scm.com/docs/gitattributes),
[git-config](https://git-scm.com/docs/git-config),
[attr.c](https://github.com/git/git/blob/master/attr.c),
[setup.c](https://github.com/git/git/blob/master/setup.c),
[files-backend.c](https://github.com/git/git/blob/master/refs/files-backend.c).
Fixture somut engine kanıtıdır; bu kaynaklardan config'isolation tasarımına
geçiş bir mühendislik çıkarımıdır, OS containment veya formal refinement değildir.

Focused real test ve strict Clippy başarılı; `/tmp/kargu-git-isolation-prototype.log`
ve `/tmp/kargu-git-isolation-clippy.log`. Consumer ERT baseline'ı `cd435c5`'te
1272/1272 source, native baseline 305+24; bu commit test-only olduğundan farklı bir
production/ERT doğrulaması yapılmış gibi sayılmaz.
