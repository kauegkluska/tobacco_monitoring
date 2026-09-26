from datetime import datetime, timezone
from typing import Annotated

from pydantic import AfterValidator


def _as_utc(value: datetime | None) -> datetime | None:
    # O SQLite guarda datas sem fuso, todas em UTC. Marcar o fuso evita que o cliente as trate como hora local.
    if value is not None and value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value


UTCDateTime = Annotated[datetime, AfterValidator(_as_utc)]
