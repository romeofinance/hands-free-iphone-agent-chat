# Hands-free iPhone Agent Chat

Romeo is a small SwiftUI iPhone app that gives you **hands-free, spoken access to
your own AI agent** while you're walking, running, or otherwise away from a
keyboard — with your music still playing in the background. You summon it with a
Siri phrase, talk, and hear the reply.

The app is a **thin client**. It does not contain an AI brain. It talks to *your*
agent, running on a machine you control (a Mac mini, a home server, a laptop —
anything that's always on), reached privately over [Tailscale](https://tailscale.com).
Your agent is referred to throughout as **Agent One**; the app is **Agent Two**.

> This repository contains the complete **app side** (Agent Two) and an optional
> OpenClaw bridge for the agent side. If you use another agent, implement the tiny
> HTTP contract described in [`docs/AGENT_SIDE.md`](docs/AGENT_SIDE.md). You do
> **not** need to rebuild the app from scratch — start from this code and adapt it.

Everything is named "Romeo". You can keep that name or rename it to your own
agent — see [Renaming the app](#renaming-the-app-and-the-siri-phrases) (this also
changes the Siri phrases, so read it before you rename).

---

## What it does

There are two conversation modes, plus a typed fallback.

### Full Romeo (one turn at a time) — "the real agent"
Each turn is a self-contained question to your agent.

1. Say **"Hey Siri, Romeo mode."** The app launches straight into listening.
2. A single metal-bell cue confirms that Romeo activated.
3. Speak your question, then say **"Romeo, over."** to submit.
4. A double cue confirms submission. The app releases the mic, and your music
   returns to full volume while the agent thinks.
5. The reply is streamed back from your agent and spoken aloud (music ducks during
   the reply, then restores).
6. The turn ends; the app goes idle. The next turn is a fresh "Hey Siri, Romeo mode."

Full Romeo sends **text**, not audio, to your agent. Speech-to-text happens on the
phone. The agent never sees audio.

The diagnostics row normally shows `Gateway`. If the agent emits the optional
`using_cli_fallback` SSE status, it changes to `CLI fallback` for that turn. This
is informational only: it is not spoken, does not change TTS, and does not trigger
an app retry. Unknown future status values are ignored safely.

### Live Romeo (continuous conversation)
A fast, fluid, interruptible back-and-forth using OpenAI's realtime model directly.

1. Say **"Hey Siri, Romeo live."** A single cue confirms activation.
2. Talk naturally — end-of-speech is detected automatically (server VAD); no
   keyword is needed between turns.
3. Say **"Romeo, over."** to end the whole session. A double cue confirms the end.
4. The full conversation transcript is posted to your agent, so a later Full
   Romeo turn already has the context.

Live Romeo connects **phone → OpenAI directly** over WebRTC using your own OpenAI
key. The current configuration uses `gpt-realtime-2.1`, low reasoning effort, and
the `ash` voice. Your agent is not involved during the live call (only the
transcript at the end).

### Romeo stop
Say **"Hey Siri, Romeo stop"** for a phase-independent stop. It cancels a Full turn
or typed request, ends and posts an active Live transcript, stops spoken playback,
and releases the audio session so your music can return. It does not call a
dedicated cancellation route on your agent.

### Typed fallback
The main screen has a text field that sends a typed message to your agent and
shows the streamed reply. Handy when you can't talk, or for testing your agent
connection without using voice.

---

## How the pieces fit together

```
                Tailscale (private, encrypted)
  ┌───────────────┐  POST /voice/full-romeo (text in, SSE reply)   ┌──────────────┐
  │   iPhone app  │ ───────────────────────────────────────────▶  │  Agent One   │
  │   (this repo) │  POST /voice/live-transcript (after a Live)     │ (your agent) │
  │   "Agent Two" │ ◀───────────────────────────────────────────  │  on a Mac/PC │
  └───────┬───────┘            GET /health                          └──────────────┘
          │
          │  WebRTC media, phone → OpenAI directly (Live mode only)
          ▼
   ┌──────────────┐        ┌──────────────────────────────────────┐
   │   OpenAI     │        │ ElevenLabs (Full Romeo: TTS + optional │
   │ realtime API │        │ Scribe speech-to-text), called direct  │
   └──────────────┘        └──────────────────────────────────────┘
```

- **Full Romeo** is a cascade: on-device speech-to-text → POST the text to your
  agent → your agent streams a text reply back → the app speaks it with ElevenLabs.
- **Live Romeo** is OpenAI's hosted realtime model over WebRTC, phone-to-OpenAI direct.
- **The only thing your agent must implement is the HTTP contract** in
  [`docs/CONTRACT.md`](docs/CONTRACT.md): three small routes.
- **Your service keys (OpenAI, ElevenLabs) are stored only on the phone.** The app
  sends them directly to those providers over TLS; your agent never receives,
  mints, or proxies them.

---

## Before you begin — what you'll need

Gather and prep all of this **before** opening the code. First-time setup is
mostly creating accounts and getting Tailscale working; budget an hour or so.

### Accounts, API keys, and costs
- [ ] **An Apple developer account for signing.** To install on a physical iPhone
      you must sign the app with an Apple ID:
  - A **free Apple ID** works (a "Personal Team") — fine for your own device, but
    the app must be re-signed every 7 days and you can't use some paid
    capabilities.
  - A **paid Apple Developer Program** membership ($99/year) gives longer
    provisioning and is the smoother option if you'll use this daily.
- [ ] **An OpenAI account + API key** — *only* needed for **Live Romeo** (the
      realtime mode). Live calls cost roughly a few cents per minute; set a spend
      cap. Skip this if you only want Full Romeo.
- [ ] **An ElevenLabs account + API key + a Voice ID** — needed for **spoken
      replies** (text-to-speech) and, optionally, for higher-quality speech-to-text
      (Scribe). Pick or create a voice in your ElevenLabs library and copy its
      **Voice ID**. Paid usage; set a spend cap.
- [ ] **A Tailscale account** (the free Personal plan is enough) — this is how the
      phone reaches your agent privately. See [Tailscale, specifically](#tailscale-specifically) below.

> Use **dedicated, revocable** API keys with spend caps. They live only in your
> iPhone's Keychain, but treat them like cash. None of these keys go in the repo.

### Hardware
- [ ] **An iPhone running iOS 26 or later.** (The on-device speech-to-text uses
      Apple's `SpeechAnalyzer`, which is iOS 26+.)
- [ ] **A Mac that can run Xcode 26+** — used to build and install the app onto your iPhone.
- [ ] **An always-on machine to host your agent** ("Agent One") — a Mac mini, an
      old Mac, a home server, etc. It must stay awake and online so you can reach
      it from anywhere. (It can be the same Mac you build with, but a dedicated
      always-on box is the intended setup.)
- [ ] **AirPods or other Bluetooth earbuds** *(recommended)* — the hands-free,
      walking-with-music experience is designed around them.

### Software to install
- [ ] **Xcode 26+** on the Mac (free from the Mac App Store).
- [ ] **Tailscale on the agent machine**, signed into your tailnet.
- [ ] **Tailscale on the iPhone**, signed into the **same** tailnet, with the VPN
      profile left enabled.
- [ ] **The `tailscale` command-line tool** on the agent machine (used to mint the
      HTTPS certificate). On macOS the Tailscale app can install it; on Linux it
      comes with the package.
- [ ] *(optional)* **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — only if
      you edit `project.yml`. A ready-to-open `Romeo.xcodeproj` is already included,
      so you can skip this.
- [ ] *(optional)* **Python 3** — only to run the bundled stub server for testing
      before your real agent is ready.

### Tailscale, specifically
Tailscale is what lets your phone talk to your agent privately from anywhere
(including cellular), with no public internet exposure. The topology:

```
   iPhone (Tailscale app)  ──┐
                             ├── same tailnet ──►  reach each other by MagicDNS name
   Agent machine (Tailscale)─┘                     e.g. my-server.my-tailnet.ts.net
```

1. **Create a Tailscale account.** You now have a **tailnet** (your private network).
2. In the **Tailscale admin console**, make sure **MagicDNS** and **HTTPS
   certificates** are enabled (both are needed for `tailscale cert`).
3. **Install Tailscale on the agent machine** and sign in. It joins your tailnet
   and gets a stable **MagicDNS name** like `my-server.my-tailnet.ts.net`.
4. **Install Tailscale on the iPhone**, sign into the **same** tailnet, and leave
   the VPN profile **on** (so it works on cellular, away from home).
5. **On the agent machine, mint a real TLS cert** for its name (iOS requires real
   HTTPS):
   ```sh
   tailscale cert my-server.my-tailnet.ts.net
   ```
6. That MagicDNS name + port (this project uses `8443`) is the **Mini Tailnet URL**
   you'll enter in the app: `https://my-server.my-tailnet.ts.net:8443`.

Full agent-side networking steps (keeping the machine awake, serving HTTPS, etc.)
are in [`docs/AGENT_SIDE.md`](docs/AGENT_SIDE.md).

### Your agent (Agent One)
- [ ] **A running agent** on the always-on machine — OpenClaw, nanoclaw, or a
      scripted Claude Code / Codex / LLM agent — that you'll wire up to the three
      HTTP routes in [`docs/CONTRACT.md`](docs/CONTRACT.md). Guide:
      [`docs/AGENT_SIDE.md`](docs/AGENT_SIDE.md).

### Skills assumed
You're comfortable building and running an app from Xcode, using a terminal, and
running a small HTTP server on your agent machine. You do **not** need to be an iOS
developer — but you do need to follow the signing and Tailscale steps carefully.

---

## Signing, build, and install

1. **Get the project open.**
   - Easiest: open the included `Romeo.xcodeproj` in Xcode.
   - Or, if you changed `project.yml`: run `xcodegen generate` first.

2. **Set your signing team.** This template ships with an **empty** development
   team on purpose (so it carries none of the original author's identity). In
   Xcode: select the **Romeo** target → **Signing & Capabilities** → check
   *Automatically manage signing* → pick **your** Team. (Or set `DEVELOPMENT_TEAM`
   in `project.yml` and re-run `xcodegen generate`.) You may also want to change
   the **Bundle Identifier** from `com.example.romeo` to your own.

   > **Do not commit your real Team ID or a personal bundle id back into a public
   > repo** if you want to keep them private.

3. **Build to your iPhone.** Select your phone as the run destination and press
   Run (▶). The first install on a device requires trusting the developer profile
   on the phone (Settings → General → VPN & Device Management).

4. **Verify the test suite (optional).**
   ```sh
   xcodebuild -project Romeo.xcodeproj -scheme Romeo \
     -destination 'platform=iOS Simulator,name=iPhone 17' test
   ```

> Audio behavior (ducking, AirPods HFP/A2DP transitions, the mic indicator) **only
> shows up on a real iPhone** — the simulator will not surface it. Test voice on
> device.

---

## First-run configuration (in the app)

Open the app and fill in the **Configuration** section, then tap a **Test** button
to confirm each one:

| Field | What it is |
|-------|-----------|
| **Mini Tailnet URL** | Your agent's HTTPS base URL, e.g. `https://my-server.my-tailnet.ts.net:8443`. The app appends route paths itself — do **not** include `/health` etc. |
| **ElevenLabs API Key** | Used for spoken replies (and Scribe speech-to-text if you pick it). Stored in the Keychain. |
| **ElevenLabs Voice ID** | The voice your agent speaks in. Copy it from your ElevenLabs voice library. |
| **OpenAI API Key** | Only needed for Live Romeo. Stored in the Keychain. |
| **STT** | Speech-to-text engine for Full Romeo: **Apple** (on-device, free, iOS 26+) or **ElevenLabs Scribe** (cloud, often more accurate, needs the ElevenLabs key). |
| **Audio Duck** | How far your music drops while you're speaking / while the agent speaks in Live mode. Default **Max**. |

Use **Check Health** to confirm the phone can reach your agent. (Tip: while you're
building the agent side, you can point this at the included stub server — see
[Testing without a full agent](#testing-without-a-full-agent).)

---

## Using it hands-free (the intended path)

The whole point is a single unlock at the start of a walk and **no touching the
phone after that**.

### The Siri phrases
The three phrases are built from the **app's name** plus a keyword:

- **"Hey Siri, Romeo mode"** → Full Romeo (one turn)
- **"Hey Siri, Romeo live"** → Live Romeo (continuous)
- **"Hey Siri, Romeo stop"** → stop a spoken reply early

> **The phrases follow the app's name.** Because the app is named *Romeo*, the
> phrases are "Romeo …". If you rename the app to *Jarvis*, they become "Jarvis
> mode", "Jarvis live", "Jarvis stop" automatically. The keywords (*mode*, *live*,
> *stop*) were chosen so they contain no "call/text/talk-to" verb — otherwise Siri
> might try to call a **contact** with that name instead of opening the app. If you
> rename, keep that in mind and test on-device that Siri opens the app and doesn't
> dial a contact.

The in-conversation **end phrase is "Romeo, over."** This is **separate** from the
app name and is hard-coded in the app. If you rename your agent and want the end
phrase to match, see [Renaming](#renaming-the-app-and-the-siri-phrases).

The cues are deliberately distinct: one ring means the requested mode activated;
two rings mean a Full turn was submitted or a Live session ended.

Mode requests are serialized. Repeating **"Romeo mode"** while a Full request is
still thinking says *"I'm still thinking"* without opening another microphone or
sending a duplicate. Requesting **"Romeo live"** instead cancels the pending Full
turn locally before Live starts. An unrelated Siri request during Full thinking
does not discard the already-submitted Full reply.

### Walking with music playing (AirPods)
This is the designed-for scenario.

- Start your music in any app (Spotify, Apple Music, a podcast — Romeo doesn't care which).
- Say "Hey Siri, Romeo mode" and talk. While the mic is open your music **ducks**
  (drops in volume) and AirPods briefly switch to call quality (HFP) — this is
  normal and unavoidable while any mic is live.
- After you say "Romeo, over", the mic is released, AirPods return to full music
  quality, and your **music comes back to full volume while the agent thinks**
  (that wait can be long, and full music there is intentional).
- The reply is spoken with the music ducked underneath, then your music restores.
- Background music is **ducked, never paused** — so there's nothing to "resume",
  and it works regardless of which music app you use.
- If microphone startup is interrupted, the app tears down the stale audio path,
  retries once, and shows an error rather than remaining in a false Listening state.

You can adjust how deep the duck goes in the **Audio Duck** section.

### Keeping the phone awake without it locking in your pocket
Two features work together so you get **one unlock at the start and none after**:

- **Auto-lock is disabled while the app is in the foreground.** The phone won't
  sleep mid-walk, so each "Hey Siri, Romeo mode" lands on an already-unlocked
  phone. Normal auto-lock returns when you leave the app. (Each Siri launch briefly
  backgrounds and refocuses the app; the app is careful that this does not let
  auto-lock creep back in.)
- **Pocket Mode** — tap **Enter Pocket Mode** to drop a black screen that **ignores
  stray touches** so nothing in your pocket can disturb a turn. To wake the normal
  UI, **long-press** the screen (about 1.5 s). A quick accidental tap does nothing.
  Pocket Mode never persists across an app relaunch, so you can't get stuck on a
  blank screen.

The result: awake, dark, and touch-resistant in your pocket, summoned entirely by
voice.

---

## Renaming the app (and the Siri phrases)

To turn "Romeo" into your own agent's name, change these (most are cosmetic; the
two **bold** ones change behavior):

1. **App name → changes the Siri launch phrases.** Rename the app: in `project.yml`
   set the target name and `CFBundleDisplayName` to your agent's name, then
   `xcodegen generate`. The Siri phrases automatically follow (they're defined as
   `"\(.applicationName) mode"` etc. in `RomeoApp/Intents/RomeoModeIntent.swift`).
2. **End phrase "Romeo, over" → edit the detector.** It lives in
   `RomeoApp/Speech/RomeoCommandDetector.swift` (it looks for the words *romeo* then
   *over*). Change those tokens to your preferred end phrase. Keep it short,
   end-anchored, and unlikely to occur by accident.
3. Live mode spoken persona: `RomeoApp/Live/LiveRealtimeSession.swift` (the
   `instructions` string).
4. Speech-to-text keyterms (helps transcription accuracy): `defaultKeyterms` in
   `RomeoApp/Speech/ElevenLabsScribeTranscriber.swift` — seed with your agent name,
   collaborators, jargon.
5. Cosmetic on-screen labels: `RomeoApp/Views/HealthCheckView.swift`.

Keeping the name "Romeo" is completely fine — you can skip all of this.

---

## The agent side (Agent One)

This is the part you implement. Your agent must answer three small HTTP routes over
Tailscale-served HTTPS. In short, your agent needs to:
- Serve `GET /health`, `POST /voice/full-romeo` (streamed reply), and
  `POST /voice/live-transcript`.
- Be reachable on your tailnet over real HTTPS (use `tailscale cert`).
- Feed Full Romeo turns into your agent's normal conversation/session and stream
  the reply back as Server-Sent Events.

### If you use OpenClaw: detailed, ready-to-run setup is included
If your agent is **OpenClaw**, you don't have to write the agent side yourself.
[`agent-openclaw/`](agent-openclaw/) is a complete, working reference
implementation — a Node HTTPS bridge that posts voice turns into your existing
OpenClaw session and streams the reply back — with **step-by-step setup
instructions**, `tailscale cert` and exposure guidance, launchd/systemd service
templates, `curl` tests, and troubleshooting in
[`agent-openclaw/README.md`](agent-openclaw/README.md) (plus implementer notes in
[`agent-openclaw/NOTES.md`](agent-openclaw/NOTES.md)). For an OpenClaw setup, start
there.

### If you use a different agent (nanoclaw, a scripted Claude Code / Codex agent, etc.)
You'll wire it up differently — there's no drop-in package for other runtimes — but
the target is identical: implement the same three routes from
[`docs/CONTRACT.md`](docs/CONTRACT.md). Two things to read:
- [`docs/AGENT_SIDE.md`](docs/AGENT_SIDE.md) — a runtime-agnostic build guide with
  concrete paths for OpenClaw, nanoclaw, and a hand-scripted LLM agent.
- [`agent-openclaw/`](agent-openclaw/) — even though it's OpenClaw-specific, it's
  the most detailed worked example available, so **use it as a reference** for the
  pieces every agent needs: serving HTTPS with a `tailscale cert`, emitting the SSE
  `thinking → text deltas → done` stream, the CLI/streaming fallback pattern, the
  concise-voice directive, and the service/keep-awake setup. Adapt those patterns to
  however your agent ingests a message and produces a reply.

The smallest possible working example of the contract is
[`tools/stub_health_server.py`](tools/stub_health_server.py) (~60 lines) — handy to
read first if you're starting from scratch.

---

## Testing without a full agent

A tiny reference server is included that implements just enough of the contract to
prove the app works end to end:

```sh
python3 tools/stub_health_server.py
```

It serves `GET /health` and a streamed `POST /voice/full-romeo` on
`http://127.0.0.1:8443`. In the iOS **Simulator**, set the Mini URL to
`http://127.0.0.1:8443` and try Check Health and the typed fallback. (Plain HTTP to
localhost is allowed; the real phone, over Tailscale, requires HTTPS.) This file is
also the smallest possible example of the contract if you're writing your agent
from scratch.

---

## Security and privacy notes

- **Your keys are stored only on the phone.** OpenAI and ElevenLabs keys are kept
  in the iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and sent
  directly to those providers over TLS. They are never sent to your agent and are
  not in this repository.
- **Nothing is exposed to the public internet.** The phone reaches your agent only
  over your private Tailscale network. There is no public endpoint and no app token
  — tailnet membership *is* the access control.
- Use dedicated, revocable API keys with spend caps. A standard client-side key is
  an accepted tradeoff for a single-user personal app; it is not appropriate for a
  mass-distributed app.
- This repo intentionally contains **no** API keys, no Apple Team ID, no private
  endpoint, and no machine-local identifiers. Set your own during configuration
  and signing.

---

## Project layout

```
RomeoApp/            The app (SwiftUI)
  App/               App entry point
  Intents/           App Shortcuts / Siri intents (the three phrases)
  ViewModels/        Full Romeo (voice + typed) and Live Romeo state machines
  Views/             The single configuration + control screen
  Audio/             AVAudioSession setup (duck, mic, route handling)
  Speech/            Apple + ElevenLabs speech-to-text; "Romeo, over" detector
  TTS/               ElevenLabs text-to-speech + playback queue
  Live/              WebRTC realtime session (OpenAI)
  Networking/        Calls to your agent (health, full-romeo SSE, live transcript)
  Storage/           Keychain
  Models/, Config/, Diagnostics/, Resources/
RomeoTests/          Unit tests
tools/               stub_health_server.py (contract reference / local testing)
docs/                CONTRACT.md (the HTTP contract) and AGENT_SIDE.md (build guide)
project.yml          XcodeGen project definition
```

## License

MIT — see [`LICENSE`](LICENSE).
