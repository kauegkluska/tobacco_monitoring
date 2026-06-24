import flet as ft
from utils.theme import AppColors
from utils.api_client import api

def HomeView(page: ft.Page):
    estufas_list = ft.Column(spacing=10)
    
    def load_estufas():
        estufas_list.controls.clear()
        data = api.get_curing_units()
        for item in data:
            estufas_list.controls.append(
                ft.Card(
                    content=ft.ListTile(
                        leading=ft.Icon(ft.icons.CHEVRON_RIGHT, color=AppColors.PRIMARY),
                        title=ft.Text(item["name"], weight="bold"),
                        subtitle=ft.Text(f"Status: {item['stage']} | {item['temp']}°C | {item['humidity']}%"),
                        on_click=lambda _, id=item["id"]: page.go(f"/monitor/{id}"),
                        trailing=ft.IconButton(
                            ft.icons.DELETE_OUTLINE, 
                            icon_color=AppColors.DANGER,
                            on_click=lambda _, id=item["id"]: delete_estufa(id)
                        )
                    )
                )
            )
        page.update()

    def delete_estufa(id):
        # Simulação de deleção
        load_estufas()

    def add_estufa_dialog(e):
        name_input = ft.TextField(label="Nome da Estufa")
        
        def save_new(e):
            # Simulação de salvamento
            dialog.open = False
            load_estufas()
            page.update()

        dialog = ft.AlertDialog(
            title=ft.Text("Nova Estufa"),
            content=name_input,
            actions=[
                ft.TextButton("Cancelar", on_click=lambda _: setattr(dialog, "open", False)),
                ft.ElevatedButton("Salvar", on_click=save_new)
            ]
        )
        page.dialog = dialog
        dialog.open = True
        page.update()

    # Carregar dados iniciais
    load_estufas()

    return ft.View(
        "/home",
        controls=[
            ft.AppBar(
                title=ft.Text("Minhas Estufas"), 
                bgcolor=AppColors.PRIMARY, 
                color=AppColors.WHITE,
                actions=[
                    ft.IconButton(ft.icons.QR_CODE, on_click=lambda _: page.go("/devices")),
                    ft.IconButton(ft.icons.LOGOUT, on_click=lambda _: page.go("/login")),
                ]
            ),
            ft.Container(
                padding=20,
                content=ft.Column([
                    ft.Row([
                        ft.Text("Estufas Cadastradas", size=24, weight="bold", expand=True),
                        ft.FloatingActionButton(icon=ft.icons.ADD, on_click=add_estufa_dialog, mini=True)
                    ]),
                    ft.Divider(),
                    estufas_list
                ])
            )
        ],
        bgcolor=AppColors.BACKGROUND
    )
