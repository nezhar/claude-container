# Use Ubuntu LTS as base image for better compatibility
FROM ubuntu:24.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    build-essential \
    ca-certificates \
    gnupg \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22 (latest LTS)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs

# Verify Node.js installation
RUN node --version && npm --version

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Create directories with proper ownership
RUN mkdir -p /claude /workspace && \
    chown -R 1000:1000 /claude /workspace

# Create workspace directory
WORKDIR /workspace

CMD ["sh", "-c", "echo 'Claude Code container is ready!'"]
