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
from models.reading import Reading
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
)
from services.stage_service import stage_hours

# Folga e tempo para encerrar ou rebaixar um alerta, para ele não oscilar perto do limite (DE).
HYSTERESIS = {"temperature": 0.5, "wet_bulb": 0.5, "depression": 0.5, "humidity": 3.0}
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
# Depois de "Temperatura alta" ou "Umidade alta", a queda é a correção pedida.
DROP_SUPPRESSION = timedelta(hours=2)

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


def _over(value: float, direction: str, threshold: float) -> bool:
    return value > threshold if direction == "high" else value < threshold


def _active(db: Session, unit: CuringUnit, alert_type: str) -> Alert | None:
    return (
        db.query(Alert)
        .filter(Alert.curing_unit_id == unit.id, Alert.type == alert_type, Alert.is_active.is_(True))
        .first()
    )


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
        curing_unit_id=unit.id,
        timestamp=now,
    ))
    db.flush()


def _update(alert: Alert, severity: str, message: str, value: float | None, threshold: float | None) -> None:
    alert.severity = severity
    alert.message = message[:255]
    alert.value = value
    alert.threshold = threshold


def _message(rule: Rule, phase: Phase) -> str:
    """O que aconteceu e o que fazer, em linguagem do produtor. Os valores vão em campos que o app converte."""
    if rule.type == TEMPERATURE_HIGH_TYPE:
        base = f"Passou do limite na fase de {phase.name}."
        if phase.key == "murchamento":
            return f"{base} Reduza o fogo. Só mantenha assim por 4 a 6 h se as folhas de cima ainda não murcharam após cerca de 12 h."
        if phase.key == "secagem_folha":
            return f"{base} Se as lâminas de baixo já secaram, passe para a Secagem do talo; senão, reduza o fogo."
        return f"{base} Reduza o fogo."
    if rule.type == WET_BULB_HIGH_TYPE:
        return "A folha pode escaldar e escurecer. Abra o flap e não suba o fogo."
    if rule.type == DEPRESSION_HIGH_TYPE:
        return "Ar seco demais: a folha pode ficar verde. Feche o flap."
    if rule.type == HUMIDITY_LOW_TYPE:
        return "Ar seco no Murchamento. Se os estaleiros de cima ainda não amarelaram, feche um pouco o flap."
    return f"Temperatura baixa para a fase de {phase.name}. Veja a fornalha e a lenha."


def _shown_value(rule: Rule, sample: Sample) -> float | None:
    # A depressão é uma diferença: o app converteria como temperatura, então ela só aparece na mensagem.
    return None if rule.metric == "depression" else getattr(sample, rule.metric)


def _shown_threshold(rule: Rule, tier: Tier) -> float | None:
    return None if rule.metric == "depression" else tier.threshold


def _evaluate_rule(db: Session, unit: CuringUnit, phase: Phase, rule: Rule, samples: list[Sample], now: datetime) -> None:
    sample = samples[-1]
    worst = -1
    for index, tier in enumerate(rule.tiers):
        if persisted(samples, now, tier.sustain_minutes, lambda s: _over(getattr(s, rule.metric), rule.direction, tier.threshold)):
            worst = index

    active = _active(db, unit, rule.type)
    if active is None:
        if worst >= 0:
            tier = rule.tiers[worst]
            _raise(db, unit, rule.type, tier.severity, _message(rule, phase), now, _shown_value(rule, sample), _shown_threshold(rule, tier))
        return

    rank = SEVERITY_RANK.get(active.severity, 0)
    level = max((i for i, tier in enumerate(rule.tiers) if SEVERITY_RANK[tier.severity] <= rank), default=0)
    if worst > level:
        tier = rule.tiers[worst]
        _raise(db, unit, rule.type, tier.severity, _message(rule, phase), now, _shown_value(rule, sample), _shown_threshold(rule, tier))
        return

    # Desce um nível por vez enquanto o valor estiver, com folga e por tempo suficiente, dentro do limite.
    margin = HYSTERESIS[rule.metric]
    while level >= 0:
        threshold = rule.tiers[level].threshold
        limit = threshold - margin if rule.direction == "high" else threshold + margin
        ratio = window_ratio(samples, now, CLEAR_MINUTES, lambda s: not _over(getattr(s, rule.metric), rule.direction, limit))
        if ratio is None or ratio < PERSISTENCE_FRACTION:
            break
        level -= 1
    if level < 0:
        _close(db, active, now)
        return
    tier = rule.tiers[level]
    _update(active, tier.severity, _message(rule, phase), _shown_value(rule, sample), _shown_threshold(rule, tier))


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
        Alert.type.in_((TEMPERATURE_HIGH_TYPE, WET_BULB_HIGH_TYPE)),
        or_(Alert.is_active.is_(True), Alert.resolved_at >= now - DROP_SUPPRESSION),
    ).first() is not None


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
    message = "A temperatura caiu. Veja a fornalha, a lenha e o ventilador. Ao retomar, suba aos poucos, em degraus a cada 30 min."
    if active is not None:
        ratio = window_ratio(samples, now, CLEAR_MINUTES, lambda s: s.temperature >= reference - DROP_CLEAR_MARGIN_C)
        if ratio is not None and ratio >= PERSISTENCE_FRACTION:
            _close(db, active, now)
        else:
            _update(active, severity, message, temperature, threshold)
        return
    if not _in_grace(unit, now) and persisted(samples, now, DROP_SUSTAIN_MINUTES, lambda s: s.temperature < threshold):
        _raise(db, unit, DROP_TYPE, severity, message, now, temperature, threshold)


def _resuming_after_drop(unit: CuringUnit, points: list[tuple[datetime, float]], temperature: float, now: datetime) -> bool:
    """Retomada depois de uma queda: subir mais rápido é o procedimento recomendado, por até 2 h."""
    reference = unit.drop_reference
    if reference is None or temperature >= reference or not points:
        return False
    lowest = min(points, key=lambda point: (point[1], -point[0].timestamp()))
    return reference - lowest[1] >= DROP_MARGIN_C and now - lowest[0] <= HEATING_RESUME_LIMIT


def _evaluate_heating(db: Session, unit: CuringUnit, phase: Phase, samples: list[Sample], now: datetime) -> None:
    window = timedelta(minutes=settings.HEATING_RATE_WINDOW_MINUTES)
    span = max(window + timedelta(minutes=HEATING_HOLD_MINUTES), HEATING_RESUME_LIMIT + timedelta(minutes=5))
    points = minute_means(db, unit.id, now - span, now)
    temperature = samples[-1].temperature
    active = _active(db, unit, HEATING_TYPE)
    if (phase is PHASES[0] and temperature < HEATING_INITIAL_C) or _resuming_after_drop(unit, points, temperature, now):
        return
    if phase is PHASES[0]:
        # O aquecimento inicial, permitido, não pode contar na inclinação depois que ele termina.
        points = [point for point in points if point[1] >= HEATING_INITIAL_C]

    slopes = [
        slope_per_hour(points, now - timedelta(minutes=minute) - window, now - timedelta(minutes=minute))
        for minute in range(HEATING_HOLD_MINUTES + 1)
    ]
    if any(slope is None for slope in slopes):
        return
    limit = phase.heating_limit
    if active is not None:
        calm = sum(1 for slope in slopes if slope <= limit - HEATING_CLEAR_MARGIN) / len(slopes)
        if calm >= PERSISTENCE_FRACTION:
            _close(db, active, now)
        return
    fast = sum(1 for slope in slopes if slope > limit) / len(slopes)
    if fast >= PERSISTENCE_FRACTION:
        message = f"A temperatura está subindo rápido demais para a fase de {phase.name}. Reduza o fogo."
        _raise(db, unit, HEATING_TYPE, settings.HEATING_RATE_SEVERITY, message, now)


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
    if reading.is_outlier or not samples:
        return

    _sync_anchor(db, unit, phase, samples[-1].temperature, now)
    _evaluate_rules(db, unit, phase, samples, suspended, now)
    _evaluate_below_range(db, unit, phase, samples, now)
    if not suspended:
        _evaluate_drop(db, unit, phase, samples, now)
        _evaluate_heating(db, unit, phase, samples, now)
    _evaluate_overdue(db, unit, phase, now)


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
