# Homelab Build - Iteration 1 (`elemeno-dev`)

This iteration operationalizes the first infra slice for `resumer-infra` on the existing Ubuntu + Docker VM.

## What this iteration includes

- Cloudflared tunnel config managed in-repo (`elemeno-dev/runtime/cloudflared/config.yml`)
- PostgreSQL install via `mother-of-all-self-hosting/ansible-role-postgres`
- Postgres backups via `mother-of-all-self-hosting/ansible-role-postgres-backup`
- Docker Compose runtime for:
  - `webapp`
  - `scraper`
  - `cloudflared`
- SOPS-based encrypted dotenv workflow with recursive scripts

## Sources

- [ansible-role-postgres](https://github.com/mother-of-all-self-hosting/ansible-role-postgres)
- [ansible-role-postgres-backup](https://github.com/mother-of-all-self-hosting/ansible-role-postgres-backup)

## 1) Configure inventory and host vars

Edit:

- `elemeno-dev/ansible/inventory/dev/hosts.ini`
- `elemeno-dev/ansible/inventory/dev/group_vars/elemeno-dev.yml`

Minimum required updates:

- Docker image tags (`resumer_webapp_image`, `resumer_scraper_image`)
- Host/IP if changed

Postgres passwords are loaded from encrypted secrets file, not from plaintext group vars.

## 2) Configure cloudflared tunnel

Edit:

- `elemeno-dev/runtime/cloudflared/config.yml`
  - Set tunnel UUID
  - Set `dev.resumer.io` ingress target if app port changes

Create on disk before deploy:

- `elemeno-dev/runtime/cloudflared/credentials.json` (use `.example` as template)
- Encrypt it to `elemeno-dev/runtime/cloudflared/credentials.json.enc` and commit only `.enc`

## 3) Environment encryption workflow

Use SOPS with `.sops.yaml` (encrypt all dotenv key values).

Create plaintext files (not committed):

- `elemeno-dev/runtime/webapp/.env.production.local`
- `elemeno-dev/runtime/scraper/.env`

Encrypt recursively:

```bash
./scripts/sops-env.sh . encrypt
```

Decrypt recursively:

```bash
./scripts/sops-env.sh . decrypt
```

PowerShell equivalents:

```powershell
.\scripts\sops-env.ps1 -RootDir . -Action encrypt
.\scripts\sops-env.ps1 -RootDir . -Action decrypt
```

## 4) Postgres password setup (encrypted + automatic)

Generate and encrypt passwords:

```bash
./scripts/generate-elemeno-postgres-secrets.sh
```

PowerShell:

```powershell
.\scripts\generate-elemeno-postgres-secrets.ps1
```

This creates:

- `elemeno-dev/secrets/postgres.secrets.sops.yaml`

At deploy time, Ansible copies this file to the server, decrypts it there using the server GPG key, and applies:

- `postgres_app_password`
- `postgres_root_password`

## 5) Install Ansible dependencies

```bash
cd elemeno-dev/ansible
ansible-galaxy role install -r requirements.yml
ansible-galaxy collection install -r requirements.yml
```

## 6) Deploy

```bash
cd elemeno-dev/ansible
ansible-playbook -i inventory/dev/hosts.ini playbooks/elemeno-dev.yml
```

This playbook:

1. Ensures required Python dependencies for Docker modules
2. Syncs `elemeno-dev/runtime/` to `/opt/resumer/`
3. Syncs `elemeno-dev/secrets/` to `/opt/resumer/secrets/`
4. Decrypts Postgres/cloudflared/env secrets on the server
5. Installs and configures Postgres + backup roles
6. Ensures Docker network `resumer_net`
7. Starts/updates compose services

## 7) CI deploy over Tailscale SSH

Workflow file:

- `.github/workflows/deploy-elemeno-dev.yml`

Required repository secrets:

- `TAILSCALE_AUTHKEY`
- `ELEMENO_DEV_HOST` (MagicDNS name or Tailscale IP, for example `elemeno-dev`)

Tailscale CI policy expectation:

- GitHub runner joins tailnet with `tag:elemeno-ci`
- Tailnet ACL/SSH policy allows `tag:elemeno-ci` to SSH to `elemeno-dev` as `alexey`

Trigger behavior:

- Auto-runs on push to `main` when files under `elemeno-dev/` change
- Can be manually triggered with `workflow_dispatch`

## Next iteration targets

- Add health checks and container-level restart alerting
- Add CI pipeline for lint + `ansible-playbook --check` and Tailscale SSH deploy
- Add restore drill runbook for Postgres backups
