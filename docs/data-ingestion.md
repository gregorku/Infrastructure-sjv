# Příjem dat

PostgreSQL je jediný dlouhodobý zdroj pravdy pro data SJV (rozhodnutí 15–30 v [decisions.md](decisions.md)). Každý vstup skončí v modelu z [database-design.md](database-design.md). Adaptér výrobce data jen převede na interní kontrakt. Tabulka odečtů pro ACRIOS ani pro jiný transport nevzniká.

ACRIOS je podporovaný integrační partner. Konkrétní model, revize hardwaru a transport nejsou vybrané. Návrh nepředpokládá, že všechny modely ACRIOS umí stejné formáty nebo protokoly. Dokud to neověří PoC ([implementation-plan.md](implementation-plan.md)), platí pro ACRIOS jen pravidla společná všem zdrojům.

Sběrná zařízení navazují spojení směrem k VPS. Výjimka je dotaz na cizí API, který navazuje server. Návrh počítá s mobilním CGNAT a nepředpokládá veřejnou IP zařízení. WireGuard pro příjem odečtů potřeba není.

Tabulky jsou v [database-design.md](database-design.md), firmware vlastního ESP v [firmware-design.md](firmware-design.md), bezpečnost příjmu v [security.md](security.md).

## Vstupní zdroje

| Zdroj | Transport | Co je známé | Kam patří odečet |
| --- | --- | --- | --- |
| ACRIOS MQTT | MQTT/TLS | model a topics až po PoC | `radio`, pokud payload obsahuje rámec; jinak `vendor:acrios` |
| ACRIOS UDP/DTLS | UDP | až PoC, včetně toho, jestli daný model DTLS má | podle skutečného payloadu, stejně jako u MQTT |
| ACRIOS HTTPS | HTTPS | až PoC | podle skutečného payloadu |
| ACRIOS Platform API | odchozí HTTPS serveru | až PoC. Přímé připojení bez platformy je samostatná otázka PoC | podle toho, co API vrací |
| vlastní ESP32/LILYGO | MQTT/TLS a záložní HTTPS | tento dokument | `radio` |
| jiný budoucí koncentrátor | podle svého adaptéru | stejná pravidla, vlastní kód `vendor:<kód>` jen pro data bez rámce | `radio` nebo `vendor:<kód>` |
| ruční import CSV nebo jiného podporovaného souboru | `file_import` | konkrétní rozložení souboru až s adaptérem | stream `import` |

Jeden kus hardwaru může mít víc transportů. Schopnosti se zapisují do `device_capabilities` podle zjištění. Z názvu výrobce se neodvozují.

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
- instalace měřidla (`meter_installations`),
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
| message_kind | `raw_wmbus`, `decoded`, `event`, `heartbeat`, `import_row` |
| msg_key | idempotence doručení, viz [Identita zprávy](#identita-zprávy) |
| external_message_id | identifikátor výrobce, jen když v datech je |
| capture | jen časové údaje, které zdroj skutečně poslal |
| frame | jen skutečný wM-Bus rámec |
| decoded | hodnoty včetně veličiny, jednotky a druhu `cumulative`, `interval` nebo `event` |
| fragment | identifikace celé zprávy, pořadí a počet nebo příznak konce, jen když to zdroj označil |
| payload_id | nezměněná obálka |
| adapter, adapter_version | verze, která položku oddělila |

Heartbeat a událost nevytvářejí odečet. `import_row` vytvoří odečet se `source_kind = import` až po validaci řádku. Neplatný řádek je příjem `invalid` a původní text řádku zůstane v payloadu.

## Dva druhy dat

| Druh | Obsah | Typický zdroj | Stream | Cesta v systému |
| --- | --- | --- | --- | --- |
| `raw` | skutečný wM-Bus rámec | vlastní ESP, kterýkoli koncentrátor, který rámec předá | `radio` | `ingest_payloads` → `ingest_receipts` → `raw_telegrams` → dekódování → `meter_readings` |
| `decoded` | hodnoty, které už dekódoval zdroj | koncentrátor nebo API bez rámce, import souboru | `vendor:<kód>` nebo `import` | `ingest_payloads` → `decoded_observations` → `meter_readings` |

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

`partition_month` příjmu, payloadu tohoto příjmu a `decoded_observations` je měsíc `server_received_at` nebo `received_at`. `partition_month` telegramu je měsíc kotvy. Příjem z prosince 2028, který odkazuje na telegram z ledna 2027, leží v prosinci 2028. Lednová identita telegramu je ve sloupcích `raw_telegram_id` a `raw_partition_month` a není to cizí klíč. Retence příjmu je 24 měsíců od prosince 2028. Retence telegramu je 24 měsíců od ledna 2027. Limity stáří a budoucnosti dál rozhodují, jestli z příjmu smí vzniknout odečet. Neříkají, do které partition se příjem uloží.

### Replay

| Situace | Ochrana |
| --- | --- |
| stejná položka znovu (ztracený ACK, `replay_since`) | prokázaný `PRIMARY KEY (ingest_source_id, msg_key_namespace, msg_key, item_index)` → `duplicate_delivery` jen této položky. Hash těla tento stav nezaloží |
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
sjv/v1/dev/{device}/events      zařízení → server   QoS 1      boot, chyby, přetečení fronty
sjv/v1/dev/{device}/heartbeat   zařízení → server   QoS 0      stav a časová reference
sjv/v1/dev/{device}/status      zařízení → server   retained   LWT "offline"
sjv/v1/dev/{device}/ack         server → zařízení   QoS 1      výsledek po COMMIT
sjv/v1/dev/{device}/config      server → zařízení   retained   konfigurace zařízení
```

`{device}` je kód zařízení (`ESP-SJV-001`). Je zároveň uživatelským jménem a client ID v Mosquitto Dynamic Security. Topics ACRIOS nejsou tyto topics. Jejich podoba není známá a do konfigurace se doplní až po PoC. Do té doby účet ACRIOS v brokeru není.

### ACL

- **Zařízení** (vlastní role pro každé zařízení):
  - publikovat smí jen do `telegrams`, `readings`, `events`, `heartbeat` a `status` svého kódu,
  - odebírat smí jen `ack` a `config` svého kódu,
  - výchozí politika je zakázat vše. `$CONTROL/#` a `$SYS/#` zařízení nevidí,
  - client ID musí odpovídat jménu, takže si zařízení nemůže převzít cizí sezení.
- **Collector:** odebírá `sjv/v1/dev/+/telegrams|readings|events|heartbeat|status`, publikuje `sjv/v1/dev/+/ack|config`. Připojuje se jen přes interní listener 1883.
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
  "heartbeat_s": 60, "batch_max": 50, "ack_timeout_s": 30,
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
| `accepted` | nový telegram nebo pozorování, ze kterého smí vzniknout odečet |
| `duplicate` | potvrzená shoda uvnitř `dedup_window`. Příjem je připojený k existujícímu telegramu |
| `probable_duplicate` | rámec je uložený jako vlastní telegram `ambiguous`. Ke staršímu telegramu připojený není a odečet nevznikl |
| `needs_review` | rámec je uložený, shoda se nenašla a bez důvěryhodné kotvy odečet nevznikl |
| `duplicate_delivery` | prokázanou položku `(ingest_source_id, msg_key_namespace, msg_key, item_index)` už server má. Ostatní položky zprávy tento stav sám neuzavře |
| `uncertain` | stejný `content_hash` bez prokázaného identifikátoru. Pozorování zůstalo, odečet z něj nevznikl |
| `id_collision` | stejný text `msg_key` v jiném namespace. Doručení se nesloučila |
| `suspect_replay` | uloženo jen jako příjem a telegram bez fronty dekódování, bez odečtu |
| `unknown_meter` | měřidlo není evidované, rámec se neuložil |
| `invalid` | CRC, formát nebo nekonzistentní časy |
| `too_old` | starší než `INGEST_MAX_MESSAGE_AGE` |
| `unresolved` | pozorování je uložené. Stejný čas ve streamu už má aktivní kumulativní odečet a druhý se nezaložil |
| `conflict` | pozorování je uložené s jinou hodnotou. Původní odečet se nezměnil |

Zařízení smaže zprávu z fronty až tehdy, když má uložený výsledek každá její položka. Jedna položka ve stavu `duplicate_delivery` ostatní položky nepotvrzuje. U ESP má položka fronty vlastní `msg_key`. U zprávy s více položkami pod jedním `msg_key` odpověď vypíše každý `item_index` a jeho stav. Stav `accepted` znamená uložený výsledek této položky, ne to, že z každé položky vznikl odečet. `probable_duplicate`, `needs_review`, `uncertain` a `id_collision` se do `duplicate` neskládají. Bez kompletního ACK zařízení po timeoutu pošle znovu stejný `msg_key` a stejné údaje `rx`.

### Doručení až po COMMIT

1. Collector má persistentní sezení (`clean_start = false`, QoS 1) a ruční PUBACK. Podpora ručního PUBACK v paho-mqtt 2.x (`manual_ack`) se ověří v PoC.
2. PUBACK brokeru i aplikační ACK zařízení se odešlou až po COMMIT transakce.
3. Když collector spadne před COMMIT, broker zprávu doručí znovu. Když spadne po COMMIT a před ACK, zařízení zprávu pošle znovu a `ingest_message_keys` vrátí `duplicate_delivery`.
4. Později lze přidat více collectorů přes `$share/collectors/...`. Idempotence je v DB, ne v paměti collectoru.

## HTTPS ingest

| Metoda a cesta | Obsah |
| --- | --- |
| `POST /api/v1/ingest/telegrams` | dávka raw, stejný formát jako MQTT |
| `POST /api/v1/ingest/readings` | dávka decoded: kanonický formát, nebo formát dodavatele přes adaptér |
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

Jedna přijatá zpráva je jedna databázová transakce a zpracuje všechny své položky. Samostatná transakce jedné položky by při existujícím klíči zprávy ostatní položky přeskočila. Evidence zpracování je po položkách: primární klíč obsahuje `item_index`.

```text
BEGIN
  Rozděl payload na položky 0 .. n-1 v pořadí zdroje.
  Prázdný seznam je invalid celé obálky: jeden příjem, COMMIT, ACK invalid.
  Když je identifikátor prokázaný:
    pg_advisory_xact_lock na (ingest_source_id, msg_key_namespace, msg_key)
    ještě před první položkou. Dva workery neprojdou stejným klíčem současně.
  Pro každou položku i, v pořadí:
    SAVEPOINT item_i
    content_hash = sha256(kanonické tělo položky i). Do msg_key se neukládá.
    1. Jen prokázaný identifikátor:
       INSERT INTO ingest_message_keys
           (ingest_source_id, msg_key_namespace, msg_key, item_index = i, …)
       ON CONFLICT (ingest_source_id, msg_key_namespace, msg_key, item_index)
           DO NOTHING
       → nic nevloženo: opakované doručení jen položky i.
          INSERT ingest_receipts (
            partition_month = měsíc tohoto server_received_at,
            status = duplicate_delivery, item_index = i,
            content_hash, ingest_source_id, msg_key, msg_key_namespace,
            server_received_at = čas tohoto doručení)
          Odkaz na dřívější telegram nebo pozorování není cizí klíč.
          UPDATE ingest_message_keys
            SET delivery_count = delivery_count + 1,
                last_received_at = čas tohoto doručení
          RELEASE SAVEPOINT. Další položka se zpracuje.
          Telegram, pozorování ani odečet této položky se nevkládá.
       → identifikátor není prokázaný: klíč se nevloží a krok 1 není
          duplicate_delivery, ani když content_hash už v databázi je.
    2. validace časů a výpočet captured_at_est, time_source, time_uncertainty_ms
       → too_old nebo invalid: receipt této položky, bez telegramu.
          Doplň outcome klíče, když v kroku 1 vznikl. Další položka.
    3. normalizace → při chybě receipt crc_error nebo invalid této položky.
       Další položka.
    4. lookup meters podle meter_key → neznámé: upsert unknown_meter_sightings,
       receipt unknown_meter bez rámce. Další položka.
    5. time_source = server_only, nebo nejistota větší než polovina dedup_window
       → postup "Kotva server_only". telegram_dedup_keys se nevkládá.
       INSERT raw_telegrams a ingest_receipts této položky,
       případně ingest_dedup_candidates.
       Odkaz na cizí telegram není cizí klíč. Další položka.
    6. raw_telegram_id := nextval('raw_telegrams_id_seq')
       raw_partition_month := měsíc captured_at_est
    7. INSERT INTO telegram_dedup_keys ( … ) ON CONFLICT DO NOTHING
       a) vloženo: suspect_replay, nebo pending a decode_queue, plus raw_telegrams
       b) konflikt: připoj k existujícímu telegramu, status příjmu = duplicate
    8. INSERT ingest_receipts této položky do měsíce server_received_at
    9. Když v kroku 1 vznikl klíč této položky:
       UPDATE ingest_message_keys
           SET outcome = stav této položky,
               receipt_id, receipt_partition_month, delivery_count = 1
    Logický stav položky transakci nekončí. RELEASE SAVEPOINT item_i.
    Neočekávaná chyba databáze: ROLLBACK TO SAVEPOINT item_i.
       Položka i uložený výsledek nemá. Smyčka skončí.
  Když některá položka uložený výsledek nemá:
    ROLLBACK celé transakce. ACK se neposílá.
    Zařízení zprávu pošle znovu. Nic z tohoto pokusu nezůstane,
    takže se žádná položka neoznačí jako duplicate_delivery omylem.
  Jinak COMMIT.
ACK až po COMMIT. Odpověď má jeden záznam na každou položku a její stav.
```

Logické selhání jedné položky (`invalid`, `unknown_meter`, `too_old`, `probable_duplicate`, `needs_review`) uloží její příjem a pokračuje na další. Nevyřadí sourozence a nevrátí jejich práci. Zařízení smí frontu smazat až po ACK, ve kterém má uložený výsledek každá položka. `duplicate_delivery` v tom seznamu platí jen pro položku, jejíž klíč už existoval. Stejný `content_hash` bez prokázaného identifikátoru tímto krokem neprojde.

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
| 13:10:03 | ACK se ztratí, ESP pošle F znovu se stejným `msg_key` a stejným `rx` | `duplicate_delivery`, další příjem, žádný nový telegram ani odečet |

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
| 1. Opakované doručení stejné položky | prokázané `(ingest_source_id, msg_key_namespace, msg_key, item_index)` | další `ingest_receipts` se stavem `duplicate_delivery` jen této položky, žádný nový odečet. Ostatní položky prvního doručení se zpracují. Stejný hash bez identifikátoru tento případ není |
| 2. Stejný telegram, víc zdrojů | jiné `ingest_source_id` nebo jiný identifikátor, stejné `(meter_key, access_number, frame_hash)` uvnitř `dedup_window` a důvěryhodná kotva | jeden `raw_telegrams`, N příjmů v měsících svých přijetí, jeden odečet `raw:<raw_telegram_id>` |
| 3. Nový telegram se stejnou hodnotou | jiné `access_number` nebo jiný `frame_hash`; u dat bez rámce jiné tělo, nebo stejné tělo bez prokázaného identifikátoru | nový telegram nebo nové pozorování. Shoda hodnoty, času nebo hashe zprávy nespojí |
| 4. Fragmenty jedné zprávy | jedna sada `ingest_fragment_sets.id` a prokázané `message_ref`, nebo jediná ještě neuzavřená sada bez něj | žádný odečet, dokud sada není `complete`. Po uzavření se fragment se stejným `group_key` k nové sadě nepřipojí. Bez `message_ref` se izoluje |
| 5. Nové dekódování starých dat | stejný `source_key`, jiná `decoder_version` nebo `adapter_version` | druhý aktivní odečet nevznikne. Shoda hodnoty jen audit. Jiná hodnota je oprava, která původní řádek označí `superseded_at` |

Případ 1 nastane jen u prokázaného identifikátoru. Dvě doručení téhož těla bez něj jsou dvě položky se stavem `uncertain`. Stejný text `msg_key` jiného `ingest_source_id` nebo jiného `msg_key_namespace` je jiná zpráva. Když jde o dva transporty téhož zařízení, pozdější příjem je `id_collision`.

U dekódovaných dat bez rámce čas měření identita není. Může mít hrubé rozlišení a víc položek ho může sdílet. Pravidla jsou v [Idempotence a deduplikace](#idempotence-a-deduplikace). Časy se nesbližují heuristikou. Jestli ACRIOS posílá stabilní čas a s jakou přesností, ukáže PoC.

Opětovné dekódování (případ 5):

- slepý opakovaný běh narazí na `UNIQUE (source_key)` a řádek nevloží,
- řízený běh nové verze porovná nový výstup s uloženou hodnotou,
- stejná hodnota: odečet se nemění, audit dostane `redecode_unchanged` se starou a novou verzí,
- jiná hodnota: vznikne řádek `correction` s novou verzí, původní dostane `superseded_at`, důvod je `decoder_upgrade`. Oba aktivní nezůstanou.

## Fragmentace

Fragment není položka dekodéru. Dekodér a deduplikace telegramu dostanou až složený payload sady ve stavu `complete`.

Postup jednoho fragmentu:

```text
BEGIN
 1. ingest_source_id je dané účtem nebo koncovým bodem. Bez něj se sada nezaloží
    (odmítnutí fragment_unidentified). device_id je jen atribuce a smí chybět.
    Payload tohoto doručení se uloží vždy, dřív než se hledá sada.
 2. group_key a fragment_index musí přijít od zdroje. Když chybí, payload zůstane,
    ingest_rejections.reason = fragment_unidentified, COMMIT. Sada nevznikne.
    group_key se nepovažuje za globálně jedinečné a adaptér k němu nepřidává předponu.
    source_message_ref se uloží na fragment, když ho zdroj poslal.
    message_ref sady se vyplní jen při prokázaném rozsahu. Jinak je NULL
    a text od zdroje sadu nespojí.
 3. pg_advisory_xact_lock na (ingest_source_id, zámek).
    Zámek je prokázané message_ref, a když rozsah zahrnuje transport, i transport.
    Bez prokázaného rozsahu je zámek group_key.
    Zámek drží do COMMIT, takže dva procesy nezaloží dvě otevřené sady.
 4. message_ref je prokázané:
       najdi collecting sadu se stejným rozsahem a message_ref.
       našla se: připoj fragment k ní.
       nenašla se a existuje ukončená sada s tímto message_ref:
          izoluj. K jiné sadě se stejným group_key se nepřipojuj.
       nenašla se žádná: SAVEPOINT set_insert, INSERT collecting s tímto message_ref a group_key.
    message_ref není prokázané:
       existuje ukončená sada se stejným (ingest_source_id, group_key),
       nebo je otevřená sada a fragment k ní nelze bezpečně přiřadit:
          izoluj. Novou collecting sadu nezakládej a k otevřené se nepřipojuj.
       collecting sada bez message_ref existuje a žádná starší sada tohoto
       group_key ještě neskončila: připoj fragment.
       žádná sada není: SAVEPOINT set_insert, INSERT první collecting sady.
    Jedinečný index collecting sady je pojistka zámku.
    unique_violation: ROLLBACK TO SAVEPOINT set_insert, znovu SELECT vítězné sady.
       Vítěz je stejná identita a pořád collecting před deadline_at: připoj k němu.
       Vítěz má jiné message_ref, už není collecting, nebo rozsah není prokázaný
       a pravidlo říká izolovat: izoluj. Fragment ani jeho payload se nezahodí.
       K jiné sadě se nepřipojí.
 5. Izolace: nová sada status = isolated, řádek fragmentu delivery_role = first,
    payload zůstane. Sada se neskládá a dekodér se nevolá. COMMIT.
 6. Připojení:
       index v sadě ještě nemá řádek first:
          INSERT ingest_fragments delivery_role = first, vlastní payload_id.
       stejný content_hash: další řádek delivery_role = repeat,
          vlastní payload_id a received_at. Řádek first se nemění.
       jiný hash: další řádek delivery_role = conflict, sada conflict,
          ingest_rejections fragment_conflict. Řádek first a jeho payload zůstanou.
          Dekodér se nevolá.
 7. Když fragmenty uvádějí různý expected_count, sada je conflict a dál se neskládá.
 8. Když jsou přítomné všechny indexy 0 .. expected_count-1 jako řádky first
    (nebo zdroj označil konec a indexy tvoří souvislou řadu od nuly):
       slož bajty řádků first v pořadí indexů do ingest_payloads, origin = assembled,
       sada complete,
       složený payload vstupuje jednou do transakce přijaté zprávy.
       msg_key složené zprávy je message_ref, jen když je prokázaný rozsah.
       Hash složeného těla msg_key není.
COMMIT
```

Neúplná sada zůstane `collecting`. Worker po `deadline_at` nastaví `timed_out`, zapíše `ingest_rejections` s důvodem `fragment_timeout` a dekodér nezavolá. Chybějící fragment se nulami nedoplňuje. Nejvyšší přijatý index se nepovažuje za důkaz, že zpráva je celá: bez `expected_count` nebo příznaku konce od zdroje sada do `complete` nepřejde.

### Scénář opožděného fragmentu

1. Sada 10 má `group_key = G`, `message_ref` NULL a stav `timed_out`. Chybí jí fragment 2.
2. Další fragment s `group_key = G` collecting sadu nezaloží. Bez `message_ref` by nešlo poznat, jestli patří k sadě 10, nebo k nové zprávě.
3. Fragment 2 staré zprávy přijde až potom. Uloží se jako sada 11 se stavem `isolated`. K sadě 10 se nepřipojí, žádnou otevřenou sadu nedoplní a nedekóduje se.
4. Fragmenty novější zprávy, která umí poslat jen `G`, se izolují stejně, každý ve vlastní sadě. Nesloží se spolu, protože by se mezi nimi mohl schovat opožděný kus sady 10.
5. Když PoC prokáže rozsah `message_ref` a zdroj ho posílá na každém fragmentu, nová zpráva s jiným `message_ref` má vlastní collecting sadu. Opožděný fragment se starým `message_ref` se k ní nepřipojí a izoluje se. Dokud rozsah prokázaný není, text od zdroje sadu nespojí.

`group_key` se tím nestává globálně jedinečným. Cena je, že bez prokázaného `message_ref` se po první ukončené sadě další zpráva se stejným klíčem automaticky nesloží. Payload izolovaného fragmentu zůstane.

Rozlišení:

| Pojem | Co to je |
| --- | --- |
| identita pokusu o zprávu | `ingest_fragment_sets.id` |
| identifikátor od zdroje | `group_key`. Rozsah jedinečnosti není známý |
| prokázaná identita celé zprávy | `message_ref` sady, jen po prokázaném rozsahu. Jinak NULL. Text od zdroje je `source_message_ref` na fragmentu |
| identita jednoho doručení fragmentu | řádek `ingest_fragments`: vlastní `payload_id`, index, sada, `received_at`, `delivery_role` |
| pořadí | `fragment_index` uvnitř jedné sady |
| opakované doručení fragmentu | další řádek `repeat` se stejným indexem a stejným hashem. Původní payload zůstane |
| nejednoznačný fragment | stav `isolated`. K žádné jiné sadě se nepřipojí |

Ochrana proti záměně:

- fragment jiného `group_key` nebo jiného `message_ref` je jiná sada,
- fragment jiného `ingest_source_id` se do sady nepřipojí, i když uvede stejné `group_key`,
- opakovaný fragment se stejným hashem počet odečtů nemění,
- konflikt hashů sadu uzavře bez dekódování,
- po `timed_out` se další fragment bez `message_ref` nepřipojí k nové ani ke staré sadě.

`INGEST_FRAGMENT_TIMEOUT` se číselně doplní, až PoC ukáže, jestli vybraný model vůbec fragmentuje, jestli posílá identifikátor celé zprávy, jaký má rozsah `group_key` a jak rychle zbytek posílá. ESP dávkuje celé rámce. Dávka není fragmentace a touto cestou nejde.

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

- Worker bere `decode_queue` přes `SKIP LOCKED` a volá zafixovaný `wmbusmeters` jako podproces s hex telegramem, driverem a klíčem z dešifrovaného úložiště. Výstup je JSON.
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
- **Idempotence:** opakované doručení prokázaného `msg_key` a `item_index` po ztraceném ACK. Druhé doručení má příjem `duplicate_delivery` a stejný počet odečtů. Dvě položky jednoho `msg_key` se při prvním doručení obě zpracují. Logické selhání první neukončí druhou. Stejné tělo bez identifikátoru má druhé pozorování.
- **Fragmenty:** neúplná sada, opakovaný fragment se stejným hashem jako další řádek s vlastním payloadem, fragment s jiným hashem, fragment cizího `group_key` nebo cizího `ingest_source_id`, timeout. Po `timed_out` přijde fragment se stejným `group_key` a je `isolated`. K nové ani ke staré sadě se nepřipojí a dekodér ho nedostane. Dva souběžné vklady nezaloží dvě otevřené sady a fragment nezahodí. `message_ref` bez zapsaného rozsahu sadu nespojí. Retence smaže fragment dřív než sadu, na kterou ještě ukazuje.
- **Dekódovaná data:** opakované poslání prokázaného identifikátoru, stejný hash bez identifikátoru jako `uncertain` se dvěma pozorováními, stejný čas a stejná hodnota jako `unresolved`, stejný čas a jiná hodnota jako `conflict`. V obou konfliktech zůstanou obě pozorování a druhý odečet nevznikne. Stejná hodnota v jiném čase jsou dva odečty. Korelace s rádiem bez sloučení, JSON bez vyrobeného rámce.
- **Pět případů:** opakované doručení prokázaného identifikátoru, dva koncentrátory se stejným rámcem, nový telegram se stejnou hodnotou a jiným `access_number`, fragmenty, opětovné dekódování se stejnou i jinou hodnotou. Deduplikace podle samotné hodnoty, samotného času nebo samotného hashe musí v testu selhat, pokud by sloučila různá měření.
- **Identita zařízení:** výměna IMSI ponechá `device_id` a historii. Stejné IMSI u jiného zařízení je konflikt a zařízení se nezaloží z těla zprávy.
- **Preferovaný zdroj:**
  - přechod s úspěšnou kontrolou,
  - zablokovaný přechod (pokles hodnoty, nereálný průtok),
  - přechod do minulosti s přepočtem,
  - souběžné odečty dvou streamů nikdy nezdvojí spotřebu.
