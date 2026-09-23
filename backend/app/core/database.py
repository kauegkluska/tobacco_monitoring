from pathlib import Path

from sqlalchemy import create_engine, inspect, text
from sqlalchemy.orm import sessionmaker, declarative_base

DATABASE_PATH = Path(__file__).resolve().parents[2] / "data" / "monitor.db"
DATABASE_PATH.parent.mkdir(parents=True, exist_ok=True)

DATABASE_URL = f"sqlite:///{DATABASE_PATH.as_posix()}"

engine = create_engine(
    DATABASE_URL,
    connect_args={"check_same_thread": False},
)

SessionLocal = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=engine
)

Base = declarative_base()


def initialize_database() -> None:
    Base.metadata.create_all(bind=engine)

    with engine.begin() as connection:
        connection.execute(text("PRAGMA foreign_keys=OFF"))
        inspector = inspect(connection)

        device_columns = {
            column["name"] for column in inspector.get_columns("devices")
        }
        if "user_id" not in device_columns and "users_id" in device_columns:
            connection.execute(text("ALTER TABLE devices RENAME TO devices_legacy"))
            connection.execute(text(
                "CREATE TABLE devices ("
                "id INTEGER PRIMARY KEY, "
                "user_id INTEGER NULL, "
                "FOREIGN KEY(user_id) REFERENCES users(id)"
                ")"
            ))
            connection.execute(text(
                "INSERT INTO devices (id, user_id) "
                "SELECT id, users_id FROM devices_legacy"
            ))
            connection.execute(text("DROP TABLE devices_legacy"))

        curing_unit_foreign_keys = connection.execute(
            text("PRAGMA foreign_key_list(curing_units)")
        ).fetchall()
        if any(key[2] == "devices_legacy" for key in curing_unit_foreign_keys):
            connection.execute(text("ALTER TABLE curing_units RENAME TO curing_units_legacy"))
            connection.execute(text(
                "CREATE TABLE curing_units ("
                "id INTEGER PRIMARY KEY, "
                "name TEXT NOT NULL DEFAULT 'Estufa', "
                "curing_stage TEXT NOT NULL DEFAULT 'Não iniciado', "
                "device_id INTEGER NOT NULL, "
                "FOREIGN KEY(device_id) REFERENCES devices(id)"
                ")"
            ))
            legacy_columns = {
                column["name"]
                for column in inspect(connection).get_columns("curing_units_legacy")
            }
            name_expression = "name" if "name" in legacy_columns else "'Estufa'"
            connection.execute(text(
                "INSERT INTO curing_units (id, name, curing_stage, device_id) "
                f"SELECT id, {name_expression}, curing_stage, device_id "
                "FROM curing_units_legacy"
            ))
            connection.execute(text("DROP TABLE curing_units_legacy"))

        for table, definition, columns in (
            (
                "readings",
                "id INTEGER PRIMARY KEY, temperature FLOAT NOT NULL, "
                "humidity FLOAT NOT NULL, timestamp DATETIME, "
                "curing_unit_id INTEGER NOT NULL, "
                "FOREIGN KEY(curing_unit_id) REFERENCES curing_units(id)",
                "id, temperature, humidity, timestamp, curing_unit_id",
            ),
            (
                "alerts",
                "id INTEGER PRIMARY KEY, timestamp DATETIME, "
                "message VARCHAR(255) NOT NULL, type VARCHAR(50) NOT NULL, "
                "is_active BOOLEAN NOT NULL, curing_unit_id INTEGER NOT NULL, "
                "FOREIGN KEY(curing_unit_id) REFERENCES curing_units(id)",
                "id, timestamp, message, type, is_active, curing_unit_id",
            ),
        ):
            foreign_keys = connection.execute(
                text(f"PRAGMA foreign_key_list({table})")
            ).fetchall()
            if not any(key[2] == "curing_units_legacy" for key in foreign_keys):
                continue

            legacy_table = f"{table}_legacy"
            connection.execute(text(f"ALTER TABLE {table} RENAME TO {legacy_table}"))
            connection.execute(text(f"CREATE TABLE {table} ({definition})"))
            connection.execute(text(
                f"INSERT INTO {table} ({columns}) "
                f"SELECT {columns} FROM {legacy_table}"
            ))
            connection.execute(text(f"DROP TABLE {legacy_table}"))

        def add_column(table: str, name: str, definition: str) -> None:
            columns = {column["name"] for column in inspect(connection).get_columns(table)}
            if name not in columns:
                connection.execute(text(f"ALTER TABLE {table} ADD COLUMN {name} {definition}"))

        add_column("devices", "device_code", "VARCHAR(100)")
        add_column("devices", "created_at", "DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00'")
        add_column("devices", "last_seen_at", "DATETIME")
        add_column("devices", "status", "VARCHAR(20) NOT NULL DEFAULT 'offline'")
        add_column("devices", "mac_address", "VARCHAR(50)")
        add_column("devices", "lora_id", "VARCHAR(50)")
        add_column("devices", "hardware_model", "VARCHAR(100)")
        add_column("devices", "firmware_version", "VARCHAR(50)")
        add_column("devices", "battery_level", "INTEGER DEFAULT 100")
        add_column("devices", "battery_status", "VARCHAR(50) DEFAULT 'Normal'")
        add_column("devices", "rssi", "INTEGER DEFAULT -64")
        add_column("devices", "snr", "FLOAT DEFAULT 9.5")
        add_column("devices", "frequency", "VARCHAR(50) DEFAULT '915.0 MHz'")
        add_column("devices", "temp_min", "FLOAT DEFAULT 35.0")
        add_column("devices", "temp_max", "FLOAT DEFAULT 75.0")
        add_column("devices", "humidity_min", "FLOAT DEFAULT 40.0")
        add_column("devices", "humidity_max", "FLOAT DEFAULT 90.0")
        add_column("devices", "calibration_data", "TEXT")
        add_column("devices", "sensors_config", "TEXT")
        add_column("curing_units", "stage_started_at", "DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00'")
        add_column("curing_units", "drying_started_at", "DATETIME")
        add_column("curing_units", "estimated_duration_hours", "FLOAT")
        add_column("alerts", "severity", "VARCHAR(20) NOT NULL DEFAULT 'warning'")
        add_column("alerts", "acknowledged_at", "DATETIME")
        add_column("alerts", "resolved_at", "DATETIME")
        add_column("users", "reset_token_hash", "VARCHAR(128)")
        add_column("users", "reset_token_expires_at", "DATETIME")

        curing_unit_columns = {
            column["name"] for column in inspector.get_columns("curing_units")
        }
        if "name" not in curing_unit_columns:
            connection.execute(text(
                "ALTER TABLE curing_units ADD COLUMN name TEXT "
                "NOT NULL DEFAULT 'Estufa'"
            ))

        connection.execute(text("PRAGMA foreign_keys=ON"))