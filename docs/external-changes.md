# Změny mimo repozitář

Tento repozitář nic z níže uvedeného neprovádí. Každá změna se dělá v příslušném projektu, nebo ji ručně provede Gregor, až po samostatném schválení. Úryvky konfigurace jsou návrh a před použitím se musí ověřit proti skutečnému stavu.

Stav všech položek: **navrženo, neschváleno**.

## Přehled

| # | Systém | Změna | Potřeba pro |
| --- | --- | --- | --- |
| E1 | VPS (Incus) | Kontejner `sjv-monitoring` na `10.10.10.20` | vše |
| E2 | DNS | `SJV_DOMAIN`, volitelně jiné `MQTT_HOSTNAME` | web, ACME, MQTT |
| E3 | VPS (NixOS, HAProxy) | Routy pro `SJV_DOMAIN` na 80 a 443 | web, ACME, HTTPS ingest |
| E4 | VPS (NixOS, nftables) | DNAT TCP 8883 do kontejneru `sjv` | MQTT |
| E5 | MikroTik doma | DNAT z WireGuardu na `rest-server`, vypnutá pravidla pro obnovovací instanci | vzdálené zálohy, obnova |
| E6 | domaPcServer | domácí `rest-server`, obnovovací instance, firewall, síťové propojení, správa vzdáleného restic repozitáře, `forget` a `prune`, kontrola a monitoring vzdálené restic kopie | vzdálené zálohy, obnova |
| E7 | SMTP | Účet pro odesílání | alarmy, pozvánky |

## E1: Incus kontejner na VPS

Úložiště Incus na VPS je typu `dir`, síť `incusbr0` je `10.10.10.0/24`.

Aktuální kontejner je `sjv-monitoring` na `10.10.10.20`. Tento repozitář ho nezakládá znovu. Záznam vzniku, ručně a mimo tento repozitář:

```bash
incus launch images:debian/13 sjv-monitoring \
  -c security.nesting=true \
  -c limits.cpu=<CPU> -c limits.memory=<RAM>
incus config device override sjv-monitoring eth0 ipv4.address=10.10.10.20
incus storage volume create default sjv-data
incus config device add sjv-monitoring docker-data disk pool=default source=sjv-data path=/docker-data
```

Ověřit:

- adresu `10.10.10.20` (`incus list`). Obsazené jsou nejméně `.10`, `.11`, `.12`, `.20` a `.100`,
- volné místo a výkon VPS. Hodnoty `<CPU>` a `<RAM>` se stanoví až podle volné kapacity VPS a měření zátěže ve fázi 4,
- zda Docker uvnitř kontejneru potřebuje kromě `security.nesting` ještě další nastavení (`security.syscalls.intercept.*`). Ověří se na testovacím kontejneru.

V kontejneru: Docker Engine a Compose v2 (zafixovaná verze), `rsync`, `jq`, `openssl`, `git`. Projekt je neinstaluje, stejně jako reference.

Rollback: `incus stop sjv-monitoring && incus delete sjv-monitoring` po ověření, že data nejsou potřeba.

## E2: DNS

Jména se do tohoto repozitáře nezapisují. Patří do runtime `.env`.

- `SJV_DOMAIN` A → veřejná IPv4 VPS.
- Volitelně jiné `MQTT_HOSTNAME` A → stejná IP. Doporučené kvůli oddělení MQTT, viz [architecture.md](architecture.md).
- Ověřit u DNS účtu, zda lze založit druhé jméno a zda ho je nutné pravidelně obnovovat.

## E3: HAProxy na VPS (`modules/server/haproxy-netcupVPSServer.nix`)

Dnes `default_backend nextcloud_http/https` posílá neznámá jména na Nextcloud Gregora. Návrh doplnění:

```text
# frontend http
use_backend sjv_http   if { hdr(host) -i <SJV_DOMAIN> }
use_backend sjv_http   if { hdr(host) -i <MQTT_HOSTNAME> }   # jen kvůli ACME, když se jméno liší

backend sjv_http
    mode http
    server sjv 10.10.10.20:80 send-proxy-v2

# frontend https
use_backend sjv_https  if { req_ssl_sni -i <SJV_DOMAIN> }

backend sjv_https
    mode tcp
    server sjv 10.10.10.20:443 send-proxy-v2
```

- Traefik v kontejneru `sjv-monitoring` přijme PROXY protocol jen od zdrojové adresy HAProxy jako `/32`. V `.env` je očekávaná adresa `10.10.10.1/32`. Před spolehnutím se na ni se potvrdí skutečným provozem.
- Volitelně později: záložní MQTT přes 443 podle SNI `<MQTT_HOSTNAME>` pro sítě, které blokují 8883. Vyžaduje ověřit podporu PROXY protocolu v Mosquittu, jinak broker uvidí jako klienta jen HAProxy.
- Rollback: odebrat řádky a `nixos-rebuild switch`.

## E4: DNAT 8883 (`modules/server/firewall/dnat-netcupVPSServer.nix`)

Do seznamu `public`:

```nix
{
  port = 8883;
  target = "10.10.10.20:8883";
}
```

- Generátor vytvoří `iifname "ens3" tcp dport 8883 dnat ip to 10.10.10.20:8883`. Forward chain už má `oifname "incusbr0" accept`, input chain se nemění.
- DNAT zachová skutečnou IP klienta. Mosquitto ji vidí a loguje.
- Rollback: odebrat položku a `nixos-rebuild switch`.

## E5: MikroTik doma

Domácí WireGuard je `10.100.101.0/24`. Pravidlo povolí jen adresu VPS v této síti a jen vybraný port. `<VPS-WG-IP>` a `<MIKROTIK-WG-IP>` se opíší z běžícího tunelu. Návrh podle vzoru Metabase:

```text
/ip firewall nat add chain=dstnat in-interface=<wg-rozhraní> src-address=<VPS-WG-IP> \
    dst-address=<MIKROTIK-WG-IP> protocol=tcp dst-port=<P> \
    action=dst-nat to-addresses=<LAN-IP-domaPcServer> to-ports=8000 comment="sjv restic"
/ip firewall filter add chain=forward in-interface=<wg-rozhraní> src-address=<VPS-WG-IP> \
    dst-address=<LAN-IP-domaPcServer> protocol=tcp dst-port=8000 action=accept comment="sjv restic"
```

- Potřebné údaje: název rozhraní, `<VPS-WG-IP>`, `<MIKROTIK-WG-IP>`, LAN IP `domaPcServer`, port `<P>`.
- Povolit jen zdroj `<VPS-WG-IP>` a jen tento port. Celá VPN síť se nepovoluje.
- Pro obnovovací instanci `rest-server-sjv-recovery` se připraví stejný pár pravidel s portem `<P2>`, komentářem `sjv restic recovery` a ve stavu `disabled=yes`. Zapíná se jen při obnově, se zdrojovou adresou nového hostitele ([backup-strategy.md](backup-strategy.md#úplná-obnova-na-novém-vps)).
- Rollback: smazat pravidla podle komentáře.

## E6: domaPcServer

### rest-server (NixOS, orientačně, názvy voleb ověřit podle verze nixpkgs)

```nix
services.restic.server = {
  enable = true;
  appendOnly = true;
  privateRepos = true;
  dataDir = "<cesta>/infrastructure-sjv";
  listenAddress = "<LAN-IP>:8000";
  extraFlags = [ "--tls" "--tls-cert" "<cert>" "--tls-key" "<key>" "--htpasswd-file" "<htpasswd>" ];
};
```

- `dataDir` je konfigurační cesta repozitáře na domácím serveru. Souborový systém se nepředepisuje.
- Port 8000 je výchozí port `rest-server`. Jiný port lze zvolit podle obsazenosti na `domaPcServer`.
- Uživatel `infrastructure-sjv` má přístup jen k repozitáři `infrastructure-sjv/`. S `--private-repos` musí jméno uživatele odpovídat první části cesty.
- Tento repozitář soubor `.htpasswd` REST serveru nezakládá ani nemění. Hostitel `restic-sjv` v něm není. `create-dashboard-user.sh` zapisuje jen dashboard Traefiku. Klient čte heslo z `RESTIC_REST_PASSWORD` v runtime `.env`.
- Vlastní certifikát pro TLS. Jeho otisk se pinuje na VPS přes `--cacert`. Na LAN úseku za MikroTikem by jinak heslo `rest-server` šlo nešifrovaně.
- Firewall `domaPcServer`: port 8000 jen ze zdroje, který po DNAT na MikroTiku přichází (`<VPS-WG-IP>` nebo adresa MikroTiku podle NAT). Ověří se pozorováním.

### Obnovovací instance `rest-server-sjv-recovery`

Účel a pravidla popisuje [backup-strategy.md](backup-strategy.md#append-only-a-oddělení-oprávnění).

- Druhý proces `rest-server` se stejným `--path`, s `--append-only`, **bez** `--private-repos`, s vlastním htpasswd (jen uživatel `sjv-recovery`), vlastním certifikátem a portem `<P2>`.
- Modul `services.restic.server` v NixOS spravuje jen jednu instanci. Druhá proto bude vlastní systemd unit (`wantedBy` prázdné, takže se sama nespustí). Konkrétní zápis se připraví po ověření verze nixpkgs na `domaPcServer`.
- Firewall: port `<P2>` jen ze zdroje po DNAT, stejně jako u hlavní instance.
- Uživatel `sjv-recovery`, jeho heslo, tato instance a klíče `recovery` a `maintenance` jsou NEIMPLEMENTOVANÉ. Skripty repozitáře je nezakládají. Návrh ukládá heslo `sjv-recovery` jen do obnovovací sady a funkčnost ověří při prvním DR testu.

### Prune a kontrola

- Timer `sjv-restic-prune` (týdně) s klíčem `maintenance` přímo na lokální cestě, zvlášť pro každý tag:

  ```text
  restic forget --tag daily --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --keep-yearly 3
  restic forget --tag wal   --keep-within 48h
  restic prune
  ```

- Timer `sjv-restic-watch` (15 min): alarm, když nejnovější snapshot `wal` je starší než 20 minut, `daily` starší než 26 hodin, nebo objem neobvykle naroste.
- Návrh klíčů restic: `vps` (zapisuje VPS), `recovery` (jen obnovovací sada), `maintenance` (jen domácí server). Jsou NEIMPLEMENTOVANÉ. `restic init` v tomto repozitáři založí jeden nepojmenovaný klíč ze souboru `restic-key-password`.

Rollback: vypnout služby. Data restic repozitáře se nemažou bez samostatného rozhodnutí.

## E7: SMTP

Účet pro odesílání alarmů, pozvánek a resetu hesla. Nesmí záviset na službách VPS, třeba na poštovním serveru, který by běžel na stejném hostiteli. Údaje patří do runtime `.env`.

## Údaje, které potřebuji pro tyto změny

- Kapacita VPS (`<CPU>`, `<RAM>`, disk). Adresa kontejneru je `10.10.10.20`.
- Možnost založit druhé veřejné jméno v DNS účtu.
- Název WireGuard rozhraní na MikroTiku doma, LAN IP `domaPcServer` a porty `<P>` a `<P2>`.
- Verze nixpkgs na `domaPcServer` (názvy voleb `services.restic.server`).
- SMTP poskytovatel.
