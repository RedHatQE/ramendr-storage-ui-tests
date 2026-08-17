import tests.utils.pattern_variant as pv


def test_qe_mixed_fleet_when_variant_unset(monkeypatch):
    monkeypatch.setattr(pv, "PATTERN_VARIANT", "")
    assert pv.is_qe_mixed_fleet()
    assert not pv.is_v13_variant()
    assert not pv.is_partner_variant()
    assert pv.has_odf_mirrorpeer()
    assert pv.has_edge_vms()
    assert pv.has_vm_drpc()
    assert not pv.has_s4_storage()


def test_odf_variant_keeps_odf_without_qe_windows_fleet(monkeypatch):
    monkeypatch.setattr(pv, "PATTERN_VARIANT", "odf")
    assert not pv.is_qe_mixed_fleet()
    assert pv.is_v13_variant()
    assert not pv.is_partner_variant()
    assert pv.has_odf_mirrorpeer()
    assert pv.has_edge_vms()
    assert pv.has_vm_drpc()
    assert not pv.has_s4_storage()


def test_drpartner_s4_has_s3_without_odf_or_vms(monkeypatch):
    monkeypatch.setattr(pv, "PATTERN_VARIANT", "drpartner-s4")
    assert pv.is_partner_variant()
    assert pv.has_s4_storage()
    assert not pv.has_odf_mirrorpeer()
    assert not pv.has_edge_vms()
    assert not pv.has_vm_drpc()
    assert not pv.is_minimal_variant()


def test_drpartner_minimal_has_neither_s4_nor_odf(monkeypatch):
    monkeypatch.setattr(pv, "PATTERN_VARIANT", "drpartner-minimal")
    assert pv.is_partner_variant()
    assert pv.is_minimal_variant()
    assert not pv.has_s4_storage()
    assert not pv.has_odf_mirrorpeer()
    assert not pv.has_edge_vms()
    assert not pv.has_vm_drpc()
