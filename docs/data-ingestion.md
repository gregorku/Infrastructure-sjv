# Příjem dat

PostgreSQL je jediný dlouhodobý zdroj pravdy pro data SJV (rozhodnutí 15–19 v [decisions.md](decisions.md)). Každý vstup skončí v modelu z [database-design.md](database-design.md). Adaptér výrobce data jen převede na interní kontrakt. Tabulka odečtů pro ACRIOS ani pro jiný transport nevzniká.

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
- Opakované doručení stejného `msg_key` má další příjem `duplicate_delivery` a zvýší `delivery_count`. Nový odečet nevznikne.

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

- `device_id` se vždy bere z autentizace (MQTT účet, API token, klientský certifikát nebo PSK), nikdy z těla zprávy. U Platform API je autentizovaný koncový bod a koncentrátor uvnitř odpovědi se přiřadí jen přes už uložené `device_external_ids`.
- `msg_key` je idempotentní klíč doručení, unikátní v rámci jednoho `device_id`:
  - **vlastní ESP:** `<instance_id>-<boot_counter>-<seq>`.
    - `instance_id` je náhodné 64bitové číslo v hex. Vygeneruje se při prvním startu a znovu po každém vymazání flash, takže reset `boot_counter` nikdy nevytvoří klíč, který server už zná.
    - `boot_counter` je v NVS a roste při každém startu.
    - `seq` je čítač v RAM od nuly v každém bootu.
  - **koncentrátor včetně ACRIOS:** identifikátor zprávy, který zdroj skutečně posílá. Když ho PoC v datech nenajde, je klíč `sha256` kanonického těla položky. Formát identifikátoru se dopředu nepředepisuje.
  - **složená zpráva z fragmentů:** jeden `msg_key` celé zprávy, až když je sada úplná. Fragment vlastní `msg_key` odečtu nemá.

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

`partition_month` se počítá z výsledného `captured_at_est`. Díky limitům na budoucnost a stáří vždy padne do existující partition.

### Replay

| Situace | Ochrana |
| --- | --- |
| stejná zpráva znovu (ztracený ACK, `replay_since`) | `ingest_message_keys` → `duplicate_delivery`. Po vypršení klíče (60 dní) už zprávu odmítne `too_old` |
| stejný telegram jiným zařízením nebo v nové zprávě, v okně | deduplikace → `duplicate` |
| stejný obsah rámce mimo okno, do 60 dní | `suspect_replay`, bez odečtu, alarm |
| stejný obsah starší než 60 dní | `too_old`. U pozdější kopie, která se tváří jako čerstvá, ji zachytí kontrola monotónnosti kumulativní hodnoty a maximálního průtoku při dekódování |
| podvržená zpráva ze sítě | TLS a autentizace každého zařízení. Účet zařízení smí publikovat jen do svých topiců |
| rádiový replay (nahraný a znovu vyslaný telegram) | stejný rámec = stejný `frame_hash`. V okně se sloučí, mimo okno je to `suspect_replay` |

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
| `accepted` | nový telegram nebo pozorování |
| `duplicate` | telegram už existoval, příjem byl připojen. Patří sem i `probable_duplicate` |
| `duplicate_delivery` | tuto zprávu (`msg_key`) už server má |
| `suspect_replay` | uloženo jen jako příjem, bez odečtu |
| `unknown_meter` | měřidlo není evidované, rámec se neuložil |
| `invalid` | CRC, formát nebo nekonzistentní časy |
| `too_old` | starší než `INGEST_MAX_MESSAGE_AGE` |

Zařízení smaže zprávu z fronty po každém z těchto stavů. Bez ACK ji po timeoutu pošle znovu se stejným `msg_key` a stejnými údaji `rx`.

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
- **Platform API.** Server se dotazuje sám, z procesu na síti `sjv-egress`. Odpověď je payload `api_response`. Záznamy uvnitř se rozdělí adaptérem na položky kontraktu. Účet platformy není `device_id` koncentrátoru. Koncentrátor se pozná jen podle `device_external_ids`. Neznámý identifikátor zařízení nezaloží a příjem má `device_attribution = unattributed`.
- **Import souboru.** Celý soubor je jeden payload. Řádek, který projde validací, je položka `import_row` a odečet se `source_kind = import` a `source_key = import:<payload_id>:<řádek>`. Ruční odečet zadaný ve formuláři zůstává `manual` a souborem není.

## Deduplikace raw telegramů

### Cíle

- Každý příjem se eviduje zvlášť (`ingest_receipts`), včetně opakovaného doručení stejného `msg_key`.
- Stejný rádiový telegram zachycený více zařízeními, nebo opakovaně jedním v nové zprávě, má jeden `raw_telegrams` a nejvýš jeden aktivní odečet.
- Dva různé telegramy se stejnou hodnotou spotřeby se nesloučí. Stejná hodnota není deduplikační klíč.
- Deduplikace funguje pro opožděné doručení z fronty ESP, i když jiný přijímač poslal stejný telegram už dříve, a funguje při souběžném zpracování.
- Pravidla jsou společná pro ESP i pro každý koncentrátor, který předá skutečný rámec, včetně budoucího ACRIOS. Zařízení, které předá jen JSON, touto větou neprojde a rámec se pro něj nevytvoří.

### Normalizace rámce (verzovaná, `normalizer_version`)

1. Hex se převede na bajty. Podle `fmt` a `crc` se ověří a odstraní CRC bloky formátu A nebo B. Při chybném CRC dostane příjem stav `crc_error` a telegram nevznikne.
2. Rámec se převede na kanonickou podobu bez CRC s přepočítaným L-polem.
3. Načte se M a A pole (výrobce, ID, verze, typ), z nich `meter_key`, a CI pole. Z krátké nebo dlouhé hlavičky transportní vrstvy se vezme ACC a režim šifrování.
4. `frame_hash = sha256(kanonický rámec)`. Šifrovaný telegram se porovnává podle šifrovaného obsahu. Retransmise stejného telegramu je bitově shodná.
5. Rámce s extended link layer nebo značkami opakovače se zpracují podle pravidel ověřených na skutečných telegramech. U neznámé struktury se použije hash celého rámce. To může zanechat duplicitní telegram, ale nikdy nesloučí dva různé.

### Okno W

- Výchozí W = 10 minut (kotva ± 5 minut). Kotva je `captured_at_est`. W musí být větší než dvojnásobek nejistoty času, jinak se příjem zpracuje jako `server_only`.
- ACC je jeden bajt a přetočí se po 256 telegramech. Pro každé měřidlo musí platit `W ≤ (256 × interval vysílání) / 4`. Interval se odhaduje z historie měřidla. Když výchozí W pravidlo nesplní, použije se `meters.dedup_window`.
- Okno se uplatní jen pro shodný obsah (`meter_key`, ACC, `frame_hash`).

### Neznámá měřidla

- `meter_key` bez záznamu v `meters`, nebo se stavem `retired`, dostane stav příjmu `unknown_meter`.
- Neuloží se rámec, telegram ani deduplikační klíč, jen se aktualizuje `unknown_meter_sightings` (upsert).
- Administrace je zobrazí v `/api/v1/admin/unknown-meters`, odkud lze měřidlo založit.

### Transakce zpracování jedné položky

```text
BEGIN
 1. INSERT INTO ingest_message_keys (device_id, msg_key, …) ON CONFLICT DO NOTHING
    → nic nevloženo: opakované doručení.
       INSERT ingest_receipts se statusem duplicate_delivery,
       navázaný na původní raw_telegram_id nebo decoded_observation_id
       a na původní partition_month.
       UPDATE ingest_message_keys SET delivery_count = delivery_count + 1,
              last_received_at = now()
       COMMIT, ACK duplicate_delivery.
       Telegram, pozorování ani odečet se nevkládá.
 2. validace časů a výpočet captured_at_est, time_source, partition_month
    → too_old nebo invalid: receipt bez telegramu, COMMIT, ACK
 3. normalizace → při chybě receipt crc_error nebo invalid, COMMIT, ACK
 4. lookup meters podle meter_key → neznámé: upsert unknown_meter_sightings,
    receipt unknown_meter bez rámce, COMMIT, ACK
 5. time_source = server_only → postup "Kotva server_only"
 6. raw_id := nextval('raw_telegrams_id_seq')
 7. INSERT INTO telegram_dedup_keys (meter_key, acc, frame_hash, anchor_at,
        tstzrange(anchor − W/2, anchor + W/2), raw_id, partition_month)
    ON CONFLICT DO NOTHING RETURNING id
    a) vloženo:   kontrola stejného obsahu mimo okno (do 60 dní) → suspect_replay
                  INSERT raw_telegrams (raw_id, …),
                  INSERT decode_queue, pokud není suspect_replay
    b) konflikt:  SELECT klíč se stejným (meter_key, acc, frame_hash)
                  a překrývajícím se oknem, nejbližší kotva → existující raw_id
                  UPDATE raw_telegrams SET receipt_count += 1,
                         capture_device_ids, first_server_received_at = least(…)
                  UPDATE meter_readings (receipt_count, capture_device_ids),
                         pokud odečet už existuje
 8. INSERT ingest_receipts (… raw_id, payload_id, partition_month …)
 9. UPDATE ingest_message_keys SET outcome, receipt_id, delivery_count = 1
COMMIT → PUBACK brokeru a ACK zařízení
```

### Proč je to bezpečné při souběhu

- Exclusion constraint vynucuje deduplikaci přímo v databázi.
- Když dvě transakce vkládají překrývající se klíč současně, druhá na `ON CONFLICT DO NOTHING` počká, až první skončí:
  - první COMMIT: druhá vidí konflikt, v kroku 7b najde potvrzený řádek (READ COMMITTED bere pro každý příkaz nový snapshot) a připojí příjem,
  - první ROLLBACK: druhá vloží svůj klíč.
- Dva uložené klíče se stejným obsahem jsou od sebe vždy alespoň W. Nový příjem se tak může překrývat nejvýš se dvěma, a to jen když by dva různé telegramy se shodným obsahem a ACC přišly do 2W. Podmínka na W to vylučuje. Kdyby to přesto nastalo, vybere se nejbližší kotva a zapíše se událost `dedup_ambiguous`.
- Odečet vzniká při dekódování se `source_key = raw:<raw_id>` a `ON CONFLICT DO NOTHING`. Ani opakované dekódování nevytvoří druhý odečet.

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

Nastává, když epocha bootu zachycení není známá a zařízení nemělo NTP. Příklad: celý předchozí boot byl bez spojení a bez NTP. Okno kolem času serveru opožděnou kopii nenajde, proto:

1. Hledá se stejný obsah (`meter_key`, ACC, `frame_hash`) v `telegram_dedup_keys` za posledních 60 dní.
2. Když se najde, příjem dostane stav `probable_duplicate`, připojí se k nalezenému telegramu a nový odečet nevznikne.
3. Když se nenajde, vznikne nový telegram s `time_source = server_only`. Odečet vezme čas z hodin měřidla, pokud je v telegramu. Jinak se uloží s příznakem `time_unknown` a nepoužije se jako hraniční hodnota spotřeby ani při přechodu zdroje.

Bitově shodný rámec včetně ACC nejde odlišit od kopie, takže nejde o sloučení dvou různých telegramů se stejnou hodnotou.

### Podezření na replay

Shodný obsah mimo okno, ale do 60 dní, dostane `decode_status = suspect_replay`: bez odečtu, s událostí a upozorněním administrátorovi. Administrátor může telegram ručně uvolnit k dekódování (s auditem), třeba u měřidel, jejichž telegram neobsahuje měnící se čas ani čítač a po přetočení ACC se skutečně zopakoval.

## Pět případů, které se nesmí slít

| Případ | Jak se pozná | Co vznikne |
| --- | --- | --- |
| 1. Opakované doručení stejné zprávy | stejné autentizované `device_id` a stejný `msg_key` | další `ingest_receipts` se stavem `duplicate_delivery`, `delivery_count + 1`, žádný nový odečet |
| 2. Stejný telegram, víc koncentrátorů | jiné `device_id`, jiný `msg_key`, stejné `(meter_key, ACC, frame_hash)` v okně W | jeden `raw_telegrams`, N příjmů, jeden odečet `raw:<id>` |
| 3. Nový telegram se stejnou hodnotou | jiný ACC nebo jiný `frame_hash`; u dat bez rámce jiný čas zdroje nebo jiné tělo zprávy | nový telegram nebo pozorování a nový odečet. Shoda samotné hodnoty zprávy nespojí |
| 4. Fragmenty jedné zprávy | stejné `(device_id, group_key)`, různý `fragment_index` | žádný odečet, dokud sada není `complete`. Pak jeden průchod případů 1–3 |
| 5. Nové dekódování starých dat | stejný `source_key`, jiná `decoder_version` nebo `adapter_version` | druhý aktivní odečet nevznikne. Shoda hodnoty jen audit. Jiná hodnota je oprava, která původní řádek označí `superseded_at` |

Případ 3 a případ 1 se u zdroje bez identifikátoru zprávy rozliší tělem položky. `sha256` kanonického těla je klíč doručení. Nové měření se stejnou hodnotou a jiným časem má jiné tělo. Dvě doručení téhož těla jsou případ 1, ne dva odečty.

U dekódovaných dat bez rámce platí navíc částečný unikátní index `(meter_id, source_stream_id, measured_at)`. To je identita času uvnitř streamu, ne identita hodnoty. Stejný čas a stejná hodnota je duplicita. Stejný čas a jiná hodnota je `conflict`, původní odečet se nepřepíše. Stejná hodnota v jiném čase jsou dva odečty. Blízké, ale různé časy se podle hodnoty neslučují. Jestli ACRIOS posílá stabilní čas, ukáže PoC. Do té doby se časy nesbližují heuristikou.

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
 1. device_id z autentizace. Bez něj se sada nezaloží (odmítnutí fragment_unidentified).
 2. group_key a fragment_index musí přijít od zdroje. Když chybí, payload se uloží,
    ingest_rejections.reason = fragment_unidentified, COMMIT. Sada nevznikne.
 3. Najdi sadu (device_id, group_key) ve stavu collecting.
    Není-li a existuje uzavřená sada se stejným klíčem v tomto měsíci:
       odmítnutí, k sadě se fragment nepřidá, COMMIT.
    Není-li žádná: založ collecting, deadline = now + INGEST_FRAGMENT_TIMEOUT,
       expected_count jen pokud ho fragment uvedl.
 4. INSERT fragmentu na (sada, fragment_index).
       stejný content_hash: delivery_count + 1
       jiný hash: sada conflict, ingest_rejections fragment_conflict, COMMIT.
       Dekodér se nevolá.
 5. Když fragmenty uvádějí různý expected_count, sada je conflict a dál se neskládá.
 6. Když jsou přítomné všechny indexy 0 .. expected_count-1
    (nebo zdroj označil konec a indexy tvoří souvislou řadu od nuly):
       slož bajty v pořadí indexů do ingest_payloads s origin = assembled,
       sada complete,
       složený payload vstupuje jednou do běžné transakce položky.
COMMIT
```

Neúplná sada zůstane `collecting`. Worker po `deadline_at` nastaví `timed_out`, zapíše `ingest_rejections` s důvodem `fragment_timeout` a dekodér nezavolá. Chybějící fragment se nulami nedoplňuje. Nejvyšší přijatý index se nepovažuje za důkaz, že zpráva je celá: bez `expected_count` nebo příznaku konce od zdroje sada do `complete` nepřejde.

Ochrana proti záměně:

- klíč sady je autentizované `device_id` plus `group_key` od zdroje, ne samotný index,
- fragment jiného `group_key` je jiná sada, i když má stejný index a přišel ve stejnou sekundu,
- fragment jiného zařízení se do sady nepřipojí, i když uvede stejné `group_key`,
- opakovaný fragment se stejným hashem počet odečtů nemění,
- konflikt hashů sadu uzavře bez dekódování.

`INGEST_FRAGMENT_TIMEOUT` se číselně doplní, až PoC ukáže, jestli vybraný model vůbec fragmentuje a jak rychle zbytek posílá. ESP dávkuje celé rámce. Dávka není fragmentace a touto cestou nejde.

## Dekódované hodnoty (koncentrátory)

### Adaptér

- Pro každého partnera, včetně ACRIOS, převede formát na kanonický záznam `decoded`: `external_meter_ref`, `source_measured_at`, `source_time_kind`, `access_number` (pokud ho zdroj má), `reading_kind` a `values` s veličinou a jednotkou.
- Má verzi (`adapter_version`) a testy na vzorových zprávách, které dodal PoC nebo výrobce. Vzor, který PoC nepřinesl, se v testu nevymýšlí.
- Neznámé pole nebo jednotka znamená stav `invalid` s uloženým původním payloadem. Žádný odhad a žádný doplněný rámec.
- Neznámý `external_meter_ref` znamená stav `unknown_meter`. Pozorování se uloží (hodnoty a původní payload, ne rámec), aby šlo měřidlo po namapování přiřadit.
- Neznámý identifikátor koncentrátoru měřidlo ani zařízení nezaloží. Payload zůstane. Příjem má `device_attribution = unattributed`.

### Omezení dekódovaných dat

Bez rámce a bez ACC nelze:

- rozhodnout, že JSON a rádiový telegram jsou totéž vysílání,
- spočítat `frame_hash` ani doplnit RSSI, který zdroj neposlal,
- odlišit nový telegram se stejnou hodnotou od staršího jinak než časem zdroje a tělem zprávy,
- použít okno W. To patří jen surovému rámci.

Korelace níže je proto jen záznam shody, ne sloučení odečtů.

### Idempotence a deduplikace

1. **Doručení:** `ingest_message_keys (device_id, msg_key)`. Když zdroj id zprávy nemá, je `msg_key` hash kanonického těla. Stejné tělo poslané znovu je případ 1 (duplicitní doručení) a má vlastní příjem.
2. **Stejné měření v nové zprávě** (například denní přeposlání posledních 7 dní): částečný unikátní index `meter_readings (meter_id, source_stream_id, measured_at) WHERE source_kind = 'vendor_decoded' AND superseded_at IS NULL`. Rozhoduje trojice měřidlo, stream a čas zdroje. Stejná hodnota v jiném čase duplicita není. Jiná hodnota pro stejný čas se nepřepíše: uloží se do `decoded_observations` se stavem `conflict` a upozorní administrátora.
3. Pravidlo 2 platí jen uvnitř jednoho streamu. `vendor:acrios` a `vendor:<jiný kód>` se neslučují. Dva koncentrátory téhož partnera sdílejí stream `vendor:<kód>`, každý se svým `device_id`, a příjmy zůstávají oddělené.

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
  - přetočení ACC, stejné hodnoty v různých telegramech,
  - pozdní doručení, přechod přes hranici měsíce,
  - kotva `server_only`, replay,
  - property-based testy (Hypothesis).
- **Čas:**
  - opakované odeslání téže položky v různých časech dává stejný `captured_at_est`,
  - položka z předchozího bootu,
  - broker držel dávku hodinu,
  - hodiny zařízení v budoucnosti,
  - regrese `boot_counter`,
  - nové `instance_id` po vymazání flash.
- **Idempotence:** opakované doručení po ztraceném ACK a po pádu collectoru před a po COMMIT. Druhé doručení má příjem `duplicate_delivery` a stejný počet odečtů.
- **Pět případů:** opakované doručení, dva koncentrátory se stejným rámcem, nový telegram se stejnou hodnotou a jiným ACC, fragmenty, opětovné dekódování se stejnou i jinou hodnotou. Deduplikace podle samotné hodnoty musí v testu selhat, pokud by sloučila různá měření.
- **Fragmenty:** neúplná sada, opakovaný fragment se stejným hashem, fragment s jiným hashem, fragment cizího `group_key` nebo cizího zařízení, timeout. Dekodér dostane v testu jen kompletní sadu.
- **Dekódovaná data:** opakované poslání, konflikt hodnot, stejná hodnota v jiném čase jako dva odečty, korelace s rádiem bez sloučení, JSON bez vyrobeného rámce.
- **Identita zařízení:** výměna IMSI ponechá `device_id` a historii. Stejné IMSI u jiného zařízení je konflikt a zařízení se nezaloží z těla zprávy.
- **Preferovaný zdroj:**
  - přechod s úspěšnou kontrolou,
  - zablokovaný přechod (pokles hodnoty, nereálný průtok),
  - přechod do minulosti s přepočtem,
  - souběžné odečty dvou streamů nikdy nezdvojí spotřebu.
