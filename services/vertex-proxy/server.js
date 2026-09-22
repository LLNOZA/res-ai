import http from "node:http";
import { timingSafeEqual } from "node:crypto";
import { pathToFileURL } from "node:url";

const PORT = Number(process.env.PORT || 8080);
const MAX_BODY_BYTES = 128 * 1024;
export function createProxyServer({ env = process.env, fetchImpl = fetch, timeoutMs = Number(env.VERTEX_TIMEOUT_MS || 18000) } = {}) {
const requestDeadlineMs = Number.isFinite(timeoutMs) ? Math.min(Math.max(timeoutMs, 1), 60000) : 18000;
let activeRequests = 0;
const server = http.createServer(async (req, res) => {
  let admitted = false;
  const controller = new AbortController();
  const deadline = setTimeout(() => controller.abort(), requestDeadlineMs);
  const disconnect = () => { if (!res.writableEnded) controller.abort(); };
  req.once("aborted", disconnect);
  res.once("close", disconnect);
  try {
    if (req.method === "GET" && req.url === "/healthz") {
      return sendJSON(res, 200, { ok: true });
    }

    if (req.method !== "POST" || req.url !== "/v1/rewrite") {
      return sendJSON(res, 404, { error: "not_found" });
    }

    const expectedSecret = env.RESAI_PROXY_SHARED_SECRET || "";
    if (!expectedSecret.trim()) {
      return sendJSON(res, 503, { error: "proxy_auth_not_configured" });
    }
    const providedSecret = req.headers["x-resai-proxy-key"] || "";
    const expected = Buffer.from(expectedSecret);
    const provided = Buffer.from(String(providedSecret));
    if (provided.length !== expected.length || !timingSafeEqual(provided, expected)) {
      return sendJSON(res, 401, { error: "unauthorized" });
    }
    if (activeRequests >= 16) return sendJSON(res, 429, { error: "busy" });
    activeRequests += 1;
    admitted = true;

    const body = await readJSON(req, controller.signal);
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return sendJSON(res, 400, { error: "invalid_request" });
    }
    const systemInstruction = stringField(body.systemInstruction);
    const userPrompt = stringField(body.userPrompt);

    if (!systemInstruction || !userPrompt) {
      return sendJSON(res, 400, { error: "systemInstruction and userPrompt are required" });
    }

    const projectID = env.VERTEX_PROJECT_ID || env.GOOGLE_CLOUD_PROJECT;
    const location = env.VERTEX_LOCATION || "global";
    const model = env.VERTEX_MODEL || "gemini-3.5-flash";

    if (!projectID) {
      return sendJSON(res, 500, { error: "VERTEX_PROJECT_ID is not configured" });
    }

    const accessToken = await accessTokenForVertex(env, fetchImpl, controller.signal);
    const vertexResponse = await callVertexAI({
      projectID,
      location,
      model,
      accessToken,
      systemInstruction,
      userPrompt,
      fetchImpl,
      signal: controller.signal
    });

    return sendJSON(res, 200, {
      text: sanitizeGeneratedText(vertexResponse.text),
      model,
      location,
      finishReason: "STOP"
    });
  } catch (error) {
    const statusCode = controller.signal.aborted ? 504 : (error.statusCode || 500);
    return sendJSON(res, statusCode, {
      error: "request_failed",
      // Never reflect upstream bodies, authorization headers or prompt contents.
      message: statusCode === 504 ? "request timed out" : "request could not be completed"
    });
  } finally {
    if (admitted) activeRequests -= 1;
    clearTimeout(deadline);
    req.removeListener("aborted", disconnect);
    res.removeListener("close", disconnect);
  }
});
server.requestTimeout = requestDeadlineMs + 1000;
server.headersTimeout = requestDeadlineMs + 1000;
return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  createProxyServer().listen(PORT, () => {
    console.log(`resai-vertex-proxy listening on ${PORT}`);
  });
}

function stringField(value) {
  if (typeof value !== "string") {
    return "";
  }
  return value.trim();
}

function sendJSON(res, statusCode, payload) {
  if (res.destroyed || res.writableEnded) return;
  if (statusCode === 413 || statusCode === 504) {
    res.setHeader("Connection", "close");
    const socket = res.socket;
    res.once("finish", () => socket?.destroy());
  }
  const body = JSON.stringify(payload);
  res.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff"
  });
  res.end(body);
}

function readJSON(req, signal) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    let tooLarge = false;
    const abort = () => reject(Object.assign(new Error("timeout"), { statusCode: 504 }));
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) return abort();

    req.on("data", (chunk) => {
      if (tooLarge) return;
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        tooLarge = true;
        const error = new Error("request body too large");
        error.statusCode = 413;
        reject(error);
        return;
      }
      chunks.push(chunk);
    });

    req.on("end", () => {
      signal.removeEventListener("abort", abort);
      if (tooLarge) return;
      try {
        const text = Buffer.concat(chunks).toString("utf8");
        resolve(text ? JSON.parse(text) : {});
      } catch {
        const error = new Error("invalid JSON");
        error.statusCode = 400;
        reject(error);
      }
    });

    req.on("error", reject);
  });
}

async function accessTokenForVertex(env, fetchImpl, signal) {
  if (env.VERTEX_AI_ACCESS_TOKEN) {
    return env.VERTEX_AI_ACCESS_TOKEN;
  }

  const response = await fetchImpl(
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token",
    {
      signal,
      headers: {
        "Metadata-Flavor": "Google"
      }
    }
  );

  if (!response.ok) {
    throw new Error(`metadata token request failed: HTTP ${response.status}`);
  }

  const payload = await response.json();
  if (!payload.access_token) {
    throw new Error("metadata token response did not include access_token");
  }
  return payload.access_token;
}

async function callVertexAI({
  projectID,
  location,
  model,
  accessToken,
  systemInstruction,
  userPrompt,
  fetchImpl,
  signal
}) {
  const encodedModel = encodeURIComponent(model);
  const url = `https://aiplatform.googleapis.com/v1/projects/${projectID}/locations/${location}/publishers/google/models/${encodedModel}:generateContent`;
  const response = await fetchImpl(url, {
      method: "POST",
      signal,
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        systemInstruction: {
          parts: [{ text: systemInstruction }]
        },
        contents: [
          {
            role: "user",
            parts: [{ text: userPrompt }]
          }
        ],
        generationConfig: {
          temperature: 0.25,
          maxOutputTokens: 4096
        }
      })
    });

  const payloadText = await response.text();
  if (!response.ok) {
    const error = new Error(`Vertex AI failed: HTTP ${response.status}`);
    error.statusCode = 502;
    throw error;
  }

  const payload = JSON.parse(payloadText);
  const candidate = payload?.candidates?.[0];
  if (candidate?.finishReason !== "STOP") {
    throw Object.assign(new Error("incomplete model response"), { statusCode: 502 });
  }
  const text = candidate?.content?.parts
    ?.filter((part) => part.thought !== true)
    .map((part) => typeof part.text === "string" ? part.text : "")
    .join("\n")
    .trim();

  if (!text) {
    throw new Error("Vertex AI returned no text");
  }

  return { text: sanitizeGeneratedText(text) };
}

function sanitizeGeneratedText(rawText) {
  let text = String(rawText || "")
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .trim();

  const fenceMatch = text.match(/^```[^\n]*\n([\s\S]*?)\n```$/);
  if (fenceMatch) {
    text = fenceMatch[1].trim();
  }

  text = text.replace(/^(返信文|返信|送信文|出力|回答|Reply|Response)\s*[:：]\s*/i, "");
  text = text.replace(/^[-*]\s+/, "").replace(/^・\s*/, "");
  text = text.replace(/^\d+\.\s+/, "");

  const quotePairs = [
    ["\"", "\""],
    ["'", "'"],
    ["“", "”"],
    ["「", "」"],
    ["『", "』"]
  ];
  for (const [open, close] of quotePairs) {
    if (text.startsWith(open) && text.endsWith(close) && text.length >= 2) {
      text = text.slice(open.length, text.length - close.length);
      break;
    }
  }

  return text.trim();
}
