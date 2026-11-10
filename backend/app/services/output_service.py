from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy.orm import Session

from core.clock import utcnow
from core.config import settings
from models.curing_unit import CuringUnit
from models.output_event import OutputEvent
from models.reading import Reading
from services import messages as msg
from services.alert_engine import HEATING_INITIAL_C, HYSTERESIS, active_alert, close_alert, raise_alert
from services.alert_signal import load_samples, persisted
from services.phases import (
    PHASES,
    FlapSetting,
    Phase,
    current_phase,
    fan_tmax,
    flap_fallback_open,
    flap_setting,
    limits_for,
    phase_named,
    TARGET_LIMITED_TYPE,
    WEAK_FIRE_TYPE,
)
from services.relays import DEFAULT_NAMES, name_of, relay_state
from services.relays import field as _get
from services.relays import held as _held
from services.stage_service import stage_hours

# Margem para o relé não ficar batendo nas regras de faixa; independente das margens dos alertas.
TEMPERATURE_HYSTERESIS_C = 0.5
HUMIDITY_HYSTERESIS = 1.0
# Metade da faixa do soprador em torno do alvo efetivo: ±2 °F.
FAN_TARGET_BAND_C = 2 / 1.8
# Rampa do alvo efetivo: para quando o bulbo seco fica tão abaixo dele, porque o fogo não acompanha (DE).
RAMP_PAUSE_BANDS = 2
# Uma lacuna entre leituras não faz a rampa saltar: cada leitura avança no máximo este tempo.
RAMP_MAX_STEP_SECONDS = 60
# Folga para o arredondamento do alvo convertido de °F no app.
TARGET_LIMIT_TOLERANCE_C = 0.01
# 4.1: flap aberto por umidade há mais que isso congela a rampa do soprador (DE; C16).
FLAP_OPEN_FREEZE_MINUTES = 15
# 4.2: com o flap aberto e o soprador ligado, queda do bulbo seco desde a abertura que fecha o flap, e por quanto
# tempo (DE). 4.3: depois disso, só reabre com o bulbo seco de volta a esta distância da abertura (DE).
FLAP_DROP_C = 1.5
FLAP_DROP_MINUTES = 3
FLAP_RECOVERY_C = 0.5
# Folga da exceção do teto: a mesma do alerta "Umidade alta", para o flap não ciclar com o bulbo úmido no teto.
FLAP_CEILING_MARGIN_C = HYSTERESIS["wet_bulb"]
# Regras que valem na hora, sem o tempo mínimo: corte do soprador pelo teto da fase e reabertura do flap travado pela
# umidade acima do teto.
IMMEDIATE_RULES = ("temperature_ceiling", "humidity_ceiling", "temperature_fallback")
# 4.4: com o sensor suspeito (congelado ou pulando), as saídas no automático seguram o estado por este tempo e depois
# vão à posição de reserva da fase (DE). A reserva desliga o soprador na hora; o flap respeita os tempos mínimos.
SENSOR_HOLD_MINUTES = 5
# A5: fechamentos por queda (4.2) nesta janela indicam que o fogo não acompanha a ventilação (DE).
WEAK_FIRE_CLOSURES = 2
WEAK_FIRE_WINDOW = timedelta(minutes=60)

OUTPUT_MODES = ("auto", "on", "off")
# "humidity" é o relé 1 do sender (GPIO2) e "temperature" o relé 2 (GPIO3).
OUTPUTS = ("humidity", "temperature")
RELAYS = {"humidity": (1, "GPIO2"), "temperature": (2, "GPIO3")}

# Regra do modo automático: grandeza medida, quando a saída liga e os textos exibidos no app.
TRIGGERS = {
    # Flap: segue o limite de bulbo úmido da fase (services/phases.py, flap_setting).
    "humidity_phase": ("wet_bulb", "phase", "a umidade passar do limite da fase", "a umidade passou do limite da fase"),
    "humidity_out": ("humidity", "out", "a umidade sair da faixa esperada", "a umidade saiu da faixa esperada"),
    "humidity_high": ("humidity", "high", "a umidade passar do máximo", "a umidade passou do máximo"),
    "humidity_low": ("humidity", "low", "a umidade ficar abaixo do mínimo", "a umidade ficou abaixo do mínimo"),
    "temperature_out": ("temperature", "out", "a temperatura sair da faixa esperada", "a temperatura saiu da faixa esperada"),
    "temperature_high": ("temperature", "high", "a temperatura passar do máximo", "a temperatura passou do máximo"),
    "temperature_low": (
        "temperature", "low", "a temperatura ficar abaixo do mínimo", "a temperatura ficou abaixo do mínimo",
    ),
    # Soprador: opera na faixa em torno do alvo efetivo, que sobe em rampa até a temperatura alvo do produtor.
    "temperature_target": (
        "temperature", "target", "a temperatura ficar abaixo da faixa do alvo", "a temperatura ficou abaixo da faixa do alvo",
    ),
}
DEFAULT_TRIGGERS = {"humidity": "humidity_phase", "temperature": "temperature_target"}


@dataclass(frozen=True)
class Signal:
    """Entrada das regras: mediana de 30 s da leitura e bulbo úmido estimado (°C)."""

    temperature: float
    humidity: float
    wet_bulb: float

    def value(self, metric: str) -> float:
        return getattr(self, metric)


def signal_of(reading: Reading | None) -> Signal | None:
    """Valores filtrados da leitura. Leitura descartada como salto, ou ainda sem filtro, não decide nada."""
    if reading is None or reading.is_outlier or reading.filtered_temperature is None:
        return None
    return Signal(reading.filtered_temperature, reading.filtered_humidity, reading.filtered_wet_bulb)


def trigger_of(unit: CuringUnit, output: str) -> str:
    trigger = _get(unit, output, "trigger")
    return trigger if trigger in TRIGGERS else DEFAULT_TRIGGERS[output]


def _auto_state(current: bool, value: float | None, low: float, high: float, margin: float, direction: str) -> bool:
    """Liga ao violar o limite e só desliga com folga dentro da faixa, para o relé não ficar batendo.

    Na regra "target", `low` e `high` são as bordas da faixa do alvo: liga abaixo dela, desliga acima dela
    e, dentro dela, mantém o estado atual. A margem não se aplica.
    """
    if value is None:
        return current
    if direction == "target":
        if value < low:
            return True
        return False if value > high else current
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


def flap_rule(unit: CuringUnit, phase: Phase, temperature: float, now: datetime) -> FlapSetting | None:
    return flap_setting(phase, temperature, stage_hours(unit, now))


def _cooling_with_flap_open(db: Session, unit: CuringUnit, now: datetime) -> bool:
    """4.2: o soprador está ligado e o bulbo seco ficou 1,5 °C abaixo do da abertura por 3 min."""
    if unit.flap_open_temperature is None or not relay_state(unit, "temperature", now):
        return False
    limit = unit.flap_open_temperature - FLAP_DROP_C
    samples = load_samples(db, unit.id, now - timedelta(minutes=FLAP_DROP_MINUTES), now)
    return persisted(samples, now, FLAP_DROP_MINUTES, lambda sample: sample.temperature <= limit)


def _flap_auto(db: Session, unit: CuringUnit, phase: Phase, signal: Signal, current: bool, now: datetime) -> tuple[bool, str]:
    """Flap pelo bulbo úmido: abre acima do limite da fase e fecha abaixo do alvo menos a banda. Nunca abre por umidade
    baixa. Com o bulbo úmido no teto da fase, os intertravamentos 4.2 e 4.3 não valem: a reabertura exige passar do
    teto, e o fechamento por queda fica impedido enquanto ele não cair abaixo do teto menos a folga."""
    setting = flap_rule(unit, phase, signal.temperature, now)
    if setting is None:
        return False, "humidity"
    if current:
        near_ceiling = signal.wet_bulb >= setting.ceiling - FLAP_CEILING_MARGIN_C
        if unit.flap_humidity_open and not near_ceiling and _cooling_with_flap_open(db, unit, now):
            return False, "drop"
        return signal.wet_bulb >= setting.close_below, "humidity"
    if unit.flap_drop_locked:
        if signal.wet_bulb > setting.ceiling:
            # Exceção da trava: reabre na hora, sem esperar o mínimo fechado.
            return True, "humidity_ceiling"
        if unit.flap_open_temperature is not None and signal.temperature < unit.flap_open_temperature - FLAP_RECOVERY_C:
            return False, "humidity"
        unit.flap_drop_locked = False
    if signal.wet_bulb <= setting.open_above:
        return False, "humidity"
    if not setting.open_sustain_minutes:
        return True, "humidity"
    minutes = setting.open_sustain_minutes
    samples = load_samples(db, unit.id, now - timedelta(minutes=minutes), now)
    return persisted(samples, now, minutes, lambda sample: sample.wet_bulb > setting.open_above), "humidity"


def _track_flap(unit: CuringUnit, state: bool, rule: str | None, signal: Signal | None) -> None:
    """Guarda a abertura por umidade e a trava de 4.3 a cada troca do flap."""
    if state and rule in ("humidity", "humidity_ceiling") and signal is not None:
        unit.flap_humidity_open = True
        unit.flap_open_temperature = signal.temperature
        unit.flap_drop_locked = False
        return
    unit.flap_humidity_open = False
    unit.flap_drop_locked = rule == "drop"
    if not unit.flap_drop_locked:
        unit.flap_open_temperature = None


def target_phase(unit: CuringUnit) -> Phase:
    """Fase que limita a temperatura alvo: a atual; com a secagem parada, a fase em que ela está ou a primeira."""
    return current_phase(unit) or phase_named(unit.curing_stage) or PHASES[0]


def target_max(phase: Phase) -> float:
    """Maior alvo aceito: a faixa do soprador não pode passar da temperatura máxima da fase (C44, C45, C46)."""
    return fan_tmax(phase) - FAN_TARGET_BAND_C


def target_allowed(unit: CuringUnit, value: float) -> bool:
    return value <= target_max(target_phase(unit)) + TARGET_LIMIT_TOLERANCE_C


def _ramp_start(phase: Phase, *candidates: float | None) -> float | None:
    """Ponto de partida da rampa; na Amarelação o aquecimento inicial é livre até HEATING_INITIAL_C."""
    values = [value for value in candidates if value is not None]
    if values and phase is PHASES[0]:
        values.append(HEATING_INITIAL_C)
    return max(values) if values else None


def set_target(db: Session, unit: CuringUnit, value: float, now: datetime) -> None:
    """Grava a temperatura alvo. Subir reinicia a rampa no maior entre o bulbo seco e o alvo efetivo atual; baixar vale
    na hora. Sem leitura recente nem rampa em andamento, a rampa começa na próxima leitura."""
    previous = unit.target_temperature
    unit.target_temperature = value
    unit.target_limited = False
    close_alert(db, active_alert(db, unit, TARGET_LIMITED_TYPE), now)
    effective = unit.target_effective
    if effective is None or previous is None or value > previous:
        signal = signal_of(recent_reading(db, unit))
        effective = _ramp_start(target_phase(unit), effective, signal.temperature if signal else None)
    if effective is not None:
        unit.target_effective = min(value, effective)
        unit.target_effective_at = now


def _limit_target(unit: CuringUnit, phase: Phase) -> bool:
    """Depois de uma troca de fase, reduz o alvo que ficou acima do máximo da nova fase. Devolve True se reduziu."""
    limit = target_max(phase)
    if unit.target_temperature is None or unit.target_temperature <= limit + TARGET_LIMIT_TOLERANCE_C:
        return False
    unit.target_temperature = limit
    unit.target_limited = True
    if unit.target_effective is not None:
        unit.target_effective = min(unit.target_effective, limit)
    return True


def ramp_frozen(unit: CuringUnit, now: datetime) -> bool:
    """4.1: o flap está aberto por umidade há mais de 15 min seguidos; a rampa do soprador para onde está."""
    opened = unit.humidity_output_changed_at
    return bool(
        unit.flap_humidity_open
        and unit.humidity_output_on
        and opened is not None
        and now - opened > timedelta(minutes=FLAP_OPEN_FREEZE_MINUTES)
    )


def _update_ramp(unit: CuringUnit, phase: Phase, signal: Signal, now: datetime) -> None:
    """Avança o alvo efetivo na taxa da fase atual, até a temperatura alvo."""
    target = unit.target_temperature
    if target is None:
        unit.target_effective = unit.target_effective_at = None
        return
    effective = unit.target_effective
    if effective is None:
        effective = _ramp_start(phase, signal.temperature)
    else:
        at = unit.target_effective_at
        seconds = 0.0 if at is None else min(max((now - at).total_seconds(), 0.0), RAMP_MAX_STEP_SECONDS)
        paused = signal.temperature < effective - RAMP_PAUSE_BANDS * FAN_TARGET_BAND_C
        if not paused and not ramp_frozen(unit, now):
            effective += phase.heating_limit * seconds / 3600
    unit.target_effective = min(target, effective)
    unit.target_effective_at = now


def _fan_auto(unit: CuringUnit, phase: Phase, signal: Signal, current: bool) -> tuple[bool, str]:
    """Soprador pelo alvo efetivo, com os cortes por teto e por taxa."""
    if unit.target_temperature is None:
        return False, "target"
    if signal.temperature >= fan_tmax(phase):
        return False, "temperature_ceiling"
    if unit.fan_rate_cut:
        return False, "rate"
    effective = unit.target_effective if unit.target_effective is not None else unit.target_temperature
    state = _auto_state(current, signal.temperature, effective - FAN_TARGET_BAND_C, effective + FAN_TARGET_BAND_C, 0.0, "target")
    return state, "target"


def sensor_state(unit: CuringUnit, now: datetime) -> str | None:
    """Falha de sensor em andamento: "hold" nos primeiros minutos, depois "fallback"; None sem falha."""
    since = unit.sensor_fault_since
    if since is None:
        return None
    return "hold" if now - since < timedelta(minutes=SENSOR_HOLD_MINUTES) else "fallback"


def _record(
    db: Session,
    unit: CuringUnit,
    output: str,
    state: bool,
    cause: str,
    now: datetime,
    metric: str | None = None,
    value: float | None = None,
    rule: str | None = None,
) -> None:
    setattr(unit, f"{output}_output_on", state)
    setattr(unit, f"{output}_output_changed_at", now)
    db.add(OutputEvent(
        output=output,
        turned_on=state,
        cause=cause,
        metric=metric,
        value=value,
        rule=rule,
        curing_unit_id=unit.id,
        timestamp=now,
    ))


def update_outputs(db: Session, unit: CuringUnit, reading: Reading | None = None, now: datetime | None = None) -> None:
    """Atualiza o comando das saídas e registra cada mudança (ligar dispara o aviso sonoro do gateway).

    O automático usa a mediana de 30 s da leitura e a fase em andamento; sem leitura válida, não muda nada.
    """
    if now is None:
        now = reading.timestamp if reading is not None else utcnow()
    signal = signal_of(reading)
    phase = current_phase(unit)
    fault = sensor_state(unit, now)
    if phase is not None and _limit_target(unit, phase):
        # A4: avisa uma vez; encerra quando o produtor grava outro alvo.
        message = msg.text(msg.TARGET_LIMITED, fan=name_of(unit, "temperature"))
        raise_alert(db, unit, TARGET_LIMITED_TYPE, "info", message, now)
    if phase is not None:
        # Sem leitura confiável, a rampa não avança.
        if signal is not None and fault is None:
            _update_ramp(unit, phase, signal, now)

    for output in OUTPUTS:
        trigger = trigger_of(unit, output)
        metric, direction, _, _ = TRIGGERS[trigger]
        mode = _get(unit, output, "mode") or "auto"
        current = bool(_get(unit, output, "on"))

        if mode in ("on", "off") or phase is None:
            # Manual ou secagem parada: os intertravamentos do automático deixam de valer.
            if output == "humidity":
                _track_flap(unit, False, None, None)
            state = mode == "on"
            if state != current:
                _record(db, unit, output, state, "manual" if mode in ("on", "off") else "stopped", now)
            continue
        if fault == "hold":
            continue
        if fault == "fallback":
            # Vale também para leituras descartadas: com o sensor pulando, quase todas são.
            if output == "humidity":
                new_state, rule = flap_fallback_open(phase, stage_hours(unit, now)), "humidity_fallback"
            else:
                new_state, rule = False, "temperature_fallback"
            if new_state == current or (rule not in IMMEDIATE_RULES and _held(unit, output, current, now)):
                continue
            if output == "humidity":
                _track_flap(unit, new_state, rule, None)
            _record(db, unit, output, new_state, "auto", now, rule=rule)
            continue
        if signal is None:
            continue

        value = signal.value(metric)
        if direction == "phase":
            new_state, rule = _flap_auto(db, unit, phase, signal, current, now)
        elif direction == "target":
            new_state, rule = _fan_auto(unit, phase, signal, current)
        else:
            limits = limits_for(unit)
            if metric == "humidity":
                low, high, margin = limits["humidity_min"], limits["humidity_max"], HUMIDITY_HYSTERESIS
            else:
                low, high, margin = limits["temp_min"], limits["temp_max"], TEMPERATURE_HYSTERESIS_C
            new_state, rule = _auto_state(current, value, low, high, margin, direction), "range"

        # O corte por teto é segurança: desliga na hora, sem esperar o tempo mínimo ligado.
        if new_state == current or (rule not in IMMEDIATE_RULES and _held(unit, output, current, now)):
            continue
        if direction == "phase":
            _track_flap(unit, new_state, rule, signal)
        _record(db, unit, output, new_state, "auto", now, metric, value, rule)
    if phase is not None:
        _evaluate_weak_fire(db, unit, now)


def _evaluate_weak_fire(db: Session, unit: CuringUnit, now: datetime) -> None:
    """A5: dois fechamentos do flap por queda (4.2) em 60 min; encerra quando a janela não tem mais dois."""
    db.flush()
    closures = (
        db.query(OutputEvent.id)
        .filter(
            OutputEvent.curing_unit_id == unit.id,
            OutputEvent.output == "humidity",
            OutputEvent.rule == "drop",
            OutputEvent.timestamp > now - WEAK_FIRE_WINDOW,
            OutputEvent.timestamp <= now,
        )
        .count()
    )
    if closures >= WEAK_FIRE_CLOSURES:
        raise_alert(db, unit, WEAK_FIRE_TYPE, "info", msg.WEAK_FIRE, now)
    else:
        close_alert(db, active_alert(db, unit, WEAK_FIRE_TYPE), now)


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
    """Última leitura válida (não descartada), se ainda for atual o bastante para decidir o modo automático."""
    reading = (
        db.query(Reading)
        .filter(
            Reading.curing_unit_id == unit.id,
            Reading.is_outlier.is_(False),
            Reading.filtered_temperature.isnot(None),
        )
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


def _reason(unit: CuringUnit, output: str, signal: Signal | None, now: datetime) -> tuple[str, dict]:
    """Motivo do estado da saída, sem números; os valores citados vão à parte, em °C."""
    mode = _get(unit, output, "mode") or "auto"
    on = bool(_get(unit, output, "on"))
    trigger = trigger_of(unit, output)
    _, _, when, because = TRIGGERS[trigger]
    if mode == "on":
        return "Ligada pelo app.", {}
    if mode == "off":
        return "Desligada pelo app.", {}
    phase = current_phase(unit)
    if phase is None:
        return "Desligada: secagem parada.", {}
    flap, fan = name_of(unit, "humidity"), name_of(unit, "temperature")
    if sensor_state(unit, now) == "fallback":
        return msg.text(msg.SENSOR_FALLBACK, fan=fan), {}
    if trigger == "humidity_phase":
        # Sem leitura recente, o alvo do Murchamento é mostrado pelo início da reta.
        setting = flap_rule(unit, phase, signal.temperature if signal else 0.0, now)
        if setting is None:
            return msg.text(msg.FLAP_YELLOWING, flap=flap, phase=phase.name), {}
        values = {"tw_limite": setting.open_above}
        if signal is not None:
            values.update(tw=signal.wet_bulb, tseco=signal.temperature)
        if on:
            return msg.text(msg.FLAP_OPEN, flap=flap), values
        if unit.flap_drop_locked:
            return msg.text(msg.FLAP_DROP_CLOSED, flap=flap), values
        return msg.text(msg.FLAP_CLOSED, flap=flap), values
    if trigger == "temperature_target":
        if unit.target_temperature is None:
            return "Desligada: defina a temperatura alvo.", {}
        values = {"tseco": signal.temperature} if signal is not None else {}
        if not on and signal is not None and signal.temperature >= fan_tmax(phase):
            return msg.text(msg.FAN_CEILING, fan=fan), values
        if not on and unit.fan_rate_cut:
            return msg.text(msg.FAN_RATE, fan=fan), {**values, "taxa_limite": phase.heating_limit}
        parts = []
        if unit.target_limited:
            parts.append(msg.text(msg.TARGET_LIMITED, fan=fan))
        if ramp_frozen(unit, now):
            parts.append(msg.text(msg.RAMP_FROZEN, flap=flap))
        elif unit.target_effective is not None and unit.target_effective < unit.target_temperature - TARGET_LIMIT_TOLERANCE_C:
            parts.append(msg.RAMP)
            values["taxa_limite"] = phase.heating_limit
        if parts:
            return " ".join(parts), values
    if on:
        return f"Ligada porque {because}.", {}
    return f"Liga quando {when}.", {}


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
    now = utcnow()
    signal = signal_of(recent_reading(db, unit))
    reasons = {output: _reason(unit, output, signal, now) for output in OUTPUTS}
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
        "target_effective": unit.target_effective,
        "target_max": target_max(target_phase(unit)),
        **{
            output: {
                "name": name_of(unit, output),
                "relay": RELAYS[output][0],
                "pin": RELAYS[output][1],
                "mode": _get(unit, output, "mode") or "auto",
                "trigger": trigger_of(unit, output),
                "on": bool(_get(unit, output, "on")),
                "reason": reasons[output][0],
                "values": reasons[output][1],
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
        "rule": event.rule,
        "curing_unit_id": event.curing_unit_id,
        "curing_unit_name": unit.name if unit else None,
    }
