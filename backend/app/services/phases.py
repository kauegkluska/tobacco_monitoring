"""Fases da cura do tabaco: faixas de referência, alarmes e condições para avançar.

O SHT40 mede temperatura e umidade relativa. O bulbo úmido, que é o que a literatura de cura controla, é estimado
a partir delas (services/psychrometrics.py). "DE" marca decisão de engenharia, a calibrar em campo.
"""

import math
from dataclasses import dataclass

NOT_STARTED = "Não iniciado"
FINISHED = "Finalizado"

TEMPERATURE_HIGH_TYPE = "Temperatura alta"
# Calor com umidade alta, medido pelo bulbo úmido estimado: principal causa de escaldadura e escurecimento.
WET_BULB_HIGH_TYPE = "Umidade alta"
DEPRESSION_HIGH_TYPE = "Ar seco na Amarelação"
HUMIDITY_LOW_TYPE = "Umidade baixa"
BELOW_RANGE_TYPE = "Temperatura abaixo da faixa"
DROP_TYPE = "Temperatura em queda"
HEATING_TYPE = "Aquecimento rápido"
NO_READINGS_TYPE = "Sem novas leituras"
SENSOR_TYPE = "Sensor suspeito"
OVERDUE_TYPE = "Permanência longa"
# Alertas informativos do controle do flap e do soprador.
VERY_WET_TYPE = "Estufa muito úmida"
WET_LOAD_TYPE = "Início da Amarelação"
MANUAL_FLAP_TYPE = "Ventilação aberta à mão"
TARGET_LIMITED_TYPE = "Alvo reduzido"
WEAK_FIRE_TYPE = "Fogo fraco"


@dataclass(frozen=True)
class Tier:
    """Nível de um alarme: valor-limite, gravidade e por quanto tempo precisa durar."""

    threshold: float
    severity: str  # "info", "warning", "critical" ou "emergency"
    sustain_minutes: int


@dataclass(frozen=True)
class Rule:
    """Um alarme por tipo; os níveis vão do mais leve ao mais grave."""

    type: str
    metric: str  # "temperature", "humidity", "wet_bulb", "depression" ou "wet_bulb_deficit" (alvo do flap menos o úmido)
    direction: str  # "high" ou "low"
    tiers: tuple[Tier, ...]


@dataclass(frozen=True)
class Phase:
    key: str
    name: str
    # Faixas exibidas e usadas pelos relés.
    temp_min: float
    temp_max: float
    humidity_min: float
    humidity_max: float
    # Mínimo para sugerir o avanço (nunca bloqueia a confirmação) e máximo de referência para o aviso informativo.
    min_hours: float
    max_hours: float
    rules: tuple[Rule, ...]
    # Aquecimento máximo permitido (°C/h).
    heating_limit: float
    # Condição de temperatura para sugerir a próxima fase (além de min_hours) e janela da média.
    advance_temp_at_least: float
    advance_temp_minutes: int
    # O que o produtor precisa confirmar olhando as folhas antes de avançar.
    visual_check: str
    # Teto da referência do alerta de queda.
    alert_temp_max: float
    # Horas iniciais da fase em que a queda é crítica; depois vira atenção.
    drop_critical_hours: float
    # Sem leituras: segundos até atenção (None: vai direto ao crítico) e até crítico.
    no_readings_warning_seconds: int | None
    no_readings_critical_seconds: int


def _temperature_high(warning: float, critical: float, minutes: int, emergency: float | None = None) -> Rule:
    tiers = (Tier(warning, "warning", minutes), Tier(critical, "critical", minutes))
    if emergency is not None:
        tiers += (Tier(emergency, "emergency", minutes),)
    return Rule(TEMPERATURE_HIGH_TYPE, "temperature", "high", tiers)


# Amarelação: diferença entre os bulbos seco e úmido. Ideal de 2 a 3 °F (1,1 a 1,7 °C, Virginia Tech); abaixo de 0,5 °C
# abre "Estufa muito úmida" (DE, dentro da incerteza da estimativa: C37, C39) e acima de 4,4 °C, "Ar seco na Amarelação".
YELLOWING_DEPRESSION_IDEAL_C = (1.1, 1.7)
VERY_WET_DEPRESSION_C = 0.5
DRY_AIR_DEPRESSION_C = 4.4
# Bulbo úmido abaixo do alvo do flap a partir do qual o Murchamento avisa "Umidade baixa" (DE).
WET_BULB_LOW_MARGIN_C = 2.0

# O manual Powell mantém o úmido em até 41,1 °C; adotou-se 40,6 °C (105 °F) por NC State, Virginia Tech e a fonte
# brasileira. Crítico a 43 °C: 2 °C abaixo dos ~45 °C em que a folha úmida morre, cobrindo a incerteza da estimativa.
_WET_BULB_HIGH = Rule(WET_BULB_HIGH_TYPE, "wet_bulb", "high", (Tier(40.6, "warning", 2), Tier(43.0, "critical", 2)))

PHASES: tuple[Phase, ...] = (
    Phase(
        key="amarelacao",
        name="Amarelação",
        temp_min=35, temp_max=40, humidity_min=80, humidity_max=95,
        min_hours=48, max_hours=60,
        rules=(
            _temperature_high(40, 42, 10),
            Rule(DEPRESSION_HIGH_TYPE, "depression", "high", (Tier(DRY_AIR_DEPRESSION_C, "warning", 15),)),
        ),
        heating_limit=1.1,
        advance_temp_at_least=38, advance_temp_minutes=10,
        visual_check="Folhas amarelas e começando a murchar.",
        alert_temp_max=40,
        drop_critical_hours=math.inf,
        no_readings_warning_seconds=None, no_readings_critical_seconds=300,
    ),
    Phase(
        key="murchamento",
        name="Murchamento",
        temp_min=40, temp_max=48, humidity_min=65, humidity_max=85,
        min_hours=18, max_hours=24,
        rules=(
            _temperature_high(47.8, 52, 2),
            _WET_BULB_HIGH,
            # Bulbo úmido 2 °C abaixo do alvo do flap por 15 min (DE).
            Rule(HUMIDITY_LOW_TYPE, "wet_bulb_deficit", "high", (Tier(WET_BULB_LOW_MARGIN_C, "info", 15),)),
        ),
        heating_limit=0.8,
        advance_temp_at_least=46, advance_temp_minutes=10,
        visual_check="Folhas completamente murchas, moles ao toque.",
        alert_temp_max=48,
        drop_critical_hours=0,
        no_readings_warning_seconds=300, no_readings_critical_seconds=1800,
    ),
    Phase(
        key="secagem_folha",
        name="Secagem da folha",
        temp_min=48, temp_max=60, humidity_min=30, humidity_max=65,
        min_hours=24, max_hours=60,
        rules=(_temperature_high(57.2, 63, 2), _WET_BULB_HIGH),
        heating_limit=1.1,
        advance_temp_at_least=54.4, advance_temp_minutes=60,
        visual_check="Lâmina seca e quebradiça; só o talo ainda úmido.",
        alert_temp_max=57.2,
        drop_critical_hours=0,
        no_readings_warning_seconds=300, no_readings_critical_seconds=1800,
    ),
    Phase(
        key="secagem_talo",
        name="Secagem do talo",
        temp_min=60, temp_max=74, humidity_min=15, humidity_max=40,
        min_hours=18, max_hours=48,
        rules=(_temperature_high(74, 77, 2, emergency=80),),
        heating_limit=1.7,
        advance_temp_at_least=70, advance_temp_minutes=10,
        visual_check="Talo seco: quebra ao dobrar.",
        alert_temp_max=74,
        drop_critical_hours=12,
        no_readings_warning_seconds=300, no_readings_critical_seconds=1800,
    ),
)

PHASE_NAMES = tuple(phase.name for phase in PHASES)
STAGES = (NOT_STARTED, *PHASE_NAMES, FINISHED)

# Nomes usados antes da divisão em quatro fases.
LEGACY_STAGES = {
    "Início da secagem": "Amarelação",
    "Amarelecimento": "Amarelação",
    "Murcha": "Murchamento",
}

# Abaixo da faixa da fase, depois da carência: vale em todas as fases.
BELOW_RANGE_MARGIN_C = 2.0
BELOW_RANGE_SUSTAIN_MINUTES = 30

SEVERITY_RANK = {"info": 0, "warning": 1, "critical": 2, "emergency": 3}


def phase_named(stage: str | None) -> Phase | None:
    for phase in PHASES:
        if phase.name == stage:
            return phase
    return None


def phase_index(phase: Phase) -> int:
    return PHASES.index(phase)


def current_phase(unit) -> Phase | None:
    """Fase em andamento. Com a secagem ligada sempre há uma; sem secagem, None."""
    if unit.drying_started_at is None:
        return None
    return phase_named(unit.curing_stage) or PHASES[0]


def next_stage(phase: Phase) -> str:
    index = phase_index(phase)
    return PHASES[index + 1].name if index + 1 < len(PHASES) else FINISHED


@dataclass(frozen=True)
class FlapSetting:
    """Flap (relé 1) no automático, pelo bulbo úmido estimado (°C). Ele nunca abre por umidade baixa."""

    # Alvo exibido; None quando a fase só tem limite de abertura (talo B).
    setpoint: float | None
    open_above: float
    close_below: float
    # Bulbo úmido acima do qual as exceções dos intertravamentos mantêm ou reabrem o flap.
    ceiling: float
    # Minutos que o bulbo úmido precisa ficar acima de `open_above` para abrir (0: abre na hora).
    open_sustain_minutes: int = 0


# Murchamento: o alvo acompanha a subida do bulbo seco de 43 °C a 48 °C (C10, C15; reta e banda: DE).
WILT_SETPOINT = ((43.0, 38.0), (48.0, 40.0))
FLAP_BAND_C = 0.5
# Teto das exceções no Murchamento e na Secagem da folha (C05, C14).
FLAP_LEAF_CEILING_C = 40.6
LEAF_SETPOINT_C = 39.5
# Talo: nas primeiras horas ainda sai água da folha e do talo (C11); banda larga pela incerteza da estimativa (C39).
STEM_A_HOURS = 18
STEM_A_SETPOINT_C = 43.0
STEM_A_BAND_C = 1.0
STEM_CEILING_C = 45.0  # DE
# Talo B: só abre com umidade muito alta e persistente (DE); fecha junto com a folha seca (C17).
STEM_B_OPEN_C = 45.0
STEM_B_CLOSE_C = 43.0
STEM_B_SUSTAIN_MINUTES = 10


def wilting_setpoint(temperature: float) -> float:
    """Alvo do bulbo úmido no Murchamento, pela reta em função do bulbo seco."""
    (t_low, sp_low), (t_high, sp_high) = WILT_SETPOINT
    fraction = min(1.0, max(0.0, (temperature - t_low) / (t_high - t_low)))
    return sp_low + fraction * (sp_high - sp_low)


def flap_setting(phase: Phase, temperature: float, hours_in_phase: float) -> FlapSetting | None:
    """Regra do flap da fase. None: o flap fica fechado no automático (Amarelação: C06, C09, C54)."""
    if phase.key == "murchamento":
        setpoint = wilting_setpoint(temperature)
        return FlapSetting(setpoint, setpoint + FLAP_BAND_C, setpoint - FLAP_BAND_C, FLAP_LEAF_CEILING_C)
    if phase.key == "secagem_folha":
        return FlapSetting(
            LEAF_SETPOINT_C, LEAF_SETPOINT_C + FLAP_BAND_C, LEAF_SETPOINT_C - FLAP_BAND_C, FLAP_LEAF_CEILING_C,
        )
    if phase.key == "secagem_talo":
        if hours_in_phase < STEM_A_HOURS:
            return FlapSetting(
                STEM_A_SETPOINT_C, STEM_A_SETPOINT_C + STEM_A_BAND_C, STEM_A_SETPOINT_C - STEM_A_BAND_C, STEM_CEILING_C,
            )
        return FlapSetting(None, STEM_B_OPEN_C, STEM_B_CLOSE_C, STEM_CEILING_C, STEM_B_SUSTAIN_MINUTES)
    return None


def flap_fallback_open(phase: Phase, hours_in_phase: float) -> bool:
    """Posição do flap sem leitura confiável (sensor suspeito): aberta no Murchamento, na Secagem da folha e no talo A
    (C05, C11, C12); fechada na Amarelação (C06) e no talo B (C11, C17)."""
    if phase.key == "secagem_talo":
        return hours_in_phase < STEM_A_HOURS
    return phase.key in ("murchamento", "secagem_folha")


def wet_bulb_limit(phase: Phase) -> float | None:
    """Bulbo úmido (°C) a partir do qual a fase avisa "Umidade alta"; None nas fases sem esse alerta."""
    rule = next((rule for rule in phase.rules if rule.type == WET_BULB_HIGH_TYPE), None)
    return rule.tiers[0].threshold if rule else None


def fan_tmax(phase: Phase) -> float:
    """Temperatura máxima da fase para o soprador: o limiar de atenção do alerta "Temperatura alta"."""
    rule = next(rule for rule in phase.rules if rule.type == TEMPERATURE_HIGH_TYPE)
    return rule.tiers[0].threshold


def limits_for(unit) -> dict | None:
    """Faixa de referência da fase atual, no formato dos antigos limites do dispositivo."""
    phase = current_phase(unit)
    if phase is None:
        return None
    return {
        "temp_min": phase.temp_min,
        "temp_max": phase.temp_max,
        "humidity_min": phase.humidity_min,
        "humidity_max": phase.humidity_max,
    }
