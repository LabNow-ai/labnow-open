/** 在固定OpenClaw镜像内选择真实SDK运行；普通开发容器明确跳过。 */
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import test from "node:test";
import { createWorkspaceFetch, workspaceGuardedFetchOptions, SENTINEL } from "../../src/labnow-open-etc/adapters/workspace_transport.mjs";

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


test("原生guard显式通道保留DNS钉扎且只发送一次规范请求",native,async()=>{
 const previous=process.env.LABNOW_RUN_MANAGED;process.env.LABNOW_RUN_MANAGED="1";
 try {
  const root=new URL(".",pathToFileURL(packageFile));const {i:guard}=await import(new URL("dist/fetch-guard-BulPh3pN.mjs",root));
  const target="https://8.8.8.8/console/api/token/runtime/v1";let calls=0;
  const send=async(input,init)=>{calls++;assert.ok(init.dispatcher);assert.equal(input,target+"/chat/completions/");assert.equal(init.headers.get("authorization"),"Bearer fixture-current");return new Response("fixture");};
  const opts={url:target+"/chat/completions",init:{method:"POST",headers:{authorization:"Bearer "+SENTINEL},body:"{}"},capture:false};
  const result=await guard(workspaceGuardedFetchOptions(opts,send,{read(){return{token:"fixture-current",baseUrl:target};}}));
  assert.equal(await result.response.text(),"fixture");await result.release();assert.equal(calls,1);
 } finally {if(previous===undefined)delete process.env.LABNOW_RUN_MANAGED;else process.env.LABNOW_RUN_MANAGED=previous;}
});
test("原生guard的跨来源redirect在第一次响应后停止",native,async()=>{
 const previous=process.env.LABNOW_RUN_MANAGED;process.env.LABNOW_RUN_MANAGED="1";
 try {
  const root=new URL(".",pathToFileURL(packageFile));const {i:guard}=await import(new URL("dist/fetch-guard-BulPh3pN.mjs",root));
  const target="https://8.8.8.8/console/api/token/runtime/v1";let calls=0;
  const send=async()=>{calls++;return new Response(null,{status:308,headers:{location:"https://foreign.invalid/collect"}});};
  await assert.rejects(guard(workspaceGuardedFetchOptions({url:target+"/models",init:{headers:{authorization:"Bearer "+SENTINEL}},capture:false},send,{read(){return{token:"fixture-current",baseUrl:target};}})));
  assert.equal(calls,1);
 } finally {if(previous===undefined)delete process.env.LABNOW_RUN_MANAGED;else process.env.LABNOW_RUN_MANAGED=previous;}
});


test("原生插件加载器使用公开SDK加载固定Lark入口", native, async () => {
  const { mkdtempSync, writeFileSync, rmSync } = await import("node:fs");
  const { spawnSync } = await import("node:child_process");
  const require = createRequire("/opt/openclaw/plugins/openclaw-lark/package.json");
  assert.equal(typeof require("openclaw/plugin-sdk/core").emptyPluginConfigSchema, "function");
  const pipeline = require("openclaw/plugin-sdk/channel-reply-pipeline");
  assert.equal(typeof pipeline.createReplyPrefixContext, "function");
  assert.equal(typeof pipeline.createTypingCallbacks, "function");
  // 必须执行真实CommonJS模块；plugins list的loaded登记不足以证明模块可执行。
  const loaded = require("/opt/openclaw/plugins/openclaw-lark/index.js");
  assert.equal(typeof (loaded.default ?? loaded).register, "function");
  const version = require("/opt/openclaw/plugins/openclaw-lark/src/core/version.js");
  assert.equal(version.getPluginVersion(), "2026.7.16");
  assert.equal(version.getPlatform(), "linux");
  require("/opt/openclaw/plugins/openclaw-lark/src/core/token-store.js");
  const home = mkdtempSync("/run/native-plugin-");
  const config = home + "/openclaw.json";
  writeFileSync(config, JSON.stringify({ gateway: { mode: "local" }, plugins: { enabled: true, allow: ["openclaw-lark"], load: { paths: ["/opt/openclaw/plugins/openclaw-lark"] }, entries: { "openclaw-lark": { enabled: true } } } }));
  try {
    const env = { ...process.env, HOME: home, OPENCLAW_STATE_DIR: home, OPENCLAW_CONFIG_PATH: config };
    delete env.LABNOW_RUN_MANAGED;
    const result = spawnSync("openclaw", ["plugins", "list", "--json"], { env, encoding: "utf8", timeout: 60000 });
    assert.equal(result.status, 0, result.stderr);
    const value = JSON.parse(result.stdout.slice(result.stdout.indexOf("{")));
    const plugin = value.plugins.find(value => value.id === "openclaw-lark");
    assert.ok(plugin, "原生加载器必须实际列出目标插件");
    assert.equal(plugin.status, "loaded", plugin.error);
  } finally { rmSync(home, { recursive: true, force: true }); }
});
