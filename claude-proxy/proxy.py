#!/usr/bin/env python3
"""
Minimalistic logging proxy for Anthropic API requests.
Receives HTTP requests, logs them to SQLite, forwards to Anthropic API as HTTPS.
"""
import asyncio
import json
import os
import sqlite3
from datetime import datetime
from typing import Optional

import aiohttp
from aiohttp import web
import aiosqlite


# Configuration from environment variables
PROXY_PORT = int(os.getenv("PROXY_PORT", "8080"))
TARGET_API_URL = os.getenv("TARGET_API_URL", "https://api.anthropic.com")
DB_PATH = os.getenv("DB_PATH", "/data/requests.db")


def compact_streaming_response(raw_body: str) -> str:
    """
    Compact a Server-Sent Events (SSE) streaming response into a single JSON response.

    SSE responses from Claude API contain multiple 'data:' lines, each with a JSON chunk.
    This function consolidates them into a single response object, significantly reducing
    storage size while preserving all essential information.

    Args:
        raw_body: The raw SSE response body with multiple data: lines

    Returns:
        A compacted JSON string, or the original body if not a streaming response
    """
    if not raw_body or not raw_body.strip().startswith("event:"):
        return raw_body

    chunks = []
    content_parts = []
    metadata = {}
    usage = {}
    finish_reason = None

    for line in raw_body.split("\n"):
        line = line.strip()
        if not line.startswith("data:"):
            continue

        data_str = line[5:].strip()
        if not data_str or data_str == "[DONE]":
            continue

        try:
            chunk = json.loads(data_str)
            chunks.append(chunk)

            # Extract metadata from first chunk
            if not metadata and chunk.get("type") == "message_start":
                msg = chunk.get("message", {})
                metadata = {
                    "id": msg.get("id"),
                    "type": "message",
                    "role": msg.get("role"),
                    "model": msg.get("model"),
                    "stop_reason": msg.get("stop_reason"),
                    "stop_sequence": msg.get("stop_sequence"),
                }
                if msg.get("usage"):
                    usage = msg.get("usage", {})

            # Extract content from content_block_delta events
            if chunk.get("type") == "content_block_delta":
                delta = chunk.get("delta", {})
                if delta.get("type") == "text_delta":
                    content_parts.append(delta.get("text", ""))
                elif delta.get("type") == "thinking_delta":
                    content_parts.append(delta.get("thinking", ""))

            # Extract finish reason and final usage from message_delta
            if chunk.get("type") == "message_delta":
                delta = chunk.get("delta", {})
                if delta.get("stop_reason"):
                    finish_reason = delta.get("stop_reason")
                    metadata["stop_reason"] = finish_reason
                if chunk.get("usage"):
                    usage.update(chunk.get("usage", {}))

        except json.JSONDecodeError:
            continue

    if not chunks:
        return raw_body

    # Build compacted response
    compacted = {
        **metadata,
        "content": [{"type": "text", "text": "".join(content_parts)}],
        "usage": usage,
        "_compacted": {
            "original_chunks": len(chunks),
            "compacted_at": datetime.utcnow().isoformat()
        }
    }

    return json.dumps(compacted)


class ProxyLogger:
    """Handles SQLite logging of requests and responses."""

    def __init__(self, db_path: str):
        self.db_path = db_path

    async def run_migrations(self, db):
        """Run all migration files (SQL and Python) in order."""
        import pathlib
        import importlib.util

        migrations_dir = pathlib.Path(__file__).parent / "migrations"
        if not migrations_dir.exists():
            print(f"No migrations directory found at {migrations_dir}")
            return

        # Create migrations tracking table
        await db.execute("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                filename TEXT PRIMARY KEY,
                applied_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        """)
        await db.commit()

        # Get list of already applied migrations
        cursor = await db.execute("SELECT filename FROM schema_migrations")
        applied = {row[0] for row in await cursor.fetchall()}

        # Check if request_logs table already exists (created by old Python code)
        cursor = await db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='request_logs'"
        )
        table_exists = await cursor.fetchone() is not None

        # If table exists but 000_initial.sql wasn't tracked, mark it as applied
        if table_exists and "000_initial.sql" not in applied:
            print("  ✓ Migration 000_initial.sql already applied (table exists from previous setup)")
            await db.execute(
                "INSERT INTO schema_migrations (filename) VALUES (?)",
                ("000_initial.sql",)
            )
            await db.commit()
            applied.add("000_initial.sql")

        # Find and sort all migration files (both .sql and .py)
        sql_files = list(migrations_dir.glob("*.sql"))
        py_files = list(migrations_dir.glob("*.py"))
        migration_files = sorted(sql_files + py_files, key=lambda f: f.name)

        for migration_file in migration_files:
            filename = migration_file.name
            if filename in applied:
                # Skip printing for 000_initial.sql if we just auto-marked it above
                if not (table_exists and filename == "000_initial.sql"):
                    print(f"  ✓ Migration {filename} already applied")
                continue

            print(f"  → Applying migration {filename}...")
            try:
                if filename.endswith(".sql"):
                    # SQL migration
                    sql_content = migration_file.read_text()
                    await db.executescript(sql_content)
                elif filename.endswith(".py"):
                    # Python migration - must have an async migrate(db) function
                    spec = importlib.util.spec_from_file_location(
                        filename[:-3], migration_file
                    )
                    module = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(module)
                    if hasattr(module, "migrate"):
                        await module.migrate(db)
                    else:
                        print(f"  ⚠ Migration {filename} has no migrate() function, skipping")
                        continue

                # Record the migration as applied
                await db.execute(
                    "INSERT INTO schema_migrations (filename) VALUES (?)",
                    (filename,)
                )
                await db.commit()
                print(f"  ✓ Migration {filename} applied successfully")
            except Exception as e:
                print(f"  ✗ ERROR applying migration {filename}: {e}")
                raise

    async def init_db(self):
        """Initialize the database schema via migrations."""
        import pathlib

        # Ensure database directory exists
        db_dir = pathlib.Path(self.db_path).parent
        db_dir.mkdir(parents=True, exist_ok=True)
        print(f"Database directory: {db_dir}")

        try:
            async with aiosqlite.connect(self.db_path) as db:
                # Run all migrations (including initial schema creation)
                print("Running database migrations...")
                await self.run_migrations(db)
                print("✓ Migrations complete")

                # Verify table was created
                cursor = await db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='request_logs'")
                result = await cursor.fetchone()
                if result:
                    print(f"✓ Database initialized successfully at {self.db_path}")
                    print(f"✓ Table 'request_logs' exists")
                else:
                    print(f"✗ ERROR: Table 'request_logs' was not created!")

        except Exception as e:
            print(f"✗ ERROR initializing database: {e}")
            raise

    async def log_request(
        self,
        method: str,
        path: str,
        target_url: str,
        request_headers: dict,
        request_body: Optional[str],
        response_status: int,
        response_headers: dict,
        response_body: Optional[str],
        duration_ms: int
    ):
        """Log a complete request/response cycle to SQLite."""
        timestamp = datetime.utcnow().isoformat()

        # Prepare JSON fields
        request_headers_json = json.dumps(dict(request_headers))
        response_headers_json = json.dumps(dict(response_headers))

        # Try to parse request_body as JSON, otherwise store as string in JSON
        request_body_json = None
        if request_body:
            try:
                # If it's already valid JSON, parse and re-stringify to ensure proper formatting
                parsed_body = json.loads(request_body)
                request_body_json = json.dumps(parsed_body)
            except json.JSONDecodeError:
                # If not JSON, wrap the string value in a JSON object
                request_body_json = json.dumps({"raw": request_body})

        try:
            async with aiosqlite.connect(self.db_path) as db:
                await db.execute("""
                    INSERT INTO request_logs
                    (timestamp, method, path, target_url, request_headers, request_body,
                     response_status, response_headers, response_body, duration_ms)
                    VALUES (?, ?, ?, ?, json(?), json(?), ?, json(?), ?, ?)
                """, (
                    timestamp,
                    method,
                    path,
                    target_url,
                    request_headers_json,
                    request_body_json,
                    response_status,
                    response_headers_json,
                    response_body,
                    duration_ms
                ))
                await db.commit()
        except Exception as e:
            print(f"✗ ERROR logging request to database: {e}")
            print(f"   Database path: {self.db_path}")
            print(f"   Request: {method} {path}")
            raise


async def proxy_handler(request: web.Request) -> web.Response:
    """Handle incoming requests and forward them to target API."""
    logger: ProxyLogger = request.app['logger']
    target_api_url: str = request.app['target_api_url']
    start_time = asyncio.get_event_loop().time()

    # Build target URL
    target_url = f"{target_api_url}{request.path_qs}"

    # Read request body
    request_body = None
    if request.body_exists:
        request_body = await request.text()

    # Prepare headers for forwarding (remove hop-by-hop headers)
    forward_headers = {
        k: v for k, v in request.headers.items()
        if k.lower() not in ('host', 'connection', 'keep-alive', 'transfer-encoding')
    }

    try:
        # Forward request to Anthropic API
        async with aiohttp.ClientSession() as session:
            async with session.request(
                method=request.method,
                url=target_url,
                headers=forward_headers,
                data=request_body,
                allow_redirects=False
            ) as response:
                # Read response body
                response_body = await response.read()

                # Calculate duration
                duration_ms = int((asyncio.get_event_loop().time() - start_time) * 1000)

                # Prepare response headers (filter hop-by-hop headers)
                response_headers = {
                    k: v for k, v in response.headers.items()
                    if k.lower() not in ('connection', 'keep-alive', 'transfer-encoding',
                                        'upgrade', 'proxy-authenticate', 'proxy-authorization',
                                        'te', 'trailers')
                }

                # Log to database (convert body to text for logging)
                try:
                    response_body_text = response_body.decode('utf-8')
                    # Compact streaming responses to reduce database size
                    if response_body_text.strip().startswith("event:"):
                        response_body_text = compact_streaming_response(response_body_text)
                except:
                    response_body_text = f"<binary data, {len(response_body)} bytes>"

                await logger.log_request(
                    method=request.method,
                    path=request.path_qs,
                    target_url=target_url,
                    request_headers=dict(request.headers),
                    request_body=request_body,
                    response_status=response.status,
                    response_headers=response_headers,
                    response_body=response_body_text,
                    duration_ms=duration_ms
                )

                print(f"{request.method} {request.path} -> {response.status} ({duration_ms}ms)")

                # Return response to client
                return web.Response(
                    status=response.status,
                    headers=response_headers,
                    body=response_body
                )

    except Exception as e:
        print(f"Error proxying request: {e}")
        import traceback
        traceback.print_exc()
        return web.Response(status=500, text=f"Proxy error: {str(e)}")


async def health_check(request: web.Request) -> web.Response:
    """Health check endpoint."""
    return web.Response(text="OK")


async def init_app() -> web.Application:
    """Initialize the application."""
    app = web.Application()

    # Initialize logger
    logger = ProxyLogger(DB_PATH)
    await logger.init_db()
    app['logger'] = logger
    app['target_api_url'] = TARGET_API_URL

    # Add routes - catch-all for proxying
    app.router.add_route('*', '/health', health_check)
    app.router.add_route('*', '/{path:.*}', proxy_handler)

    return app


def main():
    """Main entry point."""
    print(f"Starting API logging proxy on port {PROXY_PORT}")
    print(f"Forwarding to: {TARGET_API_URL}")
    print(f"Logging to: {DB_PATH}")

    web.run_app(init_app(), host='0.0.0.0', port=PROXY_PORT)


if __name__ == '__main__':
    main()
