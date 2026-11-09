from datetime import datetime, timedelta

import pytest
from conftest import make_unit
from core.database import SessionLocal
from models.reading import Reading
from services.alert_signal import Sample, coverage, persisted, prepare_reading, slope_per_hour, window_ratio
from services.psychrometrics import wet_bulb

T0 = datetime(2026, 1, 10, 8, 0, 0)
P = 90.8


@pytest.mark.parametrize(
    ("dry", "humidity", "expected"),
    [(48, 85, 45.13), (48, 65, 40.73), (60, 65, 51.67), (54, 65, 46.19), (43.3, 85, 40.59)],
)
def test_wet_bulb_matches_the_reference_values(dry, humidity, expected):
    assert wet_bulb(dry, humidity, P) == pytest.approx(expected, abs=0.02)


def test_wet_bulb_is_the_dry_bulb_in_saturated_air():
    assert wet_bulb(43, 100, P) == pytest.approx(43, abs=0.01)


def test_pressure_has_a_small_effect():
    assert abs(wet_bulb(48, 85, 90.8) - wet_bulb(48, 85, 101.325)) < 0.1


def test_wet_bulb_survives_the_sensor_limits():
    for dry, humidity in ((-40, 0), (-40, 100), (125, 0), (125, 100)):
        assert wet_bulb(dry, humidity, P) <= dry + 0.01


def _sample(seconds: float, temperature: float = 40.0) -> Sample:
    return Sample(T0 + timedelta(seconds=seconds), temperature, 80.0, 38.0)


def test_coverage_ignores_long_gaps():
    samples = [_sample(0), _sample(30), _sample(600), _sample(630)]
    # 30 s + 60 s (limitado) + 30 s, em 10,5 min.
    assert coverage(samples, T0, T0 + timedelta(seconds=630)) == pytest.approx(120 / 630)


def test_window_without_coverage_is_unknown():
    now = T0 + timedelta(minutes=10)
    samples = [_sample(590), _sample(600)]
    assert window_ratio(samples, now, 10, lambda sample: True) is None
    assert persisted(samples, now, 10, lambda sample: True) is False


def test_persistence_needs_eighty_percent():
    now = T0 + timedelta(seconds=100)
    samples = [_sample(s, 41.0 if s < 80 else 39.0) for s in range(0, 101, 10)]
    assert window_ratio(samples, now, 100 / 60, lambda sample: sample.temperature > 40) == pytest.approx(8 / 11)
    assert persisted(samples, now, 100 / 60, lambda sample: sample.temperature > 40) is False


def test_slope_is_in_degrees_per_hour():
    points = [(T0 + timedelta(minutes=m), 30 + m * 0.02) for m in range(61)]
    assert slope_per_hour(points, T0, T0 + timedelta(minutes=60)) == pytest.approx(1.2)


def test_slope_needs_half_of_the_window():
    points = [(T0 + timedelta(minutes=m), 30.0) for m in range(20)]
    assert slope_per_hour(points, T0, T0 + timedelta(minutes=60)) is None


def _feed(db, unit_id: int, series: list[tuple[float, float, float]]) -> list[Reading]:
    readings = []
    for seconds, temperature, humidity in series:
        reading = Reading(
            temperature=temperature, humidity=humidity, timestamp=T0 + timedelta(seconds=seconds), curing_unit_id=unit_id,
        )
        db.add(reading)
        db.flush()
        prepare_reading(db, reading)
        readings.append(reading)
    return readings


def test_filter_is_the_median_of_the_last_30_seconds(client, auth):
    unit_id = make_unit(client, auth)
    with SessionLocal() as db:
        readings = _feed(db, unit_id, [(0, 40.0, 80.0), (10, 41.0, 82.0), (20, 42.0, 84.0), (40, 43.0, 85.0)])
        assert readings[2].filtered_temperature == 41.0
        assert readings[2].filtered_humidity == 82.0
        # As leituras de 0 s e 10 s já saíram da janela de 30 s.
        assert readings[3].filtered_temperature == 42.5
        assert readings[3].filtered_wet_bulb == pytest.approx(wet_bulb(42.5, 84.5, P))


def test_isolated_jump_is_discarded(client, auth):
    unit_id = make_unit(client, auth)
    with SessionLocal() as db:
        series = [(s, 72.0, 30.0) for s in range(0, 10, 2)] + [(10, 85.0, 30.0)] + [(12, 72.0, 30.0)]
        readings = _feed(db, unit_id, series)
        assert readings[5].is_outlier is True
        assert readings[5].filtered_temperature is None
        assert readings[6].is_outlier is False
        assert readings[6].filtered_temperature == 72.0


def test_real_level_change_is_accepted_after_consistent_samples(client, auth):
    unit_id = make_unit(client, auth)
    with SessionLocal() as db:
        before = [(s, 40.0, 80.0) for s in range(0, 10, 2)]
        after = [(s, 44.0, 80.0) for s in range(10, 20, 2)]
        readings = _feed(db, unit_id, before + after)
        assert all(reading.is_outlier is False for reading in readings)
        # Cinco amostras de cada nível na janela de 30 s.
        assert readings[-1].filtered_temperature == 42.0
