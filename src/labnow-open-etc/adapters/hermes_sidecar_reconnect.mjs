/** 固定 Hermes 制品的侧栏重连适配，仅在构建时变换模块，不改上游源文件。 */
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const SOURCE_SHA256 =
  "6783f0958f2af30d3745b1e2a8f828de25917ba9a4f329dc2f946884eea77c2e";
const BEFORE = `    let redialTimer: ReturnType<typeof setTimeout> | null = null;
    const offRedial = gw.onState((s) => {
      if (s === "open") {
        sidecarRedialAttemptRef.current = 0;`;
const AFTER = `    let redialTimer: ReturnType<typeof setTimeout> | null = null;
    // onState synchronously replays the previous generation; only subsequent transitions can redial.
    let redialSubscribed = false;
    const offRedial = gw.onState((s) => {
      if (!redialSubscribed) return;
      if (s === "open") {
        if (redialTimer !== null) {
          clearTimeout(redialTimer);
          redialTimer = null;
        }
        sidecarRedialAttemptRef.current = 0;`;
const END = `    // Create the sidecar session so the gateway surfaces session-scoped`;

export function adaptSidecarReconnect(code) {
  if (createHash("sha256").update(code).digest("hex") !== SOURCE_SHA256)
    throw new Error("Hermes 侧栏源码版本不匹配，停止构建。");
  return code.replace(BEFORE, AFTER).replace(
    END,
    `    redialSubscribed = true;

` + END,
  );
}

export function sidecarReconnectPlugin() {
  return {
    name: "labnow-hermes-sidecar-reconnect",
    enforce: "pre",
    load(id) {
      if (id.endsWith("/web/src/components/ChatSidebar.tsx"))
        return {
          code: adaptSidecarReconnect(readFileSync(id, "utf8")),
          map: null,
        };
    },
  };
}
