# Application Analysis and Fixes

Project: AI Customer Support Automation Platform (n8n + Gemini + Qdrant + PostgreSQL)
Author: Hansi Tharaki (Software Engineering Undergraduate)
Date of this review: 2026-10-30, last updated 2026-11-01

This file explains what the project is, what was wrong, what was changed, and what was actually tested.
Everything marked **Tested** was run against the real local Docker stack. Anything not tested is listed under "Not tested".

---

## 1. Architecture

```
Customer / Postman / website form
        |
        |  POST /webhook/support-message   (JSON: name, email, message)
        v
+-------------------------------------------------------------------------------+
| n8n  (workflow "Customer Support AI", id CdAypnWR7xBZIEPc)                    |
|                                                                               |
|  Webhook -> Validate Input -> valid? --no--> 400 / 401 reply                  |
|                                |yes                                           |
|                      Generate Ticket ID (PostgreSQL sequence)                 |
|                                |                                              |
|                      Reply 202 {ticket_id}   <- the caller is done here       |
|                                |  (everything below runs in the background)   |
|                      Save Pending Ticket (PostgreSQL, status "pending")       |
|                      Get Customer History (PostgreSQL, last 5 answered)      |
|                                |                                              |
|                      Intent Detection (Gemini chat; retries + fallback model) |
|                       |                         |                             |
|                 Refund intent             Any other intent                    |
|                       |                         |                             |
|               Refund Response AI     Question Embedding (Gemini)              |
|                       |              Search Knowledge Base (Qdrant)           |
|                       |              Knowledge Response AI (Gemini)           |
|                       +-----------+-------------+                             |
|                Save Support Request (reply saved, status "answered")          |
|                            |                       |                          |
|                  Customer Response Email   Sentiment Detection (Gemini)       |
|                                                    |                          |
|                                           Save Sentiment (PostgreSQL)         |
|                                                    |                          |
|                                       Negative? -> Angry Customer Alert email |
|                                                                               |
|  GET /webhook/customer-feedback -> Validate Feedback -> Save Feedback         |
|                    -> thank-you page (200) / invalid link (400) / no ticket (404)
|                                                                               |
|  Error Trigger -> mark the ticket "failed" -> email the support team          |
|                   (with ticket, customer address and message)                 |
|  Load Knowledge Base (manual trigger) -> embed FAQ -> Qdrant  [one click]     |
+-------------------------------------------------------------------------------+
        |                    |                     |
   PostgreSQL 16         Qdrant 1.20          Gemini API (OpenAI-compatible)
   support_requests      collection           chat: gemini-3.1-flash-lite
   customer_feedback     support_docs         embeddings: gemini-embedding-001 (1536 dims)
   ticket_seq            (6 FAQ documents)
```

How the parts talk to each other:

- n8n -> PostgreSQL: the n8n "Postgres account" credential, host `postgres` on the Docker network.
- n8n -> Qdrant: plain HTTP to `http://qdrant:6333` on the Docker network (no credential).
- n8n -> Gemini: Code nodes (one per AI step) using `GEMINI_API_KEY`, `GEMINI_BASE_URL` and the model names, which are passed into the n8n container as environment variables. Each call retries temporary errors (503, 429, timeouts) with growing waits and then tries `GEMINI_FALLBACK_MODEL`.
- n8n -> email: the n8n "SMTP account" credential, created by `scripts\setup.ps1` from the `SMTP_*` values in `.env`.

### Technologies

n8n 2.44.6, Google Gemini through its OpenAI-compatible API, Qdrant v1.20.0, PostgreSQL 16, Docker Compose, PowerShell scripts, JavaScript (n8n Code nodes), Postman / Newman for API tests.

### Important: this project does not use OpenAI

The task description mentions OpenAI. The project actually uses **Google Gemini** (through an OpenAI-compatible URL). No OpenAI key is needed or used.

---

## 2. Issues found, causes, and what was done

Status: **Fixed** = changed and tested. **Mitigated** = reduced but not removed. **Open** = not changed (see section 5).

### Critical

| # | Issue | Root cause | Where | Status |
|---|---|---|---|---|
| C1 | The workflow that was actually running was **not** the workflow in the repo. The live one had 14 extra, half-duplicated nodes, according to its connections it re-embedded the whole knowledge base on **every** customer message (6 Gemini calls each time; read from the workflow wiring, not measured) and ignored feedback comments. | The live n8n database had drifted from the backup file. | n8n database vs `n8n/backup/workflows/Customer Support AI.json` | **Fixed**: the repo workflow (now improved) is deployed. The old live version was exported first to `n8n/backup/pre-fix-live-workflow.json`. |
| C2 | The real workflow file was **never committed to git**. | `.gitignore` line `workflows/` also matched `n8n/backup/workflows/`. | `.gitignore` | **Fixed**: the pattern is now `/workflows/` (only the n8n data folder), and `Customer Support AI.json` is explicitly allowed. It still needs a `git add` + commit by you. |
| C3 | The support webhook accepted anything: no email check, no length limit, no authentication. Anyone who could reach it could make the system send AI-written emails to any address and spend Gemini quota. | No validation step existed. | Webhook node | **Fixed/Mitigated**: new *Validate Input* node (valid email, message required and at most 2000 chars, name at most 100 chars) with clear 400 replies; optional `X-API-Key` check (401); body size limit set to 1 MiB (configured in n8n, not tested with a large body). The API key is **off until you set `SUPPORT_API_KEY`** in `.env`. |

### High

| # | Issue | Root cause | Where | Status |
|---|---|---|---|---|
| H1 | The `sentiment` column was always empty. | The ticket was saved before the sentiment was known and nothing wrote it back. | Workflow | **Fixed**: new *Save Sentiment* node stores `Positive`, `Neutral` or `Negative`. The alert decision reads the AI answer directly, so alerts still work if the database update fails. |
| H2 | The feedback link returned HTTP 500 when `ticket_id` was missing, saved ratings for tickets that do not exist, accepted any rating text, and (in the live version) threw away the customer's comment. | No validation; the database rejected the NULL and n8n returned a generic error. | Feedback webhook | **Fixed**: *Validate Feedback* (ticket format, rating must be `good` or `bad`, comment capped at 500 chars). The insert only happens if the ticket exists. Replies: 200 thank-you page, 400 invalid link, 404 unknown ticket. |
| H3 | PostgreSQL (password `support123`), Qdrant (no password) and n8n were published on **all** network interfaces. | `ports: "5432:5432"` style bindings. | `docker-compose.yml` | **Fixed**: all three are bound to `127.0.0.1`. Checked with `docker compose ps`. |
| H4 | The database password was hard-coded in two places. | Compose file and the credential backup. | `docker-compose.yml`, `scripts/setup.ps1` | **Mitigated**: now `POSTGRES_PASSWORD` in `.env` (default unchanged so your existing database keeps working). The setup script builds the n8n credential from it. See "Open" for the existing-volume limitation. |

### Medium

| # | Issue | Root cause | Where | Status |
|---|---|---|---|---|
| M1 | Ticket IDs were a random 4-digit number, so duplicates become likely after a few hundred tickets, and nothing prevented them. | `Math.random()` in a Set node. | *Generate Ticket ID* | **Fixed**: IDs now come from a PostgreSQL sequence: `SUP-2026-000001`, `SUP-2026-000002`, ... Old IDs stay valid. |
| M2 | If Gemini, Qdrant or the database failed, nothing told anyone. | No error workflow. | Workflow settings | **Fixed**: *Error Trigger* + *Notify Workflow Error* email to `SUPPORT_ALERT_EMAIL`. The workflow's error workflow is set to itself. The knowledge-base search now also retries 3 times. |
| M3 | The caller got `{"message":"Workflow was started"}` and no way to find their ticket. | Webhook used the default "respond immediately" mode. | Webhook node | **Fixed**: the reply is now `202 {"status":"accepted","ticket_id":"..."}`. |
| M4 | Email addresses with different capitalisation were treated as different customers (history lookup missed earlier tickets). | Case-sensitive `WHERE customer_email = $1`. | *Get Customer History*, *Save Support Request* | **Fixed**: stored lower-case; lookup uses `LOWER()`; new index `idx_support_requests_email_lower_created`. |
| M5 | `n8nio/n8n:latest` and `qdrant/qdrant:latest` can change under you (n8n 2.x already changed several defaults). | Unpinned tags. | `docker-compose.yml` | **Fixed**: pinned to the versions that were running and tested: n8n `2.44.6`, Qdrant `v1.20.0`. |
| M6 | After a restart, `setup.ps1` reported success while the webhooks still returned 404 for a few seconds. It also ignored failed imports. | It only waited for `/healthz`, which answers before workflows are registered; exit codes were not checked. | `scripts/setup.ps1` | **Fixed**: waits for the webhook to be registered, stops with an error if an import or publish fails, applies `init.sql` on every run. (Found during testing: the first request after a restart returned 404.) |

### Low

| # | Issue | Status |
|---|---|---|
| L1 | README had no setup or API instructions and described an outdated schema. | **Fixed** (Getting Started, API table, schema). |
| L2 | `test-webhooks.ps1` only printed results and could not detect failures. | **Fixed**: 18 pass/fail checks (19 when `SUPPORT_API_KEY` is set), exit code 1 on failure. |
| L3 | No Postman collection or API tests. | **Added** `postman/AI-Customer-Support.postman_collection.json` (13 requests with tests). |
| L4 | No health check for n8n in Docker. | **Fixed** (`healthcheck` on the n8n service). |
| L5 | n8n accepts webhook bodies up to 16 MiB by default. | **Configured**: `N8N_PAYLOAD_SIZE_MAX=1` (1 MiB); checked that the variable is set in the container, not tested with an oversized body. |

### Round 2 (2026-10-31): problems found while you used the workflow in the n8n editor

You reported that the workflow did not work well and sent a screenshot of the **Notify Workflow Error** node with red "[ERROR: not accessible via UI]" fields. I checked n8n's real execution history, not just the screen.

| # | Issue | Root cause | Status |
|---|---|---|---|
| R1 | **A customer message was lost.** Execution #106 failed because Gemini answered `503 This model is currently experiencing high demand` at *Knowledge Response AI*. It retried 3 times, 3 seconds apart, all failed, and the customer got no answer. | Gemini has short overload spikes. 3 quick retries and a single model are not enough. | **Fixed**: every Gemini step is now a Code node that retries (3 tries with 3 s then 6 s waits) and then tries `GEMINI_FALLBACK_MODEL` (default `gemini-3.5-flash-lite`, checked live: 200 OK in about 1 s). A bad key (401/403) stops at once. Embeddings retry 5 times (no fallback model, because vectors from another model would not match). |
| R2 | When every retry failed, **nothing was kept**: no ticket row, and the alert email did not say who was waiting. | The ticket was only written at the end of the flow. | **Fixed**: the ticket is saved first with status `pending`, then becomes `answered`. If the run fails or n8n is restarted mid-run, the ticket becomes `failed` and the alert email contains the ticket number, customer address and message, so someone can answer by hand. New columns: `status`, `execution_id`. |
| R3 | The red `[ERROR: not accessible via UI, please run node]` in the editor. | The editor cannot preview `$env.*` values. This is **only a display problem**: at run time the values were read correctly (the emails were sent). | **Fixed**: settings are read inside Code nodes (*Load Settings*, *Build Alert Email*), so the email nodes now use plain `$json` values and no field shows red. The Gemini key is no longer visible in any node field either. |
| R4 | Crash recovery sent a **blank alert email** ("undefined" subject and body). | The alert text was built with a long expression that returned nothing when n8n recovered an interrupted run. | **Fixed**: *Build Alert Email* builds the message in code with a default for every field (tested with a normal failure and with n8n restarted mid-run). |
| R5 | The knowledge-base loader nodes (*Support Knowledge* -> *Split Knowledge Docs* -> *Create Knowledge Embedding* -> *Insert Knowledge Vector*) had **no trigger**, so they could not be started. | Incomplete feature. | **Added** a *Load Knowledge Base (manual)* trigger. Not tested by clicking it (see section 4); `.\scripts\ingest-knowledge-base.ps1` remains the tested way. |
| R6 | A message with commas, quotes or apostrophes could be split wrongly by the database node. | Risk when passing values as one comma-separated text. | **Checked**: the new database steps pass values as a list; a message with commas, quotes, `#`, `$` and `;` was stored exactly. |
| R7 | **The customer reply email failed for every non-refund ticket** (execution #179). The angry-customer alert had the same problem. Error: `Node 'Refund Response AI' hasn't been executed`. | The email text used `$node['Refund Response AI']`, which in n8n 2.x throws an error when that step did not run (every knowledge-base answer). This was in the original workflow; my earlier email tests only covered refund tickets, so they missed it. | **Fixed**: both emails take the answer from *Save Support Request*, which runs on both paths. |
| R8 | The angry-customer alert showed `\n` as text instead of line breaks. | The line breaks were stored as the two characters `\` and `n`. | **Fixed**: real line breaks. |
| R9 | **No email was sent at all.** `.env` had the Gmail address and App Password, but `SMTP_HOST` was still `smtp.example.com` (`ENOTFOUND smtp.example.com`). | Placeholder left in `.env`. n8n also keeps its own copy of the SMTP settings, so `.env` changes only apply after `setup.ps1`. | **Fixed**: `SMTP_HOST=smtp.gmail.com`, then `setup.ps1`. |

| R10 | The email sign-off showed an AI-engineer title and a generic support address instead of the project owner's details. | The sign-off is written into the two Gemini reply prompts (*Refund Response AI* and *Knowledge Response AI*), not into the email node, so it was missed when only the email node was checked. | **Fixed** (2026-11-01): both prompts now sign off as Hansi Tharaki, Software Engineering Undergraduate, Smart Support AI Solutions, tharaki115h@gmail.com. Applied to n8n by re-running `setup.ps1`. Not yet checked in a real received email. |

Also found: replies were slow on one test run (tickets still `running` after about 50 s). That is Gemini being slow, not the workflow. It is why the retries now have waits and a fallback.

---

## 3. Files changed

| File | Change |
|---|---|
| `n8n/backup/workflows/Customer Support AI.json` | Rebuilt in two rounds: validation, 202 reply, sequence ticket IDs, pending/answered/failed tickets, sentiment saving, feedback checks, Gemini retries + fallback, failure alert with ticket details. 22 -> 39 nodes. Existing node names were kept. |
| `docker-compose.yml` | Localhost-only ports, pinned images, `SUPPORT_API_KEY`, `POSTGRES_PASSWORD`, `GEMINI_FALLBACK_MODEL`, payload limit, n8n health check |
| `init.sql` | Idempotent migrations: `ticket_seq`, `sentiment`, `status` and `execution_id` columns, indexes |
| `.gitignore` | Stops hiding the project workflow; ignores the pre-fix safety copies |
| `.env.example` | Documents `SUPPORT_API_KEY` and `POSTGRES_PASSWORD` |
| `scripts/setup.ps1` | Applies `init.sql`, credential from `.env`, error checks, waits for webhooks |
| `scripts/test-webhooks.ps1` | Rewritten as a pass/fail test suite |
| `README.md`, `codes.txt` | README rewritten as a full description of the application (2026-11-01); `codes.txt` has the command examples |
| `postman/AI-Customer-Support.postman_collection.json` | New |
| `APPLICATION_ANALYSIS_AND_FIXES.md` | This file (sign-off fix R10, author and date added) |

Safety copies (git-ignored, not secret): `n8n/backup/pre-fix-live-workflow.json` (what was running), `n8n/backup/pre-fix-repo-workflow.json` (the old repo file), `n8n/backup/pre-fix-v1-workflow.json` (after round 1, before round 2).
Nothing was deleted: no Docker volumes, no database rows, no workflows. The 311 imported template workflows in n8n were not touched.

---

## 4. Testing performed

All on the real stack (Docker Desktop, n8n 2.44.6, PostgreSQL 16, Qdrant 1.20.0, live Gemini API).

| What | How | Result |
|---|---|---|
| Gemini key, chat and 1536-dim embeddings | `scripts\test-gemini.ps1` | Passed |
| Docker services | `docker compose ps` | All 3 up, n8n and Postgres healthy, ports on 127.0.0.1 |
| Database migration | `setup.ps1` (twice) | Applied; second run is a no-op |
| Qdrant | `GET /collections/support_docs` | 6 points, still 6 after the Qdrant stop/start test |
| Support webhook: validation | Test suite + Postman | invalid email, missing message, message over 2000 chars -> 400; GET -> 404 |
| API key | Temporary key set, then removed | Missing key -> 401, wrong key -> 401, correct key -> 202 |
| RAG path (password reset) | Test suite, several runs | Ticket saved with intent, sentiment `Neutral`, AI answer |
| Refund + angry path | Test suite with an angry message | Intent `Refund`, sentiment `Negative` saved |
| Emails | Temporary local Mailpit mail catcher | Customer reply arrived with correct ticket and feedback links; angry-customer alert arrived **only** for the angry ticket |
| Error alert | Stopped Qdrant, sent a question | Email `[n8n] Customer Support AI failed at Search Knowledge Base`; Qdrant restarted afterwards |
| Feedback webhook | Test suite + Postman | good/bad -> 200 page and row saved with the comment; bad rating -> 400; missing ticket -> 400; unknown ticket -> 404 and nothing saved |
| Postman collection | `npx newman run ...` (after round 1 and again after round 2) | 13 requests, 13 assertions, 0 failures |
| Round 2: message with commas, quotes, apostrophe, `#`, `$`, `;` | Sent through the webhook | Stored exactly; intent `Refund`, sentiment `Negative`, status `answered` |
| Round 2: **fallback model** | Main model name set to a model that does not exist | Ticket still `answered` (30 s, including the retries on the broken model) |
| Round 2: **everything fails** | Both model names broken, temporary Mailpit | Ticket `failed`; one alert email with failed step, ticket, customer address and message |
| Round 2: **n8n restarted mid-run** | Restarted the container 4 s after a message | Ticket `failed`; one readable alert email (ticket, customer, message) |
| Full suite, final run (after round 2) | `scripts\test-webhooks.ps1` | All checks passed, including the new `status = answered` check (the 2 API-key checks run only when `SUPPORT_API_KEY` is set; they passed in the earlier run with a temporary key) |
| Gmail SMTP login (R9) | Logged in from the n8n container without sending mail | Login OK |
| Refund + angry ticket, real Gmail | Ticket `SUP-2026-000031`, sent to your own address | Gmail accepted the customer reply and the alert |
| Knowledge path + angry ticket (R7, R8) | Ticket `SUP-2026-000033` (password reset complaint), execution #183 | Went through the knowledge base; Gmail accepted the customer reply and the alert |

After testing, the temporary Mailpit container was removed, the temporary API key was removed, and `setup.ps1` was run again so the SMTP credential is back to the normal placeholder. (Later you set your own API key and Gmail account in `.env`.)

Problems found *by* testing and fixed: the 404 right after a restart (M6); and two mistakes in my own Postman collection (a lost regex backslash, and feedback sent before the ticket existed).

### Not tested

- **Clicking the new *Load Knowledge Base (manual)* trigger in the editor.** I could not drive it from the command line (n8n's CLI started the Error Trigger instead). Its nodes use the same embedding code that was tested, and Qdrant still holds the 6 FAQ points. Use the ingest script if in doubt.
- A real Gemini 503 spike. The retry and fallback were tested by breaking the model name (a 404), so the exact timing under a real 503 is not measured.
- **Whether the emails reach the inbox.** Gmail accepted them; I cannot see whether they landed in the inbox or in spam.
- `scripts\test-webhooks.ps1` checks the database only, not whether emails were sent. That is how R7 was missed.
- A public HTTPS URL or reverse proxy in front of n8n.
- Load or concurrency, and Gemini rate limits or quota exhaustion.
- A full computer reboot / Docker Desktop restart.
- The 5 template workflows that `import-templates.ps1` documents as failing to import (unrelated to this project).

---

## 5. Remaining issues and limits

Implemented and working: everything in section 2 marked Fixed.

| Item | Detail | Suggested next step |
|---|---|---|
| **API key** | You have set `SUPPORT_API_KEY`, so every POST to `/webhook/support-message` (including the editor's test URL) must send `X-API-Key`. | In Postman set the `apiKey` variable. Keep the key secret. |
| **No rate limiting** | One client can send many messages. | Put a reverse proxy (Caddy / nginx / Cloudflare) in front, or add a per-email limit in the workflow. |
| **Prompt injection** | The customer's message is placed straight into the AI prompts. A crafted message could make the AI promise a refund or say something wrong in an email. | Add a human-approval step for refund replies, and keep the policy wording in the prompt strict. |
| **No automatic retry of failed tickets** | The ticket is now saved first and flagged `failed`, and support is emailed the customer's details, but the customer is not answered automatically. The caller also gets `202` before the AI has finished. | Review with `select * from support_requests where status <> 'answered'`. Later: a scheduled job that re-runs `failed` tickets. |
| **Feedback links are GET links** | Some email scanners open links automatically and can record false ratings. Repeated clicks add duplicate rows. | Use a confirmation page with a button (POST), and keep only the latest rating per ticket. |
| **Default database password** | `support123` is still the default and is in `n8n/backup/credentials/postgres.json` in git. Changing `POSTGRES_PASSWORD` in `.env` does **not** change an existing database. | Run `ALTER USER support PASSWORD '...'` in Postgres, then set the same value in `.env` and run `setup.ps1`. |
| **Qdrant has no authentication** | Safe only because it is bound to localhost. | Enable a Qdrant API key before exposing it. |
| **Knowledge base duplicated** | The same 6 FAQ texts exist in `faq.txt` and in two nodes (*Support Knowledge*, *Split Knowledge Docs*) that only run from the *Load Knowledge Base (manual)* trigger. Both ways write point ids 1-6, so running either again overwrites instead of adding duplicates. | Keep one source: edit `faq.txt` and use `scripts\ingest-knowledge-base.ps1`. |
| **Unused Docker files** | `n8n/Dockerfile.n8n`, `n8n/Dockerfile.runner`, `n8n/n8n-task-runners.json` are not used by `docker-compose.yml`. | Delete them or wire them in; left untouched because you did not ask for deletion. |
| **Hard-coded sign-off** | The AI prompts contain the agent name "Hansi Tharaki", the position "Software Engineering Undergraduate", the company "Smart Support AI Solutions" and the contact "tharaki115h@gmail.com". `docker-compose.yml` already passes `AGENT_NAME`, `AGENT_POSITION`, `COMPANY_NAME` and `SUPPORT_CONTACT_EMAIL` into the n8n container, but the workflow does not read them yet, and `.env.example` does not list them. | Make the prompts read these variables (through *Load Settings*), add them to `.env.example`, and check that `SUPPORT_CONTACT_EMAIL` in `.env` holds your own address. |
| **Intent labels** | Only 4 categories exist; a password reset is usually labelled "Technical Issue". This is the model's choice, not a bug. | Add a "Password / Account" category if you want reports by topic. |
| **Test data** | The database holds test tickets: most with `@example.com` addresses, plus a few sent to your own Gmail address. | Tell me if you want them deleted; I did not delete anything. |
| **Latest changes are not committed** | Rounds 1-3 are committed (latest `8d370d2`). The sign-off change (R10), the new README, this file and the `docker-compose.yml` agent variables are not committed yet. | Review `git status`, then commit. |

---

## 6. Security improvements made

1. Webhook input validation (email format, lengths, required fields) with proper 400 replies.
2. Optional shared-secret header `X-API-Key` for the support webhook.
3. Request body limit reduced from 16 MiB to 1 MiB.
4. Database, Qdrant and n8n are reachable only from this computer.
5. Feedback endpoint no longer writes rows for unknown tickets or invalid ratings; all database writes use parameters (no string-built SQL).
6. Database password can be set from `.env`; secrets are never printed by the scripts and `.env` stays git-ignored.
7. Image versions are pinned, so an upstream release cannot silently change behaviour.
8. Failures now alert the support team instead of failing silently.
9. The API reply no longer exposes anything about the customer; it returns only the new ticket ID.

## 7. Recommended future improvements

1. Set `SUPPORT_API_KEY`, configure real SMTP, and test one real email.
2. Add a pending/failed status to tickets, plus a retry job.
3. Human review before sending refund-related emails.
4. HTTPS reverse proxy with rate limiting for any public use.
5. Automated backups of the `postgres16_data` and `qdrant_storage` volumes and of the `workflows` folder (it holds the n8n encryption key).
6. A small dashboard (for example Metabase) over `support_requests` and `customer_feedback`.
7. A CI job that runs `test-webhooks.ps1` and the Newman collection.

---

## 8. Exact commands to run the application

Run from the project folder in PowerShell. Docker Desktop must be running.

```powershell
copy .env.example .env                 # first time only; then edit .env and add GEMINI_API_KEY
.\scripts\setup.ps1                    # start everything, import + publish the workflow, prepare the database
.\scripts\test-gemini.ps1              # check the Gemini key
.\scripts\ingest-knowledge-base.ps1    # first time only: load the FAQ into Qdrant
.\scripts\test-webhooks.ps1            # end-to-end test (must say "All checks passed")
```

Everyday use:

```powershell
docker compose up -d                   # start
docker compose ps                      # status
docker compose logs n8n --tail 50      # logs
docker compose stop                    # stop (keeps all data)
npx newman run postman\AI-Customer-Support.postman_collection.json --env-var hook=webhook   # run the Postman tests from the command line
```

n8n editor: http://localhost:5678

Do **not** run `docker compose down -v`: it deletes the database and Qdrant volumes.

What you need to configure yourself:

| Setting (in `.env`) | Needed for |
|---|---|
| `GEMINI_API_KEY` | All AI features (required) |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM` | Sending real emails (optional; without it the email steps fail quietly) |
| `SUPPORT_ALERT_EMAIL` | Where angry-customer and error alerts go |
| `GEMINI_FALLBACK_MODEL` | Optional. Model used when the main one is overloaded. Default `gemini-3.5-flash-lite`. |
| `SUPPORT_API_KEY` | Locking the support webhook (recommended) |
| `WEBHOOK_URL` | The public address used in the feedback links inside emails. Must be reachable by your customers, not `localhost`, in production. |

---

## 9. Final project status

**Working and tested locally:** both webhooks, input validation, ticket numbering, RAG answers through Qdrant, refund path, sentiment saving, angry-customer alert, customer email, feedback endpoint, error alert, database migration, Docker startup, Postman collection.

**Needs your action before real use:** real SMTP settings, `SUPPORT_API_KEY`, a public `WEBHOOK_URL`, and a commit of the changes.

**Not production-ready yet because of:** the open items in section 5 (no rate limiting, prompt injection, no retry for failed AI calls, default database password).
