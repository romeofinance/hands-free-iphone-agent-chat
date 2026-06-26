import { readFileSync, readdirSync, realpathSync, existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

const GATEWAY_HELLO_TIMEOUT_MS = 10_000;

export const DEFAULT_VOICE_DIRECTIVE =
  "Voice reply directive: be concise and listenable; expand when explicitly asked.";

export function buildVoiceMessage(text, directive = DEFAULT_VOICE_DIRECTIVE) {
  return [directive, "", "User message:", text].join("\n");
}

export function buildLiveTranscriptMessage(transcript) {
  return [
    "Live Romeo session transcript for continuity. Record this in the main session context.",
    "Do not treat this as a new user request. Reply with exactly: OK",
    "",
    transcript
  ].join("\n");
}

function extractJsonObject(output) {
  const start = output.indexOf("{");
  const end = output.lastIndexOf("}");
  if (start < 0 || end < start) {
    throw new Error("openclaw output did not contain JSON");
  }
  return JSON.parse(output.slice(start, end + 1));
}

function extractAgentText(result) {
  const text = result?.result?.finalAssistantVisibleText ||
    result?.result?.finalAssistantRawText ||
    result?.result?.payloads?.map((payload) => payload.text).filter(Boolean).join("\n\n");

  if (!text) {
    throw new Error("openclaw result did not contain assistant text");
  }
  return text;
}

function extractOpenClawMeta(result) {
  const meta = result?.result?.meta || {};
  const agentMeta = meta.agentMeta || {};
  return {
    run_id: result?.runId,
    openclaw_agent_duration_ms: meta.durationMs,
    provider: agentMeta.provider,
    model: agentMeta.model,
    prompt_tokens: agentMeta.promptTokens,
    usage_input_tokens: agentMeta.usage?.input,
    usage_output_tokens: agentMeta.usage?.output,
    usage_total_tokens: agentMeta.usage?.total,
    cache_read_tokens: agentMeta.lastCallUsage?.cacheRead
  };
}

function resolveAgentIdFromSessionKey(sessionKey) {
  const match = /^agent:([^:]+):/.exec(sessionKey);
  return match?.[1] || "main";
}

function textFromGatewayMessage(message) {
  const content = Array.isArray(message?.content) ? message.content : [];
  return content
    .map((block) => (typeof block?.text === "string" ? block.text : ""))
    .join("");
}

export class OpenClawBridge {
  constructor({ config, logEvent }) {
    this.config = config;
    this.logEvent = logEvent;
    this.inFlight = new Map();
    this.gatewayClient = null;
    this.gatewayClientPromise = null;
    this.gatewayClientClassPromise = null;
  }

  abort(requestId, signal = "SIGTERM") {
    const entry = this.inFlight.get(requestId);
    if (!entry) return false;
    if (entry.type === "cli") {
      entry.child.kill(signal);
      return true;
    }
    entry.abort?.();
    return true;
  }

  async runTurn(params) {
    if (this.config.openclawTransport !== "gateway") {
      return this.runCliTurn(params);
    }

    try {
      return await this.runGatewayTurn(params);
    } catch (error) {
      if (
        error.aborted ||
        error.acceptedGatewayRun ||
        !this.config.openclawGatewayFallbackToCli
      ) {
        throw error;
      }
      this.logEvent(`${params.logPrefix}.gateway_fallback_to_cli`, {
        turn_id: params.requestId,
        message: error.message
      });
      params.onCliFallback?.({ message: error.message });
      return this.runCliTurn(params);
    }
  }

  runCliTurn({ requestId, text, logPrefix = "openclaw" }) {
    const startedAt = Date.now();
    const args = [
      "agent",
      "--session-key",
      this.config.openclawSessionKey,
      "--message",
      text,
      "--json",
      "--timeout",
      String(this.config.openclawTimeoutSeconds)
    ];

    const child = spawn(this.config.openclawBin, args, {
      cwd: this.config.openclawCwd,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"]
    });

    this.inFlight.set(requestId, { type: "cli", child });
    this.logEvent(`${logPrefix}.openclaw_spawned`, {
      turn_id: requestId,
      pid: child.pid,
      session_key: this.config.openclawSessionKey
    });

    return new Promise((resolve, reject) => {
      let stdout = "";
      let stderr = "";

      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");

      child.stdout.on("data", (chunk) => {
        stdout += chunk;
      });

      child.stderr.on("data", (chunk) => {
        stderr += chunk;
      });

      child.on("error", (error) => {
        this.inFlight.delete(requestId);
        this.logEvent(`${logPrefix}.openclaw_error`, {
          turn_id: requestId,
          duration_ms: Date.now() - startedAt,
          message: error.message
        });
        reject(error);
      });

      child.on("close", (code, signal) => {
        this.inFlight.delete(requestId);
        const durationMs = Date.now() - startedAt;
        this.logEvent(`${logPrefix}.openclaw_closed`, {
          turn_id: requestId,
          duration_ms: durationMs,
          exit_code: code,
          signal
        });
        if (signal) {
          reject(new Error(`openclaw turn interrupted by ${signal}`));
          return;
        }
        if (code !== 0) {
          reject(new Error(`openclaw exited ${code}: ${stderr.trim() || stdout.trim()}`));
          return;
        }
        try {
          const parsed = extractJsonObject(stdout);
          if (parsed.status && parsed.status !== "ok") {
            reject(new Error(`openclaw status ${parsed.status}`));
            return;
          }
          resolve({
            reply: extractAgentText(parsed),
            meta: {
              ...extractOpenClawMeta(parsed),
              transport: "cli"
            },
            durationMs
          });
        } catch (error) {
          reject(error);
        }
      });
    });
  }

  async runGatewayTurn({
    requestId,
    text,
    logPrefix = "openclaw",
    onFirstToken,
    onDelta
  }) {
    const startedAt = Date.now();
    const controller = new AbortController();
    let client;
    let acceptedSessionKey = this.config.openclawSessionKey;
    let acceptedGatewayRun = false;
    let firstTokenDurationMs;
    let streamedText = "";
    let deltaCount = 0;

    const entry = {
      type: "gateway",
      abort: () => {
        controller.abort();
        client?.request("chat.abort", {
          sessionKey: acceptedSessionKey,
          runId: requestId
        }, { timeoutMs: 2_000 }).catch((error) => {
          this.logEvent(`${logPrefix}.gateway_abort_error`, {
            turn_id: requestId,
            message: error.message
          });
        });
      },
      onChatEvent: (payload) => {
        if (payload.state !== "delta") return;
        const delta = typeof payload.deltaText === "string" ?
          payload.deltaText :
          textFromGatewayMessage(payload.message).slice(streamedText.length);
        if (!delta) return;
        if (firstTokenDurationMs === undefined) {
          firstTokenDurationMs = Date.now() - startedAt;
          this.logEvent(`${logPrefix}.first_token`, {
            turn_id: requestId,
            transport: "gateway",
            first_token_duration_ms: firstTokenDurationMs
          });
          onFirstToken?.({ first_token_duration_ms: firstTokenDurationMs });
        }
        deltaCount += 1;
        streamedText += delta;
        onDelta?.(delta);
      }
    };

    this.inFlight.set(requestId, entry);
    this.logEvent(`${logPrefix}.gateway_dispatching`, {
      turn_id: requestId,
      session_key: this.config.openclawSessionKey,
      gateway_url: this.config.openclawGatewayUrl
    });

    try {
      client = await this.getGatewayClient();
      const result = await client.request("agent", {
        message: text,
        agentId: resolveAgentIdFromSessionKey(this.config.openclawSessionKey),
        sessionKey: this.config.openclawSessionKey,
        deliver: false,
        timeout: this.config.openclawTimeoutSeconds,
        cleanupBundleMcpOnRunEnd: true,
        idempotencyKey: requestId
      }, {
        expectFinal: true,
        timeoutMs: (this.config.openclawTimeoutSeconds + 30) * 1000,
        signal: controller.signal,
        onAccepted: (payload) => {
          acceptedGatewayRun = true;
          acceptedSessionKey = payload?.sessionKey || acceptedSessionKey;
          this.logEvent(`${logPrefix}.gateway_accepted`, {
            turn_id: requestId,
            run_id: payload?.runId,
            session_key: acceptedSessionKey,
            accepted_at: payload?.acceptedAt
          });
        }
      });

      const reply = extractAgentText(result);
      if (deltaCount === 0 && reply) {
        // Older or changed OpenClaw builds may not publish chat deltas through the
        // Gateway event stream. Preserve the app contract by sending the final text
        // as a single delta and make the behavior visible in logs.
        deltaCount = 1;
        onDelta?.(reply);
        this.logEvent(`${logPrefix}.final_text_delta_fallback`, {
          turn_id: requestId,
          reply_length: reply.length
        });
      }

      const durationMs = Date.now() - startedAt;
      this.logEvent(`${logPrefix}.gateway_completed`, {
        turn_id: requestId,
        duration_ms: durationMs,
        delta_count: deltaCount,
        first_token_duration_ms: firstTokenDurationMs
      });

      return {
        reply,
        meta: {
          ...extractOpenClawMeta(result),
          transport: "gateway",
          first_token_duration_ms: firstTokenDurationMs,
          delta_count: deltaCount
        },
        durationMs
      };
    } catch (error) {
      error.deltaCount = deltaCount;
      error.acceptedGatewayRun = acceptedGatewayRun;
      error.aborted = controller.signal.aborted;
      throw error;
    } finally {
      this.inFlight.delete(requestId);
    }
  }

  resolveOpenClawDistDir() {
    const candidates = [];
    if (this.config.openclawDistDir) candidates.push(this.config.openclawDistDir);
    if (this.config.openclawBin && this.config.openclawBin.includes("/")) {
      try {
        candidates.push(join(dirname(realpathSync(this.config.openclawBin)), "dist"));
      } catch {
        // Continue to other candidates.
      }
    }
    try {
      const require = createRequire(import.meta.url);
      candidates.push(dirname(require.resolve("openclaw")));
    } catch {
      // Continue to common global-install candidates.
    }
    candidates.push("/opt/homebrew/lib/node_modules/openclaw/dist");
    candidates.push("/usr/local/lib/node_modules/openclaw/dist");
    for (const dir of candidates) {
      if (dir && existsSync(dir)) return dir;
    }
    throw new Error("could not locate openclaw dist directory");
  }

  async loadGatewayClientClass() {
    if (this.config.openclawGatewayClientModule) {
      const mod = await import(this.config.openclawGatewayClientModule);
      if (typeof mod.GatewayClient === "function") return mod.GatewayClient;
      throw new Error(
        `configured gateway client module has no GatewayClient export: ${this.config.openclawGatewayClientModule}`
      );
    }

    const distDir = this.resolveOpenClawDistDir();
    const candidateFiles = readdirSync(distDir)
      .filter((name) => /^client-.*\.js$/.test(name))
      .filter((name) => {
        try {
          return readFileSync(join(distDir, name), "utf8").includes("GatewayClient");
        } catch {
          return false;
        }
      });

    for (const name of candidateFiles) {
      try {
        const modulePath = join(distDir, name);
        const mod = await import(pathToFileURL(modulePath).href);
        if (typeof mod.GatewayClient === "function") {
          this.logEvent("gateway.client_module_resolved", { module: modulePath });
          return mod.GatewayClient;
        }
      } catch {
        // Keep scanning remaining candidates.
      }
    }
    throw new Error(`could not locate GatewayClient export in ${distDir}`);
  }

  getGatewayClientClass() {
    if (!this.gatewayClientClassPromise) {
      this.gatewayClientClassPromise = this.loadGatewayClientClass().catch((error) => {
        this.gatewayClientClassPromise = null;
        throw error;
      });
    }
    return this.gatewayClientClassPromise;
  }

  async getGatewayClient() {
    if (this.gatewayClient) return this.gatewayClient;
    if (this.gatewayClientPromise) return this.gatewayClientPromise;

    this.gatewayClientPromise = (async () => {
      const GatewayClient = await this.getGatewayClientClass();
      let resolveHello;
      let rejectHello;
      let helloTimeout;
      const hello = new Promise((resolve, reject) => {
        resolveHello = resolve;
        rejectHello = reject;
      });
      const helloWithTimeout = Promise.race([
        hello,
        new Promise((_, reject) => {
          helloTimeout = setTimeout(() => {
            reject(new Error(`gateway hello timed out after ${GATEWAY_HELLO_TIMEOUT_MS}ms`));
          }, GATEWAY_HELLO_TIMEOUT_MS);
          helloTimeout.unref?.();
        })
      ]);

      const client = new GatewayClient({
        url: this.config.openclawGatewayUrl,
        // "cli" identifies the client role expected by the Gateway. This is still
        // the warm WebSocket transport, not a process-spawned CLI turn.
        clientName: "cli",
        clientDisplayName: "romeo-agent-openclaw",
        mode: "cli",
        requestTimeoutMs: 10_000,
        onHelloOk: (payload) => resolveHello(payload),
        onConnectError: (error) => rejectHello(error),
        onClose: (code, reason) => {
          this.logEvent("gateway.closed", { code, reason });
          this.gatewayClient = null;
          this.gatewayClientPromise = null;
        },
        onEvent: (event) => {
          if (event.event !== "chat") return;
          const payload = event.payload || {};
          const entry = this.inFlight.get(payload.runId);
          if (entry?.type !== "gateway") return;
          entry.onChatEvent(payload);
        }
      });

      client.start();
      try {
        await helloWithTimeout;
      } catch (error) {
        client.stop?.();
        throw error;
      } finally {
        if (helloTimeout) clearTimeout(helloTimeout);
      }
      this.gatewayClient = client;
      this.logEvent("gateway.connected", { url: this.config.openclawGatewayUrl });
      return client;
    })();

    try {
      return await this.gatewayClientPromise;
    } catch (error) {
      this.gatewayClientPromise = null;
      this.gatewayClient = null;
      throw error;
    }
  }
}
