"""Unit tests for MirrorPeer status helpers."""

from tests.utils.mirrorpeer import mirrorpeer_setup_complete


def test_mirrorpeer_setup_complete_with_completed_condition():
    ok, detail = mirrorpeer_setup_complete(
        {
            "phase": "Ready",
            "conditions": [
                {
                    "type": "Completed",
                    "status": "True",
                    "reason": "MirrorPeerReady",
                    "message": "Setup is completed",
                }
            ],
        }
    )
    assert ok is True
    assert detail == "Completed=True"


def test_mirrorpeer_setup_complete_with_ready_phase_and_message():
    ok, detail = mirrorpeer_setup_complete(
        {"phase": "Ready", "message": "Setup is completed"}
    )
    assert ok is True
    assert "phase=Ready" in detail


def test_mirrorpeer_setup_complete_with_legacy_exchanged_secret_phase():
    ok, detail = mirrorpeer_setup_complete({"phase": "ExchangedSecret"})
    assert ok is True
    assert detail == "phase=ExchangedSecret"


def test_mirrorpeer_setup_complete_rejects_in_progress():
    ok, detail = mirrorpeer_setup_complete({"phase": "ExchangingSecret"})
    assert ok is False
    assert "ExchangingSecret" in detail


def test_mirrorpeer_setup_complete_rejects_failed_completed_condition():
    ok, detail = mirrorpeer_setup_complete(
        {
            "phase": "Configuring",
            "conditions": [
                {
                    "type": "Completed",
                    "status": "False",
                    "reason": "PeeringIncomplete",
                    "message": "Peering not yet completed",
                }
            ],
        }
    )
    assert ok is False
    assert "Completed=False" in detail
