"""Alarmes da cura. Cada leitura é filtrada e avaliada com as regras da fase atual.

Há no máximo um alerta ativo de cada tipo por estufa. Quando a gravidade sobe, o alerta antigo é encerrado e um novo
é aberto, para notificar de novo; quando cai, o mesmo alerta é atualizado, sem notificar.
"""

import math
from datetime import datetime, timedelta
from itertools import pairwise

from sqlalchemy import func, or_
from sqlalchemy.orm import Session

from core.clock import utcnow
from core.config import settings
from models.alert import Alert
from models.curing_unit import CuringUnit
from models.device import Device
from models.output_event import OutputEvent
from models.reading import Reading
from services import messages as msg
from services.alert_signal import (
    PERSISTENCE_FRACTION,
    Sample,
    load_samples,
    minute_means,
    persisted,
    prepare_reading,
    slope_per_hour,
    window_ratio,
)
from services.phases import (
    BELOW_RANGE_MARGIN_C,
    BELOW_RANGE_SUSTAIN_MINUTES,
    BELOW_RANGE_TYPE,
    DEPRESSION_HIGH_TYPE,
    DROP_TYPE,
    HEATING_TYPE,
    HUMIDITY_LOW_TYPE,
    MANUAL_FLAP_TYPE,
    VERY_WET_TYPE,
    WET_LOAD_TYPE,
    NO_READINGS_TYPE,
    OVERDUE_TYPE,
    PHASES,
    SENSOR_TYPE,
    SEVERITY_RANK,
    TEMPERATURE_HIGH_TYPE,
    WET_BULB_HIGH_TYPE,
    Phase,
    Rule,
    Tier,
    current_phase,
    wilting_setpoint,
)
from services.relays import field, held, mode_of, name_of, relay_state
from services.stage_service import stage_hours

# Folga e tempo para encerrar ou rebaixar um alerta, para ele não oscilar perto do limite (DE).
HYSTERESIS = {"temperature": 0.5, "wet_bulb": 0.5, "depression": 0.5, "humidity": 3.0, "wet_bulb_deficit": 0.5}
CLEAR_MINUTES = 2

# A janela maior usada pelas regras (abaixo da faixa e condensação).
SAMPLE_WINDOW = timedelta(minutes=30)
RULE_TYPES = (TEMPERATURE_HIGH_TYPE, WET_BULB_HIGH_TYPE, DEPRESSION_HIGH_TYPE, HUMIDITY_LOW_TYPE)

# Carência da Amarelação: enxugar as folhas e manter ~12 h a 90 °F, mais a subida desde a temperatura inicial.
START_HOLD_HOURS = 12
# Carência nas demais fases, além do tempo de subida (DE).
ENTRY_MARGIN_HOURS = 1

# Acima de 135 °F o úmido deixa de ser crítico e o recomendado é mantê-lo alto; a folga evita liga-desliga (DE).
WET_BULB_CUTOFF_C = 57.2
WET_BULB_CUTOFF_MARGIN_C = 0.5

# Queda: 5 °F vem do procedimento de religamento do manual Powell, não de um limiar de dano (DE).
DROP_MARGIN_C = 2.8
DROP_CLEAR_MARGIN_C = 1.0
DROP_SUSTAIN_MINUTES = 5
# Depois de "Temperatura alta", a queda é a correção pedida. "Umidade alta" não suprime: com ela o flap abre por
# umidade, e a causa da queda precisa aparecer no texto.
DROP_SUPPRESSION = timedelta(hours=2)
# Janela das aberturas do flap que explicam uma queda.
DROP_FLAP_WINDOW = timedelta(minutes=10)

HEATING_HOLD_MINUTES = 10
HEATING_CLEAR_MARGIN = 0.3
HEATING_RESUME_LIMIT = timedelta(hours=2)
# Até 90 °F a estufa ainda está saindo da temperatura ambiente.
HEATING_INITIAL_C = 32.2

SENSOR_FROZEN_MINUTES = 10
# Com menos amostras que isso não dá para afirmar que o valor congelou.
SENSOR_FROZEN_MIN_SAMPLES = 20
SENSOR_JUMP_WINDOW_MINUTES = 5
SENSOR_JUMP_COUNT = 3
SENSOR_NORMAL_MINUTES = 10
SATURATED_HUMIDITY = 99.0
SATURATED_MINUTES = 30

# A1 "Estufa muito úmida" na Amarelação: depressão do bulbo úmido para abrir e para encerrar, e por quanto tempo (DE;
# o limiar fica dentro da incerteza da estimativa, C37 e C39).
VERY_WET_DEPRESSION_C = 0.5
VERY_WET_MINUTES = 30
VERY_WET_CLEAR_C = 1.0
VERY_WET_CLEAR_MINUTES = 10
# A3: flap aberto à mão na Amarelação por mais que isso (DE; C51, C06).
MANUAL_FLAP_HOURS = 12


def _over(value: float, direction: str, threshold: float) -> bool:
    return value > threshold if direction == "high" else value < threshold


def _active(db: Session, unit: CuringUnit, alert_type: str) -> Alert | None:
    return (
        db.query(Alert)
        .filter(Alert.curing_unit_id == unit.id, Alert.type == alert_type, Alert.is_active.is_(True))
        .first()
    )


def _metric(sample: Sample, metric: str) -> float:
    if metric == "wet_bulb_deficit":
        # Quanto o bulbo úmido está abaixo do alvo do flap no Murchamento.
        return wilting_setpoint(sample.temperature) - sample.wet_bulb
    return getattr(sample, metric)


def _close(db: Session, alert: Alert | None, now: datetime) -> None:
    if alert is not None:
        alert.is_active = False
        alert.resolved_at = now
        db.flush()


def _raise(
    db: Session,
    unit: CuringUnit,
    alert_type: str,
    severity: str,
    message: str,
    now: datetime,
    value: float | None = None,
    threshold: float | None = None,
    details: dict | None = None,
) -> None:
    """Abre o alerta, ou o substitui por um mais grave. Mesma gravidade: mantém o atual."""
    active = _active(db, unit, alert_type)
    if active is not None:
        if SEVERITY_RANK.get(severity, 0) <= SEVERITY_RANK.get(active.severity, 0):
            return
        _close(db, active, now)
    db.add(Alert(
        type=alert_type,
        message=message[:255],
        severity=severity,
        value=value,
        threshold=threshold,
        details=details,
        curing_unit_id=unit.id,
        timestamp=now,
    ))
    db.flush()


def _update(
    alert: Alert,
    severity: str,
    message: str,
    value: float | None,
    threshold: float | None,
    details: dict | None = None,
) -> None:
    alert.severity = severity
    alert.message = message[:255]
    alert.value = value
    alert.threshold = threshold
    alert.details = details


# Para o serviço das saídas, que abre os alertas A4 e A5.
active_alert = _active
close_alert = _close
raise_alert = _raise


def _flap_names(unit: CuringUnit) -> dict:
    return {"flap": name_of(unit, "humidity"), "fan": name_of(unit, "temperature")}


def _wet_bulb_high_message(unit: CuringUnit, now: datetime) -> str:
    """"Umidade alta" pelo estado do flap: o confirmado pelo sender, se recente; senão, o comandado."""
    names = _flap_names(unit)
    if relay_state(unit, "humidity", now):
        return msg.text(msg.WET_HIGH_OPEN, **names)
    if mode_of(unit, "humidity") == "auto":
        if unit.flap_drop_locked:
            return msg.text(msg.WET_HIGH_LOCKED, **names)
        if held(unit, "humidity", False, now):
            return msg.text(msg.WET_HIGH_SOON, **names)
    return msg.text(msg.WET_HIGH_CLOSED, **names)


def _message(rule: Rule, phase: Phase, unit: CuringUnit, now: datetime) -> str:
    """O que aconteceu e o que fazer, em linguagem do produtor. Os valores vão em campos que o app converte."""
    if rule.type == TEMPERATURE_HIGH_TYPE:
        base = f"Passou do limite na fase de {phase.name}."
        if phase.key == "murchamento":
            return f"{base} Reduza o fogo. Só mantenha assim por 4 a 6 h se as folhas de cima ainda não murcharam após cerca de 12 h."
        if phase.key == "secagem_folha":
            return f"{base} Se as lâminas de baixo já secaram, passe para a Secagem do talo; senão, reduza o fogo."
        return f"{base} Reduza o fogo."
    if rule.type == WET_BULB_HIGH_TYPE:
        return _wet_bulb_high_message(unit, now)
    if rule.type == DEPRESSION_HIGH_TYPE:
        open_ = relay_state(unit, "humidity", now)
        return msg.text(msg.DRY_OPEN if open_ else msg.DRY_CLOSED, **_flap_names(unit))
    if rule.type == HUMIDITY_LOW_TYPE:
        return msg.LOW_WILTING
    return f"Temperatura baixa para a fase de {phase.name}. Veja a fornalha e a lenha."


# Diferenças de temperatura: o app converteria como temperatura, então vão só nos detalhes.
_DIFFERENCES = ("depression", "wet_bulb_deficit")


def _shown_value(rule: Rule, sample: Sample) -> float | None:
    return None if rule.metric in _DIFFERENCES else getattr(sample, rule.metric)


def _shown_threshold(rule: Rule, tier: Tier) -> float | None:
    return None if rule.metric in _DIFFERENCES else tier.threshold


def _details(rule: Rule, sample: Sample, tier: Tier) -> dict | None:
    """Valores citados pelo alerta, em °C, com as chaves que o app formata."""
    if rule.metric == "wet_bulb":
        return {"tw": sample.wet_bulb, "tw_limite": tier.threshold, "tseco": sample.temperature}
    if rule.metric == "wet_bulb_deficit":
        return {"tw": sample.wet_bulb, "tw_limite": wilting_setpoint(sample.temperature) - tier.threshold, "tseco": sample.temperature}
    if rule.metric == "depression":
        return {"tw": sample.wet_bulb, "tseco": sample.temperature}
    if rule.metric == "temperature":
        return {"tseco": sample.temperature}
    return None


def _shown(rule: Rule, sample: Sample, tier: Tier) -> tuple:
    return _shown_value(rule, sample), _shown_threshold(rule, tier), _details(rule, sample, tier)


def _evaluate_rule(db: Session, unit: CuringUnit, phase: Phase, rule: Rule, samples: list[Sample], now: datetime) -> None:
    sample = samples[-1]
    worst = -1
    for index, tier in enumerate(rule.tiers):
        if persisted(samples, now, tier.sustain_minutes, lambda s: _over(_metric(s, rule.metric), rule.direction, tier.threshold)):
            worst = index

    active = _active(db, unit, rule.type)
    if active is None:
        if worst >= 0:
            tier = rule.tiers[worst]
            _raise(db, unit, rule.type, tier.severity, _message(rule, phase, unit, now), now, *_shown(rule, sample, tier))
        return

    rank = SEVERITY_RANK.get(active.severity, 0)
    level = max((i for i, tier in enumerate(rule.tiers) if SEVERITY_RANK[tier.severity] <= rank), default=0)
    if worst > level:
        tier = rule.tiers[worst]
        _raise(db, unit, rule.type, tier.severity, _message(rule, phase, unit, now), now, *_shown(rule, sample, tier))
        return

    # Desce um nível por vez enquanto o valor estiver, com folga e por tempo suficiente, dentro do limite.
    margin = HYSTERESIS[rule.metric]
    while level >= 0:
        threshold = rule.tiers[level].threshold
        limit = threshold - margin if rule.direction == "high" else threshold + margin
        ratio = window_ratio(samples, now, CLEAR_MINUTES, lambda s: not _over(_metric(s, rule.metric), rule.direction, limit))
        if ratio is None or ratio < PERSISTENCE_FRACTION:
            break
        level -= 1
    if level < 0:
        _close(db, active, now)
        return
    tier = rule.tiers[level]
    _update(active, tier.severity, _message(rule, phase, unit, now), *_shown(rule, sample, tier))


def _sync_anchor(db: Session, unit: CuringUnit, phase: Phase, temperature: float, now: datetime) -> None:
    """Na entrada em uma fase ou na retomada: calcula a carência e recomeça a referência da queda."""
    entry = max(unit.stage_started_at, unit.drying_started_at or unit.stage_started_at)
    if unit.alert_anchor_at == entry:
        return
    floor = phase.temp_min - BELOW_RANGE_MARGIN_C
    climb = max(0.0, floor - temperature) / phase.heating_limit
    starting = phase is PHASES[0] and unit.cycle_started_at is not None and entry <= unit.cycle_started_at
    hours = START_HOLD_HOURS + climb if starting else climb + ENTRY_MARGIN_HOURS
    unit.alert_anchor_at = entry
    unit.alert_grace_until = entry + timedelta(hours=hours)
    unit.drop_reference = None
    unit.wet_bulb_gate_open = True
    _close(db, _active(db, unit, DROP_TYPE), now)


def _in_grace(unit: CuringUnit, now: datetime) -> bool:
    return unit.alert_grace_until is not None and now < unit.alert_grace_until


def _wet_bulb_gate(unit: CuringUnit, temperature: float) -> bool:
    if unit.wet_bulb_gate_open and temperature > WET_BULB_CUTOFF_C + WET_BULB_CUTOFF_MARGIN_C:
        unit.wet_bulb_gate_open = False
    elif not unit.wet_bulb_gate_open and temperature < WET_BULB_CUTOFF_C - WET_BULB_CUTOFF_MARGIN_C:
        unit.wet_bulb_gate_open = True
    return unit.wet_bulb_gate_open


def _evaluate_rules(db: Session, unit: CuringUnit, phase: Phase, samples: list[Sample], suspended: bool, now: datetime) -> None:
    rules = {rule.type: rule for rule in phase.rules}
    for alert_type in RULE_TYPES:
        rule = rules.get(alert_type)
        if rule is None:
            _close(db, _active(db, unit, alert_type), now)
            continue
        if suspended and alert_type != HUMIDITY_LOW_TYPE:
            continue
        skip = (
            (alert_type == WET_BULB_HIGH_TYPE and not _wet_bulb_gate(unit, samples[-1].temperature))
            or (alert_type == DEPRESSION_HIGH_TYPE and _in_grace(unit, now))
        )
        if skip:
            _close(db, _active(db, unit, alert_type), now)
            continue
        _evaluate_rule(db, unit, phase, rule, samples, now)


def _evaluate_below_range(db: Session, unit: CuringUnit, phase: Phase, samples: list[Sample], now: datetime) -> None:
    if _in_grace(unit, now):
        _close(db, _active(db, unit, BELOW_RANGE_TYPE), now)
        return
    rule = Rule(
        BELOW_RANGE_TYPE,
        "temperature",
        "low",
        (Tier(phase.temp_min - BELOW_RANGE_MARGIN_C, "warning", BELOW_RANGE_SUSTAIN_MINUTES),),
    )
    _evaluate_rule(db, unit, phase, rule, samples, now)


def _drop_suppressed(db: Session, unit: CuringUnit, now: datetime) -> bool:
    return db.query(Alert.id).filter(
        Alert.curing_unit_id == unit.id,
        Alert.type == TEMPERATURE_HIGH_TYPE,
        or_(Alert.is_active.is_(True), Alert.resolved_at >= now - DROP_SUPPRESSION),
    ).first() is not None


def _drop_message(db: Session, unit: CuringUnit, now: datetime) -> str:
    """Causa da queda pelas aberturas do flap nos últimos 10 min."""
    names = _flap_names(unit)
    if relay_state(unit, "humidity", now) and unit.flap_humidity_open:
        return msg.text(msg.DROP_FLAP_OPEN, **names)
    recently = db.query(OutputEvent.id).filter(
        OutputEvent.curing_unit_id == unit.id,
        OutputEvent.output == "humidity",
        OutputEvent.timestamp >= now - DROP_FLAP_WINDOW,
        OutputEvent.timestamp <= now,
    ).first() is not None
    if recently and not relay_state(unit, "humidity", now):
        return msg.text(msg.DROP_AFTER_FLAP, **names)
    return msg.DROP


def _evaluate_drop(db: Session, unit: CuringUnit, phase: Phase, samples: list[Sample], now: datetime) -> None:
    temperature = samples[-1].temperature
    active = _active(db, unit, DROP_TYPE)
    if _drop_suppressed(db, unit, now):
        # A referência recomeça quando a supressão acabar, senão o alerta abriria só com atraso.
        _close(db, active, now)
        unit.drop_reference = None
        return
    if active is not None and active.acknowledged_at is not None:
        # Reconhecer aceita a redução como intencional.
        _close(db, active, now)
        unit.drop_reference = min(phase.alert_temp_max, temperature)
        return

    previous = temperature if unit.drop_reference is None else unit.drop_reference
    reference = min(phase.alert_temp_max, max(previous, temperature))
    unit.drop_reference = reference
    threshold = reference - DROP_MARGIN_C
    severity = "critical" if stage_hours(unit, now) < phase.drop_critical_hours else "warning"
    details = {"tseco": temperature}
    if active is not None:
        ratio = window_ratio(samples, now, CLEAR_MINUTES, lambda s: s.temperature >= reference - DROP_CLEAR_MARGIN_C)
        if ratio is not None and ratio >= PERSISTENCE_FRACTION:
            _close(db, active, now)
        else:
            # A causa citada fica até o alerta encerrar: só troca por outra causa, nunca pelo texto genérico.
            message = _drop_message(db, unit, now)
            _update(active, severity, active.message if message == msg.DROP else message, temperature, threshold, details)
        return
    if not _in_grace(unit, now) and persisted(samples, now, DROP_SUSTAIN_MINUTES, lambda s: s.temperature < threshold):
        _raise(db, unit, DROP_TYPE, severity, _drop_message(db, unit, now), now, temperature, threshold, details)


def _resuming_after_drop(unit: CuringUnit, points: list[tuple[datetime, float]], temperature: float, now: datetime) -> bool:
    """Retomada depois de uma queda: subir mais rápido é o procedimento recomendado, por até 2 h."""
    reference = unit.drop_reference
    if reference is None or temperature >= reference or not points:
        return False
    lowest = min(points, key=lambda point: (point[1], -point[0].timestamp()))
    return reference - lowest[1] >= DROP_MARGIN_C and now - lowest[0] <= HEATING_RESUME_LIMIT


def heating_slopes(db: Session, unit: CuringUnit, phase: Phase, temperature: float, now: datetime) -> list[float] | None:
    """Inclinações (°C/h) das janelas que terminam agora e em cada um dos minutos anteriores, da mais recente à mais
    antiga. None quando o aquecimento é permitido (inicial ou retomada depois de uma queda) ou não dá para calcular.

    Usada pelo alerta "Aquecimento rápido" e pelo corte por taxa do soprador.
    """
    window = timedelta(minutes=settings.HEATING_RATE_WINDOW_MINUTES)
    span = max(window + timedelta(minutes=HEATING_HOLD_MINUTES), HEATING_RESUME_LIMIT + timedelta(minutes=5))
    points = minute_means(db, unit.id, now - span, now)
    if (phase is PHASES[0] and temperature < HEATING_INITIAL_C) or _resuming_after_drop(unit, points, temperature, now):
        return None
    if phase is PHASES[0]:
        # O aquecimento inicial, permitido, não pode contar na inclinação depois que ele termina.
        points = [point for point in points if point[1] >= HEATING_INITIAL_C]

    slopes = [
        slope_per_hour(points, now - timedelta(minutes=minute) - window, now - timedelta(minutes=minute))
        for minute in range(HEATING_HOLD_MINUTES + 1)
    ]
    return None if any(slope is None for slope in slopes) else slopes


def _heating_fast(slopes: list[float], limit: float) -> bool:
    return sum(1 for slope in slopes if slope > limit) / len(slopes) >= PERSISTENCE_FRACTION


def _update_rate_cut(unit: CuringUnit, phase: Phase, slopes: list[float] | None) -> None:
    """Corte por taxa do soprador: liga com o mesmo critério do alerta e acaba quando a taxa volta ao limite (DE)."""
    if slopes is None:
        unit.fan_rate_cut = False
    elif unit.fan_rate_cut:
        unit.fan_rate_cut = slopes[0] > phase.heating_limit
    else:
        unit.fan_rate_cut = _heating_fast(slopes, phase.heating_limit)


def _evaluate_heating(db: Session, unit: CuringUnit, phase: Phase, samples: list[Sample], now: datetime) -> None:
    slopes = heating_slopes(db, unit, phase, samples[-1].temperature, now)
    _update_rate_cut(unit, phase, slopes)
    active = _active(db, unit, HEATING_TYPE)
    if slopes is None:
        return
    limit = phase.heating_limit
    details = {"taxa": slopes[0], "taxa_limite": limit}
    if active is not None:
        calm = sum(1 for slope in slopes if slope <= limit - HEATING_CLEAR_MARGIN) / len(slopes)
        if calm >= PERSISTENCE_FRACTION:
            _close(db, active, now)
        else:
            _update(active, active.severity, _heating_message(unit, now), None, None, details)
        return
    if _heating_fast(slopes, limit):
        _raise(db, unit, HEATING_TYPE, settings.HEATING_RATE_SEVERITY, _heating_message(unit, now), now, details=details)


def _heating_message(unit: CuringUnit, now: datetime) -> str:
    """"Aquecimento rápido" pelo estado do soprador: o confirmado pelo sender, se recente; senão, o comandado."""
    names = _flap_names(unit)
    if relay_state(unit, "temperature", now):
        manual = mode_of(unit, "temperature") == "on"
        return msg.text(msg.HEATING_MANUAL if manual else msg.HEATING_CUT, **names)
    # "O sistema desligou" só quando o corte por taxa governa o soprador: automático, regra do alvo e alvo definido.
    governed = (
        mode_of(unit, "temperature") == "auto"
        and field(unit, "temperature", "trigger") in (None, "temperature_target")
        and unit.target_temperature is not None
    )
    return msg.text(msg.HEATING_CUT if unit.fan_rate_cut and governed else msg.HEATING_FAN_OFF, **names)


def _jump_runs(db: Session, unit: CuringUnit, now: datetime) -> int:
    """Quantos saltos distintos houve na janela; amostras seguidas descartadas contam como um só."""
    flags = (
        db.query(Reading.is_outlier)
        .filter(
            Reading.curing_unit_id == unit.id,
            Reading.timestamp >= now - timedelta(minutes=SENSOR_JUMP_WINDOW_MINUTES),
            Reading.timestamp <= now,
        )
        .order_by(Reading.timestamp, Reading.id)
        .all()
    )
    runs, previous = 0, False
    for (flag,) in flags:
        runs += 1 if flag and not previous else 0
        previous = flag
    return runs


def _sensor_is_normal(db: Session, unit: CuringUnit, now: datetime) -> bool:
    start = now - timedelta(minutes=SENSOR_NORMAL_MINUTES)
    rows = (
        db.query(Reading.temperature, Reading.humidity, Reading.is_outlier, Reading.timestamp)
        .filter(Reading.curing_unit_id == unit.id, Reading.timestamp >= start, Reading.timestamp <= now)
        .order_by(Reading.timestamp, Reading.id)
        .all()
    )
    if len(rows) < 2 or rows[0][3] > start + timedelta(minutes=SENSOR_NORMAL_MINUTES / 2) or any(row[2] for row in rows):
        return False
    changes = sum(1 for before, after in pairwise(rows) if before[:2] != after[:2])
    return changes / (len(rows) - 1) >= 0.5


def _evaluate_sensor(db: Session, unit: CuringUnit, reading: Reading, samples: list[Sample], now: datetime) -> bool:
    """Falha de sensor. Devolve True quando as regras que dependem da medição devem ficar suspensas."""
    start = now - timedelta(minutes=SENSOR_FROZEN_MINUTES)
    t_min, t_max, h_min, h_max, count, first = (
        db.query(
            func.min(Reading.temperature),
            func.max(Reading.temperature),
            func.min(Reading.humidity),
            func.max(Reading.humidity),
            func.count(Reading.id),
            func.min(Reading.timestamp),
        )
        .filter(Reading.curing_unit_id == unit.id, Reading.timestamp >= start, Reading.timestamp <= now)
        .one()
    )
    frozen = (
        count >= SENSOR_FROZEN_MIN_SAMPLES
        and t_min == t_max
        and h_min == h_max
        and first <= start + timedelta(minutes=1)
    )
    jumping = bool(reading.is_outlier) and _jump_runs(db, unit, now) >= SENSOR_JUMP_COUNT
    saturated = persisted(samples, now, SATURATED_MINUTES, lambda s: s.humidity >= SATURATED_HUMIDITY)
    active = _active(db, unit, SENSOR_TYPE)

    if frozen or jumping:
        message = (
            "O sensor parou de variar e a leitura pode estar errada." if frozen else "A leitura está pulando e pode estar errada."
        ) + " Confira o sensor e o cabo e compare com o termômetro da estufa."
        _raise(db, unit, SENSOR_TYPE, "warning", message, now)
        # Só congelado ou pulando: com condensação a temperatura continua confiável e as saídas seguem normais.
        if unit.sensor_fault_since is None:
            unit.sensor_fault_since = now
        return True
    if saturated:
        _raise(db, unit, SENSOR_TYPE, "warning", "Umidade em 99% ou mais há 30 min. Pode ser condensação no sensor: compare com o termômetro da estufa.", now)
        return False
    if active is None:
        return False
    if _sensor_is_normal(db, unit, now):
        ratio = window_ratio(samples, now, SENSOR_NORMAL_MINUTES, lambda s: s.humidity < SATURATED_HUMIDITY)
        if ratio is not None and ratio >= PERSISTENCE_FRACTION:
            _close(db, active, now)
        return False
    # Enquanto houver salto recente, a medição continua sem confiança.
    return db.query(Reading.id).filter(
        Reading.curing_unit_id == unit.id,
        Reading.is_outlier.is_(True),
        Reading.timestamp >= now - timedelta(minutes=SENSOR_NORMAL_MINUTES),
        Reading.timestamp <= now,
    ).first() is not None


def _evaluate_overdue(db: Session, unit: CuringUnit, phase: Phase, now: datetime) -> None:
    hours = stage_hours(unit, now)
    if hours > phase.max_hours:
        _raise(db, unit, OVERDUE_TYPE, "info", f"Fase de {phase.name} passando do tempo ({round(hours)} h). Olhe as folhas e decida se avança.", now)
    else:
        _close(db, _active(db, unit, OVERDUE_TYPE), now)


def _evaluate_very_wet(db: Session, unit: CuringUnit, phase: Phase, samples: list[Sample], now: datetime) -> None:
    """A1: na Amarelação, ar quase saturado por 30 min; encerra com folga por 10 min."""
    active = _active(db, unit, VERY_WET_TYPE)
    if phase is not PHASES[0]:
        _close(db, active, now)
        return
    sample = samples[-1]
    details = {"tw": sample.wet_bulb, "tseco": sample.temperature}
    if active is None:
        if persisted(samples, now, VERY_WET_MINUTES, lambda s: s.depression < VERY_WET_DEPRESSION_C):
            _raise(db, unit, VERY_WET_TYPE, "info", msg.text(msg.VERY_WET, **_flap_names(unit)), now, details=details)
        return
    ratio = window_ratio(samples, now, VERY_WET_CLEAR_MINUTES, lambda s: s.depression > VERY_WET_CLEAR_C)
    if ratio is not None and ratio >= PERSISTENCE_FRACTION:
        _close(db, active, now)
    else:
        _update(active, active.severity, msg.text(msg.VERY_WET, **_flap_names(unit)), None, None, details)


def _evaluate_wet_load(db: Session, unit: CuringUnit, phase: Phase, now: datetime) -> None:
    """A2: uma mensagem por estufada, no início da Amarelação, enquanto dura a carência inicial."""
    active = _active(db, unit, WET_LOAD_TYPE)
    start = unit.cycle_started_at
    starting = (
        phase is PHASES[0]
        and start is not None
        and unit.stage_started_at <= start
        and now < start + timedelta(hours=START_HOLD_HOURS)
        and mode_of(unit, "humidity") != "on"
    )
    if not starting:
        _close(db, active, now)
        return
    already = db.query(Alert.id).filter(
        Alert.curing_unit_id == unit.id, Alert.type == WET_LOAD_TYPE, Alert.timestamp >= start,
    ).first() is not None
    if not already:
        _raise(db, unit, WET_LOAD_TYPE, "info", msg.text(msg.WET_LOAD, **_flap_names(unit)), now)


def _evaluate_manual_flap(db: Session, unit: CuringUnit, phase: Phase, now: datetime) -> None:
    """A3: flap em Ligada há mais de 12 h na Amarelação."""
    active = _active(db, unit, MANUAL_FLAP_TYPE)
    since = field(unit, "humidity", "mode_at")
    manual = phase is PHASES[0] and mode_of(unit, "humidity") == "on" and since is not None
    if manual and now - max(since, unit.stage_started_at) > timedelta(hours=MANUAL_FLAP_HOURS):
        _raise(db, unit, MANUAL_FLAP_TYPE, "info", msg.text(msg.MANUAL_FLAP, **_flap_names(unit)), now)
    else:
        _close(db, active, now)


def evaluate_reading(db: Session, unit: CuringUnit, device: Device | None, reading: Reading) -> None:
    """Avalia uma leitura gravada com as regras da fase em andamento."""
    phase = current_phase(unit)
    if phase is None:
        return
    now = reading.timestamp
    _close(db, _active(db, unit, NO_READINGS_TYPE), now)

    prepare_reading(db, reading)
    samples = load_samples(db, unit.id, now - SAMPLE_WINDOW, now)
    suspended = _evaluate_sensor(db, unit, reading, samples, now)
    if unit.sensor_fault_since is not None and _active(db, unit, SENSOR_TYPE) is None:
        # O alerta encerrou: as saídas voltam ao controle normal.
        unit.sensor_fault_since = None
    if reading.is_outlier or not samples:
        return

    _sync_anchor(db, unit, phase, samples[-1].temperature, now)
    _evaluate_rules(db, unit, phase, samples, suspended, now)
    _evaluate_below_range(db, unit, phase, samples, now)
    if suspended:
        unit.fan_rate_cut = False
    else:
        _evaluate_drop(db, unit, phase, samples, now)
        _evaluate_heating(db, unit, phase, samples, now)
        _evaluate_very_wet(db, unit, phase, samples, now)
    _evaluate_overdue(db, unit, phase, now)
    _evaluate_wet_load(db, unit, phase, now)
    _evaluate_manual_flap(db, unit, phase, now)


def check_missing_readings(db: Session, now: datetime | None = None) -> None:
    """Alarme para estufas em secagem que pararam de receber leituras (sensor, gateway ou Wi-Fi)."""
    now = now or utcnow()

    for unit in db.query(CuringUnit).all():
        phase = current_phase(unit)
        if phase is None:
            _close(db, _active(db, unit, NO_READINGS_TYPE), now)
            continue
        last = (
            db.query(func.max(Reading.timestamp))
            .filter(Reading.curing_unit_id == unit.id, Reading.timestamp >= unit.drying_started_at)
            .scalar()
        )
        silent = (now - (last or unit.drying_started_at)).total_seconds()
        minutes = max(1, round(silent / 60))
        warning_after = math.inf if phase.no_readings_warning_seconds is None else phase.no_readings_warning_seconds
        message = f"Sem notícias da estufa há {minutes} min. Veja se a caixa da estufa está ligada e se o Wi-Fi de casa funciona."
        if silent >= phase.no_readings_critical_seconds:
            _raise(db, unit, NO_READINGS_TYPE, "critical", message, now)
        elif silent >= warning_after:
            _raise(db, unit, NO_READINGS_TYPE, "warning", message, now)
        else:
            _close(db, _active(db, unit, NO_READINGS_TYPE), now)
    db.commit()
