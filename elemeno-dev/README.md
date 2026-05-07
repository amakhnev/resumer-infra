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
  --skip-tags "import-postgres,import-generic-sqlite-db,upgrade-postgres,run-postgres-vacuum,start-group,restart-group,stop,stop-all,stop-group" \
  playbooks/elemeno-dev.yml
```

The `--skip-tags` flag matches the CI workflow and excludes maintenance flows from upstream MASH/devture roles that are gated only by tag and would otherwise run on every deploy. The list groups into:

- Postgres role maintenance: `import-postgres`, `import-generic-sqlite-db`, `upgrade-postgres`, `run-postgres-vacuum` — destructive or long-running, only run intentionally.
- `systemd_service_manager` group/stop flows: `start-group`, `restart-group`, `stop`, `stop-all`, `stop-group` — these target a specific service group (require `--extra-vars group=...`) or stop services the deploy just started.

To invoke any of them deliberately, see [Maintenance tasks](#maintenance-tasks) below.

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

### Restart, stop, or start a single service group

Targets a slice of services registered in `devture_systemd_service_manager_services_list_additional`. Each service entry has a `groups: [...]` list (e.g. `core`, `postgres`); pass one of those names as the `group` extra-var.

```bash
ansible-playbook -i inventory/dev/hosts.ini \
  --tags restart-group -e group=postgres playbooks/elemeno-dev.yml

ansible-playbook -i inventory/dev/hosts.ini \
  --tags start-group   -e group=postgres-backup playbooks/elemeno-dev.yml

ansible-playbook -i inventory/dev/hosts.ini \
  --tags stop-group    -e group=postgres-backup playbooks/elemeno-dev.yml
```

### Stop everything managed by systemd_service_manager

Stops every service registered in the list above (currently `resumer-postgres.service` and `resumer-postgres-backup.service`). Compose containers (webapp, scraper, cloudflared) are not affected — those are managed by Docker Compose, not by this role.

```bash
ansible-playbook -i inventory/dev/hosts.ini \
  --tags stop-all playbooks/elemeno-dev.yml
```

## Inspect the database

Postgres binds only to the `resumer_net` Docker network on `elemeno-dev` — there is no host-level port published. That is intentional (no Tailscale or LAN exposure of port 5432). To inspect the database, pick the option that matches your tool.

The Postgres password lives in `elemeno-dev/secrets/postgres.secrets.sops.yaml`. Read it locally with:

```bash
sops -d elemeno-dev/secrets/postgres.secrets.sops.yaml
```

Use `postgres_root_password` for superuser access (`postgres` user) or `postgres_app_password` for app-level access (`resumer_app` user).

### Quick `psql` shell on the VM

The Postgres role installs a helper at `/opt/resumer/postgres/bin/cli`. SSH in and run it:

```bash
ssh -t alexey@elemeno-dev /opt/resumer/postgres/bin/cli
```

This drops you into a `psql` prompt as the `postgres` superuser inside the container — no local Postgres tooling required, no port forwarding. Switch databases once inside with `\c resumer_app`.

For a one-off command instead of an interactive shell, use `docker exec` directly:

```bash
ssh -t alexey@elemeno-dev \
  docker exec -i resumer-postgres psql -U postgres -d resumer_app -c '\dt'
```

### Forward Postgres to your laptop for a GUI client

For DBeaver, TablePlus, pgAdmin, or local `psql`, run this single command. It opens an SSH tunnel and starts a temporary `socat` side-car container on the Docker network that bridges from the host's localhost into the `postgres` container:

```bash
ssh -L 15432:127.0.0.1:15432 alexey@elemeno-dev \
  docker run --rm --name resumer-postgres-tunnel \
    --network resumer_net \
    -p 127.0.0.1:15432:5432 \
    alpine/socat \
    TCP-LISTEN:5432,fork TCP:postgres:5432
```

Then connect your local client to:

- Host: `localhost`
- Port: `15432`
- Database: `resumer_app`
- User: `postgres` (superuser) or `resumer_app` (app user)
- Password: from `sops -d` above

Press Ctrl-C in the SSH session to stop the tunnel; the side-car container is auto-removed (`--rm`). Port `15432` on both sides avoids collisions with any local Postgres on `5432`.

## Notes

- Cloudflared credentials are committed only as `credentials.json.enc`; plaintext `credentials.json` is ignored by git.
- Postgres passwords are committed only in `elemeno-dev/secrets/postgres.secrets.sops.yaml`; playbook decrypts this file on the server before applying Postgres roles.
- `docker-compose.yml` uses image tags as placeholders (`ghcr.io/resumer-io/...`); swap to your real build/publish targets.
- CI deploy over Tailscale SSH is defined in `.github/workflows/deploy-elemeno-dev.yml`.
