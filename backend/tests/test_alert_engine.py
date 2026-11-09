"""Critérios de aceitação do motor de alertas, com tempo simulado."""

import random
from datetime import datetime, timedelta

import pytest
from conftest import Sim, make_unit
from core.config import settings
from core.database import SessionLocal
from models.alert import Alert
from models.curing_unit import CuringUnit
from models.reading import Reading
from services import output_service
from services.alert_engine import HYSTERESIS
from services.phases import (
    BELOW_RANGE_TYPE,
    DEPRESSION_HIGH_TYPE,
    DROP_TYPE,
    HEATING_TYPE,
    HUMIDITY_LOW_TYPE,
    NO_READINGS_TYPE,
    OVERDUE_TYPE,
    SENSOR_TYPE,
    TEMPERATURE_HIGH_TYPE,
    WET_BULB_HIGH_TYPE,
)
from services.psychrometrics import wet_bulb
from services.stage_service import phase_status

P = 90.8
# Umidade baixa o bastante para o bulbo úmido não interferir nos testes de temperatura.
DRY = 40.0


def humidity_for(temperature: float, target_wet_bulb: float) -> float:
    low, high = 1.0, 100.0
    for _ in range(50):
        middle = (low + high) / 2
        if wet_bulb(temperature, middle, P) > target_wet_bulb:
            high = middle
        else:
            low = middle
    return (low + high) / 2


@pytest.fixture()
def unit_id(client, auth) -> int:
    return make_unit(client, auth)


def after_grace(unit_id: int, stage: str, temperature: float, humidity: float, hours: float = 13) -> Sim:
    """Simulação já depois da carência, com histórico estável de 10 min."""
    sim = Sim(unit_id, stage)
    sim.skip(hours * 60)
    sim.run(10, temperature, humidity)
    return sim


# 1. Leitura espúria
def test_isolated_spurious_reading_opens_nothing(unit_id):
    sim = after_grace(unit_id, "Secagem do talo", 72, 25)
    sim.run(2, 72, 25, step=2)
    sim.run(2 / 60, 85, 25, step=2, noise=False)
    sim.run(3, 72, 25, step=2)
    assert sim.active() == {}
    with SessionLocal() as db:
        outliers = db.query(Reading).filter(Reading.curing_unit_id == unit_id, Reading.is_outlier.is_(True)).all()
        assert [reading.temperature for reading in outliers] == [85]


def _oscillate(period_above: int, period_below: int):
    cycle = period_above + period_below
    return lambda minutes: 48.2 if (minutes * 60) % cycle < period_above else 47.2


# 2. Oscilação no limite
def test_oscillation_needs_eighty_percent_of_the_window(unit_id):
    sim = after_grace(unit_id, "Murchamento", 45, 62)
    sim.run(5, _oscillate(70, 30), 62, step=5)
    assert TEMPERATURE_HIGH_TYPE not in sim.active()

    sim.run(2.5, _oscillate(85, 15), 62, step=5)
    assert sim.active()[TEMPERATURE_HIGH_TYPE].severity == "warning"


# 3. Porta aberta
def test_open_door_opens_nothing(unit_id):
    sim = after_grace(unit_id, "Amarelação", 38, 90)
    sim.run(3, 38, 90, step=2)
    sim.run(1.5, 35, 75, step=2)
    sim.run(5, 38, 90, step=2)
    assert sim.active() == {}


# 4. Queda da fornalha
def test_slow_furnace_drop_is_detected(unit_id):
    sim = after_grace(unit_id, "Secagem da folha", 55, 35)
    temperature_when_open = None
    for minute in range(1, 200):
        sim.run(1, 55 - 1.5 * minute / 60, 35)
        if DROP_TYPE in sim.active():
            temperature_when_open = 55 - 1.5 * minute / 60
            break
    assert temperature_when_open is not None
    assert 51.9 < temperature_when_open < 52.2
    assert sim.active()[DROP_TYPE].severity == "warning"


# 5. Redução pedida
def test_requested_reduction_does_not_raise_a_drop(unit_id):
    sim = after_grace(unit_id, "Amarelação", 38, 90)
    sim.run(12, 41.5, 90)
    assert TEMPERATURE_HIGH_TYPE in sim.active()
    sim.run(4, 38, 90)
    assert TEMPERATURE_HIGH_TYPE not in sim.active()
    sim.run(110, 38, 90)
    assert DROP_TYPE not in sim.active()
    # Depois da supressão a referência recomeça: a redução pedida não vira alerta atrasado.
    sim.run(20, 38, 90)
    assert DROP_TYPE not in sim.active()


def test_reduction_after_high_wet_bulb_stays_quiet_past_the_suppression(unit_id):
    sim = after_grace(unit_id, "Murchamento", 46, humidity_for(46, 42))
    sim.run(4, 46, humidity_for(46, 42))
    assert WET_BULB_HIGH_TYPE in sim.active()
    sim.run(4, 41, 70)
    assert WET_BULB_HIGH_TYPE not in sim.active()
    sim.run(140, 41, 70)
    assert DROP_TYPE not in sim.active()


def test_drop_after_suppression_uses_the_new_reference(unit_id):
    sim = after_grace(unit_id, "Amarelação", 38, 90)
    sim.run(12, 41.5, 90)
    sim.run(4, 38, 90)
    sim.run(125, 38, 90)
    # A referência agora é 38 °C; 3,5 °C abaixo dela é uma queda de verdade.
    sim.run(8, 34.5, 90)
    assert sim.active()[DROP_TYPE].severity == "critical"


def test_acknowledging_a_drop_accepts_the_new_level(unit_id):
    sim = after_grace(unit_id, "Secagem da folha", 55, 35)
    sim.run(8, 50, 35)
    alert = sim.active()[DROP_TYPE]
    with SessionLocal() as db:
        db.get(Alert, alert.id).acknowledged_at = sim.now
        db.commit()
    sim.run(1, 50, 35)
    assert DROP_TYPE not in sim.active()
    sim.run(8, 50, 35)
    assert DROP_TYPE not in sim.active()


def test_drop_closes_when_temperature_recovers(unit_id):
    sim = after_grace(unit_id, "Secagem da folha", 55, 35)
    sim.run(8, 50, 35)
    assert DROP_TYPE in sim.active()
    sim.run(4, 54.5, 35)
    assert DROP_TYPE not in sim.active()


def test_stem_drop_is_critical_only_at_the_start_of_the_phase(unit_id):
    sim = after_grace(unit_id, "Secagem do talo", 70, 25, hours=2)
    sim.run(8, 66, 25)
    assert sim.active()[DROP_TYPE].severity == "critical"

    other = make_second_unit(unit_id)
    late = after_grace(other, "Secagem do talo", 70, 25, hours=14)
    late.run(8, 66, 25)
    assert late.active()[DROP_TYPE].severity == "warning"


def make_second_unit(reference_unit_id: int) -> int:
    with SessionLocal() as db:
        original = db.get(CuringUnit, reference_unit_id)
        unit = CuringUnit(name="Outra", user_id=original.user_id)
        db.add(unit)
        db.commit()
        return unit.id


# 6. Retomada
def test_recovery_after_a_drop_is_not_fast_heating(unit_id):
    sim = after_grace(unit_id, "Secagem da folha", 55, 35)
    sim.run(10, 50, 35)
    assert DROP_TYPE in sim.active()
    for minute in range(1, 54):
        sim.run(1, 50 + 5.6 * minute / 60, 35)
        assert HEATING_TYPE not in sim.active()
    # Passou da referência: volta a avaliar.
    sim.run(16, lambda minute: 55 + 5.6 * minute / 60, 35)
    assert HEATING_TYPE in sim.active()


def test_recovery_exception_ends_after_two_hours(unit_id):
    sim = after_grace(unit_id, "Secagem da folha", 55, 35)
    sim.run(6, 45, 35)
    sim.run(110, lambda minute: 45 + 3 * minute / 60, 35)
    assert HEATING_TYPE not in sim.active()
    sim.run(25, lambda minute: 50.5 + 3 * minute / 60, 35)
    assert HEATING_TYPE in sim.active()


# 7. Bulbo úmido alto
def test_high_wet_bulb_in_wilting(unit_id):
    sim = Sim(unit_id, "Murchamento")
    sim.run(3, 44, 60, step=11)
    sim.run(2, 48, 85, step=11)
    alert = sim.active()[WET_BULB_HIGH_TYPE]
    assert alert.severity == "critical"
    assert alert.value == pytest.approx(45.1, abs=0.2)
    assert alert.threshold == 43.0


def test_dry_air_at_the_same_temperature_is_not_high_wet_bulb(unit_id):
    sim = Sim(unit_id, "Murchamento")
    sim.run(5, 48, 60)
    assert WET_BULB_HIGH_TYPE not in sim.active()


# 8. Corte da R1
def test_wet_bulb_rule_stops_above_135_f(unit_id):
    sim = after_grace(unit_id, "Secagem da folha", 58, humidity_for(58, 43.5))
    sim.run(5, 58, humidity_for(58, 43.5))
    assert WET_BULB_HIGH_TYPE not in sim.active()
    sim.run(5, 56, humidity_for(56, 43.5))
    assert WET_BULB_HIGH_TYPE in sim.active()


def test_wet_bulb_cutoff_has_hysteresis_and_closes_the_alert(unit_id):
    sim = after_grace(unit_id, "Secagem da folha", 56, humidity_for(56, 43.5))
    sim.run(5, 56, humidity_for(56, 43.5))
    assert WET_BULB_HIGH_TYPE in sim.active()
    # Entre 56,7 e 57,7 °C continua ligada.
    sim.run(3, 57.4, humidity_for(57.4, 43.5))
    assert WET_BULB_HIGH_TYPE in sim.active()
    sim.run(3, 58.2, humidity_for(58.2, 43.5))
    assert WET_BULB_HIGH_TYPE not in sim.active()
    # Voltar a 57,4 °C não religa.
    sim.run(5, 57.4, humidity_for(57.4, 43.5))
    assert WET_BULB_HIGH_TYPE not in sim.active()


# 9. R2 e carência
def test_depression_waits_for_the_calculated_grace(unit_id):
    sim = Sim(unit_id, "Amarelação")
    sim.run(1, 20, 90)
    sim.skip(10 * 60)
    sim.run(20, 30, 60)
    assert DEPRESSION_HIGH_TYPE not in sim.active()

    sim.skip(14.5 * 60)
    sim.run(5, 38, 65)
    assert DEPRESSION_HIGH_TYPE not in sim.active()
    sim.run(10, 38, 65)
    alert = sim.active()[DEPRESSION_HIGH_TYPE]
    assert alert.severity == "warning"
    assert alert.value is None and alert.threshold is None
    assert "°F entre bulbo seco e úmido" in alert.message


def test_depression_closes_below_the_margin(unit_id):
    sim = after_grace(unit_id, "Amarelação", 38, 60)
    sim.run(20, 38, 60)
    assert DEPRESSION_HIGH_TYPE in sim.active()
    sim.run(4, 38, 90)
    assert DEPRESSION_HIGH_TYPE not in sim.active()


def test_initial_grace_has_no_climb_when_already_warm(unit_id):
    sim = Sim(unit_id, "Amarelação")
    sim.run(1, 34, 60)
    assert sim.unit().alert_grace_until == sim.unit().alert_anchor_at + timedelta(hours=12)


# 10. Falha do sensor
def test_frozen_sensor_suspends_the_process_rules(unit_id):
    sim = Sim(unit_id, "Amarelação")
    sim.skip(11.5 * 60)
    sim.run(60, 38, 60, noise=False)
    active = sim.active()
    assert active[SENSOR_TYPE].severity == "warning"
    assert "congelados" in active[SENSOR_TYPE].message
    assert DEPRESSION_HIGH_TYPE not in active


def test_same_conditions_with_a_live_sensor_raise_the_rule(unit_id):
    sim = Sim(unit_id, "Amarelação")
    sim.skip(11.5 * 60)
    sim.run(60, 38, 60)
    assert SENSOR_TYPE not in sim.active()
    assert DEPRESSION_HIGH_TYPE in sim.active()


def test_saturated_air_warns_but_keeps_the_wet_bulb_rule(unit_id):
    sim = after_grace(unit_id, "Murchamento", 43, 99.5)
    sim.run(31, 43, 99.5)
    active = sim.active()
    assert "condensação" in active[SENSOR_TYPE].message
    assert WET_BULB_HIGH_TYPE in active


def test_repeated_jumps_open_the_fault_and_ten_normal_minutes_close_it(unit_id):
    sim = after_grace(unit_id, "Secagem da folha", 50, 35)
    for _ in range(3):
        sim.run(20 / 60, 50, 35, step=2)
        sim.run(2 / 60, 70, 35, step=2, noise=False)
    assert "Saltos" in sim.active()[SENSOR_TYPE].message
    sim.run(9, 50, 35, step=5)
    assert SENSOR_TYPE in sim.active()
    sim.run(3, 50, 35, step=5)
    assert SENSOR_TYPE not in sim.active()


def test_a_real_level_change_is_not_a_sensor_fault(unit_id):
    sim = after_grace(unit_id, "Secagem da folha", 50, 35)
    sim.run(1, 50, 35, step=2)
    sim.run(1, 53, 35, step=2)
    assert SENSOR_TYPE not in sim.active()


# 11. Lacuna de comunicação
def test_missing_readings_severity_by_phase(unit_id):
    sim = Sim(unit_id, "Amarelação")
    sim.run(5, 38, 90)
    sim.skip(4)
    sim.check_missing()
    assert NO_READINGS_TYPE not in sim.active()
    sim.skip(2)
    sim.check_missing()
    assert sim.active()[NO_READINGS_TYPE].severity == "critical"

    other = Sim(make_second_unit(unit_id), "Secagem da folha", start=sim.now)
    other.run(5, 50, 35)
    other.skip(5.5)
    other.check_missing()
    assert other.active()[NO_READINGS_TYPE].severity == "warning"
    other.skip(25)
    other.check_missing()
    assert other.active()[NO_READINGS_TYPE].severity == "critical"


def test_gap_does_not_close_or_open_process_alerts(unit_id):
    sim = after_grace(unit_id, "Murchamento", 45, DRY)
    sim.run(3, 49, DRY)
    assert sim.active()[TEMPERATURE_HIGH_TYPE].severity == "warning"
    sim.skip(6)
    # Primeiras leituras depois da lacuna: normais, mas sem cobertura para encerrar, e críticas sem cobertura para subir.
    sim.run(0.5, 45, DRY)
    assert sim.active()[TEMPERATURE_HIGH_TYPE].severity == "warning"
    sim.skip(6)
    sim.run(0.5, 53, DRY)
    assert sim.active()[TEMPERATURE_HIGH_TYPE].severity == "warning"


# 12. Troca de fase
def test_phase_change_reevaluates_the_active_alert(unit_id):
    sim = after_grace(unit_id, "Amarelação", 38, 90)
    sim.run(12, 41, 90)
    assert "Amarelação" in sim.active()[TEMPERATURE_HIGH_TYPE].message
    sim.change_stage("Murchamento")
    sim.run(3, 41, 90)
    # 41 °C está dentro do limite do Murchamento (47,8 °C).
    assert TEMPERATURE_HIGH_TYPE not in sim.active()
    assert sim.unit().alert_anchor_at == sim.unit().stage_started_at


def test_active_alert_gets_the_message_of_the_new_phase(unit_id):
    sim = after_grace(unit_id, "Murchamento", 45, DRY)
    sim.run(3, 49, DRY)
    assert "Murchamento" in sim.active()[TEMPERATURE_HIGH_TYPE].message
    sim.change_stage("Amarelação")
    sim.run(0.5, 49, DRY)
    assert "Amarelação" in sim.active()[TEMPERATURE_HIGH_TYPE].message


def test_phase_change_closes_a_drop_and_starts_a_new_reference(unit_id):
    sim = after_grace(unit_id, "Secagem da folha", 55, 35)
    sim.run(8, 50, 35)
    assert DROP_TYPE in sim.active()
    sim.change_stage("Secagem do talo")
    sim.run(1, 50, 35)
    assert DROP_TYPE not in sim.active()
    assert sim.unit().drop_reference == pytest.approx(50, abs=0.05)


def test_rules_that_do_not_exist_in_the_new_phase_close(unit_id):
    sim = after_grace(unit_id, "Murchamento", 46, humidity_for(46, 42))
    sim.run(4, 46, humidity_for(46, 42))
    assert WET_BULB_HIGH_TYPE in sim.active()
    sim.change_stage("Secagem do talo")
    sim.run(1, 46, humidity_for(46, 42))
    assert WET_BULB_HIGH_TYPE not in sim.active()


# 13. Pausa e retomada
def test_resume_applies_the_grace(unit_id):
    sim = after_grace(unit_id, "Secagem da folha", 50, 35)
    sim.pause()
    sim.run(30, 40, 35)
    assert sim.active() == {}
    sim.resume()
    # (46 − 40) ÷ 1,1 + 1 h ≈ 6,45 h
    sim.run(60, 40, 35)
    assert BELOW_RANGE_TYPE not in sim.active()
    sim.skip(4.5 * 60)
    sim.run(30, 40, 35)
    assert BELOW_RANGE_TYPE not in sim.active()
    sim.skip(30)
    sim.run(35, 40, 35)
    assert BELOW_RANGE_TYPE in sim.active()


# 14. Rebaixamento
def test_downgrade_keeps_the_same_alert(unit_id):
    sim = after_grace(unit_id, "Secagem do talo", 72, 25, hours=14)
    sim.run(3, 78, 25)
    alert = sim.active()[TEMPERATURE_HIGH_TYPE]
    assert alert.severity == "critical"
    sim.run(4, 75, 25)
    downgraded = sim.active()[TEMPERATURE_HIGH_TYPE]
    assert downgraded.id == alert.id
    assert downgraded.severity == "warning"
    assert downgraded.value == pytest.approx(75, abs=0.05)
    assert downgraded.threshold == 74


def test_oscillation_around_a_tier_does_not_notify_repeatedly(unit_id):
    sim = after_grace(unit_id, "Secagem do talo", 72, 25, hours=14)
    sim.run(3, 78, 25)
    temperature_alerts = lambda: [alert for alert in sim.all_alerts() if alert.type == TEMPERATURE_HIGH_TYPE]  # noqa: E731
    opened = len(temperature_alerts())
    assert sim.active()[TEMPERATURE_HIGH_TYPE].severity == "critical"
    # Encostar abaixo de 77 °C sem a folga de 0,5 °C não rebaixa nem reabre.
    sim.run(30, lambda minute: 76.8 if int(minute) % 2 else 77.4, 25)
    assert len(temperature_alerts()) == opened
    assert sim.active()[TEMPERATURE_HIGH_TYPE].severity == "critical"


def test_escalation_opens_a_new_alert(unit_id):
    sim = after_grace(unit_id, "Secagem do talo", 72, 25, hours=14)
    sim.run(3, 75, 25)
    sim.run(3, 78, 25)
    sim.run(3, 81, 25)
    alerts = [(alert.severity, alert.is_active) for alert in sim.all_alerts() if alert.type == TEMPERATURE_HIGH_TYPE]
    assert alerts == [("warning", False), ("critical", False), ("emergency", True)]


# 15. Relés
def test_relay_margins_did_not_change():
    assert output_service.TEMPERATURE_HYSTERESIS_C == 0.5
    assert output_service.HUMIDITY_HYSTERESIS == 1.0
    assert HYSTERESIS["humidity"] == 3.0  # a margem do alerta é independente


def test_relays_follow_the_raw_reading_with_the_same_margins():
    state = False
    expected = [(35.0, False), (34.9, True), (35.4, True), (35.5, False), (40.1, True), (39.6, True), (39.5, False)]
    for value, result in expected:
        state = output_service._auto_state(state, value, 35, 40, output_service.TEMPERATURE_HYSTERESIS_C, "out")
        assert state is result


# Outras regras
def test_low_humidity_is_informative_only_in_wilting(unit_id):
    sim = after_grace(unit_id, "Murchamento", 45, 50)
    sim.run(20, 45, 50)
    alert = sim.active()[HUMIDITY_LOW_TYPE]
    assert alert.severity == "info"
    sim.change_stage("Secagem da folha")
    sim.run(1, 45, 50)
    assert HUMIDITY_LOW_TYPE not in sim.active()


def test_low_humidity_closes_with_three_points_of_margin(unit_id):
    sim = after_grace(unit_id, "Murchamento", 45, 50)
    sim.run(20, 45, 50)
    sim.run(4, 45, 62)
    assert HUMIDITY_LOW_TYPE in sim.active()
    sim.run(4, 45, 63.5)
    assert HUMIDITY_LOW_TYPE not in sim.active()


def test_info_alerts_do_not_count_as_unit_status(client, auth, unit_id):
    sim = after_grace(unit_id, "Murchamento", 45, 50)
    sim.run(20, 45, 50)
    unit = next(item for item in client.get("/curing_units/", headers=auth).json() if item["id"] == unit_id)
    assert (unit["active_alerts"], unit["critical_alerts"]) == (0, 0)
    assert client.get("/alerts/?active=true", headers=auth).json()[0]["severity"] == "info"


def test_long_stay_is_informative_once(unit_id):
    sim = Sim(unit_id, "Murchamento")
    sim.skip(23.9 * 60)
    sim.run(5, 44, 62)
    assert OVERDUE_TYPE not in sim.active()
    sim.skip(30)
    sim.run(2, 44, 62)
    sim.run(2, 44, 62)
    assert sim.active()[OVERDUE_TYPE].severity == "info"
    assert len([alert for alert in sim.all_alerts() if alert.type == OVERDUE_TYPE]) == 1


def test_below_range_uses_the_calculated_grace(unit_id):
    sim = Sim(unit_id, "Amarelação")
    sim.run(1, 30, 90)
    sim.skip(14 * 60)
    sim.run(35, 30, 90)
    assert BELOW_RANGE_TYPE not in sim.active()
    sim.skip(60)
    sim.run(35, 30, 90)
    assert sim.active()[BELOW_RANGE_TYPE].threshold == 33


def test_heating_limit_depends_on_the_phase(unit_id):
    sim = after_grace(unit_id, "Murchamento", 41, 70)
    sim.run(75, lambda minute: 41 + 1.0 * minute / 60, 70)
    assert HEATING_TYPE in sim.active()

    other = after_grace(make_second_unit(unit_id), "Secagem do talo", 62, 25)
    other.run(75, lambda minute: 62 + 1.5 * minute / 60, 25)
    assert HEATING_TYPE not in other.active()


def test_heating_severity_is_configurable(unit_id, monkeypatch):
    assert settings.HEATING_RATE_SEVERITY == "info"
    monkeypatch.setattr(settings, "HEATING_RATE_SEVERITY", "warning")
    sim = after_grace(unit_id, "Murchamento", 41, 70)
    sim.run(75, lambda minute: 41 + 1.5 * minute / 60, 70)
    assert sim.active()[HEATING_TYPE].severity == "warning"


def test_initial_heating_is_allowed_and_does_not_leak_into_the_slope(unit_id, monkeypatch):
    monkeypatch.setattr(settings, "HEATING_RATE_SEVERITY", "warning")
    sim = Sim(unit_id, "Amarelação")
    sim.run(120, lambda minute: 20 + 6.1 * minute / 60, 90)
    sim.run(120, 32.3, 90)
    assert HEATING_TYPE not in sim.active()


# 16. Cura completa simulada
def test_complete_cure_raises_no_warning_or_critical(unit_id, monkeypatch):
    """Cronograma ~5 dias, em rampas a 90 % dos limites, com ruído e lacunas."""
    monkeypatch.setattr(settings, "HEATING_RATE_SEVERITY", "warning")
    rng = random.Random(42)
    sim = Sim(unit_id, "Amarelação", start=datetime(2026, 1, 10, 8, 0, 0))

    def ramp(start: float, end: float, rate: float):
        hours = abs(end - start) / rate
        return hours, lambda minute: start + rate * minute / 60

    def run_noisy(hours: float, temperature, humidity) -> None:
        with SessionLocal() as db:
            from services.alert_engine import evaluate_reading

            unit = db.get(CuringUnit, unit_id)
            elapsed = 0.0
            while elapsed < hours * 3600:
                step = 60 if rng.random() < 0.02 else 20
                elapsed += step
                sim.now += timedelta(seconds=step)
                minutes = elapsed / 60
                base = temperature(minutes) if callable(temperature) else temperature
                reading = Reading(
                    temperature=base + rng.uniform(-0.1, 0.1),
                    humidity=min(100.0, humidity(base) + rng.uniform(-1, 1)),
                    timestamp=sim.now,
                    curing_unit_id=unit_id,
                )
                db.add(reading)
                db.flush()
                evaluate_reading(db, unit, None, reading)
            db.commit()

    def ready() -> bool:
        with SessionLocal() as db:
            return phase_status(db.get(CuringUnit, unit_id), sim.now)["ready"]

    def yellowing_air(_: float) -> float:
        return 90.0

    def wet_bulb_air(temperature: float) -> float:
        return humidity_for(temperature, min(temperature - 1.5, 39.0))

    run_noisy(2, lambda minute: 20 + 6.1 * minute / 60, yellowing_air)
    run_noisy(10, 32.2, yellowing_air)
    hours, curve = ramp(32.2, 38.3, 0.99)
    run_noisy(hours, curve, yellowing_air)
    run_noisy(50 - 12 - hours, 38.3, yellowing_air)
    assert ready()

    sim.change_stage("Murchamento")
    hours, curve = ramp(38.3, 47, 0.72)
    run_noisy(hours, curve, wet_bulb_air)
    run_noisy(20 - hours, 47, wet_bulb_air)
    assert ready()

    sim.change_stage("Secagem da folha")
    hours, curve = ramp(47, 56.9, 0.99)
    run_noisy(hours, curve, wet_bulb_air)
    run_noisy(30 - hours, 56.9, wet_bulb_air)
    assert ready()

    sim.change_stage("Secagem do talo")
    hours, curve = ramp(56.9, 73, 1.53)
    run_noisy(hours, curve, lambda temperature: humidity_for(temperature, 42))
    run_noisy(24 - hours, 73, lambda temperature: humidity_for(temperature, 42))
    assert ready()

    unexpected = [(alert.type, alert.severity, alert.message) for alert in sim.all_alerts() if alert.severity != "info"]
    assert unexpected == []
