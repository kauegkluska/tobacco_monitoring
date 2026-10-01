// Início: situação atual da estufa em linguagem simples.

import { api } from "../api.js";
import { OUTPUT_TRIGGERS, describeOutputEvent } from "../buzzer.js";
import { lineChart, phaseLegend } from "../chart.js";
import { PHASES, chartPhases, isSevere, limitsFor, loadOverview, phaseKey, pickUnit, rangeState, severityInfo, stageOptions } from "../data.js";
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
  segmented,
  select,
  toast,
  withBusy,
} from "../dom.js";
import * as f from "../format.js";
import { prefs } from "../store.js";

const POLL_MS = 3000;
const SERIES_REFRESH_MS = 60_000;
const CHART_HOURS = 6;

export function renderDashboard(ctx) {
  const root = h("div", { class: "page" }, loadingState("Buscando dados da estufa…"));
  let timer = null;
  let destroyed = false;
  let data = null;
  let series = null;
  let seriesUnitId = null;
  let seriesLoadedAt = 0;
  let chartNode = null;
  let eventsOpen = false;
  let stageEditOpen = false;

  async function load() {
    try {
      const overview = await loadOverview();
      const unit = pickUnit(overview.units);
      let latest = null;
      let alerts = [];
      let outputs = null;
      if (unit) {
        const needsSeries = seriesUnitId !== unit.id || Date.now() - seriesLoadedAt > SERIES_REFRESH_MS;
        const since = new Date(Date.now() - CHART_HOURS * 3_600_000).toISOString();
        const [latestReading, activeAlerts, nextOutputs, nextSeries] = await Promise.all([
          api.getOrNull(`/curing_units/${unit.id}/latest`),
          api.get(`/curing_units/${unit.id}/alerts?active=true`),
          api.get(`/curing_units/${unit.id}/outputs?events=5`),
          needsSeries ? api.get(`/curing_units/${unit.id}/series?since=${encodeURIComponent(since)}&points=144`) : null,
        ]);
        latest = latestReading;
        alerts = activeAlerts;
        outputs = nextOutputs;
        if (nextSeries) {
          series = nextSeries;
          seriesUnitId = unit.id;
          seriesLoadedAt = Date.now();
          chartNode = null;
        }
      }
      if (destroyed) return;
      data = { ...overview, unit, latest, alerts, outputs };
      // Não redesenha enquanto o usuário mexe num campo (ex.: seletor de fase aberto).
      const focused = document.activeElement;
      const interacting = focused && root.contains(focused) && ["SELECT", "INPUT"].includes(focused.tagName);
      if (!interacting) draw();
    } catch (error) {
      if (destroyed) return;
      if (!data) clear(root, banner("crit", "cloudOff", "Não foi possível carregar o painel", error.message, [button("Tentar de novo", { onClick: load })]));
      else toast(error.message, "error");
    } finally {
      if (!destroyed) {
        clearTimeout(timer);
        timer = setTimeout(load, POLL_MS);
      }
    }
  }

  function draw() {
    const { units, devicesById, unit, latest, alerts, devices, outputs } = data;
    if (!unit) {
      clear(root, header(null, units), onboarding({ units, devices, unit: null }));
      return;
    }

    const device = unit.device_id ? devicesById.get(unit.device_id) : null;
    const limits = limitsFor(unit, device);
    const needsSetup = !device || !unit.is_drying;

    clear(
      root,
      header(unit, units, device),
      statusBanner({ unit, device, latest, alerts, limits }),
      needsSetup && !latest ? onboarding({ units, devices, unit, device }) : null,
      h(
        "div",
        { class: "grid grid-2" },
        kpiCard({ kind: "temp", latest, device, limits, unit }),
        kpiCard({ kind: "humidity", latest, device, limits, unit }),
      ),
      h(
        "div",
        { class: "grid grid-main" },
        chartCard(limits, unit),
        h("div", { class: "stack" }, outputsCard(outputs, unit, device), dryingCard(unit), alertsCard(alerts, unit)),
      ),
    );
  }

  function header(unit, units, device) {
    const selector =
      units.length > 1
        ? select(
            units.map((item) => ({ value: item.id, label: item.name })),
            unit?.id,
            {
              "aria-label": "Escolher estufa",
              onChange: (event) => {
                prefs.set({ unitId: Number(event.target.value) });
                chartNode = null;
                seriesUnitId = null;
                load();
              },
            },
          )
        : null;

    const deviceBadge = !unit
      ? null
      : !device
        ? badge("neutral", "Sem dispositivo", "linkOff")
        : device.status === "online"
          ? badge("ok", "Sensor online")
          : badge("offline", "Sensor offline", "cloudOff");

    return h(
      "div",
      { class: "page-header" },
      h(
        "div",
        {},
        h("p", { class: "eyebrow" }, "Visão geral"),
        h("h1", {}, unit ? unit.name : "Bem-vindo"),
        unit
          ? h(
              "div",
              { class: "row", style: { marginTop: "8px" } },
              h("span", { class: `phase-tag phase-${phaseKey(unit.curing_stage) || "other"}` }, h("span", { class: "phase-swatch", "aria-hidden": "true" }), unit.phase ? `Fase ${unit.phase.number} de ${unit.phase.total} · ${unit.curing_stage}` : unit.curing_stage),
              deviceBadge,
            )
          : null,
      ),
      selector ? h("div", { class: "filters" }, selector) : null,
    );
  }

  function statusBanner({ unit, device, latest, alerts, limits }) {
    const goUnits = button("Abrir estufas", { onClick: () => ctx.navigate(`#/estufas?vincular=${unit.id}`), iconName: "link" });
    if (!device) {
      return banner("info", "info", "Esta estufa ainda não tem sensor vinculado", "Vincule o dispositivo ESP32 (sender) para começar a receber temperatura e umidade.", [goUnits]);
    }
    if (device.status !== "online") {
      return banner(
        "offline",
        "cloudOff",
        `Sensor sem sinal ${device.last_seen_at ? f.relative(device.last_seen_at) : "desde o cadastro"}`,
        "Confira se o sender está ligado, se o gateway (receiver) tem Wi-Fi e se o servidor está acessível na rede.",
      );
    }
    if (!unit.is_drying) {
      return banner(
        "warn",
        "warning",
        "Secagem não iniciada: as leituras não estão sendo gravadas",
        "O sensor está enviando dados, mas o histórico e os alertas só funcionam com a secagem em andamento.",
        [button("Iniciar secagem", { variant: "btn-primary", iconName: "play", onClick: (event) => startDrying(event.currentTarget, unit) })],
      );
    }
    const critical = alerts.filter(isSevere);
    if (critical.length) {
      const emergency = critical.some((alert) => alert.severity === "emergency");
      const title = emergency ? "Emergência nesta estufa" : `${f.plural(critical.length, "alerta crítico", "alertas críticos")} nesta estufa`;
      return banner("crit", "error", title, critical[0].message, [
        button("Ver alertas", { onClick: () => ctx.navigate("#/alertas") }),
      ]);
    }
    if (alerts.length) {
      return banner("warn", "warning", `${f.plural(alerts.length, "alerta ativo", "alertas ativos")}`, alerts[0].message, [
        button("Ver alertas", { onClick: () => ctx.navigate("#/alertas") }),
      ]);
    }
    const tempState = rangeState(latest?.temperature, limits.temp_min, limits.temp_max);
    const humidityState = rangeState(latest?.humidity, limits.humidity_min, limits.humidity_max);
    if (tempState === "ok" && humidityState === "ok") {
      return banner("ok", "checkCircle", "Tudo certo", `Temperatura e umidade estão dentro da faixa da fase de ${unit.curing_stage}.`);
    }
    return banner("info", "clock", "Aguardando as próximas leituras", "Assim que chegarem, os valores aparecem aqui automaticamente.");
  }

  function onboarding({ units, devices, unit, device }) {
    const steps = [
      {
        done: units.length > 0,
        title: "Cadastre a estufa",
        text: "Dê um nome para a estufa que será monitorada.",
        action: button("Cadastrar estufa", { variant: "btn-primary", iconName: "add", onClick: () => ctx.navigate("#/estufas?nova=1") }),
      },
      {
        done: Boolean(device),
        title: "Vincule o sensor ESP32",
        text: "Informe o ID do controlador que aparece no display do sender (ex.: ESP32-TOBACCO-01).",
        action: button("Vincular dispositivo", {
          variant: "btn-primary",
          iconName: "link",
          onClick: () => ctx.navigate(unit ? `#/estufas?vincular=${unit.id}` : "#/estufas"),
        }),
      },
      {
        done: Boolean(unit?.is_drying),
        title: "Inicie a secagem",
        text: "A partir daí as leituras são gravadas e os alertas passam a funcionar.",
        action: unit ? button("Iniciar secagem", { variant: "btn-primary", iconName: "play", onClick: (event) => startDrying(event.currentTarget, unit) }) : null,
      },
    ];
    const currentIndex = steps.findIndex((step) => !step.done);
    return h(
      "section",
      { class: "card" },
      h("div", { class: "card-header" }, h("h2", {}, icon("help"), "Primeiros passos")),
      h(
        "ol",
        { class: "steps" },
        steps.map((step, index) =>
          h(
            "li",
            { class: `step ${step.done ? "is-done" : ""} ${index === currentIndex ? "is-current" : ""}` },
            h("span", { class: "step-number" }, step.done ? icon("check") : String(index + 1)),
            h(
              "div",
              { class: "step-body" },
              h("h3", {}, step.title),
              h("p", {}, step.text),
              index === currentIndex ? step.action : null,
            ),
          ),
        ),
      ),
      !devices.length && units.length ? h("p", { class: "field-hint", style: { marginTop: "12px" } }, "Dica: com o gateway ligado, o sensor aparece automaticamente para vínculo assim que envia a primeira leitura.") : null,
    );
  }

  function kpiCard({ kind, latest, device, limits, unit }) {
    const isTemp = kind === "temp";
    const raw = latest ? (isTemp ? latest.temperature : latest.humidity) : null;
    const min = isTemp ? limits.temp_min : limits.humidity_min;
    const max = isTemp ? limits.temp_max : limits.humidity_max;
    const state = rangeState(raw, min, max);
    const stale = !latest || device?.status !== "online";

    const display = isTemp ? f.tempValue(raw) : raw;
    const displayMin = isTemp ? f.tempValue(min) : min;
    const displayMax = isTemp ? f.tempValue(max) : max;
    const unitLabel = isTemp ? f.tempUnit() : "%";

    const stateBadge =
      state === "high"
        ? badge("crit", "Acima do limite", "arrowUp")
        : state === "low"
          ? badge("warn", "Abaixo do limite", "arrowDown")
          : state === "ok"
            ? badge("ok", "Na faixa", "check")
            : badge("neutral", "Sem leitura", "clock");

    // Régua: faixa segura destacada e marcador na posição do valor atual.
    const span = displayMax - displayMin;
    const scaleMin = displayMin - span * 0.35;
    const scaleMax = displayMax + span * 0.35;
    const position = (value) => `${Math.min(100, Math.max(0, ((value - scaleMin) / (scaleMax - scaleMin)) * 100))}%`;
    const meter = h(
      "div",
      { class: "meter", role: "presentation" },
      h("div", { class: "meter-safe", style: { left: position(displayMin), right: `calc(100% - ${position(displayMax)})` } }),
      display !== null ? h("div", { class: `meter-marker ${state === "ok" ? "" : "is-out"}`, style: { left: position(display) } }) : null,
    );

    return h(
      "section",
      { class: `card kpi ${stale ? "is-stale" : ""}`, "aria-label": isTemp ? "Temperatura" : "Umidade relativa" },
      h(
        "div",
        { class: "kpi-head" },
        h("div", { class: "kpi-label" }, h("span", { class: "kpi-icon" }, icon(isTemp ? "thermostat" : "water")), isTemp ? "Temperatura" : "Umidade relativa"),
        stateBadge,
      ),
      h(
        "div",
        { class: "kpi-value" },
        h("span", { class: "kpi-number" }, f.number(display)),
        h("span", { class: "kpi-unit" }, unitLabel),
        isTemp && raw !== null ? h("span", { class: "kpi-secondary" }, f.temp(raw, { unit: f.otherUnit() })) : null,
      ),
      h(
        "div",
        {},
        meter,
        h(
          "div",
          { class: "meter-scale" },
          h("span", {}, `${unit.phase ? "Faixa da fase" : "Faixa segura"}: ${f.number(displayMin, 0)} a ${f.number(displayMax, 0)} ${unitLabel}`),
          h("span", {}, latest ? `Leitura ${f.relative(latest.timestamp)}` : "Sem leituras gravadas"),
        ),
      ),
    );
  }

  function chartCard(limits, unit) {
    const phases = chartPhases(series, true);
    if (!chartNode) {
      const points = (series?.points || []).map((point) => ({ t: new Date(point.timestamp), v: f.tempValue(point.temperature), count: point.count }));
      const now = new Date();
      chartNode = lineChart({
        points,
        limits: phases.length ? null : { min: f.tempValue(limits.temp_min), max: f.tempValue(limits.temp_max) },
        phases,
        domain: [new Date(now.getTime() - CHART_HOURS * 3_600_000), now],
        format: (value) => `${f.number(value)} ${f.tempUnit()}`,
        detail: (point) => f.plural(point.count, "leitura"),
        gapMs: Math.max(5 * 60_000, (series?.bucket_seconds || 0) * 3000),
        height: 240,
        label: `Temperatura nas últimas ${CHART_HOURS} horas`,
        emptyText: "Nenhuma leitura gravada nas últimas 6 horas.",
      });
    }
    return h(
      "section",
      { class: "card" },
      h(
        "div",
        { class: "card-header" },
        h(
          "div",
          {},
          h("h2", {}, icon("chart"), "Temperatura nas últimas 6 horas"),
          h("p", { class: "small muted" }, unit.phase ? "O fundo mostra a fase da cura; a faixa verde clara é a zona segura de cada fase." : "A faixa verde clara é a zona segura."),
        ),
        h("a", { class: "card-link", href: "#/historico" }, "Histórico", icon("chevronRight")),
      ),
      chartNode,
      phases.length > 1 ? phaseLegend(phases) : null,
    );
  }

  function outputsCard(outputs, unit, device) {
    if (!outputs) return null;
    const row = (key) => {
      const state = outputs[key];
      const relay = state.pin ? `Relé ${state.relay} · ${state.pin}` : `Relé ${state.relay}`;
      const sync = state.in_sync
        ? ["ok", "checkCircle", `Sender confirmou: ${state.on ? "ligada" : "desligada"}`]
        : state.confirmed_on === null || state.confirmed_on === undefined
          ? ["muted", "clock", "O sender ainda não informou o estado do relé."]
          : state.confirmed_on === state.on
            ? ["muted", "clock", `Último estado informado pelo sender ${f.relative(outputs.confirmed_at)}.`]
            : ["warn", "refresh", "Aguardando o sender aplicar o comando…"];
      return h(
        "div",
        { class: "output-row" },
        h(
          "div",
          { class: "output-head" },
          h("span", { class: "kpi-icon" }, icon(state.relay === 1 ? "water" : "thermostat")),
          h("div", { class: "output-title" }, h("strong", {}, state.name), h("span", { class: "small muted" }, relay)),
          state.on ? badge("info", "Ligada", "power") : badge("neutral", "Desligada", "powerOff"),
          h(
            "button",
            { class: "btn btn-ghost btn-icon", type: "button", "aria-label": `Editar ${state.name}`, title: "Editar nome e regra", onClick: () => editOutput(unit, key, state) },
            icon("edit"),
          ),
        ),
        h("p", { class: "small text-2" }, state.reason),
        h("p", { class: `output-sync is-${sync[0]}` }, icon(sync[1]), sync[2]),
        segmented(
          [
            { value: "auto", label: "Automático" },
            { value: "on", label: "Ligada" },
            { value: "off", label: "Desligada" },
          ],
          state.mode,
          (mode) => setOutputMode(unit, key, mode),
          `Modo de ${state.name}`,
        ),
      );
    };
    const last = outputs.last_buzzer;
    const recent = last && Date.now() - f.parseDate(last.timestamp).getTime() < 120_000;

    return h(
      "section",
      { class: "card" },
      h("div", { class: "card-header" }, h("h2", {}, icon("campaign"), "Saídas e aviso sonoro")),
      h("p", { class: "small muted card-intro" }, "Relés do sender, como ventoinhas ou queimador. O gateway toca um aviso de 2 segundos sempre que uma saída liga."),
      row("humidity"),
      h("div", { class: "divider" }),
      row("temperature"),
      h(
        "div",
        { class: `buzzer-last${recent ? " is-recent" : ""}`, role: "status" },
        icon(last ? "volumeUp" : "volumeOff"),
        h(
          "div",
          {},
          h("p", { class: "buzzer-title" }, last ? `Último aviso sonoro ${f.relative(last.timestamp)}` : "Nenhum aviso sonoro até agora"),
          h(
            "p",
            { class: "small" },
            last ? `${describeOutputEvent(last)} · ${f.dateTime(last.timestamp)}` : "O aviso toca quando uma saída liga, no automático ou pelo painel.",
          ),
        ),
      ),
      device ? null : h("p", { class: "small muted" }, "Vincule o sensor desta estufa para que o gateway receba estes comandos."),
      outputs.events.length
        ? h(
            "details",
            { class: "output-events", open: eventsOpen, onToggle: (event) => (eventsOpen = event.currentTarget.open) },
            h("summary", {}, "Últimas mudanças"),
            h(
              "ul",
              {},
              outputs.events.map((event) =>
                h(
                  "li",
                  { class: event.turned_on ? "is-on" : "" },
                  icon(event.turned_on ? "power" : "powerOff"),
                  h("span", {}, describeOutputEvent(event)),
                  h("span", { class: "small muted" }, f.relative(event.timestamp)),
                ),
              ),
            ),
          )
        : null,
    );
  }

  function editOutput(unit, key, state) {
    const nameInput = h("input", { class: "input", value: state.name, maxlength: 40, placeholder: "Ex.: Ventoinhas, Queimador" });
    const triggerSelect = select(OUTPUT_TRIGGERS, state.trigger);
    const relay = state.pin ? `Relé ${state.relay} (${state.pin})` : `Relé ${state.relay}`;
    const modal = openModal({
      title: "Editar saída",
      body: h(
        "div",
        { class: "form" },
        h("p", { class: "text-2" }, `${relay} do sender. O nome aparece no painel, no app e nas notificações.`),
        field({ label: "Nome", input: nameInput }),
        field({ label: "No automático, liga quando…", input: triggerSelect, hint: "A faixa segura muda com a fase da cura em andamento." }),
      ),
      actions: [
        { label: "Cancelar" },
        {
          label: "Salvar",
          variant: "btn-primary",
          onClick: async (close) => {
            const name = nameInput.value.trim();
            if (!name) throw new Error("Informe um nome para a saída.");
            data.outputs = await api.patch(`/curing_units/${unit.id}/outputs`, {
              [`${key}_name`]: name,
              [`${key}_trigger`]: triggerSelect.value,
            });
            close();
            draw();
            toast(`Saída "${name}" atualizada.`, "success");
          },
        },
      ],
    });
    nameInput.focus();
    return modal;
  }

  async function setOutputMode(unit, key, mode) {
    const name = data.outputs?.[key]?.name || "Saída";
    if (mode === "on") {
      const confirmed = await confirmDialog({
        title: `Ligar "${name}"?`,
        message:
          "Ela fica ligada até você escolher Automático ou Desligada. O gateway recebe o comando na próxima leitura e toca o aviso sonoro por 2 segundos.",
        confirmLabel: "Ligar saída",
      });
      if (!confirmed) {
        draw();
        return;
      }
    }
    try {
      data.outputs = await api.patch(`/curing_units/${unit.id}/outputs`, { [`${key}_mode`]: mode });
      draw();
      toast(
        mode === "on"
          ? `"${name}" ligada. O sender recebe o comando em alguns segundos.`
          : mode === "off"
            ? `"${name}" desligada.`
            : `"${name}" no automático.`,
        "success",
      );
    } catch (error) {
      toast(error.message, "error");
      draw();
    }
  }

  function dryingCard(unit) {
    const phase = unit.phase;
    const elapsed = unit.drying_started_at ? f.hoursSince(unit.drying_started_at) : null;
    const stageHours = f.hoursSince(unit.stage_started_at);
    const total = unit.estimated_duration_hours;
    const progress = elapsed !== null && total ? Math.min(100, (elapsed / total) * 100) : null;
    const finished = unit.curing_stage === "Finalizado";

    const stageSelect = select(stageOptions(unit.curing_stage), unit.curing_stage, {
      "aria-label": "Fase da cura",
      onChange: async (event) => {
        const stage = event.target.value;
        try {
          await api.patch(`/curing_units/${unit.id}`, { curing_stage: stage });
          toast(`Fase alterada para "${stage}".`, "success");
          load();
        } catch (error) {
          toast(error.message, "error");
        }
      },
    });

    // As quatro fases em sequência, com a cor de cada uma.
    const steps = h(
      "ol",
      { class: "phase-steps", "aria-label": "Fases da cura" },
      PHASES.map((item, index) => {
        const number = index + 1;
        const status = finished || (phase && number < phase.number) ? "is-done" : phase && number === phase.number ? "is-current" : "";
        return h(
          "li",
          { class: `phase-step phase-${item.key} ${status}`, "aria-current": status === "is-current" ? "step" : null },
          h("span", { class: "phase-step-bar", "aria-hidden": "true" }),
          h("span", { class: "phase-step-name" }, status === "is-done" ? icon("check") : null, item.name),
        );
      }),
    );

    const details = h(
      "dl",
      { class: "details" },
      h("div", {}, h("dt", {}, "Em secagem há"), h("dd", {}, elapsed !== null ? f.duration(elapsed) : "Parada")),
      h(
        "div",
        {},
        h("dt", {}, "Nesta fase há"),
        h("dd", { class: phase?.overdue ? "is-bad" : "" }, phase ? `${f.duration(stageHours)} de ${f.number(phase.min_hours, 0)} a ${f.number(phase.max_hours, 0)} h` : f.duration(stageHours)),
      ),
      h("div", {}, h("dt", {}, "Duração prevista"), h("dd", {}, total ? f.duration(total) : "Não definida")),
      h("div", {}, h("dt", {}, "Término previsto"), h("dd", {}, unit.estimated_completion_at ? f.dateTime(unit.estimated_completion_at) : "--")),
    );

    const phasePanel = phase
      ? h(
          "div",
          { class: `phase-panel phase-${phase.key}` },
          h(
            "p",
            { class: "phase-range" },
            h("strong", {}, `Fase ${phase.number}: ${phase.name}`),
            h("span", {}, `${f.temp(phase.temp_min, { digits: 0 })} a ${f.temp(phase.temp_max, { digits: 0 })} · umidade ${f.number(phase.humidity_min, 0)}% a ${f.number(phase.humidity_max, 0)}%`),
          ),
          phase.overdue ? h("p", { class: "small phase-overdue" }, icon("warning"), `Passou das ${f.number(phase.max_hours, 0)} h de referência desta fase.`) : null,
          h("p", { class: "small muted" }, phase.next_stage === "Finalizado" ? "Para finalizar a cura:" : `Para passar para ${phase.next_stage}:`),
          h(
            "ul",
            { class: "phase-checks" },
            phase.checks.map((check) => h("li", { class: check.ok ? "is-ok" : "" }, icon(check.ok ? "checkCircle" : "clock"), check.label)),
            h("li", { class: "is-visual" }, icon("eco"), `Confira nas folhas: ${phase.visual_check}`),
          ),
        )
      : null;

    const actions = unit.is_drying
      ? [
          phase ? advanceButton(unit, phase) : null,
          button("Parar secagem", { variant: "btn-danger", iconName: "stop", onClick: (event) => stopDrying(event.currentTarget, unit) }),
        ]
      : button(finished ? "Iniciar nova cura" : "Iniciar secagem", { variant: "btn-primary", iconName: "play", onClick: (event) => startDrying(event.currentTarget, unit) });

    return h(
      "section",
      { class: "card" },
      h("div", { class: "card-header" }, h("h2", {}, icon("eco"), "Secagem"), unit.is_drying ? badge("ok", "Em andamento") : finished ? badge("ok", "Finalizada", "checkCircle") : badge("neutral", "Parada", "stop")),
      steps,
      phasePanel,
      h("div", { class: "divider" }),
      details,
      h(
        "details",
        { class: "phase-correct", open: stageEditOpen, onToggle: (event) => (stageEditOpen = event.currentTarget.open) },
        h("summary", {}, "Corrigir a fase manualmente"),
        field({ label: "Fase da cura", input: stageSelect }),
      ),
      progress !== null
        ? h(
            "div",
            { style: { marginTop: "14px" } },
            h("div", { class: "progress", role: "progressbar", "aria-valuenow": Math.round(progress), "aria-valuemin": 0, "aria-valuemax": 100 }, h("div", { class: "progress-bar", style: { width: `${progress}%` } })),
            h("p", { class: "small muted", style: { marginTop: "6px" } }, `${f.number(progress, 0)}% do tempo previsto`),
          )
        : null,
      h(
        "div",
        { class: "card-footer" },
        actions,
        button(total ? "Alterar duração" : "Definir duração", { variant: "btn-outline", iconName: "clock", onClick: () => editDuration(unit) }),
      ),
    );
  }

  function alertsCard(alerts, unit) {
    return h(
      "section",
      { class: "card" },
      h(
        "div",
        { class: "card-header" },
        h("h2", {}, icon("bell"), "Alertas ativos"),
        h("a", { class: "card-link", href: "#/alertas" }, "Todos", icon("chevronRight")),
      ),
      alerts.length
        ? alerts.slice(0, 3).map((alert) => {
            const info = severityInfo(alert);
            return h(
              "div",
              { class: `alert-mini ${info.className}` },
              icon(info.icon),
              h("div", {}, h("p", { style: { fontWeight: 600 } }, `${alert.type} · ${info.label}`), h("p", { class: "small text-2" }, alert.message), h("p", { class: "small muted" }, f.relative(alert.timestamp))),
            );
          })
        : h("p", { class: "text-2" }, unit.is_drying ? "Nenhum alerta. Os valores estão sendo acompanhados." : "Os alertas são avaliados enquanto a secagem está em andamento."),
    );
  }

  function advanceButton(unit, phase) {
    const finishing = phase.next_stage === "Finalizado";
    return button(finishing ? "Finalizar cura" : `Avançar para ${phase.next_stage}`, {
      variant: phase.ready ? "btn-primary" : "btn-outline",
      iconName: finishing ? "checkCircle" : "chevronRight",
      onClick: (event) => advanceStage(event.currentTarget, unit, phase),
    });
  }

  async function advanceStage(target, unit, phase) {
    const finishing = phase.next_stage === "Finalizado";
    const pending = phase.checks.filter((check) => !check.ok).map((check) => check.label.toLowerCase());
    const message = [
      `Confira nas folhas: ${phase.visual_check}`,
      pending.length ? `Ainda não atingido: ${pending.join("; ")}.` : "As condições de tempo, temperatura e umidade foram atingidas.",
      finishing ? "A secagem será encerrada e as leituras deixam de ser gravadas." : "Os alarmes e as saídas automáticas passam a usar a faixa da nova fase.",
    ].join(" ");
    const confirmed = await confirmDialog({
      title: finishing ? "Finalizar a cura?" : `Avançar para ${phase.next_stage}?`,
      message,
      confirmLabel: finishing ? "Finalizar cura" : "Avançar fase",
    });
    if (!confirmed) return;
    try {
      await withBusy(target, () => api.post(`/curing_units/${unit.id}/advance-stage`));
      toast(finishing ? "Cura finalizada." : `Fase alterada para "${phase.next_stage}".`, "success");
      seriesUnitId = null;
      load();
    } catch (error) {
      toast(error.message, "error");
    }
  }

  async function startDrying(target, unit) {
    try {
      const started = await withBusy(target, () => api.post(`/curing_units/${unit.id}/start-drying`));
      toast(`Secagem iniciada na fase de ${started.curing_stage}. As leituras passam a ser gravadas.`, "success");
      seriesUnitId = null;
      load();
    } catch (error) {
      toast(error.message, "error");
    }
  }

  async function stopDrying(target, unit) {
    const confirmed = await confirmDialog({
      title: "Parar a secagem?",
      message: "Enquanto a secagem estiver parada, as leituras do sensor não são gravadas e nenhum alerta é gerado.",
      confirmLabel: "Parar secagem",
      danger: true,
    });
    if (!confirmed) return;
    try {
      await withBusy(target, () => api.post(`/curing_units/${unit.id}/stop-drying`));
      toast("Secagem parada.", "success");
      load();
    } catch (error) {
      toast(error.message, "error");
    }
  }

  function editDuration(unit) {
    const input = h("input", { class: "input num", type: "number", min: 1, max: 1000, step: 1, value: unit.estimated_duration_hours ?? "" });
    openModal({
      title: "Duração prevista da secagem",
      body: h("div", { class: "form" }, field({ label: "Duração total", input, suffix: "horas", hint: "Uma cura completa costuma levar de 5 a 7 dias (120 a 168 horas)." })),
      actions: [
        { label: "Cancelar" },
        {
          label: "Salvar",
          variant: "btn-primary",
          onClick: async (close) => {
            const hours = Number(input.value);
            if (!hours || hours <= 0) throw new Error("Informe a duração em horas.");
            await api.patch(`/curing_units/${unit.id}`, { estimated_duration_hours: hours });
            toast("Duração atualizada.", "success");
            close();
            load();
          },
        },
      ],
    });
  }

  const unsubscribe = prefs.subscribe((changes) => {
    if ("unit" in changes && data) {
      chartNode = null;
      draw();
    }
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
