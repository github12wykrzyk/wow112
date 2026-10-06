$ErrorActionPreference = 'Stop'

$targets = @(
    'probes/Wow112HeadlessAndroid/src/bin/tele06a_acceptor_runtime.rs',
    'probes/Wow112HeadlessAndroid/src/bin/tele06a_ritual_runtime.rs'
)

function Require-Replace([string]$Text,[string]$Old,[string]$New,[string]$Label) {
    if (-not $Text.Contains($Old)) { throw "missing patch anchor: $Label" }
    return $Text.Replace($Old,$New)
}

foreach ($path in $targets) {
    $t = Get-Content $path -Raw

    $t = Require-Replace $t 'use std::net::TcpStream;' 'use std::net::{TcpStream, ToSocketAddrs};' "$path net import"

    $constAnchor = 'const DEFAULT_RECONNECT_LIMIT: u32 = 60;'
    $helper = @'
const DEFAULT_RECONNECT_LIMIT: u32 = 60;
const LOGIN_WATCHDOG_MS: u64 = 3000;

fn connect_with_login_watchdog(addr: &str, label: &str) -> Result<TcpStream, String> {
    let addrs = addr
        .to_socket_addrs()
        .map_err(|e| format!("{label} resolve {addr} failed: {e}"))?
        .collect::<Vec<_>>();
    if addrs.is_empty() {
        return Err(format!("{label} resolve {addr} returned no addresses"));
    }
    let mut last_error = None;
    for socket in addrs {
        match TcpStream::connect_timeout(&socket, Duration::from_millis(LOGIN_WATCHDOG_MS)) {
            Ok(stream) => {
                println!("[LOGIN-WATCHDOG] {label} connected addr={socket} timeout_ms={LOGIN_WATCHDOG_MS}");
                return Ok(stream);
            }
            Err(error) => {
                last_error = Some(format!("{error}"));
            }
        }
    }
    Err(format!("{label} connect {addr} watchdog timeout/failure after {LOGIN_WATCHDOG_MS}ms last={}", last_error.unwrap_or_else(|| "unknown".to_string())))
}

fn arm_login_watchdog(stream: &TcpStream, label: &str) -> Result<(), String> {
    let timeout = Some(Duration::from_millis(LOGIN_WATCHDOG_MS));
    stream.set_read_timeout(timeout).map_err(|e| format!("{label} set login read watchdog failed: {e}"))?;
    stream.set_write_timeout(timeout).map_err(|e| format!("{label} set login write watchdog failed: {e}"))?;
    println!("[LOGIN-WATCHDOG] {label} io_timeout_ms={LOGIN_WATCHDOG_MS}");
    Ok(())
}
'@
    $t = Require-Replace $t $constAnchor $helper.TrimEnd() "$path watchdog helper"

    $oldAuth = 'let mut auth_stream = TcpStream::connect(auth_addr).map_err(|e| format!("auth connect {auth_addr} failed: {e}"))?;'
    $newAuth = @'
let mut auth_stream = connect_with_login_watchdog(auth_addr, "AUTH")?;
    arm_login_watchdog(&auth_stream, "AUTH")?;
'@
    $t = Require-Replace $t $oldAuth $newAuth.TrimEnd() "$path auth connect"

    $oldWorld = 'let mut world_stream = TcpStream::connect(&world_addr).map_err(|e| format!("world connect {world_addr} failed: {e}"))?;'
    $newWorld = @'
let mut world_stream = connect_with_login_watchdog(&world_addr, "WORLD")?;
    arm_login_watchdog(&world_stream, "WORLD")?;
'@
    $t = Require-Replace $t $oldWorld $newWorld.TrimEnd() "$path world connect"

    $old20 = 'set_read_timeout(Some(Duration::from_secs(20)))'
    if (-not $t.Contains($old20)) { throw "missing 20s world login timeout anchor: $path" }
    $t = $t.Replace($old20, 'set_read_timeout(Some(Duration::from_millis(LOGIN_WATCHDOG_MS)))')

    if ($t -notmatch 'LOGIN_WATCHDOG_MS: u64 = 3000') { throw "watchdog const missing: $path" }
    if ($t -notmatch 'connect_with_login_watchdog') { throw "watchdog connect helper missing: $path" }
    if ($t -match 'TcpStream::connect\(auth_addr\)') { throw "old auth connect survived: $path" }
    if ($t -match 'TcpStream::connect\(&world_addr\)') { throw "old world connect survived: $path" }

    Set-Content -Path $path -Value $t -Encoding UTF8
}

Write-Host 'LOGIN WATCHDOG 3S PATCH PASS'
