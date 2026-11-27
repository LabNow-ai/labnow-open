// @vitest-environment jsdom
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

const state = vi.hoisted(() => ({
  clients: [] as any[],
  delay: 0,
  fail: false,
}));
vi.mock("react-router", () => ({ useNavigate: () => vi.fn() }));
vi.mock("@/lib/api", () => ({
  api: {
    getModelInfo: vi.fn(async () => ({
      model: "labnow-managed",
      capabilities: {},
    })),
  },
}));
vi.mock("@/lib/gatewayClient", () => ({
  GatewayClient: class {
    state = "idle";
    handlers = new Set<(s: string) => void>();
    connects = 0;
    closes = 0;
    constructor() {
      state.clients.push(this);
    }
    emit(s: string) {
      this.state = s;
      for (const h of [...this.handlers]) h(s);
    }
    onState(h: (s: string) => void) {
      this.handlers.add(h);
      h(this.state);
      return () => this.handlers.delete(h);
    }
    on() {
      return () => {};
    }
    async connect() {
      this.connects++;
      this.emit("connecting");
      await Promise.resolve();
      if (state.delay) await new Promise((r) => setTimeout(r, state.delay));
      this.emit(state.fail ? "closed" : "open");
    }
    close() {
      this.closes++;
      this.emit("closed");
    }
    async request() {
      return { session_id: "fixture-sidecar" };
    }
  },
}));
vi.mock("@/lib/eventsFeedClient", () => ({
  EventsFeedClient: class {
    lastCloseCode = null;
    onState() {
      return () => {};
    }
    onClose() {
      return () => {};
    }
    on() {
      return () => {};
    }
    async connect() {}
    close() {}
  },
}));
vi.mock("@/components/ModelPickerDialog", () => ({
  ModelPickerDialog: () => null,
}));
vi.mock("@/components/ModelReloadConfirm", () => ({
  ModelReloadConfirm: () => null,
}));
vi.mock("@/components/ReasoningPicker", () => ({
  ReasoningPicker: () => null,
}));
vi.mock("@nous-research/ui/ui/components/button", () => ({
  Button: ({
    children,
    onClick,
  }: {
    children?: ReactNode;
    onClick?: () => void;
  }) => <button onClick={onClick}>{children}</button>,
}));
vi.mock("@nous-research/ui/ui/components/badge", () => ({
  Badge: ({ children }: { children?: ReactNode }) => <span>{children}</span>,
}));
vi.mock("@nous-research/ui/ui/components/card", () => ({
  Card: ({ children }: { children?: ReactNode }) => <div>{children}</div>,
}));
import { ChatSidebar } from "@/components/ChatSidebar";

let root: Root, host: HTMLDivElement;
async function render(channel = "fresh") {
  await act(async () =>
    root.render(<ChatSidebar channel={channel} profile="default" />),
  );
}
async function tick(ms: number) {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(ms);
  });
}
beforeEach(() => {
  vi.useFakeTimers();
  state.clients = [];
  state.delay = 0;
  state.fail = false;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
  vi.useRealTimers();
});

it("历史会话切换后成功连接不被旧closed快照触发的重试反复拆掉", async () => {
  await render();
  const c = state.clients[0];
  expect(c.connects).toBe(1);
  await render("history");
  for (let i = 0; i < 6; i++) await tick(1000);
  expect(c.connects).toBe(2);
  expect(host.textContent).toContain("live");
});
it("慢于首个退避窗口的历史连接仍只建立一次", async () => {
  await render();
  state.delay = 1000;
  await render("history");
  for (let i = 0; i < 8; i++) await tick(500);
  expect(state.clients[0].connects).toBe(2);
  expect(host.textContent).toContain("live");
});
it("真实断连仍会重连且成功后不继续重试", async () => {
  await render();
  const c = state.clients[0];
  await act(async () => c.emit("closed"));
  await tick(250);
  for (let i = 0; i < 4; i++) await tick(1000);
  expect(c.connects).toBe(2);
  expect(host.textContent).toContain("live");
});
it("等待重试期间恢复open须取消尚未执行的定时器", async () => {
  await render();
  const c = state.clients[0];
  await act(async () => c.emit("closed"));
  await tick(100);
  await act(async () => c.emit("open"));
  await tick(2000);
  expect(c.connects).toBe(1);
  expect(host.textContent).toContain("live");
});
it("持续失败仍遵守五次自动重试上限", async () => {
  state.fail = true;
  await render();
  for (let i = 0; i < 9; i++) await tick(4000);
  expect(state.clients[0].connects).toBe(6);
  expect(host.textContent).toContain("gave up after 5 attempts");
});
it("卸载清除待执行重试，不影响其他客户端", async () => {
  await render();
  const c = state.clients[0];
  await act(async () => c.emit("closed"));
  await act(async () => root.render(null));
  await tick(5000);
  expect(c.connects).toBe(1);
});
