param(
    [Parameter(Mandatory=$true)][string]$AhRoot,
    [ValidateSet('Inspect','SettleOne','CancelOne','PostOne','RepostOne')][string]$Mode='Inspect',
    [string]$Arm='',
    [uint32]$AuctionId=0,
    [uint32]$ItemId=0,
    [uint32]$Count=0,
    [uint32]$ExpectedBuyout=0,
    [string]$ItemGuid='',
    [uint32]$Bid=0,
    [uint32]$Buyout=0,
    [uint32]$Floor=0,
    [ValidateSet(120,480,1440)][uint32]$Minutes=120
)

$ErrorActionPreference='Stop'
# LOCAL_CANARY_SINGLE_INVOCATION=YES
# This runner intentionally has no retry loop. The executable/coordinator owns the
# mutation boundary. Any non-zero result after a mutating invocation is terminal.

$ArtifactRoot=[IO.Path]::GetFullPath($PSScriptRoot)
$AhRoot=[IO.Path]::GetFullPath($AhRoot)
$Exe=Join-Path $ArtifactRoot 'wow112-ah-auction-lifecycle-v1.exe'
$ManifestPath=Join-Path $ArtifactRoot 'LIFECYCLE_PACKAGE.json'
$ProfilePath=Join-Path $AhRoot '.wow112_local\profile.json'
$PasswordPath=Join-Path $AhRoot '.wow112_local\password.dpapi'

function Fail([string]$Message){ throw "LOCAL_LIFECYCLE_CANARY: $Message" }
function Secure-ToPlain([Security.SecureString]$Secure){
    $ptr=[IntPtr]::Zero
    try{
        $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }finally{
        if($ptr-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
    }
}
function Clear-MutationEnv {
    foreach($name in @(
        'WOW112_LIFECYCLE_ACTION','WOW112_LIFECYCLE_CONFIRM','WOW112_LIFECYCLE_MAIL_LIMIT',
        'WOW112_LIFECYCLE_AUCTION_ID','WOW112_LIFECYCLE_ITEM_ID','WOW112_LIFECYCLE_COUNT',
        'WOW112_LIFECYCLE_EXPECT_BUYOUT','WOW112_LIFECYCLE_ITEM_GUID','WOW112_LIFECYCLE_BID',
        'WOW112_LIFECYCLE_BUYOUT','WOW112_LIFECYCLE_FLOOR','WOW112_LIFECYCLE_MINUTES',
        'WOW112_F1_LIVE_CONFIRM','WOW112_AUTOBUY_CONFIRM','WOW112_LAUNCHER_ARM'
    )){ Remove-Item ("Env:"+$name) -ErrorAction SilentlyContinue }
}

if(-not(Test-Path $Exe)){Fail "artifact EXE missing: $Exe"}
if(-not(Test-Path $ManifestPath)){Fail 'LIFECYCLE_PACKAGE.json missing'}
if(-not(Test-Path $ProfilePath) -or -not(Test-Path $PasswordPath)){
    Fail "canonical local profile missing under $AhRoot\.wow112_local; run canonical START_AH Setup/EnsureProfile first"
}

$manifest=Get-Content $ManifestPath -Raw | ConvertFrom-Json
if($manifest.final_package -ne 'PASS'){Fail 'artifact final_package is not PASS'}
if($manifest.base_commit -ne '99d0a45b1b62a98214f927f960156ba313de252b'){
    Fail "artifact canonical base mismatch: $($manifest.base_commit)"
}
$exeEntry=$manifest.files.PSObject.Properties['wow112-ah-auction-lifecycle-v1.exe']
if($null -eq $exeEntry){Fail 'manifest EXE entry missing'}
$actualSha=(Get-FileHash $Exe -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedSha=([string]$exeEntry.Value.sha256).ToLowerInvariant()
if($actualSha -ne $expectedSha){Fail "EXE SHA256 mismatch expected=$expectedSha actual=$actualSha"}
$selfEntry=$manifest.files.PSObject.Properties['RUN_LIFECYCLE_LOCAL_CANARY.ps1']
if($null -eq $selfEntry){Fail 'manifest canary entry missing'}
$selfSha=(Get-FileHash $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
if($selfSha -ne ([string]$selfEntry.Value.sha256).ToLowerInvariant()){Fail 'canary script SHA256 mismatch'}

$mutating=$Mode -ne 'Inspect'
if($mutating -and $Arm -cne 'LIFECYCLE_CANARY_ONCE'){
    Fail 'mutation not armed; pass -Arm LIFECYCLE_CANARY_ONCE'
}

# The coordinator is deliberately host-local. Until this feature becomes the only
# local writer, refuse to run beside any older AH terminal executable that cannot
# participate in MutationCoordinatorV1. This is conservative by design.
$otherAh=@(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Id -ne $PID -and (
        $_.ProcessName -like 'wow112-ah-*' -or
        $_.ProcessName -like 'wow112-headless-android-probe*'
    )
})
if($otherAh.Count -gt 0){
    $names=($otherAh | ForEach-Object { "$($_.ProcessName)#$($_.Id)" }) -join ', '
    Fail "another terminal AH runtime is active ($names). Stop it before Lifecycle canary; no legacy concurrent writer is allowed"
}

$profile=Get-Content $ProfilePath -Raw | ConvertFrom-Json
$secure=(Get-Content $PasswordPath -Raw).Trim() | ConvertTo-SecureString
$plain=Secure-ToPlain $secure

Clear-MutationEnv
try{
    $env:WOW112_ACCOUNT=[string]$profile.account
    $env:WOW112_CHARACTER=[string]$profile.character
    $env:WOW112_REALM_INDEX=[string]$profile.realm_index
    $env:WOW112_PASSWORD=$plain
    $env:WOW112_RECONNECT_LIMIT='1'
    $env:WOW112_SOAK_SECONDS='0'
    $env:WOW112_AUTOBUY_ACTION='scan-only'
    $env:WOW112_LIFECYCLE_MAX_PAGES='4096'

    switch($Mode){
        'Inspect' {
            $env:WOW112_LIFECYCLE_ACTION='inspect'
        }
        'SettleOne' {
            $env:WOW112_LIFECYCLE_ACTION='settle'
            $env:WOW112_LIFECYCLE_CONFIRM='YES'
            $env:WOW112_LIFECYCLE_MAIL_LIMIT='1'
        }
        'CancelOne' {
            if($AuctionId -eq 0 -or $ItemId -eq 0 -or $Count -eq 0 -or $ExpectedBuyout -eq 0){Fail 'CancelOne requires AuctionId, ItemId, Count and ExpectedBuyout'}
            $env:WOW112_LIFECYCLE_ACTION='cancel'
            $env:WOW112_LIFECYCLE_CONFIRM='YES'
            $env:WOW112_LIFECYCLE_AUCTION_ID=[string]$AuctionId
            $env:WOW112_LIFECYCLE_ITEM_ID=[string]$ItemId
            $env:WOW112_LIFECYCLE_COUNT=[string]$Count
            $env:WOW112_LIFECYCLE_EXPECT_BUYOUT=[string]$ExpectedBuyout
        }
        'PostOne' {
            if([string]::IsNullOrWhiteSpace($ItemGuid) -or $ItemId -eq 0 -or $Count -eq 0 -or $Bid -eq 0 -or $Buyout -eq 0 -or $Floor -eq 0){Fail 'PostOne requires ItemGuid, ItemId, Count, Bid, Buyout and Floor'}
            $env:WOW112_LIFECYCLE_ACTION='post'
            $env:WOW112_LIFECYCLE_CONFIRM='YES'
            $env:WOW112_LIFECYCLE_ITEM_GUID=$ItemGuid
            $env:WOW112_LIFECYCLE_ITEM_ID=[string]$ItemId
            $env:WOW112_LIFECYCLE_COUNT=[string]$Count
            $env:WOW112_LIFECYCLE_BID=[string]$Bid
            $env:WOW112_LIFECYCLE_BUYOUT=[string]$Buyout
            $env:WOW112_LIFECYCLE_FLOOR=[string]$Floor
            $env:WOW112_LIFECYCLE_MINUTES=[string]$Minutes
        }
        'RepostOne' {
            if($AuctionId -eq 0 -or $ItemId -eq 0 -or $Count -eq 0 -or $ExpectedBuyout -eq 0 -or $Bid -eq 0 -or $Buyout -eq 0 -or $Floor -eq 0){Fail 'RepostOne requires exact old tuple plus Bid, Buyout and Floor'}
            $env:WOW112_LIFECYCLE_ACTION='repost'
            $env:WOW112_LIFECYCLE_CONFIRM='YES'
            $env:WOW112_LIFECYCLE_AUCTION_ID=[string]$AuctionId
            $env:WOW112_LIFECYCLE_ITEM_ID=[string]$ItemId
            $env:WOW112_LIFECYCLE_COUNT=[string]$Count
            $env:WOW112_LIFECYCLE_EXPECT_BUYOUT=[string]$ExpectedBuyout
            $env:WOW112_LIFECYCLE_BID=[string]$Bid
            $env:WOW112_LIFECYCLE_BUYOUT=[string]$Buyout
            $env:WOW112_LIFECYCLE_FLOOR=[string]$Floor
            $env:WOW112_LIFECYCLE_MINUTES=[string]$Minutes
        }
    }

    Write-Host ("[LOCAL-LIFECYCLE] mode={0} account={1} character={2} realm={3} exact_artifact={4} base={5}" -f $Mode,$env:WOW112_ACCOUNT,$env:WOW112_CHARACTER,$env:WOW112_REALM_INDEX,$manifest.commit,$manifest.base_commit) -ForegroundColor Cyan
    if($mutating){
        Write-Host '[LOCAL-LIFECYCLE] MUTATION CANARY: exactly one process invocation; zero supervisor retry.' -ForegroundColor Red
        Write-Host '[LOCAL-LIFECYCLE] Existing same-host coordinator lock/pending state is authoritative; this script never deletes or clears it.' -ForegroundColor Yellow
    }

    # Exactly one executable invocation. Never wrap this in a retry loop.
    & $Exe
    $code=if($null -eq $LASTEXITCODE){1}else{[int]$LASTEXITCODE}
    if($code -ne 0){
        if($mutating){
            Write-Host ("[LOCAL-LIFECYCLE] HARD STOP exit={0}; NO RETRY. Reconcile coordinator/server state manually before any next mutation." -f $code) -ForegroundColor Red
        }
        exit $code
    }
    Write-Host ("[LOCAL-LIFECYCLE] PASS mode={0}" -f $Mode) -ForegroundColor Green
    exit 0
}finally{
    $plain=$null
    Clear-MutationEnv
    Remove-Item Env:WOW112_PASSWORD -ErrorAction SilentlyContinue
}
