param(
    [Parameter(Mandatory=$true)][string]$Root
)

$ErrorActionPreference='Stop'
$deDir=Join-Path $Root 'DE_LAB'
Set-Location $deDir
$exe=Join-Path $deDir 'wow112-ah-de-liquidation-v31.exe'
if(-not(Test-Path $exe)){throw 'AH executable not found. Run START_AH_LATEST updater first.'}

if($env:WOW112_LAUNCHER_ARM -ne 'VENDOR_ONE'){
    $arm=Read-Host 'REAL VENDOR BUY: wpisz VENDOR1 aby uzbroic dokladnie 1 zakup'
    if($arm -cne 'VENDOR1'){Write-Host 'Zero BUY.' -ForegroundColor Cyan;exit 2}
}

$account=$env:WOW112_ACCOUNT
$character=$env:WOW112_CHARACTER
$realm=$env:WOW112_REALM_INDEX
if([string]::IsNullOrWhiteSpace($account)){throw 'WOW112_ACCOUNT missing'}
if([string]::IsNullOrWhiteSpace($character)){throw 'WOW112_CHARACTER missing'}
if([string]::IsNullOrWhiteSpace($realm)){$realm='1'}
if([string]::IsNullOrWhiteSpace($env:WOW112_PASSWORD)){throw 'WOW112_PASSWORD missing'}

$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$prefix='VENDOR_ONE_LIVE'
$log=Join-Path $deDir ($prefix+'_'+$stamp+'.log')
$reports=Join-Path $deDir 'REPORTS'
New-Item -ItemType Directory -Force $reports | Out-Null

function Count-Marker([string]$Path,[string]$Marker){
    if(-not(Test-Path $Path)){return 0}
    return @(Select-String -Path $Path -SimpleMatch $Marker -ErrorAction SilentlyContinue).Count
}
function Test-TransientPreSend([string]$Path){
    if(-not(Test-Path $Path)){return $false}
    foreach($pattern in @('UnexpectedEof','read encrypted server header failed','read encrypted server payload failed','server did not return MSG_AUCTION_HELLO','Connection reset','forcibly closed')){
        if(Select-String -Path $Path -SimpleMatch $pattern -Quiet -ErrorAction SilentlyContinue){return $true}
    }
    return $false
}

# Canonical unified engine, but hard-bounded to Vendor only and exactly one mutation.
$env:WOW112_ACCOUNT=$account
$env:WOW112_CHARACTER=$character
$env:WOW112_REALM_INDEX=$realm
$env:WOW112_SOAK_SECONDS='0'
$env:WOW112_RECONNECT_LIMIT='1'
$env:WOW112_RECONNECT_DELAY_MS='1000'
$env:WOW112_AH_GUID='0xF130003D4100023A'
$env:WOW112_AH_FULL_SCAN_MAX_PAGES='2048'
$env:WOW112_AH_HELLO_TIMEOUT_SECS='20'
$env:WOW112_VENDOR_FULL_SCOPE='1'
$env:WOW112_DE_FAST_PREFILTER='0'
$env:WOW112_F1_ACTION='vendor+de'
$env:WOW112_F1_LIVE_CONFIRM='BUY_ONE_NOW'
$env:WOW112_AUTOBUY_CONFIRM='YES'
$env:WOW112_AUTOBUY_MAX_PURCHASES='1'
$env:WOW112_AUTOBUY_MAX_BUYOUT='20000'
$env:WOW112_AUTOBUY_MIN_PROFIT='1'
$env:WOW112_UNIFIED_VENDOR_MAX_PURCHASES='1'
$env:WOW112_UNIFIED_DE_MAX_PURCHASES='0'
$env:WOW112_UNIFIED_MAX_PURCHASES='1'
$env:WOW112_UNIFIED_MAX_SPEND='20000'
$env:WOW112_UNIFIED_DE_MAX_PER_DEID='0'
$env:WOW112_UNIFIED_DE_MAX_SPEND='0'

$candidates=Join-Path $deDir ($prefix+'_CANDIDATES.csv')
$rejected=Join-Path $deDir ($prefix+'_REJECTED.csv')
$env:WOW112_ECONOMY_CANDIDATE_EXPORT=$candidates
$env:WOW112_ECONOMY_REJECTED_EXPORT=$rejected

Write-Host 'VENDOR LIVEPASS ARMED: Vendor only / max1 BUY / max2g / DE disabled / uncertain => HARD STOP.' -ForegroundColor Yellow

$code=99
$attempt=0
$maxAttempts=3
$retryCount=0
$stopReason=''
$attemptLogs=@()
$started=Get-Date
try{
    while($attempt -lt $maxAttempts){
        $attempt++
        $attemptLog=Join-Path $deDir ($prefix+'_'+$stamp+('_TRY{0}.log' -f $attempt))
        $attemptLogs += $attemptLog
        Write-Host ("[VENDOR-LIVEPASS] attempt {0}/{1}: fresh login + fresh scan" -f $attempt,$maxAttempts) -ForegroundColor Cyan
        $oldEap=$ErrorActionPreference
        $ErrorActionPreference='Continue'
        try{
            & $exe 2>&1 | Tee-Object -FilePath $attemptLog
            if($null -eq $LASTEXITCODE){$code=1}else{$code=[int]$LASTEXITCODE}
        }catch{
            if($null -eq $LASTEXITCODE){$code=1}else{$code=[int]$LASTEXITCODE}
            ("[VENDOR-LIVEPASS] native invocation caught: "+$_.Exception.Message) | Tee-Object -FilePath $attemptLog -Append | Write-Host
        }finally{$ErrorActionPreference=$oldEap}

        $sent=Count-Marker $attemptLog '[POC07-BUY] SENT'
        $uncertain=Count-Marker $attemptLog 'AH_MUTATION_UNCERTAIN'
        if($code -eq 0){$stopReason='PASS';break}
        if($sent -gt 0 -or $uncertain -gt 0){
            $stopReason='MUTATION_BOUNDARY_NO_RETRY'
            Write-Host '[VENDOR-LIVEPASS] HARD STOP after SEND/UNCERTAIN. No automatic retry.' -ForegroundColor Red
            break
        }
        $transient=Test-TransientPreSend $attemptLog
        if($transient -and $attempt -lt $maxAttempts){
            $retryCount++
            Start-Sleep -Seconds (2*$attempt)
            continue
        }
        $stopReason=if($transient){'TRANSIENT_RETRY_EXHAUSTED'}else{'NON_RETRYABLE_PRE_SEND_FAILURE'}
        break
    }
}finally{
    Remove-Item Env:WOW112_F1_LIVE_CONFIRM,Env:WOW112_AUTOBUY_CONFIRM -ErrorAction SilentlyContinue
}

if(Test-Path $log){Remove-Item $log -Force}
foreach($attemptLog in $attemptLogs){
    if(Test-Path $attemptLog){
        Add-Content -Path $log -Value ('===== ATTEMPT LOG: '+(Split-Path $attemptLog -Leaf)+' =====')
        Get-Content $attemptLog | Add-Content -Path $log
    }
}

$sent=Count-Marker $log '[POC07-BUY] SENT'
$server=Count-Marker $log '[POC07-BUY] SERVER PASS'
$confirmed=(Count-Marker $log '[POC08-UNIFIED-V4] CONFIRMED')+(Count-Marker $log '[POC08-UNIFIED-MULTI] CONFIRMED')
$uncertain=Count-Marker $log 'AH_MUTATION_UNCERTAIN'
$livepass=(Count-Marker $log '[POC08-UNIFIED-V4] LIVE PASS')+(Count-Marker $log '[POC08-UNIFIED-MULTI] LIVE PASS')
$elapsed=[int]((Get-Date)-$started).TotalSeconds
$summary=Join-Path $deDir ($prefix+'_RUN_SUMMARY.txt')
@(
  'mode=VendorOneLive',
  'strategy=VendorOnly',
  "stamp=$stamp",
  "exit_code=$code",
  "elapsed_seconds=$elapsed",
  "attempts=$attempt",
  "safe_retries=$retryCount",
  "stop_reason=$stopReason",
  "sent=$sent",
  "server_pass=$server",
  "confirmed=$confirmed",
  "uncertain=$uncertain",
  "live_pass=$livepass",
  "exe_sha256=$((Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant())"
) | Set-Content $summary -Encoding UTF8

$report=Join-Path $reports ($prefix+'_'+$stamp+'.zip')
$files=@($log,$summary,$candidates,$rejected)+(Get-ChildItem -Path $deDir -Filter ($prefix+'_'+$stamp+'_TRY*.log') -ErrorAction SilentlyContinue | ForEach-Object {$_.FullName})
$files=@($files|Where-Object{$_ -and (Test-Path $_)}|Select-Object -Unique)
if($files.Count -gt 0){
    Compress-Archive -Path $files -DestinationPath $report -CompressionLevel Optimal -Force
    Copy-Item $report (Join-Path $reports 'LATEST_VENDOR_LIVEPASS_REPORT.zip') -Force
}

Write-Host ("VENDOR LIVEPASS summary: exit={0} stop={1} sent/server/confirmed={2}/{3}/{4} uncertain={5} livepass={6}" -f $code,$stopReason,$sent,$server,$confirmed,$uncertain,$livepass)
Write-Host 'Report: DE_LAB\REPORTS\LATEST_VENDOR_LIVEPASS_REPORT.zip' -ForegroundColor Green

if($uncertain -gt 0 -or $sent -ne $server -or $server -ne $confirmed){
    Write-Host 'SAFETY ALERT: mutation reconciliation mismatch. DO NOT RERUN before review.' -ForegroundColor Red
    if($code -eq 0){$code=3}
}
exit $code
