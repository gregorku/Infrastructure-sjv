# Databázový návrh

PostgreSQL 19.0, databáze `sjv`, schéma `public`, je centrální a jediný dlouhodobý zdroj pravdy pro data SJV (rozhodnutí 15–30, R31 a R33 v [decisions.md](decisions.md)). Konkrétní model ACRIOS, jeho firmware ani protokol tvar tabulek nemění. ACRIOS je kód partnera a adaptéru, ne předpona tabulek.

- ORM SQLAlchemy 2 s psycopg 3, migrace Alembic.
- Rozšíření `btree_gist` (exclusion constrainty) a `citext` (e-maily).
- Časy jsou `timestamptz` v UTC. Kalendářní dny (agregace, členství) se počítají v `Europe/Prague`.

## Partitioning a globální unikátnost

### Omezení PostgreSQL

1. Unikátní constraint a primární klíč na partitionované tabulce musí obsahovat všechny sloupce partition klíče. Unikátnost se vynucuje jen uvnitř jedné partition. PostgreSQL 19 nemá globální indexy.
2. Partition klíč v unikátním constraintu musí být prostý sloupec, ne výraz.
3. Exclusion constraint na partitionované tabulce je možný od PostgreSQL 17, ale jen se sloupci partition klíče porovnávanými přes `=`. Působí tedy také jen uvnitř partition.
4. Cizí klíč na partitionovanou tabulku je možný, ale musí odkazovat na unikátní klíč včetně partition klíče.
5. `ON CONFLICT` na partitionované tabulce vyžaduje unikátní index s partition klíčem. `ON CONFLICT DO NOTHING` bez cíle respektuje i exclusion constraint a při souběhu čeká na dokončení konkurenční transakce.
6. Partition, na jejíž řádky odkazuje cizí klíč, nejde odpojit ani smazat, dokud odkazující řádky existují.

### Řešení

1. **Partitionují se jen tabulky s časovou retencí po měsících:** `ingest_payloads`, `ingest_payload_items` a `ingest_receipts` (36 měsíců), `device_telemetry` (36 měsíců), `ingest_dedup_candidates`, `ingest_rejections`, `decoded_observations` a `raw_telegrams` (24 měsíců podle vlastního časového pravidla) a `device_events` (12 měsíců). Důvodem je levné mazání celé partition. `ingest_fragment_sets` a `ingest_fragments` partition nemají, protože jedinečnost otevřené sady a prvního řádku `(fragment_set_id, fragment_index)` musí platit přes hranici měsíce. Fragmenty se mažou `DELETE` 24 měsíců od `received_at`, sady až potom, když na ně fragment neukazuje. Dřívější `telegram_receipts` je sloučená do `ingest_receipts`.
2. **Globální idempotence a deduplikace jsou v malých tabulkách bez partitioningu:**
   - `ingest_message_keys` s `PRIMARY KEY (ingest_source_id, msg_key_namespace, msg_key, item_index)`. Všechny složky jsou `NOT NULL`. Řádek je prokázaná položka, ne celá zpráva bez rozlišení položek. Hash těla klíčem není. `device_id` v klíči není, protože import a platforma zařízení nemají.
   - `telegram_dedup_keys` s exclusion constraintem přes časové okno. Potvrzená shoda rámce platí jen uvnitř okna s důvěryhodnou kotvou.

   Klíče mají retenci 60 dní. Ingest odmítne zprávy starší než `INGEST_MAX_MESSAGE_AGE` (30 dní). Opakování prokázaného identifikátoru, které se ještě vejde do stáří, narazí na existující klíč. Stejný hash bez identifikátoru na klíč nenarazí.
3. **Trvalé tabulky se nepartitionují** a mají globální `UNIQUE`: `meter_readings`, `meter_daily_values`, `audit_logs`, `ingest_sources`, `reading_provenance`, `meter_replacement_events`, `meter_verifications`, kmenová data.
4. **`partition_month` je klíč partition.** Je to `date`, první den měsíce v UTC. Čas, kdy bajty dorazily, je vždy samostatný sloupec `received_at` nebo `server_received_at`.
   - `ingest_payloads.partition_month` je měsíc `received_at`.
   - `ingest_receipts.partition_month`, `ingest_dedup_candidates.partition_month` a `decoded_observations.partition_month` jsou měsíc `server_received_at`. Retence `ingest_receipts` je 36 měsíců, retence kandidátů a pozorování 24 měsíců od tohoto měsíce, ne od stáří telegramu, na který odkazují.
   - `ingest_payload_items.partition_month` je měsíc `received_at` příslušného payloadu a má stejnou 36měsíční hranici jako `ingest_payloads`.
   - `raw_telegrams.partition_month` je měsíc kotvy, ne měsíc pozdějšího příjmu. Pozdější příjem telegram do své partition nestěhuje a cizím klíčem ho nedrží.
   - `device_events.partition_month` je měsíc `received_at` v UTC. `received_at` je povinné. `occurred_at` je volitelný čas události a měsíc partition neurčuje.
   - Pozorování a položka mají `CHECK`, že měsíc payloadu je měsíc řádku, a cizí klíč `(payload_id, payload_partition_month)` na `ingest_payloads`. Fragment, odmítnutí a složený payload sady mají stejný cizí klíč. Příjem má `payload_id`, `payload_partition_month` a `CHECK` shody měsíce s `partition_month`, ale cizí klíč na payload nemá. Odmítnutí a sada mohou ukazovat na payload jiného měsíce. Retenční funkce proto před odstraněním payloadu sama spočítá zbývající odkazy.
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

- `aes_key_enc` je obálka AES klíče měřidla, ne odečet. Formát verze `0x01` je jeden bajt verze, 12 bajtů nonce, ciphertext a 16bajtový tag AES-256-GCM z knihovny `cryptography`. AAD je bajt verze. Klíč měřidla má 16 nebo 32 bajtů. Formát se nemění.
- `aes_key_fingerprint` ve schématu zůstává a aplikace do něj nezapisuje. Obyčejný hash klíče by umožnil slovníkové ověření. HMAC by potřeboval další tajemství, jeho zálohu a pravidlo rotace. Sloupec se proto neplní a schéma se kvůli tomu nemění.
- Odečty v `meter_readings` ani ostatní provozní sloupce se tímto KEK nešifrují. Zálohu šifruje Restic heslem `restic-key-password`. To je jiné tajemství než `app-kek`. Bez `app-kek` obálku klíče nerozbalí ani obnovená databáze.

### `meter_external_ids`

`id`, `meter_id`, `source_stream_id`, `external_id`

- `UNIQUE (source_stream_id, external_id)`
- Mapuje identifikátory dodavatele na měřidlo.

### `meter_installations`

`id`, `meter_id`, `apartment_id`, `location`, `installed_at`, `removed_at NULL`, `initial_value`, `final_value NULL`, `reason`, `seal_number`, `created_by`

- `EXCLUDE USING gist (meter_id WITH =, tstzrange(installed_at, removed_at, '[)') WITH &&)`
- Výměna = ukončení instalace s `final_value` a nová instalace nového fyzického měřidla s `initial_value`. Obě instalace spojí `meter_replacement_events` v jedné transakci a s auditem (R31).
- `initial_value` je povinné číslo. `final_value` smí být NULL, dokud instalace není původní stranou servisní výměny. Číselná nula je v obou sloupcích platný stav počítadla. NULL znamená, že hodnota chybí.
- `initial_value`, `final_value` a `seal_number` zůstávají jen na tomto řádku.
- Spotřeba různých fyzických měřidel v bytě (kuchyň, koupelna, staré a nové po výměně) se sčítá. Jde o různá počítadla, ne o dva zdroje téhož počítadla.
- Zákaz `DELETE` této tabulky je v odstavci Zákaz DELETE.

### `meter_replacement_events`

Servisní zásah, který spojí ukončenou a novou instalaci. Tabulka nepočítá spotřebu a nepřebírá stavy ani plomby.

`id`, `performed_at timestamptz`, `performed_by`, `reason`, `old_installation_id → meter_installations`, `new_installation_id → meter_installations`, `note NULL`, `created_by → users`, `created_at`

- `CHECK (old_installation_id <> new_installation_id)`
- `UNIQUE (old_installation_id)` a `UNIQUE (new_installation_id)`. Jedna instalace vystupuje nejvýš v jedné výměně jako původní a nejvýš v jedné jako nová.
- Oba cizí klíče jsou `ON DELETE RESTRICT`. Účinek je v odstavci Zákaz DELETE.
- `performed_by` je jméno technika nebo servisní firmy. Není to uživatelský účet a roli `technician` nezakládá. Ta zůstává nepřiřaditelná (rozhodnutí 8).
- `created_by` je administrátor, který záznam uložil. `created_at` je čas uložení a od `performed_at` se liší.

Důvod výměny je `meter_replacement_events.reason`. `reason` původní instalace se při výměně nemění, protože nese důvod jejího založení. Nová instalace dostane do svého povinného `reason` stejný text jako událost.

**Kontrola integrity**

`CHECK` ani cizí klíč neumí porovnat byt, měřidlo a časy dvou odkazovaných řádků, pokud se `apartment_id` a `meter_id` neuloží podruhé. Druhá kopie se nezakládá. Shodu hlídá jeden odložený constraint trigger. PostgreSQL 19 ho umí a nové rozšíření kvůli němu není potřeba. Trigger je odložený na konec transakce, takže vidí všechny její zápisy.

Trigger integrity je na dvou tabulkách:

- `meter_replacement_events` při `INSERT` a `UPDATE`,
- `meter_installations` při `UPDATE` řádku, na který po této transakci nějaká servisní událost odkazuje jako na původní nebo novou instalaci.

Tento trigger `DELETE` neodmítá. Samostatný trigger pro `DELETE` na `meter_installations`, `meter_replacement_events` ani `meter_verifications` definovaný není. Zákaz `DELETE` u těchto tří tabulek vynucuje oprávnění role `sjv_api`, ne aplikační kontrola a ne trigger. `UPDATE` tím zakázán není.

Při `UPDATE` události se kontrola řídí `old_installation_id` a `new_installation_id` tak, jak jsou po změně. Načte obě aktuálně odkazované instalace a ověří na nich celou vazbu, i když se změnil jen jeden odkaz a i když se řádek nově odkazované instalace v téže transakci sám nemění. Instalace, na kterou událost po změně už neodkazuje, do kontroly této události nepatří.

`INSERT` instalace sám událost nevyžaduje. První instalace a odebrání bez náhrady jím procházejí. Když stejná transakce vloží i událost, kontrola na konci obě strany spojí.

Kontrola načte událost a obě instalace a vyžaduje současně:

- obě instalace existují a jejich `id` se liší,
- obě mají stejné `apartment_id`,
- `meter_id` obou se liší,
- `removed_at` původní instalace a `installed_at` nové instalace se rovnají `performed_at`,
- `removed_at` původní instalace je pozdější než její `installed_at`,
- `final_value` původní instalace není NULL,
- `initial_value` nové instalace není NULL,
- `reason` nové instalace se rovná `reason` události.

Nula v `final_value` nebo `initial_value` kontrolou projde. `reason` původní instalace se s událostí neporovnává. `location` se nekopíruje a shoda místa se nevyžaduje. Umístění zůstává samostatným údajem každé instalace a jeho změna je přípustná.

**Oprava už uložené výměny**

Stejná kontrola se zopakuje, když se později změní událost nebo kterákoli z obou instalací. Transakce, která vazbu poruší, se nepotvrdí.

| Změna | Důsledek |
| --- | --- |
| `old_installation_id` nebo `new_installation_id` | kontrola použije oba odkazy po změně a vyžaduje na nich celou sadu podmínek. Neplatná nová dvojice se nepotvrdí. Platná oprava odkazu se potvrdí a dřívější instalace už podmínkám této události nepodléhá |
| `apartment_id` jedné instalace | potvrzení selže, když se byty rozcházejí |
| `meter_id` tak, že obě instalace míří na stejné měřidlo | potvrzení selže |
| `installed_at` nové instalace nebo `removed_at` původní | potvrzení selže, když se čas nerovná `performed_at`. Oprava času mění událost i instalaci v jedné transakci |
| `final_value` původní instalace na NULL | potvrzení selže. Jiné číslo včetně nuly projde |
| `initial_value` nové instalace na NULL | potvrzení selže. Jiné číslo včetně nuly projde |
| `reason` nové instalace nebo `reason` události | potvrzení selže, když se texty liší. Oprava důvodu mění oba řádky v jedné transakci |
| `reason` nebo `initial_value` původní instalace | výměnu samy nerozbijí. `initial_value` původní instalace zůstává povinné číslo sloupce a nula je platná |
| `location` původní nebo nové instalace | výměnu nerozbije. Místo se nekopíruje, shoda se nevyžaduje a změna umístění je přípustná |
| `removed_at` nové instalace | původní výměnu nemění. Pozdější ukončení nové instalace je další zásah nebo odebrání |

Každá taková oprava zapíše ve stejné transakci audit s hodnotou před změnou, po změně a s důvodem. `created_by` a `created_at` události se nemění.

**Transakce**

PostgreSQL při chybě vrátí celou otevřenou transakci. Nepozná, že uzavření instalace v jednom požadavku a založení jiné instalace v dalším požadavku měly být jedna výměna. Odebrání bez náhrady a první instalace jsou samostatné platné operace a řádek `meter_replacement_events` nezakládají.

Výměna je jedna transakce:

1. uzavření původní instalace (`removed_at`, `final_value`; `reason` původního řádku se nemění),
2. vložení nové instalace nového fyzického měřidla, včetně povinného čísla `initial_value`, `seal_number` a `reason`,
3. vložení `meter_replacement_events`,
4. vložení `audit_logs` k oběma instalacím a k události.

Nový řádek `meters` vzniká v téže transakci, pokud fyzické měřidlo ještě neexistuje. Odložený trigger doběhne až na konci, takže pořadí těchto zápisů uvnitř transakce není podmínka. Selhání kteréhokoli kroku nic z transakce neponechá. Všechny auditní řádky zásahu mají stejné `request_id`.

Oprava je `UPDATE` ve stejné transakci jako nový auditní řádek s `before`, `after` a povinným `reason`. `created_by` a `created_at` se nemění. Předchozí podoba zůstane v řetězu `audit_logs`.

**Zákaz DELETE**

Zákaz `DELETE` u těchto tří tabulek vynucuje databázové oprávnění role `sjv_api`. Aplikační kontrola ho nenahrazuje. Trigger pro `DELETE` na nich není. `UPDATE` zůstává povolený a je auditovaný. Zákaz `DELETE` ho neruší.

- `meter_installations`. `sjv_api` smí `INSERT` a auditovaný `UPDATE`. `DELETE` nemá u žádného řádku, ať na něj výměna odkazuje, nebo ne. `ON DELETE RESTRICT` z `meter_replacement_events` navíc brání smazat instalaci, na kterou nějaká výměna odkazuje. Instalaci bez takové vazby tento cizí klíč nechrání. Její `DELETE` pro `sjv_api` odmítá oprávnění role.
- `meter_replacement_events`. `sjv_api` smí `INSERT` a auditovaný `UPDATE`. `DELETE` nemá. Oprávnění role je vynucení tohoto zákazu. `ON DELETE RESTRICT` na `old_installation_id` a `new_installation_id` brání smazat odkazovanou instalaci. Řádek výměny tím nechrání.
- `meter_verifications`. `sjv_api` smí `INSERT` a auditovaný `UPDATE`. `DELETE` nemá. Oprávnění role je vynucení tohoto zákazu, trigger ne. `meter_id` po vložení zůstává neměnný. Oprava ostatních sloupců zůstává auditovaný `UPDATE`. Cizí klíč `meter_id → meters` s `ON DELETE RESTRICT` brání smazat měřidlo, dokud na něj ověření odkazuje. Řádek ověření tím nechrání.

### `meter_verifications`

Historie ověření, kalibrací a kontrol jednoho fyzického měřidla.

`id`, `meter_id → meters`, `verification_type` (`verification`, `calibration`, `inspection`), `performed_at date`, `valid_from date NULL`, `valid_until date NULL`, `result` (`passed`, `failed`, `not_assessed`), `provider`, `note NULL`, `created_by → users`, `created_at`

- `verification` je ověření, `calibration` je kalibrace a `inspection` je kontrola. Jsou to tři různé typy úkonů. Záznam jednoho typu neukončuje ani nenahrazuje záznam jiného typu.
- `CHECK (valid_until IS NULL OR valid_from IS NOT NULL)`
- `CHECK (valid_until IS NULL OR valid_until >= valid_from)`. `valid_until` je poslední kalendářní den, který se ještě počítá jako platný. Den se vykládá v `Europe/Prague`.
- `result` je provozní označení záznamu: `passed` kladný, `failed` nekladný, `not_assessed` když podklad kladný ani nekladný výsledek neuvádí. Není to právní klasifikace. Systém z `failed` neoznačí měřidlo jako právně nezpůsobilé, neukončí ani nezruší jiné metrologické záznamy, nezakáže používání měřidla, nepočítá náhradní spotřebu a nevyvozuje sankce ani jiné právní důsledky. Platí pro `verification`, `calibration` i `inspection`. O důsledcích rozhoduje SJV.
- `provider` je organizace nebo osoba, která úkon provedla. `created_by` je administrátor, který záznam uložil.
- Cizí klíč na `meters` je `ON DELETE RESTRICT`. Účinek je v odstavci Zákaz DELETE. Měřidlo se vyřazuje stavem `retired`.
- `meter_id` po vložení měnit nejde, aby se historie nedala přenést na jiné měřidlo. Oprava ostatních sloupců je auditovaný `UPDATE`. Skončená platnost řádek nemaže.
- Pro čtení historie stačí index `(meter_id, verification_type, performed_at)` a částečný index na `valid_until` tam, kde je vyplněné. Index termíny nehlídá.

Každý řádek patří konkrétnímu `meter_id`. Výměna historii starého měřidla na nové nekopíruje. Nové měřidlo má vlastní řádky, i kdyby zatím žádné nemělo.

Druhy měřidel už rozlišuje `meters.medium`. Historie ani platnost se mezi nimi nesdílí:

| `medium` | Význam |
| --- | --- |
| `cold_water`, `hot_water` | vodoměry. Každé fyzické měřidlo má vlastní historii |
| `heat` | měřič tepla |
| `heat_cost_allocator` | indikátor topných nákladů |

Měřič tepla a indikátor topných nákladů jsou různá měřidla. Společnou platnost nemají.

Systém `valid_until` sám nedopočítá a lhůtu neodvozuje podle druhu ani konstrukce měřidla. Metrologické lhůty sleduje SJV mimo systém. Administrátor může `performed_at`, `valid_from` a `valid_until` zapsat ručně, když údaje zná. Prázdné `valid_until` znamená, že konec platnosti v systému není určený. Systém uložené údaje zobrazuje a povinnost dalšího úkonu z nich nedělá. Upozornění na blížící se nebo prošlý metrologický termín nevytváří a odpovědnost za sledování těchto termínů nepřebírá.

Administrátor vidí u každého záznamu dvě samostatné informace. Systém je neskládá do jednoho stavu, ve kterém by `result = failed` vypadal jako úspěšné platné ověření jen proto, že dnešek leží mezi `valid_from` a `valid_until`.

- **Výsledek úkonu** je uložený `result`: `passed`, `failed` nebo `not_assessed`.
- **Časové pokrytí** se počítá jen z dat a jen když jsou obě vyplněná. Den je v `Europe/Prague` a `valid_until` se do intervalu počítá. `in_force` znamená `valid_from` ≤ dnešek ≤ `valid_until`, `not_yet_valid` znamená `valid_from` až po dnešku, `expired` znamená `valid_until` před dneškem. Chybí-li `valid_from` nebo `valid_until`, pokrytí je `undated` a o platnosti se nic netvrdí.

Souhrn pro jedno fyzické měřidlo a jeden `verification_type` se bere jen z řádků s oběma daty. Řádky `undated` souhrn nepřepíší a zůstávají v historii vidět:

- aspoň jeden řádek je `in_force`: souhrn času je `in_force`. U každého takového řádku zůstává jeho vlastní `result`. Liší-li se výsledky, zobrazí se všechny. Žádný se nezahodí a žádný `failed` se nepřejmenuje na úspěch,
- žádný řádek není `in_force` a aspoň jeden je `not_yet_valid`: souhrn času je `not_yet_valid`. Starší `expired` zůstane v historii a neříká, že nová platnost už běží,
- žádný řádek není `in_force` ani `not_yet_valid` a aspoň jeden je `expired`: souhrn času je `expired`,
- žádný řádek nemá obě data: souhrn času je `unknown`.

Pořadí úkonů určuje `performed_at`. `created_at` je čas vložení záznamu do systému a pořadí úkonů nemění. Pozdější zápis historického úkonu proto souhrn ani jeho doplnění nepřesune. Oprava `performed_at` pořadí přepočítá.

`undated` záznam souhrn času nemění. K souhrnu se přidá jako pozdější úkon bez určené platnosti jen tehdy, když je jeho `performed_at` pozdější než `performed_at` každého datovaného řádku téhož měřidla a téhož typu. Stejné `performed_at` pozdější úkon není. Souhrn času se dál řídí jen `valid_from`, `valid_until` a dneškem.

`result = failed` zůstává označením výsledku konkrétního úkonu. Uvnitř vyplněného datového intervalu se nezobrazuje jako úspěšné ověření. Nezakládá právní nezpůsobilost, zákaz používání, náhradní spotřebu, sankci ani ukončení jiných záznamů. Časové pokrytí a výsledek zůstávají oddělené. O důsledcích rozhoduje SJV podle konkrétního úkonu a jeho podkladů. Metrologický termín notifikaci nezaloží. Obecné notifikace ostatních provozních událostí tím nemizí.

### Dokumenty a fotografie

Fotografie měřidel se do systému nenahrávají. Servisní a předávací protokoly se do systému nenahrávají. Systém neukládá odkazy na tyto dokumenty ani jejich metadata. Tabulka příloh, dokumentů ani úložiště nevzniká. Dokumenty fyzicky uchovává předseda SJV mimo systém. Z výměny a z metrologické historie se ukládá jen text ve sloupcích popsaných výše.

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
- Spotřeba se počítá samostatně v jedné instalaci a na jednom fyzickém měřidle. Rozdíl `final_value` starého měřidla a `initial_value` nového měřidla se jako spotřeba nepoužije. Výměna historické řádky `meter_readings` nemění. Sloupec `installation_id` v `meter_readings` zůstává nepřítomný (R8). R15 se nemění.
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
- `esp_instance` je `instance_id` firmwaru ESP. Po vymazání flash firmware vygeneruje novou hodnotu u stejného fyzického zařízení; to **není** automaticky schválená serverová rotace aktivního řádku `device_external_ids`. Krátkodobá vazba na epochu bootu zůstává v `device_boots`. Registrace a konfliktní zápis řídí R37 §6: zámek `devices.id FOR UPDATE`, pořadí zámků, ochrana UNIQUE `uq_device_external_ids_active_value` (23505) a exclusion `ex_device_external_ids_active_kind` (23P01), bez automatického převzetí cizí aktivní identity. Při aktivní `A` a uplinku `B ≠ A` zůstane `proof_basis` NULL, dokud není autorizovaná rotace. Automatická rotace jen proto, že uplink poslal jinou `instance_id`, není schválena; autorizace rotace zůstává otevřená. Produkční první registrace volné hodnoty ([R37-O4](decisions.md)): výhradně `sjv_esp_instance_register_free(device_id, value)` (`SECURITY DEFINER`, OWNER `sjv_owner`, `EXECUTE` jen `sjv_collector`, bez parametrů `kind`/`origin`/`valid_to`). Pojistka P4 při INSERT položky s `proof_basis = esp_queue_v1`: INVOKER trigger volá `sjv_esp_p4_assert(device_id, instance_id)` (DEFINER, bez zápisu), která zamkne `devices D` a aktivní `esp_instance` zařízení D v pořadí §6 a ověří `value = V`. PostgreSQL vyžaduje pro `FOR UPDATE` i `UPDATE` privilege; `sjv_collector` proto **nedostane** `UPDATE` na `device_external_ids` — zámky jdou přes DEFINER. Hodnota `origin` při registraci (U3) zůstává otevřená; enum výše se nemění. Funkce a trigger v migracích zatím nejsou.

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
| `ingest_sources` | `ingest_sources` | identita příjmového zdroje pro idempotenci. Není to `source_streams` ani `devices.id`. Payload zůstává v `ingest_payloads` |
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

- `CHECK` drží kombinaci `kind`, `storage` a vyplněného sloupce. `bearer` a `basic` mají `storage = hash` a jen `secret_hash`. `client_cert` má `storage = hash` a jen `cert_fingerprint`. `dtls_psk` má `storage = kek_enc` a jen `secret_enc`.
- Příchozí ověření je hash nebo otisk. Opakovaně použitelný DTLS PSK je šifrovaný AES-256-GCM hlavním klíčem aplikace, stejně jako klíče měřidel. Rozšifruje se jen v paměti procesu, který ho oprávněně potřebuje. UDP/DTLS listener není přiřazený `sjv_collector`, `sjv_api` ani `sjv_worker`, proto migrace těmto rolím `SELECT` na `secret_enc` nedává. Kdo bude PSK číst, určí až návrh toho listeneru.
- `sjv_readonly` slouží `restore-test.sh` a `backup-verify.sh`. Ty kontrolují obnovená data a řetězec auditu, ne uložené tajemství. Výchozí `SELECT` vlastníka by na této tabulce zahrnulo `secret_enc`, proto ho migrace po vzniku tabulky odebere a ponechá čtení jen `id`, `endpoint_id`, `kind`, `storage`, `created_at` a `revoked_at`. `secret_hash`, `cert_fingerprint` a `secret_enc` v tom seznamu nejsou.
- Hodnota se neloguje a do `ingest_endpoints.config` ani do `ingest_payloads` se nekopíruje. Odchozí token platformy v `endpoint_credentials` není. Jeho uložení je mimo Etapu 1 a vyžaduje samostatné rozhodnutí. Nový sloupec ani `kind` se pro něj nezakládá.

### `ingest_payloads` (měsíční partitions, 36 měsíců) — vrstva A

`id` (sekvence), `partition_month`, `ingest_source_id NOT NULL`, `endpoint_id`, `device_id NULL`, `transport`, `received_at`, `content_kind` (`wmbus_batch`, `wmbus_frame`, `json`, `csv`, `udp_datagram`, `api_response`, `opaque`), `mqtt_topic NULL`, `payload bytea`, `payload_sha256`, `size_bytes`, `origin` (`received`, `assembled`), `fragment_set_id NULL`, `metadata jsonb`

- `PRIMARY KEY (id, partition_month)`
- `partition_month` je měsíc `received_at` v UTC. U `origin = assembled` je to měsíc složení.
- `ingest_source_id → ingest_sources`. Vyplněné vždy, i když `device_id` chybí.
- `payload` jsou bajty, které přišly, bez překódování a bez ořezu. Topic MQTT je vedle nich, protože do těla zprávy nepatří, ale k příjmu ano.
- `origin = assembled` vznikne jen z úplné sady fragmentů a odkazuje na ni. Původní fragmenty v tabulce zůstávají. Složený payload je jejich spojení v daném pořadí, ne náhrada.
- `metadata` smí nést jméno souboru, identifikátor stránky API nebo netajné hlavičky. Autorizační hlavička se neukládá.
- Dekódovaná hodnota bez wM-Bus rámce má `content_kind` `json` nebo `csv` a nevytvoří řádek `raw_telegrams`.
- `opaque` znamená uložené bajty bez zařazení do známého formátu. Když formát ještě není známý bez dalšího vyhodnocení, vloží se `opaque`. Druh se volí při vložení.
- Tělo nad `max_payload_bytes` se sem nezapíše. Odmítnutí je jen v `ingest_rejections`, aby velké odmítnuté zprávy plnily disk.

### `ingest_payload_items` (měsíční partitions, 36 měsíců)

`partition_month`, `payload_id`, `payload_partition_month`, `item_index`, `original bytea NOT NULL`, `message_kind`, `msg_key`, `msg_key_namespace`, `proof_basis`, `identifier_proven boolean NOT NULL`, časové údaje položky, bajty a označení rámce, `group_key`, `fragment_index`, `source_message_ref`, `external_message_id`

- `PRIMARY KEY (partition_month, payload_id, item_index)`. Měsíc je v klíči, protože partitionovaný unikátní klíč ho vyžaduje. `CHECK` drží `payload_partition_month = partition_month`, takže identita `(payload_id, payload_partition_month, item_index)` je stejná trojice.
- `FOREIGN KEY (payload_id, payload_partition_month) REFERENCES ingest_payloads (id, partition_month)`
- `CHECK (payload_partition_month = partition_month)` a `CHECK (item_index >= 0)`
- Identita položky v doručení je `(payload_id, payload_partition_month, item_index)`. Čísluje se od nuly v pořadí zdrojové obálky. `item_index = -1` patří jen příjmu prázdné obálky a v této tabulce není.
- `original` jsou bajty této položky. `ingest_payloads.payload` jsou bajty celé obálky. Jedny druhé nenahrazují. Neznámý druh se uloží jako text a `CHECK` příjmu se na něj nepoužije, aby bajty nezmizely.
- `msg_key` a `msg_key_namespace` jsou text, který zdroj poslal. `identifier_proven` je uložený vstupní boolean a načtení ho vrátí; důkaz identity to není. `proof_basis` se z něj nevyplní. Pro vlastní ESP na MQTT schválilo [R37](decisions.md) bázi `esp_queue_v1` (R20 `item_index` pro tuto bázi je vždy 0) a [R37-O4](decisions.md) produkční cestu: obecná `accept()` ukládá `proof_basis` NULL; `trusted_esp_accept` v TX1 ukládá konečnou `esp_queue_v1` nebo NULL. Cílový BEFORE INSERT trigger (`SECURITY INVOKER`) při `esp_queue_v1` ověří mqtt transport/namespace, kanonický `msg_key` a zavolá `sjv_esp_p4_assert`; přímý INSERT bez platné vazby D↔V musí selhat. Trigger neprokazuje P2 ACL. Současný `accept` stále ukládá `proof_basis` prázdnou; SQL pojistka není v head migraci. Hash tu není a nový sloupec pro immutable otisk R37 nezavádí.
- Řádek je uložený vstup, ne výsledek. Příjem vzniká až vyhodnocením. Prázdná obálka má nula těchto řádků.
- Retence je retence payloadu. Partition položek měsíce M se odpojí dřív než `ingest_payloads` měsíce M.

### `ingest_sources` (bez partitioningu, trvale)

`id`, `code UNIQUE`, `kind` (`device`, `platform`, `import`), `msg_key_scope` (`transport`, `device`), `device_id NULL → devices`, `endpoint_id NULL → ingest_endpoints`

- `id` je identita příjmového zdroje. Po založení se nemění. Není to `devices.id` a nesmí se jím nahradit.
- `CHECK ((kind = 'device' AND device_id IS NOT NULL AND endpoint_id IS NULL) OR (kind <> 'device' AND device_id IS NULL AND endpoint_id IS NOT NULL))`
- Fyzické zařízení má právě jeden řádek `kind = device`. Unikátní index je `UNIQUE (device_id) WHERE kind = 'device'`. MQTT a HTTPS téhož zařízení sdílejí tento řádek jako původce, ne jako společný prostor `msg_key`.
- `msg_key_scope = transport` je výchozí. `msg_key_namespace` v klíči zprávy je pak název transportu. Stejný text `msg_key` na MQTT a na HTTPS jsou dvě doručení.
- `msg_key_scope = device` smí být jen u zdroje, jehož kontrakt prokáže jeden prostor identifikátorů napříč transporty. `msg_key_namespace` je potom konstanta `device`. Firmware ESP popisuje `msg_key` jako vlastnost záznamu fronty při opakovaném odeslání. Nepopisuje, že MQTT a HTTPS jsou jeden prostor. Dokud to firmware výslovně nezaručí, ESP zůstává `transport`.
- Platforma a import mají povinné `endpoint_id`. Unikátní index je `UNIQUE (endpoint_id) WHERE kind <> 'device'`. Účet platformy není zařízení. Koncentrátor uvnitř odpovědi se na `devices` namapuje jen přes už uložené `device_external_ids` a na klíč idempotence se tím nepřesune.
- Budoucí zdroj bez fyzického zařízení je další `kind` a další řádek s vlastním `id`. Klíč prokázané položky zůstává `(ingest_source_id, msg_key_namespace, msg_key, item_index)`.
- Stejný text `msg_key` dvou různých `ingest_source_id` jsou dvě zprávy. Sloučení by schovalo doručení z druhého zdroje.

### `ingest_message_keys` (bez partitioningu, 60 dní)

`ingest_source_id NOT NULL → ingest_sources`, `msg_key_namespace text NOT NULL`, `msg_key text NOT NULL`, `item_index int NOT NULL`, `message_kind` (`telegram`, `decoded`, `telemetry`, `event`, `heartbeat`, `import_row`), `first_received_at`, `last_received_at`, `delivery_count`, `outcome`, `receipt_id NULL`, `receipt_partition_month NULL`

- `PRIMARY KEY (ingest_source_id, msg_key_namespace, msg_key, item_index)`. NULL v klíči není. `item_index` patří do klíče, protože jedna zpráva má víc položek. Klíč bez něj by druhou položku prvního doručení označil jako opakované doručení celé zprávy a odečet by nevznikl.
- Zpráva s jednou položkou má `item_index = 0`. Pořadí bere adaptér ze zdroje. Když zdroj pořadí nemá, dostane ho položka podle pořadí v payloadu a to pořadí se uloží. Skutečné položky se číslují od nuly.
- `ingest_receipts.item_index = -1` patří jen příjmu obálky, která žádnou položku nemá. Není to položka, řádek `ingest_message_keys` pro něj nevznikne a s čísly `0 .. n-1` se nepotká.
- Řádek vznikne jen tehdy, když zdroj poslal identifikátor a je prokázané, že se během 60denní retence klíče neopakuje. `sha256` těla se do `msg_key` neukládá.
- `msg_key_namespace` je transport, nebo `device` při `msg_key_scope = device`. Stejný text v jiném namespace není stejná zpráva.
- `outcome` je uložený výsledek této položky, jeden ze stavů ACK ([data-ingestion.md](data-ingestion.md)). Není to stav ostatních položek.
- `delivery_count` je počet doručení této položky. Evidence doručení jsou řádky `ingest_receipts` s týmž klíčem a `item_index`. Samotný počet je nenahrazuje.
- `FOREIGN KEY (receipt_id, receipt_partition_month) REFERENCES ingest_receipts (id, partition_month)` míří na první příjem této položky.
- První doručení zprávy zpracuje každou položku. Opakované doručení narazí na klíč téže položky, přidá příjem `duplicate_delivery` a odečet znovu nezaloží.
- Bez prokázaného identifikátoru klíč nevznikne. Každé doručení každé položky zůstane vlastní příjem a vlastní pozorování.
- ESP má vlastní `msg_key` na položku fronty; při `proof_basis = esp_queue_v1` je R20 `item_index` vždy 0 (R37). R20 vzniká i při terminálním `invalid`, pokud je důkaz a COMMIT (R37-O1 D6). TX1 `ingest_payload_items.item_index` zůstává pořadím v obálce. U ACRIOS důkazní báze schválená není a do PoC se nedoplňuje.

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

- Chybějící `access_number` se ukládá jako `-1`. V dokumentaci postupu se sloupec nejmenuje `acc`. ACC je jen název pole wM-Bus, které se do sloupce ukládá.
- `anchor_at` ani `dedup_window` se po zápisu nemění, takže okna se neřetězí.
- Druhý index slouží k vyhledání stejného obsahu v retenci klíče. Nález mimo `dedup_window` není potvrzená duplicita. U kotvy `server_only` se podle něj telegramy neslučují ([data-ingestion.md](data-ingestion.md#kotva-server_only)).
- `raw_telegram_id` a `raw_partition_month` ukazují na telegram, který okno založil. Pseudokód ingestu používá tato jména, ne `raw_id` a `partition_month` bez rozlišení.

### `raw_telegrams` (měsíční partitions, 24 měsíců)

`id` (sekvence `raw_telegrams_id_seq`, hodnota se alokuje před vložením), `partition_month`, `meter_key`, `meter_id NULL`, `access_number`, `ci_field`, `encryption_mode`, `canonical_frame bytea`, `frame_hash`, `normalizer_version`, `anchor_at`, `time_source`, `first_server_received_at`, `receipt_count`, `capture_device_ids bigint[]`, `decode_status` (`pending`, `decoded`, `failed`, `no_key`, `suspect_replay`, `needs_review`, `ambiguous`), `decode_error NULL`, `decoder_version NULL`

- `PRIMARY KEY (id, partition_month)`
- Telegramy neznámých měřidel se do této tabulky neukládají ([data-ingestion.md](data-ingestion.md)).
- Řádek vznikne jen ze skutečného wM-Bus rámce. JSON, CSV ani odpověď API sem nepatří a fiktivní rámec se pro ně nevytváří.
- `canonical_frame` je kanonická podoba po ověření CRC. Původní bajty obálky jsou v `ingest_payloads`, vyříznutý rámec na příjmu. Kanonická podoba původní data nenahrazuje.
- `needs_review` a `ambiguous` rámec ukládají a do `decode_queue` ho nedávají. `ambiguous` se nepřipojí k staršímu telegramu se stejným `access_number` a `frame_hash`. Starší řádek se kvůli němu nemění. Osmibitové `access_number` se ve 60 dnech přetočí, takže shoda mimo `dedup_window` není důkaz stejného vysílání.

### `ingest_receipts` (měsíční partitions, 36 měsíců) — vrstva B

`id` (sekvence), `partition_month`, `server_received_at`, `payload_id`, `payload_partition_month`, `content_hash bytea NOT NULL`, `item_index NOT NULL`, `ingest_source_id NOT NULL → ingest_sources`, `endpoint_id`, `device_id NULL`, `device_attribution` (`authenticated`, `mapped`, `unattributed`), `message_kind` (`raw_wmbus`, `decoded`, `telemetry`, `event`, `heartbeat`, `import_row`), `msg_key NULL`, `msg_key_namespace NULL`, `external_message_id NULL`, `transport` (`mqtt`, `https`, `udp_dtls`, `platform_api`, `file_import`), `device_rx_unix_ms NULL`, `rx_instance_id NULL`, `rx_boot NULL`, `rx_uptime_ms NULL`, `age_ms NULL`, `tx_at NULL`, `tx_uptime_ms NULL`, `captured_at_est`, `time_source` (`boot_epoch`, `device_clock`, `server_only`), `time_uncertainty_ms`, `time_flags text[]`, `rssi NULL`, `frame_format NULL`, `original_frame bytea NULL`, `fragment_set_id NULL`, `raw_telegram_id NULL`, `raw_partition_month NULL`, `decoded_observation_id NULL`, `decoded_partition_month NULL`, `status`

- `PRIMARY KEY (id, partition_month)`
- `partition_month` je první den měsíce `server_received_at` v UTC. `CHECK (payload_partition_month = partition_month)`. Tento `CHECK` není cizí klíč.
- Na `ingest_payloads` cizí klíč není. Stejný měsíc payloadu a příjmu drží jen `CHECK`. Retenční funkce se na neexistující klíč nespoléhá a před odstraněním payloadu zbývající příjmy spočítá.
- Na `raw_telegrams` a `decoded_observations` cizí klíč není. `raw_telegram_id` s `raw_partition_month` a `decoded_observation_id` s `decoded_partition_month` jsou odkaz pořízený v okamžiku zápisu. Telegram z ledna smí být smazaný dřív než příjem z prosince. Cizí klíč by buď příjem smazal s lednovou partition, nebo by lednový telegram držel až do retence prosincového příjmu. Ani jedno neodpovídá retenci 24 měsíců od skutečného přijetí.
- Příklad: telegram má kotvu v lednu 2027 a jeho partition se maže, když je leden 2027 starší než 24 měsíců. Další koncentrátor doručí svůj příjem v prosinci 2028. Příjem leží v partition prosince 2028 a maže se, až když je prosinec 2028 starší než 24 měsíců. Sloupce `raw_telegram_id` a `raw_partition_month` dál nesou lednovou identitu. Po smazání lednové partition se z nich řádek nenačte. To není porušený cizí klíč, protože cizí klíč tam není.
- `status`: `new_telegram`, `duplicate`, `probable_duplicate`, `needs_review`, `duplicate_delivery`, `content_mismatch`, `uncertain`, `id_collision`, `suspect_replay`, `unknown_meter`, `unknown_device`, `crc_error`, `invalid`, `too_old`, `accepted`, `unresolved`, `conflict`. `duplicate` je jen potvrzená shoda uvnitř `dedup_window`. `duplicate_delivery` je jen prokázaný identifikátor se shodným immutable obsahem (R37-O1: jen receipt, ne application ACK literál). `content_mismatch` je stejný R20 klíč s jiným `esp_queue_immutable_v1` (R37-O1 D1); `ingest_message_keys` se při něm nemění. `uncertain` je stejný `content_hash` bez prokázané identity. `id_collision` je stejný text `msg_key` v jiném namespace téhož zdroje. Ani jeden z nich není tiché sloučení. Kontrakt R37-O1 schvaluje `content_mismatch`; CHECK enum v migraci ho **zatím nepřidává** — implementační krok.
- `ingest_source_id` je povinné. `device_id` je fyzická atribuce a smí být NULL. Tělo zprávy ho nepřepíše. Nové zařízení z těla nevznikne.
- `content_hash` je `sha256` kanonického těla položky. Není to identifikátor zprávy ani primární klíč. U příjmu s `item_index = -1` tělo položky není, takže `content_hash` je `sha256` původních bajtů celé obálky. Ani tento hash identita zprávy není.
- Identita doručení je `(id, partition_month)`. Identita prokázané položky je `(ingest_source_id, msg_key_namespace, msg_key, item_index)`. Bez prokázaného `msg_key` je položka totožná s tímto doručením a s řádkem pozorování, který z něj vznikl.
- Prokázané opakované doručení se shodným immutable obsahem vloží další příjem `duplicate_delivery` do měsíce svého `server_received_at`, zvýší `delivery_count` a nevloží telegram, pozorování ani odečet. Odkaz na původní výsledek jsou sloupce bez cizího klíče (`keys.outcome` beze změny). Při jiném immutable hashu vznikne receipt `content_mismatch` bez změny keys (R37-O1).
- `original_frame` je vyříznutý wM-Bus rámec. U dekódovaného JSON zůstane NULL. Chybějící rámec se nevytváří.
- Údaje času od zařízení se ukládají, jen když je zdroj poslal. Chybějící `rx_uptime` se nevymýšlí.
- `device_attribution` je `authenticated` z účtu zařízení, `mapped` přes `device_external_ids`, nebo `unattributed`, když platforma pošle identifikátor, který v evidenci není. Poslední případ zařízení nezaloží.

### `ingest_dedup_candidates` (měsíční partitions, 24 měsíců)

`receipt_id`, `receipt_partition_month`, `candidate_raw_telegram_id`, `candidate_partition_month`

- `PRIMARY KEY (receipt_id, receipt_partition_month, candidate_raw_telegram_id, candidate_partition_month)`
- `FOREIGN KEY (receipt_id, receipt_partition_month) REFERENCES ingest_receipts (id, partition_month)`
- Na `raw_telegrams` cizí klíč není. Kandidát smí ležet v jiném měsíci a retence staršího telegramu nečeká na nevyřešenou shodu.
- Řádek znamená jen podobnost uloženého rámce s dřívějším telegramem. Kandidáta nepřepisuje, jeho `receipt_count` nezvedá a odečet nezakládá. Maže se s příjmem.

### `ingest_fragment_sets` (bez partitioningu, mazání nejdřív po fragmentech a ne dřív než 24 měsíců od `first_received_at`)

`id`, `ingest_source_id NOT NULL → ingest_sources`, `endpoint_id`, `group_key`, `message_ref NULL`, `expected_count NULL`, `received_count`, `status` (`collecting`, `complete`, `timed_out`, `conflict`, `isolated`), `first_received_at`, `deadline_at NULL`, `assembled_payload_id NULL`, `assembled_payload_partition_month NULL`

- `PRIMARY KEY (id)`. `id` je identita jednoho pokusu o složení. `group_key` jí není.
- `group_key` posílá zdroj. Jak dlouho ho neopakuje, PoC neví. Návrh ho proto nepovažuje za globálně jedinečný, ani za jedinečný v měsíci nebo po dobu života zařízení. Adaptér k němu nepřidává vymyšlenou předponu. `group_key`, hash payloadu, časová blízkost příjmu ani `source_message_ref` nejsou důkazem identity zprávy.
- `message_ref` není identita zprávy, dokud ACRIOS PoC neprokáže jeho rozsah. Prokázaný rozsah může být užší než současná jedinečnost mezi všemi endpointy, transporty, restarty a v čase. Příkladem je rozsah pouze v rámci transportu. Do výsledku PoC zůstane `message_ref` NULL. Text, který zdroj poslal, zůstane ve `source_message_ref` na fragmentu a `message_ref` sady nevyplní. Konkrétní sloupec ani jiná změna schématu se před výsledkem PoC nevybírá.
- Když PoC prokáže rozsah jen v rámci transportu, musí být transportní namespace reprezentován přímo v databázovém modelu a v odpovídajícím unikátním omezení. `endpoint_id` se za transportní namespace automaticky nepovažuje. Běžný unikátní index PostgreSQL transport JOINem z `ingest_endpoints` nezíská.
- Dokud rozsah není prokázán a reprezentován v databázovém modelu, skládání a příslušné unikátní omezení pro daný zdroj se nezapínají. Ostatní části schématu tím nejsou blokovány. Unikátní index pro `message_ref` se před tímto výsledkem nezavádí.
- Skládání do `collecting` je možné až po tomto prokázání. Fragment se připojí jen ke `collecting` před `deadline_at` a jen se stejným prokázaným `message_ref`. K `complete`, `timed_out`, `conflict` a `isolated` se nepřipojí.
- Každé nové doručení fragmentu bez prokázaného `message_ref` vždy vytvoří vlastní novou sadu `isolated`, vlastní payload a právě jeden řádek `first`. U `isolated` se nikdy nepoužívá `repeat` ani `conflict`. Žádná dodatečně odvozená identita logického fragmentu ani shoda jakýchkoliv údajů, včetně `group_key`, `source_message_ref`, `fragment_index`, `content_hash`, času a identity jednoho transportního přenosu, doručení k existující sadě nepřiřadí. Odlišný hash je další nová sada `isolated`. Původní sada se nezmění, změněný obsah nepřijme a oba payloady zůstanou. `isolated` je konečný stav a nikdy nepřejde do `collecting`, `complete`, `conflict` ani `timed_out`. Neskládá se a dekodér ji nedostane.
- `BEFORE UPDATE` trigger na `ingest_fragment_sets` hlídá jen změnu `status` vůči `isolated`. Odmítne příkaz, když `OLD.status = 'isolated'` a `NEW.status` se liší: z `isolated` nelze přejít do `collecting`, `complete`, `conflict` ani `timed_out`. Odmítne i příkaz, když `NEW.status = 'isolated'` a `OLD.status` se liší: existující sadu z jiného stavu nelze na `isolated` převést. Nová sada `isolated` vzniká jen `INSERT` pro doručení bez prokázaného `message_ref`. `UPDATE`, který `status` nemění, trigger pustí. U řádku, který zůstává `isolated`, tak lze upravit ostatní povolené údaje, pokud řádek dál splní `CHECK`.
- Stav a identita sady drží jeden `CHECK`: `((status = 'isolated' AND message_ref IS NULL AND deadline_at IS NULL) OR (status IN ('collecting', 'complete', 'timed_out', 'conflict') AND message_ref IS NOT NULL AND btrim(message_ref) <> '' AND deadline_at IS NOT NULL))`. `isolated` má `message_ref IS NULL`. `collecting`, `complete`, `conflict` a `timed_out` vyžadují identifikátor, který po odstranění okolních mezer není prázdný. Samotné `IS NOT NULL` nestačí, prázdný řetězec ani řetězec z mezer neprojde.
- `deadline_at` je u skládané sady `collecting` s prokázaným `message_ref` rovno `first_received_at + INGEST_FRAGMENT_TIMEOUT`. Číslo doplní PoC. U `complete`, `conflict` a `timed_out` zůstává lhůta, kterou sada měla jako `collecting`. `CHECK` a trigger jsou invarianty uloženého řádku a změny stavu. Neřídí samy, které řádky timeout proces načte. Timeout proces smí vybrat jen `status = 'collecting' AND message_ref IS NOT NULL AND btrim(message_ref) <> '' AND deadline_at IS NOT NULL`. `isolated`, `complete`, `conflict` a `timed_out` se znovu nezpracovávají.
- Nové doručení s prokázaným `message_ref`, jehož sada je už `timed_out`, se k ní nepřipojí a její stav ani obsah nezmění. Nevznikne `isolated`, protože `CHECK` u `isolated` vyžaduje `message_ref IS NULL`, a nevznikne nová `collecting` se stejným `message_ref`. Payload v `ingest_payloads` zůstane. Doručení se neskládá a dekodér ho nedostane. Má se evidovat jako nepřiřazené a vyžadující samostatné vyhodnocení, dokud samostatný PoC neprokáže bezpečné zacházení a nebude přijato nové rozhodnutí. Tato větev se vyhodnotí dřív než doručení k sadě `complete` nebo `conflict`. Na ty se R32 nevztahuje. Fragment se k nim nepřipojí. Jak se takové doručení dál eviduje, schválená pravidla neurčují. Je to otevřená otázka, ne nové rozhodnutí a ne změna schématu.
- Současné tabulky toto nepřiřazené doručení jednoznačně neevidují. `ingest_fragments` bez `fragment_set_id` nevznikne. Žádný stav `ingest_fragment_sets` nepřiřazené doručení neoznačuje a vazba na původní `timed_out` sadu by ho k ní připojila. `ingest_receipts` umí uložit `payload_id` s prázdným `fragment_set_id`, ale žádný jeho `status` neznamená „prokázaný `message_ref` po `timed_out`, bez skládání a bez dekódování“. `ingest_rejections.reason` takový důvod nemá. Chybí schválený záznam nepřiřazeného doručení s vazbou na `payload_id` a bez sady. To je implementační předpoklad před touto cestou. Schéma se zde nenavrhuje.
- `FOREIGN KEY (assembled_payload_id, assembled_payload_partition_month) REFERENCES ingest_payloads (id, partition_month)` jen při `complete`. Měsíc složeného payloadu je měsíc složení.

### `ingest_fragments` (bez partitioningu, mazání 24 měsíců od `received_at`)

`id`, `fragment_set_id → ingest_fragment_sets`, `fragment_index int NOT NULL`, `payload_id`, `payload_partition_month`, `content_hash bytea NOT NULL`, `source_message_ref NULL`, `received_at`, `delivery_role` (`first`, `repeat`, `conflict`)

- `PRIMARY KEY (id)`
- `CREATE UNIQUE INDEX ON ingest_fragments (fragment_set_id, fragment_index) WHERE delivery_role = 'first'`. První přijatý kus indexu je jeden. Stejný index v jiné sadě je jiný fragment.
- `FOREIGN KEY (payload_id, payload_partition_month) REFERENCES ingest_payloads (id, partition_month)`. Payload zůstává v měsíční partition podle `received_at` tohoto doručení.
- Každý řádek je jedno doručení. Eviduje `payload_id`, `received_at` a `delivery_role` (`first`, `repeat`, `conflict`), spolu se sadou a indexem. Agregovaný počet se neukládá a evidenci nenahrazuje.
- `repeat` a `conflict` jsou možné pouze u sady `collecting` s prokázaným `message_ref`. U `isolated` se nepoužívají. Trigger `BEFORE INSERT OR UPDATE OF delivery_role` to kontroluje v okamžiku vložení nebo změny role. `UPDATE`, který `delivery_role` nemění, trigger znovu nezkoumá. `collecting` už vyžaduje neprázdné `message_ref` a vyplněné `deadline_at`. Unikátní index `message_ref` ani skládání se tím nezavádí.
- Jiný `content_hash` na stejném indexu sady `collecting` s prokázaným `message_ref` uloží řádek `conflict`, přepne sadu na `conflict` a původní řádek `first` nemění. Dekodér se nevolá a chybějící kus se nulami nedoplní.
- Fragment není odečet. Dekodér dostane až složený payload sady `complete`. Skládá se z řádků `first`.

### `ingest_rejections` (měsíční partitions, 24 měsíců)

`id` (sekvence), `partition_month`, `received_at`, `ingest_source_id NULL`, `endpoint_id NULL`, `device_id NULL`, `transport`, `reason` (`auth_failed`, `payload_too_large`, `replay`, `stale`, `fragment_timeout`, `fragment_conflict`, `fragment_unidentified`, `unparseable`, `endpoint_disabled`, `rate_limited`), `payload_id NULL`, `payload_partition_month NULL`, `fragment_set_id NULL`, `detail jsonb`

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

`id` (sekvence), `partition_month`, `ingest_source_id NOT NULL`, `msg_key NULL`, `msg_key_namespace NULL`, `item_index NOT NULL`, `content_hash bytea NOT NULL`, `device_id NULL`, `source_stream_id`, `external_meter_ref`, `meter_id NULL`, `source_measured_at`, `source_time_kind` (`meter_clock`, `concentrator_rx`, `platform_time`, `unknown`), `server_received_at`, `access_number NULL`, `measurement_ref NULL`, `values jsonb`, `vendor_payload jsonb NULL`, `payload_id`, `payload_partition_month`, `adapter`, `adapter_version`, `status` (`accepted`, `unresolved`, `conflict`, `uncertain`, `unknown_meter`, `invalid`)

- `PRIMARY KEY (id, partition_month)`
- `partition_month` je měsíc `server_received_at`. `CHECK (payload_partition_month = partition_month)`.
- `FOREIGN KEY (payload_id, payload_partition_month) REFERENCES ingest_payloads (id, partition_month)`
- Prokázaná zpráva je `(ingest_source_id, msg_key_namespace, msg_key)`. Prokázaná položka je tatáž trojice plus `item_index` a je to primární klíč `ingest_message_keys`. Bez prokázaného `msg_key` je identita položky `id` tohoto pozorování. Čas měření, hodnota ani `content_hash` identita nejsou.
- `content_hash` je `sha256` kanonického těla položky. Stejný hash druhé pozorování nesmaže a neoznačí jako `duplicate`.
- `measurement_ref` se vyplní jen identifikátorem, který zdroj skutečně poslal. Unikátní index na něm není. PoC teprve ukáže, jestli ho ACRIOS má a v jakém rozsahu je jedinečný. Do té doby se podle něj neslučuje.
- Nová položka vloží nové pozorování, i když `source_measured_at`, hodnota nebo `content_hash` už v databázi jsou. Pozorování se nepřepisuje a nemaže kvůli shodě ani kvůli `meter_readings_vendor_time_guard`.
- `accepted` znamená, že z položky vznikl odečet. `unresolved` znamená stejný čas a stejnou hodnotu jako aktivní kumulativní odečet. `conflict` znamená stejný čas a jinou hodnotu. `uncertain` znamená stejný `content_hash` bez prokázané identity zprávy. Ani jeden stav není `duplicate` a původní pozorování nemaže.
- `vendor_payload` je původní JSON položky, když obálka není právě ta položka. Jinak stačí `payload_id`. Rámec se kvůli tomu nevytváří.
- `source_time_kind = platform_time` je čas, o kterém adaptér ví jen to, že ho přidala platforma. Jestli ho ACRIOS posílá, ukáže PoC. Do spotřeby jako hraniční hodnota se nepoužije.
- `device_id` smí být NULL. `ingest_source_id` ne.

### `decode_queue` (bez partitioningu)

`raw_telegram_id`, `raw_partition_month`, `attempts`, `next_attempt_at`, `locked_by NULL`, `locked_at NULL`, `last_error NULL`

- `PRIMARY KEY (raw_telegram_id, raw_partition_month)`
- `FOREIGN KEY (raw_telegram_id, raw_partition_month) REFERENCES raw_telegrams (id, partition_month)`. Cizí klíč záměrně brání smazání partition, ve které ještě čekají telegramy na dekódování.
- Řádek vkládá přijímající proces ve stejné transakci jako nový telegram, a jen při výsledku `pending`. `sjv_collector` a `sjv_api` mají jen `INSERT`. `sjv_worker` řádek nevkládá.
- Worker bere úlohy přes `FOR UPDATE SKIP LOCKED`. K tomu má `SELECT` a sloupcový `UPDATE` u `attempts`, `next_attempt_at`, `locked_by`, `locked_at` a `last_error`. Po N neúspěších (nastavitelné) dostane telegram `decode_status = failed` a úloha se smaže. `DELETE` fronty má jen worker. Zápis `decode_status` a vznik odečtu tato migrace workerovi nedává.

## Odečty

### `meter_readings` (bez partitioningu, trvale)

`id`, `meter_id`, `source_stream_id`, `source_key text NOT NULL`, `source_kind` (`radio`, `vendor_decoded`, `manual`, `correction`, `import`), `reading_kind` (`cumulative`, `interval`, `event`), `quality` (`valid`, `suspect`, `invalid`), `raw_telegram_id NULL`, `decoded_observation_id NULL`, `measured_at`, `time_basis` (`meter_clock`, `capture_estimate`, `source_time`, `manual`), `time_source`, `primary_value numeric(18,6) NULL`, `unit NULL`, `quantity NULL`, `values jsonb`, `status_flags text[]`, `decoder_version NULL`, `adapter NULL`, `adapter_version NULL`, `normalizer_version NULL`, `frame_hash NULL`, `access_number NULL`, `receipt_count`, `capture_device_ids bigint[]`, `corrects_reading_id NULL → meter_readings`, `accepted_at NULL`, `accepted_by NULL`, `superseded_at NULL`, `created_at`, `created_by NULL`

Constrainty a indexy:

- `UNIQUE (source_key)` je globální idempotence. Formát klíče:
  - `raw:<raw_telegram_id>`
  - `vobs:<decoded_observation_id>`
  - `manual:<uuid>`
  - `correction:<uuid>`
  - `import:<dávka>:<řádek>`
- `CHECK (reading_kind <> 'cumulative' OR primary_value IS NOT NULL)`
- `CREATE UNIQUE INDEX meter_readings_vendor_time_guard ON meter_readings (meter_id, source_stream_id, measured_at) WHERE source_kind = 'vendor_decoded' AND reading_kind = 'cumulative' AND superseded_at IS NULL`
  Index chrání jen aktivní kumulativní projekci: v jednom streamu není druhý bod ve stejném čase. Není to identita měření a není to důvod smazat pozorování. Insert odečtu, který na index narazí, se vrátí jen pro řádek `meter_readings`. `decoded_observations` už v téže transakci zůstane.
- Postup dvou vendor payloadů se stejným `measured_at`:
  1. Oba payloady a oba příjmy se uloží. Každý má vlastní `content_hash`.
  2. Vloží se dvě pozorování. Druhé se nevloží příkazem `ON CONFLICT DO NOTHING` a první se neaktualizuje.
  3. První položka smí založit odečet, když není `uncertain` ani `conflict`.
  4. Druhá položka se stejnou hodnotou dostane `unresolved`. S jinou hodnotou dostane `conflict`. Se stejným hashem a bez prokázaného identifikátoru zprávy dostane `uncertain`, i když čas náhodou sedí.
  5. Druhý odečet se nezaloží. Původní odečet se nepřepíše. Administrátor dostane upozornění.
  6. Rozhodnutí administrátora je v auditu. Potvrzení, že jde o jedno měření, pozorování nemaže. Potvrzení, že jde o dvě měření, smí první odečet označit `superseded_at` a z druhého pozorování vložit opravu. Dva aktivní kumulativní body ve stejném čase index dál nepustí. Obě pozorování zůstanou do své retence.
- `(meter_id, measured_at)`, `(meter_id, source_stream_id, measured_at)`, BRIN na `measured_at`.
- Trigger povolí `UPDATE` jen u `receipt_count`, `capture_device_ids` a `superseded_at` (R8). Hodnota, čas, měřidlo, druh, kvalita, zdroj ani verze dekodéru se nemění. `accepted_at` a `accepted_by` trigger měnit nepovolí. `receipt_count` a `capture_device_ids` se mění jen u potvrzeného dalšího příjmu (`duplicate` uvnitř okna nebo `duplicate_delivery`), ne u `probable_duplicate`.
- `reading_kind = cumulative` je stav počítadla. `interval` je přírůstek za období dodaný zdrojem. `event` je událost bez kumulativní hodnoty (`primary_value` smí být NULL). Do spotřeby vstupuje jen kumulativní primární hodnota. R15 dál ukazuje poslední takovou hodnotu přiřazeného streamu. Odečet, který nevznikl, ji nemění.
- `quality` se nastaví při vložení. `suspect` se do spotřeby nepočítá. `invalid` se nepřijme. R8 povoluje pozdější `UPDATE` jen u `receipt_count`, `capture_device_ids` a `superseded_at`, takže jím nelze vyplnit `accepted_at` ani `accepted_by`. Jak se má přijetí `suspect` odečtu zachytit, aniž by se rozsah R8 rozšířil, je otázka k samostatnému rozhodnutí.
- `values` nese další registry téže zprávy, každý s `quantity`, `kind`, `value`, `unit` a `quality`. Nejsou to další řádky `meter_readings` a do spotřeby samy nevstupují.
- `quantity` je veličina primární hodnoty (objem, energie, jednotky poměrového měřiče a další až podle měřidla).
- `capture_device_ids` jsou jen fyzická zařízení. U importu a u platformy bez namapovaného koncentrátoru je pole prázdné. Není to úplná provenience.
- Na `raw_telegrams`, `decoded_observations` ani `ingest_payloads` není cizí klíč. Trvalý původ odečtu je řádek `reading_provenance` spolu s `frame_hash`, verzemi, `receipt_count` a `capture_device_ids`. Detailní příjmy a payloady mají retenci a po jejich smazání se nedají zrekonstruovat.

### Opravy

Postup v jedné transakci:

1. vloží se nový řádek se `source_kind = 'correction'`, stejným `source_stream_id` a `corrects_reading_id`,
2. původní řádek dostane `superseded_at`,
3. `audit_logs` dostane starou a novou hodnotu a povinný důvod,
4. naplánuje se přepočet dotčených dnů.

### `reading_provenance` (bez partitioningu, trvale)

`reading_id PK → meter_readings`, `ingest_source_id NOT NULL → ingest_sources`, `message_id NULL`, `msg_key_namespace NULL`, `item_index NULL`, `content_hash bytea NOT NULL`, `transport`, `endpoint_code`, `first_server_received_at`, `confirmed_source_ids bigint[]`

- Jeden řádek na odečet. Není to kopie příjmu ani payloadu.
- Rozsah je zdroj, který odečet založil: `ingest_source_id`, prokázané `message_id` (jinak NULL), `item_index`, `transport`, kód koncového bodu v době zápisu a `first_server_received_at`. `content_hash` je hash těla, které odečet založilo. Není to identita zprávy a není to cizí klíč.
- `confirmed_source_ids` je souhrn dalších `ingest_sources`, jejichž příjem byl potvrzená duplicita (`duplicate` uvnitř okna nebo `duplicate_delivery` prokázaného identifikátoru). `uncertain`, `id_collision`, `probable_duplicate`, `conflict`, `unresolved` a izolovaný fragment se do pole nepřidají. Není to seznam všech přijímačů, které poslaly podobný obsah.
- Fyzická zařízení potvrzených příjmů zůstávají v `meter_readings.capture_device_ids`. Verze, `frame_hash`, `access_number` a `receipt_count` zůstávají na odečtu.
- Sloupce neobsahují `receipt_id`, `payload_id`, `raw_telegram_id` ani `decoded_observation_id`. Po retenci by to byly odkazy na smazané řádky. Cizí klíče vedou jen na `meter_readings` a `ingest_sources`, které se nemažou. `endpoint_code` je textový snímek, ne cizí klíč.
- `receipt_count` je počet potvrzených příjmů. Není to seznam časů doručení. Po retenci se jednotlivé časy a bajty nedají obnovit.
- `probable_duplicate`, `needs_review` a `uncertain` odečet nezaloží, takže sem řádek nedostanou. Jejich detail zůstane v příjmu a payloadu po dobu jejich vlastní retence.
- Ruční odečet a oprava mají `message_id` rovné `source_key`. Import má `transport = file_import`. Ruční zápis a oprava mají `transport = manual`.

### `meter_daily_values` (bez partitioningu, trvale)

`meter_id`, `day date` (`Europe/Prague`), `first_value`, `first_at`, `last_value`, `last_at`, `reading_count`, `stream_ids smallint[]`, `flags text[]`, `computed_at`

- `PRIMARY KEY (meter_id, day)`
- Počítá se z efektivní řady, tedy jen z kumulativních hodnot přiřazených streamů. V den přechodu zdroje obsahuje hraniční hodnoty obou streamů téhož počítadla a příznak `source_handover`.
- Přepočet spouští opravy, přechody zdroje a změny instalací (`maintenance.sh` a worker). Po výměně se denní hodnoty počítají znovu uvnitř každého měřidla. Hranice mezi starým `final_value` a novým `initial_value` do rozdílu nevstupuje.

## Provoz a audit

### `device_telemetry` (měsíční partitions, 36 měsíců)

Normalizovaná provozní telemetrie zařízení. Tabulka je obecná, nikoli pouze bateriová; `payload` může nést napájení, signál, teplotu nebo jiné hodnoty společného kontraktu.

`id`, `partition_month`, `device_id`, `msg_key`, `measured_at`, `received_at`, `instance_id`, `boot_counter`, `uptime_ms`, `time_source`, `time_uncertainty_ms`, `payload jsonb`

- `PRIMARY KEY (id, partition_month)`.
- `partition_month` je první den měsíce `received_at` v UTC a `CHECK` vyžaduje shodu s tímto měsícem.
- `device_id → devices` je povinná autentizovaná identita zdroje. `msg_key` je pouze zkopírovaná hodnota z položky; sama není úplnou identitou položky.
- `measured_at` je čas měření v UTC; `received_at` je skutečný čas příjmu. `time_source` používá `boot_epoch`, `device_clock` nebo `server_only`.
- `instance_id`, `boot_counter` a `uptime_ms` jsou reference zařízení, pokud je zařízení poskytlo. `time_uncertainty_ms` je nezáporná nejistota odhadu.
- Jeden řádek představuje jeden kompletní telemetrický vzorek zařízení. `payload` může obsahovat současně skupiny `power`, teploty, signálu i dalších stavových hodnot; nový sloupec `kind` se pro tyto skupiny nezavádí. `message_kind = telemetry` označuje ingestovanou položku a její cestu přes společný ingest. `payload` obsahuje normalizované hodnoty kontraktu, nikoli tajemství.
- `CHECK` vyžaduje `received_at` a `measured_at`, nezáporné `uptime_ms` a `time_uncertainty_ms`, povolený `time_source` a objektový `payload` (`jsonb_typeof(payload) = 'object'`). `msg_key` nesmí být prázdný.
- Indexy: `(device_id, measured_at)` a BRIN na `received_at`. Unikátnost položky zajišťuje pouze `ingest_message_keys` s `item_index`.
- Cizí klíč na `devices` je `ON DELETE RESTRICT`. Cizí klíč na retenční payload se nepřidává, protože payloady mají odlišnou životnost.

`sjv_collector` a `sjv_api` vkládají pouze přes společný ingestovací postup, `sjv_readonly` smí číst a `sjv_maintenance` spravuje partitions a retenci. Žádná aplikační role nemá `UPDATE` ani `DELETE` provozních řádků.

Společný ingest nejprve vytvoří `ingest_payload_items` a po vyhodnocení `ingest_receipts`; teprve z úspěšně zpracované položky vzniká řádek `device_telemetry`. Současný návrh nemá v `device_telemetry` sloupce `(ingest_source_id, msg_key_namespace, item_index)` ani složený odkaz `(receipt_id, receipt_partition_month)`. Proto `msg_key` a `device_id` dovolují pouze obsahovou korelaci, ne jednoznačnou relační vazbu na `ingest_receipts`, zejména při transportním namespace. Přidání takové vazby by muselo být samostatně rozhodnuto s ohledem na 36měsíční retenci obou tabulek; R36 ji zatím neschvaluje.

### `device_events` (měsíční partitions, 12 měsíců)

`id` (sekvence), `partition_month`, `device_id`, `msg_key NULL`, `kind`, `occurred_at NULL`, `received_at NOT NULL`, `payload jsonb`

- `PRIMARY KEY (id, partition_month)`
- `partition_month` je první den měsíce `received_at` v UTC. `CHECK` jiný měsíc odmítne. `occurred_at` smí chybět a smí ležet v jiném měsíci. Měsíc partition neurčuje.
- `FOREIGN KEY (device_id) REFERENCES devices`. Zařízení se nemažou, jen vyřazují.
- Heartbeat aktualizuje `devices` a `device_boots`. Do událostí se zapíše jen změna stavu a hodinový vzorek. Nová verze firmware založí řádek `device_firmware_history`. Původní tělo heartbeatu je v `ingest_payloads` a má příjem `message_kind = heartbeat`, odečet nezakládá.
- `device_events` není tabulka pro každý telemetrický vzorek. Významné změny a alarmy používají druhy `battery_low`, `battery_critical`, `power_source_changed`, `charging_changed` a `battery_sensor_fault`.
- Alarm vyhodnocuje centrálně VPS až po COMMIT telemetrie. Prahy nejsou v tomto návrhu určeny; závisí na chemii a zapojení baterie, vyžadují hysterézi a potlačení opakovaných notifikací.

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
| `meter_readings`, `meter_daily_values`, `reading_provenance`, `ingest_sources` | trvale | nemažou se |
| `meter_replacement_events`, `meter_verifications` | trvale | retence je neodstraňuje |
| `audit_logs` | dlouhodobě | nemažou se |
| `ingest_payloads`, `ingest_payload_items`, `ingest_receipts` | 36 měsíců stáří měsíce přijetí (`received_at` nebo `server_received_at`) | odpojení a smazání partition. Položky dřív než jejich payload |
| `device_telemetry` | 36 měsíců stáří měsíce `received_at` | odpojení a smazání partition |
| `ingest_dedup_candidates`, `ingest_rejections`, `decoded_observations` | 24 měsíců stáří měsíce přijetí | odpojení a smazání partition. Položky dřív než jejich payload |
| `raw_telegrams` | 24 měsíců stáří měsíce kotvy | odpojení a smazání partition. Pozdější příjem tuto dobu neprodlužuje |
| `ingest_fragment_sets` | 24 měsíců od `first_received_at`, ale ne dřív než poslední fragment | `DELETE` až když na sadu žádný fragment neukazuje |
| `ingest_fragments` | 24 měsíců od `received_at` | `DELETE` dřív než sada |
| `device_events` | 12 měsíců stáří měsíce `received_at` | odpojení a smazání partition. `partition_month` je měsíc UTC hodnoty `received_at` |
| `ingest_message_keys`, `telegram_dedup_keys`, `device_boots` | 60 dní | `DELETE` v dávkách |
| `device_external_ids`, `device_firmware_history`, `device_placements`, `device_capabilities` | trvale s historií | řádky se neuzavírají mazáním, jen `valid_to` |
| `unknown_meter_sightings` | 90 dní od posledního zachycení | `DELETE` |
| `login_attempts`, `notifications` | 90 dní (návrh) | `DELETE` |

`sjv_retain_ingest_month(M)` vyhodnotí retenční hranici před každým krokem, nikoli jednou pro celý měsíc. Běh má samostatnou 24měsíční větev (kandidáti, odmítnutí, dekódovaná pozorování, telegramy a fragmenty), 36měsíční payloadovou větev (payloady, položky, příjmy a `device_telemetry`) a samostatné 60denní odstranění klíčů. `device_events` má 12 měsíců, ale zůstává mimo tuto funkci. Každá větev může skončit nezávisle: odložení 24měsíční větve neodkládá 36měsíční větev a naopak. Úspěšné dokončení jedné větve proto pokračuje, i když druhá větev byla odložena. Krok, jehož tabulka ještě nedosáhla vlastní hranice, je no-op a nesmí odstranit partition. Chyba při provádění kroku zastaví další kroky pouze příslušné větve; předchozí potvrzené kroky zůstávají. Odložená větev se při dalším běhu znovu vyhodnotí stejnými podmínkami. `DETACH` a `DROP` jednoho potomka jsou jedna transakce; opakované spuštění je idempotentní.

1. Vstupní kontrola 24měsíční větve ověří, že v `decode_queue` neexistuje řádek s `raw_partition_month = M`. Pokud existuje, zapíše se odložení této větve; 36měsíční payloadová větev tím není automaticky odložena.
2. Kontrola, že telegram měsíce M ve stavu `decoded` má odečet `source_key = raw:<id>`, patří pouze 24měsíční větvi. Chybějící odečet odloží tuto větev. Stavy `needs_review`, `ambiguous`, `pending`, `failed`, `no_key` a `suspect_replay` bez odečtu retenci neblokují.
3. Kontrola odkazů se provádí zvlášť pro právě plánovanou větev. Odkaz, který stejný běh odstraní ve stejné větvi, měsíc neodkládá. Odkaz z jiného měsíce nebo z tabulky, která ještě musí být uchována, odloží jen větev, která by odkaz porušila; příslušný krok zapíše důvod a data nemaže. Příjem na payload cizí klíč nemá, proto se počítá zvlášť.
4. `DELETE` z `ingest_message_keys`, kde `receipt_partition_month = M`, pouze pokud konkrétní příjmy dosáhly 60denní hranice.
5. `DETACH` a `DROP` `ingest_dedup_candidates` měsíce M pouze po dosažení 24měsíční hranice.
6. `DETACH` a `DROP` `ingest_receipts` měsíce M pouze po dosažení 36měsíční hranice.
7. `DETACH` a `DROP` `ingest_rejections` měsíce M pouze po dosažení 24měsíční hranice.
8. `DETACH` a `DROP` `decoded_observations` měsíce M pouze po dosažení 24měsíční hranice.
9. `DELETE` fragmentů s `received_at` v měsíci M pouze po dosažení jejich 24měsíční hranice.
10. `DELETE` sady jen když současně platí jejich vlastní stáří od `first_received_at`, není žádný zbývající fragment a složený payload sady buď chybí, nebo je v měsíci M a nedrží ho odkaz, který tento běh nechá. Sada s pozdním fragmentem zůstane.
11. `DETACH` a `DROP` `ingest_payload_items` měsíce M pouze po dosažení 36měsíční hranice.
12. Před payloadovou větví se znovu spočítají odkazy podle kroků skutečně plánovaných v tomto běhu. Nenulový odkaz, který by po odstranění 36měsíčních položek, příjmů nebo odmítnutí zůstal, zastaví běh před odpojením payloadu. Odkaz z 24měsíční tabulky, která již byla odstraněna při dřívějším běhu, není požadován.
13. `DETACH` a `DROP` `ingest_payloads` měsíce M pouze po dosažení 36měsíční hranice.
14. `DETACH` a `DROP` `device_telemetry` měsíce M pouze po dosažení 36měsíční hranice; tato větev není podmíněna odstraněním payloadové partition.
15. `DELETE` z `telegram_dedup_keys`, které ukazují do měsíce M, pouze podle jejich vlastního 60denního pravidla.
16. `DETACH` a `DROP` `raw_telegrams` měsíce M pouze po dosažení 24měsíční hranice kotvy.

Úspěšný skutečně provedený krok se zapíše do `retention_log` ve stejné transakci jako změna dat. Odložení se zapisuje s důvodem pro konkrétní krok/měsíc; z dokumentace není doloženo, že `retention_log` má samostatný sloupec pro název větve, proto se větev určuje podle kroku a tabulky. Krok přeskočený pouze kvůli vlastní retenční hranici je no-op a nesmí být vydáván za úspěšné odstranění. Neúspěšný krok úspěšný záznam nenechá. Chyba v jedné větvi neinvaliduje již potvrzené kroky jiné větve, ale neúspěšná větev se musí znovu pokusit při dalším běhu. `retention_log` není `audit_logs`. Příjem z pozdějšího měsíce na telegram cizí klíč nemá a tento běh ho nemaže. Opakované spuštění nesmí vytvořit druhé odstranění ani nekonzistentní záznam.

`sjv_retain_ingest_month` potvrdí každý hotový krok příkazem `COMMIT` a pak pokračuje dalším. PostgreSQL v proceduře označené `SECURITY DEFINER` nebo klauzulí `SET` tento příkaz nepovolí. Procedura proto běží s právy volajícího, bez `SET`, a volá jen objekty schématu `public`. Mazání, odpojení partition a zápis protokolu provádějí funkce vlastníka `sjv_owner` s `SECURITY DEFINER`. `sjv_maintenance` do `retention_log` přímo nezapisuje. Volání musí být mimo otevřený transakční blok.

Session zámek `83422027` drží jeden běh přes jeho kroky, takže dva běhy nesmějí retenci provádět současně. Kontrolu měsíce, vyhodnocení odkladu a zápis `deferred` dělá `sjv_retention_capture_gate`. Když po získání zámku nastane zachytitelná chyba, zámek uvolní a chybu předá dál. Chyba před získáním zámku cizí zámek téže session nespouští. Chyba kroku v `sjv_retention_apply_one` uvolní zámek; probíhající krok se vrátí a dříve potvrzené kroky zůstávají. První `COMMIT` procedury je ještě před zámkem, aby volání uvnitř jiného transakčního bloku skončilo dřív, než zámek vznikne. `COMMIT` po získání zámku tato procedura zachytit neumí, protože blok `EXCEPTION` by `COMMIT` zakázal. Selže-li až tento `COMMIT`, zámek v session zůstane. `sjv_retention_release_lock` běží jako `sjv_owner` a odemyká `83422027` jen v této session, dokud ho drží. `sjv_retention_record_failure` zámek nebere, aby nečekal na běžící retenci a neuvolnil zámek, který nezískal. Záznam `failed` přijme jen první den měsíce staršího než 24 měsíců, jeden z dvanácti retenčních kroků a důvod, který po ořezání mezer není prázdný.

Funkce a procedury retence vlastní `sjv_owner`. Pomocné funkce s `SECURITY DEFINER` mají `search_path = public`. Dynamické SQL v `sjv_retention_detach` skládá identifikátory přes `format` s `%I` a jen pro vyjmenované rodiče. `device_events` mezi nimi není. `CREATE` ve schématu `public` má jen `sjv_owner`, ostatní aplikační role mají `USAGE`. `sjv_collector`, `sjv_api` a `sjv_readonly` retenci nespouštějí. `sjv_maintenance` nemá `EXECUTE` na `sjv_retention_month_ok`, `sjv_retention_defer_reason`, `sjv_retention_detach`, `sjv_retention_apply_step`, `sjv_retention_log_deferred` ani `sjv_retention_lock_held`. Má je na veřejné procedury a také na `sjv_retention_capture_gate`, `sjv_retention_apply_one` a `sjv_retention_log_failed`: procedura s právy volajícího tyto interní objekty zavolá jen tehdy, když na ně má `EXECUTE` i volající.

Smazání nemůže poškodit odečty, protože `meter_readings` a `reading_provenance` nemají cizí klíče na mazané tabulky. `source_key` zůstává unikátní, protože se sekvence neopakují. Po smazání zůstane souhrn původu na odečtu a v `reading_provenance`. Bajty, jednotlivé časy doručení a kandidáti podobnosti zmizí. Telegram ve stavu `ambiguous`, `needs_review` nebo `suspect_replay`, který se do odečtu neuvolnil, trvalý řádek nemá a s partition zmizí. Retence se kvůli němu neprodlužuje a do spotřeby se dodatečně nedostane.

Partitions se zakládají předem pro aktuální a 3 následující měsíce. DEFAULT partition se nepoužívá. `partition_month` payloadu, položky payloadu, příjmu, kandidáta a pozorování je měsíc přijetí. U `device_telemetry` je to měsíc `received_at` v UTC, u telegramu měsíc kotvy a u `device_events` měsíc `received_at` v UTC. Hodnota mimo existující partitions je chyba, která se má projevit. Pro `device_telemetry` je toto cílový návrh R36, nikoli tvrzení o současné migraci.

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
| `sjv_api` | čtení. Zápis kmenových dat, členství, instalací, výměn, metrologické historie, přiřazení zdrojů, externích identifikátorů, schopností, umístění, firmwaru z administrace, koncových bodů, `ingest_sources` pro import, `device_telemetry` přes společný HTTPS ingest, ručních odečtů a oprav. INSERT do auditu a notifikací. U `meter_installations`, `meter_replacement_events` a `meter_verifications` smí `INSERT` a `UPDATE` a `DELETE` nemá. Podrobnosti jsou v odstavci Zákaz DELETE. `endpoint_credentials` smí vkládat a odvolávat. Do `decode_queue` smí jen `INSERT`. `secret_enc` nečte |
| `sjv_collector` | zápis do ingest tabulek včetně payloadů, fragmentů, kandidátů deduplikace a odmítnutí, `device_telemetry`, `ingest_sources` pro nově ověřené zařízení, `device_boots`, `unknown_meter_sightings`, `device_events`, pozorované schopnosti a firmware z heartbeatu, aktualizace `devices.last_seen_at`. Do `decode_queue` smí jen `INSERT`, a jen ve stejné transakci jako telegram se stavem `pending`. Na `device_external_ids` má jen `SELECT` (žádné `UPDATE`). Cílové R37-O4: `EXECUTE` na `sjv_esp_p4_assert` a `sjv_esp_instance_register_free` (DEFINER, OWNER `sjv_owner`); široké ani sloupcové `UPDATE` na `device_external_ids` kvůli `FOR UPDATE` nedostane. Zařízení nezakládá, dekódování a odečty nezapisuje a `secret_enc` nečte |
| `sjv_worker` | `decode_queue` čte, bere `FOR UPDATE SKIP LOCKED`, aktualizuje sloupce pokusu a zámku a po vyčerpání pokusů řádek smaže. Řádek fronty nevkládá. Timeout fragmentů, INSERT `meter_readings`, `notifications`, agregace. Klíč AES dešifruje jen v paměti. `secret_enc` nečte |
| `sjv_maintenance` | partitions, retence, přepočty, INSERT auditu |
| `sjv_readonly` | jen čtení, pro `restore-test.sh` a `backup-verify.sh`. Na `endpoint_credentials` čte jen `id`, `endpoint_id`, `kind`, `storage`, `created_at` a `revoked_at`. `secret_enc` nečte |
| `pgbackrest` | lokální přístup pro zálohy |

Role se zakládají jako v referenci: heslo jde přes `\getenv` a nikdy není v argumentu procesu. Row-Level Security je případná pozdější druhá vrstva. Role `pgbackrest` zůstává `LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS`. Členství v `pg_checkpoint`, `pg_read_all_settings` a `pg_read_all_stats` má `INHERIT TRUE`, protože PostgreSQL 19 jinak tato členství nezdědí. Členství v `pg_checkpoint` není totéž co právo spouštět zálohovací funkce. V PostgreSQL 19.0 mají `pg_backup_start(text, boolean)`, `pg_backup_stop(boolean)`, `pg_create_restore_point(text)` a `pg_switch_wal()` právo `EXECUTE` jen pro bootstrap superuser, dokud se neudělí zvlášť roli `pgbackrest`. Bez toho `pgbackrest check` a plná záloha končí chybou `permission denied`, i když je `inherit_option` členství true.

## Migrace

- Alembic v `app/backend/alembic/`, jen dopředné migrace. Před každou migrací `deploy.sh` vynutí čerstvou zálohu pgBackRest, takže se místo `downgrade` počítá s obnovou.
- Konvence pojmenování constraintů v SQLAlchemy `MetaData`. Tabulky, klíče, `CHECK`, exclusion constrainty a částečné indexy vznikají z tohoto metadat, aby je `alembic check` viděl. Měsíční partitions, triggery a granty jsou v SQL migrace.
- Stav k 20. 11. 2026, migrace `0001_ingest_schema`: implementováno a izolovaně otestováno na prázdné PostgreSQL 19.0. `alembic upgrade head` a `alembic check` prošly na dvou samostatných prázdných databázích. `test.sh` databázi nespouští. Živý běh je `app/backend/tests/isolated-schema-test.sh`. K 21. 11. 2026 přidává `0003_retention` protokol `retention_log` a proceduru `sjv_retain_ingest_month`. K 27. 11. 2026 je head `0004_receipt_status_update`: pouze `GRANT UPDATE (status) ON ingest_receipts TO sjv_collector` pro R20 větev `evaluate_item`; tabulky a constrainty nemění. Bez 0004 nesmí jít do provozu evaluator, který `status` při `duplicate_delivery` aktualizuje.
- Migrace obsahuje ingest a referenční tabulky, bez kterých tento rozsah nedrží: `source_streams`, `meters`, `meter_external_ids`, `devices`, `device_external_ids`, `device_firmware_history`, `device_capabilities`, `device_credentials`, `device_boots`, `ingest_endpoints`, `endpoint_credentials`, `ingest_sources`, `ingest_payloads`, `ingest_receipts`, `ingest_message_keys`, `raw_telegrams`, `telegram_dedup_keys`, `ingest_dedup_candidates`, `ingest_fragment_sets`, `ingest_fragments`, `ingest_rejections`, `unknown_meter_sightings`, `decoded_observations`, `decode_queue`, `meter_readings`, `reading_provenance` a `device_events`. `device_telemetry` v této existující migraci není; její tabulka, partitions, constrainty a granty jsou cílovou částí návrhu R36 a nejsou tímto dokumentem vydávány za implementované.
- Neobsahuje uživatele, RBAC, budovy, byty, členství, instalace, výměny, metrologii, `meter_source_assignments`, `meter_daily_values`, `device_placements`, notifikace, audit ani sessions. Návrh těchto tabulek se nemění.
- `message_ref` unikátní omezení nemá. Skládání fragmentů, spojování podle `group_key` a evidence doručení po `timed_out` implementované nejsou.
- V existující migraci `sjv_collector` dostává `SELECT` na `devices`, `ingest_endpoints` a `device_external_ids`, `UPDATE (last_seen_at)` na `devices`, `SELECT` a `INSERT` do implementovaných ingest tabulek včetně payloadů, položek payloadů, příjmů, odmítnutí, klíčů, fragmentů, sad, kandidátů, `telegram_dedup_keys`, `raw_telegrams`, `decoded_observations`, `unknown_meter_sightings`, `device_boots`, `device_events`, `device_firmware_history` a `device_capabilities`, sloupcové `UPDATE` jen u sloupců, které schválený postup mění (od `0004_receipt_status_update` včetně `UPDATE (status)` na `ingest_receipts`), a `SELECT` sloupců `meters` kromě `aes_key_enc` a `aes_key_fingerprint`. `USAGE` a `SELECT` má na sekvenci `raw_telegrams`. Na `decode_queue` má jen `INSERT`. Na `device_external_ids` **nemá** `UPDATE` (ani sloupcové); budoucí R37-O4 zámky P4 a první registraci zajišťují DEFINER funkce, ne grant `UPDATE` collectoru. `endpoint_credentials`, `device_credentials`, `meter_readings` a `reading_provenance` nedostává. Zařízení nezakládá, dekódování a odečty nezapisuje a `secret_enc` nečte. `sjv_api` dostává na `decode_queue` jen `INSERT`; cílové oprávnění k `device_telemetry` je součástí R36, nikoli aktuální migrace. `sjv_worker` dostává na `decode_queue` `SELECT`, sloupcový `UPDATE` u `attempts`, `next_attempt_at`, `locked_by`, `locked_at` a `last_error` a `DELETE`. `INSERT` do fronty, `secret_enc`, `meter_readings` a zápis `raw_telegrams.decode_status` nedostává. `sjv_maintenance` smí spouštět `sjv_create_month_partition`, `sjv_retain_ingest_month`, `sjv_retention_record_failure` a `sjv_retention_release_lock`. Do `retention_log` přímo nezapisuje. `sjv_readonly` má na `endpoint_credentials` jen sloupcové `SELECT` metadat řádku a `secret_enc` nečte.
