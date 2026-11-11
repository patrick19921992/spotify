"""Premium Teil 2: Leistungsumfang von Codes und Lizenzen, Laufzeit (Basis-Abo/Angebot) von Käufen über Google Play

Revision ID: 0008
Revises: 0007

Bestehende Codes und Lizenzen bekommen features = NULL (= alle Leistungen), bestehende Käufe base_plan_id = offer_id
= "" (unbekannt). Am Verhalten ändert sich dadurch nichts.

Rücksprung (downgrade 0007): Die vier Spalten verschwinden. Lizenzen und Codes mit Teilumfang werden dabei zu vollem
Premium – die Vorversion kennt keinen Umfang.
"""

import sqlalchemy as sa
from alembic import op

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("premium_codes", sa.Column("features", sa.String(length=200), nullable=True))
    op.add_column("premium_licenses", sa.Column("features", sa.String(length=200), nullable=True))
    op.add_column(
        "play_purchases", sa.Column("base_plan_id", sa.String(length=64), nullable=False, server_default="")
    )
    op.add_column("play_purchases", sa.Column("offer_id", sa.String(length=64), nullable=False, server_default=""))


def downgrade() -> None:
    with op.batch_alter_table("play_purchases") as batch:
        batch.drop_column("offer_id")
        batch.drop_column("base_plan_id")
    with op.batch_alter_table("premium_licenses") as batch:
        batch.drop_column("features")
    with op.batch_alter_table("premium_codes") as batch:
        batch.drop_column("features")
