# Architektura

Infrastructure-sjv je samostatný Docker Compose stack pro informační systém SJV. Veřejné jméno je `SJV_DOMAIN` v runtime `.env`. Běží v Incus kontejneru `sjv-monitoring` na VPS `netcupVPSServer`. Nezávisí na Nextcloudu, Home Assistantu, Authentiku ani Vaultwardenu. Aplikace je jen informační, bez rozúčtování nákladů.

PostgreSQL je centrální a jediný dlouhodobý zdroj pravdy (rozhodnutí 15 v [decisions.md](decisions.md)). ESP, ACRIOS i každý další vstup končí ve stejném modelu. ACRIOS je integrační partner. Konkrétní model a protokol nejsou vybrané a schéma na nich nezávisí.

Související dokumenty:

- rozhodnutí: [decisions.md](decisions.md)
- datový model: [database-design.md](database-design.md)
- příjem dat a deduplikace: [data-ingestion.md](data-ingestion.md)
- bezpečnost: [security.md](security.md)
- zálohy: [backup-strategy.md](backup-strategy.md)
- změny mimo repozitář (jen návrh, neschváleno): [external-changes.md](external-changes.md)
- firmware: [firmware-design.md](firmware-design.md)
- postup implementace: [implementation-plan.md](implementation-plan.md)

## Kontext VPS

Aktuální nasazení. Tento repozitář DNS, HAProxy ani Incus nemění.

| Fakt | Zdroj |
| --- | --- |
| HAProxy na hostiteli: port 80 v režimu HTTP podle `Host`, port 443 jako TCP passthrough podle SNI, do Incusu s `send-proxy-v2` | `modules/server/haproxy-netcupVPSServer.nix` |
| `default_backend` míří na Nextcloud Gregora. Bez routy pro `SJV_DOMAIN` provoz pro jméno SJV skončí tam | tamtéž |
| Incus síť `incusbr0` = `10.10.10.0/24`, brána `10.10.10.1`, kontejner `sjv-monitoring` = `10.10.10.20` | aktuální nasazení |
| `PROXY_PROTOCOL_TRUSTED_IPS=10.10.10.1/32` je očekávaná zdrojová adresa HAProxy. Před spolehnutím se na ni se potvrdí skutečným provozem | runtime `.env` |
| V DNAT pravidlech jsou použité adresy `10.10.10.10`, `.11`, `.12`, `.100` | `modules/server/firewall/dnat-netcupVPSServer.nix` |
| Forward chain povoluje provoz do i z `incusbr0`. Provoz z Incusu do WireGuardu se maskuje | `modules/server/firewall/firewall-vps-netcup.nix` |
| WireGuard: `10.100.101.0/24` (správa z domova), `10.110.110.0/24`, `10.120.120.0/24` | aktuální nasazení |
| Výchozí Docker bridge `172.17.0.0/16` | Docker v kontejneru |

## Toky

```text
Uživatel ──HTTPS──► HAProxy VPS :443 (SNI, PROXY v2) ──► sjv-traefik :443
                                                          ├─ /api/*  ─► sjv-backend
                                                          └─ /*      ─► sjv-web
ESP ──MQTT/TLS :8883──► nftables DNAT VPS ──► sjv-mosquitto :8883 ──► sjv-collector ─┐
ESP ──HTTPS──► HAProxy ──► sjv-traefik ──► /api/v1/ingest/* ──► sjv-backend ─────────┤
ACRIOS MQTT / HTTPS / UDP/DTLS / Platform API  (až po PoC, teď bez portu a bez kontejneru) ─┤
import CSV ──► administrace ────────────────────────────────────────────────────────┤
                                                                                     ▼
                                                              interní kontrakt příjmu
                                                                                     ▼
                                                              sjv-postgresql  (jediný zdroj pravdy)
                                                                                     ▼
sjv-worker: dekódování, timeout fragmentů, agregace, offline detekce, odesílání e-mailů
sjv-postgresql ── archive-push ──► repozitář pgBackRest (lokální disk)
systemd timer ──► restic ──► wg1 ──► MikroTik doma (DNAT) ──► rest-server --append-only (domaPcServer)
```

Adaptér jen převede bajty na interní kontrakt z [data-ingestion.md](data-ingestion.md). Cesty ACRIOS na obrázku nejsou služby v Compose. UDP listener a klient Platform API se přidají až po PoC a po samostatném schválení portu. Do té doby nemají kontejner, port ani tajemství. Všechny cesty zapisují stejné tabulky.

## Služby

| Kontejner | Image | Sítě | Host port | Healthcheck |
| --- | --- | --- | --- | --- |
| `sjv-traefik` | `traefik` `v3.7.17` (tag i digest) | `sjv-proxy` (pevná IP), `sjv-internal` | `80`, `443`, `8443` (jen `10.10.10.20`) | `traefik healthcheck --ping` |
| `sjv-crowdsec` | `crowdsecurity/crowdsec` `v1.8.2` (tag i digest) | `sjv-internal`, `sjv-egress` | žádný | `cscli lapi status` na portu 8080 |
| `sjv-postgresql` | lokální build `postgres:18.x` + pgBackRest | `sjv-internal` | žádný | `pg_isready` |
| `sjv-mosquitto` | `eclipse-mosquitto` 2.x, přesný tag | `sjv-internal`, `sjv-mqtt` | `8883` | odběr `$SYS` přes interní listener s účtem healthcheck |
| `sjv-backend` | lokální build `app/backend` | `sjv-proxy`, `sjv-internal` | žádný | `GET /readyz` |
| `sjv-collector` | lokální build `app/collector` | `sjv-internal` | žádný | soubor heartbeat procesu |
| `sjv-worker` | stejný image jako collector, jiný entrypoint | `sjv-internal`, `sjv-egress` | žádný | soubor heartbeat procesu |
| `sjv-web` | lokální build `app/frontend` na `nginx-unprivileged` | `sjv-proxy` | žádný | HTTP na interní port |

Restic se nespouští jako trvalá služba. Skripty ho volají jako jednorázový kontejner (`docker run --rm`) se zafixovaným image, na síti `sjv-egress`.

Konvence převzaté z `Infrastructure-Nextcloud-Lu`:

- `restart: unless-stopped`, `security_opt: no-new-privileges:true`, `init: true`,
- logy `json-file` s `LOG_MAX_SIZE` a `LOG_MAX_FILES`,
- interní služby bez publikovaného portu,
- sítě jako `external`, zakládané skriptem s kontrolou překryvu,
- generovaný `traefik.yml`, režimy `PROXY_PROTOCOL_MODE` a `TRAEFIK_TLS_MODE`,
- správa bouncer klíče CrowdSec.

Rozdíly proti referenci:

- Traefik nemá `docker.sock` a nepoužívá Docker provider. Všechny routery jsou v souborech.
- Bez Dockge, Redis, Nginx+PHP a Metabase.

### Implementace B1b

V repozitáři jsou `compose.yml`, `compose/00-networks.yml`, `compose/10-traefik.yml`, `compose/15-traefik-admin-port.yml`, `compose/20-crowdsec.yml`, `configs/traefik/dynamic/` a `configs/crowdsec/`. Služby aplikace, PostgreSQL a Mosquitto v Compose ještě nejsou.

- Sítě jsou `external`. Zakládá je `deploy.sh` a označí je `com.infrastructure-sjv.managed=true`. Cizí síť se stejným jménem skript nemění ani nemaže. `sjv-internal` vzniká s `--internal`.
- Pevná adresa Traefiku na `sjv-proxy` je první adresa za branou této sítě. Počítá ji `deploy.sh` a předá ji Compose jako `TRAEFIK_PROXY_ADDRESS`. V `.env` tato hodnota není.
- Traefik má jen file provider. `docker.sock` se nikam nemountuje. Veřejné webové porty jsou 80 a 443. Samostatný administrační port 8443 se publikuje pouze na `10.10.10.20` a je dostupný jen přes WireGuard podle následujícího bodu.
- **Administrace Traefiku:** samostatný entrypoint `admin` na TCP portu `8443`. Port se publikuje pouze na `10.10.10.20:8443` v Incus kontejneru `sjv-monitoring`. Přístup vede přes WireGuard `wg1` na VPS `10.100.101.1:8443`, odkud VPS provoz přesměruje na kontejner. Firewall VPS povoluje tento provoz pouze z `10.100.101.0/24` přes `wg1`. Dashboard chrání Traefik `ipAllowList`, BasicAuth a CrowdSec. Heslo je uloženo jako bcrypt hash mimo Git.
- Routy `sjv-api` (`http://sjv-backend:8000`) a `sjv-web` (`http://sjv-web:8080`) jsou připravené. Kontejnery těchto služeb tato etapa nespouští.
- Samostatný certifikát MQTT se vykreslí, když se `MQTT_HOSTNAME` liší od `SJV_DOMAIN` a `TRAEFIK_TLS_MODE=letsencrypt`.
- CrowdSec je na `sjv-internal` a `sjv-egress`, bez portu na hostu. LAPI je `crowdsec:8080`. Healthcheck volá `cscli lapi status`, takže Traefik čeká na skutečně dostupnou LAPI, ne na verzi binárky. Bouncer middleware se připojí až po `post-deploy.sh`, protože klíč v tu chvíli teprve vzniká.
- Traefik má kořen souborového systému jen pro čtení, zahozené capabilities kromě `NET_BIND_SERVICE` a zapisuje jen do ACME, logů a `/plugins-storage`. CrowdSec má zahozené všechny capabilities. Nepřepíná se na jiného uživatele: oficiální entrypoint zapisuje `/etc/crowdsec` a databázi a image nemá neprivilegovaný účet, pod kterým by tyto zápisy prošly.
- `traefik.log` rotuje Traefik sám (`maxSize` 20 MB, `maxAge` 14 dní, `maxBackups` 14, komprese). `access.log` rotuje `scripts/rotate-traefik-logs.sh` přes copytruncate, aby CrowdSec zůstal na stejném inode. Návrh timeru je v `ops/systemd/` a do NixOS se neinstaluje.

### Sítě

| Síť | `internal` | Členové | Účel |
| --- | --- | --- | --- |
| `sjv-proxy` | ne | traefik, backend, web | HTTP mezi Traefikem a aplikací. Odchozí provoz Traefiku kvůli ACME a stažení pluginu |
| `sjv-internal` | ano | postgresql, mosquitto, collector, worker, backend, crowdsec, traefik | databáze, interní MQTT, CrowdSec LAPI |
| `sjv-mqtt` | ne | mosquitto | jen kvůli publikování portu 8883 |
| `sjv-egress` | ne | crowdsec, worker, jednorázový restic | odchozí provoz: CrowdSec hub, SMTP, rest-server |

Proč čtyři sítě:

- Kontejner, který je jen na síti `internal: true`, nemůže publikovat port ani navázat odchozí spojení. Proto Mosquitto potřebuje `sjv-mqtt` a CrowdSec, worker a restic potřebují `sjv-egress`.
- PostgreSQL a collector jsou jen na `sjv-internal` a ven se nedostanou.

Projektové sítě v `.env` jsou `172.20.0.0/24`, `172.21.0.0/24`, `172.22.0.0/24` a `172.23.0.0/24`, každá s branou `.1`. Jsou uživatelské, takže `update-env.sh` existující hodnoty ponechá. `check-env.sh` odmítne překryv mezi nimi a s `10.10.10.0/24`, `10.100.101.0/24`, `10.110.110.0/24`, `10.120.120.0/24` a `172.17.0.0/16`.

## Hostnames a TLS

| Proměnná | Účel |
| --- | --- |
| `SJV_DOMAIN` | web, API, HTTPS ingest |
| `MQTT_HOSTNAME` | jméno brokeru. Stejná hodnota jako `SJV_DOMAIN` znamená MQTT na jménu webu. Jiné platné DNS jméno dostane vlastní certifikát |

Obě proměnné jsou uživatelské. Šablona v Gitu má `example.com` a `mqtt.example.com`. `check-env.sh` tato dokumentační jména odmítne. `update-env.sh` existující hodnotu v runtime `.env` ponechá a ze šablony ji nepřepíše.

Samostatné MQTT jméno drží adresu brokeru stabilní i při přesunu a oddělí certifikát MQTT od webu. Když druhé jméno není k dispozici, `MQTT_HOSTNAME` se nastaví na stejnou hodnotu jako `SJV_DOMAIN` a broker poslouchá na `<SJV_DOMAIN>:8883`.

### Obnova certifikátů

1. Traefik získává certifikáty Let's Encrypt přes HTTP-01 na entrypointu `web`. Vyžaduje routu HAProxy na portu 80 (E3 v [external-changes.md](external-changes.md)).
2. Když se MQTT jméno liší od jména webu, `deploy.sh` zapíše `runtime/traefik/dynamic/mqtt-cert.yml` s routerem `Host(<MQTT_HOSTNAME>)`, certResolverem `letsencrypt` a službou `noop@internal`. Router jen zařídí, aby Traefik certifikát vyžádal a obnovoval.
3. `scripts/cert-sync.sh` spouští timer `sjv-cert-sync.timer` každých 6 h. Skript:
   - přečte `acme.json` (jen čtení, `jq`),
   - vybere certifikát pro MQTT jméno,
   - ověří ho přes `openssl`: shodu veřejného klíče, SAN, platnost alespoň 14 dní a řetězec,
   - atomicky zapíše `fullchain.pem` a `privkey.pem` do `${DATA_DIR}/mosquitto/certs` (vlastník je uid Mosquitta, klíč s právy `600`),
   - při změně pošle `SIGHUP` kontejneru `sjv-mosquitto`,
   - přes `openssl s_client -servername` ověří, že broker servíruje nový sériový počet, jinak kontejner restartuje.
4. `backup-status.sh --alert` hlásí certifikát MQTT s platností pod 14 dní.
5. Obnova nesmí předpokládat 90denní platnost. Timer proto kontroluje skutečné datum expirace.
6. Zda Mosquitto při `SIGHUP` znovu načte certifikát, ověří test ve fázi 10. Do té doby je výchozí cestou restart kontejneru. Zařízení se znovu připojí a frontu doručí.

Firmware ověřuje hostname a důvěřuje kořenovým CA ISRG Root X1 a X2 v aktualizovatelném balíčku ([firmware-design.md](firmware-design.md)).

### Konfigurace Mosquitta (návrh pro implementaci)

```text
per_listener_settings false
allow_anonymous false
plugin <cesta podle image>/mosquitto_dynamic_security.so
plugin_opt_config_file /mosquitto/data/dynamic-security.json
persistence true
persistence_location /mosquitto/data/
persistent_client_expiration 14d
max_queued_messages <hodnota podle kapacity>
queue_qos0_messages false

listener 8883
certfile /mosquitto/certs/fullchain.pem
keyfile /mosquitto/certs/privkey.pem
tls_version tlsv1.2

listener 1883
# dosažitelný jen z Docker sítí, host port se nepublikuje; autentizace platí i zde
```

- `queue_qos0_messages false` je záměr: heartbeat (QoS 0) se pro odpojený collector nehromadí a vždy přichází v reálném čase. Spoléhá na to odhad času zachycení ([data-ingestion.md](data-ingestion.md)).
- Účty a ACL popisuje [data-ingestion.md](data-ingestion.md).

## Rozhraní (API)

REST, prefix `/api/v1`, popsané přes OpenAPI. TS klient pro frontend se generuje z OpenAPI. Všechny měnící požadavky vyžadují CSRF token ([security.md](security.md)).

### Autentizace

| Metoda | Cesta | Popis |
| --- | --- | --- |
| POST | `/auth/login` | e-mail a heslo. Při MFA vrátí stav `mfa_required` |
| POST | `/auth/mfa/verify` | TOTP nebo obnovovací kód |
| POST | `/auth/logout` | zruší sezení |
| GET | `/auth/me` | uživatel, role, oprávnění |
| POST | `/auth/password/change` | změna hesla, zruší ostatní sezení |
| POST | `/auth/password/reset-request`, `/auth/password/reset-confirm` | reset přes jednorázový token |
| POST | `/auth/invitations/accept` | přijetí pozvánky |
| POST | `/auth/mfa/setup`, `/auth/mfa/enable`, `/auth/mfa/disable` | správa TOTP (`disable` není dostupné pro admin) |

### Člen (`member`)

Data jsou vždy omezená na období členství ([security.md](security.md), [database-design.md](database-design.md)).

| Metoda | Cesta | Popis |
| --- | --- | --- |
| GET | `/me/apartments` | byty a vlastní období členství |
| GET | `/me/apartments/{id}/meters` | měřidla v bytě během členství |
| GET | `/me/apartments/{id}/consumption?granularity=month\|year&from&to&medium` | spotřeba omezená na členství |
| GET | `/me/apartments/{id}/current` | aktuální kumulativní stav měřidel, označený jako celkový stav počítadla, ne jako osobní spotřeba (schválené R15) |
| GET | `/me/meters/{id}/readings?from&to` | odečty efektivního zdroje uvnitř členství |
| GET | `/me/exports/consumption.csv`, `/me/exports/consumption.pdf` | export vlastních dat |

### Administrátor (`admin`)

| Metoda | Cesta | Popis |
| --- | --- | --- |
| CRUD | `/admin/buildings`, `/admin/apartments`, `/admin/users` | kmenová data. Mazání je soft delete, uživatel se nemaže (viz `anonymize`) |
| GET | `/admin/apartments/{id}/history` | časová osa bytu: členství, instalace, výměny, zdroje |
| GET, POST, PATCH | `/admin/apartments/{id}/members` | přiřazení a ukončení členství (`valid_from`, `valid_to`) |
| POST | `/admin/users/{id}/invite`, `/admin/users/{id}/disable`, `/admin/users/{id}/mfa-reset`, `/admin/users/{id}/anonymize` | správa účtu |
| CRUD | `/admin/meters` | měřidla. Založení vyžaduje počáteční zdroj odečtů |
| GET, POST | `/admin/meters/{id}/installations` | instalace, výměna, odebrání |
| GET, POST | `/admin/meters/{id}/source-assignments` | historie a změna preferovaného zdroje |
| PUT | `/admin/meters/{id}/key` | zápis klíče AES. Hodnota se nikdy nevrací |
| CRUD | `/admin/devices` | zařízení. Údaje se zobrazí jen při založení. `id` se nemění. Výměna SIM není nové zařízení |
| GET, POST | `/admin/devices/{id}/external-ids` | historie IMSI, IMEI a dalších identifikátorů. Uzavření staré hodnoty a vložení nové |
| GET, POST | `/admin/devices/{id}/capabilities` | zjištěné nebo zadané schopnosti transportu a payloadu |
| GET, POST | `/admin/devices/{id}/placements` | historie umístění |
| GET | `/admin/devices/{id}/firmware` | historie firmware |
| POST | `/admin/devices/{id}/revoke`, `/admin/devices/{id}/rotate-credentials` | odvolání a rotace |
| GET, PUT | `/admin/devices/{id}/config` | whitelist, intervaly, discovery, `replay_since` |
| GET | `/admin/devices/{id}/events` | provozní události |
| GET | `/admin/telegrams`, `/admin/telegrams/{id}` | telegramy a jejich příjmy |
| GET | `/admin/ingest/receipts`, `/admin/ingest/payloads/{id}` | příjmy a původní obálka |
| GET | `/admin/ingest/rejections` | odmítnuté obálky |
| GET | `/admin/ingest/fragments` | neúplné, kompletní a odmítnuté sady fragmentů |
| GET | `/admin/decoded-observations` | dekódované hodnoty dodavatelů |
| GET | `/admin/unknown-meters` | neznámá zachycená měřidla (jen počty) |
| GET | `/admin/readings` | odečty všech streamů s filtry |
| POST | `/admin/readings/manual` | ruční odečet s důvodem |
| POST | `/admin/readings/{id}/corrections` | oprava s povinným důvodem |
| GET | `/admin/anomalies` | věrohodnost, replay, konflikty, nepotvrzené přechody zdroje |
| GET | `/admin/audit-logs` | audit s filtry |
| GET | `/admin/system/backup-status` | stav záloh ze souborů `state/` (mount jen pro čtení) |
| GET | `/admin/exports/*` | exporty CSV a PDF |

### Ingest a systém

| Metoda | Cesta | Popis |
| --- | --- | --- |
| POST | `/ingest/telegrams` | raw dávka, token zařízení |
| POST | `/ingest/readings` | decoded dávka, token zařízení |
| POST | `/ingest/events` | události |
| POST | `/ingest/heartbeat` | stav |
| GET | `/healthz`, `/readyz` | liveness a readiness, bez dat |

Cesty výše jsou kontrakt vlastního ESP a ručního importu přes administraci. Formát ACRIOS, až bude známý, dostane vlastní cestu nebo topic a zapíše stejné tabulky. Samostatná evidence odečtů pro tu cestu nevznikne. Platform API není příchozí HTTP.

## Data na disku

`/docker-data` musí být mountpoint Incus disku. Skript ho nevytváří na kořenovém souborovém systému (stejně jako reference).

| Účel | Cesta |
| --- | --- |
| Git checkout | `/incus-dir/git/Infrastructure-sjv` (konvence reference, potvrdit) |
| Stack, runtime, `.env` | `/docker-data/stacks/infrastructure-sjv` |
| PostgreSQL | `/docker-data/infrastructure-sjv/postgresql` |
| Mosquitto data a certifikáty | `/docker-data/infrastructure-sjv/mosquitto/{data,certs}` |
| Traefik | `/docker-data/infrastructure-sjv/traefik/{acme,logs,users,crowdsec,plugins}` |
| CrowdSec | `/docker-data/infrastructure-sjv/crowdsec/data` |
| Hlavní klíč aplikace (KEK) | `/docker-data/infrastructure-sjv/secrets/app-kek` |
| Stav skriptů | `/docker-data/infrastructure-sjv/state/` |
| Lokální zálohy | `/docker-data/backups/infrastructure-sjv/{pgbackrest,dumps,files}` |

## Image a verze

- Žádný tag `latest`. Externí image mají v `.env.example` přesný tag a digest a `check-env.sh` odmítne neúplný tag.
- Lokální image se staví při `deploy.sh`. Base image je zafixovaná přes tag a digest, závislosti přes `uv.lock` a `package-lock.json`. Tag lokálního image je `infrastructure-sjv/<služba>:<git-commit>`. Commit se zapíše do `state/deployed-commit`.
- Výchozí verze podle existujících stacků: PostgreSQL `18.6`, Mosquitto `2.1.2`, wmbusmeters `release-3.0.0`. Traefik, CrowdSec a bouncer plugin jsou zafixované v `.env.example`: Traefik `v3.7.17`, CrowdSec `v1.8.2`, plugin `v1.8.1`. Řada 3.6 už nemá bezpečnostní podporu. Tag `v3.7.18` k 9. 11. 2026 nebyl vydaný.
- Verze Pythonu, Node, pgBackRest, restic a rest-server se ověří a zafixují ve fázi 1. Podmínka: pgBackRest s podporou PostgreSQL 18.

## Skripty

Pořadí ručních kroků:

`init.sh` → `update-env.sh` → doplnit `set_` → `create-dashboard-user.sh` → `check-env.sh` → `deploy.sh` → `post-deploy.sh`

`create-admin.sh` přibude s backendem. `reload.sh` zopakuje `deploy.sh` a sítě nemaže. `deploy.sh --render-only` jen vykreslí runtime a Docker nezavolá.

`deploy.sh` v etapě B1b dělá v tomto pořadí:

1. ověří `.env` dřív, než něco zapíše,
2. připraví adresáře a zkopíruje soubory bez tajemství,
3. vykreslí konfiguraci Traefiku,
4. mimo testovací režim založí čtyři sítě a spustí jen `traefik` a `crowdsec`,
5. nainstaluje kolekce CrowdSec, pokud už nejsou.

Databáze, migrace a další služby se do tohoto pořadí doplní ve svých etapách. `--remove-orphans` se nepoužívá. Dockge se nekontroluje.

## Plánované úlohy (systemd timers)

Unit soubory budou v `configs/systemd/` a instaluje je `init.sh`. Každý skript drží `flock` a zapisuje stav do `state/<úloha>.json`.

| Timer | Interval | Skript | Zámek |
| --- | --- | --- | --- |
| `sjv-backup.timer` | denně (full v neděli, jinak diff) | `backup.sh` včetně snapshotu `daily` | `backup.lock`, při expire `repo.lock` exkluzivně |
| `sjv-backup-remote.timer` | každých 5 min | `backup-remote.sh --wal` | `remote.lock`, `repo.lock` sdíleně |
| `sjv-backup-verify.timer` | týdně | `backup-verify.sh` | `verify.lock` |
| `sjv-restore-test.timer` | měsíčně | `restore-test.sh --source remote` | `restore-test.lock` |
| `sjv-backup-status.timer` | každých 5 min | `backup-status.sh --alert` | žádný |
| `sjv-cert-sync.timer` | každých 6 h | `cert-sync.sh` | `cert.lock` |
| `sjv-maintenance.timer` | denně | `maintenance.sh` | `maintenance.lock` |

Spolupráci zámků mezi zálohou a vzdálenou kopií popisuje [backup-strategy.md](backup-strategy.md).

Kontinuální práce (dekódovací fronta, timeout úplnosti fragmentů, offline detekce, odesílání e-mailů z fronty `notifications`) běží ve `sjv-worker`. Timeout fragmentů se uplatní, až bude zapnutý koncový bod, který fragmenty skutečně posílá.

## Struktura repozitáře

```text
Infrastructure-sjv/
├── README.md  .env.example  .gitignore  compose.yml
├── compose/   00-networks.yml 10-traefik.yml 15-traefik-admin-port.yml 20-crowdsec.yml
│              30-postgresql.yml 40-mosquitto.yml 50-backend.yml 55-collector.yml
│              60-worker.yml 70-web.yml
├── configs/   traefik/ crowdsec/ mosquitto/ postgres/ systemd/
├── app/       backend/ collector/ frontend/
├── scripts/   config.sh init.sh update-env.sh check-env.sh deploy.sh post-deploy.sh
│              upgrade.sh reload.sh test.sh shellcheck.sh create-dashboard-user.sh
│              create-admin.sh cert-sync.sh maintenance.sh
│              backup.sh backup-verify.sh backup-remote.sh backup-status.sh
│              restore.sh restore-test.sh
│              lib/{logging.sh,common.sh,env/,deploy/,backup/,crowdsec/,tests/}
└── docs/      architecture.md database-design.md data-ingestion.md security.md
               backup-strategy.md external-changes.md firmware-design.md
               implementation-plan.md decisions.md
               (operations.md a checks.md vzniknou při implementaci)
```

Umístění firmware (`app/firmware/` nebo samostatný repozitář) se rozhodne při schválení jeho implementace.
