"""Attrappe für die Kaufprüfung bei Google Play – Tests fragen nie das echte Google."""

from dataclasses import replace
from datetime import timedelta

from app.models import utcnow
from app.services.play_billing import PurchaseNotFound, SubscriptionInfo


def sub(
    state: str = "active",
    days: float = 30,
    product: str = "premium_monat",
    account: str = "",
    linked: str = "",
    acknowledged: bool = False,
    test: bool = False,
    base_plan: str = "",
    offer: str = "",
) -> SubscriptionInfo:
    """Ein Abo, wie Google es melden würde. `days` = Ablauf ab jetzt (negativ = schon vorbei)."""
    return SubscriptionInfo(
        state=state,
        product_ids=(product,),
        expires_at=utcnow() + timedelta(days=days),
        auto_renewing=state == "active",
        acknowledged=acknowledged,
        order_id="GPA.1234-5678-9012-34567",
        obfuscated_account_id=account,
        linked_purchase_token=linked,
        is_test=test,
        base_plan_id=base_plan,
        offer_id=offer,
    )


class FakePlayVerifier:
    def __init__(self) -> None:
        # Kauf-Token -> was „Google“ dazu sagt; unbekannte Token gibt es nicht (PurchaseNotFound)
        self.subscriptions: dict[str, SubscriptionInfo] = {}
        self.acknowledged: list[str] = []
        # Wird bei jedem Aufruf geworfen (z. B. VerifierUnavailable)
        self.fail: Exception | None = None
        # Nur das Bestätigen scheitert
        self.fail_acknowledge: Exception | None = None
        self.calls = 0

    def get_subscription(self, purchase_token: str) -> SubscriptionInfo:
        self.calls += 1
        if self.fail is not None:
            raise self.fail
        if purchase_token not in self.subscriptions:
            raise PurchaseNotFound()
        return self.subscriptions[purchase_token]

    def acknowledge(self, product_id: str, purchase_token: str) -> None:
        self.calls += 1
        if self.fail is not None:
            raise self.fail
        if self.fail_acknowledge is not None:
            raise self.fail_acknowledge
        self.acknowledged.append(purchase_token)
        self.subscriptions[purchase_token] = replace(self.subscriptions[purchase_token], acknowledged=True)

    def check_access(self) -> None:
        self.calls += 1
        if self.fail is not None:
            raise self.fail
