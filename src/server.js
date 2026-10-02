// ChannelChat (codename "Anansi") HTTP/HTTPS exchange server.
//
// Routes:
//   GET  /healthz            -> liveness + dictionaryId + protocolVersion
//   POST /api/v1/exchange    -> validate, decode, re-encode (echo), respond
//
// HTTP on port 80 is a first-class mode: no TLS files required. HTTPS is optional and uses
// the SAME application protocol and codec. The transport is chosen by how you start the
// server (tls option) and, on the client, by the URL scheme -- there is no separate flag.
//
// Limits are enforced WHILE reading (not only after allocation). Content-Length is not
// trusted on its own. Every response sets JSON+UTF-8 and Cache-Control: no-store.

import http from "node:http";
import https from "node:https";
import { randomUUID } from "node:crypto";
import { ChannelError, CODES } from "./errors.js";
import { DEFAULT_LIMITS } from "./limits.js";
import {
  PROTOCOL_VERSION,
  errorBody,
  handleExchange,
  parseRequestEnvelope,
  statusForCode,
} from "./protocol.js";

const EXCHANGE_PATH = "/api/v1/exchange";
const HEALTH_PATH = "/healthz";

export function buildServer({ dict, limits = DEFAULT_LIMITS, tls = null, logger = defaultLogger } = {}) {
  if (!dict || !dict.id) throw new Error("buildServer requires a validated dictionary");

  let inflight = 0;

  const handler = (req, res) => {
    const reqId = randomUUID();
    const started = process.hrtime.bigint();
    let requestBytes = 0;
    res.setHeader("X-Request-Id", reqId);

    const done = (status, bodyObj, extra = {}) => {
      const buf = Buffer.from(JSON.stringify(bodyObj), "utf8");
      if (!res.headersSent) {
        res.writeHead(status, {
          "Content-Type": "application/json; charset=utf-8",
          "Cache-Control": "no-store",
          "Content-Length": String(buf.length),
        });
      }
      res.end(buf);
      const durMs = Number(process.hrtime.bigint() - started) / 1e6;
      logger({
        reqId,
        method: req.method,
        path: safePath(req.url),
        status,
        durationMs: Math.round(durMs * 1000) / 1000,
        requestBytes,
        responseBytes: buf.length,
        code: extra.code || null,
      });
    };

    const failResp = (err) => {
      const code = err instanceof ChannelError ? err.code : CODES.SERVER_INTERNAL;
      const status = statusForCode(code);
      const message = err instanceof ChannelError ? err.detail : "internal error";
      done(status, errorBody(code, message), { code });
    };

    // Concurrency cap.
    if (inflight >= limits.maxConcurrentRequests) {
      done(503, errorBody(CODES.SERVER_BUSY, "server busy"), { code: CODES.SERVER_BUSY });
      return;
    }
    inflight++;
    let settled = false;
    const release = () => {
      if (!settled) {
        settled = true;
        inflight--;
      }
    };
    res.on("close", release);
    res.on("finish", release);

    // Whole-request deadline.
    req.setTimeout(limits.requestTimeoutMs, () => {
      failResp(new ChannelError(CODES.SERVER_TIMEOUT, "request timed out"));
      req.destroy();
    });

    const url = safePath(req.url);

    if (req.method === "GET" && url === HEALTH_PATH) {
      // Drain and ignore any body.
      req.resume();
      done(200, { status: "ok", protocolVersion: PROTOCOL_VERSION, dictionaryId: dict.id });
      return;
    }

    if (url === EXCHANGE_PATH && req.method !== "POST") {
      req.resume();
      done(405, errorBody(CODES.SERVER_METHOD_NOT_ALLOWED, "method not allowed"), {
        code: CODES.SERVER_METHOD_NOT_ALLOWED,
      });
      return;
    }

    if (!(req.method === "POST" && url === EXCHANGE_PATH)) {
      req.resume();
      done(404, errorBody(CODES.SERVER_NOT_FOUND, "not found"), { code: CODES.SERVER_NOT_FOUND });
      return;
    }

    // Reject oversize up front if Content-Length claims too much (but never trust it alone).
    const cl = Number(req.headers["content-length"]);
    if (Number.isFinite(cl) && cl > limits.maxRequestBodyBytes) {
      req.resume();
      failResp(new ChannelError(CODES.PROTO_BODY_TOO_LARGE, "request body too large"));
      return;
    }

    const chunks = [];
    req.on("data", (chunk) => {
      requestBytes += chunk.length;
      if (requestBytes > limits.maxRequestBodyBytes) {
        // Enforce WHILE reading; stop accepting more and respond.
        failResp(new ChannelError(CODES.PROTO_BODY_TOO_LARGE, "request body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("aborted", () => release());
    req.on("error", () => {
      if (!res.headersSent) failResp(new ChannelError(CODES.SERVER_INTERNAL, "request error"));
      release();
    });
    req.on("end", () => {
      if (res.headersSent) return; // already failed (e.g. oversize)
      try {
        const body = Buffer.concat(chunks);
        const env = parseRequestEnvelope(body, limits);
        const responseEnv = handleExchange(env, dict, limits);
        done(200, responseEnv);
      } catch (err) {
        failResp(err);
      }
    });
  };

  const server = tls ? https.createServer(tls, handler) : http.createServer(handler);
  // Node-level hardening: bound time spent receiving headers and the whole request.
  server.headersTimeout = limits.headersTimeoutMs;
  server.requestTimeout = limits.requestTimeoutMs;

  return {
    server,
    isTls: Boolean(tls),
    getInflight: () => inflight,
    listen(port, host) {
      return new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, host, () => {
          server.off("error", reject);
          resolve(server.address());
        });
      });
    },
    close() {
      return new Promise((resolve) => server.close(() => resolve()));
    },
  };
}

function safePath(rawUrl) {
  try {
    return new URL(rawUrl, "http://placeholder").pathname;
  } catch {
    return "/";
  }
}

function defaultLogger(entry) {
  // Structured line; never logs payloads or message contents.
  process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), ...entry }) + "\n");
}
