from datetime import datetime

import flet as ft

from app.components.common import tag_badge
from app.data.mock_data import MOCK_ALERTAS, MOCK_ESTUFAS
from app.theme import ACCENT_BLUE, ACCENT_GREEN, ACCENT_ORANGE, ACCENT_RED, BG_CARD, BG_DARK, BORDER_COLOR, TEXT_MUTED, TEXT_PRIMARY, padxy, mar
from app.utils.formatters import pct, restantes_fmt, status_color


def screen_dashboard(page, state, navigate):
    alertas_ativos = [alerta for alerta in MOCK_ALERTAS if alerta["ativo"]]
    n_alertas = len(alertas_ativos)

    def abrir(estufa):
        state["estufa"] = estufa
        navigate("/estufa")

    def stat_box(label, value, color, icon):
        return ft.Container(
            ft.Column(
                [
                    ft.Icon(icon, color=color, size=20),
                    ft.Text(str(value), size=22, color=TEXT_PRIMARY, weight=ft.FontWeight.BOLD),
                    ft.Text(label, size=10, color=TEXT_MUTED),
                ],
                horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                spacing=4,
            ),
            bgcolor=BG_CARD,
            border_radius=12,
            padding=16,
            border=ft.border.all(1, BORDER_COLOR),
            expand=True,
        )

    def estufa_card(estufa):
        cor_status = status_color(estufa["status"])
        progresso = pct(estufa)
        status_label = {"normal": "Normal", "alerta": "Alerta", "critico": "Critico"}[estufa["status"]]

        return ft.Container(
            ft.Column(
                [
                    ft.Row(
                        [
                            ft.Column(
                                [
                                    ft.Text(estufa["nome"], color=TEXT_PRIMARY, weight=ft.FontWeight.BOLD, size=14),
                                    ft.Text(f"Dispositivo: {estufa['device_id']}", color=TEXT_MUTED, size=11),
                                ],
                                spacing=2,
                                expand=True,
                            ),
                            tag_badge(status_label, cor_status),
                        ],
                        alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                    ),
                    ft.Container(height=12),
                    ft.Row(
                        [
                            ft.Row(
                                [
                                    ft.Icon(ft.icons.THERMOSTAT, color=ACCENT_RED, size=15),
                                    ft.Text(f"{estufa['temp']:.1f} C", color=TEXT_PRIMARY, size=15, weight=ft.FontWeight.BOLD),
                                ],
                                spacing=4,
                            ),
                            ft.Row(
                                [
                                    ft.Icon(ft.icons.WATER_DROP, color=ACCENT_BLUE, size=15),
                                    ft.Text(f"{estufa['umidade']:.1f} %", color=TEXT_PRIMARY, size=15, weight=ft.FontWeight.BOLD),
                                ],
                                spacing=4,
                            ),
                            ft.Row(
                                [
                                    ft.Icon(ft.icons.ACCESS_TIME, color=ACCENT_GREEN, size=13),
                                    ft.Text(restantes_fmt(estufa), color=TEXT_MUTED, size=11),
                                ],
                                spacing=4,
                            ),
                        ],
                        spacing=16,
                    ),
                    ft.Container(height=10),
                    ft.Row(
                        [
                            ft.Text(estufa["estagio"], color=TEXT_MUTED, size=11, expand=True),
                            ft.Text(f"{progresso * 100:.0f}%", color=cor_status, size=11, weight=ft.FontWeight.BOLD),
                        ],
                        alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                    ),
                    ft.Container(height=4),
                    ft.ProgressBar(
                        value=progresso,
                        color=cor_status,
                        bgcolor=BORDER_COLOR,
                        bar_height=6,
                        border_radius=3,
                        expand=True,
                    ),
                ],
                spacing=0,
            ),
            bgcolor=BG_CARD,
            border_radius=14,
            padding=16,
            border=ft.border.all(1, f"{cor_status}44"),
            on_click=lambda ev, item=estufa: abrir(item),
            ink=True,
            margin=mar(bottom=12),
        )

    critica = next((estufa for estufa in MOCK_ESTUFAS if estufa["status"] == "critico"), None)
    banner = []
    if critica:
        banner = [
            ft.Container(
                ft.Row(
                    [
                        ft.Icon(ft.icons.WARNING_AMBER, color=ACCENT_RED, size=18),
                        ft.Text(
                            f"{critica['nome']} - temperatura critica ({critica['temp']:.1f} C)",
                            color=ACCENT_RED,
                            size=12,
                            weight=ft.FontWeight.BOLD,
                            expand=True,
                        ),
                        ft.TextButton(
                            "Ver",
                            style=ft.ButtonStyle(color=ACCENT_RED),
                            on_click=lambda ev: (state.update({"estufa": critica}), navigate("/estufa")),
                        ),
                    ],
                    spacing=8,
                    vertical_alignment=ft.CrossAxisAlignment.CENTER,
                ),
                bgcolor=f"{ACCENT_RED}18",
                border_radius=10,
                padding=padxy(horizontal=14, vertical=10),
                border=ft.border.all(1, f"{ACCENT_RED}44"),
            ),
            ft.Container(height=16),
        ]

    nome = state["user"]["name"].split()[0] if state.get("user") else ""

    return ft.View(
        route="/dashboard",
        bgcolor=BG_DARK,
        scroll=ft.ScrollMode.AUTO,
        appbar=ft.AppBar(
            leading=ft.Container(ft.Icon(ft.icons.GRAIN, color=ACCENT_GREEN, size=22), padding=8),
            title=ft.Text("EstufaMonitor", color=TEXT_PRIMARY, weight=ft.FontWeight.BOLD, size=16),
            bgcolor=BG_CARD,
            actions=[
                ft.Stack(
                    [
                        ft.IconButton(
                            ft.icons.NOTIFICATIONS_OUTLINED,
                            icon_color=ACCENT_ORANGE if n_alertas else TEXT_MUTED,
                            on_click=lambda e: navigate("/alertas"),
                        ),
                        ft.Container(
                            ft.Text(str(n_alertas), color=BG_DARK, size=9, weight=ft.FontWeight.BOLD),
                            bgcolor=ACCENT_ORANGE,
                            border_radius=10,
                            padding=padxy(horizontal=4, vertical=1),
                            right=4,
                            top=6,
                            visible=n_alertas > 0,
                        ),
                    ],
                    width=46,
                    height=46,
                ),
                ft.PopupMenuButton(
                    icon=ft.icons.PERSON_OUTLINE,
                    icon_color=TEXT_MUTED,
                    items=[
                        ft.PopupMenuItem(text=state["user"]["name"] if state.get("user") else "", disabled=True),
                        ft.PopupMenuItem(text="Sair", on_click=lambda e: navigate("/login")),
                    ],
                ),
            ],
        ),
        controls=[
            ft.Container(
                ft.Column(
                    [
                        ft.Container(height=4),
                        ft.Column(
                            [
                                ft.Text(f"Ola, {nome}", size=20, color=TEXT_PRIMARY, weight=ft.FontWeight.BOLD),
                                ft.Text(datetime.now().strftime("%d/%m/%Y - %H:%M"), size=12, color=TEXT_MUTED),
                            ],
                            spacing=2,
                        ),
                        ft.Container(height=16),
                        ft.Row(
                            [
                                stat_box("Estufas", len(MOCK_ESTUFAS), ACCENT_GREEN, ft.icons.WAREHOUSE_OUTLINED),
                                stat_box("Alertas", n_alertas, ACCENT_ORANGE, ft.icons.WARNING_AMBER_OUTLINED),
                                stat_box("Online", len(MOCK_ESTUFAS), ACCENT_BLUE, ft.icons.WIFI),
                            ],
                            spacing=10,
                        ),
                        ft.Container(height=16),
                        *banner,
                        ft.Row(
                            [
                                ft.Text("Minhas Estufas", size=15, color=TEXT_PRIMARY, weight=ft.FontWeight.BOLD),
                                ft.TextButton("+ Escanear QR", style=ft.ButtonStyle(color=ACCENT_GREEN)),
                            ],
                            alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                        ),
                        ft.Container(height=8),
                        *[estufa_card(estufa) for estufa in MOCK_ESTUFAS],
                        ft.Container(height=20),
                    ],
                    spacing=0,
                ),
                padding=padxy(horizontal=16, vertical=12),
            )
        ],
    )

