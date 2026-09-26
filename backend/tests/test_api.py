from core.config import settings
from conftest import register, send_reading


def test_register_validates_input(client):
    response = client.post("/auth/register", json={"name": "A", "login": "ab", "password": "123"})
    assert response.status_code == 422


def test_login_and_me(client, auth):
    assert client.post("/auth/login", json={"login": "produtor", "password": "errada"}).status_code == 401
    tokens = client.post("/auth/login", json={"login": " produtor ", "password": "segredo123"}).json()
    me = client.get("/users/me", headers={"Authorization": f"Bearer {tokens['access_token']}"})
    assert me.json()["login"] == "produtor"


def test_refresh_token(client):
    tokens = client.post("/auth/register", json={"name": "Maria", "login": "maria", "password": "segredo123"}).json()
    response = client.post("/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert response.status_code == 200
    assert client.post("/auth/refresh", json={"refresh_token": tokens["access_token"]}).status_code == 401


def test_password_reset_does_not_reveal_users(client, auth):
    unknown = client.post("/auth/password-reset/request", json={"login": "ninguem"})
    assert unknown.status_code == 200
    assert "reset_token" not in unknown.json()

    known = client.post("/auth/password-reset/request", json={"login": "produtor"}).json()
    confirm = client.post(
        "/auth/password-reset/confirm",
        json={"login": "produtor", "reset_token": known["reset_token"], "new_password": "novasenha"},
    )
    assert confirm.status_code == 200
    assert client.post("/auth/login", json={"login": "produtor", "password": "novasenha"}).status_code == 200


def test_password_reset_hides_token_outside_development(client, auth, monkeypatch):
    monkeypatch.setattr(settings, "ENVIRONMENT", "production")
    response = client.post("/auth/password-reset/request", json={"login": "produtor"})
    assert "reset_token" not in response.json()


def test_readings_require_authentication(client):
    assert client.get("/readings/readings/").status_code == 401
    assert client.get("/readings/").status_code == 401


def test_unit_can_be_created_without_device(client, auth):
    response = client.post("/curing_units/", json={"name": "Estufa sem sensor"}, headers=auth)
    assert response.status_code == 201
    assert response.json()["device_id"] is None


def test_reading_is_stored_only_while_drying(client, auth):
    device = client.post("/devices/link", json={"controller_id": "ESP32-TOBACCO-01"}, headers=auth).json()
    unit = client.post("/curing_units/", json={"name": "Estufa 01", "device_id": device["id"]}, headers=auth).json()

    blocked = send_reading(client)
    assert blocked.status_code == 202
    assert blocked.json()["reason"] == "drying_not_started"

    client.post(f"/curing_units/{unit['id']}/start-drying", headers=auth)
    stored = send_reading(client)
    assert stored.status_code == 201
    assert stored.json()["stored"] is True

    client.post(f"/curing_units/{unit['id']}/stop-drying", headers=auth)
    assert send_reading(client).json()["reason"] == "drying_not_started"

    readings = client.get(f"/curing_units/{unit['id']}/readings", headers=auth).json()
    assert len(readings) == 1
    assert readings[0]["timestamp"].endswith(("Z", "+00:00"))


def test_reading_never_goes_to_another_users_unit(client, auth, drying_unit):
    # Um sensor desconhecido não pode cair na estufa de outro usuário.
    response = send_reading(client, controller_id="ESP32-DESCONHECIDO", curing_unit_id=drying_unit["unit"]["id"])
    assert response.status_code == 202
    assert response.json()["reason"] == "no_curing_unit"

    readings = client.get(f"/curing_units/{drying_unit['unit']['id']}/readings", headers=auth).json()
    assert readings == []


def test_reading_requires_device_identification(client):
    response = client.post("/readings/readings/", json={"temperature": 30, "humidity": 50})
    assert response.status_code == 422


def test_reading_rejects_impossible_values(client):
    assert send_reading(client, humidity=140).status_code == 422


def test_unknown_device_is_registered_for_linking(client, auth):
    send_reading(client, controller_id="ESP32-NOVO", rssi=-80, snr=7)
    device = client.post("/devices/link", json={"controller_id": "ESP32-NOVO"}, headers=auth).json()
    assert device["rssi"] == -80
    assert device["status"] == "online"


def test_alerts_are_deduplicated_and_resolved(client, auth, drying_unit):
    for _ in range(3):
        send_reading(client, temperature=80.0)

    active = client.get("/alerts/?active=true", headers=auth).json()
    assert len(active) == 1
    assert active[0]["type"] == "Temperatura alta"
    assert active[0]["severity"] == "critical"
    assert active[0]["curing_unit_name"] == "Estufa 01"

    send_reading(client, temperature=50.0)
    assert client.get("/alerts/?active=true", headers=auth).json() == []
    assert len(client.get("/alerts/?active=false", headers=auth).json()) == 1


def test_alerts_follow_device_thresholds(client, auth, drying_unit):
    device_id = drying_unit["device"]["id"]
    client.post(
        f"/devices/{device_id}/thresholds",
        json={"temp_min": 30, "temp_max": 45, "humidity_min": 50, "humidity_max": 70},
        headers=auth,
    )
    send_reading(client, temperature=46.0, humidity=45.0)
    types = {alert["type"] for alert in client.get("/alerts/", headers=auth).json()}
    assert types == {"Temperatura alta", "Umidade baixa"}


def test_thresholds_must_be_ordered(client, auth, drying_unit):
    response = client.post(
        f"/devices/{drying_unit['device']['id']}/thresholds",
        json={"temp_min": 60, "temp_max": 40, "humidity_min": 50, "humidity_max": 70},
        headers=auth,
    )
    assert response.status_code == 422


def test_acknowledge_and_resolve_alert(client, auth, drying_unit):
    send_reading(client, temperature=80.0)
    alert = client.get("/alerts/", headers=auth).json()[0]

    acknowledged = client.post(f"/alerts/{alert['id']}/acknowledge", headers=auth).json()
    assert acknowledged["alert"]["acknowledged_at"] is not None

    resolved = client.post(f"/alerts/{alert['id']}/resolve", headers=auth).json()
    assert resolved["alert"]["is_active"] is False


def test_alerts_are_private(client, auth, drying_unit):
    send_reading(client, temperature=80.0)
    alert_id = client.get("/alerts/", headers=auth).json()[0]["id"]

    other = register(client, login="vizinho")
    assert client.get("/alerts/", headers=other).json() == []
    assert client.post(f"/alerts/{alert_id}/resolve", headers=other).status_code == 404


def test_unlink_device_keeps_unit_and_history(client, auth, drying_unit):
    send_reading(client)
    device_id = drying_unit["device"]["id"]
    unit_id = drying_unit["unit"]["id"]

    assert client.delete(f"/devices/{device_id}", headers=auth).status_code == 200

    unit = client.get(f"/curing_units/{unit_id}", headers=auth).json()
    assert unit["device_id"] is None
    assert len(client.get(f"/curing_units/{unit_id}/readings", headers=auth).json()) == 1
    assert client.get("/devices/", headers=auth).json() == []

    # Outro usuário pode vincular o dispositivo, mas não herda a estufa nem o histórico.
    other = register(client, login="vizinho")
    client.post("/devices/link", json={"controller_id": "ESP32-TOBACCO-01"}, headers=other)
    assert client.get("/curing_units/", headers=other).json() == []


def test_link_rejects_units_of_other_users(client, auth, drying_unit):
    other = register(client, login="vizinho")
    response = client.post(
        "/devices/link",
        json={"controller_id": "ESP32-OUTRO", "curing_unit_id": drying_unit["unit"]["id"]},
        headers=other,
    )
    assert response.status_code == 404


def test_link_rejects_device_of_other_user(client, auth, drying_unit):
    other = register(client, login="vizinho")
    response = client.post("/devices/link", json={"controller_id": "ESP32-TOBACCO-01"}, headers=other)
    assert response.status_code == 403


def test_device_does_not_report_fake_telemetry(client, auth):
    device = client.post("/devices/link", json={"controller_id": "ESP32-NOVO"}, headers=auth).json()
    assert device["status"] == "offline"
    assert device["rssi"] is None
    assert device["battery_level"] is None
    assert device["mac_address"] is None

    reconnect = client.post(f"/devices/{device['id']}/reconnect", headers=auth).json()
    assert reconnect["status"] == "offline"


def test_gateway_key(client, auth, drying_unit, monkeypatch):
    monkeypatch.setattr(settings, "GATEWAY_API_KEY", "chave-do-gateway")
    assert send_reading(client).status_code == 401
    response = client.post(
        "/readings/readings/",
        json={"temperature": 40, "humidity": 60, "controller_id": "ESP32-TOBACCO-01"},
        headers={"X-API-Key": "chave-do-gateway"},
    )
    assert response.status_code == 201


def test_readings_since_and_limit(client, auth, drying_unit):
    for temperature in (40, 41, 42):
        send_reading(client, temperature=temperature)
    unit_id = drying_unit["unit"]["id"]

    limited = client.get(f"/curing_units/{unit_id}/readings?limit=2", headers=auth).json()
    assert [reading["temperature"] for reading in limited] == [42, 41]

    future = client.get(f"/curing_units/{unit_id}/readings?since=2999-01-01T00:00:00Z", headers=auth).json()
    assert future == []


def test_series_groups_readings(client, auth, drying_unit):
    for temperature, humidity in ((40, 60), (44, 62), (42, 58)):
        send_reading(client, temperature=temperature, humidity=humidity)
    unit_id = drying_unit["unit"]["id"]

    series = client.get(f"/curing_units/{unit_id}/series?points=10", headers=auth).json()
    assert series["stats"]["count"] == 3
    assert series["stats"]["temperature_max"] == 44
    assert series["stats"]["humidity_min"] == 58
    assert sum(point["count"] for point in series["points"]) == 3
    assert series["points"][-1]["timestamp"].endswith(("Z", "+00:00"))

    empty = client.get(f"/curing_units/{unit_id}/series?since=2000-01-01T00:00:00Z&until=2000-01-02T00:00:00Z", headers=auth)
    assert empty.json()["points"] == []
    assert empty.json()["stats"]["count"] == 0


def test_csv_export(client, auth, drying_unit):
    send_reading(client, temperature=25.5, humidity=61.25)
    response = client.get(f"/curing_units/{drying_unit['unit']['id']}/readings.csv", headers=auth)
    assert response.status_code == 200
    lines = response.text.lstrip("﻿").strip().splitlines()
    assert lines[0] == "data_hora_utc;temperatura_c;temperatura_f;umidade_pct"
    assert lines[1].endswith(";25,50;77,90;61,25")


def test_estimate_and_update(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    updated = client.patch(
        f"/curing_units/{unit_id}",
        json={"curing_stage": "Amarelecimento", "estimated_duration_hours": 48},
        headers=auth,
    ).json()
    assert updated["curing_stage"] == "Amarelecimento"
    assert updated["estimated_completion_at"] is not None

    estimate = client.get(f"/curing_units/{unit_id}/estimate", headers=auth).json()
    assert 47 < estimate["remaining_hours"] <= 48


def test_change_password(client, auth):
    wrong = client.post("/users/me/password", json={"current_password": "x", "new_password": "novasenha"}, headers=auth)
    assert wrong.status_code == 400
    ok = client.post("/users/me/password", json={"current_password": "segredo123", "new_password": "novasenha"}, headers=auth)
    assert ok.status_code == 200


def test_web_panel_is_served(client):
    response = client.get("/", follow_redirects=False)
    assert response.status_code in (302, 307)
    assert client.get("/health").json() == {"status": "ok"}
