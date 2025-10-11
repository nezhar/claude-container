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


class ProxyLogger:
    """Handles SQLite logging of requests and responses."""

    def __init__(self, db_path: str):
        self.db_path = db_path

    async def run_migrations(self, db):
        """Run all SQL migration files in order."""
        import pathlib
        import glob

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

        # Find and sort migration files
        migration_files = sorted(migrations_dir.glob("*.sql"))

        for migration_file in migration_files:
            filename = migration_file.name
            if filename in applied:
                print(f"  ✓ Migration {filename} already applied")
                continue

            print(f"  → Applying migration {filename}...")
            try:
                sql_content = migration_file.read_text()
                # Execute the migration (split by semicolon for multiple statements)
                await db.executescript(sql_content)

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
        """Initialize the database schema."""
        import pathlib

        # Ensure database directory exists
        db_dir = pathlib.Path(self.db_path).parent
        db_dir.mkdir(parents=True, exist_ok=True)
        print(f"Database directory: {db_dir}")

        try:
            async with aiosqlite.connect(self.db_path) as db:
                # Create table if not exists with JSON fields
                await db.execute("""
                    CREATE TABLE IF NOT EXISTS request_logs (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        timestamp TEXT NOT NULL,
                        method TEXT NOT NULL,
                        path TEXT NOT NULL,
                        target_url TEXT NOT NULL,
                        request_headers JSON,
                        request_body JSON,
                        response_status INTEGER,
                        response_headers JSON,
                        response_body TEXT,
                        duration_ms INTEGER,
                        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                    )
                """)

                # Check if target_url column exists (for migration)
                cursor = await db.execute("PRAGMA table_info(request_logs)")
                columns = await cursor.fetchall()
                column_names = [col[1] for col in columns]

                # Add target_url column if it doesn't exist (migration from old schema)
                if columns and 'target_url' not in column_names:
                    print("Migrating database: adding target_url column...")
                    await db.execute("""
                        ALTER TABLE request_logs
                        ADD COLUMN target_url TEXT DEFAULT ''
                    """)
                    print("Migration complete!")

                # Migrate existing TEXT columns to JSON if needed
                if columns:
                    # Check the type of request_headers column
                    for col in columns:
                        col_name = col[1]
                        col_type = col[2]
                        if col_name in ('request_headers', 'response_headers', 'request_body') and col_type == 'TEXT':
                            print(f"Note: Column '{col_name}' is TEXT type. Consider recreating the table to use JSON type for better querying.")
                            # SQLite doesn't support ALTER COLUMN TYPE, so we note this but continue
                            # The actual stored values will be JSON strings which work fine
                            break

                await db.commit()

                # Verify table was created
                cursor = await db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='request_logs'")
                result = await cursor.fetchone()
                if result:
                    print(f"✓ Database initialized successfully at {self.db_path}")
                    print(f"✓ Table 'request_logs' exists")
                else:
                    print(f"✗ ERROR: Table 'request_logs' was not created!")

                # Run migrations
                print("Running database migrations...")
                await self.run_migrations(db)
                print("✓ Migrations complete")

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
