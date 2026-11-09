# Bezpečnost

## Co chráníme

- Osobní údaje členů SJV: jméno, e-mail, přiřazení k bytu, historie spotřeby.
- Integrita odečtů a auditní stopy.
- AES klíče měřidel.
- Přístupové údaje zařízení.
- Zálohy a obnovovací údaje.

## Hrozby a opatření

| Hrozba | Hlavní opatření |
| --- | --- |
| Útok na web a přihlášení | Traefik, CrowdSec, rate limit, argon2id, povinné MFA administrátora, blokace účtu |
| Člen vidí cizí data | Kontrola na backendu podle členství a instalace, testy přístupu u každého endpointu |
| Kompromitované zařízení | Účet a ACL pro každé zařízení, okamžité odvolání, klíče AES jen na serveru, kontroly věrohodnosti |
| Podvržené odečty | Šifrovaná měřidla, monotónnost, maximální průtok, korelace více přijímačů, detekce replay |
| Replay zpráv a telegramů | `msg_key` s `instance_id`, deduplikace, `suspect_replay`, limit stáří, TLS a autentizace ([data-ingestion.md](data-ingestion.md#replay)) |
| Chybné nebo podvržené časy zařízení | Čas zachycení počítá server z epochy bootu, hodiny zařízení jsou jen záložní zdroj, limity pro budoucnost a stáří |
| Zdvojená spotřeba při změně zdroje | Jediný přiřazený stream, kontrolovaný a auditovaný přechod |
| Únik databáze | DB jen na interní síti, AES a TOTP šifrované hlavním klíčem mimo DB |
| Kompromitace VPS | Zálohy append-only, mazání jen z domácího serveru, obnovovací sada mimo VPS |
| Neoprávněná změna dat | Opravy jen novým záznamem, audit s hash řetězcem a právem jen na INSERT |

## Uživatelé

- **Hesla:** argon2id (`argon2-cffi`), minimálně 12 znaků, kontrola proti seznamu běžných hesel. Hesla se nikdy nelogují.
- **MFA:** TOTP povinné pro `admin`, pro `member` volitelné. Jednorázové obnovovací kódy (ukládají se jako hash). Tajemství TOTP je šifrované hlavním klíčem. WebAuthn je možné rozšíření.
- **Sezení:**
  - náhodný identifikátor v cookie `HttpOnly; Secure; SameSite=Strict; Path=/`, v DB jen jako hash,
  - neaktivita 30 minut pro admin, 8 hodin pro member, absolutní limit,
  - po změně hesla nebo MFA se všechna sezení zruší.
- **CSRF:** double-submit token pro všechny měnící požadavky. API přijímá jen `application/json`.
- **Omezení pokusů:**
  - po 5 neúspěších na účet exponenciální zpoždění a po 10 dočasná blokace (hodnoty k potvrzení),
  - limit podle IP v aplikaci, `rateLimit` v Traefiku a scénáře CrowdSec pro brute-force na `/api/v1/auth/*`,
  - odpověď neprozrazuje, zda účet existuje.
- **Založení účtu:** pozvánka s jednorázovým tokenem (hash, expirace 72 h). Bez SMTP ukáže administrátor odkaz jednorázově v UI.
- **První administrátor:** `scripts/create-admin.sh` v kontejneru. Heslo se zadává interaktivně a nevypisuje se. MFA se nastaví při prvním přihlášení.
- **Ukončení a výmaz účtu:** uživatel se nemaže, protože na něj odkazují členství a audit. Nejdřív se vypne (`disabled`). Na žádost o výmaz se anonymizuje (`anonymized`): e-mail a jméno se nahradí, smaže se heslo, MFA a sezení. Historie členství zůstane bez osobních údajů. Audit si ponechá jen id a anonymizace se do něj zapíše.

## Role a oprávnění

| Role | Stav | Oprávnění |
| --- | --- | --- |
| `admin` | aktivní | správa uživatelů, budov, bytů, členství, měřidel, zařízení, opravy, audit, exporty všech dat |
| `member` | aktivní | jen vlastní byty, jen za období členství, vlastní exporty |
| `board` | v datech, nepřiřaditelná | připraveno: čtení všech dat bez úprav |
| `technician` | v datech, nepřiřaditelná | připraveno: měřidla a zařízení bez osobních údajů |

- Autorizace jde přes oprávnění (`permissions`), ne přes jména rolí v kódu. Nová role je jen nová sada oprávnění.
- Každý endpoint deklaruje potřebné oprávnění. Testy ověří, že neexistuje endpoint bez deklarace.
- **Data členů** filtruje repozitářová vrstva, ne UI: měřidlo instalované v bytě v čase odečtu a čas uvnitř členství. Id bytu nebo měřidla z URL se vždy ověří proti těmto pravidlům. Neexistující a cizí objekt vrací stejnou odpověď `404`. Celé pravidlo je v [database-design.md](database-design.md#historie-bytu-přístup-oddělený-od-spotřeby).
- **Přístup je oddělený od spotřeby.** Data spotřeby patří bytu a měřidlu, členství jen určuje viditelné období. Změna vlastníka nemění data spotřeby, takže nový vlastník nevidí historii předchozího a předchozí vlastník po skončení členství nevidí nová data.
- **Aktuální stav měřidla:** člen vidí aktuální absolutní hodnotu počítadla, stejnou jako na fyzickém displeji. Ta nepřímo obsahuje součet spotřeby od instalace měřidla, včetně doby před členstvím. Historie a spotřeba jsou jen za období členství. Je to k potvrzení ([decisions.md](decisions.md)). Alternativou je ukazovat jen spotřebu od začátku členství.
- **Historie pro administrátora:** `GET /admin/apartments/{id}/history` vrací instalace a výměny měřidel, členství a přiřazení zdrojů v čase. Přístup do ní se audituje.
- Testy přístupu: pro každý endpoint člena se ověří cizí byt, období před členstvím a po jeho skončení, dvě oddělená období jednoho člena a měřidlo po výměně.

## Zařízení

- **Založení:** administrátor zařízení založí v UI. Backend vygeneruje údaje a založí účet v Mosquitto Dynamic Security (jméno = client ID = kód zařízení) nebo API token pro HTTPS. Údaje se zobrazí jednou a v DB zůstane jen hash.
- **ACL:** zařízení smí jen do vlastních topiců (viz [data-ingestion.md](data-ingestion.md)). Výchozí politika je zakázat.
- **Odvolání:** `POST /admin/devices/{id}/revoke`
  1. vypne klienta v dynsec, broker ho odpojí,
  2. nastaví `revoked_at` na údajích a stav `revoked`,
  3. zapíše audit.

  Zprávy, které po odvolání ještě dorazí přes HTTPS, se odmítnou.
- **Rotace:** nové údaje se založí dřív, než se staré zruší. Obě sady platí po krátkou přechodnou dobu.
- **TLS:** MQTT jen na 8883 s TLS ≥ 1.2. Listener 1883 je jen v interní síti. Klientské certifikáty (mTLS) lze doplnit později.
- **Kompromitace zařízení** (postup v provozní dokumentaci):
  1. odvolat,
  2. zkontrolovat odečty, které zařízení samo doručilo v podezřelém období,
  3. zařízení nastavit znovu s novými údaji, nebo ho vyřadit.

  Klíče AES zařízení nemá, takže je neprozradí.
- **Věrohodnost odečtů:** pokles kumulativní hodnoty, překročení maximálního průtoku, odečet potvrzený jen jedním zařízením, ačkoli jiná zařízení stejné měřidlo pravidelně přijímají. Všechno se označí pro administrátora a do spotřeby se nepromítne bez potvrzení.
- **Čas a replay:** zařízení nemůže posunout čas odečtu libovolně. Čas zachycení počítá server z vlastních časů příjmu heartbeatů. Hodiny zařízení se ignorují, když jsou v budoucnosti, a rozpor se hlásí. Opakovaný obsah mimo okno deduplikace se neuloží jako odečet (`suspect_replay`). Kompromitované zařízení s platnými údaji může poslat smyšlený rámec nešifrovaného měřidla. Proti tomu pomáhá jen šifrování měřidel a korelace s jinými přijímači.
- **Přechod zdroje odečtů** smí provést jen `admin`, s povinným důvodem a auditem hraničních hodnot. Neúspěšné kontroly vyžadují výslovné potvrzení.

## AES klíče měřidel

- **Obálkové šifrování:** klíč měřidla se šifruje AES-256-GCM hlavním klíčem aplikace (KEK). KEK je v souboru `/docker-data/infrastructure-sjv/secrets/app-kek` s právy `600`, mimo DB i Git. Kontejner ho dostane jako Docker secret jen do backendu a workeru.
- **Zápis:** `PUT /admin/meters/{id}/key`. Hodnota se už nikdy nezobrazí, UI ukazuje jen otisk. Zápis i změna jdou do auditu bez hodnoty klíče.
- **Použití:** klíč se dešifruje jen ve workeru v okamžiku dekódování. Nikdy se nedostane do argumentu procesu, do logu ani do zařízení.
- **Rotace KEK:** skript přešifruje všechny záznamy v jedné transakci a starý KEK ponechá do ověření zálohy.
- **Záloha KEK:** bez KEK jsou zálohované klíče AES a tajemství TOTP nepoužitelné. KEK je proto v zálohách restic i samostatně v obnovovací sadě.

## Secrets a konfigurace

- Konvence z reference: runtime `.env` je jen v `/docker-data/stacks/infrastructure-sjv/.env` s právy `600`. Šablona `.env.example` obsahuje jen placeholdery `set_*`, které `check-env.sh` odmítne. Generovaná hesla se nikdy nevypisují.
- `test.sh --static` ověří, že `.env`, klíče, `acme.json`, `htpasswd` ani soubory dynsec nejsou v checkoutu a že je ignoruje `.gitignore`.
- Hesla jdou do psql přes `\getenv` a do Mosquitta přes soubor, nikdy jako argument procesu.

## Síť

- Ven publikují porty jen `sjv-traefik` (80, 443) a `sjv-mosquitto` (8883).
- PostgreSQL je jen na `sjv-internal` (`internal: true`), bez portu.
- Traefik nemá `docker.sock`.
- PROXY protocol jen od adresy HAProxy jako `/32` (předpoklad `10.10.10.1/32`, ověří se pozorováním). `insecure` je zakázané a forwarded hlavičky se nedůvěřují. Převzato z reference včetně testů.
- Dashboard Traefiku jen na entrypointu `admin` s allowlistem a BasicAuth.

## CrowdSec

- Čte access log Traefiku, kolekce `crowdsecurity/linux` a `crowdsecurity/traefik`. Správa bouncer klíče je převzatá z reference beze změny logiky.
- Na ingest endpointech platí opatrnost kvůli CGNAT (viz [data-ingestion.md](data-ingestion.md)).
- MQTT CrowdSec nechrání. Mosquitto chrání autentizace, ACL a limity spojení. Zda existuje vhodný parser logu Mosquitta, ověřím. Bez něj se nepočítá s blokací na úrovni MQTT.

## Logování a audit

- **Logy aplikace** jsou strukturované (JSON) s `request_id`. Bez hesel, tokenů, klíčů a obsahu telegramů. E-mail jen tam, kde je nutný.
- **Audit** zaznamenává:
  - přihlášení a odhlášení, selhání, změny MFA,
  - všechny administrátorské změny s hodnotou před a po,
  - opravy s důvodem,
  - změny zařízení a klíčů (bez hodnot), exporty,
  - retenční mazání.
- **Integrita auditu:** hash řetězec. Aplikační role smí jen INSERT. Ověřuje se při `backup-verify.sh` a `restore-test.sh`.

## Ochrana osobních údajů

Správcem je SJV. Projekt dodává technická opatření, ale ne právní dokumenty.

- **Minimalizace:** ukládá se jen nutné. Rámce cizích měřidel se neukládají (whitelist v zařízení, na serveru jen počet zachycení v `unknown_meter_sightings`).
- **Retence** podle [decisions.md](decisions.md). Zálohy prodlužují uložení až o 3 roky (roční snapshoty). Musí to být v záznamech o zpracování.
- **Odečty se uchovávají trvale** a patří bytu, ne osobě. Osobní údaj vzniká jen spojením s členstvím. Po anonymizaci uživatele zůstanou odečty bez vazby na osobu.
- **Práva subjektu:** export vlastních dat (CSV a PDF) pro člena, export za člena pro administrátora, anonymizace účtu.
- **Změna vlastníka bytu:** nový člen nevidí historii předchozího, předchozí člen po ukončení členství nevidí nová data.

## Reakce na incident

| Událost | První kroky |
| --- | --- |
| Kompromitace zařízení | odvolat, revize odečtů, nové údaje |
| Kompromitace účtu admin | zablokovat, zrušit sezení, revize auditu, reset MFA |
| Kompromitace VPS | odpojit, na domácím serveru odebrat klíč restic `vps` a heslo uživatele `infrastructure-sjv` v `rest-server`, úplná obnova podle [backup-strategy.md](backup-strategy.md#úplná-obnova-na-novém-vps) s obnovovací sadou, rotace všech secrets a údajů zařízení |
| Únik databáze | posoudit dopad, rotace KEK a hesel, oznámení podle povinností správce |
