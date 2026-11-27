# Příjem dat

PostgreSQL je jediný dlouhodobý zdroj pravdy pro data SJV (rozhodnutí 15–30 a R31 v [decisions.md](decisions.md)). Každý vstup skončí v modelu z [database-design.md](database-design.md). Adaptér výrobce data jen převede na interní kontrakt. Tabulka odečtů pro ACRIOS ani pro jiný transport nevzniká.

ACRIOS je podporovaný integrační partner. Konkrétní model, revize hardwaru a transport nejsou vybrané. Návrh nepředpokládá, že všechny modely ACRIOS umí stejné formáty nebo protokoly. Dokud to neověří PoC ([implementation-plan.md](implementation-plan.md)), platí pro ACRIOS jen pravidla společná všem zdrojům.

Sběrná zařízení navazují spojení směrem k VPS. Výjimka je dotaz na cizí API, který navazuje server. Návrh počítá s mobilním CGNAT a nepředpokládá veřejnou IP zařízení. WireGuard pro příjem odečtů potřeba není.

Tabulky jsou v [database-design.md](database-design.md), firmware vlastního ESP v [firmware-design.md](firmware-design.md), bezpečnost příjmu v [security.md](security.md).

K 20. 11. 2026 je v PostgreSQL jen schéma migrace `0001_ingest_schema`. MQTT klient, HTTPS API, worker a dekodér nejsou. Fragment bez prokázaného `message_ref` umí databáze uložit jako novou sadu `isolated` a trigger odmítne změnu jejího stavu. `repeat` a `conflict` pustí jen sada, která je v tom okamžiku `collecting`. Skládání, spojení podle `group_key` a záznam doručení po `timed_out` tato etapa nezavádí. Schéma pro ten záznam dál není určené. `device_events.partition_month` je měsíc `received_at` v UTC.

## Vstupní zdroje

| Zdroj | Transport | Co je známé | Kam patří odečet |
| --- | --- | --- | --- |
| ACRIOS MQTT | MQTT/TLS | model a topics až po PoC | `radio`, pokud payload obsahuje rámec; jinak `vendor:acrios` |
| ACRIOS UDP/DTLS | UDP | až PoC, včetně toho, jestli daný model DTLS má | podle skutečného payloadu, stejně jako u MQTT |
| ACRIOS HTTPS | HTTPS | až PoC | podle skutečného payloadu |
| ACRIOS Platform API | odchozí HTTPS serveru | až PoC. Přímé připojení bez platformy je samostatná otázka PoC | podle toho, co API vrací |
| vlastní ESP32/LILYGO | MQTT/TLS; HTTPS jen jako samostatná varianta | tento dokument | `radio` |
| jiný budoucí koncentrátor | podle svého adaptéru | stejná pravidla, vlastní kód `vendor:<kód>` jen pro data bez rámce | `radio` nebo `vendor:<kód>` |
| ruční import CSV nebo jiného podporovaného souboru | `file_import` | konkrétní rozložení souboru až s adaptérem | stream `import` |

Jeden kus hardwaru může mít víc transportů. Schopnosti se zapisují do `device_capabilities` podle zjištění. Z názvu výrobce se neodvozují.

Aktuální ESP32 receiver používá MQTT/TLS. Ethernet a LTE jsou dvě přístupové cesty ke stejnému MQTT ingest rozhraní a nemění `msg_key_namespace`. HTTPS není transparentní záložní transport při výpadku MQTT. Případný HTTPS ingest je samostatná transportní varianta s vlastním namespace a identitou zpráv podle pravidel výše a rozhodnutí R29.

## Čtyři vrstvy

### A. Původní přijatá data

`ingest_payloads` ukládá obálku v bajtech, ve kterých přišla: dávku MQTT včetně topicu, UDP datagram, tělo HTTPS, soubor CSV, tělo odpovědi API, jeden fragment. U každého záznamu je koncový bod, transport, čas příjmu, hash, velikost a `device_id`, pokud už je z autentizace známé. Metadata vedle bajtů jsou jen netajné údaje (topic, jméno souboru, identifikátor stránky API).

Obsah se nepřekóduje a neořezává. Kanonický rámec a dekódované hodnoty jsou další vrstva a obálku nenahrazují.

Když zdroj pošle jen dekódovanou hodnotu, uloží se její JSON, CSV nebo jiný skutečný payload. Řádek v `raw_telegrams` nevznikne.

Tělo nad `max_payload_bytes` se celé neukládá. V `ingest_rejections` zůstane důvod, transport, velikost a identifikátor volajícího. Do zpracování zpráva nevstoupí. Jinak by šlo zaplnit disk samotnými odmítnutími.

### B. Evidence příjmu

Každý přijatý vstup má dohledatelný záznam.

- Položka, kterou adaptér oddělil (telegram, dekódovaná hodnota, řádek importu, heartbeat, událost), má řádek v `ingest_receipts`.
- Obálka, ze které položka nevznikla (autentizace, velikost, nečitelný formát, neúplné fragmenty), má řádek v `ingest_rejections`.
- Opakované doručení prokázané položky `(ingest_source_id, msg_key_namespace, msg_key, item_index)` má další příjem `duplicate_delivery`. Nový odečet nevznikne. Ostatní položky téže zprávy se tím nepřeskakují. Stejný hash těla bez prokázaného identifikátoru tento stav není.

Příjem nese autentizované `device_id`, transport, `msg_key`, identifikátor zprávy zdroje, pokud ho poslal, `server_received_at`, odhad času zachycení a jeho nejistotu, stav a vazbu na payload. U rámce i vazbu na `raw_telegrams`. Pořadí fragmentů je na `ingest_fragments`, ne na odečtu.

`device_id` se z těla zprávy nebere. Tělo může nést externí identifikátor, který se mapuje přes `device_external_ids` jen když už k zařízení patří. Neznámý identifikátor zařízení nezaloží.

### C. Normalizovaná data

Dekódovaný odečet je řádek `meter_readings`. Nese měřidlo, veličinu, hodnotu, jednotku, čas měření, stream, způsob získání (`source_kind`, adaptér a jeho verze, u rádia i dekodér a normalizátor), kvalitu a vazbu na telegram nebo pozorování.

`reading_kind` je `cumulative`, `interval` nebo `event`. Do spotřeby a do aktuálního stavu podle R15 vstupuje jen kumulativní primární hodnota. Interval a událost se jako další stav téhož počítadla nepočítají.

### D. Historie a provozní evidence

Historie přežije výměnu SIM, firmware i koncentrátoru, protože visí na neměnném `devices.id` a na měřidle:

- externí identifikátory a firmware (`device_external_ids`, `device_firmware_history`),
- umístění zařízení (`device_placements`),
- instalace měřidla (`meter_installations`) a servisní výměna, která dvě instalace spojí (`meter_replacement_events`),
- ověření, kalibrace a kontroly fyzického měřidla (`meter_verifications`). Na nové měřidlo se při výměně nekopírují,
- přiřazení streamu k měřidlu (`meter_source_assignments`),
- opravy odečtů (nový řádek a `audit_logs`),
- zpracování a odmítnutí po dobu retence (`ingest_receipts`, `ingest_rejections`).

Měřidlo nemá cizí klíč na koncentrátor. Kdo telegram zachytil, je na příjmech a v `capture_device_ids`.

## Interní kontrakt

Adaptér smí předat dál jen tuto položku. Zápis do `meter_readings`, `raw_telegrams` a deduplikačních klíčů dělá společný postup, stejný pro všechny zdroje.

| Pole | Pravidlo |
| --- | --- |
| endpoint | koncový bod, který data přijal |
| device_id | z autentizace, nebo z už uloženého externího identifikátoru u záznamu z platformy |
| message_kind | `raw_wmbus`, `decoded`, `telemetry`, `event`, `heartbeat`, `import_row` |
| msg_key | idempotence doručení, viz [Identita zprávy](#identita-zprávy) |
| external_message_id | identifikátor výrobce, jen když v datech je |
| capture | jen časové údaje, které zdroj skutečně poslal |
| frame | jen skutečný wM-Bus rámec |
| decoded | hodnoty včetně veličiny, jednotky a druhu `cumulative`, `interval` nebo `event` |
| fragment | identifikace celé zprávy, pořadí a počet nebo příznak konce, jen když to zdroj označil. Text identifikátoru sám sadu nespojí |
| payload_id | nezměněná obálka |
| adapter, adapter_version | verze, která položku oddělila |

Heartbeat, událost a telemetrie nevytvářejí odečet. Telemetrie končí v `device_telemetry`, ne v `meter_readings`. `import_row` vytvoří odečet se `source_kind = import` až po validaci řádku. Neplatný řádek je příjem `invalid` a původní text řádku zůstane v payloadu.

## Dva druhy dat

| Druh | Obsah | Typický zdroj | Stream | Cesta v systému |
| --- | --- | --- | --- | --- |
| `raw` | skutečný wM-Bus rámec | vlastní ESP, kterýkoli koncentrátor, který rámec předá | `radio` | `ingest_payloads` → `ingest_receipts` → `raw_telegrams` → dekódování → `meter_readings` |
| `decoded` | hodnoty, které už dekódoval zdroj | koncentrátor nebo API bez rámce, import souboru | `vendor:<kód>` nebo `import` | `ingest_payloads` → `decoded_observations` → `meter_readings` |
| `telemetry` | normalizované provozní hodnoty zařízení | vlastní zařízení | `device` | `ingest_payloads` → `ingest_payload_items` → `ingest_receipts` → `device_telemetry` |

Podpora koncentrátorů, které posílají jen dekódované hodnoty:

- druh zprávy `decoded` v transportech, které ho nesou (u vlastního ESP topic `readings` a `POST /api/v1/ingest/readings`; u ACRIOS až cesta, kterou ukáže PoC),
- tabulka `decoded_observations` a mapování identifikátorů (`meter_external_ids`),
- stejná idempotence doručení jako u rámců a korelace popsaná níže,
- adaptér pro každého partnera. Adaptér ACRIOS vznikne až po PoC. Jiný výrobce dostane vlastní adaptér a stejné tabulky.

Co z dekódovaných dat zjistit nejde, popisuje část [Omezení dekódovaných dat](#omezení-dekódovaných-dat).

## Identita zprávy

Čtyři věci se nesmí používat jedna místo druhé:

| Věc | Čím se pozná | Co z ní neplyne |
| --- | --- | --- |
| identifikátor zprávy | `msg_key`, jen když je prokázaný | hash těla identifikátor není |
| hash obsahu | `content_hash` = `sha256` kanonického těla | stejný hash není stejná zpráva ani důvod ke sloučení |
| identita položky | prokázaná zpráva plus `item_index`. Bez ní je to `id` pozorování nebo příjmu | čas ani hodnota |
| identita doručení | `ingest_receipts.id` v měsíci `server_received_at` | každé přijetí je nové doručení, i když je obsah stejný |

- `device_id` se vždy bere z autentizace (MQTT účet, API token, klientský certifikát nebo PSK), nikdy z těla zprávy. U Platform API je autentizovaný koncový bod a koncentrátor uvnitř odpovědi se přiřadí jen přes už uložené `device_external_ids`.
- Prokázaný `msg_key` se ukládá po položkách do `ingest_message_keys` s `PRIMARY KEY (ingest_source_id, msg_key_namespace, msg_key, item_index)`:
  - **vlastní ESP:** `<instance_id>-<boot_counter>-<seq>` pro opakované odeslání téhož záznamu fronty.
    - `instance_id` je náhodné 64bitové číslo v hex. Vygeneruje se při prvním startu a znovu po každém vymazání flash, takže reset `boot_counter` nikdy nevytvoří klíč, který server už zná.
    - `boot_counter` je v NVS a roste při každém startu.
    - `seq` je čítač v RAM od nuly v každém bootu.
  - **koncentrátor včetně ACRIOS:** jen identifikátor, u kterého PoC prokáže, že se během 60 dní neopakuje. Formát se dopředu nepředepisuje. Když ho data nemají, `msg_key` zůstane NULL a klíč se nevloží.
- `sha256` kanonického těla se do `msg_key` neukládá. Stejný obsah může patřit dvěma zprávám a jeden payload může přijít znovu. Bez prokázaného identifikátoru se uloží obě doručení, obě pozorování a stav `uncertain`. Odečet z druhého automaticky nevznikne.
- **MQTT a HTTPS.** `msg_key_scope` je výchozí `transport`, takže `msg_key_namespace` je `mqtt` nebo `https`. Stejný text `msg_key` na obou transportech jsou dvě doručení. Když je navíc stejný `content_hash`, pozdější příjem dostane `id_collision`. Pozorování se nesmaže, `delivery_count` se mezi transporty nesčítá a stav se nehlásí jako `duplicate`. Rádiový rámec s důvěryhodnou kotvou dál smí projít oknem `telegram_dedup_keys`. To je shoda rámce, ne shoda textu `msg_key`.
- `msg_key_scope = device` se nastaví jen tehdy, když kontrakt zdroje jeden prostor napříč transporty prokáže. Firmware ESP to pro MQTT a HTTPS neprokazuje. Popisuje stejný `msg_key` při opakovaném odeslání záznamu fronty, ne společný prostor dvou transportů.
- **Složená zpráva z fragmentů** dostane `msg_key` až ze prokázaného `message_ref`. Hash složeného těla identifikátor není.

## Časový model

### Pole zprávy z ESP

Údaje o zachycení se uloží do fronty při příjmu z rádia a **při opakovaném odeslání se nemění**:

| Pole | Kde | Význam |
| --- | --- | --- |
| `rx.instance` | položka | `instance_id` v okamžiku zachycení |
| `rx.boot` | položka | `boot_counter` v okamžiku zachycení |
| `rx.uptime_ms` | položka | monotónní čas od startu v okamžiku zachycení |
| `rx.unix_ms` | položka, volitelné | čas zachycení podle hodin zařízení. Jen pokud byl čas v tu chvíli synchronizovaný přes NTP |
| `age_ms` | položka, volitelné | `tx.uptime_ms − rx.uptime_ms`. Počítá se znovu při každém odeslání, ale jen když `rx.boot` a `rx.instance` odpovídají aktuálnímu bootu. Jinak chybí |
| `tx.instance`, `tx.boot`, `tx.uptime_ms` | obálka | stav v okamžiku odeslání |
| `tx.at` | obálka, volitelné | čas odeslání podle hodin zařízení, jen při synchronizovaném čase |

`age_ms` tedy vždy odpovídá skutečnému stáří při daném odeslání. Pevné stáří uložené při zachycení by bylo nulové a k ničemu.

### Uložené časy

Každý příjem uchovává:

- `server_received_at`: skutečný čas přijetí na serveru,
- všechna pole zařízení beze změny (`device_rx_unix_ms`, `rx_*`, `age_ms`, `tx_at`, `tx_uptime_ms`),
- `captured_at_est`: odhad času zachycení,
- `time_source`: `boot_epoch`, `device_clock` nebo `server_only`,
- `time_uncertainty_ms`,
- `time_flags`: například `clock_disagreement`, `future_device_clock`, `epoch_from_envelope`.

### Odhad epochy bootu

Epocha bootu je čas startu zařízení v UTC pro trojici `(device, instance, boot)`. Ukládá se do `device_boots`.

- Každý vzorek je `server_received_at − tx.uptime_ms`. Protože zpráva nemůže dorazit dřív, než byla odeslána, je každý vzorek horní mez skutečné epochy. Odhad je **minimum** vzorků.
- **Zdroje vzorků:**
  - heartbeat přes MQTT (QoS 0). Broker má `queue_qos0_messages false`, takže heartbeat se pro odpojený collector nehromadí a vždy přichází v reálném čase,
  - každý HTTPS požadavek, protože u něj nefiguruje fronta brokeru.
- **Obálky QoS 1 přes MQTT se jako vzorek nepoužívají.** Broker je mohl držet ve frontě pro odpojený collector a vzorek by byl posunutý o dobu výpadku.
- **Nejistota** = nastavitelná základní hodnota (síťové zpoždění) + `drift × uptime`. Odchylku krystalu ESP změří PoC. Do té doby se použije konzervativní hodnota z konfigurace.

### Výpočet času zachycení

Postup podle priority:

1. **`boot_epoch`:** epocha pro `(rx.instance, rx.boot)` je známá, `captured_at_est = epoch_est + rx.uptime_ms`. Nezávisí na hodinách zařízení, na frontě ESP ani na frontě brokeru. Funguje i pro položky z předchozího bootu, pokud tehdy přišel aspoň jeden heartbeat.
2. **`device_clock`:** epocha známá není, ale existuje `rx.unix_ms` s NTP, opravené o `devices.clock_offset_ms`. Offset se měří z `tx.at` proti `server_received_at` jen u vzorků v reálném čase (heartbeat, HTTPS).
3. **`server_only`:** `captured_at_est = server_received_at` s neomezenou nejistotou. Zpracování podle [Kotva server_only](#kotva-server_only).

**Zadržení:** Když přijde MQTT dávka pro aktuální boot, jehož epocha zatím není známá (typicky hned po připojení), collector zprávu nepotvrdí a počká na první heartbeat, nejdéle `COLLECTOR_EPOCH_WAIT` (návrh 150 s, víc než dvojnásobek intervalu heartbeatu). Když heartbeat nepřijde, použije se pořadí 2 a 3. Horní mez z obálky se uloží jen jako příznak `epoch_from_envelope` a pro kotvu se nepoužije.

**Koncentrátory** posílají vlastní čas, pokud ho jejich payload má. U nich se použije `device_clock` s offsetem měřeným z příjmu v reálném čase (HTTPS, a MQTT jen když zpráva nečekala ve frontě brokeru; UDP frontu brokeru nemá). Jinak `server_only`. Čas, který přidala až platforma, má `source_time_kind = platform_time` a jako čas zachycení na rádiu se nepoužije. Jaký čas ACRIOS skutečně posílá, určí PoC. Chybějící `rx_uptime` se pro něj nevytváří.

### Validace času

| Kontrola | Výsledek při porušení |
| --- | --- |
| `age_ms ≥ 0` a `rx.uptime_ms ≤ tx.uptime_ms` při stejném bootu | `invalid` |
| `age_ms = tx.uptime_ms − rx.uptime_ms`, pokud jsou obě pole k dispozici | `invalid` |
| `rx.boot ≤ tx.boot` při stejné instanci | `invalid` |
| `boot_counter` klesl při stejném `instance_id` | událost `boot_regression`, alarm. Zprávy se dál zpracují, idempotenci drží `msg_key` s `seq` |
| `tx.uptime_ms` klesl ve stejném bootu (podle heartbeatů) | událost `uptime_regression`, epocha se pro tento boot přestane používat |
| `rx.unix_ms` nebo `tx.at` víc než 5 min v budoucnosti proti serveru | hodiny zařízení se ignorují, příznak `future_device_clock`, událost `clock_skew` |
| `captured_at_est` víc než 5 min v budoucnosti | `invalid` (nemá nastat, značí chybu výpočtu) |
| `captured_at_est` starší než `INGEST_MAX_MESSAGE_AGE` (30 dní) | `too_old` |
| `rx.unix_ms` (NTP) a odhad z epochy se liší víc než tolerance | platí epocha, příznak `clock_disagreement`, událost |

`partition_month` příjmu, payloadu tohoto příjmu a `decoded_observations` je měsíc `server_received_at` nebo `received_at`. `partition_month` telegramu je měsíc kotvy. `partition_month` události zařízení je měsíc `received_at` v UTC a `occurred_at` ho neurčuje. Příjem z prosince 2028, který odkazuje na telegram z ledna 2027, leží v prosinci 2028. Lednová identita telegramu je ve sloupcích `raw_telegram_id` a `raw_partition_month` a není to cizí klíč. Retence payloadu, položek a příjmu je 36 měsíců od prosince 2028; retence telegramu a dekódovaného pozorování je 24 měsíců od jejich měsíce. Limity stáří a budoucnosti dál rozhodují, jestli z příjmu smí vzniknout odečet. Neříkají, do které partition se příjem uloží.

### Replay

| Situace | Ochrana |
| --- | --- |
| stejná položka znovu (ztracený ACK, `replay_since`) | nové transportní doručení přes `accept` (nový `payload_id`) se stejným prokázaným `(ingest_source_id, msg_key_namespace, msg_key, item_index)` → R20 `duplicate_delivery` jen této položky. Není to recovery stejné TX1 identity. Hash těla ani shoda bajtů payloadu TX1 identitu nesloučí |
| stejný text `msg_key` na jiném transportu téhož zařízení | `id_collision`, obě doručení zůstanou. Při `msg_key_scope = transport` se nesloučí |
| stejný telegram jiným zdrojem nebo v nové zprávě, v okně a s důvěryhodnou kotvou | exclusion constraint → `duplicate`, jeden `raw_telegrams`. Příjem leží v měsíci svého `server_received_at` |
| stejný obsah, důvěryhodný čas, mimo `dedup_window`, do 60 dní | `suspect_replay`, vlastní příjem, bez odečtu, alarm. Ke staršímu telegramu se nepřipojí |
| `server_only` nebo nejistota větší než okno, shoda obsahu do 60 dní | `probable_duplicate`: nový telegram `ambiguous`, kandidáti v `ingest_dedup_candidates`, bez odečtu a bez připojení |
| `server_only` a žádná shoda do 60 dní | `needs_review`: rámec se uloží, odečet nevznikne |
| stejný obsah starší než 60 dní | `too_old`. U pozdější kopie, která se tváří jako čerstvá, ji zachytí kontrola monotónnosti kumulativní hodnoty a maximálního průtoku při dekódování |
| podvržená zpráva ze sítě | TLS a autentizace každého zařízení nebo koncového bodu. Účet zařízení smí publikovat jen do svých topiců |
| rádiový replay (nahraný a znovu vyslaný telegram) | stejný rámec = stejný `frame_hash`. V okně s důvěryhodnou kotvou se sloučí. Mimo okno je to `suspect_replay`, ne potvrzená duplicita |

## MQTT

### Topics

```text
sjv/v1/dev/{device}/telegrams   zařízení → server   QoS 1      raw, dávka
sjv/v1/dev/{device}/readings    zařízení → server   QoS 1      decoded, dávka
sjv/v1/dev/{device}/telemetry   zařízení → server   QoS 1      normalizovaná telemetrie, dávka
sjv/v1/dev/{device}/events      zařízení → server   QoS 1      boot, chyby, přetečení fronty
sjv/v1/dev/{device}/heartbeat   zařízení → server   QoS 0      stav a časová reference
sjv/v1/dev/{device}/status      zařízení → server   retained   LWT "offline"
sjv/v1/dev/{device}/ack         server → zařízení   QoS 1      výsledek po COMMIT
sjv/v1/dev/{device}/config      server → zařízení   retained   konfigurace zařízení
```

`{device}` je kód zařízení (`ESP-SJV-001`). Je zároveň uživatelským jménem a client ID v Mosquitto Dynamic Security. Topics ACRIOS nejsou tyto topics. Jejich podoba není známá a do konfigurace se doplní až po PoC. Do té doby účet ACRIOS v brokeru není.

### ACL

- **Zařízení** (vlastní role pro každé zařízení):
  - publikovat smí jen do `telegrams`, `readings`, `telemetry`, `events`, `heartbeat` a `status` svého kódu,
  - odebírat smí jen `ack` a `config` svého kódu,
  - výchozí politika je zakázat vše. `$CONTROL/#` a `$SYS/#` zařízení nevidí,
  - client ID musí odpovídat jménu, takže si zařízení nemůže převzít cizí sezení.
- **Collector:** odebírá `sjv/v1/dev/+/telegrams|readings|telemetry|events|heartbeat|status`, publikuje `sjv/v1/dev/+/ack|config`. Připojuje se jen přes interní listener 1883.
- **Backend admin:** jediný účet s právem na `$CONTROL/dynamic-security/v1`. Zakládá, vypíná a ruší účty zařízení. Heslo má jen backend.

### Raw zpráva

```json
{
  "v": 1,
  "tx": { "instance": "9f3c51a07be2d410", "boot": 17, "uptime_ms": 98402100, "at": "2026-11-09T13:10:02.100Z" },
  "items": [
    {
      "msg_key": "9f3c51a07be2d410-17-104233",
      "rx": { "instance": "9f3c51a07be2d410", "boot": 17, "uptime_ms": 87000250, "unix_ms": 1762682400250 },
      "age_ms": 11401850,
      "rssi": -81,
      "fmt": "A",
      "crc": true,
      "frame": "2A442D2C..."
    }
  ]
}
```

- `crc: true` znamená, že rámec obsahuje CRC bloky a server je ověří a odstraní.
- Položka z předchozího bootu má `rx.boot` menší než `tx.boot` a nemá `age_ms`.

### Telemetrie

Tato kapitola sjednocuje datový kontrakt R36. Jde o dokumentační návrh pro budoucí firmware, MQTT collector a HTTPS API; MQTT klient, collector ani HTTPS endpoint zatím v repozitáři nejsou.

Telemetrie používá samostatný topic `sjv/v1/dev/{device}/telemetry` s QoS 1 a také HTTPS endpoint `POST /api/v1/ingest/telemetry`. Obě transportní cesty převádějí zprávu na stejný interní kontrakt `message_kind = telemetry`. Nevzniká paralelní ingest ani nový deduplikační mechanismus. Cesta je `ingest_payloads` (původní obálka) → `ingest_payload_items` (položka) → `ingest_receipts` (příjem a výsledek validace/deduplikace) → `device_telemetry` (normalizovaný vzorek). `meter_readings` z telemetrie nevzniká.

Zařízení smí publikovat pouze do vlastního topicu `sjv/v1/dev/{device}/telemetry`. Collector tento topic odebírá a zpracuje stejnými pravidly společného ingestu. ACK zůstává na stávajícím topicu `sjv/v1/dev/{device}/ack`.

```json
{
  "v": 1,
  "tx": {
    "instance": "9f3c51a07be2d410",
    "boot": 17,
    "uptime_ms": 99300000,
    "at": "2026-11-09T13:15:00.000Z"
  },
  "samples": [
    {
      "msg_key": "9f3c51a07be2d410-17-t-001234",
      "uptime_ms": 99300000,
      "measured_at": "2026-11-09T13:15:00.000Z",
      "power": {
        "source": "battery",
        "battery_mv": 3820,
        "charging": false,
        "soc_percent": null
      }
    }
  ]
}
```

`v` je verze kontraktu. `tx.instance`, `tx.boot`, `tx.uptime_ms` a `tx.at` identifikují vysílač a čas odeslání. Každý prvek `samples` je jedna položka se stabilním `msg_key`, `uptime_ms` a UTC `measured_at`. Při opakování se odešle stejný klíč i stejný obsah. Dávka používá `item_index` v existující identitě `(ingest_source_id, msg_key_namespace, msg_key, item_index)` v `ingest_message_keys`. Hash obsahu není náhradou `msg_key`.

Jeden prvek `samples` je jeden kompletní telemetrický vzorek. Může obsahovat více skupin hodnot současně, například `power`, teplotu nebo signál. JSON kontrakt nepoužívá samostatné pole `kind` ani samostatný vzorek pro každou skupinu. Skupiny přítomné ve vzorku se po úspěšném zpracování uloží jako objekt `device_telemetry.payload`; neznámé nebo nedostupné hodnoty se neposílají jako nula. `power` je nepovinná skupina; `soc_percent` se vynechá nebo je `null`, pokud jej zařízení neumí spolehlivě určit.

Výchozí `msg_key_scope` je `transport`, takže MQTT používá namespace `mqtt` a HTTPS namespace `https`. Firmware ESP společný prostor klíčů napříč transporty zatím neprokazuje, proto se stejný text `msg_key` mezi MQTT a HTTPS automaticky neslučuje. Když má stejný text `msg_key` napříč transporty také stejný `content_hash`, pozdější příjem dostane `id_collision`. `delivery_count` se mezi transporty nesčítá, výsledek se neoznačuje jako `duplicate_delivery` a žádné pozorování se kvůli této kolizi nemaže. Opakované doručení stejného transportu se vyhodnocuje přes existující `ingest_message_keys` a může skončit jako `duplicate_delivery`.

Příjem zachovává limit `INGEST_MAX_MESSAGE_AGE` a existující validační a deduplikační pravidla. `ingest_receipts` eviduje každou přijatou položku a její výsledek, včetně `accepted` nebo `duplicate_delivery`; tento výsledek je podkladem pro položkový aplikační ACK. ACK se publikuje až po COMMIT výsledné transakce. Zařízení odstraní vzorek z persistentní fronty až po uložení odpovídajícího výsledku ACK. Telemetrický vzorek sám o sobě nezakládá `device_events`; významné změny a alarmy se vyhodnocují centrálně po uložení. Heartbeat zůstává samostatný, QoS 0, s intervalem `heartbeat_s` (návrh 60 s) a telemetrii nenahrazuje. Interval telemetrie je `telemetry_interval_s` (návrh 900 s) v retained konfiguraci.

### Heartbeat

```json
{
  "v": 1,
  "instance": "9f3c51a07be2d410", "boot": 17, "uptime_ms": 98400000,
  "at": "2026-11-09T13:10:00.000Z", "ntp": true,
  "fw": "0.3.1", "rssi_wifi": -67,
  "queue": { "depth": 12, "oldest_uptime_ms": 87000250, "oldest_boot": 17, "dropped": 0 },
  "filtered_unknown": 3
}
```

Heartbeat nese `instance`, `boot`, `uptime_ms` a `at` (čas odeslání podle hodin zařízení). Interval je v `config`, návrh 60 s.

### Config

Retained zprávu publikuje collector podle `PUT /api/v1/admin/devices/{id}/config`. Každá změna jde do auditu.

```json
{
  "v": 1, "rev": 7,
  "meters": ["2C2D31957904", "2C2D98670804"],
  "discovery_until": null,
  "heartbeat_s": 60, "telemetry_interval_s": 900, "batch_max": 50, "ack_timeout_s": 30,
  "replay_since": null
}
```

- `meters` je whitelist M a A polí. Měřidla mimo whitelist zařízení jen počítá (`filtered_unknown`).
- `discovery_until` dočasně povolí odesílání všech zachycených měřidel kvůli instalaci nových.
- `replay_since` (čas nebo `msg_key`) vyžádá opakované odeslání potvrzených záznamů po obnově serveru ([firmware-design.md](firmware-design.md)).

### ACK

```json
{ "v": 1, "results": [ { "msg_key": "9f3c51a07be2d410-17-104233", "status": "accepted" } ] }
```

| Stav | Význam |
| --- | --- |
| `accepted` | uložený výsledek položky (například nový telegram nebo pozorování). Sám o sobě nevypovídá, zda vznikl odečet |
| `duplicate` | potvrzená shoda uvnitř `dedup_window`. Příjem je připojený k existujícímu telegramu |
| `probable_duplicate` | rámec je uložený jako vlastní telegram `ambiguous`. Ke staršímu telegramu připojený není a odečet nevznikl |
| `needs_review` | rámec je uložený, shoda se nenašla a bez důvěryhodné kotvy odečet nevznikl |
| `duplicate_delivery` | prokázanou položku `(ingest_source_id, msg_key_namespace, msg_key, item_index)` už server má. Ostatní položky zprávy tento stav sám neuzavře |
| `uncertain` | stejný `content_hash` bez prokázaného identifikátoru. Pozorování zůstalo, odečet z něj nevznikl |
| `id_collision` | stejný text `msg_key` v jiném namespace. Doručení se nesloučila |
| `suspect_replay` | uloženo jen jako příjem a telegram bez fronty dekódování, bez odečtu |
| `unknown_meter` | měřidlo není evidované, rámec se neuložil |
| `invalid` | chybný CRC, formát nebo nekonzistentní časy |
| `too_old` | starší než `INGEST_MAX_MESSAGE_AGE` |
| `unresolved` | pozorování je uložené. Stejný čas ve streamu už má aktivní kumulativní odečet a druhý se nezaložil |
| `conflict` | pozorování je uložené s jinou hodnotou. Původní odečet se nezměnil |

Normalizace může uložit interní příjem se stavem `crc_error`. Aplikační ACK vrací stav každé položky, ale mapování interního `crc_error` na některý status z této tabulky není v transakčním popisu výslovně doložené a zůstává otevřenou otázkou. Nový ACK status se kvůli tomu nezavádí.

Zařízení smaže zprávu z fronty až tehdy, když má uložený výsledek každá její položka. Jedna položka ve stavu `duplicate_delivery` ostatní položky nepotvrzuje. U ESP má položka fronty vlastní `msg_key`. U zprávy s více položkami pod jedním `msg_key` odpověď vypíše každý `item_index` a jeho stav. Stav `accepted` znamená uložený výsledek této položky, ne to, že z každé položky vznikl odečet. `probable_duplicate`, `needs_review`, `uncertain` a `id_collision` se do `duplicate` neskládají. Bez kompletního ACK zařízení po timeoutu pošle znovu stejný `msg_key` a stejné údaje `rx`.

### Doručení až po COMMIT

1. Collector má persistentní sezení (`clean_start = false`, QoS 1) a ruční PUBACK. Podpora ručního PUBACK v paho-mqtt 2.x (`manual_ack`) se ověří v PoC. MQTT klient a collector v repozitáři ještě nejsou; jde o návrh chování nad existujícími `accept` / `evaluate_item`.
2. PUBACK brokeru i aplikační ACK zařízení se odešlou až po COMMIT TX2.
3. Dva odlišné pády se nesmí slévat:
   - **Pád mezi TX1 a TX2** (payload a položky jsou potvrzené, receipt ještě ne): položka zůstává v DB. Stejnou TX1 trojici `(payload_id, payload_partition_month, item_index)` dokončí `evaluate_item` (první běh nebo short-circuit). Výběr položek bez receiptu dělá knihovna `sjv_ingest.recovery` a one-shot CLI `python -m sjv_ingest.recovery` (hot-path: aktuální a předchozí UTC měsíc). Periodický worker, host timer ani historický backfill **zatím nejsou** zapojené; spouštění a rozsah backfillu zůstávají otevřené. Shoda bajtů nebo `msg_key` sama o sobě TX1 identitu nenahrazuje.
   - **Pád po COMMIT TX2 před ACK** (receipt už je): broker nebo zařízení doručí MQTT zprávu znovu. Nové přijetí jde znovu přes `accept` a může založit **nový** `payload_id`. To už není stejná TX1 položka a není to úloha `sjv_ingest.recovery`. `evaluate_item` na nové trojici podléhá R20: při shodném prokázaném klíči vznikne nový receipt se `receipt_status = duplicate_delivery`, `delivery_count` se zvýší a `outcome` / `original_receipt_*` zůstanou z prvního doručení.
4. Později lze přidat více collectorů přes `$share/collectors/...`. Idempotence TX1 i R20 je v DB, ne v paměti collectoru.

## HTTPS ingest

| Metoda a cesta | Obsah |
| --- | --- |
| `POST /api/v1/ingest/telegrams` | dávka raw, stejný formát jako MQTT |
| `POST /api/v1/ingest/readings` | dávka decoded: kanonický formát, nebo formát dodavatele přes adaptér |
| `POST /api/v1/ingest/telemetry` | dávka telemetrie, stejný interní kontrakt jako MQTT |
| `POST /api/v1/ingest/events` | události |
| `POST /api/v1/ingest/heartbeat` | stav, stejný formát jako MQTT |

- **Autentizace vlastního ESP:** `Authorization: Bearer <token zařízení>`. Token se ukládá jako hash.
- **Autentizace koncentrátoru:** heslo, token, klientský certifikát nebo PSK podle toho, co model umí. Pro ACRIOS není metoda vybraná. mTLS je připravené, není povinné.
- **Odpověď:** `200` s výsledkem pro každou položku, ve stejných stavech jako ACK. `200` znamená, že data jsou v DB. Při `5xx` musí zdroj poslat znovu. Duplicitní doručení je bezpečné.
- **Limity:** velikost těla, počet položek v dávce a rate limit na token, vše v aplikaci.
- **CrowdSec:** ingest router v Traefiku má vlastní řetězec middleware. CrowdSec se na něj aplikuje opatrně, protože zařízení za CGNAT sdílejí veřejné IP s cizími klienty a blokace podle IP by mohla odříznout vlastní zařízení. Hlavní ochranou je autentizace a limit na token.

## Další transporty

Platí, i když konkrétní datagram, topic nebo JSON ACRIOS ještě nejsou známé.

- **UDP/DTLS.** Každý datagram je jeden `ingest_payloads` s `content_kind = udp_datagram`. Otevřený UDP se nezapíná. DTLS se použije, až PoC ukáže, že ho vybraný model má. Session DTLS nenahrazuje aplikační `msg_key`. Port se do Compose ani do firewallu nepřidává, dokud PoC přímý UDP potvrdí a změna mimo repozitář bude zvlášť schválená.
- **Platform API.** Server se dotazuje sám, z procesu na síti `sjv-egress`. Odpověď je payload `api_response`. Záznamy uvnitř se rozdělí adaptérem na položky kontraktu. Účet platformy má vlastní řádek `ingest_sources` s `kind = platform` a `device_id` NULL. Prokázaná idempotence je `(ingest_source_id, msg_key_namespace, msg_key, item_index)` tohoto řádku. Všechny položky jednoho payloadu se zpracují v jedné transakci. Bez prokázaného identifikátoru se položky neslučují podle hashe. Koncentrátor uvnitř odpovědi se na `devices` namapuje jen přes `device_external_ids` a klíč zprávy se na něj nepřesune. Neznámý identifikátor zařízení nezaloží a příjem má `device_attribution = unattributed`.
- **Import souboru.** Import má vlastní `ingest_sources` s `kind = import`. Celý soubor je jeden payload. Řádek, který projde validací, je položka `import_row`. Identifikátor řádku se jako `msg_key` použije jen tehdy, když formát prokáže, že se neopakuje. Hash řádku identifikátor není. Stejný obsah dvou řádků jsou dvě doručení se stavem `uncertain`. Odečet má `source_kind = import` a `source_key = import:<payload_id>:<řádek>`. Ruční odečet zadaný ve formuláři zůstává `manual` a souborem není.

## Deduplikace raw telegramů

### Cíle

- Každý příjem se eviduje zvlášť (`ingest_receipts`) v měsíci svého `server_received_at`, včetně opakovaného doručení prokázané položky `(ingest_source_id, msg_key_namespace, msg_key, item_index)`.
- Stejný rádiový telegram zachycený více zdroji, nebo opakovaně jedním v nové zprávě, má jeden `raw_telegrams` a nejvýš jeden aktivní odečet, když je shoda potvrzená uvnitř `dedup_window` a kotva je důvěryhodná. Mimo ni se rámec uloží znovu a odečet se nezaloží.
- Dva různé telegramy se stejnou hodnotou spotřeby se nesloučí. Stejná hodnota není deduplikační klíč.
- Deduplikace funguje pro opožděné doručení z fronty ESP, i když jiný přijímač poslal stejný telegram už dříve, a funguje při souběžném zpracování.
- Pravidla jsou společná pro ESP i pro každý koncentrátor, který předá skutečný rámec, včetně budoucího ACRIOS. Zařízení, které předá jen JSON, touto větou neprojde a rámec se pro něj nevytvoří.

### Normalizace rámce (verzovaná, `normalizer_version`)

1. Hex se převede na bajty. Podle `fmt` a `crc` se ověří a odstraní CRC bloky formátu A nebo B. Při chybném CRC dostane příjem stav `crc_error` a telegram nevznikne.
2. Rámec se převede na kanonickou podobu bez CRC s přepočítaným L-polem.
3. Načte se M a A pole (výrobce, ID, verze, typ), z nich `meter_key`, a CI pole. Z krátké nebo dlouhé hlavičky transportní vrstvy se vezme ACC a uloží se do sloupce `access_number`. Režim šifrování se uloží vedle něj.
4. `frame_hash = sha256(kanonický rámec)`. Šifrovaný telegram se porovnává podle šifrovaného obsahu. Retransmise stejného telegramu je bitově shodná.
5. Rámce s extended link layer nebo značkami opakovače se zpracují podle pravidel ověřených na skutečných telegramech. U neznámé struktury se použije hash celého rámce. To může zanechat duplicitní telegram, ale nikdy nesloučí dva různé.

### Okno W

- Výchozí W = 10 minut (kotva ± 5 minut). Kotva je `captured_at_est`. W musí být větší než dvojnásobek nejistoty času, jinak se příjem zpracuje jako `server_only`.
- `access_number` je jeden bajt a přetočí se po 256 telegramech. Pro každé měřidlo musí platit `W ≤ (256 × interval vysílání) / 4`. Interval se odhaduje z historie měřidla. Když výchozí W pravidlo nesplní, použije se `meters.dedup_window`. Do klíče se uloží jako rozsah `telegram_dedup_keys.dedup_window`.
- Okno se uplatní jen pro shodný obsah (`meter_key`, `access_number`, `frame_hash`) a jen s důvěryhodnou kotvou.

### Neznámá měřidla

- `meter_key` bez záznamu v `meters`, nebo se stavem `retired`, dostane stav příjmu `unknown_meter`.
- Neuloží se rámec, telegram ani deduplikační klíč, jen se aktualizuje `unknown_meter_sightings` (upsert).
- Administrace je zobrazí v `/api/v1/admin/unknown-meters`, odkud lze měřidlo založit.

### Transakce jedné přijaté zprávy

Příjem má dvě samostatně potvrzené transakce.

První vloží původní bajty do `ingest_payloads` a každý řádek `ingest_payload_items` a potvrdí je společně, dřív než se rozhoduje identita, deduplikace nebo dekódování. Bajty obálky a bajty položky zůstávají oddělené. Když formát nejde určit bez dalšího vyhodnocení, `content_kind` je `opaque`. Neznámý druh položky se uloží a transakci nezruší. V této transakci nevznikne příjem položky, klíč zprávy, telegram, deduplikační klíč, fronta ani fragment. `proof_basis` zůstává prázdná, dokud její ověření neschválí samostatné rozhodnutí. Boolean `identifier_proven` se uloží jako vstupní údaj položky a při načtení se vrátí. `proof_basis` z něj nevznikne a klíč zprávy se nezaloží.

Druhá transakce (`evaluate_item`) vyhodnotí **jednu** uloženou TX1 položku a atomicky uloží její konečný receipt a případný stav `ingest_message_keys`. TX1 identita položky je `(payload_id, payload_partition_month, item_index)`. R20 identita prokázané zprávy je `(ingest_source_id, msg_key_namespace, msg_key, item_index)`. Rollback TX2 už potvrzený payload ani položky nesmaže. ACK, včetně PUBACK, se odešle až po COMMIT TX2.

`load_envelope` skládá obálku z uloženého payloadu a položek a nic nezapisuje. Obnova konkrétní nedokončené TX1 položky vždy končí voláním stejného `evaluate_item` nad **stejnou** TX1 trojicí. Finder položek bez receiptu je `sjv_ingest.recovery` (včetně one-shot CLI); periodická orchestrace po restartu collectoru / host timer **zatím není**. Opakované MQTT doručení po ztraceném ACK nepoužívá tuto cestu: znovu volá `accept` a dostane nový `payload_id`.

```text
BEGIN  — transakce 1 (accept)
  INSERT ingest_payloads s původními bajty obálky.
  INSERT ingest_payload_items pro položky 0 .. n-1, každá se svými bajty.
  Prázdná obálka vloží nula položek a hned v TX1 jeden receipt
    status = invalid, item_index = -1, bez ingest_message_keys.
  Chyba kteréhokoli INSERT vrátí celou transakci.
COMMIT

BEGIN  — transakce 2 (evaluate_item jedné položky i)
  role musí být sjv_collector
  pg_advisory_xact_lock z kanonického klíče
    md5('sjv.evaluate_item.v1|' || payload_id || '|' || YYYY-MM-DD || '|' || i)
    → decode(hex)::bigint
    Zámek drží do COMMIT/ROLLBACK této TX2.
  SELECT receipt pro (payload_id, payload_partition_month, i)
  → existuje:
      sestav EvaluationResult z tohoto receipt
      (receipt_status = receipt.status;
       outcome a original_receipt_* z ingest_message_keys, pokud R20 klíč existuje;
       bez klíče: outcome = receipt.status, first_delivery = true)
      žádný další INSERT/UPDATE/UPSERT
      COMMIT
  → neexistuje:
      load_envelope + validace jen položky i
      INSERT ingest_receipts (provisional status accepted|invalid)
      když je použitelný msg_key + namespace:
        UPSERT ingest_message_keys (R20)
          first_delivery: status zůstane accepted|invalid,
            keys.receipt_* = tento receipt, delivery_count = 1
          jinak: UPDATE receipt.status = duplicate_delivery,
            delivery_count += 1, outcome a original_receipt_* zůstanou z prvního doručení
      bez klíče: first_delivery = true, bez ingest_message_keys
      Současný evaluate_item do raw_telegrams / device_events / device_telemetry
        nezapisuje; to je pozdější krok mimo tento evaluator.
      COMMIT
ACK až po COMMIT TX2. Odpověď má jeden záznam na položku:
  aplikační výsledek bere outcome (+ original_receipt_*),
  historický stav doručení této TX1 položky je receipt_status.
```

Rozlišení opakování:

- **Opakované evaluate stejné TX1 položky** (stejný `payload_id` + měsíc + `item_index`): nejvýše jeden receipt; short-circuit vrátí stejný `EvaluationResult` a nezvýší `delivery_count`. Volající může být ruční zásah, test, nebo `sjv_ingest.recovery` / `python -m sjv_ingest.recovery`, které nedokončené položky dohledají a předají do `evaluate_item`.
- **Nové transportní doručení** (znovu `accept`, typicky po ztraceném ACK): nový `payload_id`, i když bajty nebo `msg_key` sedí. Při shodném R20 klíči nový receipt se `receipt_status = duplicate_delivery`; `delivery_count` se zvýší; `outcome` a `original_receipt_*` zůstanou z prvního doručení. To není TX1 recovery stejné uložené položky.

Pozdější kroky dekódování (`telegram_dedup_keys`, `decode_queue`, `raw_telegrams`) zůstávají popsané v sekcích o telegramu a workerovi. Řádek `decode_queue` vkládá role přijímajícího procesu jen když výsledek telegramové deduplikace je `pending`. U MQTT je to `sjv_collector`, u HTTPS `sjv_api`. Obě role mají na frontu jen `INSERT`. `sjv_worker` řádek nevkládá. Bere ho `FOR UPDATE SKIP LOCKED`, zapíše zámek a počet pokusů a po vyčerpání pokusů ho smaže.

Zařízení smí frontu smazat až po ACK, ve kterém má uložený výsledek každá položka. `duplicate_delivery` platí jen pro položku, jejíž R20 klíč už patřil dřívějšímu doručení. Stejný `content_hash` bez prokázaného identifikátoru tímto krokem `duplicate_delivery` nezaloží.

### Proč je to bezpečné při souběhu

- Exclusion constraint vynucuje deduplikaci přímo v databázi.
- Když dvě transakce vkládají překrývající se klíč současně, druhá na `ON CONFLICT DO NOTHING` počká, až první skončí:
  - první COMMIT: druhá vidí konflikt, v kroku 7b najde potvrzený řádek (READ COMMITTED bere pro každý příkaz nový snapshot) a připojí příjem,
  - první ROLLBACK: druhá vloží svůj klíč.
- Dva uložené klíče se stejným obsahem jsou od sebe vždy alespoň W. Nový příjem se tak může překrývat nejvýš se dvěma, a to jen když by dva různé telegramy se shodným obsahem a ACC přišly do 2W. Podmínka na W to vylučuje. Kdyby to přesto nastalo, vybere se nejbližší kotva a zapíše se událost `dedup_ambiguous`.
- Odečet vzniká při dekódování se `source_key = raw:<raw_telegram_id>` a `ON CONFLICT DO NOTHING`. Ani opakované dekódování nevytvoří druhý odečet. Telegram `ambiguous`, `needs_review` a `suspect_replay` ve frontě není, takže z něj odečet sám nevznikne.

### Příklad: pozdní doručení z ESP a souběžný koncentrátor

ESP-SJV-001 je v bootu 17. Jeho epocha je ze heartbeatů známá s nejistotou pod 1 s.

| Čas | Událost | Výsledek |
| --- | --- | --- |
| 10:00:00,2 | Měřidlo vyšle telegram F (ACC `0x5A`, 123,456 m³). ESP ho uloží s `rx.uptime_ms = 87 000 250` | |
| 10:00:05 | CONCENTRATOR-001 pošle F přes HTTPS, jeho offset hodin je změřený | kotva 10:00:00,3 → **R1**, příjem 1 |
| 10:00:08 | Měřidlo vyšle telegram G (ACC `0x5B`, stále 123,456 m³) | |
| 10:00:12 | CONCENTRATOR-001 pošle G | jiný ACC i hash → **R2**, příjem 2, druhý odečet se stejnou hodnotou |
| 10:00–13:10 | ESP je bez internetu, F a G drží ve flash frontě | |
| 13:10:02 | ESP se připojí, pošle heartbeat a dávku s F (`age_ms = 11 401 850`) | kotva = epocha + 87 000 250 ms ≈ 10:00:00,25 → konflikt s R1 → příjem 3 k **R1** |
| 13:10:02 | stejná dávka obsahuje G | konflikt s R2 → příjem 4 k **R2** |
| 13:10:03 | ACK se ztratí, ESP pošle F znovu se stejným `msg_key` a stejným `rx` | nové `accept` → nový `payload_id`; R20 `duplicate_delivery` (další příjem), žádný nový telegram ani odečet. Není to short-circuit stejné TX1 položky |

Výsledek: dva telegramy, pět příjmů, dva odečty se stejnou hodnotou. Pátý příjem je opakované doručení F a odečet nezakládá. Spotřeba je správná, protože se počítá z kumulativních hodnot.

Stejný výsledek vyjde, i když collector byl hodinu mimo provoz a broker dávku držel. Kotva vychází z `rx.uptime_ms` a epochy z heartbeatů, ne z času doručení. Stejné sloučení nastane, když druhý přijímač není ESP, ale koncentrátor včetně ACRIOS, pokud předá stejný rámec. Jeho `device_id` je jiné, `msg_key` je jiné a `telegram_dedup_keys` oba příjmy spojí s jedním telegramem.

### Kotva `server_only`

Nastává, když epocha bootu zachycení není známá a zařízení nemělo NTP, nebo když je nejistota času větší než polovina `dedup_window`. Koncentrátor s vlastními hodinami sem nepatří: použije `device_clock`. Příklad `server_only`: celý předchozí boot byl bez spojení a bez NTP.

`access_number` je jeden bajt. Za 60 dní se přetočí. Bitově shodný rámec se stejným `access_number` proto může být nové vysílání, ne kopie starého. Okno W tu shodu neumí potvrdit, protože kotva není důvěryhodná. Automatické připojení k nalezenému telegramu by smazalo rozdíl mezi kopií a novým vysíláním.

1. `telegram_dedup_keys` se nevkládá. Exclusion constraint by bez důvěryhodného `anchor_at` spojoval různá vysílání.
2. Hledá se `(meter_key, access_number, frame_hash)` v `telegram_dedup_keys` za posledních 60 dní.
3. **Aspoň jeden kandidát.** Vznikne nový `raw_telegrams` se `decode_status = ambiguous` a `partition_month` podle `server_received_at`. Příjem má stav `probable_duplicate` a `raw_telegram_id` tohoto nového řádku, ne kandidáta. Každý kandidát se zapíše do `ingest_dedup_candidates` bez cizího klíče na jeho telegram. `receipt_count` a `capture_device_ids` kandidáta se nemění. `decode_queue` se nevkládá. Odečet nevznikne.
4. **Žádný kandidát.** Vznikne nový `raw_telegrams` se `decode_status = needs_review`. Příjem má stav `needs_review`. Fronta ani odečet nevzniknou. Nezakotvený rámec se nestane spotřebou jen proto, že se podobný v okně nenašel.
5. ACK je `probable_duplicate` nebo `needs_review`. Zařízení smí zprávu z fronty smazat, protože rámec je uložený. Stav se nehlásí jako `duplicate`.

Administrátor později, se zápisem do auditu:

- potvrdí sloučení s jedním kandidátem. Nový telegram zůstane `ambiguous` a odečet z něj nevznikne. Až toto potvrzení smí zvýšit `receipt_count` potvrzeného telegramu,
- nebo uvolní nový telegram k dekódování (`pending` a řádek `decode_queue`). Odečet smí vzniknout teprve potom.

Do té doby se kumulativní řada, spotřeba ani hodnota pro R15 nepohnou. R15 dál ukazuje poslední důvěryhodný kumulativní stav přiřazeného streamu. Nevyřešený rámec ho nenahradí a nezdvojí.

Když později přijde stejný rámec s důvěryhodnou kotvou, projde běžným oknem. `ambiguous` řádek v `telegram_dedup_keys` není, takže ho exclusion constraint nespojí s novým příjmem a druhý odečet z něj nevznikne.

### Podezření na replay

Shodný obsah s důvěryhodnou kotvou, mimo `dedup_window`, ale do 60 dní, dostane `decode_status = suspect_replay`: bez odečtu, s událostí a upozorněním administrátorovi. Ke staršímu telegramu se nepřipojí. Není to `probable_duplicate`. Ten patří jen kotvě bez důvěryhodného času. Administrátor může telegram ručně uvolnit k dekódování (s auditem), třeba u měřidel, jejichž telegram neobsahuje měnící se čas ani čítač a po přetočení `access_number` se skutečně zopakoval. Do uvolnění odečet nevznikne.

## Pět případů, které se nesmí slít

| Případ | Jak se pozná | Co vznikne |
| --- | --- | --- |
| 1. Opakované doručení stejné položky | nové transportní doručení se stejným prokázaným `(ingest_source_id, msg_key_namespace, msg_key, item_index)` (nový `payload_id`) | další `ingest_receipts` se stavem `duplicate_delivery` jen této položky, žádný nový odečet. Opakované evaluate **stejného** TX1 `(payload_id, payload_partition_month, item_index)` nový receipt nevytváří. Ostatní položky prvního doručení se zpracují. Stejný hash bez identifikátoru tento případ není |
| 2. Stejný telegram, víc zdrojů | jiné `ingest_source_id` nebo jiný identifikátor, stejné `(meter_key, access_number, frame_hash)` uvnitř `dedup_window` a důvěryhodná kotva | jeden `raw_telegrams`, N příjmů v měsících svých přijetí, jeden odečet `raw:<raw_telegram_id>` |
| 3. Nový telegram se stejnou hodnotou | jiné `access_number` nebo jiný `frame_hash`; u dat bez rámce jiné tělo, nebo stejné tělo bez prokázaného identifikátoru | nový telegram nebo nové pozorování. Shoda hodnoty, času nebo hashe zprávy nespojí |
| 4. Fragmenty jedné zprávy | prokázané `message_ref`: fragmenty jedné zprávy se mohou skládat do odpovídající sady `collecting`. Neprokázané `message_ref`: každé doručení má vlastní sadu `isolated` a `repeat` se nepoužije | u prokázaného `message_ref` žádný odečet, dokud sada není `complete`. Sada `isolated` se neskládá a dekodér ji nedostane |
| 5. Nové dekódování starých dat | stejný `source_key`, jiná `decoder_version` nebo `adapter_version` | druhý aktivní odečet nevznikne. Shoda hodnoty jen audit. Jiná hodnota je oprava, která původní řádek označí `superseded_at` |

Případ 1 nastane jen u prokázaného identifikátoru. Dvě doručení téhož těla bez něj jsou dvě položky se stavem `uncertain`. Stejný text `msg_key` jiného `ingest_source_id` nebo jiného `msg_key_namespace` je jiná zpráva. Když jde o dva transporty téhož zařízení, pozdější příjem je `id_collision`.

U dekódovaných dat bez rámce čas měření identita není. Může mít hrubé rozlišení a víc položek ho může sdílet. Pravidla jsou v [Idempotence a deduplikace](#idempotence-a-deduplikace). Časy se nesbližují heuristikou. Jestli ACRIOS posílá stabilní čas a s jakou přesností, ukáže PoC.

Opětovné dekódování (případ 5):

- slepý opakovaný běh narazí na `UNIQUE (source_key)` a řádek nevloží,
- řízený běh nové verze porovná nový výstup s uloženou hodnotou,
- stejná hodnota: odečet se nemění, audit dostane `redecode_unchanged` se starou a novou verzí,
- jiná hodnota: vznikne řádek `correction` s novou verzí, původní dostane `superseded_at`, důvod je `decoder_upgrade`. Oba aktivní nezůstanou.

## Fragmentace

Fragment není položka dekodéru. Dekodér a deduplikace telegramu dostanou až složený payload sady ve stavu `complete`. Sada `isolated` se neskládá a dekodér ji nedostane.

Každé nové doručení bez prokázaného `message_ref` dostane vlastní sadu `isolated` s jedním řádkem `first` a vlastním `payload_id`. `delivery_role = repeat` se u `isolated` nepoužívá. Shoda `group_key`, `source_message_ref`, indexu, hashe, času ani identity transportního přenosu doručení k existující sadě nepřiřadí.

`repeat` je povolen jen u sady `collecting` s prokázaným `message_ref`. Stavy `collecting`, `complete`, `conflict` a `timed_out` patří jen této sadě.

Postup jednoho fragmentu:

```text
BEGIN
 1. ingest_source_id je dané účtem nebo koncovým bodem. Bez něj se sada nezaloží
    (odmítnutí fragment_unidentified). device_id je jen atribuce a smí chybět.
    Payload tohoto doručení se uloží vždy, dřív než se rozhoduje o sadě.
    Každé doručení má vlastní ingest_payloads a vlastní evidenci.
 2. group_key a fragment_index musí přijít od zdroje. Když chybí, payload zůstane,
    ingest_rejections.reason = fragment_unidentified, COMMIT. Sada nevznikne.
    group_key se nepovažuje za globálně jedinečné a adaptér k němu nepřidává předponu.
    group_key, hash payloadu, časová blízkost ani source_message_ref
    nejsou důkazem identity celé zprávy.
    source_message_ref se uloží na fragment, když ho zdroj poslal.
    Je to údaj od zdroje a ke spojování sad se nepoužije.
    message_ref sady se vyplní jen po PoC, který prokáže rozsah jeho jedinečnosti.
    Když ten rozsah platí jen v rámci transportu, je transport součást identity.
    Do výsledku PoC message_ref zůstane NULL.
 3. message_ref není prokázané:
       Zámek podle group_key se nebere. Jiná sada se podle group_key nehledá.
       Collecting sada nevznikne a SAVEPOINT pro ni není.
       Každé nové doručení dostane vlastní sadu status = isolated,
       message_ref NULL, právě jeden logický fragment,
       jeden řádek delivery_role = first a vlastní payload_id.
       delivery_role = repeat se nepoužije.
       Shoda group_key, source_message_ref, fragment_index, content_hash,
       času ani identity jednotlivého transportního přenosu
       doručení k existující sadě nepřiřadí.
       Shoda indexu a hashe sama repeat nevytvoří.
       Odlišný content_hash je další samostatná sada isolated.
       Původní sada se na conflict nezmění, změněný obsah nepřijme
       a oba payloady zůstanou.
       Jiný fragment se k sadě nepřipojí.
       Sada se neskládá a dekodér se nevolá. COMMIT.
 4. message_ref je prokázané:
       pg_advisory_xact_lock na (ingest_source_id, message_ref).
       Když rozsah zahrnuje transport, je v zámku i transport.
       Zámek drží do COMMIT, takže dva procesy nezaloží dvě otevřené sady.
       najdi collecting sadu se stejným rozsahem a message_ref před deadline_at.
       našla se: připoj fragment k ní.
       collecting se nenašla. Nejdřív sada timed_out se stejným prokázaným message_ref:
          tato větev je před větví complete a conflict.
          k sadě se nepřipojuj. Její stav ani obsah se nemění.
          Nová isolated nevznikne, protože message_ref je prokázaný.
          Nová collecting se stejným message_ref nevznikne.
          Payload tohoto doručení zůstane.
          Doručení se neskládá a dekodér se nevolá.
          Eviduje se jako nepřiřazené a vyžadující samostatné vyhodnocení.
          Platí, dokud samostatný PoC neprokáže bezpečné zacházení
          a nebude přijato nové rozhodnutí. COMMIT.
       timed_out se nenašla a existuje complete nebo conflict se stejným message_ref:
          k sadě se nepřipojuj. R32 se nepoužije.
          Jak se doručení eviduje, jestli vznikne nová sada a jestli se dekóduje,
          schválená pravidla neurčují. Je to otevřená otázka, ne nové rozhodnutí.
          Payload z kroku 1 zůstane.
       nenašla se žádná sada s tímto message_ref: SAVEPOINT set_insert,
          INSERT collecting s tímto message_ref a group_key.
       Jedinečný index collecting sady je pojistka zámku v prokázaném rozsahu.
       unique_violation: ROLLBACK TO SAVEPOINT set_insert, znovu SELECT vítězné sady.
          Vítěz je stejná identita a pořád collecting před deadline_at: připoj k němu.
          Vítěz je timed_out: větev timed_out výše, dřív než complete a conflict.
          Vítěz je complete nebo conflict: otevřená otázka výše. R32 se nepoužije.
             K sadě se nepřipojí. Payload z kroku 1 zůstane.
 5. Isolated zakládá jen krok 3, pro doručení bez prokázaného message_ref.
       Ukončenou sadu rozhoduje krok 4.
 6. Připojení k collecting sadě s prokázaným message_ref:
       index v sadě ještě nemá řádek first:
          INSERT ingest_fragments delivery_role = first, vlastní payload_id.
       stejný content_hash: další řádek delivery_role = repeat,
          vlastní payload_id a received_at. Řádek first se nemění.
       jiný hash: další řádek delivery_role = conflict, sada conflict,
          ingest_rejections fragment_conflict. Řádek first a jeho payload zůstanou.
          Dekodér se nevolá.
 7. Když fragmenty uvádějí různý expected_count, collecting sada je conflict
    a dál se neskládá.
 8. Když jsou přítomné všechny indexy 0 .. expected_count-1 jako řádky first
    (nebo zdroj označil konec a indexy tvoří souvislou řadu od nuly):
       slož bajty řádků first v pořadí indexů do ingest_payloads, origin = assembled,
       sada complete,
       složený payload vstupuje jednou do transakce přijaté zprávy.
       msg_key složené zprávy je prokázané message_ref.
       Hash složeného těla msg_key není.
COMMIT
```

Budoucí možnost, ne součást současného postupu: rozpoznání opakovaného doručení u `isolated` bude možné až po samostatném PoC, které prokáže stabilní identitu téhož logického fragmentu napříč opakovanými doručeními. Identifikátor jednoho transportního přenosu nestačí.

`repeat` a `conflict` databáze přijme jen tehdy, když je sada v okamžiku vložení nebo změny role `collecting`. `UPDATE` ostatních sloupců fragmentu, nebo zápis stejné role, stav sady znovu nezkoumá. Po vložení řádku `conflict` postup sady teprve přepne na `conflict`.

Neúplná sada s prokázaným `message_ref` zůstane `collecting`. Worker po `deadline_at` nastaví `timed_out`, zapíše `ingest_rejections` s důvodem `fragment_timeout` a dekodér nezavolá. `INGEST_FRAGMENT_TIMEOUT` platí jen pro tyto skládané sady s prokázanou identitou. Sada `isolated` tento limit nemá a do `collecting`, `complete`, `conflict` ani `timed_out` nepřejde. Chybějící fragment se nulami nedoplňuje. Nejvyšší přijatý index se nepovažuje za důkaz, že zpráva je celá: bez `expected_count` nebo příznaku konce od zdroje sada do `complete` nepřejde.

### Scénář opožděného fragmentu

1. Přijde fragment s `group_key = G` a bez prokázaného `message_ref`. Dostane sadu 10 se stavem `isolated` a právě jeden logický fragment. Sada není `collecting` a dekodér ji nedostane.
2. Další fragment se stejným `group_key` se podle klíče nehledá a ke sadě 10 se nepřipojí. Dostane vlastní sadu 11, také `isolated`. Collecting sada nevznikne.
3. Další doručení se stejným `group_key`, `source_message_ref`, indexem, stejným i odlišným hashem, blízkým časem nebo identitou jednoho transportního přenosu ke sadě 10 nepatří. Vznikne nová sada `isolated` s právě jedním logickým fragmentem, řádkem `first` a vlastním `payload_id`. `repeat` se nepoužije. Odlišný hash sadu 10 na `conflict` nezmění, změněný obsah nepřijme a oba payloady zůstanou.
4. Když PoC prokáže rozsah `message_ref` a zdroj ho posílá na každém fragmentu, fragmenty se stejným prokázaným `message_ref` se skládají do jedné sady `collecting` před `deadline_at`. Fragment s jiným prokázaným `message_ref` se k ní nepřipojí. Dokud rozsah prokázaný není, `source_message_ref` sadu nespojí. Když prokázaný rozsah platí jen v rámci transportu, je transport součást identity.

`group_key` se tím nestává globálně jedinečným. Bez prokázaného `message_ref` se fragmenty podle něj neskládají, ani dokud žádná sada neskončila. Payload izolovaného fragmentu zůstane.

Rozlišení:

| Pojem | Co to je |
| --- | --- |
| identita pokusu o zprávu | `ingest_fragment_sets.id` |
| identifikátor od zdroje | `group_key`. Rozsah jedinečnosti není známý a ke skládání se nepoužije |
| prokázaná identita celé zprávy | `message_ref` sady, jen po PoC, který prokáže rozsah. Když rozsah platí jen v transportu, je transport součást identity. Jinak NULL. `source_message_ref` je text od zdroje a sady nespojuje |
| identita jednoho doručení fragmentu | řádek `ingest_fragments`: vlastní `payload_id`, index, sada, `received_at`, `delivery_role` |
| pořadí | `fragment_index` uvnitř jedné sady |
| opakované doručení fragmentu | U `collecting` s prokázaným `message_ref` je to další řádek `repeat` se stejným indexem a `content_hash`, vlastním `payload_id` a `received_at`. U `isolated` se `repeat` nepoužívá. Každé nové doručení bez prokázaného `message_ref` je nová sada `isolated`, jeden řádek `first` a vlastní `payload_id`. Shoda `group_key`, `source_message_ref`, indexu, hashe, času ani identity transportního přenosu sadu nepřiřadí a `repeat` nevytvoří. Odlišný hash je další `isolated`. Původní sada se na `conflict` nezmění, změněný obsah nepřijme a oba payloady zůstanou |
| nejednoznačný fragment | stav `isolated`. Právě jeden logický fragment, jeden řádek `first` a vlastní `payload_id`. Do `collecting`, `complete`, `conflict` ani `timed_out` nepřejde, `repeat` se nepoužije, jiný fragment nepřijme, dekodér ho nedostane |
| stavy skládání | `collecting`, `complete`, `conflict` a `timed_out` jen u sady s prokázaným `message_ref` |

Ochrana proti záměně:

- `group_key` je jen údaj od zdroje. Jeho shoda ani rozdíl samy o sobě neurčují identitu zprávy ani příslušnost fragmentu k sadě,
- příslušnost fragmentu ke skládané sadě určuje jen prokázaný `message_ref` v jeho prokázaném rozsahu. Fragment jiného prokázaného `message_ref` je jiná sada,
- když je `message_ref` prokázán a odpovídá existující sadě `collecting`, samotný rozdíl `group_key` není důvod k odmítnutí fragmentu ani k založení jiné sady,
- když `message_ref` prokázán není, každé nové doručení vytvoří vlastní sadu `isolated` bez ohledu na shodu či rozdíl `group_key`,
- fragment jiného `ingest_source_id` se do sady nepřipojí, i když uvede stejné `group_key`,
- v `collecting` sadě s prokázaným `message_ref` je stejný index a `content_hash` řádek `repeat` a počet odečtů se nemění; jiný hash je `conflict` a sada se uzavře bez dekódování,
- doručení bez prokázaného `message_ref` se neskládá. Shoda `group_key`, `source_message_ref`, indexu, hashe, času ani identity transportního přenosu ho k existující sadě `isolated` nepřiřadí a `repeat` z ní neudělá,
- jiný `content_hash` u `isolated` není `repeat` ani `conflict`. Sada změněný obsah nepřijme, nové doručení je další `isolated` a oba payloady zůstanou,
- po `timed_out` sady s prokázaným `message_ref` platí větev kroku 4, vyhodnocená před `complete` a `conflict`: původní sada zůstane, doručení se nepřipojí, nevznikne `isolated` ani nová `collecting`, payload zůstane, neskládá se, dekodér ho nedostane a eviduje se jako nepřiřazené. U `complete` a `conflict` se fragment k sadě nepřipojí. R32 se na ně nevztahuje a další zacházení je otevřená otázka,

`INGEST_FRAGMENT_TIMEOUT` se číselně doplní, až PoC ukáže, jestli vybraný model vůbec fragmentuje, jestli posílá identifikátor celé zprávy, jaký má rozsah `group_key` a jak rychle zbytek posílá. Číslo se použije jen u skládané sady s prokázaným `message_ref`. Do výsledku PoC se `message_ref` ke skládání nepoužije a `group_key` ho nenahradí. ESP dávkuje celé rámce. Dávka není fragmentace a touto cestou nejde.

## Dekódované hodnoty (koncentrátory)

### Adaptér

- Pro každého partnera, včetně ACRIOS, převede formát na kanonický záznam `decoded`: `external_meter_ref`, `source_measured_at`, `source_time_kind`, `access_number` (pokud ho zdroj má), `reading_kind` a `values` s veličinou a jednotkou.
- Má verzi (`adapter_version`) a testy na vzorových zprávách, které dodal PoC nebo výrobce. Vzor, který PoC nepřinesl, se v testu nevymýšlí.
- Neznámé pole nebo jednotka znamená stav `invalid` s uloženým původním payloadem. Žádný odhad a žádný doplněný rámec.
- Neznámý `external_meter_ref` znamená stav `unknown_meter`. Pozorování se uloží (hodnoty a původní payload, ne rámec), aby šlo měřidlo po namapování přiřadit.
- Neznámý identifikátor koncentrátoru měřidlo ani zařízení nezaloží. Payload zůstane. Příjem má `device_attribution = unattributed`.

### Omezení dekódovaných dat

Bez rámce a bez `access_number` nelze:

- rozhodnout, že JSON a rádiový telegram jsou totéž vysílání,
- spočítat `frame_hash` ani doplnit RSSI, který zdroj neposlal,
- odlišit nový telegram se stejnou hodnotou od staršího podle času nebo podle shody hodnoty,
- použít okno W. To patří jen surovému rámci.

Korelace níže je proto jen záznam shody, ne sloučení odečtů.

### Idempotence a deduplikace

Šest věcí se nesmí slít do jednoho sloupce:

| Věc | Čím se pozná | Čím se nepozná |
| --- | --- | --- |
| zpráva | prokázané `(ingest_source_id, msg_key_namespace, msg_key)` | hash, `device_id`, čas, hodnota |
| položka | `(…, item_index)` v `ingest_message_keys` | ostatní položky téže zprávy |
| položka zprávy | prokázaná zpráva plus `item_index`, jinak `id` pozorování | `source_measured_at`, `content_hash` |
| doručení | `ingest_receipts.id` | shoda obsahu |
| měření, ze kterého vznikl odečet | `source_key = vobs:<decoded_observation_id>` | čas ani hodnota |
| čas měření | `source_measured_at` | není unikátní. Přesnost ACRIOS není známá |
| opakované doručení | prokázaná stejná zpráva a stejná položka | shoda času, hodnoty nebo hashe |
| nejistota stejného obsahu | stejný `content_hash`, stav `uncertain` | není `duplicate` a druhé pozorování nemaže |
| konflikt dvou hodnot | dvě různé položky, stejné měřidlo, stream a čas, jiná hodnota | nepřepíše původní odečet ani pozorování |

1. **Nová položka** vloží payload, příjem v měsíci `server_received_at` a nové `decoded_observations`. Pozorování se vloží dřív, než se zkouší odečet. `ON CONFLICT` na indexu odečtu pozorování nesmaže.
2. **Prokázané opakované doručení** je případ 1. Nové pozorování ani odečet nevznikne.
3. **Stejný `content_hash` bez prokázaného identifikátoru:** druhé pozorování zůstane se stavem `uncertain`. Není to `duplicate_delivery`. Druhý odečet nevznikne. První pozorování se nemění.
4. **Stejný text `msg_key` v jiném namespace:** stav `id_collision`. Pozorování se vloží. `delivery_count` se mezi transporty nesčítá. Když by druhý odečet byl další aktivní kumulativní bod ve stejném čase, platí index projekce a pozorování zůstane.
5. **Stejný čas a stejná hodnota** v nové položce: stav `unresolved`. Oba řádky zůstanou. Není to důkaz stejného měření.
6. **Stejný čas a jiná hodnota:** stav `conflict`. Původní odečet se nepřepíše. Druhé pozorování zůstane. Administrátor dostane upozornění.
7. **Stejná hodnota v jiném čase** a bez shody hashe, která by položku označila `uncertain`: dvě pozorování a dva odečty. Blízké časy se neslučují.
8. Index `meter_readings_vendor_time_guard` jen brání dvěma aktivním kumulativním bodům v jednom čase. Když insert odečtu narazí, vrátí se jen ten insert. Pozorování zůstane `unresolved`, `conflict` nebo `uncertain`.
9. Administrátor s auditem buď nechá jeden odečet a obě pozorování, nebo první odečet označí `superseded_at` a z druhého pozorování vznikne oprava. Dva aktivní kumulativní body ve stejném čase nevzniknou. R15 se tím nemění: člen dál vidí aktivní kumulativní stav.
10. `measurement_ref` se vyplní jen identifikátorem, který zdroj skutečně poslal. Unikátní constraint na něm není, dokud PoC neukáže jeho rozsah.
11. Pravidla platí uvnitř jednoho streamu. `vendor:acrios` a `vendor:<jiný kód>` se neslučují. Dva koncentrátory téhož partnera sdílejí stream `vendor:<kód>`. Jejich příjmy zůstávají oddělené podle `ingest_source_id`.

Dokud není pozorování `accepted`, odečet nevznikne. Spotřeba a hodnota pro R15 se tím nepohnou. Původní pozorování zůstane dohledatelné po dobu retence pozorování. Souhrn původu odečtu, který vznikl, je v `reading_provenance`.

### Korelace se surovými telegramy

Stejné rádiové vysílání může přijmout ESP (raw) i koncentrátor (decoded), a to i když oba nesou značku ACRIOS. Raw a decoded se **neslučují do jednoho odečtu**, protože bez ACC a rámce nejde bezpečně rozhodnout, že jde o stejný telegram. Koncentrátor, který předá rámec, je ve streamu `radio` a slučuje se podle `frame_hash`. Koncentrátor, který předá jen hodnoty, je ve `vendor:<kód>`.

- Každý stream má vlastní odečty.
- Shoda se zaznamená jen v tomto případě: dekódovaná data obsahují čas z hodin měřidla nebo ACC a stejné měřidlo má odečet z rádia se stejným časem nebo ACC a stejnou hodnotou. Odečty se propojí jako vzájemné potvrzení, žádný se nesmaže.
- Korelace slouží ke kontrole kvality a jako podklad pro přechod zdroje.

## Preferovaný zdroj

Každé měřidlo má v každém okamžiku právě jeden přiřazený stream (`meter_source_assignments`). Výpočet spotřeby a postup přechodu popisuje [database-design.md](database-design.md#zdroje-odečtů).

- Ingest ukládá odečty ze všech streamů. Přiřazení rozhoduje jen o tom, co se použije pro spotřebu, grafy a pohled člena.
- Mezery přiřazeného streamu se **nedoplňují** z jiného streamu. Přes mezeru se spotřeba spočítá z kumulativních hodnot přiřazeného streamu a interval se označí.
- Systém zdroj sám nepřepíná. Když přiřazený stream mlčí déle než `SOURCE_SILENCE_ALERT` (návrh 24 h) a jiný stream měřidlo dodává, vznikne anomálie s návrhem přechodu.
- Přechod se navazuje na poslední kumulativní stav starého streamu a první stav nového. Nesplněné kontroly přechod zablokují do potvrzení administrátorem. Vše jde do auditu.

## Dekódování

- Worker bere `decode_queue` přes `FOR UPDATE SKIP LOCKED` a volá zafixovaný `wmbusmeters` jako podproces s hex telegramem, driverem a klíčem z dešifrovaného úložiště. Výstup je JSON. Řádek fronty vložil přijímající proces. Worker ho po vyčerpání pokusů smaže.
- Klíč AES se dešifruje jen v paměti workeru a nedostane se do argumentů procesu ani do logů. Předá se přes stdin, nebo přes dočasný soubor s právy `600` v tmpfs. Konkrétní způsob ověří PoC.
- Čas odečtu (`measured_at`):
  - čas z hodin měřidla, pokud ho telegram obsahuje a je věrohodný (`time_basis = meter_clock`),
  - jinak `anchor_at` telegramu (`capture_estimate`).
- **Kontroly věrohodnosti** proti efektivní řadě téhož streamu:
  - kumulativní hodnota neklesá,
  - přírůstek nepřekročí `max_flow_per_hour`.

  Porušení znamená `quality = suspect`, příznak a anomálii. Odečet se uloží, ale do spotřeby se nezapočte, dokud administrátor nevyplní `accepted_at`. Hodnota se tím nemění.
- `decoder_version` a u dat z adaptéru i `adapter_version` se ukládají k odečtu v okamžiku, kdy hodnota vznikla. Opětovné dekódování je případ 5 v [Pět případů, které se nesmí slít](#pět-případů-které-se-nesmí-slít): druhý aktivní odečet nevznikne.
- Výsledky: `decoded`, `no_key`, `failed`.

## Monitoring zařízení

- `devices.last_seen_at` se aktualizuje při každé zprávě a heartbeatu.
- Worker každou minutu označí zařízení jako `offline`, když heartbeat chybí déle než trojnásobek intervalu. Zapíše událost a vloží notifikaci.
- Heartbeat obsahuje:
  - hloubku fronty a nejstarší neodeslanou zprávu,
  - počet zahozených zpráv,
  - verzi firmware,
  - sílu signálu,
  - stav NTP,
  - počet odfiltrovaných neznámých měřidel.
- Administrace ukazuje u každého měřidla přiřazený stream a zařízení, která ho naposledy zachytila. U každého zařízení ukazuje frontu, boot, epochu a posun hodin, pokud je zařízení posílá.
- U koncentrátoru, který heartbeat ve tvaru ESP neposílá, se poslední kontakt bere z posledního příjmu na jeho transportech. Pole fronty a `rx_uptime` se pro něj nevyplňují. Verze firmware z payloadu, když v něm je, se zapíše do `device_firmware_history`. Jak vypadá stavová zpráva ACRIOS, určí PoC.

## Testy

- **Simulátor zařízení** (MQTT i HTTPS) přehrává zaznamenané skutečné telegramy včetně zpoždění, výpadků, ztracených ACK, restartů a výpadku collectoru při zaplněné frontě brokeru.
- **Deduplikace:**
  - paralelní transakce, dvě i více zařízení se stejným telegramem: jeden telegram, N příjmů, jeden odečet,
  - stejný `msg_key` dvou různých `ingest_source_id` jsou dvě zprávy,
  - stejný text `msg_key` na MQTT a HTTPS při `msg_key_scope = transport` jsou dvě doručení a stav `id_collision`,
  - stejný `content_hash` bez prokázaného identifikátoru je `uncertain`, dvě pozorování a žádné tiché sloučení,
  - přetočení `access_number`, stejné hodnoty v různých telegramech,
  - pozdní doručení: příjem leží v měsíci svého `server_received_at`, i když telegram má starší `partition_month`, a na telegram není cizí klíč,
  - kotva `server_only` se shodou do 60 dní nepřipojí příjem ke staršímu telegramu a odečet nezaloží,
  - `server_only` bez shody odečet nezaloží,
  - `suspect_replay` se od `probable_duplicate` liší a taky odečet nezaloží,
  - property-based testy (Hypothesis).
- **Čas:**
  - opakované odeslání téže položky v různých časech dává stejný `captured_at_est`,
  - položka z předchozího bootu,
  - broker držel dávku hodinu,
  - hodiny zařízení v budoucnosti,
  - regrese `boot_counter`,
  - nové `instance_id` po vymazání flash.
- **Idempotence:** opakované `evaluate_item` stejné TX1 trojice vrátí stejný receipt short-circuitem (bez dalšího zápisu). `sjv_ingest.recovery` vybere `ingest_payload_items` bez receiptu a volá totéž `evaluate_item`; one-shot CLI je `python -m sjv_ingest.recovery`. Periodický worker / timer a historický backfill nejsou. Ztracený ACK po COMMIT TX2 vede k novému transportnímu doručení přes `accept` (nový `payload_id`); při shodném prokázaném `msg_key` a `item_index` je další příjem `duplicate_delivery` a `delivery_count` + 1 — oddělená cesta od TX1 recovery. Dvě položky jednoho `msg_key` se při prvním doručení obě zpracují. Souběžné evaluate stejné TX1 položky nechají jeden receipt. Stejné tělo bez identifikátoru má druhé pozorování.
- **Fragmenty:** každé nové doručení fragmentu bez prokázaného `message_ref` dostane vlastní sadu `isolated`, nikdy `collecting`, jeden řádek `first`, vlastní `payload_id` a dekodér ho nedostane. Není to `repeat`. Stejný `group_key`, `source_message_ref`, index, hash, čas ani identita jednoho transportního přenosu ho k existující sadě nepřiřadí. Test, který by z toho udělal `repeat`, selže. Shoda indexu a hashe sama `repeat` nevytvoří. Odlišný hash u `isolated` `conflict` nevytvoří: vznikne další `isolated`, původní sada změněný obsah nepřijme a oba payloady zůstanou. `repeat` a `conflict` vzniknou jen v `collecting` sadě s prokázaným `message_ref`: stejný index a `content_hash` je další řádek `repeat` s vlastním payloadem a časem, jiný hash je `conflict` jen v této sadě. Neúplná prokázaná sada a timeout jen u ní. Fragment cizího `ingest_source_id` se nepřipojí. Samotný rozdíl `group_key` při shodném prokázaném `message_ref` existující sady `collecting` fragment neodmítne a jinou sadu nezaloží. Bez prokázaného `message_ref` vlastní `isolated` vznikne i při rozdílném `group_key`. Po `timed_out` se další fragment k této sadě nepřipojí, původní sada se nezmění, nové doručení s prokázaným `message_ref` nevytvoří `isolated` ani novou `collecting`, jeho payload zůstane, dekodér ho nedostane a eviduje se jako nepřiřazené. Dva souběžné vklady prokázaného `message_ref` nezaloží dvě otevřené `collecting` sady a fragment nezahodí. `message_ref` bez zapsaného rozsahu sadu nespojí. `source_message_ref` samo sadu nespojí. Retence smaže fragment dřív než sadu, na kterou ještě ukazuje.
- **Dekódovaná data:** opakované poslání prokázaného identifikátoru, stejný hash bez identifikátoru jako `uncertain` se dvěma pozorováními, stejný čas a stejná hodnota jako `unresolved`, stejný čas a jiná hodnota jako `conflict`. V obou konfliktech zůstanou obě pozorování a druhý odečet nevznikne. Stejná hodnota v jiném čase jsou dva odečty. Korelace s rádiem bez sloučení, JSON bez vyrobeného rámce.
- **Pět případů:** opakované doručení prokázaného identifikátoru, dva koncentrátory se stejným rámcem, nový telegram se stejnou hodnotou a jiným `access_number`, fragmenty s prokázaným `message_ref` jako jedna sada `collecting` a každé doručení bez něj jako nová sada `isolated`, ne jako `repeat`, opětovné dekódování se stejnou i jinou hodnotou. Deduplikace podle samotné hodnoty, samotného času nebo samotného hashe musí v testu selhat, pokud by sloučila různá měření.
- **Identita zařízení:** výměna IMSI ponechá `device_id` a historii. Stejné IMSI u jiného zařízení je konflikt a zařízení se nezaloží z těla zprávy.
- **Preferovaný zdroj:**
  - přechod s úspěšnou kontrolou,
  - zablokovaný přechod (pokles hodnoty, nereálný průtok),
  - přechod do minulosti s přepočtem,
  - souběžné odečty dvou streamů nikdy nezdvojí spotřebu.
