"""Korrekturen aus der Gegenprüfung: ein Code je Benutzer höchstens einmal, Downloads nur ausblenden

Revision ID: 0006
Revises: 0005
"""

import sqlalchemy as sa
from alembic import op

import app.models.base

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Doppelte Einlösungen (nur durch gleichzeitige Anfragen möglich) bereinigen: die erste bleibt
    op.execute(
        sa.text(
            "DELETE FROM premium_licenses WHERE code_id IS NOT NULL AND id NOT IN "
            "(SELECT MIN(id) FROM premium_licenses WHERE code_id IS NOT NULL GROUP BY code_id, user_id)"
        )
    )
    with op.batch_alter_table("premium_licenses") as batch:
        batch.create_unique_constraint("uq_premium_licenses_code_id_user_id", ["code_id", "user_id"])
    # „Entfernen“ in der Download-Liste blendet nur noch aus – die Statistik im Dashboard zählt weiter
    with op.batch_alter_table("download_jobs") as batch:
        batch.add_column(sa.Column("hidden_at", app.models.base.UTCDateTime(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("download_jobs") as batch:
        batch.drop_column("hidden_at")
    with op.batch_alter_table("premium_licenses") as batch:
        batch.drop_constraint("uq_premium_licenses_code_id_user_id", type_="unique")
