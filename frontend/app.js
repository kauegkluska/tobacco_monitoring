const API_URL = 'http://127.0.0.1:8000/readings/readings/';
const POLL_INTERVAL = 1000;

const temperatureElement = document.querySelector('#temperature');
const humidityElement = document.querySelector('#humidity');
const updatedElement = document.querySelector('#updated-at');
const statusText = document.querySelector('#status-text');
const statusDot = document.querySelector('#status-dot');
const refreshButton = document.querySelector('#refresh-button');
let loading = false;

function setStatus(message, state) {
  statusText.textContent = message;
  statusDot.className = `status-dot ${state}`;
}

async function loadReading() {
  if (loading) return;
  loading = true;
  refreshButton.disabled = true;
  try {
    const response = await fetch(`${API_URL}?_=${Date.now()}`, { cache: 'no-store' });
    if (!response.ok) throw new Error(`API returned ${response.status}`);

    const readings = await response.json();
    if (!readings.length) throw new Error('No readings available');

    const latest = readings.reduce((current, reading) => (
      new Date(reading.timestamp) > new Date(current.timestamp) ? reading : current
    ));

    const temperatureCelsius = Number(latest.temperature);
    const temperatureFahrenheit = (temperatureCelsius * 9 / 5) + 32;
    temperatureElement.textContent = temperatureFahrenheit.toFixed(1);
    humidityElement.textContent = Number(latest.humidity).toFixed(1);
    updatedElement.textContent = new Date(latest.timestamp).toLocaleString('pt-BR');
    setStatus('Conectado · dados em tempo real', 'online');
  } catch (error) {
    setStatus('Não foi possível acessar a API', 'error');
    console.error(error);
  } finally {
    loading = false;
    refreshButton.disabled = false;
  }
}

refreshButton.addEventListener('click', loadReading);
loadReading();
setInterval(loadReading, POLL_INTERVAL);
