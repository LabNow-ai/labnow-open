function isExternalUrl(path) {
  return /^(https?:)?\/\//.test(path);
}

export function getRuntimeHomeBasePath() {
  const runtimeBase =
    (typeof window !== "undefined" && window.__LABNOW_URL_PREFIX__) ||
    import.meta.env.BASE_URL ||
    "./";

  if (typeof window === "undefined") {
    return runtimeBase.endsWith("/") ? runtimeBase : `${runtimeBase}/`;
  }

  const pathname = new URL(runtimeBase, window.location.href).pathname;
  return pathname.endsWith("/") ? pathname : `${pathname}/`;
}

export function getRuntimeApiBase() {
  const homeBase = getRuntimeHomeBasePath();
  return homeBase === "/" ? "/home" : homeBase.replace(/\/$/, "");
}

export function buildHomePath(path) {
  if (!path) {
    return "";
  }
  if (isExternalUrl(path)) {
    return path;
  }
  return `${getRuntimeHomeBasePath()}${String(path).replace(/^\/+/, "")}`;
}

export function buildWorkspacePath(path) {
  if (!path) {
    return "";
  }
  if (isExternalUrl(path)) {
    return path;
  }
  const prefix = getRuntimeHomeBasePath().replace(/\/home\/?$/, "/");
  return `${prefix}${String(path).replace(/^\/+/, "")}`;
}
