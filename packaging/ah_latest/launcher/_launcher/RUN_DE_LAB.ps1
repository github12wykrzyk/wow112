param(
    [Parameter(Mandatory=$true)][string]$Root,
    [ValidateSet('Audit','Live3')][string]$RunMode='Audit'
)
$ErrorActionPreference='Stop'
$deDir=Join-Path $Root 'DE_LAB'
Set-Location $deDir
$exe=Join-Path $deDir 'wow112-ah-de-liquidation-v31.exe'
if(-not(Test-Path $exe)){throw 'DE executable not found. Run START_AH_LATEST_CORP updater first.'}

$account=$env:WOW112_ACCOUNT
$character=$env:WOW112_CHARACTER
$realm=$env:WOW112_REALM_INDEX
if([string]::IsNullOrWhiteSpace($account)){$account=Read-Host 'Login WoW'}
if([string]::IsNullOrWhiteSpace($character)){$character=Read-Host 'Postac'}
if([string]::IsNullOrWhiteSpace($realm)){$realm='1'}
if([string]::IsNullOrWhiteSpace($env:WOW112_PASSWORD)){
    $sec=Read-Host 'Haslo WoW' -AsSecureString
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try{$env:WOW112_PASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}finally{if($ptr-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}}
}

$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$prefix=if($RunMode -eq 'Live3'){'DE_FAST_LIVE3'}else{'DE_FAST_AUDIT'}
$log=Join-Path $deDir ($prefix+'_'+$stamp+'.log')
$reports=Join-Path $deDir 'REPORTS'
New-Item -ItemType Directory -Force $reports | Out-Null

foreach($name in @(
  'WOW112_DE_MAT_VALUES','WOW112_F1_DE_MAX_MODEL_DISAGREEMENT_BPS','WOW112_F0_MAX_MODEL_DISAGREEMENT_BPS',
  'WOW112_F1_DE_WHITELIST','WOW112_F2_EXPECT_AUCTION_ID','WOW112_F2_EXPECT_ITEM_ID','WOW112_F2_EXPECT_BUYOUT','WOW112_F2_EXPECT_COUNT'
)){Remove-Item ("Env:"+$name) -ErrorAction SilentlyContinue}

$env:WOW112_ACCOUNT=$account
$env:WOW112_CHARACTER=$character
$env:WOW112_REALM_INDEX=$realm
$env:WOW112_SOAK_SECONDS='0'
$env:WOW112_RECONNECT_LIMIT='1'
$env:WOW112_RECONNECT_DELAY_MS='1000'
$env:WOW112_AH_GUID='0xF130003D4100023A'
$env:WOW112_AH_FULL_SCAN_MAX_PAGES='2048'

# V3.2 speed path: full raw AH snapshot stays intact for materials/history;
# only post-snapshot DE template/decision work is narrowed locally.
$env:WOW112_DE_FAST_PREFILTER='1'
$env:WOW112_DE_ITEM_QUERY_WINDOW='128'

$env:WOW112_AUTOBUY_MAX_BUYOUT='20000'
$env:WOW112_F0_HARD_MAX_SINGLE_BUYOUT='20000'
$env:WOW112_F1_HARD_MAX_SINGLE_BUYOUT='20000'
$env:WOW112_AUTOBUY_MIN_PROFIT='100'
$env:WOW112_DE_NET_BPS='8500'
$env:WOW112_DE_MIN_SAFE_PROFIT='500'
$env:WOW112_DE_MIN_SAFE_ROI_BPS='2000'
$env:WOW112_DE_MAX_PLOSS_BPS='4000'
$env:WOW112_F0_MIN_SAFE_PROFIT='2500'
$env:WOW112_F0_MIN_SAFE_ROI_BPS='2500'
$env:WOW112_F0_MAX_PLOSS_BPS='2500'
$env:WOW112_F0_MIN_EDGE_VS_VENDOR='2000'
$env:WOW112_F1_DE_MIN_LIQUIDATION_PROFIT='2500'

$env:WOW112_MATERIAL_HISTORY_PATH=(Join-Path $deDir 'POC08_MATERIAL_HISTORY_V3.csv')
$env:WOW112_MATERIAL_HISTORY_BUCKET_SECS='1800'
$env:WOW112_MATERIAL_HISTORY_MAX_AGE_SECS='172800'
$env:WOW112_MATERIAL_HISTORY_ACCEPT_LEGACY='0'
$env:WOW112_MATERIAL_MEDIUM_HAIRCUT_BPS='8500'
$env:WOW112_MATERIAL_OWN_EXPOSURE_FLOOR_BPS='6500'
$env:WOW112_MATERIAL_OWN_SHARE_BLOCK_BPS='7500'
$env:WOW112_MATERIAL_OWN_UNITS_BLOCK_MIN='10'

$candidates=Join-Path $deDir ($prefix+'_CANDIDATES.csv')
$rejected=Join-Path $deDir ($prefix+'_REJECTED.csv')
$material=Join-Path $deDir ($prefix+'_MATERIAL_BOOK.csv')
$f0=Join-Path $deDir ($prefix+'_F0_ELIGIBLE.csv')
$prov=Join-Path $deDir ($prefix+'_PROVENANCE.csv')
$env:WOW112_ECONOMY_CANDIDATE_EXPORT=$candidates
$env:WOW112_ECONOMY_REJECTED_EXPORT=$rejected
$env:WOW112_MATERIAL_BOOK_EXPORT=$material
$env:WOW112_F0_ELIGIBLE_EXPORT=$f0
$env:WOW112_DE_PROVENANCE_EXPORT=$prov

if($RunMode -eq 'Live3'){
    if($env:WOW112_LAUNCHER_ARM -ne 'DE_LIVE3'){
        $arm=Read-Host 'REAL BUY: wpisz V32LIVE3 aby uzbroic max 3 DE BUY'
        if($arm -cne 'V32LIVE3'){Write-Host 'Zero BUY.' -ForegroundColor Cyan;exit 2}
    }
    $env:WOW112_F1_ACTION='de-best'
    $env:WOW112_F1_LIVE_CONFIRM='BUY_ONE_NOW'
    $env:WOW112_AUTOBUY_CONFIRM='YES'
    $env:WOW112_AUTOBUY_MAX_PURCHASES='1'
    $env:WOW112_UNIFIED_DE_MAX_PURCHASES='3'
    $env:WOW112_UNIFIED_DE_MAX_PER_DEID='3'
    $env:WOW112_UNIFIED_DE_MAX_SPEND='30000'
    Write-Host 'DE FAST LIVE3 ARMED: max3 / max3g total / max2g each / exact tuple revalidation.' -ForegroundColor Red
}else{
    $env:WOW112_F1_ACTION='audit'
    $env:WOW112_UNIFIED_DE_MAX_PURCHASES='0'
    Remove-Item Env:WOW112_F1_LIVE_CONFIRM,Env:WOW112_AUTOBUY_CONFIRM -ErrorAction SilentlyContinue
    Write-Host 'DE FAST AUDIT: zero mutation.' -ForegroundColor Cyan
}

$started=Get-Date
$code=99
try{
    & $exe 2>&1 | Tee-Object -FilePath $log
    $code=$LASTEXITCODE
}finally{
    Remove-Item Env:WOW112_F1_LIVE_CONFIRM,Env:WOW112_AUTOBUY_CONFIRM -ErrorAction SilentlyContinue
}
$elapsed=[int]((Get-Date)-$started).TotalSeconds

$sent=0;$server=0;$confirmed=0;$uncertain=0;$livepass=0;$prefilter=''
if(Test-Path $log){
    $sent=@(Select-String -Path $log -SimpleMatch '[POC07-BUY] SENT').Count
    $server=@(Select-String -Path $log -SimpleMatch '[POC07-BUY] SERVER PASS').Count
    $confirmed=@(Select-String -Path $log -SimpleMatch '[POC08-UNIFIED-MULTI] CONFIRMED').Count
    $uncertain=@(Select-String -Path $log -SimpleMatch 'AH_MUTATION_UNCERTAIN').Count
    $livepass=@(Select-String -Path $log -SimpleMatch '[POC08-UNIFIED-MULTI] LIVE PASS').Count
    $prefilter=(Select-String -Path $log -SimpleMatch '[POC08-DE-FAST-PREFILTER] stage=LOCAL_DEID' | Select-Object -Last 1).Line
}
$summary=Join-Path $deDir ($prefix+'_RUN_SUMMARY.txt')
@(
  "mode=$RunMode",
  "stamp=$stamp",
  "exit_code=$code",
  "elapsed_seconds=$elapsed",
  "sent=$sent",
  "server_pass=$server",
  "confirmed=$confirmed",
  "uncertain=$uncertain",
  "live_pass=$livepass",
  "fast_prefilter=$prefilter",
  "exe_sha256=$((Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant())"
) | Set-Content $summary -Encoding UTF8

$report=Join-Path $reports ($prefix+'_'+$stamp+'.zip')
$files=@($log,$summary,$candidates,$f0,$rejected,$prov,$material,(Join-Path $deDir 'POC08_MATERIAL_HISTORY_V3.csv'),(Join-Path $deDir 'LATEST_EXE_SHA256.txt')) | Where-Object {Test-Path $_}
Compress-Archive -Path $files -DestinationPath $report -CompressionLevel Optimal -Force
Copy-Item $report (Join-Path $reports 'LATEST_DE_REPORT.zip') -Force

Write-Host ''
Write-Host ("RUN summary: exit={0} elapsed={1}s sent/server/confirmed={2}/{3}/{4} uncertain={5}" -f $code,$elapsed,$sent,$server,$confirmed,$uncertain)
Write-Host ("AUTO REPORT ZIP: {0}" -f $report) -ForegroundColor Green
Write-Host 'Do wyslania tutaj wystarczy DE_LAB\REPORTS\LATEST_DE_REPORT.zip' -ForegroundColor Green
if($RunMode -eq 'Live3' -and ($uncertain -gt 0 -or $sent -gt 3 -or $sent -ne $server -or $server -ne $confirmed)){
    Write-Host 'SAFETY ALERT: mutation reconciliation mismatch. DO NOT RERUN before review.' -ForegroundColor Red
    if($code -eq 0){$code=3}
}
exit $code
