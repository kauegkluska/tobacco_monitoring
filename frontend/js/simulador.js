// Simulador do sender + gateway LoRa: monta o mesmo pacote e faz o mesmo POST que o receiver.ino.

const STORAGE_KEY = "monitor.simulador";
const LOG_LIMIT = 200;
// http.setTimeout(3000) no receiver.
const HTTP_TIMEOUT_MS = 3000;
// "%31[^;]" no sscanf do receiver: IDs maiores tornam o pacote inválido.
const MAX_ID_LENGTH = 31;

// API_FIXA do receiver.ino: usada quando a página é aberta direto do disco.
const API_FIXA = "http://137.131.176.80:8000";

function defaultApiBase() {
  const { protocol, origin, pathname } = window.location;
  if (protocol.startsWith("http") && pathname.startsWith("/app")) return origin;
  return API_FIXA;
}

const DEFAULTS = {
  controller_id: "ESP32-TOBACCO-01",
  // Digitada em °F (como no LCD); o pacote sai em °C, como o sender manda.
  temperature_f: 95,
  humidity: 70,
  rssi: -60,
  snr: 9,
  n: 0,
  include_relays: true,
  follow_app: true,
  r1: false,
  r2: false,
  jitter: false,
  jitter_t: 0.5,
  jitter_h: 1,
  api_base: defaultApiBase(),
  api_path: "/readings/readings/",
  api_key: "",
  curing_unit_id: 1,
  interval: 2,
};

const forms = [document.getElementById("sender-form"), document.getElementById("gateway-form")];
const $ = (id) => document.getElementById(id);
const field = (name) => forms.map((form) => form.elements[name]).find(Boolean);

// Comando de relé guardado no gateway para este sender (EstadoSender começa desligado).
let gatewayCache = { controller_id: null, rele_umidade: false, rele_temperatura: false };
let autoTimer = null;
let sending = false;

/* ---------- Estado dos campos ---------- */

function loadSaved() {
  try {
    return JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}");
  } catch (_) {
    return {};
  }
}

function save() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(readValues()));
  } catch (_) {
    // Sem armazenamento: os valores valem até fechar a aba.
  }
}

function writeValues(values) {
  for (const [name, value] of Object.entries(values)) {
    const input = field(name);
    if (!input) continue;
    if (input.type === "checkbox") input.checked = Boolean(value);
    else input.value = value;
  }
}

function readValues() {
  const values = {};
  for (const name of Object.keys(DEFAULTS)) {
    const input = field(name);
    if (input.type === "checkbox") values[name] = input.checked;
    else if (input.type === "number") values[name] = input.value === "" ? NaN : Number(input.value);
    else values[name] = input.value.trim();
  }
  // Copiada do .ino costuma vir com as aspas: const char* GATEWAY_API_KEY = "...";
  values.temperature = fahrenheitToCelsius(values.temperature_f);
  values.api_key = values.api_key.replace(/^["'\s]+|["'\s;]+$/g, "");
  return values;
}

function fahrenheitToCelsius(fahrenheit) {
  return ((fahrenheit - 32) * 5) / 9;
}

// Mostra só o começo e o fim, para comparar com o .env sem expor a chave inteira.
function describeKey(key) {
  if (key.length <= 8) return `${"•".repeat(key.length)} (${key.length} caracteres)`;
  return `${key.slice(0, 4)}…${key.slice(-4)} (${key.length} caracteres)`;
}

/* ---------- Pacotes (mesmo formato do firmware) ---------- */

// sender.ino: "ID=%s;N=%ld;T=%.2f;H=%.2f;R1=%d;R2=%d"
function buildLoraPacket(v) {
  let packet = `ID=${v.controller_id};N=${Math.trunc(v.n)};T=${v.temperature.toFixed(2)};H=${v.humidity.toFixed(2)}`;
  if (v.include_relays) packet += `;R1=${v.r1 ? 1 : 0};R2=${v.r2 ? 1 : 0}`;
  return packet;
}

// receiver.ino: processarPacote() — devolve o motivo quando o gateway descartaria o pacote.
function receiverRejects(v) {
  if (!v.controller_id) return "Pacote inválido: ID vazio.";
  if (v.controller_id.includes(";")) return "Pacote inválido: o ID não pode ter ponto e vírgula.";
  if (v.controller_id.length > MAX_ID_LENGTH) return `Pacote inválido: o ID passa de ${MAX_ID_LENGTH} caracteres.`;
  if (![v.temperature, v.humidity, v.n, v.rssi, v.snr].every(Number.isFinite)) return "Preencha todos os números.";
  if (v.temperature < -40 || v.temperature > 125 || v.humidity < 0 || v.humidity > 100) {
    return "Valores fora da faixa do SHT40 (−40 a 257 °F, 0 a 100 %): o gateway descarta e não chama a API.";
  }
  return null;
}

// receiver.ino: enviarLeituraAPI() monta o JSON à mão, nesta ordem.
function buildBody(v) {
  let body = `{"temperature":${v.temperature.toFixed(2)},"humidity":${v.humidity.toFixed(2)}`;
  if (v.curing_unit_id > 0) body += `,"curing_unit_id":${Math.trunc(v.curing_unit_id)}`;
  body += `,"controller_id":"${v.controller_id}","device_code":"${v.controller_id}"`;
  body += `,"rssi":${Math.trunc(v.rssi)},"snr":${Math.trunc(v.snr)}`;
  if (v.include_relays) {
    body += `,"output_humidity_state":${v.r1}`;
    body += `,"output_temperature_state":${v.r2}`;
  }
  return body + "}";
}

function buildHeaders(v) {
  const headers = { "Content-Type": "application/json" };
  if (v.api_key) headers["X-API-Key"] = v.api_key;
  return headers;
}

function buildUrl(v) {
  let base = v.api_base.replace(/\/+$/, "");
  if (!/^https?:\/\//.test(base)) base = `http://${base}`;
  return base + (v.api_path.startsWith("/") ? v.api_path : `/${v.api_path}`);
}

// RELAY;ID=<controller_id>;H=<0|1>;T=<0|1>
function buildDownlink(id, cache) {
  return `RELAY;ID=${id};H=${cache.rele_umidade ? 1 : 0};T=${cache.rele_temperatura ? 1 : 0}`;
}

// extrairBooleanJSON(): mantém o valor anterior quando a chave não vem na resposta.
function readCommand(json, key, fallback) {
  return typeof json?.[key] === "boolean" ? json[key] : fallback;
}

/* ---------- Tela ---------- */

function cacheFor(id) {
  if (gatewayCache.controller_id !== id) gatewayCache = { controller_id: id, rele_umidade: false, rele_temperatura: false };
  return gatewayCache;
}

function render() {
  const v = readValues();

  $("temp-f").textContent = Number.isFinite(v.temperature) ? `Vai no pacote como ${v.temperature.toFixed(2)} °C` : "";

  for (const [key, on] of [["r1", v.r1], ["r2", v.r2]]) {
    $(`${key}-state`).textContent = on ? "Ligado" : "Desligado";
    $(`${key}-box`).classList.toggle("is-on", on);
    field(key).disabled = !v.include_relays || v.follow_app;
  }
  field("follow_app").disabled = !v.include_relays;
  field("jitter_t").disabled = !v.jitter;
  field("jitter_h").disabled = !v.jitter;
  document.querySelectorAll(".step-btn").forEach((button) => {
    button.disabled = button.stepTarget.disabled;
  });

  const problem = receiverRejects(v);
  $("preview-lora").textContent = [v.temperature, v.humidity, v.n].every(Number.isFinite) ? buildLoraPacket(v) : "—";
  if (problem) {
    $("preview-http").textContent = problem;
  } else {
    const headers = Object.entries(buildHeaders(v))
      .map(([name, value]) => `${name}: ${name === "X-API-Key" ? describeKey(value) : value}`)
      .join("\n");
    // Corpo cru, igual ao enviado. O firmware não escapa o ID: com aspas nele o JSON sai inválido.
    let body = buildBody(v);
    try {
      JSON.parse(body);
    } catch (_) {
      body += "\n\n(JSON inválido: o ID tem aspas ou barra invertida)";
    }
    $("preview-http").textContent = `POST ${buildUrl(v)}\n${headers}\n\n${body}`;
  }

  const cache = cacheFor(v.controller_id);
  $("gateway-cache").textContent = buildDownlink(v.controller_id, cache);

  $("send-once").disabled = sending;
  $("hint").textContent = problem ? problem : "";
}

function setAuto(running) {
  const badge = $("auto-badge");
  badge.className = `badge ${running ? "badge-ok" : "badge-neutral"}`;
  badge.lastElementChild.textContent = running ? "Enviando" : "Parado";
  $("toggle-auto").textContent = running ? "Parar envio automático" : "Iniciar envio automático";
}

function statusHtml(text, tone) {
  const span = document.createElement("span");
  span.className = `status-${tone}`;
  span.textContent = text;
  return span;
}

function addLog(entry) {
  const row = document.createElement("tr");
  const cells = [
    entry.time.toLocaleTimeString("pt-BR"),
    entry.n,
    entry.temperatureF.toFixed(1),
    entry.temperature.toFixed(2),
    entry.humidity.toFixed(2),
    entry.relays,
    entry.http,
    entry.result,
    entry.command,
  ];
  cells.forEach((value, index) => {
    const cell = document.createElement("td");
    if (index >= 1 && index <= 4) cell.className = "num";
    if (value instanceof Node) cell.append(value);
    else cell.textContent = String(value);
    row.append(cell);
  });
  const log = $("log");
  log.prepend(row);
  while (log.rows.length > LOG_LIMIT) log.deleteRow(-1);
  $("log-empty").hidden = true;
}

function describeResult(status, json) {
  if (status === 201) return statusHtml("Leitura gravada", "ok");
  if (status === 202) {
    const reasons = {
      no_measurement: "sem medição",
      no_curing_unit: "controlador sem estufa vinculada",
      drying_not_started: "secagem não iniciada",
    };
    return statusHtml(`Recebida, não gravada (${reasons[json?.reason] || json?.reason || "sem motivo"})`, "warn");
  }
  if (status === 401 || status === 403) return statusHtml("Chave da API vazia ou errada", "crit");
  if (status === 422) return statusHtml("Dados recusados pela API", "crit");
  return statusHtml(status > 0 ? "Erro do servidor" : "Sem conexão", "crit");
}

/* ---------- Ciclo de envio ---------- */

function applyJitter(v) {
  if (!v.jitter) return;
  const drift = (amplitude) => (Math.random() * 2 - 1) * (Number.isFinite(amplitude) ? amplitude : 0);
  // Faixa do SHT40 (−40 a 125 °C) em °F.
  const temperatureF = Math.min(257, Math.max(-40, v.temperature_f + drift(v.jitter_t)));
  const humidity = Math.min(100, Math.max(0, v.humidity + drift(v.jitter_h)));
  field("temperature_f").value = temperatureF.toFixed(1);
  field("humidity").value = humidity.toFixed(2);
}

async function sendOnce() {
  if (sending) return false;
  if (!forms.every((form) => form.reportValidity())) return false;

  const v = readValues();
  const problem = receiverRejects(v);
  const sentAt = new Date();
  const relays = v.include_relays ? `${v.r1 ? 1 : 0} / ${v.r2 ? 1 : 0}` : "não enviados";

  // O sender transmite e sempre incrementa o contador, mesmo que o gateway descarte.
  field("n").value = Math.trunc(v.n) + 1;

  if (problem) {
    addLog({ time: sentAt, n: v.n, temperatureF: v.temperature_f || 0, temperature: v.temperature || 0, humidity: v.humidity || 0, relays, http: "—", result: statusHtml("Descartado pelo gateway", "crit"), command: "—" });
    $("last-status").replaceChildren(statusHtml("Descartado", "crit"));
    $("last-downlink").textContent = "Nenhum: o gateway descartou o pacote.";
    $("last-response").textContent = problem;
    save();
    render();
    return true;
  }

  sending = true;
  render();

  // 1) O gateway responde logo com o comando guardado; o sender aplica nos relés.
  const cache = cacheFor(v.controller_id);
  const downlink = buildDownlink(v.controller_id, cache);
  $("last-downlink").textContent = v.include_relays && v.follow_app ? `${downlink}\n(aplicado nos relés do próximo pacote)` : `${downlink}\n(ignorado: relés manuais)`;
  if (v.include_relays && v.follow_app) {
    field("r1").checked = cache.rele_umidade;
    field("r2").checked = cache.rele_temperatura;
  }

  // 2) Depois manda a leitura para a API e atualiza o cache para a próxima rodada.
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), HTTP_TIMEOUT_MS);
  let status = -1;
  let text = "";
  let json = null;
  try {
    const response = await fetch(buildUrl(v), { method: "POST", headers: buildHeaders(v), body: buildBody(v), signal: controller.signal });
    status = response.status;
    text = await response.text();
    try {
      json = JSON.parse(text);
    } catch (_) {
      json = null;
    }
  } catch (error) {
    text = error.name === "AbortError" ? `Sem resposta em ${HTTP_TIMEOUT_MS / 1000} s (timeout do gateway).` : `Erro de conexão: ${error.message}\nConfira o endereço da API e se o backend está rodando.`;
  } finally {
    clearTimeout(timeout);
  }

  const success = status >= 200 && status < 300;
  if (success) {
    cache.rele_umidade = readCommand(json, "rele_umidade", cache.rele_umidade);
    cache.rele_temperatura = readCommand(json, "rele_temperatura", cache.rele_temperatura);
  }

  const result = describeResult(status, json);
  $("last-status").replaceChildren(statusHtml(status > 0 ? `HTTP ${status}` : "Falhou", success ? "ok" : "crit"));
  $("last-response").textContent = json ? JSON.stringify(json, null, 2) : text || "(resposta vazia)";
  addLog({
    time: sentAt,
    n: v.n,
    temperatureF: v.temperature_f,
    temperature: v.temperature,
    humidity: v.humidity,
    relays,
    http: status > 0 ? status : "—",
    result,
    command: success ? `H=${cache.rele_umidade ? 1 : 0} T=${cache.rele_temperatura ? 1 : 0}` : "—",
  });

  applyJitter(v);
  sending = false;
  save();
  render();
  return true;
}

function scheduleNext(startedAt) {
  if (!autoTimer) return;
  const interval = Math.max(0.5, readValues().interval || DEFAULTS.interval) * 1000;
  autoTimer = setTimeout(runAuto, Math.max(0, interval - (Date.now() - startedAt)));
}

async function runAuto() {
  const startedAt = Date.now();
  const sent = await sendOnce();
  if (!sent && !sending) {
    stopAuto();
    return;
  }
  scheduleNext(startedAt);
}

function stopAuto() {
  clearTimeout(autoTimer);
  autoTimer = null;
  setAuto(false);
}

/* ---------- Botões − e + ---------- */

const REPEAT_DELAY_MS = 400;
const REPEAT_EVERY_MS = 70;

function stepInput(input, direction) {
  const step = Number(input.dataset.stepper);
  const decimals = Math.max((input.dataset.stepper.split(".")[1] || "").length, (input.step.split(".")[1] || "").length);
  const current = input.value === "" ? 0 : Number(input.value);
  let next = Number((current + direction * step).toFixed(decimals));
  if (input.min !== "") next = Math.max(Number(input.min), next);
  if (input.max !== "") next = Math.min(Number(input.max), next);
  input.value = String(next);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

function makeStepButton(input, direction) {
  const label = input.closest(".field")?.querySelector(".field-label")?.textContent || "valor";
  const button = document.createElement("button");
  button.type = "button";
  button.className = `step-btn ${direction < 0 ? "step-down" : "step-up"}`;
  button.textContent = direction < 0 ? "−" : "+";
  button.setAttribute("aria-label", `${direction < 0 ? "Diminuir" : "Aumentar"} ${label.toLowerCase()} em ${input.dataset.stepper}`);
  button.stepTarget = input;

  // Segurar o botão repete o passo.
  let timer = null;
  const stop = () => {
    clearTimeout(timer);
    timer = null;
  };
  const repeat = () => {
    stepInput(input, direction);
    timer = setTimeout(repeat, REPEAT_EVERY_MS);
  };
  button.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 || button.disabled) return;
    stepInput(input, direction);
    timer = setTimeout(repeat, REPEAT_DELAY_MS);
  });
  ["pointerup", "pointerleave", "pointercancel"].forEach((type) => button.addEventListener(type, stop));
  // Teclado (Enter/Espaço) gera click sem pointerdown.
  button.addEventListener("click", (event) => {
    if (event.detail === 0) stepInput(input, direction);
  });
  return button;
}

document.querySelectorAll("input[data-stepper]").forEach((input) => {
  let group = input.closest(".input-group");
  if (!group) {
    group = document.createElement("span");
    group.className = "input-group";
    input.replaceWith(group);
    group.append(input);
  }
  group.prepend(makeStepButton(input, -1));
  group.append(makeStepButton(input, 1));
});

/* ---------- Início ---------- */

writeValues({ ...DEFAULTS, ...loadSaved() });
render();

forms.forEach((form) => {
  form.addEventListener("input", () => {
    save();
    render();
  });
  form.addEventListener("submit", (event) => event.preventDefault());
});

$("send-once").addEventListener("click", sendOnce);
$("toggle-auto").addEventListener("click", () => {
  if (autoTimer) {
    stopAuto();
    return;
  }
  if (!forms.every((form) => form.reportValidity())) return;
  autoTimer = true;
  setAuto(true);
  runAuto();
});
$("reset").addEventListener("click", () => {
  const { api_base, api_key } = readValues();
  writeValues({ ...DEFAULTS, api_base, api_key });
  gatewayCache = { controller_id: null, rele_umidade: false, rele_temperatura: false };
  save();
  render();
});
$("clear-log").addEventListener("click", () => {
  $("log").replaceChildren();
  $("log-empty").hidden = false;
});
