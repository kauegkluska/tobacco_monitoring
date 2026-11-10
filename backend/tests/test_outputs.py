import pytest
from conftest import hold, humidity_for, send_reading, set_stage


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


def test_auto_mode_turns_on_outside_the_safe_range_with_hysteresis(client, auth, drying_unit, clock):
    # Amarelação: 35–40 °C e 80–95%. As duas saídas passam às regras antigas de faixa, que continuam selecionáveis.
    unit_id = drying_unit["unit"]["id"]
    client.patch(
        f"/curing_units/{unit_id}/outputs",
        json={"humidity_trigger": "humidity_out", "temperature_trigger": "temperature_out"},
        headers=auth,
    )
    assert commands(hold(client, clock, 38.0, 90.0)) == (False, False)
    assert commands(hold(client, clock, 38.0, 97.0)) == (True, False)
    # 94,5% ainda está na margem de 1 ponto: a saída continua ligada.
    assert commands(hold(client, clock, 38.0, 94.5, 300)) == (True, False)
    assert commands(hold(client, clock, 38.0, 90.0)) == (False, False)
    # 7 °C de uma amostra para outra é salto: o pacote é descartado e não decide nada.
    assert commands(send_reading(client, 45.0, 90.0)) == (False, False)
    assert commands(hold(client, clock, 45.0, 90.0, 90)) == (False, True)

    outputs = client.get(f"/curing_units/{unit_id}/outputs", headers=auth).json()
    temperature = outputs["temperature"]
    assert (temperature["mode"], temperature["on"], temperature["trigger"]) == ("auto", True, "temperature_out")
    assert temperature["reason"] == "Ligada porque a temperatura saiu da faixa esperada."
    assert (temperature["name"], temperature["relay"], temperature["pin"]) == ("Soprador", 2, "GPIO3")
    events = outputs["events"]
    assert [(e["output"], e["turned_on"], e["cause"], e["rule"]) for e in events] == [
        ("temperature", True, "auto", "range"),
        ("humidity", False, "auto", "range"),
        ("humidity", True, "auto", "range"),
    ]
    # O valor registrado é a mediana de 30 s, não a leitura bruta.
    assert events[2]["metric"] == "humidity"
    assert abs(events[2]["value"] - 97.0) < 0.05
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


def test_output_events_feed_is_private_and_incremental(client, auth, drying_unit, clock):
    client.patch(f"/curing_units/{drying_unit['unit']['id']}/outputs", json={"target_temperature": 36}, headers=auth)
    hold(client, clock, 30.0, 85.0, 30)
    first = client.get("/output-events/?limit=1", headers=auth).json()
    assert len(first) == 1 and first[0]["curing_unit_name"] == "Estufa 01"

    assert client.get(f"/output-events/?after_id={first[0]['id']}", headers=auth).json() == []
    hold(client, clock, 34.0, 85.0, 180)
    hold(client, clock, 30.0, 85.0, 180)
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


def test_output_can_be_renamed_and_follow_another_rule(client, auth, drying_unit, clock):
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
    assert commands(hold(client, clock, 20.0, 85.0)) == (False, False)
    assert commands(hold(client, clock, 45.0, 85.0, 120)) == (True, False)
    # Dentro da margem de 0,5 °C; e o mínimo ligado de 3 min passa.
    assert commands(hold(client, clock, 39.8, 85.0, 300)) == (True, False)
    assert commands(hold(client, clock, 39.0, 85.0, 60)) == (False, False)

    events = client.get(f"/curing_units/{unit_id}/outputs", headers=auth).json()["events"]
    fans_on = next(e for e in events if e["output"] == "humidity" and e["turned_on"])
    assert (fans_on["output_name"], fans_on["metric"]) == ("Ventoinhas do forno", "temperature")
    assert abs(fans_on["value"] - 45.0) < 0.05


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


def test_flap_follows_the_wet_bulb_limit_of_the_phase(client, auth, drying_unit, clock):
    unit_id = drying_unit["unit"]["id"]
    url = f"/curing_units/{unit_id}/outputs"
    flap = client.get(url, headers=auth).json()["humidity"]
    assert flap["trigger"] == "humidity_phase"
    assert flap["reason"] == "Flap fechado: na Amarelação ele fica fechado no automático."

    # Sem degraus entre as fases: as leituras começam já na Secagem da folha.
    set_stage(client, auth, unit_id, "Secagem da folha")
    assert commands(hold(client, clock, 55.0, humidity_for(55.0, 39.5), 120)) == (False, False)
    flap = client.get(url, headers=auth).json()["humidity"]
    assert flap["reason"] == "Flap fechado: umidade dentro do alvo."
    assert flap["values"]["tw_limite"] == 40.0
    assert abs(flap["values"]["tw"] - 39.5) < 0.05 and abs(flap["values"]["tseco"] - 55.0) < 0.05

    assert commands(hold(client, clock, 55.0, humidity_for(55.0, 40.5), 60)) == (True, False)
    outputs = client.get(url, headers=auth).json()
    assert outputs["humidity"]["reason"] == "Flap aberto: umidade acima do limite da fase."
    opened = outputs["events"][0]
    assert (opened["metric"], opened["rule"]) == ("wet_bulb", "humidity")
    assert abs(opened["value"] - 40.5) < 0.05


def test_fan_starts_a_ramp_when_the_target_is_set(client, auth, drying_unit, clock):
    unit_id = drying_unit["unit"]["id"]
    url = f"/curing_units/{unit_id}/outputs"
    outputs = client.get(url, headers=auth).json()
    assert (outputs["humidity"]["name"], outputs["temperature"]["name"]) == ("Flap", "Soprador")
    assert outputs["temperature"]["trigger"] == "temperature_target"
    assert outputs["target_temperature"] is None
    assert outputs["temperature"]["reason"] == "Desligada: defina a temperatura alvo."
    # Sem alvo, o soprador não liga nem com a estufa fria.
    assert commands(hold(client, clock, 30.0, 85.0, 30)) == (False, False)

    changed = client.patch(url, json={"target_temperature": 38}, headers=auth).json()
    assert changed["target_temperature"] == 38
    # Na Amarelação o aquecimento inicial é livre: a rampa parte de 32,2 °C, não dos 30 °C medidos.
    assert changed["target_effective"] == pytest.approx(32.2)
    # A última leitura (30 °C) já está abaixo da faixa do alvo efetivo: liga sem esperar a próxima.
    assert changed["temperature"]["on"] is True
    assert changed["temperature"]["reason"] == "A temperatura vai subir aos poucos até o alvo."
    assert changed["temperature"]["values"]["taxa_limite"] == 1.1


def test_fan_keeps_the_target_temperature(client, auth, drying_unit, clock):
    unit_id = drying_unit["unit"]["id"]
    url = f"/curing_units/{unit_id}/outputs"
    # Com a estufa já no alvo, a rampa começa e termina no próprio alvo.
    assert commands(hold(client, clock, 38.0, 85.0, 60)) == (False, False)
    changed = client.patch(url, json={"target_temperature": 38}, headers=auth).json()
    assert changed["target_effective"] == pytest.approx(38.0, abs=0.05)
    assert changed["temperature"]["reason"] == "Liga quando a temperatura ficar abaixo da faixa do alvo."
    # Faixa de ±2 °F em torno de 38 °C: de 36,89 °C a 39,11 °C. Cada nível dura mais que o mínimo de 2 min.
    assert commands(hold(client, clock, 39.0, 85.0, 150)) == (False, False)  # dentro da faixa: segue desligado
    assert commands(hold(client, clock, 37.0, 85.0, 150)) == (False, False)  # ainda dentro da faixa
    assert commands(hold(client, clock, 36.8, 85.0, 150)) == (False, True)  # abaixo da faixa: liga
    assert commands(hold(client, clock, 38.0, 85.0, 150)) == (False, True)  # no alvo: segue ligado
    assert commands(hold(client, clock, 39.0, 85.0, 150)) == (False, True)  # ainda dentro da faixa
    assert commands(hold(client, clock, 39.2, 85.0, 150)) == (False, False)  # passou da faixa: desliga
    assert commands(hold(client, clock, 36.8, 85.0, 150)) == (False, True)

    # Oscilação dentro da faixa não gera nenhum acionamento novo.
    before = client.get(url, headers=auth).json()["events"][0]["id"]
    for value in (37.2, 38.5, 37.0, 39.0, 36.95, 38.0):
        assert commands(hold(client, clock, value, 85.0, 30)) == (False, True)
    assert client.get(url, headers=auth).json()["events"][0]["id"] == before

    assert client.get(f"/curing_units/{unit_id}", headers=auth).json()["target_temperature"] == 38
    assert client.patch(url, json={"target_temperature": 95}, headers=auth).status_code == 422


# 13. Limite do alvo: alvo + faixa não passa da temperatura máxima da fase.
def test_target_is_limited_by_the_phase(client, auth, drying_unit):
    unit_id = drying_unit["unit"]["id"]
    url = f"/curing_units/{unit_id}/outputs"
    limits = {"Amarelação": 38.9, "Murchamento": 46.7, "Secagem da folha": 56.1, "Secagem do talo": 72.9}
    for stage, limit in limits.items():
        set_stage(client, auth, unit_id, stage)
        assert client.get(url, headers=auth).json()["target_max"] == pytest.approx(limit, abs=0.02)

    refused = client.patch(url, json={"target_temperature": 80}, headers=auth)
    assert refused.status_code == 422
    assert not any(character.isdigit() for character in refused.json()["detail"])
    set_stage(client, auth, unit_id, "Secagem da folha")
    assert client.patch(url, json={"target_temperature": 60}, headers=auth).status_code == 422
    assert client.patch(url, json={"target_temperature": 56}, headers=auth).status_code == 200
    # 102 °F convertido e arredondado pelo app (38,89 °C) cabe na Amarelação.
    set_stage(client, auth, unit_id, "Amarelação")
    assert client.patch(url, json={"target_temperature": 38.89}, headers=auth).status_code == 200

    set_stage(client, auth, unit_id, "Murchamento")
    assert client.patch(url, json={"target_temperature": 45}, headers=auth).status_code == 200
    # Correção de fase para a Amarelação: o alvo cai ao máximo da nova fase.
    set_stage(client, auth, unit_id, "Amarelação")
    outputs = client.get(url, headers=auth).json()
    assert outputs["target_temperature"] == pytest.approx(38.9, abs=0.02)
    assert outputs["temperature"]["reason"].startswith("O alvo de Soprador foi limitado ao máximo da fase.")
    # A4: alerta informativo com o mesmo texto.
    active = {alert["type"]: alert for alert in client.get("/alerts/?active=true", headers=auth).json()}
    assert (active["Alvo reduzido"]["severity"], active["Alvo reduzido"]["message"]) == (
        "info", "O alvo de Soprador foi limitado ao máximo da fase.",
    )
    # Gravar um alvo novo apaga o aviso e encerra o alerta.
    changed = client.patch(url, json={"target_temperature": 36}, headers=auth).json()
    assert "limitado" not in changed["temperature"]["reason"]
    active = {alert["type"] for alert in client.get("/alerts/?active=true", headers=auth).json()}
    assert "Alvo reduzido" not in active
