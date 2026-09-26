// Dados compartilhados entre as páginas e regras de apresentação.

import { api } from "./api.js";
import { prefs } from "./store.js";

export const STAGES = [
  "Não iniciado",
  "Início da secagem",
  "Amarelecimento",
  "Murcha",
  "Secagem da folha",
  "Secagem do talo",
  "Finalizado",
];

export const DEFAULT_LIMITS = { temp_min: 35, temp_max: 75, humidity_min: 40, humidity_max: 90 };

export async function loadOverview() {
  const [units, devices] = await Promise.all([api.get("/curing_units/"), api.get("/devices/")]);
  const devicesById = new Map(devices.map((device) => [device.id, device]));
  return { units, devices, devicesById };
}

/** Estufa escolhida pelo usuário (lembrada neste navegador) ou a primeira. */
export function pickUnit(units, requestedId = prefs.unitId) {
  if (!units.length) return null;
  return units.find((unit) => String(unit.id) === String(requestedId)) || units[0];
}

export function limitsOf(device) {
  return {
    temp_min: device?.temp_min ?? DEFAULT_LIMITS.temp_min,
    temp_max: device?.temp_max ?? DEFAULT_LIMITS.temp_max,
    humidity_min: device?.humidity_min ?? DEFAULT_LIMITS.humidity_min,
    humidity_max: device?.humidity_max ?? DEFAULT_LIMITS.humidity_max,
  };
}

/** "ok" | "high" | "low" */
export function rangeState(value, min, max) {
  if (value === null || value === undefined) return null;
  if (value > max) return "high";
  if (value < min) return "low";
  return "ok";
}

export function stageOptions(current) {
  const stages = STAGES.includes(current) || !current ? STAGES : [current, ...STAGES];
  return stages.map((stage) => ({ value: stage, label: stage }));
}

export function severityInfo(alert) {
  if (!alert.is_active) return { kind: "ok", label: "Resolvido", icon: "checkCircle", className: "is-resolved" };
  if (alert.severity === "critical") return { kind: "crit", label: "Crítico", icon: "error", className: "is-critical" };
  return { kind: "warn", label: "Atenção", icon: "warning", className: "is-warning" };
}

export function signalQuality(rssi) {
  if (rssi === null || rssi === undefined) return "Não informado";
  if (rssi >= -70) return "Ótimo";
  if (rssi >= -85) return "Bom";
  if (rssi >= -100) return "Fraco";
  return "Muito fraco";
}
