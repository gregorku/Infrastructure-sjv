# Změny mimo repozitář

Tento repozitář nic z níže uvedeného neprovádí. Každá změna se dělá v příslušném projektu, nebo ji ručně provede Gregor, až po samostatném schválení. Úryvky konfigurace jsou návrh a před použitím se musí ověřit proti skutečnému stavu.

Stav všech položek: **navrženo, neschváleno**.

## Přehled

| # | Systém | Změna | Potřeba pro |
| --- | --- | --- | --- |
| E1 | VPS (Incus) | Nový kontejner `sjv` | vše |
| E2 | DNS (`serveftp.org`) | `sjv.serveftp.org`, volitelně `sjv-mqtt.serveftp.org` | web, ACME, MQTT |
| E3 | VPS (NixOS, HAProxy) | Routy pro `sjv.serveftp.org` na 80 a 443 | web, ACME, HTTPS ingest |
| E4 | VPS (NixOS, nftables) | DNAT TCP 8883 do kontejneru `sjv` | MQTT |
| E5 | MikroTik doma | DNAT z WireGuardu na `rest-server`, vypnutá pravidla pro obnovovací instanci | vzdálené zálohy, obnova |
| E6 | domaPcServer | ZFS dataset, `rest-server`, obnovovací instance, firewall, snapshoty, prune, kontrola | vzdálené zálohy, obnova |
| E7 | SMTP | Účet pro odesílání | alarmy, pozvánky |

## E1: Incus kontejner na VPS

Úložiště Incus na VPS je typu `dir`, síť `incusbr0` je `10.10.10.0/24`.

Návrh (ručně, ne přes tento repozitář):

```bash
incus launch images:debian/13 sjv \
  -c security.nesting=true \
  -c limits.cpu=<CPU> -c limits.memory=<RAM>
incus config device override sjv eth0 ipv4.address=10.10.10.<X>
incus storage volume create default sjv-data
incus config device add sjv docker-data disk pool=default source=sjv-data path=/docker-data
```

Ověřit:

- volnou adresu `<X>` (`incus list`). Obsazené jsou nejméně `.10`, `.11`, `.12` a `.100`,
- volné místo a výkon VPS. Hodnoty `<CPU>` a `<RAM>` se stanoví až podle volné kapacity VPS a měření zátěže ve fázi 4,
- zda Docker uvnitř kontejneru potřebuje kromě `security.nesting` ještě další nastavení (`security.syscalls.intercept.*`). Ověří se na testovacím kontejneru.

V kontejneru: Docker Engine a Compose v2 (zafixovaná verze), `rsync`, `jq`, `openssl`, `git`. Projekt je neinstaluje, stejně jako reference.

Rollback: `incus stop sjv && incus delete sjv` po ověření, že data nejsou potřeba.

## E2: DNS

- `sjv.serveftp.org` A → veřejná IPv4 VPS.
- Volitelně `sjv-mqtt.serveftp.org` A → stejná IP. Doporučené kvůli oddělení MQTT, viz [architecture.md](architecture.md).
- Ověřit: `serveftp.org` vypadá jako sdílená DDNS doména No-IP. Je potřeba zjistit, zda lze založit další jméno a zda na účtu nejde o funkci, kterou je nutné pravidelně obnovovat (jinak jméno vyprší).

## E3: HAProxy na VPS (`modules/server/haproxy-netcupVPSServer.nix`)

Dnes `default_backend nextcloud_http/https` posílá neznámá jména na Nextcloud Gregora. Návrh doplnění:

```text
# frontend http
use_backend sjv_http   if { hdr(host) -i sjv.serveftp.org }
use_backend sjv_http   if { hdr(host) -i sjv-mqtt.serveftp.org }   # jen kvůli ACME, pokud jméno vznikne

backend sjv_http
    mode http
    server sjv 10.10.10.<X>:80 send-proxy-v2

# frontend https
use_backend sjv_https  if { req_ssl_sni -i sjv.serveftp.org }

backend sjv_https
    mode tcp
    server sjv 10.10.10.<X>:443 send-proxy-v2
```

- Traefik v kontejneru `sjv` přijme PROXY protocol jen od zdrojové adresy HAProxy jako `/32`. Očekávaná adresa je `10.10.10.1` a ověří se pozorováním v režimu `local`, stejně jako v referenci.
- Volitelně později: záložní MQTT přes 443 podle SNI `sjv-mqtt.serveftp.org` pro sítě, které blokují 8883. Vyžaduje ověřit podporu PROXY protocolu v Mosquittu, jinak broker uvidí jako klienta jen HAProxy.
- Rollback: odebrat řádky a `nixos-rebuild switch`.

## E4: DNAT 8883 (`modules/server/firewall/dnat-netcupVPSServer.nix`)

Do seznamu `public`:

```nix
{
  port = 8883;
  target = "10.10.10.<X>:8883";
}
```

- Generátor vytvoří `iifname "ens3" tcp dport 8883 dnat ip to 10.10.10.<X>:8883`. Forward chain už má `oifname "incusbr0" accept`, input chain se nemění.
- DNAT zachová skutečnou IP klienta. Mosquitto ji vidí a loguje.
- Rollback: odebrat položku a `nixos-rebuild switch`.

## E5: MikroTik doma

Provoz z kontejneru `sjv` do `wg1` je na VPS maskovaný na `10.100.100.1`. VPS dosáhne jen na `10.100.100.100` (MikroTik). Návrh podle vzoru Metabase:

```text
/ip firewall nat add chain=dstnat in-interface=<wg1-rozhraní> src-address=10.100.100.1 \
    dst-address=10.100.100.100 protocol=tcp dst-port=<P> \
    action=dst-nat to-addresses=<LAN-IP-domaPcServer> to-ports=8000 comment="sjv restic"
/ip firewall filter add chain=forward in-interface=<wg1-rozhraní> src-address=10.100.100.1 \
    dst-address=<LAN-IP-domaPcServer> protocol=tcp dst-port=8000 action=accept comment="sjv restic"
```

- Potřebné údaje: název rozhraní, LAN IP `domaPcServer`, port `<P>`.
- Povolit jen zdroj `10.100.100.1` a jen tento port. Celá VPN síť se nepovoluje.
- Pro obnovovací instanci `rest-server-sjv-recovery` se připraví stejný pár pravidel s portem `<P2>`, komentářem `sjv restic recovery` a ve stavu `disabled=yes`. Zapíná se jen při obnově, se zdrojovou adresou nového hostitele ([backup-strategy.md](backup-strategy.md#úplná-obnova-na-novém-vps)).
- Rollback: smazat pravidla podle komentáře.

## E6: domaPcServer

**Předpoklad:** výsledek ověření ZFS z [backup-strategy.md](backup-strategy.md). Dokud není potvrzený pool, nic se nezakládá.

### Dataset

```bash
zfs create -o compression=zstd -o atime=off -o recordsize=1M \
  -o quota=<Q> <pool>/backups/infrastructure-sjv
```

### rest-server (NixOS, orientačně, názvy voleb ověřit podle verze nixpkgs)

```nix
services.restic.server = {
  enable = true;
  appendOnly = true;
  privateRepos = true;
  dataDir = "/<mount>/backups/infrastructure-sjv";
  listenAddress = "<LAN-IP>:8000";
  extraFlags = [ "--tls" "--tls-cert" "<cert>" "--tls-key" "<key>" "--htpasswd-file" "<htpasswd>" ];
};
```

- Port 8000 je výchozí port `rest-server`. Jiný port lze zvolit podle obsazenosti na `domaPcServer`.
- Uživatel `infrastructure-sjv` má přístup jen k repozitáři `infrastructure-sjv/`. S `--private-repos` musí jméno uživatele odpovídat první části cesty.
- Vlastní certifikát pro TLS. Jeho otisk se pinuje na VPS přes `--cacert`. Na LAN úseku za MikroTikem by jinak heslo `rest-server` šlo nešifrovaně.
- Firewall `domaPcServer`: port 8000 jen ze zdroje, který po DNAT na MikroTiku přichází (`10.100.100.1` nebo adresa MikroTiku podle NAT). Ověří se pozorováním.

### Obnovovací instance `rest-server-sjv-recovery`

Účel a pravidla popisuje [backup-strategy.md](backup-strategy.md#append-only-a-oddělení-oprávnění).

- Druhý proces `rest-server` se stejným `--path`, s `--append-only`, **bez** `--private-repos`, s vlastním htpasswd (jen uživatel `sjv-recovery`), vlastním certifikátem a portem `<P2>`.
- Modul `services.restic.server` v NixOS spravuje jen jednu instanci. Druhá proto bude vlastní systemd unit (`wantedBy` prázdné, takže se sama nespustí). Konkrétní zápis se připraví po ověření verze nixpkgs na `domaPcServer`.
- Firewall: port `<P2>` jen ze zdroje po DNAT, stejně jako u hlavní instance.
- Uživatel `sjv-recovery` a jeho heslo se založí předem a heslo se uloží jen do obnovovací sady. Funkčnost se ověří při prvním DR testu.

### ZFS snapshoty

Návrh: sanoid jen pro tento dataset, hodinové 48, denní 30, měsíční 6 (k rozhodnutí). VPS k nim nemá přístup.

### Prune a kontrola

- Timer `sjv-restic-prune` (týdně) s klíčem `maintenance` přímo na lokální cestě, zvlášť pro každý tag:

  ```text
  restic forget --tag daily --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --keep-yearly 3
  restic forget --tag wal   --keep-within 48h
  restic prune
  ```

- Timer `sjv-restic-watch` (15 min): alarm, když nejnovější snapshot `wal` je starší než 20 minut, `daily` starší než 26 hodin, nebo objem neobvykle naroste.
- Klíče restic: `vps` (zapisuje VPS), `recovery` (jen obnovovací sada), `maintenance` (jen domácí server).
- Doporučení mimo projekt: zapnout pravidelný scrub poolu.

Rollback: vypnout služby. Data datasetu se nemažou bez samostatného rozhodnutí.

## E7: SMTP

Účet pro odesílání alarmů, pozvánek a resetu hesla. Nesmí záviset na službách VPS, třeba na poštovním serveru, který by běžel na stejném hostiteli. Údaje patří do runtime `.env`.

## Údaje, které potřebuji pro tyto změny

- Volná IP v `incusbr0` a kapacita VPS (`<CPU>`, `<RAM>`, disk).
- Možnost založit jména na `serveftp.org`.
- Název WireGuard rozhraní na MikroTiku doma, LAN IP `domaPcServer` a porty `<P>` a `<P2>`.
- Výsledek ověření ZFS a kvóta `<Q>`.
- Verze nixpkgs na `domaPcServer` (názvy voleb `services.restic.server`).
- SMTP poskytovatel.
