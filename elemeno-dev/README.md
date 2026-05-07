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
- `elemeno-dev/runtime/cloudflared/credentials.json` — produced by [Cloudflare Tunnel setup](#cloudflare-tunnel-setup) below on a first-time setup; otherwise reuse the existing encrypted copy

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

## Cloudflare Tunnel setup

One-time, when first creating the tunnel for this host (or rotating its secret). After this, `credentials.json.enc` lives in the repo and the playbook reuses it on every deploy.

This setup uses the locally-managed tunnel mode — config (`config.yml`) lives in this repo, secrets (`credentials.json`) are SOPS-encrypted alongside it. Sourced from the [Cloudflare Tunnel API docs](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel-api/).

### 1. Prepare an API token and IDs

Create an API token at Cloudflare → My Profile → API Tokens with these permissions:

| Type    | Item              | Permission |
|---------|-------------------|------------|
| Account | Cloudflare Tunnel | Edit       |
| Zone    | DNS               | Edit (scoped to `resumer.io`) |

Then export the token plus your account ID and zone ID into your shell:

```bash
export CLOUDFLARE_API_TOKEN='<token>'
export ACCOUNT_ID='<account-id>'   # Cloudflare dashboard right sidebar
export ZONE_ID='<zone-id>'         # resumer.io DNS page right sidebar
```

### 2. Create the tunnel

`config_src: "local"` is the important bit — it tells Cloudflare this tunnel is configured by local files, not by the dashboard.

```bash
curl "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel" \
  --request POST \
  --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  --json '{
    "name": "elemeno-dev-tunnel",
    "config_src": "local"
  }' | jq .
```

The response includes a `result.credentials_file` object — that is exactly what `cloudflared` expects on disk (with capitalised keys: `AccountTag`, `TunnelID`, `TunnelSecret`). Capture it:

```bash
TUNNEL_RESPONSE="$(curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel" \
  --request POST \
  --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  --json '{"name":"elemeno-dev-tunnel","config_src":"local"}')"

echo "$TUNNEL_RESPONSE" \
  | jq '.result.credentials_file' \
  > elemeno-dev/runtime/cloudflared/credentials.json

TUNNEL_ID="$(echo "$TUNNEL_RESPONSE" | jq -r '.result.id')"
echo "Tunnel ID: $TUNNEL_ID"
```

### 3. Point `config.yml` at the new tunnel

Replace the `tunnel:` value in `elemeno-dev/runtime/cloudflared/config.yml` with `$TUNNEL_ID` from above. The rest of `config.yml` (ingress rules, hostname, target service) stays as-is.

### 4. Create the DNS record

CNAME `dev.resumer.io` to `<TUNNEL_ID>.cfargotunnel.com` so Cloudflare's edge knows where to route the hostname:

```bash
curl "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  --request POST \
  --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  --json "$(jq -n --arg id "$TUNNEL_ID" '{
    type: "CNAME",
    proxied: true,
    name: "dev.resumer.io",
    content: ($id + ".cfargotunnel.com")
  }')"
```

If the record already exists from a previous tunnel, this returns an error; either delete the old record first (`GET /zones/$ZONE_ID/dns_records?name=dev.resumer.io` then `DELETE`) or use the dashboard to repoint it to the new tunnel ID.

CLI alternative if you prefer not to call the DNS API directly: `cloudflared tunnel login` once (browser auth) then `cloudflared tunnel route dns "$TUNNEL_ID" dev.resumer.io --overwrite-dns`.

### 5. Encrypt and clean up

The plaintext `credentials.json` is gitignored. Encrypt it for the repo and drop the plaintext copy:

```bash
./scripts/sops-env.sh . encrypt
rm -f elemeno-dev/runtime/cloudflared/credentials.json
git add elemeno-dev/runtime/cloudflared/credentials.json.enc \
        elemeno-dev/runtime/cloudflared/config.yml
git commit -m "cloudflared: rotate tunnel for elemeno-dev"
git push
```

CI will pick up the new encrypted credentials and `config.yml` on the next deploy. Verify after with `docker logs resumer-cloudflared --tail 20` — expect four `Connection ... registered` lines.

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

For DBeaver, TablePlus, pgAdmin, or local `psql`, run this single command. It opens an SSH tunnel and starts a temporary `socat` side-car container on the Docker network that bridges from the host's localhost into the `resumer-postgres` container:

```bash
ssh -L 15432:127.0.0.1:15432 alexey@elemeno-dev \
  sh -c 'docker rm -f resumer-postgres-tunnel >/dev/null 2>&1; \
         docker run --rm --name resumer-postgres-tunnel \
           --network resumer_net \
           -p 127.0.0.1:15432:5432 \
           alpine/socat \
           TCP-LISTEN:5432,fork TCP:resumer-postgres:5432'
```

The `docker rm -f` prefix is idempotent: it cleans up a stale container left over from a previous tunnel that exited abnormally (Ctrl-C, dropped SSH, etc.) where `--rm` didn't get to run.

Then connect your local client to:

- Host: `localhost`
- Port: `15432`
- Database: `resumer_app`
- User: `postgres` (superuser) or `resumer_app` (app user)
- Password: from `sops -d` above

One liner to combine the DATABSE_URL from the .env file with the password from the sops -d output:
`export DATABASE_URL=postgresql://resumer_app:$(sops -d elemeno-dev/secrets/postgres.secrets.sops.yaml | grep postgres_app_password | cut -d: -f2)@resumer-postgres:5432/resumer_app`

Press Ctrl-C in the SSH session to stop the tunnel; the side-car container is auto-removed (`--rm`). Port `15432` on both sides avoids collisions with any local Postgres on `5432`.
If not removed, can be removed with `docker rm -f resumer-postgres-tunnel`.

## Notes

- Cloudflared credentials are committed only as `credentials.json.enc`; plaintext `credentials.json` is ignored by git.
- Postgres passwords are committed only in `elemeno-dev/secrets/postgres.secrets.sops.yaml`; playbook decrypts this file on the server before applying Postgres roles.
- `docker-compose.yml` uses image tags as placeholders (`ghcr.io/resumer-io/...`); swap to your real build/publish targets.
- CI deploy over Tailscale SSH is defined in `.github/workflows/deploy-elemeno-dev.yml`.
