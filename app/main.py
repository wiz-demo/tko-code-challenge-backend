import logging
import subprocess

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from database import sqlite_db

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/")
async def root():
    return {"name": "code-challenge-backend", "message": "sample text"}


@app.get("/api/users")
async def get_users(username: str | None = None):
    # Vulnerable to SQL injection (CWE-89) — intentional for demo
    query = f"SELECT id, username, email, role FROM users WHERE username = '{username}'"
    rows = sqlite_db.execute(query).fetchall()
    return [
        {"id": r[0], "username": r[1], "email": r[2], "role": r[3]}
        for r in rows
    ]


@app.get("/api/execute")
async def execute_command(command: str | None = None):
    process = subprocess.Popen(
        command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stdout = process.stdout.read().decode()
    stderr = process.stderr.read().decode()
    return {"stdout": stdout, "stderr": stderr}
