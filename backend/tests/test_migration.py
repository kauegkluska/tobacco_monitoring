from sqlalchemy import create_engine, text

from core.database import initialize_database

# Esquema criado pela versão anterior do backend (estufa com device_id obrigatório e sem dono).
LEGACY_SCHEMA = (
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name VARCHAR(100) NOT NULL, login VARCHAR(100) NOT NULL UNIQUE, "
    "password_hash VARCHAR(255) NOT NULL)",
    "CREATE TABLE devices (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id))",
    "CREATE TABLE curing_units (id INTEGER NOT NULL, name VARCHAR(100) NOT NULL, curing_stage VARCHAR(50) NOT NULL, "
    "stage_started_at DATETIME NOT NULL, drying_started_at DATETIME, estimated_duration_hours FLOAT, "
    "device_id INTEGER NOT NULL, PRIMARY KEY (id), FOREIGN KEY(device_id) REFERENCES devices (id))",
    "CREATE TABLE readings (id INTEGER PRIMARY KEY, temperature FLOAT NOT NULL, humidity FLOAT NOT NULL, "
    "timestamp DATETIME, curing_unit_id INTEGER NOT NULL REFERENCES curing_units(id))",
    "CREATE TABLE alerts (id INTEGER PRIMARY KEY, timestamp DATETIME, message VARCHAR(255) NOT NULL, "
    "type VARCHAR(50) NOT NULL, is_active BOOLEAN NOT NULL, curing_unit_id INTEGER NOT NULL REFERENCES curing_units(id))",
    "INSERT INTO users (id, name, login, password_hash) VALUES (1, 'Antigo', 'antigo', 'x')",
    "INSERT INTO devices (id, user_id) VALUES (1, 1)",
    "INSERT INTO curing_units VALUES (1, 'Estufa legado', 'Amarelecimento', '2026-01-01 00:00:00', NULL, NULL, 1)",
    "INSERT INTO readings VALUES (1, 40.0, 60.0, '2026-01-01 01:00:00', 1)",
)


def test_legacy_database_is_migrated(tmp_path):
    engine = create_engine(f"sqlite:///{(tmp_path / 'legacy.db').as_posix()}")
    with engine.begin() as connection:
        for statement in LEGACY_SCHEMA:
            connection.execute(text(statement))

    initialize_database(engine)
    initialize_database(engine)  # precisa ser idempotente

    with engine.connect() as connection:
        columns = {row[1]: row for row in connection.execute(text("PRAGMA table_info(curing_units)"))}
        assert columns["device_id"][3] == 0  # device_id deixou de ser NOT NULL
        assert connection.execute(text("SELECT user_id, name FROM curing_units")).fetchone() == (1, "Estufa legado")
        # "Amarelecimento" virou a fase "Amarelação".
        assert connection.execute(text("SELECT curing_stage FROM curing_units")).scalar() == "Amarelação"
        assert connection.execute(text("SELECT COUNT(*) FROM readings")).scalar() == 1
        assert connection.execute(text("PRAGMA foreign_key_check")).fetchall() == []
        assert "value" in {row[1] for row in connection.execute(text("PRAGMA table_info(alerts)"))}
        # Relé 1 vira o flap e relé 2 a ventoinha, que segue a temperatura alvo.
        outputs = connection.execute(text(
            "SELECT humidity_output_name, temperature_output_name, temperature_output_trigger, target_temperature "
            "FROM curing_units"
        )).fetchone()
        assert tuple(outputs) == ("Flap", "Ventoinha", "temperature_target", None)
