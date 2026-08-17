const PROGRAM_DEFINITIONS = {
  "caddy": { displayName: "Caddy Server", hidden: true },
  "jupyter": {
    displayName: "JupyterLab",
    link: "/lab/",
    logo: "logo-jupyter.svg",
    description: "Interactive notebooks for Python and data workflows. Great for exploration and quick experiments.",
  },
  "vscode": {
    displayName: "VS Code",
    link: "/vscode/",
    logo: "logo-vscode.svg",
    description: "A full-featured code editor in your browser. Edit files, run terminals, and manage projects.",
  },
  "rserver": {
    displayName: "R-Studio",
    link: "/rserver/",
    logo: "logo-rserver.svg",
    description: "RStudio Server for R development and analysis. Build scripts, run models, and visualize results.",
  },
  "rshiny": {
    displayName: "R Shiny",
    link: "/rshiny/",
    logo: "logo-rshiny.svg",
    description: "Run Shiny applications for interactive dashboards. Useful for sharing data apps with your team.",
  },
  "hermes_gateway": { displayName: "Hermes Gateway", hidden: true },
  "hermes_dashboard": {
    displayName: "Hermes",
    link: "/hermes/",
    logo: "logo-hermes.svg",
    description: "An agent workspace for managing sessions, skills, configurations, and plans.",
    programs: ["hermes_gateway", "hermes_dashboard"],
  },
  "openclaw": {
    displayName: "OpenClaw",
    link: "/openclaw/",
    logo: "logo-openclaw.svg",
    description: "OpenClaw AI Agent platform. Build and deploy intelligent agents with natural language.",
  },
};

export function resolveProgramNames(name) {
  const def = PROGRAM_DEFINITIONS[name];
  return def?.programs?.length ? def.programs : [name];
}

export default PROGRAM_DEFINITIONS;
