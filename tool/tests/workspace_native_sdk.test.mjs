/** 在固定OpenClaw镜像内选择真实SDK运行；普通开发容器明确跳过。 */
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import test from "node:test";
import { createWorkspaceFetch, SENTINEL } from "../../src/labnow-open-etc/adapters/workspace_transport.mjs";

const packageFile = process.env.NATIVE_OPENCLAW_PACKAGE_JSON;
const native = { skip: !packageFile && "需在固定原生OpenClaw镜像内提供其package.json路径" };
const baseURL = "https://console.invalid/console/api/token/runtime/v1";
async function fixture() {
  const require = createRequire(packageFile);
  const { default: OpenAI } = await import(pathToFileURL(require.resolve("openai")));
  let token = "fixture-first", reads = 0;
  const calls = [];
  const send = async (input, init) => {
    const request = new Request(input, init);
    calls.push(request);
    return new Response(JSON.stringify({ id: "fixture", object: "chat.completion", created: 1,
      model: "labnow-managed", choices: [{ index: 0, message: { role: "assistant", content: "fixture" }, finish_reason: "stop" }] }),
      { status: 200, headers: { "content-type": "application/json" } });
  };
  const source = { read() { reads++; return { token, baseUrl: baseURL }; } };
  const fetch = createWorkspaceFetch({ send, source });
  return { OpenAI, send, source, fetch, calls, rotate(value) { token = value; }, reads() { return reads; } };
}
const payload = { model: "labnow-managed", messages: [{ role: "user", content: "fixture" }], max_tokens: 16 };

test("原生SDK同一客户端发送前采用当前身份", native, async () => {
  const f = await fixture(); const client = new f.OpenAI({ apiKey: SENTINEL, baseURL, fetch: f.fetch, maxRetries: 7 });
  await client.chat.completions.create(payload);f.rotate("fixture-second");await client.chat.completions.create(payload);
  assert.equal(f.calls.length, 2);assert.notEqual(f.calls[0].headers.get("authorization"), f.calls[1].headers.get("authorization"));
  assert.ok(f.calls.every(request => request.url.endsWith("/chat/completions/") && request.headers.get("x-stainless-retry-count") === "0"));
});
test("原生SDK身份故障不重放模型请求", native, async () => {
  const f = await fixture();let reads = 0;
  const fetch = createWorkspaceFetch({ send: f.send, source: { read() { reads++;throw Error("fixture"); } } });
  const client = new f.OpenAI({ apiKey: SENTINEL, baseURL, fetch, maxRetries: 7 });
  await assert.rejects(client.chat.completions.create(payload));assert.equal(reads, 1);assert.equal(f.calls.length, 0);
});
test("原生SDK配置到其他目标时不发送运行身份", native, async () => {
  const f = await fixture();const client = new f.OpenAI({ apiKey: SENTINEL, baseURL: "https://foreign.invalid/v1", fetch: f.fetch, maxRetries: 7 });
  await assert.rejects(client.chat.completions.create(payload));assert.equal(f.calls.length, 0);
});
test("原生SDK自持Key和目标保留且不读取平台身份", native, async () => {
  const f = await fixture();const client = new f.OpenAI({ apiKey: "fixture-own", baseURL: "https://own.invalid/v1", fetch: f.fetch });
  await client.chat.completions.create({ ...payload, model: "own" });
  assert.equal(f.reads(), 0);assert.equal(f.calls[0].headers.get("authorization"), "Bearer fixture-own");
  assert.equal(f.calls[0].url, "https://own.invalid/v1/chat/completions");
});
