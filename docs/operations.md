# Provoz: instalace a konfigurace

Stav: etapa B1b. Popisuje přípravu adresářů, runtime `.env`, vykreslení Traefiku, postup pro CrowdSec, rotaci souborových logů Traefiku, přípravu vzdálené zálohy, službu PostgreSQL 19.0 a postup obnovy ověřený izolovaným testem. MQTT, aplikace, `pg_dump`, `backup.sh` a `restore.sh` zatím nejsou. `deploy.sh` PostgreSQL nespouští. Návrh systemd timeru pro logy je v repozitáři a není nainstalovaný.

## Předpoklady

- Incus kontejner podle E1 z [external-changes.md](external-changes.md) s připojeným `/docker-data` (samostatný mountpoint, `require_mountpoint` jinak skript zastaví).
- Git checkout mimo `/docker-data`, podle konvence `/incus-dir/git/Infrastructure-sjv` (cesta ještě k potvrzení, viz [architecture.md](architecture.md)).
- Bash 5, coreutils, `findmnt`, `flock`, `awk`. Skripty kontrolují dostupnost příkazů samy.
- Instalační skripty běží jako root. `test.sh` root nepotřebuje.

## Adresáře

| Cesta | Práva | Obsah |
| --- | --- | --- |
| `/docker-data/stacks/infrastructure-sjv` | 750 | runtime `.env`, kopie `.env.example`, Compose, `configs/` a build context `postgresql/` |
| `/docker-data/infrastructure-sjv` | 755 | data služeb |
| `/docker-data/infrastructure-sjv/state` | 700 | stav skriptů |
| `/docker-data/infrastructure-sjv/secrets` | 700 | soubory s tajemstvími pro služby (od pozdějších etap) |
| `/docker-data/infrastructure-sjv/traefik/acme` | 700 | `acme.json`, práva 600 |
| `/docker-data/infrastructure-sjv/traefik/logs` | 755 | `access.log` pro CrowdSec a `traefik.log` |
| `/docker-data/infrastructure-sjv/traefik/plugins` | 755 | cache pluginu, zapisovatelná i při read-only kořeni kontejneru |
| `/docker-data/infrastructure-sjv/traefik/users` | 700 | `dashboard.htpasswd`, práva 600 |
| `/docker-data/infrastructure-sjv/traefik/crowdsec` | 700 | `BOUNCER_KEY_sjv-traefik`, práva 600, mimo Git i `.env` |
| `/docker-data/infrastructure-sjv/crowdsec/data` | 700 | data CrowdSec |
| `/docker-data/infrastructure-sjv/postgresql` | 2770, vlastník root, skupina 999 při instalaci rootem | mount `/var/lib/postgresql`. Data jsou v `19/docker` podle oficiálního image |
| `/docker-data/backups/infrastructure-sjv` | 700 | lokální zálohy: `pgbackrest/`, `dumps/`, `files/` |
| `/docker-data/backups/infrastructure-sjv/pgbackrest` | 2770, vlastník root, skupina 999 při instalaci rootem | repozitář pgBackRest. Rodičovský adresář záloh zůstává 700 |
| `/docker-data/infrastructure-sjv/backup-locks` | 700 | zámky `sjv-backup` a budoucí lokální zálohy |
| `/docker-data/infrastructure-sjv/secrets/restic-key-password` | 600 | heslo klíče restic, až ho správce vytvoří |
| `/docker-data/infrastructure-sjv/secrets/restic-rest-server.crt` | 644 | TLS certifikát domácího `rest-server`, až ho správce uloží |

`init.sh`, `update-env.sh` i `check-env.sh` nejdřív ověří, že `/docker-data` je mountpoint. Když není, skončí chybou a nezaloží adresář ani `.env`. `init.sh` adresáře vytvoří, příliš otevřená práva zúží a odmítne symlinky nebo adresáře jiného vlastníka. Adresář, ve kterém leží `.env`, `update-env.sh` odmítne, když je zapisovatelný pro skupinu nebo ostatní, a práva mu nemění. Datové adresáře PostgreSQL a pgBackRest mají záměrně mód 2770. Nic nemaže.

## Postup první instalace

1. `sudo ./scripts/init.sh` vytvoří adresáře a zkopíruje soubory stacku bez tajemství: `.env.example`, Compose, `configs/`, `postgresql/` a `backup/`. `.env` nevytváří. Shodný soubor při dalším běhu nepřepíše. Build context PostgreSQL je `/docker-data/stacks/infrastructure-sjv/postgresql`. Compose v `compose/40-postgresql.yml` má `context: ../postgresql`, takže po synchronizaci míří sem. Build context zálohy je `/docker-data/stacks/infrastructure-sjv/backup` a `compose/30-backup.yml` má `context: ../backup`. Datový adresář `/docker-data/infrastructure-sjv/postgresql` zůstává zvlášť a skript do něj tyto soubory nekopíruje.
2. `sudo ./scripts/update-env.sh` vytvoří `.env` (práva 600), vygeneruje hesla a vypíše jména proměnných, které ještě obsahují `set_*` nebo dokumentační hostname.
3. V `/docker-data/stacks/infrastructure-sjv/.env` nahraď `example.com` a `mqtt.example.com` skutečnými jmény a doplň zbylé `set_*`. Hodnoty piš bez uvozovek. Existující domény další běh `update-env.sh` nepřepíše.
4. `sudo ./scripts/check-env.sh` musí skončit bez chyb. Varování (například chybějící vzdálená záloha) je třeba vědomě přijmout.
5. `sudo ./scripts/create-dashboard-user.sh` uloží heslo dashboardu. Bez tohoto kroku se dashboard nepublikuje.
6. `sudo ./scripts/deploy.sh` vykreslí Traefik, založí čtyři sítě projektu, před startem kontejnerů založí prázdný `access.log`, když chybí, a spustí `sjv-traefik` a `sjv-crowdsec`. Příkaz nepoužívá `--build`. Existující log se nezkrátí. `--render-only` tento soubor nezakládá a Docker nezavolá. `sjv-backup` a `sjv-postgresql` v Compose zůstávají a tento krok je nespouští.
7. `sudo ./scripts/init-backup.sh` založí současný vzdálený repozitář, když je v `.env` vyplněný a ještě neexistuje. Prázdný `RESTIC_REPOSITORY` skončí úspěchem a Docker nespustí. Neúplné heslo, klíč nebo certifikát jsou chyba a Docker se nespustí. Chyba připojení, TLS, HTTP 401 nebo hesla klíče repozitář nezaloží a skript skončí chybou. Jednorázový kontejner se smaže. Plánovač se nespustí.
8. `sudo ./scripts/post-deploy.sh` zaregistruje bouncer klíč u CrowdSec, znovu vykreslí middleware a v případě potřeby restartuje Traefik. Klíč se nevypisuje.

Opakované spuštění je bezpečné. Pokud se nic nezměnilo, soubory se nepřepisují a nevzniká záloha. `reload.sh` volá stejný `deploy.sh`. V testovacím režimu `deploy.sh` bez `--render-only` skončí chybou a Docker nezavolá.

## Hodnoty k doplnění

| Proměnná | Kdy | Poznámka |
| --- | --- | --- |
| `SJV_DOMAIN` | před nasazením | uživatelská hodnota, platné DNS jméno. V šabloně je `example.com`. `check-env.sh` ho odmítne |
| `MQTT_HOSTNAME` | před nasazením | uživatelská hodnota, platné DNS jméno. V šabloně je `mqtt.example.com`. Stejné jméno jako `SJV_DOMAIN`, nebo jiné jméno pro samostatný certifikát |
| `DOCKER_*_SUBNET`, `DOCKER_*_GATEWAY` | v šabloně, kategorie `user` | `172.20.0.0/24`, `172.21.0.0/24`, `172.22.0.0/24`, `172.23.0.0/24`, brány `.1`. Bez překryvu navzájem ani s `10.10.10.0/24`, `10.100.101.0/24`, `10.110.110.0/24`, `10.120.120.0/24` a `172.17.0.0/16`. Existující hodnotu sync ponechá |
| `ADMIN_IP_ALLOWLIST` | před nasazením | privátní CIDR oddělené mezerou, nikdy `0.0.0.0/0` |
| `TRAEFIK_ACME_EMAIL` | před `TRAEFIK_TLS_MODE=letsencrypt` | v režimu `local` může zůstat placeholder |
| `TRAEFIK_IMAGE`, `CROWDSEC_IMAGE` | v šabloně | tag a index digest, kategorie `framework` |
| `POSTGRES_IMAGE` | v šabloně | `postgres:19.0` a index digest, kategorie `framework`. Tag `19` ani `latest` validace nepřijme |
| `PGBACKREST_VERSION` | v šabloně | přesně `2.60.1`, kategorie `framework`. Samostatný image pgBackRest nevzniká |
| `CROWDSEC_BOUNCER_PLUGIN` | v šabloně | verze pluginu `v1.8.1`, ne API klíč |
| `CROWDSEC_BOUNCER_PLUGIN_HASH` | v šabloně | sha256 zipu z `plugins.traefik.io`, ne API klíč |
| `PROXY_PROTOCOL_TRUSTED_IPS` | před `PROXY_PROTOCOL_MODE=haproxy` | `10.10.10.1/32` je očekávaná zdrojová adresa HAProxy. Před spolehnutím se na ni se potvrdí skutečným provozem z kontejneru |
| `RESTIC_REPOSITORY`, `RESTIC_REST_PASSWORD` | před ostrými daty | závisí na E5, E6; prázdné = varování |
| `SMTP_*`, `MAIL_FROM` | fáze 9 | závisí na E7; prázdný `SMTP_HOST` = notifikace zůstávají ve frontě |

## Politika proměnných (`ENV_POLICY`)

Definice je v `scripts/lib/env/policy.sh`. Každá proměnná v `.env.example` musí mít politiku a naopak.

| Politika | Chování `update-env.sh` |
| --- | --- |
| `framework` | hodnota vždy podle `.env.example`; ruční změnu vrátí (po záloze) |
| `user` | existující hodnotu ponechá; chybějící doplní z `.env.example` |
| `generated` | existující tajemství ponechá; chybějící nebo `set_*` vygeneruje (48 znaků, URL-safe) a nevypíše |

Proměnné, které v `.env` jsou, ale politika je nezná, se nemažou. Přesunou se na konec souboru pod komentář a `check-env.sh` je hlásí jako chybu, dokud je správce neodstraní.

## Bezpečnost `.env`

- `.env` leží jen v `/docker-data/stacks/infrastructure-sjv/`, nikdy v Git checkoutu (`check-env.sh` to kontroluje).
- Práva 600, vlastník root. Hodnoty bez uvozovek; znaky `$`, `` ` ``, `"`, `'`, `\`, `#`, CR a mezery na okrajích jsou odmítnuté. Soubor se nikdy nespouští přes `source` ani `eval`.
- Před každým přepsáním vznikne záloha `.env.bak-<UTC čas>`. Nejdřív se zapíše do dočasného souboru s právy 600 a teprve potom se přejmenuje, takže pod konečným názvem není ani krátce čitelná pro skupinu. Obsah se porovná se zdrojovým `.env`. Nový `.env` se stejně zapisuje do `.env.tmp.*` a přejmenuje. Když zápis spadne nebo dostane signál, smaže se jen ten dočasný soubor, který běh sám založil.
- Osiřelý `.env.tmp.*` je pro `check-env.sh` chyba. Skript ho nemaže.
- Zálohy se nemažou automaticky. Při více než 20 zálohách skript varuje, staré zálohy odstraňuje správce ručně.
- Nečitelný `.env` (duplicitní klíč, řádek bez `=`, nebezpečná hodnota) ani symlink se nepřepíše. Skript skončí chybou s číslem řádku, bez hodnoty.
- Souběžné spuštění `update-env.sh` brání zámek `.env.lock` (čekání 10 s).
- Výstupy skriptů obsahují jen jména proměnných. Citlivé hodnoty se zobrazují jako `<hidden>`.

## Testovací režim

`SJV_TEST_BASE_DIR` přesměruje `/docker-data` jen do adresáře `.test-tmp/<běh>/base` uvnitř checkoutu. Porovnání je textové, ne regulární výraz, a symlink v kterékoli složce cesty je odmítnutý. V testovacím režimu se přeskočí kontrola rootu a mountpointu. Používá ho jen `test.sh`, ruční použití není potřeba.

## Sítě a bouncer

`deploy.sh` před vytvořením sítě zkontroluje, že nekoliduje s už existující sítí Dockeru. Síť, kterou projekt nezaložil, se nepřepisuje. `sjv-internal` je interní. Ostatní tři sítě interní nejsou, protože Traefik potřebuje ACME a stažení pluginu, CrowdSec hub a později publikaci portu 8883.

Bouncer klíč není v `.env` ani v Gitu. Vznikne až v běžícím CrowdSec a uloží se do `/docker-data/infrastructure-sjv/traefik/crowdsec/BOUNCER_KEY_sjv-traefik`. Do prvního `post-deploy.sh` Traefik middleware bounceru nemá. `post-deploy.sh` maže jen bouncer jména `sjv-traefik`.

## Logy Traefiku

Limit `json-file` v Compose omezuje jen stdout kontejneru. Soubory `traefik.log` a `access.log` se jím nerotují.

- `traefik.log` rotuje proces Traefiku: 20 MB, 14 záloh, 14 dní, gzip. Signál USR1 tento soubor znovu neotevírá, proto ho skript nepřesouvá.
- `deploy.sh` před `docker compose up` založí prázdný `access.log` s právy 640, když soubor ještě není. CrowdSec tak při prvním startu najde `/logs/access.log` a kvůli chybějícímu souboru se nerestartuje. Existující obsah se nepřepisuje. Symlink se odmítne. `--render-only` soubor nezakládá.
- `access.log` Traefik sám nerotuje. `sudo ./scripts/rotate-traefik-logs.sh` udělá copytruncate: zkopíruje obsah, po úspěšném gzipu zkrátí původní soubor na nulu a ponechá inode, vlastníka i práva. CrowdSec dál čte `/logs/access.log`. Řádky zapsané mezi kopií a zkrácením mohou chybět. Při přerušení před zkrácením zůstane původní soubor a smaže se jen nedokončený dočasný soubor. Archivů se drží 14, práva 640. Prázdný soubor se nerotuje. `--force` přeskočí práh 20 MB a 24 hodin, prázdný soubor stejně nechá být.
- Návrh hodinového timeru je `ops/systemd/sjv-traefik-logrotate.service` a `.timer`. Cesta checkoutu v jednotce je pořád nepotvrzená konvence. Jednotky se do NixOS neinstalují. Než timer běží, strop `access.log` nastane až po ručním spuštění skriptu.

## Vzdálená záloha

Služba `sjv-backup` je v `compose/30-backup.yml`. První `deploy.sh` ji nespouští a její obraz nesestavuje. Současný vzdálený repozitář zakládá až `sudo ./scripts/init-backup.sh`. Trvalý plánovač a jeho nasazení na VPS zůstávají samostatný krok. Obnova po kompromitaci zakládá nový repozitář a nové klíče.

1. `sudo ./scripts/init.sh` založí `postgresql/`, `pgbackrest/`, `pgbackrest/archive/`, `dumps/`, `files/` a `backup-locks/`. Adresáře, do kterých zapisuje uživatel image PostgreSQL, mají mód 2770 a při běhu `init.sh` jako root skupinu 999.
2. Do runtime `.env` zapiš obě proměnné. Heslo v URL být nesmí.

```bash
RESTIC_REPOSITORY=rest:https://infrastructure-sjv@10.100.101.12:8000/infrastructure-sjv/
RESTIC_REST_PASSWORD=<heslo uživatele rest-server>
```

3. Heslo šifrovacího klíče ulož mimo `.env`. Příkaz hodnotu nevypisuje; soubor otevři v editoru.

```bash
install -m 600 /dev/null /docker-data/infrastructure-sjv/secrets/restic-key-password
```

4. Certifikát domácího serveru ulož jen pro čtení služby. Soubor smí mít práva 644, protože nejde o heslo.

```bash
install -m 644 /cesta/k/rest-server.crt /docker-data/infrastructure-sjv/secrets/restic-rest-server.crt
```

5. `sudo ./scripts/check-env.sh` a teprve potom schválené `sudo ./scripts/deploy.sh`. To spustí Traefik a CrowdSec. Klienta `sjv-backup` nespustí.
6. `sudo ./scripts/init-backup.sh` jednorázově ověří současný repozitář a založí ho jen tehdy, když ještě neexistuje. Heslo REST, soubor klíče a certifikát musí být na místě. Chyba připojení, TLS, HTTP 401 nebo hesla klíče `init` nespustí a skript skončí chybou. Příkaz plánovač nespustí a kontejner po sobě nenechá.
7. Stav plánovače tato fáze neověřuje, protože trvalý kontejner neběží. Až bude služba spuštěná samostatným postupem, stav je `docker logs sjv-backup` a soubory `state/sjv-backup-daily.json` a `state/sjv-backup-wal.json`. Healthcheck je jen živost plánovače.
8. Při `failed` se záloha za úspěšnou nepovažuje. Plánovač pokračuje. Další `wal` je až po 300 s. Přeskočení kvůli obsazenému `restic-job.lock` nebo `repo.lock` má vlastní stav a další pokus po 60 s (`SJV_BACKUP_WAL_RETRY_SECONDS`). Čas posledního pokusu je `state/sjv-backup-wal.epoch`, čas dalšího pokusu `state/sjv-backup-wal.next`. Restart se řídí tím druhým a nespouští sérii pokusů. `wal` na zámky nečeká. Dlouhá denní úloha může interval `wal` překročit; druhý Restic se nespouští. `forget` a `prune` se na VPS nespouštějí.

## Záloha a obnova PostgreSQL

Běžná záloha a obnova do samostatného clusteru jsou různé operace. První start obnoveného clusteru je další krok po příkazu `pgbackrest restore`. Návrat do provozu se rozhoduje až po něm.

### Běžná záloha

Izolovaný test 20. 11. 2026 na PostgreSQL 19.0 a pgBackRest 2.60.1 provedl v pořadí `pgbackrest --stanza=sjv stanza-create`, `pgbackrest --stanza=sjv check` a `pgbackrest --stanza=sjv --type=full backup`. Repozitář byl zapisovatelný mount `/backup/pgbackrest`, `archive_mode=on` a `archive_command` posílal WAL přes `pgbackrest --stanza=sjv archive-push %p`. Plná záloha `20261120-212608F` měla 30,3 MB a 1 273 souborů. Archiv obsahoval WAL `000000010000000000000001` až `000000010000000000000005`. `expire-auto` zůstalo vypnuté a `pgbackrest expire` se nespustil.

Tento test neběžel na `/docker-data`, nespustil `backup.sh` a nevytvořil rozdílovou zálohu ani vzdálenou Restic kopii. Produkční adresáře pro stejné cesty v kontejneru jsou `/docker-data/infrastructure-sjv/postgresql` a `/docker-data/backups/infrastructure-sjv/pgbackrest`.

### Obnova do samostatného clusteru

Postup ověřený izolovaným testem. Obnova zapisovala do vlastního prázdného datového adresáře. Původní cluster a původní stanza zůstaly nedotčené.

1. Původní databázová služba se před návratem obnoveného clusteru do jejího datového adresáře zastaví. Izolovaný test ji nezastavoval, protože obnovoval do jiného adresáře a jiného kontejneru. Příkaz produkčního zastavení ani přepnutí adresářů ověřený není.
2. Připraví se samostatný prázdný datový adresář. V testu to bylo `/tmp/sjv-pg-itest/restore`, v kontejneru mount `/var/lib/postgresql`. Původní PGDATA se znovu nepoužije.
3. Původní repozitář pgBackRest musí být dostupný na `/backup/pgbackrest`. V testu to byl `/tmp/sjv-pg-itest/repo`.
4. Při `pgbackrest restore` i při prvním startu obnoveného clusteru se repozitář připojí jen pro čtení. Zkoušený postup jiný režim nevyžadoval.
5. Obnovu provede `pgbackrest --stanza=sjv --pg1-path=/var/lib/postgresql/19/docker restore`. V testu příkaz skončil `restore command end: completed successfully`, obnovil sadu `20261120-212608F` a zapsal `postgresql.auto.conf`.
6. Dokončení příkazu `pgbackrest restore` ještě neznamená, že obnovený PostgreSQL cluster nastartuje. První pokus spustil cluster bez repozitáře. Recovery potřebovalo WAL, `archive-get` nenašel `/backup/pgbackrest/archive/sjv/archive.info` a server skončil na `could not locate required checkpoint record`. Repozitář proto zůstane dostupný i během recovery a prvního startu.
7. Obnovený cluster nesmí zapisovat WAL do původní stanza. V testu tomu bránil mount repozitáře `ro`. Seznam souborů archivu se během obnovy a startu nezměnil.
8. Obnovený cluster se spouští s `postgres -c archive_mode=off`. V testu `current_setting('archive_mode')` vrátilo `off`.
9. Po startu se ověří, že recovery doběhlo, `pg_isready` databázi `sjv` přijímá, verze je PostgreSQL 19.0 a data sedí se zdrojem. V testu byly obnovené řádky `1|alpha`, `2|beta`, `3|gamma` a jejich `md5` `998376a4d170c152ed7f47c9168b3281` stejný jako ve zdroji.
10. Teprve po těchto kontrolách se rozhoduje, zda obnovený cluster přejde do provozu. Přepnutí na původní datový adresář, zapnutí `archive_mode=on` a další archivace do původní stanza ověřené nejsou.

PITR na zvolený čas, `pgbackrest verify`, obnova ze vzdáleného Restic snapshotu a skript `restore.sh` součástí tohoto testu nebyly.

## Mimo rozsah B1b

- Produkční spuštění `sjv-backup` a `sjv-postgresql` přes `deploy.sh`, `backup.sh`, `restore.sh`, `pg_dump`, Mosquitto, FastAPI, React, wmbusmeters a firmware. `deploy.sh` v první fázi startuje jen Traefik a CrowdSec.
- Trvalý plánovač `sjv-backup` a jeho nasazení na VPS. Prvotní `init-backup.sh` současného repozitáře je součást instalace. Obnova po kompromitaci dál zakládá nový repozitář a nové klíče.
- Instalace systemd jednotek. Návrh timeru pro access log v repozitáři není nasazení.
- Jakékoli změny NixOS, Incus, HAProxy, MikroTik, DNS nebo WireGuard (viz [external-changes.md](external-changes.md)).
