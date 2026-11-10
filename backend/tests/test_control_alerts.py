"""Alertas e textos do controle do flap e do soprador (parte e), com tempo simulado e as saídas no caminho de produção."""

import re
from datetime import datetime, timedelta

import pytest
import test_controls as controls
from conftest import Sim, make_unit
from models.curing_unit import CuringUnit
from services import messages
from services.alert_engine import _heating_message, _wet_bulb_high_message
from services.phases import (
    DEPRESSION_HIGH_TYPE,
    DROP_TYPE,
    HEATING_TYPE,
    MANUAL_FLAP_TYPE,
    VERY_WET_TYPE,
    WEAK_FIRE_TYPE,
    WET_BULB_HIGH_TYPE,
    WET_LOAD_TYPE,
)

LEAF = controls.LEAF
run, towards, flap, toggles = controls.run, controls.towards, controls.flap, controls.toggles


@pytest.fixture()
def unit_id(client, auth) -> int:
    return make_unit(client, auth)


def leaf_after_grace(unit_id: int) -> Sim:
    """Secagem da folha passada a carência de entrada (1 h com a estufa já na faixa)."""
    sim = Sim(unit_id, LEAF)
    sim.skip(70)
    return sim


# 5. Amarelação muito úmida: o flap fica fechado e A1 abre depois de cerca de 30 min.
def test_very_wet_yellowing_keeps_the_flap_closed_and_raises_a1(unit_id):
    sim = Sim(unit_id, "Amarelação")
    run(sim, 30, 38.0, 36.0)
    run(sim, 1, 38.0, towards(36.0, 37.8, 1))
    run(sim, 20, 38.0, 37.8)
    assert VERY_WET_TYPE not in sim.active()
    # Persistência dos alertas: 80 % das amostras da janela de 30 min; abre por volta dos 24 min.
    run(sim, 10, 38.0, 37.8)
    alert = sim.active()[VERY_WET_TYPE]
    assert alert.severity == "info"
    assert alert.message == "Estufa muito úmida: se o fumo estiver suando, abra Flap por poucos minutos."
    run(sim, 30, 38.0, 37.8)
    assert not flap(sim) and toggles(sim) == []
    # Encerra com mais de 1,0 °C de diferença por 10 min.
    run(sim, 1, 38.0, towards(37.8, 36.8, 1))
    run(sim, 6, 38.0, 36.8)
    assert VERY_WET_TYPE in sim.active()
    run(sim, 6, 38.0, 36.8)
    assert VERY_WET_TYPE not in sim.active()


# 10. Queda × alerta.
def test_drop_that_stops_at_the_flap_closing_raises_no_alert(unit_id):
    sim = leaf_after_grace(unit_id)
    controls.open_flap_with_fan_on(sim, wet_bulb=40.05)
    run(sim, 2, towards(54.0, 52.4, 1.5), 40.05)
    run(sim, 4, 52.4, 40.05)
    assert not flap(sim) and toggles(sim)[-1].rule == "drop"
    # A queda parou em 1,6 °C: o alerta não abre.
    run(sim, 20, 52.4, 40.05)
    assert DROP_TYPE not in sim.active()


def test_drop_alert_names_the_flap_closing_as_the_cause(unit_id):
    sim = leaf_after_grace(unit_id)
    controls.open_flap_with_fan_on(sim, wet_bulb=40.05)
    # A estufa continua esfriando até 2,8 °C abaixo da referência; no caminho, o 4.2 fecha o flap.
    run(sim, 4, towards(54.0, 50.8, 3), 40.05)
    run(sim, 6, 50.8, 40.05)
    assert not flap(sim) and toggles(sim)[-1].rule == "drop"
    drop = sim.active()[DROP_TYPE]
    assert drop.message == "A estufa continua esfriando depois que Flap fechou: confira o fogo."
    # A causa fica no texto até o alerta encerrar, mesmo depois da janela de 10 min.
    run(sim, 15, 50.8, 40.05)
    assert sim.active()[DROP_TYPE].message == drop.message


def test_drop_alert_with_the_flap_open_for_humidity(unit_id):
    sim = leaf_after_grace(unit_id)
    controls.open_flap_with_fan_on(sim, wet_bulb=41.0)
    run(sim, 3, 54.0, 41.0)
    assert WET_BULB_HIGH_TYPE in sim.active()
    run(sim, 3, towards(54.0, 50.8, 2.5), 41.0)
    run(sim, 6, 50.8, 41.0)
    active = sim.active()
    assert flap(sim)
    assert active[WET_BULB_HIGH_TYPE].message == "Umidade alta com Flap aberto: não aumente o fogo."
    assert active[DROP_TYPE].message == "A estufa está esfriando com Flap aberto para tirar umidade: mantenha o fogo."


# 11. Dois fechamentos por queda em 60 min: A5.
def test_two_drop_closures_in_an_hour_raise_a5(unit_id):
    sim = leaf_after_grace(unit_id)
    controls.open_flap_with_fan_on(sim, wet_bulb=40.05)
    run(sim, 2, towards(54.0, 52.4, 1.5), 40.05)
    run(sim, 4, 52.4, 40.05)
    assert not flap(sim)
    assert WEAK_FIRE_TYPE not in sim.active()
    # A estufa se recupera, o flap reabre por umidade e a estufa volta a esfriar.
    run(sim, 2, towards(52.4, 54.0, 1.5), 40.05)
    run(sim, 6, 54.0, 40.05)
    assert flap(sim)
    run(sim, 2, towards(54.0, 52.4, 1.5), 40.05)
    run(sim, 4, 52.4, 40.05)
    assert not flap(sim)
    assert [event.rule for event in toggles(sim) if not event.turned_on] == ["drop", "drop"]
    alert = sim.active()[WEAK_FIRE_TYPE]
    assert (alert.severity, alert.message) == ("info", "O fogo não está acompanhando a ventilação.")


# 18. Modos manuais: as regras não atuam e os textos seguem o estado do relé.
def test_manual_flap_ignores_the_rules_and_texts_follow_the_relay(unit_id):
    sim = leaf_after_grace(unit_id)
    sim.set_unit(humidity_output_mode="off")
    run(sim, 5, 54.0, 39.5)
    run(sim, 1, 54.0, towards(39.5, 41.5, 1))
    run(sim, 4, 54.0, 41.5)
    assert not flap(sim) and toggles(sim) == []
    assert sim.active()[WET_BULB_HIGH_TYPE].message == "Umidade alta: abra Flap."
    # O sender informa o relé aberto (ligado à mão no painel): vale o estado confirmado.
    sim.set_unit(humidity_output_confirmed=True, outputs_confirmed_at=sim.now)
    run(sim, 0.5, 54.0, 41.5)
    assert sim.active()[WET_BULB_HIGH_TYPE].message == "Umidade alta com Flap aberto: não aumente o fogo."
    # Confirmação antiga: volta a valer o comando.
    run(sim, 2, 54.0, 41.5)
    assert sim.active()[WET_BULB_HIGH_TYPE].message == "Umidade alta: abra Flap."


def test_dry_air_text_follows_the_flap(unit_id):
    sim = Sim(unit_id, "Amarelação")
    sim.skip(13 * 60)
    sim.set_unit(humidity_output_mode="on")
    run(sim, 20, 38.0, 32.0)
    assert flap(sim)
    assert sim.active()[DEPRESSION_HIGH_TYPE].message == "Ar seco: feche Flap."


@pytest.mark.parametrize(
    "mode, target, text, fan_on",
    [
        ("on", None, "A temperatura está subindo rápido demais com Soprador ligado à mão: desligue-o ou coloque menos lenha.", True),
        ("auto", 56.0, "A temperatura está subindo rápido demais: o sistema desligou Soprador. Coloque menos lenha.", False),
        (
            "auto",
            None,
            "A temperatura está subindo mais rápido que o recomendado para a fase, com Soprador desligado: coloque menos lenha.",
            False,
        ),
    ],
)
def test_fast_heating_text_follows_the_fan(unit_id, mode, target, text, fan_on):
    sim = Sim(unit_id, LEAF)
    sim.set_unit(temperature_output_mode=mode, target_temperature=target, target_effective=target)
    run(sim, 10, 48.0, 38.0)
    run(sim, 80, lambda minute: 48.0 + 3.0 * minute / 60, 38.0)
    alert = sim.active()[HEATING_TYPE]
    assert alert.message == text
    assert controls.fan(sim) is fan_on
    assert alert.details["taxa_limite"] == 1.1 and alert.details["taxa"] > 1.1


def test_wet_bulb_high_text_for_each_flap_state():
    now = datetime(2026, 1, 10, 12)
    unit = CuringUnit(humidity_output_name="Janela", temperature_output_name="Ventarola", humidity_output_mode="auto")
    unit.humidity_output_on, unit.flap_drop_locked = True, False
    assert _wet_bulb_high_message(unit, now) == "Umidade alta com Janela aberto: não aumente o fogo."
    unit.humidity_output_on, unit.flap_drop_locked = False, True
    assert _wet_bulb_high_message(unit, now) == (
        "Umidade alta: Janela foi fechado porque a estufa esfriou. Ele reabre quando a temperatura se recuperar."
    )
    unit.flap_drop_locked = False
    unit.humidity_output_changed_at = now - timedelta(minutes=2)
    assert _wet_bulb_high_message(unit, now) == "Umidade alta: Janela reabre em instantes."
    unit.humidity_output_mode = "off"
    assert _wet_bulb_high_message(unit, now) == "Umidade alta: abra Janela."
    unit.temperature_output_on, unit.temperature_output_mode, unit.fan_rate_cut = False, "auto", True
    unit.temperature_output_trigger, unit.target_temperature = "temperature_target", 56.0
    assert _heating_message(unit, now) == "A temperatura está subindo rápido demais: o sistema desligou Ventarola. Coloque menos lenha."


# A2 e A3.
def test_wet_load_message_once_at_the_start_of_yellowing(unit_id):
    sim = Sim(unit_id, "Amarelação")
    run(sim, 2, 30.0, 29.0)
    alert = sim.active()[WET_LOAD_TYPE]
    assert alert.message == (
        "Se o fumo entrou molhado, deixe Flap em Ligada até as folhas enxugarem; depois volte para o Automático."
    )
    sim.skip(12 * 60)
    run(sim, 2, 32.0, 31.0)
    assert WET_LOAD_TYPE not in sim.active()
    assert [alert.type for alert in sim.all_alerts()].count(WET_LOAD_TYPE) == 1


def test_manual_flap_for_twelve_hours_in_yellowing_raises_a3(unit_id):
    sim = Sim(unit_id, "Amarelação")
    sim.set_unit(humidity_output_mode="on", humidity_output_mode_at=sim.now)
    run(sim, 2, 30.0, 29.0)
    assert MANUAL_FLAP_TYPE not in sim.active()
    sim.skip(12 * 60)
    run(sim, 2, 32.0, 31.0)
    alert = sim.active()[MANUAL_FLAP_TYPE]
    assert alert.message == (
        "Flap continua aberto à mão. Se as folhas já enxugaram, volte para o Automático: "
        "ar demais na amarelação pode deixar o fumo verde."
    )
    sim.set_unit(humidity_output_mode="auto")
    run(sim, 1, 32.0, 31.0)
    assert MANUAL_FLAP_TYPE not in sim.active()


# 19. Textos: sem dígito, sem unidade, sem "bulbo úmido", e com os nomes configurados.
def test_texts_have_no_numbers_units_or_wet_bulb_and_use_the_names():
    assert len(messages.ALL) >= 25
    for template in messages.ALL:
        rendered = messages.text(template, flap="Abafador", fan="Ventarola", phase="Murchamento")
        assert not re.search(r"\d", rendered), rendered
        assert "°" not in rendered and "bulbo úmido" not in rendered.lower(), rendered
        assert "{" not in rendered, rendered
        if "{flap}" in template:
            assert "Abafador" in rendered
        if "{fan}" in template:
            assert "Ventarola" in rendered
        # O nome configurado é o único jeito de citar as saídas.
        assert "flap" not in rendered.lower().replace("abafador", ""), rendered
        assert "soprador" not in rendered.lower(), rendered
