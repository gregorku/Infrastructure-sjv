# Kontroly a testy

Stav: etapa B1b. Sada běží offline. `docker compose config` se spustí jen když je CLI k dispozici a nic nespouští.

## Přehled

| Příkaz | Kde | Mění soubory | Účel |
| --- | --- | --- | --- |
| `./scripts/test.sh` | vývoj, CI, server | jen `.test-tmp/` (po běhu smazáno) | offline testy |
| `./scripts/shellcheck.sh` | kde je ShellCheck | ne | lint Bash |
| `sudo ./scripts/check-env.sh` | server | ne | ověření runtime `.env` a práv |

`test.sh` nepotřebuje root, síť, Docker ani `/docker-data`. Skončí nenulovým kódem, pokud selže kterýkoli test. Přeskočené testy vypíše jako `SKIP` s důvodem a nepočítá je jako úspěšné.

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
- `init.sh`: adresáře a práva, kopie `.env.example`, žádný `.env`, opakovaný běh beze změny, zúžení práv, odmítnutí symlinku.
- `update-env.sh`: vytvoření `.env`, výpis placeholderů a dokumentačních jmen, opakovaný běh beze změny souborů i adresářů, zachování doplněných hodnot včetně `SJV_DOMAIN` a `MQTT_HOSTNAME`, záloha před obnovou hodnoty `framework`, zámek proti souběhu, odmítnutí zastaralé kopie `.env.example`.
- `update-env.sh` a `check-env.sh` volají `require_mountpoint` dřív, než sáhnou na `.env`. Bez mountpointu nic nezapíšou a nezaloží adresář.
- `check-env.sh`: odmítne `example.com` a `mqtt.example.com` jako produkční domény a spolu s nimi ostatní chyby, práva 644 u `.env` i záloh, osiřelý `.env.tmp.*`, visící symlink `.env` v checkoutu a nebezpečný allowlist; přijme kompletní konfiguraci; nikdy nic nezmění a nevypíše tajemství.
- Compose a konfigurace: v repozitáři není `docker.sock`, bouncer klíč není proměnná `.env`, gitová šablona admin portu nic nepublikuje. Image mají tag i digest podporované řady, plugin má verzi a sha256 katalogového zipu. `sjv-postgresql` je jen na `sjv-internal`, bez publikovaného portu, s `pg_isready`, checksums a rolemi bez superuser oprávnění. Členství `pgbackrest` v `pg_checkpoint`, `pg_read_all_settings` a `pg_read_all_stats` má `INHERIT TRUE`. Grant bez této volby test odmítne. Samostatně musí být `EXECUTE` na `pg_backup_start(text, boolean)`, `pg_backup_stop(boolean)`, `pg_create_restore_point(text)` a `pg_switch_wal()`. Jiná signatura nebo chybějící grant testem neprojde. Členství v `pg_checkpoint` toto `EXECUTE` nenahrazuje. `docker compose config` se spustí jen když je nainstalované Docker CLI.
- Plán sítí bez Docker démona: `sjv-internal` je jediná interní, cizí síť se nemění, překryv zastaví vytvoření, shodná označená síť se nezakládá znovu. Traefik není na `sjv-egress`, CrowdSec není na `sjv-proxy`.
- `deploy.sh --render-only` v testovacím režimu vykreslí Traefik bez Docker provideru, s file providerem, allowlistem, limity rotace `traefik.log` a budoucími routami API a webu. Middleware bounceru chybí, dokud nevznikne soubor klíče s právy 600. Druhé vykreslení soubor nemění. Plný `deploy.sh` v testovacím režimu skončí před Dockerem.
- Healthcheck CrowdSec v Compose je `cscli lapi status`. Traefik na něj dál čeká přes `service_healthy`.
- `sjv-backup` je v `compose/30-backup.yml`, jen na `sjv-egress`, bez portu, se zdroji a TLS certifikátem jen pro čtení. Plán `daily` a `wal`, zámek proti souběhu, zákaz `forget`, `prune` a vypnutí TLS, předání `--cacert` pro `backup` i `snapshots`, nečinnost bez hesla REST serveru, přeskočení prázdného WAL archivu, heartbeat během dlouhé zálohy a ukončení procesu heartbeatu se ověřují na náhradní binárce. Stejné testy ověřují, že obsazený `backup.lock` nebo `repo.lock` denní úlohu hned přeskočí, že `wal` ani při `SJV_BACKUP_LOCK_WAIT=600` na `repo.lock` nečeká, že po obsazeném zámku je další pokus podle retry intervalu a po úspěchu, prázdném archivu nebo chybě Resticu až po standardním intervalu, že restart ctí uložený čas dalšího pokusu, že se Restic úlohy nepřekrývají a že symlink ve WAL archivu není platný soubor. Produkční repozitář se nekontaktuje. Sestavení image a `flock` uvnitř něj se spustí jen když je k dispozici Docker nebo Podman.
- Rotace `access.log`: práh velikosti a stáří, copytruncate se stejným inode, vlastníkem a právy, archiv 640, retence 14, odmítnutí symlinku, úklid po selhání gzipu a ponechání souboru mimo adresář logů. `traefik.log` skript nemění.
- Zápis klíče smaže jen svůj dočasný soubor. Výstup klíč neobsahuje.

## Testy, které `test.sh` nespustí

| Test | Důvod | Jak ověřit |
| --- | --- | --- |
| `.env` jiného vlastníka | `test.sh` ho spustí, jen když běží jako root | jinak je poctivě přeskočený |
| ShellCheck | nemusí být nainstalovaný | `./scripts/shellcheck.sh` (kód 3 = nespuštěno) |
| `require_mountpoint` v testovacím režimu | testovací režim ho přeskakuje | bez `SJV_TEST_BASE_DIR` a bez `/docker-data` musí `init.sh`, `update-env.sh` i `check-env.sh` skončit chybou a nic nevytvořit |
| Izolovaná záloha a obnova pgBackRest | `test.sh` nespouští databázový kontejner | ruční běh jen v dočasném adresáři, mimo `/docker-data`. Poslední úspěch je 20. 11. 2026 a postup je v [operations.md](operations.md#záloha-a-obnova-postgresql) |
| Ingest migrace PostgreSQL 19.0 | `test.sh` nespouští databázový kontejner | `app/backend/tests/isolated-schema-test.sh` ve vlastním dočasném Podman úložišti. Maže jen `/tmp/sjv-alembic-itest` a svou testovací síť. Kontroluje `alembic upgrade head`, `alembic check`, roli fragmentu, frontu dekódování, měsíc `device_events`, mapování `endpoint_credentials`, zákaz čtení `secret_enc` pro `sjv_readonly` a retenci `DETACH PARTITION CONCURRENTLY` |

## Kontrola na serveru po instalaci

1. `sudo ./scripts/check-env.sh` skončí kódem 0.
2. `stat -c '%a %U' /docker-data/stacks/infrastructure-sjv/.env` vrátí `600 root`.
3. `git -C /incus-dir/git/Infrastructure-sjv status --short` neukazuje `.env` ani jiné runtime soubory.
