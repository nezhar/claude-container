-- Migration 002: Add performance indexes
-- Improves query performance for common filters and sorts

-- Index for timestamp ordering (most queries ORDER BY timestamp DESC)
CREATE INDEX IF NOT EXISTS idx_request_logs_timestamp ON request_logs(timestamp DESC);

-- Index for filtering by status code (used in error dashboards)
CREATE INDEX IF NOT EXISTS idx_request_logs_status ON request_logs(response_status);

-- Index for filtering by path (used in path analysis)
CREATE INDEX IF NOT EXISTS idx_request_logs_path ON request_logs(path);

-- Index for filtering by method
CREATE INDEX IF NOT EXISTS idx_request_logs_method ON request_logs(method);

-- Composite index for common query patterns (status + timestamp)
CREATE INDEX IF NOT EXISTS idx_request_logs_status_timestamp ON request_logs(response_status, timestamp DESC);

-- Composite index for path analysis (path + timestamp)
CREATE INDEX IF NOT EXISTS idx_request_logs_path_timestamp ON request_logs(path, timestamp DESC);
