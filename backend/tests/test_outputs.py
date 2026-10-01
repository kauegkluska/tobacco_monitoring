from conftest import send_reading


def firmware_bool(text: str, key: str, default: bool = False) -> bool:
    """Mesma lógica de extrairBooleanJSON() do receiver.ino: primeira ocorrência da chave no texto."""
    pos = text.find(key)
    if pos < 0:
        return default
    pos = text.find(":", pos)
    if pos < 0:
        return default
    rest = text[pos + 1:].lstrip(" ")
    if rest.startswith("true"):
        return True
    if rest.startswith("false"):
        return False
    return default


def commands(response) -> tuple[bool, bool]:
    return firmware_bool(response.text, "rele_umidade"), firmware_bool(response.text, "rele_temperatura")


def test_outputs_start_off_and_are_read_by_the_firmware(client, auth, drying_unit):
    response = send_reading(client, 38.0, 85.0)
    assert response.status_code == 201
    assert response.text.startswith('{"rele_umidade":false,"rele_temperatura":false')
    assert commands(response) == (False, False)


def test_auto_mode_turns_on_outside_the_safe_range_with_hysteresis(client, auth, drying_unit):
    # Amarelação: 35–40 °C e 80–95%. A ventoinha passa a seguir a faixa em vez da temperatura alvo.
    unit_id = drying_unit["unit"]["id"]
    client.patch(f"/curing_units/{unit_id}/outputs", json={"temperature_trigger": "temperature_out"}, headers=auth)
    assert commands(send_reading(client, 38.0, 97.0)) == (True, False)
    # 94,5% ainda está na margem de 1 ponto: a saída continua ligada.
    assert commands(send_reading(client, 38.0, 94.5)) == (True, False)
    assert commands(send_reading(client, 38.0, 90.0)) == (False, False)
    assert commands(send_reading(client, 45.0, 90.0)) == (False, True)

    outputs = client.get(f"/curing_units/{unit_id}/outputs", headers=auth).json()
    temperature = outputs["temperature"]
    assert (temperature["mode"], temperature["on"], temperature["trigger"]) == ("auto", True, "temperature_out")
    assert temperature["reason"] == "Ligada: a temperatura saiu da faixa esperada."
    assert (temperature["name"], temperature["relay"], temperature["pin"]) == ("Ventoinha", 2, "GPIO3")
    events = outputs["events"]
    assert [(e["output"], e["turned_on"], e["cause"]) for e in events] == [
        ("temperature", True, "auto"),
        ("humidity", False, "auto"),
        ("humidity", True, "auto"),
    ]
    assert events[2]["value"] == 97.0
    assert outputs["last_buzzer"]["output"] == "temperature"
    assert outputs["last_buzzer"]["buzzer"] is True


def test_manual_mode_is_sent_even_without_drying(client, auth):
    device = client.post("/devices/link", json={"controller_id": "ESP32-TOBACCO-01"}, headers=auth).json()
    unit = client.post("/curing_units/", json={"name": "Estufa 01", "device_id": device["id"]}, headers=auth).json()

    changed = client.patch(f"/curing_units/{unit['id']}/outputs", json={"humidity_mode": "on"}, headers=auth)
    assert changed.status_code == 200
    assert changed.json()["humidity"]["on"] is True
    assert changed.json()["events"][0]["cause"] == "manual"

    response = send_reading(client)
    assert response.status_code == 202
    assert response.json()["reason"] == "drying_not_started"
    assert commands(response) == (True, False)

    client.patch(f"/curing_units/{unit['id']}/outputs", json={"humidity_mode": "off"}, headers=auth)
    assert commands(send_reading(client)) == (False, False)


def test_invalid_mode_is_rejected(client, auth, drying_unit):
    response = client.patch(
        f"/curing_units/{drying_unit['unit']['id']}/outputs", json={"temperature_mode": "ligado"}, headers=auth,
    )
    assert response.status_code == 422


def test_stopping_the_drying_turns_auto_outputs_off(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    client.patch(f"/curing_units/{unit_id}/outputs", json={"target_temperature": 38}, headers=auth)
    assert commands(send_reading(client, 20.0, 85.0)) == (False, True)

    client.post(f"/curing_units/{unit_id}/stop-drying", headers=auth)
    outputs = client.get(f"/curing_units/{unit_id}/outputs", headers=auth).json()
    assert outputs["temperature"]["on"] is False
    assert outputs["events"][0]["cause"] == "stopped"
    assert commands(send_reading(client, 20.0, 85.0)) == (False, False)


def test_unknown_device_gets_outputs_off(client):
    response = send_reading(client, 20.0, 99.0, controller_id="ESP32-NOVO")
    assert response.status_code == 202
    assert commands(response) == (False, False)


def test_output_events_feed_is_private_and_incremental(client, auth, drying_unit):
    client.patch(f"/curing_units/{drying_unit['unit']['id']}/outputs", json={"target_temperature": 36}, headers=auth)
    send_reading(client, 38.0, 97.0)
    first = client.get("/output-events/?limit=1", headers=auth).json()
    assert len(first) == 1 and first[0]["curing_unit_name"] == "Estufa 01"

    assert client.get(f"/output-events/?after_id={first[0]['id']}", headers=auth).json() == []
    send_reading(client, 35.0, 97.0)
    newer = client.get(f"/output-events/?after_id={first[0]['id']}&buzzer=true", headers=auth).json()
    assert [(e["output"], e["buzzer"]) for e in newer] == [("temperature", True)]

    from conftest import register
    other = register(client, login="vizinho")
    assert client.get("/output-events/", headers=other).json() == []
    assert client.get(f"/curing_units/{drying_unit['unit']['id']}/outputs", headers=other).status_code == 404


def test_unit_with_only_output_events_can_be_deleted(client, auth):
    unit = client.post("/curing_units/", json={"name": "Teste"}, headers=auth).json()
    client.patch(f"/curing_units/{unit['id']}/outputs", json={"humidity_mode": "on"}, headers=auth)
    assert client.delete(f"/curing_units/{unit['id']}", headers=auth).status_code == 200


def test_output_can_be_renamed_and_follow_another_rule(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    changed = client.patch(
        f"/curing_units/{unit_id}/outputs",
        json={"humidity_name": "  Ventoinhas   do forno ", "humidity_trigger": "temperature_high"},
        headers=auth,
    )
    assert changed.status_code == 200
    fans = changed.json()["humidity"]
    assert fans["name"] == "Ventoinhas do forno"
    assert fans["reason"] == "Liga quando a temperatura passar do máximo."

    # Temperatura baixa não liga as ventoinhas (só acima do máximo da Amarelação, 40 °C).
    # A ventoinha do relé 2 fica desligada: ainda não há temperatura alvo.
    assert commands(send_reading(client, 20.0, 85.0)) == (False, False)
    assert commands(send_reading(client, 45.0, 85.0)) == (True, False)
    assert commands(send_reading(client, 39.8, 85.0)) == (True, False)  # dentro da margem de 0,5 °C
    assert commands(send_reading(client, 39.0, 85.0)) == (False, False)

    events = client.get(f"/curing_units/{unit_id}/outputs", headers=auth).json()["events"]
    fans_on = next(e for e in events if e["output"] == "humidity" and e["turned_on"])
    assert (fans_on["output_name"], fans_on["metric"], fans_on["value"]) == ("Ventoinhas do forno", "temperature", 45.0)


def test_output_name_and_rule_are_validated(client, auth, drying_unit):
    url = f"/curing_units/{drying_unit['unit']['id']}/outputs"
    assert client.patch(url, json={"humidity_name": "   "}, headers=auth).status_code == 422
    assert client.patch(url, json={"humidity_name": "x" * 41}, headers=auth).status_code == 422
    assert client.patch(url, json={"temperature_trigger": "sempre"}, headers=auth).status_code == 422


def test_sender_confirms_the_relay_state(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    client.patch(f"/curing_units/{unit_id}/outputs", json={"humidity_mode": "on"}, headers=auth)
    outputs = client.get(f"/curing_units/{unit_id}/outputs", headers=auth).json()
    assert outputs["humidity"]["confirmed_on"] is None
    assert outputs["humidity"]["in_sync"] is False

    send_reading(client, 40.0, 60.0, output_humidity_state=True, output_temperature_state=False)
    outputs = client.get(f"/curing_units/{unit_id}/outputs", headers=auth).json()
    assert outputs["humidity"]["confirmed_on"] is True and outputs["humidity"]["in_sync"] is True
    assert outputs["temperature"]["in_sync"] is True
    assert outputs["confirmed_at"] is not None

    client.patch(f"/curing_units/{unit_id}/outputs", json={"humidity_mode": "off"}, headers=auth)
    outputs = client.get(f"/curing_units/{unit_id}/outputs", headers=auth).json()
    assert outputs["humidity"]["in_sync"] is False  # aguardando o sender aplicar


def test_fan_keeps_the_target_temperature(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    url = f"/curing_units/{unit_id}/outputs"
    outputs = client.get(url, headers=auth).json()
    assert (outputs["humidity"]["name"], outputs["temperature"]["name"]) == ("Flap", "Ventoinha")
    assert outputs["temperature"]["trigger"] == "temperature_target"
    assert outputs["target_temperature"] is None
    assert outputs["temperature"]["reason"] == "Desligada: defina a temperatura alvo."
    # Sem alvo, a ventoinha não liga nem com a estufa fria.
    assert commands(send_reading(client, 30.0, 85.0)) == (False, False)

    changed = client.patch(url, json={"target_temperature": 38}, headers=auth).json()
    assert changed["target_temperature"] == 38
    # A última leitura (30 °C) já está abaixo do alvo: liga sem esperar a próxima.
    assert changed["temperature"]["on"] is True
    assert changed["temperature"]["reason"] == "Ligada: a temperatura está abaixo do alvo."
    assert commands(send_reading(client, 37.9, 85.0)) == (False, True)  # segue até atingir o alvo
    assert commands(send_reading(client, 38.0, 85.0)) == (False, False)  # atingiu: desliga
    assert commands(send_reading(client, 37.7, 85.0)) == (False, False)  # dentro da margem de 0,5 °C
    assert commands(send_reading(client, 37.4, 85.0)) == (False, True)

    assert client.get(f"/curing_units/{unit_id}", headers=auth).json()["target_temperature"] == 38
    assert client.patch(url, json={"target_temperature": 95}, headers=auth).status_code == 422
