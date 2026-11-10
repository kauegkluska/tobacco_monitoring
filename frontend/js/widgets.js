// Peças de interface usadas em mais de uma tela: situação da estufa, leituras e alertas.

import { api } from "./api.js";
import { PHASES, isSevere, limitsFor, phaseKey, rangeState, severityLabel } from "./data.js";
import { badge, button, confirmDialog, h, icon, toast, withBusy } from "./dom.js";
import * as f from "./format.js";

/** Leituras mais antigas que isso aparecem apagadas. */
const STALE_MS = 5 * 60_000;

/**
 * A resposta para "preciso ir lá?": o selo da lista (`label`) e a frase do topo da estufa (`title`, `text`).
 * A conexão vem primeiro: sem dado novo, "Tudo certo" seria uma promessa falsa.
 */
export function unitStatus({ unit, device, latest, activeAlerts, criticalAlerts, sensorDoubt = false, message = null }) {
  if (!api.online) {
    return { rank: 0, kind: "offline", label: "Sem conexão", icon: "cloudOff", title: "Sem conexão com o monitor", text: "Os números abaixo podem estar velhos. Confira a internet." };
  }
  if (!device) return { rank: 8, kind: "neutral", label: "Sem sensor", icon: "linkOff", title: "Nenhum sensor nesta estufa", text: "Vincule o sensor para começar a acompanhar." };
  if (!unit.is_drying) {
    return unit.curing_stage === "Finalizado"
      ? { rank: 9, kind: "ok", label: "Finalizada", icon: "checkCircle", title: "Cura finalizada" }
      : { rank: 9, kind: "neutral", label: "Parada", icon: "stop", title: "Secagem parada", text: "O sistema não está acompanhando a estufa nem enviando avisos." };
  }
  if ((latest && isStale(latest, unit, device)) || (!latest && device.status !== "online")) {
    const since = latest ? f.relative(latest.timestamp) : device.last_seen_at ? f.relative(device.last_seen_at) : "ainda";
    return { rank: 1, kind: "offline", label: "Sem notícias", icon: "cloudOff", title: `Sem notícias da estufa ${since}`, text: "Veja se a caixa da estufa está ligada e se o Wi-Fi de casa funciona." };
  }
  if (criticalAlerts > 0) return { rank: 2, kind: "crit", label: "Vá à estufa", icon: "error", title: "Vá à estufa agora", text: message };
  if (sensorDoubt) return { rank: 3, kind: "warn", label: "Leitura duvidosa", icon: "help", title: "A leitura pode estar errada", text: message };
  if (activeAlerts > 0) return { rank: 4, kind: "warn", label: "Fique de olho", icon: "warning", title: "Fique de olho", text: message };
  if (!latest) return { rank: 7, kind: "neutral", label: "Aguardando", icon: "clock", title: "Aguardando a primeira leitura" };
  const limits = limitsFor(unit, device);
  const outside =
    rangeState(latest.temperature, limits.temp_min, limits.temp_max) !== "ok" ||
    rangeState(latest.humidity, limits.humidity_min, limits.humidity_max) !== "ok";
  if (outside) return { rank: 5, kind: "warn", label: "Fora do esperado", icon: "tune", title: "Fique de olho", text: "A temperatura ou a umidade saiu do esperado para a fase." };
  if (unit.phase?.ready) {
    const finishing = unit.phase.next_stage === "Finalizado";
    return { rank: 6, kind: "ok", label: "Pode avançar", icon: "chevronRight", title: finishing ? "Já dá para finalizar a cura" : "Já dá para passar de fase", text: `Olhe as folhas: ${unit.phase.visual_check}` };
  }
  return { rank: 7, kind: "ok", label: "Tudo certo", icon: "check", title: "Tudo certo" };
}

/** O alerta que vira a frase do topo: o mais grave, sem contar os informativos. */
export function featuredAlert(alerts) {
  const weight = (alert) => (isSevere(alert) ? 0 : alert.type === "Sensor suspeito" ? 1 : 2);
  return [...alerts].filter((alert) => alert.severity !== "info").sort((a, b) => weight(a) - weight(b))[0] || null;
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

/** As quatro fases em sequência: concluídas, a atual (`current`, 1 a 4) em destaque e as próximas apagadas. */
export function phaseSteps(current, finished) {
  return h(
    "ol",
    { class: "phase-steps", "aria-label": "Fases da cura" },
    PHASES.map((item, index) => {
      const number = index + 1;
      const status = finished || (current && number < current) ? "is-done" : number === current ? "is-current" : "";
      return h(
        "li",
        { class: `phase-step phase-${item.key} ${status}`, "aria-current": status === "is-current" ? "step" : null },
        h("span", { class: "phase-step-bar", "aria-hidden": "true" }),
        h("span", { class: "phase-step-name" }, status === "is-done" ? icon("check") : null, item.name),
      );
    }),
  );
}

/**
 * Valor grande de temperatura ou umidade com a faixa esperada. `compact` é a versão da lista.
 * Sem `limits` (nenhuma fase em andamento) não há faixa a mostrar.
 *
 * A umidade aparece como bulbo úmido estimado (`value` em °C), como no termômetro molhado da estufa e nos guias de
 * cura; a umidade relativa medida pelo sensor (`relativeHumidity`) fica na linha de baixo. Ela só tem teto, e só nas
 * fases com o alerta "Umidade alta".
 */
export function reading({ metric, value, limits, stale, compact = false, target = null, relativeHumidity = null }) {
  const isTemp = metric === "temperature";
  const min = limits && isTemp ? limits.temp_min : null;
  const max = limits ? (isTemp ? limits.temp_max : limits.wet_bulb_max ?? null) : null;
  const hasValue = value !== null && value !== undefined;
  const state = max === null ? null : min === null ? (hasValue && value > max ? "high" : "ok") : rangeState(value, min, max);
  const outside = !stale && (state === "high" || state === "low");
  const show = (v) => f.tempValue(v);
  const symbol = f.tempUnit();
  const expected = max === null ? null : isTemp ? f.tempRange(min, max) : `até ${f.temp(max)}`;
  const label = isTemp ? "Temperatura" : "Umidade";
  const relative = isTemp ? null : `Bulbo úmido estimado · UR ${f.humidity(relativeHumidity, 0)}`;

  let meter = null;
  if (!compact && isTemp && limits) {
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
      "aria-label": `${label}: ${f.number(show(value))} ${symbol}${relative ? ` (${relative})` : ""}.${expected ? ` Esperado: ${expected}.` : ""}`,
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
    relative ? h("p", { class: "reading-expected" }, relative) : null,
    target !== null && target !== undefined ? h("p", { class: "reading-target" }, `Alvo ${f.temp(target)}`) : null,
    // Fase sem teto do bulbo úmido (Amarelação, Secagem do talo): nada a comparar na umidade.
    expected || !limits ? h("p", { class: "reading-expected" }, expected ? `Esperado ${expected}` : "Sem fase em andamento") : null,
  );
}

/** "Estou ciente" mantém o alerta aberto. Na queda de temperatura, aceita o novo nível e encerra. */
export async function acknowledgeAlert(target, alert) {
  if (alert.type === "Temperatura em queda") {
    const confirmed = await confirmDialog({
      title: "Você baixou de propósito?",
      message: "O alerta será encerrado e esta temperatura passa a ser a referência. Se a fornalha estiver apagando, não confirme.",
      confirmLabel: "Baixei de propósito",
    });
    if (!confirmed) return false;
  }
  try {
    await withBusy(target, () => api.post(`/alerts/${alert.id}/acknowledge`));
    toast("Anotado.", "success");
    return true;
  } catch (error) {
    toast(error.message, "error");
    return false;
  }
}

export async function resolveAlert(target, alert) {
  const confirmed = await confirmDialog({
    title: "Encerrar este alerta?",
    message: "Use só se o problema já acabou. Se continuar, um novo alerta abre sozinho.",
    confirmLabel: "Encerrar",
  });
  if (!confirmed) return false;
  try {
    await withBusy(target, () => api.post(`/alerts/${alert.id}/resolve`));
    toast("Alerta encerrado.", "success");
    return true;
  } catch (error) {
    toast(error.message, "error");
    return false;
  }
}

/** Botões de um alerta ativo: uma ação principal e, discreto, encerrar à mão. */
export function alertActions(alert, onChange) {
  if (!alert.is_active || alert.severity === "info") return [];
  const acknowledge = !alert.acknowledged_at
    ? button(alert.type === "Temperatura em queda" ? "Baixei de propósito" : "Estou ciente", {
        variant: "btn-primary btn-sm",
        iconName: "check",
        onClick: async (event) => {
          if (await acknowledgeAlert(event.currentTarget, alert)) onChange?.();
        },
      })
    : null;
  const close = button("Encerrar", {
    variant: "btn-ghost btn-sm",
    onClick: async (event) => {
      if (await resolveAlert(event.currentTarget, alert)) onChange?.();
    },
  });
  return [acknowledge, close].filter(Boolean);
}

/** Alerta com a orientação em destaque; os valores ficam discretos. `onChange` roda depois de uma ação. */
export function alertCard(alert, { onChange, showUnit = true } = {}) {
  const info = alert.severity === "info";
  const tone = !alert.is_active ? "is-resolved" : isSevere(alert) ? "is-critical" : info ? "is-resolved" : "is-warning";
  const status = !alert.is_active ? "Encerrado" : alert.acknowledged_at ? `${severityLabel(alert)} · ciente` : severityLabel(alert);
  // "Umidade alta" guarda o bulbo úmido estimado, que é uma temperatura.
  const wetBulb = alert.type === "Umidade alta";
  const isTemp = alert.type.startsWith("Temperatura") || wetBulb;
  const value = (v) => (v === null || v === undefined ? "--" : isTemp ? f.temp(v) : f.humidity(v));
  const hasValues = alert.value !== null && alert.value !== undefined && alert.threshold !== null && alert.threshold !== undefined;
  const limitLabel = alert.type === "Temperatura em queda" ? "alerta abaixo de" : alert.type.endsWith("alta") ? "máximo" : "mínimo";
  const unitName = alert.curing_unit_name || `Estufa ${alert.curing_unit_id}`;

  return h(
    "article",
    { class: `alert-row ${tone}` },
    h(
      "p",
      { class: "alert-status" },
      icon(!alert.is_active ? "checkCircle" : isSevere(alert) ? "error" : info ? "help" : "warning"),
      h("span", {}, status),
      h("span", { class: "alert-time", title: f.fullDate(alert.timestamp) }, f.relative(alert.timestamp)),
    ),
    h("h3", { class: "alert-title" }, showUnit ? `${alert.type} · ${unitName}` : alert.type),
    alert.message ? h("p", { class: "text-2" }, alert.message) : null,
    alert.details
      ? h("p", { class: "small muted" }, f.details(alert.details))
      : hasValues
        ? h("p", { class: "small muted" }, `${wetBulb ? "Bulbo úmido" : "Agora"} ${value(alert.value)} · ${limitLabel} ${value(alert.threshold)}`)
        : null,
    !alert.is_active && alert.resolved_at ? h("p", { class: "small muted" }, `Encerrado em ${f.fullDate(alert.resolved_at)}`) : null,
    h(
      "div",
      { class: "row alert-actions" },
      alertActions(alert, onChange),
      showUnit ? h("a", { class: "card-link", href: `#/estufa/${alert.curing_unit_id}` }, "Abrir estufa", icon("chevronRight")) : null,
    ),
  );
}
