# Rust-owned provider catalog

Kullanıcı önceliği: AI API motoru ve providers Rust'a taşınacak; Elisp UI
core verisini gösterecek. API desteği dört installed-app backend'inden
ayrıdır; bunlar API sağlayıcısı kimliğiyle karıştırılmaz.

İlk kesim, mevcut 162 sağlayıcı / 5 wire tanımını sürümlü tek JSON asset'e
taşır. Rust bounded admission, typed identities/endpoints, duplicate/schema
kontrolü ve SHA-256 revision sahibidir. provider/catalog credential-free
snapshot yayınlar; bridge ready olmadan UI projection yüklenir. Elisp'in
1416 satırlık literal catalog motoru kaldırılır. Başlangıçta senkron config
okuyucuları aynı Rust asset'ini okur; bağımsız ikinci katalog/fallback yoktur.
Explicit editor registration baseline refresh ile ezilmez.

Öğrenim: Azure/Vertex/Neon gibi kayıtlar ${ENV_NAME} URL şablonlarıdır.
CatalogEndpoint bunları metadata olarak korur. Ağ sınırındaki ApiEndpoint
çözülmemiş şablon, userinfo, fragment ve HTTP(S) dışı adresleri reddeder.
Header binding değerleri yalnız app-url/session kapalı enum'udur; eval yok.
Environment alanları değişken isimleridir, credential değerleri değildir.

Bu kesim HTTP/stream/wire/retry motorunun taşındığı anlamına gelmez. Bunlar
sonraki bağımlı kesimlerde canlı consumer bağlandıktan sonra silinecek.
Credential çözümleme/auth-source ve canlı UI ownership editör portlarıdır.
Gerçek hesaba, ücretli API'ye veya installed CLI login'ine bağlanılmaz.
