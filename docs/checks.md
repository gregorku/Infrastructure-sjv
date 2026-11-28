# Kontroly a testy

Stav: etapa B1b. Sada běží offline. `docker compose config` se spustí jen když je CLI k dispozici a nic nespouští.

## Přehled

| Příkaz | Kde | Mění soubory | Účel |
| --- | --- | --- | --- |
| `./scripts/test.sh` | lokální vývoj / offline | jen `.test-tmp/` (po běhu smazáno) | unit a statické testy bez Dockeru |
| `app/backend/tests/isolated-schema-test.sh` | vývojový stroj s Dockerem | jen vlastní dočasné Docker objekty a `sjv-alembic-itest.*` | jednorázový integrační test migrací a recovery |
| `./scripts/shellcheck.sh` | kde je ShellCheck | ne | lint Bash |
| `sudo ./scripts/check-env.sh` | produkční server | ne | ověření runtime `.env` a práv |

`test.sh` je lokální offline sada. Nepotřebuje root, síť, Docker ani `/docker-data`. Skončí nenulovým kódem, pokud selže kterýkoli test. Přeskočené testy vypíše jako `SKIP` s důvodem a nepočítá je jako úspěšné.

`isolated-schema-test.sh` je jednorázová kontrola, ne produkční služba. Sestaví dočasný image z `app/backend/Dockerfile.test` (zamčené závislosti z `uv.lock`), spustí dočasné PostgreSQL 19.0 ve vlastní síti a Alembic i Python testy provede jen uvnitř toho image. Hostitelský Debian neinstaluje `uv`, Alembic, SQLAlchemy ani testovací Python balíčky. Po běhu maže jen objekty s vlastním run ID.

Provozní skripty `python3` ani `shellcheck` nevolají a `check_environment` je nevyžaduje. Kompletní offline běh `test.sh` na Debianu 13 tyto dva balíčky potřebuje:

```bash
apt-get install python3 shellcheck
```

Chybějící `python3` ukončí krok kontraktu ingestu chybou a text pojmenuje balíček `python3`. Chybějící `shellcheck` nechá `shellcheck.sh` skončit kódem 3 a doporučí `apt-get install shellcheck`. `test.sh` tento krok přeskočí a dál doporučí `apt-get install python3 shellcheck`. Ostatní testy a bezpečnostní kontroly pokračují.

## Co ověřuje `test.sh`

### Statické kontroly

- `bash -n` všech shell souborů.
- Hlavička `#!/usr/bin/env bash`; vstupní skripty mají `set -Eeuo pipefail`, chybový trap a jsou spustitelné.
- Zakázané konstrukce: `eval`, `set -x`, `curl | sh`, `chmod` zapisovatelný pro všechny nebo rekurzivní, `sudo`, příkazy `docker`, `zfs`, `zpool`, `incus`, `nixos-rebuild`, `restic`, `rest-server`, `wg`, `nft`, `iptables`, `systemctl`, výpis proměnných `*PASSWORD*`, `*SECRET*`, `*TOKEN*`, `source` souboru `.env`, rekurzivní `rm` mimo úklid v `test.sh`. Každý detektor se nejdřív ověří na vzorku, který musí zachytit.
- Hygiena repozitáře: žádný `.env` ani soubory podobné tajemstvím v checkoutu, `.gitignore` je pokrývá, názvy dokumentů malými písmeny, žádný tag `latest` v `.env.example` a `config.sh`.
- `.env.example`: dá se načíst, má stejné klíče jako `ENV_POLICY`, neobsahuje tajemství ani skutečnou doménu. `SJV_DOMAIN` a `MQTT_HOSTNAME` jsou uživatelské a v šabloně mají `example.com` a `mqtt.example.com`. Čtyři projektové podsítě jsou `172.20.0.0/24` až `172.23.0.0/24`. Validátor šablonu odmítne a po doplnění ostatních hodnot odmítne i samotná dokumentační jména.

### Knihovna `.env`

- Parser: duplicitní klíč, `export`, malá písmena v klíči, řádek bez `=`, CRLF, nebezpečné znaky a symlink jsou odmítnuté. Hodnota `$(…)` se nespustí.
- Sítě: platné a neplatné CIDR, překryvy, privátní a veřejné adresy.
- Validace: chybějící a neznámé proměnné, placeholdery, dokumentační hostname, obecné DNS jméno, pevné hodnoty, čtyři projektové sítě a brány, překryv s `10.10.10.0/24`, `10.100.101.0/24`, `10.110.110.0/24`, `10.120.120.0/24` a `172.17.0.0/16`, allowlist, režimy TLS a PROXY protokolu, publikace administrace Traefiku, účty PostgreSQL a MQTT, hesla, retence ingestu, restic, SMTP, logy, odkazy na image s digestem, `POSTGRES_IMAGE` jen jako `postgres:19.0` s digestem a `PGBACKREST_VERSION` jen `2.60.1`. Chybové zprávy neobsahují tajné hodnoty.
- Synchronizace: vytvoření s právy 600, generování různých tajemství bez výpisu, opakovaný běh bez přepisu a bez zálohy, zachování uživatelských hodnot a tajemství, obnovení hodnot `framework` po záloze, zúžení práv `.env` a záloh, odmítnutí nečitelného `.env`, symlinku, zapisovatelného adresáře a vadného `.env.example`.

### Skripty v testovacím režimu

- Pojistka `SJV_TEST_BASE_DIR`: jen přesně `.test-tmp/<běh>/base` uvnitř checkoutu. Cesta se neporovnává jako regulární výraz. Symlink v kterékoli složce, `atest-tmp` i `//test-tmp` jsou odmítnuté.
- `init.sh`: adresáře a práva, kopie `.env.example`, žádný `.env`, opakovaný běh beze změny, zúžení práv, odmítnutí symlinku. `postgresql` je v `DEPLOY_ITEMS`. Synchronizace zkopíruje `Dockerfile`, `pgbackrest.conf` a `docker-entrypoint-initdb.d` do stacku. Druhý běh tyto shodné soubory nemění. Compose `context: ../postgresql` po kopii míří na `/docker-data/stacks/infrastructure-sjv/postgresql`, ne do datového adresáře. `/docker-data` test nesáhne.
- `update-env.sh`: vytvoření `.env`, výpis placeholderů a dokumentačních jmen, opakovaný běh beze změny souborů i adresářů, zachování doplněných hodnot včetně `SJV_DOMAIN` a `MQTT_HOSTNAME`, záloha před obnovou hodnoty `framework`, zámek proti souběhu, odmítnutí zastaralé kopie `.env.example`.
- `update-env.sh` a `check-env.sh` volají `require_mountpoint` dřív, než sáhnou na `.env`. Bez mountpointu nic nezapíšou a nezaloží adresář.
- `check-env.sh`: odmítne `example.com` a `mqtt.example.com` jako produkční domény a spolu s nimi ostatní chyby, práva 644 u `.env` i záloh, osiřelý `.env.tmp.*`, visící symlink `.env` v checkoutu a nebezpečný allowlist; přijme kompletní konfiguraci; nikdy nic nezmění a nevypíše tajemství.
- Compose a konfigurace: v repozitáři není `docker.sock`, bouncer klíč není proměnná `.env`, gitová šablona admin portu nic nepublikuje. Image mají tag i digest podporované řady, plugin má verzi a sha256 katalogového zipu. `sjv-postgresql` je jen na `sjv-internal`, bez publikovaného portu, s `pg_isready`, checksums a rolemi bez superuser oprávnění. Členství `pgbackrest` v `pg_checkpoint`, `pg_read_all_settings` a `pg_read_all_stats` má `INHERIT TRUE`. Grant bez této volby test odmítne. Samostatně musí být `EXECUTE` na `pg_backup_start(text, boolean)`, `pg_backup_stop(boolean)`, `pg_create_restore_point(text)` a `pg_switch_wal()`. Jiná signatura nebo chybějící grant testem neprojde. Členství v `pg_checkpoint` toto `EXECUTE` nenahrazuje. `docker compose config` se spustí jen když je nainstalované Docker CLI.
- Plán sítí bez Docker démona: `sjv-internal` je jediná interní, cizí síť se nemění, překryv zastaví vytvoření, shodná označená síť se nezakládá znovu. Traefik není na `sjv-egress`, CrowdSec není na `sjv-proxy`.
- `deploy.sh --render-only` v testovacím režimu vykreslí Traefik bez Docker provideru, s file providerem, allowlistem, limity rotace `traefik.log` a budoucími routami API a webu. Middleware bounceru chybí, dokud nevznikne soubor klíče s právy 600. Druhé vykreslení soubor nemění. `--render-only` nezaloží `access.log` a Docker nezavolá. Plný `deploy.sh` v testovacím režimu skončí před Dockerem. Jeho jediný Compose příkaz je `docker_compose up -d traefik crowdsec sjv-backup`, bez `--build` a bez PostgreSQL. `access.log` se v pořadí skriptu zakládá až po návratu `--render-only` a před tímto příkazem. Samostatná příprava chybějícího `access.log` založí prázdný soubor s právy 640, existující obsah nechá, symlink odmítne a na `/docker-data` nesáhne. `compose/30-backup.yml` a `compose/40-postgresql.yml` v `compose.yml` zůstávají.
- Healthcheck CrowdSec v Compose je `cscli lapi status`. Traefik na něj dál čeká přes `service_healthy`.
- `sjv-backup` je v `compose/30-backup.yml`, jen na `sjv-egress`, bez portu, s `pgbackrest/` a `preparations/` pouze pro čtení. `scripts/backup.sh` publikuje přípravu a denní snapshot vytváří výhradně plánovač. Testy ověřují validaci `current`, manifestu, ID, skutečných souborů, jedinečného tagu a dohledání snapshot ID i manifestu v snapshotu. Dále ověřují plán `wal`, zámky proti souběhu, zákaz `forget`, `prune` a vypnutí TLS, předání `--cacert`, nečinnost bez hesla REST serveru, přeskočení prázdného WAL archivu, heartbeat během dlouhé zálohy a ukončení procesu heartbeatu. Produkční repozitář se nekontaktuje. Sestavení image a `flock` uvnitř něj se spustí jen když je k dispozici Docker nebo Podman.
- Rotace `access.log`: práh velikosti a stáří, copytruncate se stejným inode, vlastníkem a právy, archiv 640, retence 14, odmítnutí symlinku, úklid po selhání gzipu a ponechání souboru mimo adresář logů. `traefik.log` skript nemění.
- Zápis klíče smaže jen svůj dočasný soubor. Výstup klíč neobsahuje.

### Kontrakt ingestu a TX1 recovery (unit)

- `app/backend/tests/test_ingest_contract.py` běží přes `python3` a standardní `unittest`. Pytest v projektu není. Test neotevírá PostgreSQL ani kontejner. Selhání kteréhokoli případu ukončí `test.sh` nenulovým kódem. Chybějící příkaz `python3` skončí stejnou chybou a text pojmenuje balíček `python3`. Výstup nepíše bajtkód do repozitáře.
- `app/backend/tests/test_recovery.py` běží stejně offline: SQL stránkování / keyset, klasifikace výjimek a SQLSTATE, validace `batch_size` a CLI exit kódy. PostgreSQL ani kontejner neotevírá. Periodickou orchestraci recovery netestuje — ta v repozitáři není.

## Testy, které `test.sh` nespustí

| Test | Důvod | Jak ověřit |
| --- | --- | --- |
| `.env` jiného vlastníka | `test.sh` ho spustí, jen když běží jako root | jinak je poctivě přeskočený |
| ShellCheck | balíček `shellcheck` chybí | `./scripts/shellcheck.sh` skončí kódem 3 a doporučí `apt-get install shellcheck`. `test.sh` krok přeskočí |
| `require_mountpoint` v testovacím režimu | testovací režim ho přeskakuje | bez `SJV_TEST_BASE_DIR` a bez `/docker-data` musí `init.sh`, `update-env.sh` i `check-env.sh` skončit chybou a nic nevytvořit |
| Izolovaná záloha a obnova pgBackRest | `test.sh` nespouští databázový kontejner | ruční běh jen v dočasném adresáři, mimo `/docker-data`. Poslední úspěch je 20. 11. 2026 a postup je v [operations.md](operations.md#záloha-a-obnova-postgresql) |
| Ingest migrace PostgreSQL 19.0 | `test.sh` nespouští databázový kontejner | `app/backend/tests/isolated-schema-test.sh`: dočasný Python image (`Dockerfile.test`) + dočasné PostgreSQL 19.0 ve vlastní Docker síti. Alembic a Python testy neběží na hostitelském Debianu. Maže jen objekty s vlastním run ID. Kontroluje `alembic upgrade head` (head `0004_receipt_status_update`), `alembic check`, roli fragmentu, frontu dekódování, měsíc `device_events`, mapování `endpoint_credentials`, zákaz čtení `secret_enc` pro `sjv_readonly`, uložení payloadu a položek, příjem prázdné obálky rolí `sjv_collector` a sloupcové `UPDATE (status)` na `ingest_receipts` pro `sjv_collector` (migrace 0004; bez práva na ostatní sloupce receiptu) |
| Retence ingestu staršího než 24 měsíců | `test.sh` nespouští databázový kontejner | Stejný izolovaný běh uvnitř test image, `tests/retention_tests.py`, rolí `sjv_maintenance`. Odklad kvůli `decode_queue` a kvůli `decoded` bez odečtu `raw:<id>`. Stavy `needs_review`, `ambiguous`, `pending`, `failed`, `no_key` a `suspect_replay` samy retenci neblokují. Odkaz na payload, který běh nechá, měsíc odloží. Odkaz odstraněný v tomtéž běhu payload pustí. Položky se odpojí před payloadem. `telegram_dedup_keys` se mažou před `raw_telegrams`. Příjem jiného měsíce a `device_events` zůstávají. `DETACH` a `DROP` jednoho potomka jsou jedna transakce a úspěch v `retention_log` je v ní. Chyba další krok měsíce nespustí a úspěšný záznam tohoto kroku nenechá. Zachytitelná chyba odkladu, kroku i vyhodnocení důvodu uvolní session zámek a další běh ho získá. Cizí zámek téže session odmítnutí mladého měsíce neuvolní. Dva běhy současně retenci neprovádějí. Volání uvnitř otevřené transakce skončí před získáním zámku. `COMMIT` po získání zámku procedura nezachytí; `sjv_retention_release_lock` pak uvolní jen zámek této session. Neplatný měsíc, krok nebo prázdný důvod `failed` nezapíšou. Vlastník funkcí je `sjv_owner`. `sjv_collector`, `sjv_api` a `sjv_readonly` retenci nespouštějí a `CREATE` ve schématu `public` nemá nikdo kromě `sjv_owner`. `ingest_receipts` na payload cizí klíč nemá |
| TX1 recovery (izolované) | `test.sh` nespouští databázový kontejner | Stejný izolovaný běh uvnitř test image, `tests/recovery_tests.py`: výběr položek bez receiptu, volání existujícího `evaluate_item`, souběh / opakovaný běh, oprávnění `sjv_collector`. Periodický worker, host timer ani historický backfill se netestují — v repozitáři nejsou |

## Kontrola na serveru po instalaci

1. `sudo ./scripts/check-env.sh` skončí kódem 0.
2. `stat -c '%a %U' /docker-data/stacks/infrastructure-sjv/.env` vrátí `600 root`.
3. `git -C /incus-dir/git/Infrastructure-sjv status --short` neukazuje `.env` ani jiné runtime soubory.
