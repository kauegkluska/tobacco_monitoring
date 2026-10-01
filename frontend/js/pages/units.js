// Tela inicial: um cartão por estufa com temperatura, umidade e situação.

import { api } from "../api.js";
import { limitsFor, loadOverview } from "../data.js";
import { banner, button, clear, confirmDialog, emptyState, field, h, icon, loadingState, openModal, toast } from "../dom.js";
import * as f from "../format.js";
import { prefs } from "../store.js";
import { isStale, phaseTag, reading, statusBadge, unitStatus } from "../widgets.js";

const POLL_MS = 5000;

/** Cadastra uma estufa e abre a tela dela. */
export function createUnit(ctx, count = 0) {
  const name = h("input", { class: "input", value: `Estufa ${String(count + 1).padStart(2, "0")}`, maxlength: 100, required: true });
  openModal({
    title: "Nova estufa",
    body: h("div", { class: "form" }, field({ label: "Nome", input: name })),
    actions: [
      { label: "Cancelar" },
      {
        label: "Cadastrar",
        variant: "btn-primary",
        onClick: async (close) => {
          if (!name.value.trim()) throw new Error("Informe o nome.");
          const unit = await api.post("/curing_units/", { name: name.value.trim() });
          close();
          ctx.navigate(`#/estufa/${unit.id}`);
        },
      },
    ],
  });
}

export function renderUnits(ctx) {
  const root = h("div", { class: "page" }, loadingState());
  let data = null;
  let timer = null;
  let destroyed = false;

  async function load() {
    try {
      data = await loadOverview();
      if (destroyed) return;
      ctx.setAlertCount(data.units.reduce((sum, unit) => sum + (unit.active_alerts || 0), 0));
      if (!document.querySelector("dialog[open]")) draw();
    } catch (error) {
      if (destroyed) return;
      if (!data) clear(root, banner("crit", "cloudOff", "Não foi possível carregar as estufas", error.message, [button("Tentar de novo", { onClick: load })]));
    } finally {
      if (!destroyed) {
        clearTimeout(timer);
        timer = setTimeout(load, POLL_MS);
      }
    }
  }

  function draw() {
    const { units, devices, devicesById } = data;
    const loose = devices.filter((device) => !device.curing_unit_id);
    const add = () => createUnit(ctx, units.length);

    clear(
      root,
      units.length
        ? h("div", { class: "grid grid-3" }, units.map((unit) => unitCard(unit, unit.device_id ? devicesById.get(unit.device_id) : null)))
        : h("section", { class: "card" }, emptyState("warehouse", "Nenhuma estufa", "Cadastre a estufa e vincule o sensor dela.", [button("Nova estufa", { variant: "btn-primary", iconName: "add", onClick: add })])),
      units.length ? h("div", {}, button("Nova estufa", { variant: "btn-outline", iconName: "add", onClick: add })) : null,
      loose.length
        ? h(
            "section",
            {},
            h("h2", { class: "section-heading" }, "Sensores sem estufa"),
            h(
              "div",
              { class: "card list-card" },
              loose.map((device) =>
                h(
                  "div",
                  { class: "list-row" },
                  icon("sensors"),
                  h("div", { class: "list-row-body" }, h("strong", { class: "num" }, device.device_code), h("span", { class: "small muted" }, device.status === "online" ? "Online" : `Último contato ${f.relative(device.last_seen_at)}`)),
                  button("", { variant: "btn-ghost btn-icon btn-icon-danger", iconName: "linkOff", "aria-label": `Desvincular ${device.device_code}`, onClick: () => unlink(device) }),
                ),
              ),
            ),
          )
        : null,
    );
  }

  function unitCard(unit, device) {
    const latest = unit.latest;
    const stale = isStale(latest, unit, device);
    const limits = unit.phase ? limitsFor(unit, device) : null;
    const status = unitStatus({ unit, device, latest, activeAlerts: unit.active_alerts || 0, criticalAlerts: unit.critical_alerts || 0 });
    const footer = [latest ? `Leitura ${f.relative(latest.timestamp)}` : "Sem leituras"];
    if (unit.active_alerts) footer.push(f.plural(unit.active_alerts, "alerta ativo", "alertas ativos"));

    return h(
      "a",
      { class: "card unit-card", href: `#/estufa/${unit.id}` },
      h("div", { class: "unit-card-head" }, h("h2", {}, unit.name), statusBadge(status), icon("chevronRight", "unit-card-chevron")),
      phaseTag(unit),
      h(
        "div",
        { class: "readings" },
        reading({ metric: "temperature", value: latest?.temperature, limits, stale, compact: true }),
        reading({ metric: "humidity", value: latest?.humidity, limits, stale, compact: true }),
      ),
      h("p", { class: `unit-card-foot ${unit.critical_alerts ? "is-crit" : unit.active_alerts ? "is-warn" : ""}` }, footer.join(" · ")),
    );
  }

  async function unlink(device) {
    const confirmed = await confirmDialog({
      title: `Desvincular ${device.device_code}?`,
      message: "O sensor sai da sua conta. Você pode vinculá-lo de novo depois.",
      confirmLabel: "Desvincular",
      danger: true,
    });
    if (!confirmed) return;
    try {
      await api.del(`/devices/${device.id}`);
      toast("Sensor desvinculado.", "success");
      load();
    } catch (error) {
      toast(error.message, "error");
    }
  }

  const unsubscribe = prefs.subscribe((changes) => {
    if ("unit" in changes && data) draw();
  });

  load();
  return {
    el: root,
    destroy() {
      destroyed = true;
      clearTimeout(timer);
      unsubscribe();
    },
  };
}
