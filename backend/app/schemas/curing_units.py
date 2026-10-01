from pydantic import BaseModel, Field, field_validator

from schemas.common import UTCDateTime
from schemas.readings import ReadingOut
from services.phases import NOT_STARTED, STAGES


def _known_stage(value: str | None) -> str | None:
    if value is not None and value not in STAGES:
        raise ValueError(f"Fase inválida. Use uma destas: {', '.join(STAGES)}")
    return value


class CuringUnitCreate(BaseModel):
    name: str = Field("Estufa", min_length=1, max_length=100)
    curing_stage: str = NOT_STARTED
    device_id: int | None = None
    estimated_duration_hours: float | None = Field(None, gt=0, le=1000)

    _stage = field_validator("curing_stage")(_known_stage)


class CuringUnitUpdate(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=100)
    curing_stage: str | None = None
    estimated_duration_hours: float | None = Field(None, gt=0, le=1000)

    _stage = field_validator("curing_stage")(_known_stage)


class PhaseCheck(BaseModel):
    label: str
    ok: bool
    metric: str | None = None
    target: float | None = None


class PhaseStatus(BaseModel):
    """Fase da cura em andamento, com a faixa de referência e o que falta para avançar."""

    key: str
    name: str
    number: int
    total: int
    temp_min: float
    temp_max: float
    humidity_min: float
    humidity_max: float
    min_hours: float
    max_hours: float
    hours: float
    overdue: bool
    next_stage: str
    ready: bool
    checks: list[PhaseCheck]
    visual_check: str


class CuringUnitOut(BaseModel):
    id: int
    name: str
    curing_stage: str
    device_id: int | None
    stage_started_at: UTCDateTime
    drying_started_at: UTCDateTime | None
    cycle_started_at: UTCDateTime | None = None
    # Horas com a secagem ligada, sem o tempo parado: na fase atual e na estufada inteira.
    stage_hours: float | None = None
    cycle_hours: float | None = None
    # Secagem parada no meio de uma fase: ao ligar, o produtor escolhe continuar ou começar outra estufada.
    interrupted: bool = False
    paused_at: UTCDateTime | None = None
    estimated_duration_hours: float | None
    estimated_completion_at: UTCDateTime | None = None
    is_drying: bool = False
    target_temperature: float | None = None
    device_code: str | None = None
    device_status: str | None = None
    # Presente com a secagem em andamento.
    phase: PhaseStatus | None = None
    # Só na listagem: última leitura gravada e alertas ativos (total e críticos ou piores).
    latest: ReadingOut | None = None
    active_alerts: int = 0
    critical_alerts: int = 0

    model_config = {"from_attributes": True}


class DryingEstimateOut(BaseModel):
    curing_unit_id: int
    stage: str
    remaining_hours: float | None
    estimated_completion_at: UTCDateTime | None
