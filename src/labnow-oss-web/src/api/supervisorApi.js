function buildJsonHeaders(extraHeaders) {
  return {
    "Content-Type": "application/json",
    ...(extraHeaders || {}),
  };
}

async function request(url, options) {
  const resp = await fetch(url, options);
  const contentType = resp.headers.get("content-type") || "";
  let data = null;

  if (contentType.includes("application/json")) {
    data = await resp.json();
    return { ok: resp.ok, data, status: resp.status };
  }

  const text = await resp.text();
  if (text) {
    try {
      data = JSON.parse(text);
    } catch (_error) {
      data = text;
    }
  }

  return { ok: resp.ok, data, status: resp.status };
}

export async function resolveApiBase() {
  if (import.meta.env.DEV) {
    return "/api/home";
  }

  try {
    const resp = await fetch(window.location.href, { method: "HEAD" });
    const base = resp.headers.get("location-base");
    if (base) {
      return `${base}home`;
    }
  } catch (error) {
    console.error("Failed to resolve location-base header", error);
  }

  return "/home";
}

export function createSupervisorApi(apiBase) {
  return {
    listPrograms() {
      return request(`${apiBase}/program/list`);
    },
    startProgram(name) {
      return request(`${apiBase}/program/start/${encodeURIComponent(name)}`, {
        method: "POST",
      });
    },
    stopProgram(name) {
      return request(`${apiBase}/program/stop/${encodeURIComponent(name)}`, {
        method: "POST",
      });
    },
    startPrograms(names) {
      return request(`${apiBase}/program/startPrograms`, {
        method: "POST",
        headers: buildJsonHeaders(),
        body: JSON.stringify(names),
      });
    },
    stopPrograms(names) {
      return request(`${apiBase}/program/stopPrograms`, {
        method: "POST",
        headers: buildJsonHeaders(),
        body: JSON.stringify(names),
      });
    },
    reloadSupervisor() {
      return request(`${apiBase}/supervisor/reload`, { method: "POST" });
    },
    shutdownSupervisor() {
      return request(`${apiBase}/supervisor/shutdown`, { method: "PUT" });
    },
  };
}

export function isRunningState(stateName) {
  const value = String(stateName || "").toLowerCase();
  return value.includes("running") || value.includes("starting");
}
