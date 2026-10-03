#!/usr/bin/env python3
"""Deterministic delivery transform for the SummonScout hot-reload runtime.

Canonical addon logic remains under src/AddOns/SummonScout.  The parallel addon
packager calls this adapter for the two legacy Lua files that were originally
written as one-shot cold-load chunks.  The transform is intentionally
fail-closed: every structural anchor must match exactly once, otherwise the
candidate build stops rather than shipping a partially hot-safe runtime.
"""
from __future__ import annotations

import re

CORE_NAME = "SummonScout.lua"
WHISPER_NAME = "SummonScout_WhisperConfirmSpam.lua"
HOT_CORE_VERSION = "1.60-hot1"
HOT_WHISPER_VERSION = "2-hot1"
DEFAULT_SERVICE_SPEC = "hyjal,hydraxian,winterspring"


def _text(data: bytes) -> str:
    return data.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")


def _one(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"SummonScout hot transform anchor {label!r}: expected 1 match, got {count}")
    return text.replace(old, new, 1)


def _between(text: str, start: str, end: str, replacement: str, label: str) -> str:
    a = text.find(start)
    if a < 0:
        raise RuntimeError(f"SummonScout hot transform missing start anchor: {label}")
    b = text.find(end, a)
    if b < 0:
        raise RuntimeError(f"SummonScout hot transform missing end anchor: {label}")
    b += len(end)
    if text.find(start, b) >= 0:
        raise RuntimeError(f"SummonScout hot transform ambiguous start anchor: {label}")
    return text[:a] + replacement + text[b:]


def transform_core(data: bytes) -> bytes:
    s = _text(data)
    versions = re.findall(r'local ADDON_VERSION = "([^"]+)"', s)
    if len(versions) != 1:
        raise RuntimeError(f"SummonScout core version anchor count={len(versions)}")
    s = re.sub(
        r'local ADDON_VERSION = "[^"]+"',
        f'local ADDON_VERSION = "{HOT_CORE_VERSION}"\n'
        f'local DEFAULT_SERVICE_SPEC = "{DEFAULT_SERVICE_SPEC}"\n'
        'local SERVICE_PROFILE_VERSION = 3',
        s,
        count=1,
    )

    state = '''-- Runtime state survives hot code replacement.  Code generations replace\n-- functions and scripts, not operational queues/trade/summon state.\nW112_SUMMONSCOUT_STATE = W112_SUMMONSCOUT_STATE or {}\nlocal SS = W112_SUMMONSCOUT_STATE\nlocal function ssDefault(key, value)\n    if SS[key] == nil then SS[key] = value end\nend\nssDefault("queue", {})\nssDefault("queued", {})\nssDefault("recent", {})\nssDefault("loggedRecent", {})\nssDefault("nextInviteAt", 0)\nssDefault("nextSpamAt", 0)\nssDefault("counterAt", 0)\nssDefault("lastCounterAt", -100000)\nssDefault("lastInvitedAt", 0)\nssDefault("tradeMoneyBefore", 0)\nssDefault("tradeTargetMoney", 0)\nssDefault("tradeBothAccepted", false)\nssDefault("tradeActive", false)\nssDefault("nextGuiRefreshAt", 0)\nssDefault("partyKnown", {})\nssDefault("partyRosterReady", false)\nssDefault("partySyncAt", 0)\nssDefault("nextRosterPollAt", 0)\nssDefault("summonPending", {})\nssDefault("summonActiveQueuedAt", 0)\nssDefault("summonActiveAttempts", 0)\nssDefault("summonActiveNextAt", 0)\nssDefault("summonActiveExpires", 0)\nssDefault("summonActiveStarted", false)\nssDefault("summonActiveStartReported", false)\nssDefault("summonWhisperRecent", {})\nssDefault("whisperInviteRecent", {})\nssDefault("pendingManualInvites", {})\nssDefault("lastAdvertMessage", "")\nssDefault("lastAdvertSentAt", -100000)\nssDefault("lastSummonRequestAt", -100000)\nssDefault("lastSummonError", "")\nssDefault("summonRequestSeq", 0)\nssDefault("shardGuardPaused", false)\nssDefault("shardGuardLastCount", -1)\nssDefault("shardGuardNextCheckAt", 0)\nssDefault("loginRecoveryArmed", false)\nssDefault("loginRecoveryUntil", 0)\nssDefault("loginRecoveryDetectUntil", 0)\nssDefault("loginRecoveryAttempted", false)\nssDefault("loginRecoveryAcked", false)\nssDefault("loginRecoveryPasses", 0)\nssDefault("loginRecoveryRequestSeq", 0)\nssDefault("loginRecoveryAwaitingAck", false)\nssDefault("loginRecoveryCancelPending", false)\nssDefault("loginRecoveryCancelAttempts", 0)\nssDefault("loginRecoveryNextActionAt", 0)\nssDefault("loginRecoveryReported", false)'''
    s = _between(
        s,
        "local SS = {}",
        "SS.loginRecoveryReported = false",
        state,
        "persistent core state",
    )

    s = _one(
        s,
        '    { id="everlook", label="Everlook", aliases={"everlook"} },\n',
        "",
        "remove Everlook duplicate location",
    )
    s = _one(
        s,
        '    { id="winterspring", label="Winterspring", aliases={"winterspring"} },',
        '    { id="winterspring", label="Winterspring / Everlook", aliases={"winterspring", "everlook"} },',
        "Winterspring/Everlook native alias",
    )

    s = _one(
        s,
        "local GUI = {}\nlocal guiRefresh",
        "W112_SUMMONSCOUT_GUI = W112_SUMMONSCOUT_GUI or {}\nlocal GUI = W112_SUMMONSCOUT_GUI\nlocal guiRefresh",
        "persistent GUI state",
    )

    service_old = '''    if SummonScoutDB.service == nil then SummonScoutDB.service = "all" end\n    local canonicalService = resolveServiceSpec(SummonScoutDB.service)\n    if canonicalService then SummonScoutDB.service = canonicalService else SummonScoutDB.service = "all" end\n'''
    service_new = '''    if SummonScoutDB.serviceProfileVersion == nil\n        or (tonumber(SummonScoutDB.serviceProfileVersion) or 0) < SERVICE_PROFILE_VERSION then\n        SummonScoutDB.service = DEFAULT_SERVICE_SPEC\n        SummonScoutDB.serviceProfileVersion = SERVICE_PROFILE_VERSION\n    end\n    if SummonScoutDB.service == nil then SummonScoutDB.service = DEFAULT_SERVICE_SPEC end\n    local canonicalService = resolveServiceSpec(SummonScoutDB.service)\n    if canonicalService then\n        SummonScoutDB.service = canonicalService\n    else\n        SummonScoutDB.service = DEFAULT_SERVICE_SPEC\n    end\n'''
    s = _one(s, service_old, service_new, "three-location service profile")

    s = _one(
        s,
        'local frame = CreateFrame("Frame", "SummonScoutFrame")\n',
        'local frame = SummonScoutFrame\nif not frame then frame = CreateFrame("Frame", "SummonScoutFrame") end\n',
        "reuse core frame",
    )

    eventapi_old = '''    handleChannelMessage = handleChannelMessage,\n}\n\nframe:SetScript("OnEvent", function()\n'''
    eventapi_new = '''    handleChannelMessage = handleChannelMessage,\n}\n\n-- Hot execution does not receive PLAYER_LOGIN, so apply defaults/migrations\n-- before replacing the live frame scripts.\nEventAPI.setDefaults()\n\nframe:SetScript("OnEvent", function()\n'''
    s = _one(s, eventapi_old, eventapi_new, "hot defaults before script swap")

    slash = '''SLASH_SUMMONSCOUT1 = "/ssi"\nSLASH_SUMMONSCOUT2 = "/summonscout"\nSlashCmdList["SUMMONSCOUT"] = slash\n'''
    slash_hot = slash + '''\nW112_SUMMONSCOUT_CORE_GENERATION = (tonumber(W112_SUMMONSCOUT_CORE_GENERATION) or 0) + 1\nW112_SUMMONSCOUT_CORE_VERSION = ADDON_VERSION\nif W112_SUMMONSCOUT_CORE_GENERATION > 1 then\n    chat("hot core -> v" .. ADDON_VERSION .. " gen " .. tostring(W112_SUMMONSCOUT_CORE_GENERATION))\nend\n'''
    s = _one(s, slash, slash_hot, "core generation marker")
    return s.encode("utf-8")


def transform_whisper(data: bytes) -> bytes:
    s = _text(data)
    s, count = re.subn(
        r'local WC_VERSION = "[^"]+"',
        f'local WC_VERSION = "{HOT_WHISPER_VERSION}"',
        s,
        count=1,
    )
    if count != 1:
        raise RuntimeError(f"SummonScout whisper version anchor count={count}")
    s = _one(
        s,
        "local WC_STARTUP_SPAM_MAX = 400\n",
        "local WC_STARTUP_SPAM_MAX = 400\nlocal WC_CODE_TOKEN = {}\n",
        "whisper code token",
    )

    persistent = '''W112_SUMMONSCOUT_WC_STATE = W112_SUMMONSCOUT_WC_STATE or {}\nlocal WC = W112_SUMMONSCOUT_WC_STATE\nlocal function wcDefault(key, value)\n    if WC[key] == nil then WC[key] = value end\nend\nwcDefault("pending", {})\nwcDefault("candidates", {})\nwcDefault("confirmations", {})\nwcDefault("probedAt", {})\nwcDefault("inviteIssuedAt", {})\nwcDefault("inviteWrapped", false)\nwcDefault("startupSpamScheduled", false)\nwcDefault("startupSpamDelay", 0)\nwcDefault("guiAttached", false)\nwcDefault("nextGuiRefreshAt", 0)'''
    s = _between(
        s,
        "local WC = {",
        "}\n\nlocal POSITIVE",
        persistent + "\n\nlocal POSITIVE",
        "persistent whisper state",
    )

    s = _one(s, '    everlook = "Everlook",', '    everlook = "Winterspring",', "Everlook service label")

    observer = '''local function wcInstallInviteObserver()\n    if WC.wrapperToken == WC_CODE_TOKEN\n        and WC.currentInviteWrapper\n        and InviteByName == WC.currentInviteWrapper then\n        return\n    end\n\n    if type(W112_SUMMONSCOUT_BASE_INVITE_BY_NAME) ~= "function" then\n        if type(InviteByName) ~= "function" then return end\n        W112_SUMMONSCOUT_BASE_INVITE_BY_NAME = InviteByName\n    end\n\n    local base = W112_SUMMONSCOUT_BASE_INVITE_BY_NAME\n    local wrapper = function(name)\n        local key = wcKey(name)\n        if key ~= "" then WC.inviteIssuedAt[key] = wcNow() end\n        return base(name)\n    end\n    WC.originalInviteByName = base\n    WC.currentInviteWrapper = wrapper\n    WC.wrapperToken = WC_CODE_TOKEN\n    WC.inviteWrapped = true\n    InviteByName = wrapper\nend'''
    s = _between(
        s,
        "local function wcInstallInviteObserver()",
        "end\n\nlocal function wcSendProbe",
        observer + "\n\nlocal function wcSendProbe",
        "non-stacking InviteByName observer",
    )

    gui = '''local function wcAttachGui()\n    if not SummonScoutOptionsFrame or not SummonScoutOptionsFrame.CreateFontString then return end\n    local parent = SummonScoutOptionsFrame\n    local edit = WC.intervalEdit\n    if not edit and getglobal then edit = getglobal("SummonScoutAdvertIntervalEdit") end\n\n    if not edit then\n        local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")\n        label:SetPoint("TOPLEFT", parent, "TOPLEFT", 28, -421)\n        label:SetText("Advert every:")\n\n        edit = CreateFrame("EditBox", "SummonScoutAdvertIntervalEdit", parent, "InputBoxTemplate")\n        edit:SetPoint("TOPLEFT", parent, "TOPLEFT", 100, -413)\n        edit:SetWidth(52)\n        edit:SetHeight(22)\n        edit:SetAutoFocus(false)\n        edit:SetMaxLetters(4)\n        edit:SetText(tostring(wcClampSpamInterval(SummonScoutDB.spamInterval)))\n        edit.ssFocused = false\n\n        local secondsLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")\n        secondsLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 157, -421)\n        secondsLabel:SetText("sec")\n    end\n\n    edit:SetScript("OnEditFocusGained", function() edit.ssFocused = true end)\n    edit:SetScript("OnEditFocusLost", function() edit.ssFocused = false end)\n    edit:SetScript("OnEscapePressed", function() edit:ClearFocus() end)\n    edit:SetScript("OnEnterPressed", function() wcSaveInterval(); edit:ClearFocus() end)\n\n    local button\n    if getglobal then button = getglobal("SummonScoutAdvertIntervalSet") end\n    if not button then\n        button = CreateFrame("Button", "SummonScoutAdvertIntervalSet", parent, "UIPanelButtonTemplate")\n        button:SetPoint("TOPLEFT", parent, "TOPLEFT", 184, -413)\n        button:SetWidth(46)\n        button:SetHeight(22)\n        button:SetText("Set")\n    end\n    button:SetScript("OnClick", wcSaveInterval)\n\n    WC.intervalEdit = edit\n    WC.guiAttached = true\nend'''
    s = _between(
        s,
        "local function wcAttachGui()",
        "end\n\nlocal function wcRefreshGui",
        gui + "\n\nlocal function wcRefreshGui",
        "idempotent whisper GUI",
    )

    s = _one(
        s,
        'local frame = CreateFrame("Frame", "SummonScoutWhisperConfirmSpamFrame")\n',
        'local frame = SummonScoutWhisperConfirmSpamFrame\nif not frame then frame = CreateFrame("Frame", "SummonScoutWhisperConfirmSpamFrame") end\n',
        "reuse whisper frame",
    )
    s = _one(
        s,
        'frame:RegisterEvent("PLAYER_LOGIN")\nframe:RegisterEvent("CHAT_MSG_WHISPER")\nframe:SetScript("OnEvent", function()\n',
        'frame:RegisterEvent("PLAYER_LOGIN")\nframe:RegisterEvent("CHAT_MSG_WHISPER")\nwcInstallInviteObserver()\nW112_SUMMONSCOUT_WHISPER_CONFIRM_SPAM_VERSION = WC_VERSION\nframe:SetScript("OnEvent", function()\n',
        "immediate whisper rebind",
    )
    s += '''\nW112_SUMMONSCOUT_WC_GENERATION = (tonumber(W112_SUMMONSCOUT_WC_GENERATION) or 0) + 1\nif W112_SUMMONSCOUT_WC_GENERATION > 1 and DEFAULT_CHAT_FRAME then\n    DEFAULT_CHAT_FRAME:AddMessage("|cff66ff66SummonScout hot:|r whisper -> v"\n        .. WC_VERSION .. " gen " .. tostring(W112_SUMMONSCOUT_WC_GENERATION))\nend\n'''
    return s.encode("utf-8")


def transform_file(name: str, data: bytes) -> bytes:
    if name == CORE_NAME:
        return transform_core(data)
    if name == WHISPER_NAME:
        return transform_whisper(data)
    return data
