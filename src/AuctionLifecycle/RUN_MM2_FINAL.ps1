param(
    [Parameter(Mandatory=$true)][string]$AhRoot,
    [Parameter(Mandatory=$true)]
    [ValidateSet('capability','mailbox','inventory','undercut-canary','clear-one-buy-canary','reconcile')]
    [string]$Mode,
    [ValidateSet('','YES')][string]$ConfirmMutation=''
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

# Contracted launcher exit codes.
$EXIT_PASS=0
$EXIT_BLOCKED=20
$EXIT_FAILED=30
$Mutating=@('undercut-canary','clear-one-buy-canary') -contains $Mode
$ReadOnly=-not $Mutating

function Emit-Result([string]$Status,[string]$Reason,[int]$Code){
    Write-Host ("MM2_LAUNCHER_RESULT status={0} mode={1} reason={2} exit={3}" -f $Status,$Mode,$Reason,$Code)
    exit $Code
}
function Block([string]$Reason){ Emit-Result 'BLOCKED' $Reason $EXIT_BLOCKED }
function Fail([string]$Reason){ Emit-Result 'FAILED' $Reason $EXIT_FAILED }
function Secure-ToPlain([Security.SecureString]$Secure){
    $ptr=[IntPtr]::Zero
    try{$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure);return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}
    finally{if($ptr-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}}
}
function Clear-MM2Env {
    foreach($n in @(
        'WOW112_LIFECYCLE_ACTION','WOW112_LIFECYCLE_CONFIRM','WOW112_MM2_MODE',
        'WOW112_MM2_MUTATION_CONFIRM','WOW112_MM2_EFFECT_CAP','WOW112_AUTOBUY_CONFIRM',
        'WOW112_F1_LIVE_CONFIRM','WOW112_LAUNCHER_ARM','WOW112_PASSWORD'
    )){Remove-Item ("Env:"+$n) -ErrorAction SilentlyContinue}
}
function Latest-Record([string]$Path){
    $rows=@(Get-Content $Path -ErrorAction Stop | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    if($rows.Count -eq 0){return $null}
    return [string]$rows[-1]
}

try{
    $ArtifactRoot=[IO.Path]::GetFullPath($PSScriptRoot)
    $AhRoot=[IO.Path]::GetFullPath($AhRoot)
    $Exe=Join-Path $ArtifactRoot 'wow112-ah-market-maker-v2.exe'
    $ManifestPath=Join-Path $ArtifactRoot 'MANIFEST.txt'
    $ProfilePath=Join-Path $AhRoot '.wow112_local\profile.json'
    $PasswordPath=Join-Path $AhRoot '.wow112_local\password.dpapi'

    if(-not(Test-Path $Exe)){Fail "artifact_exe_missing:$Exe"}
    if(-not(Test-Path $ManifestPath)){Fail 'manifest_missing'}
    if(-not(Test-Path $ProfilePath) -or -not(Test-Path $PasswordPath)){Fail 'canonical_local_profile_missing'}

    $manifest=@{}
    foreach($line in Get-Content $ManifestPath){if($line -match '^([^=]+)=(.*)$'){$manifest[$matches[1]]=$matches[2]}}
    if(-not $manifest.ContainsKey('SHA') -or [string]::IsNullOrWhiteSpace([string]$manifest['SHA'])){Fail 'manifest_exact_sha_missing'}
    $exactSha=[string]$manifest['SHA']
    Write-Host "MM2_EXACT_SHA=$exactSha"
    Write-Host "MM2_MODE=$Mode read_only=$ReadOnly mutation=$Mutating"

    # Hard stop before login/network activity if any durable uncertain SEND exists on this host.
    # The artifact cannot safely infer a character GUID before login, so this launcher is deliberately
    # more conservative than the per-character coordinator and blocks on any host-local .pending.
    $coordRoot=Join-Path $env:LOCALAPPDATA 'WoW112\MutationCoordinatorV1'
    if(Test-Path $coordRoot){
        $pending=@(Get-ChildItem $coordRoot -Filter '*.pending' -File -ErrorAction Stop)
        if($pending.Count -gt 0){Block ("unresolved_pending:"+($pending.Name -join ','))}
    }

    # Recovery/saga debt never authorizes a new run. Read-only reconcile is the sole exception.
    $debts=New-Object System.Collections.Generic.List[string]
    $recoveryRoot=Join-Path $env:LOCALAPPDATA 'WoW112\MarketMakerV2'
    if(Test-Path $recoveryRoot){
        foreach($f in Get-ChildItem $recoveryRoot -Filter '*.recovery' -File -ErrorAction Stop){
            $last=Latest-Record $f.FullName
            if($null -eq $last -or $last -notmatch '\|IDLE\|[0-9a-fA-F]{16}$'){$debts.Add("recovery:$($f.Name)")}
        }
    }
    $sagaRoot=Join-Path $env:LOCALAPPDATA 'WoW112\MarketMakerV2Saga'
    if(Test-Path $sagaRoot){
        foreach($f in Get-ChildItem $sagaRoot -Filter '*.saga' -File -ErrorAction Stop){
            $last=Latest-Record $f.FullName
            if($null -eq $last -or $last -notmatch '\|DONE\|[0-9a-fA-F]{16}$'){$debts.Add("saga:$($f.Name)")}
        }
    }
    if($debts.Count -gt 0 -and $Mode -ne 'reconcile'){Block ("durable_debt_reconcile_only:"+($debts -join ','))}

    if($Mutating -and $ConfirmMutation -cne 'YES'){Block 'explicit_mutation_confirmation_required'}
    if($ReadOnly -and -not [string]::IsNullOrEmpty($ConfirmMutation)){Fail 'read_only_mode_must_not_receive_mutation_confirmation'}

    # Exactly one local writer process. No supervisor retry exists in this launcher.
    $other=@(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Id -ne $PID -and ($_.ProcessName -like 'wow112-ah-*' -or $_.ProcessName -like 'wow112-headless-android-probe*')
    })
    if($other.Count -gt 0){Block ('concurrent_ah_runtime:'+ (($other|ForEach-Object{"$($_.ProcessName)#$($_.Id)"}) -join ','))}

    $profile=Get-Content $ProfilePath -Raw | ConvertFrom-Json
    $secure=(Get-Content $PasswordPath -Raw).Trim() | ConvertTo-SecureString
    $plain=Secure-ToPlain $secure
    Clear-MM2Env
    $env:WOW112_ACCOUNT=[string]$profile.account
    $env:WOW112_CHARACTER=[string]$profile.character
    $env:WOW112_REALM_INDEX=[string]$profile.realm_index
    $env:WOW112_PASSWORD=$plain
    $env:WOW112_RECONNECT_LIMIT='1'
    $env:WOW112_SOAK_SECONDS='0'
    $env:WOW112_AUTOBUY_ACTION='scan-only'
    $env:WOW112_LIFECYCLE_ACTION='marketmaker2'
    $env:WOW112_MM2_MODE=$Mode
    if($Mutating){
        $env:WOW112_MM2_MUTATION_CONFIRM='YES'
        $env:WOW112_MM2_EFFECT_CAP='1'
        Write-Host 'MM2_CANARY_GUARD confirm=YES effect_cap=1 invocations=1 auto_retry=NO'
    }

    $log=Join-Path $env:TEMP ("wow112-mm2-{0}-{1}.log" -f $Mode,[guid]::NewGuid().ToString('N'))
    try{
        # One and only one executable invocation. Never add a retry loop here.
        & $Exe *> $log
        $native=if($null -eq $LASTEXITCODE){1}else{[int]$LASTEXITCODE}
        $lines=@(Get-Content $log -ErrorAction SilentlyContinue)
        foreach($line in $lines){Write-Host $line}
        $text=$lines -join "`n"

        if($native -ne 0){
            if($text -match 'BLOCKED|HARD_STOP|RECONCILIATION_REQUIRED|RECOVERY_REQUIRED|unresolved send'){
                Block ("runtime_blocked_exit_$native")
            }
            Fail ("runtime_exit_$native")
        }

        if($Mutating){
            # NO-ACTION is never mutation PASS. A canary may pass only on an explicit proof that
            # exactly one lifecycle/effect was confirmed by the runtime.
            $proof="MM2_CANARY_EFFECT_CONFIRMED mode=$Mode effects=1"
            if(-not $text.Contains($proof)){Block 'no_confirmed_single_effect_proof'}
        } else {
            $required=if($Mode -eq 'capability'){'CAPABILITY_PASS'}elseif($Mode -eq 'mailbox'){'MAILBOX_RESOLVER_PASS'}elseif($Mode -eq 'inventory'){'INVENTORY_TRACKER_PASS'}else{'READ_ONLY=YES'}
            if(-not $text.Contains($required)){Fail ("read_only_success_marker_missing:$required")}
        }
        Emit-Result 'PASS' 'contract_satisfied' $EXIT_PASS
    } finally {
        Remove-Item $log -Force -ErrorAction SilentlyContinue
        $plain=$null
        Clear-MM2Env
    }
}catch{
    Write-Host ("MM2_LAUNCHER_RESULT status=FAILED mode={0} reason=exception:{1} exit={2}" -f $Mode,$_.Exception.Message,$EXIT_FAILED)
    exit $EXIT_FAILED
}
