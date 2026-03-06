import { useEffect, useMemo, useState } from "react";
import {
  Button,
  Content,
  Header,
  HeaderGlobalAction,
  HeaderGlobalBar,
  HeaderName,
  InlineLoading,
  InlineNotification,
  Link,
  Modal,
  Tag,
  Theme,
  Toggletip,
  ToggletipButton,
  ToggletipContent,
} from "@carbon/react";
import {
  DocumentExport,
  Home,
  Information,
  Launch,
  Light,
  LogoGithub,
  LogoX,
  Moon,
  PlayFilledAlt,
  Renew,
  Restart,
  StopFilledAlt,
} from "@carbon/icons-react";
import { useSupervisorController } from "./hooks/useSupervisorController";

const PROGRAM_DEFINITIONS = {
  caddy: { displayName: "Caddy Server", hidden: true },
  jupyter: {
    displayName: "JupyterLab",
    link: "/lab",
    logo: "logo-jupyter.svg",
    description:
      "Interactive notebooks for Python and data workflows. Great for exploration and quick experiments.",
  },
  vscode: {
    displayName: "VS Code",
    link: "/vscode",
    logo: "logo-vscode.svg",
    description:
      "A full-featured code editor in your browser. Edit files, run terminals, and manage projects.",
  },
  rserver: {
    displayName: "R-Studio",
    link: "/rserver",
    logo: "logo-rserver.svg",
    description:
      "RStudio Server for R development and analysis. Build scripts, run models, and visualize results.",
  },
  rshiny: {
    displayName: "R Shiny",
    link: "/rshiny",
    logo: "logo-rshiny.svg",
    description:
      "Run Shiny applications for interactive dashboards. Useful for sharing data apps with your team.",
  },
};

function normalizeBaseUrl(baseUrl) {
  if (!baseUrl) {
    return "/";
  }
  return baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;
}

function buildPrefixedPath(path) {
  if (!path) {
    return "";
  }
  if (/^(https?:)?\/\//.test(path)) {
    return path;
  }

  const runtimeBase =
    (typeof window !== "undefined" && window.__LABNOW_URL_PREFIX__) ||
    import.meta.env.BASE_URL;
  const normalizedBase = normalizeBaseUrl(runtimeBase);
  const normalizedPath = String(path).replace(/^\/+/, "");
  return `${normalizedBase}${normalizedPath}`;
}

function NotificationBar({ notice, onClose }) {
  if (!notice) {
    return null;
  }

  return (
    <InlineNotification
      lowContrast
      kind={notice.kind}
      title={notice.title}
      subtitle={notice.subtitle}
      onCloseButtonClick={onClose}
    />
  );
}

export default function App() {
  const {
    apiBase,
    loading,
    programs,
    refreshPrograms,
    startProgram,
    stopProgram,
    restartProgram,
    reloadSupervisor,
    shutdownSupervisor,
    isRunningState,
  } = useSupervisorController();

  const [notice, setNotice] = useState(null);
  const [isDarkMode, setIsDarkMode] = useState(true);
  const [confirm, setConfirm] = useState({ open: false, type: null, name: "" });
  const [confirmBusy, setConfirmBusy] = useState(false);

  const programMetaByName = useMemo(
    () =>
      programs.reduce((acc, program) => {
        const override = PROGRAM_DEFINITIONS[program.name];
        acc[program.name] = {
          displayName:
            program.display_name || override?.displayName || program.name,
          link: program.link || override?.link || "",
          hidden: override?.hidden || false,
          logo: override?.logo || "",
          description:
            override?.description ||
            program.description ||
            "Service endpoint managed by the LabNow runtime.",
        };
        return acc;
      }, {}),
    [programs],
  );
  const visiblePrograms = useMemo(
    () =>
      programs.filter((program) => !programMetaByName[program.name]?.hidden),
    [programMetaByName, programs],
  );

  const pushNotice = (kind, title, subtitle = "") => {
    setNotice({ kind, title, subtitle });
  };

  useEffect(() => {
    if (!notice) {
      return undefined;
    }

    const timer = setTimeout(() => {
      setNotice(null);
    }, 4000);

    return () => clearTimeout(timer);
  }, [notice]);

  useEffect(() => {
    document.body.style.backgroundColor = isDarkMode ? "#161616" : "#f4f4f4";
    return () => {
      document.body.style.backgroundColor = "";
    };
  }, [isDarkMode]);

  const handleStartProgram = async (name) => {
    const result = await startProgram(name);
    if (!result.ok) {
      pushNotice("error", "Failed to start program", name);
      return;
    }
    pushNotice("success", "Program started", name);
  };

  const handleRestartProgram = async (name) => {
    const result = await restartProgram(name);
    if (!result.ok) {
      pushNotice("error", "Failed to restart program", name);
      return;
    }
    pushNotice("success", "Program restarted", name);
  };

  const openStopConfirm = (name) => {
    setConfirm({ open: true, type: "stop", name });
  };

  const openReloadConfirm = () => {
    setConfirm({ open: true, type: "reload", name: "" });
  };

  const openShutdownConfirm = () => {
    setConfirm({ open: true, type: "shutdown", name: "" });
  };

  const closeConfirm = () => {
    if (confirmBusy) {
      return;
    }
    setConfirm({ open: false, type: null, name: "" });
  };

  const handleConfirmSubmit = async () => {
    setConfirmBusy(true);
    try {
      if (confirm.type === "stop") {
        const result = await stopProgram(confirm.name);
        if (!result.ok) {
          pushNotice("error", "Failed to stop program", confirm.name);
        } else {
          pushNotice("success", "Program stopped", confirm.name);
        }
      }

      if (confirm.type === "reload") {
        const result = await reloadSupervisor();
        if (!result.ok) {
          pushNotice("error", "Failed to reload supervisor");
        } else {
          pushNotice("success", "Reload command sent");
        }
      }

      if (confirm.type === "shutdown") {
        const result = await shutdownSupervisor();
        if (!result.ok) {
          pushNotice("error", "Failed to shutdown supervisor");
        } else {
          pushNotice("success", "Shutdown command sent");
        }
      }
    } finally {
      setConfirmBusy(false);
      setConfirm({ open: false, type: null, name: "" });
    }
  };

  const confirmText = {
    stop: {
      heading: "Stop confirmation",
      body: "Do you really want to stop program?",
      primary: "Stop",
    },
    reload: {
      heading: "Reload confirmation",
      body: "Do you really want to reload supervisor?",
      primary: "Reload",
    },
    shutdown: {
      heading: "Shutdown confirmation",
      body: "Do you really want to shutdown supervisor?",
      primary: "Shutdown",
    },
  }[confirm.type] || { heading: "", body: "", primary: "Confirm" };

  return (
    <Theme theme={isDarkMode ? "g100" : "g10"}>
      <div className="app-shell">
        <Header aria-label="LabNow Console - Open Source Version">
          <HeaderName href="#" prefix="">
            <img
              className="header-brand-logo"
              src={buildPrefixedPath("favicon.svg")}
              alt=""
              aria-hidden="true"
            />
            Console (Open Source Version)
          </HeaderName>
          <HeaderGlobalBar>
            <Toggletip>
              <ToggletipButton
                className="header-toggletip-button"
                label="Show API Base information"
              >
                <Information size={20} />
              </ToggletipButton>
              <ToggletipContent>
                <p className="header-toggletip-content">API Base: {apiBase}</p>
              </ToggletipContent>
            </Toggletip>
            <HeaderGlobalAction
              aria-label={
                isDarkMode ? "Switch to light mode" : "Switch to dark mode"
              }
              tooltipAlignment="end"
              onClick={() => setIsDarkMode((prev) => !prev)}
            >
              {isDarkMode ? <Light size={20} /> : <Moon size={20} />}
            </HeaderGlobalAction>
            <HeaderGlobalAction
              aria-label="Open documentation"
              tooltipAlignment="end"
              onClick={() =>
                window.open(
                  "https://doc.labnow.ai",
                  "_blank",
                  "noopener,noreferrer",
                )
              }
            >
              <DocumentExport size={20} />
            </HeaderGlobalAction>
          </HeaderGlobalBar>
        </Header>

        <Content id="main-content" className="page-content">
          <div className="section">
            <div className="section-top">
              <h2 className="section-title">
                LabNow Programs (Open Source Version)
              </h2>
              <div className="section-top-actions">
                <Button
                  kind="ghost"
                  size="sm"
                  hasIconOnly
                  iconDescription="Reload Supervisor"
                  renderIcon={Restart}
                  tooltipAlignment="end"
                  tooltipPosition="bottom"
                  title="Reload Supervisor"
                  onClick={openReloadConfirm}
                />
                <Button
                  kind="ghost"
                  size="sm"
                  hasIconOnly
                  iconDescription="Refresh Status"
                  renderIcon={Renew}
                  tooltipAlignment="end"
                  tooltipPosition="bottom"
                  title="Refresh Status"
                  onClick={refreshPrograms}
                />
              </div>
            </div>

            <NotificationBar notice={notice} onClose={() => setNotice(null)} />

            <div className="program-grid">
              {visiblePrograms.map((program) => {
                const running = isRunningState(program.statename);
                const programMeta = programMetaByName[program.name];
                const programLabel = programMeta?.displayName || program.name;
                const programLink = programMeta?.link;
                const programLogo = programMeta?.logo || "";
                const programDescription = programMeta?.description || "";
                const programLinkEnabled =
                  String(program.statename || "")
                    .trim()
                    .toLowerCase() === "running";
                const programTooltip = programLinkEnabled
                  ? "Open the program in new browser tab"
                  : "Please start the program first to use it!";
                const programTitleContent =
                  programLink && programLinkEnabled ? (
                    <Link
                      className="program-card-title-link"
                      href={programLink}
                      target="_blank"
                      rel="noopener noreferrer"
                      title={programTooltip}
                    >
                      {programLabel}
                      <Launch size={14} />
                    </Link>
                  ) : (
                    <span
                      className={
                        programLink ? "program-card-title-disabled" : ""
                      }
                      title={programTooltip}
                    >
                      {programLabel}
                    </span>
                  );

                return (
                  <article key={program.name} className="program-card">
                    <div className="program-card-header">
                      {programLogo ? (
                        <img
                          className="program-logo program-logo-card"
                          src={buildPrefixedPath(programLogo)}
                          alt=""
                          aria-hidden="true"
                        />
                      ) : null}
                      <div className="program-card-meta">
                        <h3 className="program-card-title">
                          {programTitleContent}
                        </h3>
                        <p className="program-card-description">
                          {programDescription}
                        </p>
                      </div>
                    </div>

                    <div className="program-card-footer">
                      <div className="card-footer-left">
                        <div className="card-actions-left">
                          <Button
                            size="sm"
                            kind={running ? "secondary" : "primary"}
                            hasIconOnly
                            iconDescription={running ? "Stop" : "Start"}
                            title={running ? "Stop" : "Start"}
                            renderIcon={running ? StopFilledAlt : PlayFilledAlt}
                            onClick={() =>
                              running
                                ? openStopConfirm(program.name)
                                : handleStartProgram(program.name)
                            }
                          />
                          {running ? (
                            <Button
                              size="sm"
                              kind="tertiary"
                              hasIconOnly
                              iconDescription="Restart"
                              title="Restart"
                              renderIcon={Renew}
                              onClick={() => handleRestartProgram(program.name)}
                            />
                          ) : null}
                        </div>

                        <div className="state-cell">
                          <Toggletip>
                            <ToggletipButton
                              className="state-tag-toggletip-button"
                              label={`Show details for ${program.name}`}
                            >
                              <Tag
                                className="state-tag"
                                type={running ? "green" : "red"}
                              >
                                <Information className="state-tag-icon" size={16} />
                              </Tag>
                            </ToggletipButton>
                            <ToggletipContent>
                              <p className="state-toggletip-title">
                                {program.name}
                              </p>
                              <p className="state-toggletip-text">
                                Description: {program.description || "-"}
                              </p>
                              <p className="state-toggletip-text">
                                State: {program.statename}
                              </p>
                            </ToggletipContent>
                          </Toggletip>
                        </div>
                      </div>

                      <div className="card-actions-right">
                        {running && programLink ? (
                          <Button
                            size="sm"
                            kind="primary"
                            title="Launch"
                            renderIcon={Launch}
                            onClick={() =>
                              window.open(
                                programLink,
                                "_blank",
                                "noopener,noreferrer",
                              )
                            }
                          >
                            Launch
                          </Button>
                        ) : null}
                      </div>
                    </div>
                  </article>
                );
              })}
            </div>
          </div>

          <Modal
            open={confirm.open}
            danger={confirm.type === "shutdown" || confirm.type === "stop"}
            modalHeading={confirmText.heading}
            primaryButtonText={confirmText.primary}
            secondaryButtonText="Cancel"
            onRequestClose={closeConfirm}
            onRequestSubmit={handleConfirmSubmit}
            primaryButtonDisabled={confirmBusy}
            secondaryButtonDisabled={confirmBusy}
          >
            <p>{confirmText.body}</p>
          </Modal>
        </Content>
        <footer className="app-footer">
          <div className="app-footer-content">
            <span>Copyright © 2024-{new Date().getFullYear()}</span>
            <a
              className="footer-link"
              href="https://labnow.ai"
              target="_blank"
              rel="noreferrer"
              aria-label="Open LabNow Official Website"
              title="labnow.ai"
            >
              <Home size={18} />
              <span>LabNow.ai</span>
            </a>

            <a
              className="footer-link"
              href="https://github.com/LabNow-ai"
              target="_blank"
              rel="noreferrer"
              aria-label="Open LabNow-ai on GitHub"
              title="github.com/LabNow-ai"
            >
              <LogoGithub size={18} />
              <span>LabNow-ai</span>
            </a>
            <a
              className="footer-link footer-link-icon-only"
              href="https://x.com/LabNowAi"
              target="_blank"
              rel="noreferrer"
              aria-label="Open LabNowAi on X"
              title="x.com/LabNowAi"
            >
              <LogoX size={18} />
              <span>LabNowAi</span>
            </a>
          </div>
        </footer>
      </div>
    </Theme>
  );
}
