# Návrh firmware ESP32

Pouze návrh. Firmware se zatím neimplementuje. Umístění (`app/firmware/` nebo samostatný repozitář) se rozhodne při schválení implementace.

Protokol (topics, formát zpráv, ACK, config) je závazně popsaný v [data-ingestion.md](data-ingestion.md). Tento dokument popisuje jen chování zařízení.

## Neznámé vlastnosti hardwaru

Návrh nepředpokládá konkrétní desku. Před implementací je potřeba zjistit:

- přesný model LILYGO, rádiový čip (CC1101, SX1262, SX1276 nebo jiný) a podporované režimy wM-Bus (T1, C1, S1),
- velikost flash a PSRAM,
- konektivitu v budově: Wi-Fi, LTE modem, nebo obojí,
- napájení: síťové, nebo baterie (mění strategii spojení),
- zda konkrétní varianta čipu podporuje flash encryption a secure boot v2,
- přesnost krystalu, tedy drift monotónního času. Měří se v PoC, protože vstupuje do nejistoty času zachycení,
- dřívější firmware LilyGO (zdroj, licence). Posílal hex do `wmbus/lilygo/telegram`.

## Volba platformy

Doporučuji **ESP-IDF** (C). Nabízí:

- spolehlivý MQTT klient (`esp-mqtt`) s TLS,
- OTA s rollbackem,
- NVS s šifrováním,
- LittleFS,
- 64bitový monotónní čas `esp_timer_get_time()`.

ESPHome nedává kontrolu nad persistentní frontou a aplikačním ACK. Arduino je možná alternativa, ale s horší kontrolou nad OTA a bezpečností. Ovladač rádia lze případně převzít z existujících open-source projektů pro wM-Bus, po kontrole licence.

## Úlohy (FreeRTOS)

```text
radio_rx ──► frame_check ──► filter ──► queue_append (flash)
                                             │
uplink (Wi-Fi/LTE, MQTT TLS) ◄── queue_read ─┘
   │  publish dávky QoS 1                     ▲
   └─ ack_handler ── queue_mark_acked ────────┘
heartbeat, time_sync (SNTP), config_handler, ota, watchdog
```

1. **radio_rx:** příjem rámce a RSSI. Ihned se zaznamená reference zachycení: `instance_id`, `boot_counter`, `rx_uptime_ms` a `rx_unix_ms`, ale `rx_unix_ms` jen při synchronizovaném čase.
2. **frame_check:** základní kontrola délky a CRC podle formátu. Rámec se nemění, posílá se původní podoba s údaji `fmt` a `crc`.
3. **filter:** whitelist měřidel (M a A pole) z retained `config`. Ostatní měřidla se nezapisují, jen se počítají (`filtered_unknown` v heartbeatu). Režim discovery do času `discovery_until` povolí odesílání všech měřidel kvůli instalaci nových.
4. **queue_append:** zápis do persistentní fronty. Teprve potom se rámec považuje za přijatý.
5. **uplink:** odesílání dávek do `batch_max` položek. Čekání na ACK s timeoutem `ack_timeout_s` z `config`. Při výpadku exponenciální backoff s náhodným rozptylem a horní mezí. Před první dávkou po připojení se pošle heartbeat, aby server znal epochu bootu.
6. **ack_handler:** podle `msg_key` označí položky jako potvrzené. Všechny stavy ACK v [data-ingestion.md](data-ingestion.md#ack) končí potvrzením.

## Identita zprávy

| Hodnota | Uložení | Chování |
| --- | --- | --- |
| `instance_id` | NVS | náhodných 64 bitů z hardwarového RNG při prvním startu. Nové po vymazání NVS nebo flash |
| `boot_counter` (uint32) | NVS | zvýší se při každém startu. Je to jediný pravidelný zápis do NVS |
| `seq` (uint32) | RAM | od 0 po každém startu |

`msg_key = "<instance_id hex>-<boot_counter>-<seq>"` je jednoznačný napříč restarty bez zápisu do flash při každé zprávě. Díky `instance_id` je jednoznačný i po vymazání flash, kdy `boot_counter` začne znovu od nuly.

## Persistentní fronta

- LittleFS, segmenty po 64 kB, jen přidávání na konec. Každý záznam má hlavičku `magic`, `version`, `len`, `crc32`.
- **Záznam obsahuje:**
  - `msg_key` (tedy `instance_id`, `boot_counter`, `seq`),
  - referenci zachycení: `rx_instance`, `rx_boot`, `rx_uptime_ms` a `rx_unix_ms` (0, když čas nebyl synchronizovaný),
  - `rssi`, `fmt`, `crc_flag` a rámec.

  Záznam se po zápisu nemění. Při každém, i opakovaném, odeslání se z něj posílají stejné údaje `rx` a stejný `msg_key`.
- Potvrzení se nezapisuje k jednotlivým záznamům. Ukládá se jako „potvrzeno do“ pro každý segment. Segment se smaže, až jsou potvrzené všechny jeho záznamy a uplynulo `REPLAY_HOURS`.
- Po výpadku napájení se při startu segmenty projdou a záznam s neplatným `crc32` na konci se zahodí. Ztratí se nejvýš rozepsaný záznam.
- Při zaplnění se smaže nejstarší segment, i nepotvrzený. Zařízení pošle událost `queue_overflow` s rozsahem ztracených `msg_key` a počtem. Server z toho udělá alarm.
- **Kapacita** se určí až podle skutečné flash a změřené velikosti záznamů: `kapacita ≈ velikost oddílu fronty / průměrná velikost záznamu`. Doba, kterou fronta pokryje, je `kapacita / počet přijatých telegramů za hodinu`. Obojí se zapíše po PoC.

## Čas

- SNTP po připojení. Do synchronizace je `rx_unix_ms = 0` a `tx.at` chybí.
- Monotónní čas `uptime_ms` se bere z `esp_timer_get_time()` a po restartu začíná od nuly. Proto se ukládá vždy spolu s `instance_id` a `boot_counter`.
- **Při každém odeslání** zařízení doplní obálku `tx` (`instance`, `boot`, `uptime_ms`, volitelně `at`). Pro položky z aktuálního bootu dopočítá `age_ms = tx.uptime_ms − rx_uptime_ms`. Položky z předchozího bootu `age_ms` nemají.
- Server čas zachycení počítá sám z reference zachycení a epochy bootu odhadnuté z heartbeatů ([data-ingestion.md](data-ingestion.md#časový-model)). Zařízení proto nesmí reference v záznamu přepisovat ani „opravovat“ podle pozdější synchronizace času.
- Položky z bootu, ve kterém zařízení nikdy nebylo online a nemělo NTP, server zpracuje jako `server_only`. Firmware to omezuje tím, že po startu nejdřív zkouší spojení a SNTP, a teprve potom spustí příjem z rádia. Příjem z rádia ale na spojení nečeká, když se ho nepodaří navázat.

## Replay po obnově serveru

- Potvrzené záznamy zůstávají ve flash ještě `REPLAY_HOURS`. Návrh je 24 h, skutečná hodnota se určí podle kapacity fronty.
- Server může přes `config` poslat `replay_since` s časem nebo `msg_key`. Zařízení znovu odešle potvrzené záznamy od daného bodu se stejnými `msg_key` a údaji `rx`. Opakování zachytí idempotence a deduplikace na serveru.
- Jedno `replay_since` (podle `rev` v config) se provede jen jednou.

## Heartbeat a stav

- Interval `heartbeat_s` z `config`, návrh 60 s, QoS 0.
- Obsah:
  - časová reference: `instance`, `boot`, `uptime_ms`, `at` a stav SNTP,
  - verze firmware,
  - fronta: hloubka, reference nejstaršího nepotvrzeného záznamu, počet zahozených,
  - RSSI Wi-Fi nebo LTE, volná paměť,
  - počet přijatých a odfiltrovaných rámců.
- LWT `status = offline` (retained). Po připojení `online`.
- Události (QoS 1, přes frontu): `boot` (s důvodem resetu), `queue_overflow`, `time_sync_lost`, `radio_error`, `ota_result`.

## Bezpečnost zařízení

- Každé zařízení má vlastní jméno a heslo MQTT, uložené v šifrovaném NVS.
- **Flash encryption a secure boot v2** doporučuji, aby se údaje z ukradeného zařízení nedaly snadno přečíst. Použití závisí na podpoře konkrétního čipu.
- TLS s ověřením hostname. Kořenové CA ISRG Root X1 a X2 v aktualizovatelném balíčku, bez pinování konkrétního certifikátu.
- AES klíče měřidel zařízení nemá a nepotřebuje.
- OTA: jen podepsané image, rollback při neúspěšném startu. Kanál OTA (HTTPS z VPS) se navrhne při implementaci.
- Žádný vzdálený shell ani obecné příkazy. Ze serveru jdou jen `config` (whitelist, intervaly, `replay_since`, discovery) a OTA.
- Watchdog pro všechny úlohy.

## Testy firmware (při implementaci)

- Simulace výpadku sítě a napájení během zápisu.
- Zaplnění fronty.
- Ztráta ACK a duplicitní ACK.
- Opakované odeslání: stejné `msg_key` a `rx`, nové `tx` a `age_ms`.
- Restart před a po SNTP, záznamy z předchozího bootu.
- Vymazání flash: nové `instance_id`.
- Přetečení `seq` a `boot_counter`.
- Měření driftu monotónního času proti NTP během několika dní.
- Testovací server se simulátorem ACK.
