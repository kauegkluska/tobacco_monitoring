from pydantic import BaseModel

from schemas.alerts import AlertOut
from schemas.common import UTCDateTime
from schemas.readings import SeriesStats


class CyclePhaseHours(BaseModel):
    stage: str
    key: str | None = None
    hours: float


class CuringCycleOut(BaseModel):
    """Uma estufada: período, como terminou e o resumo das leituras e alertas."""

    id: int
    curing_unit_id: int
    curing_unit_name: str
    started_at: UTCDateTime
    ended_at: UTCDateTime | None
    # "in_progress", "finished" (cura concluída) ou "stopped" (encerrada antes de concluir).
    status: str
    # Fase atual (em andamento) ou última fase em que a estufada esteve.
    final_stage: str | None
    is_drying: bool
    # Horas com a secagem ligada, sem o tempo parado.
    drying_hours: float
    phases: list[CyclePhaseHours]
    stats: SeriesStats
    alerts: int
    critical_alerts: int


class CuringCycleDetail(CuringCycleOut):
    alert_items: list[AlertOut] = []
