// Estufas e dispositivos: cadastro, vínculo do sensor ESP32, limites e desvínculo.

import { api } from "../api.js";
import { loadOverview, signalQuality, stageOptions } from "../data.js";
import {
  badge,
  banner,
  button,
  clear,
  confirmDialog,
  emptyState,
  field,
  h,
  icon,
  loadingState,
  openModal,
  select,
  toast,
  withBusy,
} from "../dom.js";
import * as f from "../format.js";
import { prefs } from "../store.js";

const POLL_MS = 3000;

export function renderUnits(ctx) {
  const root = h("div", { class: "page" }, loadingState("Carregando estufas e dispositivos…"));
  let data = null;
  let timer = null;
  let destroyed = false;
  let handledQuery = false;

  async function load() {
    try {
      data = await loadOverview();
      if (destroyed) return;
      if (!document.querySelector("dialog[open]")) draw();
      if (!handledQuery) {
        handledQuery = true;
        const query = ctx.query;
        if (query.get("nova")) createUnit();
        else if (query.get("vincular")) linkDevice(Number(query.get("vincular")));
      }
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
    clear(
      root,
      h(
        "div",
        { class: "page-header" },
        h("div", {}, h("p", { class: "eyebrow" }, "Cadastro"), h("h1", {}, "Estufas e dispositivos"), h("p", { class: "page-subtitle" }, "Cada estufa recebe as leituras de um sensor ESP32 (sender). O gateway (receiver) repassa os dados para o servidor.")),
        h("div", { class: "row" }, button("Nova estufa", { variant: "btn-primary", iconName: "add", onClick: createUnit }), button("Vincular dispositivo", { variant: "btn-outline", iconName: "link", onClick: () => linkDevice() })),
      ),
      h(
        "section",
        {},
        h("div", { class: "section-title" }, h("h2", {}, `Estufas (${units.length})`)),
        units.length
          ? h("div", { class: "grid grid-3" }, units.map((unit) => unitCard(unit, unit.device_id ? devicesById.get(unit.device_id) : null)))
          : h("div", { class: "card" }, emptyState("warehouse", "Nenhuma estufa cadastrada", "Comece cadastrando a estufa que será monitorada.", [button("Nova estufa", { variant: "btn-primary", iconName: "add", onClick: createUnit })])),
      ),
      h(
        "section",
        {},
        h("div", { class: "section-title" }, h("h2", {}, `Dispositivos (${devices.length})`)),
        devices.length
          ? h("div", { class: "grid grid-3" }, devices.map(deviceCard))
          : h("div", { class: "card" }, emptyState("sensors", "Nenhum dispositivo vinculado", "Use o ID do controlador mostrado no display do sender (ex.: ESP32-TOBACCO-01).", [button("Vincular dispositivo", { variant: "btn-primary", iconName: "link", onClick: () => linkDevice() })])),
      ),
    );
  }

  function unitCard(unit, device) {
    return h(
      "article",
      { class: "card entity-card" },
      h(
        "div",
        { class: "entity-head" },
        h("span", { class: "entity-icon" }, icon("warehouse")),
        h("div", { class: "entity-title" }, h("h3", {}, unit.name), h("p", { class: "small muted" }, unit.curing_stage)),
        unit.is_drying ? badge("ok", "Secando") : badge("neutral", "Parada", "stop"),
      ),
      h(
        "dl",
        { class: "details" },
        h("div", {}, h("dt", {}, "Sensor"), h("dd", {}, device ? device.device_code : "Nenhum")),
        h("div", {}, h("dt", {}, "Situação do sensor"), h("dd", {}, !device ? "--" : device.status === "online" ? "Online" : device.last_seen_at ? `Offline (${f.relative(device.last_seen_at)})` : "Aguardando primeira leitura")),
        h("div", {}, h("dt", {}, "Duração prevista"), h("dd", {}, unit.estimated_duration_hours ? f.duration(unit.estimated_duration_hours) : "Não definida")),
        h("div", {}, h("dt", {}, "Secagem iniciada"), h("dd", {}, unit.drying_started_at ? f.dateTime(unit.drying_started_at) : "--")),
      ),
      h(
        "div",
        { class: "entity-actions" },
        button("Painel", {
          variant: "btn-sm",
          iconName: "dashboard",
          onClick: () => {
            prefs.set({ unitId: unit.id });
            ctx.navigate("#/inicio");
          },
        }),
        device ? null : button("Vincular sensor", { variant: "btn-sm btn-primary", iconName: "link", onClick: () => linkDevice(unit.id) }),
        button("Editar", { variant: "btn-sm btn-outline", iconName: "edit", onClick: () => editUnit(unit) }),
        button("", { variant: "btn-sm btn-ghost btn-icon btn-icon-danger", iconName: "delete", "aria-label": `Excluir ${unit.name}`, onClick: () => deleteUnit(unit) }),
      ),
    );
  }

  function deviceCard(device) {
    const online = device.status === "online";
    const batteryLow = device.battery_level !== null && device.battery_level <= 25;
    return h(
      "article",
      { class: "card entity-card" },
      h(
        "div",
        { class: "entity-head" },
        h("span", { class: "entity-icon" }, icon("sensors")),
        h("div", { class: "entity-title" }, h("h3", { class: "num" }, device.device_code), h("p", { class: "small muted" }, device.curing_unit_name ? `Estufa: ${device.curing_unit_name}` : "Sem estufa vinculada")),
        online ? badge("ok", "Online") : badge("offline", "Offline", "cloudOff"),
      ),
      h(
        "div",
        { class: "metrics" },
        h("div", { class: "metric" }, h("p", { class: "metric-label" }, icon("signal"), "Sinal LoRa"), h("p", { class: "metric-value num" }, device.rssi === null ? "--" : `${device.rssi} dBm`), h("p", { class: "metric-sub" }, signalQuality(device.rssi))),
        h("div", { class: "metric" }, h("p", { class: "metric-label" }, icon("battery"), "Bateria"), h("p", { class: "metric-value num" }, device.battery_level === null ? "--" : `${device.battery_level}%`), h("p", { class: "metric-sub" }, device.battery_level === null ? "Não informada" : batteryLow ? "Baixa" : "Normal")),
        h("div", { class: "metric" }, h("p", { class: "metric-label" }, icon("clock"), "Último contato"), h("p", { class: "metric-value" }, f.relative(device.last_seen_at)), h("p", { class: "metric-sub" }, device.last_seen_at ? f.time(device.last_seen_at) : "Nunca enviou")),
      ),
      h(
        "dl",
        { class: "details" },
        h("div", {}, h("dt", {}, "Endereço MAC"), h("dd", { class: "num" }, device.mac_address || "Não informado")),
        h("div", {}, h("dt", {}, "Modelo"), h("dd", {}, device.hardware_model || "--")),
      ),
      h(
        "div",
        { class: "entity-actions" },
        button("Verificar", {
          variant: "btn-sm btn-outline",
          iconName: "refresh",
          onClick: async (event) => {
            try {
              const result = await withBusy(event.currentTarget, () => api.post(`/devices/${device.id}/reconnect`));
              if (result.status === "online") toast(`${device.device_code} está online e enviando leituras.`, "success");
              else toast(`${device.device_code} continua sem sinal. Confira a alimentação do sender e o gateway.`, "error");
              load();
            } catch (error) {
              toast(error.message, "error");
            }
          },
        }),
        button("", { variant: "btn-sm btn-ghost btn-icon btn-icon-danger", iconName: "linkOff", "aria-label": `Desvincular ${device.device_code}`, onClick: () => unlinkDevice(device) }),
      ),
    );
  }

  function unitForm(unit = {}) {
    const name = h("input", { class: "input", value: unit.name || `Estufa ${String((data?.units.length || 0) + 1).padStart(2, "0")}`, maxlength: 100, required: true });
    const stage = select(stageOptions(unit.curing_stage || "Não iniciado"), unit.curing_stage || "Não iniciado");
    const hours = h("input", { class: "input num", type: "number", min: 1, max: 1000, step: 1, value: unit.estimated_duration_hours ?? "" });
    return {
      element: h(
        "div",
        { class: "form" },
        field({ label: "Nome da estufa", input: name }),
        field({ label: "Fase da cura", input: stage }),
        field({ label: "Duração prevista (opcional)", input: hours, suffix: "horas", hint: "Usada para calcular o término previsto da secagem." }),
      ),
      values() {
        if (!name.value.trim()) throw new Error("Informe o nome da estufa.");
        const payload = { name: name.value.trim(), curing_stage: stage.value };
        if (hours.value) payload.estimated_duration_hours = Number(hours.value);
        return payload;
      },
    };
  }

  function createUnit() {
    const form = unitForm();
    openModal({
      title: "Nova estufa",
      body: form.element,
      actions: [
        { label: "Cancelar" },
        {
          label: "Cadastrar",
          variant: "btn-primary",
          onClick: async (close) => {
            const unit = await api.post("/curing_units/", form.values());
            prefs.set({ unitId: unit.id });
            toast(`${unit.name} cadastrada. Agora vincule o sensor.`, "success");
            close();
            await load();
            linkDevice(unit.id);
          },
        },
      ],
    });
  }

  function editUnit(unit) {
    const form = unitForm(unit);
    openModal({
      title: `Editar ${unit.name}`,
      body: form.element,
      actions: [
        { label: "Cancelar" },
        {
          label: "Salvar",
          variant: "btn-primary",
          onClick: async (close) => {
            await api.patch(`/curing_units/${unit.id}`, form.values());
            toast("Estufa atualizada.", "success");
            close();
            load();
          },
        },
      ],
    });
  }

  async function deleteUnit(unit) {
    const confirmed = await confirmDialog({
      title: `Excluir ${unit.name}?`,
      message: "Só é possível excluir estufas sem histórico de leituras. Esta ação não pode ser desfeita.",
      confirmLabel: "Excluir",
      danger: true,
    });
    if (!confirmed) return;
    try {
      await api.del(`/curing_units/${unit.id}`);
      toast("Estufa excluída.", "success");
      load();
    } catch (error) {
      toast(error.message, "error");
    }
  }

  function linkDevice(unitId = null) {
    const units = data?.units || [];
    const code = h("input", { class: "input num", placeholder: "ESP32-TOBACCO-01", autocapitalize: "characters", maxlength: 100 });
    const mac = h("input", { class: "input num", placeholder: "24:6F:28:B1:09:4A (opcional)", maxlength: 50 });
    const unitSelect = select(
      [{ value: "", label: "Nenhuma por enquanto" }, ...units.map((unit) => ({ value: String(unit.id), label: unit.name }))],
      unitId ? String(unitId) : units.length === 1 ? String(units[0].id) : "",
    );
    openModal({
      title: "Vincular dispositivo ESP32",
      body: h(
        "div",
        { class: "form" },
        h("p", { class: "text-2" }, "O ID do controlador é o CONTROLLER_ID gravado no sender. Ele aparece no display ao ligar e no monitor serial."),
        field({ label: "ID do controlador", input: code }),
        field({ label: "Endereço MAC", input: mac, hint: "Só é necessário se você não souber o ID." }),
        field({ label: "Estufa que vai receber as leituras", input: unitSelect }),
      ),
      actions: [
        { label: "Cancelar" },
        {
          label: "Vincular",
          variant: "btn-primary",
          icon: "link",
          onClick: async (close) => {
            if (!code.value.trim() && !mac.value.trim()) throw new Error("Informe o ID do controlador ou o endereço MAC.");
            const payload = { controller_id: code.value.trim() || null, mac_address: mac.value.trim() || null };
            if (unitSelect.value) payload.curing_unit_id = Number(unitSelect.value);
            const device = await api.post("/devices/link", payload);
            toast(`${device.device_code} vinculado${device.curing_unit_name ? ` à ${device.curing_unit_name}` : ""}.`, "success");
            close();
            load();
          },
        },
      ],
    });
  }

  async function unlinkDevice(device) {
    const confirmed = await confirmDialog({
      title: `Desvincular ${device.device_code}?`,
      message: "A estufa e todo o histórico continuam salvos, mas deixam de receber leituras deste sensor. Você pode vinculá-lo de novo depois.",
      confirmLabel: "Desvincular",
      danger: true,
    });
    if (!confirmed) return;
    try {
      await api.del(`/devices/${device.id}`);
      toast("Dispositivo desvinculado.", "success");
      load();
    } catch (error) {
      toast(error.message, "error");
    }
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
