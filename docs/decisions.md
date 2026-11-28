# Rozhodnutí

Stav: dokumentace po technické revizi (kolo 3) z 9. 11. 2026, doplněná 10. 11. 2026 o univerzální datovou vrstvu a ACRIOS (rozhodnutí 15–19), druhé kolo kontroly příjmu (20–24), třetí kolo (25–30) a upřesnění formulace 20 a 26 ve čtvrtém kole. Dne 16. 11. 2026 přibylo rozhodnutí R31 o výměnách a metrologické historii. Téhož dne se uzavřely jeho tři otevřené body: metrologické lhůty a upozornění, význam `failed` a shoda `location`. R1–R30 zůstávají schválené a beze změny. Dne 17. 11. 2026 přibylo rozhodnutí R32 o doručení s prokázaným `message_ref` po `timed_out`. R1–R31 se nemění. Dne 20. 11. 2026 přibylo rozhodnutí R33 o PostgreSQL 19 a o zahájení ostrého sběru 1. 1. 2027. Znění rozhodnutí 1–32 a revizí R1–R32 se nemění. Téhož dne přibylo rozhodnutí R34 o dokončení ingest schématu a 26. 11. 2026 R36 o obecné telemetrii a bateriovém monitoringu. Znění R1–R35 se nemění. Dne 28. 11. 2026 přibylo schválené kontraktní rozhodnutí R37 o důkazu identity položky fronty vlastního ESP32 (`esp_queue_v1`). Znění R1–R36 se nemění. Téhož dne bylo schváleno doplnění **R37-O1** (D1, D2, D4, D6, D7) o application ACK, `content_mismatch` a oddělení MQTT PUBACK. Znění R20, R29, R35 a R37 se nemění; O1 je uzavírá v rozsahu ACK/receipt projekce. Téhož dne bylo schváleno doplnění **R37-O4** (varianta B) o trusted ESP MQTT příjem, DB pojistku P4 a SECURITY DEFINER funkce. Znění R20, R29, R35, R37 a R37-O1 se nemění. Schválení R37/O1/O4 neznamená produkční připravenost collectoru, firmwaru, SQL migrací ani evaluatoru. Schválení dokumentace neznamená souhlas s nasazením.

## Potvrzená rozhodnutí

| # | Rozhodnutí | Dopad |
| --- | --- | --- |
| 1 | PostgreSQL 18.x + pgBackRest pro WAL a PITR | Vlastní image `postgres:18.x` + pgBackRest, sestavovaný lokálně |
| 2 | Restic pro šifrované vzdálené zálohy | Snapshoty `daily` (celý repozitář pgBackRest, dumpy, soubory stacku) a `wal` (jen archiv WAL), viz [backup-strategy.md](backup-strategy.md) |
| 3 | Push na append-only `rest-server` přes WireGuard | VPS zálohy zapisuje a čte, ale nemůže je mazat ani přepsat |
| 4 | Další záložní kopie na domácím serveru je mimo rozsah projektu | Infrastructure-sjv ji nespravuje a její mechanismus není součástí projektové dokumentace |
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
| 31 | Výměna je servisní událost mezi původní a novou instalací. Metrologická historie patří fyzickému měřidlu | Stavy a plomby zůstávají v `meter_installations`. Fotografie a protokoly se neukládají. Znění je v R31 |
| 32 | Doručení s prokázaným `message_ref` po `timed_out` se neskládá | Původní sada zůstane. Nové doručení se nepřipojí, nevznikne `isolated` ani nová `collecting` a payload zůstane. Znění je v R32 |

## Retence

| Data | Retence | Mechanismus |
| --- | --- | --- |
| Odečty (`meter_readings`), denní hodnoty (`meter_daily_values`), souhrnná provenience (`reading_provenance`), příjmové zdroje (`ingest_sources`) | trvale | tabulky bez partitioningu. Odečty a provenience nemají cizí klíč na data s retencí |
| Původní obálky (`ingest_payloads`), položky obálky (`ingest_payload_items`) a příjmy (`ingest_receipts`) | 36 měsíců stáří měsíce přijetí | měsíční partitions. Položky se odpojí dřív než jejich payload |
| Kandidáti deduplikace (`ingest_dedup_candidates`), odmítnuté obálky (`ingest_rejections`) a dekódovaná pozorování (`decoded_observations`) | 24 měsíců stáří měsíce přijetí | měsíční partitions. Příjem z prosince se nemaže s telegramem z ledna |
| Normalizovaná telemetrie (`device_telemetry`) | 36 měsíců stáří měsíce `received_at` | měsíční partitions podle UTC `received_at` |
| Surové telegramy (`raw_telegrams`) | 24 měsíců stáří měsíce kotvy | měsíční partitions. Pozdější příjem tuto dobu neprodlužuje a cizím klíčem ji nedrží |
| Fragmentové sady (`ingest_fragment_sets`) a fragmenty (`ingest_fragments`) | 24 měsíců od `first_received_at` a od `received_at` | bez partitioningu. Nejdřív `DELETE` fragmentů, potom sady, na kterou už žádný fragment neukazuje. Pozdní fragment sadu podrží. Každé doručení fragmentu je vlastní řádek |
| Události zařízení (`device_events`) | 12 měsíců stáří měsíce `received_at` | měsíční partitions. `partition_month` je měsíc UTC hodnoty `received_at`. `occurred_at` měsíc neurčuje |
| Audit (`audit_logs`) | dlouhodobě | bez partitioningu, hash řetězec, jen INSERT |
| Výměny (`meter_replacement_events`) a metrologická historie (`meter_verifications`) | trvale | bez partitioningu, řádky se nemažou. Skončená platnost ověření řádek nemaže |
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
| R13 | Obnovovací přístup | Uživatel `sjv-vps` neodpovídal cestě `infrastructure-sjv/` při `--private-repos`. Druhý uživatel ve stejné instanci by k repozitáři neměl přístup | Uživatel VPS se jmenuje `infrastructure-sjv`. Návrh obnovy je vypnutá instance `rest-server-sjv-recovery` bez `--private-repos` s uživatelem `sjv-recovery`. Skripty ji nezakládají |
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

## Doplnění 16. 11. 2026: výměny a metrologická historie

**R31 – Výměny a metrologická historie měřidel**

Výměna měřidla je samostatná servisní událost propojující původní a novou instalaci. Počáteční a konečné stavy a čísla plomb zůstávají v `meter_installations`. Metrologická ověření, kalibrace a kontroly se evidují samostatně u konkrétního fyzického měřidla. Fotografie a protokoly se v systému neukládají; uchovává je předseda SJV. Výměna a změny metrologické historie jsou auditované.

R31 nerozporuje dřívější rozhodnutí a jejich znění nemění:

- R8 dál zakazuje `installation_id` v `meter_readings`. Výměna ho nepřidává.
- R15 a rozhodnutí 7 a 14 dál určují, co člen vidí. Výměna ani metrologická historie viditelnost člena nemění.
- Rozhodnutí 8 nechává role `board` a `technician` nepřiřaditelné. `performed_by` je jméno technika nebo firmy, ne přidělení role.
- Rozhodnutí 13 nechává aplikaci informační. R31 nezavádí rozúčtování, cenu ani automatické určování a hlídání metrologických lhůt.
- R3 a výpočet spotřeby zůstávají. Spotřeba se dál počítá uvnitř jedné instalace a jednoho počítadla.

Podrobnosti, constraint trigger a transakce jsou v [database-design.md](database-design.md). Oprávnění jsou v [security.md](security.md). Zobrazení metrologického záznamu drží výsledek úkonu a časové pokrytí odděleně. Věta R31 se tím nemění.

Uzavření tří otevřených bodů R31, 16. 11. 2026. Věta R31 ani rozhodnutí R1–R30 se nemění.

- Metrologické lhůty sleduje SJV samostatně mimo systém. Systém `valid_until` nepočítá, lhůtu podle druhu ani konstrukce měřidla neodvozuje, upozornění na blížící se ani prošlý termín nevytváří a odpovědnost za sledování těchto termínů nepřebírá. Tabulka `meter_verifications` zůstává. Administrátor může `performed_at`, `valid_from` a `valid_until` zapsat ručně, když údaje zná. Systém uložené údaje zobrazuje a povinnost dalšího úkonu z nich nedělá. Obecné notifikace ostatních provozních událostí zůstávají.
- `result` zůstává provozním označením výsledku konkrétního úkonu: `passed`, `failed`, `not_assessed`. Není to právní klasifikace. Systém z `failed` neoznačí měřidlo jako právně nezpůsobilé, neukončí ani nezruší jiné metrologické záznamy, nezakáže používání měřidla, nepočítá náhradní spotřebu a nevyvozuje sankce ani jiné právní důsledky. Výsledek a časové pokrytí zůstávají oddělené. Platí pro `verification`, `calibration` i `inspection`. O právních a provozních důsledcích rozhoduje SJV podle konkrétního úkonu a jeho podkladů.
- Výměna dál vyžaduje stejný byt, rozdílné fyzické měřidlo, časovou návaznost instalací a vyplněné konečné a počáteční stavy. Shoda `location` se nevyžaduje. Umístění je samostatný údaj každé instalace, při výměně se nekopíruje a jeho změna je přípustná.

## Doplnění 17. 11. 2026: doručení po `timed_out`

**R32 – Doručení s prokázaným `message_ref` po `timed_out`**

Když nové doručení nese prokázaný `message_ref` a odpovídající sada je už `timed_out`, původní sada zůstane beze změny. Doručení se k ní nepřipojí. Nevznikne `isolated`, protože `message_ref` je prokázaný, a nevznikne nová `collecting` se stejným `message_ref`. Payload doručení zůstane. Doručení se neskládá ani nedekóduje a eviduje se jako nepřiřazené, které vyžaduje samostatné vyhodnocení. Platí, dokud samostatný PoC neprokáže bezpečné zacházení s takovým doručením a nebude přijato nové rozhodnutí.

R32 nemění znění R1–R31. Doručení bez prokázaného `message_ref` dál zakládá vlastní `isolated`.

## Doplnění 20. 11. 2026: PostgreSQL 19 a termín ostrého sběru

**R33 – PostgreSQL 19 jako cílová major verze**

Cílová major verze databáze Infrastructure-sjv je PostgreSQL 19. Konkrétní báze lokálního image je `docker.io/library/postgres:19.0` s index digestem `sha256:bb6e70add742cd868fb62cb3b2f67d1dd2bdd2b65a521e778420748753687c60`. Tag `latest` ani pohyblivý tag `19` se nepoužije. pgBackRest je připnutý na 2.60.1 a patří do téhož lokálního image. Restic zůstává 0.19.1. Schválená koncepce zálohování se nemění. Zálohování a obnova na PostgreSQL 19 se ověří dřív, než 1. 1. 2027 začne ostrý příjem a uchovávání skutečných dat z měřidel. Tento termín je zahájení příjmu, ne dokončení informačního systému ani veřejného portálu.

R33 nemění znění rozhodnutí 1–32 ani revizí R1–R32. Rozhodnutí 1 dál zaznamenává dřívější volbu PostgreSQL 18.x. Databáze verze 18 v projektu nevznikla, takže se nemigrují existující data. Schéma se kvůli změně verze nemění: PostgreSQL 19.0 nezavádí globální indexy a odložený constraint trigger zůstává.

pgBackRest 2.60.1 vyšel 16. 11. 2026 a v poznámkách uvádí podporu PostgreSQL 19rc2. Proti zdrojům PostgreSQL 19.0 z 19. 11. 2026 se shoduje `PG_CONTROL_VERSION` 1905, `XLOG_PAGE_MAGIC` 0xD122 a rozložení `ControlFileData`, včetně `slru_pages_per_segment` a `data_checksum_version_init`. Konstanta katalogu vložená do pgBackRest je 202605131, vydání 19.0 má 202610061. Běžící nástroj čte `catalog_version_no` z `pg_control`. Záloha a obnova touto dvojicí se ještě nespustily.

## Doplnění 20. 11. 2026: dokončení ingest schématu

**R34 – Role fragmentu, fronta dekódování, měsíc události a druh údaje koncového bodu**

Čtyři pravidla doplňují migraci `0001_ingest_schema`. Znění R1–R33 se nemění.

1. Trigger `BEFORE INSERT OR UPDATE OF delivery_role` na `ingest_fragments` pustí `repeat` a `conflict` jen tehdy, když je nadřazená sada v tom okamžiku `collecting`. `collecting` už nese neprázdné `message_ref` a vyplněné `deadline_at`. `UPDATE`, který `delivery_role` nemění, trigger znovu nezkoumá. Trigger zákazu přechodu `isolated` zůstává. Unikátní index `message_ref`, skládání a evidence po `timed_out` se nezavádějí.
2. Řádek `decode_queue` vkládá přijímající proces ve stejné transakci jako nový telegram, a jen když vložení do `telegram_dedup_keys` dá výsledek `pending`. `sjv_collector` a `sjv_api` mají na frontu jen `INSERT`. `sjv_worker` řádek nevkládá. Frontu čte, bere ji `FOR UPDATE SKIP LOCKED`, aktualizuje `attempts`, `next_attempt_at`, `locked_by`, `locked_at` a `last_error` a po vyčerpání pokusů ji smaže. Collector dekódování a odečty nedostává.
3. `device_events.partition_month` je první den měsíce UTC hodnoty `received_at`. `received_at` je povinné. `occurred_at` je volitelný čas události a měsíc partition neurčuje. Řádek, jehož měsíc tomuto času neodpovídá, uložit nelze. Retence 12 měsíců se dál počítá od stáří `partition_month`.
4. `endpoint_credentials` drží tuto kombinaci: `bearer` a `basic` mají `storage = hash` a jen `secret_hash`; `client_cert` má `storage = hash` a jen `cert_fingerprint`; `dtls_psk` má `storage = kek_enc` a jen `secret_enc`. Příchozí ověření zůstává hash nebo otisk. Opakovaně použitelný DTLS PSK je šifrovaný AES-256-GCM. Hodnota se neloguje a nekopíruje do konfigurace ani do payloadu. `secret_enc` se rozšifruje jen v paměti procesu, který PSK oprávněně potřebuje. UDP/DTLS listener není přiřazený `sjv_collector`, `sjv_api` ani `sjv_worker`. Migrace proto `SELECT` na `secret_enc` těmto rolím nedává. Obecné `SELECT` role `sjv_readonly` z výchozích oprávnění vlastníka zůstává a není to právo pro použití PSK. Dřívější věta, že odchozí token platformy leží v `secret_enc`, tímto mapováním neplatí. Kam se token platformy uloží, R34 neurčuje a nový sloupec nezakládá.

Schválená oprava oprávnění v téže migraci odebírá `sjv_readonly` tabulkové `SELECT` na `endpoint_credentials` a ponechává čtení `id`, `endpoint_id`, `kind`, `storage`, `created_at` a `revoked_at`. `secret_enc` mezi nimi není. Znění R34 se nemění. Ukládání odchozího tokenu platformy zůstává mimo tuto tabulku a mimo Etapu 1. Přístup budoucího UDP/DTLS listeneru k `secret_enc` zůstává otevřený.

## Doplnění 21. 11. 2026: položky ingestovací obálky

**R35 – Trvalé uložení položek ingestovací obálky**

Systém zavádí samostatnou tabulku `ingest_payload_items`, která uchovává jednotlivé položky původní ingestovací obálky nezávisle na jejich následném vyhodnocení. Znění R1–R34 se nemění.

1. Každá položka náleží právě jednomu záznamu `ingest_payloads`. Vazba používá `payload_id` a `payload_partition_month` a odpovídající složený cizí klíč. Identita položky v rámci doručení je `(payload_id, payload_partition_month, item_index)`.
2. Skutečné položky se číslují od nuly v pořadí, v jakém byly přijaty ve zdrojové obálce. `item_index` je `NOT NULL` a nezáporný. Hodnota `-1` se v `ingest_payload_items` nepoužívá. Hodnota `item_index = -1` zůstává vyhrazena výhradně pro `ingest_receipts` evidující prázdnou obálku bez položek.
3. `ingest_payloads.payload` uchovává původní bajty celé obálky. `ingest_payload_items.original` uchovává původní bajty každé jednotlivé položky. Bajty obálky a bajty položek jsou samostatná data a nesmějí se vzájemně nahrazovat ani slučovat. Neznámý formát nebo druh položky nesmí zabránit uchování jejích původních bajtů. Hash obsahu není identitou zprávy a nesmí sloužit ke slučování doručení.
4. Vložení payloadu a všech jeho položek probíhá v jedné databázové transakci. Transakce se potvrdí pouze tehdy, pokud byly úspěšně uloženy payload i všechny položky. Při chybě kteréhokoli `INSERT` se vrátí celá transakce. Pozdější vyhodnocení položek probíhá v samostatné transakci. Jeho rollback nesmí odstranit již potvrzený payload ani položky.
5. `ingest_payload_items` představuje trvalé uložení vstupních položek, nikoliv jejich výsledek zpracování. `ingest_receipts` nadále eviduje konečný výsledek vyhodnocení jednotlivých položek. Pro neposouzenou položku se nevytváří předčasný receipt ani nový mezistavový status. Prázdná obálka má nula řádků v `ingest_payload_items` a jeden konečný receipt `invalid` s `item_index = -1`.
6. Textový `msg_key` sám o sobě není důkazem identity. Tabulka může uchovávat `msg_key`, `msg_key_namespace` a případnou `proof_basis`. `proof_basis` smí být použita k založení `ingest_message_keys` pouze tehdy, pokud její význam a ověřovací podmínky schválí samostatné rozhodnutí nebo výslovně schválená specifikace. Samotná hodnota boolean `identifier_proven` není dostatečným důkazem. R35 sama neschvaluje žádnou novou důkazní bázi ani obecnou důvěryhodnost transportu.
7. `sjv_collector` má na `ingest_payload_items` oprávnění `SELECT` a `INSERT`. `sjv_collector` nemá `UPDATE` ani `DELETE`. `sjv_api` nedostává oprávnění k této tabulce. `sjv_readonly` má pouze oprávnění potřebná pro čtení. `sjv_maintenance` má pouze oprávnění potřebná pro správu a retenci partition.
8. `ingest_payload_items` je měsíčně partitionovaná podle měsíce příslušného payloadu. Měsíc položky musí odpovídat `payload_partition_month`. Retence položek odpovídá retenci příslušných payloadů. Při odpojování měsíčních partition se nejprve odpojí `ingest_payload_items` a až poté odpovídající partition `ingest_payloads`. Údržba nesmí odstranit payload, dokud na něj existují uchovávané položky.
9. Payload bez konečných příjmů představuje nedokončené vyhodnocení. Po restartu lze vyhodnocení obnovit z původního payloadu a trvale uložených položek. Obnova nesmí používat hash jako identitu ani vytvářet duplicity telegramů či odečtů. Příjem, jehož vyhodnocení již bylo potvrzeno, se nesmí znovu zpracovat jako nový příjem.

R35 neschvaluje nové statusy příjmu, změnu `ingest_message_keys.outcome`, zápis do `meter_readings`, deduplikační algoritmus, pravidla fragmentace ani transportní adaptéry. Tyto oblasti zůstávají předmětem samostatného vyhodnocení a schválení.

## Doplnění 26. 11. 2026: obecná telemetrie a bateriový monitoring

**R36 – Obecná telemetrie zařízení a bateriový monitoring**

Znění R1–R35 se nemění. Jde o dokumentační návrh; schválení R36 samo o sobě neznamená implementaci ani nasazení.

1. Normalizovaná data se ukládají do obecné tabulky `device_telemetry`, nikoli do nové bateriové tabulky. Telemetrie se měří v intervalu 900 sekund a normalizovaná data se navrhují uchovávat 36 měsíců.
2. R36 konkretizuje obecné pravidlo R27 pro nové retenční vrstvy: původní `ingest_payloads`, `ingest_payload_items` a `ingest_receipts` se uchovávají 36 měsíců. `ingest_message_keys` zůstává 60 dní, `raw_telegrams` a `decoded_observations` 24 měsíců a `device_events` 12 měsíců.
3. Doručení používá samostatný MQTT topic `sjv/v1/dev/{device}/telemetry` s QoS 1 a HTTPS `POST /api/v1/ingest/telemetry`. Obě cesty používají stejný interní kontrakt a existující identitu `ingest_message_keys` `(ingest_source_id, msg_key_namespace, msg_key, item_index)`.
   Jeden prvek `samples` je jeden kompletní vzorek, jehož payload může obsahovat více skupin hodnot současně. R36 neschvaluje nový sloupec `kind` ani nový deduplikační mechanismus. Současný návrh `device_telemetry` ale neobsahuje úplnou složenou identitu ani odkaz na `ingest_receipts`; rozhodnutí, zda ukládat složenou vazbu na příjem, zůstává otevřené.
4. Aplikační ACK se publikuje až po databázovém COMMIT. Zařízení odstraní vzorek z lokální fronty až po uložení odpovídajícího výsledku ACK. Heartbeat zůstává samostatný, QoS 0, s intervalem 60 sekund.
5. Alarmy baterie vyhodnocuje centrálně VPS po uložení telemetrie. `device_events` je určen pro významné změny a alarmy (`battery_low`, `battery_critical`, `power_source_changed`, `charging_changed`, `battery_sensor_fault`), nikoli pro každý vzorek. Konkrétní prahy vyžadují rozhodnutí podle chemie a zapojení, včetně hystereze a potlačení opakovaných notifikací.

## Doplnění 28. 11. 2026: důkaz identity položky fronty ESP32

**R37 – Důkaz identity položky fronty vlastního ESP32 (`esp_queue_v1`)**

R37 plní požadavek R35 bodu 6 na samostatné schválení významu `proof_basis` pro vlastní ESP na MQTT. Znění R20, R29 a R35 se nemění. R37 je kontrakt; neimplementuje collector, firmware ani úpravu `evaluate_item`. Schválení R37 neznamená produkční připravenost.

### 1. Identita položky ESP fronty

1. `msg_key` identifikuje jednu položku persistentní fronty ESP, nikoli fyzické měřidlo (`meter_key`).
2. Kanonický formát: `<instance_id>-<boot_counter>-<seq>`, kde `instance_id` je právě 16 znaků `0-9a-f` (lowercase, 64 bitů), `boot_counter` a `seq` jsou desítkové zápisy uint32 bez zbytečných úvodních nul (výjimka: samotné `0`).
3. `instance_id` je náhodná 64bitová hodnota v NVS (nová po erase NVS/flash). `boot_counter` je monotónní uint32 v NVS. `seq` je uint32 v RAM od nuly v každém bootu.
4. Při opakovaném odeslání MUST zůstat stejné `msg_key`, uložené `rx.*` a původní wM-Bus bajty; `tx.*` a `age_ms` se MAY měnit.
5. Ethernet a LTE jsou dvě cesty ke stejnému MQTT; `msg_key_namespace` zůstává `mqtt` (R29). HTTPS není failover a `esp_queue_v1` na něj R37 nepřesouvá.

### 2. R20 a `item_index`

1. Tvar R20 PK `(ingest_source_id, msg_key_namespace, msg_key, item_index)` zůstává (rozhodnutí 20).
2. Pro `proof_basis = esp_queue_v1` MUST být složka R20 `item_index` vždy **0**. Unikátnost položky fronty nese `msg_key`.
3. TX1 `ingest_payload_items.item_index` zůstává pořadím položek v přijaté obálce (0…n−1) dle R35.
4. Změna pořadí položek při retry MUST NOT měnit R20 identitu `esp_queue_v1`.
5. Opakovaný stejný `msg_key` v jedné obálce: TX1 se MUST uložit; collector MUST nastavit `proof_basis = NULL` u **všech** položek této obálky (žádné částečné `esp_queue_v1`).

### 3. `proof_basis` a podmínky P1–P7

1. `proof_basis` NIKDY není autoritativní hodnota z těla zprávy ESP. Nastavuje ji pouze důvěryhodný collector (nebo ekvivalentní důvěryhodná serverová cesta) po ověření.
2. Schválená hodnota báze pro toto rozhodnutí: `esp_queue_v1`.
3. `identifier_proven` samo o sobě NENÍ důkaz a MUST NOT otevírat vznik `ingest_message_keys`.
4. Neznámé fyzické měřidlo MUST NOT bránit uznání `esp_queue_v1` ani R20 deduplikaci položky fronty. `unknown_meter` zůstává pozdější telegramovou větví.
5. Collector smí nastavit `esp_queue_v1` jen když současně platí:
   - **P1** transport `mqtt` a `device_id` / `ingest_source_id` z autentizace;
   - **P2** topic ACL shodný s autentizovaným zařízením;
   - **P3** kanonický `msg_key` (§1);
   - **P4** uplinková kanonická `instance_id = V` je vázána na autentizované `devices.id = D` přes aktivní `device_external_ids(kind = esp_instance, value = V)` patřící právě `D`, nebo právě úspěšnou první registraci volné `V` u `D` bez dosavadní aktivní instance (viz §6). Existence jiné aktivní instance `A ≠ V` u `D` P4 nesplní. Konflikt s cizí aktivní hodnotou ⇒ bez báze;
   - **P5** `msg_key_namespace = mqtt`;
   - **P6** `rx.instance` a `rx.boot` přítomné a shodné s `instance_id` / `boot_counter` v `msg_key`;
   - **P7** každá položka má vlastní `msg_key`; duplicita v dávce ⇒ §2 bod 5.
6. Budoucí `evaluate_item` MUST zakládat / upsertovat `ingest_message_keys` pro ESP MQTT jen při uložené `proof_basis = esp_queue_v1` (a platných klíčových polích), nikoli z pouhého neprázdného textu `msg_key`. Současný kód tuto bránu ještě nemá; R37 ji předepisuje jako kontrakt implementace.

### 4. Immutable hash `esp_queue_immutable_v1`

1. Pro porovnání retry při existujícím R20 klíči se spočte SHA-256 nad pevnou posloupností length-prefixed chunků (`u32be(len) || bytes`), prefix ASCII `esp_queue_immutable_v1`.
2. Pořadí a typy chunků: `msg_key` (UTF-8); `msg_key_namespace` (UTF-8 `mqtt`); `original` (raw); `frame_original` (raw nebo prázdný chunk při NULL); `frame_format` (UTF-8 nebo prázdný); `crc_included` (NULL → prázdný chunk; false → `0x00`; true → `0x01`); `rssi` (NULL → prázdný; jinak int32be); `rx_instance_id` (NULL → prázdný; jinak UTF-8 16 lowercase hex); `rx_boot` (NULL → prázdný; jinak **u32be**); `rx_uptime_ms` (NULL → prázdný; jinak **u64be**, záporné nepřípustné pro bázi); `device_rx_unix_ms` (NULL → prázdný; přítomná nula → **u64be(0)**).
3. MUST NOT zahrnout `tx_*`, `age_ms`, `proof_basis`, `identifier_proven`, `server_received_at` ani TX1 `item_index`.
4. Otisk se MUST přepočítat z první uložené položky odkazované prvním receiptem (`ingest_message_keys.receipt_*` → `ingest_receipts` → `ingest_payload_items`) a z aktuální položky. Nový DB sloupec není nutný.
5. Shodný hash ⇒ MAY `duplicate_delivery` (jen `ingest_receipts.status`). Rozdílný hash při stejném R20 klíči ⇒ MUST NOT `duplicate_delivery`; mapování na receipt a application ACK je v **R37-O1** (`content_mismatch`).
6. Obecný význam `ingest_receipts.content_hash` se nemění.

### 5. Boot counter, NVS a fronta

1. Firmware MUST používat obnovitelný stav NVS: `boot_phase` ∈ {`idle`, `prepared`, `committed`}, `boot_counter`, `boot_next`.
2. Start: rezervovat `boot_next`, zapsat `prepared`, read-back; teprve pak commitnout `boot_counter` a vrátit `idle`. Výpadek v `prepared` MUST NOT způsobit dvojí inkrementaci.
3. Přetečení `boot_counter` nebo neopravitelné poškození identity ⇒ nový `instance_id` (ne wrap na 0 ve stejné instance) nebo stav identity unsafe.
4. Identity unsafe: MUST NOT vytvářet nové položky fronty s novými `msg_key`, dokud není bezpečný commit boot / nová instance.
5. Staré záznamy LittleFS MUST zachovat původní `msg_key` i po nové `instance_id`. Nová instance se vztahuje jen na nové záchyty.
6. Pořadí inkrementace `seq` vůči commit záznamu LittleFS (před/po) zůstává implementační volbou firmwaru — O2. Brown-out záruky konkrétního ESP32-S3 NVS — O3.

### 6. Registrace `esp_instance`

1. Vazba je v `device_external_ids` (`kind = esp_instance`), omezení `uq_device_external_ids_active_value` (UNIQUE aktivní `kind+value` → SQLSTATE **23505**) a `ex_device_external_ids_active_kind` (exclusion jedné aktivní `esp_instance` na `device_id` → SQLSTATE **23P01`).
2. Jednotné pořadí zámků: (1) `SELECT … FROM devices WHERE id = $D FOR UPDATE`; (2) aktivní `esp_instance` řádky tohoto `$D` FOR UPDATE; (3) aktivní řádek s `value = $V` FOR UPDATE; (4) zápis / audit.
3. `$V` aktivní u cizího device ⇒ MUST NOT měnit cizí `valid_to` ani převzít hodnotu; audit `external_id_conflict` v úspěšné TX; bez `esp_queue_v1`.
4. Při 23505 / 23P01: bezpečný rollback, opakované načtení od zámku `devices`, nové vyhodnocení stavu.
5. Collector smí přidělit `proof_basis = esp_queue_v1` pouze tehdy, když současně platí:
   1. MQTT autentizace určila konkrétní `devices.id = D`;
   2. uplink obsahuje kanonickou `instance_id = V`;
   3. existuje aktivní vazba `device_external_ids(kind = 'esp_instance', value = V)` patřící právě zařízení `D`; **nebo** jde o první registraci volné hodnoty `V` u zařízení `D` bez dosavadní aktivní instance a tato registrace byla úspěšně provedena podle tohoto §6 (body 1–4). První registrace není rotace;
   4. všechny ostatní podmínky P1–P7 (§3) jsou splněny.
6. **Neshoda A ≠ B:** Pokud zařízení `D` již má aktivní instanci `A` a aktuální uplink obsahuje jinou instanci `B`, pak samotná autentizace zařízení `D` ani existence aktivní vazby `A` neopravňuje collector k přidělení `esp_queue_v1` pro `B`. V takovém případě MUST `proof_basis` zůstat NULL; collector MUST NOT automaticky uzavřít vazbu `A`; MUST NOT automaticky zaregistrovat `B` jako náhradu `A`; změnu instance MUST odmítnout jako prokázanou identitu fronty. Rotace `A` → `B` MAY proběhnout pouze po samostatně definované a ověřené autorizaci. **Automatická rotace** pouze proto, že uplink poslal jinou `instance_id`, **není tímto rozhodnutím schválena.** Pravidla autorizace rotace (automaticky vs admin) zůstávají **otevřená implementační podmínka**; dokud nejsou schválena a implementována, nesmějí se prezentovat jako hotová.

### 7. Mimo rozsah R37

R37 neschvaluje: ACRIOS důkazní bázi, HTTPS `esp_queue_v1`, zápis `raw_telegrams` / odečtů, změnu wire JSON ESP, ani tvrzení, že collector/`evaluate_item` už R37 provádějí. Mapování receipt/ACK při content-mismatch a duplicitním `msg_key` v dávce schvaluje samostatné doplnění **R37-O1** níže (včetně literálu `content_mismatch`). Migrace CHECK a implementace zůstávají až po O1 jako implementační krok; O1 samotné schema nemění.

## Doplnění 28. 11. 2026: R37-O1 – application ACK a kolize `msg_key`

**R37-O1 – Application ACK, `content_mismatch` a oddělení MQTT PUBACK (D1, D2, D4, D6, D7)**

Uzavírá otevřený bod O1 u R37. Znění R20, R29, R35 a R37 (mimo nahrazení odkazu „O1 otevřené“ v §4 bodu 5) se nemění. R37-O1 je kontrakt; neimplementuje collector, migraci CHECK ani úpravu `evaluate_item`.

Schválená rozhodnutí:

| ID | Pravidlo |
| --- | --- |
| **D1** | Literál `content_mismatch` je povolený `ingest_receipts.status` a literál application ACK. Při něm se `ingest_message_keys` **nemění**. ACK.`status` = `content_mismatch` má **přednost** před `keys.outcome`. |
| **D2** | Při shodném `esp_queue_immutable_v1` (S1) je ACK.`status` = `ingest_message_keys.outcome`. `duplicate_delivery` je **pouze** receipt status nového doručení, nikoli náhrada původního výsledku v ACK. |
| **D4** | Duplicitní `msg_key` v jednom envelope (S3): `proof_basis = NULL` u všech položek (R37). Application ACK má **jeden** výsledek na unikátní `msg_key` se `status = invalid`. Všechny TX1 výskyty zůstávají dohledatelné v DB. |
| **D6** | Při `proof_basis = esp_queue_v1` a commitnutém terminálním výsledku včetně `invalid` MUST vzniknout / zůstat R20 klíč s `outcome` = první terminální výsledek (idempotentní ACK při retry). |
| **D7** | MQTT PUBACK ≠ application ACK. Application ACK se odesílá až po terminálním COMMIT **všech** TX2 položek daného doručení. PUBACK nejdřív po COMMIT TX1; smí být odložen až po TX2. PUBACK nevyjadřuje úspěch položky fronty. |

### Pořadí sestavení application ACK (unikátní `msg_key`)

Až když jsou všechny položky doručení terminálně vyhodnocené a jejich TX2 změny commitnuté, pro každý unikátní `msg_key`:

1. Toto doručení má receipt `content_mismatch` → ACK.`status` = `content_mismatch` (D1). Konec.
2. Envelope obsahuje jakýkoli duplicitní `msg_key` → ACK.`status` = `invalid` pro každý unikátní `msg_key` dávky (D4). Konec.
3. Existuje R20 a `esp_queue_immutable_v1` sedí → ACK.`status` = `keys.outcome` (D2); receipt smí být `duplicate_delivery`. Konec.
4. Terminální receipt bez R20 → ACK.`status` = `receipt.status`. Konec.
5. Jakákoli položka doručení bez terminálního COMMIT (včetně dočasné chyby bez COMMIT) → **neodesílat** application ACK.

Dočasná chyba bez COMMIT nezakládá terminální R20 výsledek ani application ACK; umožňuje recovery stejné TX1 trojice nebo nové doručení.

Wire tvar ACK zůstává položkový:

```json
{ "v": 1, "results": [ { "msg_key": "<instance>-<boot>-<seq>", "status": "<ack-status>" } ] }
```

`status` je aplikační výsledek dle pořadí výše. Firmware maže položku fronty podle `msg_key` po uložení terminálního ACK (stávající pravidlo ve firmware-design).

### Kontrakt vs implementace

Současný `evaluate_item` otevírá R20 z neprázdného `msg_key` bez `proof_basis`, neporovnává `esp_queue_immutable_v1` a při konfliktu vždy nastaví `duplicate_delivery`. Collector a MQTT ACK v repozitáři nejsou. R37-O1 předepisuje cílové chování; CHECK enum pro `content_mismatch` a úprava evaluatoru jsou budoucí implementace.

## Doplnění 28. 11. 2026: R37-O4 – trusted ESP MQTT příjem a DB pojistka P4

**R37-O4 (varianta B) – Trusted-only nastavení `esp_queue_v1`, první registrace a BEFORE INSERT pojistka P4**

Uzavírá otevřený bod O4 u R37. Znění R20, R29, R35, R37 a R37-O1 se nemění. R37-O4 je architektonický kontrakt; neimplementuje Python collectoru, SQL migraci, triggery ani DEFINER funkce v repozitáři. Schválení O4 neznamená produkční připravenost.

### Schválená architektura

1. Produkční ESP MQTT příjem MUST používat samostatnou cestu `trusted_esp_accept(authenticated_device_id, envelope)`. Obecná knihovní `accept()` MUST vždy ukládat `proof_basis = NULL` (vhodné pro non-ESP a testy; ESP MQTT s bází MUST jít trusted cestou).
2. Trusted cesta v **jedné TX1** ověří P1–P7 včetně P4 a uloží položky s **konečným** `proof_basis ∈ {esp_queue_v1, NULL}`. Durable pending stav mezi TX1 a pozdějším nastavením báze se **nezavádí**.
3. První registrace volné `esp_instance` hodnoty `V` u zařízení `D` bez dosavadní aktivní instance MUST probíhat výhradně přes `sjv_esp_instance_register_free(device_id, value)` (`SECURITY DEFINER`, OWNER `sjv_owner`, pevný `search_path`, plně kvalifikované názvy, `REVOKE ALL … FROM PUBLIC`, `EXECUTE` jen `sjv_collector`). Parametry jsou pouze `device_id` a `value`; volající MUST NOT předávat `kind`, `origin` ani `valid_to`. Funkce hardcoduje `kind = 'esp_instance'`, drží zámky R37 §6 a při 23505 / 23P01 MUST NOT uzavírat cizí ani stávající vazbu. Automatická rotace A→B zůstává zakázaná (R37 §6 bod 6).
4. `BEFORE INSERT` trigger na `ingest_payload_items` zůstává **`SECURITY INVOKER`**. Při `NEW.proof_basis = 'esp_queue_v1'` MUST ověřit existenci payloadu, `transport = 'mqtt'`, `msg_key_namespace = 'mqtt'`, kanonický `msg_key`, shodu `payload.device_id` s autentizovaným zařízením položky a extrahovanou `instance_id = V`, a povinně zavolat `sjv_esp_p4_assert(device_id, instance_id)`.
5. `sjv_esp_p4_assert(device_id, instance_id)` je úzká `SECURITY DEFINER` funkce: OWNER `sjv_owner`; pevný `search_path`; plně kvalifikované názvy; `REVOKE ALL … FROM PUBLIC`; `EXECUTE` pouze `sjv_collector`; žádné parametry `kind` / `origin` / `valid_to`; **žádný zápis** do tabulek. Uvnitř: row-locky v pořadí R37 §6 prefixu — (1) `public.devices` řádek `D` `FOR UPDATE`; (2) aktivní `public.device_external_ids` řádky `kind = 'esp_instance'` zařízení `D` `FOR UPDATE` — a ověření, že aktivní instance má přesně hodnotu `V`. Jinak RAISE a INSERT neprojde.
6. PostgreSQL vyžaduje pro `SELECT … FOR UPDATE` také oprávnění `UPDATE` (alespoň na jednom sloupci zamčené tabulky). `sjv_collector` má na `device_external_ids` jen `SELECT` a **MUST NOT** dostat široké ani sloupcové `UPDATE` na tuto tabulku kvůli zamykání. Zámky P4 proto zajišťuje DEFINER assert (a registrace DEFINER funkce), nikoli INVOKER `FOR UPDATE` collectoru.
7. Trusted cesta i přímý `INSERT` s `esp_queue_v1` MUST používat stejný prefix pořadí zámků. Přímý INSERT bez platné aktivní vazby D↔V MUST selhat na triggeru / assertu. Holý `SELECT` bez row-locků nestačí proti souběžné změně vazby mezi kontrolou a COMMIT.
8. Trigger ani databáze samy **neprokazují** MQTT autentizaci identity `D` ani **P2** topic ACL. Tyto kontroly MUST zajistit collector před nastavením `esp_queue_v1`. DB pojistka kryje P4 (a kanonické MQTT/msg_key podmínky triggeru), nikoli P2.
9. Budoucí `evaluate_item` MUST zakládat R20 pro ESP MQTT jen při uložené `proof_basis = esp_queue_v1` (R37 §3 bod 6; R37-O1 D6). Položka s `proof_basis` NULL MUST NOT otevřít R20 jen z textu `msg_key`.

### Kontrakt vs implementace

Současný `sjv_ingest.accept` ukládá `proof_basis` prázdnou; `trusted_esp_accept`, `sjv_esp_instance_register_free`, `sjv_esp_p4_assert` a BEFORE INSERT trigger v repozitáři **nejsou**. O4 předepisuje cíl; SQL migrace a úprava collectoru / evaluatoru jsou budoucí implementace.

### Otevřené pod O4

- **U3** — hodnota `origin` při první registraci `esp_instance`; enum `device_external_ids.origin` se tímto rozhodnutím **nemění**.
- R37-O2, R37-O3 a autorizace rotace A→B zůstávají otevřené (viz tabulka níže).

## Otevřené body

Hodnoty, které nejsou známé, se nedoplňují odhadem.

| Bod | Blokuje |
| --- | --- |
| **R37-O2** Pořadí inkrementace `seq` vůči LittleFS commit | firmware spec a testy reuse `seq` |
| **R37-O3** Brown-out ověření NVS na skutečném ESP32-S3 | důvěra v §5 R37 na HW |
| **R37-O4 U3** Hodnota `origin` při `sjv_esp_instance_register_free` (enum beze změny) | dokončení SQL textu registrace |
| Autorizace rotace `esp_instance` (automat vs admin) po změně `instance_id` | R37 §6 bod 6; produkční collector |
| Kapacita VPS (`<CPU>`, `<RAM>`, disk). Kontejner `sjv-monitoring` má adresu `10.10.10.20` | E1, měření zátěže |
| Zda DNS účet dovolí druhé veřejné jméno (`MQTT_HOSTNAME` jiné než `SJV_DOMAIN`) a jak se to jméno udržuje | E2, MQTT hostname |
| Upload domácí linky | odhad RTO před DR testem ve fázi 13 |
| WireGuard rozhraní MikroTiku, LAN IP `domaPcServer`, porty `<P>` a `<P2>` | E5 |
| SMTP účet | E7, notifikace |
| Retence pokusů o přihlášení a notifikací | fáze 4 |
| Maximální stáří zprávy (návrh 30 dní) | fáze 5 |
| Hardware ESP (čip, rádio, flash, konektivita, napájení) | firmware |
| Vzorky telegramů, typy měřidel tepla, AES klíče | fáze 6 |
| Dokumentace a vzorky konkrétního ACRIOS: model, revize hardwaru, firmware, skutečně dostupné transporty, topics nebo API, surové i dekódované payloady, fragmentace, jestli fragment nese identifikátor celé zprávy oddělený od `group_key`, rozsah jedinečnosti `group_key`, opakované doručení, rozsah jedinečnosti identifikátoru zprávy, jestli se `message_ref` opakuje mezi endpointy, transporty, restarty nebo v čase a po jaké době, jestli je vázané na zařízení, spojení nebo boot a jestli je jiné než `group_key`, jestli MQTT a HTTPS sdílejí jeden prostor identifikátorů, přesnost času, autentizace, přímé připojení bez ACRIOS Platform | fáze 11 (PoC). Neblokuje návrh tabulek ani fázi 4. Blokuje fázi 12 pro tento přístroj. Do výsledku se `msg_key`, hash těla, `group_key` ani `message_ref` nepovažují za identitu zprávy |
| Zda další model ACRIOS umí totéž co přístroj z PoC | nesmí se předpokládat. Každý model má vlastní záznam schopností a případně vlastní PoC |
| Zda Platform API vrací stabilní identifikátor koncentrátoru přes výměnu SIM, jaký čas payload nese a zda dekódovaná data obsahují ACC nebo čas měřidla | mapování adaptéru ve fázi 12, ne tvar tabulek |
| UDP/DTLS port a případný DNAT, pokud PoC přímý UDP potvrdí | samostatná změna mimo repozitář, až po PoC. Teď se port nepublikuje |
| Která role smí číst `endpoint_credentials.secret_enc` kvůli DTLS PSK | UDP/DTLS listener není přiřazený. `sjv_collector`, `sjv_api`, `sjv_worker` ani `sjv_readonly` `secret_enc` nečtou. Přístup listeneru zůstává otevřený |
| Kam se uloží odchozí token platformy | R34 přiřazuje `secret_enc` jen `dtls_psk`. Nový sloupec pro token platformy se nezakládá |
| Přesná relační vazba `device_telemetry` na `ingest_receipts` | R36 určuje pořadí společného ingestu a používá existující `ingest_message_keys`, ale neschvaluje nový složený cizí klíč ani kopii celé ingest identity v telemetrii. Je třeba rozhodnout mezi dohledatelnou vazbou na `(receipt_id, receipt_partition_month)` a uložením celé identity `(ingest_source_id, msg_key_namespace, msg_key, item_index)` |
| Závazné hodnoty případného klasifikačního pole telemetrie | JSON R36 žádné pole `kind` nemá a jeden řádek obsahuje celý vzorek; další klasifikace skupin v `payload` vyžaduje samostatný kontrakt |
| Počet měřidel a intervaly vysílání | odhad objemu, fáze 4 |
| Další doručení s prokázaným `message_ref`, když odpovídající sada je `complete` nebo `conflict` | Samostatné rozhodnutí. R32 se na tyto stavy nevztahuje. Fragment se k sadě nepřipojí. Jak se doručení dál eviduje, schválená pravidla neurčují |
| Verze software a ověření bodů „k ověření“ | fáze 1–3 |
