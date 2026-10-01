from typing import Literal

from pydantic import BaseModel, Field, field_validator

from schemas.common import UTCDateTime

OutputMode = Literal["auto", "on", "off"]
OutputTrigger = Literal[
    "humidity_out", "humidity_high", "humidity_low",
    "temperature_out", "temperature_high", "temperature_low", "temperature_target",
]


class OutputState(BaseModel):
    name: str
    # Relé do sender: 1 (GPIO2) ou 2 (GPIO3).
    relay: int
    pin: str
    mode: OutputMode
    trigger: OutputTrigger
    # Comando enviado ao gateway.
    on: bool
    reason: str
    # Estado informado pelo sender (nulo enquanto ele não informar).
    confirmed_on: bool | None = None
    # O sender informou recentemente o mesmo estado comandado.
    in_sync: bool = False


class OutputEventOut(BaseModel):
    id: int
    timestamp: UTCDateTime
    # "humidity" ou "temperature".
    output: str
    output_name: str | None = None
    turned_on: bool
    # Verdadeiro quando o gateway toca o aviso sonoro (a saída ligou).
    buzzer: bool
    # "auto", "manual" ou "stopped" (secagem parada).
    cause: str
    # Grandeza de "value": "temperature" (°C) ou "humidity" (%).
    metric: str | None = None
    value: float | None = None
    curing_unit_id: int
    curing_unit_name: str | None = None


class OutputsOut(BaseModel):
    curing_unit_id: int
    is_drying: bool
    confirmed_at: UTCDateTime | None = None
    # Temperatura alvo em °C (regra "temperature_target"); nula até o produtor definir.
    target_temperature: float | None = None
    humidity: OutputState
    temperature: OutputState
    last_buzzer: OutputEventOut | None = None
    events: list[OutputEventOut]


class OutputsUpdate(BaseModel):
    humidity_mode: OutputMode | None = None
    temperature_mode: OutputMode | None = None
    humidity_name: str | None = Field(None, min_length=1, max_length=40)
    temperature_name: str | None = Field(None, min_length=1, max_length=40)
    humidity_trigger: OutputTrigger | None = None
    temperature_trigger: OutputTrigger | None = None
    target_temperature: float | None = Field(None, ge=20, le=90)

    @field_validator("humidity_name", "temperature_name")
    @classmethod
    def _strip(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = " ".join(value.split())
        if not value:
            raise ValueError("Informe um nome para a saída")
        return value
