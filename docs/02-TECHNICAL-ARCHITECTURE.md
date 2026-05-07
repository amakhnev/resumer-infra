# Resumer.io - Technical Architecture

**Stack:** Next.js (app) | PostgreSQL | S3 Vector | S3 | separate Job Acquisition Service

Hosting (app and scraper) is decided at implementation time and revisitable independently.

---

## Architecture Principles

| Principle | Decision |
|-----------|----------|
| Country isolation | Each country has its own app, data, scrapers, file storage, and vector indexes. Marketing site (`resumer.io`) routes to the right country app. |
| No CV generation | The product never produces, modifies, or reformats user CV files. CVs are user-owned artifacts; the product owns matching only. |
| Profile is structured data | Profiles are JSON-backed, paired 1:1 with a user-uploaded CV file. Editable in form mode or JSON mode against a published schema. |
| No LLM in matching path | Matching and match explanation use embeddings, rules, and classifiers. |
| LLM use is external and optional | The product packages context; users run prompts in their own AI tools. Profile creation can use the Extract Profile prompt template. |
| Human content only | The product selects and packages user-written content; it does not invent career claims. |
| Feed quality first | Scraping is a data quality pipeline, not just page collection. |
| Match explainability | Every shortlisted match carries a deterministic explanation. Stored once, rendered tier-aware. |
| Explanation is a data source | The match explanation object is structured (per-skill evidence with role linkage). It powers UI, prompt context, and the cover-letter template engine without recomputation or LLM. |
| Speed as Pro mechanism | Pro = real-time alerts, Free = daily digest. Same matcher, different delivery. |
| Shortlist is short-lived | Untagged shortlist items expire by age (Free 7d, Pro 30d). Tagged items (`saved`, `archived`) survive up to a tier cap (Free 50, Pro 500). Move-to-applications deletes the shortlist item; the application is then the canonical record. Tier differentiates the retention window, not slot counters. |
| API as product boundary | User-owned scrapers and automations use an API contract, not internal tables. |
| Job acquisition is external | First-party scrapers run as a separate service that submits to the same public job-ingest API used by paying API users. App and scraper share no internals. One contract, many producer types (own scrapers, paying-user submissions, future paid-data adapters). |
| Webhooks share API contract | Outbound webhook payloads use the same data model and versioning as the inbound API. One contract, push and pull. |
| Implementation-light docs | This architecture avoids table definitions and endpoint payloads. |

## Country Model

`resumer.io` is the public marketing site and country chooser.

Country apps are isolated:

- `uk.resumer.io` - UK jobs, UK users, UK data
- `us.resumer.io` - US jobs, US users, US data
- Future country apps follow the same pattern

`dev.resumer.io` is the shared development environment. It runs on a homelab server with a Cloudflared tunnel. CI reaches it through Tailscale SSH.

Production country environments run in AWS. CI deploys through assumed roles.

## Runtime Components

| Component | Responsibility |
|-----------|----------------|
| Next.js app | UI, server actions, app routes/API, auth, product flows. Owns the inbound job-ingest API used by both first-party scrapers and paying API users. |
| Job Acquisition Service | First-party scrapers. Standalone service. Communicates with the app **only** through the public job-ingest API. Language and hosting deliberately unspecified - see [Job Acquisition Service](#job-acquisition-service). |
| PostgreSQL | Relational product state |
| S3 Vector | Per-profile and per-job vector search |
| S3 | User files, exports, attachments |
| Better Auth | User auth and API key support |
| Stripe | Paid plans |

## Product Domains

No table shape is fixed here. Data modeling should be decided during implementation.

- **Identity and billing:** users, plans, limits, API access. Personal information (name, email, phone, address, billing data) lives here, never in profiles.
- **Profiles:** structured JSON profiles, paired 1:1 with user-uploaded CV files. Each profile has summary, roles (extended descriptions), per-profile categorised skills, education, certifications. Active vs inactive state (inactive on downgrade, preserved indefinitely). No bullet variants, no variant groups, no master skill bank, no shared skill→role link tables.
- **CV files:** user-uploaded documents, paired with profiles. Stored as-is in S3, served back on download. Never modified or regenerated.
- **Embeddings:** S3 Vector references and metadata for profiles and jobs. One vector per active profile, one vector per cleaned job.
- **Jobs:** scraped, manually added, and API-added jobs with provenance and quality signals.
- **Job intelligence:** duplicate groups, repost history, possible ghost jobs, source quality, extraction confidence, red flags.
- **Shortlist:** jobs that might be interesting, with per-profile match scores, explanation, best-matching profile reference, seen flag, tags (`saved`, `archived`), and timestamps for age-based cleanup. Untagged items deleted after the tier-specific age window; tagged items survive up to the tier cap. Move-to-applications deletes the shortlist item in the same transaction as the application is created.
- **Applications:** preparation and tracking. Selected profile reference + an **independent CV file reference** (auto-attached from the profile's current CV at creation, then editable manually or via API; may point to any CV the user owns, not only the selected profile's). Notes, attachments, status. Drift between profile and application CVs is expected and acceptable. CRM-grade fields deferred post-MVP.
- **Files:** user-uploaded CV files, attachments, prompt exports.
- **Operations:** scraper runs, ingestion state, matching jobs, source health, monitoring.

Keep Postgres for relational state, S3 Vector for vector search, and S3 for file blobs. Store references across systems instead of duplicating payloads.

### Why S3 Vector over pgvector

Job embedding volume grows linearly with feed scale (cleaned jobs + reposts) and is independent of paying-user count. With pgvector, that volume sits in Postgres and forces an upgrade of the database instance well before user revenue justifies it - HNSW indexes are RAM-bound and large vector tables push working set out of cache. S3 Vector decouples vector storage cost from Postgres sizing: storage is cheap object-tier, query cost is per-request. Postgres stays sized for relational workload, vector spend scales with actual usage. Trade-off accepted: extra system to operate, extra IAM boundary, no transactional consistency between vector and relational state.

## Matching and Selection

Matching is embedding-based. No LLM is involved in job/profile matching.

The system uses:

- Job embeddings from cleaned job descriptions
- One embedding per active profile, built from a normalised serialisation of the profile JSON
- Per-profile structured skills, used for skill-overlap scoring
- Rules and classifiers for hard constraints and extracted fields

Each job is matched against every active profile owned by every user. The shortlist item records which profile matched best (and the full ranked list of profile scores for the user, surfaced in the explanation).

Profile embeddings exclude personal information by construction - profile JSON does not contain name, email, phone, address, or billing data; those live in identity/billing.

Conceptual vector groups per country:

- Per-profile vectors (one per active profile)
- Per-job vectors (one per cleaned job)

### Embedding-friendly text construction

Both sides of the comparison need normalised text suitable for the same embedding model.

**Profile side:**

- Serialise structured profile JSON into stable, sectioned text (summary, role headings with company/dates/title, role descriptions, skills as inline list, education, certifications)
- Strip JSON syntax and any meta fields not relevant for matching
- Stable across edits so re-embedding is needed only when the meaningful content changes (skip embedding if only formatting/whitespace differs)

**Job side:**

- Cleaned job description from the feed quality pipeline
- Plus extracted structured attributes inlined as a short header (role title, location, contract type, IR35, salary band)

Same embedding model on both sides. Hard filters (location, IR35, salary, clearance, contract type) are applied as a pre-filter before vector ranking, not embedded - filter compliance is a binary pass/fail, not a similarity dimension.

### Score composition

Every (profile, job) comparison produces two scores:

- `cosine` - cosine similarity between the profile embedding and the job embedding (in [0, 1])
- `skills` - skill-overlap ratio between `profile.skills[].name` and `job.skills_extracted[].name` (in [0, 1])

`skills` is computed as a weighted ratio that rewards required skills more than nice-to-haves and degrades gracefully when the listing does not flag requiredness:

```text
matched_required + 0.3 · matched_nice_to_have
-----------------------------------------------
total_required   + 0.3 · total_nice_to_have
```

Skill matching is name-based (no taxonomy lookup): exact match (case-insensitive), then a small curated synonym map (e.g. "Postgres" ↔ "PostgreSQL"), then embedding similarity on the skill name above a fixed cutoff. Synonym map is maintained in code and grows from logged misses.

#### The blend

Cosine on a long resume vs a long job description has a soft ceiling well below 1.0 because the two documents are different speech acts (descriptive past vs prescriptive present). A great match typically lands in the 0.65-0.78 raw cosine range; values above 0.85 usually indicate a near-duplicate (e.g. someone tested the matcher by uploading a job ad as their CV) rather than a better match. We compensate with a fixed bump and a hard output cap.

The display score (used for shortlisting and shown in the UI) is:

```text
display = min( cap,  ( a · (cosine · c)  +  b · skills ) / (a + b) )
```

| Coefficient | Meaning | MVP default |
|-------------|---------|-------------|
| `a` | Weight on cosine | `1.0` |
| `b` | Weight on skills | `1.5` |
| `c` | Cosine bump - lifts a strong raw cosine (≈ 0.70) into the "great match" band | `1.4` |
| `cap` | Output ceiling - keeps 1.0 free for future use, and avoids overpromising on a noisy signal | `0.99` |
| `threshold` | Display score required for shortlisting | `0.65` |

These five numbers are **per-country runtime configuration**, not hard-coded. Each country app calibrates from its own data.

#### Two scoring spaces, one purpose each

The matcher uses two distinct comparisons:

| Decision | Score used | Why |
|----------|------------|-----|
| Which of this user's profiles fits this job best? | Raw blended (`a · cos·c + b · skills`), pre-cap, **per profile** | Same job, same embedding call, fully comparable across profiles. Argmax wins. |
| Should this job enter the shortlist? | Display score (post-cap) of the **best profile** | Stable, calibrated, comparable across users and across single-job iterations. |

This separation is the reason real-time matching of one job at a time works without a batch context: the shortlist threshold operates on a value that is already on the same scale for every user.

#### Calibration

Cold start: ship with the MVP defaults above. They were chosen so that:

| Cosine | Skills | display |
|--------|--------|---------|
| 0.75   | 0.90   | 0.93 |
| 0.65   | 0.75   | 0.81 |
| 0.55   | 0.55   | 0.64 |
| 0.40   | 0.30   | 0.40 |
| 0.95   | 1.00   | 0.99 (capped) |

After roughly a month of usage, refit `a`, `b`, `c`, and `threshold` from user actions as labels:

- Job moved to applications → strong positive
- Shortlist tag `saved` → positive
- Shortlist tag `archived` → negative
- Shortlist item expired untagged → weak negative

Refit is offline, monthly, per country. The matcher reads the current coefficient set at request time from per-country config.

#### Why no per-user / per-profile calibration

- Cold start: a new user has zero match history. Per-user calibration would require a global fallback anyway, doubling the code path.
- Profile-quality regressions (a generic profile that never scores well) are valuable signals to surface, not to silently rescale away.
- The output cap and the bump together absorb most of the variance between profile types.
- The blend rewards strong skill overlap when raw cosine is weaker, so generalist profiles still score reasonably.

If telemetry later shows specific profile categories drifting, add per-category offsets before applying the blend - not per-user state.

### Match Explanation

Every shortlisted match produces an explanation deterministically. No LLM call.

Stored on the shortlist item:

- Best-matching profile name + display score
- Per-profile scores (display score for every active profile, ranked) - so the user sees which CV to send and how close other profiles came
- `score_breakdown` - the inputs (`cosine`, `skills`), the bumped cosine (`cosine · c` capped), the coefficients used (`a`, `b`, `c`, `cap`), the threshold, and the raw blended pre-cap value. Audit trail.
- Skill overlap with **per-skill role evidence** - for each matched skill, links back to the role(s) in the best profile where the skill is used (company, title, recency, duration). Computed by maintaining a per-profile inverted index `skill_name → [role_id]` at profile-save time. No LLM.
- Missing skills - present in the job, absent from the best profile. Drives gap chips and per-profile skills-gap analytics.
- Filter compliance - which hard filters passed (location, work mode, contract type, compensation, IR35, security clearance, visa)
- **Time-to-match** - timestamp delta between job ingest and shortlist match, surfaced in UI

The full explanation set is computed once and stored alongside the shortlist item. UI reads from the stored object so render is cheap and consistent. The same object is the **data source for prompt templates and the cover-letter template engine** - no recomputation needed at templating time.

### Tiered explanation rendering

The full explanation is the same data on both tiers; the UI gates which fields are exposed:

- **Free**: best profile + display score, top skill match summary ("7/8 required skills"), filter compliance ticks, time-to-match.
- **Pro**: all of Free, plus display scores for every active profile (so user sees the full ranking), full skill overlap chips with role-evidence on hover, missing-skill chips, per-filter detail.

Storing the full object regardless of tier keeps tier upgrades zero-cost (no recomputation needed) and avoids two code paths in the matcher.

## Job Feed Quality Pipeline

Two cleanup passes happen on every job: one **producer-side** (in the scraper, before POST) and one **app-side** (after ingest, with cross-source context the scraper doesn't have).

**Producer-side** (in the Job Acquisition Service, before POSTing to ingest API):

```text
raw source page
  -> paragraph / block splitting
  -> exact duplicate block removal
  -> near-duplicate boilerplate clustering
  -> local text classification
  -> cleaned job description reconstruction
  -> salary / rate / commute extraction
  -> emit job-schema.json payload
  -> POST /api/v1/jobs/ingest
```

**App-side** (after ingest, with the rest of the corpus available):

```text
ingested job
  -> dedup against existing jobs (cross-source, near-duplicate matching)
  -> attach to duplicate group; record other-agency entries
  -> recurring / ghost-job intelligence
  -> red flag generation
  -> embedding (skip if content_hash already embedded)
  -> enqueue matching
```

The split keeps the contract honest: producers do the work only they can do (source-specific extraction, source-specific cleaning) and the app does the work only it can do (cross-source dedup, ghost-job intelligence, embedding consistency).

Cleaning should remove or downweight non-job text:

- Cookie banners
- Legal boilerplate
- Equal-opportunity text
- Agency marketing
- Generic benefits
- Repeated company descriptions
- Navigation and footer content
- Application instructions unless they affect the user's decision

Extraction should prefer:

- Rules and regex for explicit salary, rate, contract type, location, remote/hybrid/onsite, commute, visa/security constraints
- TF-IDF or lightweight local classifiers for implicit commute requirements and boilerplate separation
- Confidence flags or review states for ambiguous cases

## Duplicate and Ghost-Job Intelligence

Deduplication is product intelligence, not just cleanup.

Detect:

- Exact duplicate jobs from the same source
- Near-duplicate jobs across sources and agencies
- Same job promoted by multiple agents
- Reposted jobs that appear again and again
- Jobs that look active but repeatedly cycle without hiring signal

Examples of user-facing red flags:

- Possible ghost job
- Reposted repeatedly
- Same job promoted by many agencies
- Salary/rate missing or inconsistent
- Commute requirement unclear or hidden


## Job Acquisition Service

First-party scrapers run as a **separate service** from the app and talk to it only through the public job-ingest API. No shared database, no shared queue, no shared codebase.

### What lives where

The **app** owns: auth, profiles, CV files, shortlist, applications, billing, the inbound job-ingest API and its webhook counterpart, and the cross-corpus work that happens *after* ingest (cross-source dedup, ghost-job intelligence, embedding, matching).

The **scraper service** owns: source-specific extraction, source-specific cleaning, fetching, session/anti-bot handling, and producing valid `job-schema.json` payloads to POST.

### Why separate

| Reason | Detail |
|---|---|
| **Failure isolation** | A banned scraper IP doesn't affect the app. An app deploy doesn't lose in-flight scraper work. Two independent restart loops. |
| **Tech freedom** | Scraping favours different tools and different runtime profiles (long-running, memory-heavy, browser-driving) than the app. Separation lets each pick what fits. |
| **Hosting portability** | Scrapers are pure outbound HTTPS clients. They can move between clouds, providers, or self-hosted boxes without touching the app. |
| **Credit eligibility** | Sustained compute (the scraper's profile) is what startup-credit programmes cover well. Keeping it separate lets credits be applied where they have most impact, independent of where the app lives. |
| **Source diversity** | Different sources have different rate, proxy, and uptime needs. Easy to fan out: one service instance per source group. |
| **Same path as paying-user submissions** | Scrapers use the same ingest API a paying Pro user would. One validation path, one auth model, one rate limiter. No "internal vs external" code fork. |
| **Future paid-data swap** | Replacing first-party scraping with a paid feed (e.g. a commercial jobs API) becomes "write an adapter that POSTs to the same endpoint". The app does not change. |

### Integration contract (conceptual)

One endpoint, used identically by first-party scrapers, paying API users, and any future paid-data adapter. Specifics (path, headers, batch size, status codes, auth roles) are decided at implementation time. The contract must guarantee:

- **Schema-validated:** payloads conform to `job-schema.json`; per-job errors don't drop the whole batch.
- **Idempotent:** safe to retry; the same source job submitted twice is a no-op.
- **Backpressured:** producers are told to slow down rather than the app failing under load.
- **Auth-scoped:** scrapers can submit jobs but cannot read user data.
- **Source-attributed:** every job carries provenance (source, scraper id, first-seen timestamp, extraction confidence).

### Operational shape (conceptual)

- One or more scraper instances, grouped by source characteristics. Add instances as sources are added.
- Instances must be **resumable** (cursor persisted) so eviction or restart is non-fatal.
- Instances must **heartbeat** so silent failure is detectable.
- Anti-bot/proxy strategy is the scraper's concern, not the app's. Source choice in early phases should bias towards sources that don't require expensive mitigation.

### What this is not

- **Not a microservices architecture.** Two services total: app and scraper.
- **Not a private RPC.** The contract is the same one offered to paying users.
- **Not a streaming pipeline.** Producers POST batches; backpressure is HTTP-level. No shared queues or message buses.

## Core Flows

### Job Ingestion

All producers (first-party scrapers, paying-user API submissions, manual user add, future paid-data adapters) hit the same ingest path:

```text
producer submits job-schema.json payload
  -> auth + rate-limit
  -> validate against job-schema.json
  -> dedup against existing jobs (idempotent: re-submitting is a no-op)
  -> cross-source cleanup, duplicate grouping, ghost-job intelligence, red flags
  -> embed cleaned job text (skip if already embedded for this content)
  -> enqueue matching
  -> acknowledge to producer
```

Producer-side cleanup (boilerplate strip, structured field extraction) runs before submission. App-side cleanup runs after ingest with cross-corpus context. The split keeps the contract honest: producers send their best structured guess; the app doesn't trust blindly but doesn't redo source-specific work either.

### Matching

```text
matching run starts (per-job: every active profile; per-profile: every recent job)
  -> for each (job, profile) pair:
       -> apply hard filters (location, IR35, salary, clearance, contract type)
       -> if passed: vector similarity via S3 Vector
       -> compute skill overlap (regex/TF-IDF over extracted skills)
  -> per job: rank profile scores; pick best profile
  -> if best profile score > threshold:
       -> compute time-to-match (job_ingested_at -> match_at)
       -> create shortlist item, recording best profile + full per-profile score list
       -> store full explanation object alongside shortlist item
       -> enqueue notification: real-time push/email (Pro) or daily digest (Free)
       -> emit event: shortlist.item.created (Pro webhooks)
```

### Match Notifications

Pro users get real-time match alerts; Free users get a daily digest. Same matcher output, different delivery.

```text
shortlist item created
  -> tier check on owner
  -> Pro: enqueue immediate push/email
  -> Free: append to per-user digest queue, send next morning
```

Notifications are delivery-only - they do not change matching behaviour. This keeps the speed differentiator a marketing/UX feature, not a different code path through the matcher.

Paid users get more frequent matching so they can apply earlier while jobs are fresh.

### Shortlist Review

```text
user opens shortlist item
  -> mark as seen
  -> keep, save, archive, delete, or move to applications
  -> on tag change: emit shortlist.item.tagged (Pro webhooks)
  -> on tag-cap reached: block new tagging with upgrade-or-untag message
  -> on move to applications: shortlist item is deleted (see Application Preparation)
  -> on delete: shortlist item removed; the underlying job is unaffected
```

### Shortlist Cleanup

```text
periodic sweep (e.g. nightly):
  for each user:
    -> delete untagged shortlist items older than tier age window
       (Free: 7d, Pro: 30d)
    -> for each deleted item: emit shortlist.item.expired (Pro webhooks)

  tagged items:
    -> never deleted by age
    -> if tagged-cap exceeded (Free: 50, Pro: 500), block new tag attempts
       (do not auto-evict tagged items - user explicitly cared)
```

Cleanup never blocks the matcher - new shortlist items are always created at write time; cleanup just runs in the background to bound storage.

### Application Preparation

```text
user moves job to applications (from a shortlist item)
  -> single transaction:
       create application record + job snapshot (copied from the shortlist item)
       copy stored match explanation onto the application
       delete the source shortlist item
  -> pre-select best-matching profile
  -> auto-attach the profile's current CV as the application's CV reference
  -> from this point: application owns its own CV reference, independent of profile
  -> user can override profile (auto-re-attaches new profile's CV)
  -> user can replace CV directly without changing profile selection
       (manual upload or via API, any CV the user owns)
  -> add private notes and attachments
  -> package built-in prompts (Pro): Tailor CV, Recruiter View, Cover Letter
       all driven by stored matching evidence + selected profile + job snapshot
  -> CV file is downloadable as-is - never modified or regenerated
  -> emit event: application.created (Pro webhooks)
  -> on later status change: emit application.status.changed (Pro webhooks)
```

The shortlist item deletion is implicit in `application.created`; no separate `shortlist.item.deleted` event is emitted. If the same job re-matches later (job re-posted, profile updated), it re-enters the shortlist as a fresh item - the UI cross-references the applications table by (user_id, job_id) and shows an "already applied to this" hint without blocking the item.

Profile edits, profile CV swaps, and profile deletion **never** retroactively change CVs already attached to existing applications. Implementation strategy (snapshot copy vs immutable file versioning) is deferred to implementation - the contract is "application CV reference is stable unless the user explicitly changes it on this application".

### Profile Lifecycle

```text
user uploads CV file
  -> store CV in S3 as-is, never modified
  -> create new profile bound to this CV (1:1 pairing)

profile creation - two paths:
  Path A (auto-import):
    -> CV text sent to theresumeparser.com
    -> JSON returned
    -> populate profile editor; user reviews/edits

  Path B (Extract Profile prompt template):
    -> user copies the template (includes JSON schema, no-PII instruction, no-invention instruction)
    -> user runs in own ChatGPT/Claude with their CV
    -> user pastes JSON back into the editor (form or JSON mode)

on profile save:
  -> validate against published schema
  -> recompute embedding only if meaningful content changed (skip on whitespace/format)
  -> mark profile active or inactive based on tier limits

on tier downgrade:
  -> profiles above Free limit become inactive (read-only, hidden from matching)
  -> never deleted automatically
```

## External API

API access is for paying users only.

The API should support user-owned automation without exposing internal tables.

Core API responsibilities:

- Submit jobs from user-owned scrapers, browser extensions, shortcuts, or automation
- Choose where submitted jobs go: shortlist, applications
- Retrieve authenticated shortlist/application state (including which profile matched)
- List/read/update user's profiles (JSON form), respecting active/inactive state
- Trigger application preparation for a job

## Webhooks (Pro)

Webhooks are the outbound counterpart to the API. They let users wire Resumer.io into their own automation stack (Slack, Notion, Make, n8n, Zapier, custom services) without polling.

Pro users can register one or more webhook endpoints per event type. Each endpoint is an HTTPS URL with a per-endpoint signing secret.

### Events

| Event | Fires when |
|-------|------------|
| `shortlist.item.created` | A new job enters the user's shortlist (any source) |
| `shortlist.item.tagged` | User adds or removes a tag (`saved`, `archived`) on a shortlist item |
| `shortlist.item.expired` | A shortlist item is auto-removed by the cleanup sweep (untagged + past age window) |
| `application.created` | A shortlist item is moved to applications. Implicitly deletes the source shortlist item; no separate event for that deletion. |
| `application.status.changed` | Application status transitions (e.g. `applied` → `interview`) |

Event payloads contain the user-facing object plus enough context (job snapshot reference, status from/to) to drive an external workflow. Personal data follows the same exclusion rules as embeddings - webhook payloads carry product-level data, not raw personal info.

### Delivery model

```text
event occurs (e.g. shortlist.item.created)
  -> tier check + endpoint lookup
  -> sign payload with endpoint secret (HMAC SHA-256)
  -> POST JSON to endpoint URL
  -> on non-2xx: retry with exponential backoff (capped attempts)
  -> on exhausted retries: mark delivery failed, surface in user's webhook log
```

Properties:

- **At-least-once delivery** - consumers must be idempotent (use `event_id`)
- **HMAC signature** in header so receivers can verify origin
- **Retry with backoff**, capped attempts, dead-letter visible in user's webhook log UI
- **Per-event subscription** - user picks which events go to which endpoint
- **Auto-disable** an endpoint after sustained failures, with notification to the user
- **Replay** - user can replay a failed delivery from the webhook log

### Boundary

Webhooks share the API contract surface - same versioning, same payload shapes, same field stability rules. The webhook is push, the API is pull; both speak the same product-level data model. This avoids two diverging contracts.

## Prompt System

The app does not call an LLM for matching, profile selection, or content generation. LLM use is **deliberately optional** and external - users run prompts in their own ChatGPT/Claude subscriptions.

Rationale: users in the target persona already pay for capable models. The product packages context (profile + job + filters), the user keeps control of the model. The product does not compete with the user's AI subscription, does not pay per-token at runtime, and avoids any liability for generated content.

### Available to all users

- **Extract Profile from CV** - prompt template containing the published profile JSON schema, plus instructions to exclude personal data, extract implied skills, and never invent experience details. Used to bootstrap a profile by pasting the prompt + CV into the user's own AI tool, then pasting the JSON output back into the profile editor (form or JSON mode). Available to all users because it powers profile creation.

### Built-in templates (Pro)

Pro users get curated templates that package the **selected profile + job + matching evidence** for external AI use or for deterministic rendering. Free users can copy raw context (job JSON + selected profile JSON) and write their own prompt.

- **Recruiter view prompt** - external review of how the application looks to a recruiter or ATS, given job + selected profile
- **Tailor CV prompt** - packages job + selected profile context, asks AI to suggest tailoring tweaks for the user to apply manually to their CV file. The product never modifies the CV file itself.
- **Cover letter / outreach template** - rendered by a deterministic template engine over the matching evidence object. No LLM. See below.

### Cover letter / outreach template engine

Cover letters and short outreach messages are **rendered**, not generated.

```text
inputs:
  - match_explanation object (stored on shortlist item)
  - selected profile (from application)
  - job snapshot (from application)
  - application metadata (status, notes)
  - user fields (display name etc., from account settings, opt-in)

engine:
  - placeholder substitution against the inputs (dot-path or similar)
  - default values (`{x | "fallback"}`) for missing fields
  - formatting helpers (date formatting, list joining)
  - no LLM, fully deterministic

output:
  - rendered text the user can copy / edit / send
  - never sent automatically by the product
```

Curated templates ship at MVP (long-form cover letter, short LinkedIn intro, agency reply). User-defined templates are deferred to post-MVP but the engine and the matching-evidence schema are designed to support them without contract changes.

This is the deterministic counterpart to "AI generates a cover letter from your CV". Output cites specific evidence the matcher already produced (skill X used at company Y in role Z), so it sounds grounded and human-written without depending on an LLM.

### Custom templates

Out of scope for MVP. Engine and matching-evidence schema are forward-compatible.

## Skills Gap Analytics (Pro)

Per-profile aggregate analytics over the user's recent shortlist:

- For each profile, take the jobs it recently matched best on
- For each skill present in those jobs: count occurrences
- Compare against skills present in that profile
- Output buckets: present + frequently demanded (confirms fit), missing + frequently demanded (improvement target), present + rarely demanded (consider trimming)

Computed from the same skill extraction pass used in matching - no LLM, no new pipeline. Stored per-profile as a periodically refreshed snapshot, not on demand.

Purpose: drives profile improvement, surfaces opportunities to create a new profile (if a different positioning is being demanded by jobs the user wants), and creates a reason for Pro users to return between active searches.


## Infrastructure

Two independently-hostable surfaces:

- **App surface:** Next.js app/API + PostgreSQL + S3 Vector + S3.
- **Scraper surface:** Job Acquisition Service. Pure outbound HTTPS to the app's ingest endpoint.

Development:

- `dev.resumer.io` runs on a homelab server, Cloudflared tunnel for public access, Tailscale SSH from CI.
- App and dev PostgreSQL co-located on the homelab.
- Scraper service runs locally and POSTs to the dev ingest endpoint.
- S3 Vector and S3 used even in dev (vector and blob storage aren't usefully mocked).

Production country app:

- App surface and scraper surface hosted independently. Specific providers and instance types are an implementation decision, revisitable for each surface without affecting the other.
- The choice should be revisited when phase milestones (paying-user count, job volume, credit balance) materially change the cost picture.

## Non-Goals

- No auto-apply.
- **No CV generation, modification, or reformatting.** Ever. Users send their own CV files.
- No CV templates, layout engine, font management, PDF generation, or ATS-format validation.
- No bullet-level variant entities, variant groups, or master skill bank.
- No generated fake career content.
- No in-product LLM calls for matching, profile selection, or content generation.
- No personal/contact data in profiles or matching embeddings.
- No shared production database between countries.
- No CRM-grade application fields at MVP (contacts, conversation log, recruiter messages).
- No custom prompt templates at MVP.
- No "shared/curated job sets" at MVP.
