# Příjem dat

Všechna sběrná zařízení navazují spojení směrem k VPS. Návrh počítá s mobilním CGNAT a nepředpokládá veřejnou IP zařízení. WireGuard pro příjem odečtů potřeba není.

Tabulky jsou popsané v [database-design.md](database-design.md), firmware v [firmware-design.md](firmware-design.md).

## Dva druhy dat

| Druh | Obsah | Typický zdroj | Stream | Cesta v systému |
| --- | --- | --- | --- | --- |
| `raw` | původní wM-Bus rámec v hex | vlastní ESP, koncentrátor s exportem rámců | `radio` | `telegram_receipts` → `raw_telegrams` → dekódování → `meter_readings` |
| `decoded` | hodnoty, které už dekódoval zdroj | koncentrátor dodavatele | `vendor:<kód>` | `decoded_observations` → `meter_readings` |

Podpora koncentrátorů, které posílají jen dekódované hodnoty:

- druh zprávy `decoded` v obou transportech (MQTT topic `readings`, HTTPS `POST /api/v1/ingest/readings`),
- tabulka `decoded_observations` a mapování identifikátorů dodavatele (`meter_external_ids`),
- vlastní pravidla idempotence a korelace (níže),
- adaptér pro každého dodavatele. Konkrétní adaptér vznikne až podle skutečné dokumentace zařízení.

Co z dekódovaných dat zjistit nejde, popisuje část [Omezení dekódovaných dat](#omezení-dekódovaných-dat).

## Identita zprávy

- `device_id` se vždy bere z autentizace (MQTT účet nebo API token), nikdy z těla zprávy.
- `msg_key` je idempotentní klíč zprávy, unikátní pro zařízení:
  - **vlastní ESP:** `<instance_id>-<boot_counter>-<seq>`.
    - `instance_id` je náhodné 64bitové číslo v hex. Vygeneruje se při prvním startu a znovu po každém vymazání flash, takže reset `boot_counter` nikdy nevytvoří klíč, který server už zná.
    - `boot_counter` je v NVS a roste při každém startu.
    - `seq` je čítač v RAM od nuly v každém bootu.
  - **koncentrátor dodavatele:** id zprávy dodavatele. Když ho nemá, je klíč `sha256` kanonického těla položky.

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

**Koncentrátory** posílají vlastní čas. U nich se použije `device_clock` s offsetem měřeným z HTTPS požadavků, jinak `server_only`.

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

`{device}` je kód zařízení (`ESP-SJV-001`). Je zároveň uživatelským jménem a client ID v Mosquitto Dynamic Security.

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

- **Autentizace:** `Authorization: Bearer <token zařízení>`. Token se ukládá jako hash. mTLS lze doplnit, až bude známa podpora u dodavatele.
- **Odpověď:** `200` s výsledkem pro každou položku, ve stejných stavech jako ACK. `200` znamená, že data jsou v DB. Při `5xx` musí zdroj poslat znovu. Duplicitní doručení je bezpečné.
- **Limity:** velikost těla, počet položek v dávce a rate limit na token, vše v aplikaci.
- **CrowdSec:** ingest router v Traefiku má vlastní řetězec middleware. CrowdSec se na něj aplikuje opatrně, protože zařízení za CGNAT sdílejí veřejné IP s cizími klienty a blokace podle IP by mohla odříznout vlastní zařízení. Hlavní ochranou je autentizace a limit na token.

## Deduplikace raw telegramů

### Cíle

- Každý příjem se eviduje zvlášť (`telegram_receipts`).
- Stejný rádiový telegram zachycený více zařízeními, nebo opakovaně jedním, má jeden `raw_telegrams` a nejvýš jeden odečet.
- Dva různé telegramy se stejnou hodnotou spotřeby se nesloučí.
- Deduplikace funguje pro opožděné doručení z fronty ESP, i když jiný přijímač poslal stejný telegram už dříve, a funguje při souběžném zpracování.

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
    → nic nevloženo: duplicate_delivery, vrátit původní výsledek, COMMIT, ACK
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
 8. INSERT telegram_receipts (… raw_id, partition_month …)
 9. UPDATE ingest_message_keys SET outcome, receipt_id
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
| 13:10:03 | ACK se ztratí, ESP pošle F znovu se stejným `msg_key` a stejným `rx` | `duplicate_delivery`, nic nového |

Výsledek: dva telegramy, čtyři příjmy, dva odečty se stejnou hodnotou. Spotřeba je správná, protože se počítá z kumulativních hodnot.

Stejný výsledek vyjde, i když collector byl hodinu mimo provoz a broker dávku držel. Kotva vychází z `rx.uptime_ms` a epochy z heartbeatů, ne z času doručení.

### Kotva `server_only`

Nastává, když epocha bootu zachycení není známá a zařízení nemělo NTP. Příklad: celý předchozí boot byl bez spojení a bez NTP. Okno kolem času serveru opožděnou kopii nenajde, proto:

1. Hledá se stejný obsah (`meter_key`, ACC, `frame_hash`) v `telegram_dedup_keys` za posledních 60 dní.
2. Když se najde, příjem dostane stav `probable_duplicate`, připojí se k nalezenému telegramu a nový odečet nevznikne.
3. Když se nenajde, vznikne nový telegram s `time_source = server_only`. Odečet vezme čas z hodin měřidla, pokud je v telegramu. Jinak se uloží s příznakem `time_unknown` a nepoužije se jako hraniční hodnota spotřeby ani při přechodu zdroje.

Bitově shodný rámec včetně ACC nejde odlišit od kopie, takže nejde o sloučení dvou různých telegramů se stejnou hodnotou.

### Podezření na replay

Shodný obsah mimo okno, ale do 60 dní, dostane `decode_status = suspect_replay`: bez odečtu, s událostí a upozorněním administrátorovi. Administrátor může telegram ručně uvolnit k dekódování (s auditem), třeba u měřidel, jejichž telegram neobsahuje měnící se čas ani čítač a po přetočení ACC se skutečně zopakoval.

## Dekódované hodnoty (koncentrátory dodavatele)

### Adaptér

- Pro každého dodavatele převede formát na kanonický záznam `decoded`: `external_meter_ref`, `source_measured_at`, `source_time_kind`, `access_number` (pokud ho zdroj má) a `values` s jednotkami a registry.
- Má verzi (`adapter_version`) a testy na vzorových zprávách od dodavatele.
- Neznámé pole nebo jednotka znamená stav `invalid` s uloženým `vendor_payload`. Žádný odhad.
- Neznámý `external_meter_ref` znamená stav `unknown_meter`. Pozorování se uloží (hodnoty, ne rámec), aby šlo měřidlo po namapování přiřadit.

### Idempotence a deduplikace

1. **Doručení:** `ingest_message_keys (device_id, msg_key)`. Když dodavatel id zprávy nemá, je `msg_key` hash kanonického těla. Stejné tělo poslané znovu je duplicitní doručení.
2. **Opakované poslání stejného měření v nové zprávě** (např. denní přeposlání posledních 7 dní): částečný unikátní index `meter_readings (meter_id, source_stream_id, measured_at) WHERE source_kind = 'vendor_decoded' AND superseded_at IS NULL`. Stejná hodnota je duplicita. Jiná hodnota pro stejný čas se nepřepíše: uloží se do `decoded_observations` se stavem `conflict` a upozorní administrátora.
3. Pravidlo 2 platí jen uvnitř jednoho streamu, kde je `(měřidlo, čas zdroje)` identitou měření.

### Korelace se surovými telegramy

Stejné rádiové vysílání může přijmout ESP (raw) i koncentrátor (decoded). Tato data se **neslučují do jednoho odečtu**, protože bez ACC a rámce nejde bezpečně rozhodnout, že jde o stejný telegram.

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

  Porušení znamená příznak a anomálii. Odečet se uloží, ale do spotřeby se nezapočte do rozhodnutí administrátora.
- `decoder_version` se ukládá k odečtu. Opakované dekódování po změně verze se dělá řízeně: nevytváří nové odečty a změnu zapíše do auditu.
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
- Administrace ukazuje u každého měřidla přiřazený stream a zařízení, která ho naposledy zachytila. U každého zařízení ukazuje frontu, boot, epochu a posun hodin.

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
- **Idempotence:** opakované doručení po ztraceném ACK a po pádu collectoru před a po COMMIT.
- **Dekódovaná data:** opakované poslání, konflikt hodnot, korelace s rádiem.
- **Preferovaný zdroj:**
  - přechod s úspěšnou kontrolou,
  - zablokovaný přechod (pokles hodnoty, nereálný průtok),
  - přechod do minulosti s přepočtem,
  - souběžné odečty dvou streamů nikdy nezdvojí spotřebu.
