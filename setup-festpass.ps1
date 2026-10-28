# Usage (run INSIDE your cloned <REGNO>-dockerassessment folder):
#   .\setup-festpass.ps1 -Regno 12345637 -DhUser yourdockerhubuser
param(
  [Parameter(Mandatory = $true)][string]$Regno,
  [Parameter(Mandatory = $true)][string]$DhUser
)

$Port = "80" + $Regno.Substring($Regno.Length - 2)
$utf8 = New-Object System.Text.UTF8Encoding $false

function W($path, $content) {
  $dir = Split-Path $path -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $full = Join-Path (Get-Location) $path
  [System.IO.File]::WriteAllText($full, ($content -replace "`r`n", "`n"), $utf8)
}

foreach ($d in "backend", "frontend", "reports", "screenshots", "_stage_files") {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

# ---------------- backend/app.py ----------------
W "backend/app.py" @'
"""FestPass registration API (starter code)."""
import os
import signal
import socket
import sys
import threading
from contextlib import closing

import psycopg2
from flask import Flask, jsonify, request

app = Flask(__name__)
REGNO = os.getenv("REGNO", "NOT-SET")
APP_VERSION = os.getenv("APP_VERSION", "dev")

TABLE_SQL = """CREATE TABLE IF NOT EXISTS registrations (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  event TEXT NOT NULL,
  created TIMESTAMPTZ NOT NULL DEFAULT now())"""
_table_lock = threading.Lock()
_table_ready = False


def connect():
    return psycopg2.connect(
        host=os.getenv("DB_HOST", "localhost"),
        dbname=os.getenv("DB_NAME", "festpass"),
        user=os.getenv("DB_USER", "festpass"),
        password=os.getenv("DB_PASSWORD", ""),
        connect_timeout=3,
    )


def run_sql(sql, params=(), fetch=False):
    """Create the table on first use, run one statement, commit and close."""
    global _table_ready
    with _table_lock:
        if not _table_ready:
            with closing(connect()) as conn, conn, conn.cursor() as cur:
                cur.execute(TABLE_SQL)
            _table_ready = True
    with closing(connect()) as conn, conn, conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall() if fetch else None


@app.errorhandler(psycopg2.Error)
def database_error(err):
    return jsonify(error="database unavailable"), 503


@app.get("/api/health")
def health():
    try:
        run_sql("SELECT 1")
        database = True
    except psycopg2.Error:
        database = False
    return jsonify(service="festpass-backend", regno=REGNO,
                   version=APP_VERSION,
                   container=socket.gethostname(), database=database)


@app.get("/api/registrations")
def list_registrations():
    rows = run_sql("SELECT id, name, event, created FROM registrations ORDER BY id", fetch=True)
    return jsonify([{"id": i, "name": n, "event": e, "created": c.isoformat(timespec="seconds")}
                    for i, n, e, c in rows])


@app.post("/api/registrations")
def add_registration():
    data = request.get_json(silent=True) or {}
    name = str(data.get("name", "")).strip()
    event = str(data.get("event", "")).strip()
    if not name or not event:
        return jsonify(error="name and event are required"), 400
    new_id = run_sql("INSERT INTO registrations (name, event) VALUES (%s, %s) RETURNING id",
                     (name, event), fetch=True)[0][0]
    return jsonify(id=new_id, name=name, event=event), 201


if __name__ == "__main__":
    # Exit promptly on `docker stop` instead of waiting to be killed.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    app.run(host="0.0.0.0", port=5000)
'@

# ---------------- backend/requirements.txt (starter versions) ----------------
W "backend/requirements.txt" @'
Flask==2.2.2
Werkzeug==2.2.2
psycopg2-binary==2.9.10
'@

# ---------------- frontend ----------------
W "frontend/index.html" @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>FestPass 2026</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 640px; margin: 2rem auto; padding: 0 1rem; }
  #status { padding: 0.5rem; background: #eef2ff; }
</style>
</head>
<body>
<h1>FestPass 2026 registrations</h1>
<p id="status">Checking the backend…</p>
<form id="form">
  <input id="name" placeholder="Your name" required>
  <select id="event">
    <option>Hackathon</option>
    <option>Robo Race</option>
    <option>Tech Quiz</option>
  </select>
  <button>Register</button>
</form>
<ul id="list"></ul>
<script>
const api = (path, options) => fetch("/api/" + path, options).then(r => r.json());

async function refresh() {
  const status = document.getElementById("status");
  try {
    const h = await api("health");
    status.textContent = `REGNO ${h.regno} | backend ${h.version} on ${h.container} | database ${h.database ? "connected" : "not connected"}`;
    const rows = await api("registrations");
    document.getElementById("list").replaceChildren(...(Array.isArray(rows) ? rows : []).map(r => {
      const li = document.createElement("li");
      li.textContent = `#${r.id} ${r.name} (${r.event})`;
      return li;
    }));
  } catch (err) {
    status.textContent = "Backend not reachable";
  }
}

document.getElementById("form").addEventListener("submit", async (e) => {
  e.preventDefault();
  await api("registrations", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: document.getElementById("name").value, event: document.getElementById("event").value }),
  });
  document.getElementById("name").value = "";
  refresh();
});

refresh();
</script>
</body>
</html>
'@

W "frontend/nginx.conf" @'
server {
    listen 80;

    location / {
        root /usr/share/nginx/html;
        index index.html;
    }

    # Requests for /api/... are passed to the backend service on port 5000
    location /api/ {
        proxy_pass http://backend:5000;
    }
}
'@

# ---------------- Stage 1 Dockerfile (python:3.9, as developers want) ----------------
W "backend/Dockerfile" @'
FROM python:3.9

WORKDIR /app

# Dependencies first so this layer is cached between builds
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 5000
CMD ["python", "app.py"]
'@

W "backend/.dockerignore" @'
__pycache__/
*.pyc
*.pyo
.git
.gitignore
.env
.venv/
Dockerfile
.dockerignore
'@

# ---------------- .env / .env.example / .gitignore ----------------
$pw = -join ((48..57) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
W ".env" "DB_PASSWORD=$pw`nREGNO=$Regno`nPORT=$Port`n"
W ".env.example" "DB_PASSWORD=change-me`nREGNO=your-regno`nPORT=80xx`n"
W ".gitignore" @'
.env
*.key
__pycache__/
*.pyc
_stage_files/
'@

# ---------------- Stage 2 compose.yaml ----------------
W "compose.yaml" @'
services:
  db:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: festpass
      POSTGRES_DB: festpass
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks:
      - backend-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U festpass -d festpass"]
      interval: 5s
      timeout: 3s
      retries: 10

  backend:
    build: ./backend
    environment:
      DB_HOST: db
      DB_NAME: festpass
      DB_USER: festpass
      DB_PASSWORD: ${DB_PASSWORD}
      REGNO: ${REGNO}
    depends_on:
      db:
        condition: service_healthy
    networks:
      - frontend-net
      - backend-net

  frontend:
    image: nginx:1.30-alpine
    ports:
      - "${PORT}:80"
    volumes:
      - ./frontend/index.html:/usr/share/nginx/html/index.html:ro
      - ./frontend/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - backend
    networks:
      - frontend-net

networks:
  frontend-net:
  backend-net:

volumes:
  pgdata:
'@

# ---------------- Stage 3 files (kept outside the repo layout) ----------------
W "_stage_files/Dockerfile.stage3" @'
FROM python:3.13-slim

ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Run as a non-root user
RUN useradd --system --no-create-home --uid 10001 appuser
USER appuser

EXPOSE 5000
CMD ["python", "app.py"]
'@

W "_stage_files/requirements.stage3.txt" @'
Flask==3.1.3
Werkzeug==3.1.9
psycopg2-binary==2.9.13
'@

# ---------------- Stage 4 compose (image from Docker Hub) ----------------
$c = Get-Content compose.yaml -Raw
$c = $c -replace "    build: \./backend", "    image: $DhUser/fest-backend:1.0.0"
W "_stage_files/compose.stage4.yaml" $c

# ---------------- README template ----------------
W "README.md" @"
# FestPass - Docker & Container Security (CA-2)

- **Name:** <YOUR NAME>
- **REGNO:** $Regno
- **PORT:** $Port
- **Docker Hub username:** $DhUser
- **Docker Hub repo:** https://hub.docker.com/r/$DhUser/fest-backend

## AI tools used
- <Claude / ChatGPT / ...>: <what you used it for - writing Dockerfiles and compose, explaining errors>

## Digest of 1.0.0 (as pushed)
``sha256:<PASTE DIGEST>``

## Vulnerability before / after (3.3)
| Image | CRITICAL | HIGH | Size |
|---|---|---|---|
| fest-backend:0.1 (python:3.9) | <n> | <n> | <size> |
| fest-backend:0.2 (python:3.13-slim) | <n> | <n> | <size> |

## Steps not completed
- None
"@

Write-Host ""
Write-Host "Done. REGNO=$Regno  PORT=$Port  DockerHub=$DhUser" -ForegroundColor Green
Write-Host "Stage files are in .\_stage_files (git-ignored)."
