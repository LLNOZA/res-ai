import test from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import net from "node:net";
import { createProxyServer } from "./server.js";

const env = { RESAI_PROXY_SHARED_SECRET: "test-only", VERTEX_PROJECT_ID: "test", VERTEX_AI_ACCESS_TOKEN: "test-token" };
const body = JSON.stringify({ systemInstruction: "test instruction", userPrompt: "test prompt" });
const completed = (finishReason = "STOP") => new Response(JSON.stringify({ candidates: [{ finishReason, content: { parts: [{ text: "private reasoning", thought: true }, { text: "completed reply" }] } }] }));

async function fixture(t, options = {}) {
  const server = createProxyServer({ env, fetchImpl: async () => completed(), ...options });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => { server.closeAllConnections(); return new Promise(resolve => server.close(resolve)); });
  return (payload = body, key = "test-only") => fetch(`http://127.0.0.1:${server.address().port}/v1/rewrite`, {
    method: "POST", headers: { "Content-Type": "application/json", "X-ResAI-Proxy-Key": key }, body: payload
  });
}

test("missing server secret fails closed without calling upstream", async t => {
  let called = false;
  const send = await fixture(t, { env: { ...env, RESAI_PROXY_SHARED_SECRET: "" }, fetchImpl: async () => { called = true; return completed(); } });
  assert.equal((await send()).status, 503);
  assert.equal(called, false);
});

test("missing or incorrect client credentials rejected", async t => {
  const send = await fixture(t);
  for (const key of ["", "incorrect"]) assert.equal((await send(body, key)).status, 401);
});

test("null, arrays, malformed JSON and empty prompts rejected", async t => {
  const send = await fixture(t);
  for (const payload of ["null", "[]", "{", "{}", '{"systemInstruction":1,"userPrompt":"hi"}']) {
    assert.equal((await send(payload)).status, 400);
  }
});

test("oversized request returns 413", async t => {
  const send = await fixture(t);
  assert.equal((await send(JSON.stringify({ userPrompt: "x".repeat(130 * 1024) }))).status, 413);
});

test("oversized unfinished upload is answered and disconnected", async t => {
  const server = createProxyServer({ env, fetchImpl: async () => completed() });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => { server.closeAllConnections(); return new Promise(resolve => server.close(resolve)); });
  const socket = net.connect(server.address().port, "127.0.0.1");
  socket.setTimeout(1000, () => socket.destroy(new Error("did not disconnect oversized request")));
  let response = "";
  socket.on("data", chunk => { response += chunk.toString(); });
  await once(socket, "connect");
  socket.write("POST /v1/rewrite HTTP/1.1\r\nHost: localhost\r\nX-ResAI-Proxy-Key: test-only\r\nContent-Length: 9999999\r\n\r\n");
  socket.write("x".repeat(130 * 1024));
  await once(socket, "close");
  assert.match(response, /413/);
});

test("HTTP receive deadlines follow the configured operation budget", () => {
  const server = createProxyServer({ env, timeoutMs: 30000 });
  assert.equal(server.requestTimeout, 31000);
  assert.equal(server.headersTimeout, 31000);
});

test("completed response filters thought parts", async t => {
  const send = await fixture(t);
  const result = await send();
  assert.equal(result.status, 200);
  const payload = await result.json();
  assert.equal(payload.text, "completed reply");
  assert.equal(payload.finishReason, "STOP");
});

test("partial or blocked output is never accepted", async t => {
  for (const reason of ["MAX_TOKENS", "SAFETY", "RECITATION", "UNKNOWN"]) {
    const send = await fixture(t, { fetchImpl: async () => completed(reason) });
    assert.equal((await send()).status, 502);
  }
});

test("upstream error bodies and exception messages are not reflected", async t => {
  const send = await fixture(t, { fetchImpl: async () => new Response("SECRET user prompt", { status: 403 }) });
  const response = await send();
  assert.equal(response.status, 502);
  assert.doesNotMatch(await response.text(), /SECRET|user prompt/);
});

function abortable(signal) {
  return new Promise((_, reject) => {
    const abort = () => reject(new DOMException("aborted", "AbortError"));
    if (signal.aborted) abort();
    else signal.addEventListener("abort", abort, { once: true });
  });
}

test("metadata request is covered by the overall deadline", async t => {
  const send = await fixture(t, { env: { ...env, VERTEX_AI_ACCESS_TOKEN: "" }, timeoutMs: 30,
    fetchImpl: async (_, { signal }) => abortable(signal) });
  assert.equal((await send()).status, 504);
});

test("deadline remains active while reading upstream response body", async t => {
  const send = await fixture(t, { timeoutMs: 30, fetchImpl: async (_, { signal }) => ({ ok: true, text: () => abortable(signal) }) });
  assert.equal((await send()).status, 504);
});
