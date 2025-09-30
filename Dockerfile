# Use official Node.js Alpine image
FROM node:22-alpine

# Install git (required by Claude Code)
RUN apk add --no-cache git

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code@~2.0.0

# Create directories with proper ownership
RUN mkdir -p /claude /workspace && \
    chown -R 1000:1000 /claude /workspace

# Create workspace directory
WORKDIR /workspace

CMD ["sh", "-c", "echo 'Claude Code container is ready!'"]
