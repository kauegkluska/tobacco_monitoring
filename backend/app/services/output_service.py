from datetime import timedelta

from sqlalchemy.orm import Session

from core.clock import utcnow
from core.config import settings
from models.curing_unit import CuringUnit
from models.output_event import OutputEvent
from models.reading import Reading
from services.alert_engine import HUMIDITY_HYSTERESIS, TEMPERATURE_HYSTERESIS_C
from services.phases import limits_for

OUTPUT_MODES = ("auto", "on", "off")
# "humidity" é o relé 1 do sender (GPIO2) e "temperature" o relé 2 (GPIO3).
OUTPUTS = ("humidity", "temperature")
RELAYS = {"humidity": (1, "GPIO2"), "temperature": (2, "GPIO3")}

# Regra do modo automático: grandeza medida, quando a saída liga e os textos exibidos no app.
TRIGGERS = {
    "humidity_out": ("humidity", "out", "a umidade sair da faixa esperada", "a umidade saiu da faixa esperada"),
    "humidity_high": ("humidity", "high", "a umidade passar do máximo", "a umidade passou do máximo"),
    "humidity_low": ("humidity", "low", "a umidade ficar abaixo do mínimo", "a umidade ficou abaixo do mínimo"),
    "temperature_out": ("temperature", "out", "a temperatura sair da faixa esperada", "a temperatura saiu da faixa esperada"),
    "temperature_high": ("temperature", "high", "a temperatura passar do máximo", "a temperatura passou do máximo"),
    "temperature_low": (
        "temperature", "low", "a temperatura ficar abaixo do mínimo", "a temperatura ficou abaixo do mínimo",
    ),
    # Ventoinha: liga abaixo da temperatura alvo definida pelo produtor e desliga ao atingi-la.
    "temperature_target": (
        "temperature", "target", "a temperatura ficar abaixo do alvo", "a temperatura está abaixo do alvo",
    ),
}
DEFAULT_TRIGGERS = {"humidity": "humidity_out", "temperature": "temperature_target"}
DEFAULT_NAMES = {"humidity": "Flap", "temperature": "Ventoinha"}


def _get(unit: CuringUnit, output: str, field: str):
    return getattr(unit, f"{output}_output_{field}")


def trigger_of(unit: CuringUnit, output: str) -> str:
    trigger = _get(unit, output, "trigger")
    return trigger if trigger in TRIGGERS else DEFAULT_TRIGGERS[output]


def name_of(unit: CuringUnit, output: str) -> str:
    return _get(unit, output, "name") or DEFAULT_NAMES[output]


def _auto_state(current: bool, value: float | None, low: float, high: float, margin: float, direction: str) -> bool:
    """Liga ao violar o limite e só desliga com folga dentro da faixa, para o relé não ficar batendo.

    Na regra "target", `low` é a temperatura alvo: liga abaixo de alvo − margem e desliga ao atingir o alvo.
    """
    if value is None:
        return current
    if direction == "target":
        if value < low - margin:
            return True
        return False if value >= low else current
    too_high = value > high
    too_low = value < low
    if direction == "high":
        if too_high:
            return True
        return current if value > high - margin else False
    if direction == "low":
        if too_low:
            return True
        return current if value < low + margin else False
    if too_high or too_low:
        return True
    if low + margin <= value <= high - margin:
        return False
    return current


def update_outputs(
    db: Session,
    unit: CuringUnit,
    temperature: float | None = None,
    humidity: float | None = None,
) -> None:
    """Atualiza o comando das saídas e registra cada mudança (ligar dispara o aviso sonoro do gateway).

    No automático, a faixa esperada é a da fase da cura em andamento.
    """
    limits = limits_for(unit)
    now = utcnow()

    for output in OUTPUTS:
        metric, direction, _, _ = TRIGGERS[trigger_of(unit, output)]
        mode = _get(unit, output, "mode") or "auto"
        current = bool(_get(unit, output, "on"))
        value = humidity if metric == "humidity" else temperature

        if mode == "on":
            new_state, cause = True, "manual"
        elif mode == "off":
            new_state, cause = False, "manual"
        elif limits is None:
            new_state, cause = False, "stopped"
        elif direction == "target":
            # Sem temperatura alvo definida, a ventoinha fica desligada.
            target = unit.target_temperature
            new_state = False if target is None else _auto_state(
                current, value, target, target, TEMPERATURE_HYSTERESIS_C, direction,
            )
            cause = "auto"
        else:
            if metric == "humidity":
                low, high, margin = limits["humidity_min"], limits["humidity_max"], HUMIDITY_HYSTERESIS
            else:
                low, high, margin = limits["temp_min"], limits["temp_max"], TEMPERATURE_HYSTERESIS_C
            new_state, cause = _auto_state(current, value, low, high, margin, direction), "auto"

        if new_state == current:
            continue
        setattr(unit, f"{output}_output_on", new_state)
        automatic = cause == "auto" and value is not None
        db.add(OutputEvent(
            output=output,
            turned_on=new_state,
            cause=cause,
            metric=metric if automatic else None,
            value=value if automatic else None,
            curing_unit_id=unit.id,
            timestamp=now,
        ))


def record_confirmation(unit: CuringUnit, humidity_state: bool | None, temperature_state: bool | None) -> None:
    """Guarda o estado real dos relés informado pelo sender."""
    if humidity_state is None and temperature_state is None:
        return
    if humidity_state is not None:
        unit.humidity_output_confirmed = humidity_state
    if temperature_state is not None:
        unit.temperature_output_confirmed = temperature_state
    unit.outputs_confirmed_at = utcnow()


def recent_reading(db: Session, unit: CuringUnit) -> Reading | None:
    """Última leitura, se ainda for atual o bastante para decidir o modo automático."""
    reading = (
        db.query(Reading)
        .filter(Reading.curing_unit_id == unit.id)
        .order_by(Reading.timestamp.desc())
        .first()
    )
    if reading is None or utcnow() - reading.timestamp > timedelta(seconds=settings.DEVICE_OFFLINE_SECONDS):
        return None
    return reading


def commands(unit: CuringUnit | None) -> dict:
    """Chaves lidas pelo firmware do gateway (receiver.ino)."""
    if unit is None:
        return {"rele_umidade": False, "rele_temperatura": False}
    return {
        "rele_umidade": bool(unit.humidity_output_on),
        "rele_temperatura": bool(unit.temperature_output_on),
    }


def _reason(unit: CuringUnit, output: str) -> str:
    mode = _get(unit, output, "mode") or "auto"
    on = bool(_get(unit, output, "on"))
    _, _, when, because = TRIGGERS[trigger_of(unit, output)]
    if mode == "on":
        return "Ligada pelo app."
    if mode == "off":
        return "Desligada pelo app."
    if unit.drying_started_at is None:
        return "Desligada: secagem parada."
    if trigger_of(unit, output) == "temperature_target" and unit.target_temperature is None:
        return "Desligada: defina a temperatura alvo."
    if on:
        return f"Ligada: {because}."
    return f"Liga quando {when}."


def _confirmation(unit: CuringUnit, output: str) -> dict:
    confirmed = _get(unit, output, "confirmed")
    at = unit.outputs_confirmed_at
    fresh = at is not None and utcnow() - at <= timedelta(seconds=settings.DEVICE_OFFLINE_SECONDS)
    return {
        "confirmed_on": confirmed,
        # Verdadeiro quando o sender informou recentemente o mesmo estado comandado.
        "in_sync": bool(fresh and confirmed is not None and confirmed == bool(_get(unit, output, "on"))),
    }


def describe(db: Session, unit: CuringUnit, events: int = 10) -> dict:
    recent = (
        db.query(OutputEvent)
        .filter(OutputEvent.curing_unit_id == unit.id)
        .order_by(OutputEvent.id.desc())
        .limit(events)
        .all()
    )
    last_buzzer = (
        db.query(OutputEvent)
        .filter(OutputEvent.curing_unit_id == unit.id, OutputEvent.turned_on.is_(True))
        .order_by(OutputEvent.id.desc())
        .first()
    )
    return {
        "curing_unit_id": unit.id,
        "is_drying": unit.drying_started_at is not None,
        "confirmed_at": unit.outputs_confirmed_at,
        "target_temperature": unit.target_temperature,
        **{
            output: {
                "name": name_of(unit, output),
                "relay": RELAYS[output][0],
                "pin": RELAYS[output][1],
                "mode": _get(unit, output, "mode") or "auto",
                "trigger": trigger_of(unit, output),
                "on": bool(_get(unit, output, "on")),
                "reason": _reason(unit, output),
                **_confirmation(unit, output),
            }
            for output in OUTPUTS
        },
        "last_buzzer": serialize_event(last_buzzer, unit) if last_buzzer else None,
        "events": [serialize_event(event, unit) for event in recent],
    }


def serialize_event(event: OutputEvent, unit: CuringUnit | None = None) -> dict:
    unit = unit or event.curing_unit
    return {
        "id": event.id,
        "timestamp": event.timestamp,
        "output": event.output,
        "output_name": name_of(unit, event.output) if unit else DEFAULT_NAMES.get(event.output),
        "turned_on": event.turned_on,
        "buzzer": event.turned_on,
        "cause": event.cause,
        # Eventos antigos, sem "metric", vinham sempre da grandeza de mesmo nome da saída.
        "metric": event.metric or (event.output if event.value is not None else None),
        "value": event.value,
        "curing_unit_id": event.curing_unit_id,
        "curing_unit_name": unit.name if unit else None,
    }
