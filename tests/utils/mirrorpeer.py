"""MirrorPeer status helpers for version-agnostic smoke checks."""

from __future__ import annotations

# Canonical steady-state message from odf-multicluster-orchestrator (MirrorPeerReady).
_SETUP_COMPLETE_MESSAGE = "setup is completed"


def mirrorpeer_setup_complete(status: dict | None) -> tuple[bool, str]:
    """Return whether MirrorPeer peering/setup finished across ODF operator versions.

    Newer operators expose ``status.conditions[Completed=True]``. ODF 4.22 reports
    ``phase=Ready`` with message ``Setup is completed`` without conditions. Legacy
    operators stop at ``phase=ExchangedSecret`` after secret exchange.
    """
    status = status or {}
    conditions = {
        entry["type"]: entry
        for entry in (status.get("conditions") or [])
        if isinstance(entry, dict) and entry.get("type")
    }
    completed = conditions.get("Completed")
    if completed is not None:
        completed_status = completed.get("status", "False")
        if completed_status == "True":
            return True, "Completed=True"
        reason = completed.get("reason", "")
        message = completed.get("message", "")
        detail = f"Completed={completed_status}"
        if reason:
            detail += f", reason={reason}"
        if message:
            detail += f", message={message}"
        return False, detail

    phase = status.get("phase", "")
    message = (status.get("message") or "").strip()

    if phase == "Ready" and message.lower() == _SETUP_COMPLETE_MESSAGE:
        return True, f"phase=Ready, message={message!r}"

    if phase == "ExchangedSecret":
        return True, "phase=ExchangedSecret"

    detail = f"phase={phase!r}"
    if message:
        detail += f", message={message!r}"
    if conditions:
        detail += f", conditions={sorted(conditions)}"
    return False, detail
