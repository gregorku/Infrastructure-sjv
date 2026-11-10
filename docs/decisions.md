# Rozhodnutí

Stav: dokumentace po technické revizi (kolo 3) z 9. 11. 2026, doplněná 10. 11. 2026 o univerzální datovou vrstvu a ACRIOS (rozhodnutí 15–19), druhé kolo kontroly příjmu (20–24), třetí kolo (25–30) a upřesnění formulace 20 a 26 ve čtvrtém kole. Nové číslo rozhodnutí nevzniklo. R15 zůstává schválené a beze změny. Schválení dokumentace neznamená souhlas s nasazením.

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
| 20 | Idempotence prokázané položky je `(ingest_source_id, msg_key_namespace, msg_key, item_index)` | Jedna zpráva se zpracuje celá. Klíč bez `item_index` by druhou položku prvního doručení označil jako opakování. Hash těla klíčem není |
| 21 | Shoda rámce mimo důvěryhodné okno není potvrzená duplicita | `server_only` uloží vlastní telegram a odečet nezaloží. Bitově shodný rámec po přetočení `access_number` za 60 dní se ke staršímu nepřipojí |
| 22 | Čas ani hodnota dekódované položky nejsou identita měření | Nové pozorování zůstane. Druhý aktivní kumulativní odečet ve stejném čase nevznikne. Původní odečet se nepřepíše |
| 23 | Trvalá provenience odečtu je souhrn, ne kopie příjmu | `reading_provenance` plus verze, `frame_hash`, `receipt_count` a `capture_device_ids`. Payload a jednotlivé příjmy mají retenci. Rozsah upřesňuje rozhodnutí 28 |
| 24 | `group_key` není globálně jedinečné | Po ukončení sady se fragment bez prokázaného rozsahu `message_ref` izoluje. K nové sadě se nepřipojí. Upřesnění je v rozhodnutí 26 a 27 |
| 25 | Hash obsahu není identita zprávy | Stejný obsah bez prokázaného identifikátoru zůstane dvě pozorování se stavem `uncertain` |
| 26 | Nejednoznačný fragment se izoluje a `message_ref` bez prokázaného rozsahu sadu nespojí | Opožděný fragment staré sady se nepřipojí k sadě se stejným `group_key`. Text od zdroje není identita, dokud PoC nezapíše rozsah |
| 27 | Retence příjmu je 24 měsíců od `server_received_at` | Příjem nemá cizí klíč na starší telegram. Odkaz je ve sloupcích |
| 28 | Provenience neobsahuje id smazaných řádků | Nese zdroj, který odečet založil, a jen potvrzené další zdroje |
| 29 | MQTT a HTTPS nesdílejí `msg_key`, dokud to kontrakt neprokáže | Výchozí `msg_key_scope = transport`. Stejný text na druhém transportu je `id_collision` |
| 30 | `meter_readings_vendor_time_guard` chrání jen projekci | Konfliktní pozorování se vloží dřív než odečet a index je nesmaže |

## Retence

| Data | Retence | Mechanismus |
| --- | --- | --- |
| Odečty (`meter_readings`), denní hodnoty (`meter_daily_values`), souhrnná provenience (`reading_provenance`), příjmové zdroje (`ingest_sources`) | trvale | tabulky bez partitioningu. Odečty a provenience nemají cizí klíč na data s retencí |
| Původní obálky (`ingest_payloads`), příjmy (`ingest_receipts`), kandidáti deduplikace (`ingest_dedup_candidates`), odmítnuté obálky (`ingest_rejections`), dekódovaná pozorování (`decoded_observations`) | 24 měsíců stáří měsíce přijetí | měsíční partitions. Příjem z prosince se nemaže s telegramem z ledna |
| Surové telegramy (`raw_telegrams`) | 24 měsíců stáří měsíce kotvy | měsíční partitions. Pozdější příjem tuto dobu neprodlužuje a cizím klíčem ji nedrží |
| Fragmentové sady (`ingest_fragment_sets`) a fragmenty (`ingest_fragments`) | 24 měsíců od `first_received_at` a od `received_at` | bez partitioningu. Nejdřív `DELETE` fragmentů, potom sady, na kterou už žádný fragment neukazuje. Pozdní fragment sadu podrží. Každé doručení fragmentu je vlastní řádek |
| Události zařízení (`device_events`) | 12 měsíců | měsíční partitions |
| Audit (`audit_logs`) | dlouhodobě | bez partitioningu, hash řetězec, jen INSERT |
| Klíče idempotence a deduplikace, epochy bootů | 60 dní | `DELETE` v dávkách. Delší než maximální stáří zprávy (30 dní) |
| Neznámá měřidla (`unknown_meter_sightings`) | 90 dní od posledního zachycení | `DELETE` |
| Pokusy o přihlášení, notifikace | 90 dní (návrh k potvrzení) | `DELETE` |

Mazání respektuje vazby: nejdřív kandidáti, příjmy, odmítnutí a pozorování měsíce přijetí, potom fragmenty, potom sada, na kterou už žádný fragment neukazuje, potom payloady a telegramy. Příjem na telegram cizí klíč nemá. Sada starší než svůj poslední fragment se nemaže. Retence se odloží, pokud v měsíci čekají telegramy na dekódování, telegramu ve stavu `decoded` chybí odečet, nebo na mazaný payload ještě odkazuje řádek téhož měsíce. `needs_review` a `ambiguous` bez odečtu retenci neblokují. Pořadí je v [database-design.md](database-design.md#retence-a-vazby).

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

R15 se tím nemění. Aktuální stav pro člena je dál poslední kumulativní stav přiřazeného streamu, označený jako celkový stav počítadla. Intervalové hodnoty a události ho nenahrazují. Nevyřešený rámec (`ambiguous`, `needs_review`, `suspect_replay`) a nevyřešené pozorování (`unresolved`, `conflict`) odečet nezaloží, takže tuto hodnotu samy neposunou.

## Doplnění 10. 11. 2026: druhé kolo kontroly příjmu

Rozhodnutí 20–24. Chrání se tím příjem, který by se jinak ztratil nebo sloučil s jinou zprávou. Podrobnosti jsou v [database-design.md](database-design.md) a [data-ingestion.md](data-ingestion.md).

| # | Proč tak a co by sloučení pokazilo |
| --- | --- |
| 20 | `PRIMARY KEY (device_id, msg_key)` neumí import a platformu bez zařízení, protože NULL v primárním klíči není. `ingest_sources.id` je identita zdroje a `devices.id` zůstává fyzická atribuce. Stejný `msg_key` dvou zdrojů jsou dvě zprávy. Klíč položky je `(ingest_source_id, msg_key_namespace, msg_key, item_index)`. Bez `item_index` by druhá položka téhož prvního doručení vypadala jako opakování celé zprávy a její odečet by nevznikl. Věta, že se neprokázaný identifikátor nahradí hashem těla, se ruší rozhodnutím 25. |
| 21 | Připojení bitově shodného rámce k telegramu z posledních 60 dní je širší než `dedup_window`. Osmibitové `access_number` se za těch 60 dní přetočí, takže shoda může být nové vysílání. Nový rámec se uloží zvlášť, kandidát se jen zaznamená a odečet nevznikne. Tím nevznikne falešná jistota a původní pozorování nezmizí. Spotřeba a R15 zůstanou na posledním důvěryhodném kumulativním odečtu. |
| 22 | Unikátní index na čase by dvě položky se stejným hrubým časem smazal do jednoho měření. Pozorování se ukládá vždy. Index `meter_readings_vendor_time_guard` jen brání dvěma aktivním kumulativním bodům v jednom čase. Stejný čas se stejnou hodnotou je `unresolved`, jiná hodnota je `conflict`. Ani jedno není `duplicate` a původní odečet se nepřepíše. Postup, který pozorování opravdu zachová, je v rozhodnutí 30. |
| 23 | `receipt_count`, `capture_device_ids` a verze neřeknou, který nepřiřazený zdroj a která položka odečet založily. `reading_provenance` to nese trvale, jeden řádek na odečet. Bajty a jednotlivé časy doručení se po 24 měsících neuchovávají podruhé. Rozsah souhrnu a zákaz odkazů na smazané řádky jsou v rozhodnutí 28. |
| 24 | `UNIQUE (device_id, group_key, partition_month)` by po uzavření sady další zprávu zahodil. `group_key` není globálně jedinečné. Věta, že po uzavření vznikne nová sbírající sada, se ruší rozhodnutím 26: opožděný fragment by se k ní přilepil. Věta, že partition příjmu je měsíc cíle cizího klíče, se ruší rozhodnutím 27: prosincový příjem by se smazal s lednovým telegramem. |

## Doplnění 10. 11. 2026: třetí kolo kontroly příjmu

Rozhodnutí 25–30. Mění věty z 20 a 24, které pořád mohly sloučit nebo předčasně smazat původní data. R15, PostgreSQL jako jediný dlouhodobý zdroj pravdy a rozhodnutí 15–19 se nemění. Podrobnosti jsou v [database-design.md](database-design.md) a [data-ingestion.md](data-ingestion.md).

| # | Proč tak a co by sloučení pokazilo |
| --- | --- |
| 25 | `sha256` těla nerozliší novou zprávu se stejným obsahem od opakovaného odeslání. Klíč se založí jen pro prokázaný identifikátor. Jinak zůstanou dvě doručení a dvě pozorování se stavem `uncertain` a druhý odečet nevznikne. |
| 26 | Po `timed_out` sady s `group_key = G` by další fragment s `G` spadl do nové otevřené sady a smíchal dvě zprávy. Bez prokázaného rozsahu `message_ref` se izoluje: payload zůstane, sada se nesloží a dekodér ji nedostane. `group_key` se nepovažuje za globálně jedinečné. Přítomnost textu `message_ref` rozsah neprokazuje. Prokázané znamená, že se identifikátor po dobu skládání neopakuje mezi endpointy, transporty, restarty ani v čase. Do té doby text zůstane na fragmentu a sadu nespojí. |
| 27 | Příjem z prosince 2028 uložený do lednové partition 2027 by se smazal asi měsíc po doručení. `partition_month` příjmu je měsíc `server_received_at`. Odkaz na telegram jsou sloupce bez cizího klíče, protože životnosti se liší. Po smazání telegramu se z odkazu řádek nenačte a cizí klíč se tím neporuší. |
| 28 | Trvalá provenience říká, který zdroj odečet založil, a v `confirmed_source_ids` které další zdroje byly potvrzená duplicita. Nejistý, konfliktní a izolovaný příjem do souhrnu nepatří. Neukládají se `receipt_id`, `payload_id` ani id telegramu, protože po retenci by to byly odkazy na smazané řádky. |
| 29 | Firmware ESP garantuje stejný `msg_key` při opakovaném odeslání záznamu fronty. Negarantuje jeden prostor pro MQTT a HTTPS. Výchozí `msg_key_scope = transport`. Stejný text na druhém transportu je `id_collision`, obě doručení zůstanou a `delivery_count` se mezi nimi nesčítá. |
| 30 | Dva vendor payloady se stejným časem mohou být dvě měření. Oba se uloží jako pozorování dřív, než se zkouší odečet. Index smí odmítnout druhý aktivní kumulativní bod. Nesmí smazat druhé pozorování ani přepsat první odečet. Administrátor rozhodne auditem. Dva aktivní body ve stejném čase dál nevzniknou, takže R15 dál ukazuje jeden aktivní kumulativní stav. |

Další upřesnění bez samostatného čísla:

- Uživatel se nemaže, ale anonymizuje (vazby na členství a audit). Kmenová data mají soft delete.
- Jedna přijatá zpráva je jedna transakce. Uložený výsledek se vede po položkách. Logické selhání jedné položky ostatní nepřeskočí. Neočekávaná chyba celou transakci vrátí a ACK se nepošle.
- Každé doručení fragmentu je řádek `ingest_fragments` s vlastním payloadem. Agregovaný počet doručení evidenci jednotlivých řádků nenahrazuje.
- Dva procesy, které současně nezaloží sadu, drží `pg_advisory_xact_lock` na rozsahu jedinečnosti. Konflikt unikátního indexu zopakuje vyhledání. Fragment se nezahodí a nepřipojí se k jiné sadě.
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
| Dokumentace a vzorky konkrétního ACRIOS: model, revize hardwaru, firmware, skutečně dostupné transporty, topics nebo API, surové i dekódované payloady, fragmentace, jestli fragment nese identifikátor celé zprávy oddělený od `group_key`, rozsah jedinečnosti `group_key`, opakované doručení, rozsah jedinečnosti identifikátoru zprávy, jestli se `message_ref` opakuje mezi endpointy, transporty, restarty nebo v čase a po jaké době, jestli je vázané na zařízení, spojení nebo boot a jestli je jiné než `group_key`, jestli MQTT a HTTPS sdílejí jeden prostor identifikátorů, přesnost času, autentizace, přímé připojení bez ACRIOS Platform | fáze 11 (PoC). Neblokuje návrh tabulek ani fázi 4. Blokuje fázi 12 pro tento přístroj. Do výsledku se `msg_key`, hash těla, `group_key` ani `message_ref` nepovažují za identitu zprávy |
| Zda další model ACRIOS umí totéž co přístroj z PoC | nesmí se předpokládat. Každý model má vlastní záznam schopností a případně vlastní PoC |
| Zda Platform API vrací stabilní identifikátor koncentrátoru přes výměnu SIM, jaký čas payload nese a zda dekódovaná data obsahují ACC nebo čas měřidla | mapování adaptéru ve fázi 12, ne tvar tabulek |
| UDP/DTLS port a případný DNAT, pokud PoC přímý UDP potvrdí | samostatná změna mimo repozitář, až po PoC. Teď se port nepublikuje |
| Počet měřidel a intervaly vysílání | odhad objemu, fáze 4 |
| Verze software a ověření bodů „k ověření“ | fáze 1–3 |
