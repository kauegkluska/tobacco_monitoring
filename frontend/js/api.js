// Cliente da API FastAPI: guarda a sessão, renova o token e traduz erros para mensagens claras.

const TOKENS_KEY = "monitor.tokens";
const BASE_KEY = "monitor.apiBase";

const FIELD_NAMES = {
  login: "Login",
  password: "Senha",
  new_password: "Nova senha",
  current_password: "Senha atual",
  name: "Nome",
  controller_id: "ID do controlador",
  device_code: "ID do controlador",
  mac_address: "Endereço MAC",
  temp_min: "Temperatura mínima",
  temp_max: "Temperatura máxima",
  humidity_min: "Umidade mínima",
  humidity_max: "Umidade máxima",
  estimated_duration_hours: "Duração estimada",
  curing_stage: "Fase",
};

function storageGet(key) {
  try {
    return localStorage.getItem(key);
  } catch (_) {
    return null;
  }
}

function storageSet(key, value) {
  try {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch (_) {
    // Sem armazenamento disponível: a sessão dura até fechar a aba.
  }
}

/** Painel servido pela própria API (http://ip:8000/app/) usa o mesmo endereço. */
export function defaultBase() {
  const { protocol, origin, hostname, pathname } = window.location;
  if (protocol.startsWith("http") && pathname.startsWith("/app")) return origin;
  if (protocol.startsWith("http")) return `${protocol}//${hostname}:8000`;
  return "http://127.0.0.1:8000";
}

export class ApiError extends Error {
  constructor(message, status = 0, detail = null) {
    super(message);
    this.status = status;
    this.detail = detail;
  }
}

function describeValidation(detail) {
  if (!Array.isArray(detail)) return null;
  const messages = detail.map((item) => {
    const fieldName = FIELD_NAMES[item.loc?.[item.loc.length - 1]] || "Campo";
    const ctx = item.ctx || {};
    switch (item.type) {
      case "string_too_short":
        return `${fieldName}: mínimo de ${ctx.min_length} caracteres.`;
      case "string_too_long":
        return `${fieldName}: máximo de ${ctx.max_length} caracteres.`;
      case "missing":
        return `${fieldName}: campo obrigatório.`;
      case "greater_than_equal":
        return `${fieldName}: o valor mínimo é ${ctx.ge}.`;
      case "less_than_equal":
        return `${fieldName}: o valor máximo é ${ctx.le}.`;
      case "greater_than":
        return `${fieldName}: deve ser maior que ${ctx.gt}.`;
      case "float_parsing":
      case "int_parsing":
        return `${fieldName}: informe um número.`;
      case "value_error":
        return String(item.msg || "").replace(/^Value error, /, "");
      default:
        return `${fieldName}: ${item.msg}`;
    }
  });
  return messages.join(" ");
}

class Api {
  constructor() {
    this.base = (storageGet(BASE_KEY) || defaultBase()).replace(/\/+$/, "");
    this.tokens = null;
    try {
      this.tokens = JSON.parse(storageGet(TOKENS_KEY) || "null");
    } catch (_) {
      this.tokens = null;
    }
    this.refreshing = null;
    this.listeners = { expired: new Set(), connection: new Set() };
    this.online = true;
  }

  on(event, listener) {
    this.listeners[event].add(listener);
    return () => this.listeners[event].delete(listener);
  }

  emit(event, value) {
    this.listeners[event].forEach((listener) => listener(value));
  }

  setConnection(online) {
    if (this.online === online) return;
    this.online = online;
    this.emit("connection", online);
  }

  get isAuthenticated() {
    return Boolean(this.tokens?.access_token);
  }

  get hasCustomBase() {
    return Boolean(storageGet(BASE_KEY));
  }

  setBase(url) {
    const clean = url.trim().replace(/\/+$/, "");
    if (!clean || clean === defaultBase()) {
      storageSet(BASE_KEY, null);
      this.base = defaultBase();
    } else {
      storageSet(BASE_KEY, clean);
      this.base = clean;
    }
  }

  saveTokens(tokens) {
    this.tokens = tokens ? { access_token: tokens.access_token, refresh_token: tokens.refresh_token } : null;
    storageSet(TOKENS_KEY, this.tokens ? JSON.stringify(this.tokens) : null);
  }

  async testConnection(url = this.base) {
    try {
      const response = await fetch(`${url.replace(/\/+$/, "")}/health`, { cache: "no-store" });
      return response.ok;
    } catch (_) {
      return false;
    }
  }

  async refresh() {
    if (!this.tokens?.refresh_token) return false;
    if (!this.refreshing) {
      this.refreshing = (async () => {
        try {
          const response = await fetch(`${this.base}/auth/refresh`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ refresh_token: this.tokens.refresh_token }),
          });
          if (!response.ok) return false;
          this.saveTokens(await response.json());
          return true;
        } catch (_) {
          return false;
        } finally {
          setTimeout(() => {
            this.refreshing = null;
          }, 0);
        }
      })();
    }
    return this.refreshing;
  }

  async request(method, path, { body, auth = true, raw = false, retry = true } = {}) {
    const headers = { Accept: raw ? "*/*" : "application/json" };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (auth && this.tokens?.access_token) headers.Authorization = `Bearer ${this.tokens.access_token}`;

    let response;
    try {
      response = await fetch(`${this.base}${path}`, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        cache: "no-store",
      });
    } catch (_) {
      this.setConnection(false);
      throw new ApiError(`Não foi possível conectar ao servidor (${this.base}). Verifique se o backend está ligado.`, 0);
    }
    this.setConnection(true);

    if (response.status === 401 && auth && retry) {
      if (await this.refresh()) return this.request(method, path, { body, auth, raw, retry: false });
      this.saveTokens(null);
      this.emit("expired");
      throw new ApiError("Sua sessão expirou. Entre novamente.", 401);
    }

    if (!response.ok) {
      let detail = null;
      try {
        detail = (await response.json()).detail;
      } catch (_) {
        detail = null;
      }
      const message =
        describeValidation(detail) ||
        (typeof detail === "string" ? detail : null) ||
        (response.status >= 500 ? "O servidor encontrou um erro. Tente novamente em instantes." : `Erro ${response.status} ao falar com o servidor.`);
      throw new ApiError(message, response.status, detail);
    }

    if (raw) return response;
    if (response.status === 204) return null;
    return response.json();
  }

  get(path, options) {
    return this.request("GET", path, options);
  }

  post(path, body = {}, options) {
    return this.request("POST", path, { ...options, body });
  }

  patch(path, body, options) {
    return this.request("PATCH", path, { ...options, body });
  }

  del(path, options) {
    return this.request("DELETE", path, options);
  }

  /** Igual a get, mas devolve null quando o recurso não existe (404). */
  async getOrNull(path) {
    try {
      return await this.get(path);
    } catch (error) {
      if (error.status === 404) return null;
      throw error;
    }
  }

  async login(login, password) {
    this.saveTokens(await this.post("/auth/login", { login, password }, { auth: false }));
  }

  async register(name, login, password) {
    this.saveTokens(await this.post("/auth/register", { name, login, password }, { auth: false }));
  }

  logout() {
    this.saveTokens(null);
  }

  /** Baixa um arquivo autenticado (ex.: CSV) e aciona o download no navegador. */
  async download(path, filename) {
    const response = await this.request("GET", path, { raw: true });
    const blob = await response.blob();
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
}

export const api = new Api();
