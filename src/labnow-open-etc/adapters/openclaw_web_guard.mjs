/** Open 自有的管理接口保护；原生权限、Agent 秘密读取和刷新保持独立。 */
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createHash } from "node:crypto";

const POLICY = "/etc/labnow/openclaw-managed-identity.json";
const CREDENTIALS = "/etc/labnow/openclaw-runtime-identity.json";
const NAME = /^LABNOW_RUN_[A-Z0-9_]{1,64}$/;
const fail = () => { throw new GuardFailure(); };
function present(file) {
  try { fs.lstatSync(file); return true; }
  catch (error) { if (error.code === "ENOENT") return false; throw error; }
}
export class GuardFailure extends Error {
  constructor() { super("平台运行身份保护尚未就绪。"); }
}

/** 用已打开描述符的mount id核实只读目录bind，避免把文件属主误当控制权限。 */
export function isReadOnlyDirectoryMount(fd, directory) {
  const info = fs.readFileSync(`/proc/self/fdinfo/${fd}`, "utf8");
  const id = /^mnt_id:\s*(\d+)$/m.exec(info)?.[1];
  const row = fs.readFileSync("/proc/self/mountinfo", "utf8").split("\n").find(line => line.split(" ")[0] === id);
  if (!row) return false;
  const fields = row.split(" ");
  const mountpoint = fields[4].replace(/\\([0-7]{3})/g, (_, digits) => String.fromCharCode(parseInt(digits, 8)));
  return mountpoint === fs.realpathSync(directory) && fields[5].split(",").includes("ro");
}

function stableFile(file, limit, { uid = 0, verifyDirectory } = {}) {
  const parent = fs.lstatSync(path.dirname(file));
  if (!parent.isDirectory() || parent.isSymbolicLink() || parent.uid !== 0 || (parent.mode & 0o022)) fail();
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const before = fs.fstatSync(fd);
    if (!before.isFile() || before.uid !== uid || (before.mode & 0o022) || before.size > limit) fail();
    if (verifyDirectory && ((before.mode & 0o077) || !verifyDirectory(fd, path.dirname(file)))) fail();
    const buffer = Buffer.alloc(limit + 1);
    let size = 0, n;
    while ((n = fs.readSync(fd, buffer, size, buffer.length - size, null)) > 0) {
      size += n;
      if (size > limit) fail();
    }
    const after = fs.fstatSync(fd);
    if (["dev", "ino", "size", "mtimeMs", "ctimeMs"].some(k => before[k] !== after[k])) fail();
    return buffer.subarray(0, size);
  } finally { fs.closeSync(fd); }
}

/** 参数仅供受信任装配及测试使用；生产工厂使用固定路径，不接受浏览器配置。 */
export function createPolicyReader({ policyFile = POLICY, credentialsFile = CREDENTIALS, required = () => process.env.LABNOW_RUN_MANAGED === "1", verifyDirectory = isReadOnlyDirectoryMount } = {}) {
  let seen = false, initialNames;
  function read(force = false) {
    try {
      if (!present(policyFile)) {
        if (seen || force || required() || present(credentialsFile)) fail();
        return null;
      }
      seen = true;
      const policyBytes = stableFile(policyFile, 16 * 1024);
      const policy = JSON.parse(policyBytes.toString("utf8"));
      if (!policy || Array.isArray(policy) || Object.keys(policy).sort().join() !== "protected_env,version" || policy.version !== 1) fail();
      const names = policy.protected_env;
      if (!Array.isArray(names) || names.length < 1 || names.length > 8 || names.some(n => typeof n !== "string" || !NAME.test(n)) || new Set(names).size !== names.length) fail();
      const canonical = [...names].sort().join();
      if (initialNames !== undefined && canonical !== initialNames) fail();
      initialNames = canonical;
      // 原生FileProvider要求有效UID所有、仅本人可读；控制权由root目录和只读挂载保证。
      const bytes = stableFile(credentialsFile, 64 * 1024, { uid: process.geteuid(), verifyDirectory });
      const values = JSON.parse(bytes.toString("utf8"));
      if (!values || Array.isArray(values) || Object.keys(values).sort().join() !== canonical) fail();
      for (const name of names) {
        if (typeof values[name] !== "string" || !/^[\x21-\x7e]{16,4096}$/.test(values[name]) || values[name].includes("${")) fail();
      }
      return Object.freeze({
        names: Object.freeze([...names]), values: Object.freeze(Object.values(values)),
        file: fs.realpathSync(credentialsFile),
        digest: createHash("sha256").update(policyBytes).update(bytes).digest("hex"),
      });
    } catch { throw new GuardFailure(); }
  }
  return Object.freeze({ read, credentialsFile: path.resolve(credentialsFile) });
}

const record = v => v !== null && typeof v === "object" && !Array.isArray(v);
function providerPath(value) {
  if (typeof value !== "string" || !value || value.includes("\0") || value.includes("${")) return null;
  const expanded = value === "~" ? os.homedir() : value.startsWith("~/") ? path.join(os.homedir(), value.slice(2)) : value;
  try { return fs.realpathSync(expanded); } catch { return null; }
}
function at(root, parts) {
  let value = root;
  for (const key of parts) {
    if (!value || typeof value !== "object" || !Object.hasOwn(value, key)) return undefined;
    value = value[key];
  }
  return value;
}

/** 使用原生未解析配置和原生coerce函数分类，避免仅按当前值过滤漏掉旧快照。 */
function references(snapshot, coerceRef, protectedFile, names) {
  if (!record(snapshot?.sourceConfig) || typeof coerceRef !== "function") fail();
  const config = snapshot.sourceConfig, defaults = config.secrets?.defaults;
  const providers = config.secrets?.providers ?? {};
  const resolvedProviders = snapshot.config?.secrets?.providers ?? {};
  const protectedPaths = new Set(), unknownPaths = new Set(), sensitive = [];
  let count = 0, unmappedProtected = false;
  function visit(value, parts, resolved, authStore = false, depth = 0) {
    if (++count > 20000 || depth > 32) fail();
    const ref = coerceRef(value, defaults);
    if (ref) {
      const key = parts.join(".");
      let managed = ref.source === "env" && names.includes(ref.id), unknown = false;
      if (ref.source === "file") {
        const candidate = resolvedProviders[ref.provider]?.path ?? providers[ref.provider]?.path;
        const file = providerPath(candidate);
        managed = file === protectedFile;
        unknown = file === null;
      }
      if (managed) {
        if (authStore) unmappedProtected = true;
        else protectedPaths.add(key);
        const raw = at(resolved, parts);
        if (typeof raw === "string" && raw.length >= 16) sensitive.push(raw);
      } else if (unknown) unknownPaths.add(key);
      return;
    }
    if (Array.isArray(value)) value.forEach((x, i) => visit(x, [...parts, i], resolved, authStore, depth + 1));
    else if (record(value)) for (const key of Object.keys(value)) visit(value[key], [...parts, key], resolved, authStore, depth + 1);
  }
  visit(config, [], snapshot.config);
  if (!Array.isArray(snapshot.authStores)) fail();
  for (const entry of snapshot.authStores) visit(entry.store, [], entry.store, true);
  return { protectedPaths, unknownPaths, sensitive, unmappedProtected };
}

function containsSensitive(payload, values) {
  const encoded = JSON.stringify(payload);
  if (encoded !== undefined && Buffer.byteLength(encoded) > 8 * 1024 * 1024) fail();
  let nodes = 0;
  function visit(value, depth = 0) {
    if (++nodes > 50000 || depth > 40) fail();
    if (typeof value === "string") return values.some(v => value.includes(v));
    if (Array.isArray(value)) return value.some(v => visit(v, depth + 1));
    if (record(value)) return Object.entries(value).some(([key, v]) => values.some(s => key.includes(s)) || visit(v, depth + 1));
    return false;
  }
  return visit(payload);
}

export function wrapSecretsHandlers(handlers, { snapshot, coerceRef, source = createPolicyReader() }) {
  source.read(); // 已有平台源但缺策略时，启动即拒绝；普通未绑定应用保持可用。
  const original = handlers["secrets.resolve"];
  if (typeof original !== "function") fail();
  return {
    ...handlers,
    "secrets.resolve": async input => {
      let before, meta, answered = false;
      const reply = (code, message) => {
        if (answered) return;
        answered = true;
        return input.respond(false, undefined, { code, message });
      };
      try {
        before = source.read();
        if (before) {
          meta = references(snapshot(), coerceRef, before.file, before.names);
          // 即使原生来源暂时降级而返回空assignments，也不把受管读取报告为成功。
          const selected = [input.params?.allowedPaths, input.params?.forcedActivePaths, input.params?.optionalActivePaths];
          if (selected.some(paths => Array.isArray(paths) && paths.some(p => meta.protectedPaths.has(p)))) {
            return reply("INVALID_REQUEST", "平台运行身份不允许通过管理接口读取。");
          }
        }
        await original({ ...input, respond: (ok, payload, error) => {
          if (answered) return;
          try {
            const after = source.read();
            if (before?.digest !== after?.digest) fail();
            if (after) {
              const current = references(snapshot(), coerceRef, after.file, after.names);
              if (meta.unmappedProtected || current.unmappedProtected) fail();
              if (ok) {
                if (!record(payload) || !Array.isArray(payload.assignments)) fail();
                for (const assignment of payload.assignments) {
                  if (meta.protectedPaths.has(assignment.path) || current.protectedPaths.has(assignment.path)) {
                    return reply("INVALID_REQUEST", "平台运行身份不允许通过管理接口读取。");
                  }
                  if (meta.unknownPaths.has(assignment.path) || current.unknownPaths.has(assignment.path)) fail();
                }
              }
              if (containsSensitive(ok ? payload : error, [...after.values, ...meta.sensitive, ...current.sensitive])) fail();
            }
            answered = true;
            return input.respond(ok, payload, error);
          } catch { return reply("UNAVAILABLE", "平台运行身份保护暂不可用。"); }
        } });
      } catch { return reply("UNAVAILABLE", "平台运行身份保护暂不可用。"); }
    },
  };
}
