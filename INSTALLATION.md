# Instalační a provozní příručka

Příručka říká, co se dnes na VPS skutečně spouští, v jakém pořadí a jak poznat, že krok doběhl. Podrobnosti adresářů, politiky `.env`, CrowdSec a ověřené obnovy pgBackRest jsou v [docs/operations.md](docs/operations.md). Tahle stránka je neopakuje.

Stav repozitáře je etapa B1b. `deploy.sh` spouští Traefik a CrowdSec. `sjv-backup` a `sjv-postgresql` jsou v Compose a tento skript je nespouští. Aplikace, MQTT, `pg_dump`, `upgrade.sh`, `backup.sh`, `restore.sh`, `maintenance.sh` a jeho timer v repozitáři nejsou.

## A. Přehled

Vývojová kontrola je `./scripts/test.sh`. Nepotřebuje root ani Docker démona a na hostiteli nic nemění. Izolovaná kontrola schématu je `app/backend/tests/isolated-schema-test.sh`. Běží ve vlastním dočasném Podman úložišti, maže jen `/tmp/sjv-alembic-itest` a svou síť a odmítne `/docker-data` i `SJV_DATABASE_URL` z okolí. Ani jeden z těchto běhů není instalace na VPS.

Provozní instalace je ruční postup v Incus kontejneru `sjv-monitoring`. `init.sh`, `update-env.sh`, `check-env.sh`, `deploy.sh`, `init-backup.sh`, `post-deploy.sh`, `reload.sh`, `create-dashboard-user.sh` a `rotate-traefik-logs.sh` chtějí root a mountpoint `/docker-data`. `shellcheck.sh` root nechce. Repozitář DNS, HAProxy, Incus ani firewall nemění.

Pořadí první instalace, jak ho skripty samy vypisují:

1. `sudo ./scripts/init.sh`
2. `sudo ./scripts/update-env.sh`
3. úprava runtime `.env` mimo Git
4. `sudo ./scripts/check-env.sh`
5. `sudo ./scripts/create-dashboard-user.sh`
6. `sudo ./scripts/deploy.sh`
7. `sudo ./scripts/init-backup.sh`
8. `sudo ./scripts/post-deploy.sh`

Aktualizace konfigurace a znovuspuštění stejných služeb je jiný postup a je v části G. Databázové migrace do tohoto pořadí nepatří, protože je žádný instalační skript nespouští.

Související dokumenty:

| Dokument | K čemu |
| --- | --- |
| [docs/operations.md](docs/operations.md) | adresáře, politika `.env`, první instalace, logy, záloha a obnova |
| [docs/architecture.md](docs/architecture.md) | sítě, porty, co je na VPS a co tento repozitář nemění |
| [docs/database-design.md](docs/database-design.md) | schéma, role, retence |
| [docs/backup-strategy.md](docs/backup-strategy.md) | návrh záloh |
| [docs/checks.md](docs/checks.md) | co které testy pokrývají a co je přeskočené |
| [docs/security.md](docs/security.md) | bezpečnostní model |
| [docs/external-changes.md](docs/external-changes.md) | změny mimo repozitář, dosud neschválené |
| [docs/implementation-plan.md](docs/implementation-plan.md) | co ještě není hotové |

## B. Předpoklady

### Provoz

Skripty `init.sh`, `update-env.sh`, `check-env.sh`, `deploy.sh`, `init-backup.sh` a `post-deploy.sh` volají `check_environment`. Ta vyžaduje root a příkazy `awk`, `base64`, `cmp`, `cp`, `date`, `find`, `findmnt`, `flock`, `head`, `install`, `mktemp`, `sort`, `stat` a `tr`. `deploy.sh` a `post-deploy.sh` navíc chtějí `docker` a fungující `docker compose`. `init-backup.sh` je chce jen tehdy, když je vzdálený repozitář vyplněný a běží mimo testovací režim. `create-dashboard-user.sh` chce `htpasswd`. `rotate-traefik-logs.sh` chce root, `gzip`, `truncate`, `sync`, `date`, `find`, `cp` a `mktemp`. `python3` a `shellcheck` mezi těmito příkazy nejsou. Provozní instalace je bez nich spustitelná.

### Vývoj a testování

Kompletní `./scripts/test.sh` na Debianu 13 potřebuje balíčky `python3` a `shellcheck`. Na VPS se neinstalují kvůli `init.sh` ani `deploy.sh`.

```bash
apt-get install python3 shellcheck
```

Chybějící `python3` ukončí krok kontraktu ingestu chybou a text pojmenuje balíček `python3`. Chybějící `shellcheck` nechá `./scripts/shellcheck.sh` skončit kódem 3 a doporučí `apt-get install shellcheck`. Python k tomu není potřeba. `test.sh` tento krok přeskočí, ostatní testy a bezpečnostní kontroly doběhnou a dál doporučí `apt-get install python3 shellcheck`.

Cílová databáze v Compose je PostgreSQL 19.0 s pgBackRest 2.60.1. Image je `POSTGRES_IMAGE` v `.env.example`, tag `19.0` a index digest. Tag `19` ani `latest` validace nepřijme. Služba `sjv-postgresql` nepublikuje port a je jen v síti `sjv-internal`.

Veřejné HTTP a HTTPS jdou na Traefik, porty 80 a 443. Dashboard je port 8443 a jen tehdy, když existuje soubor hesel mimo Git. V šabloně je publikace `10.10.10.20:8443:8443`. MQTT port 8883, backend a web jsou v [docs/architecture.md](docs/architecture.md) jako pozdější služby. V aktuálním `deploy.sh` se nespouštějí.

`/docker-data` musí být samostatný mountpoint. Když není, `init.sh`, `update-env.sh` a `check-env.sh` skončí chybou a adresář ani `.env` nezaloží. Git checkout má být mimo `/docker-data`. Konvence `/incus-dir/git/Infrastructure-sjv` v dokumentaci pořád není potvrzená.

Adresáře, práva a svazky zakládá `init.sh`. Tabulka cest je v [docs/operations.md](docs/operations.md#adresáře). Data PostgreSQL jsou `/docker-data/infrastructure-sjv/postgresql`, v kontejneru `/var/lib/postgresql`, PGDATA podle image `/var/lib/postgresql/19/docker`. Repozitář pgBackRest je `/docker-data/backups/infrastructure-sjv/pgbackrest`. Build context image je jiná cesta: `/docker-data/stacks/infrastructure-sjv/postgresql`. `init.sh` a `deploy.sh` ji plní z adresáře `postgresql/` v Gitu. `compose/40-postgresql.yml` má `context: ../postgresql`, takže z runtime souboru `compose/40-postgresql.yml` tato cesta vyjde. Datový adresář se při tom nepřepisuje. Stejně se kopíruje `backup/`. Jeho build context je `/docker-data/stacks/infrastructure-sjv/backup` a používá ho až jednorázový `init-backup.sh`.

Hesla databázových rolí, MQTT a rest-server vznikají až v runtime `.env` nebo v souborech pod `/docker-data`. Do dokumentace nepatří.

## C. Příprava konfigurace

URL vzdáleného Git serveru v repozitáři není. Příručka počítá s hotovým checkoutem na stroji, kde se skripty spouštějí.

Šablona je `.env.example` v kořeni. `init.sh` ji zkopíruje do `/docker-data/stacks/infrastructure-sjv/`. Runtime soubor je `/docker-data/stacks/infrastructure-sjv/.env`. V checkoutu `.env` být nesmí. `check-env.sh` takový soubor odmítne.

`update-env.sh` šablonu nečte z Gitu napřímo. Nejdřív porovná kopii ve stacku s `.env.example`. Když se liší, skončí a chce znovu `init.sh`.

Skupiny v `.env.example`:

| Skupina | Proměnné | Poznámka |
| --- | --- | --- |
| Identita stacku | `TZ`, `COMPOSE_PROJECT_NAME`, `DATA_DIR`, `BACKUP_LOCAL_DIR` | cesty dat a záloh |
| Jména | `SJV_DOMAIN`, `MQTT_HOSTNAME` | v šabloně `example.com` a `mqtt.example.com`. V provozu se nahradí. Další `update-env.sh` existující jména nepřepíše |
| Sítě | `DOCKER_*_SUBNET`, `DOCKER_*_GATEWAY` | čtyři rozsahy `172.20.0.0/24` až `172.23.0.0/24`, brány `.1` |
| Proxy | `PROXY_PROTOCOL_MODE`, `PROXY_PROTOCOL_TRUSTED_IPS` | šablona má `haproxy` a `10.10.10.1/32`. Adresu je před spoléháním se na ni ověřit z provozu |
| Traefik | `TRAEFIK_TLS_MODE`, `TRAEFIK_ACME_EMAIL`, `TRAEFIK_ADMIN_PUBLISH`, `ADMIN_IP_ALLOWLIST` | e-mail je `set_acme_email`, dokud není režim `local` |
| Image | `TRAEFIK_IMAGE`, `CROWDSEC_IMAGE`, `CROWDSEC_BOUNCER_PLUGIN`, `CROWDSEC_BOUNCER_PLUGIN_HASH`, `POSTGRES_IMAGE`, `PGBACKREST_VERSION` | tag a digest, kategorie `framework`. `update-env.sh` ruční změnu vrátí |
| Role PostgreSQL | `PG_DB`, `PG_BOOTSTRAP_USER`, `PG_*_USER`, `PG_*_PASSWORD` | hesla v šabloně jsou `set_*`. Skript je vygeneruje a nevypíše |
| MQTT | `MQTT_*_USER`, `MQTT_*_PASSWORD` | služba MQTT zatím není nasazená. Hesla se přesto generují |
| Příjem | `INGEST_MAX_MESSAGE_AGE_DAYS`, `INGEST_KEY_RETENTION_DAYS` | v šabloně 30 a 60. Věk zprávy musí být kratší než retence klíčů |
| Vzdálená záloha | `RESTIC_REPOSITORY`, `RESTIC_REST_PASSWORD` | prázdné je varování, ne tvrdá chyba. Heslo v URL být nesmí |
| Pošta | `SMTP_*`, `MAIL_FROM` | prázdný `SMTP_HOST` nechá notifikace ve frontě |
| Logy Compose | `LOG_MAX_SIZE`, `LOG_MAX_FILES` | stdout kontejnerů, ne soubor `access.log` |

Politika `framework`, `user` a `generated` je v [docs/operations.md](docs/operations.md#politika-proměnných-env_policy). Hodnoty se píší bez uvozovek. `$`, zpětný apostrof, `"`, `'`, `\`, `#`, CR a mezery na okrajích `check-env.sh` odmítne. Soubor se nespouští přes `source` ani `eval`.

Tajné hodnoty jsou jen v runtime `.env` (práva 600, vlastník root) a v souborech pod `/docker-data/infrastructure-sjv/secrets/` a v souboru bouncer klíče. Skripty je netisknou. Záloha `.env` před přepisem je `.env.bak-<čas UTC>`. Při více než 20 zálohách `update-env.sh` varuje a staré nemaže. Osiřelý `.env.tmp.*` je pro `check-env.sh` chyba. Skript ho nemaže.

Před `deploy.sh` musí `sudo ./scripts/check-env.sh` skončit patičkou `Environment checks passed.` Varování, například prázdná vzdálená záloha, proces nezastaví. Je potřeba ho vědomě přijmout.

## D. Instalace

`upgrade.sh` v repozitáři není. Následující pořadí je první instalace, ne aktualizace.

### `init.sh`

Spouští se jako první, na stroji s mountem `/docker-data`. Založí adresáře, zúží příliš otevřená práva, odmítne symlink a adresář jiného vlastníka a zkopíruje soubory stacku bez tajemství: `.env.example`, Compose, `configs/`, `postgresql/` včetně `Dockerfile`, `pgbackrest.conf` a `docker-entrypoint-initdb.d` a `backup/` včetně `Dockerfile` a `sjv-backup.sh`. Cíle build contextu jsou `/docker-data/stacks/infrastructure-sjv/postgresql` a `/docker-data/stacks/infrastructure-sjv/backup`. Soubor, který už se shoduje, se nepřepíše. Existující `.env` nemění. Kontejnery ani data nemaže.

```bash
sudo ./scripts/init.sh
```

Úspěch je patička `Initialization completed. Next: ./scripts/update-env.sh`. Opakovaný běh je bezpečný. Bez argumentů. `--help` vypíše použití.

### `update-env.sh`

Až po `init.sh`, když kopie `.env.example` ve stacku sedí s Gitem. Vytvoří nebo doplní `.env` s právy 600. Tajemství, která už existují, nechá. Chybějící nebo `set_*` u generovaných klíčů doplní a nevypíše. Ruční změnu `framework` hodnoty vrátí, předtím udělá zálohu. Neznámé proměnné nesmaže. Přesune je na konec a `check-env.sh` je pak hlásí jako chybu, dokud je správce neodebere.

```bash
sudo ./scripts/update-env.sh
```

Patička říká, že zbývá nahradit dokumentační hostname a zbylé `set_*` a spustit `check-env.sh`. Souběh drží zámek `.env.lock` s čekáním 10 s. Opakovaný běh je bezpečný. Když se soubor nezmění, záloha nevznikne.

### Úprava `.env`

Mezi `update-env.sh` a `check-env.sh` se v runtime souboru nahradí `example.com` a `mqtt.example.com` a doplní hodnoty, které skript nevygeneroval. `TRAEFIK_ACME_EMAIL` musí být skutečný kontakt, dokud `TRAEFIK_TLS_MODE` není `local`. `ADMIN_IP_ALLOWLIST` jsou privátní CIDR oddělené mezerou.

### `check-env.sh`

Nic nezapisuje. Ověří, že `.env` není v Gitu, a že runtime `.env` projde validací. Adresáře `state`, `secrets`, záloh, `traefik/acme`, `traefik/users`, `traefik/crowdsec` a dat CrowdSec mají mít mód 700 a vlastníka aktuálního uid. `traefik/logs` a `traefik/plugins` mají mít mód 755. Chybějící adresář je varování s odkazem na `init.sh`, ne tvrdá chyba.

```bash
sudo ./scripts/check-env.sh
```

Úspěch je `Environment checks passed.` a návratový kód 0. Opakovat ho lze kdykoli. Je to kontrola, ne instalace.

### `create-dashboard-user.sh`

Až po `init.sh`, protože potřebuje adresář uživatelů Traefiku. Bez tohoto souboru se dashboard nepublikuje. Heslo se zadává do `htpasswd` a skript ho nečte ani netiskne. Uživatelské jméno je volitelné, výchozí `admin`, povolené znaky jsou písmena, číslice, tečka, podtržítko a pomlčka, nejvýš 64 znaků.

```bash
sudo ./scripts/create-dashboard-user.sh
```

Když soubor hesel už existuje, aktualizuje jen zadaný účet a ostatní nechá. Nový soubor založí s právy 600. Symlink odmítne. Opakování je bezpečné. Úspěch je hláška, že účet byl zapsán nebo aktualizován. Samostatnou patičku s dalším krokem skript nevypisuje.

### `deploy.sh`

Až po úspěšném `check-env.sh` a po souboru hesel dashboardu, pokud se má dashboard publikovat. Načte runtime `.env`, připraví layout, vykreslí Traefik a založí čtyři sítě projektu, pokud nekolidují s cizí sítí. Těsně před startem kontejnerů založí prázdný `/docker-data/infrastructure-sjv/traefik/logs/access.log`, když soubor chybí. Nový soubor má práva 640 a vlastníka uživatele, který skript spouští. V provozu je to root. Existující běžný soubor se nenačte znovu a jeho obsah, inode ani práva se nemění. Symlink se odmítne a cíl se neotevře. Teprve potom skript spustí služby `traefik` a `crowdsec` příkazem `docker compose up -d` bez `--build`. Oba používají připravené obrazy. CrowdSec má akviziční soubor `/logs/access.log` k dispozici už při prvním startu, takže kvůli chybějícímu logu není potřeba kontejner `sjv-crowdsec` restartovat. `sjv-backup`, PostgreSQL, MQTT ani aplikaci nespouští. Jejich Compose definice zůstávají. Cizí kontejnery a sítě nemaže.

```bash
sudo ./scripts/deploy.sh
```

`--render-only` jen zapíše runtime soubory. Docker nezavolá a `access.log` nezaloží. V testovacím režimu bez této volby skript skončí chybou dřív, než sáhne na log.

Úspěch je patička `Deploy completed. Next: ./scripts/init-backup.sh`. Opakovaný běh je bezpečný. Když se nic nezměnilo, soubory se nepřepisují. Trvalý klient `sjv-backup` v této fázi nevznikne.

### `init-backup.sh`

Až po `deploy.sh`. Z `deploy.sh` ani z `post-deploy.sh` se nevolá. Zakládá současný vzdálený repozitář a nespouští trvalou službu `sjv-backup`.

```bash
sudo ./scripts/init-backup.sh
```

Když je `RESTIC_REPOSITORY` prázdný, Restic ani Docker se nespustí. Úspěch je hláška `Remote backup is not configured. The repository was not initialized.` a patička `Remote backup initialization skipped. Next: ./scripts/post-deploy.sh`.

Vyplněný repozitář vyžaduje:

- `RESTIC_REST_PASSWORD` v runtime `.env`. Do URL nepatří. Neplatná URL nebo krátké heslo skončí validací `.env` a Docker se nespustí.
- `/docker-data/infrastructure-sjv/secrets/restic-key-password` jako běžný neprázdný soubor, ne symlink, s právy 600 nebo 400.
- `/docker-data/infrastructure-sjv/secrets/restic-rest-server.crt` jako běžný neprázdný soubor, ne symlink. Práva 644 jsou přípustná.

Chybějící část, prázdný klíč, symlink nebo jiná práva klíče jsou chyba `Remote backup configuration is incomplete. The repository was not initialized.` Docker se nespustí. Obsah hesel se netiskne.

Úplná konfigurace spustí jednorázový kontejner s příkazem `init-repository`. Obraz se sestaví ze synchronizovaného `/docker-data/stacks/infrastructure-sjv/backup`, kontejner se po skončení smaže a služby `traefik` a `crowdsec` se nerestartují. Plánovač `supervise` se nespustí, takže `sjv-backup` po tomto kroku neběží.

Nejdřív se přečte konfigurace repozitáře. Když už existuje, `init` se nezavolá. Když repozitář prokazatelně neexistuje, založí se a konfigurace se přečte znovu. Oba úspěchy končí patičkou `Remote backup repository is ready. Next: ./scripts/post-deploy.sh`.

HTTP 401, chyba TLS, chyba sítě, chybné heslo klíče a každá jiná diagnostika `init` nespustí. Skript skončí nenulovým kódem a patičku o připraveném repozitáři nevypíše. Obsazený `repo.lock` také skončí chybou bez `init`. V testovacím režimu vyplněný repozitář skončí před Dockerem. Opakování existujícího repozitáře je bezpečné. Obnova po kompromitaci je jiná operace: nový repozitář a nové klíče, jak je popisuje [docs/backup-strategy.md](docs/backup-strategy.md).

### `post-deploy.sh`

Až když běží CrowdSec. Zaregistruje bouncer `sjv-traefik`, klíč uloží do `/docker-data/infrastructure-sjv/traefik/crowdsec/BOUNCER_KEY_sjv-traefik` a nevypíše ho. Middleware vykreslí znovu a Traefik restartuje, když se klíč změnil. Maže jen bouncer tohoto jména.

```bash
sudo ./scripts/post-deploy.sh
```

Úspěch je `Post-deploy completed. The bouncer key was not printed.` V testovacím režimu skript selže, protože bouncer registrovat neumí. Opakování je součást návrhu: do prvního běhu middleware klíč nemá, další běh stejný klíč znovu použije.

### `reload.sh`

Není samostatná instalace. Předá argumenty `deploy.sh`, včetně `--render-only` a `--help`.

```bash
sudo ./scripts/reload.sh
```

### `rotate-traefik-logs.sh`

Není krok první instalace. Rotuje jen `access.log` příkazem copytruncate, když soubor dosáhne 20 MiB nebo je starší než den. Prázdný soubor nerotuje. `traefik.log` nechává Traefiku. Docker nevolá. `--force` přeskočí práh u neprázdného souboru.

```bash
sudo ./scripts/rotate-traefik-logs.sh
```

Opakování je bezpečné. Návrh timeru `ops/systemd/sjv-traefik-logrotate.service` a `.timer` v repozitáři je a do NixOS se neinstaluje.

## E. Databáze

Role vzniknou při prvním startu oficiálního entrypointu image, ze skriptů v `postgresql/docker-entrypoint-initdb.d/`. Hesla čte `\getenv` z proměnných `POSTGRES_SJV_*_PASSWORD`, které Compose plní z `PG_*_PASSWORD`. Do argumentu procesu se nepíšou. `sjv_bootstrap` zakládá image jako superuser. Ostatní role jsou `LOGIN` a nejsou superuser, nesmějí zakládat databáze ani role a nemají `INHERIT` ani `BYPASSRLS`.

| Role | K čemu dnes slouží |
| --- | --- |
| `sjv_bootstrap` | superuser image, vlastník procesu při inicializaci |
| `sjv_owner` | vlastník databáze `sjv` a schématu, Alembic a funkce `SECURITY DEFINER` |
| `sjv_collector` | zápis ingestu. Zařízení nezakládá, `secret_enc` nečte |
| `sjv_api` | do fronty dekódování jen `INSERT` |
| `sjv_worker` | čtení, aktualizace pokusu a mazání fronty dekódování |
| `sjv_maintenance` | založení měsíční partition a retence ingestu |
| `sjv_readonly` | čtení. U `endpoint_credentials` jen metadata řádku, ne `secret_enc` |
| `pgbackrest` | lokální záloha, bez hesla, `NOINHERIT` |

`CREATE` ve schématu `public` má jen `sjv_owner`. Podrobná tabulka práv je v [docs/database-design.md](docs/database-design.md#databázové-role). Text návrhu říká, že `sjv_bootstrap` používá jen `deploy.sh` a že `deploy.sh` před migrací vynutí čerstvou zálohu pgBackRest. Aktuální `deploy.sh` PostgreSQL nespouští, Alembic nespouští a pgBackRest nevolá.

Alembic je v `app/backend/alembic/`. URL není v souborech migrace. `app/backend/alembic/env.py` ji čte jen z `SJV_DATABASE_URL` a bez ní skončí. Izolovaný test ji předává takto, z adresáře `app/backend`:

```bash
SJV_DATABASE_URL="…" alembic -c alembic.ini upgrade head
SJV_DATABASE_URL="…" alembic -c alembic.ini check
```

Produkční obal, který by totéž spustil v `sjv-postgresql`, v repozitáři není. Po `upgrade head` má tabulka `alembic_version` jeden řádek `0003_retention`. To izolovaný test ověřuje dotazem `SELECT version_num FROM alembic_version`.

Řetěz revizí:

| Revize | Předchůdce | Co přidává |
| --- | --- | --- |
| `0001_ingest_schema` | žádný | ingest, referenční tabulky, role oprávnění, měsíční partitions |
| `0002_payload_items` | `0001_ingest_schema` | položky obálky `ingest_payload_items` |
| `0003_retention` | `0002_payload_items` | `retention_log` a retenční procedury |

Všechny tři revize mají `downgrade`, který vyvolá chybu a označí migraci jako forward-only. Izolovaný test očekává, že `alembic downgrade -1` selže a v hlášení bude `forward-only`. Návrat schématu je obnova ze zálohy, ne downgrade. Skript, který by před migrací zálohu vynutil, dnes není.

`alembic check` v izolovaném běhu porovná metadata s databází po `upgrade head`. Na VPS ho nemá co spustit, dokud nebude běžící PostgreSQL a ručně předané `SJV_DATABASE_URL`.

## F. Ověření instalace

Po `deploy.sh`, `init-backup.sh` a `post-deploy.sh` zůstávají z tohoto repozitáře spuštěné jen `sjv-traefik` a `sjv-crowdsec`. `init-backup.sh` může jednorázově založit současný vzdálený repozitář a kontejner po sobě nenechá. Trvalý `sjv-backup` a `sjv-postgresql` jsou v `compose.yml` a tento postup je nespouští.

Kontroly, které projekt sám popisuje:

1. `sudo ./scripts/check-env.sh` skončí kódem 0.
2. `stat -c '%a %U' /docker-data/stacks/infrastructure-sjv/.env` vrátí `600 root`. To je kontrola z [docs/checks.md](docs/checks.md#kontrola-na-serveru-po-instalaci). Cesta checkoutu v tom dokumentu je nepotvrzená konvence.
3. Soubor bouncer klíče existuje a `check-env.sh` hlásí, že je soukromý. Hodnotu nečte.
4. Po startu `sjv-crowdsec` v jeho logu není `No matching files for pattern /logs/access.log`. Až Traefik zapíše alespoň jeden řádek, uvnitř kontejneru `cscli metrics show acquisition parsers` ukáže zdroj `file:/logs/access.log` s nenulovým počtem načtených a parsovaných řádků. Příkaz z hostitele je `docker exec sjv-crowdsec cscli metrics show acquisition parsers`. Prázdný soubor při startu ještě žádný řádek nemá, proto nula do první skutečné žádosti není chyba akvizice.

Kontrola databáze, oprávnění rolí a schématu na VPS hotový skript nemá. V izolovaném testu ji dělá `app/backend/tests/isolated-schema-test.sh` včetně `schema_tests.py`, `ingest_accept_tests.py` a `retention_tests.py`. Na VPS se nespouští.

```bash
./scripts/test.sh
```

`./scripts/test.sh --static` je totéž. Výchozí argument je `--static`. Běh je offline. Na Debianu 13 ho doplňují balíčky `python3` a `shellcheck` příkazem `apt-get install python3 shellcheck`. Samostatný `./scripts/shellcheck.sh` bez balíčku skončí kódem 3 a doporučí `apt-get install shellcheck`.

Dostupnost HTTPS pro `SJV_DOMAIN` závisí na HAProxy a DNS mimo tento repozitář. Příkaz, který by je z checkoutu ověřil, tu není. Dashboard se publikuje jen s existujícím souborem hesel a s `ADMIN_IP_ALLOWLIST`.

Záloha a obnova produkčním skriptem ověřit nejdou. `backup.sh` a `restore.sh` nejsou. Ověřený je jen izolovaný postup v [docs/operations.md](docs/operations.md#záloha-a-obnova-postgresql).

## G. Běžný provoz a aktualizace

Aktualizace konfigurace a znovuspuštění Traefiku a CrowdSec:

1. V checkoutu převzít nový Git. Příkaz `git pull` a vzdálený repozitář tu nejsou určené.
2. `sudo ./scripts/init.sh`, aby se do stacku dostala nová `.env.example`, soubory Compose a build context `postgresql/` a `backup/`.
3. `sudo ./scripts/update-env.sh`. Existující uživatelské hodnoty a vygenerovaná hesla nechá. `framework` hodnoty srovná se šablonou.
4. `sudo ./scripts/check-env.sh`.
5. `sudo ./scripts/deploy.sh` nebo `sudo ./scripts/reload.sh`.
6. `sudo ./scripts/init-backup.sh`.
7. `sudo ./scripts/post-deploy.sh`, když se měnil bouncer nebo Traefik middleware.

To není aktualizace schématu. Alembic se při tom nespustí. Až bude PostgreSQL běžet a má se posunout schéma, jediný popsaný příkaz je ruční `alembic -c alembic.ini upgrade head` s `SJV_DATABASE_URL`. Kdo ho spouští, z jaké sítě a po jaké záloze, repozitář neurčuje. `upgrade.sh` chybí. Návrh v `docs/database-design.md`, že `deploy.sh` před migrací vynutí zálohu pgBackRest, v `scripts/deploy.sh` není.

Když `update-env.sh` odmítne `.env`, soubor nepřepíše. Hláška obsahuje číslo řádku a ne hodnotu. Osiřelý `.env.tmp.*` se smaže jen tehdy, když pád nastane v běhu, který ten soubor sám založil. Cizí dočasný soubor zůstane a `check-env.sh` pak selže, dokud ho správce nezkontroluje a neodstraní.

Když `deploy.sh` selže uprostřed, sítě a cizí kontejnery nemaže. Opakovaný běh je určený k dorovnání. Postup návratu schématu při chybě migrace není, protože downgrade je odmítnutý a produkční obnova do původního datového adresáře není ověřená.

## H. Zálohování a obnova

Produkční `backup.sh` a `restore.sh` nejsou. Služba `sjv-backup` zůstává v `compose/30-backup.yml`. `deploy.sh` ji nespouští a její obraz nesestavuje. Současný vzdálený repozitář zakládá `sudo ./scripts/init-backup.sh` jednorázovým kontejnerem. Trvalá služba `sjv-backup` po tomto kroku neběží. Chyba připojení nebo autentizace repozitář nezaloží. Obnova po kompromitaci dál zakládá nový repozitář a nové klíče.

Příprava vzdálené zálohy je v [docs/operations.md](docs/operations.md#vzdálená-záloha). První `deploy.sh` klienta nespustí. `init-backup.sh` po sobě kontejner nenechá, takže `docker logs sjv-backup` platí až po samostatném spuštění trvalé služby. Heslo šifrovacího klíče je soubor `/docker-data/infrastructure-sjv/secrets/restic-key-password` s právy 600, ne proměnná. Certifikát je `restic-rest-server.crt` a smí mít práva 644.

Lokální pgBackRest má stanza `sjv`, archivaci přes `archive-push` a vypnuté `expire-auto`. Izolovaný test 20. 11. 2026 provedl `stanza-create`, `check` a plnou zálohu. Neběžel na `/docker-data` a nespustil `backup.sh`. Obnova do jiného prázdného adresáře, s repozitářem jen pro čtení a s `archive_mode=off`, je popsaná v [docs/operations.md](docs/operations.md#obnova-do-samostatného-clusteru). Přepnutí obnoveného clusteru zpět do provozního datového adresáře ověřené není. PITR, `pgbackrest verify` a obnova ze snapshotu Restic součástí toho testu nebyly.

`forget` a `prune` se na VPS nespouštějí. Denní běh a WAL se navzájem neblokují způsobem, který by druhý Restic pustil souběžně. Podrobnosti intervalů jsou v `docs/operations.md`.

## I. Retence a údržba

`sjv_retain_ingest_month(date)` je procedura s právy volajícího. Nemá `SECURITY DEFINER` ani `SET`. `EXECUTE` má `sjv_maintenance`. Vlastník `sjv_owner` ho má také, protože rutiny vlastní. `sjv_retention_month_ok` požaduje první den měsíce a měsíc starší než 24 měsíců podle UTC. Do `retention_log` role `sjv_maintenance` přímo nezapisuje. Řádky zapisují funkce `SECURITY DEFINER` vlastníka `sjv_owner`.

Procedura musí běžet mimo otevřený transakční blok. Její první příkaz je `COMMIT`. V otevřené transakci skončí `invalid transaction termination` ještě před `pg_advisory_lock(83422027)`. Zámek ani řádek protokolu při tom nevznikne.

Pak volá `sjv_retention_capture_gate`. Ta ověří měsíc, vezme session zámek a zjistí důvod odkladu. Když důvod je, `sjv_retention_log_deferred` zapíše krok `gate`, výsledek `deferred`, tento důvod a `row_count` 0. `sjv_retain_ingest_month` tuto změnu potvrdí, zámek pustí a skončí. Partitions se nemažou.

Když důvod odkladu není, pro každý krok zavolá `sjv_retention_apply_one` a hned potom `COMMIT`. Pořadí je `message_keys`, `dedup_candidates`, `receipts`, `rejections`, `observations`, `fragments`, `fragment_sets`, `payload_items`, `payload_references`, `payloads`, `telegram_dedup_keys`, `raw_telegrams`. Na konci pustí zámek. `device_events` v seznamu kroků není a `sjv_retention_detach` tuto tabulku neobsahuje.

`sjv_retention_apply_step` provede mazání nebo `DETACH` a `DROP` jen tehdy, když `sjv_retention_lock_held()` v této session vidí udělený advisory zámek s `classid` 0, `objid` 83422027 a `objsubid` 1. Bez něj krok skončí `retention lock is not held`, řádek protokolu nezapíše a data nesmaže.

Řádek `completed` vzniká ve stejné transakci jako změna kroku. Chybějící partition má výsledek `completed`, důvod `absent` a `row_count` 0. Povolené hodnoty `result` jsou `completed`, `deferred` a `failed`.

Když krok selže, `sjv_retention_apply_one` pustí zámek této session a vyvolá `retention step <krok> failed: <text>`. `sjv_retain_ingest_month` tuto chybu nezachytí, takže se aktuální transakce vrátí. Dříve potvrzené kroky zůstávají. U selhaného kroku řádek `completed` není. Řádek `failed` zapíše až pozdější volání `sjv_retention_record_failure`.

`sjv_retention_record_failure(date, text, text)` je také procedura volajícího. Zámek nebere a zámek jiné session nepouští. Zavolá `sjv_retention_log_failed` a pak `COMMIT`. Funkce přijme jeden z dvanácti kroků výše, první den měsíce staršího než 24 měsíců a důvod, který po `btrim` není prázdný. Krok `gate` odmítne. Zapíše `result` `failed` a `row_count` nechá prázdný.

`sjv_retention_release_lock()` je `SECURITY DEFINER` s `search_path` `public`. Dokud `sjv_retention_lock_held()` platí, volá `pg_advisory_unlock(83422027)`. Platí jen pro backend, který proceduru zavolal. Když zámek nedrží, `pg_advisory_unlock` se nezavolá. Použije se, když selže `COMMIT` až po získání zámku. Ten `COMMIT` je v `sjv_retain_ingest_month` mimo blok `EXCEPTION`, procedura ho nezachytí, zámek v session zůstane a neúspěšný `COMMIT` řádek protokolu neponechá. Konec session session zámek pustí.

`EXECUTE` pro `sjv_maintenance` mají `sjv_retain_ingest_month`, `sjv_retention_record_failure`, `sjv_retention_release_lock`, `sjv_retention_capture_gate`, `sjv_retention_apply_one` a `sjv_retention_log_failed`. Provozní volání jsou první tři. `capture_gate`, `apply_one` a `log_failed` mají `EXECUTE` proto, že procedury volajícího je musí zavolat. Běžný provozní vstup to není.

Bez grantu pro `sjv_maintenance` zůstávají `sjv_retention_month_ok`, `sjv_retention_defer_reason`, `sjv_retention_actual_payload_refs`, `sjv_retention_detach`, `sjv_retention_lock_held`, `sjv_retention_apply_step`, `sjv_retention_log_deferred` a `sjv_retention_log_protect`. `PUBLIC` na retenčních rutinách `EXECUTE` nemá. `sjv_collector`, `sjv_api`, `sjv_worker` a `sjv_readonly` ho také nemají.

`retention_log` je provozní protokol. Migrace `0003_retention` tabulku `audit_logs` nezakládá. Sloupce protokolu jsou `id`, `recorded_at`, `partition_month`, `step`, `result`, `reason` a `row_count`. `UPDATE` a `DELETE` zastaví trigger `trg_retention_log_protect` hláškou `retention_log is append-only`. Kontrola po běhu je čtení řádků daného `partition_month` v pořadí `id`.

Denní `maintenance.sh` a systemd timer nejsou. Automatické pravidelné spouštění retence je v plánu fáze 4 a hotové není. Tahle příručka ho nezavádí.

Pořadí mazání, odklady a cizí klíče jsou v [docs/database-design.md](docs/database-design.md) a v [docs/checks.md](docs/checks.md).

## J. Řešení problémů

| Projev | Kam se dívat |
| --- | --- |
| Skript chce root | hláška `This script must be run as root inside the Incus container.` |
| `/docker-data` není mount | skript skončí a nic nezaloží. Disk Incusu se z tohoto repozitáře nevytváří |
| `update-env.sh` chce nejdřív `init.sh` | chybí stack, chybí kopie `.env.example`, nebo se kopie liší od Gitu |
| `check-env.sh` hlásí `.env` v checkoutu | runtime soubor je na špatném místě nebo je to symlink |
| `check-env.sh` hlásí `.env.tmp.*` | přerušený zápis. Soubor prohlédnout a odstranit ručně. Skript ho nemaže |
| Validace `.env` | číslo řádku, bez hodnoty. Nebezpečný znak, `set_*`, dokumentační hostname nebo neznámá proměnná |
| `deploy.sh` v testu | bez `--render-only` je to záměrná chyba |
| `init-backup.sh` v testu | vyplněný repozitář skončí před Dockerem. Prázdný repozitář skončí úspěchem |
| `init-backup.sh` hlásí neúplnou konfiguraci | chybí REST heslo, soubor klíče, jeho práva 600 nebo 400, nebo certifikát. Symlink, prázdný klíč a prázdný certifikát se odmítnou. Docker se nespustí |
| `init-backup.sh` skončí při ověření repozitáře | HTTP 401, TLS, síť, heslo klíče nebo jiná diagnostika. `init` se nespustí a patička o připraveném repozitáři se nevypíše |
| po `init-backup.sh` neběží `sjv-backup` | jednorázový kontejner se maže. Trvalý plánovač tento krok nespouští |
| `post-deploy.sh` v testu | bouncer se v testovacím režimu neregistruje |
| CrowdSec bouncer | do prvního `post-deploy.sh` middleware klíč nemá. Logy kontejneru `sjv-crowdsec` a soukromý soubor klíče |
| `sjv-backup` po prvním `deploy.sh` neběží | tato fáze ho nespouští. Definice zůstává v `compose/30-backup.yml` |
| PostgreSQL na VPS neběží | `deploy.sh` ho nespouští. Chybějící kontejner není chyba aktuálního instalačního pořadí |
| Migrace | downgrade je odmítnutý. Produkční příkaz nasazení migrace není. Izolovaný test je `app/backend/tests/isolated-schema-test.sh` |
| Retence drží zámek | `COMMIT` po zámku procedura nezachytí a řádek protokolu neponechá. Na téže session `sjv_retention_release_lock` |
| Retence skončí uprostřed měsíce | hláška `retention step <krok> failed`. Řádek `failed` vznikne až voláním `sjv_retention_record_failure` |
| Přístup role | `permission denied` u `sjv_collector`, `sjv_api`, `sjv_worker` a `sjv_readonly` a u přímého volání interních funkcí včetně `sjv_retention_month_ok`. Přímý `INSERT` do `retention_log` rolí `sjv_maintenance` také |

Logy stdout kontejnerů jsou ovladač `json-file`. Soubory Traefiku jsou `/docker-data/infrastructure-sjv/traefik/logs/access.log` a `traefik.log`. Skripty na stdout píšou průběh a patičku. Tajné hodnoty tisknou jako `<hidden>` nebo je netisknou vůbec.

## Přehled skriptů

| Skript | Účel | Kdy spustit | Opakovatelnost |
| --- | --- | --- | --- |
| `scripts/init.sh` | adresáře a kopie stacku bez tajemství | první instalace a po změně souborů v Gitu | ano, existující `.env` nemění |
| `scripts/update-env.sh` | vytvoří nebo doplní runtime `.env` | po `init.sh` a po změně `.env.example` | ano, tajemství a uživatelské hodnoty nechá |
| `scripts/check-env.sh` | kontrola `.env` a práv, nic nezapisuje | před `deploy.sh` a kdykoli potom | ano |
| `scripts/create-dashboard-user.sh` | heslo dashboardu mimo Git | před publikací dashboardu | ano, ostatní účty nechá |
| `scripts/deploy.sh` | sítě, Traefik a CrowdSec | první instalace těchto dvou služeb a jejich aktualizace | ano, cizí sítě a kontejnery nemaže |
| `scripts/deploy.sh --render-only` | jen vykreslení, bez Dockeru | kontrola vykreslení, testovací režim | ano |
| `scripts/init-backup.sh` | prvotní založení současného vzdáleného repozitáře | po `deploy.sh`, před `post-deploy.sh` | ano, existující repozitář znovu nezakládá a plánovač nespouští |
| `scripts/post-deploy.sh` | registrace bouncer klíče | po `init-backup.sh`, když běží CrowdSec | ano, klíč netiskne |
| `scripts/reload.sh` | totéž co `deploy.sh` | místo dalšího `deploy.sh` | ano |
| `scripts/rotate-traefik-logs.sh` | copytruncate `access.log` | ručně, dokud timer není nasazený | ano, prázdný soubor nerotuje |
| `scripts/test.sh` | offline testy | vývoj, před změnou, bez VPS | ano, hostitele nemění. Debian 13: `python3` a `shellcheck` |
| `scripts/shellcheck.sh` | ShellCheck skriptů | spolu s `test.sh`, nebo samostatně | ano, kód 3 doporučí `apt-get install shellcheck` |

`upgrade.sh`, `backup.sh`, `restore.sh` a `maintenance.sh` v této tabulce nejsou, protože v `scripts/` nejsou.
