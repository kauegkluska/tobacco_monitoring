"""Fases da cura do tabaco: faixas de referência, alarmes e condições para avançar.

O SHT40 mede temperatura e umidade relativa, não bulbo úmido. Por isso os limites de umidade
relativa são usados como parâmetros indiretos de monitoramento.
"""

from dataclasses import dataclass

NOT_STARTED = "Não iniciado"
FINISHED = "Finalizado"


@dataclass(frozen=True)
class Tier:
    """Nível de um alarme: valor-limite, gravidade e por quanto tempo precisa durar."""

    threshold: float
    severity: str  # "warning", "critical" ou "emergency"
    sustain_minutes: int = 0


@dataclass(frozen=True)
class Rule:
    """Um alarme por tipo; os níveis vão do mais leve ao mais grave."""

    type: str
    metric: str  # "temperature" ou "humidity"
    direction: str  # "high" ou "low"
    tiers: tuple[Tier, ...]


@dataclass(frozen=True)
class Phase:
    key: str
    name: str
    temp_min: float
    temp_max: float
    humidity_min: float
    humidity_max: float
    min_hours: float
    max_hours: float
    rules: tuple[Rule, ...]
    # Aquecimento máximo permitido (°C/h), medido em 30 min. None: não avaliado nesta fase.
    heating_limit: float | None
    # Condições automáticas para sugerir a próxima fase (além de min_hours).
    advance_temp_at_least: float | None
    advance_humidity_at_most: float | None
    advance_humidity_falling: bool
    # O que o produtor precisa confirmar olhando as folhas antes de avançar.
    visual_check: str
    # Horas depois do início da fase em que "abaixo da faixa" ainda é esperado (estufa aquecendo).
    warmup_hours: float


def _temperature_high(*tiers: Tier) -> Rule:
    return Rule("Temperatura alta", "temperature", "high", tiers)


def _humidity_low(*tiers: Tier) -> Rule:
    return Rule("Umidade baixa", "humidity", "low", tiers)


PHASES: tuple[Phase, ...] = (
    Phase(
        key="amarelacao",
        name="Amarelação",
        temp_min=35, temp_max=40, humidity_min=80, humidity_max=95,
        min_hours=24, max_hours=48,
        rules=(
            _temperature_high(Tier(40, "warning", 10), Tier(42, "critical", 10)),
            _humidity_low(Tier(75, "warning", 15), Tier(70, "critical", 15)),
        ),
        heating_limit=None,
        advance_temp_at_least=38, advance_humidity_at_most=None, advance_humidity_falling=True,
        visual_check="Folhas amarelas e começando a murchar.",
        warmup_hours=6,
    ),
    Phase(
        key="murchamento",
        name="Murchamento",
        temp_min=40, temp_max=48, humidity_min=65, humidity_max=85,
        min_hours=12, max_hours=24,
        rules=(
            _temperature_high(Tier(50, "warning"), Tier(52, "critical")),
            _humidity_low(Tier(60, "warning")),
        ),
        heating_limit=1.5,
        advance_temp_at_least=46, advance_humidity_at_most=None, advance_humidity_falling=False,
        visual_check="Folhas completamente murchas, moles ao toque.",
        warmup_hours=3,
    ),
    Phase(
        key="secagem_folha",
        name="Secagem da folha",
        temp_min=48, temp_max=60, humidity_min=30, humidity_max=65,
        min_hours=24, max_hours=48,
        rules=(
            _temperature_high(Tier(60, "warning"), Tier(63, "critical")),
            _humidity_low(Tier(25, "warning")),
        ),
        heating_limit=1.5,
        advance_temp_at_least=55, advance_humidity_at_most=40, advance_humidity_falling=False,
        visual_check="Lâmina seca e quebradiça; só o talo ainda úmido.",
        warmup_hours=3,
    ),
    Phase(
        key="secagem_talo",
        name="Secagem do talo",
        temp_min=60, temp_max=74, humidity_min=15, humidity_max=40,
        min_hours=24, max_hours=48,
        rules=(
            _temperature_high(Tier(74, "warning"), Tier(76, "critical"), Tier(80, "emergency")),
            _humidity_low(Tier(10, "warning")),
        ),
        heating_limit=None,
        advance_temp_at_least=70, advance_humidity_at_most=None, advance_humidity_falling=False,
        visual_check="Talo seco: quebra ao dobrar.",
        warmup_hours=3,
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

# Abaixo da faixa da fase, depois do aquecimento: vale em todas as fases.
BELOW_RANGE_TYPE = "Temperatura abaixo da faixa"
BELOW_RANGE_MARGIN_C = 2.0
BELOW_RANGE_SUSTAIN_MINUTES = 30
HEATING_TYPE = "Aquecimento rápido"
NO_READINGS_TYPE = "Sem novas leituras"

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
