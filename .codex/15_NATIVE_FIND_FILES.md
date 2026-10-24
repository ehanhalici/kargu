# Üçüncü dilim: native find_files ve Emacs portu

## Rust servisi

`workspace/findFiles`, application/session scope'u zorunlu, ayrı bir **read
service portudur**. Agent run, prompt veya arbitrary execution capability'si
değildir. Mevcut Elisp tool gate/budget/claim yönetimi taşınmış gibi gösterilmez.
Rust `ApplicationActor` admission/approval library'si vardır; provider run ve
genel `tool/execute` entegrasyonu sonraki dilimdir.

Tek IPC mailbox yazıcısı en fazla dört read worker kabul eder. Filesystem ve
glob compilation blocking worker'dadır; completion yalnız mailbox tarafından
yayımlanır. Session close/shutdown, doğru connection epoch'lu rpc/cancel,
deadline ve transport drop publication hakkını geri alır. İptal edilen işin
slot'u worker gerçekten dönmeden serbest bırakılmaz. Shutdown yanıtı drain
sonrasındadır. Başka owner ve geç completion başarı yayımlayamaz.

Dosya sistemi çağrısı işletim sisteminde takılırsa Rust thread'ini güvenli
şekilde öldürmek mümkün değildir. İptal OS çağrıları arasında kooperatiftir;
30 saniyelik deadline mutlak syscall-kill garantisi değildir. Bloklanan
filesystem için process izolasyonu/OS containment ayrı iştir; bu sınır gizlenmez.

Input -> FindFilesPlan TryFrom -> consuming execute -> FindFilesResult.
Private file/directory visit limit ve counter tipleri kullanılır. Glob için
globset 0.4.20, Cargo.lock içinde sabittir. `*`, `?`, `**/`, karakter sınıfı ve
alternation parser'ı sıfırdan yazılmadı. `literal_separator(true)` kullanılır.
Referans: https://docs.rs/globset/0.4.20/globset/struct.GlobBuilder.html

## Açık davranış sözleşmesi

- Public `find_files` şeması/alias'ları korunur; basename ve recursive glob,
  subdirectory/file target ve project-relative output korunur.
- Gizli kaynaklar dâhil; ortak skip-directory ve derleme/yedek artifact politikası
  uygulanır. fd/rg varlığı ve makine-global Git ignore kuralları sonucu değiştirmez.
  Bu, eski üç fallback arasındaki farklılıkların bilinçli normalizasyonudur.
- Discovery sırasında symlink izlenmez; açık target canonicalize edilip root
  containment kontrolünden geçer. `..` bileşeni I/O öncesi reddedilir.
  Directory replacement/final workspace identity tekrar kontrol edilir.
- En fazla 200 result/64 KiB raw text; file visit 20.000, directory visit
  20.000, bütün entry'ler 100.000, iterator depth 128 hard limit. Editor default
  file/directory bütçeleri 2000'dir. İncomplete sonuç açıkça belirtilir.
- Geçersiz UTF-8 veya newline içeren result path sessizce normalize edilmez.
  Negotiated frame'e sığmayan yanıt connection'ı düşürmez; scoped resource error.
- Hata yanıtlarında ham path, pattern veya OS hata gövdesi loglanmaz.

## Rust doğrulaması (adapter silinmeden önce)

35 test + 2 compile-fail doctest başarılı; locked fmt/Clippy kapıları başarılı.
Yeni kanıtlar: eski Elisp glob fixture'larının native karşılıkları, exclusion ve
artifact policy, symlink/traversal/replaced workspace, file/directory/result
limitleri, cancellation sırasında slot tutma, expired/closed owner'ın geç
başarı üretememesi, drop revocation, gerçek pipe search+ping+foreign scope+
shutdown drain ve negotiated-small-frame error.

Emacs facade ve legacy kaldırma sonucu bu dosyaya sonraki commit'te eklenecek.
