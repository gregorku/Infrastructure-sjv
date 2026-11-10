# Databázový návrh

PostgreSQL 18.x, databáze `sjv`, schéma `public`, je centrální a jediný dlouhodobý zdroj pravdy pro data SJV (rozhodnutí 15–19 v [decisions.md](decisions.md)). Konkrétní model ACRIOS, jeho firmware ani protokol tvar tabulek nemění. ACRIOS je kód partnera a adaptéru, ne předpona tabulek.

- ORM SQLAlchemy 2 s psycopg 3, migrace Alembic.
- Rozšíření `btree_gist` (exclusion constrainty) a `citext` (e-maily).
- Časy jsou `timestamptz` v UTC. Kalendářní dny (agregace, členství) se počítají v `Europe/Prague`.

## Partitioning a globální unikátnost

### Omezení PostgreSQL

1. Unikátní constraint a primární klíč na partitionované tabulce musí obsahovat všechny sloupce partition klíče. Unikátnost se vynucuje jen uvnitř jedné partition. PostgreSQL 18 nemá globální indexy.
2. Partition klíč v unikátním constraintu musí být prostý sloupec, ne výraz.
3. Exclusion constraint na partitionované tabulce je možný od PostgreSQL 17, ale jen se sloupci partition klíče porovnávanými přes `=`. Působí tedy také jen uvnitř partition.
4. Cizí klíč na partitionovanou tabulku je možný, ale musí odkazovat na unikátní klíč včetně partition klíče.
5. `ON CONFLICT` na partitionované tabulce vyžaduje unikátní index s partition klíčem. `ON CONFLICT DO NOTHING` bez cíle respektuje i exclusion constraint a při souběhu čeká na dokončení konkurenční transakce.
6. Partition, na jejíž řádky odkazuje cizí klíč, nejde odpojit ani smazat, dokud odkazující řádky existují.

### Řešení

1. **Partitionují se jen tabulky s časovou retencí:** `ingest_payloads`, `ingest_receipts`, `ingest_fragments`, `ingest_fragment_sets`, `ingest_rejections`, `raw_telegrams`, `decoded_observations` (24 měsíců) a `device_events` (12 měsíců). Důvodem je levné mazání celé partition. Dřívější `telegram_receipts` je sloučená do `ingest_receipts`, aby MQTT, HTTPS, UDP/DTLS, API a import neměly každý vlastní evidenci.
2. **Globální idempotence a deduplikace jsou v malých tabulkách bez partitioningu:**
   - `ingest_message_keys` s `PRIMARY KEY (device_id, msg_key)`,
   - `telegram_dedup_keys` s exclusion constraintem přes časové okno.

   Mají retenci 60 dní a ingest odmítne zprávy starší než `INGEST_MAX_MESSAGE_AGE` (30 dní). Každé možné opakování tak vždy narazí na existující klíč.
3. **Trvalé tabulky se nepartitionují** a mají globální `UNIQUE`: `meter_readings`, `meter_daily_values`, `audit_logs`, kmenová data.
4. **Partition klíč je `partition_month date`** (první den měsíce v UTC). U telegramu, pozorování a jejich příjmu ho server počítá z ověřeného odhadu času zachycení a po zápisu se nemění. Příjem a jeho telegram mají stejné `partition_month`, takže cizí klíč `(raw_telegram_id, partition_month)` funguje. Původní obálka má měsíc podle `server_received_at`: na server dorazila teď, i když rámec byl zachycen dříve. Příjem si drží `(payload_id, payload_partition_month)`. Rozdíl měsíců je nejvýš stáří zprávy (30 dní), takže údržba mazající od nejstaršího měsíce nenarazí na živý odkaz.
5. **Trvalé odečty nemají cizí klíč na tabulky s retencí.** Odkaz na telegram nebo pozorování je jen historický údaj. Smazání telegramu tak nikdy neovlivní odečet ([retence](#retence-a-vazby)).

## Kmenová data

### `buildings`

`id`, `name`, `street`, `city`, `postal_code`, `deleted_at NULL`, `created_at`, `updated_at`

### `apartments`

`id`, `building_id → buildings`, `unit_number`, `floor`, `note`, `deleted_at NULL`

- `UNIQUE (building_id, unit_number)`

### `users`

`id`, `email citext UNIQUE`, `display_name`, `password_hash` (argon2id), `status` (`invited`, `active`, `disabled`, `anonymized`), `mfa_totp_secret_enc`, `mfa_enabled`, `failed_login_count`, `locked_until`, `last_login_at`, `created_at`

Uživatel se nemaže. Kvůli vazbám a auditu se anonymizuje: e-mail a jméno se nahradí, `status = anonymized`.

### RBAC

| Tabulka | Sloupce |
| --- | --- |
| `roles` | `code` (`admin`, `member`, `board`, `technician`), `is_assignable` (`board` a `technician` = `false`) |
| `permissions` | `code` |
| `role_permissions` | `role_code`, `permission_code` |
| `user_roles` | `user_id`, `role_code`, `granted_by`, `granted_at` |

Seznam oprávnění je v [security.md](security.md). Trigger brání vložit do `user_roles` roli s `is_assignable = false`.

## Historie bytu: přístup oddělený od spotřeby

Dvě nezávislé osy:

- **Spotřeba** patří bytu a měřidlu: `meter_installations`, `meter_readings`, `meter_daily_values`. Odečty nikdy neodkazují na uživatele.
- **Přístup** patří uživateli: `apartment_members`. Určuje jen, které časové úseky spotřeby smí uživatel vidět.

Změna vlastníka proto nemění ani nepřesouvá data spotřeby, jen ukončí jedno členství a založí jiné. Administrátor vidí obě osy v `/admin/apartments/{id}/history`.

### `apartment_members`

`id`, `apartment_id`, `user_id`, `relation` (`owner`, `co_owner`, `representative`), `valid_from date`, `valid_to date NULL`, `created_by`, `created_at`, `ended_by NULL`, `ended_at NULL`

- `CHECK (valid_to IS NULL OR valid_to > valid_from)`
- `EXCLUDE USING gist (apartment_id WITH =, user_id WITH =, daterange(valid_from, valid_to, '[)') WITH &&)`
- Datum se vykládá jako kalendářní den v `Europe/Prague`. Členství platí od 00:00 `valid_from` do 00:00 `valid_to`.
- Řádky se nemažou. Změny jdou do `audit_logs`. Více současných členů (spoluvlastníci) je povoleno.

### Pravidlo viditelnosti pro člena

Odečet nebo denní hodnota je pro uživatele U viditelná, právě když platí obojí:

1. měřidlo bylo v čase odečtu instalováno v bytě B (`meter_installations`),
2. U měl v bytě B členství a čas leží v `[valid_from, valid_to)`.

Důsledky:

- Nový vlastník nevidí nic z doby před svým `valid_from`. Předchozí vlastník po `valid_to` nevidí nic nového.
- Kdo byl členem ve dvou oddělených obdobích, vidí obě období, ale ne mezeru mezi nimi.
- Spotřeba za měsíc, který členství pokrývá jen částečně, se počítá z denních hodnot uvnitř členství a je označená jako částečná.
- Aktuální stav ukazuje kumulativní hodnotu počítadla, stejnou jako na displeji měřidla. Je označená jako celkový stav měřidla, ne jako osobní spotřeba, protože zahrnuje i spotřebu před členstvím. Historické odečty a vypočítaná spotřeba zůstávají jen za období členství. Administrátor vidí kompletní historii. Schváleno jako R15 v [decisions.md](decisions.md). Bere se poslední kumulativní primární hodnota přiřazeného streamu. Intervalová hodnota ani událost ji nenahrazují.

Pravidlo vynucuje repozitářová vrstva backendu jedním společným predikátem. Pokrývají ho testy ([security.md](security.md)).

## Měřidla a instalace

### `meters`

`id`, `manufacturer_code char(3)`, `wmbus_id char(8)`, `wmbus_version smallint`, `wmbus_type smallint`, `meter_key bytea UNIQUE` (M + A pole, 8 B), `driver`, `medium` (`cold_water`, `hot_water`, `heat`, `heat_cost_allocator`), `primary_register`, `unit`, `aes_key_enc bytea NULL`, `aes_key_fingerprint NULL`, `dedup_window interval NULL`, `max_flow_per_hour numeric NULL`, `status` (`active`, `retired`), `note`

### `meter_external_ids`

`id`, `meter_id`, `source_stream_id`, `external_id`

- `UNIQUE (source_stream_id, external_id)`
- Mapuje identifikátory dodavatele na měřidlo.

### `meter_installations`

`id`, `meter_id`, `apartment_id`, `location`, `installed_at`, `removed_at NULL`, `initial_value`, `final_value NULL`, `reason`, `seal_number`, `created_by`

- `EXCLUDE USING gist (meter_id WITH =, tstzrange(installed_at, removed_at, '[)') WITH &&)`
- Výměna = ukončení instalace s `final_value` a nová instalace nového měřidla s `initial_value`. Obojí v jedné transakci a s auditem.
- Spotřeba různých fyzických měřidel v bytě (kuchyň, koupelna, staré a nové po výměně) se sčítá. Jde o různá počítadla, ne o dva zdroje téhož počítadla.

## Zdroje odečtů

### `source_streams`

`id`, `code UNIQUE`, `kind` (`radio`, `vendor_decoded`, `manual`, `import`), `description`

| Stream | Obsah |
| --- | --- |
| `radio` | všechny wM-Bus rámce. Vlastní ESP i libovolný koncentrátor, který rámec skutečně předá, včetně ACRIOS, tvoří jeden stream. Deduplikace je slučuje na úrovni telegramu |
| `vendor:<kód>` | dekódované hodnoty jednoho partnera, když rámec nepředává. Pro ACRIOS je kód `vendor:acrios`. Řádek streamu není tabulka a neříká, které transporty model umí. Jiný výrobce dostane vlastní kód, ne sloupec v tabulkách ACRIOS |
| `manual` | ruční odečet zadaný v administraci |
| `import` | souborový import (CSV a další formát, pro který existuje adaptér) |

`devices.source_stream_id` určuje jen to, kam patří dekódovaná data tohoto zařízení. Surový rámec jde vždy do `radio`, i když ho poslalo zařízení, které jindy posílá jen JSON. Import se do spotřeby dostane až explicitním přiřazením streamu, stejně jako každý jiný přechod zdroje.

### `meter_source_assignments` (preferovaný zdroj)

`id`, `meter_id`, `source_stream_id`, `valid_from`, `valid_to NULL`, `handover_from_reading_id NULL`, `handover_to_reading_id NULL`, `handover_status` (`initial`, `pending`, `verified`, `admin_confirmed`), `reason`, `created_by`, `created_at`

- `EXCLUDE USING gist (meter_id WITH =, tstzrange(valid_from, valid_to, '[)') WITH &&)`
- Každé aktivní měřidlo má v každém okamžiku od první instalace právě jedno přiřazení. Založení měřidla bez počátečního přiřazení API nepřijme a `maintenance.sh` hlásí každou mezeru.

### Efektivní řada a výpočet spotřeby

- Efektivní řada měřidla E(t) se skládá jen z odečtů streamu, který je v čase t přiřazený, a jen z `reading_kind = cumulative`, plus z hraničních hodnot instalací (`initial_value`, `final_value`).
- Spotřeba v intervalu ⟨a, b⟩ uvnitř jedné instalace je `E(b) − E(a)`, tedy rozdíl dvou absolutních hodnot téhož počítadla. Intervalové hodnoty a události se do rozdílu nezapočítávají.
- **Nikdy se nesčítají přírůstky ze dvou streamů za stejné období.** Odečty nepřiřazeného streamu se do spotřeby nepromítnou. Slouží jen ke korelaci a kontrole.
- Mezera v přiřazeném streamu se nedoplňuje z jiného streamu. Spotřeba přes mezeru se spočítá z nejbližších odečtů přiřazeného streamu, protože počítadlo je kumulativní. Hranice měsíce se pak označí jako nepřesná, s uvedením skutečného času použitých odečtů.
- Pokles E(t) bez výměny měřidla je anomálie. Do spotřeby se nezapočte a čeká na rozhodnutí administrátora.

### Přechod na jiný zdroj

Přechod je vždy explicitní akce administrátora (`POST /admin/meters/{id}/source-assignments`). Systém sám zdroj nepřepíná. Když přiřazený stream mlčí déle než nastavená doba a jiný stream měřidlo přijímá, jen navrhne přechod a zobrazí anomálii.

1. Administrátor zadá cílový stream, čas přechodu T (výchozí teď) a důvod. T v minulosti vyžaduje výslovné potvrzení a přepočet.
2. Navázání:
   - `handover_from` = poslední odečet starého streamu ≤ T, hodnota V1,
   - `handover_to` = první odečet nového streamu ≥ T, hodnota V2.

   Když nový stream ještě nedodal odečet, přiřazení vznikne se stavem `pending` a spotřeba se po T nepočítá, dokud odečet nepřijde.
3. Kontroly:
   - stejný registr a jednotka po normalizaci adaptérem,
   - `V2 ≥ V1`,
   - `V2 − V1 ≤ max_flow_per_hour × (t2 − t1)`, pokud je limit nastaven,
   - u měření obou streamů s blízkým časem musí rozdíl hodnot ležet v toleranci. To odhalí posun nebo jiné měřítko.
4. Výsledek: `verified`, nebo zablokování. Zablokovaný přechod může administrátor potvrdit (`admin_confirmed`) jen s důvodem. Systém nikdy sám neopravuje posun ani měřítko.
5. Uložení v jedné transakci:
   - ukončit staré přiřazení (`valid_to = T`) a založit nové,
   - zapsat odkazy na hraniční odečty,
   - zapsat `audit_logs` s hodnotami V1, V2, výsledkem kontrol a důvodem,
   - naplánovat přepočet `meter_daily_values` od t1.

## Zařízení

Identita zařízení a identita měřidla jsou dvě osy. Měřidlo nemá sloupec koncentrátoru. Kdo ho zachytil, plyne z příjmů.

### `devices`

`id`, `code UNIQUE` (`ESP-SJV-001`, `ACRIOS-SJV-001`), `kind` (`esp32`, `concentrator`, `import_channel`), `vendor NULL`, `model NULL`, `hardware_revision NULL`, `adapter NULL`, `source_stream_id NULL`, `status` (`active`, `disabled`, `revoked`), `last_seen_at`, `last_ip`, `clock_offset_ms NULL`, `clock_checked_at NULL`, `created_at`

- `id` je interní surrogate klíč. Po INSERT se nemění, po vyřazení zařízení se znovu nepřidělí a řádek se nemaže.
- `code` je stabilní kód SJV a u MQTT zároveň uživatelské jméno. Není to IMSI, IMEI, sériové číslo ani identifikátor platformy.
- `vendor`, `model` a `hardware_revision` jsou popis. Jejich změna jde do `audit_logs` a `id` nemění. Nevyplňují se odhadem, dokud nejsou známé.
- `adapter` je výchozí adaptér pro nové zprávy tohoto zařízení. Zpráva si verzí adaptéru uloženou na příjmu pamatuje, čím byla rozdělena. Pozdější změna adaptéru staré payloady nepřepisuje.
- Jedno zařízení může mít víc transportů. Sloupec `protocol` ani `payload_kind` proto v tabulce není. Schopnosti jsou v `device_capabilities`.
- Výměna hardwaru je nové `devices.id`. Staré zařízení se odvolá. Měřidla se nepřepisují, protože na koncentrátor vazbu nemají.

### `device_external_ids` (historie identifikátorů)

`id`, `device_id → devices`, `kind` (`imsi`, `imei`, `iccid`, `serial`, `platform_id`, `mqtt_client_id`, `mac`, `esp_instance`, `other`), `value`, `valid_from`, `valid_to NULL`, `origin` (`admin`, `heartbeat`, `api`, `import`), `created_at`

- Částečný exclusion constraint. `kind` je v klíči, takže zařízení má v jednu chvíli nejvýš jedno IMSI a nejvýš jedno IMEI a tyto druhy se navzájem neblokují:

```sql
EXCLUDE USING gist (
    device_id WITH =,
    kind WITH =,
    tstzrange(valid_from, valid_to, '[)') WITH &&
) WHERE (kind IN ('imsi', 'imei', 'iccid', 'esp_instance'))
```

  `serial`, `platform_id`, `mac` a `other` mohou být souběžně víc hodnot. Aktivní unikátnost hodnoty drží index níže.
- `CREATE UNIQUE INDEX ON device_external_ids (kind, value) WHERE valid_to IS NULL`
- IMSI, IMEI ani ICCID nejsou primární klíč. Výměna SIM: otevřené řádky `imsi` a `iccid` dostanou `valid_to` a vloží se nové hodnoty se stejným `device_id`. Historie zařízení zůstane na původním `id`. IMEI se při výměně SIM nemění.
- Stejná aktivní hodnota nesmí patřit dvěma zařízením. Když autentizované zařízení ohlásí identifikátor, který drží jiné aktivní zařízení, řádek se nepřesune. Vznikne událost `external_id_conflict` a zásah zůstane na administrátorovi.
- Nové zařízení se z dosud neznámého IMSI, IMEI ani identifikátoru v těle zprávy nezakládá.
- `esp_instance` je `instance_id` firmwaru ESP. Po vymazání flash vznikne nová hodnota u stejného `device_id`. Krátkodobá vazba na epochu bootu zůstává v `device_boots`.

### `device_firmware_history`

`id`, `device_id → devices`, `firmware_version`, `valid_from`, `valid_to NULL`, `origin` (`heartbeat`, `api`, `admin`)

- `EXCLUDE USING gist (device_id WITH =, tstzrange(valid_from, valid_to, '[)') WITH &&)`
- Otevřený řádek je aktuální firmware. Nová verze z heartbeatu nebo API uzavře předchozí řádek a vloží nový v jedné transakci, s auditem. `devices` sloupec firmware nemá, aby nevznikly dva zdroje.

### `device_placements` (historie umístění koncentrátoru a ostatních zařízení)

`id`, `device_id → devices`, `building_id NULL → buildings`, `location NULL`, `valid_from`, `valid_to NULL`, `reason`, `created_by`

- `EXCLUDE USING gist (device_id WITH =, tstzrange(valid_from, valid_to, '[)') WITH &&)`
- Je to historie instalace samotného zařízení, ne přiřazení měřidel. Výměna SIM umístění nemění. `devices.building_id` by tuto historii smazal, proto v `devices` není.

### `device_capabilities`

`id`, `device_id → devices`, `capability` (`mqtt`, `udp_dtls`, `https`, `platform_api`, `raw_wmbus`, `decoded_json`, `csv`, `fragmentation`), `detail jsonb NULL`, `valid_from`, `valid_to NULL`, `origin` (`admin`, `observed`, `vendor_doc`)

- `EXCLUDE USING gist (device_id WITH =, capability WITH =, tstzrange(valid_from, valid_to, '[)') WITH &&)`
- Záznam vzniká z administrace, z dokumentace po PoC, nebo z toho, co zařízení skutečně poslalo. Z názvu ACRIOS se schopnost neodvozuje. Dva modely téhož výrobce mohou mít různou sadu řádků.
- `detail` smí obsahovat třeba prefix topicu, až je známý. Tajemství do něj nepatří.

### `device_credentials`

`id`, `device_id → devices`, `kind` (`mqtt_password`, `api_token`, `client_cert`, `dtls_psk`), `secret_hash NULL`, `cert_fingerprint NULL`, `created_at`, `revoked_at NULL`

- Příchozí tajemství je hash nebo otisk. Otevřená hodnota v tabulce není.
- Metoda se vybírá podle toho, co daný kus hardwaru umí. ESP používá heslo MQTT. U ACRIOS metoda není vybraná, dokud ji neukáže PoC. Jedno zařízení může mít víc řádků.
- Pravidla odvolání a rotace jsou v [security.md](security.md).

### `device_boots` (bez partitioningu, retence 60 dní)

`device_id`, `instance_id`, `boot_counter`, `epoch_est`, `epoch_uncertainty_ms`, `first_seen_at`, `last_seen_at`

- `PRIMARY KEY (device_id, instance_id, boot_counter)`
- `epoch_est` je odhad času startu zařízení v UTC. Používá se pro výpočet času zachycení ([data-ingestion.md](data-ingestion.md)).
- Platí pro zařízení, která posílají referenci bootu (vlastní ESP). Koncentrátor bez této reference řádek nemá a čas se bere z jeho vlastních údajů, nebo jako `server_only`. Chybějící `rx_uptime` se nedoplňuje.

## Ingest

Čtyři vrstvy z [data-ingestion.md](data-ingestion.md) sedí na těchto tabulkách. Názvy ze zadání, které by se s už existujícím modelem bily, jsou přejmenované:

| Zadání | V návrhu | Proč |
| --- | --- | --- |
| `device_external_ids` | `device_external_ids` | beze změny významu |
| `device_capabilities` | `device_capabilities` | beze změny významu |
| `ingest_endpoints` | `ingest_endpoints` | konfigurace příjmu, ne přijatá data |
| `ingest_sources` | `ingest_payloads` a `devices` | `source_streams` už je zdroj odečtů. Původní bajty jsou payload, původce je zařízení nebo koncový bod |
| `ingest_fragments` | `ingest_fragments` a `ingest_fragment_sets` | sada drží úplnost, timeout a hranici mezi zprávami. Samotný fragment by to neuměl |
| `ingest_rejections` | `ingest_rejections` | odmítnutá obálka. Výsledek jednotlivé položky zůstává na `ingest_receipts`, aby jeden příjem nebyl ve dvou tabulkách |
| dřívější `telegram_receipts` | `ingest_receipts` | jeden tvar příjmu pro všechny transporty |

Žádná tabulka odečtů se nejmenuje podle výrobce ani podle transportu. Všechny cesty končí v `meter_readings`.

### `ingest_endpoints` (bez partitioningu)

`id`, `code UNIQUE`, `transport` (`mqtt`, `https`, `udp_dtls`, `platform_api`, `file_import`), `adapter`, `status` (`planned`, `active`, `disabled`), `max_payload_bytes`, `max_batch_items NULL`, `config jsonb`, `description`

- `config` popisuje vazbu bez tajemství: filtr topiců, cestu HTTP, interval dotazu, číslo portu. Hesla, tokeny a klíče jsou v `endpoint_credentials`.
- Katalog počítá s kódy `esp-mqtt`, `esp-https`, `acrios-mqtt`, `acrios-udp`, `acrios-https`, `acrios-platform-api` a `import-csv`. Řádky ACRIOS zůstávají `planned`, dokud PoC nevyplní skutečnou konfiguraci. Prázdné topic názvy se nevymýšlejí.
- Vypnutý koncový bod data nepřijímá. Pokus se zapíše do `ingest_rejections` s důvodem `endpoint_disabled`, pokud už spojení došlo tak daleko.

### `endpoint_credentials`

`id`, `endpoint_id → ingest_endpoints`, `kind` (`bearer`, `basic`, `client_cert`, `dtls_psk`), `storage` (`hash`, `kek_enc`), `secret_hash NULL`, `secret_enc NULL`, `cert_fingerprint NULL`, `created_at`, `revoked_at NULL`

- `CHECK` drží právě jedno z `secret_hash`, `secret_enc`, `cert_fingerprint` podle `storage` a `kind`.
- Příchozí ověření je hash nebo otisk (`storage = hash`). Odchozí token platformy se musí umět použít znovu, proto je šifrovaný AES-256-GCM hlavním klíčem aplikace (`storage = kek_enc`), stejně jako klíče měřidel.
- Hodnota se neloguje a do `ingest_endpoints.config` ani do `ingest_payloads` se nekopíruje.

### `ingest_payloads` (měsíční partitions, 24 měsíců) — vrstva A

`id` (sekvence), `partition_month`, `endpoint_id`, `device_id NULL`, `transport`, `received_at`, `content_kind` (`wmbus_batch`, `wmbus_frame`, `json`, `csv`, `udp_datagram`, `api_response`, `opaque`), `mqtt_topic NULL`, `payload bytea`, `payload_sha256`, `size_bytes`, `origin` (`received`, `assembled`), `fragment_set_id NULL`, `fragment_set_partition_month NULL`, `metadata jsonb`

- `PRIMARY KEY (id, partition_month)`
- `partition_month` je měsíc `received_at` v UTC. U `origin = assembled` je to měsíc složení, shodný s měsícem sady fragmentů.
- `payload` jsou bajty, které přišly, bez překódování a bez ořezu. Topic MQTT je vedle nich, protože do těla zprávy nepatří, ale k příjmu ano.
- `origin = assembled` vznikne jen z úplné sady fragmentů a odkazuje na ni. Původní fragmenty v tabulce zůstávají. Složený payload je jejich spojení v daném pořadí, ne náhrada.
- `metadata` smí nést jméno souboru, identifikátor stránky API nebo netajné hlavičky. Autorizační hlavička se neukládá.
- Dekódovaná hodnota bez wM-Bus rámce má `content_kind` `json` nebo `csv` a nevytvoří řádek `raw_telegrams`.
- Tělo nad `max_payload_bytes` se sem nezapíše. Odmítnutí je jen v `ingest_rejections`, aby velké odmítnuté zprávy plnily disk.

### `ingest_message_keys` (bez partitioningu, 60 dní)

`device_id`, `msg_key text`, `message_kind` (`telegram`, `decoded`, `event`, `heartbeat`, `import_row`), `first_received_at`, `last_received_at`, `delivery_count`, `outcome`, `receipt_id NULL`, `receipt_partition_month NULL`

- `PRIMARY KEY (device_id, msg_key)`
- `outcome` je výsledek první položky, jeden ze stavů ACK ([data-ingestion.md](data-ingestion.md)).
- `delivery_count` začíná na 1. Každé další doručení téhož klíče ho zvýší, přidá příjem `duplicate_delivery` a odečet nezaloží.
- `device_id` je součást klíče, protože stejný `msg_key` dvou koncentrátorů jsou dva příjmy. U zařízení, které identifikátor zprávy nemá, je `msg_key` rovné `sha256` kanonického těla položky. To chytá opakované doručení stejného těla. Nový telegram se stejnou hodnotou a jiným časem nebo jiným ACC má jiné tělo, tedy jiný klíč.

### `telegram_dedup_keys` (bez partitioningu, 60 dní)

```sql
CREATE TABLE telegram_dedup_keys (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    meter_key            bytea       NOT NULL,  -- M (2 B) + A (6 B)
    access_number        smallint    NOT NULL,  -- -1, pokud rámec ACC nemá
    frame_hash           bytea       NOT NULL,  -- sha256 kanonického rámce
    anchor_at            timestamptz NOT NULL,  -- odhad času zachycení prvního příjmu
    dedup_window         tstzrange   NOT NULL,  -- [anchor_at - W/2, anchor_at + W/2)
    raw_telegram_id      bigint      NOT NULL,
    raw_partition_month  date        NOT NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    EXCLUDE USING gist (
        meter_key     WITH =,
        access_number WITH =,
        frame_hash    WITH =,
        dedup_window  WITH &&
    )
);
CREATE INDEX ON telegram_dedup_keys (meter_key, access_number, frame_hash);
```

- Chybějící ACC se ukládá jako `-1`. Hodnoty `NULL` by se v exclusion constraintu nikdy nesrazily.
- `anchor_at` ani okno se po zápisu nemění, takže okna se neřetězí.
- Druhý index slouží k hledání stejného obsahu v celé retenci (kotva `server_only`, podezření na replay).

### `raw_telegrams` (měsíční partitions, 24 měsíců)

`id` (sekvence `raw_telegrams_id_seq`, hodnota se alokuje před vložením), `partition_month`, `meter_key`, `meter_id NULL`, `access_number`, `ci_field`, `encryption_mode`, `canonical_frame bytea`, `frame_hash`, `normalizer_version`, `anchor_at`, `time_source`, `first_server_received_at`, `receipt_count`, `capture_device_ids bigint[]`, `decode_status` (`pending`, `decoded`, `failed`, `no_key`, `suspect_replay`), `decode_error NULL`, `decoder_version NULL`

- `PRIMARY KEY (id, partition_month)`
- Telegramy neznámých měřidel se do této tabulky neukládají ([data-ingestion.md](data-ingestion.md)).
- Řádek vznikne jen ze skutečného wM-Bus rámce. JSON, CSV ani odpověď API sem nepatří a fiktivní rámec se pro ně nevytváří.
- `canonical_frame` je kanonická podoba po ověření CRC. Původní bajty obálky jsou v `ingest_payloads`, vyříznutý rámec na příjmu. Kanonická podoba původní data nenahrazuje.

### `ingest_receipts` (měsíční partitions, 24 měsíců) — vrstva B

`id` (sekvence), `partition_month`, `payload_id`, `payload_partition_month`, `item_index NULL`, `endpoint_id`, `device_id NULL`, `device_attribution` (`authenticated`, `mapped`, `unattributed`), `message_kind` (`raw_wmbus`, `decoded`, `event`, `heartbeat`, `import_row`), `msg_key`, `external_message_id NULL`, `transport` (`mqtt`, `https`, `udp_dtls`, `platform_api`, `file_import`), `server_received_at`, `device_rx_unix_ms NULL`, `rx_instance_id NULL`, `rx_boot NULL`, `rx_uptime_ms NULL`, `age_ms NULL`, `tx_at NULL`, `tx_uptime_ms NULL`, `captured_at_est`, `time_source` (`boot_epoch`, `device_clock`, `server_only`), `time_uncertainty_ms`, `time_flags text[]`, `rssi NULL`, `frame_format NULL`, `original_frame bytea NULL`, `fragment_set_id NULL`, `raw_telegram_id NULL`, `decoded_observation_id NULL`, `status`

- `PRIMARY KEY (id, partition_month)`
- `FOREIGN KEY (payload_id, payload_partition_month) REFERENCES ingest_payloads (id, partition_month)`
- `FOREIGN KEY (raw_telegram_id, partition_month) REFERENCES raw_telegrams (id, partition_month)`
- `FOREIGN KEY (decoded_observation_id, partition_month) REFERENCES decoded_observations (id, partition_month)`
- `status`: `new_telegram`, `duplicate`, `probable_duplicate`, `duplicate_delivery`, `suspect_replay`, `unknown_meter`, `unknown_device`, `crc_error`, `invalid`, `too_old`, `accepted`, `conflict`. Stavy ACK pro ESP se nemění. `new_telegram` na příjmu odpovídá ACK `accepted`.
- `device_id` pochází z autentizace. NULL je jen u záznamu z Platform API, jehož vnitřní identifikátor koncentrátoru ještě není v `device_external_ids`. U známého měřidla se položka zpracuje a `status` zůstane stavem položky; v `time_flags` se nepřidává nic, attribution nese sloupec `device_attribution` (`authenticated`, `mapped`, `unattributed`). Neznámý koncentrátor u MQTT, HTTPS tokenu a DTLS nenastane, protože `device_id` je z autentizace povinné a tělo ho nepřepíše. Nové zařízení z těla zprávy nevznikne.
- U příjmu bez telegramu je `raw_telegram_id NULL`. `partition_month` je měsíc `captured_at_est`, a když odhad není, měsíc `server_received_at`.
- Opakované doručení stejného `(device_id, msg_key)` vloží další příjem `duplicate_delivery` do partition původního výsledku, zvýší `delivery_count` a nevloží telegram, pozorování ani odečet.
- `original_frame` je vyříznutý wM-Bus rámec, bajtově shodný s polem v obálce. U dekódovaného JSON zůstane NULL. Obálka v `ingest_payloads` je záznam toho, co přišlo na transport. Rámec na příjmu je položka, nad kterou běží normalizace. Není to druhý datový model.
- Údaje času od zařízení se ukládají, jen když je zdroj poslal. Chybějící `rx_uptime` u ACRIOS se nevymýšlí.

### `ingest_fragment_sets` (měsíční partitions, 24 měsíců)

`id` (sekvence), `partition_month`, `device_id`, `endpoint_id`, `group_key`, `expected_count NULL`, `received_count`, `status` (`collecting`, `complete`, `timed_out`, `conflict`, `rejected`), `first_received_at`, `deadline_at`, `assembled_payload_id NULL`, `assembled_payload_partition_month NULL`

- `PRIMARY KEY (id, partition_month)`
- `UNIQUE (device_id, group_key, partition_month)` drží jednu sadu. Fragment s klíčem už uzavřené sady se k ní nepřipojí a novou sadu ve stejném měsíci nezaloží: je to odmítnutí, ne sloučení dvou zpráv. Dokud PoC neukáže, jestli zařízení identifikátor znovu používá, adaptér klíč neprodlužuje o domyšlenou předponu.
- `partition_month` se bere z prvního fragmentu a další fragmenty téže sady ho používají i přes půlnoc měsíce.
- `deadline_at` je `first_received_at + INGEST_FRAGMENT_TIMEOUT`. Délka timeoutu se doplní podle PoC. Do té doby je sloupec připravený a žádný model se nepředpokládá.
- `FOREIGN KEY (assembled_payload_id, assembled_payload_partition_month) REFERENCES ingest_payloads (id, partition_month)` se vyplní jen při `status = complete`.

### `ingest_fragments` (měsíční partitions, 24 měsíců)

`id` (sekvence), `partition_month`, `fragment_set_id`, `fragment_index int`, `payload_id`, `payload_partition_month`, `content_hash bytea`, `received_at`, `delivery_count`

- `PRIMARY KEY (id, partition_month)`
- `UNIQUE (fragment_set_id, partition_month, fragment_index)`
- `FOREIGN KEY (fragment_set_id, partition_month) REFERENCES ingest_fragment_sets (id, partition_month)`
- `FOREIGN KEY (payload_id, payload_partition_month) REFERENCES ingest_payloads (id, partition_month)`
- Stejný index a stejný `content_hash` jen zvýší `delivery_count`. Jiný hash při stejném indexu přepne sadu na `conflict`.
- Fragment není příjem odečtu a není vstup dekodéru. Vstupem je až složený payload kompletní sady, a ten projde obyčejnou cestou `ingest_receipts`.

### `ingest_rejections` (měsíční partitions, 24 měsíců)

`id` (sekvence), `partition_month`, `received_at`, `endpoint_id NULL`, `device_id NULL`, `transport`, `reason` (`auth_failed`, `payload_too_large`, `replay`, `stale`, `fragment_timeout`, `fragment_conflict`, `fragment_unidentified`, `unparseable`, `endpoint_disabled`, `rate_limited`), `payload_id NULL`, `payload_partition_month NULL`, `fragment_set_id NULL`, `fragment_set_partition_month NULL`, `detail jsonb`

- `PRIMARY KEY (id, partition_month)`
- `partition_month` je měsíc `received_at`.
- Sem patří obálka, ze které nevznikla položka. CRC, neznámé měřidlo, `too_old` a konflikt hodnoty jsou stavy `ingest_receipts`, ne druhý zápis sem.
- `detail` nemá hesla, tokeny ani tělo, které bylo odmítnuté kvůli velikosti. U `payload_too_large` se uloží jen `size_bytes` a identifikátor volajícího (kód zařízení nebo kód koncového bodu).
- `FOREIGN KEY` na payload je vyplněný, jen když se obálka vešla do limitu a přesto byla odmítnutá (třeba nečitelný formát nebo timeout fragmentů).

### `unknown_meter_sightings` (bez partitioningu)

`meter_key`, `first_seen_at`, `last_seen_at`, `sighting_count`, `last_device_id`, `last_rssi`

- `PRIMARY KEY (meter_key)`
- Řádky nezaznamenané 90 dní se mažou. Rámce neznámých měřidel se neukládají.

### `decoded_observations` (měsíční partitions, 24 měsíců)

`id` (sekvence), `partition_month`, `device_id NULL`, `msg_key`, `source_stream_id`, `external_meter_ref`, `meter_id NULL`, `source_measured_at`, `source_time_kind` (`meter_clock`, `concentrator_rx`, `platform_time`, `unknown`), `server_received_at`, `access_number NULL`, `values jsonb`, `vendor_payload jsonb NULL`, `payload_id`, `payload_partition_month`, `adapter`, `adapter_version`, `status` (`accepted`, `duplicate`, `conflict`, `unknown_meter`, `invalid`)

- `PRIMARY KEY (id, partition_month)`
- `FOREIGN KEY (payload_id, payload_partition_month) REFERENCES ingest_payloads (id, partition_month)`
- `vendor_payload` je původní JSON položky, když je obálka dávka a položka není celá obálka. Když je obálka právě ta položka, stačí `payload_id` a `vendor_payload` zůstane NULL. V obou případech je původní text uložený. Rámec se kvůli tomu nevytváří.
- `source_time_kind = platform_time` znamená čas, o kterém adaptér ví jen to, že ho přidala platforma. PoC teprve ukáže, jestli ACRIOS takový čas posílá. Do odečtu se pak dostane s `time_basis = source_time` a do spotřeby jako hraniční hodnota se nepoužije, stejně jako `time_unknown`.
- `device_id` může být NULL jen u nepřirazeného záznamu z platformy, viz `ingest_receipts`.

### `decode_queue` (bez partitioningu)

`raw_telegram_id`, `raw_partition_month`, `attempts`, `next_attempt_at`, `locked_by NULL`, `locked_at NULL`, `last_error NULL`

- `PRIMARY KEY (raw_telegram_id, raw_partition_month)`
- `FOREIGN KEY (raw_telegram_id, raw_partition_month) REFERENCES raw_telegrams (id, partition_month)`. Cizí klíč záměrně brání smazání partition, ve které ještě čekají telegramy na dekódování.
- Worker bere úlohy přes `FOR UPDATE SKIP LOCKED`. Po N neúspěších (nastavitelné) dostane telegram `decode_status = failed` a úloha se smaže.

## Odečty

### `meter_readings` (bez partitioningu, trvale)

`id`, `meter_id`, `source_stream_id`, `source_key text NOT NULL`, `source_kind` (`radio`, `vendor_decoded`, `manual`, `correction`, `import`), `reading_kind` (`cumulative`, `interval`, `event`), `quality` (`valid`, `suspect`, `invalid`), `raw_telegram_id NULL`, `decoded_observation_id NULL`, `measured_at`, `time_basis` (`meter_clock`, `capture_estimate`, `source_time`, `manual`), `time_source`, `primary_value numeric(18,6) NULL`, `unit NULL`, `quantity NULL`, `values jsonb`, `status_flags text[]`, `decoder_version NULL`, `adapter NULL`, `adapter_version NULL`, `normalizer_version NULL`, `frame_hash NULL`, `receipt_count`, `capture_device_ids bigint[]`, `corrects_reading_id NULL → meter_readings`, `accepted_at NULL`, `accepted_by NULL`, `superseded_at NULL`, `created_at`, `created_by NULL`

Constrainty a indexy:

- `UNIQUE (source_key)` je globální idempotence. Formát klíče:
  - `raw:<raw_telegram_id>`
  - `vobs:<decoded_observation_id>`
  - `manual:<uuid>`
  - `correction:<uuid>`
  - `import:<dávka>:<řádek>`
- `CHECK (reading_kind <> 'cumulative' OR primary_value IS NOT NULL)`
- `CREATE UNIQUE INDEX ON meter_readings (meter_id, source_stream_id, measured_at) WHERE source_kind = 'vendor_decoded' AND superseded_at IS NULL`
  Index identifikuje měření časem zdroje uvnitř jednoho streamu. Stejná hodnota v jiném čase je jiný řádek. Stejná hodnota sama indexem není.
- `(meter_id, measured_at)`, `(meter_id, source_stream_id, measured_at)`, BRIN na `measured_at`.
- Trigger povolí `UPDATE` jen u `superseded_at`, `receipt_count`, `capture_device_ids`, `accepted_at` a `accepted_by`. Hodnota, čas, měřidlo, druh, kvalita, zdroj ani verze dekodéru se nemění.
- `reading_kind = cumulative` je stav počítadla. `interval` je přírůstek za období dodaný zdrojem. `event` je událost bez kumulativní hodnoty (`primary_value` smí být NULL). Do spotřeby a do aktuálního stavu R15 vstupuje jen kumulativní primární hodnota.
- `quality` se nastaví při vložení. `suspect` (pokles, průtok, neznámý čas) se do spotřeby nepočítá, dokud administrátor nevyplní `accepted_at`. `invalid` se nepřijme ani potom. Přijetí nemění hodnotu a zapisuje se do auditu.
- `values` nese další registry téže zprávy, každý s `quantity`, `kind`, `value`, `unit` a `quality`. Nejsou to další řádky `meter_readings` a do spotřeby samy nevstupují.
- `quantity` je veličina primární hodnoty (objem, energie, jednotky poměrového měřiče a další až podle měřidla).
- Na `raw_telegrams`, `decoded_observations` ani `ingest_payloads` není cizí klíč. `frame_hash`, verze dekodéru, adaptéru a normalizátoru, `receipt_count` a `capture_device_ids` uchovají původ odečtu i po smazání příjmu a payloadu. Vazba za života dat je `source_key` → telegram nebo pozorování → `ingest_receipts` → `ingest_payloads`.
- `adapter` a `adapter_version` jsou verze, která uloženou hodnotu vytvořila. Opětovné dekódování je popsané v [data-ingestion.md](data-ingestion.md).

### Opravy

Postup v jedné transakci:

1. vloží se nový řádek se `source_kind = 'correction'`, stejným `source_stream_id` a `corrects_reading_id`,
2. původní řádek dostane `superseded_at`,
3. `audit_logs` dostane starou a novou hodnotu a povinný důvod,
4. naplánuje se přepočet dotčených dnů.

### `meter_daily_values` (bez partitioningu, trvale)

`meter_id`, `day date` (`Europe/Prague`), `first_value`, `first_at`, `last_value`, `last_at`, `reading_count`, `stream_ids smallint[]`, `flags text[]`, `computed_at`

- `PRIMARY KEY (meter_id, day)`
- Počítá se z efektivní řady, tedy jen z kumulativních hodnot přiřazených streamů. V den přechodu zdroje obsahuje hraniční hodnoty obou streamů téhož počítadla a příznak `source_handover`.
- Přepočet spouští opravy, přechody zdroje a změny instalací (`maintenance.sh` a worker).

## Provoz a audit

### `device_events` (měsíční partitions, 12 měsíců)

`id` (sekvence), `partition_month`, `device_id`, `msg_key NULL`, `kind`, `occurred_at`, `received_at`, `payload jsonb`

- `PRIMARY KEY (id, partition_month)`
- `FOREIGN KEY (device_id) REFERENCES devices`. Zařízení se nemažou, jen vyřazují.
- Heartbeat aktualizuje `devices` a `device_boots`. Do událostí se zapíše jen změna stavu a hodinový vzorek. Nová verze firmware založí řádek `device_firmware_history`. Původní tělo heartbeatu je v `ingest_payloads` a má příjem `message_kind = heartbeat`, odečet nezakládá.

### `notifications` (bez partitioningu)

`id`, `kind`, `recipient`, `subject`, `body`, `status` (`pending`, `sent`, `failed`), `attempts`, `created_at`, `sent_at NULL`

- Odesílá worker přes SMTP. Odeslané a neúspěšné řádky se mažou po 90 dnech (návrh).

### `audit_logs` (bez partitioningu, dlouhodobě)

`id`, `occurred_at`, `actor_kind` (`user`, `device`, `system`), `actor_id NULL`, `action`, `entity_type`, `entity_id`, `before jsonb`, `after jsonb`, `reason NULL`, `ip NULL`, `request_id NULL`, `prev_hash`, `row_hash`

- Žádná aplikační role nemá `UPDATE` ani `DELETE`.
- `row_hash = sha256(prev_hash || kanonický JSON řádku)`. Zápis je serializovaný přes `pg_advisory_xact_lock` s pevným klíčem.
- Odkazy na entity jsou bez cizích klíčů. Audit přežije anonymizaci uživatele i vyřazení zařízení.

### Ostatní

| Tabulka | Retence |
| --- | --- |
| `sessions` (hash id, expirace) | po expiraci |
| `login_attempts` | 90 dní (návrh k potvrzení) |
| `password_reset_tokens`, `invitations` (hash tokenu, expirace) | po expiraci |

## Retence a vazby

| Data | Retence | Způsob |
| --- | --- | --- |
| `meter_readings`, `meter_daily_values` | trvale | nemažou se |
| `audit_logs` | dlouhodobě | nemažou se |
| `ingest_payloads`, `ingest_receipts`, `ingest_fragments`, `ingest_fragment_sets`, `ingest_rejections`, `raw_telegrams`, `decoded_observations` | 24 měsíců | odpojení a smazání partition |
| `device_events` | 12 měsíců | odpojení a smazání partition |
| `ingest_message_keys`, `telegram_dedup_keys`, `device_boots` | 60 dní | `DELETE` v dávkách |
| `device_external_ids`, `device_firmware_history`, `device_placements`, `device_capabilities` | trvale s historií | řádky se neuzavírají mazáním, jen `valid_to` |
| `unknown_meter_sightings` | 90 dní od posledního zachycení | `DELETE` |
| `login_attempts`, `notifications` | 90 dní (návrh) | `DELETE` |

Pořadí v `maintenance.sh` pro měsíc M starší než 24 měsíců:

1. Kontrola, že v `decode_queue` neexistuje řádek s `raw_partition_month = M`. Pokud existuje, retence měsíce M se odloží a vznikne alarm. Cizí klíč by mazání stejně zablokoval.
2. Kontrola, že každý telegram z M ve stavu `decoded` má odečet `raw:<id>`. Chybějící odečet znamená alarm a odklad.
3. Kontrola, že na payloady měsíce M neodkazuje příjem, fragment, sada, odmítnutí ani pozorování z jiného měsíce. Údržba mazává od nejstaršího měsíce a stáří zprávy je nejvýš 30 dní, takže odkaz může vést jen z M−1 a ten už je smazaný. Jinak se měsíc odloží.
4. `ALTER TABLE … DETACH PARTITION … CONCURRENTLY` a `DROP` v tomto pořadí: `ingest_receipts_<M>`, `ingest_fragments_<M>`, `ingest_fragment_sets_<M>`, `ingest_rejections_<M>`, `decoded_observations_<M>`, `ingest_payloads_<M>`, `raw_telegrams_<M>`. Příjmy odkazují na telegramy, pozorování i payloady. Pozorování odkazují na payloady. Fragmenty odkazují na sady a payloady, sady na složený payload.
5. Záznam do `audit_logs` (actor `system`): měsíc, tabulka, počet řádků.

Smazání nemůže poškodit odečty, protože `meter_readings` nemají cizí klíče na mazané tabulky a jejich `source_key` zůstává unikátní (sekvence se neopakují).

Partitions se zakládají předem pro aktuální a 3 následující měsíce. DEFAULT partition se nepoužívá. `partition_month` vychází z času ověřeného ingestem, takže hodnota mimo existující partitions je chyba, která se má projevit.

## Odhad objemu

Počet měřidel (N), interval vysílání v sekundách (i) a průměrný počet přijímačů na telegram (R) zatím nejsou známé.

- unikátní telegramy za den = `N × 86400 / i`
- příjmy za den = `telegramy × R`, plus heartbeat každého zařízení a případné obálky API
- odečty za rok ≈ `telegramy za den × 365` (jen skutečné odečty; opakované doručení a druhý koncentrátor počet odečtů nezvýší)
- objem `ingest_payloads` závisí na velikosti obálek. Heartbeat se ukládá celý. Čísla se dosadí až s počtem zařízení, ne odhadem pro ACRIOS.

Před fází 4 se dosadí skutečné hodnoty. Kdyby trvalé uchování všech odečtů bylo objemově neúnosné, ztenčování starých odečtů vyžaduje samostatné rozhodnutí, protože mění rozhodnutí „trvale“.

## Databázové role

| Role | Práva |
| --- | --- |
| `sjv_bootstrap` | superuser z image. Používá jen `deploy.sh` |
| `sjv_owner` | vlastník schématu. Používá jen Alembic |
| `sjv_api` | čtení. Zápis kmenových dat, členství, instalací, přiřazení zdrojů, externích identifikátorů, schopností, umístění, firmwaru z administrace, koncových bodů, ručních odečtů a oprav. INSERT do auditu a notifikací. `endpoint_credentials` smí vkládat a odvolávat. `secret_enc` nečte |
| `sjv_collector` | zápis do ingest tabulek včetně payloadů, fragmentů a odmítnutí, `device_boots`, `unknown_meter_sightings`, `device_events`, pozorované schopnosti a firmware z heartbeatu, aktualizace `devices.last_seen_at`. Zařízení nezakládá a `secret_enc` nečte |
| `sjv_worker` | `decode_queue`, timeout fragmentů, INSERT `meter_readings`, `notifications`, agregace. Odchozí token platformy dešifruje jen v paměti, stejně jako klíč AES |
| `sjv_maintenance` | partitions, retence, přepočty, INSERT auditu |
| `sjv_readonly` | jen čtení, pro `restore-test.sh` a `backup-verify.sh` |
| `pgbackrest` | lokální přístup pro zálohy |

Role se zakládají jako v referenci: heslo jde přes `\getenv` a nikdy není v argumentu procesu. Row-Level Security je případná pozdější druhá vrstva.

## Migrace

- Alembic v `app/backend/alembic/`, jen dopředné migrace. Před každou migrací `deploy.sh` vynutí čerstvou zálohu pgBackRest, takže se místo `downgrade` počítá s obnovou.
- Konvence pojmenování constraintů v SQLAlchemy `MetaData`.
- Partitions, exclusion constrainty, triggery a částečné indexy se píšou ručně (`op.execute`).
- `test.sh` ověří `alembic upgrade head` na prázdné DB a `alembic check`.
