import flet as ft
from utils.theme import AppColors
from utils.api_client import api
import matplotlib
import matplotlib.pyplot as plt
from flet.matplotlib_chart import MatplotlibChart

matplotlib.use("agg")

def MonitorView(page: ft.Page, unit_id):
    # Simular busca de dados da estufa específica
    unit_data = {"id": unit_id, "name": f"Estufa {unit_id}", "temp": 26.5, "humidity": 58, "time_left": "2h 30min"}
    readings = api.get_readings(unit_id)

    def create_chart():
        fig, ax = plt.subplots(figsize=(6, 4))
        times = [r["timestamp"] for r in readings]
        temps = [r["temp"] for r in readings]
        hums = [r["humidity"] for r in readings]
        
        ax.plot(times, temps, marker='o', label='Temp (°C)', color='red')
        ax.plot(times, hums, marker='s', label='Umid (%)', color='blue')
        ax.set_title("Histórico de Sensores")
        ax.legend()
        ax.grid(True, linestyle='--', alpha=0.7)
        return MatplotlibChart(fig, expand=True)

    return ft.View(
        f"/monitor/{unit_id}",
        controls=[
            ft.AppBar(title=ft.Text(unit_data["name"]), bgcolor=AppColors.PRIMARY, color=AppColors.WHITE),
            ft.Container(
                padding=20,
                content=ft.Column([
                    ft.Row([
                        ft.Card(
                            expand=1,
                            content=ft.Container(
                                padding=15,
                                content=ft.Column([
                                    ft.Text("Temperatura", size=16),
                                    ft.Text(f"{unit_data['temp']}°C", size=28, weight="bold", color="red"),
                                ], horizontal_alignment="center")
                            )
                        ),
                        ft.Card(
                            expand=1,
                            content=ft.Container(
                                padding=15,
                                content=ft.Column([
                                    ft.Text("Umidade", size=16),
                                    ft.Text(f"{unit_data['humidity']}%", size=28, weight="bold", color="blue"),
                                ], horizontal_alignment="center")
                            )
                        ),
                    ]),
                    ft.Card(
                        content=ft.Container(
                            padding=15,
                            content=ft.Row([
                                ft.Icon(ft.icons.TIMER, color=AppColors.ACCENT),
                                ft.Column([
                                    ft.Text("Estimativa de Secagem", size=14),
                                    ft.Text(unit_data["time_left"], size=18, weight="bold"),
                                ])
                            ])
                        )
                    ),
                    ft.Text("Monitoramento em Tempo Real", size=18, weight="bold"),
                    ft.Container(
                        content=create_chart(),
                        height=300,
                        border_radius=10,
                    ),
                    ft.Divider(),
                    ft.Text("Alertas Recentes", size=18, weight="bold"),
                    ft.ListTile(
                        leading=ft.Icon(ft.icons.WARNING, color="orange"),
                        title=ft.Text("Temperatura Alta Detectada"),
                        subtitle=ft.Text("Há 5 minutos | Valor: 30°C"),
                    )
                ], scroll=ft.ScrollMode.AUTO)
            )
        ],
        bgcolor=AppColors.BACKGROUND
    )
