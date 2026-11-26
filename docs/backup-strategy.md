# Strategie zálohování

Zálohování je kritická část projektu. Projekt nelze označit za dokončený bez úspěšného testu obnovy a bez měřeného DR testu, který splní RTO.

## Cíle

| Parametr | Cíl | Jak se ověřuje |
| --- | --- | --- |
| RPO | cíl běžného provozu do 15 minut | Alarm, když je vzdálený snapshot `wal` starší než 15 minut. Během dlouhé denní úlohy Resticu to není záruka |
| RTO | ≤ 4 hodiny | Měřený DR test: úplná obnova na novém VPS bez přístupu k původnímu |
| Ochrana proti mazání | Kompromitovaný VPS nesmaže existující vzdálenou restic kopii | Append-only `rest-server`, ověřené testem ve fázi 3 |
| Obnova bez VPS | Ano | Obnovovací sada a domácí server stačí k obnově do nového prostředí |

## Architektura 3-2-1

```text
                 VPS: Incus kontejner sjv
  ┌──────────────────────────────────────────────────────────────────┐
  │ sjv-postgresql ── archive-push (async) ──► pgBackRest repo1        │ kopie 1: živá DB
  │                         /docker-data/backups/infrastructure-sjv/pgbackrest
  │ scripts/backup.sh ──► …/preparations/<preparation_id>              │ lokální příprava
  │   dumps/, files/, backup-manifest.json; current je atomický marker  │ (stejný disk!)
  └── sjv-backup: tag daily + sjv-daily-prep-<id>, tag wal (archive/) ┘
                              │ WireGuard wg1 → MikroTik doma (DNAT) → LAN
                              ▼
  domaPcServer: rest-server --append-only --private-repos (TLS, htpasswd)
       vzdálená restic kopie na jiném místě
       └── restic forget/prune spouští jen domácí server, mimo skripty VPS
```

- **Tři kopie v rozsahu projektu:** živá DB, lokální zálohy na disku VPS, vzdálená restic kopie předaná na `rest-server`.
- **Dvě média:** disk VPS a úložiště `rest-server` na domácím serveru. Lokální zálohy jsou na stejném disku jako DB. Chrání před logickou chybou a urychlí běžnou obnovu, ale ne před ztrátou VPS.
- **Jedna kopie mimo lokalitu:** vzdálená restic kopie na domácím serveru.
- **Neměnnost vzdálené kopie:** append-only `rest-server`. VPS do něj zapisuje a čte, mazat ani přepisovat ho nemůže.
- **Mimo rozsah projektu:** domácí server může držet další záložní kopii. Instalace Infrastructure-sjv na VPS ji nespravuje, skripty a služby projektu ji neobsluhují a není součástí implementace ani provozní odpovědnosti. Způsob jejího vytváření, ukládání, šifrování, snapshotování, retence a obnovy tato dokumentace neurčuje a negarantuje.

## Komponenty

### pgBackRest (PITR)

- Stanza `sjv`, repozitář `repo1` v `/docker-data/backups/infrastructure-sjv/pgbackrest`.
- `archive_mode = on`, `archive_command = 'pgbackrest --stanza=sjv archive-push %p'`, `archive-async = y`, `archive_timeout = 60s`.
- Plná záloha v neděli, rozdílová v ostatní dny (`backup.sh`).
- `repo1-retention-full = 2`, takže okno PITR je nejméně 7 a obvykle až 14 dní. Pro garantovaných 14 dní lze retenci zvýšit na 3. Rozhodne se podle velikosti DB.
- **Automatické expire je vypnuté** (`expire-auto = n`). `scripts/backup.sh` `pgbackrest expire` nevolá, takže WAL potřebné k obnově nemaže. Expire až po potvrzeném vzdáleném snapshotu zůstává samostatný krok ([Konzistence](#konzistence-vzdálené-kopie)).
- Lokální repozitář není šifrovaný pgBackRestem. Leží na stejném disku jako DB a mimo VPS ho šifruje restic. Obnova pak nepotřebuje další heslo.
- PostgreSQL běží s `--data-checksums` (převzato z reference).
- Verze je pgBackRest 2.60.1 nad PostgreSQL 19.0 (R33). `PG_CONTROL_VERSION` 1905 a `XLOG_PAGE_MAGIC` 0xD122 se shodují s vydáním 19.0. Poznámky k 2.60.1 jmenují 19rc2. Konstanta katalogu v nástroji je 202605131 a vydání 19.0 má 202610061. Běh čte číslo katalogu z `pg_control`. Izolovaný test 20. 11. 2026 dokončil `stanza-create`, `check`, plnou zálohu 30,3 MB (1 273 souborů), archivaci WAL a obnovu do samostatného clusteru s `archive_mode=off` a repozitářem jen pro čtení. `scripts/backup.sh` umí stejné kroky spustit v kontejneru a v offline testech je zastupují jen náhradní příkazy. Produkční běh, `pgbackrest expire`, PITR na zvolený čas, `restore.sh` a vzdálená obnova ověřené nejsou. Postup je v [operations.md](operations.md#záloha-a-obnova-postgresql).

### Denní logický dump

`pg_dump -Fc` do `…/preparations/<preparation_id>/dumps/sjv-<UTC>.dump`:

- `scripts/backup.sh` kontroluje hlavičku `PGDMP` a soubor bez ní smaže. `sha256` zatím nezapisuje.
- Návrh drží lokálně 7 dumpů. Skript staré dumpy nemaže, aby nespouštěl retenci.

Slouží k obnově nezávislé na verzi PostgreSQL a pgBackRest a k ročním zálohám.

### Soubory stacku

Kopie do `…/preparations/<preparation_id>/files/`:

- runtime `.env`,
- `dynamic-security.json` Mosquitta,
- `acme.json` (kvůli rate limitům Let's Encrypt při obnově),
- KEK, `dashboard.htpasswd` Traefiku, bouncer klíč CrowdSec,
- `state/`.

`scripts/backup.sh` kopíruje runtime `.env` a, když už existují, `acme.json`, `dashboard.htpasswd` a bouncer klíč CrowdSec do pracovní přípravy. Po úspěšném dokončení atomicky zveřejní adresář a marker `preparations/current`. Manifest `backup-manifest.json` obsahuje pouze metadata a musí mít stav `ready`; neúplná nebo chybná příprava marker nezmění. `app-kek` kopíruje jen tehdy, když soubor už existuje, a jen když má 32 bajtů. Chybí-li a v `meters.aes_key_enc` už nějaký záznam je, příprava je neúplná. `restic-key-password` do `files/` nepatří a skript ho nekopíruje.

Adresář má práva `700` a šifruje se až v resticu. Git repozitář se nezálohuje, je na GitHubu.

### Restic (vzdálená kopie)

- Repozitář `rest:https://infrastructure-sjv@10.100.101.12:8000/infrastructure-sjv/`. Při `--private-repos` musí cesta začínat jménem uživatele `rest-server`. HTTP heslo a šifrovací heslo jsou dva různé údaje. Rozdíl je v [Hesla a přístupové údaje](#hesla-a-přístupové-údaje). Do logů se nepíšou.
- Certifikát `rest-server` je `/docker-data/infrastructure-sjv/secrets/restic-rest-server.crt`, v kontejneru jen pro čtení. Restic 0.19.1 má `--cacert` jako globální volbu, takže ho služba předává před `backup` i před `snapshots`. Ověření TLS se nevypíná.
- Bez neprázdného `RESTIC_REST_PASSWORD` plánovač zůstane nečinný a Restic nespustí. Chybějící heslo se do logu ani do stavového JSON nezapisuje.
- Restic 0.19.1 běží jako trvalá služba `sjv-backup` (`compose/30-backup.yml`) na síti `sjv-egress`, bez publikovaného portu. Oficiální image je jen jednorázová binárka, proto má služba vlastní image se stejným binárním souborem a plánovačem. Zálohované adresáře jsou připojené jen pro čtení. Na hostitele se Restic neinstaluje.
- Restic 0.19.1 při uživateli v URL ignoruje `RESTIC_REST_PASSWORD` (issue 22035). Když URL uživatelské jméno obsahuje, služba ho pro proces klienta oddělí a nastaví `RESTIC_REST_USERNAME`. Když ho URL neobsahuje, ponechá `RESTIC_REST_USERNAME` z prostředí. Prázdné zůstane jen tehdy, když není ani v URL, ani v prostředí. Hodnota v `.env` se nemění, heslo REST zůstává v `RESTIC_REST_PASSWORD` a heslo klíče jde dál jen přes `RESTIC_PASSWORD_FILE`. Heslo se do URL ani do logu nedává.
- Prvotní založení tohoto repozitáře je `sudo ./scripts/init-backup.sh`, po `deploy.sh` a před `post-deploy.sh`. V kontejneru běží jen `init-repository`: nejdřív přečte konfiguraci, existující repozitář znovu nezakládá a plánovač nespouští. `restic init` se spustí jen při kódu 10 a přesně třech řádcích diagnostiky chybějícího repozitáře. Chyba připojení, TLS, HTTP 401 nebo šifrovacího hesla `init` nespustí. `restic init` založí jeden klíč z obsahu `restic-key-password`. Jméno klíče nepředává a `restic key add` nevolá. Obnova po kompromitaci je krok 11 níže.

### Hesla a přístupové údaje

| Proměnná / soubor | Účel | Umístění | Kdo a kdy jej používá |
| --- | --- | --- | --- |
| `RESTIC_REPOSITORY` | Adresa repozitáře. Validátor vyžaduje `rest:https://infrastructure-sjv@HOST:PORT/infrastructure-sjv/` a heslo v URL odmítne. | Runtime `.env` v `/docker-data/stacks/infrastructure-sjv/.env`, politika `user`. | Compose ji předá do `sjv-backup`. `prepare_repository()` z ní před každým voláním Resticu uživatelské jméno vyjme. |
| `RESTIC_REST_USERNAME` | Uživatelské jméno HTTP Basic autentizace k REST serveru. | V `.env` není. Compose ji nepředává. Proces ji nastaví z uživatelského jména v URL. Když URL jméno nemá, ponechá hodnotu, která už v procesu je. | `cat config`, `init`, `backup` a kontrola posledního snapshotu. Do `.env` se nepřidává: validátor neznámou proměnnou odmítne. |
| `RESTIC_REST_PASSWORD` | Heslo téže HTTP Basic autentizace. Obsah repozitáře nešifruje. Nejméně 16 znaků, když je adresa vyplněná. | Runtime `.env`, politika `user`. | Compose ho předá do kontejneru. Restic 0.19.1 ho načte jen tehdy, když URL neobsahuje ani jméno, ani heslo. |
| `RESTIC_PASSWORD` | Proměnná, ze které Restic umí číst šifrovací heslo. Projekt ji nepoužívá a před Resticem ji maže. | V `.env` ani v Compose není. | `prepare_repository()` provede `unset`. Do `.env` se nepřidává. |
| `RESTIC_PASSWORD_FILE` | Cesta k souboru se šifrovacím heslem. | Compose nastaví `/run/secrets/restic-key-password`. | `prepare_repository()` ji exportuje před `cat config`, `init`, `backup` i kontrolou snapshotu. |
| `secrets/restic-key-password` | Obsah souboru je šifrovací heslo repozitáře. `restic init` z něj založí jeden klíč. | `/docker-data/infrastructure-sjv/secrets/restic-key-password`, běžný neprázdný soubor, mód 600 nebo 400. Skript ho negeneruje. | `init-backup.sh` kontroluje soubor a obsah nečte. Kontejner ho má jen pro čtení. |
| `secrets/restic-rest-server.crt` | Certifikát pro `--cacert`. Heslo to není. | `/docker-data/infrastructure-sjv/secrets/restic-rest-server.crt`. Mód smí být 644. | Před každým podpříkazem Resticu. Ověření TLS se nevypíná. |
| `.htpasswd` REST serveru | Databáze HTTP jména a hesla, proti které se přihlášení ověřuje. | Na domácím serveru, mimo tento repozitář. Návrh E6 uvádí `--htpasswd-file`. | Jen REST server. Klient soubor nečte. `dashboard.htpasswd` Traefiku a `create-dashboard-user.sh` jsou jiný soubor a jiný účel. |

### Přihlášení k REST serveru

1. Uživatelské jméno je součást `RESTIC_REPOSITORY`. Provozní tvar je `rest:https://infrastructure-sjv@10.100.101.12:8000/infrastructure-sjv/`.
2. `prepare_repository()` jméno z URL vyjme a nastaví `RESTIC_REST_USERNAME`. Adresa předaná Resticu je `rest:https://10.100.101.12:8000/infrastructure-sjv/`. Soubor `.env` se při tom nemění.
3. `RESTIC_REST_PASSWORD` se načte z runtime `.env` a Compose ho předá do kontejneru.
4. Restic 0.19.1 v `internal/backend/rest/config.go` vezme obě proměnné jen tehdy, když URL neobsahuje ani jméno, ani heslo. Když jméno v URL zůstane, heslo z prostředí ignoruje. Proto se jméno z URL odděluje dřív, než se zavolá `restic`.
5. Stejná dvojice se použije při `cat config`, `init`, `backup` i při kontrole posledního snapshotu. Všechny tyto operace jdou přes `prepare_repository()` a `run_restic()`. Obnovu žádný skript v repozitáři neprovádí.

### Šifrování záloh

`restic init` přečte obsah `RESTIC_PASSWORD_FILE` a založí jím jeden klíč repozitáře. Skript mu nepředává jméno. Označení `vps` v této dokumentaci je návrh, ne jméno zapsané příkazem.

Toto heslo není `RESTIC_REST_PASSWORD`. HTTP přihlášení otevře přístup k souborům na REST serveru. Bez šifrovacího hesla z nich Restic zálohu nepřečte. Šifrovací heslo bez HTTP účtu, nebo bez přímého čtení disku na domácím serveru, k těm souborům nedosáhne.

Kopie obsahu `restic-key-password` musí být mimo VPS a mimo zálohu `preparations/`. Záloha je tímto heslem zamčená, takže kopie uvnitř ní při ztrátě VPS nepomůže. Skripty soubor do přípravy nekopírují.

`app-kek` je jiné tajemství. Rozbaluje jen `meters.aes_key_enc`. Odečty jím šifrované nejsou a heslo Restic je nerozbalí. Soubor je `/docker-data/infrastructure-sjv/secrets/app-kek`. `scripts/backup.sh` ho do `preparations/<preparation_id>/files/` zkopíruje, jen když už existuje. Kopie v Restic snapshotu nenahrazuje kopii mimo VPS: bez ní se po ztrátě VPS i snapshotu ke klíčům měřidel nedá dostat. Skript produkční soubor nezakládá.

### Co obnova potřebuje

Běžná obnova se současnými přihlašovacími údaji potřebuje adresu s uživatelem `infrastructure-sjv`, `RESTIC_REST_PASSWORD`, certifikát a obsah `restic-key-password`. Dešifrování je heslo z tohoto souboru, protože `restic init` zakládá jeden klíč a `restic key add` v repozitáři není. Skript `restore.sh` ani `restore-test.sh` tuto obnovu neprovádí.

Obnova po kompromitaci heslo účtu `infrastructure-sjv` zneplatní. Náhradní HTTP účet v současné implementaci není. Zbývá návrh přímého čtení úložiště na disku domácího serveru a dešifrování stejným heslem z `restic-key-password`.

NEIMPLEMENTOVANÉ, jen návrh:

- účet `sjv-recovery` a jeho heslo,
- druhá instance `rest-server-sjv-recovery`,
- klíče se jmény `recovery` a `maintenance`,
- `restic key add`, `restic key remove`, `restore.sh` a `restore-test.sh`.

Mimo VPS a mimo plánovanou zálohu `preparations/` se uchovává kopie šifrovacího hesla, certifikát REST serveru a postup k domácímu serveru. Heslo `infrastructure-sjv` leží na VPS v runtime `.env`. Po jeho zneplatnění se pro obnovu nepoužije.

| Tag | Kdy | Obsah | Spouští |
| --- | --- | --- | --- |
| `daily` | každý den v 03:15 | `pgbackrest/` a právě ověřená příprava z `preparations/current` | pouze `sjv-backup`, s tagy `daily` a `sjv-daily-prep-<preparation_id>` |
| `wal` | běžně po 300 s | jen `pgbackrest/archive/` | `sjv-backup`. Po obsazeném zámku další pokus po 60 s. Dlouhá denní úloha interval protáhne |

Zámky jsou v `/docker-data/infrastructure-sjv/backup-locks/` a stejný adresář je v kontejneru `/locks`. Stav úlohy je `state/sjv-backup-daily.json` a `state/sjv-backup-wal.json`; denní pokus navíc zapisuje `sjv-backup-last-attempt.json`, `sjv-backup-last-restorable.json` a čítač po sobě jdoucích selhání. Denní úloha nejprve ověří marker, manifest a skutečné soubory, potom bere `restic-job.lock` exkluzivně a `backup.lock` i `repo.lock` sdíleně, všechno bez čekání. `wal` bere `restic-job.lock` exkluzivně a `repo.lock` sdíleně, `backup.lock` nebere. Obě úlohy používají stejné fyzické soubory zámků; WAL nemění `current`.

Čas posledního pokusu `wal` je `state/sjv-backup-wal.epoch`. Čas dalšího pokusu je `state/sjv-backup-wal.next`. Oba soubory se zapisují atomicky. Po `ok`, po `skipped-empty` a po `failed` je další pokus až za `SJV_BACKUP_WAL_SECONDS` (výchozí 300 s). Po `skipped-locked` a `skipped-repo-lock` je další pokus za `SJV_BACKUP_WAL_RETRY_SECONDS` (výchozí 60 s). Prázdný archiv se proto neopakuje po 60 s a obsazený zámek nečeká celých 300 s. `failed` je chyba Resticu, ne přeskočená úloha. Po restartu se pokračuje podle uloženého `sjv-backup-wal.next`. Když ten soubor chybí a zůstane jen čas posledního pokusu, počká se standardní interval, takže restart nespustí sérii pokusů.

Když `pgbackrest/archive/` nemá žádný skutečný soubor, `wal` Restic nespustí, zapíše `skipped-empty` a skončí kódem 0. To není chyba zálohy. Dočasné `*.pgbackrest.tmp` a symlinky se nepočítají. Běžný soubor ve vnořeném adresáři ano. Healthcheck čte soubor heartbeat. Plánovač ho obnovuje i během zálohy, takže běžící záloha sama o sobě kontejner neoznačí jako nezdravý. Při SIGTERM i při normálním konci se proces heartbeatu ukončí a nenechá po sobě `sleep`. Zastavený plánovač healthcheck pozná. Neúspěch zálohy se pozná ze stavu `failed`, ne ze healthchecku.

Když úloha selže, JSON má `failed` a plánovač běží dál. Další `wal` je až po standardních 300 s, ne po krátkém retry. `daily` nejdřív za 15 minut a po úspěchu už ten den znovu ne. Log kontejneru heslo neobsahuje. Obnova z posledního `daily` a `archive/` z posledního `wal` se nemění. `forget` a `prune` zůstávají jen na domácím serveru.

## Konzistence vzdálené kopie

### Problém

Restic čte soubory postupně. pgBackRest během zálohy zapisuje soubory zálohy a na konci aktualizuje `backup.info`. Při expire maže staré zálohy a WAL. Snapshot pořízený během těchto operací může obsahovat zálohu bez platného záznamu v `backup.info`, nebo `backup.info` odkazující na chybějící soubory. Nekonzistentní snapshot by se odhalil až při obnově.

### Řešení

1. **`daily` jen v klidovém stavu.** `scripts/backup.sh` drží exkluzivní `backup.lock` po dobu `pgbackrest backup`, `pg_dump`, kopií souborů a atomického zveřejnění přípravy. Zámek pak pustí. Jediným vlastníkem denního Restic snapshotu je `sjv-backup`; ten načte konkrétní adresář z `preparations/current`, ověří manifest a hned získá sdílený `backup.lock` a `repo.lock`. Obsazený zámek denní běh přeskočí a nečeká na něj, takže plánovač může pokračovat k `wal`. Pořadí tím zůstává:
   1. `pgbackrest check` a `pgbackrest backup` (check ověří archivaci WAL; záloha sama vyžaduje WAL potřebné pro svou konzistenci),
   2. `pg_dump`, kopie souborů, manifest a atomické zveřejnění přípravy,
   3. `sjv-backup restic backup --tag daily --tag sjv-daily-prep-<preparation_id>`,
   4. `pgbackrest expire` se v této etapě nespouští. WAL v repozitáři zůstávají.

   Při snapshotu `daily` neběží v repozitáři žádná záloha ani expire. Mění se jen `archive/`, kam přibývají nové WAL. PostgreSQL ani pgBackRest tato služba nespouští.
2. **WAL soubory se nemění.** archive-push zapisuje každý segment pod konečným názvem atomicky (dočasný soubor a přejmenování). Restic tedy vidí buď celý segment, nebo žádný. Dočasné soubory (`*.pgbackrest.tmp`) se vylučují. Atomičnost zápisu se ověří ve fázi 3 pro zafixovanou verzi.
3. **`wal` a `daily` se nepřekrývají a `wal` neběží souběžně s expire.** Obě úlohy berou exkluzivní `restic-job.lock`, takže dvě Restic úlohy neběží zároveň. `daily` bere sdílený `backup.lock` a `repo.lock` bez čekání. Když je některý obsazený, denní běh hned skončí stavem `skipped-backup-lock` nebo `skipped-repo-lock`, zámky uvolní a plánovač pokračuje. `wal` `backup.lock` nebere, takže během dlouhé lokální zálohy PostgreSQL pokračuje. `wal` bere sdílený `repo.lock` bez čekání. Když ho drží `pgbackrest expire`, `wal` hned skončí stavem `skipped-repo-lock`, uvolní `restic-job.lock` a další pokus naplánuje po retry intervalu. S expire ani s `daily` tedy `wal` neběží souběžně. Během dlouhé denní zálohy může být interval `wal` delší než 300 s i než práh 15 minut. Systém kvůli tomu nespouští souběžný Restic. Neúspěch Resticu se zapíše jako `failed` a další pokus je až po standardním intervalu. Po restartu kontejneru se pokračuje podle `sjv-backup-wal.next`.
4. **Obnova** = poslední `daily` + přes něj `archive/` z posledního `wal`. Segmenty WAL mají jednoznačné názvy a nemění se, takže sjednocení je bezpečné. `archive.info` se mění jen při `stanza-upgrade` a ten se dělá jen s novým `daily` ihned po něm.
5. **Kontinuita WAL:** `daily` obsahuje zálohu i všechny WAL do svého pořízení. `wal` obsahuje všechny WAL od nejstarší ponechané zálohy do svého pořízení. Expire maže jen WAL starší než nejstarší ponechaná plná záloha, kterou zároveň obsahuje novější `daily`. Pro PITR do času T se použije první `daily` s plnou nebo rozdílovou zálohou před T a WAL ze snapshotu pořízeného po T.

### Ověření

Návrh. `backup-verify.sh` a `restore-test.sh` v repozitáři nejsou.

- `backup-verify.sh` (týdně), NEIMPLEMENTOVANÉ:
  - `restic check --read-data-subset=5%`,
  - porovná nejnovější segment WAL v lokálním `archive/` s nejnovějším v posledním snapshotu `wal`,
  - `pgbackrest verify` a `pgbackrest info` nad lokálním repo1.
- `restore-test.sh` (měsíčně), NEIMPLEMENTOVANÉ, má ověřit celý postup obnovy z resticu včetně `pgbackrest verify` nad obnoveným repozitářem a PITR. `pgbackrest verify` hlásí chybějící rozsahy WAL. Přesný formát výstupu pro automatickou kontrolu se ověří ve fázi 3.

## Append-only a oddělení oprávnění

### Chování `rest-server --append-only`

| Operace restic | Potřebuje | V append-only | Pro tento projekt |
| --- | --- | --- | --- |
| `backup` | zápis nových souborů, vytvoření a smazání vlastního zámku | funguje (mazat lze jen zámky) | VPS |
| `check` | čtení, zámek | funguje | VPS, domácí server |
| `restore`, `snapshots`, `ls` | čtení, zámek | funguje | VPS, obnova |
| `unlock` | mazání zámků | funguje | podle potřeby |
| `forget`, `prune` | mazání snapshotů a packů | **selže** | jen domácí server lokálně |
| přepis existujícího souboru | zápis přes existující soubor | **selže** | nikdo |

Ve fázi 3 se to ověří testem z VPS proti skutečnému `rest-server`:

- `restic backup`, `check`, `restore` a `unlock` musí projít,
- `restic forget` a `restic prune` musí selhat,
- `curl -X DELETE` na existující snapshot a pack musí vrátit chybu,
- `curl -X POST` na existující soubor (přepis) musí vrátit chybu,
- přístup na cestu jiného uživatele (`--private-repos`) musí vrátit chybu.

Výsledky se zapíšou do `docs/operations.md`.

### Kdo smí co

| Operace | Kdo | Jak |
| --- | --- | --- |
| Zápis | VPS | HTTP uživatel `infrastructure-sjv` a jeden klíč založený souborem `restic-key-password`. Skript klíč nepojmenovává |
| Čtení | VPS a domácí server | Append-only čtení nebrání. VPS své zálohy přečíst může, data zná i tak. Dešifrování stále potřebuje šifrovací heslo |
| Obnova | běžný klient, po kompromitaci domácí server | NEIMPLEMENTOVANÉ jako skript. Běžná obnova používá účet `infrastructure-sjv` a heslo z `restic-key-password`. Po zneplatnění tohoto účtu náhradní HTTP účet není. Návrh po kompromitaci je přímé čtení disku domácího serveru se stejným šifrovacím heslem |
| Mazání a prune | jen domácí server | NEIMPLEMENTOVANÉ v tomto repozitáři. Návrh: lokální přístup k úložišti a klíč `maintenance`. VPS na domácí server SSH nemá |

**Obnovovací instance `rest-server`.** S volbou `--private-repos` vidí uživatel jen cestu se svým jménem. Druhý uživatel ve stejné instanci by se k repozitáři `infrastructure-sjv/` nedostal. Návrh, který skripty tohoto repozitáře nezakládají:

- druhá instance `rest-server-sjv-recovery` se stejným datovým adresářem, `--append-only`, **bez** `--private-repos`, s vlastním htpasswd obsahujícím jen uživatele `sjv-recovery`, na vlastním portu a s vlastním TLS,
- v běžném provozu vypnutá. Při obnově ji zapne správce domácího serveru a DNAT na MikroTiku pro její port se povolí jen pro adresu nového VPS,
- heslo `sjv-recovery` jen v obnovovací sadě.

Běžná obnova používá účet `infrastructure-sjv` a obsah `restic-key-password`. Po zneplatnění tohoto účtu náhradní HTTP účet v implementaci není. Návrh obnovy po kompromitaci je přímé čtení úložiště na domácím serveru se stejným šifrovacím heslem. Účet `sjv-recovery`, instance i klíče `recovery` a `maintenance` jsou NEIMPLEMENTOVANÉ. Přesné volby pro NixOS jsou v [external-changes.md](external-changes.md) a v tomto repozitáři se nespouštějí.

### Kompromitovaný VPS

- Může dál přidávat nové snapshoty, i nesmyslné, ale nesmaže ani nepřepíše existující data.
- Kontrola na domácím serveru hlásí neobvyklý nárůst objemu vzdálené restic kopie a chybějící snapshoty `wal` a `daily`.
- Po incidentu se na domácím serveru má odebrat klíč, kterým VPS šifroval, a zneplatnit heslo `infrastructure-sjv`. Příkaz `restic key remove` v tomto repozitáři není. Dnes je v repozitáři jeden klíč z `restic init` a skript ho neumí odebrat.
- Kdo má šifrovací heslo tohoto klíče, umí data dešifrovat. Po incidentu se proto založí nový repozitář a nové heslo. Starý zůstane jen pro čtení do vypršení retence. Klíče `recovery` a `maintenance` tímto krokem samy nevzniknou.

## Retence vzdálených záloh

`forget` a `prune` spouští **jen domácí server** (timer `sjv-restic-prune`, mimo tento repozitář), zvlášť pro každý tag:

```text
restic forget --tag daily --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --keep-yearly 3
restic forget --tag wal   --keep-within 48h
restic prune
```

- Snapshot `daily` obsahuje celý repozitář pgBackRest včetně WAL do svého pořízení. Z denního, týdenního nebo měsíčního snapshotu lze obnovit stav kdykoli v okně PITR, které repozitář tehdy měl.
- Snapshoty `wal` slouží jen k RPO posledních 48 hodin. Starší body pokrývají snapshoty `daily`.
- Roční snapshoty drží 3 roky i data, která DB podle retence už smazala (telegramy po 24 měsících). Musí to být v záznamech o zpracování.

## Obnovovací sada (nezávislá na VPS)

Uložení:

- offline u Gregora (soubor KeePassXC mimo VPS a mimo Nextcloud na VPS),
- vytištěná v zalepené obálce u statutárního orgánu SJV.

**Nesmí být jen ve Vaultwardenu**, protože ten běží na stejném VPS.

Dnes se mimo VPS uchovává:

1. kopie obsahu `restic-key-password`, tedy šifrovací heslo jediného klíče založeného `restic init`,
2. certifikát `restic-rest-server.crt` domácího REST serveru,
3. přístup k domácímu serveru, nebo postup pro jeho správce, a cesta k úložišti na jeho disku,
4. odkaz na repozitář `Infrastructure-sjv` na GitHubu a commit poslední nasazené verze,
5. tištěný runbook obnovy (tento dokument a `operations.md`),
6. datum poslední kontroly sady. Skript té kontroly v repozitáři není.

`scripts/backup.sh` do `preparations/<preparation_id>/files/` dává runtime `.env`, existující `app-kek`, a když jsou na disku, také `acme.json`, `dashboard.htpasswd` a bouncer klíč CrowdSec. `dynamic-security.json` nekopíruje, protože Mosquitto v repozitáři není. `restic-key-password` v přípravě není. Produkční běh této kopie se na tomto stroji nespouštěl.

Heslo `infrastructure-sjv` je na VPS v runtime `.env`. Do obnovovací sady nepatří jako jediná cesta k datům: po kompromitaci se má zneplatnit a samo zálohu nedešifruje. Náhradní HTTP účet tím nevznikne.

Až budou založené, a dnes jsou NEIMPLEMENTOVANÉ: heslo klíče `recovery`, heslo účtu `sjv-recovery`, certifikát obnovovací instance a heslo klíče `maintenance` na domácím serveru.

## Skripty

V repozitáři je `backup/sjv-backup.sh`, `scripts/init-backup.sh` a `scripts/backup.sh`. `backup-verify.sh`, `backup-status.sh`, `restore.sh` a `restore-test.sh` jsou NEIMPLEMENTOVANÉ. `backup.sh` má `set -Eeuo pipefail`, vlastní `flock` a stav v `state/backup.json`.

| Skript | Zámky | Účel |
| --- | --- | --- |
| `sjv-backup` | `restic-job.lock` exkluzivně. `daily` bere `backup.lock` a `repo.lock` sdíleně bez čekání. `wal` bere `repo.lock` sdíleně bez čekání a při obsazeném zámku se přeskočí. `backup.lock` nebere | `restic backup` a ověření posledního snapshotu. Tagy `daily` a `wal`. `forget` a `prune` nevolá |
| `scripts/backup.sh` | `backup.lock` exkluzivně po dobu lokální zálohy a zveřejnění | `pgbackrest` stanza, `check` a backup (v neděli full, jinak diff; bez předchozího full vždy full), `pg_dump -Fc`, kopie do pracovní přípravy a atomické zveřejnění. Denní Restic nespouští |
| `backup-verify.sh` | `verify.lock` | viz [Ověření](#ověření), plus `sha256` dumpů a hash řetězec auditu v živé DB |
| `backup-status.sh` | žádný | stáří posledního WAL v repo1, posledního full a diff, posledních snapshotů `daily` a `wal`, posledního testu obnovy, platnost certifikátu MQTT. `--alert` vrací nenulový kód a vloží notifikaci |
| `restore.sh` | `backup.lock`, `repo.lock` exkluzivně | obnova produkce. Dvoufázová: bez `--replace-data` jen ověří. S `--confirm infrastructure-sjv` obnoví do nového datového adresáře a teprve po kontrole přepne |
| `restore-test.sh` | `restore-test.lock` | izolovaná testovací obnova, nikdy nesahá na produkční DB |

### `restore.sh` (produkce)

NEIMPLEMENTOVANÉ. Návrh:

1. Parametry: `--source local|remote`, `--target-time` (PITR) nebo `--latest`, a `--confirm infrastructure-sjv`.
2. Bez `--replace-data` ověří dostupnost záloh a okno PITR a skončí kódem 2. Princip je z reference.
3. `--source remote` obnoví poslední `daily` a přes něj `archive/` z posledního `wal` do pracovního adresáře, ne do repo1.
4. S `--replace-data`:
   - zastaví backend, collector a worker,
   - nechá běžet Mosquitto (zprávy čekají v persistentní frontě brokeru i v zařízeních),
   - obnoví přes `pgbackrest restore --type=time` (nebo `--type=default` pro `--latest`) do nového adresáře,
   - spustí DB, `alembic current` musí odpovídat kódu,
   - po kontrolách přepne adresář a starý ponechá do ručního smazání.
5. Po obnově do bodu T se v `config` zařízení nastaví `replay_since` na T. Zařízení znovu pošlou zprávy z doby po T, pokud je ještě drží ([firmware-design.md](firmware-design.md)). Opakování zachytí idempotence a deduplikace.

### `restore-test.sh` (izolovaný test)

NEIMPLEMENTOVANÉ. Návrh:

1. Vytvoří dočasný kontejner `sjv-restore-test-<stamp>` se sítí `none` a vlastním dočasným adresářem. S produkčními sítěmi ani daty nic nesdílí. Restic běží v samostatném kroku na `sjv-egress` a zapisuje jen do dočasného adresáře.
2. Vzdálený zdroj (výchozí, měsíčně):
   - NEIMPLEMENTOVANÉ. Návrh: `restic restore` posledního `daily` a přes něj `archive/` z posledního `wal`, dešifrované heslem existujícího klíče. Pojmenovaný klíč `vps` skript nezakládá,
   - `pgbackrest verify` nad obnoveným repozitářem,
   - `pgbackrest restore` s PITR na čas o 10 minut starší než poslední WAL v obnoveném `archive/`.

   Lokální zdroj (volitelně týdně) jde přímo z repo1.
3. Ověření:
   - DB se spustí, `alembic current` odpovídá kódu,
   - počty řádků v klíčových tabulkách se blíží produkci,
   - nejnovější příjem není starší než `cíl − 15 min`,
   - hash řetězec auditu je v pořádku,
   - KEK z obnovených souborů dešifruje testovací klíč.
4. Měří čas každého kroku a výsledek zapíše do `state/restore-test-last.json`.
5. Dočasný kontejner a data vždy smaže, i při chybě (`trap`).
6. `backup-status.sh` hlásí alarm, když poslední úspěšný test je starší než 31 dní.

## Úplná obnova na novém VPS

Postup pro ztrátu nebo kompromitaci VPS. Předpoklad: dostupný domácí server, obnovovací sada a GitHub. Původní VPS se nepoužije.

| Krok | Činnost | Kdo |
| --- | --- | --- |
| 0 | Rozhodnutí o obnově a zápis času začátku. Při kompromitaci: zneplatnit heslo `infrastructure-sjv` a odvolat údaje zařízení. Odebrání šifrovacího klíče je návrh na domácím serveru. `restic key remove` v tomto repozitáři není | Gregor, správce domácího serveru |
| 1 | Nový hostitel: VPS, Incus kontejner s `security.nesting`, Docker, `/docker-data` jako připojený disk | Gregor |
| 2 | Síť: WireGuard k MikroTiku pro nového hostitele, HAProxy (nebo přímé porty 80, 443, 8883), DNS na novou adresu | Gregor, mimo tento projekt |
| 3 | NEIMPLEMENTOVANÉ. Návrh: na domácím serveru zapnout `rest-server-sjv-recovery` a povolit jeho port jen pro adresu nového hostitele | správce domácího serveru |
| 4 | Checkout `Infrastructure-sjv` na commit z obnovovací sady, `init.sh` | Gregor |
| 5 | NEIMPLEMENTOVANÉ jako skript. Návrh: `restic restore` posledního ověřeného `daily` (`preparations/<preparation_id>/`, `pgbackrest/`) a přes něj `archive/` z posledního `wal` do `/docker-data/backups/infrastructure-sjv/`. Účet `sjv-recovery` a klíč `recovery` v repozitáři nevznikají. Dnes dešifruje jen heslo z `restic-key-password` | Gregor |
| 6 | Obnova souborů z `preparations/<preparation_id>/files/` je pořád ruční. Ověřený daily snapshot může obsahovat runtime `.env`, existující `app-kek`, `acme.json`, `dashboard.htpasswd` a bouncer klíč. `dynamic-security.json` v něm není. `update-env.sh` existuje a existující hesla nepřepíše. `restic-key-password` v přípravě není | Gregor |
| 7 | Při kompromitaci rotace: hesla DB rolí, hesla zařízení v dynsec, API tokeny, bouncer klíč CrowdSec. KEK se rotuje až po spuštění (krok 11) | Gregor |
| 8 | `pgbackrest verify`, `pgbackrest info` a kontrola kontinuity WAL | Gregor |
| 9 | NEIMPLEMENTOVANÉ. Návrh: `restore.sh --source local --latest --replace-data --confirm infrastructure-sjv` | Gregor |
| 10 | `deploy.sh` (build image, spuštění), `post-deploy.sh`, kontroly zdraví | Gregor |
| 11 | Po kompromitaci nový repozitář a nové šifrovací heslo. Není to `init-backup.sh` současného repozitáře. Klíče pojmenované `vps`, `recovery` a `maintenance` a nový uživatel REST serveru jsou NEIMPLEMENTOVANÉ. Rotace KEK a nová obnovovací sada | Gregor, správce domácího serveru |
| 12 | Zařízení: nové údaje (při kompromitaci), `replay_since` na čas posledního obnoveného WAL, kontrola příjmu | Gregor |
| 13 | NEIMPLEMENTOVANÉ. Návrh: vypnout `rest-server-sjv-recovery`, okamžitý `backup.sh`, `restore-test.sh`, zápis naměřených časů do `docs/operations.md` | Gregor, správce domácího serveru |

Bez kompromitace (například porucha hostitele) se kroky 7 a 11 zjednoduší: rotace není nutná a pokračuje se do stávajícího repozitáře se šifrovacím heslem z `restic-key-password`.

## RPO: výpočet

- Lokální RPO: `archive_timeout = 60 s` a asynchronní push, přibližně 1–2 minuty.
- Vzdálené RPO za běžného provozu: lokální RPO + interval snapshotu `wal` (300 s) + doba jeho běhu, přibližně 7–10 minut. Snapshot `wal` obsahuje jen nové WAL, takže je malý. Po obsazeném `repo.lock` nebo `restic-job.lock` se další pokus plánuje po retry intervalu (výchozí 60 s). Ani tehdy se nespouští druhý Restic.
- Patnáct minut není záruka za všech okolností. Denní Restic může trvat déle a po tu dobu drží `restic-job.lock`. `wal` se během něj nespustí, takže interval může překročit 300 s i práh alarmu. `backup-status.sh` hlásí alarm, když je vzdálený snapshot `wal` starší než 15 minut. To je signál, ne důkaz, že se interval podařilo dodržet.
- Při výpadku WireGuardu nebo domácí linky vzdálené RPO roste stejně. Nezávislou kontrolu stáří snapshotů má i domácí server (dead man's switch), aby alarm přišel i tehdy, když VPS nefunguje.
- Data zařízení: vlastní ESP drží potvrzené zprávy ještě po dobu `REPLAY_HOURS`. Po obnově je lze vyžádat znovu, takže skutečná ztráta telegramů může být menší než RPO databáze. Úpravy administrátora za posledních až 15 minut znovu získat nelze.

## RTO: odhad a ověření

Obnova po ztrátě VPS teče z domova. Rozhoduje upload domácí linky (U, zatím neznámý) a velikost potřebných dat (S): poslední snapshot `daily` (dumpy, soubory a repozitář pgBackRest) a WAL z posledního `wal`.

| Krok úplné obnovy | Odhad |
| --- | --- |
| 0–3: rozhodnutí, hostitel, síť, obnovovací instance | 30–90 min, závisí na dostupnosti VPS a DNS |
| 4–6: checkout, `init.sh`, obnova souborů | 15–30 min |
| 5: přenos dat | `S / U` |
| 8–9: verify, `pgbackrest restore` a přehrání WAL | 5–30 min podle objemu WAL |
| 10: build image, deploy | 15–30 min |
| 12–13: zařízení a kontroly | 15–30 min |

Odhady časů jsou předběžné. Ilustrační výpočet přenosu, ne údaj o skutečné lince: při U = 20 Mbit/s (2,5 MB/s) odpovídá 1,5 h přenosu S ≈ 13 GB. RTO 4 h je reálné, jen pokud potřebná data nepřesáhnou mez danou skutečným uploadem.

**RTO není splněné, dokud ho neověří měřený DR test:**

- úplná obnova podle runbooku do nového Incus kontejneru, jen z domácího serveru a obnovovací sady, bez přístupu k původnímu VPS,
- poprvé před ostrým provozem, potom dvakrát ročně,
- výsledek se zapíše do `docs/operations.md` s naměřenými časy.

Návrh měsíčního `restore-test.sh` má ověřovat obnovitelnost dat a měřit dobu obnovy DB. Skript je NEIMPLEMENTOVANÝ a celé RTO neověřuje.

## Pravidelné úlohy a kontroly

| Úloha | Interval | Alarm, když |
| --- | --- | --- |
| WAL archivace | průběžně | poslední WAL starší než 5 min |
| `sjv-backup` tag `wal` | běžně 300 s; po obsazeném zámku 60 s | poslední snapshot `wal` starší než 15 min. Dlouhá denní úloha práh může překročit, souběžný Restic se nespouští |
| `backup.sh`, NEIMPLEMENTOVANÉ | denně | poslední full starší než 8 dní, diff starší než 26 h, nebo snapshot `daily` starší než 26 h |
| `backup-verify.sh`, NEIMPLEMENTOVANÉ | týdně | jakákoli chyba |
| `restore-test.sh`, NEIMPLEMENTOVANÉ | měsíčně | neúspěch, nebo poslední úspěch starší než 31 dní |
| DR test | 2× ročně | naměřené RTO nad 4 h |
| Kontrola na domácím serveru | 15 min | nejnovější snapshot `wal` starší než 20 min, `daily` starší než 26 h, neobvyklý nárůst |
