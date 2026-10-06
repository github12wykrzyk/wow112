$ErrorActionPreference = 'Stop'

$acceptor = 'probes/Wow112HeadlessAndroid/src/bin/tele06a_acceptor_runtime.rs'
$summoner = 'probes/Wow112HeadlessAndroid/src/bin/tele06a_ritual_runtime.rs'

# Preserve V2/V3 acceptor and reconnect fixes.
$a = Get-Content $acceptor -Raw
$a = $a -replace '(?m)^\s*let deadline = Instant::now\(\) \+ Duration::from_secs\(180\);\r?\n', ''
$a = $a -replace '(?ms)^\s*if Instant::now\(\) >= deadline \{\r?\n\s*let _ = stream\.set_read_timeout\(previous_timeout\);\r?\n\s*return Err\("TELE06A_ACCEPT_TIMEOUT no whitelisted invite observed"\.to_string\(\)\);\r?\n\s*\}\r?\n', ''
$a = $a.Replace('println!("[TELE-06A-ACCEPTOR] ARMED ONCE whitelist={expected_inviter:?} deadline=180s");', 'println!("[TELE-06A-ACCEPTOR] ARMED ONCE whitelist={expected_inviter:?} wait=infinite");')
$a = $a.Replace('"world keepalive pong timeout"]', '"world keepalive pong timeout", "10060"]')
$a = $a.Replace('println!("[RESILIENCE] transient network failure: {error}");', 'let display_error = if error.contains("10060") { "network timeout (WinSock 10060: remote host did not respond)".to_string() } else { error.clone() }; println!("[RESILIENCE] transient network failure: {display_error}");')
Set-Content -Path $acceptor -Value $a -Encoding UTF8

$s = Get-Content $summoner -Raw
$s = $s.Replace('"world keepalive pong timeout",', '"world keepalive pong timeout", "10060",')
$s = $s.Replace('println!("[RESILIENCE] transient network failure: {error}");', 'let display_error = if error.contains("10060") { "network timeout (WinSock 10060: remote host did not respond)".to_string() } else { error.clone() }; println!("[RESILIENCE] transient network failure: {display_error}");')

# V4: server stores Ritual of Summoning action target from player selection GUID.
if (-not $s.Contains('const CMSG_SET_SELECTION_OPCODE: u32 = 0x013D;')) {
    $needleConst = '    const CMSG_CAST_SPELL_OPCODE: u32 = 0x012E;'
    if (-not $s.Contains($needleConst)) { throw 'CMSG_CAST_SPELL const insertion point missing' }
    $s = $s.Replace($needleConst, $needleConst + "`r`n    const CMSG_SET_SELECTION_OPCODE: u32 = 0x013D;")
}

$oldEncode = @'
    fn encode_ritual_cast(target_guid: u64) -> Result<Vec<u8>, String> {
        if target_guid == 0 {
            return Err("ritual target guid must not be zero".to_string());
        }
        let mut payload = Vec::with_capacity(15);
        payload.extend_from_slice(&RITUAL_OF_SUMMONING_SPELL_ID.to_le_bytes());
        payload.extend_from_slice(&TARGET_FLAG_UNIT.to_le_bytes());
        payload.extend_from_slice(&encode_packed_guid(target_guid));
        Ok(payload)
    }
'@
$newEncode = @'
    fn encode_ritual_cast() -> Vec<u8> {
        let mut payload = Vec::with_capacity(6);
        payload.extend_from_slice(&RITUAL_OF_SUMMONING_SPELL_ID.to_le_bytes());
        payload.extend_from_slice(&0u16.to_le_bytes());
        payload
    }
'@
if (-not $s.Contains($oldEncode.Trim())) { throw 'old ritual encoder not found' }
$s = $s.Replace($oldEncode.Trim(), $newEncode.Trim())

$oldPayload = '        let payload = encode_ritual_cast(target_guid)?;'
if (-not $s.Contains($oldPayload)) { throw 'old ritual payload call not found' }
$s = $s.Replace($oldPayload, '        let payload = encode_ritual_cast();')

$castNeedle = @'
        println!(
            "[TELE-06A-RITUAL] state=CAST_ATTEMPTED spell={} target={:?} target_guid=0x{:016X} shard_precheck=server_authoritative",
'@
$selectionBlock = @'
        if target_guid == 0 {
            return Err("ritual selection guid must not be zero".to_string());
        }
        let selection_payload = target_guid.to_le_bytes();
        write_encrypted_raw(
            stream,
            crypto.encrypter(),
            CMSG_SET_SELECTION_OPCODE,
            &selection_payload,
        )
        .map_err(|error| {
            format!(
                "TELE06A_SELECTION_MUTATION_UNCERTAIN target={target_name:?} guid=0x{target_guid:016X} retry_allowed=false cause={error}"
            )
        })?;
        println!(
            "[TELE-06A-SELECTION-TX] opcode=0x013D target={:?} target_guid=0x{:016X} bytes=8 result=attempted_once retry_allowed=false",
            target_name,
            target_guid
        );
        thread::sleep(Duration::from_millis(150));

        println!(
            "[TELE-06A-RITUAL] state=CAST_ATTEMPTED spell={} target={:?} target_guid=0x{:016X} target_mode=selection cast_target_mask=0x0000 shard_precheck=server_authoritative",
'@
if (-not $s.Contains($castNeedle.Trim())) { throw 'ritual state marker insertion point missing' }
$s = $s.Replace($castNeedle.Trim(), $selectionBlock.Trim())

$oldCastLog = '            "[TELE-06A-CAST-TX] opcode=0x012E spell={} target={:?} target_guid=0x{:016X} bytes={} result=attempted_once retry_allowed=false",'
$newCastLog = '            "[TELE-06A-CAST-TX] opcode=0x012E spell={} target={:?} target_guid=0x{:016X} target_mode=selection target_mask=0x0000 bytes={} result=attempted_once retry_allowed=false",'
if (-not $s.Contains($oldCastLog)) { throw 'old cast log marker missing' }
$s = $s.Replace($oldCastLog, $newCastLog)

# Retain V3 raw cast-result diagnostic.
$diagNeedle = '                        let is_ritual = parsed.contains("698") || parsed.contains("0x02BA");'
$diag = @'
                        if opcode == SMSG_CAST_RESULT_OPCODE && payload.len() >= 6 {
                            let raw_spell = u32::from_le_bytes(payload[0..4].try_into().unwrap());
                            let status = payload[4];
                            let reason = payload[5];
                            let reason_name = match reason {
                                0x09 => "BAD_IMPLICIT_TARGETS",
                                0x0A => "BAD_TARGETS",
                                0x13 => "CASTER_DEAD",
                                0x3C => "NOT_READY",
                                0x3E => "NOT_STANDING",
                                0x4D => "NO_POWER",
                                0x59 => "OUT_OF_RANGE",
                                0x5C => "REAGENTS",
                                0x61 => "SPELL_IN_PROGRESS",
                                0x65 => "TARGETS_DEAD",
                                0x66 => "TARGET_AFFECTING_COMBAT",
                                _ => "OTHER",
                            };
                            let raw_hex = payload.iter().map(|byte| format!("{byte:02X}")).collect::<Vec<_>>().join(" ");
                            println!("[TELE-06A-CAST-RESULT-RAW] spell={} status={} reason=0x{:02X} reason_name={} raw={}", raw_spell, status, reason, reason_name, raw_hex);
                        }
                        let is_ritual = parsed.contains("698") || parsed.contains("0x02BA");
'@
if (-not $s.Contains('TELE-06A-CAST-RESULT-RAW')) {
    if (-not $s.Contains($diagNeedle)) { throw 'cast result diagnostic insertion point missing' }
    $s = $s.Replace($diagNeedle, $diag.TrimEnd())
}

# Replace the old UNIT-target contract with exact V4 selection + targetless cast contract.
$oldTest = @'
        #[test]
        fn ritual_wire_contract() {
            assert_eq!(CMSG_CAST_SPELL_OPCODE, 0x012E);
            assert_eq!(RITUAL_OF_SUMMONING_SPELL_ID, 698);
            assert_eq!(TARGET_FLAG_UNIT, 0x0002);
            let payload = encode_ritual_cast(0x0000_0000_3B9F_74DE).unwrap();
            assert_eq!(&payload[0..4], &698u32.to_le_bytes());
            assert_eq!(&payload[4..6], &0x0002u16.to_le_bytes());
            assert_eq!(payload[6], 0x0F);
            assert_eq!(&payload[7..11], &[0xDE, 0x74, 0x9F, 0x3B]);
        }
'@
$newTest = @'
        #[test]
        fn ritual_wire_contract() {
            assert_eq!(CMSG_SET_SELECTION_OPCODE, 0x013D);
            assert_eq!(CMSG_CAST_SPELL_OPCODE, 0x012E);
            assert_eq!(RITUAL_OF_SUMMONING_SPELL_ID, 698);
            let guid = 0x0000_0000_3B9F_74DEu64;
            assert_eq!(guid.to_le_bytes(), [0xDE, 0x74, 0x9F, 0x3B, 0x00, 0x00, 0x00, 0x00]);
            let payload = encode_ritual_cast();
            assert_eq!(payload.len(), 6);
            assert_eq!(&payload[0..4], &698u32.to_le_bytes());
            assert_eq!(&payload[4..6], &0u16.to_le_bytes());
        }
'@
if (-not $s.Contains($oldTest.Trim())) { throw 'old ritual contract test not found' }
$s = $s.Replace($oldTest.Trim(), $newTest.Trim())
Set-Content -Path $summoner -Value $s -Encoding UTF8

# Assertions make CI fail closed if any patch drifts.
$acheck = Get-Content $acceptor -Raw
$scheck = Get-Content $summoner -Raw
if ($acheck -match 'deadline=180s|TELE06A_ACCEPT_TIMEOUT') { throw 'acceptor infinite wait patch failed' }
if ($acheck -notmatch 'wait=infinite') { throw 'acceptor infinite wait marker missing' }
if ($acheck -notmatch '"10060"' -or $scheck -notmatch '"10060"') { throw '10060 transient classifier missing' }
if ($scheck -notmatch 'CMSG_SET_SELECTION_OPCODE: u32 = 0x013D') { throw 'selection opcode missing' }
if ($scheck -notmatch 'target_mode=selection target_mask=0x0000') { throw 'targetless cast marker missing' }
if ($scheck -notmatch 'TELE-06A-CAST-RESULT-RAW') { throw 'raw cast diagnostic missing' }
if ($scheck -match 'encode_ritual_cast\(0x') { throw 'old UNIT ritual contract survived patch' }
Write-Host 'TELE06A V4 PATCH PASS'
