# Strategie zálohování

Zálohování je kritická část projektu. Projekt nelze označit za dokončený bez úspěšného testu obnovy a bez měřeného DR testu, který splní RTO.

## Cíle

| Parametr | Cíl | Jak se ověřuje |
| --- | --- | --- |
| RPO | ≤ 15 minut | `backup-status.sh` hlídá stáří posledního archivovaného WAL a posledního vzdáleného snapshotu |
| RTO | ≤ 4 hodiny | Měřený DR test: úplná obnova na novém VPS bez přístupu k původnímu |
| Ochrana proti mazání | Kompromitovaný VPS nesmaže existující vzdálené zálohy | Append-only `rest-server` a ZFS snapshoty, ověřené testem ve fázi 3 |
| Obnova bez VPS | Ano | Obnovovací sada a domácí server stačí k obnově do nového prostředí |

## Architektura 3-2-1

```text
                 VPS: Incus kontejner sjv
  ┌──────────────────────────────────────────────────────────────────┐
  │ sjv-postgresql ── archive-push (async) ──► pgBackRest repo1        │ kopie 1: živá DB
  │                         /docker-data/backups/infrastructure-sjv/pgbackrest
  │ pg_dump (denně) ─────────────────────────► …/dumps                 │ kopie 2: lokální zálohy
  │ soubory stacku (.env, dynsec, acme.json, KEK) ► …/files            │ (stejný disk!)
  └── restic: tag daily (celé repo, 1× denně), tag wal (archive/, 5 min) ┘
                              │ WireGuard wg1 → MikroTik doma (DNAT) → LAN
                              ▼
  domaPcServer: rest-server --append-only --private-repos (TLS, htpasswd)
       ZFS dataset <pool>/backups/infrastructure-sjv       kopie 3: jiné místo, jiné médium
       ├── ZFS snapshoty (spravuje jen domaPcServer)
       └── restic forget/prune (spouští jen domaPcServer)
```

- **Tři kopie:** živá DB, lokální zálohy na VPS, vzdálené zálohy doma.
- **Dvě média:** disk VPS a ZFS pool doma. Lokální zálohy jsou na stejném disku jako DB. Chrání před logickou chybou a urychlí běžnou obnovu, ale ne před ztrátou VPS.
- **Jedna kopie mimo lokalitu:** domácí server.
- **Neměnnost:** append-only `rest-server` a ZFS snapshoty, ke kterým VPS nemá přístup.

## Komponenty

### pgBackRest (PITR)

- Stanza `sjv`, repozitář `repo1` v `/docker-data/backups/infrastructure-sjv/pgbackrest`.
- `archive_mode = on`, `archive_command = 'pgbackrest --stanza=sjv archive-push %p'`, `archive-async = y`, `archive_timeout = 60s`.
- Plná záloha v neděli, rozdílová v ostatní dny (`backup.sh`).
- `repo1-retention-full = 2`, takže okno PITR je nejméně 7 a obvykle až 14 dní. Pro garantovaných 14 dní lze retenci zvýšit na 3. Rozhodne se podle velikosti DB.
- **Automatické expire je vypnuté** (`expire-auto = n`) a `pgbackrest expire` spouští `backup.sh` samostatně, až po denním vzdáleném snapshotu ([Konzistence](#konzistence-vzdálené-kopie)). Název a chování volby se ověří pro zafixovanou verzi pgBackRest ve fázi 1.
- Lokální repozitář není šifrovaný pgBackRestem. Leží na stejném disku jako DB a mimo VPS ho šifruje restic. Obnova pak nepotřebuje další heslo.
- PostgreSQL běží s `--data-checksums` (převzato z reference).

### Denní logický dump

`pg_dump -Fc` do `…/dumps/sjv-<UTC>.dump`:

- kontrola hlavičky `PGDMP` (převzato z reference) a `sha256`,
- lokálně se drží 7 dumpů.

Slouží k obnově nezávislé na verzi PostgreSQL a pgBackRest a k ročním zálohám.

### Soubory stacku

Kopie do `…/files/`:

- runtime `.env`,
- `dynamic-security.json` Mosquitta,
- `acme.json` (kvůli rate limitům Let's Encrypt při obnově),
- KEK, `htpasswd`, bouncer klíč CrowdSec,
- `state/`.

Adresář má práva `700` a šifruje se až v resticu. Git repozitář se nezálohuje, je na GitHubu.

### Restic (vzdálená kopie)

- Repozitář `rest:https://infrastructure-sjv@<adresa>:<port>/infrastructure-sjv/`. Při `--private-repos` musí cesta začínat jménem uživatele `rest-server`. Heslo do `rest-server` je v `.env`, heslo klíče restic `vps` v souboru s právy `600`.
- Certifikát `rest-server` je pinovaný přes `--cacert`.
- Restic běží jako jednorázový kontejner `restic/restic:<verze>` (`docker run --rm`) na síti `sjv-egress`, se zálohovanými adresáři připojenými jen pro čtení. Na hostitele se nic neinstaluje.

| Tag | Kdy | Obsah | Spouští |
| --- | --- | --- | --- |
| `daily` | 1× denně | celé `pgbackrest/`, `dumps/`, `files/` | `backup.sh` po dokončení `pgbackrest backup` |
| `wal` | každých 5 min | jen `pgbackrest/archive/` | `backup-remote.sh --wal` |

## Konzistence vzdálené kopie

### Problém

Restic čte soubory postupně. pgBackRest během zálohy zapisuje soubory zálohy a na konci aktualizuje `backup.info`. Při expire maže staré zálohy a WAL. Snapshot pořízený během těchto operací může obsahovat zálohu bez platného záznamu v `backup.info`, nebo `backup.info` odkazující na chybějící soubory. Nekonzistentní snapshot by se odhalil až při obnově.

### Řešení

1. **`daily` jen v klidovém stavu.** `backup.sh` drží zámek `backup.lock` po celou dobu běhu. Pořadí:
   1. `pgbackrest backup` (s `archive-check`, takže WAL potřebné pro konzistenci zálohy jsou v `archive/` před jejím dokončením),
   2. `pg_dump` a kopie souborů stacku,
   3. `restic backup --tag daily`,
   4. `pgbackrest expire` pod exkluzivním `repo.lock`.

   Při snapshotu `daily` neběží v repozitáři žádná záloha ani expire. Mění se jen `archive/`, kam přibývají nové WAL.
2. **WAL soubory se nemění.** archive-push zapisuje každý segment pod konečným názvem atomicky (dočasný soubor a přejmenování). Restic tedy vidí buď celý segment, nebo žádný. Dočasné soubory (`*.pgbackrest.tmp`) se vylučují. Atomičnost zápisu se ověří ve fázi 3 pro zafixovanou verzi.
3. **`wal` nesmí běžet souběžně s expire.** `backup-remote.sh --wal` drží `remote.lock` (žádné překrývání vlastních běhů) a sdílený `repo.lock`. Na exkluzivní zámek expire počká nejvýš 10 minut, jinak běh přeskočí a zapíše stav. Během dlouhé plné zálohy WAL snapshoty pokračují, protože záloha `repo.lock` nedrží.
4. **Obnova** = poslední `daily` + přes něj `archive/` z posledního `wal`. Segmenty WAL mají jednoznačné názvy a nemění se, takže sjednocení je bezpečné. `archive.info` se mění jen při `stanza-upgrade` a ten se dělá jen s novým `daily` ihned po něm.
5. **Kontinuita WAL:** `daily` obsahuje zálohu i všechny WAL do svého pořízení. `wal` obsahuje všechny WAL od nejstarší ponechané zálohy do svého pořízení. Expire maže jen WAL starší než nejstarší ponechaná plná záloha, kterou zároveň obsahuje novější `daily`. Pro PITR do času T se použije první `daily` s plnou nebo rozdílovou zálohou před T a WAL ze snapshotu pořízeného po T.

### Ověření

- `backup-verify.sh` (týdně):
  - `restic check --read-data-subset=5%`,
  - porovná nejnovější segment WAL v lokálním `archive/` s nejnovějším v posledním snapshotu `wal`,
  - `pgbackrest verify` a `pgbackrest info` nad lokálním repo1.
- `restore-test.sh` (měsíčně) ověří celý postup obnovy z resticu včetně `pgbackrest verify` nad obnoveným repozitářem a PITR. `pgbackrest verify` hlásí chybějící rozsahy WAL. Přesný formát výstupu pro automatickou kontrolu se ověří ve fázi 3.

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
| Zápis | VPS | uživatel `rest-server` `infrastructure-sjv`, klíč restic `vps` |
| Čtení | VPS a domácí server | Append-only čtení nebrání. VPS své zálohy přečíst může, data zná i tak |
| Obnova | obnovovací prostředí | klíč restic `recovery` jen v obnovovací sadě. Přístup přes obnovovací instanci `rest-server`, nebo přímo na disku domácího serveru |
| Mazání a prune | jen domácí server | lokální přístup k datasetu a klíč restic `maintenance` |
| Mazání ZFS snapshotů | jen správce domácího serveru | VPS nemá na domácí server SSH ani jiný přístup |

**Obnovovací instance `rest-server`.** S volbou `--private-repos` vidí uživatel jen cestu se svým jménem. Druhý uživatel ve stejné instanci by se k repozitáři `infrastructure-sjv/` nedostal. Proto:

- na domácím serveru je předem připravená druhá instance `rest-server-sjv-recovery` se stejným datovým adresářem, `--append-only`, **bez** `--private-repos`, s vlastním htpasswd obsahujícím jen uživatele `sjv-recovery`, na vlastním portu a s vlastním TLS,
- v běžném provozu je vypnutá. Zapne ji správce domácího serveru při obnově a DNAT na MikroTiku pro její port se povolí jen pro adresu nového VPS,
- heslo `sjv-recovery` je jen v obnovovací sadě.

Tím obnova nezávisí na heslu uživatele `infrastructure-sjv`, které je po kompromitaci VPS nutné zneplatnit. Přesné volby pro NixOS (dvě instance `rest-server`) se ověří při návrhu externí změny, viz [external-changes.md](external-changes.md).

### Kompromitovaný VPS

- Může dál přidávat nové snapshoty, i nesmyslné, ale nesmaže ani nepřepíše existující data.
- Kontrola na domácím serveru hlásí neobvyklý nárůst objemu a chybějící snapshoty.
- ZFS snapshoty chrání i proti chybě nebo kompromitaci samotného `rest-server`.
- Po incidentu se na domácím serveru odebere klíč restic `vps` (`restic key remove`) a zneplatní heslo `infrastructure-sjv`.
- Útočník s klíčem `vps` mohl získat hlavní klíč repozitáře, a tím schopnost dešifrovat data. Po incidentu se proto založí nový repozitář. Starý zůstane jen pro čtení do vypršení retence.

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

Obsah:

1. heslo klíče restic `recovery`, URL repozitáře přes obnovovací instanci a cesta k datasetu na domácím serveru,
2. heslo `sjv-recovery` a otisk TLS certifikátu obnovovací instance,
3. přístup k domácímu serveru, nebo postup pro jeho správce,
4. KEK aplikace (kopie, je i v záloze),
5. odkaz na repozitář `Infrastructure-sjv` na GitHubu a commit poslední nasazené verze,
6. tištěný runbook obnovy (tento dokument a `operations.md`),
7. datum poslední kontroly sady. Kontroluje se při každém DR testu.

## Skripty

Všechny skripty mají `set -Eeuo pipefail`, drží svůj `flock` a zapisují stav do `state/<skript>.json`.

| Skript | Zámky | Účel |
| --- | --- | --- |
| `backup.sh` | `backup.lock`, při expire `repo.lock` exkluzivně | `pgbackrest backup` (full nebo diff), `pg_dump`, kopie souborů stacku, lokální retence dumpů, `restic backup --tag daily`, ověření snapshotu, `pgbackrest expire` |
| `backup-remote.sh --wal` | `remote.lock`, `repo.lock` sdíleně | `restic backup --tag wal` pro `archive/`, ověření snapshotu (`restic snapshots --latest 1 --tag wal`) |
| `backup-verify.sh` | `verify.lock` | viz [Ověření](#ověření), plus `sha256` dumpů a hash řetězec auditu v živé DB |
| `backup-status.sh` | žádný | stáří posledního WAL v repo1, posledního full a diff, posledních snapshotů `daily` a `wal`, posledního testu obnovy, platnost certifikátu MQTT. `--alert` vrací nenulový kód a vloží notifikaci |
| `restore.sh` | `backup.lock`, `repo.lock` exkluzivně | obnova produkce. Dvoufázová: bez `--replace-data` jen ověří. S `--confirm infrastructure-sjv` obnoví do nového datového adresáře a teprve po kontrole přepne |
| `restore-test.sh` | `restore-test.lock` | izolovaná testovací obnova, nikdy nesahá na produkční DB |

### `restore.sh` (produkce)

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

1. Vytvoří dočasný kontejner `sjv-restore-test-<stamp>` se sítí `none` a vlastním dočasným adresářem. S produkčními sítěmi ani daty nic nesdílí. Restic běží v samostatném kroku na `sjv-egress` a zapisuje jen do dočasného adresáře.
2. Vzdálený zdroj (výchozí, měsíčně):
   - `restic restore` posledního `daily` a přes něj `archive/` z posledního `wal`, přes klíč `vps`,
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
| 0 | Rozhodnutí o obnově a zápis času začátku. Při kompromitaci: zneplatnit heslo `infrastructure-sjv`, odebrat klíč restic `vps`, odvolat údaje zařízení v evidenci | Gregor, správce domácího serveru |
| 1 | Nový hostitel: VPS, Incus kontejner s `security.nesting`, Docker, `/docker-data` jako připojený disk | Gregor |
| 2 | Síť: WireGuard k MikroTiku pro nového hostitele, HAProxy (nebo přímé porty 80, 443, 8883), DNS na novou adresu | Gregor, mimo tento projekt |
| 3 | Na domácím serveru zapnout `rest-server-sjv-recovery` a povolit jeho port jen pro adresu nového hostitele | správce domácího serveru |
| 4 | Checkout `Infrastructure-sjv` na commit z obnovovací sady, `init.sh` | Gregor |
| 5 | `restic restore` posledního `daily` (`files/`, `dumps/`, `pgbackrest/`) přes `sjv-recovery` a klíč `recovery` do `/docker-data/backups/infrastructure-sjv/`, potom `archive/` z posledního `wal` | Gregor |
| 6 | Obnova souborů stacku z `files/`: `.env`, KEK, dynsec, `acme.json`, htpasswd. `update-env.sh` doplní jen chybějící hodnoty | Gregor |
| 7 | Při kompromitaci rotace: hesla DB rolí, hesla zařízení v dynsec, API tokeny, bouncer klíč CrowdSec. KEK se rotuje až po spuštění (krok 11) | Gregor |
| 8 | `pgbackrest verify`, `pgbackrest info` a kontrola kontinuity WAL | Gregor |
| 9 | `restore.sh --source local --latest --replace-data --confirm infrastructure-sjv` | Gregor |
| 10 | `deploy.sh` (build image, spuštění), `post-deploy.sh`, kontroly zdraví | Gregor |
| 11 | Nový repozitář restic: `restic init`, nové klíče `vps`, `recovery`, `maintenance`, nový uživatel `rest-server`. Rotace KEK. Nová obnovovací sada | Gregor, správce domácího serveru |
| 12 | Zařízení: nové údaje (při kompromitaci), `replay_since` na čas posledního obnoveného WAL, kontrola příjmu | Gregor |
| 13 | Vypnout `rest-server-sjv-recovery`, okamžitý `backup.sh`, `restore-test.sh`, zápis naměřených časů do `docs/operations.md` | Gregor, správce domácího serveru |

Bez kompromitace (například porucha hostitele) se kroky 7 a 11 zjednoduší: rotace není nutná a pokračuje se do stávajícího repozitáře s klíčem `vps`.

## RPO: výpočet

- Lokální RPO: `archive_timeout = 60 s` a asynchronní push, přibližně 1–2 minuty.
- Vzdálené RPO: lokální RPO + interval snapshotu `wal` (5 min) + doba jeho běhu, v normálním provozu přibližně 7–10 minut. Snapshot `wal` obsahuje jen nové WAL, takže je malý.
- Při výpadku WireGuardu nebo domácí linky vzdálené RPO roste. `backup-status.sh` hlásí alarm, když vzdálený snapshot `wal` je starší než 15 minut. Nezávislou kontrolu stáří snapshotů má i domácí server (dead man's switch), aby alarm přišel i tehdy, když VPS nefunguje.
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

Měsíční `restore-test.sh` ověřuje obnovitelnost dat a měří dobu obnovy DB. Celé RTO neověřuje.

## Ověření cílového ZFS datasetu

Cesta `/zfs-RAID-6TB/backups/infrastructure-sjv/` není potvrzená. V NixOS konfiguraci `domaPcServer` jsou jen pooly `datapool`, `zfs-NVME-4TB` a `zfs-image`. Navíc je tam `services.zfs.autoScrub.enable = false` a `services.zfs.autoSnapshot.enable = false`.

**Tento projekt dataset nevytváří a NixOS nemění.** Ověření před rozhodnutím (spouští Gregor na `domaPcServer`, jen čtení):

1. `zpool list` a `zpool status`: existuje pool pro `/zfs-RAID-6TB`? Jaký má typ redundance (raidz, mirror) a stav?
2. `zfs list -o name,mountpoint,used,avail,compression,encryption` a `findmnt /zfs-RAID-6TB`: který dataset tam je připojený.
3. Zda se pool importuje při bootu. Pokud chybí v `boot.zfs.extraPools`, po restartu nemusí být dostupný a zálohy by tiše selhávaly nebo se zapisovaly na kořenový souborový systém.
4. Volné místo proti odhadu: velikost repozitáře pgBackRest × počet ponechaných snapshotů `daily` po deduplikaci resticem + dumpy. Doporučuji kvótu datasetu.
5. Šifrování v klidu (`encryption`) a kdo zná klíč. Restic data šifruje sám, šifrování ZFS je druhá vrstva.
6. Scrub. `autoScrub` je vypnutý a bez scrubu se tichá chyba disku neodhalí. Doporučuji pravidelný scrub.
7. Existující nástroje snapshotů (sanoid, syncoid, vlastní skripty), aby se nekřížily.
8. Zda je pool zálohovaný dál. Kopie 3 je jen tak bezpečná jako tento pool.

Navrhované vlastnosti nového datasetu (provede se jen po schválení, viz [external-changes.md](external-changes.md)): `<pool>/backups/infrastructure-sjv`, `compression=zstd`, `atime=off`, `recordsize=1M`, kvóta, vlastník je uživatel služby `rest-server`.

Návrh retence ZFS snapshotů (k rozhodnutí): hodinové 48, denní 30, měsíční 6. Snapshoty drží i data, která `prune` už smazal, takže zvyšují potřebné místo.

## Pravidelné úlohy a kontroly

| Úloha | Interval | Alarm, když |
| --- | --- | --- |
| WAL archivace | průběžně | poslední WAL starší než 5 min |
| `backup-remote.sh --wal` | 5 min | poslední snapshot `wal` starší než 15 min |
| `backup.sh` | denně | poslední full starší než 8 dní, diff starší než 26 h, nebo snapshot `daily` starší než 26 h |
| `backup-verify.sh` | týdně | jakákoli chyba |
| `restore-test.sh` | měsíčně | neúspěch, nebo poslední úspěch starší než 31 dní |
| DR test | 2× ročně | naměřené RTO nad 4 h |
| Kontrola na domácím serveru | 15 min | nejnovější snapshot `wal` starší než 20 min, `daily` starší než 26 h, neobvyklý nárůst |
