import tests.utils.pattern_variant as pv


def test_odf_variant_is_default_qe_mixed_fleet(monkeypatch):
    monkeypatch.delenv("PATTERN_VARIANT", raising=False)
    import importlib

    importlib.reload(pv)
    assert pv.PATTERN_VARIANT == "odf"
    assert pv.is_qe_mixed_fleet()
    assert pv.is_v13_variant()
    assert not pv.is_partner_variant()
    assert pv.has_odf_mirrorpeer()
    assert pv.has_edge_vms()
    assert pv.has_vm_drpc()
    assert not pv.has_s4_storage()
    assert pv.hub_argocd_namespace() == "ramendr-starter-kit-odf"


def test_drpartner_s4_has_s3_without_odf_or_vms(monkeypatch):
    monkeypatch.setattr(pv, "PATTERN_VARIANT", "drpartner-s4")
    assert pv.is_partner_variant()
    assert pv.has_s4_storage()
    assert not pv.has_odf_mirrorpeer()
    assert not pv.has_edge_vms()
    assert not pv.has_vm_drpc()
    assert not pv.is_minimal_variant()
    assert pv.hub_argocd_namespace() == "ramendr-starter-kit-drpartner-s4"


def test_drpartner_minimal_has_neither_s4_nor_odf(monkeypatch):
    monkeypatch.setattr(pv, "PATTERN_VARIANT", "drpartner-minimal")
    assert pv.is_partner_variant()
    assert pv.is_minimal_variant()
    assert not pv.has_s4_storage()
    assert not pv.has_odf_mirrorpeer()
    assert not pv.has_edge_vms()
    assert not pv.has_vm_drpc()
    assert pv.hub_argocd_namespace() == "ramendr-starter-kit-minimal"
