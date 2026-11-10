// Formatação em português. A API trabalha em °C; a conversão para °F é só na exibição.

import { prefs } from "./store.js";

const numberFormats = new Map();

export function number(value, digits = 1) {
  if (value === null || value === undefined || Number.isNaN(value)) return "--";
  if (!numberFormats.has(digits)) {
    numberFormats.set(digits, new Intl.NumberFormat("pt-BR", { minimumFractionDigits: digits, maximumFractionDigits: digits }));
  }
  return numberFormats.get(digits).format(value);
}

export const toFahrenheit = (celsius) => (celsius * 9) / 5 + 32;
export const toCelsius = (fahrenheit) => ((fahrenheit - 32) * 5) / 9;

/** Converte °C para a unidade escolhida pelo usuário. */
export function tempValue(celsius, unit = prefs.unit) {
  if (celsius === null || celsius === undefined) return null;
  return unit === "F" ? toFahrenheit(celsius) : celsius;
}

/** Converte da unidade do usuário para °C (para enviar à API). */
export function tempToCelsius(value, unit = prefs.unit) {
  return unit === "F" ? toCelsius(value) : value;
}

export const tempUnit = (unit = prefs.unit) => (unit === "F" ? "°F" : "°C");

export function temp(celsius, { digits = 1, unit = prefs.unit } = {}) {
  if (celsius === null || celsius === undefined) return `-- ${tempUnit(unit)}`;
  return `${number(tempValue(celsius, unit), digits)} ${tempUnit(unit)}`;
}

/** Taxa de subida (°C/h na API): a conversão para °F só multiplica, sem somar 32. */
/** Diferença de temperatura (°C na API): a conversão para °F só multiplica, sem somar 32. */
export function tempDelta(celsius, { digits = 1, unit = prefs.unit } = {}) {
  if (celsius === null || celsius === undefined) return `-- ${tempUnit(unit)}`;
  return `${number(unit === "F" ? (celsius * 9) / 5 : celsius, digits)} ${tempUnit(unit)}`;
}

export function rate(celsiusPerHour, { digits = 1, unit = prefs.unit } = {}) {
  if (celsiusPerHour === null || celsiusPerHour === undefined) return `-- ${tempUnit(unit)}/h`;
  const value = unit === "F" ? (celsiusPerHour * 9) / 5 : celsiusPerHour;
  return `${number(value, digits)} ${tempUnit(unit)}/h`;
}

/** Valores citados nos motivos das saídas e nos alertas (tw, tw_limite, tseco, taxa, taxa_limite, em °C). */
export function details(values) {
  if (!values) return "";
  const parts = [];
  if (values.tseco !== undefined) parts.push(`Temperatura ${temp(values.tseco)}`);
  if (values.tw !== undefined) parts.push(`Bulbo úmido ${temp(values.tw)}`);
  if (values.tw_limite !== undefined) parts.push(`limite do úmido ${temp(values.tw_limite)}`);
  if (values.taxa !== undefined) parts.push(`subida ${rate(values.taxa)}`);
  if (values.taxa_limite !== undefined) parts.push(`subida máxima ${rate(values.taxa_limite)}`);
  return parts.join(" · ");
}

/** "95 a 104 °F" */
export function tempRange(min, max, unit = prefs.unit) {
  return `${number(tempValue(min, unit), 0)} a ${number(tempValue(max, unit), 0)} ${tempUnit(unit)}`;
}

/** "80 a 95%" */
export function humidityRange(min, max) {
  return `${number(min, 0)} a ${number(max, 0)}%`;
}

export function humidity(value, digits = 1) {
  return value === null || value === undefined ? "-- %" : `${number(value, digits)}%`;
}

export function parseDate(value) {
  if (!value) return null;
  const date = value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

const dateTimeFormat = new Intl.DateTimeFormat("pt-BR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });
const fullDateFormat = new Intl.DateTimeFormat("pt-BR", {
  day: "2-digit",
  month: "2-digit",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
});
const timeFormat = new Intl.DateTimeFormat("pt-BR", { hour: "2-digit", minute: "2-digit" });
const dayFormat = new Intl.DateTimeFormat("pt-BR", { day: "2-digit", month: "2-digit" });

export function dateTime(value) {
  const date = parseDate(value);
  return date ? dateTimeFormat.format(date) : "--";
}

export function fullDate(value) {
  const date = parseDate(value);
  return date ? fullDateFormat.format(date) : "--";
}

export function time(value) {
  const date = parseDate(value);
  return date ? timeFormat.format(date) : "--";
}

export function day(value) {
  const date = parseDate(value);
  return date ? dayFormat.format(date) : "--";
}

/** "agora", "há 12 s", "há 5 min", "há 2 h", "há 3 dias" */
export function relative(value, now = Date.now()) {
  const date = parseDate(value);
  if (!date) return "nunca";
  const seconds = Math.max(0, Math.round((now - date.getTime()) / 1000));
  if (seconds < 5) return "agora";
  if (seconds < 60) return `há ${seconds} s`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `há ${minutes} min`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `há ${hours} h`;
  const days = Math.round(hours / 24);
  return `há ${days} dia${days === 1 ? "" : "s"}`;
}

/** 29 → "1 d 5 h"; 5,4 → "5 h 24 min" */
export function duration(hours) {
  if (hours === null || hours === undefined || Number.isNaN(hours)) return "--";
  const totalMinutes = Math.max(0, Math.round(hours * 60));
  const days = Math.floor(totalMinutes / 1440);
  const h = Math.floor((totalMinutes % 1440) / 60);
  const m = totalMinutes % 60;
  if (days > 0) return h ? `${days} d ${h} h` : `${days} d`;
  if (h > 0) return m ? `${h} h ${m} min` : `${h} h`;
  return `${m} min`;
}

export function hoursSince(value, now = Date.now()) {
  const date = parseDate(value);
  return date ? (now - date.getTime()) / 3_600_000 : null;
}

export function plural(count, singular, pluralForm = `${singular}s`) {
  return `${count} ${count === 1 ? singular : pluralForm}`;
}
