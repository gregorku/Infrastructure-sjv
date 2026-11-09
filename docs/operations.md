# Provoz: instalace a konfigurace

Stav: etapa B1b. Popisuje přípravu adresářů, runtime `.env`, vykreslení Traefiku a postup pro CrowdSec. Databáze, MQTT, aplikace, zálohy a systemd timery zatím nejsou.

## Předpoklady

- Incus kontejner podle E1 z [external-changes.md](external-changes.md) s připojeným `/docker-data` (samostatný mountpoint, `require_mountpoint` jinak skript zastaví).
- Git checkout mimo `/docker-data`, podle konvence `/incus-dir/git/Infrastructure-sjv` (cesta ještě k potvrzení, viz [architecture.md](architecture.md)).
- Bash 5, coreutils, `findmnt`, `flock`, `awk`. Skripty kontrolují dostupnost příkazů samy.
- Instalační skripty běží jako root. `test.sh` root nepotřebuje.

## Adresáře

| Cesta | Práva | Obsah |
| --- | --- | --- |
| `/docker-data/stacks/infrastructure-sjv` | 750 | runtime `.env`, kopie `.env.example`, později Compose |
| `/docker-data/infrastructure-sjv` | 755 | data služeb |
| `/docker-data/infrastructure-sjv/state` | 700 | stav skriptů |
| `/docker-data/infrastructure-sjv/secrets` | 700 | soubory s tajemstvími pro služby (od pozdějších etap) |
| `/docker-data/infrastructure-sjv/traefik/acme` | 700 | `acme.json`, práva 600 |
| `/docker-data/infrastructure-sjv/traefik/logs` | 755 | access log pro CrowdSec |
| `/docker-data/infrastructure-sjv/traefik/users` | 700 | `dashboard.htpasswd`, práva 600 |
| `/docker-data/infrastructure-sjv/traefik/crowdsec` | 700 | `BOUNCER_KEY_sjv-traefik`, práva 600, mimo Git i `.env` |
| `/docker-data/infrastructure-sjv/crowdsec/data` | 700 | data CrowdSec |
| `/docker-data/backups/infrastructure-sjv` | 700 | lokální zálohy (od fáze 2) |

`init.sh`, `update-env.sh` i `check-env.sh` nejdřív ověří, že `/docker-data` je mountpoint. Když není, skončí chybou a nezaloží adresář ani `.env`. `init.sh` adresáře vytvoří, příliš otevřená práva zúží a odmítne symlinky nebo adresáře jiného vlastníka. Adresář zapisovatelný pro skupinu nebo ostatní `update-env.sh` odmítne a práva mu nemění. Nic nemaže.

## Postup první instalace

1. `sudo ./scripts/init.sh` vytvoří adresáře a zkopíruje `.env.example` do stacku. `.env` nevytváří.
2. `sudo ./scripts/update-env.sh` vytvoří `.env` (práva 600), vygeneruje hesla a vypíše jména proměnných, které ještě obsahují `set_*`.
3. Doplň hodnoty `set_*` v `/docker-data/stacks/infrastructure-sjv/.env` ručně, bez uvozovek.
4. `sudo ./scripts/check-env.sh` musí skončit bez chyb. Varování (například chybějící vzdálená záloha) je třeba vědomě přijmout.
5. `sudo ./scripts/create-dashboard-user.sh` uloží heslo dashboardu. Bez tohoto kroku se dashboard nepublikuje.
6. `sudo ./scripts/deploy.sh` vykreslí Traefik, založí čtyři sítě projektu a spustí jen `sjv-traefik` a `sjv-crowdsec`.
7. `sudo ./scripts/post-deploy.sh` zaregistruje bouncer klíč u CrowdSec, znovu vykreslí middleware a v případě potřeby restartuje Traefik. Klíč se nevypisuje.

Opakované spuštění je bezpečné. Pokud se nic nezměnilo, soubory se nepřepisují a nevzniká záloha. `reload.sh` volá stejný `deploy.sh`. V testovacím režimu `deploy.sh` bez `--render-only` skončí chybou a Docker nezavolá.

## Hodnoty k doplnění

| Proměnná | Kdy | Poznámka |
| --- | --- | --- |
| `MQTT_HOSTNAME` | před nasazením | `sjv-mqtt.serveftp.org`, pokud jde jméno založit, jinak `sjv.serveftp.org` |
| `DOCKER_*_SUBNET`, `DOCKER_*_GATEWAY` | před nasazením | čtyři privátní sítě /16 až /28, bez překryvu navzájem ani s 10.10.10.0/24, 10.100.100.0/24, 10.110.100.0/24, 10.120.100.0/24 a 172.17.0.0/16 |
| `ADMIN_IP_ALLOWLIST` | před nasazením | privátní CIDR oddělené mezerou, nikdy `0.0.0.0/0` |
| `TRAEFIK_ACME_EMAIL` | před `TRAEFIK_TLS_MODE=letsencrypt` | v režimu `local` může zůstat placeholder |
| `TRAEFIK_IMAGE`, `CROWDSEC_IMAGE` | v šabloně | tag a digest, kategorie `framework` |
| `CROWDSEC_BOUNCER_PLUGIN` | v šabloně | verze pluginu `vX.Y.Z`, ne API klíč |
| `PROXY_PROTOCOL_TRUSTED_IPS` | před `PROXY_PROTOCOL_MODE=haproxy` | zjištěná zdrojová adresa HAProxy jako /32 |
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

## Mimo rozsah B1b

- PostgreSQL, pgBackRest, Restic, Mosquitto, FastAPI, React, wmbusmeters a firmware.
- systemd jednotky a timery, zálohy, obnova.
- Jakékoli změny NixOS, Incus, HAProxy, MikroTik, DNS nebo WireGuard (viz [external-changes.md](external-changes.md)).
