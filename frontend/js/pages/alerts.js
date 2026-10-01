// Alertas de todas as estufas, com filtro por estado, estufa e gravidade.

import { api } from "../api.js";
import { SEVERITIES } from "../data.js";
import { banner, button, clear, emptyState, h, loadingState, select } from "../dom.js";
import { alertCard } from "../widgets.js";

const POLL_MS = 5000;
const TABS = [
  { value: "active", label: "Ativos" },
  { value: "resolved", label: "Resolvidos" },
  { value: "all", label: "Todos" },
];

export function renderAlerts(ctx) {
  const root = h("div", { class: "page" }, loadingState());
  const state = { tab: "active", unit: "all", severity: "all", alerts: null, units: [] };
  let timer = null;
  let destroyed = false;

  async function load() {
    try {
      const [alerts, units] = await Promise.all([api.get("/alerts/?limit=500"), api.get("/curing_units/")]);
      if (destroyed) return;
      state.alerts = alerts;
      state.units = units;
      ctx.setAlertCount(alerts.filter((alert) => alert.is_active).length);
      if (!document.querySelector("dialog[open]") && !root.contains(document.activeElement?.closest("select"))) draw();
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

  const inTab = (alert, tab) => (tab === "active" ? alert.is_active : tab === "resolved" ? !alert.is_active : true);

  function draw() {
    const filtered = state.alerts.filter(
      (alert) =>
        (state.unit === "all" || String(alert.curing_unit_id) === state.unit) && (state.severity === "all" || alert.severity === state.severity),
    );
    const list = filtered.filter((alert) => inTab(alert, state.tab));

    const tabs = h(
      "div",
      { class: "tabs", role: "tablist", "aria-label": "Estado" },
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
          h("span", { class: "tab-count" }, String(filtered.filter((alert) => inTab(alert, tab.value)).length)),
        ),
      ),
    );

    const filter = (key, label, options) =>
      select([{ value: "all", label }, ...options], state[key], {
        "aria-label": label,
        onChange: (event) => {
          state[key] = event.target.value;
          draw();
        },
      });

    clear(
      root,
      h(
        "div",
        { class: "filters" },
        tabs,
        state.units.length > 1 ? filter("unit", "Todas as estufas", state.units.map((unit) => ({ value: String(unit.id), label: unit.name }))) : null,
        filter("severity", "Todas as gravidades", SEVERITIES),
      ),
      list.length
        ? h("div", { class: "grid grid-3" }, list.map((alert) => alertCard(alert, { onChange: load })))
        : h("section", { class: "card" }, emptyState(state.tab === "active" ? "checkCircle" : "bell", state.tab === "active" ? "Nenhum alerta ativo" : "Nenhum alerta")),
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
