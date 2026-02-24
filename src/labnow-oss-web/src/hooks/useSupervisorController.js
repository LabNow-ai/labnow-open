import { useCallback, useEffect, useMemo, useState } from "react";
import {
  createSupervisorApi,
  isRunningState,
  resolveApiBase,
} from "../api/supervisorApi";

export function useSupervisorController() {
  const [loading, setLoading] = useState(false);
  const [programs, setPrograms] = useState([]);
  const [apiBase, setApiBase] = useState(
    import.meta.env.DEV ? "/api/home" : "/home"
  );
  const [selectedRowKeys, setSelectedRowKeys] = useState([]);

  useEffect(() => {
    resolveApiBase().then(setApiBase);
  }, []);

  const api = useMemo(() => createSupervisorApi(apiBase), [apiBase]);

  const patchProgramState = useCallback((name, nextState) => {
    setPrograms((prev) =>
      prev.map((item) =>
        item.name === name ? { ...item, statename: nextState } : item
      )
    );
  }, []);

  const refreshPrograms = useCallback(async () => {
    setLoading(true);
    try {
      const { ok, data } = await api.listPrograms();
      const programList = Array.isArray(data)
        ? data
        : Array.isArray(data?.data)
          ? data.data
          : null;

      if (!ok || !programList) {
        return { ok: false };
      }

      setPrograms(programList);
      return { ok: true };
    } finally {
      setLoading(false);
    }
  }, [api]);

  useEffect(() => {
    const timer = setTimeout(() => {
      refreshPrograms();
    }, 2000);
    return () => clearTimeout(timer);
  }, [refreshPrograms]);

  const startProgram = useCallback(
    async (name) => {
      const { ok, data } = await api.startProgram(name);
      if (!ok || (data && data.success === false)) {
        return { ok: false };
      }

      patchProgramState(name, "Running");
      return { ok: true };
    },
    [api, patchProgramState]
  );

  const stopProgram = useCallback(
    async (name) => {
      const { ok, data } = await api.stopProgram(name);
      if (!ok || (data && data.success === false)) {
        return { ok: false };
      }

      patchProgramState(name, "Stopped");
      return { ok: true };
    },
    [api, patchProgramState]
  );

  const restartProgram = useCallback(
    async (name) => {
      const stopResult = await stopProgram(name);
      if (!stopResult.ok) {
        return { ok: false, phase: "stop" };
      }

      const startResult = await startProgram(name);
      if (!startResult.ok) {
        return { ok: false, phase: "start" };
      }

      return { ok: true };
    },
    [startProgram, stopProgram]
  );

  const startSelectedPrograms = useCallback(async () => {
    if (selectedRowKeys.length === 0) {
      return { ok: false, reason: "empty_selection" };
    }

    const { ok } = await api.startPrograms(selectedRowKeys);
    await refreshPrograms();
    return { ok };
  }, [api, refreshPrograms, selectedRowKeys]);

  const stopSelectedPrograms = useCallback(async () => {
    if (selectedRowKeys.length === 0) {
      return { ok: false, reason: "empty_selection" };
    }

    const { ok } = await api.stopPrograms(selectedRowKeys);
    await refreshPrograms();
    return { ok };
  }, [api, refreshPrograms, selectedRowKeys]);

  const reloadSupervisor = useCallback(async () => {
    const { ok } = await api.reloadSupervisor();
    await refreshPrograms();
    return { ok };
  }, [api, refreshPrograms]);

  const shutdownSupervisor = useCallback(async () => {
    const { ok } = await api.shutdownSupervisor();
    return { ok };
  }, [api]);

  return {
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
  };
}
