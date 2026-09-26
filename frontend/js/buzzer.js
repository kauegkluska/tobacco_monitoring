// Aviso sonoro: o gateway bipa quando uma saída liga; o painel repete o aviso neste aparelho.

import { api } from "./api.js";
import { toast } from "./dom.js";
import * as f from "./format.js";
import { prefs } from "./store.js";

const POLL_MS = 5000;

let audio = null;
let timer = null;
let lastId = null;
let generation = 0;

/** Três bipes curtos, parecidos com o buzzer do gateway, e vibração no celular. */
export function playBeep() {
  try {
    audio ??= new (window.AudioContext || window.webkitAudioContext)();
    if (audio.state === "suspended") audio.resume();
    const start = audio.currentTime + 0.02;
    for (let i = 0; i < 3; i += 1) {
      const t = start + i * 0.34;
      const oscillator = audio.createOscillator();
      const gain = audio.createGain();
      oscillator.type = "square";
      oscillator.frequency.value = 2700;
      gain.gain.setValueAtTime(0.0001, t);
      gain.gain.exponentialRampToValueAtTime(0.12, t + 0.01);
      gain.gain.setValueAtTime(0.12, t + 0.2);
      gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.22);
      oscillator.connect(gain).connect(audio.destination);
      oscillator.start(t);
      oscillator.stop(t + 0.23);
    }
  } catch (_) {
    // Navegador sem Web Audio: o aviso na tela continua aparecendo.
  }
  try {
    navigator.vibrate?.([220, 120, 220, 120, 220]);
  } catch (_) {
    // Sem vibração neste aparelho.
  }
}

/** Regras do modo automático das saídas (mesmos códigos da API). */
export const OUTPUT_TRIGGERS = [
  { value: "humidity_out", label: "Umidade fora da faixa segura" },
  { value: "humidity_high", label: "Umidade acima do máximo" },
  { value: "humidity_low", label: "Umidade abaixo do mínimo" },
  { value: "temperature_out", label: "Temperatura fora da faixa segura" },
  { value: "temperature_high", label: "Temperatura acima do máximo" },
  { value: "temperature_low", label: "Temperatura abaixo do mínimo" },
];

/** Ex.: "Ventoinhas ligou (automático, 46,0 °C)". */
export function describeOutputEvent(event) {
  const name = event.output_name || (event.output === "temperature" ? "Saída de temperatura" : "Saída de umidade");
  const action = event.turned_on ? "ligou" : "desligou";
  const value =
    event.value === null || event.value === undefined
      ? null
      : event.metric === "temperature"
        ? f.temp(event.value)
        : f.humidity(event.value);
  const cause =
    event.cause === "manual" ? "pelo painel" : event.cause === "stopped" ? "secagem parada" : value ? `automático, ${value}` : "automático";
  return `${name} ${action} (${cause})`;
}

async function poll(current) {
  try {
    const after = lastId;
    const events = await api.get(after === null ? "/output-events/?limit=1" : `/output-events/?after_id=${after}&limit=20`);
    if (current !== generation) return;
    if (events.length) lastId = events[0].id;
    // Na primeira consulta só marca onde parou: avisos antigos não tocam de novo.
    lastId ??= 0;
    const rang = events.filter((event) => event.buzzer);
    if (after !== null && rang.length) {
      if (prefs.sound) playBeep();
      const event = rang[0];
      const where = event.curing_unit_name ? ` em ${event.curing_unit_name}` : "";
      const extra = rang.length > 1 ? ` (+${rang.length - 1})` : "";
      toast(`Aviso sonoro${where}: ${describeOutputEvent(event)}${extra}`, "warning");
    }
  } catch (_) {
    // O indicador de conexão já mostra a falha.
  } finally {
    if (current === generation && api.isAuthenticated) timer = setTimeout(() => poll(current), POLL_MS);
  }
}

export function startBuzzerWatch() {
  stopBuzzerWatch();
  lastId = null;
  poll(generation);
}

export function stopBuzzerWatch() {
  generation += 1;
  clearTimeout(timer);
  timer = null;
}
