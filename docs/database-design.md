# Databázový návrh

PostgreSQL 18.x, databáze `sjv`, schéma `public`.

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

1. **Partitionují se jen tabulky s časovou retencí:** `raw_telegrams`, `telegram_receipts`, `decoded_observations` (24 měsíců) a `device_events` (12 měsíců). Důvodem je levné mazání celé partition.
2. **Globální idempotence a deduplikace jsou v malých tabulkách bez partitioningu:**
   - `ingest_message_keys` s `PRIMARY KEY (device_id, msg_key)`,
   - `telegram_dedup_keys` s exclusion constraintem přes časové okno.

   Mají retenci 60 dní a ingest odmítne zprávy starší než `INGEST_MAX_MESSAGE_AGE` (30 dní). Každé možné opakování tak vždy narazí na existující klíč.
3. **Trvalé tabulky se nepartitionují** a mají globální `UNIQUE`: `meter_readings`, `meter_daily_values`, `audit_logs`, kmenová data.
4. **Partition klíč je `partition_month date`** (první den měsíce v UTC). Počítá ho server z ověřeného odhadu času zachycení a po zápisu se nemění. Příjem a jeho telegram mají stejné `partition_month`, takže cizí klíč `(raw_telegram_id, partition_month)` funguje a obě tabulky se mažou po stejných měsících.
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
- Aktuální stav ukazuje absolutní hodnotu počítadla, stejnou jako na displeji měřidla. Ta zahrnuje i spotřebu před členstvím. Je to návrh k potvrzení, viz [decisions.md](decisions.md).

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

`id`, `code UNIQUE`, `kind` (`radio`, `vendor_decoded`, `manual`), `description`

| Stream | Obsah |
| --- | --- |
| `radio` | všechny telegramy z rádia. Vlastní ESP i koncentrátory s exportem rámců tvoří jeden stream, protože deduplikace je slučuje na úrovni telegramu |
| `vendor:<kód>` | dekódované hodnoty jednoho systému dodavatele (může mít více koncentrátorů) |
| `manual` | ruční odečty administrátora |

`devices.source_stream_id` určuje, kam patří decoded data zařízení. Raw data jdou vždy do `radio`.

### `meter_source_assignments` (preferovaný zdroj)

`id`, `meter_id`, `source_stream_id`, `valid_from`, `valid_to NULL`, `handover_from_reading_id NULL`, `handover_to_reading_id NULL`, `handover_status` (`initial`, `pending`, `verified`, `admin_confirmed`), `reason`, `created_by`, `created_at`

- `EXCLUDE USING gist (meter_id WITH =, tstzrange(valid_from, valid_to, '[)') WITH &&)`
- Každé aktivní měřidlo má v každém okamžiku od první instalace právě jedno přiřazení. Založení měřidla bez počátečního přiřazení API nepřijme a `maintenance.sh` hlásí každou mezeru.

### Efektivní řada a výpočet spotřeby

- Efektivní řada měřidla E(t) se skládá jen z odečtů streamu, který je v čase t přiřazený, plus z hraničních hodnot instalací (`initial_value`, `final_value`).
- Spotřeba v intervalu ⟨a, b⟩ uvnitř jedné instalace je `E(b) − E(a)`, tedy rozdíl dvou absolutních hodnot téhož počítadla.
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

### `devices`

`id`, `code UNIQUE` (`ESP-SJV-001`), `kind` (`esp32`, `concentrator`), `vendor`, `model`, `serial`, `firmware_version`, `protocol` (`mqtt`, `https`), `payload_kind` (`raw`, `decoded`, `both`), `adapter NULL`, `source_stream_id NULL`, `building_id NULL`, `instance_id NULL`, `status` (`active`, `disabled`, `revoked`), `last_seen_at`, `last_ip`, `clock_offset_ms NULL`, `clock_checked_at NULL`, `created_at`

### `device_credentials`

`id`, `device_id`, `kind` (`mqtt_password`, `api_token`, `client_cert`), `secret_hash` nebo `cert_fingerprint`, `created_at`, `revoked_at NULL`

### `device_boots` (bez partitioningu, retence 60 dní)

`device_id`, `instance_id`, `boot_counter`, `epoch_est`, `epoch_uncertainty_ms`, `first_seen_at`, `last_seen_at`

- `PRIMARY KEY (device_id, instance_id, boot_counter)`
- `epoch_est` je odhad času startu zařízení v UTC. Používá se pro výpočet času zachycení ([data-ingestion.md](data-ingestion.md)).

## Ingest

### `ingest_message_keys` (bez partitioningu, 60 dní)

`device_id`, `msg_key text`, `message_kind` (`telegram`, `decoded`, `event`), `received_at`, `outcome`, `receipt_id NULL`, `receipt_partition_month NULL`

- `PRIMARY KEY (device_id, msg_key)`
- `outcome` je jeden ze stavů ACK ([data-ingestion.md](data-ingestion.md)).

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

### `telegram_receipts` (měsíční partitions, 24 měsíců)

`id` (sekvence), `partition_month`, `raw_telegram_id NULL`, `device_id`, `msg_key`, `transport` (`mqtt`, `https`), `server_received_at`, `device_rx_unix_ms NULL`, `rx_instance_id NULL`, `rx_boot NULL`, `rx_uptime_ms NULL`, `age_ms NULL`, `tx_at NULL`, `tx_uptime_ms NULL`, `captured_at_est`, `time_source` (`boot_epoch`, `device_clock`, `server_only`), `time_uncertainty_ms`, `time_flags text[]`, `rssi NULL`, `frame_format`, `original_frame bytea NULL`, `status` (`new_telegram`, `duplicate`, `probable_duplicate`, `suspect_replay`, `unknown_meter`, `crc_error`, `invalid`, `too_old`)

- `PRIMARY KEY (id, partition_month)`
- `FOREIGN KEY (raw_telegram_id, partition_month) REFERENCES raw_telegrams (id, partition_month)`
- U příjmu bez telegramu (`crc_error`, `invalid`, `unknown_meter`, `too_old`) je `raw_telegram_id NULL` a `partition_month` je měsíc `server_received_at`.
- Ukládá se skutečný čas přijetí na serveru (`server_received_at`), všechny údaje zařízení beze změny i výsledný odhad času zachycení.

### `unknown_meter_sightings` (bez partitioningu)

`meter_key`, `first_seen_at`, `last_seen_at`, `sighting_count`, `last_device_id`, `last_rssi`

- `PRIMARY KEY (meter_key)`
- Řádky nezaznamenané 90 dní se mažou. Rámce neznámých měřidel se neukládají.

### `decoded_observations` (měsíční partitions, 24 měsíců)

`id` (sekvence), `partition_month`, `device_id`, `msg_key`, `source_stream_id`, `external_meter_ref`, `meter_id NULL`, `source_measured_at`, `source_time_kind` (`meter_clock`, `concentrator_rx`, `unknown`), `server_received_at`, `access_number NULL`, `values jsonb`, `vendor_payload jsonb`, `adapter`, `adapter_version`, `status` (`accepted`, `duplicate`, `conflict`, `unknown_meter`, `invalid`)

- `PRIMARY KEY (id, partition_month)`

### `decode_queue` (bez partitioningu)

`raw_telegram_id`, `raw_partition_month`, `attempts`, `next_attempt_at`, `locked_by NULL`, `locked_at NULL`, `last_error NULL`

- `PRIMARY KEY (raw_telegram_id, raw_partition_month)`
- `FOREIGN KEY (raw_telegram_id, raw_partition_month) REFERENCES raw_telegrams (id, partition_month)`. Cizí klíč záměrně brání smazání partition, ve které ještě čekají telegramy na dekódování.
- Worker bere úlohy přes `FOR UPDATE SKIP LOCKED`. Po N neúspěších (nastavitelné) dostane telegram `decode_status = failed` a úloha se smaže.

## Odečty

### `meter_readings` (bez partitioningu, trvale)

`id`, `meter_id`, `source_stream_id`, `source_key text NOT NULL`, `source_kind` (`radio`, `vendor_decoded`, `manual`, `correction`, `import`), `raw_telegram_id NULL`, `decoded_observation_id NULL`, `measured_at`, `time_basis` (`meter_clock`, `capture_estimate`, `source_time`, `manual`), `time_source`, `primary_value numeric(18,6)`, `unit`, `values jsonb`, `status_flags text[]`, `decoder_version NULL`, `normalizer_version NULL`, `frame_hash NULL`, `receipt_count`, `capture_device_ids bigint[]`, `corrects_reading_id NULL → meter_readings`, `superseded_at NULL`, `created_at`, `created_by NULL`

Constrainty a indexy:

- `UNIQUE (source_key)` je globální idempotence. Formát klíče:
  - `raw:<raw_telegram_id>`
  - `vobs:<decoded_observation_id>`
  - `manual:<uuid>`
  - `correction:<uuid>`
  - `import:<dávka>:<řádek>`
- `CREATE UNIQUE INDEX ON meter_readings (meter_id, source_stream_id, measured_at) WHERE source_kind = 'vendor_decoded' AND superseded_at IS NULL`
- `(meter_id, measured_at)`, `(meter_id, source_stream_id, measured_at)`, BRIN na `measured_at`.
- Trigger povolí `UPDATE` jen u `superseded_at`, `receipt_count` a `capture_device_ids`. Hodnota, čas, měřidlo ani zdroj se nikdy nemění.
- Na `raw_telegrams` ani `decoded_observations` není cizí klíč. `frame_hash`, `decoder_version`, `normalizer_version`, `receipt_count` a `capture_device_ids` uchovají původ odečtu i po smazání telegramu a příjmů.

### Opravy

Postup v jedné transakci:

1. vloží se nový řádek se `source_kind = 'correction'`, stejným `source_stream_id` a `corrects_reading_id`,
2. původní řádek dostane `superseded_at`,
3. `audit_logs` dostane starou a novou hodnotu a povinný důvod,
4. naplánuje se přepočet dotčených dnů.

### `meter_daily_values` (bez partitioningu, trvale)

`meter_id`, `day date` (`Europe/Prague`), `first_value`, `first_at`, `last_value`, `last_at`, `reading_count`, `stream_ids smallint[]`, `flags text[]`, `computed_at`

- `PRIMARY KEY (meter_id, day)`
- Počítá se z efektivní řady, tedy jen z přiřazených streamů. V den přechodu zdroje obsahuje hraniční hodnoty obou streamů téhož počítadla a příznak `source_handover`.
- Přepočet spouští opravy, přechody zdroje a změny instalací (`maintenance.sh` a worker).

## Provoz a audit

### `device_events` (měsíční partitions, 12 měsíců)

`id` (sekvence), `partition_month`, `device_id`, `msg_key NULL`, `kind`, `occurred_at`, `received_at`, `payload jsonb`

- `PRIMARY KEY (id, partition_month)`
- `FOREIGN KEY (device_id) REFERENCES devices`. Zařízení se nemažou, jen vyřazují.
- Heartbeat aktualizuje `devices` a `device_boots`. Do událostí se zapíše jen změna stavu a hodinový vzorek.

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
| `raw_telegrams`, `telegram_receipts`, `decoded_observations` | 24 měsíců | odpojení a smazání partition |
| `device_events` | 12 měsíců | odpojení a smazání partition |
| `ingest_message_keys`, `telegram_dedup_keys`, `device_boots` | 60 dní | `DELETE` v dávkách |
| `unknown_meter_sightings` | 90 dní od posledního zachycení | `DELETE` |
| `login_attempts`, `notifications` | 90 dní (návrh) | `DELETE` |

Pořadí v `maintenance.sh` pro měsíc M starší než 24 měsíců:

1. Kontrola, že v `decode_queue` neexistuje řádek s `raw_partition_month = M`. Pokud existuje, retence měsíce M se odloží a vznikne alarm. Cizí klíč by mazání stejně zablokoval.
2. Kontrola, že každý telegram z M ve stavu `decoded` má odečet `raw:<id>`. Chybějící odečet znamená alarm a odklad.
3. `ALTER TABLE telegram_receipts DETACH PARTITION telegram_receipts_<M> CONCURRENTLY`, potom `DROP`.
4. Totéž pro `raw_telegrams_<M>` a `decoded_observations_<M>`.
5. Záznam do `audit_logs` (actor `system`): měsíc, tabulka, počet řádků.

Smazání nemůže poškodit odečty, protože `meter_readings` nemají cizí klíče na mazané tabulky a jejich `source_key` zůstává unikátní (sekvence se neopakují).

Partitions se zakládají předem pro aktuální a 3 následující měsíce. DEFAULT partition se nepoužívá. `partition_month` vychází z času ověřeného ingestem, takže hodnota mimo existující partitions je chyba, která se má projevit.

## Odhad objemu

Počet měřidel (N), interval vysílání v sekundách (i) a průměrný počet přijímačů na telegram (R) zatím nejsou známé.

- unikátní telegramy za den = `N × 86400 / i`
- příjmy za den = `telegramy × R`
- odečty za rok ≈ `telegramy za den × 365`

Před fází 4 se dosadí skutečné hodnoty. Kdyby trvalé uchování všech odečtů bylo objemově neúnosné, ztenčování starých odečtů vyžaduje samostatné rozhodnutí, protože mění rozhodnutí „trvale“.

## Databázové role

| Role | Práva |
| --- | --- |
| `sjv_bootstrap` | superuser z image. Používá jen `deploy.sh` |
| `sjv_owner` | vlastník schématu. Používá jen Alembic |
| `sjv_api` | čtení. Zápis kmenových dat, členství, instalací, přiřazení zdrojů, ručních odečtů a oprav. INSERT do auditu a notifikací |
| `sjv_collector` | zápis do ingest tabulek, `device_boots`, `unknown_meter_sightings`, `device_events`, aktualizace `devices.last_seen_at` |
| `sjv_worker` | `decode_queue`, INSERT `meter_readings`, `notifications`, agregace |
| `sjv_maintenance` | partitions, retence, přepočty, INSERT auditu |
| `sjv_readonly` | jen čtení, pro `restore-test.sh` a `backup-verify.sh` |
| `pgbackrest` | lokální přístup pro zálohy |

Role se zakládají jako v referenci: heslo jde přes `\getenv` a nikdy není v argumentu procesu. Row-Level Security je případná pozdější druhá vrstva.

## Migrace

- Alembic v `app/backend/alembic/`, jen dopředné migrace. Před každou migrací `deploy.sh` vynutí čerstvou zálohu pgBackRest, takže se místo `downgrade` počítá s obnovou.
- Konvence pojmenování constraintů v SQLAlchemy `MetaData`.
- Partitions, exclusion constrainty, triggery a částečné indexy se píšou ručně (`op.execute`).
- `test.sh` ověří `alembic upgrade head` na prázdné DB a `alembic check`.
