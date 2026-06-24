from collections.abc import Iterable
from datetime import datetime
from typing import Any

import flet as ft


def icon(name: str):
    icons = getattr(ft, "Icons", None) or getattr(ft, "icons", None)
    return getattr(icons, name, None) if icons else None


def color(name: str):
    colors = getattr(ft, "Colors", None) or getattr(ft, "colors", None)
    return getattr(colors, name)


def center_alignment() -> ft.Alignment:
    return ft.Alignment(0, 0)


def symmetric_padding(horizontal: int | float = 0, vertical: int | float = 0) -> ft.Padding:
    return ft.Padding(
        left=horizontal,
        top=vertical,
        right=horizontal,
        bottom=vertical,
    )


def value_at(data: Any, *keys: str, default: Any = "-") -> Any:
    if not isinstance(data, dict):
        return default
    for key in keys:
        if key in data and data[key] not in (None, ""):
            return data[key]
    return default


def as_list(payload: Any) -> list[Any]:
    if payload is None:
        return []
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ("items", "data", "results", "readings", "alerts", "curing_units"):
            value = payload.get(key)
            if isinstance(value, list):
                return value
        return [payload]
    if isinstance(payload, Iterable) and not isinstance(payload, (str, bytes)):
        return list(payload)
    return []


def format_number(value: Any, suffix: str = "") -> str:
    if value in (None, ""):
        return "-"
    try:
        number = float(value)
    except (TypeError, ValueError):
        return str(value)
    rendered = f"{number:.1f}".rstrip("0").rstrip(".")
    return f"{rendered}{suffix}"


def format_timestamp(value: Any) -> str:
    if not value:
        return "-"
    if not isinstance(value, str):
        return str(value)
    try:
        normalized = value.replace("Z", "+00:00")
        parsed = datetime.fromisoformat(normalized)
        return parsed.strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return value


def page_shell(title: str, controls: list[ft.Control], actions: list[ft.Control] | None = None) -> ft.Container:
    return ft.Container(
        expand=True,
        padding=symmetric_padding(horizontal=18, vertical=14),
        content=ft.Column(
            expand=True,
            spacing=16,
            controls=[
                ft.Row(
                    alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                    vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    controls=[
                        ft.Text(title, size=24, weight=ft.FontWeight.W_700),
                        ft.Row(spacing=8, controls=actions or []),
                    ],
                ),
                *controls,
            ],
        ),
    )


def error_banner(message: str) -> ft.Container:
    return ft.Container(
        padding=12,
        border_radius=8,
        bgcolor=color("RED_50"),
        content=ft.Text(message, color=color("RED_900")),
    )


def empty_state(message: str) -> ft.Container:
    return ft.Container(
        expand=True,
        alignment=center_alignment(),
        content=ft.Text(message, color=color("GREY_700"), text_align=ft.TextAlign.CENTER),
    )
