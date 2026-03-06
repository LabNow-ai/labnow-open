import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

function normalizeBaseUrl(prefix) {
  if (!prefix || prefix === "/") {
    return "/";
  }
  const trimmed = prefix.replace(/^\/+|\/+$/g, "");
  return `/${trimmed}/`;
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "");
  const base = normalizeBaseUrl(env.URL_PREFIX || env.VITE_URL_PREFIX || "/");

  return {
    base,
    plugins: [react()],
    server: {
      proxy: {
        "/api": {
          target: "http://localhost:80",
          changeOrigin: true,
          rewrite: (path) => path.replace(/^\/api/, ""),
        },
      },
    },
  };
});
