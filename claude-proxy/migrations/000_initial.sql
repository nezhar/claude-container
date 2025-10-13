-- Migration 000: Initial database schema
-- Creates the core request_logs table for storing proxy request/response data

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
);
