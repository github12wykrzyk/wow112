param(
    [string]$AuthAddr = "play.octowow.st:3724",
    [string]$WorldAddr = "",
    [int]$RealmIndex = 1,
    [int]$PortalAttempts = 3,
    [int]$ReconnectLimit = 60
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:rows = New-Object System.Collections.ArrayList
$script:adb = $null
$script:adbReady = $false
$script:remoteBase = "/data/local/tmp/wow112-headless-android-probe"
$script:binary = Join-Path $PSScriptRoot "wow112-headless-android-probe"
$configDir = Join-Path $env:LOCALAPPDATA "WoW112PortalClicker"
$configPath = Join-Path $configDir "accounts.json"
$crashPath = Join-Path $configDir "last_gui_crash.txt"

function Resolve-Adb {
    $candidates = @(
        (Join-Path $PSScriptRoot "platform-tools\adb.exe"),
        (Join-Path $PSScriptRoot "adb.exe")
    )
    if ($env:ANDROID_SDK_ROOT) { $candidates += (Join-Path $env:ANDROID_SDK_ROOT "platform-tools\adb.exe") }
    if ($env:ANDROID_HOME) { $candidates += (Join-Path $env:ANDROID_HOME "platform-tools\adb.exe") }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe") }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command adb -ErrorAction SilentlyContinue }
    if ($cmd) { return $cmd.Source }
    throw "Nie znaleziono adb.exe."
}

function Quote-Sh([string]$Value) {
    if ($null -eq $Value) { return "''" }
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Protect-Password([string]$Password) {
    if ([string]::IsNullOrEmpty($Password)) { return "" }
    return ConvertFrom-SecureString (ConvertTo-SecureString $Password -AsPlainText -Force)
}

function Unprotect-Password([string]$Encrypted) {
    if ([string]::IsNullOrWhiteSpace($Encrypted)) { return "" }
    try {
        $secure = ConvertTo-SecureString $Encrypted
        $cred = New-Object System.Management.Automation.PSCredential("saved", $secure)
        return $cred.GetNetworkCredential().Password
    }
    catch { return "" }
}

function Append-Log([string]$Text) {
    if (-not $script:logBox -or $script:logBox.IsDisposed) { return }
    $script:logBox.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] $Text`r`n")
    $script:logBox.SelectionStart = $script:logBox.TextLength
    $script:logBox.ScrollToCaret()
}

function Set-Status($Row, [string]$Text, [System.Drawing.Color]$Color) {
    $Row.Status.Text = $Text
    $Row.Status.ForeColor = $Color
}

function Invoke-AdbShell([string]$Command, [switch]$IgnoreExitCode) {
    if (-not $script:adb) { $script:adb = Resolve-Adb }
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $out = (& $script:adb shell $Command 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    if (-not $IgnoreExitCode -and $code -ne 0) { throw "adb shell failed ($code): $out" }
    return [pscustomobject]@{ Code = $code; Output = $out }
}

function Ensure-AdbReady {
    if ($script:adbReady) { return }
    if (-not (Test-Path -LiteralPath $script:binary)) { throw "Brak binarki: $script:binary" }
    $script:adb = Resolve-Adb
    $script:adbStatus.Text = "ADB: preparing..."
    $script:adbStatus.ForeColor = [System.Drawing.Color]::DarkOrange

    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $script:adb start-server | Out-Null
        $c1 = $LASTEXITCODE
        & $script:adb wait-for-device
        $c2 = $LASTEXITCODE
        & $script:adb push $script:binary $script:remoteBase | Out-Null
        $c3 = $LASTEXITCODE
        & $script:adb shell "chmod 755 $script:remoteBase" | Out-Null
        $c4 = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }

    if ($c1 -ne 0 -or $c2 -ne 0 -or $c3 -ne 0 -or $c4 -ne 0) {
        throw "ADB prepare failed: start=$c1 wait=$c2 push=$c3 chmod=$c4"
    }
    $script:adbReady = $true
    $script:adbStatus.Text = "ADB: READY"
    $script:adbStatus.ForeColor = [System.Drawing.Color]::DarkGreen
    Append-Log "ADB READY"
}

function Get-Paths($Row) {
    $s = $Row.Id.Substring(0,8)
    return [pscustomobject]@{
        Bin = "/data/local/tmp/pclkr_$s"
        Log = "/data/local/tmp/pclkr_$s.log"
        Pid = "/data/local/tmp/pclkr_$s.pid"
    }
}

function Probe-Row($Row) {
    $p = Get-Paths $Row
    $cmd = 'P=$(cat {0} 2>/dev/null); if [ -n "$P" ] && kill -0 $P 2>/dev/null; then echo __RUNNING__; else echo __DEAD__; fi; tail -n 12 {1} 2>/dev/null' -f $p.Pid, $p.Log
    $r = Invoke-AdbShell $cmd -IgnoreExitCode
    $text = $r.Output
    $login = $Row.Login.Text.Trim()

    if ($text -match '__RUNNING__') {
        $Row.Running = $true
        $Row.Stop.Enabled = $true
        $Row.Start.Enabled = $false
        if ($text.Contains('[PORTAL] USE attempt=')) { Set-Status $Row "CLICKED" ([System.Drawing.Color]::DarkBlue) }
        elseif ($text.Contains('[PORTAL] discovered')) { Set-Status $Row "PORTAL" ([System.Drawing.Color]::DarkCyan) }
        elseif ($text.Contains('[PORTAL] CLICKER ACTIVE')) { Set-Status $Row "ACTIVE" ([System.Drawing.Color]::DarkGreen) }
        else { Set-Status $Row "RUNNING" ([System.Drawing.Color]::DarkOrange) }
    }
    else {
        $Row.Running = $false
        $Row.Stop.Enabled = $false
        $Row.Start.Enabled = $true
        Set-Status $Row "STOPPED" ([System.Drawing.Color]::DimGray)
    }

    $clean = @($text -split "`r?`n" | Where-Object { $_ -and $_ -notlike '__*__' })
    if ($clean.Count -gt 0) {
        Append-Log "[$login] " + ($clean -join " | ")
    }
}

function Stop-Row($Row, [bool]$LogIt = $true) {
    try {
        if (-not $script:adb) { $script:adb = Resolve-Adb }
        $p = Get-Paths $Row
        $cmd = 'if [ -f {0} ]; then P=$(cat {0}); if [ -n "$P" ]; then kill $P 2>/dev/null || true; fi; fi; rm -f {0}' -f $p.Pid
        [void](Invoke-AdbShell $cmd -IgnoreExitCode)
        $Row.Running = $false
        $Row.Stop.Enabled = $false
        $Row.Start.Enabled = $true
        Set-Status $Row "STOPPED" ([System.Drawing.Color]::DimGray)
        if ($LogIt) { Append-Log "[$($Row.Login.Text.Trim())] stopped" }
    }
    catch {
        Set-Status $Row "STOP ERROR" ([System.Drawing.Color]::Firebrick)
        Append-Log "[$($Row.Login.Text.Trim())] stop error: $($_.Exception.Message)"
    }
}

function Save-Config {
    try {
        if (-not (Test-Path -LiteralPath $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
        $accounts = @()
        foreach ($row in $script:rows) {
            $accounts += [pscustomobject]@{
                id = $row.Id
                enabled = [bool]$row.Enabled.Checked
                login = $row.Login.Text.Trim()
                password = Protect-Password $row.Password.Text
            }
        }
        [pscustomobject]@{
            version = 4
            authAddr = $script:authBox.Text.Trim()
            worldAddr = $script:worldBox.Text.Trim()
            realmIndex = [int]$script:realmBox.Value
            portalAttempts = [int]$script:attemptsBox.Value
            accounts = $accounts
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
    }
    catch { Append-Log "Config error: $($_.Exception.Message)" }
}

function Load-Config {
    if (-not (Test-Path -LiteralPath $configPath)) { return $null }
    try { return Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json }
    catch { return $null }
}

function Start-Row($Row) {
    $login = $Row.Login.Text.Trim()
    $password = $Row.Password.Text
    if ([string]::IsNullOrWhiteSpace($login)) { return }
    if ([string]::IsNullOrEmpty($password)) {
        Set-Status $Row "BRAK HASLA" ([System.Drawing.Color]::Firebrick)
        return
    }

    try {
        Ensure-AdbReady
        Save-Config
        Stop-Row $Row $false
        $p = Get-Paths $Row
        [void](Invoke-AdbShell ("cp $script:remoteBase $($p.Bin) && chmod 755 $($p.Bin)"))

        $a = New-Object 'System.Collections.Generic.List[string]'
        $a.Add("WOW112_MODE=$(Quote-Sh 'portal-clicker')")
        $a.Add("WOW112_AUTH_ADDR=$(Quote-Sh $script:authBox.Text.Trim())")
        $a.Add("WOW112_ACCOUNT=$(Quote-Sh $login)")
        $a.Add("WOW112_PASSWORD=$(Quote-Sh $password)")
        $a.Add("WOW112_REALM_INDEX=$(Quote-Sh ([string]$script:realmBox.Value))")
        $a.Add("WOW112_SOAK_SECONDS='0'")
        $a.Add("WOW112_RECONNECT_LIMIT=$(Quote-Sh ([string]$ReconnectLimit))")
        $a.Add("WOW112_RECONNECT_DELAY_MS='0'")
        $a.Add("WOW112_PORTAL_ATTEMPTS=$(Quote-Sh ([string]$script:attemptsBox.Value))")
        $world = $script:worldBox.Text.Trim()
        if ($world) { $a.Add("WOW112_WORLD_ADDR=$(Quote-Sh $world)") }

        $envLine = $a -join " "
        $launch = 'rm -f {0} {1}; nohup env {2} {3} >{0} 2>&1 </dev/null & echo $! >{1}' -f $p.Log, $p.Pid, $envLine, $p.Bin
        [void](Invoke-AdbShell $launch)
        Start-Sleep -Milliseconds 350
        Probe-Row $Row
        if (-not $Row.Running) { throw "worker zatrzymal sie po starcie - zobacz log GUI" }
        Append-Log "[$login] worker detached; pierwsza postac na koncie"
    }
    catch {
        $Row.Running = $false
        $Row.Start.Enabled = $true
        $Row.Stop.Enabled = $false
        Set-Status $Row "ERROR" ([System.Drawing.Color]::Firebrick)
        Append-Log "[$login] START ERROR: $($_.Exception.Message)"
    }
}

function Add-Row($Account = $null) {
    $id = if ($Account -and $Account.id) { [string]$Account.id } else { [Guid]::NewGuid().ToString("N") }
    if ($id.Length -lt 8) { $id = [Guid]::NewGuid().ToString("N") }

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Width = 890; $panel.Height = 46
    $enabled = New-Object System.Windows.Forms.CheckBox
    $enabled.Location = New-Object System.Drawing.Point(8,13); $enabled.Width = 22
    $enabled.Checked = if ($Account) { [bool]$Account.enabled } else { $true }
    $login = New-Object System.Windows.Forms.TextBox
    $login.Location = New-Object System.Drawing.Point(38,10); $login.Size = New-Object System.Drawing.Size(190,24)
    if ($Account) { $login.Text = [string]$Account.login }
    $password = New-Object System.Windows.Forms.TextBox
    $password.Location = New-Object System.Drawing.Point(238,10); $password.Size = New-Object System.Drawing.Size(190,24); $password.UseSystemPasswordChar = $true
    if ($Account) { $password.Text = Unprotect-Password ([string]$Account.password) }
    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(438,13); $status.Size = New-Object System.Drawing.Size(128,22); $status.Text = "STOPPED"
    $start = New-Object System.Windows.Forms.Button
    $start.Location = New-Object System.Drawing.Point(575,7); $start.Size = New-Object System.Drawing.Size(80,30); $start.Text = "Start"
    $stop = New-Object System.Windows.Forms.Button
    $stop.Location = New-Object System.Drawing.Point(663,7); $stop.Size = New-Object System.Drawing.Size(80,30); $stop.Text = "Stop"; $stop.Enabled = $false
    $remove = New-Object System.Windows.Forms.Button
    $remove.Location = New-Object System.Drawing.Point(751,7); $remove.Size = New-Object System.Drawing.Size(115,30); $remove.Text = "Usun konto"

    $row = [pscustomobject]@{ Id=$id; Panel=$panel; Enabled=$enabled; Login=$login; Password=$password; Status=$status; Start=$start; Stop=$stop; Remove=$remove; Running=$false }
    $start.Add_Click(({ Start-Row $row }.GetNewClosure()))
    $stop.Add_Click(({ Stop-Row $row $true }.GetNewClosure()))
    $remove.Add_Click(({ Stop-Row $row $false; [void]$script:rows.Remove($row); $script:rowsPanel.Controls.Remove($row.Panel); $row.Panel.Dispose(); Save-Config }.GetNewClosure()))
    $panel.Controls.AddRange(@($enabled,$login,$password,$status,$start,$stop,$remove))
    [void]$script:rows.Add($row)
    $script:rowsPanel.Controls.Add($panel)
}

function Start-All {
    foreach ($row in @($script:rows)) {
        if ($row.Enabled.Checked -and $row.Login.Text.Trim()) {
            Start-Row $row
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 250
        }
    }
}

function Stop-All {
    foreach ($row in @($script:rows)) { if ($row.Running) { Stop-Row $row $false } }
    Append-Log "All stopped"
}

function Refresh-All {
    foreach ($row in @($script:rows)) {
        if ($row.Login.Text.Trim()) {
            try { Probe-Row $row } catch { Append-Log "[$($row.Login.Text.Trim())] refresh error: $($_.Exception.Message)" }
        }
    }
}

$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = "WoW112 Portal Clickers - Detached"
$script:form.Size = New-Object System.Drawing.Size(940,700)
$script:form.MinimumSize = New-Object System.Drawing.Size(940,600)
$script:form.StartPosition = "CenterScreen"

$top = New-Object System.Windows.Forms.Panel
$top.Dock = "Top"; $top.Height = 112
$title = New-Object System.Windows.Forms.Label
$title.Location = New-Object System.Drawing.Point(12,10); $title.Size = New-Object System.Drawing.Size(520,24); $title.Font = New-Object System.Drawing.Font("Segoe UI",12,[System.Drawing.FontStyle]::Bold); $title.Text = "Headless Summoning Portal Clickers - Detached"
$top.Controls.Add($title)

function Add-TopLabel([string]$Text,[int]$X,[int]$Y,[int]$W) { $l=New-Object System.Windows.Forms.Label; $l.Location=New-Object System.Drawing.Point($X,$Y); $l.Size=New-Object System.Drawing.Size($W,22); $l.Text=$Text; $top.Controls.Add($l) }
Add-TopLabel "Auth" 12 43 38
$script:authBox=New-Object System.Windows.Forms.TextBox; $script:authBox.Location=New-Object System.Drawing.Point(52,40); $script:authBox.Size=New-Object System.Drawing.Size(190,24); $script:authBox.Text=$AuthAddr; $top.Controls.Add($script:authBox)
Add-TopLabel "World" 252 43 42
$script:worldBox=New-Object System.Windows.Forms.TextBox; $script:worldBox.Location=New-Object System.Drawing.Point(296,40); $script:worldBox.Size=New-Object System.Drawing.Size(150,24); $script:worldBox.Text=$WorldAddr; $top.Controls.Add($script:worldBox)
Add-TopLabel "Realm" 456 43 44
$script:realmBox=New-Object System.Windows.Forms.NumericUpDown; $script:realmBox.Location=New-Object System.Drawing.Point(502,40); $script:realmBox.Size=New-Object System.Drawing.Size(55,24); $script:realmBox.Minimum=0; $script:realmBox.Maximum=99; $script:realmBox.Value=$RealmIndex; $top.Controls.Add($script:realmBox)
Add-TopLabel "Attempts" 568 43 62
$script:attemptsBox=New-Object System.Windows.Forms.NumericUpDown; $script:attemptsBox.Location=New-Object System.Drawing.Point(632,40); $script:attemptsBox.Size=New-Object System.Drawing.Size(48,24); $script:attemptsBox.Minimum=1; $script:attemptsBox.Maximum=8; $script:attemptsBox.Value=[Math]::Max(1,[Math]::Min(8,$PortalAttempts)); $top.Controls.Add($script:attemptsBox)
$script:adbStatus=New-Object System.Windows.Forms.Label; $script:adbStatus.Location=New-Object System.Drawing.Point(696,43); $script:adbStatus.Size=New-Object System.Drawing.Size(180,22); $script:adbStatus.Text="ADB: not prepared"; $top.Controls.Add($script:adbStatus)

$buttons=@(
    @{T="+ Dodaj konto";X=12;A={ Add-Row; Save-Config }},
    @{T="Start all";X=135;A={ Start-All }},
    @{T="Stop all";X=258;A={ Stop-All }},
    @{T="Odswiez";X=381;A={ Refresh-All }},
    @{T="Zapisz";X=504;A={ Save-Config; Append-Log "Config saved" }}
)
foreach($b in $buttons){ $btn=New-Object System.Windows.Forms.Button; $btn.Location=New-Object System.Drawing.Point($b.X,73); $btn.Size=New-Object System.Drawing.Size(115,30); $btn.Text=$b.T; $btn.Add_Click($b.A); $top.Controls.Add($btn) }

$headers=New-Object System.Windows.Forms.Panel; $headers.Dock="Top"; $headers.Height=28
foreach($h in @(@{X=8;W=25;T="On"},@{X=38;W=190;T="Login"},@{X=238;W=190;T="Haslo"},@{X=438;W=128;T="Status"})) { $l=New-Object System.Windows.Forms.Label; $l.Location=New-Object System.Drawing.Point($h.X,5); $l.Size=New-Object System.Drawing.Size($h.W,20); $l.Text=$h.T; $headers.Controls.Add($l) }
$script:logBox=New-Object System.Windows.Forms.RichTextBox; $script:logBox.Dock="Bottom"; $script:logBox.Height=230; $script:logBox.ReadOnly=$true; $script:logBox.Font=New-Object System.Drawing.Font("Consolas",9)
$script:rowsPanel=New-Object System.Windows.Forms.FlowLayoutPanel; $script:rowsPanel.Dock="Fill"; $script:rowsPanel.FlowDirection="TopDown"; $script:rowsPanel.WrapContents=$false; $script:rowsPanel.AutoScroll=$true
$script:form.Controls.Add($script:rowsPanel); $script:form.Controls.Add($script:logBox); $script:form.Controls.Add($headers); $script:form.Controls.Add($top)

try {
    if (-not (Test-Path -LiteralPath $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    if (Test-Path -LiteralPath $crashPath) { Remove-Item -LiteralPath $crashPath -Force -ErrorAction SilentlyContinue }
    $cfg=Load-Config
    if($cfg){ if($cfg.authAddr){$script:authBox.Text=[string]$cfg.authAddr}; if($null-ne $cfg.worldAddr){$script:worldBox.Text=[string]$cfg.worldAddr}; if($null-ne $cfg.realmIndex){$script:realmBox.Value=[decimal]$cfg.realmIndex}; if($null-ne $cfg.portalAttempts){$script:attemptsBox.Value=[decimal][Math]::Max(1,[Math]::Min(8,[int]$cfg.portalAttempts))}; foreach($a in @($cfg.accounts)){Add-Row $a} }
    while($script:rows.Count-lt 3){Add-Row}
    Append-Log "GUI ready. World moze zostac puste. Pierwsza postac na koncie."
    $script:form.Add_FormClosing({ Save-Config; Stop-All })
    [void]$script:form.ShowDialog()
}
catch {
    try { Set-Content -LiteralPath $crashPath -Encoding UTF8 -Value ("$($_.Exception.Message)`r`n$($_.ScriptStackTrace)") } catch {}
    [System.Windows.Forms.MessageBox]::Show("GUI crash zapisany do:`r`n$crashPath`r`n`r`n$($_.Exception.Message)","Portal Clicker","OK","Error") | Out-Null
    exit 2
}
