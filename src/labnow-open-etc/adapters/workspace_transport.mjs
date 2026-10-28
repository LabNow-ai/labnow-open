/** Open自有发送适配；原生SDK持有静态标记，发送前读取系统短期身份。 */
import fs from "node:fs";
import path from "node:path";
import { createPolicyReader, isReadOnlyDirectoryMount } from "./openclaw_web_guard.mjs";

export const SENTINEL = "labnow-runtime";
const HEADER = Buffer.from(JSON.stringify({ alg: "HS256", typ: "labnow-run+jwt", v: 1 })).toString("base64url") + ".";
const MODEL = "labnow-managed";
const DESCRIPTOR = "/etc/labnow/workspace-model.json";
const fail = () => { throw new Error("平台模型运行身份或固定传输入口不可用。"); };

function descriptor(file) {
  const parent = fs.lstatSync(path.dirname(file));
  if (!parent.isDirectory() || parent.isSymbolicLink() || parent.uid !== 0 || (parent.mode & 0o022)) fail();
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const before = fs.fstatSync(fd);
    if (!before.isFile() || before.uid !== 0 || before.mode & 0o022 || before.size > 16384 || !isReadOnlyDirectoryMount(fd, path.dirname(file))) fail();
    const encoded = fs.readFileSync(fd);
    const after = fs.fstatSync(fd);
    if (["ino", "size", "mtimeMs", "ctimeMs"].some(key => before[key] !== after[key])) fail();
    return { value: JSON.parse(encoded.toString("utf8")), encoded };
  } finally { fs.closeSync(fd); }
}

export function createWorkspaceSource({ policy = createPolicyReader(), readDescriptor = () => descriptor(DESCRIPTOR), now = () => Math.floor(Date.now() / 1000) } = {}) {
  return Object.freeze({ read() {
    const before = policy.read(true), metadata = readDescriptor(), value = metadata.value;
    if (!before || before.names.join() !== "LABNOW_RUN_TOKEN" || before.values.length !== 1 ||
      !value || Array.isArray(value) || Object.keys(value).sort().join() !== "adapter_id,base_url,expires_at,model,version" ||
      value.version !== 1 || value.adapter_id !== "openclaw" || value.model !== MODEL || !Number.isSafeInteger(value.expires_at)) fail();
    const token = before.values[0];
    if (!token.startsWith(HEADER) || token.length > 4096 || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{43}$/.test(token)) fail();
    const claims = JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8")), time = now();
    if (claims.aud !== "labnow-console-workspace-model-v1" || claims.adapter !== "openclaw" ||
      !Number.isSafeInteger(claims.iat) || !Number.isSafeInteger(claims.exp) || claims.iat > time ||
      claims.exp <= time || claims.exp > time + 300 || claims.exp - claims.iat < 1 || claims.exp - claims.iat > 300 || claims.exp !== value.expires_at) fail();
    const base = new URL(value.base_url);
    if (base.protocol !== "https:" || base.username || base.password || base.search || base.hash || base.pathname.replace(/\/$/, "") !== "/console/api/token/runtime/v1") fail();
    if (before.digest !== policy.read(true)?.digest || !metadata.encoded.equals(readDescriptor().encoded)) fail();
    return Object.freeze({ token, baseUrl: base.toString().replace(/\/$/, ""), model: MODEL, expiresAt: claims.exp });
  } });
}

function failure(status = 503) {
  return new Response(JSON.stringify({ error: { message: "平台模型身份或传输未完成。", type: "request_error", code: "workspace_transport_unavailable" } }), {
    status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "x-should-retry": "false" },
  });
}

export function createWorkspaceFetch({ send = globalThis.fetch, source = createWorkspaceSource() } = {}) {
  return async (input, init) => {
    let request;
    const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined));
    const authorization = headers.get("authorization"), credential = authorization?.replace(/^Bearer /i, "");
    if (credential !== SENTINEL && !credential?.startsWith(HEADER)) return send(input, init);
    try {
      if ((headers.get("x-stainless-retry-count") ?? "0") !== "0") return failure(409);
      for (const [key, value] of headers) if (key !== "authorization" && value.includes(HEADER)) return failure();
      const current = source.read(), base = new URL(current.baseUrl);
      request = new Request(input, init);
      const target = new URL(request.url), route = target.pathname.replace(/\/$/, ""), prefix = base.pathname.replace(/\/$/, "");
      if (target.origin !== base.origin || target.username || target.password || target.search || target.hash ||
        !((request.method === "POST" && route === prefix + "/chat/completions") || (request.method === "GET" && route === prefix + "/models"))) return failure(403);
      target.pathname = route + "/";
      const forwarded = new Request(target, request);
      forwarded.headers.set("authorization", "Bearer " + current.token);
      // 禁止原生fetch自动跟随任何重定向；网络故障也不触发SDK模型重放。
      return await send(forwarded, { redirect: "error" });
    } catch {
      return failure();
    }
  };
}

if (process.env.LABNOW_RUN_MANAGED === "1") {
  globalThis.fetch = createWorkspaceFetch();
}
