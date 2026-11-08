// Últimas secagens (estufadas) e o detalhe de cada uma: período, fases, leituras e alertas.

import { api } from "../api.js";
import { lineChart, phaseLegend } from "../chart.js";
import { PHASES, chartPhases } from "../data.js";
import { badge, banner, button, clear, emptyState, h, icon, loadingState, segmented, select, toast, withBusy } from "../dom.js";
import * as f from "../format.js";
import { prefs } from "../store.js";
import { alertCard, phaseSteps } from "../widgets.js";

const POLL_MS = 30_000;

/** Como a estufada terminou (ou se ainda está em andamento). */
function cycleStatus(cycle) {
  if (cycle.status === "finished") return { kind: "ok", label: "Concluída", icon: "checkCircle" };
  if (cycle.status !== "in_progress") return { kind: "warn", label: "Interrompida", icon: "close" };
  if (cycle.is_drying) return { kind: "info", label: "Em andamento", icon: "play" };
  return { kind: "offline", label: "Parada", icon: "stop" };
}

/** Número da última fase alcançada (1 a 4), ou 0. */
const stageNumber = (cycle) => PHASES.findIndex((phase) => phase.name === cycle.final_stage) + 1;

function cycleSteps(cycle) {
  const finished = cycle.status === "finished";
  return phaseSteps(finished ? null : stageNumber(cycle), finished);
}

function period(cycle) {
  const end = cycle.ended_at ? f.fullDate(cycle.ended_at) : cycle.is_drying ? "agora" : "parada";
  return `${f.fullDate(cycle.started_at)} até ${end}`;
}

function readingsLabel(count) {
  if (!count) return "Sem leituras";
  return count === 1 ? "1 leitura" : `${count.toLocaleString("pt-BR")} leituras`;
}

export function renderCycles(ctx) {
  const root = h("div", { class: "page" }, loadingState());
  const state = { unit: ctx.query.get("estufa") || "all", cycles: null };
  let timer = null;
  let destroyed = false;

  async function load() {
    try {
      const cycles = await api.get("/curing-cycles/?limit=100");
      if (destroyed) return;
      state.cycles = cycles;
      if (!root.contains(document.activeElement?.closest("select"))) draw();
    } catch (error) {
      if (destroyed) return;
      if (!state.cycles) clear(root, banner("crit", "cloudOff", "Não foi possível carregar as secagens", error.message, [button("Tentar de novo", { onClick: load })]));
    } finally {
      if (!destroyed) {
        clearTimeout(timer);
        timer = setTimeout(load, POLL_MS);
      }
    }
  }

  function draw() {
    const units = new Map(state.cycles.map((cycle) => [String(cycle.curing_unit_id), cycle.curing_unit_name]));
    const list = state.cycles.filter((cycle) => state.unit === "all" || String(cycle.curing_unit_id) === state.unit);

    clear(
      root,
      units.size > 1 || state.unit !== "all"
        ? h(
            "div",
            { class: "filters" },
            select([{ value: "all", label: "Todas as estufas" }, ...[...units].map(([value, label]) => ({ value, label }))], state.unit, {
              "aria-label": "Estufa",
              onChange: (event) => {
                state.unit = event.target.value;
                draw();
              },
            }),
          )
        : null,
      list.length
        ? h("div", { class: "grid grid-3" }, list.map(cycleCard))
        : h("section", { class: "card" }, emptyState("history", "Nenhuma secagem", "Cada estufada aparece aqui ao iniciar a secagem e fica guardada depois de finalizada.")),
    );
  }

  function cycleCard(cycle) {
    const status = cycleStatus(cycle);
    const stats = cycle.stats;
    const footer = [readingsLabel(stats.count)];
    if (cycle.alerts) footer.push(f.plural(cycle.alerts, "alerta"));
    return h(
      "a",
      { class: "card unit-card", href: `#/secagem/${cycle.id}` },
      h("div", { class: "unit-card-head" }, h("h2", {}, cycle.curing_unit_name), badge(status.kind, status.label, status.icon), icon("chevronRight", "unit-card-chevron")),
      h("p", { class: "small text-2" }, period(cycle)),
      cycleSteps(cycle),
      h(
        "dl",
        { class: "details" },
        h("div", {}, h("dt", {}, "Secagem"), h("dd", {}, f.duration(cycle.drying_hours))),
        h(
          "div",
          {},
          h("dt", {}, "Temperatura"),
          h("dd", {}, stats.count ? `média ${f.temp(stats.temperature_avg, { digits: 0 })}, máx. ${f.temp(stats.temperature_max, { digits: 0 })}` : "--"),
        ),
      ),
      h("p", { class: `unit-card-foot ${cycle.critical_alerts ? "is-crit" : ""}` }, footer.join(" · ")),
    );
  }

  const unsubscribe = prefs.subscribe((changes) => {
    if ("unit" in changes && state.cycles) draw();
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

export function renderCycle(ctx) {
  const cycleId = Number(ctx.param);
  const root = h("div", { class: "page" }, loadingState());
  const state = { metric: "temperature" };
  let cycle = null;
  let series = null;
  let destroyed = false;

  async function load() {
    try {
      const next = await api.get(`/curing-cycles/${cycleId}`);
      const since = f.parseDate(next.started_at);
      const until = next.ended_at ? f.parseDate(next.ended_at) : new Date();
      series = await api.get(
        `/curing_units/${next.curing_unit_id}/series?since=${encodeURIComponent(since.toISOString())}&until=${encodeURIComponent(until.toISOString())}&points=240`,
      );
      if (destroyed) return;
      cycle = next;
      ctx.setTitle(`Secagem · ${cycle.curing_unit_name}`);
      draw();
    } catch (error) {
      if (destroyed) return;
      if (error.status === 404) {
        toast("Secagem não encontrada.", "error");
        ctx.navigate("#/secagens");
        return;
      }
      clear(root, banner("crit", "cloudOff", "Não foi possível carregar a secagem", error.message, [button("Tentar de novo", { onClick: load })]));
    }
  }

  function draw() {
    const status = cycleStatus(cycle);
    const stats = cycle.stats;
    const range = (min, avg, max, format) => (stats.count ? `${format(min)} / ${format(avg)} / ${format(max)}` : "--");
    const temp = (value) => f.temp(value, { digits: 0 });
    const humidity = (value) => f.humidity(value, 0);
    const alerts = cycle.alert_items || [];

    clear(
      root,
      h(
        "div",
        { class: "unit-header" },
        h("a", { class: "card-link", href: "#/secagens" }, icon("chevronRight", "is-back"), "Últimas secagens"),
        h("h1", {}, cycle.curing_unit_name),
        h(
          "div",
          { class: "row" },
          badge(status.kind, status.label, status.icon),
          cycle.final_stage
            ? h(
                "span",
                { class: `phase-tag phase-${PHASES.find((phase) => phase.name === cycle.final_stage)?.key || "other"}` },
                h("span", { class: "phase-swatch", "aria-hidden": "true" }),
                `${cycle.status === "in_progress" ? "Fase atual" : "Última fase"} · ${cycle.final_stage}`,
              )
            : null,
        ),
      ),
      h(
        "div",
        { class: "grid grid-main" },
        h(
          "div",
          { class: "stack" },
          h(
            "section",
            { class: "card" },
            h("div", { class: "card-header" }, h("h2", {}, icon("eco"), "Resumo")),
            cycleSteps(cycle),
            h(
              "dl",
              { class: "details" },
              h("div", {}, h("dt", {}, "Início"), h("dd", {}, f.fullDate(cycle.started_at))),
              h("div", {}, h("dt", {}, "Fim"), h("dd", {}, cycle.ended_at ? f.fullDate(cycle.ended_at) : status.label)),
              h("div", {}, h("dt", {}, "Secagem (sem o tempo parado)"), h("dd", {}, f.duration(cycle.drying_hours))),
              h("div", {}, h("dt", {}, "Leituras"), h("dd", { class: "num" }, (stats.count || 0).toLocaleString("pt-BR"))),
              h(
                "div",
                {},
                h("dt", {}, "Alertas"),
                h("dd", { class: cycle.critical_alerts ? "is-bad" : "" }, cycle.alerts ? `${cycle.alerts}${cycle.critical_alerts ? ` (${cycle.critical_alerts} críticos ou piores)` : ""}` : "Nenhum"),
              ),
            ),
            cycle.phases.length
              ? h(
                  "div",
                  { class: "phase-next" },
                  h("h3", {}, "Tempo em cada fase"),
                  phaseLegend(
                    cycle.phases.map((phase) => ({ key: phase.key, name: phase.stage, hours: phase.hours })),
                    (phase) => f.duration(phase.hours),
                  ),
                )
              : null,
            h("div", { class: "card-footer" }, h("a", { class: "btn btn-outline", href: `#/estufa/${cycle.curing_unit_id}` }, icon("warehouse"), h("span", {}, "Abrir estufa"))),
          ),
        ),
        h("div", { class: "stack" }, chartCard(range, temp, humidity)),
      ),
      alerts.length
        ? h(
            "section",
            {},
            h("h2", { class: "section-heading" }, "Alertas desta secagem"),
            h("div", { class: "grid grid-3" }, alerts.map((alert) => alertCard(alert, { showUnit: false, onChange: load }))),
          )
        : null,
    );
  }

  function chartCard(range, temp, humidity) {
    const isTemp = state.metric === "temperature";
    const key = state.metric;
    const toDisplay = (value) => (isTemp ? f.tempValue(value) : value);
    const format = (value) => (isTemp ? `${f.number(value)} ${f.tempUnit()}` : `${f.number(value)}%`);
    const phases = chartPhases(series, isTemp);
    const stats = cycle.stats;

    return h(
      "section",
      { class: "card" },
      h(
        "div",
        { class: "card-header" },
        h("h2", {}, icon("chart"), "Temperatura e umidade"),
        button("CSV", { variant: "btn-ghost btn-sm", iconName: "download", "aria-label": "Baixar CSV da secagem", onClick: (event) => exportCsv(event.currentTarget) }),
      ),
      h(
        "dl",
        { class: "details" },
        h("div", {}, h("dt", {}, "Temperatura mín. / méd. / máx."), h("dd", {}, range(stats.temperature_min, stats.temperature_avg, stats.temperature_max, temp))),
        h("div", {}, h("dt", {}, "Umidade mín. / méd. / máx."), h("dd", {}, range(stats.humidity_min, stats.humidity_avg, stats.humidity_max, humidity))),
      ),
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
            draw();
          },
          "Medida",
        ),
      ),
      lineChart({
        points: series.points.map((point) => ({
          t: new Date(point.timestamp),
          v: toDisplay(point[key]),
          low: toDisplay(point[`${key}_min`]),
          high: toDisplay(point[`${key}_max`]),
          count: point.count,
        })),
        phases,
        domain: [new Date(series.since), new Date(series.until)],
        format,
        detail: (point) => (point.count > 1 ? `${format(point.low)} a ${format(point.high)}` : "1 leitura"),
        gapMs: Math.max(5 * 60_000, series.bucket_seconds * 3000),
        height: 260,
        label: `${isTemp ? "Temperatura" : "Umidade"} durante a secagem`,
        emptyText: "Sem leituras nesta secagem.",
      }),
      phases.length > 1 ? phaseLegend(phases) : null,
    );
  }

  async function exportCsv(target) {
    const since = f.parseDate(cycle.started_at);
    const until = cycle.ended_at ? f.parseDate(cycle.ended_at) : new Date();
    try {
      await withBusy(target, () =>
        api.download(
          `/curing_units/${cycle.curing_unit_id}/readings.csv?since=${encodeURIComponent(since.toISOString())}&until=${encodeURIComponent(until.toISOString())}`,
          `secagem-${cycle.curing_unit_name.replace(/[^\w-]+/g, "_")}-${since.toISOString().slice(0, 10)}.csv`,
        ),
      );
    } catch (error) {
      toast(error.message, "error");
    }
  }

  const unsubscribe = prefs.subscribe((changes) => {
    if ("unit" in changes && cycle) draw();
  });

  load();
  return {
    el: root,
    destroy() {
      destroyed = true;
      unsubscribe();
    },
  };
}
