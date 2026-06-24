import flet as ft
from utils.theme import AppColors
from utils.api_client import api

def RegisterView(page: ft.Page):
    name_field = ft.TextField(label="Nome Completo", width=300, prefix_icon=ft.icons.BADGE)
    username_field = ft.TextField(label="Usuário", width=300, prefix_icon=ft.icons.PERSON)
    password_field = ft.TextField(label="Senha", width=300, password=True, can_reveal_password=True, prefix_icon=ft.icons.LOCK)
    
    def register_click(e):
        success, message = api.register(name_field.value, username_field.value, password_field.value)
        if success:
            page.go("/login")

    return ft.View(
        "/register",
        controls=[
            ft.AppBar(title=ft.Text("Criar Conta"), bgcolor=AppColors.PRIMARY, color=AppColors.WHITE),
            ft.Container(
                content=ft.Column(
                    [
                        ft.Container(height=40),
                        name_field,
                        username_field,
                        password_field,
                        ft.ElevatedButton(
                            "Cadastrar", 
                            on_click=register_click, 
                            width=300,
                            style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=10))
                        ),
                        ft.TextButton("Já tem uma conta? Faça Login", on_click=lambda _: page.go("/login")),
                    ],
                    horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                ),
                alignment=ft.alignment.center,
                expand=True
            )
        ],
        bgcolor=AppColors.BACKGROUND
    )
