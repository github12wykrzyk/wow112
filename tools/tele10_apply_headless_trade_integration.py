from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RITUAL = ROOT / "probes/Wow112HeadlessAndroid/src/bin/tele06a_ritual_runtime.rs"
SUPERVISOR = ROOT / "probes/Wow112HeadlessAndroid/src/bin/tele07_supervisor.rs"
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
remove_addon_wrong_path()
print("TELE10_HEADLESS_INTEGRATION_PATCH: PASS")
