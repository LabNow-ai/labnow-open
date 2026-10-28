/** 本地适配单测；真实原生鉴权、快照及浏览器合同另行验收。 */
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { createPolicyReader, GuardFailure, isReadOnlyDirectoryMount, wrapSecretsHandlers } from "../../src/labnow-open-etc/adapters/openclaw_web_guard.mjs";

const KEY = "LABNOW_RUN_API_KEY", VALUE = "fixture-platform-value-before", NEXT = "fixture-platform-value-after";
const OWN = "fixture-self-owned-value", TARGET = "models.providers.managed.apiKey";
const coerceRef = v => v && ["env", "file", "exec"].includes(v.source) && typeof v.id === "string" && typeof v.provider === "string" ? v : null;
function fixture(t) {
  assert.equal(process.getuid(), 0, "应在开发容器内验证真实root文件所有权");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "openclaw-guard-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const policyFile = path.join(dir, "policy.json"), credentialsFile = path.join(dir, "runtime.json"), ownFile = path.join(dir, "own.json");
  function write(file, value) { fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 }); }
  write(policyFile, { version: 1, protected_env: [KEY] }); write(credentialsFile, { [KEY]: VALUE }); write(ownFile, { apiKey: OWN });
  const source = createPolicyReader({ policyFile, credentialsFile, required: () => false, verifyDirectory: () => true });
  const state = {
    sourceConfig: { secrets: { providers: { platform: { source: "file", path: credentialsFile }, own: { source: "file", path: ownFile } } }, models: { providers: {
      managed: { apiKey: { source: "file", provider: "platform", id: "/" + KEY } },
      own: { apiKey: { source: "file", provider: "own", id: "/apiKey" } },
    } } },
    config: { models: { providers: { managed: { apiKey: VALUE }, own: { apiKey: OWN } } } }, authStores: [],
  };
  const resolve = payload => async input => input.respond(true, payload);
  async function invoke(payload, original = resolve(payload)) {
    const replies = [];
    const handlers = wrapSecretsHandlers({ "secrets.resolve": original }, { source, snapshot: () => state, coerceRef });
    await handlers["secrets.resolve"]({ params: {}, respond: (...args) => replies.push(args) });
    assert.equal(replies.length, 1);
    return replies[0];
  }
  return { dir, policyFile, credentialsFile, ownFile, source, state, write, invoke };
}
const assignments = (name, value) => ({ assignments: [{ path: name, value }], diagnostics: [], inactiveRefPaths: [] });
const unavailable = result => { assert.equal(result[0], false); assert.equal(result[2].code, "UNAVAILABLE"); assert.equal(result[1], undefined); };

test("受管FileProvider回读拒绝，自持Key按原响应保留", async t => {
  const f = fixture(t);
  const denied = await f.invoke(assignments(TARGET, VALUE));
  assert.equal(denied[0], false); assert.equal(denied[2].code, "INVALID_REQUEST");
  const own = assignments("models.providers.own.apiKey", OWN);
  assert.deepEqual(await f.invoke(own), [true, own, undefined]);
});
test("非托管普通Lab保持原生响应和其他handler对象", async t => {
  const f = fixture(t); fs.unlinkSync(f.policyFile); fs.unlinkSync(f.credentialsFile);
  const original = async input => input.respond(false, undefined, { code: "ORIGINAL", message: "original" });
  const reload = () => "native-reload", handlers = wrapSecretsHandlers({ "secrets.resolve": original, "secrets.reload": reload }, { source: f.source });
  assert.equal(handlers["secrets.reload"], reload);
  let response; await handlers["secrets.resolve"]({ respond: (...v) => { response = v; } });
  assert.deepEqual(response, [false, undefined, { code: "ORIGINAL", message: "original" }]);
});
test("显式受管路径在原生解析前拒绝，不能因原生降级变成空成功", async t => {
  const f = fixture(t); let calls = 0, result;
  const handlers = wrapSecretsHandlers({ "secrets.resolve": async () => { calls++; } }, { source: f.source, snapshot: () => f.state, coerceRef });
  await handlers["secrets.resolve"]({ params: { allowedPaths: [TARGET] }, respond: (...v) => { result = v; } });
  assert.equal(calls, 0); assert.equal(result[0], false); assert.equal(result[2].code, "INVALID_REQUEST");
});
test("源已轮换但原生缓存仍为旧值时按引用路径拒绝", async t => {
  const f = fixture(t); f.write(f.credentialsFile, { [KEY]: NEXT });
  assert.equal((await f.invoke(assignments(TARGET, VALUE)))[2].code, "INVALID_REQUEST");
});
test("文件别名及JSON局部指针仍识别为受管来源", async t => {
  const f = fixture(t), alias = path.join(f.dir, "alias.json"); fs.symlinkSync(f.credentialsFile, alias);
  f.state.sourceConfig.secrets.providers.platform.path = alias;
  f.state.sourceConfig.models.providers.managed.apiKey.id = "/LABNOW_RUN_API_KEY/partial";
  assert.equal((await f.invoke(assignments(TARGET, "partial-value")))[2].code, "INVALID_REQUEST");
});
test("被删除的来源别名不能降级为自持Key", async t => {
  const f = fixture(t); f.state.sourceConfig.secrets.providers.platform.path = path.join(f.dir, "missing.json");
  unavailable(await f.invoke(assignments(TARGET, VALUE)));
});
test("受管env引用也拒绝管理回读", async t => {
  const f = fixture(t); f.state.sourceConfig.models.providers.managed.apiKey = { source: "env", provider: "default", id: KEY };
  assert.equal((await f.invoke(assignments(TARGET, VALUE)))[2].code, "INVALID_REQUEST");
});
test("受管来源缺名单不能启动；双缺失且可信启动要求保护也不能启动", t => {
  const f = fixture(t); fs.unlinkSync(f.policyFile);
  assert.throws(() => f.source.read(), GuardFailure); fs.unlinkSync(f.credentialsFile);
  assert.throws(() => createPolicyReader({ policyFile: f.policyFile, credentialsFile: f.credentialsFile, required: () => true }).read(), GuardFailure);
});
test("策略启用后任一文件丢失保持失败关闭", t => {
  const f = fixture(t); f.source.read(); fs.unlinkSync(f.policyFile); fs.unlinkSync(f.credentialsFile);
  assert.throws(() => f.source.read(), GuardFailure);
});
test("无效策略曾出现后移除不能转普通模式", t => {
  const f = fixture(t); f.write(f.policyFile, {}); assert.throws(() => f.source.read(), GuardFailure);
  fs.unlinkSync(f.policyFile); fs.unlinkSync(f.credentialsFile); assert.throws(() => f.source.read(), GuardFailure);
});
test("策略及来源的非root、组写和符号链接拒绝", t => {
  const f = fixture(t);
  for (const file of [f.policyFile, f.credentialsFile, f.dir]) {
    const mode = fs.statSync(file).mode & 0o777; fs.chmodSync(file, mode | 0o020);
    assert.throws(() => f.source.read(), GuardFailure); fs.chmodSync(file, mode);
    fs.chownSync(file, 12345, 0); assert.throws(() => f.source.read(), GuardFailure); fs.chownSync(file, 0, 0);
  }
  const other = path.join(f.dir, "other.json"); fs.renameSync(f.credentialsFile, other); fs.symlinkSync(other, f.credentialsFile);
  assert.throws(() => f.source.read(), GuardFailure);
});
test("策略直接父目录符号链接拒绝", t => {
  const f = fixture(t), alias = f.dir + "-alias"; fs.symlinkSync(f.dir, alias); t.after(() => fs.unlinkSync(alias));
  const reader = createPolicyReader({ policyFile: path.join(alias, "policy.json"), credentialsFile: f.credentialsFile });
  assert.throws(() => reader.read(), GuardFailure);
});
test("身份来源必须是仅本人可读的只读目录挂载", t => {
  const f = fixture(t);
  const writable = createPolicyReader({ policyFile: f.policyFile, credentialsFile: f.credentialsFile, verifyDirectory: () => false });
  assert.throws(() => writable.read(), GuardFailure);
  fs.chmodSync(f.credentialsFile, 0o644); assert.throws(() => f.source.read(), GuardFailure);
});
test("内核mount检查不把普通可写临时目录当成只读挂载", t => {
  const f = fixture(t), fd = fs.openSync(f.credentialsFile, "r");
  try { assert.equal(isReadOnlyDirectoryMount(fd, f.dir), false); } finally { fs.closeSync(fd); }
});
test("未知字段、重复名称、错误版本和超限名单拒绝", t => {
  const f = fixture(t);
  for (const policy of [
    { version: true, protected_env: [KEY] }, { version: 1, protected_env: [] }, { version: 1, protected_env: [KEY, KEY] },
    { version: 1, protected_env: ["OPENAI_API_KEY"] }, { version: 1, protected_env: [KEY], disabled: true },
    { version: 1, protected_env: Array.from({ length: 9 }, (_, i) => "LABNOW_RUN_" + i) },
  ]) { f.write(f.policyFile, policy); assert.throws(() => f.source.read(), GuardFailure); }
});
test("受管名称变更必须重新可信装配，不能在请求中改名单", t => {
  const f = fixture(t); f.source.read(); f.write(f.policyFile, { version: 1, protected_env: ["LABNOW_RUN_OTHER"] });
  assert.throws(() => f.source.read(), GuardFailure);
});
test("空值、引用、来源多键及超限文件拒绝", t => {
  const f = fixture(t);
  for (const value of ["", "short", "${LABNOW_RUN_API_KEY}", "x".repeat(4097), "fixture value with spaces"]) {
    f.write(f.credentialsFile, { [KEY]: value }); assert.throws(() => f.source.read(), GuardFailure);
  }
  f.write(f.credentialsFile, { [KEY]: VALUE, extra: OWN }); assert.throws(() => f.source.read(), GuardFailure);
  fs.writeFileSync(f.credentialsFile, "x".repeat(65537)); assert.throws(() => f.source.read(), GuardFailure);
});
test("请求期间发生轮换或策略消失，成功响应也不得发出", async t => {
  const f = fixture(t);
  for (const mutation of [() => f.write(f.credentialsFile, { [KEY]: NEXT }), () => fs.unlinkSync(f.policyFile)]) {
    f.write(f.policyFile, { version: 1, protected_env: [KEY] }); f.write(f.credentialsFile, { [KEY]: VALUE });
    unavailable(await f.invoke(null, async input => { mutation(); input.respond(true, assignments("models.providers.own.apiKey", OWN)); }));
  }
});
test("原生错误及diagnostics包含当前或旧缓存值时输出固定错误", async t => {
  const f = fixture(t); f.write(f.credentialsFile, { [KEY]: NEXT });
  unavailable(await f.invoke(null, async input => input.respond(false, undefined, { message: "bad " + VALUE })));
  unavailable(await f.invoke({ ...assignments("models.providers.own.apiKey", OWN), diagnostics: [NEXT] }));
});
test("缺失原生快照、异常原生函数与畸形响应失败关闭", async t => {
  const f = fixture(t), previous = f.state.sourceConfig; delete f.state.sourceConfig;
  unavailable(await f.invoke(assignments(TARGET, VALUE))); f.state.sourceConfig = previous;
  unavailable(await f.invoke(null, async () => { throw new Error(VALUE); }));
  unavailable(await f.invoke({ assignments: "invalid" }));
});
test("无法映射的受管authStore引用保守拒绝", async t => {
  const f = fixture(t); f.state.authStores.push({ store: { key: { source: "env", provider: "default", id: KEY } } });
  unavailable(await f.invoke(assignments("models.providers.own.apiKey", OWN)));
});
test("重复原生回调只向调用者答复一次", async t => {
  const f = fixture(t), own = assignments("models.providers.own.apiKey", OWN);
  assert.deepEqual(await f.invoke(null, async input => { input.respond(true, own); input.respond(true, assignments(TARGET, VALUE)); }), [true, own, undefined]);
});
