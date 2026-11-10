# Rozhodnutí

Stav: dokumentace po technické revizi (kolo 3) z 9. 11. 2026, doplněná 10. 11. 2026 o univerzální datovou vrstvu a ACRIOS (rozhodnutí 15–19). R15 zůstává schválené a beze změny. Schválení dokumentace neznamená souhlas s nasazením.

## Potvrzená rozhodnutí

| # | Rozhodnutí | Dopad |
| --- | --- | --- |
| 1 | PostgreSQL 18.x + pgBackRest pro WAL a PITR | Vlastní image `postgres:18.x` + pgBackRest, sestavovaný lokálně |
| 2 | Restic pro šifrované vzdálené zálohy | Snapshoty `daily` (celý repozitář pgBackRest, dumpy, soubory stacku) a `wal` (jen archiv WAL), viz [backup-strategy.md](backup-strategy.md) |
| 3 | Push na append-only `rest-server` přes WireGuard | VPS zálohy zapisuje a čte, ale nemůže je mazat ani přepsat |
| 4 | ZFS snapshoty na domácím serveru | Jen jako návrh. Existující ZFS konfigurace se nemění |
| 5 | MQTT TLS ukončené přímo v Mosquittu | Certifikát se exportuje z ACME Traefiku, viz [architecture.md](architecture.md) |
| 6 | Vlastní firmware ESP s frontou a aplikačním ACK | Zatím jen návrh v [firmware-design.md](firmware-design.md) |
| 7 | Člen vidí historii jen za období svého členství v bytě | Přístup je oddělený od spotřeby, viz [database-design.md](database-design.md#historie-bytu-přístup-oddělený-od-spotřeby) |
| 8 | Aktivní role `admin` a `member` | `board` a `technician` existují v datech jako nepřiřaditelné |
| 9 | Bez Dockge | Deploy nekontroluje kontejner Dockge |
| 10 | Image se staví lokálně při deployi | Bez CI a GHCR. Base image mají přesný tag a digest |
| 11 | Plánované úlohy přes systemd timers | Zálohy, testy obnovy, certifikáty, údržba partitions, viz [architecture.md](architecture.md#plánované-úlohy-systemd-timers) |
| 12 | Dokumentace malými písmeny | Stejná konvence jako `Infrastructure-Nextcloud-Lu` |
| 13 | Aplikace je jen informační | Bez rozúčtování nákladů a bez výpočtu cen |
| 14 | Člen vidí aktuální kumulativní stav měřidla a historii jen za své členství | Hodnota je celkový stav počítadla, ne osobní spotřeba. Administrátor má kompletní historii |
| 15 | PostgreSQL je centrální a jediný dlouhodobý zdroj pravdy | Všechna data z koncentrátoru, zařízení, transportu i importu se evidují v jednom modelu SJV. Model nezávisí na výrobci, modelu zařízení ani protokolu |
| 16 | ACRIOS je integrační partner, ne vlastník modelu | Adaptér převádí příjem na jeden interní kontrakt. Oddělený model výrobce ani evidence odečtů podle transportu nevzniká |
| 17 | `devices.id` je neměnné a měřidlo nepatří koncentrátoru | IMSI a IMEI jsou externí identifikátory s historií. Výměna SIM nezakládá nové zařízení ani novou historii |
| 18 | Deduplikace raw telegramů zůstává a rozšiřuje se na pět případů příjmu | Stejná naměřená hodnota sama o sobě zprávy neslučuje. Neúplná fragmentovaná zpráva se dekodéru nepředává |
| 19 | Schéma je nezávislé na ACRIOS PoC | PoC je podmínka adaptéru daného zařízení, ne podmínka tabulek. Stejná brána platí pro dalšího výrobce |

## Retence

| Data | Retence | Mechanismus |
| --- | --- | --- |
| Odečty (`meter_readings`) a denní hodnoty (`meter_daily_values`) | trvale | tabulky bez partitioningu, bez cizích klíčů na data s retencí |
| Původní obálky (`ingest_payloads`), příjmy (`ingest_receipts`), fragmenty (`ingest_fragments`, `ingest_fragment_sets`), odmítnuté obálky (`ingest_rejections`), surové telegramy (`raw_telegrams`), dekódovaná pozorování (`decoded_observations`) | 24 měsíců | měsíční partitions, mazání celé partition. `ingest_receipts` nahrazuje dřívější `telegram_receipts` |
| Události zařízení (`device_events`) | 12 měsíců | měsíční partitions |
| Audit (`audit_logs`) | dlouhodobě | bez partitioningu, hash řetězec, jen INSERT |
| Klíče idempotence a deduplikace, epochy bootů | 60 dní | `DELETE` v dávkách. Delší než maximální stáří zprávy (30 dní) |
| Neznámá měřidla (`unknown_meter_sightings`) | 90 dní od posledního zachycení | `DELETE` |
| Pokusy o přihlášení, notifikace | 90 dní (návrh k potvrzení) | `DELETE` |

Mazání respektuje vazby: nejdřív příjmy, fragmenty a odmítnutí, potom payloady, telegramy a pozorování. Retence se odloží, pokud v měsíci čekají telegramy na dekódování, dekódovanému telegramu chybí odečet, nebo na mazaný payload ještě odkazuje příjem. Pořadí je v [database-design.md](database-design.md#retence-a-vazby).

Zálohy prodlužují faktickou dobu uložení. Roční snapshot restic drží data až 3 roky po jejich smazání z databáze. Patří to do záznamů o zpracování osobních údajů.

## Revize v kole 3

Změny proti dokumentaci z kola 2. Všech devět dokumentů je s nimi sladěných.

| # | Oblast | Problém v kole 2 | Rozhodnutí |
| --- | --- | --- | --- |
| R1 | Čas zachycení (`age_ms`) | `age_ms` uložené při prvním zachycení by bylo nulové. Kotva `server_received_at − age_ms` byla chybná, když broker držel zprávu pro odpojený collector | Fronta ESP uchovává referenci zachycení (`rx_instance`, `rx_boot`, `rx_uptime_ms`, `rx_unix_ms`) beze změny. `age_ms` se přepočítá při každém odeslání ve stejném bootu. Server odhaduje epochu bootu jako minimum `server_received − tx_uptime` z heartbeatů (QoS 0) a HTTPS. `captured_at_est = epocha + rx_uptime`. Ukládá se `server_received_at`, `captured_at_est`, `time_source` a nejistota. Nová tabulka `device_boots`. Validace a replay v [data-ingestion.md](data-ingestion.md#časový-model) |
| R2 | `msg_key` | `<boot_counter>-<seq>` se po vymazání flash opakuje | `<instance_id>-<boot_counter>-<seq>`, `instance_id` náhodných 64 bitů |
| R3 | Preferovaný zdroj | `meters.preferred_stream` bez historie. Ostatní streamy doplňovaly mezery, což mohlo míchat dvě nezávislá počítadla | Tabulky `source_streams` a `meter_source_assignments` (bez překryvu). Bez doplňování mezer a bez automatického přepnutí. Přechod navazuje na poslední kumulativní stav, kontroluje `V2 ≥ V1`, průtok a toleranci. Při nesplnění je zablokovaný do potvrzení administrátorem. Vše se audituje |
| R4 | Konzistence vzdálené kopie | Restic každých 5 min kopíroval celý repozitář pgBackRest i během zálohy a expire | `daily` jen v klidovém stavu po `pgbackrest backup`, `expire-auto = n` a expire až po snapshotu. `wal` jen `archive/`, se sdíleným zámkem proti expire. Obnova = `daily` + `archive/` z `wal`. Retence podle tagů |
| R5 | Sítě Docker | Síť `internal: true` nemůže publikovat porty ani odchozí spojení | Čtyři sítě: `sjv-proxy`, `sjv-internal`, `sjv-mqtt`, `sjv-egress` |
| R6 | E-maily | Nebylo určeno, kdo posílá | Fronta `notifications`, odesílá worker (síť `sjv-egress`) |
| R7 | Neznámá měřidla | Telegramy se ukládaly do dekódování | Stav příjmu `unknown_meter`, rámec se neukládá, jen `unknown_meter_sightings` |
| R8 | `meter_readings` | Cizí klíče na tabulky s retencí by blokovaly mazání. `installation_id` duplikoval instalace | Bez cizích klíčů na raw a decoded, bez `installation_id`. Doplněno `receipt_count` a `capture_device_ids`. Trigger povolí měnit jen tyto sloupce a `superseded_at` |
| R9 | `decode_queue` | Bez vazby na telegram | Cizí klíč `(raw_telegram_id, raw_partition_month)`. Retence kontroluje frontu |
| R10 | REST API | Rozptýlené po dokumentech | Jeden katalog v [architecture.md](architecture.md) |
| R11 | Neověřené hodnoty | CPU a RAM kontejneru, kapacita fronty firmware a rychlosti linky byly uvedené konkrétně | `<CPU>`, `<RAM>`, kapacita jen jako vzorec, rychlost linky jen jako ilustrační výpočet |
| R12 | Denní hodnoty | Nebylo určeno, ze kterých streamů a v jakém časovém pásmu | Jen z efektivní řady (přiřazené streamy), den v `Europe/Prague` |
| R13 | Obnovovací přístup | Uživatel `sjv-vps` neodpovídal cestě `infrastructure-sjv/` při `--private-repos`. Druhý uživatel ve stejné instanci by k repozitáři neměl přístup | Uživatel VPS se jmenuje `infrastructure-sjv`. Pro obnovu je předem připravená vypnutá instance `rest-server-sjv-recovery` bez `--private-repos` s uživatelem `sjv-recovery` |
| R14 | Heartbeat a broker | Heartbeat nenesl časovou referenci. Broker mohl hromadit QoS 0 | `queue_qos0_messages false`. Heartbeat nese `instance`, `boot`, `uptime_ms`, `at` |
| R15 | Aktuální stav pro člena | Nebylo určeno | Schváleno. Člen vidí aktuální kumulativní stav měřidla, označený jako celkový stav počítadla, ne jako osobní spotřebu. Historické odečty a vypočítanou spotřebu vidí jen za období svého členství. Administrátor má kompletní historii |
| R16 | Retence odečtů | „dlouhodobě“ | „trvale“, podle zadání |

## Doplnění 10. 11. 2026: univerzální datová vrstva a ACRIOS

Rozhodnutí 15–19. Podrobnosti jsou v [architecture.md](architecture.md), [data-ingestion.md](data-ingestion.md), [database-design.md](database-design.md), [security.md](security.md) a [implementation-plan.md](implementation-plan.md).

| # | Pravidlo |
| --- | --- |
| 15 | Cokoli přijde z ACRIOS MQTT, ACRIOS UDP/DTLS, ACRIOS HTTPS, ACRIOS Platform API, vlastního ESP32/LILYGO, jiného koncentrátoru nebo z importu CSV a dalších podporovaných souborů, uloží se do PostgreSQL. Databáze není model výrobce. |
| 16 | Adaptér umí jen převod na interní kontrakt. Když zdroj pošle jen dekódovanou hodnotu, uloží se původní JSON nebo CSV. Chybějící raw telegram se nevymýšlí. |
| 17 | Interní `device_id` se po založení nemění a znovu se nepřiděluje. Výměna SIM uzavře staré IMSI nebo ICCID a přidá nové ke stejnému zařízení. Nový řádek `devices` vzniká při výměně hardwaru, ne při výměně SIM. Měřidlo nemá vazbu „patří koncentrátoru“. |
| 18 | Pět případů se eviduje odděleně: opakované doručení stejné zprávy, stejný telegram od více koncentrátorů, nový telegram se stejnou hodnotou, fragmenty jedné zprávy, opětovné dekódování novou verzí dekodéru. Každý příjem má záznam. Jeden skutečný odečet má jeden aktivní řádek `meter_readings`. |
| 19 | Fáze ACRIOS PoC ověří konkrétní zařízení dřív, než vznikne jeho adaptér. Tabulky na výsledek PoC nečekají a neobsahují sloupce jednoho modelu. Další výrobce dostane vlastní PoC a stejný model. |

R15 se tím nemění. Aktuální stav pro člena je dál poslední kumulativní stav přiřazeného streamu, označený jako celkový stav počítadla. Intervalové hodnoty a události ho nenahrazují.

Další upřesnění bez samostatného čísla:

- Uživatel se nemaže, ale anonymizuje (vazby na členství a audit). Kmenová data mají soft delete.
- Ruční PUBACK v paho-mqtt 2.x (`manual_ack`), `SIGHUP` u Mosquitta, podpora PROXY protocolu v Mosquittu, volba `expire-auto` v pgBackRest, atomičnost zápisu WAL a názvy voleb `services.restic.server` v NixOS jsou označené jako „k ověření“.
- Runbook úplné obnovy na novém VPS (kroky 0–13) je v [backup-strategy.md](backup-strategy.md#úplná-obnova-na-novém-vps).

## Otevřené body

Hodnoty, které nejsou známé, se nedoplňují odhadem.

| Bod | Blokuje |
| --- | --- |
| Volná IP v `incusbr0` a kapacita VPS (`<CPU>`, `<RAM>`, disk) | E1, nasazení na VPS |
| Zda lze na `serveftp.org` založit `sjv-mqtt.serveftp.org` a jak se jméno udržuje | E2, MQTT hostname |
| Skutečný ZFS pool a výsledek ověření. `zfs-RAID-6TB` v NixOS konfiguraci `domaPcServer` není | E6, fáze 3 |
| Upload domácí linky | odhad RTO před DR testem ve fázi 13 |
| WireGuard rozhraní MikroTiku, LAN IP `domaPcServer`, porty `<P>` a `<P2>` | E5 |
| SMTP účet | E7, notifikace |
| Retence ZFS snapshotů, pokusů o přihlášení a notifikací | E6, fáze 4 |
| Maximální stáří zprávy (návrh 30 dní) | fáze 5 |
| Hardware ESP (čip, rádio, flash, konektivita, napájení) | firmware |
| Vzorky telegramů, typy měřidel tepla, AES klíče | fáze 6 |
| Dokumentace a vzorky konkrétního ACRIOS: model, revize hardwaru, firmware, skutečně dostupné transporty, topics nebo API, surové i dekódované payloady, fragmentace, opakované doručení, autentizace, přímé připojení bez ACRIOS Platform | fáze 11 (PoC). Neblokuje návrh tabulek ani fázi 4. Blokuje fázi 12 pro tento přístroj |
| Zda další model ACRIOS umí totéž co přístroj z PoC | nesmí se předpokládat. Každý model má vlastní záznam schopností a případně vlastní PoC |
| Zda Platform API vrací stabilní identifikátor koncentrátoru přes výměnu SIM, jaký čas payload nese a zda dekódovaná data obsahují ACC nebo čas měřidla | mapování adaptéru ve fázi 12, ne tvar tabulek |
| UDP/DTLS port a případný DNAT, pokud PoC přímý UDP potvrdí | samostatná změna mimo repozitář, až po PoC. Teď se port nepublikuje |
| Počet měřidel a intervaly vysílání | odhad objemu, fáze 4 |
| Verze software a ověření bodů „k ověření“ | fáze 1–3 |
