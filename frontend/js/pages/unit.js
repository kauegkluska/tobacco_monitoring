// Tela de uma estufa: a frase de decisão no topo, depois leituras, fase, gráfico, ventilação e sensor.

import { api } from "../api.js";
import { OUTPUT_TRIGGERS, describeOutputEvent } from "../buzzer.js";
import { lineChart, phaseLegend } from "../chart.js";
import { PHASES, chartPhases, isSevere, limitsFor, signalQuality, stageOptions } from "../data.js";
import { badge, banner, button, clear, confirmDialog, field, h, icon, loadingState, openModal, segmented, select, toast, withBusy } from "../dom.js";
import * as f from "../format.js";
import { prefs } from "../store.js";
import { alertActions, alertCard, featuredAlert, isStale, phaseCheckLabel, phaseSteps, phaseTag, reading, unitStatus } from "../widgets.js";

const POLL_MS = 5000;
const SERIES_REFRESH_MS = 60_000;
// O gráfico é da estufada (a carga atual, ou a última), não da estufa: "all" é a estufada inteira.
const PERIODS = [
  { value: "all", label: "Estufada toda" },
  { value: 24, label: "Últimas 24 h" },
  { value: 6, label: "Últimas 6 h" },
];

export function renderUnit(ctx) {
  const unitId = Number(ctx.param);
  const base = `/curing_units/${unitId}`;
  const root = h("div", { class: "page" }, loadingState());
  const state = { hours: PERIODS[0].value, metric: "temperature" };
  let data = null;
  let series = null;
  let seriesLoadedAt = 0;
  let chartNode = null;
  let eventsOpen = false;
  let timer = null;
  let destroyed = false;

  async function load() {
    try {
      const [unit, devices, latest, alerts, outputs] = await Promise.all([
        api.get(base),
        api.get("/devices/"),
        api.getOrNull(`${base}/latest`),
        api.get(`${base}/alerts?active=true`),
        api.get(`${base}/outputs?events=5`),
      ]);
      if (destroyed) return;
      data = { unit, device: devices.find((device) => device.id === unit.device_id) || null, latest, alerts, outputs };
      ctx.setTitle(unit.name);
      if (Date.now() - seriesLoadedAt > SERIES_REFRESH_MS) await loadSeries();
      // Não redesenha com um diálogo aberto ou enquanto o usuário mexe num campo.
      const focused = document.activeElement;
      const interacting = focused && root.contains(focused) && ["SELECT", "INPUT"].includes(focused.tagName);
      if (!destroyed && !interacting && !document.querySelector("dialog[open]")) draw();
    } catch (error) {
      if (destroyed) return;
      if (error.status === 404) {
        toast("Estufa não encontrada.", "error");
        ctx.navigate("#/estufas");
        return;
      }
      if (!data) clear(root, banner("crit", "cloudOff", "Não foi possível carregar a estufa", error.message, [button("Tentar de novo", { onClick: load })]));
      // Sem conexão quem avisa é a frase do topo, sem repetir um aviso a cada consulta.
      else if (error.status === 0) {
        if (!document.querySelector("dialog[open]")) draw();
      } else toast(error.message, "error");
    } finally {
      if (!destroyed) {
        clearTimeout(timer);
        timer = setTimeout(load, POLL_MS);
      }
    }
  }

  async function loadSeries() {
    const hours = state.hours === "all" ? "" : `&hours=${state.hours}`;
    try {
      series = await api.get(`${base}/series?batch=true&points=240${hours}`);
      seriesLoadedAt = Date.now();
      chartNode = null;
    } catch (error) {
      toast(error.message, "error");
    }
  }

  async function reload({ withSeries = false } = {}) {
    if (withSeries) seriesLoadedAt = 0;
    await load();
  }

  /** Roda uma ação da API, mostra o resultado e recarrega a tela. */
  async function run(target, action, done, options) {
    try {
      await withBusy(target, action);
      toast(done, "success");
      await reload(options);
    } catch (error) {
      toast(error.message, "error");
    }
  }

  function draw() {
    const { unit, device, latest, alerts } = data;
    const limits = limitsFor(unit, device);
    const doubtful = alerts.some((alert) => alert.type === "Sensor suspeito");
    const stale = isStale(latest, unit, device) || doubtful;
    const featured = featuredAlert(alerts);
    const status = unitStatus({
      unit,
      device,
      latest,
      activeAlerts: alerts.filter((alert) => alert.severity !== "info").length,
      criticalAlerts: alerts.filter(isSevere).length,
      sensorDoubt: doubtful,
      message: featured?.message ?? null,
    });
    const showsFeatured = featured && status.text === featured.message;
    const others = alerts.filter((alert) => !showsFeatured || alert.id !== featured.id);
    const setupActions = !device
      ? [button("Vincular sensor", { variant: "btn-primary", iconName: "link", onClick: linkDevice })]
      : !unit.is_drying
        ? [button(unit.curing_stage === "Finalizado" ? "Nova estufada" : "Iniciar secagem", { variant: "btn-primary", iconName: "play", onClick: (event) => startDrying(event.currentTarget, unit) })]
        : [];

    clear(
      root,
      h(
        "div",
        { class: "unit-header" },
        h("a", { class: "card-link", href: "#/estufas" }, icon("chevronRight", "is-back"), "Estufas"),
        h("div", { class: "row-between" }, h("h1", {}, unit.name), menu(unit, latest)),
        h("div", { class: "row" }, phaseTag(unit), latest ? h("span", { class: "small muted" }, `${doubtful ? "Leitura duvidosa" : "Leitura"} ${f.relative(latest.timestamp)}`) : null),
      ),
      h("div", { class: "decision" }, banner(status.kind === "neutral" ? "info" : status.kind, status.icon, status.title, status.text, showsFeatured ? alertActions(featured, reload) : setupActions)),
      h(
        "section",
        { class: "card readings" },
        reading({ metric: "temperature", value: latest?.temperature, limits: unit.phase ? limits : null, stale, target: fanTarget(data.outputs) }),
        reading({ metric: "humidity", value: latest?.humidity, limits: unit.phase ? limits : null, stale }),
      ),
      others.length ? h("div", { class: "grid grid-3" }, others.map((alert) => alertCard(alert, { showUnit: false, onChange: reload }))) : null,
      h(
        "div",
        { class: "grid grid-main" },
        h("div", { class: "stack" }, curingCard(unit), chartCard(unit, limits)),
        h("div", { class: "stack" }, outputsCard(unit), sensorCard(device)),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Menu: renomear, duração, corrigir fase, excluir

  function menu(unit, latest) {
    const items = [
      ["Duração prevista", "clock", () => editDuration(unit)],
      ["Corrigir fase", "tune", () => changeStage(unit)],
      ["Renomear", "edit", () => rename(unit)],
      unit.is_drying ? ["Parar secagem", "stop", (target) => stopDrying(target)] : null,
      // A API só exclui estufa sem leituras: não oferece o que depois recusaria.
      // A API só exclui estufa parada e sem leituras: nos outros casos a opção aparece desativada, com o motivo.
      ["Excluir estufa", "delete", () => removeUnit(unit), deleteBlocker(unit, latest)],
    ].filter(Boolean);
    return h(
      "details",
      { class: "menu" },
      h("summary", { class: "btn btn-outline btn-sm", "aria-label": "Mais opções" }, "Opções"),
      h(
        "div",
        { class: "menu-list", role: "menu" },
        items.map(([label, iconName, onClick, blocker]) =>
          h(
            "button",
            {
              type: "button",
              role: "menuitem",
              class: `menu-item ${iconName === "delete" || iconName === "stop" ? "is-danger" : ""}`,
              disabled: Boolean(blocker),
              onClick: (event) => {
                const target = event.currentTarget;
                target.closest("details").open = false;
                onClick(target);
              },
            },
            icon(iconName),
            blocker ? h("span", { class: "menu-item-text" }, label, h("span", { class: "menu-item-hint" }, blocker)) : label,
          ),
        ),
      ),
    );
  }

  /** Por que a estufa não pode ser excluída agora; null quando pode. */
  function deleteBlocker(unit, latest) {
    if (unit.is_drying) return "Pare a secagem antes.";
    if (latest) return "Tem leituras salvas: o histórico das estufadas fica guardado.";
    return null;
  }

  function rename(unit) {
    const name = h("input", { class: "input", value: unit.name, maxlength: 100, required: true });
    openModal({
      title: "Renomear estufa",
      body: h("div", { class: "form" }, field({ label: "Nome", input: name })),
      actions: [
        { label: "Cancelar" },
        {
          label: "Salvar",
          variant: "btn-primary",
          onClick: async (close) => {
            if (!name.value.trim()) throw new Error("Informe o nome.");
            await api.patch(base, { name: name.value.trim() });
            close();
            reload();
          },
        },
      ],
    });
  }

  function editDuration(unit) {
    const input = h("input", { class: "input num", type: "number", min: 1, max: 1000, step: 1, value: unit.estimated_duration_hours ?? "" });
    openModal({
      title: "Duração prevista",
      body: h("div", { class: "form" }, field({ label: "Duração total", input, suffix: "horas", hint: "Uma cura costuma levar de 5 a 7 dias (120 a 168 h)." })),
      actions: [
        { label: "Cancelar" },
        {
          label: "Salvar",
          variant: "btn-primary",
          onClick: async (close) => {
            const hours = Number(input.value);
            if (!hours || hours <= 0) throw new Error("Informe a duração em horas.");
            await api.patch(base, { estimated_duration_hours: hours });
            toast("Duração salva.", "success");
            close();
            reload();
          },
        },
      ],
    });
  }

  function changeStage(unit) {
    const stage = select(stageOptions(unit.curing_stage), unit.curing_stage);
    openModal({
      title: "Corrigir fase",
      body: h("div", { class: "form" }, field({ label: "Fase", input: stage })),
      actions: [
        { label: "Cancelar" },
        {
          label: "Salvar",
          variant: "btn-primary",
          onClick: async (close) => {
            if (stage.value !== unit.curing_stage) {
              await api.patch(base, { curing_stage: stage.value });
              toast(`Fase: ${stage.value}.`, "success");
            }
            close();
            reload({ withSeries: true });
          },
        },
      ],
    });
  }

  async function removeUnit(unit) {
    const confirmed = await confirmDialog({
      title: `Excluir ${unit.name}?`,
      message: "A estufa sai da sua lista.",
      confirmLabel: "Excluir",
      danger: true,
    });
    if (!confirmed) return;
    try {
      await api.del(base);
      toast("Estufa excluída.", "success");
      ctx.navigate("#/estufas");
    } catch (error) {
      toast(error.message, "error");
    }
  }

  // ---------------------------------------------------------------------------
  // Cura

  function curingCard(unit) {
    const phase = unit.phase;
    const finished = unit.curing_stage === "Finalizado";
    // Horas com a secagem ligada (o tempo parado não conta).
    const elapsed = unit.cycle_hours ?? null;
    const total = unit.estimated_duration_hours;
    const progress = unit.is_drying && elapsed !== null && total ? Math.min(100, (elapsed / total) * 100) : null;
    // Com a secagem parada no meio da cura, a fase em que parou continua marcada.
    const current = phase?.number ?? PHASES.findIndex((item) => item.name === unit.curing_stage) + 1;

    const details = unit.is_drying || unit.interrupted
      ? h(
          "dl",
          { class: "details" },
          h(
            "div",
            {},
            h("dt", {}, "Nesta fase"),
            h(
              "dd",
              { class: phase?.overdue ? "is-bad" : "" },
              phase ? `${f.duration(phase.hours)} (o normal é de ${f.number(phase.min_hours, 0)} a ${f.number(phase.max_hours, 0)} h)` : f.duration(unit.stage_hours),
            ),
          ),
          // Faixa, nunca valor único: a duração real depende das folhas.
          phase ? h("div", {}, h("dt", {}, "Falta para acabar"), h("dd", {}, `de ${f.duration(phase.remaining_hours_min)} a ${f.duration(phase.remaining_hours_max)}`)) : null,
          h("div", {}, h("dt", {}, "Secagem total"), h("dd", {}, f.duration(elapsed))),
          total && unit.is_drying ? h("div", {}, h("dt", {}, "Término previsto"), h("dd", {}, f.dateTime(unit.estimated_completion_at))) : null,
        )
      : null;

    const checks = phase
      ? h(
          "div",
          { class: "phase-next" },
          h("h3", {}, phase.ready ? "Já dá para passar de fase" : "Ainda não é hora de passar de fase"),
          h(
            "ul",
            { class: "phase-checks" },
            phase.overdue ? h("li", { class: "is-warn" }, icon("warning"), "Passou do tempo previsto. Olhe as folhas.") : null,
            phase.checks.map((check) => h("li", { class: check.ok ? "is-ok" : "" }, icon(check.ok ? "checkCircle" : "clock"), phaseCheckLabel(check))),
            h("li", { class: `is-visual phase-${phase.key}` }, icon("eco"), `Nas folhas: ${phase.visual_check}`),
          ),
        )
      : null;

    const actions = [];
    if (phase) {
      const finishing = phase.next_stage === "Finalizado";
      actions.push(
        button(finishing ? "Finalizar cura" : `Passar para ${phase.next_stage}`, {
          variant: phase.ready ? "btn-primary" : "btn-outline",
          iconName: finishing ? "checkCircle" : "chevronRight",
          onClick: (event) => advanceStage(event.currentTarget, phase),
        }),
      );
    }

    return h(
      "section",
      { class: "card" },
      h("div", { class: "card-header" }, h("h2", {}, icon("eco"), "Cura")),
      phaseSteps(current, finished),
      unit.interrupted
        ? h("p", { class: "small text-2 paused-note" }, `Parada em ${unit.curing_stage}${unit.paused_at ? ` ${f.relative(unit.paused_at)}` : ""}. O tempo parado não conta.`)
        : null,
      details,
      progress !== null
        ? h("div", { class: "progress", role: "progressbar", "aria-label": "Tempo previsto", "aria-valuenow": Math.round(progress), "aria-valuemin": 0, "aria-valuemax": 100 }, h("div", { class: "progress-bar", style: { width: `${progress}%` } }))
        : null,
      checks,
      actions.length ? h("div", { class: "card-footer" }, actions) : null,
    );
  }

  /** Liga a secagem. Parada no meio da cura, pergunta se continua a mesma estufada ou começa outra. */
  function startDrying(target, unit) {
    const start = (newBatch, done) => api.post(`${base}/start-drying${newBatch ? "?new_batch=true" : ""}`).then(() => {
      toast(done, "success");
      reload({ withSeries: true });
    });
    if (!unit.interrupted) {
      run(target, () => api.post(`${base}/start-drying`), "Secagem iniciada.", { withSeries: true });
      return;
    }
    openModal({
      title: "Continuar a secagem?",
      body: h(
        "div",
        { class: "form" },
        h("p", {}, `A secagem parou em ${unit.curing_stage} com ${f.duration(unit.stage_hours)} nesta fase${unit.paused_at ? `, ${f.relative(unit.paused_at)}` : ""}.`),
        h(
          "ul",
          { class: "choice-list" },
          h("li", {}, h("strong", {}, "Continuar: "), "segue na mesma fase, sem contar o tempo parado."),
          h("li", {}, h("strong", {}, "Nova estufada: "), "começa outra carga na Amarelação, do zero."),
        ),
      ),
      actions: [
        { label: "Cancelar" },
        {
          label: "Nova estufada",
          variant: "btn-outline",
          onClick: async (close) => {
            await start(true, "Nova estufada iniciada.");
            close();
          },
        },
        {
          label: "Continuar",
          variant: "btn-primary",
          icon: "play",
          onClick: async (close) => {
            await start(false, "Secagem retomada.");
            close();
          },
        },
      ],
    });
  }

  async function advanceStage(target, phase) {
    const finishing = phase.next_stage === "Finalizado";
    const pending = phase.checks.filter((check) => !check.ok).map((check) => phaseCheckLabel(check).toLowerCase());
    const message = [
      `Nas folhas: ${phase.visual_check}`,
      pending.length ? `Ainda falta: ${pending.join("; ")}.` : null,
      finishing ? "A secagem será encerrada." : null,
    ]
      .filter(Boolean)
      .join(" ");
    const confirmed = await confirmDialog({
      title: finishing ? "Finalizar a cura?" : `Passar para ${phase.next_stage}?`,
      message,
      confirmLabel: finishing ? "Finalizar" : "Passar de fase",
    });
    if (!confirmed) return;
    await run(target, () => api.post(`${base}/advance-stage`), finishing ? "Cura finalizada." : `Fase: ${phase.next_stage}.`, { withSeries: true });
  }

  async function stopDrying(target) {
    const confirmed = await confirmDialog({
      title: "Parar a secagem?",
      message: "Se parar, o sistema deixa de acompanhar a estufa e você não recebe mais avisos.",
      confirmLabel: "Parar",
      danger: true,
    });
    if (confirmed) await run(target, () => api.post(`${base}/stop-drying`), "Secagem parada.");
  }

  // ---------------------------------------------------------------------------
  // Histórico

  function chartCard(unit, limits) {
    const isTemp = state.metric === "temperature";
    const key = state.metric;
    const toDisplay = (value) => (isTemp ? f.tempValue(value) : value);
    const format = (value) => (isTemp ? `${f.number(value)} ${f.tempUnit()}` : `${f.number(value)}%`);
    const phases = chartPhases(series, isTemp);
    const stats = series?.stats;
    const stat = (label, value) => h("div", {}, h("dt", {}, label), h("dd", {}, stats?.count ? format(toDisplay(value)) : "--"));
    const hasBatch = Boolean(unit.cycle_started_at);
    const periodText = state.hours === "all" ? "na estufada" : `nas últimas ${state.hours} h da estufada`;

    if (!chartNode && series) {
      chartNode = lineChart({
        points: series.points.map((point) => ({
          t: new Date(point.timestamp),
          v: toDisplay(point[key]),
          low: toDisplay(point[`${key}_min`]),
          high: toDisplay(point[`${key}_max`]),
          count: point.count,
        })),
        // Com fases no período, cada uma desenha a própria faixa esperada.
        limits: phases.length
          ? null
          : isTemp
            ? { min: f.tempValue(limits.temp_min), max: f.tempValue(limits.temp_max) }
            : { min: limits.humidity_min, max: limits.humidity_max },
        phases,
        domain: [new Date(series.since), new Date(series.until)],
        format,
        detail: (point) => (point.count > 1 ? `${format(point.low)} a ${format(point.high)}` : "1 leitura"),
        gapMs: Math.max(5 * 60_000, series.bucket_seconds * 3000),
        height: 260,
        label: `${isTemp ? "Temperatura" : "Umidade"} ${periodText}`,
        emptyText: !hasBatch
          ? "Nenhuma estufada ainda. O gráfico começa quando a secagem for iniciada."
          : unit.is_drying
            ? "Sem leituras neste período da estufada."
            : "Sem leituras nesta estufada. Elas só são gravadas com a secagem ligada.",
      });
    }

    return h(
      "section",
      { class: "card" },
      h(
        "div",
        { class: "card-header" },
        h("h2", {}, icon("chart"), "Gráfico da estufada"),
        button("CSV", { variant: "btn-ghost btn-sm", iconName: "download", "aria-label": "Baixar CSV do período", disabled: !series || !hasBatch, onClick: (event) => exportCsv(event.currentTarget, unit) }),
      ),
      hasBatch
        ? h("p", { class: "small muted" }, `${unit.is_drying ? "Estufada em andamento" : "Última estufada"}, iniciada em ${f.dateTime(unit.cycle_started_at)}.`)
        : null,
      h(
        "div",
        { class: "filters" },
        segmented(
          [
            { value: "temperature", label: "Temperatura" },
            { value: "humidity", label: "Umidade" },
          ],
          state.metric,
          (value) => {
            state.metric = value;
            chartNode = null;
            draw();
          },
          "Medida",
        ),
        segmented(
          PERIODS,
          state.hours,
          async (value) => {
            state.hours = value;
            root.classList.add("is-loading");
            await loadSeries();
            root.classList.remove("is-loading");
            if (!destroyed) draw();
          },
          "Período",
        ),
      ),
      h("dl", { class: "details details-3" }, stat("Mínima", stats?.[`${key}_min`]), stat("Média", stats?.[`${key}_avg`]), stat("Máxima", stats?.[`${key}_max`])),
      chartNode || loadingState(),
      phases.length > 1 ? phaseLegend(phases) : null,
    );
  }

  /** As leituras do mesmo período do gráfico. */
  async function exportCsv(target, unit) {
    if (!series) return;
    const suffix = state.hours === "all" ? "estufada" : `estufada-${state.hours}h`;
    try {
      await withBusy(target, () =>
        api.download(
          `${base}/readings.csv?since=${encodeURIComponent(series.since)}&until=${encodeURIComponent(series.until)}`,
          `leituras-${unit.name.replace(/[^\w-]+/g, "_")}-${suffix}.csv`,
        ),
      );
    } catch (error) {
      toast(error.message, "error");
    }
  }

  // ---------------------------------------------------------------------------
  // Saídas

  const followsTarget = (output) => output.trigger === "temperature_target";

  /** Alvo em °C quando alguma saída segue a temperatura alvo. */
  function fanTarget(outputs) {
    if (!outputs || !(followsTarget(outputs.humidity) || followsTarget(outputs.temperature))) return null;
    return outputs.target_temperature ?? null;
  }

  function targetRow(outputs) {
    const target = outputs.target_temperature;
    const missing = target === null || target === undefined;
    return h(
      "div",
      { class: `target-row ${missing ? "is-missing" : ""}` },
      icon("thermostat"),
      missing
        ? h("span", { class: "target-text" }, "Defina a temperatura alvo")
        : h(
            "span",
            { class: "target-text" },
            h("span", { class: "muted" }, "Alvo "),
            h("strong", {}, f.temp(target)),
            ramping(outputs) ? h("span", { class: "muted" }, ` · subindo, agora ${f.temp(outputs.target_effective)}`) : null,
          ),
      button(missing ? "Definir" : "Alterar", { variant: "btn-ghost btn-sm", onClick: editTarget }),
    );
  }

  /** O alvo efetivo ainda está subindo em rampa até o alvo. */
  const ramping = (outputs) =>
    outputs.target_effective !== null && outputs.target_effective !== undefined && outputs.target_effective < outputs.target_temperature - 0.01;

  /** Temperatura alvo do soprador, digitada na unidade escolhida e enviada em °C. O máximo depende da fase. */
  function editTarget() {
    const current = data.outputs?.target_temperature;
    const input = h("input", {
      class: "input num",
      type: "number",
      step: "0.5",
      inputmode: "decimal",
      value: current === null || current === undefined ? "" : f.number(f.tempValue(current), 0).replace(",", "."),
    });
    const max = data.outputs?.target_max ?? 90;
    openModal({
      title: "Temperatura alvo",
      body: h(
        "div",
        { class: "form" },
        field({
          label: "Alvo",
          input,
          suffix: f.tempUnit(),
          hint: `Máximo nesta fase: ${f.temp(max)}. O soprador sobe a temperatura aos poucos até o alvo.`,
        }),
      ),
      actions: [
        { label: "Cancelar" },
        {
          label: "Salvar",
          variant: "btn-primary",
          onClick: async (close) => {
            const typed = Number(input.value.replace(",", "."));
            const celsius = input.value.trim() === "" || Number.isNaN(typed) ? null : f.tempToCelsius(typed);
            if (celsius === null || celsius < 20 || celsius > max + 0.01) throw new Error(`Informe um valor entre ${f.tempRange(20, max)}.`);
            data.outputs = await api.patch(`${base}/outputs`, { target_temperature: Math.round(celsius * 100) / 100 });
            toast(`Alvo: ${f.temp(celsius, { digits: 0 })}.`, "success");
            close();
            draw();
          },
        },
      ],
    });
  }

  function outputsCard(unit) {
    const outputs = data.outputs;
    if (!outputs) return null;
    const row = (key) => {
      const output = outputs[key];
      const sync = output.in_sync
        ? ["ok", "checkCircle", "Confirmado pela estufa"]
        : output.confirmed_on === null || output.confirmed_on === undefined
          ? ["muted", "clock", "Ainda sem confirmação da estufa"]
          : output.confirmed_on === output.on
            ? ["muted", "clock", `Confirmado ${f.relative(outputs.confirmed_at)}`]
            : ["warn", "refresh", "Aguardando a estufa aplicar"];
      return h(
        "div",
        { class: "output-row" },
        h(
          "div",
          { class: "output-head" },
          h(
            "div",
            { class: "output-title" },
            h("strong", {}, output.name),
            h("span", { class: "small text-2" }, output.reason),
            output.values && Object.keys(output.values).length ? h("span", { class: "small muted" }, f.details(output.values)) : null,
          ),
          output.on ? badge("info", "Ligada", "power") : badge("neutral", "Desligada", "powerOff"),
          h(
            "button",
            { class: "btn btn-ghost btn-icon", type: "button", "aria-label": `Editar ${output.name}`, title: "Editar nome e regra", onClick: () => editOutput(key, output) },
            icon("edit"),
          ),
        ),
        h("p", { class: `output-sync is-${sync[0]}` }, icon(sync[1]), sync[2]),
        followsTarget(output) ? targetRow(outputs) : null,
        segmented(
          [
            { value: "auto", label: "Automático" },
            { value: "on", label: "Ligada" },
            { value: "off", label: "Desligada" },
          ],
          output.mode,
          (mode) => setOutputMode(key, mode),
          `Modo de ${output.name}`,
        ),
      );
    };
    const last = outputs.last_buzzer;

    return h(
      "section",
      { class: "card" },
      h("div", { class: "card-header" }, h("h2", {}, icon("power"), "Ventilação")),
      row("humidity"),
      h("div", { class: "divider" }),
      row("temperature"),
      last ? h("p", { class: "small text-2 output-last" }, icon("volumeUp"), `Último apito ${f.relative(last.timestamp)}: ${describeOutputEvent(last)}`) : null,
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

  function editOutput(key, output) {
    const nameInput = h("input", { class: "input", value: output.name, maxlength: 40, placeholder: "Ex.: Flap, Soprador" });
    const triggerSelect = select(OUTPUT_TRIGGERS, output.trigger);
    openModal({
      title: `Editar ${output.name}`,
      body: h("div", { class: "form" }, field({ label: "Nome", input: nameInput }), field({ label: "No automático, liga com", input: triggerSelect })),
      actions: [
        { label: "Cancelar" },
        {
          label: "Salvar",
          variant: "btn-primary",
          onClick: async (close) => {
            const name = nameInput.value.trim();
            if (!name) throw new Error("Informe o nome.");
            data.outputs = await api.patch(`${base}/outputs`, { [`${key}_name`]: name, [`${key}_trigger`]: triggerSelect.value });
            close();
            draw();
          },
        },
      ],
    });
  }

  async function setOutputMode(key, mode) {
    const name = data.outputs?.[key]?.name || "Saída";
    if (mode !== "auto") {
      const on = mode === "on";
      const confirmed = await confirmDialog({
        title: on ? `Ligar ${name}?` : `Desligar ${name}?`,
        message: on
          ? "Fica ligada até você voltar para o Automático. A caixa da estufa apita por 2 s."
          : "Fica desligada até você voltar para o Automático, mesmo que a temperatura ou a umidade saia do esperado.",
        confirmLabel: on ? "Ligar" : "Desligar",
        danger: !on,
      });
      if (!confirmed) {
        draw();
        return;
      }
    }
    try {
      data.outputs = await api.patch(`${base}/outputs`, { [`${key}_mode`]: mode });
      draw();
      toast(mode === "on" ? `${name} ligada.` : mode === "off" ? `${name} desligada.` : `${name} no automático.`, "success");
    } catch (error) {
      toast(error.message, "error");
      draw();
    }
  }

  // ---------------------------------------------------------------------------
  // Sensor

  function sensorCard(device) {
    if (!device) {
      return h(
        "section",
        { class: "card" },
        h("div", { class: "card-header" }, h("h2", {}, icon("sensors"), "Sensor")),
        h("p", { class: "text-2" }, "Nenhum sensor vinculado."),
        h("div", { class: "card-footer" }, button("Vincular sensor", { variant: "btn-primary", iconName: "link", onClick: linkDevice })),
      );
    }
    const online = device.status === "online";
    const signal = device.rssi === null || device.rssi === undefined ? "--" : signalQuality(device.rssi);
    const item = (label, value) => h("div", {}, h("dt", {}, label), h("dd", {}, value));
    return h(
      "section",
      { class: "card" },
      h("div", { class: "card-header" }, h("h2", {}, icon("sensors"), "Sensor"), online ? badge("ok", "Respondendo") : badge("offline", "Sem notícias", "cloudOff")),
      h(
        "dl",
        { class: "details" },
        item("Último contato", f.relative(device.last_seen_at)),
        item("Sinal", signal),
        device.battery_level === null || device.battery_level === undefined ? null : item("Bateria", `${device.battery_level}%${device.battery_level <= 25 ? " (baixa)" : ""}`),
      ),
      h(
        "details",
        { class: "output-events" },
        h("summary", {}, "Detalhes técnicos"),
        h(
          "dl",
          { class: "details" },
          item("ID", h("span", { class: "num" }, device.device_code)),
          device.rssi === null || device.rssi === undefined ? null : item("RSSI", `${device.rssi} dBm`),
          device.snr === null || device.snr === undefined ? null : item("SNR", f.number(device.snr)),
          item("Firmware", device.firmware_version || "--"),
          device.mac_address ? item("MAC", h("span", { class: "num" }, device.mac_address)) : null,
        ),
      ),
      h(
        "div",
        { class: "card-footer" },
        button("Verificar", {
          variant: "btn-outline btn-sm",
          iconName: "refresh",
          onClick: async (event) => {
            try {
              const result = await withBusy(event.currentTarget, () => api.post(`/devices/${device.id}/reconnect`));
              if (result.status === "online") toast("A estufa está respondendo.", "success");
              else toast("Sem resposta. Veja se a caixa da estufa está ligada e se o Wi-Fi de casa funciona.", "error");
              reload();
            } catch (error) {
              toast(error.message, "error");
            }
          },
        }),
        button("Desvincular", { variant: "btn-ghost btn-sm btn-icon-danger", iconName: "linkOff", onClick: () => unlinkDevice(device) }),
      ),
    );
  }

  function linkDevice() {
    const code = h("input", { class: "input num", placeholder: "ESP32-TOBACCO-01", autocapitalize: "characters", maxlength: 100 });
    const mac = h("input", { class: "input num", maxlength: 50 });
    openModal({
      title: "Vincular sensor",
      body: h("div", { class: "form" }, field({ label: "ID do sensor", input: code }), field({ label: "Endereço MAC (opcional)", input: mac })),
      actions: [
        { label: "Cancelar" },
        {
          label: "Vincular",
          variant: "btn-primary",
          icon: "link",
          onClick: async (close) => {
            if (!code.value.trim() && !mac.value.trim()) throw new Error("Informe o ID ou o endereço MAC.");
            const device = await api.post("/devices/link", {
              controller_id: code.value.trim() || null,
              mac_address: mac.value.trim() || null,
              curing_unit_id: unitId,
            });
            toast(`Sensor ${device.device_code} vinculado.`, "success");
            close();
            reload();
          },
        },
      ],
    });
  }

  async function unlinkDevice(device) {
    const confirmed = await confirmDialog({
      title: `Desvincular ${device.device_code}?`,
      message: "O histórico continua salvo. A estufa deixa de receber leituras deste sensor.",
      confirmLabel: "Desvincular",
      danger: true,
    });
    if (!confirmed) return;
    try {
      await api.del(`/devices/${device.id}`);
      toast("Sensor desvinculado.", "success");
      reload();
    } catch (error) {
      toast(error.message, "error");
    }
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
