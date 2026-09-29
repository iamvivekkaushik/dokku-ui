import { createContext, useContext } from 'react';
import type { TerminalSpec } from '../components/Terminal';

export interface UiActions {
  openTerminal: (spec: TerminalSpec, title?: string) => void;
  openConsole: () => void;
  openDeploy: (app?: string) => void;
  openCreateApp: () => void;
  openProvision: (type?: string) => void;
  openConnect: (editId?: string) => void;
}

export const UiCtx = createContext<UiActions | null>(null);

export function useUi(): UiActions {
  const c = useContext(UiCtx);
  if (!c) throw new Error('useUi outside provider');
  return c;
}
