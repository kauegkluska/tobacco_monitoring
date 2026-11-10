"""Estado dos relés do sender, usado pelas saídas e pelos textos dos alertas."""

from datetime import datetime, timedelta

from core.config import settings
from models.curing_unit import CuringUnit

# "humidity" é o relé 1 (o flap) e "temperature" o relé 2 (o soprador da fornalha).
DEFAULT_NAMES = {"humidity": "Flap", "temperature": "Soprador"}
# Tempo mínimo em cada estado no automático, em minutos: (ligado, desligado) (DE; C38).
MIN_MINUTES = {"humidity": (3, 5), "temperature": (2, 2)}


def field(unit: CuringUnit, output: str, name: str):
    return getattr(unit, f"{output}_output_{name}")


def name_of(unit: CuringUnit, output: str) -> str:
    return field(unit, output, "name") or DEFAULT_NAMES[output]


def mode_of(unit: CuringUnit, output: str) -> str:
    return field(unit, output, "mode") or "auto"


def held(unit: CuringUnit, output: str, current: bool, now: datetime) -> bool:
    """Verdadeiro enquanto o relé ainda não cumpriu o tempo mínimo no estado atual."""
    changed = field(unit, output, "changed_at")
    if changed is None:
        return False
    on_minutes, off_minutes = MIN_MINUTES[output]
    return now - changed < timedelta(minutes=on_minutes if current else off_minutes)


def relay_state(unit: CuringUnit, output: str, now: datetime) -> bool:
    """Estado do relé: o último confirmado pelo sender, se recente; senão, o comandado."""
    at = unit.outputs_confirmed_at
    confirmed = field(unit, output, "confirmed")
    if confirmed is not None and at is not None and timedelta(0) <= now - at <= timedelta(seconds=settings.DEVICE_OFFLINE_SECONDS):
        return bool(confirmed)
    return bool(field(unit, output, "on"))
