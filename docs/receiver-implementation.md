# Implementace vlastního přijímače SJV

Tento dokument je praktický implementační plán přijímače na známém cílovém
hardware. Nenahrazuje [firmware-design.md](firmware-design.md), který zůstává
hlavní technickou specifikací chování a architektury firmware. Dokumentace
projektu stále označuje firmware, MQTT klient, HTTPS API a collector jako
neimplementované.

Závazné hodnoty protokolu jsou v
[data-ingestion.md](data-ingestion.md). Bezpečnostní omezení jsou v
[security.md](security.md), schválená rozhodnutí v
[decisions.md](decisions.md) a pořadí širší implementace v
[implementation-plan.md](implementation-plan.md).

## 1. Účel a rozsah přijímače

Přijímač zachytává surové Wireless M-Bus rámce, ověří jejich základní
integritu, odfiltruje neznámá měřidla a uloží známé rámce do lokální
persistentní fronty. Přes MQTT/TLS je posílá jako položky společného interního
kontraktu. Přijímač není dekodér odečtů, neobsahuje AES klíče měřidel a
neprovádí jejich dešifrování.

Rozsah tohoto plánu:

- firmware pro T-ETH-Elite s ESP32-S3;
- čtyři moduly CC1101 pro příjem v pásmu 868 MHz;
- Ethernet jako primární uplink;
- T-A7670E jako záložní LTE uplink;
- lokální identita zpráv, fronta, MQTT/TLS, ACK, heartbeat a telemetrie;
- diagnostika, OTA a testování.

RP530C se do návrhu nezařazuje. V aktuální dokumentaci není doložena jeho
role ani kompatibilita s touto architekturou.

## 2. Přehled hardware

| Prvek | Úloha | Stav znalosti |
| --- | --- | --- |
| T-ETH-Elite / ESP32-S3 | hlavní MCU a síťový uzel | cílový hardware podle zadání; přesná revize se ověří |
| 4× CC1101 | čtyři rádiové přijímací větve 868 MHz | modul je známý, zapojení, antény a podporované režimy se ověří |
| Ethernet | primární spojení na VPS | konkrétní PHY, ovladač a napájení se ověří |
| T-A7670E | záložní LTE spojení | rozhraní, napájení, anténa a AT podpora se ověří |
| flash/PSRAM | firmware a persistentní fronta | velikost a použitelné oddíly nejsou v dokumentaci doložené |

Počet rádiových modulů neznamená automaticky čtyři současné kanály nebo čtyři
antény. To bude výsledek Etapy 0, nikoli předpoklad implementace.

## 3. Elektrické zapojení a GPIO

Konkrétní GPIO, CS, GDO, SPI host, IRQ, reset, napájecí enable, Ethernet PHY
signály ani UART pro modem nejsou v aktuálních dokumentech uvedené. Nesmějí
být doplněny odhadem.

Etapa 0 musí z dokumentace desky a fyzickým měřením potvrdit:

- dostupné SPI sběrnice a jejich elektrické úrovně;
- zda čtyři CC1101 sdílejí MOSI/MISO/SCLK, nebo mají oddělené sběrnice;
- samostatný CS pro každý modul;
- použití GDO pinů a případné IRQ;
- reset a řízení napájení každého modulu;
- UART, USB nebo jinou cestu k T-A7670E;
- napájecí rezervu při současném rádiovém příjmu, Ethernetu a LTE;
- anténní konektory, zemnění a oddělení rušení.

Dokud nejsou tyto body změřené a zapsané pro konkrétní revizi desky, zdrojový
kód GPIO nevzniká.

## 4. Vývojové prostředí a framework

[firmware-design.md](firmware-design.md) doporučuje ESP-IDF v jazyce C kvůli
MQTT/TLS, OTA, NVS, LittleFS a FreeRTOS. Tento plán jej používá jako
preferovaného kandidáta, nikoli jako již schválenou nebo nainstalovanou
závislost.

Před implementací se musí zafixovat:

- verze ESP-IDF a toolchainu;
- target ESP32-S3 a přesná revize desky;
- ovladač Ethernetu a modemu;
- knihovna nebo vlastní ovladač CC1101 a licence;
- způsob reprodukovatelného buildu a podepisování OTA image.

ESPHome se pro tento rozsah nepředpokládá, protože neposkytuje potřebnou
kontrolu nad persistentní frontou a aplikačním ACK. Arduino zůstává
alternativou pouze po samostatném technickém posouzení.

## 5. Architektura firmware a moduly

Implementace zachová tok z [firmware-design.md](firmware-design.md):

```text
radio_rx → frame_check → filter → queue_append
                                      ↓
                         queue_read → uplink → ack_handler
heartbeat / time_sync / config_handler / ota / watchdog
```

Pravděpodobné moduly:

- `board`: inicializace desky a ověřeného pin-muxu;
- `radio`: CC1101 ovladač a čtyři přijímací instance;
- `wmbus`: režim příjmu a rámcový formát;
- `frame_check`: délka, CRC příznak a zachování původních bajtů;
- `identity`: `instance_id`, `boot_counter`, `seq`, `msg_key`;
- `whitelist`: canonical `meter_key` a retained konfigurace;
- `queue`: LittleFS segmenty, CRC32, potvrzení a replay;
- `uplink`: Ethernet/LTE výběr a MQTT/TLS;
- `ack`: položkové výsledky a odstranění fronty;
- `heartbeat`, `telemetry`, `config`, `ota`, `diagnostics`.

Modul `decoder` ani knihovna s AES klíči měřidel do firmware nepatří.

## 6. Příjem Wireless M-Bus přes CC1101

CC1101 se nejprve ověří na jednom modulu s laboratorním nebo skutečným
vzorkem. Teprve po potvrzení frekvence, modulace, symbolové rychlosti,
filtrace a režimu Wireless M-Bus se konfigurace rozšíří na další moduly.

Podporované režimy (například T1, C1 nebo S1) nejsou z dokumentace projektu
známé. Každý režim musí být potvrzen skutečnými telegramy a zapsán jako
ověřená schopnost zařízení.

Přijímač:

1. zachytí celý rámec a RSSI;
2. uloží `fmt` a příznak přítomnosti CRC;
3. neprovádí dešifrování;
4. předá rámec ke kontrole a filtraci;
5. po úspěšném zápisu do fronty jej považuje za přijatý.

Rámec se ve frontě nemění při opakovaném odeslání.

## 7. Konfigurace čtyř rádiových přijímačů

Každý CC1101 bude samostatně inicializovatelná instance s vlastním stavem,
CS, GDO a diagnostikou. Zda sdílejí SPI, zůstává otevřené do Etapy 0.

Konfigurace musí určit:

- fyzickou identitu modulu a antény;
- rádiový režim a parametry ověřené na vzorcích;
- pořadí inicializace a zotavení po chybě;
- zda běží moduly současně, nebo se plánují v čase;
- způsob řešení souběžných IRQ a přístupu na sdílenou sběrnici;
- počítadla přijatých, chybných a odfiltrovaných rámců.

Konfigurace nesmí vytvářet čtyři různé datové kontrakty. Všechny větve produkují
stejný typ raw položky.

## 8. Kontrola integrity a identifikace telegramů

`frame_check` ve firmware je pouze předběžná, nedestruktivní kontrola délky,
formátu a dostupného CRC příznaku. Není autoritativním rozhodnutím o validitě
telegramu. Firmware nesmí měnit původní bajty ani odstraňovat CRC bloky.
Předběžný výsledek se smí použít pro diagnostiku a filtraci zjevně vadného
příjmu, ale politika zahazování rámce po takové kontrole musí být ještě
ověřena na skutečných vzorcích.

Autoritativní kontrolu provádí VPS podle `fmt` a `crc` v rámci společného
ingest postupu. `crc: true` znamená, že rámec obsahuje CRC bloky a server je
ověří a odstraní při své kanonizaci; tato operace nesmí zpětně změnit původní
bajty uložené v payloadu. Při chybě vzniká příslušný stav příjmu, například
`crc_error` nebo `invalid`, podle [data-ingestion.md](data-ingestion.md).

Z rámce se podle pravidel v [data-ingestion.md](data-ingestion.md#deduplikace-raw-telegramů)
určí M a A pole, případně další identifikační údaje potřebné pro canonical
`meter_key`. `frame_hash` a serverové deduplikační okno vznikají až na VPS.
Firmware pouze zachovává data potřebná pro server.

Firmware vytváří transportní `msg_key`:

```text
<instance_id hex>-<boot_counter>-<seq>
```

Stejná položka při opakování používá stejný `msg_key` i stejné údaje `rx`.
`tx` a `age_ms` se mohou změnit podle okamžiku odeslání.

## 9. Whitelist měřidel a canonical meter_key

Whitelist `meters` v retained `config` obsahuje canonical identifikátory
měřidel včetně M a A polí podle skutečně ověřeného formátu. Převod rámce na
canonical `meter_key` musí být deterministický a verzovaný.

Měřidlo mimo whitelist:

- nevstoupí do lokální fronty;
- neodešle se na VPS;
- zvýší pouze `filtered_unknown` v heartbeat diagnostice.

Dočasný `discovery_until` je výjimka určená pro instalaci nových měřidel a
musí být řízený retained konfigurací. Firmware nesmí vytvářet záznam měřidla
ani měnit serverový katalog.

## 10. Lokální persistentní fronta

Fronta používá LittleFS podle návrhu firmware:

- segmenty mají 64 kB pouze jako návrhový formát, pokud jej ověří velikost
  flash;
- záznam obsahuje `magic`, `version`, délku, CRC32, `msg_key`, reference
  `rx`, RSSI, formát, CRC příznak a původní rámec;
- zápis je append-only;
- po výpadku napájení se nedokončený poslední záznam ověří a zahodí pouze,
  pokud má neplatný CRC;
- potvrzení se eviduje pro segment a segment se smaže až po potvrzení všech
  položek a uplynutí `REPLAY_HOURS`. Dosavadní návrhová výchozí hodnota je
  24 hodin; definitivní hodnota závisí na kapacitě flash a měření skutečné
  velikosti záznamů.

Při zaplnění se může zahodit nejstarší segment včetně nepotvrzených položek.
Zařízení vytvoří událost `queue_overflow` s rozsahem ztracených `msg_key` a
jejich počtem.
Kapacita, životnost a skutečný formát oddílu se změří v Etapě 0/6, neodhadují
se z typu desky.

Fronta přežije restart, výpadek sítě i přepnutí Ethernet/LTE. Záznam se
odstraní až po uložení odpovídajícího aplikačního ACK pro každou jeho položku.

## 11. MQTT/TLS a datový kontrakt s VPS

`data-ingestion.md` uvádí pro raw rámce topic:

```text
sjv/v1/dev/{device}/telegrams
```

Zařízení má podle návrhu publikovat raw dávky s QoS 1. Telemetrie má oddělený
topic `sjv/v1/dev/{device}/telemetry`, rovněž QoS 1; nejde o náhradu raw
telegramů. Heartbeat používá vlastní topic QoS 0. Tyto hodnoty jsou
kontraktový návrh, nikoli důkaz implementace.

Před implementací telemetrie je nutné sjednotit jeden topic registry a ověřit
proti němu:

- ACL zařízení pro publikování vlastního topicu;
- subscription collectoru;
- serverový ACK topic a jeho položkové výsledky;
- HTTPS endpoint `POST /api/v1/ingest/telemetry`;
- stejný interní kontrakt a stejnou deduplikační identitu pro MQTT i HTTPS.

Tato revize nevytváří nový topic ani nové JSON pole. Dokud není registry,
ACL, collector subscription, ACK a HTTPS cesta implementovaná a otestovaná,
nelze telemetrii označit za plně implementovanou nebo za dokonale sjednocený
provozní kontrakt.

Raw obálka odpovídá kontraktu v
[data-ingestion.md](data-ingestion.md#raw-zpráva). Firmware posílá celé
rámce v `items`, nikoli fragmenty jedné zprávy. Každá položka má vlastní
`msg_key`, `rx`, `rssi`, `fmt`, `crc` a `frame`.

MQTT/TLS:

- zařízení ověřuje hostname a důvěřuje schválenému balíčku kořenových CA;
- tajemství MQTT je v šifrovaném NVS;
- účet smí publikovat pouze do vlastních topiců a odebírat pouze vlastní
  `ack` a `config`;
- nové topics ani ACL se tímto plánem nepřidávají;
- při výpadku uplinku se zprávy neodhazují dříve než podle pravidel fronty.

HTTPS je v datovém kontraktu podporovaný fallback, ale adaptér ani HTTPS
implementace nejsou součástí tohoto dokumentu. Pokud bude později použita,
musí odeslat stejný obsah položky a stejný `msg_key`.

## 12. Aplikační ACK a deduplikace

Server publikuje výsledek do:

```text
sjv/v1/dev/{device}/ack
```

ACK má jeden výsledek pro každou položku dávky. `duplicate_delivery` potvrzuje
konkrétní opakované doručení; nepotvrzuje automaticky jiné položky téže dávky.
Přijímač odstraní položku z fronty až poté, co uloží odpovídající výsledek ACK.

Aplikační ACK není totéž co MQTT PUBACK. Server jej smí vytvořit a odeslat
až po COMMITu databázového výsledku. Při ztrátě ACK zařízení znovu pošle
stejný `msg_key` a stejné `rx`; server použije existující identitu
`(ingest_source_id, msg_key_namespace, msg_key, item_index)` a nevytvoří druhý
logický odečet.

## 13. Ethernet a LTE failover

Ethernet je preferovaná cesta. LTE se použije po detekovaném selhání
Ethernetu a po ověření dostupnosti modemu a datového spojení. Přepnutí:

- nesmí změnit `instance_id`, `boot_counter`, `seq`, `msg_key` ani uložený
  obsah fronty;
- nesmí vytvořit nový záznam pro stejný rámec;
- smí změnit pouze aktuální transportní cestu a diagnostiku;
- musí zachovat pořadí a retry/backoff fronty;
- po návratu Ethernetu smí uplink přejít zpět podle explicitního stavového
  automatu.

Přesné API T-A7670E, UART piny, napájecí sekvence, SIM stav, APN a způsob
detekce linky se ověří na hardware. Nejsou zde uvedeny jako hotové hodnoty.

## 14. Heartbeat a telemetrie

Heartbeat zůstává samostatný, QoS 0, s intervalem 60 sekund z konfigurace
`heartbeat_s`. Nese `instance`, `boot`, `uptime_ms`, `at`, stav NTP, firmware,
frontu, RSSI a počty přijatých a odfiltrovaných rámců. Nenahrazuje telemetrii.

Telemetrický vzorek se vytváří každých 900 sekund podle
`telemetry_interval_s` v retained konfiguraci. Používá samostatný QoS 1 topic
a vlastní stabilní `msg_key`. Jeden vzorek je kompletní objekt a může nést
více skupin, například `power`, teplotu nebo signál; firmware nevymýšlí nové
pole `kind`.

`power` je nepovinná skupina. Neznámé hodnoty se neposílají jako nula a
`soc_percent` se neposílá, pokud jej zařízení neumí spolehlivě určit.

Konfigurace zachovává `v`, `rev`, `heartbeat_s`, `telemetry_interval_s`,
`batch_max`, `ack_timeout_s`, whitelist a ostatní schválené parametry.
Změny retained konfigurace podléhají existujícímu auditu.

## 15. Diagnostika a logování

Diagnostika má poskytovat stavové informace bez tajemství a bez obsahu
telegramů:

- stav každého CC1101 a počty rámců;
- CRC/formát chyby a `filtered_unknown`;
- stav Ethernetu, LTE a přepínání;
- hloubka fronty, nejstarší klíč, zahozené záznamy a `queue_overflow`;
- MQTT reconnect, retry a ACK timeout;
- synchronizace času, reset reason, heap a watchdog;
- verze firmware a konfigurace.

Logy nesmí obsahovat MQTT hesla, TLS klíče, AES klíče měřidel, tokeny ani
celé surové telegramy. Pro korelaci se používá `msg_key` a bezpečná
diagnostická metadata.

## 16. Aktualizace firmware a bezpečnost

OTA image musí být podepsaný a po neúspěšném startu musí následovat rollback.
Použití secure boot v2 a flash encryption se ověří podle konkrétní podpory
ESP32-S3 a desky. Tajemství zařízení se ukládají do chráněného NVS.

Firmware:

- neobsahuje AES klíče měřidel;
- neprovádí dešifrování Wireless M-Bus;
- nemá vzdálený shell ani obecné příkazy;
- přijímá pouze whitelist, intervaly, replay požadavek, discovery a OTA;
- používá watchdog pro úlohy;
- zachovává bezpečné chování při výpadku napájení během zápisu fronty.

## 17. Testovací plán

Testy se dělí na hardware-in-the-loop, simulaci a integrační test s VPS.

- **Hardware:** pin-mux, SPI/CS/GDO, napájení, Ethernet, LTE, reset a
  souběžný provoz čtyř rádií.
- **Radio:** skutečné vzorky všech podporovaných režimů, CRC, krátké/
  neznámé rámce, RSSI a souběžný příjem.
- **Identita:** restart, vymazání NVS, přetečení `seq`, zvýšení
  `boot_counter`, nové `instance_id`, opakované odeslání.
- **Fronta:** výpadek napájení při každé části zápisu, neplatný poslední
  CRC, zaplnění, replay a zachování pořadí.
- **Uplink:** Ethernet výpadek, LTE přechod, návrat Ethernetu, TLS chyba,
  broker reconnect a změna linky bez změny `msg_key`.
- **ACK:** ztracený ACK, duplicitní ACK, částečný ACK, `accepted`,
  `duplicate_delivery`, `invalid`, `too_old` a další stavy podle kontraktu.
- **Čas:** SNTP před příjmem, po příjmu, předchozí boot, drift a chybějící
  čas zařízení.
- **Whitelist:** známé, neznámé a dočasně povolené měřidlo.
- **Telemetrie:** interval 900 s, stejný vzorek při retry a oddělení od
  heartbeat 60 s QoS 0.
- **Bezpečnost:** hostname TLS, ACL vlastního zařízení, odmítnutí cizího
  topicu, OTA podpis a rollback.

Integrační test musí ověřit, že serverový `server_received_at` vzniká na
serveru a že transportní `tx.at` není autoritativní čas příjmu.

## 18. Etapy implementace

### Etapa 0: ověření hardware, pinů a zapojení

- **Cíl:** získat ověřený pinout, napájecí a komunikační plán.
- **Předpoklady:** dostupná konkrétní revize T-ETH-Elite, čtyři CC1101 a
  T-A7670E.
- **Úkoly:** datasheet, vizuální kontrola, continuity test, SPI/UART měření,
  napájecí profil, antény a reset.
- **Soubory:** `hardware/receiver-revision-<id>.md`, pinout a měřicí protokol;
  přesné názvy jsou otevřené podle zvolené struktury firmware.
- **Ověření:** každý pin a napájecí stav je změřen a označen na fotografii
  nebo schématu.
- **Dokončení:** žádný GPIO ani SPI parametr nezůstává pouze odhadnutý.
- **Závislosti:** žádné; blokuje Etapy 1–4 a 9.

### Etapa 1: základní firmware a diagnostika ESP32-S3

- **Cíl:** reprodukovatelně sestavit image a spustit watchdog, log a OTA
  diagnostický základ.
- **Předpoklady:** uzavřená Etapa 0 a zvolený framework.
- **Úkoly:** projekt, board init, NVS, čas, watchdog, diagnostika a bezpečný
  reset.
- **Soubory:** firmware projekt, build konfigurace, `board`, `diagnostics`,
  `ota`, testy.
- **Ověření:** build, flash, reboot, log bez tajemství a rollback test.
- **Dokončení:** zařízení stabilně běží bez rádia a uplinku.
- **Závislosti:** Etapa 0.

### Etapa 2: komunikace s jedním CC1101

- **Cíl:** ověřit jeden modul na skutečném pinoutu.
- **Předpoklady:** Etapy 0–1.
- **Úkoly:** SPI/CS/GDO/reset ovladač, registrace, stavové chyby.
- **Soubory:** `radio/cc1101`, board konfigurace a unit/HIL testy.
- **Ověření:** čtení identity, reset, IRQ a opakovaný start.
- **Dokončení:** modul komunikuje bez chyb a diagnostika rozlišuje závady.
- **Závislosti:** Etapy 0–1.

### Etapa 3: příjem Wireless M-Bus a ověření telegramů

- **Cíl:** přijmout a zachovat celé skutečné rámce.
- **Předpoklady:** Etapa 2, vzorky telegramů a známý podporovaný režim.
- **Úkoly:** konfigurace rádia, `frame_check`, RSSI, CRC a capture metadata.
- **Soubory:** `wmbus`, `frame_check`, testovací vzorky a simulátor.
- **Ověření:** očekávané bajty, CRC chyby a diagnostické počty.
- **Dokončení:** validní rámec se nezmění a chybný se nepředá jako validní.
- **Závislosti:** Etapa 2; AES/dekódování není součástí.

### Etapa 4: zapojení všech čtyř CC1101

- **Cíl:** provozovat čtyři ověřené přijímací instance.
- **Předpoklady:** Etapa 3 a potvrzená sdílená nebo oddělená SPI topologie.
- **Úkoly:** instance, plánování, mutex/IRQ, izolace chyb a společné počitadla.
- **Soubory:** `radio/manager`, konfigurace modulů a HIL testy.
- **Ověření:** čtyři současné zdroje, dlouhý běh, restart jedné instance.
- **Dokončení:** porucha jednoho modulu neblokuje ostatní.
- **Závislosti:** Etapa 3.

### Etapa 5: whitelist a identifikace měřidel

- **Cíl:** filtrovat měřidla a vytvořit canonical `meter_key`.
- **Předpoklady:** validní rámce a ověřená struktura M/A polí.
- **Úkoly:** parser identity, retained config, discovery a počitadla.
- **Soubory:** `identity`, `whitelist`, config testy.
- **Ověření:** známé měřidlo projde, neznámé se neuloží ani neodešle.
- **Dokončení:** žádný neznámý rámec nevstoupí do fronty.
- **Závislosti:** Etapy 3–4.

### Etapa 6: persistentní fronta

- **Cíl:** přežít restart, výpadek napájení a síť.
- **Předpoklady:** stabilní položka a `msg_key`.
- **Úkoly:** LittleFS segmenty, CRC32, replay, overflow a kapacitní měření.
- **Soubory:** `queue`, filesystem konfigurace a fault-injection testy.
- **Ověření:** přerušení zápisu, obnova segmentu, plná fronta a ACK markery.
- **Dokončení:** žádný nepotvrzený záznam se nemaže kvůli běžnému reconnectu.
- **Závislosti:** Etapa 5.

### Etapa 7: MQTT/TLS a datový kontrakt s VPS

- **Cíl:** odeslat raw dávku v existujícím kontraktu.
- **Předpoklady:** fronta, zařízení a Mosquitto/collector PoC.
- **Úkoly:** TLS hostname, MQTT session QoS 1, dávky, retry a payload.
- **Soubory:** `uplink/mqtt`, certifikační balíček a integrační testy.
- **Ověření:** VPS uloží původní položky a zachová `msg_key`/`rx`.
- **Dokončení:** opakování posílá stejný obsah a jiný transportní čas pouze
  tam, kde to kontrakt dovoluje.
- **Závislosti:** Etapa 6 a dostupný serverový PoC.

### Etapa 8: aplikační ACK a opakované doručování

- **Cíl:** mazat frontu pouze po výsledku každé položky.
- **Předpoklady:** QoS 1 uplink a serverový ACK po COMMITu.
- **Úkoly:** `ack_handler`, mapování podle `msg_key` a `item_index`,
  ztracený/duplicitní ACK, replay.
- **Soubory:** `ack`, fronta a integrační testy.
- **Ověření:** pád před ACK vytvoří bezpečnou duplicitu bez druhého odečtu.
- **Dokončení:** žádný ACK nevede k předčasnému odstranění fronty.
- **Závislosti:** Etapy 6–7 a implementovaný serverový ingest.

### Etapa 9: Ethernet/LTE failover

- **Cíl:** zachovat doručování při změně linky.
- **Předpoklady:** ověřený Ethernet, modem a napájení.
- **Úkoly:** modem driver, stavový automat, APN/SIM konfigurace, návrat
  primární linky a diagnostika.
- **Soubory:** `net/ethernet`, `net/lte`, failover testy.
- **Ověření:** přepnutí během zápisu i během retry bez změny fronty.
- **Dokončení:** identita a obsah záznamu jsou stejné na obou cestách.
- **Závislosti:** Etapy 0, 6, 7 a 8.

### Etapa 10: heartbeat, telemetrie a dlouhodobé testování

- **Cíl:** dokončit provozní stav, telemetrii a soak test.
- **Předpoklady:** stabilní uplink a ACK.
- **Úkoly:** heartbeat 60 s QoS 0, telemetrie 900 s QoS 1, config audit,
  drift času, dlouhý běh a OTA.
- **Soubory:** `heartbeat`, `telemetry`, `config`, soak/HIL testy.
- **Ověření:** oddělené topics, intervaly, retry a zachování fronty.
- **Dokončení:** dlouhodobý test splní limity bez ztráty identity a bez
  tajemství v logu.
- **Závislosti:** Etapy 1, 6–9 a serverový kontrakt.

## 19. Otevřené technické otázky

| Otázka | Druh | Dopad |
| --- | --- | --- |
| Přesná revize T-ETH-Elite a dostupné GPIO | technické ověření | Etapa 0 |
| Sdílená nebo oddělená SPI sběrnice | technické ověření | Etapy 0, 2, 4 |
| CS, GDO, IRQ a reset čtyř CC1101 | technické ověření | Etapy 0–4 |
| Napájení a řízení napájení modulů | technické ověření | souběžný příjem a LTE |
| Ethernet PHY, UART a napájecí sekvence T-A7670E | technické ověření | Etapa 9 |
| ESP-IDF verze a ovladače CC1101/modemu | rozhodnutí po ověření | build a licence |
| Podporované režimy Wireless M-Bus a konkrétní konfigurace | technické ověření na vzorcích | Etapa 3 |
| Sdílení antén a elektromagnetické rušení | technické ověření | Etapy 0, 4 |
| Velikost flash oddílu a životnost LittleFS | technické ověření/měření | Etapa 6 |
| Maximální počet měřidel a intervaly vysílání | vstup od provozu/měření | kapacita fronty |
| APN, SIM, LTE režim a failover politika | schválení + technické ověření | Etapa 9 |
| Secure boot v2 a flash encryption na konkrétní desce | technické ověření | kapitola 16 „Aktualizace firmware a bezpečnost“ |
| Podpora ručního PUBACK na serveru | technické ověření serveru | Etapy 7–8 |
| Přesný firmware repozitář (`app/firmware/` nebo samostatný) | rozhodnutí projektu | všechny etapy |

## Návaznost a konzistence

Tento plán nepřidává MQTT topic, JSON pole, databázovou tabulku ani nový
mechanismus deduplikace. Používá existující `telegrams`, `telemetry`,
`heartbeat`, `ack` a `config` topics, canonical `meter_key` a složenou
identitu `ingest_message_keys`.

Heartbeat zůstává QoS 0/60 s, telemetrie QoS 1/900 s a ACK až po COMMITu.
Přijímač nepřebírá odpovědnost serveru za `server_received_at`, dekódování,
AES klíče ani deduplikaci raw telegramů. Neznámá hardware data jsou
výslovně otevřené body k ověření.
