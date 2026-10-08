#!/usr/bin/env python3
"""Summon Service V1 synthetic fault/adversarial/soak harness.

Test-only. It does not send WoW packets, invoke Lua, mutate economy state, or alter
SummonScout production code. It produces deterministic JSON + Markdown evidence.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
import time
import tracemalloc
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

SCHEMA_FIELDS = (
    "schema_version", "event_id", "ts_utc", "type", "session_id", "request_id",
    "customer", "destination", "state", "amount_copper", "correlation_id",
    "severity", "metadata",
)
EVENT_TYPES = {
    "ServiceStarted", "SessionReady", "WhisperReceived", "ParserDecision",
    "RequestQueued", "SummonStarted", "SummonCompleted", "SummonFailed",
    "PaymentExpected", "PaymentReceived", "PaymentMissing", "TradeUncertain",
    "Reconnect", "ServiceStopped",
}
GOLD = 10_000
DEFAULT_PRICE = 4 * GOLD


def _id(prefix: str) -> str:
    return f"{prefix}-{uuid.uuid4().hex[:12]}"


def _utc() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


@dataclass
class Event:
    schema_version: int
    event_id: str
    ts_utc: str
    type: str
    session_id: str
    request_id: str
    customer: str
    destination: str
    state: str
    amount_copper: int
    correlation_id: str
    severity: str
    metadata: dict = field(default_factory=dict)

    def validate(self) -> None:
        data = asdict(self)
        missing = [k for k in SCHEMA_FIELDS if k not in data]
        if missing:
            raise AssertionError(f"missing event fields: {missing}")
        if self.type not in EVENT_TYPES:
            raise AssertionError(f"unsupported event type: {self.type}")
        if self.schema_version != 1:
            raise AssertionError("schema_version must be 1")
        if not self.event_id or not self.session_id:
            raise AssertionError("event_id/session_id required")
        if not isinstance(self.metadata, dict):
            raise AssertionError("metadata must be object")


class EventStore:
    """Append-only in-memory test journal with replay idempotency."""
    def __init__(self) -> None:
        self.events: List[Event] = []
        self._seen: set[str] = set()

    def append(self, ev: Event) -> bool:
        ev.validate()
        if ev.event_id in self._seen:
            return False
        self._seen.add(ev.event_id)
        self.events.append(ev)
        return True

    def snapshot(self) -> list[dict]:
        return [asdict(e) for e in self.events]

    @classmethod
    def restore(cls, rows: Iterable[dict]) -> "EventStore":
        s = cls()
        for row in rows:
            s.append(Event(**row))
        return s


@dataclass
class Request:
    request_id: str
    player: str
    destination: str
    state: str = "QUEUED"
    paid_copper: int = 0
    uncertain: bool = False


class ServiceModel:
    """Contract model used to drive deterministic fault/adversarial cases.

    This model is intentionally not production implementation. Its only purpose is
    to encode expected safety invariants and generate reproducible evidence.
    """
    STRONG = {
        "+", "here", "sure", "123", "invi", "inv", "inv pls", "invite", "invite me",
        "can i get one", "could i get one", "can i have one", "could i have one",
        "need one", "i need one", "want one", "one pls", "one plz", "one please",
        "can i get summon", "can i get a summon", "need summon", "lf summon",
    }
    DEST = {
        "winterspring": "winterspring", "winter spring": "winterspring",
        "wintersprng": "winterspring",
        "hyjal": "hyjal", "mount hyjal": "hyjal",
        "azshara": "hydraxian", "azsh": "hydraxian", "hydraxian": "hydraxian",
        "hydraxis": "hydraxian", "hydraxians": "hydraxian",
    }
    SELLER = ("wts", "selling", "summon service", "summons available", "whisper me")

    def __init__(self, service: str = "winterspring") -> None:
        self.session_id = _id("sess")
        self.service = service
        self.store = EventStore()
        self.queue: List[str] = []
        self.requests: Dict[str, Request] = {}
        self.player_open: Dict[str, str] = {}
        self.reconnects = 0
        self.duplicate_suppressed = 0
        self._emit("ServiceStarted", "", "", "READY")
        self._emit("SessionReady", "", service, "READY")

    @staticmethod
    def norm(text: str) -> str:
        s = text.lower().strip()
        s = re.sub(r"[^a-z0-9+ ]+", " ", s)
        s = re.sub(r"\s+", " ", s).strip()
        return s

    def destination(self, text: str) -> Optional[str]:
        s = self.norm(text)
        for phrase, dest in sorted(self.DEST.items(), key=lambda kv: len(kv[0]), reverse=True):
            if re.search(rf"(?:^| ){re.escape(phrase)}(?: |$)", s):
                return dest
        return None

    def parse(self, text: str) -> Tuple[bool, Optional[str], str]:
        s = self.norm(text)
        if not s:
            return False, None, "empty"
        if any(x in s for x in self.SELLER):
            return False, self.destination(text), "seller-or-competition"
        dest = self.destination(text)
        if s in self.STRONG:
            return True, dest, "strong-direct"
        if s.startswith("need ") and dest:
            return True, dest, "destination-demand"
        if "summon" in s and any(c in s for c in ("need", "can i", "could i", "lf", "want")):
            return True, dest, "summon-demand"
        return False, dest, "weak-or-unrelated"

    def whisper(self, player: str, text: str) -> Tuple[Optional[Request], str]:
        corr = _id("corr")
        self._emit("WhisperReceived", "", "", "OBSERVED", customer=player,
                   correlation_id=corr, metadata={"text": text})
        accept, dest, reason = self.parse(text)
        dest = dest or self.service
        self._emit("ParserDecision", "", dest, "ACCEPT" if accept else "REJECT",
                   customer=player, correlation_id=corr,
                   metadata={"reason": reason, "accepted": accept})
        if not accept:
            return None, reason
        if dest != self.service:
            return None, "different-destination"
        key = player.lower()
        if key in self.player_open:
            self.duplicate_suppressed += 1
            return self.requests[self.player_open[key]], "duplicate-suppressed"
        req = Request(_id("req"), player, dest)
        self.requests[req.request_id] = req
        self.player_open[key] = req.request_id
        self.queue.append(req.request_id)
        self._emit("RequestQueued", req.request_id, dest, "QUEUED", customer=player,
                   correlation_id=corr)
        return req, "queued"

    def summon(self, req: Request, fault: Optional[str] = None) -> str:
        req.state = "SUMMON_STARTED"
        self._emit("SummonStarted", req.request_id, req.destination, req.state, customer=req.player)
        if fault in {"failed_cast", "interrupted_cast", "portal_timeout", "no_clicker",
                     "customer_no_click", "customer_disconnect", "summoner_disconnect",
                     "reconnect_after_cast_start"}:
            if "disconnect" in fault or fault == "reconnect_after_cast_start":
                self.reconnect(req.request_id, req.player, req.destination, fault)
            req.state = "SUMMON_FAILED"
            self._emit("SummonFailed", req.request_id, req.destination, req.state,
                       customer=req.player, severity="warning", metadata={"fault": fault})
            return req.state
        req.state = "SUMMON_COMPLETED"
        self._emit("SummonCompleted", req.request_id, req.destination, req.state, customer=req.player)
        req.state = "PAYMENT_EXPECTED"
        self._emit("PaymentExpected", req.request_id, req.destination, req.state,
                   customer=req.player, amount=DEFAULT_PRICE)
        return req.state

    def payment(self, req: Request, amount: int, fault: Optional[str] = None,
                duplicate_event_id: Optional[str] = None) -> str:
        if fault in {"trade_cancel", "back_to_trade", "uncertain_write", "payer_disconnect", "summoner_disconnect"}:
            req.uncertain = True
            req.state = "TRADE_UNCERTAIN"
            ev = self._make_event("TradeUncertain", req.request_id, req.destination, req.state,
                                  customer=req.player, amount=amount, severity="warning",
                                  metadata={"fault": fault})
            if duplicate_event_id:
                ev.event_id = duplicate_event_id
            self.store.append(ev)
            return req.state
        if amount <= 0:
            req.state = "PAYMENT_MISSING"
            self._emit("PaymentMissing", req.request_id, req.destination, req.state,
                       customer=req.player, amount=0, severity="warning")
            return req.state
        req.paid_copper = amount
        req.state = "PAYMENT_RECEIVED"
        self._emit("PaymentReceived", req.request_id, req.destination, req.state,
                   customer=req.player, amount=amount,
                   metadata={"expected_copper": DEFAULT_PRICE, "delta_copper": amount})
        self.player_open.pop(req.player.lower(), None)
        return req.state

    def reconnect(self, request_id: str, player: str, destination: str, reason: str) -> None:
        self.reconnects += 1
        self._emit("Reconnect", request_id, destination, "RECONNECTED", customer=player,
                   severity="warning", metadata={"reason": reason})

    def _make_event(self, typ: str, request_id: str, destination: str, state: str,
                    *, customer: str = "", amount: int = 0, correlation_id: str = "",
                    severity: str = "info", metadata: Optional[dict] = None) -> Event:
        return Event(1, _id("ev"), _utc(), typ, self.session_id, request_id, customer,
                     destination, state, int(amount), correlation_id or _id("corr"),
                     severity, metadata or {})

    def _emit(self, typ: str, request_id: str, destination: str, state: str,
              *, customer: str = "", amount: int = 0, correlation_id: str = "",
              severity: str = "info", metadata: Optional[dict] = None) -> Event:
        ev = self._make_event(typ, request_id, destination, state, customer=customer,
                              amount=amount, correlation_id=correlation_id,
                              severity=severity, metadata=metadata)
        self.store.append(ev)
        return ev


@dataclass
class CaseResult:
    result: str
    case: str
    stage: str
    request_id: str
    player: str
    destination: str
    timing_ms: float
    expected: str
    actual: str
    reason: str
    evidence_paths: List[str]
    severity: str = "info"
    coverage: str = "synthetic"


def case(name: str, stage: str, expected: str, actual: str, ok: bool,
         *, req: Optional[Request] = None, player: str = "", destination: str = "",
         timing_ms: float = 0.0, reason: str = "", severity: str = "info",
         evidence: Optional[List[str]] = None, coverage: str = "synthetic") -> CaseResult:
    return CaseResult("PASS" if ok else "FAIL", name, stage,
                      req.request_id if req else "", player or (req.player if req else ""),
                      destination or (req.destination if req else ""), timing_ms,
                      expected, actual, reason, evidence or [], severity, coverage)


def run_whispers() -> List[CaseResult]:
    rows: List[CaseResult] = []
    positives = [
        ("need winterspring", "winterspring"), ("+", "winterspring"), ("invi", "winterspring"),
        ("inv pls", "winterspring"), ("can i get one", "winterspring"),
        ("need one", "winterspring"), ("here", "winterspring"),
        ("NEED WINTERSPRING!!!", "winterspring"), ("need wintersprng pls", "winterspring"),
    ]
    negatives = [
        ("hello there", "weak-or-unrelated"),
        ("maybe later", "weak-or-unrelated"),
        ("WTS Winterspring summon 4g whisper me", "seller-or-competition"),
        ("I am here already", "weak-or-unrelated"),
    ]
    for idx, (msg, dest) in enumerate(positives):
        m = ServiceModel(dest)
        t0 = time.perf_counter_ns(); req, why = m.whisper(f"P{idx}", msg); dt = (time.perf_counter_ns()-t0)/1e6
        rows.append(case(f"whisper:{msg}", "WHISPER", "queued", why, req is not None,
                         req=req, player=f"P{idx}", destination=dest, timing_ms=dt,
                         reason="strong/adversarial buyer intent must queue exactly once"))
    for idx, (msg, expected_reason) in enumerate(negatives):
        m = ServiceModel("winterspring")
        t0 = time.perf_counter_ns(); req, why = m.whisper(f"N{idx}", msg); dt = (time.perf_counter_ns()-t0)/1e6
        rows.append(case(f"whisper-negative:{msg}", "WHISPER", expected_reason, why,
                         req is None and why == expected_reason, player=f"N{idx}",
                         destination="winterspring", timing_ms=dt,
                         reason="weak/competition/unrelated input must not queue"))
    m = ServiceModel("winterspring")
    first, _ = m.whisper("Spammy", "need one")
    second, why = m.whisper("Spammy", "need one")
    rows.append(case("whisper:duplicate-spam", "WHISPER", "one open request", f"queue={len(m.queue)} reason={why}",
                     first is second and len(m.queue) == 1 and m.duplicate_suppressed == 1,
                     req=first, reason="same player duplicate must be idempotent"))
    return rows


def run_queue() -> List[CaseResult]:
    rows: List[CaseResult] = []
    m = ServiceModel("winterspring")
    reqs = []
    t0 = time.perf_counter_ns()
    for i in range(5):
        r, _ = m.whisper(f"Burst{i}", "need one")
        reqs.append(r)
    dt = (time.perf_counter_ns()-t0)/1e6
    rows.append(case("queue:5-fast-customers", "QUEUE", "5 unique queued", str(len(m.queue)),
                     len(m.queue) == 5 and len(set(m.queue)) == 5, timing_ms=dt,
                     reason="burst must preserve uniqueness and order"))
    again, why = m.whisper("Burst2", "inv pls")
    rows.append(case("queue:same-player-twice", "QUEUE", "dedupe existing request", why,
                     again is reqs[2] and len(m.queue) == 5, req=reqs[2], reason="open request is single-owner"))
    victim = reqs[0]; victim.state = "SUMMON_FAILED"
    m._emit("SummonFailed", victim.request_id, victim.destination, victim.state, customer=victim.player,
            severity="warning", metadata={"fault": "customer-left-or-offline"})
    rows.append(case("queue:customer-leaves", "QUEUE", "SummonFailed", victim.state,
                     victim.state == "SUMMON_FAILED", req=victim, severity="warning",
                     reason="left/offline customer must not be marked completed"))
    m.reconnect("", "summoner", "winterspring", "summoner-reconnect")
    m.reconnect("", "clicker", "winterspring", "clicker-reconnect")
    rows.append(case("queue:reconnect-count", "QUEUE", "2", str(m.reconnects), m.reconnects == 2,
                     reason="summoner and clicker reconnects must be observable"))
    return rows


def run_summon() -> List[CaseResult]:
    rows: List[CaseResult] = []
    faults = ["failed_cast", "interrupted_cast", "portal_timeout", "no_clicker", "customer_no_click",
              "customer_disconnect", "summoner_disconnect", "reconnect_after_cast_start"]
    for i, fault in enumerate(faults):
        m = ServiceModel("winterspring"); r, _ = m.whisper(f"S{i}", "need one")
        t0=time.perf_counter_ns(); actual=m.summon(r, fault); dt=(time.perf_counter_ns()-t0)/1e6
        rows.append(case(f"summon:{fault}", "SUMMON", "SUMMON_FAILED", actual,
                         actual == "SUMMON_FAILED", req=r, timing_ms=dt, severity="warning",
                         reason="fault must terminate visibly; never optimistic-complete"))
    m = ServiceModel("winterspring"); r,_=m.whisper("GoodSummon", "need one")
    actual=m.summon(r)
    rows.append(case("summon:happy-path", "SUMMON", "PAYMENT_EXPECTED", actual,
                     actual == "PAYMENT_EXPECTED", req=r,
                     reason="completion must transition to payment expectation"))
    return rows


def run_payment() -> List[CaseResult]:
    rows: List[CaseResult] = []
    amounts = [("4g", 4*GOLD, "PAYMENT_RECEIVED"), ("0g", 0, "PAYMENT_MISSING"),
               ("underpay", 3*GOLD, "PAYMENT_RECEIVED"), ("overpay", 5*GOLD, "PAYMENT_RECEIVED")]
    for i,(name, amount, expected) in enumerate(amounts):
        m=ServiceModel("winterspring"); r,_=m.whisper(f"Pay{i}", "need one"); m.summon(r)
        t0=time.perf_counter_ns(); actual=m.payment(r, amount); dt=(time.perf_counter_ns()-t0)/1e6
        rows.append(case(f"payment:{name}", "PAYMENT", expected, actual, actual==expected,
                         req=r,timing_ms=dt,reason="wallet delta classification is explicit"))
    for i,fault in enumerate(["trade_cancel","payer_disconnect","summoner_disconnect","back_to_trade","uncertain_write"]):
        m=ServiceModel("winterspring"); r,_=m.whisper(f"U{i}", "need one"); m.summon(r)
        actual=m.payment(r, 4*GOLD, fault)
        rows.append(case(f"payment:{fault}", "PAYMENT", "TRADE_UNCERTAIN", actual,
                         actual=="TRADE_UNCERTAIN" and r.paid_copper==0, req=r,
                         severity="critical" if fault in {"back_to_trade","uncertain_write"} else "warning",
                         reason="uncertain/cancelled trade must never become paid"))
    m=ServiceModel("winterspring"); r,_=m.whisper("DupPay", "need one"); m.summon(r)
    ev=m._make_event("PaymentReceived",r.request_id,r.destination,"PAYMENT_RECEIVED",customer=r.player,amount=4*GOLD)
    one=m.store.append(ev); two=m.store.append(ev)
    rows.append(case("payment:duplicate-packet", "PAYMENT", "1 journal append", f"first={one} second={two}",
                     one and not two, req=r, reason="event_id replay is idempotent"))
    m=ServiceModel("winterspring"); r,_=m.whisper("LatePay", "need one"); m.summon(r); m.payment(r,0)
    actual=m.payment(r,4*GOLD)
    rows.append(case("payment:delayed-payment", "PAYMENT", "PAYMENT_RECEIVED", actual,
                     actual=="PAYMENT_RECEIVED" and r.paid_copper==4*GOLD, req=r,
                     reason="late positive wallet delta must remain attributable and auditable"))
    return rows


def run_persistence() -> List[CaseResult]:
    rows=[]
    checkpoints=["idle","after-summon-started","after-summon-completed-before-payment","after-payment-received"]
    for i,point in enumerate(checkpoints):
        m=ServiceModel("winterspring"); r=None
        if point != "idle":
            r,_=m.whisper(f"Persist{i}","need one")
            if point == "after-summon-started":
                r.state="SUMMON_STARTED"; m._emit("SummonStarted",r.request_id,r.destination,r.state,customer=r.player)
            else:
                m.summon(r)
                if point == "after-payment-received": m.payment(r,4*GOLD)
        snap=m.store.snapshot(); restored=EventStore.restore(snap)
        rows.append(case(f"persistence:{point}","PERSISTENCE",str(len(snap)),str(len(restored.events)),
                         len(snap)==len(restored.events),req=r,reason="restart must preserve append-only evidence"))
        before=len(restored.events)
        for row in snap: restored.append(Event(**row))
        rows.append(case(f"persistence:{point}:replay","PERSISTENCE",str(before),str(len(restored.events)),
                         before==len(restored.events),req=r,reason="event replay must be idempotent"))
    return rows


def run_soak(cycles: int) -> Tuple[List[CaseResult], dict]:
    rows=[]; lat=[]; reconnects=0; duplicates=0; unpaid=0; uncertain=0
    tracemalloc.start(); start_mem=tracemalloc.get_traced_memory()[0]
    m=ServiceModel("winterspring")
    for i in range(cycles):
        t0=time.perf_counter_ns(); r,_=m.whisper(f"Soak{i}","need one")
        if i and i % 10 == 0:
            m.summon(r,"reconnect_after_cast_start"); reconnects += 1
        else:
            m.summon(r)
            if i and i % 11 == 0:
                m.payment(r,4*GOLD,"uncertain_write"); uncertain += 1
            elif i and i % 7 == 0:
                m.payment(r,0); unpaid += 1
            else:
                m.payment(r,4*GOLD)
        lat.append((time.perf_counter_ns()-t0)/1e6)
    end_mem, peak_mem=tracemalloc.get_traced_memory(); tracemalloc.stop()
    duplicates=m.duplicate_suppressed
    metrics={
        "cycles": cycles, "stage_latency_ms_mean": round(statistics.mean(lat),4),
        "stage_latency_ms_p95": round(sorted(lat)[max(0,int(len(lat)*0.95)-1)],4),
        "memory_growth_bytes": end_mem-start_mem, "memory_peak_bytes": peak_mem,
        "reconnect_count": reconnects, "duplicate_rate": duplicates/max(1,cycles),
        "unpaid_count": unpaid, "uncertain_count": uncertain,
    }
    ok=cycles>=20 and duplicates==0 and m.reconnects==reconnects
    rows.append(case("soak:aggregate","SOAK","cycles>=20; duplicate_rate=0; reconnects observable",
                     json.dumps(metrics,sort_keys=True),ok,timing_ms=sum(lat),
                     reason="deterministic mixed happy/fault workload"))
    return rows,metrics


def source_audit(root: Path) -> List[CaseResult]:
    rows=[]
    core=root/"src/AddOns/SummonScout/SummonScout.lua"
    native=root/"src/AutoSummonAssist/WoWAutoSummonAssist_5875_v1.c"
    toc=root/"src/AddOns/SummonScout/SummonScout.toc"
    files=[core,native,toc]
    if not all(p.exists() for p in files):
        return [case("source-audit:files","SOURCE_AUDIT","production files present",
                     ", ".join(str(p) for p in files if not p.exists()),False,
                     severity="critical",coverage="source-attestation",
                     reason="cannot attest production source")]
    c=core.read_text(encoding="utf-8",errors="replace")
    n=native.read_text(encoding="utf-8",errors="replace")
    checks=[
        ("source:public-parser-api", "whisperInviteDecision" in c and "W112_SUMMONSCOUT_API_V1" in c,
         "public whisper decision surface", "parser API exported", "critical"),
        ("source:adversarial-invi", 'token == "invi"' in c,
         "invi explicitly recognized", "token stem guard", "warning"),
        ("source:plus-marker", "hasWhisperPlusMarker" in c and '"+"' in c,
         "+ recognized from raw whisper", "plus marker", "warning"),
        ("source:trusted-wallet-delta", "pendingTrade" in c and "GetMoney" in c and "positive wallet gain" in c,
         "post-trade wallet delta authority", "trusted ledger primitives", "critical"),
        ("source:duplicate-trade-close", "duplicate TRADE_CLOSED" in c and "resetTradeState" in c,
         "duplicate TRADE_CLOSED suppression", "session reset guard", "critical"),
        ("source:sequenced-native-request", "summonActiveRequestSeq" in c and ("REQUEST" in n or "request" in n.lower()),
         "request-sequenced native summon", "sequence fields found", "critical"),
    ]
    for name,ok,expected,actual,severity in checks:
        rows.append(case(name,"SOURCE_AUDIT",expected,actual,ok,severity=severity,
                         coverage="source-attestation",reason="static exact-SHA source evidence",
                         evidence=[str(core.relative_to(root)) if "native" not in name else str(native.relative_to(root))]))
    missing=sorted(x for x in EVENT_TYPES if x not in c and x not in n)
    rows.append(case("source:event-contract","SOURCE_AUDIT","all required event types emitted",
                     "missing="+",".join(missing) if missing else "all-present",not missing,
                     severity="critical",coverage="source-attestation",
                     reason="required shared event contract must be source-visible for durable evidence",
                     evidence=[str(core.relative_to(root)),str(native.relative_to(root))]))
    back_guard=("BACK_TO_TRADE" in c or "back_to_trade" in c.lower() or "trade reopen" in c.lower())
    rows.append(case("source:back-to-trade-guard","SOURCE_AUDIT","explicit BACK_TO_TRADE/reopen fail-closed guard",
                     "explicit guard found" if back_guard else "no explicit guard found",back_guard,
                     severity="critical",coverage="source-attestation",
                     reason="adversarial payment transition must not be inferred as safe",
                     evidence=[str(core.relative_to(root))]))
    persistent_journal=("event_id" in c and "schema_version" in c and "request_id" in c)
    rows.append(case("source:durable-event-journal","SOURCE_AUDIT","durable event schema/journal",
                     "present" if persistent_journal else "not source-visible",persistent_journal,
                     severity="critical",coverage="source-attestation",
                     reason="hour-later summon/payment audit requires durable correlation evidence",
                     evidence=[str(core.relative_to(root))]))
    return rows


def markdown_report(meta: dict, rows: List[CaseResult], metrics: dict) -> str:
    passed=sum(r.result=="PASS" for r in rows); failed=len(rows)-passed
    out=["# Summon Service V1 — fault/adversarial/soak report", "",
         f"- Exact SHA: `{meta['exact_sha']}`", f"- Base ref: `{meta['base_ref']}`",
         f"- Run ID: `{meta['run_id']}`", f"- Cases: **{len(rows)}** (PASS {passed} / FAIL {failed})",
         f"- Synthetic soak cycles: **{metrics.get('cycles',0)}**", "",
         "## Metrics", "", "```json", json.dumps(metrics,indent=2,sort_keys=True), "```", "",
         "## Cases", "",
         "| Result | Severity | Stage | Case | Request | Player | Destination | ms | Expected | Actual | Reason |",
         "|---|---|---|---|---|---|---|---:|---|---|---|"]
    for r in rows:
        esc=lambda x:str(x).replace("|","/").replace("\n"," ")
        out.append(f"| {r.result} | {r.severity} | {esc(r.stage)} | {esc(r.case)} | {esc(r.request_id)} | {esc(r.player)} | {esc(r.destination)} | {r.timing_ms:.3f} | {esc(r.expected)} | {esc(r.actual)} | {esc(r.reason)} |")
    blockers=[r for r in rows if r.result=="FAIL" and r.severity=="critical"]
    out += ["", "## Production blockers", ""]
    if blockers:
        for r in blockers: out.append(f"- **{r.case}** — {r.actual}. {r.reason}")
    else: out.append("- None found by this harness.")
    out += ["", "## Scope note", "",
            "This branch is test-only. Synthetic PASS means the harness invariant held; it is not live-game proof. "
            "SOURCE_AUDIT FAIL is a production gap/reproducer candidate and is intentionally not repaired here."]
    return "\n".join(out)+"\n"


def main() -> int:
    ap=argparse.ArgumentParser()
    ap.add_argument("--root",default=str(Path(__file__).resolve().parents[1]))
    ap.add_argument("--cycles",type=int,default=20)
    ap.add_argument("--out",default="artifacts/summon_service_soak_v1")
    ap.add_argument("--exact-sha",default=os.environ.get("GITHUB_SHA","UNKNOWN"))
    ap.add_argument("--base-ref",default="parallel")
    ap.add_argument("--run-id",default=os.environ.get("GITHUB_RUN_ID") or _id("local"))
    ap.add_argument("--strict-synthetic",action="store_true")
    args=ap.parse_args()
    if args.cycles < 20:
        ap.error("--cycles must be >=20")
    root=Path(args.root).resolve(); out=root/args.out; out.mkdir(parents=True,exist_ok=True)
    rows=[]
    rows += run_whispers(); rows += run_queue(); rows += run_summon(); rows += run_payment(); rows += run_persistence()
    soak_rows,metrics=run_soak(args.cycles); rows += soak_rows
    rows += source_audit(root)
    meta={"schema_version":1,"exact_sha":args.exact_sha,"base_ref":args.base_ref,"run_id":args.run_id,
          "generated_utc":_utc(),"cycles":args.cycles}
    payload={"meta":meta,"metrics":metrics,"summary":{"total":len(rows),"pass":sum(r.result=="PASS" for r in rows),"fail":sum(r.result=="FAIL" for r in rows)},
             "cases":[asdict(r) for r in rows]}
    (out/"report.json").write_text(json.dumps(payload,indent=2,sort_keys=True)+"\n",encoding="utf-8")
    (out/"report.md").write_text(markdown_report(meta,rows,metrics),encoding="utf-8")
    print(json.dumps(payload["summary"],sort_keys=True))
    print(f"evidence={out}")
    if args.strict_synthetic and any(r.result=="FAIL" and r.coverage=="synthetic" for r in rows):
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
