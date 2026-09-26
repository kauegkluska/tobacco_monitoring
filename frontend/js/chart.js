// Gráfico de linha em SVG: uma série, faixa segura (limites), cursor com tooltip e teclado.

import { h } from "./dom.js";

const SVG_NS = "http://www.w3.org/2000/svg";
const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const TICK_STEPS = [5 * MINUTE, 10 * MINUTE, 15 * MINUTE, 30 * MINUTE, HOUR, 2 * HOUR, 3 * HOUR, 6 * HOUR, 12 * HOUR, DAY, 2 * DAY, 7 * DAY];

const timeTick = new Intl.DateTimeFormat("pt-BR", { hour: "2-digit", minute: "2-digit" });
const dayTick = new Intl.DateTimeFormat("pt-BR", { day: "2-digit", month: "2-digit" });

function svg(tag, attrs = {}) {
  const element = document.createElementNS(SVG_NS, tag);
  for (const [key, value] of Object.entries(attrs)) element.setAttribute(key, String(value));
  return element;
}

function niceStep(range, targetTicks) {
  const rough = range / Math.max(1, targetTicks);
  const power = 10 ** Math.floor(Math.log10(rough));
  const fraction = rough / power;
  const nice = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 2.5 ? 2.5 : fraction <= 5 ? 5 : 10;
  return nice * power;
}

function nearestIndex(points, time) {
  let low = 0;
  let high = points.length - 1;
  while (high - low > 1) {
    const mid = (low + high) >> 1;
    if (points[mid].t.getTime() < time) low = mid;
    else high = mid;
  }
  return Math.abs(points[low].t - time) <= Math.abs(points[high].t - time) ? low : high;
}

/**
 * @param {object} options
 * @param {{t: Date, v: number}[]} options.points  valores já na unidade de exibição, em ordem cronológica
 * @param {{min?: number, max?: number}} [options.limits]
 * @param {[Date, Date]} [options.domain]  período exibido no eixo X
 * @param {(v: number) => string} options.format
 * @param {(p: object) => string} [options.detail]  linha extra no tooltip
 * @param {number} [options.gapMs]  intervalo sem dados a partir do qual a linha é interrompida
 */
export function lineChart({ points, limits = null, domain = null, format, detail, gapMs = 10 * MINUTE, height = 260, label, emptyText }) {
  const container = h("div", { class: "chart" });
  if (!points.length) {
    container.append(h("div", { class: "chart-empty" }, emptyText || "Sem leituras neste período."));
    return container;
  }

  const tooltip = h("div", { class: "chart-tooltip", hidden: true });
  let width = 0;
  let activeIndex = null;
  let geometry = null;

  function render() {
    width = Math.max(280, Math.floor(container.clientWidth));
    const compact = width < 480;
    const margin = { top: 14, right: compact ? 46 : 60, bottom: 26, left: compact ? 36 : 44 };
    const plotWidth = width - margin.left - margin.right;
    const plotHeight = height - margin.top - margin.bottom;

    const start = (domain?.[0] || points[0].t).getTime();
    const endCandidate = (domain?.[1] || points[points.length - 1].t).getTime();
    const end = endCandidate > start ? endCandidate : start + HOUR;

    const values = points.map((point) => point.v);
    const extent = [...values];
    if (limits?.min !== undefined && limits?.min !== null) extent.push(limits.min);
    if (limits?.max !== undefined && limits?.max !== null) extent.push(limits.max);
    let yMin = Math.min(...extent);
    let yMax = Math.max(...extent);
    if (yMax - yMin < 2) {
      yMin -= 1;
      yMax += 1;
    }
    const step = niceStep(yMax - yMin, height < 200 ? 3 : 4);
    yMin = Math.floor(yMin / step) * step;
    yMax = Math.ceil(yMax / step) * step;

    const x = (time) => margin.left + ((time - start) / (end - start)) * plotWidth;
    const y = (value) => margin.top + (1 - (value - yMin) / (yMax - yMin)) * plotHeight;

    const root = svg("svg", {
      viewBox: `0 0 ${width} ${height}`,
      height,
      role: "img",
      tabindex: 0,
      "aria-label": label || "Gráfico",
    });

    // Grade e eixo Y
    const grid = svg("g", { class: "chart-grid" });
    const axis = svg("g", { class: "chart-axis" });
    for (let value = yMin; value <= yMax + step / 2; value += step) {
      const py = Math.round(y(value)) + 0.5;
      grid.append(svg("line", { x1: margin.left, x2: margin.left + plotWidth, y1: py, y2: py }));
      const text = svg("text", { x: margin.left - 8, y: py + 4, "text-anchor": "end" });
      text.textContent = Number.isInteger(step) ? String(Math.round(value)) : value.toFixed(1).replace(".", ",");
      axis.append(text);
    }

    // Eixo X
    const span = end - start;
    const maxTicks = Math.max(2, Math.floor(plotWidth / (compact ? 70 : 90)));
    const tickStep = TICK_STEPS.find((candidate) => span / candidate <= maxTicks) || TICK_STEPS[TICK_STEPS.length - 1];
    const offset = new Date(start).getTimezoneOffset() * MINUTE;
    let tick = Math.ceil((start - offset) / tickStep) * tickStep + offset;
    for (; tick <= end; tick += tickStep) {
      const text = svg("text", { x: x(tick), y: height - 6, "text-anchor": "middle" });
      text.textContent = tickStep >= DAY || span > 2 * DAY ? dayTick.format(tick) : timeTick.format(tick);
      axis.append(text);
    }
    root.append(grid);

    // Faixa segura entre os limites
    const hasMin = limits?.min !== undefined && limits?.min !== null;
    const hasMax = limits?.max !== undefined && limits?.max !== null;
    if (hasMin || hasMax) {
      const top = hasMax ? y(limits.max) : margin.top;
      const bottom = hasMin ? y(limits.min) : margin.top + plotHeight;
      root.append(svg("rect", { class: "chart-band", x: margin.left, y: top, width: plotWidth, height: Math.max(0, bottom - top) }));
      for (const [kind, value] of [["máx", hasMax ? limits.max : null], ["mín", hasMin ? limits.min : null]]) {
        if (value === null) continue;
        const py = Math.round(y(value)) + 0.5;
        root.append(svg("line", { class: "chart-limit", x1: margin.left, x2: margin.left + plotWidth, y1: py, y2: py }));
        // Rótulo acima da linha; abaixo só quando não há espaço no topo do gráfico.
        const labelY = py - 5 < margin.top + 10 ? py + 13 : py - 5;
        const text = svg("text", { class: "chart-limit-label", x: margin.left + 6, y: labelY });
        text.textContent = `${kind} ${format(value)}`;
        root.append(text);
      }
    }
    root.append(axis);

    // Linha e área, interrompidas onde faltaram leituras
    const segments = [];
    let current = [];
    points.forEach((point, index) => {
      if (index > 0 && point.t - points[index - 1].t > gapMs) {
        segments.push(current);
        current = [];
      }
      current.push(point);
    });
    segments.push(current);

    const baseline = margin.top + plotHeight;
    for (const segment of segments) {
      const coordinates = segment.map((point) => `${x(point.t.getTime()).toFixed(1)},${y(point.v).toFixed(1)}`);
      if (segment.length > 1) {
        const first = x(segment[0].t.getTime()).toFixed(1);
        const last = x(segment[segment.length - 1].t.getTime()).toFixed(1);
        root.append(svg("path", { class: "chart-area", d: `M${first},${baseline} L${coordinates.join(" L")} L${last},${baseline} Z` }));
        root.append(svg("path", { class: "chart-line", d: `M${coordinates.join(" L")}` }));
      } else {
        root.append(svg("circle", { class: "chart-dot", cx: x(segment[0].t.getTime()), cy: y(segment[0].v), r: 3 }));
      }
    }

    // Valor mais recente no fim da linha
    const lastPoint = points[points.length - 1];
    const lastX = x(lastPoint.t.getTime());
    const lastY = y(lastPoint.v);
    root.append(svg("circle", { class: "chart-dot", cx: lastX, cy: lastY, r: 4 }));
    const endLabel = svg("text", { class: "chart-end-label", x: Math.min(lastX + 8, width - 2), y: lastY + 4 });
    endLabel.textContent = format(lastPoint.v).replace(/\s?°[CF]$|%$/, "");
    root.append(endLabel);

    // Camada de interação
    const crosshair = svg("line", { class: "chart-crosshair", y1: margin.top, y2: baseline, visibility: "hidden" });
    const focusDot = svg("circle", { class: "chart-dot", r: 5, visibility: "hidden" });
    const hit = svg("rect", { x: margin.left, y: 0, width: plotWidth, height, fill: "transparent" });
    root.append(crosshair, focusDot, hit);

    geometry = { x, y, crosshair, focusDot, margin, plotWidth };

    const pickFromEvent = (event) => {
      const bounds = root.getBoundingClientRect();
      const px = ((event.clientX - bounds.left) / bounds.width) * width;
      const time = start + ((px - margin.left) / plotWidth) * (end - start);
      show(nearestIndex(points, time));
    };
    hit.addEventListener("pointermove", pickFromEvent);
    hit.addEventListener("pointerdown", pickFromEvent);
    hit.addEventListener("pointerleave", hide);
    root.addEventListener("keydown", (event) => {
      if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
        event.preventDefault();
        const base = activeIndex ?? points.length - 1;
        show(Math.min(points.length - 1, Math.max(0, base + (event.key === "ArrowLeft" ? -1 : 1))));
      } else if (event.key === "Escape") hide();
    });
    root.addEventListener("focus", () => show(activeIndex ?? points.length - 1));
    root.addEventListener("blur", hide);

    container.replaceChildren(root, tooltip);
    if (activeIndex !== null) show(activeIndex);
  }

  function show(index) {
    if (!geometry) return;
    activeIndex = index;
    const point = points[index];
    const px = geometry.x(point.t.getTime());
    const py = geometry.y(point.v);
    geometry.crosshair.setAttribute("x1", px);
    geometry.crosshair.setAttribute("x2", px);
    geometry.crosshair.setAttribute("visibility", "visible");
    geometry.focusDot.setAttribute("cx", px);
    geometry.focusDot.setAttribute("cy", py);
    geometry.focusDot.setAttribute("visibility", "visible");

    tooltip.replaceChildren(
      h("div", { class: "chart-tooltip-value" }, h("span", { class: "chart-tooltip-key", "aria-hidden": "true" }), format(point.v)),
      h("div", { class: "chart-tooltip-meta" }, new Intl.DateTimeFormat("pt-BR", { dateStyle: "short", timeStyle: "short" }).format(point.t)),
      detail ? h("div", { class: "chart-tooltip-meta" }, detail(point)) : null,
    );
    tooltip.hidden = false;
    const scale = container.clientWidth / width;
    const tooltipWidth = tooltip.offsetWidth;
    const left = Math.min(Math.max(0, px * scale - tooltipWidth / 2), container.clientWidth - tooltipWidth);
    tooltip.style.left = `${left}px`;
    tooltip.style.top = `${Math.max(0, py * scale - tooltip.offsetHeight - 14)}px`;
  }

  function hide() {
    activeIndex = null;
    tooltip.hidden = true;
    geometry?.crosshair.setAttribute("visibility", "hidden");
    geometry?.focusDot.setAttribute("visibility", "hidden");
  }

  const observer = new ResizeObserver(() => {
    if (Math.floor(container.clientWidth) !== width) render();
  });
  observer.observe(container);
  requestAnimationFrame(() => {
    if (!width) render();
  });
  return container;
}
