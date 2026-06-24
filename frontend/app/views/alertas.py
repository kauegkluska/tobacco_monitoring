import flet as ft

from app.components.common import alerta_row
from app.data.mock_data import MOCK_ALERTAS
from app.theme import ACCENT_GREEN, ACCENT_RED, BG_CARD, BG_DARK, BORDER_COLOR, TEXT_MUTED, TEXT_PRIMARY, padxy


def screen_alertas(page, state, navigate):
    ativos = [alerta for alerta in MOCK_ALERTAS if alerta["ativo"]]
    resolvidos = [alerta for alerta in MOCK_ALERTAS if not alerta["ativo"]]

    def sumcard(label, value, color):
        return ft.Container(
            ft.Column(
                [
                    ft.Text(str(value), size=28, color=color, weight=ft.FontWeight.BOLD),
                    ft.Text(label, size=11, color=TEXT_MUTED),
                ],
                horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                spacing=2,
            ),
            bgcolor=BG_CARD,
            border_radius=12,
            padding=16,
            expand=True,
            border=ft.border.all(1, BORDER_COLOR),
        )

    return ft.View(
        route="/alertas",
        bgcolor=BG_DARK,
        scroll=ft.ScrollMode.AUTO,
        appbar=ft.AppBar(
            leading=ft.IconButton(ft.icons.ARROW_BACK, icon_color=TEXT_MUTED, on_click=lambda e: navigate("/dashboard")),
            title=ft.Text("Alertas", color=TEXT_PRIMARY, weight=ft.FontWeight.BOLD, size=16),
            bgcolor=BG_CARD,
        ),
        controls=[
            ft.Container(
                ft.Column(
                    [
                        ft.Row(
                            [
                                sumcard("Ativos", len(ativos), ACCENT_RED),
                                sumcard("Resolvidos", len(resolvidos), ACCENT_GREEN),
                            ],
                            spacing=10,
                        ),
                        ft.Container(height=20),
                        ft.Text("Ativos", size=13, color=ACCENT_RED, weight=ft.FontWeight.BOLD),
                        ft.Container(height=8),
                        *[alerta_row(alerta) for alerta in ativos],
                        ft.Container(height=16),
                        ft.Text("Resolvidos", size=13, color=TEXT_MUTED, weight=ft.FontWeight.BOLD),
                        ft.Container(height=8),
                        *[alerta_row(alerta) for alerta in resolvidos],
                        ft.Container(height=20),
                    ],
                    spacing=0,
                ),
                padding=padxy(horizontal=16, vertical=12),
            )
        ],
    )

