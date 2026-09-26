// Preferências deste navegador (unidade, tema, estufa selecionada, aviso sonoro).

const KEY = "monitor.prefs";
const DEFAULTS = { unit: "F", theme: "auto", unitId: null, sound: true };

function read() {
  try {
    return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(KEY) || "{}") };
  } catch (_) {
    return { ...DEFAULTS };
  }
}

const state = read();
const listeners = new Set();

export const prefs = {
  get unit() {
    return state.unit === "C" ? "C" : "F";
  },
  get theme() {
    return state.theme;
  },
  get unitId() {
    return state.unitId;
  },
  /** Bipa e vibra quando o gateway toca o aviso sonoro. */
  get sound() {
    return state.sound !== false;
  },
  set(changes) {
    Object.assign(state, changes);
    try {
      localStorage.setItem(KEY, JSON.stringify(state));
    } catch (_) {
      // Sem armazenamento (modo privado): a preferência vale só nesta sessão.
    }
    if ("theme" in changes) applyTheme();
    listeners.forEach((listener) => listener(changes));
  },
  subscribe(listener) {
    listeners.add(listener);
    return () => listeners.delete(listener);
  },
};

export function applyTheme() {
  const root = document.documentElement;
  if (state.theme === "light" || state.theme === "dark") root.dataset.theme = state.theme;
  else delete root.dataset.theme;
}
