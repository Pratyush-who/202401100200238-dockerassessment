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