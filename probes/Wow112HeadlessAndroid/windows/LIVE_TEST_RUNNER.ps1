param(
    [switch]$SelfTest,
    [int]$TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'WoW112 LOCAL LIVE TEST RUNNER'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

$AcceptorExe = Join-Path $Root 'tele06a_acceptor_runtime.exe'
$SummonerExe = Join-Path $Root 'tele06a_ritual_runtime.exe'
$LocalDir = Join-Path $Root '.local'
$PasswordFile = Join-Path $LocalDir 'wow_password.dpapi'
$ResultsRoot = Join-Path $Root 'results'

$Roles = @(
    [pscustomobject]@{ Label='CUSTOMER'; Account='octowar1'; Character='Smokinpole'; Type='acceptor' },
    [pscustomobject]@{ Label='SLAVE1'; Account='octowinter1'; Character='Winterone'; Type='acceptor' },
    [pscustomobject]@{ Label='SLAVE2'; Account='octowinter2'; Character='Wintertwoo'; Type='acceptor' }
)
$Summoner = [pscustomobject]@{ Label='SUMMONER'; Account='taxi3'; Character='Teletanaris'; Type='summoner' }

function Read-AllTextSafe([string]$Path) {
    if (!(Test-Path $Path)) { return '' }
    try { return [IO.File]::ReadAllText($Path) } catch { return '' }
}

function Get-LastIndex([string]$Text, [string]$Needle) {
    if ([string]::IsNullOrEmpty($Text)) { return -1 }
    return $Text.LastIndexOf($Needle, [StringComparison]::Ordinal)
}

function Get-AcceptorState([string]$Text, [bool]$Exited) {
    if ($Exited) {
        return [pscustomobject]@{ State='EXITED'; Ready=$false; Session=0; Detail='process exited' }
    }

    $sessionMatches = [regex]::Matches($Text, '\[RESILIENCE\] session attempt=(\d+)/(\d+)')
    $session = if ($sessionMatches.Count -gt 0) { [int]$sessionMatches[$sessionMatches.Count - 1].Groups[1].Value } else { 0 }
    $sessionIndex = Get-LastIndex $Text '[RESILIENCE] session attempt='
    $armedIndex = Get-LastIndex $Text '[TELE-06A-ACCEPTOR] ARMED ONCE'
    $pongIndex = Get-LastIndex $Text '[TELE-06A-ACCEPTOR] keepalive pong'
    $handshakeIndex = Get-LastIndex $Text '[TELE-06A-ACCEPTOR] handshake complete'

    if ($handshakeIndex -gt $sessionIndex) {
        return [pscustomobject]@{ State='HANDSHAKE'; Ready=$true; Session=$session; Detail='invite accepted' }
    }
    if ($armedIndex -lt 0 -or $armedIndex -lt $sessionIndex) {
        return [pscustomobject]@{ State='CONNECTING'; Ready=$false; Session=$session; Detail='waiting for current-session ARMED' }
    }
    if ($pongIndex -lt $armedIndex) {
        return [pscustomobject]@{ State='ARMED'; Ready=$false; Session=$session; Detail='waiting for fresh keepalive pong' }
    }
    return [pscustomobject]@{ State='READY'; Ready=$true; Session=$session; Detail='ARMED + fresh pong in current session' }
}

function Get-SummonerVerdict([string]$Text, [bool]$Exited) {
    if ($Text.Contains('LIVE_CAST_START_PASS') -or $Text.Contains('LIVE_CAST_GO_PASS')) {
        return [pscustomobject]@{ Done=$true; Code='PASS_RITUAL_STARTED'; Detail='Ritual 698 reached SPELL_START/SPELL_GO' }
    }
    if ($Text.Contains('[TELE-06A-RITUAL] SERVER_REJECT')) {
        $reason = [regex]::Match($Text, '\[TELE-06A-CAST-RESULT-RAW\].*reason=0x([0-9A-Fa-f]{2}).*reason_name=([^\s]+)')
        $detail = if ($reason.Success) { 'server reject reason=0x' + $reason.Groups[1].Value.ToUpperInvariant() + ' ' + $reason.Groups[2].Value } else { 'server rejected Ritual 698' }
        return [pscustomobject]@{ Done=$true; Code='FAIL_SERVER_REJECT'; Detail=$detail }
    }
    if ($Text.Contains('TELE06A_ROSTER_TIMEOUT')) {
        return [pscustomobject]@{ Done=$true; Code='FAIL_ROSTER_TIMEOUT'; Detail='summoner did not observe full roster' }
    }
    if ($Text.Contains('TELE06A_CAST_MUTATION_UNCERTAIN') -or $Text.Contains('TELE06A_SELECTION_MUTATION_UNCERTAIN')) {
        return [pscustomobject]@{ Done=$true; Code='FAIL_MUTATION_UNCERTAIN'; Detail='selection/cast socket outcome uncertain; no retry allowed' }
    }
    if ($Exited) {
        return [pscustomobject]@{ Done=$true; Code='FAIL_SUMMONER_EXITED'; Detail='summoner process exited before ritual outcome' }
    }
    return [pscustomobject]@{ Done=$false; Code='RUNNING'; Detail='waiting for ritual checkpoint' }
}

function Run-SelfTest {
    $ready = @"
[RESILIENCE] session attempt=1/60
[TELE-06A-ACCEPTOR] ARMED ONCE whitelist="Teletanaris" wait=infinite
[TELE-06A-ACCEPTOR] keepalive ping sequence=1
[TELE-06A-ACCEPTOR] keepalive pong sequence=1
"@
    $reconnect = @"
[RESILIENCE] session attempt=1/60
[TELE-06A-ACCEPTOR] ARMED ONCE whitelist="Teletanaris" wait=infinite
[TELE-06A-ACCEPTOR] keepalive pong sequence=1
[RESILIENCE] transient network failure: network timeout
[RESILIENCE] reconnecting; reset/accept guards remain committed
[RESILIENCE] session attempt=2/60
"@
    $armedNoPong = @"
[RESILIENCE] session attempt=2/60
[TELE-06A-ACCEPTOR] ARMED ONCE whitelist="Teletanaris" wait=infinite
"@
    if (!(Get-AcceptorState $ready $false).Ready) { throw 'SELFTEST ready state failed' }
    if ((Get-AcceptorState $reconnect $false).Ready) { throw 'SELFTEST reconnect invalidation failed' }
    if ((Get-AcceptorState $armedNoPong $false).Ready) { throw 'SELFTEST fresh-pong gate failed' }
    if (!(Get-SummonerVerdict '[TELE-06A-RITUAL] LIVE_CAST_START_PASS spell=698' $false).Done) { throw 'SELFTEST ritual pass failed' }
    $reject = Get-SummonerVerdict '[TELE-06A-CAST-RESULT-RAW] spell=698 status=2 reason=0x0A reason_name=BAD_TARGETS raw=x`n[TELE-06A-RITUAL] SERVER_REJECT' $false
    if ($reject.Code -ne 'FAIL_SERVER_REJECT') { throw 'SELFTEST reject verdict failed' }
    Write-Host 'LIVE TEST RUNNER SELFTEST PASS'
    return
}

if ($SelfTest) {
    Run-SelfTest
    exit 0
}

if (!(Test-Path $AcceptorExe) -or !(Test-Path $SummonerExe)) {
    throw 'Missing TELE-06A binaries. Extract the complete ZIP before running RUN_LIVE_TEST.cmd.'
}

New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
New-Item -ItemType Directory -Force -Path $ResultsRoot | Out-Null

function SecureString-ToPlain([Security.SecureString]$Secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-LocalPassword {
    if (Test-Path $PasswordFile) {
        try {
            $encrypted = Get-Content $PasswordFile -Raw
            $secure = ConvertTo-SecureString $encrypted
            Write-Host '[CREDENTIAL] using DPAPI-encrypted local password for current Windows user'
            return SecureString-ToPlain $secure
        } catch {
            Write-Host '[CREDENTIAL] saved password could not be decrypted; asking again' -ForegroundColor Yellow
        }
    }

    $secure = Read-Host 'Common WoW password' -AsSecureString
    $plain = SecureString-ToPlain $secure
    if ([string]::IsNullOrEmpty($plain)) { throw 'Password cannot be empty.' }
    $save = Read-Host 'Save password encrypted with Windows DPAPI for future one-click tests? [Y/n]'
    if ([string]::IsNullOrWhiteSpace($save) -or $save.Trim().ToLowerInvariant() -eq 'y') {
        $secure | ConvertFrom-SecureString | Set-Content -Encoding ASCII $PasswordFile
        Write-Host "[CREDENTIAL] saved encrypted credential: $PasswordFile"
    }
    return $plain
}

$PlainPassword = Get-LocalPassword
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunDir = Join-Path $ResultsRoot ("LIVE_TEST_{0}" -f $Stamp)
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
$RunnerLog = Join-Path $RunDir 'RUNNER.log'
$VerdictPath = Join-Path $RunDir 'VERDICT.txt'
$LatestZip = Join-Path $Root 'LATEST_RESULT.zip'

function Log([string]$Message) {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
    Write-Host $line
    Add-Content -Encoding UTF8 -Path $RunnerLog -Value $line
}

$Managed = @{}

function Set-BaseEnv([string]$Account, [string]$Character) {
    $env:WOW112_PASSWORD = $PlainPassword
    $env:WOW112_ACCOUNT = $Account
    $env:WOW112_CHARACTER = $Character
    $env:WOW112_REALM_INDEX = '1'
    $env:WOW112_RECONNECT_LIMIT = '60'
    $env:WOW112_RECONNECT_DELAY_MS = '1000'
    $env:WOW112_SOAK_SECONDS = '0'
}

function Clear-WowEnv {
    @(
        'WOW112_PASSWORD','WOW112_ACCOUNT','WOW112_CHARACTER','WOW112_REALM_INDEX',
        'WOW112_RECONNECT_LIMIT','WOW112_RECONNECT_DELAY_MS','WOW112_SOAK_SECONDS',
        'WOW112_TELE_AUTO_ACCEPT_FROM','WOW112_TELE_RESET_GROUP','WOW112_TELE_INVITE_LIST','WOW112_RITUAL_TARGET_NAME'
    ) | ForEach-Object { [Environment]::SetEnvironmentVariable($_, $null, 'Process') }
}

function Start-Role([pscustomobject]$Role) {
    Set-BaseEnv $Role.Account $Role.Character
    $exe = if ($Role.Type -eq 'summoner') { $SummonerExe } else { $AcceptorExe }
    if ($Role.Type -eq 'acceptor') {
        $env:WOW112_TELE_AUTO_ACCEPT_FROM = $Summoner.Character
    } else {
        $env:WOW112_TELE_RESET_GROUP = '1'
        $env:WOW112_TELE_INVITE_LIST = 'Smokinpole,Winterone,Wintertwoo'
        $env:WOW112_RITUAL_TARGET_NAME = 'Smokinpole'
    }

    $stdout = Join-Path $RunDir ("TELE06A_{0}_{1}.log" -f $Role.Label, $Stamp)
    $stderr = Join-Path $RunDir ("TELE06A_{0}_{1}.stderr.log" -f $Role.Label, $Stamp)
    $process = Start-Process -FilePath $exe -WorkingDirectory $Root -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Clear-WowEnv

    $entry = [pscustomobject]@{
        Label=$Role.Label; Account=$Role.Account; Character=$Role.Character; Type=$Role.Type;
        Process=$process; Stdout=$stdout; Stderr=$stderr; LastState='STARTING'
    }
    $script:Managed[$Role.Label] = $entry
    Log ("START {0} pid={1} account={2} character={3}" -f $Role.Label, $process.Id, $Role.Account, $Role.Character)
    return $entry
}

function Is-Exited($Entry) {
    try { $Entry.Process.Refresh(); return $Entry.Process.HasExited } catch { return $true }
}

function Read-RoleText($Entry) {
    return (Read-AllTextSafe $Entry.Stdout) + "`n" + (Read-AllTextSafe $Entry.Stderr)
}

function Stop-ManagedProcesses {
    foreach ($entry in $script:Managed.Values) {
        try {
            $entry.Process.Refresh()
            if (!$entry.Process.HasExited) {
                Stop-Process -Id $entry.Process.Id -Force -ErrorAction SilentlyContinue
                Log ("STOP {0} pid={1}" -f $entry.Label, $entry.Process.Id)
            }
        } catch { }
    }
}

function Write-Verdict([string]$Code, [string]$Detail) {
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add("result=$Code")
    $lines.Add("detail=$Detail")
    $lines.Add("timestamp=$Stamp")
    $lines.Add('runner=LIVE_TEST_RUNNER_V1')
    $lines.Add('summoner=taxi3/Teletanaris')
    $lines.Add('customer=octowar1/Smokinpole')
    $lines.Add('slave1=octowinter1/Winterone')
    $lines.Add('slave2=octowinter2/Wintertwoo')
    foreach ($label in @('CUSTOMER','SLAVE1','SLAVE2','SUMMONER')) {
        if ($script:Managed.ContainsKey($label)) {
            $entry = $script:Managed[$label]
            $text = Read-RoleText $entry
            $state = if ($entry.Type -eq 'acceptor') { (Get-AcceptorState $text (Is-Exited $entry)).State } else { (Get-SummonerVerdict $text (Is-Exited $entry)).Code }
            $lines.Add(("{0}_state={1}" -f $label.ToLowerInvariant(), $state))
        }
    }
    $lines | Set-Content -Encoding UTF8 $VerdictPath
}

$FinalCode = 'FAIL_RUNNER_EXCEPTION'
$FinalDetail = 'runner ended unexpectedly'

try {
    Write-Host '============================================================'
    Write-Host ' WoW112 LOCAL LIVE TEST RUNNER V1'
    Write-Host ' session-aware READY gate + auto logs + verdict ZIP'
    Write-Host '============================================================'
    Log 'starting three acceptors'
    foreach ($role in $Roles) {
        [void](Start-Role $role)
        Start-Sleep -Milliseconds 250
    }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $allReadySince = $null
    while ((Get-Date) -lt $deadline) {
        $readyCount = 0
        foreach ($role in $Roles) {
            $entry = $Managed[$role.Label]
            $state = Get-AcceptorState (Read-RoleText $entry) (Is-Exited $entry)
            if ($state.Ready) { $readyCount++ }
            if ($entry.LastState -ne $state.State) {
                Log ("STATE {0}: {1} session={2} detail={3}" -f $role.Label, $state.State, $state.Session, $state.Detail)
                $entry.LastState = $state.State
            }
            if ($state.State -eq 'EXITED') {
                throw ("{0} exited before READY" -f $role.Label)
            }
        }

        if ($readyCount -eq 3) {
            if ($null -eq $allReadySince) {
                $allReadySince = Get-Date
                Log 'READY 3/3; requiring 2 seconds of simultaneous stability'
            } elseif (((Get-Date) - $allReadySince).TotalSeconds -ge 2) {
                break
            }
        } else {
            $allReadySince = $null
        }
        Start-Sleep -Milliseconds 500
    }

    if ($null -eq $allReadySince -or ((Get-Date) -ge $deadline)) {
        $FinalCode = 'FAIL_READY_TIMEOUT'
        $FinalDetail = 'did not obtain 3/3 acceptors ARMED + fresh pong in the same live sessions'
        throw $FinalDetail
    }

    Log 'READY GATE PASS 3/3; starting summoner taxi3/Teletanaris'
    $sumEntry = Start-Role $Summoner

    while ((Get-Date) -lt $deadline) {
        $sumText = Read-RoleText $sumEntry
        $verdict = Get-SummonerVerdict $sumText (Is-Exited $sumEntry)
        if ($verdict.Done) {
            $FinalCode = $verdict.Code
            $FinalDetail = $verdict.Detail
            Log ("CHECKPOINT {0}: {1}" -f $FinalCode, $FinalDetail)
            break
        }

        $sumRosterPass = $sumText.Contains('[TELE-06A-ROSTER] PASS')
        if (!$sumRosterPass) {
            foreach ($role in $Roles) {
                $entry = $Managed[$role.Label]
                $state = Get-AcceptorState (Read-RoleText $entry) (Is-Exited $entry)
                if (!$state.Ready) {
                    $FinalCode = 'FAIL_ACCEPTOR_LOST_DURING_HANDSHAKE'
                    $FinalDetail = ("{0} lost current-session readiness before summoner reached ROSTER PASS" -f $role.Label)
                    Log ("CHECKPOINT {0}: {1}" -f $FinalCode, $FinalDetail)
                    break
                }
            }
            if ($FinalCode -eq 'FAIL_ACCEPTOR_LOST_DURING_HANDSHAKE') { break }
        }
        Start-Sleep -Milliseconds 500
    }

    if ($FinalCode -eq 'FAIL_RUNNER_EXCEPTION') {
        $FinalCode = 'FAIL_TEST_TIMEOUT'
        $FinalDetail = "no terminal ritual verdict within $TimeoutMinutes minutes"
        Log ("CHECKPOINT {0}: {1}" -f $FinalCode, $FinalDetail)
    }
} catch {
    if ($FinalCode -eq 'FAIL_RUNNER_EXCEPTION') {
        $FinalDetail = $_.Exception.Message
    }
    Log ("EXCEPTION {0}: {1}" -f $FinalCode, $_.Exception.Message)
} finally {
    Stop-ManagedProcesses
    Start-Sleep -Milliseconds 500
    Write-Verdict $FinalCode $FinalDetail
    if (Test-Path $LatestZip) { Remove-Item -Force $LatestZip }
    $runZip = Join-Path $ResultsRoot ("LIVE_TEST_{0}.zip" -f $Stamp)
    if (Test-Path $runZip) { Remove-Item -Force $runZip }
    Compress-Archive -Path (Join-Path $RunDir '*') -DestinationPath $runZip -Force
    Copy-Item -Force $runZip $LatestZip
    Clear-WowEnv
    $PlainPassword = $null
    Log ("RESULT {0}: {1}" -f $FinalCode, $FinalDetail)
    Write-Host ''
    Write-Host ('VERDICT: ' + $FinalCode) -ForegroundColor $(if ($FinalCode -eq 'PASS_RITUAL_STARTED') { 'Green' } else { 'Yellow' })
    Write-Host ('DETAIL : ' + $FinalDetail)
    Write-Host ('ZIP    : ' + $LatestZip)
    Write-Host 'Upload only LATEST_RESULT.zip to ChatGPT.' -ForegroundColor Cyan
}

if ($FinalCode -eq 'PASS_RITUAL_STARTED') { exit 0 }
exit 2
