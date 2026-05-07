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
ansible-playbook -i inventory/dev/hosts.ini playbooks/elemeno-dev.yml
```

6. Re-encrypt and keep plaintext out of git:

```bash
./scripts/sops-env.sh . encrypt
rm -f elemeno-dev/runtime/webapp/.env.production.local elemeno-dev/runtime/scraper/.env elemeno-dev/runtime/cloudflared/credentials.json
```

## Notes

- Cloudflared credentials are committed only as `credentials.json.enc`; plaintext `credentials.json` is ignored by git.
- Postgres passwords are committed only in `elemeno-dev/secrets/postgres.secrets.sops.yaml`; playbook decrypts this file on the server before applying Postgres roles.
- `docker-compose.yml` uses image tags as placeholders (`ghcr.io/resumerio/...`); swap to your real build/publish targets.
- CI deploy over Tailscale SSH is defined in `.github/workflows/deploy-elemeno-dev.yml`.
