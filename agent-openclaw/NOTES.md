# Notes for Implementers

Tested against:

```text
OpenClaw 2026.6.10 (aa69b12)
```

## Important caveat: Gateway RPC vs channel adapter

The desired architecture is "voice as another OpenClaw channel", mirroring the
Telegram or WhatsApp adapters. In the tested install, the reusable channel
runtime functions exist inside OpenClaw's bundled runtime, but they expect
runtime-injected channel/session/dispatch dependencies. They were not a clean
standalone API for an external HTTPS service.

The reliable standalone integration was the local OpenClaw Gateway:

1. Connect to the local Gateway WebSocket.
2. Dispatch an `agent` RPC into an existing session key.
3. Listen for Gateway `chat` events to forward assistant deltas.
4. Wait for the final RPC result for completion metadata and fallback safety.

This keeps memory, tools, and continuity in the existing OpenClaw session, but it
is not as clean as a first-class documented channel adapter. If OpenClaw exposes
a stable inbound channel API later, use that instead.

The session key is deliberately config, not hard-coded. Set
`ROMEO_AGENT_OPENCLAW_SESSION_KEY` to whatever session is the user's real main
OpenClaw session. The example value `agent:main:main` is only a common default.

## Streaming behavior

Gateway `chat` events with `state === "delta"` are forwarded to the app as SSE:

```text
event: text
data: {"delta":"..."}
```

The deltas are incremental. The app should concatenate them. If a future
OpenClaw build returns a final assistant reply but does not emit chat deltas,
this package emits the full final reply as one `text` delta and logs
`final_text_delta_fallback`.

CLI fallback cannot token-stream. It is kept for reliability only.

## Fallback behavior

Fallback to CLI only happens if Gateway fails before the run is accepted. After a
run is accepted, the server surfaces the error instead of starting a duplicate
turn in the same session.

When fallback starts, `/voice/full-romeo` emits:

```text
event: status
data: {"value":"using_cli_fallback"}
```

The app can show that as a diagnostic transport label. It should not speak it.

## Voice directive

The preferred implementation would attach a per-channel system directive to the
voice channel only. This package uses a short prompt prefix because that is the
portable option with the Gateway RPC path:

```text
Voice reply directive: be concise and listenable; expand when explicitly asked.
```

This is intentionally soft guidance, not a token cap. Token caps can cut off
spoken replies mid-sentence.

## Concurrency

The iPhone app should keep only one Full Romeo request in flight. This server can
track and abort multiple runs by generated turn ID, but it does not implement
dedupe because the public contract intentionally removed request IDs and dedupe.

## Certificates and networking

The included bridge uses `tailscale cert` for its local HTTPS listener. Prefer
keeping it on `127.0.0.1` and exposing it privately with Tailscale Serve; the
iPhone then calls Serve's valid HTTPS endpoint. Direct HTTPS on port `8443`
remains supported when explicitly configured.

Do not expose this server with Tailscale Funnel or any public reverse proxy
unless you add real authentication. The intended access control is tailnet
membership plus a narrow directional grant or ACL.

## Keeping the machine awake

For macOS, a simple always-on setup can use:

```sh
sudo pmset -a sleep 0
```

Use a user LaunchAgent when OpenClaw auth and Tailscale state live in the user
session. A root LaunchDaemon often cannot see those credentials.

## OpenClaw update risk

The package discovers the bundled `GatewayClient` by export name from OpenClaw's
`dist/client-*.js` files because the filename hash changes between builds. This
survives filename churn, but not a renamed or removed `GatewayClient` export.

If discovery breaks:

1. Run `openclaw --version`.
2. Locate the module exporting `GatewayClient`.
3. Set `ROMEO_AGENT_OPENCLAW_GATEWAY_CLIENT_MODULE` to that module path, or set
   `ROMEO_AGENT_OPENCLAW_DIST_DIR` to the correct `dist` directory.

If Gateway itself changes its RPC shape, keep `/voice/full-romeo` and
`/voice/live-transcript` stable and replace only `src/openclaw-bridge.mjs`.
