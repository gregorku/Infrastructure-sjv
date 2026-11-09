# Infrastructure-sjv

Informační systém SJV na `sjv.serveftp.org`: sběr odečtů měřidel (wM-Bus), aplikace pro členy a správu, zálohy. Běží jako Docker stack v samostatném Incus kontejneru.

Stav: etapa B1 (kostra repozitáře a instalační infrastruktura). Aplikace, Docker Compose, databáze, MQTT ani zálohy zatím nejsou implementované.

## Dokumentace

| Dokument | Obsah |
| --- | --- |
| [docs/decisions.md](docs/decisions.md) | rozhodnutí R1–R16 a otevřené body |
| [docs/architecture.md](docs/architecture.md) | služby, sítě, adresáře, tok dat |
| [docs/database-design.md](docs/database-design.md) | schéma PostgreSQL a role |
| [docs/data-ingestion.md](docs/data-ingestion.md) | příjem dat z koncentrátoru a ESP |
| [docs/security.md](docs/security.md) | bezpečnostní model |
| [docs/backup-strategy.md](docs/backup-strategy.md) | zálohy a obnova |
| [docs/external-changes.md](docs/external-changes.md) | změny mimo repozitář (E1–E7) |
| [docs/firmware-design.md](docs/firmware-design.md) | návrh firmwaru ESP |
| [docs/implementation-plan.md](docs/implementation-plan.md) | fáze implementace |
| [docs/operations.md](docs/operations.md) | instalace a správa `.env` |
| [docs/checks.md](docs/checks.md) | kontroly a testy |

## Rychlý přehled

```bash
sudo ./scripts/init.sh        # adresáře a kopie .env.example do stacku
sudo ./scripts/update-env.sh  # vytvoří nebo doplní /docker-data/stacks/infrastructure-sjv/.env
sudo ./scripts/check-env.sh   # ověří .env, nic nemění
./scripts/test.sh             # offline testy, bez rootu
```

Podrobnosti jsou v [docs/operations.md](docs/operations.md).

## Pravidla repozitáře

- Runtime `.env`, klíče, certifikáty ani data nepatří do Gitu. Hlídá to `.gitignore` a `test.sh`.
- Dokumentace je česky, kód a komentáře anglicky, názvy souborů v `docs/` malými písmeny.
