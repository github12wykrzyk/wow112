from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "src" / "AddOns" / "SummonScout"
BOOT = (ADDON / "SummonScout_FleetProfileBootstrap.lua").read_text(encoding="utf-8")
TOC = (ADDON / "SummonScout.toc").read_text(encoding="utf-8")


def test_bootstrap_loads_before_router():
    assert TOC.index("SummonScout_FleetProfileBootstrap.lua") < TOC.index("SummonScout_FallbackRouterHot.lua")


def test_canonical_five_profiles():
    expected = {
        "feltaxi": "hydraxian",
        "kalisum": "silithus",
        "bolthyjal": "hyjal",
        "taxiwinter": "winterspring",
        "teletanaris": "tanaris",
    }
    for name, service in expected.items():
        assert f'{name}' in BOOT
        assert f'service="{service}"' in BOOT
    assert 'local MASTER = "Feltaxi"' in BOOT


def test_one_shot_per_character_marker():
    assert "fleetProfileBootstrapByCharacter" in BOOT
    assert "tonumber(SummonScoutDB.fleetProfileBootstrapByCharacter[k]) == VERSION" in BOOT
    assert "SummonScoutDB.fleetProfileBootstrapByCharacter[k] = VERSION" in BOOT


def test_old_world_scheduler_is_disabled():
    assert "SummonScoutDB.spamEnabled = false" in BOOT
    assert "SummonScoutDB.fleetAdvertEnabled = true" in BOOT
    assert "SummonScoutDB.fleetCounterEnabled = true" in BOOT


def test_master_reporting_topology():
    assert 'feltaxi     = { service="hydraxian", reporting=false }' in BOOT
    for name in ("kalisum", "bolthyjal", "taxiwinter", "teletanaris"):
        assert f"{name}" in BOOT
    assert "SummonScoutDB.masterReportingEnabled = p.reporting and true or false" in BOOT


def test_no_slave_character_profiles():
    for slave in (
        "silione", "silitwo", "hyjaluno", "hyjalonee", "hydratwo", "hydraone",
        "winterone", "wintertwoo", "tanarisone", "tanaristwo",
    ):
        assert f"{slave}     =" not in BOOT


def test_lua50_safety():
    assert "table.unpack" not in BOOT
    assert "goto " not in BOOT
    assert "continue" not in BOOT
