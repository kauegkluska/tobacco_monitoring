// Histórico: gráfico por período, resumo (mín/média/máx), tabela e exportação CSV.

import { api } from "../api.js";
import { lineChart } from "../chart.js";
import { limitsOf, loadOverview, pickUnit } from "../data.js";
import { banner, button, clear, emptyState, h, icon, loadingState, segmented, select, toast, withBusy } from "../dom.js";
import * as f from "../format.js";
import { prefs } from "../store.js";

const RANGES = [
  { value: "1h", label: "1 hora", hours: 1 },
  { value: "6h", label: "6 horas", hours: 6 },
  { value: "24h", label: "24 horas", hours: 24 },
  { value: "7d", label: "7 dias", hours: 24 * 7 },
  { value: "30d", label: "30 dias", hours: 24 * 30 },
];
const TABLE_PAGE = 20;

export function renderHistory(ctx) {
  const root = h("div", { class: "page" }, loadingState("Carregando histórico…"));
  const state = { range: "24h", metric: "temperature", overview: null, unit: null, series: null, rows: TABLE_PAGE };
  let destroyed = false;

  async function init() {
    try {
      state.overview = await loadOverview();
      state.unit = pickUnit(state.overview.units);
      if (!state.unit) {
        clear(root, emptyState("warehouse", "Nenhuma estufa cadastrada", "Cadastre uma estufa e vincule o sensor para ver o histórico.", [
          button("Cadastrar estufa", { variant: "btn-primary", iconName: "add", onClick: () => ctx.navigate("#/estufas?nova=1") }),
        ]));
        return;
      }
      await loadSeries();
    } catch (error) {
      if (!destroyed) clear(root, banner("crit", "cloudOff", "Não foi possível carregar o histórico", error.message, [button("Tentar de novo", { onClick: init })]));
    }
  }

  function period() {
    const hours = RANGES.find((range) => range.value === state.range).hours;
    const until = new Date();
    return [new Date(until.getTime() - hours * 3_600_000), until];
  }

  async function loadSeries() {
    const [since, until] = period();
    root.classList.add("is-loading");
    try {
      state.series = await api.get(
        `/curing_units/${state.unit.id}/series?since=${encodeURIComponent(since.toISOString())}&until=${encodeURIComponent(until.toISOString())}&points=240`,
      );
      state.rows = TABLE_PAGE;
      if (!destroyed) draw();
    } catch (error) {
      toast(error.message, "error");
    } finally {
      root.classList.remove("is-loading");
    }
  }

  function draw() {
    const { overview, unit, series } = state;
    const device = unit.device_id ? overview.devicesById.get(unit.device_id) : null;
    const limits = limitsOf(device);
    const isTemp = state.metric === "temperature";
    const toDisplay = (value) => (isTemp ? f.tempValue(value) : value);
    const format = (value) => (isTemp ? `${f.number(value)} ${f.tempUnit()}` : `${f.number(value)}%`);
    const stats = series.stats;

    const filters = h(
      "div",
      { class: "filters", role: "group", "aria-label": "Filtros do histórico" },
      overview.units.length > 1
        ? select(
            overview.units.map((item) => ({ value: item.id, label: item.name })),
            unit.id,
            {
              "aria-label": "Estufa",
              onChange: (event) => {
                prefs.set({ unitId: Number(event.target.value) });
                state.unit = pickUnit(overview.units);
                loadSeries();
              },
            },
          )
        : null,
      segmented(RANGES, state.range, (value) => { state.range = value; loadSeries(); }, "Período"),
      segmented(
        [
          { value: "temperature", label: "Temperatura" },
          { value: "humidity", label: "Umidade" },
        ],
        state.metric,
        (value) => { state.metric = value; draw(); },
        "Medida",
      ),
    );

    const statCard = (label, iconName, value, meta) =>
      h("div", { class: "stat" }, h("p", { class: "stat-label" }, icon(iconName), label), h("p", { class: "stat-value" }, value), meta ? h("p", { class: "stat-meta" }, meta) : null);

    const key = isTemp ? "temperature" : "humidity";
    const statsRow = h(
      "div",
      { class: "stats" },
      statCard("Mínima", "arrowDown", stats.count ? format(toDisplay(stats[`${key}_min`])) : "--"),
      statCard("Média", "average", stats.count ? format(toDisplay(stats[`${key}_avg`])) : "--"),
      statCard("Máxima", "arrowUp", stats.count ? format(toDisplay(stats[`${key}_max`])) : "--"),
      statCard("Leituras", "sensors", f.number(stats.count, 0), stats.last_at ? `Última ${f.relative(stats.last_at)}` : "Nenhuma no período"),
    );

    const points = series.points.map((point) => ({
      t: new Date(point.timestamp),
      v: toDisplay(point[key]),
      low: toDisplay(point[`${key}_min`]),
      high: toDisplay(point[`${key}_max`]),
      count: point.count,
    }));
    const rangeLabel = RANGES.find((range) => range.value === state.range).label;
    const chart = lineChart({
      points,
      limits: isTemp ? { min: f.tempValue(limits.temp_min), max: f.tempValue(limits.temp_max) } : { min: limits.humidity_min, max: limits.humidity_max },
      domain: [new Date(series.since), new Date(series.until)],
      format,
      detail: (point) => (point.count > 1 ? `${format(point.low)} a ${format(point.high)} · ${f.plural(point.count, "leitura")}` : "1 leitura"),
      gapMs: Math.max(5 * 60_000, series.bucket_seconds * 3000),
      height: 300,
      label: `${isTemp ? "Temperatura" : "Umidade"} — ${rangeLabel}`,
      emptyText: unit.is_drying ? "Nenhuma leitura neste período." : "Nenhuma leitura neste período. As leituras só são gravadas com a secagem em andamento.",
    });

    const chartCard = h(
      "section",
      { class: "card" },
      h(
        "div",
        { class: "card-header" },
        h(
          "div",
          {},
          h("h2", {}, icon(isTemp ? "thermostat" : "water"), `${isTemp ? "Temperatura" : "Umidade relativa"} · ${rangeLabel}`),
          h("p", { class: "small muted" }, series.bucket_seconds > 60 ? `Cada ponto é a média de ${f.duration(series.bucket_seconds / 3600)} de leituras. Passe o mouse ou toque para ver os valores.` : "Passe o mouse ou toque no gráfico para ver os valores."),
        ),
      ),
      chart,
    );

    clear(
      root,
      h(
        "div",
        { class: "page-header" },
        h("div", {}, h("p", { class: "eyebrow" }, "Histórico"), h("h1", {}, unit.name), h("p", { class: "page-subtitle" }, "Acompanhe como a temperatura e a umidade variaram ao longo da cura.")),
        button("Exportar CSV", { variant: "btn-outline", iconName: "download", onClick: (event) => exportCsv(event.currentTarget) }),
      ),
      filters,
      statsRow,
      chartCard,
      tableCard(format, toDisplay, key),
    );
  }

  function tableCard(format, toDisplay, key) {
    const rows = [...state.series.points].reverse();
    const visible = rows.slice(0, state.rows);
    const other = key === "temperature" ? "humidity" : "temperature";
    const formatOther = (value) => (other === "temperature" ? f.temp(value) : f.humidity(value));
    return h(
      "section",
      { class: "card" },
      h("div", { class: "card-header" }, h("h2", {}, icon("clock"), "Registros do período"), h("span", { class: "small muted" }, f.plural(rows.length, "intervalo"))),
      rows.length
        ? h(
            "div",
            { class: "table-wrap" },
            h(
              "table",
              { class: "table" },
              h(
                "thead",
                {},
                h(
                  "tr",
                  {},
                  h("th", { scope: "col" }, "Horário"),
                  h("th", { scope: "col", class: "num" }, key === "temperature" ? "Temperatura" : "Umidade"),
                  h("th", { scope: "col", class: "num" }, "Faixa no intervalo"),
                  h("th", { scope: "col", class: "num" }, other === "temperature" ? "Temperatura" : "Umidade"),
                  h("th", { scope: "col", class: "num" }, "Leituras"),
                ),
              ),
              h(
                "tbody",
                {},
                visible.map((point) =>
                  h(
                    "tr",
                    {},
                    h("td", {}, f.dateTime(point.timestamp)),
                    h("td", { class: "num" }, format(toDisplay(point[key]))),
                    h("td", { class: "num muted" }, `${format(toDisplay(point[`${key}_min`]))} a ${format(toDisplay(point[`${key}_max`]))}`),
                    h("td", { class: "num" }, formatOther(point[other])),
                    h("td", { class: "num" }, f.number(point.count, 0)),
                  ),
                ),
              ),
            ),
          )
        : h("p", { class: "text-2" }, "Sem registros no período selecionado."),
      rows.length > state.rows
        ? h("div", { class: "card-footer" }, button(`Mostrar mais (${rows.length - state.rows} restantes)`, { variant: "btn-outline", onClick: () => { state.rows += TABLE_PAGE * 2; draw(); } }))
        : null,
    );
  }

  async function exportCsv(target) {
    const [since, until] = period();
    try {
      await withBusy(target, () =>
        api.download(
          `/curing_units/${state.unit.id}/readings.csv?since=${encodeURIComponent(since.toISOString())}&until=${encodeURIComponent(until.toISOString())}`,
          `leituras-${state.unit.name.replace(/[^\w-]+/g, "_")}-${state.range}.csv`,
        ),
      );
      toast("Arquivo CSV baixado.", "success");
    } catch (error) {
      toast(error.message, "error");
    }
  }

  const unsubscribe = prefs.subscribe((changes) => {
    if ("unit" in changes && state.series) draw();
  });

  init();
  return {
    el: root,
    destroy() {
      destroyed = true;
      unsubscribe();
    },
  };
}
