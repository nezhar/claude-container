"""
Migration: Compact existing streaming responses.

This migration converts existing Server-Sent Events (SSE) streaming responses
stored in the database into a compact JSON format, significantly reducing
database size while preserving all essential information.

New responses are automatically compacted on insert, so this migration only
needs to run once to convert historical data.
"""

import json
from datetime import datetime


def compact_streaming_response(raw_body: str) -> str:
    """
    Compact a Server-Sent Events (SSE) streaming response into a single JSON response.
    """
    if not raw_body or not raw_body.strip().startswith("event:"):
        return raw_body

    chunks = []
    content_parts = []
    metadata = {}
    usage = {}

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
                    metadata["stop_reason"] = delta.get("stop_reason")
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


def format_bytes(size: int) -> str:
    """Format byte size to human readable string."""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if abs(size) < 1024.0:
            return f"{size:.2f} {unit}"
        size /= 1024.0
    return f"{size:.2f} TB"


async def migrate(db):
    """
    Compact all existing streaming responses in the database.

    Args:
        db: aiosqlite database connection
    """
    # Find rows with streaming responses (starting with "event:")
    cursor = await db.execute("""
        SELECT id, response_body
        FROM request_logs
        WHERE response_body LIKE 'event:%'
    """)

    rows = await cursor.fetchall()
    total_rows = len(rows)

    if total_rows == 0:
        print("    No streaming responses found to compact")
        return

    print(f"    Found {total_rows} streaming response(s) to compact")

    total_original_bytes = 0
    total_compacted_bytes = 0
    migrated_count = 0

    for row_id, response_body in rows:
        if not response_body:
            continue

        original_size = len(response_body.encode('utf-8'))
        compacted = compact_streaming_response(response_body)
        compacted_size = len(compacted.encode('utf-8'))

        # Only update if actually compacted
        if compacted != response_body:
            total_original_bytes += original_size
            total_compacted_bytes += compacted_size
            migrated_count += 1

            await db.execute(
                "UPDATE request_logs SET response_body = ? WHERE id = ?",
                (compacted, row_id)
            )

    await db.commit()

    # Summary
    if migrated_count > 0:
        total_reduction = total_original_bytes - total_compacted_bytes
        reduction_pct = (total_reduction / total_original_bytes) * 100
        print(f"    Compacted {migrated_count} responses")
        print(f"    Space saved: {format_bytes(total_reduction)} ({reduction_pct:.1f}% reduction)")

        # Run VACUUM to reclaim disk space
        print("    Running VACUUM to reclaim disk space...")
        await db.execute("VACUUM")
        print("    VACUUM complete")
    else:
        print("    No responses needed compaction")
