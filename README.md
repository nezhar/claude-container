# Claude Container

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/nezhar/claude-container)

A Docker container with Claude Code pre-installed and ready to use.

This container includes all necessary dependencies and provides an easy way to run Claude Code in an isolated environment.

An optional proxy can be enabled to track all the requests made by Claude Code in a local SQLite database.

## Docker Hub

Images available on Docker Hub: [nezhar/claude-container](https://hub.docker.com/r/nezhar/claude-container) and [nezhar/claude-proxy](https://hub.docker.com/r/nezhar/claude-proxy)

## Compatibility Matrix

**Latest Release:** 1.3.1 (Claude Code 2.0.17)

| Container Version | Claude Code Version |
|-------------------|---------------------|
| 1.0.x             | 1.0.x               |
| 1.1.x             | 2.0.x               |
| 1.2.x             | 2.0.x               |
| 1.3.x             | 2.0.x              |

## Quick Start

### Using the Helper Script (Recommended)

The easiest way to run Claude Container is using the provided bash script. Download and install it with:

```bash
# Download the script directly from GitHub
curl -o ~/.local/bin/claude-container https://raw.githubusercontent.com/nezhar/claude-container/main/bin/claude-container

# Make it executable
chmod +x ~/.local/bin/claude-container

# Run Claude Code
claude-container
```

Make sure `~/.local/bin` is in your PATH. Alternatively, install to `/usr/local/bin`:

```bash
# Download and install system-wide (requires sudo)
sudo curl -o /usr/local/bin/claude-container https://raw.githubusercontent.com/nezhar/claude-container/main/bin/claude-container
sudo chmod +x /usr/local/bin/claude-container
```

The script handles all Docker configuration automatically and supports additional features like API logging. Run with `--help` to see all available options:

```bash
claude-container --help
```

#### Optional: Enable Tab Completion

To enable bash tab completion for the `claude-container` command:

```bash
# Download and install completion script
mkdir -p ~/.local/share/bash-completion/completions
curl -o ~/.local/share/bash-completion/completions/claude-container https://raw.githubusercontent.com/nezhar/claude-container/main/completions/claude-container

# Reload your shell or start a new terminal session
source ~/.bashrc
```

Once installed, you can use tab completion with `claude-container --<TAB>` to see all available options

### Using Docker Compose

Create a `compose.yml` file as provided in the example folder. 
```bash
docker compose run claude-code claude
```

You will need to login for the first time, afterwards your credentials and configurations will be stored inside a bind mount volume, make sure this stays in your `.gitignore`.

### Using Docker directly


```bash
docker run --rm -it -v "$(pwd):/workspace" -v "$HOME/.config/claude-container:/claude" -e "CLAUDE_CONFIG_DIR=/claude" nezhar/claude-container:latest claude
```

This will store the credentials in `$HOME/.config/claude-container` and will be able to reuse them after the first login.

### Using VS Code Dev Containers or GitHub Codespaces (Zero Setup)

The easiest way to get started with Claude Container is using VS Code Dev Containers or GitHub Codespaces - no local Docker installation required for Codespaces!

#### GitHub Codespaces (Cloud-Based, Instant Setup)

1. **Launch a Codespace**: Click the "Code" button on the GitHub repository page, select "Codespaces", and click "Create codespace on main"
2. **Wait for Setup**: The container will automatically build and start (usually takes 1-2 minutes)
3. **Run Claude Code**: Open the terminal in VS Code and run:
   ```bash
   claude
   ```
4. **Authenticate**: Follow the authentication prompts (see [How does the authentication work](#how-does-the-authentication-work) section below)

Your configuration will persist across Codespace sessions using a Docker volume.

#### VS Code Dev Containers (Local)

If you prefer to work locally with VS Code:

1. **Prerequisites**: 
   - Install [VS Code](https://code.visualstudio.com/)
   - Install the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
   - Install [Docker Desktop](https://www.docker.com/products/docker-desktop)

2. **Open in Container**:
   - Clone this repository
   - Open the folder in VS Code
   - When prompted, click "Reopen in Container" (or run "Dev Containers: Reopen in Container" from the command palette)

3. **Run Claude Code**:
   ```bash
   claude
   ```

4. **Authenticate**: Follow the authentication prompts (see [How does the authentication work](#how-does-the-authentication-work) section below)

#### Devcontainer Benefits

- ✅ **Zero Configuration**: Everything is pre-configured and ready to use
- ✅ **Consistent Environment**: Everyone uses the same development environment
- ✅ **Persistent Config**: Your authentication persists between container rebuilds
- ✅ **Cloud or Local**: Works with both GitHub Codespaces and local VS Code
- ✅ **Instant Access**: Try Claude Code without installing anything locally (using Codespaces)

#### Troubleshooting Devcontainers

**Authentication not persisting between rebuilds:**
- The devcontainer uses a named Docker volume `claude-container-config` to persist your configuration
- If you need to reset authentication, you can delete this volume:
  ```bash
  docker volume rm claude-container-config
  ```

**Port forwarding issues in Codespaces:**
- Claude Code doesn't require any port forwarding by default
- If you're using the proxy features, ports will be automatically forwarded

**Permission errors:**
- The container runs as the `node` user (UID 1000) by default
- If you encounter permission issues, ensure the workspace folder has appropriate permissions

**Container fails to build:**
- Check your internet connection (container needs to pull the image)
- Try rebuilding: Run "Dev Containers: Rebuild Container" from the VS Code command palette
- For Codespaces, delete and recreate the Codespace if issues persist

**Codespaces-specific considerations:**
- Free tier has usage limits (60 hours/month for free accounts)
- Your workspace files persist in the Codespace, but Docker volumes are separate
- Codespaces automatically suspends after 30 minutes of inactivity

## How does the authentication work

When you run the container for the first time, you'll go through the following authentication steps:

1. **Choose Color Schema**: Select your preferred terminal color scheme

   ![Color Schema Selection](docs/auth1.png)

2. **Select Login Method**: Choose between Subscription or Console login (this example uses Subscription)

   ![Login Method Selection](docs/auth2.png)

3. **Generate Token**: Open the provided URL in your browser to generate an authentication token, then paste it into the prompt

   ![Token Generation](docs/auth3.png)

4. **Success**: You're authenticated and ready to use Claude Code

   ![Authentication Success](docs/auth4.png)

## Integration with Existing Projects

To integrate Claude Container into an existing Docker Compose project, create a `compose.override.yml` file:

```yaml
services:
  claude-code:
    image: nezhar/claude-container:latest
    volumes:
      - ./workspace:/workspace
      - ./claude-config:/claude
    environment:
      CLAUDE_CONFIG_DIR: /claude
    profiles:
      - tools
```

Then run Claude Code with:

```bash
# Using profiles to avoid starting by default
docker compose --profile tools run claude-code claude
```

This approach keeps Claude Code separate from your main application services while allowing easy access when needed.

## API Request Logging Proxy

This repository includes an optional logging proxy that captures all Anthropic API requests and responses to a SQLite database. This is useful for:

- Debugging API interactions
- Monitoring token usage and costs
- Analyzing request/response patterns
- Building custom analytics tools

### Running with Docker

**Run Claude Container directly:**
```bash
docker run --rm -it \
  -v "$(pwd):/workspace" \
  -v "$HOME/.config/claude-container:/claude" \
  -e "CLAUDE_CONFIG_DIR=/claude" \
  nezhar/claude-container:latest claude
```

**Run with logging proxy:**
```bash
# 1. Create a Docker network
docker network create claude-network

# 2. Start the proxy container
docker run -d --name claude-proxy \
  --network claude-network \
  -v "$(pwd)/proxy-data:/data" \
  -p 8080:8080 \
  nezhar/claude-proxy:latest

# 3. Run Claude Code (configured to use the proxy)
docker run --rm -it \
  --network claude-network \
  -v "$(pwd):/workspace" \
  -v "$HOME/.config/claude-container:/claude" \
  -e "CLAUDE_CONFIG_DIR=/claude" \
  -e "ANTHROPIC_BASE_URL=http://claude-proxy:8080" \
  nezhar/claude-container:latest claude

# 4. Cleanup when done
docker stop claude-proxy
docker rm claude-proxy
docker network rm claude-network
```

### Proxy Configuration

The proxy supports the following environment variables:

- `PROXY_PORT`: Port to listen on (default: `8080`)
- `TARGET_API_URL`: Target API URL (default: `https://api.anthropic.com`)
- `DB_PATH`: SQLite database path (default: `/data/requests.db`)

## Data Visualization with Datasette

This repository includes a Datasette container for exploring and visualizing the API request logs captured by the proxy. Datasette provides a web-based interface to explore your SQLite database with filtering, sorting, and export capabilities.

### Features

- **Browse Request Logs**: View all API requests with filtering and sorting
- **JSON Visualization**: Pretty-print JSON request/response bodies
- **Analytics**: Analyze request patterns, response times, and error rates
- **Export Data**: Export filtered results to CSV, JSON, or Excel
- **SQL Queries**: Run custom SQL queries against your data

### Running with Datasette

When using Docker Compose, you can add the Datasette service to visualize your proxy data:

```yaml
services:
  claude-proxy:
    image: nezhar/claude-proxy:latest
    ports:
      - "8080:8080"
    volumes:
      - ./proxy-data:/data

  claude-datasette:
    image: nezhar/claude-datasette:latest
    ports:
      - "8001:8001"
    volumes:
      - ./proxy-data:/data:ro
    depends_on:
      - claude-proxy

  claude-code:
    image: nezhar/claude-container:latest
    volumes:
      - ./workspace:/workspace
      - ./claude-config:/claude
    environment:
      CLAUDE_CONFIG_DIR: /claude
      ANTHROPIC_BASE_URL: http://claude-proxy:8080
    depends_on:
      - claude-proxy
```

Start the services:
```bash
docker compose up -d claude-proxy claude-datasette
docker compose run claude-code claude
```

Then access Datasette at http://localhost:8001 to explore your API request logs.

### Using Datasette

Once Datasette is running:

1. **View All Requests**: Navigate to the `request_logs` table to see all captured API requests
2. **Filter Data**: Use the faceted filters to narrow down by HTTP method, status code, etc.
3. **Examine Details**: Click on individual requests to see full headers and JSON bodies
4. **Run Queries**: Use the SQL interface to run custom analytics queries
5. **Export Results**: Export filtered data in various formats for further analysis

Example queries you might run:

```sql
-- Average response time by endpoint
SELECT path, AVG(duration_ms) as avg_duration, COUNT(*) as request_count
FROM request_logs
GROUP BY path
ORDER BY avg_duration DESC;

-- Requests with errors
SELECT timestamp, method, path, response_status, duration_ms
FROM request_logs
WHERE response_status >= 400
ORDER BY timestamp DESC;

-- Token usage over time (if captured in request_body)
SELECT
  DATE(timestamp) as date,
  SUM(json_extract(response_body, '$.usage.input_tokens')) as input_tokens,
  SUM(json_extract(response_body, '$.usage.output_tokens')) as output_tokens
FROM request_logs
WHERE json_extract(response_body, '$.usage') IS NOT NULL
GROUP BY date
ORDER BY date DESC;
```
