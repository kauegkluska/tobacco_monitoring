import flet as ft

from app.components.common import alerta_row, hdivider, mini_sparkline, sensor_big, tag_badge
from app.data.mock_data import HISTORICO, MOCK_ALERTAS
from app.theme import ACCENT_BLUE, ACCENT_GREEN, ACCENT_RED, BG_CARD, BG_CARD2, BG_DARK, BORDER_COLOR, TEXT_MUTED, TEXT_PRIMARY, padxy
from app.utils.formatters import pct, restantes_fmt, status_color


def screen_estufa(page, state, navigate):
    estufa = state.get("estufa")
    if not estufa:
        navigate("/dashboard")
        return None

    cor_status = status_color(estufa["status"])
    progresso = pct(estufa)
    rest = restantes_fmt(estufa)
    alertas_estufa = [alerta for alerta in MOCK_ALERTAS if alerta["estufa_id"] == estufa["id"]]
    status_label = {"normal": "Normal", "alerta": "Alerta", "critico": "Critico"}[estufa["status"]]

    def aba_monitor():
        temps = [registro["temp"] for registro in HISTORICO]
        umids = [registro["umid"] for registro in HISTORICO]
        return ft.Column(
            [
                ft.Row(
                    [
                        sensor_big("Temperatura", estufa["temp"], "C", 80, ACCENT_RED, ft.icons.THERMOSTAT),
                        ft.Container(width=10),
                        sensor_big("Umidade", estufa["umidade"], "%", 100, ACCENT_BLUE, ft.icons.WATER_DROP),
                    ],
                ),
                ft.Container(height=16),
                ft.Container(
                    ft.Column(
                        [
                            ft.Row(
                                [
                                    ft.Column(
                                        [
                                            ft.Text("Progresso da Secagem", size=13, color=TEXT_PRIMARY, weight=ft.FontWeight.BOLD),
                                            ft.Text(estufa["estagio"], size=11, color=TEXT_MUTED),
                                        ],
                                        spacing=2,
                                        expand=True,
                                    ),
                                    ft.Column(
                                        [
                                            ft.Text(f"{progresso * 100:.0f}%", size=24, color=cor_status, weight=ft.FontWeight.BOLD),
                                            ft.Text("concluido", size=10, color=TEXT_MUTED),
                                        ],
                                        spacing=0,
                                        horizontal_alignment=ft.CrossAxisAlignment.END,
                                    ),
                                ],
                                alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                            ),
                            ft.Container(height=10),
                            ft.ProgressBar(value=progresso, color=cor_status, bgcolor=BORDER_COLOR, bar_height=10, border_radius=5),
                            ft.Container(height=10),
                            ft.Row(
                                [
                                    ft.Row(
                                        [
                                            ft.Icon(ft.icons.PLAY_CIRCLE_OUTLINE, color=TEXT_MUTED, size=13),
                                            ft.Text(f"Inicio: {estufa['inicio']}", size=11, color=TEXT_MUTED),
                                        ],
                                        spacing=4,
                                    ),
                                    ft.Row(
                                        [
                                            ft.Icon(ft.icons.TIMER_OUTLINED, color=ACCENT_GREEN, size=13),
                                            ft.Text(f"Restam: {rest}", size=11, color=ACCENT_GREEN, weight=ft.FontWeight.BOLD),
                                        ],
                                        spacing=4,
                                    ),
                                ],
                                alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                            ),
                        ],
                        spacing=0,
                    ),
                    bgcolor=BG_CARD,
                    border_radius=14,
                    padding=16,
                    border=ft.border.all(1, BORDER_COLOR),
                ),
                ft.Container(height=16),
                ft.Text("Historico de leituras", size=13, color=TEXT_PRIMARY, weight=ft.FontWeight.BOLD),
                ft.Container(height=8),
                ft.Container(
                    ft.Column(
                        [
                            ft.Row(
                                [
                                    ft.Icon(ft.icons.THERMOSTAT, color=ACCENT_RED, size=14),
                                    ft.Text("Temperatura (C)", color=TEXT_MUTED, size=11, expand=True),
                                    ft.Text(f"{estufa['temp']:.1f} C", color=ACCENT_RED, size=12, weight=ft.FontWeight.BOLD),
                                ],
                                spacing=6,
                            ),
                            ft.Container(height=6),
                            mini_sparkline(temps, ACCENT_RED),
                            ft.Row(
                                [
                                    ft.Text(HISTORICO[0]["ts"], size=9, color=TEXT_MUTED),
                                    ft.Container(expand=True),
                                    ft.Text(HISTORICO[-1]["ts"], size=9, color=TEXT_MUTED),
                                ],
                            ),
                            ft.Container(height=16),
                            ft.Row(
                                [
                                    ft.Icon(ft.icons.WATER_DROP, color=ACCENT_BLUE, size=14),
                                    ft.Text("Umidade (%)", color=TEXT_MUTED, size=11, expand=True),
                                    ft.Text(f"{estufa['umidade']:.1f} %", color=ACCENT_BLUE, size=12, weight=ft.FontWeight.BOLD),
                                ],
                                spacing=6,
                            ),
                            ft.Container(height=6),
                            mini_sparkline(umids, ACCENT_BLUE),
                            ft.Row(
                                [
                                    ft.Text(HISTORICO[0]["ts"], size=9, color=TEXT_MUTED),
                                    ft.Container(expand=True),
                                    ft.Text(HISTORICO[-1]["ts"], size=9, color=TEXT_MUTED),
                                ],
                            ),
                        ],
                        spacing=0,
                    ),
                    bgcolor=BG_CARD,
                    border_radius=14,
                    padding=16,
                    border=ft.border.all(1, BORDER_COLOR),
                ),
                ft.Container(height=20),
            ],
            spacing=0,
        )

    def aba_alertas():
        if not alertas_estufa:
            return ft.Container(
                ft.Column(
                    [
                        ft.Icon(ft.icons.CHECK_CIRCLE_OUTLINE, color=ACCENT_GREEN, size=48),
                        ft.Text("Nenhum alerta para esta estufa", color=TEXT_MUTED, size=13),
                    ],
                    horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                    spacing=12,
                ),
                padding=padxy(vertical=40),
                alignment=ft.Alignment(0, 0),
            )
        return ft.Column([alerta_row(alerta) for alerta in alertas_estufa] + [ft.Container(height=20)], spacing=0)

    def aba_info():
        def irow(icon, label, value, color=TEXT_PRIMARY):
            return ft.Column(
                [
                    ft.Row(
                        [
                            ft.Icon(icon, color=TEXT_MUTED, size=16),
                            ft.Text(label, color=TEXT_MUTED, size=12, expand=True),
                            ft.Text(value, color=color, size=12, weight=ft.FontWeight.BOLD),
                        ],
                        spacing=10,
                    ),
                    hdivider(),
                ],
                spacing=10,
            )

        return ft.Container(
            ft.Column(
                [
                    irow(ft.icons.BADGE_OUTLINED, "ID da Estufa", f"#{estufa['id']}"),
                    irow(ft.icons.ROUTER_OUTLINED, "Dispositivo LoRa", estufa["device_id"], ACCENT_GREEN),
                    irow(ft.icons.LAYERS_OUTLINED, "Estagio atual", estufa["estagio"]),
                    irow(ft.icons.SCHEDULE, "Inicio da secagem", estufa["inicio"]),
                    irow(ft.icons.HOURGLASS_BOTTOM, "Duracao total", f"{estufa['duracao_total_h']} h"),
                    irow(ft.icons.TIMER_OUTLINED, "Horas decorridas", f"{estufa['horas_decorridas']} h"),
                    ft.Container(height=16),
                    ft.ElevatedButton(
                        "Escanear QR Code - Vincular dispositivo",
                        icon=ft.icons.QR_CODE_SCANNER,
                        bgcolor=BG_CARD2,
                        color=TEXT_PRIMARY,
                        width=float("inf"),
                        style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=10)),
                    ),
                    ft.Container(height=20),
                ],
                spacing=0,
            ),
            bgcolor=BG_CARD,
            border_radius=14,
            padding=16,
            border=ft.border.all(1, BORDER_COLOR),
        )

    content_col = ft.Column([aba_monitor()], spacing=0)

    def on_tab(event):
        idx = event.control.selected_index
        content_col.controls.clear()
        if idx == 0:
            content_col.controls.append(aba_monitor())
        elif idx == 1:
            content_col.controls.append(aba_alertas())
        else:
            content_col.controls.append(aba_info())
        page.update()

    nav_bar = ft.NavigationBar(
        destinations=[
            ft.NavigationBarDestination(icon=ft.icons.MONITOR_HEART_OUTLINED, selected_icon=ft.icons.MONITOR_HEART, label="Monitor"),
            ft.NavigationBarDestination(icon=ft.icons.NOTIFICATIONS_OUTLINED, selected_icon=ft.icons.NOTIFICATIONS, label=f"Alertas ({len(alertas_estufa)})"),
            ft.NavigationBarDestination(icon=ft.icons.INFO_OUTLINED, selected_icon=ft.icons.INFO, label="Info"),
        ],
        bgcolor=BG_CARD,
        indicator_color=f"{ACCENT_GREEN}33",
        on_change=on_tab,
    )

    return ft.View(
        route="/estufa",
        bgcolor=BG_DARK,
        scroll=ft.ScrollMode.AUTO,
        navigation_bar=nav_bar,
        appbar=ft.AppBar(
            leading=ft.IconButton(ft.icons.ARROW_BACK, icon_color=TEXT_MUTED, on_click=lambda ev: navigate("/dashboard")),
            title=ft.Column(
                [
                    ft.Text(estufa["nome"], color=TEXT_PRIMARY, weight=ft.FontWeight.BOLD, size=14),
                    ft.Text(estufa["estagio"], color=TEXT_MUTED, size=11),
                ],
                spacing=1,
            ),
            bgcolor=BG_CARD,
            actions=[tag_badge(status_label, cor_status), ft.Container(width=8)],
        ),
        controls=[ft.Container(content_col, padding=padxy(horizontal=16, vertical=12))],
    )

