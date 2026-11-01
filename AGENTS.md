# Bağlayıcı mimari kuralı

Kullanıcının 2026-11-01 talimatı: Rust backend'dir; Elisp yalnız Emacs frontend'i
ve Rust ile editör arasındaki köprüdür. Bütün iş mantığı ve orkestrasyon Rust'ta
yaşamalıdır.

- Config dosyasını Rust okur ve doğrular. Provider/model keşfi, bunlara HTTP
  isteği atılması, cache, seçim ve istek politikası Rust'a aittir. Elisp yalnız
  Rust'ın verdiği DTO'ları listeler ve kullanıcı eylemlerini iletir.
- Loop, permission, tool dispatch, edit/review kararları, history, persistence,
  bütçe, compaction, healing ve verification Rust'ın sorumluluğudur. Elisp'te
  bunların ikinci bir karar motorunu veya domain state aynasını ekleme.
- Emacs'e özel buffer kimliği/metin yakalama, native yetkiye bağlı canlı
  transaction/save/undo, UI sunumu, Eglot/Dape gözlemleri ve auth-source erişimi
  ince editör adaptörleri olarak kalabilir. İşlem kararı Rust'a geri döner.
- Var olan eski Elisp motorları geçiş borcudur. Gerçek tüketicileri native yola
  geçirip eşdeğerliği doğruladıktan sonra kaldır; dosya taşıma veya yeşil unit
  testi tek başına geçişi kapatmaz.

Uygulama kuralları: [.codex/00_MIGRATION_ARCHITECTURE.md](.codex/00_MIGRATION_ARCHITECTURE.md)
ve [.codex/01_RUST_CORE_PATTERNS.md](.codex/01_RUST_CORE_PATTERNS.md).
İşlerin ve kabulün tek takip listesi [todo.md](todo.md) dosyasıdır.

Kullanıcının test talimatı: TLA+/TLC yalnız TLA+ kodu değiştiğinde çalıştırılır.
Değişmeyen modelin önceki sonucunu tekrar elde etmek için TLC çalıştırma.
Değişikliğe uygun Rust/ERT, lint ve derleme kontrollerini uygula; yalnız gerçekten
doğrulanan dilimleri kapsamına uygun commit et. Kullanıcının diğer staged ve
unstaged çalışmalarını koru.
