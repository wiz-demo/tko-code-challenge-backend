# SQL Injection Demo Endpoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an intentional, live SQL injection vulnerability (CWE-89) at `GET /api/users` backed by an in-memory sqlite users table, matching the existing demo-vulnerability style in `app/main.py`.

**Architecture:** Two small additions to two existing files. `app/database.py` gains a synchronous `sqlite3` in-memory connection seeded at module load. `app/main.py` gains a new FastAPI route that builds its SQL with f-string interpolation of the `username` query parameter and passes it to `sqlite3.Connection.execute()`.

**Tech Stack:** Python stdlib `sqlite3` (no new dependencies), existing FastAPI + uvicorn stack.

**Spec:** [docs/superpowers/specs/2026-06-01-sql-injection-demo-design.md](../specs/2026-06-01-sql-injection-demo-design.md)

**Note on testing:** The approved spec explicitly opts out of automated tests to match the style of the existing intentional-vulnerability endpoints (`/api/execute`, `/api/import_prompts`), which are also untested. Verification in this plan is therefore manual: importing the module, starting uvicorn, and exercising the endpoint with `curl`.

**Local prerequisites:** `app/database.py` initialises a Mongo client at module load. Importing or starting the app requires placeholder env vars even if no Mongo server is running:

```bash
export MONGO_URI=mongodb://localhost:27017
export MONGO_DB=sorcery_demo
```

(Mongo itself does NOT need to be reachable — motor connects lazily. Only the env vars must be set so `client[MONGO_DB]` does not receive `None`.)

---

## Task 1: Add in-memory sqlite users table to `app/database.py`

**Files:**
- Modify: `app/database.py`

- [ ] **Step 1: Read the current file to confirm starting state**

Run: `cat app/database.py`

Expected: the file contains exactly the Motor/Mongo setup — `MONGO_URI`, `MONGO_DB`, `client`, `db`. No `sqlite3` import.

- [ ] **Step 2: Replace `app/database.py` with the new content**

Overwrite `app/database.py` with:

```python
import os
import sqlite3

import motor.motor_asyncio

from dotenv import load_dotenv

load_dotenv()

MONGO_URI = os.getenv("MONGO_URI")
MONGO_DB = os.getenv("MONGO_DB")

client = motor.motor_asyncio.AsyncIOMotorClient(MONGO_URI)
db = client[MONGO_DB]

# In-memory sqlite users table used by the intentionally vulnerable
# /api/users endpoint (CWE-89 demo). Connection is shared across uvicorn
# worker threads, so check_same_thread must be False.
sqlite_db = sqlite3.connect(":memory:", check_same_thread=False)
sqlite_db.execute(
    "CREATE TABLE users ("
    "id INTEGER PRIMARY KEY, "
    "username TEXT NOT NULL, "
    "email TEXT NOT NULL, "
    "role TEXT NOT NULL"
    ")"
)
sqlite_db.executemany(
    "INSERT INTO users (id, username, email, role) VALUES (?, ?, ?, ?)",
    [
        (1, "alice", "alice@example.com", "user"),
        (2, "bob", "bob@example.com", "user"),
        (3, "admin", "admin@sorcery.example", "admin"),
    ],
)
sqlite_db.commit()
```

- [ ] **Step 3: Smoke-test the import and seed data**

Run from the repo root:

```bash
MONGO_URI=mongodb://localhost:27017 MONGO_DB=sorcery_demo \
  python -c "
import sys
sys.path.insert(0, 'app')
from database import sqlite_db
rows = sqlite_db.execute('SELECT id, username, email, role FROM users ORDER BY id').fetchall()
for r in rows: print(r)
"
```

Expected output (exactly three lines):

```
(1, 'alice', 'alice@example.com', 'user')
(2, 'bob', 'bob@example.com', 'user')
(3, 'admin', 'admin@sorcery.example', 'admin')
```

If you see `TypeError: name must be an instance of str` or similar, the `MONGO_DB` env var is missing — re-export it.

- [ ] **Step 4: Commit**

```bash
git add app/database.py
git commit -m "feat: add in-memory sqlite users table for demo endpoint"
```

---

## Task 2: Add the vulnerable `GET /api/users` endpoint to `app/main.py`

**Files:**
- Modify: `app/main.py` (import line on line 10, new endpoint added after `/api/prompts` block, before `/api/execute`)

- [ ] **Step 1: Read the current file to confirm starting state**

Run: `sed -n '1,15p' app/main.py`

Expected line 10: `from database import db`. (No `sqlite_db` in the import yet.)

- [ ] **Step 2: Update the `database` import in `app/main.py`**

Change line 10 from:

```python
from database import db
```

to:

```python
from database import db, sqlite_db
```

- [ ] **Step 3: Add the vulnerable endpoint**

Insert this block in `app/main.py` immediately AFTER the `@app.get("/api/prompts")` function (the `get_all_prompts` block that ends around line 57) and BEFORE the `@app.get("/api/execute")` block:

```python
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

(Placement next to the other intentionally vulnerable endpoints — `/api/execute` and `/api/import_prompts` — keeps the demo vulnerabilities visually grouped.)

- [ ] **Step 4: Start uvicorn in the background**

`app/main.py` uses top-level imports (`from schemas import ...`, `from database import db`), so uvicorn must be invoked with `app/` on `PYTHONPATH`:

```bash
MONGO_URI=mongodb://localhost:27017 MONGO_DB=sorcery_demo PYTHONPATH=app \
  uvicorn main:app --host 127.0.0.1 --port 8765 > /tmp/uvicorn.log 2>&1 &
echo $! > /tmp/uvicorn.pid
sleep 2
cat /tmp/uvicorn.log
```

Expected: `/tmp/uvicorn.log` ends with a line like `Uvicorn running on http://127.0.0.1:8765`. No tracebacks. If you see `ModuleNotFoundError: No module named 'schemas'`, `PYTHONPATH=app` was missing.

- [ ] **Step 5: Verify a benign request**

```bash
curl -s 'http://127.0.0.1:8765/api/users?username=alice'
```

Expected output (single JSON line, formatted here for readability):

```json
[{"id":1,"username":"alice","email":"alice@example.com","role":"user"}]
```

- [ ] **Step 6: Verify the SQL injection exploit returns all rows**

```bash
curl -s --get 'http://127.0.0.1:8765/api/users' --data-urlencode "username=' OR '1'='1"
```

Expected output (all three seeded users):

```json
[{"id":1,"username":"alice","email":"alice@example.com","role":"user"},{"id":2,"username":"bob","email":"bob@example.com","role":"user"},{"id":3,"username":"admin","email":"admin@sorcery.example","role":"admin"}]
```

If you instead see `[]`, the f-string interpolation did not happen — confirm Step 3's `query = f"..."` uses an `f` prefix and single quotes around `{username}`.

- [ ] **Step 7: Verify existing endpoints are still registered**

```bash
curl -s 'http://127.0.0.1:8765/openapi.json' | python -c "
import json, sys
spec = json.load(sys.stdin)
print(sorted(spec['paths'].keys()))
"
```

Expected output:

```
['/api/chat', '/api/execute', '/api/import_prompts', '/api/prompts', '/api/users']
```

The new `/api/users` appears alongside all four pre-existing paths. If any pre-existing path is missing, something else was changed by accident — investigate before committing.

- [ ] **Step 8: Stop uvicorn**

```bash
kill "$(cat /tmp/uvicorn.pid)" && rm /tmp/uvicorn.pid
```

- [ ] **Step 9: Commit**

```bash
git add app/main.py
git commit -m "feat: add vulnerable GET /api/users endpoint (CWE-89)

Intentional SQL injection demo against the in-memory sqlite users
table introduced in the previous commit. F-string interpolation of
the username query param into sqlite3 Connection.execute() trips
CWE-89 SAST rules and is exploitable at runtime."
```

---

## Done criteria

- [ ] Both commits land on the working branch.
- [ ] `curl 'http://127.0.0.1:8765/api/users?username=alice'` returns alice's row.
- [ ] `curl --get 'http://127.0.0.1:8765/api/users' --data-urlencode "username=' OR '1'='1"` returns all three rows.
- [ ] `/openapi.json` lists `/api/users` alongside the four pre-existing routes.
- [ ] No new files outside `docs/superpowers/`. No changes to `requirements.txt`, `Dockerfile`, helm charts, or CI workflows.
- [ ] (Post-merge, out-of-band) Wiz SAST scan via `build-scan-push.yml` reports a new CWE-89 / MEDIUM finding on `app/main.py`.
