"""Critérios de aceitação do controle do flap (relé 1) e do soprador (relé 2), com tempo simulado.

As leituras passam pelo mesmo caminho de produção: filtro de saltos, mediana de 30 s e depois as saídas.
Uma leitura a cada 10 s, sem degraus maiores que 2 °C ou 10 pontos de umidade entre amostras.
"""

from datetime import timedelta

import pytest
from conftest import Sim, humidity_for, make_unit
from core.database import SessionLocal
from models.reading import Reading
from services.phases import PHASES, flap_setting, phase_named

STEP = 10
LEAF = "Secagem da folha"
STEM = "Secagem do talo"


@pytest.fixture()
def unit_id(client, auth) -> int:
    return make_unit(client, auth)


def wet(temperature, wet_bulb):
    """Umidade que dá o bulbo úmido pedido; os dois podem ser funções dos minutos decorridos."""
    if callable(wet_bulb) or callable(temperature):
        at = lambda source, minute: source(minute) if callable(source) else source  # noqa: E731
        return lambda minute: humidity_for(at(temperature, minute), at(wet_bulb, minute))
    return humidity_for(temperature, wet_bulb)


def towards(start: float, end: float, minutes: float):
    """Variação gradual de `start` até `end` em `minutes`, depois constante."""
    return lambda minute: start + (end - start) * min(1.0, minute / minutes)


def run(sim: Sim, minutes: float, temperature, wet_bulb, **extra) -> None:
    sim.run(minutes, temperature, wet(temperature, wet_bulb), step=STEP, outputs=True, **extra)


def flap(sim: Sim) -> bool:
    return sim.outputs()[0]


def toggles(sim: Sim, output: str = "humidity") -> list:
    return [event for event in sim.events(output) if event.cause == "auto"]


def assert_min_times(events: list, on_minutes: float, off_minutes: float) -> None:
    for before, after in zip(events, events[1:], strict=False):
        held = after.timestamp - before.timestamp
        assert held >= timedelta(minutes=on_minutes if before.turned_on else off_minutes), (before.timestamp, after.timestamp)


# 1. Umidade baixa: o flap nunca abre por umidade baixa.
def test_low_humidity_keeps_the_flap_closed(unit_id):
    sim = Sim(unit_id, LEAF)
    run(sim, 30, 55.0, 35.0)
    assert not flap(sim)
    assert toggles(sim) == []


# 2. Abertura e fechamento com a banda da Secagem da folha (abre acima de 40,0; fecha abaixo de 39,0).
def test_flap_opens_above_the_limit_and_closes_below_the_band(unit_id):
    sim = Sim(unit_id, LEAF)
    run(sim, 5, 55.0, 39.5)
    assert not flap(sim)
    run(sim, 3, 55.0, towards(39.5, 40.2, 2))
    assert flap(sim)
    run(sim, 5, 55.0, towards(40.2, 39.2, 2))
    assert flap(sim)
    run(sim, 3, 55.0, towards(39.2, 38.9, 1))
    assert not flap(sim)
    opened, closed = toggles(sim)
    assert closed.timestamp - opened.timestamp >= timedelta(minutes=3)
    assert closed.metric == "wet_bulb" and closed.rule == "humidity"


# 3. Oscilação no limite: no máximo uma troca a cada 3 min aberto / 5 min fechado.
@pytest.mark.parametrize("low, high", [(39.9, 40.1), (38.8, 40.2)])
def test_oscillation_respects_the_minimum_times(unit_id, low, high):
    sim = Sim(unit_id, LEAF)
    run(sim, 2, 55.0, low)
    humidity = {low: humidity_for(55.0, low), high: humidity_for(55.0, high)}
    # A cada amostra o bulbo úmido alterna; a mediana de 30 s alterna junto.
    sim.run(60, 55.0, lambda minute: humidity[high if round(minute * 60 / STEP) % 2 else low], step=STEP, noise=False, outputs=True)
    events = toggles(sim)
    print(f"\nTw alternando {low}/{high} °C por 60 min: {len(events)} trocas do flap")
    assert_min_times(events, 3, 5)
    if (low, high) == (39.9, 40.1):
        # 39,9 não fica abaixo de 39,0: depois de abrir, o flap não fecha mais.
        assert len(events) == 1
    else:
        assert len(events) >= 2


# 4. Leitura espúria: um pacote isolado com 15 pontos de umidade a mais não muda nenhuma saída.
def test_isolated_spurious_humidity_changes_no_output(unit_id):
    sim = Sim(unit_id, LEAF)
    sim.set_unit(target_temperature=55.0)
    base = humidity_for(55.0, 39.5)
    run(sim, 5, 55.0, 39.5)
    before = sim.events()
    sim.run(2, 55.0, lambda minute: base + (15 if abs(minute - 1.0) < 1e-9 else 0), step=STEP, outputs=True)
    sim.run(2, 55.0, base, step=STEP, outputs=True)
    assert [event.id for event in sim.events()] == [event.id for event in before]
    with SessionLocal() as db:
        spikes = db.query(Reading).filter(Reading.curing_unit_id == unit_id, Reading.humidity > base + 10).all()
        assert len(spikes) == 1 and spikes[0].is_outlier


# Amarelação: o flap não abre no automático, nem com o ar quase saturado.
def test_flap_stays_closed_in_yellowing(unit_id):
    sim = Sim(unit_id, "Amarelação")
    sim.run(60, 38.0, lambda minute: humidity_for(38.0, 37.8), step=STEP, outputs=True)
    assert not flap(sim)
    assert toggles(sim) == []


# 6. Murchamento: o alvo acompanha o bulbo seco (38,0 até 43 °C, 40,0 a partir de 48 °C).
def test_wilting_setpoint_follows_the_dry_bulb(unit_id):
    wilting = phase_named("Murchamento")
    setting = flap_setting(wilting, 45.5, 0)
    assert (setting.setpoint, setting.open_above, setting.close_below) == pytest.approx((39.0, 39.5, 38.5))
    assert flap_setting(wilting, 40.0, 0).setpoint == 38.0
    assert flap_setting(wilting, 50.0, 0).setpoint == 40.0

    sim = Sim(unit_id, "Murchamento")
    run(sim, 10, 45.5, 39.4)
    assert not flap(sim)
    run(sim, 3, 45.5, towards(39.4, 39.6, 1))
    assert flap(sim)
    run(sim, 5, 45.5, towards(39.6, 38.6, 2))
    assert flap(sim)
    run(sim, 3, 45.5, towards(38.6, 38.4, 1))
    assert not flap(sim)


# 7. Troca de fase com o flap aberto: vale o alvo da nova fase, respeitando o mínimo aberto.
def test_phase_change_applies_the_new_setpoint_after_the_minimum_open_time(unit_id):
    sim = Sim(unit_id, LEAF)
    run(sim, 5, 56.0, 39.5)
    run(sim, 1, 56.0, towards(39.5, 41.5, 1))
    assert flap(sim)
    opened = toggles(sim)[-1].timestamp

    sim.change_stage(STEM)
    closed_at = []

    def watch(current: Sim) -> None:
        if not closed_at and not flap(current):
            closed_at.append(current.now)

    run(sim, 6, 56.0, 41.5, on_reading=watch)
    assert closed_at, "o flap deveria fechar: 41,5 °C está abaixo de 42,0 °C no talo"
    assert closed_at[0] - opened >= timedelta(minutes=3)
    assert closed_at[0] - opened < timedelta(minutes=3, seconds=30)


def test_stem_band_keeps_the_flap_open_above_42(unit_id):
    sim = Sim(unit_id, LEAF)
    run(sim, 5, 56.0, 39.5)
    run(sim, 2, 56.0, towards(39.5, 41.5, 1))
    assert flap(sim)
    sim.change_stage(STEM)
    run(sim, 2, 56.0, towards(41.5, 42.5, 1))
    run(sim, 10, 56.0, 42.5)
    assert flap(sim)
    run(sim, 2, 56.0, towards(42.5, 41.8, 1))
    assert not flap(sim)


# 8. Talo: nas primeiras 18 h abre acima de 44,0; depois, só com mais de 45,0 por 10 min.
def test_stem_b_opens_only_with_persistent_high_humidity(unit_id):
    sim = Sim(unit_id, STEM)
    run(sim, 5, 65.0, 43.0)
    run(sim, 3, 65.0, towards(43.0, 44.5, 1))
    assert flap(sim), "talo A: 44,5 °C passa de 44,0 °C"
    run(sim, 5, 65.0, towards(44.5, 41.5, 2))
    assert not flap(sim)

    sim.skip(18 * 60)
    run(sim, 20, 65.0, 44.0)
    assert not flap(sim)
    run(sim, 20, 65.0, towards(44.0, 44.8, 2))
    assert not flap(sim), "talo B: abaixo de 45,0 °C o flap fica fechado"

    run(sim, 1, 65.0, towards(44.8, 45.5, 1))
    run(sim, 6, 65.0, 45.5)
    assert not flap(sim), "ainda não são 10 min acima de 45,0 °C"
    run(sim, 4, 65.0, 45.5)
    assert flap(sim)
    run(sim, 5, 65.0, towards(45.5, 42.8, 2))
    assert not flap(sim)


def test_every_phase_has_a_flap_rule_except_yellowing():
    assert flap_setting(PHASES[0], 38.0, 0) is None
    assert all(flap_setting(phase, 50.0, 0) is not None for phase in PHASES[1:])


# --- Soprador (relé 2) ---

def set_target(sim: Sim, value: float) -> None:
    from models.curing_unit import CuringUnit
    from services import output_service

    with SessionLocal() as db:
        output_service.set_target(db, db.get(CuringUnit, sim.unit_id), value, sim.now)
        db.commit()


@pytest.fixture()
def sim_clock(monkeypatch):
    """Faz o serviço das saídas usar a hora da simulação (para a última leitura recente)."""
    from services import output_service

    holder = {}
    monkeypatch.setattr(output_service, "utcnow", lambda: holder["sim"].now)
    return holder


def effective(sim: Sim) -> float:
    return sim.unit().target_effective


def fan(sim: Sim) -> bool:
    return sim.outputs()[1]


# 14. Rampa do alvo efetivo.
def test_ramp_rises_at_the_phase_rate_and_pauses_when_the_fire_lags(unit_id, sim_clock):
    sim = sim_clock["sim"] = Sim(unit_id, LEAF)
    run(sim, 5, 50.0, 38.0)
    set_target(sim, 55.0)
    assert effective(sim) == pytest.approx(50.0, abs=0.05)
    run(sim, 60, 50.0, 38.0)
    assert effective(sim) == pytest.approx(51.1, abs=0.05)
    # O bulbo seco parado em 50 °C: a rampa para quando ele fica duas faixas abaixo do alvo efetivo.
    run(sim, 90, 50.0, 38.0)
    assert effective(sim) == pytest.approx(50.0 + 2 * 2 / 1.8, abs=0.05)
    assert fan(sim)
    # Baixar o alvo vale na hora.
    set_target(sim, 51.0)
    assert effective(sim) == pytest.approx(51.0)
    # Subir de novo não faz a rampa recuar até o bulbo seco: parte do alvo efetivo atual.
    set_target(sim, 55.0)
    assert effective(sim) == pytest.approx(51.0)
    # Bulbo seco acima do alvo efetivo: a rampa recomeça nele.
    run(sim, 3, towards(50.0, 52.0, 2), 38.0)
    set_target(sim, 56.0)
    assert effective(sim) == pytest.approx(52.0, abs=0.05)


def test_ramp_in_yellowing_starts_at_the_end_of_the_initial_heating(unit_id, sim_clock):
    sim = sim_clock["sim"] = Sim(unit_id, "Amarelação")
    run(sim, 5, 25.0, 24.0)
    set_target(sim, 38.0)
    assert effective(sim) == pytest.approx(32.2)
    assert sim.unit().target_effective_at == sim.now
    set_target(sim, 38.5)
    assert effective(sim) == pytest.approx(32.2)
    run(sim, 2, 25.0, 24.0)
    assert fan(sim)


def test_ramp_continues_with_the_rate_of_the_new_phase(unit_id, sim_clock):
    sim = sim_clock["sim"] = Sim(unit_id, "Murchamento")
    run(sim, 5, 44.0, 38.0)
    set_target(sim, 46.5)
    run(sim, 60, 44.0, 38.0)
    assert effective(sim) == pytest.approx(44.8, abs=0.05)
    sim.change_stage(LEAF)
    run(sim, 60, 44.0, 38.0)
    assert effective(sim) == pytest.approx(45.9, abs=0.05)


# 15. Cortes do soprador e tempo mínimo.
def test_rate_cut_turns_the_fan_off_until_the_rate_returns_to_the_limit(unit_id):
    sim = Sim(unit_id, LEAF)
    sim.set_unit(target_temperature=56.0, target_effective=56.0)
    run(sim, 10, 48.0, 38.0)
    assert fan(sim)
    run(sim, 80, lambda minute: 48.0 + 3.0 * minute / 60, 38.0)
    assert not fan(sim) and sim.unit().fan_rate_cut
    assert sim.events("temperature")[-1].rule == "rate"
    run(sim, 70, 52.0, 38.0)
    assert fan(sim) and not sim.unit().fan_rate_cut
    assert_min_times(toggles(sim, "temperature"), 2, 2)


def test_rate_cut_spares_the_initial_heating(unit_id):
    sim = Sim(unit_id, "Amarelação")
    sim.set_unit(target_temperature=38.0, target_effective=38.0)
    cut = []
    sim.run(110, lambda minute: 20 + 6.1 * minute / 60, humidity_for(25.0, 24.0), step=STEP, outputs=True,
            on_reading=lambda current: cut.append(current.unit().fan_rate_cut))
    assert fan(sim) and not any(cut)


def test_rate_cut_spares_the_recovery_after_a_drop(unit_id):
    # Mesmo cenário de test_recovery_after_a_drop_is_not_fast_heating, agora com as saídas.
    sim = Sim(unit_id, LEAF)
    sim.set_unit(target_temperature=56.0, target_effective=56.0)
    sim.skip(13 * 60)
    sim.run(10, 55, 35, outputs=True)
    sim.run(10, 50, 35, outputs=True)
    states = []
    sim.run(53, lambda minute: 50 + 5.6 * minute / 60, 35, outputs=True,
            on_reading=lambda current: states.append((current.unit().fan_rate_cut, fan(current))))
    assert not any(cut for cut, _ in states)
    assert all(on for _, on in states)


def test_ceiling_cut_is_immediate(unit_id):
    sim = Sim(unit_id, LEAF)
    sim.set_unit(target_temperature=56.0, target_effective=56.0)
    run(sim, 5, 55.5, 38.0)
    assert not fan(sim)
    run(sim, 1, towards(55.5, 54.7, 0.5), 38.0)
    assert fan(sim)
    run(sim, 1.5, towards(54.7, 57.5, 1), 38.0)
    on, off = toggles(sim, "temperature")[-2:]
    assert (on.turned_on, off.turned_on, off.rule) == (True, False, "temperature_ceiling")
    assert off.timestamp - on.timestamp < timedelta(minutes=2)
    # Acima do máximo da fase, segue desligado mesmo abaixo da faixa do alvo depois.
    run(sim, 5, 57.5, 38.0)
    assert not fan(sim)
    assert sim.unit().temperature_output_on is False


def test_fan_respects_the_minimum_times(unit_id):
    import math

    sim = Sim(unit_id, LEAF)
    sim.set_unit(target_temperature=55.4, target_effective=55.4)
    run(sim, 2, 55.4, 38.0)
    # A faixa do alvo (2,22 °C) é maior que o salto aceito entre amostras (2 °C): em vez de alternar amostra a amostra,
    # o bulbo seco oscila ±1,5 °C a cada 90 s, saindo da faixa (54,29 a 56,51 °C) dos dois lados.
    oscillation = lambda minute: 55.4 + 1.5 * math.sin(2 * math.pi * minute / 1.5)  # noqa: E731
    sim.run(60, oscillation, humidity_for(55.4, 38.0), step=STEP, outputs=True)
    events = toggles(sim, "temperature")
    print(f"\nTseco oscilando a cada 90 s por 60 min: {len(events)} trocas do soprador")
    assert len(events) >= 2
    assert_min_times(events, 2, 2)


# --- Intertravamentos ---

def reasons(sim: Sim) -> tuple[str, str]:
    """Motivos exibidos (flap, soprador). Requer a fixture sim_clock com esta simulação."""
    from models.curing_unit import CuringUnit
    from services.output_service import describe

    with SessionLocal() as db:
        outputs = describe(db, db.get(CuringUnit, sim.unit_id))
        return outputs["humidity"]["reason"], outputs["temperature"]["reason"]


def open_flap_with_fan_on(sim: Sim, temperature: float = 54.0, wet_bulb: float = 40.5) -> None:
    """Secagem da folha com o soprador ligado (bulbo seco abaixo da faixa do alvo) e o flap aberto por umidade."""
    sim.set_unit(target_temperature=56.0, target_effective=56.0)
    run(sim, 5, temperature, 39.5)
    run(sim, 2, temperature, towards(39.5, wet_bulb, 1))
    assert sim.outputs() == (True, True)


# 9. Queda com o flap aberto e trava de reabertura.
def test_flap_closes_when_the_kiln_cools_and_waits_for_the_recovery(unit_id, sim_clock):
    sim = sim_clock["sim"] = Sim(unit_id, LEAF)
    open_flap_with_fan_on(sim)
    assert sim.unit().flap_open_temperature == pytest.approx(54.0, abs=0.05)
    # 1,6 °C abaixo da abertura, com a umidade acima do alvo mas abaixo do teto menos a folga (40,1 °C).
    run(sim, 2, towards(54.0, 52.4, 1.5), towards(40.5, 40.05, 1))
    assert flap(sim)
    run(sim, 4, 52.4, 40.05)
    assert not flap(sim)
    closed = toggles(sim)[-1]
    assert closed.rule == "drop"
    assert reasons(sim)[0] == "Flap foi fechado porque a estufa estava esfriando."
    # Umidade acima do alvo, mas a estufa ainda não se recuperou: não reabre.
    run(sim, 10, 52.4, towards(40.05, 40.5, 1))
    assert not flap(sim) and sim.unit().flap_drop_locked
    # Acima do teto da fase: reabre na hora, sem esperar o mínimo fechado.
    run(sim, 1, 52.4, towards(40.5, 40.8, 0.5))
    assert flap(sim)
    assert toggles(sim)[-1].rule == "humidity_ceiling"


def test_locked_flap_reopens_after_the_temperature_recovers(unit_id, sim_clock):
    sim = sim_clock["sim"] = Sim(unit_id, LEAF)
    open_flap_with_fan_on(sim)
    run(sim, 2, towards(54.0, 52.4, 1.5), towards(40.5, 40.05, 1))
    run(sim, 4, 52.4, 40.05)
    assert not flap(sim)
    closed_at = toggles(sim)[-1].timestamp
    run(sim, 2, towards(52.4, 53.4, 1), towards(40.05, 40.5, 1))
    assert not flap(sim), "53,4 °C ainda está abaixo da abertura menos 0,5 °C"
    run(sim, 2, towards(53.4, 53.7, 1), 40.5)
    run(sim, 3, 53.7, 40.5)
    assert flap(sim)
    reopened = toggles(sim)[-1]
    assert reopened.rule == "humidity" and reopened.timestamp - closed_at >= timedelta(minutes=5)
    assert not sim.unit().flap_drop_locked


def test_cooling_with_the_fan_off_does_not_close_the_flap(unit_id):
    sim = Sim(unit_id, LEAF)
    run(sim, 5, 54.0, 39.5)
    run(sim, 2, 54.0, towards(39.5, 40.5, 1))
    assert sim.outputs() == (True, False)
    run(sim, 2, towards(54.0, 52.4, 1.5), 40.5)
    run(sim, 6, 52.4, 40.5)
    assert flap(sim)


def test_cooling_above_the_ceiling_keeps_the_flap_open(unit_id):
    sim = Sim(unit_id, LEAF)
    open_flap_with_fan_on(sim, wet_bulb=41.0)
    run(sim, 2, towards(54.0, 52.4, 1.5), 41.0)
    run(sim, 6, 52.4, 41.0)
    assert flap(sim)


# 12. Flap aberto por umidade há mais de 15 min: a rampa do soprador congela e volta quando ele fecha.
def test_long_flap_opening_freezes_the_ramp(unit_id, sim_clock):
    sim = sim_clock["sim"] = Sim(unit_id, LEAF)
    run(sim, 5, 50.0, 39.5)
    set_target(sim, 55.0)
    run(sim, 2, 50.0, towards(39.5, 40.5, 1))
    assert flap(sim)
    run(sim, 14, 50.0, 40.5)
    frozen_at = effective(sim)
    run(sim, 30, 50.0, 40.5)
    assert effective(sim) == pytest.approx(frozen_at, abs=0.02)
    assert reasons(sim)[1] == (
        "A umidade não baixa com Flap aberto. O sistema segurou o aumento de temperatura; não coloque mais lenha agora."
    )
    run(sim, 3, 50.0, towards(40.5, 38.5, 1))
    assert not flap(sim)
    resumed_at = effective(sim)
    run(sim, 30, 50.0, 38.5)
    assert effective(sim) == pytest.approx(resumed_at + 1.1 / 2, abs=0.02)
    assert reasons(sim)[1] == "A temperatura vai subir aos poucos até o alvo."


def test_wet_bulb_around_the_ceiling_does_not_cycle_the_flap(unit_id):
    import math

    sim = Sim(unit_id, LEAF)
    open_flap_with_fan_on(sim, wet_bulb=40.6)
    # A estufa esfria 1,6 °C enquanto o bulbo úmido oscila entre 40,4 e 40,8 °C em torno do teto (40,6 °C).
    oscillating = lambda minute: 40.6 + 0.2 * math.sin(2 * math.pi * minute / 4)  # noqa: E731
    run(sim, 2, towards(54.0, 52.4, 1.5), oscillating)
    run(sim, 60, 52.4, lambda minute: oscillating(minute + 2))
    events = toggles(sim)
    print(f"\nTw oscilando 40,4/40,8 °C com a estufa esfriando, 60 min: {len(events)} trocas do flap")
    assert_min_times(events, 3, 3)
    # Acima do teto menos a folga (40,1 °C), o fechamento por queda fica impedido: o flap não sai do lugar.
    assert flap(sim) and len(events) == 1
    # Abaixo da folga, a exceção acaba e a queda fecha o flap.
    run(sim, 2, 52.4, towards(40.6, 39.8, 1))
    run(sim, 4, 52.4, 39.8)
    assert not flap(sim)
    assert toggles(sim)[-1].rule == "drop"


# --- Sensor suspeito (4.4) ---

M7 = "O sensor está com leitura suspeita: o sistema desligou Soprador. Cuide do fogo à mão até a leitura voltar."


def frozen(sim: Sim, minutes: float, temperature: float, wet_bulb: float, **extra) -> None:
    """Sensor congelado: o mesmo valor em todas as leituras."""
    sim.run(minutes, temperature, humidity_for(temperature, wet_bulb), step=STEP, noise=False, outputs=True, **extra)


def test_fallback_table():
    hours = {"Amarelação": 0, "Murchamento": 0, LEAF: 0}
    from services.phases import flap_fallback_open

    assert [flap_fallback_open(phase_named(stage), hour) for stage, hour in hours.items()] == [False, True, True]
    assert flap_fallback_open(phase_named(STEM), 17.9) is True
    assert flap_fallback_open(phase_named(STEM), 18.0) is False


# 16. Sensor suspeito: as saídas seguram o estado por 5 min, vão à reserva da fase com M7 e voltam ao normal depois.
def test_frozen_sensor_holds_then_applies_the_fallback(unit_id, sim_clock):
    from services.phases import SENSOR_TYPE

    sim = sim_clock["sim"] = Sim(unit_id, LEAF)
    open_flap_with_fan_on(sim)
    states = []
    frozen(sim, 25, 54.0, 40.5, on_reading=lambda current: states.append((current.now, current.unit().sensor_fault_since, current.outputs())))
    since = next(fault for _, fault, _ in states if fault is not None)
    assert SENSOR_TYPE in sim.active()
    during_hold = [outputs for now, fault, outputs in states if fault is not None and now - fault < timedelta(minutes=5)]
    after_hold = [outputs for now, fault, outputs in states if fault is not None and now - fault >= timedelta(minutes=5)]
    assert during_hold and all(outputs == (True, True) for outputs in during_hold)
    # Secagem da folha: flap aberto e soprador desligado, na hora.
    assert after_hold and all(outputs == (True, False) for outputs in after_hold)
    fan_off = toggles(sim, "temperature")[-1]
    assert (fan_off.turned_on, fan_off.rule) == (False, "temperature_fallback")
    assert fan_off.timestamp - since < timedelta(minutes=5, seconds=STEP + 1)
    assert reasons(sim) == (M7, M7)

    # O sensor volta a variar: depois de 10 min normais o alerta encerra e o controle normal volta.
    run(sim, 12, 54.0, 40.5)
    assert SENSOR_TYPE not in sim.active()
    assert sim.unit().sensor_fault_since is None
    assert sim.outputs() == (True, True)
    assert reasons(sim)[0] == "Flap aberto: umidade acima do limite da fase."


def test_fallback_closes_the_flap_in_stem_b_respecting_the_minimum_time(unit_id):
    sim = Sim(unit_id, STEM)
    sim.skip(18 * 60)
    run(sim, 5, 65.0, 44.0)
    run(sim, 2, 65.0, towards(44.0, 45.5, 1))
    run(sim, 12, 65.0, 45.5)
    assert flap(sim)
    frozen(sim, 18, 65.0, 45.5)
    assert not flap(sim)
    closed = toggles(sim)[-1]
    assert closed.rule == "humidity_fallback"


def test_jumping_sensor_applies_the_fallback_even_on_discarded_readings(unit_id):
    from services.phases import SENSOR_TYPE

    sim = Sim(unit_id, LEAF)
    sim.set_unit(target_temperature=56.0, target_effective=56.0)
    base = humidity_for(54.0, 39.5)
    run(sim, 5, 54.0, 39.5)
    assert fan(sim)
    # Um pacote com 15 pontos a mais a cada minuto: saltos isolados e repetidos.
    sim.run(12, 54.0, lambda minute: base + (15 if round(minute * 60 / STEP) % 6 == 0 else 0), step=STEP, outputs=True)
    assert SENSOR_TYPE in sim.active()
    assert not fan(sim)
    assert toggles(sim, "temperature")[-1].rule == "temperature_fallback"
