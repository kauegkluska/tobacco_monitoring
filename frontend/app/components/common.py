import flet as ft

from app.theme import (
    ACCENT_BLUE,
    ACCENT_GREEN,
    ACCENT_RED,
    BG_CARD,
    BG_CARD2,
    BORDER_COLOR,
    TEXT_MUTED,
    TEXT_PRIMARY,
    mar,
    padxy,
)
from app.utils.formatters import gravidade_color


def tag_badge(text, color):
    return ft.Container(
        ft.Text(text, size=10, color=color, weight=ft.FontWeight.BOLD),
        bgcolor=f"{color}22",
        border_radius=4,
        padding=padxy(horizontal=8, vertical=3),
        border=ft.border.all(1, f"{color}55"),
    )


def hdivider():
    return ft.Divider(height=1, color=BORDER_COLOR)


def sensor_big(label, value, unit, max_val, color, icon):
    frac = min(1.0, value / max_val)
    return ft.Container(
        ft.Column(
            [
                ft.Row(
                    [ft.Icon(icon, color=color, size=15), ft.Text(label, color=TEXT_MUTED, size=11)],
                    spacing=5,
                ),
                ft.Container(height=10),
                ft.Row(
                    [
                        ft.Text(f"{value:.1f}", size=36, color=color, weight=ft.FontWeight.BOLD),
                        ft.Text(unit, size=16, color=TEXT_MUTED, weight=ft.FontWeight.BOLD),
                    ],
                    spacing=4,
                    vertical_alignment=ft.CrossAxisAlignment.END,
                ),
                ft.Container(height=10),
                ft.ProgressBar(
                    value=frac,
                    color=color,
                    bgcolor=BORDER_COLOR,
                    bar_height=6,
                    border_radius=3,
                    expand=True,
                ),
                ft.Container(height=4),
                ft.Row(
                    [
                        ft.Text("0", size=9, color=TEXT_MUTED),
                        ft.Container(expand=True),
                        ft.Text(f"{max_val}{unit}", size=9, color=TEXT_MUTED),
                    ]
                ),
            ],
            spacing=0,
            expand=True,
        ),
        bgcolor=BG_CARD2,
        border_radius=12,
        padding=16,
        border=ft.border.all(1, BORDER_COLOR),
        expand=True,
    )


def mini_sparkline(vals, color, width=None):
    mn = min(vals)
    mx = max(vals)
    rng = mx - mn or 1
    max_h = 48

    bars = []
    for value in vals:
        height = int(((value - mn) / rng) * (max_h - 6)) + 6
        bars.append(
            ft.Container(
                width=4,
                height=height,
                bgcolor=color,
                border_radius=ft.BorderRadius(top_left=2, top_right=2, bottom_left=0, bottom_right=0),
                opacity=0.75,
                margin=mar(left=1, right=1),
            )
        )

    return ft.Container(
        ft.Row(bars, spacing=0, vertical_alignment=ft.CrossAxisAlignment.END),
        height=max_h + 4,
        bgcolor=BG_CARD2,
        border_radius=8,
        padding=padxy(horizontal=6, vertical=4),
        border=ft.border.all(1, BORDER_COLOR),
        clip_behavior=ft.ClipBehavior.HARD_EDGE,
        width=width,
        expand=width is None,
    )


def alerta_row(alerta):
    gravidade_cor = gravidade_color(alerta["gravidade"])
    tipo_icon = {
        "TEMPERATURA_ALTA": ft.icons.THERMOSTAT,
        "TEMPERATURA_CRITICA": ft.icons.WARNING_AMBER,
        "UMIDADE_BAIXA": ft.icons.WATER_DROP,
        "FALTA_ENERGIA": ft.icons.POWER_OFF,
    }.get(alerta["tipo"], ft.icons.NOTIFICATIONS)

    return ft.Container(
        ft.Row(
            [
                ft.Container(
                    ft.Icon(tipo_icon, color=gravidade_cor, size=20),
                    bgcolor=f"{gravidade_cor}22",
                    border_radius=10,
                    padding=10,
                    width=44,
                    height=44,
                    alignment=ft.Alignment(0, 0),
                ),
                ft.Column(
                    [
                        ft.Row(
                            [
                                ft.Text(
                                    alerta["estufa_nome"],
                                    color=TEXT_PRIMARY,
                                    size=12,
                                    weight=ft.FontWeight.BOLD,
                                    expand=True,
                                ),
                                tag_badge(
                                    "ATIVO" if alerta["ativo"] else "RESOLVIDO",
                                    ACCENT_RED if alerta["ativo"] else ACCENT_GREEN,
                                ),
                            ],
                        ),
                        ft.Text(alerta["mensagem"], color=TEXT_MUTED, size=11),
                        ft.Row(
                            [
                                ft.Text(f"Esperado: {alerta['valor_esperado']}", color=TEXT_MUTED, size=10),
                                ft.Text("-", color=TEXT_MUTED, size=10),
                                ft.Text(
                                    f"Lido: {alerta['valor_encontrado']}",
                                    color=gravidade_cor,
                                    size=10,
                                    weight=ft.FontWeight.BOLD,
                                ),
                                ft.Text("-", color=TEXT_MUTED, size=10),
                                ft.Text(alerta["timestamp"], color=TEXT_MUTED, size=10),
                            ],
                            spacing=4,
                        ),
                    ],
                    spacing=2,
                    expand=True,
                ),
            ],
            spacing=12,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        bgcolor=BG_CARD,
        border_radius=12,
        padding=14,
        border=ft.border.all(1, BORDER_COLOR),
        margin=mar(bottom=10),
    )

