import flet as ft

from app.api_client import ApiClient, ApiError
from app.state import AppState
from app.ui.helpers import center_alignment, color, error_banner, icon, value_at


class LoginView:
    def __init__(self, page: ft.Page, api: ApiClient, state: AppState):
        self.page = page
        self.api = api
        self.state = state
        self.error = ft.Column(spacing=0)
        self.loading = ft.ProgressRing(visible=False)
        self.login_field = ft.TextField(label="Login", autofocus=True)
        self.password_field = ft.TextField(label="Password", password=True, can_reveal_password=True)

    def build(self) -> ft.View:
        return ft.View(
            route="/login",
            padding=0,
            controls=[
                ft.Container(
                    expand=True,
                    alignment=center_alignment(),
                    padding=24,
                    content=ft.Container(
                        width=420,
                        content=ft.Column(
                            tight=True,
                            spacing=16,
                            horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
                            controls=[
                                ft.Text("Estufas IoT", size=30, weight=ft.FontWeight.W_700),
                                ft.Text("Sign in to monitor curing units.", color=color("GREY_700")),
                                self.error,
                                self.login_field,
                                self.password_field,
                                ft.FilledButton(
                                    "Login",
                                    icon=icon("LOGIN"),
                                    on_click=lambda _: self.page.run_task(self.submit),
                                ),
                                ft.TextButton(
                                    "Create account",
                                    icon=icon("PERSON_ADD"),
                                    on_click=lambda _: self.page.go("/register"),
                                ),
                                ft.Container(alignment=center_alignment(), content=self.loading),
                            ],
                        ),
                    ),
                )
            ],
        )

    async def submit(self):
        self.error.controls.clear()
        self.loading.visible = True
        self.page.update()

        try:
            payload = await self.api.login(self.login_field.value or "", self.password_field.value or "")
            token = value_at(payload, "access_token", "token", default=None)
            if not token:
                raise ApiError("Login succeeded, but the API did not return an access token.")
            self.api.set_token(token)
            self.state.jwt_token = token
            self.state.current_user = await self.api.me()
            self.page.go("/dashboard")
        except ApiError as exc:
            self.error.controls = [error_banner(exc.message)]
        finally:
            self.loading.visible = False
            self.page.update()


class RegisterView:
    def __init__(self, page: ft.Page, api: ApiClient, state: AppState):
        self.page = page
        self.api = api
        self.state = state
        self.error = ft.Column(spacing=0)
        self.loading = ft.ProgressRing(visible=False)
        self.name_field = ft.TextField(label="Name", autofocus=True)
        self.login_field = ft.TextField(label="Login", autofocus=True)
        self.password_field = ft.TextField(label="Password", password=True, can_reveal_password=True)

    def build(self) -> ft.View:
        return ft.View(
            route="/register",
            padding=0,
            controls=[
                ft.Container(
                    expand=True,
                    alignment=center_alignment(),
                    padding=24,
                    content=ft.Container(
                        width=420,
                        content=ft.Column(
                            tight=True,
                            spacing=16,
                            horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
                            controls=[
                                ft.Text("Create account", size=30, weight=ft.FontWeight.W_700),
                                ft.Text("Register a user in the existing API.", color=color("GREY_700")),
                                self.error,
                                self.name_field,
                                self.login_field,
                                self.password_field,
                                ft.FilledButton(
                                    "Register",
                                    icon=icon("PERSON_ADD"),
                                    on_click=lambda _: self.page.run_task(self.submit),
                                ),
                                ft.TextButton(
                                    "Back to login",
                                    icon=icon("ARROW_BACK"),
                                    on_click=lambda _: self.page.go("/login"),
                                ),
                                ft.Container(alignment=center_alignment(), content=self.loading),
                            ],
                        ),
                    ),
                )
            ],
        )

    async def submit(self):
        self.error.controls.clear()
        self.loading.visible = True
        self.page.update()
        try:
            await self.api.register(self.name_field.value or "", self.login_field.value or "", self.password_field.value or "")
            self.page.go("/login")
            self.page.snack_bar = ft.SnackBar(ft.Text("Account created. Please log in."), open=True)
        except ApiError as exc:
            self.error.controls = [error_banner(exc.message)]
        finally:
            self.loading.visible = False
            self.page.update()
