# Use official Python Alpine image
FROM python:3.12-alpine

# Set working directory
WORKDIR /app

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy proxy application and migrations
COPY proxy.py .
COPY migrations/ ./migrations/

# Create data directory for SQLite database
RUN mkdir -p /data && chmod 777 /data

# Expose proxy port
EXPOSE 8080

# Run the proxy
CMD ["python", "-u", "proxy.py"]
