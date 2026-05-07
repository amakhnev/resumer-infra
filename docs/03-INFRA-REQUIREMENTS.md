# Resumer.io - Infrastructure Requirements (resumer-infra)

Derived from `02-TECHNICAL-ARCHITECTURE.md`. This doc defines infra requirements for provisioning and operating `resumer-infra` (dev + production).

---

## 1) Scope

`resumer-infra` provisions and operates two independently-hostable surfaces:

- **App surface**: Next.js app/API, PostgreSQL, S3 Vector, S3 integration.
- **Scraper surface**: Job Acquisition Service (separate runtime, outbound HTTPS only to app ingest API).

Country isolation is mandatory: each country runs isolated app data, storage, and runtime boundaries.

---

## 2) Non-Negotiable Architecture Requirements

1. **Country isolation**
   - Each country environment MUST have isolated runtime, Postgres, object storage prefixes/buckets, vector indexes, secrets, and observability labels.
   - No shared production Postgres across countries.

2. **Service boundary**
   - App and scraper surfaces MUST deploy independently.
   - No shared DB, queue, or private RPC between app and scraper.
   - Scraper-to-app integration MUST use only the public ingest API over HTTPS.

3. **Storage model**
   - Relational state MUST be in PostgreSQL.
   - Vectors MUST be in S3 Vector (not pgvector in Postgres).
   - Files MUST be in S3-compatible object storage.

4. **Retry-safe ingest path**
   - Ingest API infra MUST support idempotent retries and burst backpressure without global failure.

---

## 3) Environments and DNS

### 3.1 Development

- `dev.resumer.io` MUST run on homelab infra.
- Public dev ingress MUST be through Cloudflared tunnel.
- CI remote access MUST use Tailscale SSH.
- Dev app and dev Postgres MAY be co-located (current target).
- Dev scraper runs as a separate process/service and POSTs to dev ingest endpoint.
- Dev MUST use real S3 Vector and S3 services (no fake local substitutes for vector/blob behavior).

### 3.2 Production

- Country environments (e.g. `uk.resumer.io`, `us.resumer.io`) MUST run in AWS.
- CI deployments MUST use assumed roles (OIDC or equivalent short-lived auth; no long-lived deploy keys).
- App and scraper surfaces MAY use different providers/instance classes, but MUST preserve contract boundary.
- Marketing root (`resumer.io`) routes users to country apps; routing changes MUST not break country isolation.

---

## 4) Network and Access Requirements

1. **Ingress**
   - App surface MUST terminate TLS for web and API traffic.
   - Scraper surface SHOULD avoid public ingress when possible; outbound-only preferred.

2. **Egress**
   - Scraper egress MUST allow target source sites plus app ingest endpoint.
   - App egress MUST allow Postgres, object storage, vector service, auth/billing providers, and email/push providers.

3. **Trust boundaries**
   - Network policy/security groups MUST prevent scraper lateral access to app internals except ingest HTTPS.
   - Postgres MUST not be publicly writable.

4. **Secrets**
   - Secrets MUST be managed in a dedicated secret manager or encrypted environment mechanism.
   - Secret rotation MUST be supported without full platform redeploy where feasible.

---

## 5) Compute and Runtime Requirements

### 5.1 App Surface

- Must support:
  - Next.js server rendering + app routes/server actions.
  - Background job execution for matching, cleanup, notifications, and webhook delivery retries.
- Runtime must tolerate bursty ingest/match workloads.
- App deployment MUST support rolling updates or equivalent no-downtime strategy.

### 5.2 Scraper Surface

- Must support long-running, memory-heavy/browser-driving workloads.
- Instances MUST be resumable (cursor/progress persisted) to survive evictions/restarts.
- Instances MUST emit heartbeats for liveness monitoring.
- Horizontal fan-out by source group MUST be possible without app changes.

---

## 6) Data and Storage Requirements

1. **PostgreSQL**
   - Managed backups required (daily minimum).
   - Point-in-time recovery strongly recommended in production.
   - Major/minor upgrade path must be defined per environment.

2. **S3 Vector**
   - Separate vector namespaces/indexes per country are required.
   - Embedding read/write IAM policies MUST be least-privilege.

3. **Object storage (S3)**
   - Bucket/prefix isolation per country required.
   - Encryption at rest required.
   - Lifecycle policy required for exports/temp artifacts where applicable.

4. **Data references**
   - Systems should store references across Postgres/S3/S3 Vector, not duplicate large payloads.

---

## 7) Security and Compliance Baseline

1. **Identity & IAM**
   - Separate IAM roles for app runtime, scraper runtime, CI deployer, and operators.
   - CI role assumptions MUST be environment-scoped and auditable.

2. **Transport/security**
   - TLS 1.2+ required for all external traffic.
   - Webhook signing (HMAC SHA-256) support is required in app infra config.

3. **Data handling**
   - Personal/contact data MUST remain in identity/billing domains; not copied into profile/matching stores.
   - Logs MUST avoid sensitive payload dumps (PII and secrets redaction required).

4. **API hardening**
   - Ingest endpoint MUST enforce auth scope, schema validation path capacity, and rate-limits.
   - Backpressure behavior MUST degrade gracefully (429/retry-friendly), not fail-open.

---

## 8) CI/CD Requirements

1. **Pipelines**
   - Separate deploy pipelines for app and scraper surfaces.
   - Country deployments MUST be independently triggerable.

2. **Release strategy**
   - App supports rolling/canary-capable deploys.
   - Scraper deploys support rapid rollback and per-source-group rollout.

3. **Config management**
   - Per-country runtime coefficients/config (matching constants, thresholds, feature flags) MUST be externally configurable and versioned.

4. **Stateful changes**
   - DB migrations must run in controlled deploy stages with rollback playbook.

---

## 9) Observability and Operations

1. **Telemetry minimum**
   - Structured logs, metrics, and traces for both surfaces.
   - Correlation IDs across ingest -> dedup -> embed -> match -> notify path.

2. **Health monitoring**
   - App: API latency/error rates, queue depth, match throughput.
   - Scraper: heartbeat freshness, fetch success rates, source-level error rates.

3. **Alerting**
   - Critical alerts: ingest outage, match pipeline backlog, webhook failure spike, scraper heartbeat loss, Postgres health degradation.

4. **Auditability**
   - Deployment events, role assumptions, and infra changes must be auditable.

---

## 10) Reliability, Backup, and Recovery

1. **Failure isolation**
   - App and scraper failures MUST not cascade through shared runtime dependencies.

2. **Backups**
   - Postgres automated backups mandatory.
   - Object storage durability and versioning/lifecycle strategy documented.

3. **Recovery**
   - Environment restore runbook required (per country).
   - Recovery drills SHOULD be run periodically.

4. **Idempotency and replay**
   - Infra must preserve retry/replay-safe semantics for ingest and webhook delivery paths.

---

## 11) Cost and Scaling Requirements

1. **Independent scaling**
   - App and scraper resources MUST scale independently.
   - Vector cost MUST scale by usage; Postgres sizing should remain tied to relational workload.

2. **Revisit triggers**
   - Hosting/instance strategy SHOULD be re-evaluated at phase milestones:
     - Paying-user count changes materially.
     - Job ingestion volume shifts materially.
     - Startup/cloud credit balance changes materially.

3. **Capacity planning inputs**
   - Required tracked inputs: jobs/day by country, embed calls/day, match queue lag, scraper runtime hours/source, webhook volume.

---

## 12) Acceptance Checklist (MVP)

`resumer-infra` MVP is acceptable when:

- [ ] Dev runs at `dev.resumer.io` via Cloudflared + Tailscale SSH CI path.
- [ ] At least one production country stack runs in AWS with isolated app data plane.
- [ ] App and scraper deploy independently with no shared private data plane.
- [ ] Ingest API handles authenticated, rate-limited, idempotent submissions.
- [ ] Postgres backups and restore playbook are in place.
- [ ] S3 + S3 Vector are wired with country-isolated access controls.
- [ ] Baseline monitoring + critical alerts are active for both surfaces.
- [ ] CI deploy uses assumed roles and short-lived credentials.

---

## 13) Deferred Decisions (Track Explicitly)

To be selected during implementation (not fixed by architecture):

- Exact compute products and instance classes for app/scraper.
- Queue/job-runner implementation details.
- Final secret manager and key-rotation automation.
- Exact SLO targets and alert thresholds.
- Scraper anti-bot/proxy vendor choices by source group.
