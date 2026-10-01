from datetime import datetime, timedelta, timezone

from conftest import add_past_readings, send_reading, set_stage, shift_stage_start
from core.clock import utcnow
from core.database import SessionLocal
from models.curing_unit import CuringUnit
from services.alert_engine import check_missing_readings


def active_alerts(client, auth) -> dict:
    return {alert["type"]: alert for alert in client.get("/alerts/?active=true", headers=auth).json()}


def test_drying_starts_in_the_first_phase(client, auth, drying_unit):
    unit = client.get(f"/curing_units/{drying_unit['unit']['id']}", headers=auth).json()
    assert unit["curing_stage"] == "Amarelação"
    phase = unit["phase"]
    assert (phase["number"], phase["total"], phase["key"]) == (1, 4, "amarelacao")
    assert (phase["temp_min"], phase["temp_max"], phase["humidity_min"], phase["humidity_max"]) == (35, 40, 80, 95)
    assert phase["next_stage"] == "Murchamento"
    assert phase["ready"] is False
    assert phase["visual_check"]


def test_phase_status_is_absent_without_drying(client, auth):
    unit = client.post("/curing_units/", json={"name": "Parada"}, headers=auth).json()
    assert unit["phase"] is None
    assert client.post(f"/curing_units/{unit['id']}/advance-stage", headers=auth).status_code == 409


def test_advancing_walks_the_four_phases_and_finishes(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    names = []
    for _ in range(4):
        unit = client.post(f"/curing_units/{unit_id}/advance-stage", headers=auth).json()
        names.append(unit["curing_stage"])
    assert names == ["Murchamento", "Secagem da folha", "Secagem do talo", "Finalizado"]
    assert unit["is_drying"] is False
    assert unit["phase"] is None

    series = client.get(f"/curing_units/{unit_id}/series", headers=auth).json()
    assert [phase["stage"] for phase in series["phases"]] == ["Amarelação", "Murchamento", "Secagem da folha", "Secagem do talo"]
    assert [phase["key"] for phase in series["phases"]][-1] == "secagem_talo"
    assert series["phases"][1]["temp_max"] == 48


def test_stage_must_be_one_of_the_phases(client, auth, drying_unit):
    response = client.patch(f"/curing_units/{drying_unit['unit']['id']}", json={"curing_stage": "Murcha"}, headers=auth)
    assert response.status_code == 422


def test_pausing_keeps_the_phase_and_marks_the_history(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    set_stage(client, auth, unit_id, "Murchamento")
    client.post(f"/curing_units/{unit_id}/stop-drying", headers=auth)
    resumed = client.post(f"/curing_units/{unit_id}/start-drying", headers=auth).json()
    assert resumed["curing_stage"] == "Murchamento"

    phases = client.get(f"/curing_units/{unit_id}/series", headers=auth).json()["phases"]
    assert [phase["stage"] for phase in phases] == ["Amarelação", "Murchamento", "Murchamento"]


def test_finishing_by_hand_stops_the_drying(client, auth, drying_unit):
    unit = set_stage(client, auth, drying_unit["unit"]["id"], "Finalizado")
    assert unit["is_drying"] is False
    restarted = client.post(f"/curing_units/{unit['id']}/start-drying", headers=auth).json()
    assert restarted["curing_stage"] == "Amarelação"


def test_outputs_follow_the_new_phase_range(client, auth, drying_unit):
    # 45 °C está acima da Amarelação (35–40), mas dentro do Murchamento (40–48).
    client.patch(
        f"/curing_units/{drying_unit['unit']['id']}/outputs", json={"temperature_trigger": "temperature_out"}, headers=auth,
    )
    response = send_reading(client, 45.0, 85.0)
    assert response.json()["rele_temperatura"] is True
    set_stage(client, auth, drying_unit["unit"]["id"], "Murchamento")
    outputs = client.get(f"/curing_units/{drying_unit['unit']['id']}/outputs", headers=auth).json()
    assert outputs["temperature"]["on"] is False


def test_yellowing_alarm_needs_ten_minutes(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    send_reading(client, 41.0, 85.0)
    assert "Temperatura alta" not in active_alerts(client, auth)

    add_past_readings(unit_id, range(1, 12), temperature=41.0)
    send_reading(client, 41.0, 85.0)
    alert = active_alerts(client, auth)["Temperatura alta"]
    assert alert["severity"] == "warning"
    assert alert["message"].endswith("na fase de Amarelação por 10 min.")


def test_a_reading_inside_the_window_cancels_the_sustained_alarm(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    add_past_readings(unit_id, range(6, 12), temperature=43.0)
    add_past_readings(unit_id, range(5, 6), temperature=39.0)
    add_past_readings(unit_id, range(1, 5), temperature=43.0)
    send_reading(client, 43.0, 85.0)
    assert "Temperatura alta" not in active_alerts(client, auth)


def test_yellowing_humidity_becomes_critical(client, auth, drying_unit):
    add_past_readings(drying_unit["unit"]["id"], range(1, 17), temperature=38.0, humidity=68.0)
    send_reading(client, 38.0, 68.0)
    assert active_alerts(client, auth)["Umidade baixa"]["severity"] == "critical"


def test_stem_drying_has_an_emergency_level(client, auth, drying_unit):
    set_stage(client, auth, drying_unit["unit"]["id"], "Secagem do talo")
    send_reading(client, 81.0, 20.0)
    assert active_alerts(client, auth)["Temperatura alta"]["severity"] == "emergency"


def test_fast_heating_is_reported_in_wilting(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    set_stage(client, auth, unit_id, "Murchamento")
    add_past_readings(unit_id, range(31, 35), temperature=42.0, humidity=75.0)
    add_past_readings(unit_id, range(1, 5), temperature=44.0, humidity=75.0)
    send_reading(client, 44.0, 75.0)
    alert = active_alerts(client, auth)["Aquecimento rápido"]
    assert alert["severity"] == "warning"
    assert alert["value"] is None
    # Mensagem em °F, como o resto da interface (limite de 1,5 °C/h = 2,7 °F/h).
    assert alert["message"].endswith("Máximo: 2,7 °F/h.")

    # Na Secagem do talo não há limite de aquecimento: o alerta fecha.
    set_stage(client, auth, unit_id, "Secagem do talo")
    send_reading(client, 62.0, 30.0)
    assert "Aquecimento rápido" not in active_alerts(client, auth)


def test_below_range_waits_for_the_warm_up(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    add_past_readings(unit_id, range(1, 32), temperature=30.0)
    send_reading(client, 30.0, 85.0)
    assert "Temperatura abaixo da faixa" not in active_alerts(client, auth)

    shift_stage_start(unit_id, hours=7)
    send_reading(client, 30.0, 85.0)
    alert = active_alerts(client, auth)["Temperatura abaixo da faixa"]
    assert alert["threshold"] == 33


def test_missing_readings_raise_and_clear_the_alarm(client, auth, drying_unit):
    send_reading(client, 38.0, 85.0)
    with SessionLocal() as db:
        check_missing_readings(db, utcnow() + timedelta(minutes=2))
    alert = active_alerts(client, auth)["Sem novas leituras"]
    assert alert["severity"] == "warning"

    with SessionLocal() as db:
        check_missing_readings(db, utcnow() + timedelta(minutes=6))
    alert = active_alerts(client, auth)["Sem novas leituras"]
    assert alert["severity"] == "critical"

    send_reading(client, 38.0, 85.0)
    assert "Sem novas leituras" not in active_alerts(client, auth)


def test_missing_readings_alarm_closes_when_drying_stops(client, auth, drying_unit):
    with SessionLocal() as db:
        check_missing_readings(db, utcnow() + timedelta(minutes=6))
    assert "Sem novas leituras" in active_alerts(client, auth)
    client.post(f"/curing_units/{drying_unit['unit']['id']}/stop-drying", headers=auth)
    with SessionLocal() as db:
        check_missing_readings(db)
    assert "Sem novas leituras" not in active_alerts(client, auth)


def test_ready_to_advance_after_time_and_conditions(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    shift_stage_start(unit_id, hours=25)
    # Umidade caindo: 92% entre 4 h e 2 h atrás, 86% nas últimas 2 h.
    add_past_readings(unit_id, range(130, 240, 10), temperature=37.0, humidity=92.0)
    add_past_readings(unit_id, range(1, 110, 10), temperature=38.5, humidity=86.0)
    send_reading(client, 38.5, 86.0)

    phase = client.get(f"/curing_units/{unit_id}", headers=auth).json()["phase"]
    assert all(check["ok"] for check in phase["checks"]), phase["checks"]
    assert phase["ready"] is True


def _pass_time(unit_id: int, hours: float) -> None:
    """Empurra para o passado tudo o que já aconteceu na estufa, como se `hours` tivessem passado."""
    shift = timedelta(hours=hours)
    with SessionLocal() as db:
        unit = db.get(CuringUnit, unit_id)
        for field in ("stage_started_at", "drying_started_at", "cycle_started_at"):
            if getattr(unit, field) is not None:
                setattr(unit, field, getattr(unit, field) - shift)
        for segment in unit.stage_changes:
            segment.started_at -= shift
            if segment.ended_at is not None:
                segment.ended_at -= shift
        db.commit()


def test_paused_time_does_not_count_and_drying_resumes(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    client.patch(f"/curing_units/{unit_id}", json={"estimated_duration_hours": 100}, headers=auth)
    _pass_time(unit_id, 10)  # 10 h secando

    stopped = client.post(f"/curing_units/{unit_id}/stop-drying", headers=auth).json()
    assert stopped["interrupted"] is True
    assert stopped["paused_at"] is not None
    assert round(stopped["stage_hours"]) == 10

    _pass_time(unit_id, 5)  # 5 h parada: não conta
    resumed = client.post(f"/curing_units/{unit_id}/start-drying", headers=auth).json()
    assert resumed["curing_stage"] == "Amarelação"
    assert resumed["interrupted"] is False
    assert round(resumed["stage_hours"]) == 10
    assert round(resumed["phase"]["hours"]) == 10
    assert round(resumed["cycle_hours"]) == 10
    # Faltam 90 h das 100 previstas, contadas a partir da retomada.
    remaining = datetime.fromisoformat(resumed["estimated_completion_at"].replace("Z", "+00:00")) - datetime.now(timezone.utc)
    assert round(remaining.total_seconds() / 3600) == 90


def test_new_batch_starts_over_and_closes_old_alerts(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    set_stage(client, auth, unit_id, "Murchamento")
    send_reading(client, 53.0, 70.0)
    assert "Temperatura alta" in active_alerts(client, auth)
    _pass_time(unit_id, 8)
    client.post(f"/curing_units/{unit_id}/stop-drying", headers=auth)

    started = client.post(f"/curing_units/{unit_id}/start-drying?new_batch=true", headers=auth).json()
    assert started["curing_stage"] == "Amarelação"
    assert started["stage_hours"] < 0.1 and started["cycle_hours"] < 0.1
    assert active_alerts(client, auth) == {}


def test_finished_unit_always_starts_a_new_batch(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    set_stage(client, auth, unit_id, "Finalizado")
    stopped = client.get(f"/curing_units/{unit_id}", headers=auth).json()
    assert stopped["interrupted"] is False
    started = client.post(f"/curing_units/{unit_id}/start-drying", headers=auth).json()
    assert started["curing_stage"] == "Amarelação"
    assert started["cycle_hours"] < 0.1
