#!/usr/bin/env python3
"""Small, dependency-free community service for the G1R integrated mod."""

from __future__ import annotations

import argparse
import hmac
import json
import os
import re
import sqlite3
import threading
import time
import unicodedata
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


APP_VERSION = "1.1.0"
MAX_JSON_BYTES = 16 * 1024
MAX_NICKNAME_LENGTH = 24
MAX_MESSAGE_LENGTH = 500
PLAYER_PREFIX = "玩家·"
ADMIN_NAME = "管理员"
SAFE_VERSION = re.compile(r"^[A-Za-z0-9._+-]{1,32}$")


def utc_iso(epoch: int | None = None) -> str:
    value = time.time() if epoch is None else epoch
    return datetime.fromtimestamp(value, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def validate_uuid(value: object) -> str:
    text = str(value or "").strip()
    parsed = uuid.UUID(text)
    if str(parsed) != text.lower():
        raise ValueError("invalid client id")
    return text.lower()


def validate_optional_message_id(value: object) -> int | None:
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        raise ValueError("invalid reply target")
    message_id = int(value)
    if message_id <= 0:
        raise ValueError("invalid reply target")
    return message_id


def clean_text(value: object, maximum: int, *, multiline: bool) -> str:
    text = unicodedata.normalize("NFKC", str(value or ""))
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    cleaned: list[str] = []
    for char in text:
        if char == "\n" and multiline:
            cleaned.append(char)
            continue
        if unicodedata.category(char).startswith("C"):
            continue
        cleaned.append(char)
    result = "".join(cleaned).strip()
    if not result:
        raise ValueError("text is empty")
    if len(result) > maximum:
        raise ValueError(f"text exceeds {maximum} characters")
    return result


class Store:
    def __init__(self, database_path: Path):
        self.database_path = database_path
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        self._write_lock = threading.Lock()
        self.initialize()

    def connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 10000")
        return connection

    @contextmanager
    def session(self):
        connection = self.connect()
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def initialize(self) -> None:
        with self.session() as connection:
            connection.executescript(
                """
                PRAGMA journal_mode = WAL;
                CREATE TABLE IF NOT EXISTS installations (
                    install_id TEXT PRIMARY KEY,
                    first_seen INTEGER NOT NULL,
                    last_seen INTEGER NOT NULL,
                    version TEXT NOT NULL,
                    install_events INTEGER NOT NULL DEFAULT 1
                );
                CREATE TABLE IF NOT EXISTS messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    client_id TEXT,
                    role TEXT NOT NULL CHECK (role IN ('player', 'admin')),
                    nickname TEXT NOT NULL,
                    body TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    reply_to_id INTEGER
                );
                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_messages_created
                    ON messages(created_at DESC, id DESC);
                CREATE INDEX IF NOT EXISTS idx_messages_client_created
                    ON messages(client_id, created_at DESC);
                """
            )
            columns = {row["name"] for row in connection.execute("PRAGMA table_info(messages)")}
            if "reply_to_id" not in columns:
                connection.execute("ALTER TABLE messages ADD COLUMN reply_to_id INTEGER")
            connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_messages_reply ON messages(reply_to_id)"
            )
            connection.execute(
                "INSERT OR IGNORE INTO settings(key, value) VALUES ('board_open', '1')"
            )

    def record_install(self, install_id: str, version: str) -> dict[str, int]:
        now = int(time.time())
        with self._write_lock, self.session() as connection:
            connection.execute(
                """
                INSERT INTO installations(install_id, first_seen, last_seen, version, install_events)
                VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(install_id) DO UPDATE SET
                    last_seen = excluded.last_seen,
                    version = excluded.version,
                    install_events = installations.install_events + 1
                """,
                (install_id, now, now, version),
            )
            return self.stats(connection)

    def stats(self, connection: sqlite3.Connection | None = None) -> dict[str, int]:
        owns_connection = connection is None
        connection = connection or self.connect()
        try:
            row = connection.execute(
                """
                SELECT
                    (SELECT COUNT(*) FROM installations) AS unique_installs,
                    (SELECT COALESCE(SUM(install_events), 0) FROM installations) AS install_events,
                    (SELECT COUNT(*) FROM messages) AS messages
                """
            ).fetchone()
            return {key: int(row[key]) for key in ("unique_installs", "install_events", "messages")}
        finally:
            if owns_connection:
                connection.close()

    def board_open(self, connection: sqlite3.Connection | None = None) -> bool:
        owns_connection = connection is None
        connection = connection or self.connect()
        try:
            row = connection.execute(
                "SELECT value FROM settings WHERE key = 'board_open'"
            ).fetchone()
            return row is None or row["value"] == "1"
        finally:
            if owns_connection:
                connection.close()

    def set_board_open(self, is_open: bool) -> None:
        with self._write_lock, self.session() as connection:
            connection.execute(
                """
                INSERT INTO settings(key, value) VALUES ('board_open', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                ("1" if is_open else "0",),
            )

    def list_messages(self, limit: int) -> list[dict[str, object]]:
        with self.session() as connection:
            rows = connection.execute(
                """
                SELECT
                    message.id,
                    message.role,
                    message.nickname,
                    message.body,
                    message.created_at,
                    message.reply_to_id,
                    parent.role AS parent_role,
                    parent.nickname AS parent_nickname,
                    parent.body AS parent_body
                FROM messages AS message
                LEFT JOIN messages AS parent ON parent.id = message.reply_to_id
                ORDER BY message.id DESC
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
        result = []
        for row in reversed(rows):
            display_name = ADMIN_NAME if row["role"] == "admin" else PLAYER_PREFIX + row["nickname"]
            reply_display_name = None
            if row["reply_to_id"] is not None and row["parent_role"] is not None:
                reply_display_name = (
                    ADMIN_NAME
                    if row["parent_role"] == "admin"
                    else PLAYER_PREFIX + row["parent_nickname"]
                )
            result.append(
                {
                    "id": int(row["id"]),
                    "role": row["role"],
                    "display_name": display_name,
                    "message": row["body"],
                    "created_at": utc_iso(int(row["created_at"])),
                    "reply_to_id": int(row["reply_to_id"]) if row["reply_to_id"] is not None else None,
                    "reply_to_display_name": reply_display_name,
                    "reply_to_message": row["parent_body"] if reply_display_name else None,
                }
            )
        return result

    @staticmethod
    def require_reply_target(connection: sqlite3.Connection, reply_to_id: int | None) -> None:
        if reply_to_id is None:
            return
        exists = connection.execute(
            "SELECT 1 FROM messages WHERE id = ?",
            (reply_to_id,),
        ).fetchone()
        if exists is None:
            raise ValueError("reply target was not found")

    def add_player_message(
        self,
        client_id: str,
        nickname: str,
        body: str,
        reply_to_id: int | None,
    ) -> int:
        now = int(time.time())
        with self._write_lock, self.session() as connection:
            if not self.board_open(connection):
                raise BoardClosedError("the community board is temporarily closed")
            self.require_reply_target(connection, reply_to_id)
            recent_minute = connection.execute(
                "SELECT COUNT(*) FROM messages WHERE client_id = ? AND created_at >= ?",
                (client_id, now - 60),
            ).fetchone()[0]
            recent_hour = connection.execute(
                "SELECT COUNT(*) FROM messages WHERE client_id = ? AND created_at >= ?",
                (client_id, now - 3600),
            ).fetchone()[0]
            if recent_minute >= 3 or recent_hour >= 20:
                raise RateLimitError("please wait before posting again")
            cursor = connection.execute(
                """
                INSERT INTO messages(client_id, role, nickname, body, created_at, reply_to_id)
                VALUES (?, 'player', ?, ?, ?, ?)
                """,
                (client_id, nickname, body, now, reply_to_id),
            )
            return int(cursor.lastrowid)

    def add_admin_message(self, body: str, reply_to_id: int | None) -> int:
        now = int(time.time())
        with self._write_lock, self.session() as connection:
            self.require_reply_target(connection, reply_to_id)
            cursor = connection.execute(
                """
                INSERT INTO messages(client_id, role, nickname, body, created_at, reply_to_id)
                VALUES (NULL, 'admin', '', ?, ?, ?)
                """,
                (body, now, reply_to_id),
            )
            return int(cursor.lastrowid)

    def delete_message(self, message_id: int) -> bool:
        with self._write_lock, self.session() as connection:
            connection.execute(
                "UPDATE messages SET reply_to_id = NULL WHERE reply_to_id = ?",
                (message_id,),
            )
            cursor = connection.execute("DELETE FROM messages WHERE id = ?", (message_id,))
            return cursor.rowcount > 0

    def clear_messages(self) -> int:
        with self._write_lock, self.session() as connection:
            cursor = connection.execute("DELETE FROM messages")
            return cursor.rowcount


class RateLimitError(RuntimeError):
    pass


class BoardClosedError(RuntimeError):
    pass


class CommunityServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address: tuple[str, int],
        handler: type[BaseHTTPRequestHandler],
        *,
        store: Store,
        admin_token: str,
        web_root: Path,
    ):
        super().__init__(address, handler)
        self.store = store
        self.admin_token = admin_token
        self.web_root = web_root


class Handler(BaseHTTPRequestHandler):
    server: CommunityServer
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        # Deliberately omit client IP addresses from application logs.
        print(f"{utc_iso()} {self.command} {urlparse(self.path).path}", flush=True)

    def _headers(self, status: HTTPStatus, content_type: str, length: int, *, cache: str = "no-store") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self'; "
            "img-src 'self' data:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'",
        )
        self.end_headers()

    def _json(self, status: HTTPStatus, payload: object) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self._headers(status, "application/json; charset=utf-8", len(body))
        self.wfile.write(body)

    def _error(self, status: HTTPStatus, code: str, message: str) -> None:
        self._json(status, {"ok": False, "error": code, "message": message})

    def _read_json(self) -> dict[str, object]:
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type != "application/json":
            raise RequestError(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, "content_type", "JSON is required")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise RequestError(HTTPStatus.BAD_REQUEST, "content_length", "invalid content length") from exc
        if length <= 0 or length > MAX_JSON_BYTES:
            raise RequestError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "request_size", "request body is too large")
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise RequestError(HTTPStatus.BAD_REQUEST, "json", "invalid JSON") from exc
        if not isinstance(payload, dict):
            raise RequestError(HTTPStatus.BAD_REQUEST, "json", "JSON object is required")
        return payload

    def _authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        provided = header[7:] if header.startswith("Bearer ") else ""
        return bool(provided) and hmac.compare_digest(provided, self.server.admin_token)

    def _require_admin(self) -> bool:
        if self._authorized():
            return True
        self._error(HTTPStatus.UNAUTHORIZED, "unauthorized", "administrator token required")
        return False

    def _serve_static(self, relative_path: str, content_type: str) -> None:
        path = (self.server.web_root / relative_path).resolve()
        if self.server.web_root.resolve() not in path.parents:
            self._error(HTTPStatus.NOT_FOUND, "not_found", "not found")
            return
        try:
            body = path.read_bytes()
        except FileNotFoundError:
            self._error(HTTPStatus.NOT_FOUND, "not_found", "not found")
            return
        self._headers(HTTPStatus.OK, content_type, len(body), cache="public, max-age=300")
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/api/v1/health":
            self._json(HTTPStatus.OK, {"ok": True, "version": APP_VERSION})
            return
        if parsed.path == "/api/v1/messages":
            query = parse_qs(parsed.query)
            try:
                limit = min(100, max(1, int(query.get("limit", ["80"])[0])))
            except ValueError:
                limit = 80
            self._json(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "messages": self.server.store.list_messages(limit),
                    "stats": self.server.store.stats(),
                    "board_open": self.server.store.board_open(),
                },
            )
            return
        if parsed.path == "/api/v1/admin/overview":
            if not self._require_admin():
                return
            self._json(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "messages": self.server.store.list_messages(100),
                    "stats": self.server.store.stats(),
                    "board_open": self.server.store.board_open(),
                },
            )
            return
        static_files = {
            "/": ("index.html", "text/html; charset=utf-8"),
            "/admin": ("admin.html", "text/html; charset=utf-8"),
            "/assets/styles.css": ("styles.css", "text/css; charset=utf-8"),
            "/assets/app.js": ("app.js", "application/javascript; charset=utf-8"),
            "/assets/admin.js": ("admin.js", "application/javascript; charset=utf-8"),
            "/favicon.ico": ("favicon.svg", "image/svg+xml"),
        }
        if parsed.path in static_files:
            self._serve_static(*static_files[parsed.path])
            return
        self._error(HTTPStatus.NOT_FOUND, "not_found", "not found")

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        try:
            payload = self._read_json()
            if parsed.path == "/api/v1/installations":
                install_id = validate_uuid(payload.get("install_id"))
                version = str(payload.get("version") or "").strip()
                if not SAFE_VERSION.fullmatch(version):
                    raise ValueError("invalid version")
                stats = self.server.store.record_install(install_id, version)
                self._json(HTTPStatus.OK, {"ok": True, "stats": stats})
                return
            if parsed.path == "/api/v1/messages":
                client_id = validate_uuid(payload.get("client_id"))
                nickname = clean_text(payload.get("nickname"), MAX_NICKNAME_LENGTH, multiline=False)
                for prefix in ("玩家·", "玩家", "Player·", "Player"):
                    if nickname.startswith(prefix):
                        nickname = nickname[len(prefix) :].lstrip(" ·:：")
                        break
                nickname = clean_text(nickname, MAX_NICKNAME_LENGTH, multiline=False)
                body = clean_text(payload.get("message"), MAX_MESSAGE_LENGTH, multiline=True)
                reply_to_id = validate_optional_message_id(payload.get("reply_to_id"))
                message_id = self.server.store.add_player_message(
                    client_id,
                    nickname,
                    body,
                    reply_to_id,
                )
                self._json(HTTPStatus.CREATED, {"ok": True, "id": message_id})
                return
            if parsed.path == "/api/v1/admin/messages":
                if not self._require_admin():
                    return
                body = clean_text(payload.get("message"), MAX_MESSAGE_LENGTH, multiline=True)
                reply_to_id = validate_optional_message_id(payload.get("reply_to_id"))
                message_id = self.server.store.add_admin_message(body, reply_to_id)
                self._json(HTTPStatus.CREATED, {"ok": True, "id": message_id})
                return
            if parsed.path == "/api/v1/admin/settings":
                if not self._require_admin():
                    return
                board_open = payload.get("board_open")
                if not isinstance(board_open, bool):
                    raise ValueError("board_open must be true or false")
                self.server.store.set_board_open(board_open)
                self._json(HTTPStatus.OK, {"ok": True, "board_open": board_open})
                return
            self._error(HTTPStatus.NOT_FOUND, "not_found", "not found")
        except RequestError as exc:
            self._error(exc.status, exc.code, exc.message)
        except RateLimitError as exc:
            self._error(HTTPStatus.TOO_MANY_REQUESTS, "rate_limited", str(exc))
        except BoardClosedError as exc:
            self._error(HTTPStatus.LOCKED, "board_closed", str(exc))
        except (ValueError, TypeError) as exc:
            self._error(HTTPStatus.BAD_REQUEST, "invalid_input", str(exc))
        except Exception:
            self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "server_error", "request failed")

    def do_DELETE(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/api/v1/admin/messages":
            if not self._require_admin():
                return
            deleted = self.server.store.clear_messages()
            self._json(HTTPStatus.OK, {"ok": True, "deleted": deleted})
            return
        match = re.fullmatch(r"/api/v1/admin/messages/(\d+)", parsed.path)
        if not match:
            self._error(HTTPStatus.NOT_FOUND, "not_found", "not found")
            return
        if not self._require_admin():
            return
        deleted = self.server.store.delete_message(int(match.group(1)))
        if not deleted:
            self._error(HTTPStatus.NOT_FOUND, "not_found", "message not found")
            return
        self._json(HTTPStatus.OK, {"ok": True})


class RequestError(RuntimeError):
    def __init__(self, status: HTTPStatus, code: str, message: str):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def build_server(
    host: str,
    port: int,
    database_path: Path,
    admin_token: str,
    web_root: Path | None = None,
) -> CommunityServer:
    if len(admin_token) < 32:
        raise ValueError("G1R_COMMUNITY_ADMIN_TOKEN must contain at least 32 characters")
    root = web_root or (Path(__file__).resolve().parent / "web")
    return CommunityServer(
        (host, port),
        Handler,
        store=Store(database_path),
        admin_token=admin_token,
        web_root=root,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=os.environ.get("G1R_COMMUNITY_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("G1R_COMMUNITY_PORT", "18182")))
    parser.add_argument(
        "--database",
        type=Path,
        default=Path(os.environ.get("G1R_COMMUNITY_DATABASE", "/var/lib/g1r-community/community.sqlite3")),
    )
    arguments = parser.parse_args()
    admin_token = os.environ.get("G1R_COMMUNITY_ADMIN_TOKEN", "")
    server = build_server(arguments.host, arguments.port, arguments.database, admin_token)
    print(f"G1R community service {APP_VERSION} listening on {arguments.host}:{arguments.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
