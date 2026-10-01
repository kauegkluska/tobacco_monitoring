// Dados compartilhados entre as páginas e regras de apresentação.

import { api } from "./api.js";
import * as f from "./format.js";

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

/** Faixa esperada: a da fase em andamento; sem secagem, os limites do dispositivo. */
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

/** Gravidades da API, da mais grave para a mais leve. */
export const SEVERITIES = [
  { value: "emergency", label: "Emergência" },
  { value: "critical", label: "Crítico" },
  { value: "warning", label: "Atenção" },
  { value: "info", label: "Informativo" },
];

export function severityLabel(alert) {
  return SEVERITIES.find((item) => item.value === alert.severity)?.label || "Atenção";
}

export function signalQuality(rssi) {
  if (rssi === null || rssi === undefined) return "Não informado";
  if (rssi >= -70) return "Ótimo";
  if (rssi >= -85) return "Bom";
  if (rssi >= -100) return "Fraco";
  return "Muito fraco";
}
