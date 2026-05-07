# Homelab First Iteration (`elemeno-dev`)

This directory contains the first deployable iteration for the `elemeno-dev` Ubuntu Docker host:

- Cloudflared tunnel config stored in this repo
- PostgreSQL + Postgres backup via official Mother-of-All-Self-Hosting Ansible roles
- Docker Compose runtime for `webapp` + `scraper`
- SOPS-encrypted runtime `.env` files committed as `.enc`

## Layout

- `ansible/`: host inventory, vars, role requirements, and playbook
- `runtime/`: Docker Compose app stack and cloudflared config
- `secrets/postgres.secrets.sops.yaml`: encrypted Postgres app/root passwords
- `runtime/webapp/.env.production.local.enc`: encrypted web app env file
- `runtime/scraper/.env.enc`: encrypted scraper env file
- `runtime/cloudflared/credentials.json.enc`: encrypted cloudflared credentials

## Prerequisites

- Ansible 2.16+
- `sops` + `gpg`
- Docker Engine on the target VM
- GPG private key locally available for decryption

## Bootstrap flow

1. Install Ansible role dependencies:

```bash
cd elemeno-dev/ansible
ansible-galaxy role install -r requirements.yml
ansible-galaxy collection install -r requirements.yml
```

2. Decrypt env files in repo before first deploy:

```bash
./scripts/sops-env.sh . decrypt
```

3. Generate encrypted Postgres passwords (one-time or when rotating):

```bash
./scripts/generate-elemeno-postgres-secrets.sh
```

PowerShell:

```powershell
.\scripts\generate-elemeno-postgres-secrets.ps1
```

4. Fill in decrypted files:

- `elemeno-dev/runtime/webapp/.env.production.local`
- `elemeno-dev/runtime/scraper/.env`
- `elemeno-dev/runtime/cloudflared/credentials.json`

5. Deploy:

```bash
cd elemeno-dev/ansible
ansible-playbook \
  -i inventory/dev/hosts.ini \
  --skip-tags "import-postgres,import-generic-sqlite-db,upgrade-postgres,run-postgres-vacuum" \
  playbooks/elemeno-dev.yml
```

The `--skip-tags` flag matches the CI workflow and excludes destructive maintenance flows that the upstream Postgres role gates only by tag (so they would otherwise run on every deploy). To invoke any of them deliberately, see [Maintenance tasks](#maintenance-tasks) below.

6. Re-encrypt and keep plaintext out of git:

```bash
./scripts/sops-env.sh . encrypt
rm -f elemeno-dev/runtime/webapp/.env.production.local elemeno-dev/runtime/scraper/.env elemeno-dev/runtime/cloudflared/credentials.json
```

## Maintenance tasks

The Postgres role from MASH ships several optional flows gated only by tag. The default deploy (CI and the local command above) skips them via `--skip-tags`. Run them ad-hoc from a workstation that has SSH access to the host (Tailscale or otherwise) when needed.

The pattern is always: pass the matching `--tags`, plus any required `--extra-vars`, against the same inventory.

### Restore from a Postgres dump

Use when seeding a host from an existing SQL dump produced by `pg_dump` (or by the `postgres-backup` container).

```bash
ansible-playbook \
  -i inventory/dev/hosts.ini \
  --tags import-postgres \
  -e server_path_postgres_dump=/opt/resumer/postgres-backup/data/daily/resumer_app-YYYY-MM-DD.sql.gz \
  playbooks/elemeno-dev.yml
```

The dump path must already be reachable on the **target server**. The role detects `.sql`, `.sql.gz`, and `.sql.xz` and pipes through the matching decompressor.

Destructive: this will recreate database objects from the dump.

### Convert a SQLite database into Postgres

Use when migrating a service from SQLite to Postgres. See `tasks/import_generic_sqlite_db.yml` in the upstream role for the full set of required `--extra-vars` (database name, source SQLite path on the server, etc.).

```bash
ansible-playbook \
  -i inventory/dev/hosts.ini \
  --tags import-generic-sqlite-db \
  -e ... \
  playbooks/elemeno-dev.yml
```

Destructive into the target Postgres database.

### Major-version Postgres upgrade

Use only when intentionally moving to a newer Postgres major (e.g. 16 → 17). The role stops the running container, dumps all databases, replaces the data directory, starts the new image, and restores from the dump.

```bash
ansible-playbook \
  -i inventory/dev/hosts.ini \
  --tags upgrade-postgres \
  playbooks/elemeno-dev.yml
```

Take a manual backup first. Plan downtime; the host's webapp/scraper containers will lose their database mid-task.

### Run VACUUM

Use when bloat is suspected or after a large delete. Not destructive but can lock tables and run for a long time.

```bash
ansible-playbook \
  -i inventory/dev/hosts.ini \
  --tags run-postgres-vacuum \
  playbooks/elemeno-dev.yml
```

By default vacuums the databases listed in `postgres_managed_databases` (so `resumer_app`). Override with `postgres_vacuum_default_databases_list` or `postgres_vacuum_query` per the role's defaults.

## Notes

- Cloudflared credentials are committed only as `credentials.json.enc`; plaintext `credentials.json` is ignored by git.
- Postgres passwords are committed only in `elemeno-dev/secrets/postgres.secrets.sops.yaml`; playbook decrypts this file on the server before applying Postgres roles.
- `docker-compose.yml` uses image tags as placeholders (`ghcr.io/resumer-io/...`); swap to your real build/publish targets.
- CI deploy over Tailscale SSH is defined in `.github/workflows/deploy-elemeno-dev.yml`.
