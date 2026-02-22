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
  Modal,
  OverflowMenu,
  OverflowMenuItem,
  Tag,
  Theme,
} from "@carbon/react";
import {
  Information,
  Light,
  Moon,
  PlayFilledAlt,
  Renew,
  StopFilledAlt,
} from "@carbon/icons-react";
import { useSupervisorController } from "./hooks/useSupervisorController";

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
    selectedRowKeys,
    setSelectedRowKeys,
    refreshPrograms,
    startProgram,
    stopProgram,
    restartProgram,
    startSelectedPrograms,
    stopSelectedPrograms,
    reloadSupervisor,
    shutdownSupervisor,
    isRunningState,
  } = useSupervisorController();

  const [notice, setNotice] = useState(null);
  const [isDarkMode, setIsDarkMode] = useState(true);
  const [confirm, setConfirm] = useState({ open: false, type: null, name: "" });
  const [confirmBusy, setConfirmBusy] = useState(false);

  const selectedSet = useMemo(() => new Set(selectedRowKeys), [selectedRowKeys]);
  const allSelected = programs.length > 0 && selectedRowKeys.length === programs.length;

  const pushNotice = (kind, title, subtitle = "") => {
    setNotice({ kind, title, subtitle });
  };

  useEffect(() => {
    if (!notice) {
      return undefined;
    }

    const timer = setTimeout(() => {
      setNotice(null);
    }, 6000);

    return () => clearTimeout(timer);
  }, [notice]);

  const handleToggleAll = () => {
    if (allSelected) {
      setSelectedRowKeys([]);
      return;
    }
    setSelectedRowKeys(programs.map((item) => item.name));
  };

  const handleToggleOne = (name) => {
    if (selectedSet.has(name)) {
      setSelectedRowKeys(selectedRowKeys.filter((key) => key !== name));
      return;
    }
    setSelectedRowKeys([...selectedRowKeys, name]);
  };

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

  const handleStartSelected = async () => {
    const result = await startSelectedPrograms();
    if (result.reason === "empty_selection") {
      pushNotice("warning", "No program selected");
      return;
    }
    if (!result.ok) {
      pushNotice("error", "Batch start failed");
      return;
    }
    pushNotice("success", "Start selected command sent");
  };

  const handleStopSelected = async () => {
    const result = await stopSelectedPrograms();
    if (result.reason === "empty_selection") {
      pushNotice("warning", "No program selected");
      return;
    }
    if (!result.ok) {
      pushNotice("error", "Batch stop failed");
      return;
    }
    pushNotice("success", "Stop selected command sent");
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
      <Header aria-label="LabNow Supervisor Console">
        <HeaderName href="#" prefix="LabNow">
          Console (OSS)
        </HeaderName>
        <HeaderGlobalBar>
          <HeaderGlobalAction
            aria-label={isDarkMode ? "Switch to light mode" : "Switch to dark mode"}
            tooltipAlignment="end"
            onClick={() => setIsDarkMode((prev) => !prev)}
          >
            {isDarkMode ? <Light size={20} /> : <Moon size={20} />}
          </HeaderGlobalAction>
          <OverflowMenu
            ariaLabel="API Base information"
            size="md"
            renderIcon={Information}
          >
            <OverflowMenuItem itemText={`API Base: ${apiBase}`} disabled />
          </OverflowMenu>
        </HeaderGlobalBar>
      </Header>

      <Content id="main-content" className="page-content">
        <div className="section">
          <div className="section-top">
            <h2 className="section-title">Programs</h2>
          </div>

          <NotificationBar notice={notice} onClose={() => setNotice(null)} />

          <div className="action-row">
            <Button kind="primary" onClick={handleStartSelected}>
              Start Selected
            </Button>
            <Button kind="secondary" onClick={handleStopSelected}>
              Stop Selected
            </Button>
            <Button kind="tertiary" onClick={openReloadConfirm}>
              Reload
            </Button>
            <Button kind="danger--tertiary" onClick={openShutdownConfirm}>
              Shutdown
            </Button>
            <Button kind="ghost" onClick={refreshPrograms}>
              Refresh
            </Button>
            {loading ? <InlineLoading description="Loading programs..." /> : null}
          </div>

          <div className="table-wrap">
            <table className="cds--data-table cds--data-table--zebra">
              <thead>
                <tr>
                  <th className="checkbox-col">
                    <input
                      type="checkbox"
                      checked={allSelected}
                      onChange={handleToggleAll}
                      aria-label="Select all programs"
                    />
                  </th>
                  <th>Program</th>
                  <th>State</th>
                  <th>Description</th>
                  <th>Action</th>
                </tr>
              </thead>
              <tbody>
                {programs.map((program) => {
                  const running = isRunningState(program.statename);
                  return (
                    <tr key={program.name}>
                      <td className="checkbox-col">
                        <input
                          type="checkbox"
                          checked={selectedSet.has(program.name)}
                          onChange={() => handleToggleOne(program.name)}
                          aria-label={`Select ${program.name}`}
                        />
                      </td>
                      <td>{program.name}</td>
                      <td>
                        <Tag type={running ? "green" : "red"}>
                          {program.statename}
                        </Tag>
                      </td>
                      <td>{program.description || "-"}</td>
                      <td>
                        <div className="row-actions">
                          <Button
                            size="sm"
                            kind="primary"
                            hasIconOnly
                            iconDescription="Start"
                            renderIcon={PlayFilledAlt}
                            tooltipAlignment="center"
                            tooltipPosition="top"
                            title="Start"
                            disabled={running}
                            onClick={() => handleStartProgram(program.name)}
                          />
                          <Button
                            size="sm"
                            kind="secondary"
                            hasIconOnly
                            iconDescription="Stop"
                            renderIcon={StopFilledAlt}
                            tooltipAlignment="center"
                            tooltipPosition="top"
                            title="Stop"
                            disabled={!running}
                            onClick={() => openStopConfirm(program.name)}
                          />
                          <Button
                            size="sm"
                            kind="tertiary"
                            hasIconOnly
                            iconDescription="Restart"
                            renderIcon={Renew}
                            tooltipAlignment="center"
                            tooltipPosition="top"
                            title="Restart"
                            disabled={!running}
                            onClick={() => handleRestartProgram(program.name)}
                          />
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
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
    </Theme>
  );
}
