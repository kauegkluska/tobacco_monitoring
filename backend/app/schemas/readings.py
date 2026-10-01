from pydantic import BaseModel, Field

from schemas.common import UTCDateTime


class TelemetryInput(BaseModel):
    """Pacote enviado pelo gateway. Temperatura e umidade são opcionais (pode ser só um sinal de vida)."""

    temperature: float | None = Field(None, ge=-40, le=125)
    humidity: float | None = Field(None, ge=0, le=100)
    curing_unit_id: int | None = None
    device_id: int | None = None
    controller_id: str | None = Field(None, max_length=100)
    device_code: str | None = Field(None, max_length=100)
    mac_address: str | None = Field(None, max_length=50)
    lora_id: str | None = Field(None, max_length=50)
    firmware_version: str | None = Field(None, max_length=50)
    battery_level: int | None = Field(None, ge=0, le=100)
    rssi: int | None = None
    snr: float | None = None
    # Estado real dos relés do sender (R1/R2 no pacote LoRa), repassado pelo receiver.
    output_humidity_state: bool | None = None
    output_temperature_state: bool | None = None


class ReadingCreate(TelemetryInput):
    temperature: float = Field(ge=-40, le=125)
    humidity: float = Field(ge=0, le=100)


class ReadingOut(BaseModel):
    id: int
    temperature: float
    humidity: float
    timestamp: UTCDateTime
    curing_unit_id: int

    model_config = {"from_attributes": True}


class SeriesPoint(BaseModel):
    timestamp: UTCDateTime
    temperature: float
    temperature_min: float
    temperature_max: float
    humidity: float
    humidity_min: float
    humidity_max: float
    count: int


class SeriesStats(BaseModel):
    count: int = 0
    temperature_min: float | None = None
    temperature_avg: float | None = None
    temperature_max: float | None = None
    humidity_min: float | None = None
    humidity_avg: float | None = None
    humidity_max: float | None = None
    first_at: UTCDateTime | None = None
    last_at: UTCDateTime | None = None


class SeriesPhase(BaseModel):
    """Trecho do período em que a estufa ficou numa fase da cura (recortado ao período pedido)."""

    stage: str
    key: str | None = None
    started_at: UTCDateTime
    ended_at: UTCDateTime
    temp_min: float | None = None
    temp_max: float | None = None
    humidity_min: float | None = None
    humidity_max: float | None = None


class SeriesOut(BaseModel):
    curing_unit_id: int
    since: UTCDateTime
    until: UTCDateTime
    bucket_seconds: int
    points: list[SeriesPoint]
    stats: SeriesStats
    phases: list[SeriesPhase] = []


class IngestResult(BaseModel):
    # Comandos das saídas lidos pelo gateway. Ficam no início da resposta porque o firmware
    # procura a primeira ocorrência de cada chave no texto.
    rele_umidade: bool = False
    rele_temperatura: bool = False
    stored: bool
    # Motivo quando a leitura não foi gravada: "no_measurement", "no_curing_unit" ou "drying_not_started".
    reason: str | None = None
    device_id: int
    curing_unit_id: int | None = None
    reading: ReadingOut | None = None
