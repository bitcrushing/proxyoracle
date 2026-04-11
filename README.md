# ProxyOracle

A Claude AI proxy server + thin OpenComputers client. Offloads TLS, conversation storage, and thinking blocks to a proxy server, letting the OC client run comfortably on 1MB RAM.

## Architecture

```
OC Computer (1MB RAM)              Proxy Server (any machine)
┌─────────────────┐  plain HTTP   ┌──────────────────────┐   HTTPS
│ Thin Lua Client  │ ──────────→  │  Python Proxy Server  │ ────────→ api.anthropic.com
│ - Tool execution │ ←──────────  │  - Conversation store │ ←────────
│ - UI / input     │  SSE stream  │  - TLS termination    │
│ - Agentic loop   │              │  - Thinking blocks    │
└─────────────────┘              └──────────────────────┘
```

## Requirements

### Proxy Server
- Python 3.8+
- Anthropic API key

### OC Client
- Internet Card (no Data Card needed)
- Any tier RAM (256KB+ should work)

## Setup

### 1. Proxy Server

```bash
cd server
pip install -r requirements.txt
python proxy.py
```

On first run, `proxy_config.json` is auto-generated with a random auth token.

Edit `proxy_config.json` to add your Anthropic API key:

```json
{
  "api_key": "sk-ant-your-key-here",
  "auth_token": "auto-generated-token",
  "allowed_models": ["claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5-20251001"],
  "max_sessions": 10,
  "max_messages_per_session": 500,
  "bind_host": "0.0.0.0",
  "bind_port": 8080
}
```

Restart the proxy after editing the config.

### 2. Internet Exposure (Optional)

If exposing to the internet:

- **Use a reverse proxy with TLS** (Caddy recommended for auto-HTTPS):
  ```
  your-domain.com {
      reverse_proxy localhost:8080
  }
  ```
- The auth token in `proxy_config.json` is your API key's guard — keep it secret
- The Anthropic API key never leaves the proxy server
- Consider IP allowlisting if possible
- Rate limiting is built in (30 req/min default)

### 3. OC Client

On your OpenComputers computer:

```
# Install from local files:
install

# Or install to external drive:
install /mnt/abc

# Configure:
claude --setup
```

Enter:
- Proxy host (IP or domain of your proxy server)
- Proxy port (default 8080, or 443 if behind Caddy)
- Auth token (from `proxy_config.json`)

### 4. Start Chatting

```
claude
```

## Commands

| Command | Description |
|---------|-------------|
| /help | Show help |
| /clear | Clear conversation (new session) |
| /cost | Show token usage and cost estimate |
| /memory | Show OC RAM usage |
| /setup | Reconfigure proxy connection |
| /exit | Exit |

## Tools

Claude can use these tools on your OC computer:

| Tool | Description | Confirmation |
|------|-------------|--------------|
| Read | Read files | Auto |
| Write | Write files | Required |
| Edit | Find/replace in files | Required |
| Run | Execute commands | Required |
| Glob | Find files by pattern | Auto |
| Grep | Search file contents | Auto |
| Fetch | HTTP GET a URL | Auto |

## Troubleshooting

**"Failed to connect"** — Check proxy host/port, ensure proxy is running

**"Invalid token"** — Auth token in OC config doesn't match proxy_config.json

**"API key not configured on proxy"** — Edit proxy_config.json, add your sk-ant-... key

**"Model not allowed"** — Model not in proxy_config.json allowed_models list

**"Session message limit reached"** — Use /clear to start fresh

**"Rate limited"** — Too many requests, wait a moment

## Security Notes

- The Anthropic API key is stored ONLY on the proxy server
- The OC client only has a bearer token — if compromised, revoke it by editing proxy_config.json
- For internet exposure, always use HTTPS (Caddy, nginx, etc.)
- The proxy rate-limits requests and caps session counts
- Model allowlisting prevents unexpected API costs
