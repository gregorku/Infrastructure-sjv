# Implementační plán

Stav: čeká na schválení. Schválení dokumentace neznamená souhlas s implementací. Každá fáze končí ověřitelnými kritérii. Změny mimo repozitář (E1–E7 z [external-changes.md](external-changes.md)) se provádějí jen po samostatném schválení.

## Vstupy, které blokují konkrétní fáze

| Vstup | Blokuje |
| --- | --- |
| E1 Incus kontejner, kapacita VPS | nasazení na VPS od fáze 1 (vývoj a testy lze dělat lokálně) |
| Výsledek ověření ZFS, E5, E6 | fáze 3: vzdálená záloha proti skutečnému domácímu serveru |
| Upload domácí linky | odhad RTO před DR testem ve fázi 13 |
| Počet měřidel a intervaly vysílání | odhad objemu ve fázi 4 |
| Vzorky telegramů, typy měřidel tepla, AES klíče | fáze 6 |
| Hardware ESP | firmware (mimo tento plán, jen návrh) |
| Výsledek ACRIOS PoC (fáze 11) | fáze 12 pro adaptér ACRIOS. Návrh tabulek neblokuje |
| E2, E3, E4 | ostrý provoz (fáze 13) |
| SMTP (E7) | odesílání notifikací (fáze 9). Do té doby zůstávají ve frontě a v administraci |

## Fáze

### 1. Kostra repozitáře a skriptů

- `README.md`, `.gitignore`, `.env.example` s `set_*`.
- `scripts/config.sh`, `lib/logging.sh`, `lib/common.sh`, `lib/env/` (`ENV_POLICY`, sync, validace) převzaté z reference a upravené. Parser `.env` bez `eval`.
- `init.sh`, `update-env.sh`, `check-env.sh`, `test.sh --static`, `shellcheck.sh`.
- Compose: čtyři sítě podle [architecture.md](architecture.md), Traefik (bez `docker.sock`), CrowdSec, správa bouncer klíče převzatá z reference, včetně testů. Soubory a offline testy jsou v repozitáři od B1b. Spuštění na testovacím kontejneru tato etapa neprovádí.
- Zafixování verzí: Python, Node, pgBackRest (s podporou PostgreSQL 18), restic, rest-server. Ověření voleb `expire-auto` v pgBackRest a `manual_ack` v paho-mqtt.
- Hotovo, když:
  - `test.sh --static` a shellcheck projdou,
  - deploy v režimu `local` na testovacím kontejneru spustí Traefik a CrowdSec,
  - kontroly z `checks.md` projdou.

### 2. PostgreSQL a lokální zálohy

- Vlastní image `postgres:18.x` + pgBackRest, `--data-checksums`, archivace WAL, `expire-auto = n`.
- Role DB přes `\getenv`, pořadí deploye „nejdřív DB“.
- `backup.sh` (bez restic kroku), `backup-verify.sh`, `backup-status.sh`, `restore.sh` (lokální zdroj), systemd timery se zámky.
- Hotovo, když:
  - proběhne PITR obnova do izolovaného kontejneru na zvolený čas,
  - `backup-status.sh` hlásí stáří WAL do 2 minut.

### 3. Vzdálená záloha a test obnovy

- Restic krok v `backup.sh` (`daily`) a `backup-remote.sh --wal` se zámky `backup.lock`, `repo.lock` a `remote.lock`.
- `restore-test.sh` ze vzdáleného zdroje (`daily` a přes něj `wal`), s měřením času.
- Do schválení E5 a E6 se testuje proti `rest-server --append-only --private-repos` v lokálním testovacím kontejneru.
- Testy:
  - **append-only** podle [backup-strategy.md](backup-strategy.md#chování-rest-server---append-only): `backup`, `check`, `restore` a `unlock` projdou, `forget`, `prune`, `DELETE` a přepis selžou, cizí cesta je nedostupná,
  - **konzistence:** snapshot `wal` během běžící plné zálohy a během expire. Obnova z `daily` + `wal` musí projít `pgbackrest verify` a PITR na poslední WAL,
  - atomičnost zápisu WAL segmentů v archive-push,
  - obnovovací přístup přes instanci bez `--private-repos` s uživatelem `sjv-recovery`.
- Hotovo, když:
  - všechny testy projdou,
  - `restore-test.sh` ze vzdáleného zdroje projde,
  - vzdálené RPO je naměřené do 15 minut.
- **Bez splnění této fáze se do systému nenahrávají skutečná data.**

### 4. Schéma databáze a migrace

- Alembic podle [database-design.md](database-design.md):
  - kmenová data se soft delete, uživatelé s anonymizací, RBAC (`board` a `technician` nepřiřaditelné),
  - členství, instalace a přiřazení zdrojů s exclusion constrainty,
  - `source_streams` včetně `import` a `vendor:acrios` jako řádku katalogu, ne jako vlastní tabulky,
  - `devices` s neměnným `id`, `device_external_ids`, `device_firmware_history`, `device_placements`, `device_capabilities`,
  - `device_boots`, `ingest_endpoints`, `endpoint_credentials`,
  - `ingest_sources` a `reading_provenance` bez partitioningu,
  - ingest: měsíční partitions `ingest_payloads`, `ingest_receipts`, `ingest_dedup_candidates`, `ingest_rejections`, `raw_telegrams`, `decoded_observations`,
  - `ingest_fragment_sets` a `ingest_fragments` bez partitioningu,
  - `ingest_message_keys` s `PRIMARY KEY (ingest_source_id, msg_key_namespace, msg_key, item_index)` jen pro prokázaný identifikátor, `telegram_dedup_keys`, `unknown_meter_sightings`, `decode_queue` s cizím klíčem,
  - `meter_readings` s `reading_kind`, `quality`, `source_key`, indexem `meter_readings_vendor_time_guard` a triggerem proti změnám, `meter_daily_values`,
  - `notifications`, audit s hash řetězcem.
- `maintenance.sh`: zakládání partitions, retence v daném pořadí s kontrolami, mazání klíčů po 60 dnech.
- Odhad objemu podle skutečného počtu měřidel a intervalů. Objem payloadů ACRIOS se neodhaduje, dokud není vzorek z PoC.
- Schéma se nasazuje bez výsledku PoC. Tabulky ani sloupce nenesou jméno modelu ACRIOS.
- Hotovo, když:
  - `alembic upgrade head` na prázdné DB a `alembic check` projdou,
  - testy constraintů projdou (překryv členství, instalací a přiřazení, změna odečtu, zápis do auditu),
  - výměna IMSI ponechá `device_id` a uzavře starý externí identifikátor,
  - v katalogu tabulek není evidence odečtů pojmenovaná podle transportu nebo výrobce,
  - stejný `msg_key` dvou `ingest_source_id` jsou dva klíče,
  - `server_only` se shodou do 60 dní nepřipojí příjem ke staršímu telegramu a odečet nezaloží,
  - stejný `group_key` po `timed_out` fragment izoluje a k nové sadě ho nepřipojí,
  - test retence na umělých datech: nejdřív kandidáti a příjmy měsíce přijetí, potom fragmenty `DELETE`, potom sada bez zbývajících fragmentů, potom payload a telegram. Sada se nesmaže, dokud na ni fragment ukazuje. Odečet a `reading_provenance` zůstanou a neobsahují cizí klíč na smazaný příjem. Retence se odloží při čekajícím dekódování. `needs_review` bez odečtu ji neblokuje. Příjem z prosince 2028 odkazující na telegram z ledna 2027 se nemaže s lednovou partition.
  - dvě položky jednoho `msg_key` se při prvním doručení obě uloží a při druhém z nich nevznikne odečet,
  - opakované doručení fragmentu má vlastní řádek a vlastní payload,
  - souběžné založení sady nevytvoří dvě otevřené sady a fragment nezahodí,
  - `message_ref` bez zapsaného rozsahu sadu nespojí.

### 5. Ingest, čas a deduplikace

- Mosquitto (TLS listener s testovacím certifikátem, dynsec, interní listener, `queue_qos0_messages false`), collector s ručním PUBACK, HTTPS ingest vlastního kontraktu.
- Časový model: epocha bootu z heartbeatů, zadržení dávky do heartbeatu, validace časů, `captured_at_est`.
- Normalizace rámce, neznámá měřidla, deduplikace, `suspect_replay`, ACK po COMMIT, příjem i pro `duplicate_delivery`.
- Config zařízení přes API a retained topic.
- Simulátor zařízení. Fragmenty a transporty ACRIOS se v této fázi neimplementují. Tabulky pro ně už z fáze 4 jsou.
- Hotovo, když projdou všechny testy deduplikace, času a idempotence z [data-ingestion.md](data-ingestion.md#testy), které se týkají ESP a společného kontraktu. Patří k nim paralelní transakce, pozdní doručení přes hranici měsíce, broker držící dávku během výpadku collectoru a opakované odeslání se stejným `captured_at_est`.

### 6. Dekódování (PoC na skutečných datech)

- Worker s `decode_queue`, volání wmbusmeters, obálkové šifrování klíčů AES.
- Kontroly věrohodnosti (monotónnost, maximální průtok).
- Ověření na vzorcích Apator a měřidel tepla. Pravidla normalizace pro extended link layer a opakovače podle skutečných rámců.
- Hotovo, když vzorky dávají očekávané hodnoty a odečty vznikají přesně jednou na telegram.

### 7. Backend: autentizace, administrace a přístup

- Přihlášení, sezení, CSRF, argon2id, TOTP pro admin, limity pokusů, `create-admin.sh`, anonymizace účtu.
- CRUD kmenových dat, členství, instalace a výměny měřidel, zařízení (založení, odvolání, rotace přes dynsec), klíče AES, config zařízení.
- Preferovaný zdroj: přiřazení, přechod s kontrolami, zablokování, potvrzení administrátorem, audit, přepočet `meter_daily_values`.
- Historie bytu pro administrátora (instalace, členství, přiřazení zdrojů).
- Opravy s auditem, exporty CSV a PDF.
- Hotovo, když:
  - projdou testy oprávnění pro každý endpoint,
  - projdou testy pravidla členství, včetně dvou oddělených období a změny vlastníka,
  - projdou testy přechodu zdroje: úspěšný, zablokovaný, do minulosti a souběh dvou streamů bez zdvojení spotřeby,
  - API testy pokryjí všechny endpointy z [architecture.md](architecture.md).

### 8. Frontend

- Člen: byty, aktuální kumulativní stav měřidla podle schváleného R15 (celkový stav počítadla, ne osobní spotřeba), historie a spotřeba jen za členství, grafy po měsících a letech (ECharts), exporty.
- Administrátor: správa, přehled zařízení, telegramů, neznámých měřidel a anomálií, přechody zdroje, opravy, audit, historie bytu.
- Hotovo, když projdou e2e testy hlavních scénářů (Playwright) a ověření, že UI nikdy nedostane data mimo členství.

### 9. Monitoring a notifikace

- Offline detekce zařízení, alarmy `queue_overflow`, `boot_regression` a `clock_skew`, mlčení přiřazeného streamu, věrohodnost odečtů, přehled stavu záloh v administraci.
- Worker odesílá frontu `notifications`, až bude SMTP. Do té doby přehled v administraci a nenulový kód `backup-status.sh`.

### 10. Produkční TLS pro MQTT

- `cert-sync.sh` s timerem, router `noop@internal` pro MQTT hostname, pokud vznikne. Ověření, zda Mosquitto po `SIGHUP` načte nový certifikát, jinak restart.
- Hotovo, když test obnovy certifikátu (vynucená změna) projde, včetně ověření servírovaného certifikátu a odolnosti klientů proti restartu brokeru.

### 11. ACRIOS PoC

Samostatná fáze před adaptérem. Ověřuje jeden konkrétní kus, ne „ACRIOS obecně“. Jiný model stejného výrobce není tímto PoC pokrytý. Databáze se podle výsledku nepřestavuje. Když vzorek nejde uložit do stávajícího modelu bez tabulky výrobce, upraví se společný kontrakt, ne schéma ACRIOS.

Před fází 12 musí být zapsané:

- konkrétní zařízení a revize hardwaru,
- firmware,
- které z transportů MQTT, UDP/DTLS, HTTPS a Platform API tento kus skutečně má,
- topics nebo tvar API, až jsou pozorované,
- ukázky surového payloadu a ukázky dekódovaného payloadu, pokud je zařízení posílá,
- jestli a jak fragmentuje (identifikátor celé zprávy, pořadí, počet, opakování, timeout, jestli se identifikátor po uzavření použije znovu a v jakém rozsahu je jedinečný),
- jestli se `message_ref` opakuje mezi endpointy, transporty, restarty nebo v čase, po jaké době, a jestli patří zařízení, spojení nebo bootu. Dokud to není zapsané, `message_ref` identita zprávy není,
- jak vypadá opakované doručení a jestli zpráva nese vlastní identifikátor, který se během 60 dní neopakuje,
- jaká je přesnost času dekódované hodnoty,
- jaká autentizace je dostupná (heslo, certifikát, PSK, token platformy). Metoda se v PoC vybírá podle zařízení, ne dopředu,
- jestli jde přijímat data přímým spojením bez ACRIOS Platform.

Zároveň se zapíše, co z toho plyne pro mapování, aniž by se měnily tabulky: stabilita identifikátoru přes výměnu SIM, jaký čas payload nese, jestli dekódovaná data mají ACC nebo čas měřidla, jestli jeden údaj umí i zápis konfigurace.

Hotovo, když je záznam ověření uložený u projektu a je rozhodnuté, které transporty adaptér tohoto kusu bude implementovat. Neznámá hodnota zůstane neznámá. Úspěch PoC není podmínka fáze 4 ani 5.

### 12. Adaptér koncentrátoru

Až po PoC daného zařízení. První očekávaný partner je ACRIOS, postup je stejný pro dalšího výrobce: vlastní PoC, pak adaptér, stream `vendor:<kód>` jen pro data bez rámce, testy na zaznamenaných zprávách, korelace s rádiovým streamem bez sloučení odečtů.

Adaptér zapisuje interní kontrakt. Parser jednoho modelu ACRIOS, MQTT konfigurace toho modelu a nové Compose služby vznikají v této fázi, ne dřív. Když PoC přímý UDP nepotvrdí, UDP listener se nezakládá.

Hotovo, když vzorky z PoC projdou pěti případy deduplikace, neúplná zpráva se nedekóduje a odečty jsou v `meter_readings` bez tabulky výrobce.

### 13. Hardening a ostrý provoz

- Bezpečnostní review, kontrola logů na osobní údaje, revize CrowdSec na ingestu.
- `docs/operations.md` a `docs/checks.md`.
- Obnovovací sada uložená podle [backup-strategy.md](backup-strategy.md).
- **Měřený DR test podle runbooku úplné obnovy na novém VPS, bez přístupu k původnímu VPS, s výsledkem RTO ≤ 4 h.**
- Teprve potom schválené změny E2 až E4 a přepnutí na `TRAEFIK_TLS_MODE=letsencrypt` a `PROXY_PROTOCOL_MODE=haproxy`.

## Firmware

Jen návrh v [firmware-design.md](firmware-design.md). Implementace vyžaduje samostatné schválení a znalost hardwaru. Fáze 5 a 6 se do té doby testují simulátorem a zaznamenanými telegramy.

## Definice dokončení projektu

- Všechny fáze 1–10 a 13 jsou hotové. Fáze 11 je podmínka fáze 12 pro dané zařízení. Fáze 12 se opakuje pro každého dalšího výrobce a na schéma nesahá.
- Poslední `restore-test.sh` je úspěšný a ne starší než 31 dní.
- DR test splnil RTO ≤ 4 h a naměřené RPO ≤ 15 min.
- Provozní dokumentace popisuje všechny postupy, které skripty provádějí.
