"""Helfer für die Unraid-Konsole, z. B. wenn das Admin-Passwort vergessen wurde.

Aufruf im Container:
    python -m app.cli list-users
    python -m app.cli reset-password <benutzer> <neues-passwort>
    python -m app.cli create-user <benutzer> <passwort> [--admin]
"""

import argparse
import re
import sys

from sqlalchemy import select

from app.config import get_settings
from app.database import create_db_engine, create_session_factory, run_migrations
from app.models import User
from app.schemas.common import USERNAME_PATTERN
from app.security import hash_password
from app.services.auth import revoke_all_sessions


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m app.cli", description="Selfify-Verwaltung")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list-users", help="Alle Benutzer anzeigen")
    reset = sub.add_parser("reset-password", help="Passwort neu setzen und alle Geräte abmelden")
    reset.add_argument("username")
    reset.add_argument("password")
    create = sub.add_parser("create-user", help="Neuen Benutzer anlegen")
    create.add_argument("username")
    create.add_argument("password")
    create.add_argument("--admin", action="store_true", help="Als Admin anlegen")
    args = parser.parse_args(argv)

    settings = get_settings()
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    run_migrations(settings.database_url)
    engine = create_db_engine(settings.database_url)
    with create_session_factory(engine)() as db:
        if args.command == "list-users":
            for user in db.scalars(select(User).order_by(User.username)):
                flags = [f for f, on in (("admin", user.is_admin), ("deaktiviert", not user.is_active)) if on]
                print(f"{user.id:>4}  {user.username:<32} {user.display_name} {' '.join(flags)}")
            return 0

        username = args.username.strip().lower()
        if len(args.password) < 8:
            print("Das Passwort muss mindestens 8 Zeichen lang sein.", file=sys.stderr)
            return 1
        user = db.scalar(select(User).where(User.username == username))

        if args.command == "reset-password":
            if user is None:
                print(f"Benutzer '{username}' nicht gefunden.", file=sys.stderr)
                return 1
            user.password_hash = hash_password(args.password)
            user.is_active = True
            revoke_all_sessions(db, user.id)
            db.commit()
            print(f"Passwort für '{username}' neu gesetzt.")
            return 0

        if user is not None:
            print(f"Benutzer '{username}' gibt es schon.", file=sys.stderr)
            return 1
        if not re.fullmatch(USERNAME_PATTERN, username):
            print("Ungültiger Benutzername (3–32 Zeichen: a-z, 0-9, . _ -).", file=sys.stderr)
            return 1
        db.add(
            User(
                username=username,
                display_name=username.capitalize(),
                password_hash=hash_password(args.password),
                is_admin=args.admin,
            )
        )
        db.commit()
        print(f"Benutzer '{username}' angelegt{' (Admin)' if args.admin else ''}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
