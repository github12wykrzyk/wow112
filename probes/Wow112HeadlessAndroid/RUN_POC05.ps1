param(
    [string]$AuthAddr = "play.octowow.st:3724",
    [string]$WorldAddr = "",
    [string]$AhGuid = "",
    [string]$MailboxGuid = "",
    [int]$RealmIndex = 1,
    [int]$SoakSeconds = 60,
    [int]$ReconnectLimit = 60,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Resolve-Adb {
    $candidates = @(
        (Join-Path $PSScriptRoot "platform-tools\adb.exe"),
        (Join-Path $PSScriptRoot "adb.exe")
    )

    if ($env:ANDROID_SDK_ROOT) {
        $candidates += (Join-Path $env:ANDROID_SDK_ROOT "platform-tools\adb.exe")
    }
    if ($env:ANDROID_HOME) {
        $candidates += (Join-Path $env:ANDROID_HOME "platform-tools\adb.exe")
    }
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe")
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command adb -ErrorAction SilentlyContinue
    }
    if ($command) {
        return $command.Source
    }

    throw "Nie znaleziono adb.exe. Dodaj Android SDK platform-tools do PATH albo ustaw ANDROID_SDK_ROOT/ANDROID_HOME."
}

function Quote-Sh([string]$Value) {
    if ($null -eq $Value) {
        return "''"
    }
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Add-EnvAssignment([System.Collections.Generic.List[string]]$List, [string]$Name, [string]$Value) {
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $List.Add("$Name=$(Quote-Sh $Value)")
    }
}

$binary = Join-Path $PSScriptRoot "wow112-headless-android-probe"
$buildInfo = Join-Path $PSScriptRoot "BUILD_INFO.txt"
$remoteBinary = "/data/local/tmp/wow112-headless-android-probe"

try {
    Write-Host "============================================================"
    Write-Host "WoW112 Android Headless - POC-05"
    Write-Host "INVENTORY + GOLD + GUARDED MAIL ACTIONS"
    Write-Host "============================================================"
    if (Test-Path -LiteralPath $buildInfo) {
        Get-Content -LiteralPath $buildInfo | ForEach-Object { Write-Host $_ }
        Write-Host ""
    }

    if (-not (Test-Path -LiteralPath $binary)) {
        throw "Brak binarki w paczce: $binary"
    }

    $adb = Resolve-Adb
    Write-Host "[CONFIG] Auth: $AuthAddr"
    Write-Host "[CONFIG] RealmIndex: $RealmIndex"
    if ([string]::IsNullOrWhiteSpace($WorldAddr)) {
        Write-Host "[CONFIG] World: from realm list"
    } else {
        Write-Host "[CONFIG] World: $WorldAddr"
    }
    Write-Host "[1/4] ADB: $adb"
    & $adb start-server | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "adb start-server failed: $LASTEXITCODE" }

    Write-Host "[2/4] Czekam na emulator/urzadzenie ADB..."
    & $adb wait-for-device
    if ($LASTEXITCODE -ne 0) { throw "adb wait-for-device failed: $LASTEXITCODE" }

    Write-Host "[3/4] Wgrywanie binarki..."
    & $adb push $binary $remoteBinary | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "adb push failed: $LASTEXITCODE" }
    & $adb shell "chmod 755 $remoteBinary" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "adb chmod failed: $LASTEXITCODE" }

    $account = (Read-Host "Login WoW").Trim()
    if ([string]::IsNullOrWhiteSpace($account)) {
        throw "Login WoW nie moze byc pusty."
    }

    $securePassword = Read-Host "Haslo WoW" -AsSecureString
    $credential = New-Object System.Management.Automation.PSCredential($account, $securePassword)
    $password = $credential.GetNetworkCredential().Password
    if ([string]::IsNullOrEmpty($password)) {
        throw "Haslo WoW nie moze byc puste."
    }

    $character = (Read-Host "Postac [Enter=pierwsza postac]").Trim()

    Write-Host ""
    Write-Host "Wybierz tryb POC-05:"
    Write-Host "  [Enter/0] read-only (bez mutacji mailboxa)"
    Write-Host "  [1]       take-money z jednego mail_id"
    Write-Host "  [2]       take-item z jednego mail_id"
    $mode = (Read-Host "Tryb").Trim()

    $mailAction = "read-only"
    $mailId = ""
    $mailConfirm = ""
    switch ($mode) {
        "" { $mailAction = "read-only" }
        "0" { $mailAction = "read-only" }
        "1" { $mailAction = "take-money" }
        "2" { $mailAction = "take-item" }
        default { throw "Nieznany tryb POC-05: $mode" }
    }

    if ($mailAction -ne "read-only") {
        $mailId = (Read-Host "mail_id do operacji $mailAction").Trim()
        if ($mailId -notmatch '^\d+$') {
            throw "mail_id musi byc liczba dziesietna."
        }
        [void][uint32]::Parse($mailId)
        $mailConfirm = (Read-Host "Mutacja mailboxa. Wpisz dokladnie YES, aby uzbroic operacje").Trim()
        if ($mailConfirm -cne "YES") {
            throw "Anulowano: brak dokladnego potwierdzenia YES."
        }
    }

    $assignments = New-Object 'System.Collections.Generic.List[string]'
    Add-EnvAssignment $assignments "WOW112_AUTH_ADDR" $AuthAddr
    Add-EnvAssignment $assignments "WOW112_ACCOUNT" $account
    Add-EnvAssignment $assignments "WOW112_PASSWORD" $password
    Add-EnvAssignment $assignments "WOW112_REALM_INDEX" ([string]$RealmIndex)
    Add-EnvAssignment $assignments "WOW112_SOAK_SECONDS" ([string]$SoakSeconds)
    Add-EnvAssignment $assignments "WOW112_RECONNECT_LIMIT" ([string]$ReconnectLimit)
    Add-EnvAssignment $assignments "WOW112_RECONNECT_DELAY_MS" "0"
    Add-EnvAssignment $assignments "WOW112_CHARACTER" $character
    Add-EnvAssignment $assignments "WOW112_WORLD_ADDR" $WorldAddr
    Add-EnvAssignment $assignments "WOW112_AH_GUID" $AhGuid
    Add-EnvAssignment $assignments "WOW112_MAILBOX_GUID" $MailboxGuid
    Add-EnvAssignment $assignments "WOW112_MAIL_ACTION" $mailAction
    Add-EnvAssignment $assignments "WOW112_MAIL_ID" $mailId
    Add-EnvAssignment $assignments "WOW112_MAIL_MUTATION_CONFIRM" $mailConfirm

    $remoteCommand = (($assignments -join " ") + " " + $remoteBinary)
    Write-Host "[4/4] Start POC-05. Retry login/world: natychmiast. Niepewna mutacja mailboxa: bez auto-retry."
    & $adb shell $remoteCommand
    $probeExit = $LASTEXITCODE

    $password = $null
    $credential = $null
    if ($securePassword) { $securePassword.Dispose() }

    if ($probeExit -ne 0) {
        throw "POC-05 zakonczyl sie kodem $probeExit."
    }
    Write-Host ""
    Write-Host "POC-05 zakonczony kodem 0."
}
catch {
    Write-Host ""
    Write-Error $_
    exit 2
}
finally {
    if (-not $NoPause) {
        Write-Host ""
        [void](Read-Host "Enter aby zamknac")
    }
}
