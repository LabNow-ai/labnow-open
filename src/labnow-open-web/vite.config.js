import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

function normalizeBaseUrl(prefix) {
  if (!prefix) {
    return "./";
  }
  if (prefix === "." || prefix === "./") {
    return "./";
  }
  if (prefix === "/") {
    return "/";
  }
  const trimmed = prefix.replace(/^\/+|\/+$/g, "");
  return `/${trimmed}/`;
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "");
  const base = normalizeBaseUrl(env.URL_PREFIX || env.VITE_URL_PREFIX);

  return {
    base,
    plugins: [react()],
    build: {
      // Carbon emits @position-try rules that lightningcss 1.33.0 cannot parse.
      // Keep production CSS minification enabled with Vite's esbuild alternative.
      cssMinify: "esbuild",
    },
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
