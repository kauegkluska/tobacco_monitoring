"""Critério 20: cura completa simulada (~150 h) com o flap e o soprador em malha fechada.

Um modelo térmico simples fecha a malha: o soprador ligado aquece a estufa, que perde calor para o ambiente; o flap
aberto puxa o bulbo úmido para baixo e fechado deixa a umidade das folhas subir. As leituras (uma a cada 10 s) passam
pelo mesmo caminho de produção: filtro de saltos, mediana de 30 s, motor de alertas e saídas.
"""

import math
import random
from collections import Counter
from datetime import datetime, timedelta

from conftest import Sim
from core.database import SessionLocal
from models.curing_unit import CuringUnit
from models.output_event import OutputEvent
from models.reading import Reading
from services import output_service
from services.alert_engine import evaluate_reading
from services.phases import flap_setting, phase_named, wilting_setpoint
from services.psychrometrics import _ratio_at_wet_bulb, _saturation_pressure
from services.stage_service import change_stage

STEP_S = 10
PRESSURE_PA = 90.8 * 1000
AMBIENT_C = 25.0
HEAT_C_PER_H = 14.0  # aquecimento com o soprador ligado
LOSS_PER_H = 0.2  # perda proporcional à diferença para o ambiente
WET_TAU_MIN = 15.0  # tempo de resposta da umidade
FLAP_DRYING_C = 4.0  # quanto o flap aberto puxa o bulbo úmido para baixo
MAX_FLAP_OPENINGS_PER_HOUR = 6

# Fase, horas na fase e temperatura alvo gravada pelo produtor no início dela.
SCHEDULE = (
    ("Amarelação", 50, 38.0),
    ("Murchamento", 20, 46.5),
    ("Secagem da folha", 40, 56.0),
    ("Secagem do talo", 40, 72.5),
)


def humidity(temperature: float, wet_bulb: float) -> float:
    """Inverte a equação psicrométrica: umidade relativa que dá esse bulbo úmido."""
    ratio = _ratio_at_wet_bulb(temperature, wet_bulb, PRESSURE_PA)
    vapor = ratio * PRESSURE_PA / (0.621945 + ratio)
    return min(100.0, max(1.0, 100 * vapor / _saturation_pressure(temperature)))


def moisture_source(stage: str, hours: float, temperature: float) -> float:
    """Bulbo úmido para onde a estufa tende com o flap fechado (a água que sai das folhas), com excursões."""
    wave = 1.5 * math.sin(2 * math.pi * hours / 5)
    if stage == "Murchamento":
        if 8 <= hours < 9:
            return wilting_setpoint(temperature) - 3.5  # ar seco: "Umidade baixa"
        return wilting_setpoint(temperature) + 1.0 + wave
    if stage == "Secagem da folha":
        if 20 <= hours < 20.4:
            return 45.5  # excursão acima do limite: "Umidade alta" mesmo com o flap aberto
        return 40.5 + wave
    if hours < 18:
        return 44.5 + wave
    if 25 <= hours < 25.4:
        return 47.0  # talo B: só abre com umidade muito alta e persistente
    return max(38.0, 42.0 - 0.2 * (hours - 18)) + 0.5 * wave


def test_complete_cure_with_outputs_keeps_the_flap_below_six_openings_per_hour(client, auth, monkeypatch):
    rng = random.Random(7)
    unit_id = client.post("/curing_units/", json={"name": "Estufa completa"}, headers=auth).json()["id"]
    start = datetime(2026, 1, 10, 8, 0, 0)
    sim = Sim(unit_id, SCHEDULE[0][0], start=start)
    monkeypatch.setattr(output_service, "utcnow", lambda: sim.now)

    temperature, wet_bulb = AMBIENT_C, AMBIENT_C - 1.0
    frozen = None
    phase_starts = []
    with SessionLocal() as db:
        unit = db.get(CuringUnit, unit_id)
        for stage, hours, target in SCHEDULE:
            if stage != unit.curing_stage:
                change_stage(unit, stage, sim.now)
            phase_starts.append((stage, sim.now))
            output_service.set_target(db, unit, target, sim.now)
            for index in range(int(hours * 3600 / STEP_S)):
                sim.now += timedelta(seconds=STEP_S)
                in_phase = index * STEP_S / 3600
                dt = STEP_S / 3600

                # Queda de fogo de 45 min na Secagem da folha: o soprador não aquece.
                fire_out = stage == "Secagem da folha" and 25 <= in_phase < 25.75
                heating = HEAT_C_PER_H if unit.temperature_output_on and not fire_out else 0.0
                temperature += (heating - LOSS_PER_H * (temperature - AMBIENT_C)) * dt

                if stage == "Amarelação":
                    # O flap não abre; um período muito úmido (depressão de 0,3 °C) no meio da fase.
                    wet_bulb = temperature - (0.3 if 20 <= in_phase < 21 else 1.0)
                else:
                    source = moisture_source(stage, in_phase, temperature)
                    goal = source - FLAP_DRYING_C if unit.humidity_output_on else source
                    wet_bulb += (goal - wet_bulb) * (STEP_S / 60) / WET_TAU_MIN
                    wet_bulb = min(wet_bulb, temperature - 0.5)

                measured = (temperature + rng.uniform(-0.05, 0.05), humidity(temperature, wet_bulb) + rng.uniform(-0.3, 0.3))
                # Sensor congelado por 20 min no início do talo: repete o último valor.
                if stage == "Secagem do talo" and 10 <= in_phase < 10 + 20 / 60:
                    frozen = frozen or measured
                    measured = frozen
                reading = Reading(
                    temperature=measured[0], humidity=min(100.0, measured[1]), timestamp=sim.now, curing_unit_id=unit_id,
                )
                db.add(reading)
                db.flush()
                evaluate_reading(db, unit, None, reading)
                output_service.update_outputs(db, unit, reading)
                if index % 360 == 0:
                    db.commit()
        db.commit()
        events = db.query(OutputEvent).filter(OutputEvent.curing_unit_id == unit_id).order_by(OutputEvent.id).all()
        db.expunge_all()

    end = sim.now
    auto = [event for event in events if event.cause == "auto"]
    flap_events = [event for event in auto if event.output == "humidity"]
    openings = [event.timestamp for event in flap_events if event.turned_on]
    fan_ons = [event.timestamp for event in auto if event.output == "temperature" and event.turned_on]

    def stage_at(moment: datetime) -> str:
        return [stage for stage, began in phase_starts if began <= moment][-1]

    print("\nCura completa simulada: acionamentos por fase")
    print(f"{'Fase':<18}{'h':>5}{'trocas flap':>13}{'aberturas':>11}{'aberturas/h':>13}{'soprador liga':>15}{'liga/h':>8}")
    for stage, hours, _ in SCHEDULE:
        toggles = sum(1 for event in flap_events if stage_at(event.timestamp) == stage)
        opened = sum(1 for moment in openings if stage_at(moment) == stage)
        fan = sum(1 for moment in fan_ons if stage_at(moment) == stage)
        print(f"{stage:<18}{hours:>5}{toggles:>13}{opened:>11}{opened / hours:>13.2f}{fan:>15}{fan / hours:>8.2f}")
    print(f"{'Total':<18}{sum(h for _, h, _ in SCHEDULE):>5}{len(flap_events):>13}{len(openings):>11}"
          f"{len(openings) / 150:>13.2f}{len(fan_ons):>15}{len(fan_ons) / 150:>8.2f}")

    per_hour_flap = Counter(int((moment - start).total_seconds() // 3600) for moment in openings)
    per_hour_toggles = Counter(int((event.timestamp - start).total_seconds() // 3600) for event in flap_events)
    per_hour_fan = Counter(int((moment - start).total_seconds() // 3600) for moment in fan_ons)
    total_hours = int((end - start).total_seconds() // 3600)
    print("\nPor hora (aberturas do flap / trocas do flap / ligações do soprador):")
    for first in range(0, total_hours, 10):
        cells = [f"{hour:>3}h {per_hour_flap[hour]}/{per_hour_toggles[hour]}/{per_hour_fan[hour]:<2}" for hour in range(first, min(first + 10, total_hours))]
        print("  ".join(cells))

    # Janela móvel de 1 h: o pior caso de aberturas do flap.
    worst, worst_at = 0, None
    for index, moment in enumerate(openings):
        count = sum(1 for other in openings[index:] if other - moment < timedelta(hours=1))
        if count > worst:
            worst, worst_at = count, moment
    print(f"\nMáximo de aberturas do flap em qualquer janela de 1 h: {worst} (a partir de {worst_at})")
    print(f"Máximo de ligações do soprador numa hora: {max(per_hour_fan.values(), default=0)}")

    # O cenário passou pelos episódios previstos.
    rules = Counter(event.rule for event in auto)
    print(f"Regras que acionaram: {dict(rules)}")
    assert not any(stage_at(moment) == "Amarelação" for moment in openings), "o flap não abre na Amarelação"
    assert rules["humidity_fallback"] + rules["temperature_fallback"] >= 1, "o sensor congelado deveria levar à reserva"
    assert openings and fan_ons
    assert flap_setting(phase_named("Secagem do talo"), 70, 30).setpoint is None
    assert worst <= MAX_FLAP_OPENINGS_PER_HOUR
