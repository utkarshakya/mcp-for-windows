# mcp-for-windows

Exposes a local directory as an MCP filesystem server behind Google OAuth via ngrok.

## Setup

1. Copy `config.env.example` to `config.env` and fill in your values.
2. Download [mcp-auth-proxy](https://github.com/sigbit/mcp-auth-proxy/releases/latest) (Windows binary) and place it as `mcp-auth-proxy.exe` in the project root.
3. Install [ngrok](https://ngrok.com/download).

## Usage

```powershell
.\start.ps1
```

This starts the proxy locally on port 8080, opens an ngrok tunnel using your configured domain, and exposes the specified directory via MCP's `filesystem` server.

## Requirements

- Windows
- ngrok
- mcp-auth-proxy
- Node.js (for `@modelcontextprotocol/server-filesystem`)
