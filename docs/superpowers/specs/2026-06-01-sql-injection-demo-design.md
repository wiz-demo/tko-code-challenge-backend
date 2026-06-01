# SQL Injection Demo Endpoint (CWE-89)

**Date:** 2026-06-01
**Status:** Approved
**Repo:** summit-code-challenge-backend (Wiz security demo / CTF)

## Goal

Add an intentional, **live** SQL injection vulnerability to the existing Wiz
security demo backend, so that:

- SAST tools (Wiz, Bandit, Semgrep) flag the pattern as **CWE-89 (MEDIUM)**.
- Red-team agents / CTF participants can exploit the endpoint at runtime.
- Style matches the existing intentional vulnerabilities already in
  `app/main.py` (`subprocess.Popen(..., shell=True)` and
  `yaml.load(..., Loader=yaml.Loader)`).

This is not a detection-only demo. The endpoint is wired into the running app
and is genuinely exploitable. That is appropriate for this repository because
it is explicitly a demo / CTF target — the README already states *"This repo is
for demo purposes only. All secret keys and sensitive data are fake."*

## Non-goals

- No side-by-side "secure" implementation.
- No README, no inline educational comments beyond a single short marker.
- No tests (existing demo endpoints are also untested).
- No new third-party dependencies.
- No changes to MongoDB code paths or existing endpoints.

## Architecture

Two small additions to two existing files:

```
app/
  database.py   # + in-memory sqlite3 connection + seeded users table
  main.py       # + GET /api/users endpoint (vulnerable f-string SQL)
```

No new files, no new directories, no new packages.

## Components

### 1. In-memory sqlite users DB — `app/database.py`

Add alongside the existing async Mongo client. Connection is created once at
module load, kept open for the process lifetime, and accessible from FastAPI
handlers without a per-request setup cost.

- Connection: `sqlite3.connect(":memory:", check_same_thread=False)`
  (`check_same_thread=False` is required because FastAPI/uvicorn dispatches
  requests across threads; the connection is read-mostly and exploit traffic
  is single-user demo traffic, so locking is not a concern.)
- Schema:

  ```sql
  CREATE TABLE users (
      id       INTEGER PRIMARY KEY,
      username TEXT NOT NULL,
      email    TEXT NOT NULL,
      role     TEXT NOT NULL
  );
  ```

- Seed rows (committed at module load):

  | id | username | email                 | role  |
  |----|----------|-----------------------|-------|
  | 1  | alice    | alice@example.com     | user  |
  | 2  | bob      | bob@example.com       | user  |
  | 3  | admin    | admin@sorcery.example | admin |

- Export: `sqlite_db` (a `sqlite3.Connection`).

The existing `db` (Motor / Mongo) export remains unchanged.

### 2. Vulnerable lookup endpoint — `app/main.py`

Add a new route, importing `sqlite_db` from `database`.

```python
from database import db, sqlite_db
...

@app.get("/api/users")
async def get_users(username: str | None = None):
    # Vulnerable to SQL injection (CWE-89) — intentional for demo
    query = f"SELECT id, username, email, role FROM users WHERE username = '{username}'"
    rows = sqlite_db.execute(query).fetchall()
    return [
        {"id": r[0], "username": r[1], "email": r[2], "role": r[3]}
        for r in rows
    ]
```

The single comment matches the style of the existing
`# Use yaml.load (vulnerable to arbitrary code execution)` comment in
`/api/import_prompts`.

If `username` is `None` (no query param), the f-string interpolates the
literal string `"None"`, which yields zero rows — acceptable for a demo and
consistent with how other endpoints handle missing input loosely.

## Runtime behavior

| Request | Result |
|---------|--------|
| `GET /api/users?username=alice` | Returns the `alice` row. |
| `GET /api/users?username=' OR '1'='1` | Returns **all rows** (auth-bypass-style). |
| `GET /api/users?username=' UNION SELECT sql, name, type, '' FROM sqlite_master --` | Leaks the table schema. |
| `GET /api/users` (no param) | Returns `[]`. |

## What SAST should flag

- f-string-built SQL passed to `sqlite3.Connection.execute()`.
- Bandit: `B608` (`hardcoded_sql_expressions`).
- Semgrep / Wiz SAST: CWE-89 rules covering string interpolation into
  `sqlite3` execute calls.
- Expected severity: **MEDIUM**.

## Verification checklist (post-implementation)

- [ ] `uvicorn app.main:app` starts cleanly with no import errors.
- [ ] `GET /api/users?username=alice` returns the seeded `alice` row.
- [ ] `GET /api/users?username=' OR '1'='1` returns all three seeded rows.
- [ ] Existing endpoints (`/api/prompts`, `/api/execute`, `/api/import_prompts`,
      `/api/chat`) still respond as before.
- [ ] Wiz SAST scan (via the existing `build-scan-push.yml` pipeline) reports
      a new CWE-89 finding on the `app/main.py` change.

## Out of scope

- Persistence of `users` data across restarts.
- Authentication / authorization on the endpoint.
- Hardening the existing intentional vulnerabilities.
- Removing the existing `subprocess` / `yaml.load` vulnerabilities.
- Adding a secure / parameterized alternative endpoint.
- Updating the project README.
