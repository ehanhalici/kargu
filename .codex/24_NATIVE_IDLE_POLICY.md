# Interaktif süreçler için native idle policy

2026-10-24. Bash cutover (a7ecdfa) sonrası interactive session prerequisite'i.

`IdleTimeout`, toplam `ExecutionTimeout` ve bounded approval/drain sürelerinden
farklı private domain tipidir. Wire `idle_timeout_ms` optional/null=disabled,
pozitif integer en çok 86400000 ms'dir. CommandSpec builder'ı immutable capture
yapar; interval action digest, reverse review ve Emacs exact karşılaştırmasına
bağlıdır. Capability `process_idle_timeout`; eski binary enabled idle policy'yi
sessizce yok sayamaz. Varsayılan Bash, ls ve diğer portlar idle kapalı kalır.

`process/io.rs` sadece pipe drain ve bounded stdin acknowledgement yürütür.
Nonempty stdout/stderr veya başarılı nonempty stdin yazımı I/O activity
gözlemidir. Stdin chunk'ının tamamının acknowledgement'ı beklenmez; başarılı
partial write da gözlenir (bounded duplex + paused clock testi). Empty write,
EOF ve henüz teslim edilmemiş queued input idle süresini
yenilemez. Startup'ta etkinleşir, onay ekranında bekleme süreyi tüketmez.
Tek süreç supervisor görevi Timeout / cleanup lifecycle kararını verir;
I/O görevleri işi iptal edemez, tamamlayamaz veya actor state değiştiremez.

`process/activity.rs` sabit boyutlu watch observation kullanır: last activity
ve gözlenmiş en uzun sessizlik. Özellikle ikinci alan gereklidir: sadece son
timestamp tutulursa, supervisor gecikmişken gelen geç I/O pulse'ı coalesce
olup önceden dolmuş idle süresini canlandırabilir. Gözlenmiş uzun gap kaybolmaz;
paused Tokio clock testi monitor poll edilmeden önceki geç/çoklu pulse'ı sınar.
Disabled idle observation için kanal/timer allocate edilmez. Bu I/O gözlemi
ölçümüdür, kernel write timestamp/gerçek-zaman scheduling garantisi değildir.

Idle expiry mevcut TERM/grace/KILL/reap yoluna gider; sibling job'a dokunmaz.
Monitor altyapısı hata verse de kanıtlanmış PGID cleanup atlanmaz; typed
OutcomeUnknown sonucu sahte başarıya çevrilmez. Lifetime/byte/input sınırları
ve session ownership aynı kalır. Unlimited total süre idle'ı iptal etmez.

Testler: tip/serde bound ve digest değişimi; approval süresinin idle'a
sayılmaması; paused-clock late/coalesced pulse ve disabled timer; gerçek wire
idle expiry + /proc temizliği + sibling isolation; ayrı stdout/stderr ve
successful stdin ile yenilenme; exact UI interval ve missing capability reddi.
Tokio test-util yalnız dev dependency'dir; production unsafe yasağı aynıdır.

Bu commit henüz `tools/process/session.el` consumer'ını değiştirmez veya
silmez. Sonraki dilim generic editor command capture ve session consumer
cutover'ıdır; idle timer, OS spawn/send/kill motoru o kesimde Elisp'ten silinir.
Eski bounded process/session modelleri yeni idle observation'ın refinement
ispatı değildir. Doğrulama: **74 Rust testi + 2 compile-fail**, locked
build/test, fmt ve strict all-target Clippy sıfır uyarı; source-only gerçek
binary full ERT **1170/1170 expected**, 0 unexpected, **94.48 s**. Değişen
Emacs dosyaları warning-as-error bytecompile/checkdoc temiz; .elc kaldırıldı.
