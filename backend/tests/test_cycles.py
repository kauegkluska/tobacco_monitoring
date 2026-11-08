from conftest import add_past_readings, register, send_reading, set_stage
from core.database import SessionLocal, initialize_database
from models.curing_cycle import CuringCycle
from models.curing_unit import CuringUnit


def cycles(client, auth, **params) -> list[dict]:
    response = client.get("/curing-cycles/", params=params, headers=auth)
    assert response.status_code == 200, response.text
    return response.json()


def finish(client, auth, unit_id: int) -> None:
    for _ in range(4):
        client.post(f"/curing_units/{unit_id}/advance-stage", headers=auth)


def test_starting_the_drying_opens_a_cycle(client, auth, drying_unit):
    send_reading(client, 38.0, 85.0)
    [cycle] = cycles(client, auth)
    assert cycle["status"] == "in_progress"
    assert cycle["ended_at"] is None
    assert cycle["is_drying"] is True
    assert cycle["final_stage"] == "Amarelação"
    assert cycle["curing_unit_name"] == "Estufa 01"
    assert cycle["stats"]["count"] == 1
    assert cycle["stats"]["temperature_max"] == 38.0
    assert [phase["stage"] for phase in cycle["phases"]] == ["Amarelação"]


def test_finishing_the_cure_stores_the_cycle(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    send_reading(client, 38.0, 85.0)
    finish(client, auth, unit_id)
    [cycle] = cycles(client, auth)
    assert cycle["status"] == "finished"
    assert cycle["ended_at"] is not None
    assert cycle["is_drying"] is False
    assert cycle["final_stage"] == "Secagem do talo"
    assert [phase["key"] for phase in cycle["phases"]] == ["amarelacao", "murchamento", "secagem_folha", "secagem_talo"]

    # Uma nova estufada não mexe na que terminou.
    client.post(f"/curing_units/{unit_id}/start-drying", headers=auth)
    send_reading(client, 36.0, 90.0)
    newest, previous = cycles(client, auth)
    assert newest["status"] == "in_progress"
    assert newest["stats"]["count"] == 1
    assert newest["stats"]["temperature_max"] == 36.0
    assert previous["id"] == cycle["id"]
    assert previous["status"] == "finished"
    assert previous["stats"]["count"] == 1


def test_new_batch_after_a_pause_marks_the_old_one_as_stopped(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    set_stage(client, auth, unit_id, "Murchamento")
    client.post(f"/curing_units/{unit_id}/stop-drying", headers=auth)

    [paused] = cycles(client, auth)
    assert paused["status"] == "in_progress"
    assert paused["is_drying"] is False

    client.post(f"/curing_units/{unit_id}/start-drying?new_batch=true", headers=auth)
    newest, stopped = cycles(client, auth)
    assert newest["status"] == "in_progress"
    assert newest["final_stage"] == "Amarelação"
    assert stopped["status"] == "stopped"
    assert stopped["final_stage"] == "Murchamento"


def test_resuming_keeps_the_same_cycle(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    client.post(f"/curing_units/{unit_id}/stop-drying", headers=auth)
    client.post(f"/curing_units/{unit_id}/start-drying", headers=auth)
    [cycle] = cycles(client, auth)
    assert cycle["status"] == "in_progress"
    assert cycle["is_drying"] is True


def test_correcting_a_finished_cure_reopens_it(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    set_stage(client, auth, unit_id, "Finalizado")
    assert cycles(client, auth)[0]["status"] == "finished"

    set_stage(client, auth, unit_id, "Secagem do talo")
    client.post(f"/curing_units/{unit_id}/start-drying", headers=auth)
    [cycle] = cycles(client, auth)
    assert cycle["status"] == "in_progress"
    assert cycle["final_stage"] == "Secagem do talo"


def test_detail_lists_the_alerts_of_the_cycle(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    add_past_readings(unit_id, range(15, 0, -1), temperature=43.0)
    send_reading(client, 43.0, 85.0)
    [cycle] = cycles(client, auth)
    assert cycle["alerts"] >= 1
    detail = client.get(f"/curing-cycles/{cycle['id']}", headers=auth).json()
    assert detail["alert_items"]
    assert detail["alert_items"][0]["curing_unit_name"] == "Estufa 01"


def test_filter_by_unit_and_ownership(client, auth, drying_unit):
    other_unit = client.post("/curing_units/", json={"name": "Estufa 02"}, headers=auth).json()
    assert cycles(client, auth, curing_unit_id=other_unit["id"]) == []
    assert len(cycles(client, auth, curing_unit_id=drying_unit["unit"]["id"])) == 1

    stranger = register(client, login="vizinho")
    assert cycles(client, stranger) == []
    cycle_id = cycles(client, auth)[0]["id"]
    assert client.get(f"/curing-cycles/{cycle_id}", headers=stranger).status_code == 404


def test_migration_creates_the_current_cycle(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    with SessionLocal() as db:
        db.query(CuringCycle).delete()
        db.commit()
    initialize_database()
    with SessionLocal() as db:
        unit = db.get(CuringUnit, unit_id)
        [cycle] = unit.cycles
        assert cycle.status == "in_progress"
        assert cycle.started_at == unit.cycle_started_at
    # Rodar de novo não duplica.
    initialize_database()
    assert len(cycles(client, auth)) == 1
