import { createServer } from "node:https";
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import {
  OpenClawBridge,
  buildLiveTranscriptMessage,
  buildVoiceMessage
} from "./openclaw-bridge.mjs";

const VERSION = "0.1.0";
const MAX_JSON_BYTES = 64 * 1024;
const MAX_TRANSCRIPT_BYTES = 1024 * 1024;

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function numberEnv(name, fallback) {
  const raw = process.env[name];
  if (!raw) return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value)) {
    throw new Error(`Invalid number for ${name}: ${raw}`);
  }
  return value;
}

const config = {
  host: process.env.ROMEO_AGENT_HOST || "127.0.0.1",
  port: numberEnv("ROMEO_AGENT_PORT", 8443),
  certFile: requiredEnv("ROMEO_AGENT_CERT_FILE"),
  keyFile: requiredEnv("ROMEO_AGENT_KEY_FILE"),
  openclawBin: process.env.ROMEO_AGENT_OPENCLAW_BIN || "openclaw",
  openclawCwd: process.env.ROMEO_AGENT_OPENCLAW_CWD || `${process.env.HOME}/.openclaw/workspace`,
  openclawSessionKey: process.env.ROMEO_AGENT_OPENCLAW_SESSION_KEY || "agent:main:main",
  openclawTimeoutSeconds: numberEnv("ROMEO_AGENT_OPENCLAW_TIMEOUT_SECONDS", 600),
  openclawTransport: process.env.ROMEO_AGENT_OPENCLAW_TRANSPORT || "gateway",
  openclawGatewayUrl: process.env.ROMEO_AGENT_OPENCLAW_GATEWAY_URL || "ws://127.0.0.1:18789",
  openclawGatewayClientModule: process.env.ROMEO_AGENT_OPENCLAW_GATEWAY_CLIENT_MODULE || "",
  openclawDistDir: process.env.ROMEO_AGENT_OPENCLAW_DIST_DIR || "",
  openclawGatewayFallbackToCli: process.env.ROMEO_AGENT_OPENCLAW_GATEWAY_FALLBACK_TO_CLI !== "0"
};

const tlsOptions = {
  cert: readFileSync(config.certFile),
  key: readFileSync(config.keyFile)
};

function logEvent(event, fields = {}) {
  process.stdout.write(
    JSON.stringify({
      ts: new Date().toISOString(),
      event,
      ...fields
    }) + "\n"
  );
}

const bridge = new OpenClawBridge({ config, logEvent });

function sendJson(res, statusCode, body) {
  const payload = JSON.stringify(body);
  res.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
    "cache-control": "no-store"
  });
  res.end(payload);
}

function sendSse(res, event, data) {
  res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

function readJsonBody(req, maxBytes = MAX_JSON_BYTES) {
  return new Promise((resolve, reject) => {
    let total = 0;
    const chunks = [];

    req.on("data", (chunk) => {
      total += chunk.length;
      if (total > maxBytes) {
        reject(Object.assign(new Error("request body too large"), { statusCode: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on("end", () => {
      try {
        const raw = Buffer.concat(chunks).toString("utf8");
        resolve(raw ? JSON.parse(raw) : {});
      } catch {
        reject(Object.assign(new Error("invalid json"), { statusCode: 400 }));
      }
    });

    req.on("error", reject);
  });
}

async function handleFullRomeo(req, res) {
  const routeStartedAt = Date.now();
  const requestId = randomUUID();
  let body;
  let bodyReadDurationMs = 0;
  try {
    const bodyStartedAt = Date.now();
    body = await readJsonBody(req);
    bodyReadDurationMs = Date.now() - bodyStartedAt;
  } catch (error) {
    return sendJson(res, error.statusCode || 400, { error: error.message });
  }

  const text = typeof body.text === "string" ? body.text.trim() : "";
  if (!text) {
    logEvent("full_romeo.invalid_request", {
      turn_id: requestId,
      reason: "missing_text",
      body_read_duration_ms: bodyReadDurationMs,
      duration_ms: Date.now() - routeStartedAt
    });
    return sendJson(res, 400, { error: "text is required" });
  }

  logEvent("full_romeo.accepted", {
    turn_id: requestId,
    source: body.mode_metadata?.source,
    text_length: text.length,
    body_read_duration_ms: bodyReadDurationMs
  });

  res.writeHead(200, {
    "content-type": "text/event-stream; charset=utf-8",
    "cache-control": "no-cache, no-transform",
    "connection": "keep-alive",
    "x-accel-buffering": "no"
  });
  sendSse(res, "status", { value: "thinking" });

  let responseFinished = false;
  let clientDisconnected = false;
  let sentTextDelta = false;
  res.on("close", () => {
    if (!responseFinished && bridge.abort(requestId)) {
      clientDisconnected = true;
      logEvent("full_romeo.client_disconnected", {
        turn_id: requestId,
        duration_ms: Date.now() - routeStartedAt
      });
    }
  });

  try {
    const result = await bridge.runTurn({
      requestId,
      text: buildVoiceMessage(text),
      logPrefix: "full_romeo",
      onCliFallback: () => {
        if (clientDisconnected || res.destroyed) return;
        sendSse(res, "status", { value: "using_cli_fallback" });
      },
      onDelta: (delta) => {
        if (clientDisconnected || res.destroyed) return;
        sentTextDelta = true;
        sendSse(res, "text", { delta });
      }
    });
    if (clientDisconnected || res.destroyed) {
      return;
    }
    logEvent("full_romeo.reply_complete", {
      turn_id: requestId,
      route_duration_ms: Date.now() - routeStartedAt,
      openclaw_process_duration_ms: result.durationMs,
      reply_length: result.reply.length,
      ...result.meta
    });
    if (!sentTextDelta && result.reply) {
      sendSse(res, "text", { delta: result.reply });
      logEvent("full_romeo.final_text_delta_sent", {
        turn_id: requestId,
        reply_length: result.reply.length,
        transport: result.meta.transport
      });
    }
    sendSse(res, "status", { value: "done" });
    responseFinished = true;
    res.end();
  } catch (error) {
    if (clientDisconnected || res.destroyed) {
      return;
    }
    logEvent("full_romeo.error", {
      turn_id: requestId,
      duration_ms: Date.now() - routeStartedAt,
      message: error.message || "Full Romeo turn failed"
    });
    sendSse(res, "error", { message: error.message || "Full Romeo turn failed" });
    responseFinished = true;
    res.end();
  }
}

async function handleLiveTranscript(req, res) {
  const routeStartedAt = Date.now();
  const requestId = randomUUID();
  let body;
  let bodyReadDurationMs = 0;
  try {
    const bodyStartedAt = Date.now();
    body = await readJsonBody(req, MAX_TRANSCRIPT_BYTES);
    bodyReadDurationMs = Date.now() - bodyStartedAt;
  } catch (error) {
    return sendJson(res, error.statusCode || 400, { error: error.message });
  }

  const transcript = typeof body.transcript === "string" ? body.transcript.trim() : "";
  if (!transcript) {
    logEvent("live_transcript.invalid_request", {
      turn_id: requestId,
      reason: "missing_transcript",
      body_read_duration_ms: bodyReadDurationMs,
      duration_ms: Date.now() - routeStartedAt
    });
    return sendJson(res, 400, { error: "transcript is required" });
  }

  logEvent("live_transcript.accepted", {
    turn_id: requestId,
    transcript_length: transcript.length,
    transcript_lines: transcript.split(/\r?\n/).filter((line) => line.trim()).length,
    body_read_duration_ms: bodyReadDurationMs
  });

  try {
    const result = await bridge.runTurn({
      requestId,
      text: buildLiveTranscriptMessage(transcript),
      logPrefix: "live_transcript"
    });
    logEvent("live_transcript.recorded", {
      turn_id: requestId,
      route_duration_ms: Date.now() - routeStartedAt,
      openclaw_process_duration_ms: result.durationMs,
      reply_length: result.reply.length,
      ...result.meta
    });
    return sendJson(res, 200, { status: "ok" });
  } catch (error) {
    logEvent("live_transcript.error", {
      turn_id: requestId,
      duration_ms: Date.now() - routeStartedAt,
      message: error.message || "Live transcript failed"
    });
    return sendJson(res, 500, { error: error.message || "Live transcript failed" });
  }
}

function requestLogger(req, res) {
  const startedAt = Date.now();
  const httpRequestId = req.headers["x-request-id"] || randomUUID();

  res.on("finish", () => {
    logEvent("http.request", {
      http_request_id: httpRequestId,
      method: req.method,
      url: req.url,
      status: res.statusCode,
      duration_ms: Date.now() - startedAt
    });
  });
}

async function route(req, res) {
  requestLogger(req, res);

  const url = new URL(req.url, "https://localhost");

  if (req.method === "GET" && url.pathname === "/health") {
    return sendJson(res, 200, { status: "ok", version: VERSION });
  }

  if (req.method === "POST" && url.pathname === "/voice/full-romeo") {
    return handleFullRomeo(req, res);
  }

  if (req.method === "POST" && url.pathname === "/voice/live-transcript") {
    return handleLiveTranscript(req, res);
  }

  return sendJson(res, 404, { error: "not_found" });
}

const server = createServer(tlsOptions, route);

server.listen(config.port, config.host, () => {
  logEvent("server_started", {
    version: VERSION,
    host: config.host,
    port: config.port
  });
});

function shutdown(signal) {
  logEvent("shutdown", { signal });
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5000).unref();
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
