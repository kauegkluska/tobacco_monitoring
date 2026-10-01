// Central de alertas: ativos, resolvidos e todos, com reconhecer e resolver.

import { api } from "../api.js";
import { isSevere, severityInfo } from "../data.js";
import { badge, banner, button, clear, confirmDialog, emptyState, h, icon, loadingState, select, toast, withBusy } from "../dom.js";
import * as f from "../format.js";

const POLL_MS = 3000;
const TABS = [
  { value: "active", label: "Ativos" },
  { value: "resolved", label: "Resolvidos" },
  { value: "all", label: "Todos" },
];

export function renderAlerts(ctx) {
  const root = h("div", { class: "page" }, loadingState("Carregando alertas…"));
  const state = { tab: "active", unitFilter: "all", alerts: null, units: [] };
  let timer = null;
  let destroyed = false;

  async function load() {
    try {
      const [alerts, units] = await Promise.all([api.get("/alerts/?limit=500"), api.get("/curing_units/")]);
      if (destroyed) return;
      state.alerts = alerts;
      state.units = units;
      ctx.setAlertCount(alerts.filter((alert) => alert.is_active).length);
      draw();
    } catch (error) {
      if (destroyed) return;
      if (!state.alerts) clear(root, banner("crit", "cloudOff", "Não foi possível carregar os alertas", error.message, [button("Tentar de novo", { onClick: load })]));
    } finally {
      if (!destroyed) {
        clearTimeout(timer);
        timer = setTimeout(load, POLL_MS);
      }
    }
  }

  function filtered() {
    return state.alerts.filter((alert) => {
      if (state.unitFilter !== "all" && String(alert.curing_unit_id) !== state.unitFilter) return false;
      if (state.tab === "active") return alert.is_active;
      if (state.tab === "resolved") return !alert.is_active;
      return true;
    });
  }

  function draw() {
    const byUnit = state.unitFilter === "all" ? state.alerts : state.alerts.filter((alert) => String(alert.curing_unit_id) === state.unitFilter);
    const counts = {
      active: byUnit.filter((alert) => alert.is_active).length,
      resolved: byUnit.filter((alert) => !alert.is_active).length,
      all: byUnit.length,
    };
    const critical = byUnit.filter((alert) => alert.is_active && isSevere(alert)).length;

    const tabs = h(
      "div",
      { class: "tabs", role: "tablist", "aria-label": "Filtrar alertas" },
      TABS.map((tab) =>
        h(
          "button",
          {
            class: "tab",
            type: "button",
            role: "tab",
            "aria-selected": String(state.tab === tab.value),
            onClick: () => {
              state.tab = tab.value;
              draw();
            },
          },
          tab.label,
          h("span", { class: "tab-count" }, String(counts[tab.value])),
        ),
      ),
    );

    const unitSelect =
      state.units.length > 1
        ? select([{ value: "all", label: "Todas as estufas" }, ...state.units.map((unit) => ({ value: String(unit.id), label: unit.name }))], state.unitFilter, {
            "aria-label": "Estufa",
            onChange: (event) => {
              state.unitFilter = event.target.value;
              draw();
            },
          })
        : null;

    const list = filtered();
    const emptyTexts = {
      active: ["Nenhum alerta ativo", "Todas as estufas estão dentro dos limites definidos. Os alertas aparecem aqui assim que algum valor sair da faixa."],
      resolved: ["Nenhum alerta resolvido", "Alertas encerrados aparecem aqui, automaticamente ou quando você os resolve."],
      all: ["Nenhum alerta registrado", "Os alertas são criados quando a temperatura ou a umidade saem da faixa segura."],
    };

    clear(
      root,
      h(
        "div",
        { class: "page-header" },
        h("div", {}, h("p", { class: "eyebrow" }, "Central de alertas"), h("h1", {}, "Ocorrências"), h("p", { class: "page-subtitle" }, "Um alerta abre quando um valor sai da faixa segura e fecha sozinho quando ele volta ao normal.")),
        critical ? badge("crit", f.plural(critical, "crítico", "críticos"), "error") : null,
      ),
      h("div", { class: "filters" }, tabs, unitSelect),
      list.length
        ? h("div", { class: "grid grid-3" }, list.map(alertCard))
        : h("section", { class: "card" }, emptyState(state.tab === "active" ? "checkCircle" : "bell", ...emptyTexts[state.tab])),
    );
  }

  function describeValue(alert, value) {
    if (value === null || value === undefined) return "--";
    return alert.type.startsWith("Temperatura") ? f.tempWithOther(value) : f.humidity(value);
  }

  function alertCard(alert) {
    const info = severityInfo(alert);
    const isHigh = alert.type.endsWith("alta");
    const expected = alert.threshold === null || alert.threshold === undefined ? "--" : `${isHigh ? "Até" : "A partir de"} ${describeValue(alert, alert.threshold)}`;

    const acknowledge = button(alert.acknowledged_at ? "Reconhecido" : "Reconhecer", {
      variant: "btn-outline",
      iconName: "checkAll",
      disabled: Boolean(alert.acknowledged_at) || !alert.is_active,
      onClick: async (event) => {
        try {
          await withBusy(event.currentTarget, () => api.post(`/alerts/${alert.id}/acknowledge`));
          toast("Alerta reconhecido. Ele continua ativo até o valor normalizar.", "success");
          load();
        } catch (error) {
          toast(error.message, "error");
        }
      },
    });

    const resolve = alert.is_active
      ? button("Resolver", {
          variant: "btn-primary",
          iconName: "check",
          onClick: async (event) => {
            const confirmed = await confirmDialog({
              title: "Encerrar este alerta?",
              message: "Use quando o problema já foi tratado. Se o valor continuar fora da faixa, um novo alerta será aberto na próxima leitura.",
              confirmLabel: "Resolver",
            });
            if (!confirmed) return;
            try {
              await withBusy(event.currentTarget, () => api.post(`/alerts/${alert.id}/resolve`));
              toast("Alerta resolvido.", "success");
              load();
            } catch (error) {
              toast(error.message, "error");
            }
          },
        })
      : button("Ver estufa", {
          variant: "btn-outline",
          iconName: "chart",
          onClick: () => {
            ctx.selectUnit(alert.curing_unit_id);
            ctx.navigate("#/historico");
          },
        });

    return h(
      "article",
      { class: `card alert-card ${info.className}` },
      h(
        "div",
        { class: "alert-head" },
        h("span", { class: "alert-icon" }, icon(info.icon)),
        h(
          "div",
          { style: { minWidth: 0, flex: 1 } },
          h("div", { class: "row" }, badge(info.kind, info.label, info.icon), alert.acknowledged_at && alert.is_active ? badge("neutral", "Reconhecido", "checkAll") : null),
          h("h3", { class: "alert-title" }, `${alert.type} · ${alert.curing_unit_name || `Estufa ${alert.curing_unit_id}`}`),
        ),
        h("span", { class: "alert-time", title: f.fullDate(alert.timestamp) }, f.relative(alert.timestamp)),
      ),
      h("p", { class: "text-2", style: { marginTop: "10px" } }, alert.message),
      h(
        "dl",
        { class: "alert-compare" },
        h("div", {}, h("dt", {}, icon("flag"), "Esperado"), h("dd", {}, expected)),
        h("div", {}, h("dt", {}, icon("warning"), "Encontrado"), h("dd", { class: alert.is_active ? "is-bad" : "" }, describeValue(alert, alert.value))),
      ),
      h(
        "p",
        { class: "small muted", style: { marginTop: "10px" } },
        `Aberto em ${f.fullDate(alert.timestamp)}`,
        alert.resolved_at ? ` · encerrado em ${f.fullDate(alert.resolved_at)}` : "",
      ),
      h("div", { class: "alert-actions" }, acknowledge, resolve),
    );
  }

  load();
  return {
    el: root,
    destroy() {
      destroyed = true;
      clearTimeout(timer);
    },
  };
}
