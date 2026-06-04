import sqlite3

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
        (3, "admin", "admin@code-challenge.example", "admin"),
    ],
)
sqlite_db.commit()
