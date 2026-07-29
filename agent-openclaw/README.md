# Romeo Agent OpenClaw

Public, reusable OpenClaw-side bridge for the Romeo iPhone app contract.

It serves HTTPS over a Tailscale-reachable machine, receives text from the app,
posts that text into an existing OpenClaw main session, streams assistant text
deltas back as Server-Sent Events, and records Live Romeo transcripts into the
same session for continuity.

## Contract

Base URL:

```text
https://agent-host.your-tailnet.ts.net
```

Routes:

- `GET /health`
- `POST /voice/full-romeo`
- `POST /voice/live-transcript`

There is no app-layer bearer token. Tailscale membership plus the tailnet's
directional grants or ACLs controls access. There are no request IDs or
server-side dedupe requirements.

## Prerequisites

- Node.js 20 or newer.
- OpenClaw installed and a main session available.
- Tailscale installed on the server and the iPhone.
- A certificate for the bridge's local HTTPS listener (the setup below uses
  `tailscale cert`; iOS only sees the certificate terminated by Tailscale Serve).
- The server machine should stay awake. On macOS, one option is:

```sh
sudo pmset -a sleep 0
```

## Install

Copy this folder onto the machine running OpenClaw.

```sh
cd agent-openclaw
mkdir -p "$HOME/.config/romeo-agent-openclaw"
cp .env.example "$HOME/.config/romeo-agent-openclaw/romeo-agent-openclaw.env"
chmod 600 "$HOME/.config/romeo-agent-openclaw/romeo-agent-openclaw.env"
```

Edit the env file and replace every placeholder.

Minimum important values:

```sh
ROMEO_AGENT_HOST=127.0.0.1
ROMEO_AGENT_PORT=8443
ROMEO_AGENT_CERT_FILE=$HOME/.config/romeo-agent-openclaw/tls/agent-host.your-tailnet.ts.net.crt
ROMEO_AGENT_KEY_FILE=$HOME/.config/romeo-agent-openclaw/tls/agent-host.your-tailnet.ts.net.key
ROMEO_AGENT_OPENCLAW_SESSION_KEY=agent:main:main
```

`ROMEO_AGENT_OPENCLAW_SESSION_KEY` is the continuity setting. Set it to the
existing OpenClaw session that should receive voice turns. If your main session
is not `agent:main:main`, replace the example with your real main-session key.
Do not create a separate app session unless you intentionally want separate
context.

## Recommended private exposure: Tailscale Serve

Keep the bridge bound to `127.0.0.1`. The included bridge is an HTTPS server, so
Tailscale Serve proxies its local certificate with `https+insecure` while
presenting valid HTTPS to the iPhone:

```sh
tailscale serve --bg --https=443 https+insecure://127.0.0.1:8443
tailscale serve status
```

The `https+insecure` hop is restricted to loopback. The iPhone sees Tailscale
Serve's valid HTTPS endpoint at
`https://agent-host.your-tailnet.ts.net`, with no port suffix.

For a generic agent service that listens on local HTTP instead of this included
HTTPS bridge, the common command is:

```sh
tailscale serve --bg --https=443 http://127.0.0.1:<local-agent-port>
tailscale serve status
```

Tailscale Funnel is not required and should remain off unless you intentionally
want a public endpoint and add suitable authentication. Tailscale SSH is
unrelated to this bridge.

## Tailscale certificate

```sh
mkdir -p "$HOME/.config/romeo-agent-openclaw/tls"
tailscale cert \
  --cert-file "$HOME/.config/romeo-agent-openclaw/tls/agent-host.your-tailnet.ts.net.crt" \
  --key-file "$HOME/.config/romeo-agent-openclaw/tls/agent-host.your-tailnet.ts.net.key" \
  agent-host.your-tailnet.ts.net
chmod 600 "$HOME/.config/romeo-agent-openclaw/tls/"*.key
```

This local certificate is required by the included bridge implementation. A
generic HTTP agent behind Tailscale Serve does not need to manage its own
certificate.

### Direct HTTPS on port 8443

Direct HTTPS remains supported as an alternative to Serve. Bind the bridge to
the machine's Tailscale interface, use the certificate above, expose only TCP
`8443` in your tailnet policy, and enter
`https://agent-host.your-tailnet.ts.net:8443` in the app. Do not bind broadly or
expose the port to the public internet.

### Directional access control

On a tailnet with restrictive grants or ACLs, merge a narrow object like this
into the existing policy's `grants` array:

```json
{
  "src": ["<iphone-tailscale-ip>"],
  "dst": ["<agent-machine-tailscale-ip>"],
  "ip": ["tcp:443", "tcp:8443"]
}
```

This is an example, not a complete replacement policy. Include only the port you
actually expose, and do not modify unrelated tags, devices, grants, or ACLs.

## Run manually

```sh
./scripts/run-server.sh
```

Health check from another tailnet device:

```sh
curl --fail --silent --show-error \
  https://agent-host.your-tailnet.ts.net/health
```

Expected:

```json
{"status":"ok","version":"0.1.0"}
```

## macOS LaunchAgent

The template is `launchd/com.example.romeo-agent-openclaw.plist`.

Edit these placeholders before installing:

- `/path/to/agent-openclaw`
- `/path/to/logs`

Install as the same user that runs OpenClaw:

```sh
mkdir -p "$HOME/Library/LaunchAgents"
cp launchd/com.example.romeo-agent-openclaw.plist \
  "$HOME/Library/LaunchAgents/com.example.romeo-agent-openclaw.plist"
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.example.romeo-agent-openclaw.plist"
launchctl enable "gui/$(id -u)/com.example.romeo-agent-openclaw"
launchctl kickstart "gui/$(id -u)/com.example.romeo-agent-openclaw"
```

Use a user LaunchAgent unless you have a reason to do otherwise. The service
usually needs the user's OpenClaw auth, workspace, Tailscale state, and env file.

## systemd

The template is `systemd/romeo-agent-openclaw.service`.

Edit:

- `WorkingDirectory`
- `EnvironmentFile`
- `ExecStart` if Node is not on PATH

Then:

```sh
sudo cp systemd/romeo-agent-openclaw.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now romeo-agent-openclaw
```

## Full Romeo curl test

```sh
curl --no-buffer --fail --silent --show-error \
  -H "Content-Type: application/json" \
  -d '{"text":"Reply with exactly OK","mode_metadata":{"source":"tap"}}' \
  https://agent-host.your-tailnet.ts.net/voice/full-romeo
```

Typical SSE output:

```text
event: status
data: {"value":"thinking"}

event: text
data: {"delta":"OK"}

event: status
data: {"value":"done"}
```

On longer replies, `text` events should arrive as incremental chunks, not
cumulative text. If the warm Gateway path fails before OpenClaw accepts the run,
the service may emit:

```text
event: status
data: {"value":"using_cli_fallback"}
```

CLI fallback is slower and cannot provide true model-token streaming; it emits
the final assistant reply as one `text` delta.

## Live transcript curl test

```sh
curl --fail --silent --show-error \
  -H "Content-Type: application/json" \
  -d '{"transcript":"User: hello\nRomeo: hi"}' \
  https://agent-host.your-tailnet.ts.net/voice/live-transcript
```

Expected:

```json
{"status":"ok"}
```

## How this binds to OpenClaw

This package uses the local OpenClaw Gateway WebSocket and sends an `agent` RPC
with:

- `sessionKey`: `ROMEO_AGENT_OPENCLAW_SESSION_KEY`
- `agentId`: derived from that session key
- `deliver`: `false`
- `idempotencyKey`: the server-generated turn UUID

That puts the turn into the configured existing OpenClaw session and returns the
assistant reply. In the tested OpenClaw build, Gateway `chat` events expose
assistant deltas, which this server forwards as SSE `text` deltas.

The public standalone runtime did not expose a simple documented Telegram-style
channel-adapter hook that could be called from this separate HTTPS process. If
OpenClaw later exposes a stable channel inbound API, replace the Gateway bridge
in `src/openclaw-bridge.mjs` with that adapter and keep the HTTP contract the
same.

## Voice directive

The voice channel should be concise without forcing other channels to be terse.
This implementation uses the conservative fallback: it prepends this short line
only to `/voice/full-romeo` turns:

```text
Voice reply directive: be concise and listenable; expand when explicitly asked.
```

It does not affect Telegram, WhatsApp, TUI, or other OpenClaw channels. If your
OpenClaw build supports per-channel system directives, prefer that and remove
the prefix.

## Troubleshooting

- `curl /health` fails: confirm Tailscale is connected, the certificate hostname
  matches `agent-host.your-tailnet.ts.net`, and the process is listening on the
  expected host/port.
- `/health` works locally but the iPhone times out and no request reaches the
  logs: confirm Tailscale on both devices, verify the app URL and port, run
  `tailscale serve status`, check for a directional iPhone-to-agent grant on the
  Tailscale Access Controls page, and test
  `https://agent-host.your-tailnet.ts.net/health` from the iPhone. Do not enable
  Funnel as a workaround.
- iOS rejects HTTPS: use `tailscale cert`; do not use a self-signed certificate.
- Full Romeo is slow: check logs for `gateway_fallback_to_cli`. Gateway mode
  should log `transport:"gateway"`; CLI fallback logs `transport:"cli"`.
- Gateway discovery fails after an OpenClaw update: set
  `ROMEO_AGENT_OPENCLAW_DIST_DIR` or `ROMEO_AGENT_OPENCLAW_GATEWAY_CLIENT_MODULE`.
- Replies appear in a separate session: set `ROMEO_AGENT_OPENCLAW_SESSION_KEY`
  to the existing main session key you actually use.
- No incremental deltas: check OpenClaw version. The code falls back to one final
  text delta if the Gateway does not emit `chat` delta events.
