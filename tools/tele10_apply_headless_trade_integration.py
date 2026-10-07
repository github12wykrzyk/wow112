from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RITUAL = ROOT / "probes/Wow112HeadlessAndroid/src/bin/tele06a_ritual_runtime.rs"
SUPERVISOR = ROOT / "probes/Wow112HeadlessAndroid/src/bin/tele07_supervisor.rs"
LEDGER = ROOT / "probes/Wow112HeadlessAndroid/src/tele10_trade_ledger.rs"
RUNTIME = ROOT / "probes/Wow112HeadlessAndroid/src/tele10_trade_runtime.rs"
SERVICE = ROOT / "probes/Wow112HeadlessAndroid/src/tele10_trade_service.rs"
TOC = ROOT / "src/AddOns/SummonScout/SummonScout.toc"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count == 0 and new in text:
        return text
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one anchor, got {count}")
    return text.replace(old, new, 1)


def patch_ritual() -> None:
    text = RITUAL.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "    static CAST_ATTEMPTED: AtomicBool = AtomicBool::new(false);\n",
        "    static CAST_ATTEMPTED: AtomicBool = AtomicBool::new(false);\n"
        "    static RITUAL_CONFIRMED: AtomicBool = AtomicBool::new(false);\n",
        "ritual-confirmed-static",
    )
    text = replace_once(
        text,
        "                            SMSG_SPELL_START_OPCODE => {\n"
        "                                cast_started = true;\n",
        "                            SMSG_SPELL_START_OPCODE => {\n"
        "                                cast_started = true;\n"
        "                                RITUAL_CONFIRMED.store(true, Ordering::SeqCst);\n",
        "ritual-start-confirm",
    )
    text = replace_once(
        text,
        "                            SMSG_SPELL_GO_OPCODE => {\n"
        "                                publish_runner_state(\n",
        "                            SMSG_SPELL_GO_OPCODE => {\n"
        "                                RITUAL_CONFIRMED.store(true, Ordering::SeqCst);\n"
        "                                publish_runner_state(\n",
        "ritual-go-confirm",
    )
    text = replace_once(
        text,
        "        maybe_reset_group(stream, &mut crypto)?;\n"
        "        let invite_targets = env_csv(\"WOW112_TELE_INVITE_LIST\");\n",
        "        if RITUAL_CONFIRMED.load(Ordering::SeqCst) && tele10_enabled() {\n"
        "            println!(\"[TELE10-TRADE] reconnect_after_confirmed_ritual -> payment_service_only\");\n"
        "            tele10_trade_service_loop(\n"
        "                stream,\n"
        "                &mut crypto,\n"
        "                soak_seconds,\n"
        "                selected.guid.guid(),\n"
        "                &selected.name,\n"
        "            )?;\n"
        "            return Ok(());\n"
        "        }\n\n"
        "        maybe_reset_group(stream, &mut crypto)?;\n"
        "        let invite_targets = env_csv(\"WOW112_TELE_INVITE_LIST\");\n",
        "ritual-reconnect-service",
    )
    text = replace_once(
        text,
        "        drive_roster_and_ritual(stream, &mut crypto, &invite_targets, &target_name)?;\n\n"
        "        println!(\"[TELE-06A] cast checkpoint complete; observer loop remains active\");\n"
        "        tele_sniffer_loop(stream, &mut crypto, soak_seconds)?;\n",
        "        drive_roster_and_ritual(stream, &mut crypto, &invite_targets, &target_name)?;\n\n"
        "        println!(\"[TELE-06A] cast checkpoint complete; observer loop remains active\");\n"
        "        if RITUAL_CONFIRMED.load(Ordering::SeqCst) && tele10_enabled() {\n"
        "            let destination = std::env::var(\"WOW112_TELE10_DESTINATION\")\n"
        "                .unwrap_or_else(|_| \"unknown\".to_string());\n"
        "            tele10_note_ritual_started(&target_name, &selected.name, &destination)?;\n"
        "            tele10_trade_service_loop(\n"
        "                stream,\n"
        "                &mut crypto,\n"
        "                soak_seconds,\n"
        "                selected.guid.guid(),\n"
        "                &selected.name,\n"
        "            )?;\n"
        "        } else {\n"
        "            tele_sniffer_loop(stream, &mut crypto, soak_seconds)?;\n"
        "        }\n",
        "ritual-enter-trade-service",
    )
    RITUAL.write_text(text, encoding="utf-8")


def patch_supervisor() -> None:
    text = SUPERVISOR.read_text(encoding="utf-8")
    helper_anchor = "fn spawn_role(\n"
    helpers = r'''fn tele10_customer_character() -> String {
    env::var("WOW112_TELE09_CUSTOMER_CHARACTER")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| CUSTOMER.character.to_string())
}

fn tele10_ledger_path(root: &Path) -> PathBuf {
    if let Ok(path) = env::var("WOW112_TELE10_LEDGER_PATH") {
        if !path.trim().is_empty() {
            return PathBuf::from(path);
        }
    }
    let dir = env::var("WOW112_TELE10_LEDGER_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| root.join("tele10_ledger"));
    wow112_headless_android_probe::tele10_trade_ledger::LedgerStore::stable_file_for(
        dir,
        SUMMONER.character,
    )
}

fn tele10_destination() -> String {
    env::var("WOW112_TELE10_DESTINATION")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

'''
    if helpers not in text:
        text = replace_once(text, helper_anchor, helpers + helper_anchor, "supervisor-helpers")

    text = replace_once(
        text,
        "        .env(\"WOW112_SOAK_SECONDS\", \"0\")\n"
        "        .env(\"WOW112_RUNNER_STATE_FILE\", &state_path);\n",
        "        .env(\"WOW112_SOAK_SECONDS\", \"0\")\n"
        "        .env(\"WOW112_RUNNER_STATE_FILE\", &state_path)\n"
        "        .env(\"WOW112_TELE10_LEDGER_PATH\", tele10_ledger_path(root));\n",
        "supervisor-ledger-path-env",
    )
    text = replace_once(
        text,
        "            command\n"
        "                .env(\"WOW112_TELE_RESET_GROUP\", \"1\")\n"
        "                .env(\"WOW112_TELE_INVITE_LIST\", &invite_list)\n"
        "                .env(\"WOW112_RITUAL_TARGET_NAME\", &customer_character);\n",
        "            command\n"
        "                .env(\"WOW112_TELE_RESET_GROUP\", \"1\")\n"
        "                .env(\"WOW112_TELE_INVITE_LIST\", &invite_list)\n"
        "                .env(\"WOW112_RITUAL_TARGET_NAME\", &customer_character)\n"
        "                .env(\"WOW112_TELE10_TRADE_ENABLED\", \"1\")\n"
        "                .env(\"WOW112_TELE10_DESTINATION\", tele10_destination());\n",
        "supervisor-enable-trade",
    )
    text = replace_once(
        text,
        "        if verdict.code == \"PASS_TELEPORT_COMPLETE\" {\n"
        "            total_pass += 1;\n",
        "        if verdict.code == \"PASS_TELEPORT_COMPLETE\" {\n"
        "            let ledger_path = tele10_ledger_path(&root);\n"
        "            let store = wow112_headless_android_probe::tele10_trade_ledger::LedgerStore::new(&ledger_path);\n"
        "            let customer = tele10_customer_character();\n"
        "            let settled_summon = store.mark_summoned_for_client(\n"
        "                &customer,\n"
        "                wow112_headless_android_probe::tele10_trade_ledger::unix_now(),\n"
        "            )?;\n"
        "            log.log(&format!(\n"
        "                \"TELE10_LEDGER SUMMONED id={} client={} ledger={}\",\n"
        "                settled_summon.summon_id,\n"
        "                settled_summon.client_name,\n"
        "                ledger_path.display()\n"
        "            ));\n"
        "            total_pass += 1;\n",
        "supervisor-mark-summoned",
    )
    SUPERVISOR.write_text(text, encoding="utf-8")


def patch_ledger_resilience() -> None:
    text = LEDGER.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "use std::fs::{self, File, OpenOptions};\nuse std::io::{BufRead, BufReader, Write};\n",
        "use std::fs::{self, OpenOptions};\nuse std::io::Write;\n",
        "ledger-imports",
    )
    text = replace_once(
        text,
        "        let line = serde_json::to_string(event)\n"
        "            .map_err(|error| format!(\"serialize ledger event failed: {error}\"))?;\n"
        "        file.write_all(line.as_bytes())\n"
        "            .and_then(|_| file.write_all(b\"\\n\"))\n"
        "            .and_then(|_| file.flush())\n"
        "            .and_then(|_| file.sync_all())\n",
        "        let line = serde_json::to_string(event)\n"
        "            .map_err(|error| format!(\"serialize ledger event failed: {error}\"))?;\n"
        "        let mut record = line.into_bytes();\n"
        "        record.push(b'\\n');\n"
        "        file.write_all(&record)\n"
        "            .and_then(|_| file.flush())\n"
        "            .and_then(|_| file.sync_all())\n",
        "ledger-single-write",
    )
    old_load = r'''    pub fn load(&self) -> Result<LedgerState, String> {
        let file = match File::open(&self.path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(LedgerState::default())
            }
            Err(error) => {
                return Err(format!(
                    "open ledger {} failed: {error}",
                    self.path.display()
                ))
            }
        };
        let reader = BufReader::new(file);
        let mut state = LedgerState::default();
        for (index, line) in reader.lines().enumerate() {
            let line = line.map_err(|error| {
                format!(
                    "read ledger {} line {} failed: {error}",
                    self.path.display(),
                    index + 1
                )
            })?;
            if line.trim().is_empty() {
                continue;
            }
            let event: JournalEvent = serde_json::from_str(&line).map_err(|error| {
                format!(
                    "parse ledger {} line {} failed: {error}",
                    self.path.display(),
                    index + 1
                )
            })?;
            state.replay(event);
        }
        state.apply_pending_hard_stops();
        Ok(state)
    }
'''
    new_load = r'''    pub fn load(&self) -> Result<LedgerState, String> {
        let bytes = match fs::read(&self.path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(LedgerState::default())
            }
            Err(error) => {
                return Err(format!(
                    "open ledger {} failed: {error}",
                    self.path.display()
                ))
            }
        };
        let complete_tail = bytes.last().copied() == Some(b'\n');
        let text = String::from_utf8(bytes)
            .map_err(|error| format!("ledger {} is not UTF-8: {error}", self.path.display()))?;
        let lines = text.lines().collect::<Vec<_>>();
        let mut state = LedgerState::default();
        for (index, line) in lines.iter().enumerate() {
            if line.trim().is_empty() {
                continue;
            }
            let event: JournalEvent = match serde_json::from_str(line) {
                Ok(event) => event,
                Err(error) if index + 1 == lines.len() && !complete_tail => {
                    // A process crash can leave only the last append torn. It is never
                    // committed: intent-before-send means no wire mutation follows a failed
                    // append, and a torn terminal event reopens as an unresolved intent.
                    break;
                }
                Err(error) => {
                    return Err(format!(
                        "parse ledger {} line {} failed: {error}",
                        self.path.display(),
                        index + 1
                    ))
                }
            };
            state.replay(event);
        }
        state.apply_pending_hard_stops();
        Ok(state)
    }
'''
    text = replace_once(text, old_load, new_load, "ledger-torn-tail")
    text = replace_once(
        text,
        "        let mut active = Vec::new();\n"
        "        let mut fallback = Vec::new();\n"
        "        for record in &state.summons {\n"
        "            if !record.client_name.eq_ignore_ascii_case(partner)\n"
        "                || record.summon_status != \"summoned\"\n"
        "                || !matches!(record.payment_status.as_str(), \"unpaid\" | \"partial\")\n"
        "            {\n"
        "                continue;\n"
        "            }\n",
        "        let mut active = Vec::new();\n"
        "        let mut fallback = Vec::new();\n"
        "        let mut pending_confirmation = Vec::new();\n"
        "        for record in &state.summons {\n"
        "            if !record.client_name.eq_ignore_ascii_case(partner) {\n"
        "                continue;\n"
        "            }\n"
        "            if matches!(record.summon_status.as_str(), \"ritual_started\" | \"portal_ready\")\n"
        "                && matches!(record.payment_status.as_str(), \"unpaid\" | \"partial\")\n"
        "                && now >= record.timestamp_created\n"
        "                && now.saturating_sub(record.timestamp_created) <= self.correlation_window_seconds\n"
        "            {\n"
        "                pending_confirmation.push(record);\n"
        "                continue;\n"
        "            }\n"
        "            if record.summon_status != \"summoned\"\n"
        "                || !matches!(record.payment_status.as_str(), \"unpaid\" | \"partial\")\n"
        "            {\n"
        "                continue;\n"
        "            }\n",
        "ledger-pending-correlation-scan",
    )
    text = replace_once(
        text,
        "            (0, n) if n > 1 => return Err(\"ambiguous_unpaid_summons\".to_string()),\n"
        "            _ => return Err(\"no_matching_unpaid_summon\".to_string()),\n"
        "        };\n"
        "        let remaining = selected\n",
        "            (0, n) if n > 1 => return Err(\"ambiguous_unpaid_summons\".to_string()),\n"
        "            _ if !pending_confirmation.is_empty() => {\n"
        "                return Err(\"newer_summon_pending_confirmation\".to_string())\n"
        "            }\n"
        "            _ => return Err(\"no_matching_unpaid_summon\".to_string()),\n"
        "        };\n"
        "        if pending_confirmation\n"
        "            .iter()\n"
        "            .any(|pending| pending.timestamp_created > selected.0.timestamp_created)\n"
        "        {\n"
        "            return Err(\"newer_summon_pending_confirmation\".to_string());\n"
        "        }\n"
        "        let remaining = selected\n",
        "ledger-newer-pending-block",
    )
    text = replace_once(
        text,
        "    #[test]\n"
        "    fn newer_active_session_disambiguates_same_client() {\n",
        "    #[test]\n"
        "    fn newer_pending_summon_blocks_old_fallback_until_confirmed() {\n"
        "        let store = temp_store(\"pending_newer\");\n"
        "        let old = summoned(&store, \"PlayerA\", 1000);\n"
        "        store\n"
        "            .create_ritual_started(\"PlayerA\", \"Summoner\", \"Hyjal\", \"+\", 4000)\n"
        "            .unwrap();\n"
        "        assert_eq!(\n"
        "            store.correlate(\"PlayerA\", 4010).unwrap_err(),\n"
        "            \"newer_summon_pending_confirmation\"\n"
        "        );\n"
        "        let fresh = store.mark_summoned_for_client(\"PlayerA\", 4011).unwrap();\n"
        "        let correlation = store.correlate(\"PlayerA\", 4012).unwrap();\n"
        "        assert_eq!(correlation.summon_id, fresh.summon_id);\n"
        "        assert_ne!(correlation.summon_id, old.summon_id);\n"
        "    }\n\n"
        "    #[test]\n"
        "    fn newer_active_session_disambiguates_same_client() {\n",
        "ledger-newer-pending-test",
    )
    text = replace_once(
        text,
        "    #[test]\n"
        "    fn journal_survives_reopen() {\n",
        "    #[test]\n"
        "    fn torn_final_jsonl_record_is_ignored_but_valid_history_survives() {\n"
        "        let store = temp_store(\"torn_tail\");\n"
        "        let record = summoned(&store, \"PlayerA\", 1000);\n"
        "        let mut file = std::fs::OpenOptions::new()\n"
        "            .append(true)\n"
        "            .open(store.path())\n"
        "            .unwrap();\n"
        "        std::io::Write::write_all(&mut file, br#\"{\\\"type\\\":\\\"payment\\\"\"#).unwrap();\n"
        "        drop(file);\n"
        "        let state = store.load().unwrap();\n"
        "        assert_eq!(state.summons.len(), 1);\n"
        "        assert_eq!(state.summons[0].summon_id, record.summon_id);\n"
        "        assert!(state.payments.is_empty());\n"
        "    }\n\n"
        "    #[test]\n"
        "    fn journal_survives_reopen() {\n",
        "ledger-torn-tail-test",
    )
    LEDGER.write_text(text, encoding="utf-8")


def patch_trade_race() -> None:
    text = RUNTIME.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "pub const TRADE_STATUS_CLOSE_WINDOW: u32 = 12;\n",
        "pub const TRADE_STATUS_CLOSE_WINDOW: u32 = 12;\nconst CORRELATION_RETRY_SECONDS: u64 = 10;\n",
        "runtime-retry-constant",
    )
    text = replace_once(
        text,
        "    correlation_error: Option<String>,\n"
        "    offered_copper: u32,\n",
        "    correlation_error: Option<String>,\n"
        "    correlation_retry_until: Option<u64>,\n"
        "    correlation_retry_next: Option<u64>,\n"
        "    begin_wire_sent: bool,\n"
        "    offered_copper: u32,\n",
        "runtime-retry-fields",
    )
    text = replace_once(
        text,
        "                    correlation_error: None,\n"
        "                    offered_copper: 0,\n",
        "                    correlation_error: None,\n"
        "                    correlation_retry_until: None,\n"
        "                    correlation_retry_next: None,\n"
        "                    begin_wire_sent: false,\n"
        "                    offered_copper: 0,\n",
        "runtime-retry-init",
    )
    old_partner = r'''        trade.partner_name = Some(name.to_string());
        match self.store.correlate(name, now_wall) {
            Ok(_) => {
                trade.correlation_error = None;
                Ok(vec![TradeAction::BeginTrade])
            }
            Err(error) => {
                trade.correlation_error = Some(error);
                Ok(Vec::new())
            }
        }
    }

    pub fn on_trade_extended(
'''
    new_partner = r'''        trade.partner_name = Some(name.to_string());
        match self.store.correlate(name, now_wall) {
            Ok(_) => {
                trade.correlation_error = None;
                trade.correlation_retry_until = None;
                trade.correlation_retry_next = None;
                if trade.begin_wire_sent {
                    return Ok(Vec::new());
                }
                // Commit the one-shot guard before emitting the wire action.
                trade.begin_wire_sent = true;
                Ok(vec![TradeAction::BeginTrade])
            }
            Err(error)
                if matches!(
                    error.as_str(),
                    "no_matching_unpaid_summon" | "newer_summon_pending_confirmation"
                ) =>
            {
                trade.correlation_error = Some(error);
                trade.correlation_retry_until = Some(now_wall.saturating_add(CORRELATION_RETRY_SECONDS));
                trade.correlation_retry_next = Some(now_wall.saturating_add(1));
                Ok(Vec::new())
            }
            Err(error) => {
                trade.correlation_error = Some(error);
                trade.correlation_retry_until = None;
                trade.correlation_retry_next = None;
                Ok(Vec::new())
            }
        }
    }

    pub fn retry_pending_correlation(
        &mut self,
        now_wall: u64,
    ) -> Result<Vec<TradeAction>, String> {
        let Some(trade) = self.active.as_mut() else {
            return Ok(Vec::new());
        };
        if trade.begin_wire_sent {
            return Ok(Vec::new());
        }
        let Some(partner) = trade.partner_name.clone() else {
            return Ok(Vec::new());
        };
        let Some(until) = trade.correlation_retry_until else {
            return Ok(Vec::new());
        };
        if now_wall > until {
            trade.correlation_error = Some("correlation_retry_timeout".to_string());
            trade.correlation_retry_until = None;
            trade.correlation_retry_next = None;
            return Ok(Vec::new());
        }
        if trade
            .correlation_retry_next
            .is_some_and(|next| now_wall < next)
        {
            return Ok(Vec::new());
        }
        match self.store.correlate(&partner, now_wall) {
            Ok(_) => {
                trade.correlation_error = None;
                trade.correlation_retry_until = None;
                trade.correlation_retry_next = None;
                trade.begin_wire_sent = true;
                Ok(vec![TradeAction::BeginTrade])
            }
            Err(error)
                if matches!(
                    error.as_str(),
                    "no_matching_unpaid_summon" | "newer_summon_pending_confirmation"
                ) =>
            {
                trade.correlation_error = Some(error);
                trade.correlation_retry_next = Some(now_wall.saturating_add(1));
                Ok(Vec::new())
            }
            Err(error) => {
                trade.correlation_error = Some(error);
                trade.correlation_retry_until = None;
                trade.correlation_retry_next = None;
                Ok(Vec::new())
            }
        }
    }

    pub fn on_trade_extended(
'''
    text = replace_once(text, old_partner, new_partner, "runtime-correlation-retry")
    text = replace_once(
        text,
        "    #[test]\n"
        "    fn accept_is_armed_persistently_before_wire_send() {\n",
        "    #[test]\n"
        "    fn incoming_trade_waits_for_new_summon_confirmation_then_begins_once() {\n"
        "        let path = std::env::temp_dir().join(format!(\n"
        "            \"wow112_tele10_runtime_race_{}_{}.jsonl\",\n"
        "            std::process::id(),\n"
        "            SystemTime::now()\n"
        "                .duration_since(UNIX_EPOCH)\n"
        "                .unwrap_or_default()\n"
        "                .as_nanos()\n"
        "        ));\n"
        "        let store = LedgerStore::new(path);\n"
        "        store\n"
        "            .create_ritual_started(\"PlayerA\", \"Summoner\", \"Hyjal\", \"+\", 1000)\n"
        "            .unwrap();\n"
        "        let mut engine = TradeEngine::new(store, 2000);\n"
        "        engine\n"
        "            .on_trade_status(&begin_payload(0x1234), 1010, 10)\n"
        "            .unwrap();\n"
        "        assert!(engine\n"
        "            .on_partner_name(0x1234, \"PlayerA\", 1010)\n"
        "            .unwrap()\n"
        "            .is_empty());\n"
        "        engine\n"
        "            .store()\n"
        "            .mark_summoned_for_client(\"PlayerA\", 1011)\n"
        "            .unwrap();\n"
        "        assert_eq!(\n"
        "            engine.retry_pending_correlation(1011).unwrap(),\n"
        "            vec![TradeAction::BeginTrade]\n"
        "        );\n"
        "        assert!(engine.retry_pending_correlation(1012).unwrap().is_empty());\n"
        "    }\n\n"
        "    #[test]\n"
        "    fn accept_is_armed_persistently_before_wire_send() {\n",
        "runtime-race-test",
    )
    RUNTIME.write_text(text, encoding="utf-8")


def patch_service_retry() -> None:
    text = SERVICE.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "    loop {\n"
        "        let now_ms = tele10_monotonic_ms(&epoch);\n"
        "        if let Some(event) = engine.poll(unix_now(), now_ms)? {\n",
        "    loop {\n"
        "        let now_ms = tele10_monotonic_ms(&epoch);\n"
        "        let retry_actions = engine.retry_pending_correlation(unix_now())?;\n"
        "        if !retry_actions.is_empty() {\n"
        "            println!(\"[TELE10-CORRELATION] delayed_summon_confirmation=PASS\");\n"
        "            tele10_execute_actions(stream, crypto, &mut engine, retry_actions)?;\n"
        "        }\n"
        "        if let Some(event) = engine.poll(unix_now(), now_ms)? {\n",
        "service-correlation-retry",
    )
    SERVICE.write_text(text, encoding="utf-8")


def remove_addon_wrong_path() -> None:
    text = TOC.read_text(encoding="utf-8")
    text = text.replace("SummonScout_TradePaymentLedgerQuery.lua\n", "")
    text = text.replace("SummonScout_TradePaymentLedger.lua\n", "")
    TOC.write_text(text, encoding="utf-8")
    for relative in [
        "src/AddOns/SummonScout/SummonScout_TradePaymentLedger.lua",
        "src/AddOns/SummonScout/SummonScout_TradePaymentLedgerQuery.lua",
        "tools/test_tele10_trade_payment_ledger.py",
    ]:
        path = ROOT / relative
        if path.exists():
            path.unlink()


patch_ritual()
patch_supervisor()
patch_ledger_resilience()
patch_trade_race()
patch_service_retry()
remove_addon_wrong_path()
print("TELE10_HEADLESS_INTEGRATION_PATCH: PASS")
