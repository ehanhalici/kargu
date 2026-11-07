# Mimari Disiplin ve Sadeliği Koruma İlkeleri

Kargu üzerinde kod üretirken veya refactoring yaparken aşağıdaki ilkelere kesinlikle uyulmalıdır:

1. **İşletim Sistemi Seviyesinde Basitlik (No Hand-Rolled Lexers/Parsers):**
   - Alt süreçler çağrılırken kabuk enjeksiyonunu engellemek için string regex/tokenizer yazmayın. Komutları doğrudan dizi argümanlarıyla (`execvp` mantığıyla) çağırın.
   - Yama uygularken karmaşık hunk eşleme motorları yazmak yerine atomik blok değişimi (`old_string` -> `new_string`) veya standart `git apply` / `patch` araçlarını kullanın.

2. **Bağlam İzolasyonu (Buffer-Local Context):**
   - Oturum ve sohbet durumunu global değişkenler (`defvar`) ve tampon arama döngüleriyle (`routing`) yönetmeyin.
   - Her oturumun durumunu tampona özel tekil bir `cl-defstruct` (`defvar-local`) içinde tutun.

3. **Açık Asenkron Akış (Continuation over Exception Replay):**
   - İnsan onayı gibi asenkron duraklamalarda `throw` ile istisna fırlatıp tüm fonksiyonu baştan çalıştırmayın (replay).
   - Tek seferlik çalışacak açık continuation callback'leri kullanın.

4. **Append-Only Değişmezleri (Invariants over Repair Passes):**
   - Her istekte tüm ağacı dolaşıp tamir eden $O(N)$ temizleme katmanları yerine, veri ekleme anında (`history-add`) kuralları kesin olarak doğrulayın.

5. **Homojen Veri Temsili:**
   - Dahili modellerde Alist/Plist/Hash-table karmaşasından kaçının. Sözleşmeleri `cl-defstruct` ile tanımlayın; gevşek tipleri yalnızca API tel (wire) katmanında tutun.
