// Dados compartilhados entre as páginas e regras de apresentação.

import { api } from "./api.js";
import * as f from "./format.js";
import { prefs } from "./store.js";

// As quatro fases da cura, na ordem; a cor de cada uma vem do CSS (--phase-<key>).
export const PHASES = [
  { key: "amarelacao", name: "Amarelação" },
  { key: "murchamento", name: "Murchamento" },
  { key: "secagem_folha", name: "Secagem da folha" },
  { key: "secagem_talo", name: "Secagem do talo" },
];

export const STAGES = ["Não iniciado", ...PHASES.map((phase) => phase.name), "Finalizado"];

export const DEFAULT_LIMITS = { temp_min: 35, temp_max: 75, humidity_min: 40, humidity_max: 90 };

export function phaseKey(stage) {
  return PHASES.find((phase) => phase.name === stage)?.key || null;
}

/** Faixa segura: a da fase em andamento; sem secagem, os limites do dispositivo. */
export function limitsFor(unit, device) {
  return unit?.phase ? { ...unit.phase } : limitsOf(device);
}

/** Fases do período (resposta de /series) no formato do gráfico, já na unidade de exibição. */
export function chartPhases(series, isTemp) {
  return (series?.phases || []).map((phase) => ({
    start: new Date(phase.started_at),
    end: new Date(phase.ended_at),
    key: phase.key,
    name: phase.stage,
    min: isTemp ? f.tempValue(phase.temp_min) : phase.humidity_min,
    max: isTemp ? f.tempValue(phase.temp_max) : phase.humidity_max,
  }));
}

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

/** Crítico ou emergência: pede ação imediata. */
export function isSevere(alert) {
  return alert.severity === "critical" || alert.severity === "emergency";
}

export function severityInfo(alert) {
  if (!alert.is_active) return { kind: "ok", label: "Resolvido", icon: "checkCircle", className: "is-resolved" };
  if (alert.severity === "emergency") return { kind: "crit", label: "Emergência", icon: "error", className: "is-critical" };
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
