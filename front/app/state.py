from dataclasses import dataclass
from typing import Any


@dataclass
class AppState:
    jwt_token: str | None = None
    current_user: dict[str, Any] | None = None
    selected_curing_unit: dict[str, Any] | None = None

    def clear(self) -> None:
        self.jwt_token = None
        self.current_user = None
        self.selected_curing_unit = None
