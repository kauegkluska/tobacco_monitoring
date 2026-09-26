from datetime import datetime, timezone


def utcnow() -> datetime:
    """Hora atual em UTC, sem tzinfo, no formato que o SQLite armazena."""
    return datetime.now(timezone.utc).replace(tzinfo=None)
