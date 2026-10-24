# 35. Editor application → native service lease

2026-10-25. API POST ve model-discovery GET artık editor application başına
ayrı native application/service-session identity'si kullanır. Connection root
read scope'u eski standalone/tool tüketicileri içindir; yeni API application
scope'u yerine sessizce kullanılmaz. Bu henüz user history import'u veya native
agent run/claim değildir; farklı kavramlar aynı ID olarak sunulmaz.

`bridge/application.el` sadece UI lease delivery'sini yönetir: aynı application
için eşzamanlı startup tek create/session akışında birleşir; her waiter'ın iptali
bağımsızdır; callback scope string'leri detached'dir. Lease connection'a bağlıdır.
Eksik application lifecycle/close capability'de fail-closed; kapanmış identity
aynı connection'da tekrar hazır sayılmaz. Explicit close'un callback'i native
drain ack'ini bekler. Geç create acquisition kapatılır; geç session callback
closed lease'i diriltemez. Reentrant close kalan scope waiter'larını da reddeder.

Idle/unreachable UI lease için finalizer yalnız mevcut connection'a best-effort
close gönderir; yeni core başlatmaz ve deterministic active-work cleanup yerine
geçmez. Aktif forward handle kendi owner/Stop lifecycle'ına bağlıdır. Owner kill
ve major-mode change startup beklerken de delivery'yi iptal eder. Native scope
binding henüz process/tool consumer'larına genişletilmedi; onlar eski explicit
standalone service portunda kalır.

Öğrenimler: application→request→application grafiği döngülüdür; `copy-tree t`
ile DTO gibi kopyalamak excessive-lisp-nesting üretir. Owner/closure kimlikleri
korunur; authority taşıyan URL/body/header/wire/auth/tuning kendi encoder'ında
ayrılır. Transport artık callback/owner projection'ında ham request seçeneklerini
tutmaz. Sync connection-ready callback içinden ikinci async scope waiter'ı
edinilebilir; tek cleanup slotunu overwrite etmek yerine bağımsız cleanup stack'i
gerekir. Late acquisition finished/cancelled handle'da derhal bırakılır.

Testler coalescing/cancel, detached scope, close-during-create, close/create
failure, reentrant close, late session callback, old-core refusal, nested startup
cleanup ve startup owner death'i kapsar. Gerçek Emacs→stdio testi iki editor
application'ın root'tan ve birbirinden farklı identity aldığını; birinin aktif
HTTP'sini close ile durdurunca diğerinin session'ının yaşadığını doğrular.

Core run/budget/retry ve history/agent henüz burada uygulanmadı. Mevcut Elisp
motorları live consumer taşınmadan kaldırılmaz. Güncel Antigravity araştırması
03 bölüm 4'e eklendi; kaynak oradadır. CLI varlığı/`agy` dokümanı `Ready` iddiası
değildir. Kurulum/login veya gerçek ücretli model/CLI çağrısı yapılmadı.
