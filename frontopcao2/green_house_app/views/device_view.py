import flet as ft
from utils.theme import AppColors
from utils.api_client import api

def DeviceView(page: ft.Page):
    qr_input = ft.TextField(label="Código do Dispositivo (ou simule QR)", width=300, hint_text="Ex: device_123")
    status_text = ft.Text()

    def handle_link(e):
        success, message = api.link_device(qr_input.value)
        status_text.value = message
        status_text.color = AppColors.PRIMARY if success else AppColors.DANGER
        page.update()

    return ft.View(
        "/devices",
        controls=[
            ft.AppBar(title=ft.Text("Meus Dispositivos"), bgcolor=AppColors.PRIMARY, color=AppColors.WHITE),
            ft.Container(
                padding=20,
                content=ft.Column(
                    [
                        ft.Card(
                            content=ft.Container(
                                padding=20,
                                content=ft.Column([
                                    ft.Text("Vincular Novo Dispositivo", size=20, weight="bold"),
                                    ft.Text("Escaneie o QR Code no seu nó transmissor LoRa"),
                                    ft.Icon(ft.icons.QR_CODE_SCANNER, size=100, color=AppColors.PRIMARY),
                                    qr_input,
                                    ft.ElevatedButton("Vincular Dispositivo", on_click=handle_link),
                                    status_text
                                ], horizontal_alignment="center")
                            )
                        ),
                        ft.Divider(),
                        ft.Text("Dispositivos Ativos", size=18, weight="bold"),
                        ft.ListTile(
                            leading=ft.Icon(ft.icons.ROUTER),
                            title=ft.Text("LoRa Gateway #1"),
                            subtitle=ft.Text("Status: Online"),
                            trailing=ft.Icon(ft.icons.CHECK_CIRCLE, color="green")
                        )
                    ]
                )
            )
        ],
        bgcolor=AppColors.BACKGROUND
    )
