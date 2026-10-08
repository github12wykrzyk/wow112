$ErrorActionPreference='Stop'

$SourceRoot=[IO.Path]::GetFullPath($PSScriptRoot)
$ShortRoot=Join-Path $env:LOCALAPPDATA 'WoW112\AH_AUTO_V2_BASELINE_FIX'
$Logs=Join-Path $ShortRoot 'logs'
New-Item -ItemType Directory -Force $ShortRoot,$Logs | Out-Null

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' WoW112 AH - AUTO LIFECYCLE V2 / INVENTORY BASELINE FIX' -ForegroundColor Cyan
Write-Host ' BUILD: see BUILD_INFO.txt (EXACT_SHA)' -ForegroundColor Cyan
Write-Host ' ITEM: 10998   FLOOR: 40s00c (4000 copper)   MAX REPOSTS: 2' -ForegroundColor Yellow
Write-Host ' INVENTORY BASELINE + MERGE-RISK GUARD + BOUNDED READ-ONLY SETTLE' -ForegroundColor Yellow
Write-Host ' AH HELLO TIMEOUT: 120s' -ForegroundColor Yellow
Write-Host ' ZERO AUTO-RETRY AFTER MUTATION SEND / UNCERTAIN' -ForegroundColor Red
Write-Host '============================================================' -ForegroundColor Cyan

Get-ChildItem $SourceRoot -Force | Where-Object {
    $_.Name -notin @('START_AUTO_V2_BASELINE_FIX.ps1','START_AUTO_V2_BASELINE_FIX.bat')
} | ForEach-Object {
    $dst=Join-Path $ShortRoot $_.Name
    if($_.PSIsContainer){
        if(Test-Path $dst){Remove-Item $dst -Recurse -Force}
        Copy-Item $_.FullName $dst -Recurse -Force
    } else {
        Copy-Item $_.FullName $dst -Force
    }
}

$Exe=Join-Path $ShortRoot 'wow112-ah-auction-lifecycle-v1.exe'
if(-not(Test-Path $Exe)){throw "Missing lifecycle EXE: $Exe"}

$other=@(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Id -ne $PID -and ($_.ProcessName -like 'wow112-ah-*' -or $_.ProcessName -like 'wow112-headless-android-probe*')
})
if($other.Count -gt 0){
    throw "STOP: another AH terminal process is active: $(($other|ForEach-Object{"$($_.ProcessName)#$($_.Id)"}) -join ', ')"
}

$account=Read-Host 'Login WoW [Enter=octowar1]'
if([string]::IsNullOrWhiteSpace($account)){$account='octowar1'}
$character=Read-Host 'Postac [Enter=Smokinpole]'
if([string]::IsNullOrWhiteSpace($character)){$character='Smokinpole'}
$realm=Read-Host 'Realm index [Enter=1]'
if([string]::IsNullOrWhiteSpace($realm)){$realm='1'}
$sec=Read-Host 'Haslo WoW' -AsSecureString

Write-Host ''
Write-Host 'CANARY: max 2 reposty itemu 10998; baseline nieustalony / same-item w torbach = SKIP before cancel.' -ForegroundColor Yellow
Write-Host 'Po take-item runtime robi bounded READ-ONLY settle i akceptuje tylko exact new GUID + exact stack.' -ForegroundColor Yellow
$arm=Read-Host 'Wpisz AUTO2 aby uzbroic canary; wszystko inne = stop'
if($arm -cne 'AUTO2'){
    Write-Host 'Stopped. ZERO MUTATION.' -ForegroundColor Cyan
    exit 0
}

$ptr=[IntPtr]::Zero
$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$log=Join-Path $Logs ("AUTO_V2_BASELINE_FIX_"+$stamp+".log")

try{
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)

    $env:WOW112_ACCOUNT=$account
    $env:WOW112_CHARACTER=$character
    $env:WOW112_REALM_INDEX=$realm
    $env:WOW112_PASSWORD=$plain
    $env:WOW112_RECONNECT_LIMIT='1'
    $env:WOW112_RECONNECT_DELAY_MS='0'
    $env:WOW112_SOAK_SECONDS='0'
    $env:WOW112_AUTOBUY_ACTION='scan-only'
    $env:WOW112_SERVER_ID='octowow'
    $env:WOW112_AH_GUID='0xF130003D4100023A'
    $env:WOW112_MAILBOX_GUID='0xF11002A4A5002A0C'
    $env:WOW112_AH_HELLO_TIMEOUT_SECS='120'
    $env:WOW112_LIFECYCLE_ACTION='auto'
    $env:WOW112_LIFECYCLE_CONFIRM='YES'
    $env:WOW112_LIFECYCLE_AUTO_FLOORS='10998:4000'
    $env:WOW112_LIFECYCLE_AUTO_LIMIT='2'
    $env:WOW112_LIFECYCLE_MINUTES='120'
    $env:WOW112_LIFECYCLE_MAX_PAGES='4096'

    foreach($n in @('WOW112_F1_LIVE_CONFIRM','WOW112_AUTOBUY_CONFIRM','WOW112_LAUNCHER_ARM')){
        Remove-Item ("Env:"+$n) -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host '[AUTO-V2] SINGLE INVOCATION START.' -ForegroundColor Red
    Write-Host "Log: $log" -ForegroundColor DarkGray

    $raw=& $Exe 2>&1
    $rc=if($null -eq $LASTEXITCODE){1}else{[int]$LASTEXITCODE}
    $raw | Set-Content -Path $log -Encoding UTF8
    $raw | ForEach-Object {Write-Host "$_"}

    Write-Host ''
    if($rc -eq 0){
        Write-Host '[AUTO-V2] RUN PASS.' -ForegroundColor Green
    } else {
        Write-Host '[AUTO-V2] HARD STOP. DO NOT RUN AGAIN.' -ForegroundColor Red
        Write-Host 'Send AUTO_V2_BASELINE_FIX_*.log for read-only reconciliation. Do NOT start any mutation again.' -ForegroundColor Red
    }
    Write-Host "Log: $log"
    exit $rc
}
finally{
    if($ptr-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
    $plain=$null
    foreach($n in @(
        'WOW112_PASSWORD','WOW112_LIFECYCLE_ACTION','WOW112_LIFECYCLE_CONFIRM',
        'WOW112_LIFECYCLE_AUTO_FLOORS','WOW112_LIFECYCLE_AUTO_LIMIT',
        'WOW112_LIFECYCLE_MINUTES','WOW112_LIFECYCLE_MAX_PAGES',
        'WOW112_AH_GUID','WOW112_MAILBOX_GUID','WOW112_AH_HELLO_TIMEOUT_SECS'
    )){Remove-Item ("Env:"+$n) -ErrorAction SilentlyContinue}
}
