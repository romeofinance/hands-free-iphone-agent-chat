# The app ↔ agent contract

This is the **only** coupling between the iPhone app (Agent Two) and your agent
(Agent One). Implement exactly this on your agent and the app will work unchanged.
It is deliberately tiny: three routes.

If you implement these three routes and serve them over Tailscale HTTPS, you can
back them with **anything** — OpenClaw, nanoclaw, a Claude Code or Codex agent, or
a hand-written script. See [`AGENT_SIDE.md`](AGENT_SIDE.md) for concrete options.

---

## Transport and auth

- **Base URL:** normally `https://<machine-name>.<your-tailnet>.ts.net`, reached
  over Tailscale. The app stores this base URL and appends route paths itself.
- **TLS:** Tailscale Serve can terminate valid HTTPS for a service bound to
  `127.0.0.1`. A manually managed `tailscale cert` endpoint also works.
  **No self-signed certificates or plain HTTP** from the phone. (Plain HTTP to
  `127.0.0.1` / `localhost` is allowed only for Simulator testing.)
- **Auth:** the app sends no bearer token and no per-request IDs. Privacy relies
  on Tailscale membership plus the tailnet's directional grants or ACLs.
- **Bodies:** JSON unless noted.
- The app holds its own OpenAI and ElevenLabs keys and calls those services
  directly. Your agent mints and proxies nothing.

Standard HTTPS on port `443` needs no suffix in the app. Port `8443` remains
supported when explicitly exposed and included in the configured base URL.

---

## 1. `GET /health`

Liveness check, used by the app's **Check Health** button.

**Response:** `200`
```json
{ "status": "ok", "version": "1.0.0" }
```
`version` is any string you like (shown in the app for diagnostics).

---

## 2. `POST /voice/full-romeo`

One Full Romeo turn. Your agent receives the user's text, runs it through your
agent however you normally would, and **streams the reply back** as Server-Sent
Events.

**Request body:**
```json
{
  "text": "the user's utterance, with 'Romeo, over' already stripped",
  "mode_metadata": { "source": "siri" }
}
```
- `text` — the transcribed utterance. The trailing "Romeo, over" is already removed by the app.
- `mode_metadata.source` — `"siri"` or `"tap"`. Informational; you can ignore it.

**Response:** `Content-Type: text/event-stream`, standard SSE framing. Each event is
an `event:` line, then a `data:` line containing one JSON object, then a blank line.
Emit events in this order:

```
event: status
data: {"value":"thinking"}

event: text
data: {"delta":"partial response "}

event: text
data: {"delta":"text"}

event: status
data: {"value":"done"}
```

Rules:
- `text` deltas are **incremental**, not cumulative — the app concatenates them in
  order and speaks clauses as they complete.
- After `status: done`, **close the stream.** The app finalizes the turn on `done`.
  (As a safety net the app also finalizes if the stream simply closes, but you
  should send `done`.)
- **Pre-stream failure:** if the turn fails before you've sent any bytes, return an
  HTTP error status (`4xx` for a bad request, `5xx` for an agent/server failure)
  and no stream.
- **Mid-stream failure:** if it fails after streaming has begun (HTTP 200 already
  sent), emit an error event and close:
  ```
  event: error
  data: {"message":"what went wrong"}
  ```

**Optional diagnostic status (safe to ignore):** you may emit
`event: status` / `data: {"value":"using_cli_fallback"}` to tell the app this turn
was served by a slower fallback path. The app shows it as a transport label and
otherwise behaves normally. The app ignores any unknown `status` value safely, so
you may add your own informational statuses without breaking it.

---

## 3. `POST /voice/live-transcript`

Called once, when a Live Romeo session ends. Lets you fold the live conversation
into your agent's memory/session so a later Full Romeo turn has the context.

**Request body:**
```json
{ "transcript": "User: ...\nRomeo: ...\nUser: ...   (the 'Romeo, over' end command removed)" }
```
Role-labeled, one line per turn.

**Response:** `200`
```json
{ "status": "ok" }
```

---

## Notes for implementers

- **Single in-flight.** The app keeps one Full Romeo request in flight at a time and
  does not auto-retry, so you do not need request IDs or de-duplication.
- **Streaming matters for latency.** The app pipes `text` deltas into text-to-speech
  as clauses complete, so the user starts hearing the reply before your agent
  finishes. Stream in small chunks (e.g. as your model produces tokens) rather than
  sending the whole reply as one delta.
- **Keep voice replies concise.** Spoken replies should be shorter than what you'd
  write in a chat. The recommended approach is a per-channel instruction on the
  agent side telling it to keep *voice* replies brief — see [`AGENT_SIDE.md`](AGENT_SIDE.md).
- **Long thinking is OK, but don't go fully silent forever.** The app uses a
  generous idle timeout (~5 minutes) that resets on every byte it receives, so an
  agent that thinks for a while before its first token is fine. If your agent can
  pause longer than that before producing anything, send a periodic keep-alive
  (re-emit `event: status` / `{"value":"thinking"}`, or an SSE comment line `:\n\n`)
  so the connection stays visibly alive.
- **`tools/stub_health_server.py`** in the repo root is a ~60-line working
  implementation of routes 1 and 2 — the simplest possible reference.
