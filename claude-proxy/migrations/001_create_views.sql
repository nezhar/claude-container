-- Migration 001: Create views for flattened data
-- These views enable faceting in Datasette

CREATE VIEW IF NOT EXISTS v_flatten_request_headers AS
SELECT
    request_logs.id,
    request_logs.timestamp,
    request_logs.method,
    request_logs.path,
    json_each.key as header_name,
    json_each.value as header_value
FROM request_logs, json_each(request_logs.request_headers);

CREATE VIEW IF NOT EXISTS v_flatten_response_headers AS
SELECT
    request_logs.id,
    request_logs.timestamp,
    request_logs.method,
    request_logs.path,
    request_logs.response_status,
    json_each.key as header_name,
    json_each.value as header_value
FROM request_logs, json_each(request_logs.response_headers);

CREATE VIEW IF NOT EXISTS v_flatten_request_body AS
SELECT
    request_logs.id,
    request_logs.timestamp,
    request_logs.method,
    request_logs.path,
    json_each.key as field_name,
    json_each.value as field_value
FROM request_logs, json_each(request_logs.request_body);

CREATE VIEW IF NOT EXISTS v_full_request_data AS
SELECT
    request_logs.id,
    request_logs.timestamp,
    request_logs.method,
    request_logs.path,
    'header' as data_type,
    h.key as key_name,
    h.value as value_data
FROM request_logs, json_each(request_logs.request_headers) as h
UNION ALL
SELECT
    request_logs.id,
    request_logs.timestamp,
    request_logs.method,
    request_logs.path,
    'body' as data_type,
    b.key as key_name,
    b.value as value_data
FROM request_logs, json_each(request_logs.request_body) as b;
