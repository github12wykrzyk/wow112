param(
    [ValidateSet('EnsureProfile','Setup','Vendor','DeLive3','DeAudit','UnifiedLive','UnifiedAudit')]
    [string]$Mode='EnsureProfile'
)

$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$StateDir=Join-Path $Root '.wow112_local'
$ProfilePath=Join-Path $StateDir 'profile.json'
$PasswordPath=Join-Path $StateDir 'password.dpapi'

function Write-Profile {
    New-Item -ItemType Directory -Force $StateDir | Out-Null
    $account=Read-Host 'Login WoW [Enter=octowar1]'
    if([string]::IsNullOrWhiteSpace($account)){$account='octowar1'}
    $character=Read-Host 'Postac [Enter=Smokinpole]'
    if([string]::IsNullOrWhiteSpace($character)){$character='Smokinpole'}
    $realmRaw=Read-Host 'Realm index [Enter=1]'
    $realm=1
    if(-not [string]::IsNullOrWhiteSpace($realmRaw)){
        if(-not [int]::TryParse($realmRaw,[ref]$realm)){throw 'Realm index musi byc liczba.'}
    }
    $secure=Read-Host 'Haslo WoW - zostanie zapisane przez Windows DPAPI' -AsSecureString
    if($secure.Length -eq 0){throw 'Haslo nie moze byc puste.'}
    [pscustomobject]@{account=$account;character=$character;realm_index=$realm} |
        ConvertTo-Json | Set-Content -Path $ProfilePath -Encoding UTF8
    $secure | ConvertFrom-SecureString | Set-Content -Path $PasswordPath -Encoding ASCII
    Write-Host 'Profil zapisany. Haslo nie jest zapisane jako jawny tekst.' -ForegroundColor Green
}

function Get-Profile {
    if(-not(Test-Path $ProfilePath) -or -not(Test-Path $PasswordPath)){Write-Profile}
    try{
        $profile=Get-Content $ProfilePath -Raw | ConvertFrom-Json
        $secure=(Get-Content $PasswordPath -Raw).Trim() | ConvertTo-SecureString
    }catch{
        Write-Host 'Zapisany profil/DPAPI jest nieczytelny. Tworze go ponownie.' -ForegroundColor Yellow
        Remove-Item $ProfilePath,$PasswordPath -Force -ErrorAction SilentlyContinue
        Write-Profile
        $profile=Get-Content $ProfilePath -Raw | ConvertFrom-Json
        $secure=(Get-Content $PasswordPath -Raw).Trim() | ConvertTo-SecureString
    }
    return @($profile,$secure)
}

function Secure-ToPlain([Security.SecureString]$Secure){
    $ptr=[IntPtr]::Zero
    try{
        $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }finally{
        if($ptr-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
    }
}

if($Mode -eq 'Setup'){
    Remove-Item $ProfilePath,$PasswordPath -Force -ErrorAction SilentlyContinue
    Write-Profile
    exit 0
}
if($Mode -eq 'EnsureProfile'){
    [void](Get-Profile)
    exit 0
}

$data=Get-Profile
$profile=$data[0]
$secure=$data[1]
$plain=Secure-ToPlain $secure
try{
    $env:WOW112_ACCOUNT=[string]$profile.account
    $env:WOW112_CHARACTER=[string]$profile.character
    $env:WOW112_REALM_INDEX=[string]$profile.realm_index
    $env:WOW112_PASSWORD=$plain

    switch($Mode){
        'Vendor'{
            Write-Host 'HOTKEY V: VENDOR STABLE REAL BUY - AUTO ARMED' -ForegroundColor Yellow
            & (Join-Path $PSScriptRoot 'RUN_VENDOR_STABLE_HOTKEY.ps1') -Root $Root -Account $env:WOW112_ACCOUNT -Character $env:WOW112_CHARACTER -RealmIndex ([int]$env:WOW112_REALM_INDEX)
            exit $LASTEXITCODE
        }
        'DeLive3'{
            Write-Host 'HOTKEY D: DE FAST LIVE x3 - REAL BUY AUTO ARMED' -ForegroundColor Red
            $env:WOW112_LAUNCHER_ARM='DE_LIVE3'
            & (Join-Path $PSScriptRoot 'RUN_DE_LAB.ps1') -Root $Root -RunMode Live3 -Strategy De
            exit $LASTEXITCODE
        }
        'DeAudit'{
            Write-Host 'HOTKEY A: DE FAST AUDIT - ZERO BUY' -ForegroundColor Cyan
            Remove-Item Env:WOW112_LAUNCHER_ARM -ErrorAction SilentlyContinue
            & (Join-Path $PSScriptRoot 'RUN_DE_LAB.ps1') -Root $Root -RunMode Audit -Strategy De
            exit $LASTEXITCODE
        }
        'UnifiedLive'{
            Write-Host 'HOTKEY U: UNIFIED VENDOR+DE V4 - REAL BUY AUTO ARMED' -ForegroundColor Red
            $env:WOW112_LAUNCHER_ARM='VENDOR_DE_V4'
            & (Join-Path $PSScriptRoot 'RUN_DE_LAB.ps1') -Root $Root -RunMode Live3 -Strategy VendorDe
            exit $LASTEXITCODE
        }
        'UnifiedAudit'{
            Write-Host 'HOTKEY T: UNIFIED VENDOR+DE V4 AUDIT - ZERO BUY' -ForegroundColor Cyan
            Remove-Item Env:WOW112_LAUNCHER_ARM -ErrorAction SilentlyContinue
            & (Join-Path $PSScriptRoot 'RUN_DE_LAB.ps1') -Root $Root -RunMode Audit -Strategy VendorDe
            exit $LASTEXITCODE
        }
    }
}finally{
    $plain=$null
    Remove-Item Env:WOW112_PASSWORD,Env:WOW112_LAUNCHER_ARM -ErrorAction SilentlyContinue
}
