# Use official Python Alpine image for smaller size
FROM python:3.12-alpine

# Set working directory
WORKDIR /app

# Install datasette and useful plugins
RUN pip install --no-cache-dir \
    datasette==1.0a15 \
    datasette-json-html \
    datasette-copyable \
    datasette-pretty-json \
    datasette-export-notebook \
    datasette-dashboards

# Copy metadata and configuration
COPY metadata.json /app/metadata.json
COPY datasette.yaml /app/datasette.yaml

# Create data directory for SQLite database
RUN mkdir -p /data && chmod 755 /data

# Expose datasette default port
EXPOSE 8001

# Configure datasette to be accessible from outside the container
# Point to the same database path that the proxy uses
# Performance settings optimized for large databases
CMD ["datasette", "/data/requests.db", \
     "--host", "0.0.0.0", \
     "--port", "8001", \
     "--cors", \
     "--metadata", "/app/metadata.json", \
     "--config", "/app/datasette.yaml", \
     "--setting", "max_returned_rows", "100", \
     "--setting", "sql_time_limit_ms", "5000", \
     "--setting", "default_page_size", "50", \
     "--setting", "cache_size_kb", "10000", \
     "--setting", "default_cache_ttl", "60", \
     "--setting", "num_sql_threads", "8"]
