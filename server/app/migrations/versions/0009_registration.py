"""Selbst-Registrierung und Sichtbarkeit je Rubrik

Revision ID: 0009
Revises: 0008

Bestehende Konten bekommen all_categories = true (sehen weiter alle Rubriken), approval_pending = false und
self_registered = false. Am Verhalten ändert sich dadurch nichts. Neue Tabelle user_categories für die Rubriken, die
ein eingeschränktes Konto sehen darf. Dazu Indizes auf cover_id bei Titeln, Alben und Künstlern (die Cover-Prüfung für
eingeschränkte Konten sucht bei jedem Cover-Abruf danach).

Rücksprung (downgrade 0008): Tabelle und die drei Spalten verschwinden. Wartende Konten bleiben danach als
is_active = false gesperrt (gewollt), eingeschränkte Konten sehen in der Vorversion wieder alles.
"""

import sqlalchemy as sa
from alembic import op

revision = "0009"
down_revision = "0008"
branch_labels = None
depends_on = None

COVER_TABLES = ("tracks", "albums", "artists")


def upgrade() -> None:
    with op.batch_alter_table("users") as batch:
        batch.add_column(sa.Column("all_categories", sa.Boolean(), nullable=False, server_default="1"))
        batch.add_column(sa.Column("approval_pending", sa.Boolean(), nullable=False, server_default="0"))
        batch.add_column(sa.Column("self_registered", sa.Boolean(), nullable=False, server_default="0"))
    op.create_table(
        "user_categories",
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("category_id", sa.Integer(), nullable=False),
        sa.ForeignKeyConstraint(
            ["category_id"],
            ["categories.id"],
            name=op.f("fk_user_categories_category_id_categories"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_user_categories_user_id_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("user_id", "category_id", name=op.f("pk_user_categories")),
    )
    with op.batch_alter_table("user_categories") as batch:
        batch.create_index(batch.f("ix_user_categories_category_id"), ["category_id"], unique=False)
    for table in COVER_TABLES:
        op.create_index(op.f(f"ix_{table}_cover_id"), table, ["cover_id"], unique=False)


def downgrade() -> None:
    for table in COVER_TABLES:
        op.drop_index(op.f(f"ix_{table}_cover_id"), table_name=table)
    op.drop_table("user_categories")
    with op.batch_alter_table("users") as batch:
        batch.drop_column("self_registered")
        batch.drop_column("approval_pending")
        batch.drop_column("all_categories")
