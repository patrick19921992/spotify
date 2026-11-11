"""Käufe über Google Play (Abo für Premium): ein Kauf-Token gehört genau einem Konto

Revision ID: 0007
Revises: 0006
"""

import sqlalchemy as sa
from alembic import op

import app.models.base

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Bestehende Tabellen bleiben unverändert: premium_licenses.source nimmt den neuen Wert "play" ohne Schemaänderung auf
    op.create_table(
        "play_purchases",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("product_id", sa.String(length=100), nullable=False),
        sa.Column("purchase_token", sa.Text(), nullable=False),
        sa.Column("token_hash", sa.String(length=64), nullable=False),
        sa.Column("linked_token_hash", sa.String(length=64), nullable=True),
        sa.Column("order_id", sa.String(length=100), nullable=False),
        sa.Column("state", sa.String(length=12), nullable=False),
        sa.Column("expires_at", app.models.base.UTCDateTime(), nullable=True),
        sa.Column("auto_renewing", sa.Boolean(), nullable=False),
        sa.Column("acknowledged", sa.Boolean(), nullable=False),
        sa.Column("is_test", sa.Boolean(), nullable=False),
        sa.Column("license_id", sa.Integer(), nullable=True),
        sa.Column("last_checked_at", app.models.base.UTCDateTime(), nullable=False),
        sa.Column("last_error", sa.String(length=300), nullable=False),
        sa.Column("created_at", app.models.base.UTCDateTime(), nullable=False),
        sa.Column("updated_at", app.models.base.UTCDateTime(), nullable=False),
        sa.ForeignKeyConstraint(
            ["license_id"],
            ["premium_licenses.id"],
            name=op.f("fk_play_purchases_license_id_premium_licenses"),
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_play_purchases_user_id_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_play_purchases")),
        sa.UniqueConstraint("token_hash", name="uq_play_purchases_token_hash"),
    )
    with op.batch_alter_table("play_purchases") as batch:
        batch.create_index(batch.f("ix_play_purchases_state"), ["state"], unique=False)
        batch.create_index(batch.f("ix_play_purchases_user_id"), ["user_id"], unique=False)


def downgrade() -> None:
    # Lizenzen mit source="play" bleiben als Historie stehen
    with op.batch_alter_table("play_purchases") as batch:
        batch.drop_index(batch.f("ix_play_purchases_user_id"))
        batch.drop_index(batch.f("ix_play_purchases_state"))
    op.drop_table("play_purchases")
