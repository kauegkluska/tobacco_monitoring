// Peças de interface usadas em mais de uma tela: situação da estufa, leituras e alertas.

import { api } from "./api.js";
import { isSevere, limitsFor, phaseKey, rangeState, severityLabel } from "./data.js";
import { badge, button, confirmDialog, h, icon, toast, withBusy } from "./dom.js";
import * as f from "./format.js";

/** Leituras mais antigas que isso aparecem apagadas. */
const STALE_MS = 5 * 60_000;

/** Situação da estufa em uma palavra, da mais urgente para a mais tranquila. */
export function unitStatus({ unit, device, latest, activeAlerts, criticalAlerts }) {
  if (!device) return { kind: "neutral", label: "Sem sensor", icon: "linkOff" };
  if (!unit.is_drying) {
    return unit.curing_stage === "Finalizado"
      ? { kind: "ok", label: "Finalizada", icon: "checkCircle" }
      : { kind: "neutral", label: "Parada", icon: "stop" };
  }
  if (criticalAlerts > 0) return { kind: "crit", label: "Crítico", icon: "error" };
  if (device.status !== "online") return { kind: "offline", label: "Sem sinal", icon: "cloudOff" };
  if (activeAlerts > 0) return { kind: "warn", label: "Atenção", icon: "warning" };
  if (!latest) return { kind: "neutral", label: "Aguardando", icon: "clock" };
  const limits = limitsFor(unit, device);
  const outside =
    rangeState(latest.temperature, limits.temp_min, limits.temp_max) !== "ok" ||
    rangeState(latest.humidity, limits.humidity_min, limits.humidity_max) !== "ok";
  if (outside) return { kind: "warn", label: "Fora da faixa", icon: "tune" };
  return { kind: "ok", label: "Normal", icon: "check" };
}

export function statusBadge(status) {
  return badge(status.kind, status.label, status.icon);
}

/** Leitura antiga, sem sinal ou gravada fora da secagem atual. */
export function isStale(latest, unit, device) {
  if (!latest || !device || device.status !== "online" || !unit.is_drying) return true;
  return Date.now() - f.parseDate(latest.timestamp).getTime() > STALE_MS;
}

/** Condição para avançar de fase, com o alvo de temperatura na unidade escolhida. */
export function phaseCheckLabel(check) {
  if (check.metric === "temperature" && check.target !== null && check.target !== undefined) {
    return `Temperatura em ${f.temp(check.target, { digits: 0 })} ou mais`;
  }
  return check.label;
}

export function phaseTag(unit) {
  const phase = unit.phase;
  return h(
    "span",
    { class: `phase-tag phase-${phaseKey(unit.curing_stage) || "other"}` },
    h("span", { class: "phase-swatch", "aria-hidden": "true" }),
    phase ? `Fase ${phase.number} de ${phase.total} · ${unit.curing_stage}` : unit.curing_stage,
  );
}

/**
 * Valor grande de temperatura ou umidade com a faixa esperada. `compact` é a versão da lista.
 * Sem `limits` (nenhuma fase em andamento) não há faixa a mostrar.
 */
export function reading({ metric, value, limits, stale, compact = false, target = null }) {
  const isTemp = metric === "temperature";
  const min = limits ? (isTemp ? limits.temp_min : limits.humidity_min) : null;
  const max = limits ? (isTemp ? limits.temp_max : limits.humidity_max) : null;
  const state = limits ? rangeState(value, min, max) : null;
  const outside = !stale && (state === "high" || state === "low");
  const show = (v) => (isTemp ? f.tempValue(v) : v);
  const symbol = isTemp ? f.tempUnit() : "%";
  const expected = !limits ? null : isTemp ? f.tempRange(min, max) : f.humidityRange(min, max);
  const label = isTemp ? "Temperatura" : "Umidade";

  let meter = null;
  if (!compact && limits) {
    // Régua: faixa esperada destacada e marcador no valor atual.
    const lo = show(min);
    const hi = show(max);
    const span = hi - lo;
    const scaleMin = lo - span * 0.5;
    const scaleMax = hi + span * 0.5;
    const position = (v) => `${Math.min(100, Math.max(0, ((v - scaleMin) / (scaleMax - scaleMin)) * 100))}%`;
    meter = h(
      "div",
      { class: "meter", "aria-hidden": "true" },
      h("div", { class: "meter-safe", style: { left: position(lo), right: `calc(100% - ${position(hi)})` } }),
      value !== null && value !== undefined ? h("div", { class: `meter-marker ${outside ? "is-out" : ""}`, style: { left: position(show(value)) } }) : null,
    );
  }

  return h(
    "div",
    {
      class: `reading ${compact ? "is-compact" : ""} ${stale ? "is-stale" : ""} ${outside ? "is-out" : ""}`,
      role: "group",
      "aria-label": `${label}: ${f.number(show(value))} ${symbol}.${expected ? ` Esperado: ${expected}.` : ""}`,
    },
    h(
      "p",
      { class: "reading-label" },
      icon(isTemp ? "thermostat" : "water"),
      label,
      !compact && outside ? icon(state === "high" ? "arrowUp" : "arrowDown", "reading-trend") : null,
    ),
    h("p", { class: "reading-value" }, h("span", { class: "reading-number num" }, f.number(show(value))), h("span", { class: "reading-unit" }, symbol)),
    meter,
    target !== null && target !== undefined ? h("p", { class: "reading-target" }, `Alvo ${f.temp(target)}`) : null,
    h("p", { class: "reading-expected" }, expected ? `Esperado ${expected}` : "Sem fase em andamento"),
  );
}

export async function acknowledgeAlert(target, alert) {
  try {
    await withBusy(target, () => api.post(`/alerts/${alert.id}/acknowledge`));
    toast("Alerta reconhecido.", "success");
    return true;
  } catch (error) {
    toast(error.message, "error");
    return false;
  }
}

export async function resolveAlert(target, alert) {
  const confirmed = await confirmDialog({
    title: "Resolver alerta?",
    message: "Se o valor continuar fora da faixa, um novo alerta abre na próxima leitura.",
    confirmLabel: "Resolver",
  });
  if (!confirmed) return false;
  try {
    await withBusy(target, () => api.post(`/alerts/${alert.id}/resolve`));
    toast("Alerta resolvido.", "success");
    return true;
  } catch (error) {
    toast(error.message, "error");
    return false;
  }
}

/** Alerta com valor medido, limite e ações. `onChange` roda depois de reconhecer ou resolver. */
export function alertCard(alert, { onChange, showUnit = true } = {}) {
  const tone = !alert.is_active ? "is-resolved" : isSevere(alert) ? "is-critical" : "is-warning";
  const status = !alert.is_active ? "Resolvido" : alert.acknowledged_at ? `${severityLabel(alert)} · reconhecido` : severityLabel(alert);
  const isTemp = alert.type.startsWith("Temperatura");
  const value = (v) => (v === null || v === undefined ? "--" : isTemp ? f.temp(v) : f.humidity(v));
  const hasValues = alert.value !== null && alert.value !== undefined && alert.threshold !== null && alert.threshold !== undefined;
  const unitName = alert.curing_unit_name || `Estufa ${alert.curing_unit_id}`;

  return h(
    "article",
    { class: `alert-row ${tone}` },
    h(
      "p",
      { class: "alert-status" },
      icon(!alert.is_active ? "checkCircle" : isSevere(alert) ? "error" : "warning"),
      h("span", {}, status),
      h("span", { class: "alert-time", title: f.fullDate(alert.timestamp) }, f.relative(alert.timestamp)),
    ),
    h("h3", { class: "alert-title" }, showUnit ? `${alert.type} · ${unitName}` : alert.type),
    hasValues
      ? h("p", { class: "alert-values" }, h("strong", {}, value(alert.value)), h("span", {}, ` · limite ${value(alert.threshold)}`))
      : null,
    alert.message ? h("p", { class: "small text-2" }, alert.message) : null,
    !alert.is_active && alert.resolved_at ? h("p", { class: "small muted" }, `Encerrado em ${f.fullDate(alert.resolved_at)}`) : null,
    h(
      "div",
      { class: "row alert-actions" },
      alert.is_active
        ? button("Resolver", {
            variant: "btn-primary btn-sm",
            iconName: "check",
            onClick: async (event) => {
              if (await resolveAlert(event.currentTarget, alert)) onChange?.();
            },
          })
        : null,
      alert.is_active && !alert.acknowledged_at
        ? button("Reconhecer", {
            variant: "btn-outline btn-sm",
            iconName: "checkAll",
            onClick: async (event) => {
              if (await acknowledgeAlert(event.currentTarget, alert)) onChange?.();
            },
          })
        : null,
      showUnit ? h("a", { class: "card-link", href: `#/estufa/${alert.curing_unit_id}` }, "Abrir estufa", icon("chevronRight")) : null,
    ),
  );
}
