#!/usr/bin/env python3
"""Fail-closed hot-reload transform for the SummonScout runtime.

Canonical Lua stays readable and cold-load oriented under src/AddOns/SummonScout.
The parallel addon packager applies the minimum structural changes needed for
executing SummonScout.lua again inside an already-running WoW 1.12.1 client.
A small canonical timing module is also appended to an already watched hot
payload so timing-only changes can be delivered without adding another native
watch slot. Service, pricing and destination logic remain untouched here.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE_NAME = "SummonScout.lua"
TIMING_NAME = "SummonScout_TimingHot.lua"
TIMING_HOST_NAME = "SummonScout_PostPaymentOfferHot.lua"
TIMING_SOURCE = ROOT / "src/AddOns/SummonScout" / TIMING_NAME
TIMING_MARKER = b'local TIMING_VERSION = "1-random-spam-counter1"'


def _text(data: bytes) -> str:
    return data.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")


def _one(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(
            f"SummonScout hot transform anchor {label!r}: expected 1 match, got {count}"
        )
    return text.replace(old, new, 1)


def _persistent_state(text: str) -> str:
    start = "local SS = {}\n"
    end = "\n\nlocal LOCATIONS = {"
    a = text.find(start)
    if a < 0 or text.find(start, a + 1) >= 0:
        raise RuntimeError("SummonScout hot transform: ambiguous SS state start")
    b = text.find(end, a + len(start))
    if b < 0:
        raise RuntimeError("SummonScout hot transform: missing SS state end")

    rows = text[a + len(start):b].splitlines()
    defaults = []
    seen = set()
    for row in rows:
        if not row.strip():
            continue
        match = re.fullmatch(r"SS\.([A-Za-z_][A-Za-z0-9_]*) = (.+)", row)
        if not match:
            raise RuntimeError(f"SummonScout hot transform: unsupported SS initializer: {row!r}")
        key, value = match.groups()
        if key in seen:
            raise RuntimeError(f"SummonScout hot transform: duplicate SS initializer: {key}")
        seen.add(key)
        if value != "nil":
            defaults.append(f"if SS.{key} == nil then SS.{key} = {value} end")

    if not defaults or "queue" not in seen or "loginRecoveryReported" not in seen:
        raise RuntimeError("SummonScout hot transform: incomplete SS initializer block")

    replacement = (
        "W112_SUMMONSCOUT_STATE = W112_SUMMONSCOUT_STATE or {}\n"
        "local SS = W112_SUMMONSCOUT_STATE\n"
        + "\n".join(defaults)
    )
    return text[:a] + replacement + text[b:]


def transform_core(data: bytes) -> bytes:
    s = _text(data)
    s = _persistent_state(s)

    s = _one(
        s,
        "local GUI = {}\nlocal guiRefresh",
        "W112_SUMMONSCOUT_GUI = W112_SUMMONSCOUT_GUI or {}\n"
        "local GUI = W112_SUMMONSCOUT_GUI\nlocal guiRefresh",
        "persistent GUI registry",
    )

    s = _one(
        s,
        'local frame = CreateFrame("Frame", "SummonScoutFrame")\n',
        'local frame = SummonScoutFrame\n'
        'local hotReload = frame ~= nil\n'
        'if not frame then frame = CreateFrame("Frame", "SummonScoutFrame") end\n',
        "reuse core frame",
    )

    # Once Ritual has actually started, a transient party/raid roster rebuild
    # must not retire the active customer. Native/event start evidence is
    # resolved first; STOP/FAILED/INTERRUPTED plus the existing completion
    # watchdog remain the only authorities after start.
    active_before_roster = (
        '    local name = SS.summonActiveName\n'
        '    if not isInGroup(name) then\n'
        '        if (t - (SS.summonActiveQueuedAt or t)) < 5 then return end\n'
        '        if SummonScoutDB.masterReportLifecycle then\n'
        '            reportMaster("SUMMON FAIL", name .. " - left party/raid before cast")\n'
        '        end\n'
        '        finishActiveSummon(name)\n'
        '        return\n'
        '    end\n'
        '\n'
        '    -- Shared slave workers can legitimately be leased to another summoner first.\n'
        '    -- Keep this customer alive long enough for FIFO coordinator arbitration +\n'
        '    -- a full 30s character-switch preparation window.\n'
        '    if (t - (SS.summonActiveQueuedAt or t)) > 180 then\n'
        '        chat("summon watchdog dropped -> " .. name)\n'
        '        if SummonScoutDB.masterReportLifecycle then\n'
        '            reportMaster("SUMMON FAIL", name .. " - transaction watchdog timeout")\n'
        '        end\n'
        '        finishActiveSummon(name)\n'
        '        return\n'
        '    end\n'
        '\n'
        '    local nativeStatus, ackSeq, startedSeq = nativeSummonStatus()\n'
        '    local requestSeq = trim(tostring(SS.summonActiveRequestSeq or ""))\n'
        '\n'
        '    if requestSeq ~= "" and startedSeq == requestSeq then\n'
        '        markActiveSummonStarted("native")\n'
        '    end\n'
        '\n'
        '    if SS.summonActiveStarted then\n'
        '        if t >= (SS.summonActiveExpires or 0) then\n'
        '            if SummonScoutDB.debug then chat("summon completion watchdog -> " .. name) end\n'
        '            if SummonScoutDB.masterReportLifecycle then\n'
        '                reportMaster("SUMMON OK", name .. " -> " .. summonDestinationLabel())\n'
        '            end\n'
        '            finishActiveSummon(name)\n'
        '        end\n'
        '        return\n'
        '    end\n'
    )
    active_after_roster = (
        '    local name = SS.summonActiveName\n'
        '    local nativeStatus, ackSeq, startedSeq = nativeSummonStatus()\n'
        '    local requestSeq = trim(tostring(SS.summonActiveRequestSeq or ""))\n'
        '\n'
        '    if requestSeq ~= "" and startedSeq == requestSeq then\n'
        '        markActiveSummonStarted("native")\n'
        '    end\n'
        '\n'
        '    -- A started Ritual owns this active target until cast completion,\n'
        '    -- interruption/failure retry, or the existing completion watchdog.\n'
        '    -- PARTY_MEMBERS_CHANGED/RAID_ROSTER_UPDATE can expose a transient\n'
        '    -- incomplete roster while another customer joins; ignore it here.\n'
        '    if SS.summonActiveStarted then\n'
        '        if t >= (SS.summonActiveExpires or 0) then\n'
        '            if SummonScoutDB.debug then chat("summon completion watchdog -> " .. name) end\n'
        '            if SummonScoutDB.masterReportLifecycle then\n'
        '                reportMaster("SUMMON OK", name .. " -> " .. summonDestinationLabel())\n'
        '            end\n'
        '            finishActiveSummon(name)\n'
        '        end\n'
        '        return\n'
        '    end\n'
        '\n'
        '    if not isInGroup(name) then\n'
        '        if (t - (SS.summonActiveQueuedAt or t)) < 5 then return end\n'
        '        if SummonScoutDB.masterReportLifecycle then\n'
        '            reportMaster("SUMMON FAIL", name .. " - left party/raid before cast")\n'
        '        end\n'
        '        finishActiveSummon(name)\n'
        '        return\n'
        '    end\n'
        '\n'
        '    -- Shared slave workers can legitimately be leased to another summoner first.\n'
        '    -- Keep this customer alive long enough for FIFO coordinator arbitration +\n'
        '    -- a full 30s character-switch preparation window.\n'
        '    if (t - (SS.summonActiveQueuedAt or t)) > 180 then\n'
        '        chat("summon watchdog dropped -> " .. name)\n'
        '        if SummonScoutDB.masterReportLifecycle then\n'
        '            reportMaster("SUMMON FAIL", name .. " - transaction watchdog timeout")\n'
        '        end\n'
        '        finishActiveSummon(name)\n'
        '        return\n'
        '    end\n'
    )
    s = _one(s, active_before_roster, active_after_roster, "active summon before roster guard")

    event_anchor = (
        "    handleChannelMessage = handleChannelMessage,\n"
        "}\n\n"
        'frame:SetScript("OnEvent", function()\n'
    )
    event_rebind = (
        "    handleChannelMessage = handleChannelMessage,\n"
        "}\n\n"
        "-- PLAYER_LOGIN is not fired by an in-world hot execution. Re-apply\n"
        "-- defaults/migrations only for a real hot generation before scripts swap.\n"
        "if hotReload then EventAPI.setDefaults() end\n\n"
        'frame:SetScript("OnEvent", function()\n'
    )
    s = _one(s, event_anchor, event_rebind, "hot defaults before script swap")

    slash = (
        'SLASH_SUMMONSCOUT1 = "/ssi"\n'
        'SLASH_SUMMONSCOUT2 = "/summonscout"\n'
        'SlashCmdList["SUMMONSCOUT"] = slash\n'
    )
    marker = slash + (
        "\nW112_SUMMONSCOUT_CORE_GENERATION = "
        "(tonumber(W112_SUMMONSCOUT_CORE_GENERATION) or 0) + 1\n"
        "W112_SUMMONSCOUT_CORE_VERSION = ADDON_VERSION\n"
        "if W112_SUMMONSCOUT_CORE_GENERATION > 1 and DEFAULT_CHAT_FRAME then\n"
        '    DEFAULT_CHAT_FRAME:AddMessage("|cff66ff66SummonScout hot:|r core -> v"\n'
        '        .. ADDON_VERSION .. " gen " .. tostring(W112_SUMMONSCOUT_CORE_GENERATION))\n'
        "end\n"
    )
    s = _one(s, slash, marker, "core generation marker")
    return s.encode("utf-8")


def append_timing_module(data: bytes) -> bytes:
    if not TIMING_SOURCE.is_file():
        raise RuntimeError("SummonScout hot transform: timing module source missing")
    timing = TIMING_SOURCE.read_bytes()
    if TIMING_MARKER not in timing:
        raise RuntimeError("SummonScout hot transform: timing module marker missing")
    if TIMING_MARKER in data:
        raise RuntimeError("SummonScout hot transform: timing module already appended")
    return data.rstrip(b"\r\n") + b"\n\n-- Packaged hot timing module follows.\n" + timing


def transform_file(name: str, data: bytes) -> bytes:
    if name == CORE_NAME:
        return transform_core(data)
    if name == TIMING_HOST_NAME:
        return append_timing_module(data)
    return data
