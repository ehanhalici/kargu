# 09. DİNAMİK BAĞLAM VE MENTION SÖZLEŞMESİ

Mention çözümleme typed attachment üretir. Disk dosyası ile canlı tampon
aynı kaynak değildir. Girişte scope/path/read policy, LLM'e gönderimden önce
ayrıca context/token bütçesi uygulanır. Completion aday seçimi izin sayılmaz.

## 1. Sözdizimi ve uyumluluk

Yeni etiketler: `@file:path`, `@buff:buffer`, `@sym:symbol`,
`@git:diff`, `@git:staged`, `@line:path:40-65`, `@folder:path`.
Mevcut `@path` ve `@file::symbol` davranışları test-attach fixture'larıyla
korunur; belirsiz girişte kullanıcıya çözümleme hatası sunulur.

Lexer span'ları korur; quoted/escaped boşluk, Unicode, noktalama, parantezli
dosya adı, buffer adındaki yıldız ve line range sonundaki sayıları işler.
`split_whitespace + trim punctuation` geçerli isimleri bozduğu için kullanılmaz.
Email ve fenced code içindeki metin varsayılan mention sayılmaz.
Satır aralığı 1 tabanlı, kapsayıcı, start <= end ve positive olmalıdır.

Wire target `type` + typed `value` taşır; file/buffer/symbol/git string,
line_range nesne, folder path + limit/options nesnesidir. Kaynak prompt span'i
ve target_id her sonuçla ilişkilendirilir. Yinelenen hedefler tek snapshot
alabilir; kullanıcının referans sırası korunur.

## 2. Hibrit çözümleme

Rust path/Git/folder ve token policy'sini yönetir. Önce
`editor/resolve_mentions` ile açık tampon varlığı ve revizyon sorulur.
Emacs explicit root/document_id bağlamında RAM snapshot döner.
Kaynak bulunamazsa `not_found/unavailable/rejected` açıkça döner; başka buffer'a
fallback yapılmaz. `@buff` hedefinin root dışı veya dosyasız olması explicit
capability gerektirir; process/log/secret buffer'lar otomatik export edilmez.

Dosya Emacs'te açıksa widened RAM metni, tick/hash ve dirty flag alınır;
kapalıysa Rust diskten canonical path guard ile okur. Kaydedilmemiş yeni
dosya file-exists-p false diye kaybolmaz. Range aynı snapshot üzerinde kesilir.
Temiz tampon ile disk değişmişse tutarlılık kanıtı/durum bilgisi döner.
Snapshot sonrası değişiklik late result olarak yeniden doğrulanır.

Sembol çözümü source document + konuma bağlı async Xref/Eglot kullanır;
ilk tanımı rastgele seçmez. Çoklu sonuç ambiguity/range listesi üretir.
Marker, cons ve native editor nesnesi JSON'a verilmez.

Git bağlamı Rust job servisiyle root'a bağlı çalışır; `diff` gerçek patch,
`staged` index diff üretir. `--stat` çıktısı diff diye sunulmaz. Emacs
process filter içinde senkron call-process yapılmaz.

Folder expansion varsayılan ignore kurallarını uygular, symlink ile root
dışına çıkmaz; depth/file-count/total-byte/deadline limitleri taşır. Binary,
aşırı büyük ve reddedilen dosyalar reason ile listelenir; sessiz kaybolmaz.
İlk default: 100 dosya, depth 8, toplam 512 KiB; negotiated frame limiti için
pagination kullanılır. Yeni dosyalar ve ignore override explicit seçenektir.

## 3. Attachment ve enjeksiyon

Attachment target_id, source_kind, canonical path/document_id, revision/hash,
range, content, dirty, truncation, byte_count ve çözümleme durumunu taşır.
Token estimate editor'dan güvenilmez biçimde alınmaz; Rust kullanılan modelin
tokenizer'ı veya muhafazakâr estimator'ıyla hesaplar. `chars / 4` sert context
limiti için yeterli değildir. Nihai istek overhead/output reserve ile bütçelenir.

Context kullanıcı/veri rolünde taşınır; system/developer talimatına çevrilmez.
XML kullanılırsa content/attribute delimiter'ları escape edilir; sahte kapanış
etiketi üst yetkili talimat oluşturamaz. Kaynak provenance ve güvenilmeyen
içerik ayrımı korunur; bu tek başına prompt injection'a tam koruma iddiası değildir.
Kırpılan hedefler açık listelenir; bütün belge gönderilmiş gibi gösterilmez.

## 4. Kabul kapısı

Legacy syntax, folder, quoted path, emoji, unsaved/new/narrowed buffer,
workspace dışı buffer, symlink, çoklu sembol, geç snapshot, token aşımı,
binary file, attachment delimiter injection ve cancel fixture'ları zorunludur.
