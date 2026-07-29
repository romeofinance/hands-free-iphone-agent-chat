# Building the agent side (Agent One)

This guide explains how to stand up the agent half so the Romeo app can reach it.
The app is finished and unchanging; **all you do is implement the three routes in
[`CONTRACT.md`](CONTRACT.md) and make them reachable over Tailscale.**

You have wide latitude in *what* serves those routes. The contract is just HTTP +
Server-Sent Events. Three common shapes:

- **OpenClaw** — the setup this app was originally built against. A complete,
  ready-to-run reference implementation lives in
  [`../agent-openclaw/`](../agent-openclaw/): a Node HTTPS bridge that dispatches
  voice turns into your existing OpenClaw session and streams the reply back, plus
  service templates and setup/troubleshooting docs. Start there if you run OpenClaw.
- **nanoclaw / a lighter agent runtime** — same idea, smaller surface. Wire the
  route's text into your agent loop and stream the reply out.
- **A Claude Code / Codex (or any LLM) agent you script yourself** — you don't need
  a full framework. A ~150-line HTTP server that forwards `text` to your model and
  streams tokens back as SSE satisfies the contract completely.

Whichever you choose, the requirements are identical. Work through the four parts
below.

---

## Part 1 — Networking: reachable over Tailscale with real HTTPS

The phone reaches your agent privately over [Tailscale](https://tailscale.com);
nothing is exposed to the public internet.

1. **Install Tailscale** on the agent machine and on the iPhone; sign both into the
   same tailnet. Leave the VPN profile enabled on the phone. Note the machine's
   MagicDNS name, e.g. `agent-host.your-tailnet.ts.net`.
2. **Keep the machine awake.** On a Mac: `sudo pmset -a sleep 0`. The agent must be
   always-on to answer from anywhere.
3. **Bind the agent service to loopback**, normally
   `http://127.0.0.1:<local-agent-port>`. This prevents the backend itself from
   listening broadly.
4. **Expose it privately with Tailscale Serve:**
   ```sh
   tailscale serve --bg --https=443 http://127.0.0.1:<local-agent-port>
   tailscale serve status
   ```
   Tailscale Serve handles a valid public-trust HTTPS certificate while keeping
   the endpoint available only inside the tailnet.
5. From the phone (off Wi-Fi, on cellular) open
   `https://agent-host.your-tailnet.ts.net/health`. Put the base URL
   `https://agent-host.your-tailnet.ts.net` into the app's **Tailnet URL** field
   and tap **Check Health**.

### Directional access control

Installing both devices in the same tailnet is not always sufficient. Tailnets
with restrictive grants or ACLs must allow the iPhone, as the connection source,
to reach the agent machine, as the destination. Merge a narrow example like this
into the existing `grants` array on the Tailscale **Access Controls** page:

```json
{
  "src": ["<iphone-tailscale-ip>"],
  "dst": ["<agent-machine-tailscale-ip>"],
  "ip": ["tcp:443", "tcp:8443"]
}
```

This object is only an example. Do not replace the existing policy or alter
unrelated tags, devices, ACLs, or grants. Include only the port you actually
expose.

Port `8443` remains supported. If you configure Serve or your HTTPS server on that
port, include it in the app URL:
`https://agent-host.your-tailnet.ts.net:8443`.

A manually managed `tailscale cert` certificate remains a valid alternative when
the agent service terminates HTTPS itself. It is not mandatory when Tailscale
Serve terminates HTTPS. The included OpenClaw bridge uses this direct-HTTPS
implementation and documents both exposure options in
[`../agent-openclaw/README.md`](../agent-openclaw/README.md).

Do not enable Tailscale Funnel for the generic setup. Funnel creates a public
endpoint and requires suitable application authentication. Tailscale SSH is a
separate remote-shell feature and is not required by this app.

> **Tip:** develop against the included `tools/stub_health_server.py` first (plain
> HTTP on localhost, in the iOS Simulator) to get the app flow working, then move to
> real HTTPS over Tailscale for on-device use.

---

## Part 2 — The three routes

Implement [`CONTRACT.md`](CONTRACT.md):

- `GET /health` → `{"status":"ok","version":"..."}`.
- `POST /voice/full-romeo` → read `text`, run it through your agent, **stream** the
  reply as SSE (`status: thinking` → `text` deltas → `status: done`).
- `POST /voice/live-transcript` → take the posted transcript and add it to your
  agent's context; reply `{"status":"ok"}`.

The single most important detail is **streaming the Full Romeo reply incrementally**.
The app speaks clauses as they arrive, so stream small `text` deltas as your model
produces them instead of buffering the whole answer. `tools/stub_health_server.py`
shows the exact SSE framing in ~60 lines.

---

## Part 3 — Feed turns into your agent's real session

The point of Full Romeo is that voice turns land in the **same** conversation your
agent already runs (so it shares memory, tools, and continuity) — not a throwaway
side chat.

- **OpenClaw:** build a small channel adapter mirroring the existing Telegram
  adapter — inbound message into the main session, stream the reply out. Tag the
  channel (e.g. `"voice"`). Do **not** create a new session or write storage files
  directly; bind to whatever inbound-message interface your OpenClaw setup exposes.
  The route server is a thin bridge to that adapter.
- **nanoclaw / custom runtimes:** call your normal "handle a user message" entry
  point with the route's `text`, and pipe the streamed reply into the SSE response.
- **Scripted LLM agent:** maintain your own conversation history (a list of
  messages, or your model's session/thread construct). On each Full Romeo turn,
  append the `text`, call the model with streaming enabled, emit each token as a
  `text` delta, then `status: done`. On `POST /voice/live-transcript`, append the
  transcript to that same history.

Continuity across modes is achieved entirely through this shared session: there is
no in-app Live→Full handoff. Live's transcript reaches Full Romeo because you posted
it via `/voice/live-transcript`.

---

## Part 4 — Keep spoken replies concise

A reply that's great to read can be tedious to listen to. Attach a soft style
instruction to the **voice path only** (so it doesn't make your chat/Telegram
replies terse): *"For voice replies, keep it concise and suited to listening; give
more detail only when explicitly asked."*

- Prefer a per-channel / per-session system directive if your runtime supports one.
- Otherwise, prepend a short directive to the `text` before sending it to the model
  (accepting that the prefix is visible in the shared transcript).

Make it a soft instruction, not a hard token cap — a cap truncates mid-sentence.

---

## What you do *not* need to build

- **No token minting or key proxying.** The app calls OpenAI (Live) and ElevenLabs
  (speech + voice) directly with its own keys. Your agent is never in those paths.
- **No audio handling.** The app does all speech-to-text and text-to-speech. Your
  agent only ever sees text.
- **No app-layer auth / tokens / request IDs / de-duplication.** Tailscale
  membership and directional access policy protect reachability, and the app keeps
  a single request in flight.
- **No public hosting, no reverse proxy to the internet.** Tailscale only.

---

## Checklist

- [ ] Tailscale installed on agent machine + phone, same tailnet, phone VPN on.
- [ ] Directional grant or ACL allows the iPhone to reach the exposed agent port.
- [ ] Machine set to never sleep.
- [ ] Agent service bound to `127.0.0.1`; private Tailscale Serve HTTPS configured
      (or a manually managed `tailscale cert` alternative).
- [ ] `tailscale serve status` shows the expected private endpoint when using Serve.
- [ ] `GET /health` returns ok — confirmed from the phone on cellular.
- [ ] `POST /voice/full-romeo` streams `thinking → text deltas → done`.
- [ ] Full Romeo turns enter your real agent session and reply streams back.
- [ ] `POST /voice/live-transcript` accepts the transcript and returns ok.
- [ ] Voice replies are concise.

---

## Troubleshooting: local health works, iPhone times out

If `/health` works on the agent machine but the iPhone times out and the service
logs show no incoming request:

1. Confirm Tailscale is connected on both devices.
2. Confirm the app's Tailnet URL and port.
3. Run `tailscale serve status`.
4. Check the Tailscale **Access Controls** page for an explicit directional grant
   from the iPhone to the agent machine.
5. Test `https://agent-host.your-tailnet.ts.net/health` in Safari on the iPhone,
   adding `:8443` only when that is the exposed port.

Do not enable Funnel as a workaround. It makes the service public instead of
repairing private tailnet access.
