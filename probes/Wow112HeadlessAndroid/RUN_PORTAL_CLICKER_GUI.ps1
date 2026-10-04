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
$script:eventQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:startQueue = New-Object System.Collections.Queue
$script:adb = $null
$script:adbReady = $false
$script:closing = $false
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
    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if (-not $command) { $command = Get-Command adb -ErrorAction SilentlyContinue }
    if ($command) { return $command.Source }
    throw "Nie znaleziono adb.exe. Dodaj Android SDK platform-tools do PATH albo ustaw ANDROID_SDK_ROOT/ANDROID_HOME."
}

function Quote-Sh([string]$Value) {
    if ($null -eq $Value) { return "''" }
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Protect-Password([string]$Password) {
    if ([string]::IsNullOrEmpty($Password)) { return "" }
    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    return ConvertFrom-SecureString $secure
}

function Unprotect-Password([string]$Encrypted) {
    if ([string]::IsNullOrWhiteSpace($Encrypted)) { return "" }
    try {
        $secure = ConvertTo-SecureString $Encrypted
        $credential = New-Object System.Management.Automation.PSCredential("saved", $secure)
        return $credential.GetNetworkCredential().Password
    }
    catch { return "" }
}

function Append-Log([string]$Text) {
    if (-not $script:logBox -or $script:logBox.IsDisposed) { return }
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $script:logBox.AppendText("[$stamp] $Text`r`n")
    $script:logBox.SelectionStart = $script:logBox.TextLength
    $script:logBox.ScrollToCaret()
}

function Set-RowStatus($Row, [string]$Text, [System.Drawing.Color]$Color) {
    if ($null -eq $Row -or $null -eq $Row.Status -or $Row.Status.IsDisposed) { return }
    $Row.Status.Text = $Text
    $Row.Status.ForeColor = $Color
}

function Find-Row([string]$Id) {
    foreach ($row in $script:rows) {
        if ($row.Id -eq $Id) { return $row }
    }
    return $null
}

function Set-AdbStatus([string]$Text, [System.Drawing.Color]$Color) {
    if ($script:adbStatus -and -not $script:adbStatus.IsDisposed) {
        $script:adbStatus.Text = $Text
        $script:adbStatus.ForeColor = $Color
    }
}

function Ensure-AdbReady {
    if ($script:adbReady) { return }
    if (-not (Test-Path -LiteralPath $script:binary)) { throw "Brak binarki: $script:binary" }

    $script:adb = Resolve-Adb
    Set-AdbStatus "ADB: preparing..." ([System.Drawing.Color]::DarkOrange)
    Append-Log "ADB start-server"
    & $script:adb start-server | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "adb start-server failed: $LASTEXITCODE" }

    Append-Log "Waiting for Android device/emulator"
    & $script:adb wait-for-device
    if ($LASTEXITCODE -ne 0) { throw "adb wait-for-device failed: $LASTEXITCODE" }

    Append-Log "Uploading headless binary"
    & $script:adb push $script:binary $script:remoteBase | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "adb push failed: $LASTEXITCODE" }
    & $script:adb shell "chmod 755 $script:remoteBase" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "adb chmod failed: $LASTEXITCODE" }

    $script:adbReady = $true
    Set-AdbStatus "ADB: READY" ([System.Drawing.Color]::DarkGreen)
    Append-Log "ADB READY"
}

function Get-RowRemoteName($Row) {
    return "pclkr_" + $Row.Id.Substring(0, 8)
}

function Stop-RemoteSlot($Row, [bool]$LogIt = $true) {
    try {
        if (-not $script:adb) { $script:adb = Resolve-Adb }
        $remoteName = Get-RowRemoteName $Row
        $raw = (& $script:adb shell "pidof $remoteName" 2>$null | Out-String).Trim()
        if ($raw) {
            foreach ($pidText in ($raw -split '\s+')) {
                if ($pidText -match '^\d+$') { & $script:adb shell "kill $pidText" | Out-Null }
            }
            if ($LogIt) { Append-Log "[$($Row.Login.Text)] remote process stopped" }
        }
    }
    catch {
        if ($LogIt) { Append-Log "[$($Row.Login.Text)] stop warning: $($_.Exception.Message)" }
    }

    if ($Row.Process) {
        try { if (-not $Row.Process.HasExited) { $Row.Process.Kill() } } catch {}
        $Row.Process = $null
    }
    Set-RowStatus $Row "STOPPED" ([System.Drawing.Color]::DimGray)
    $Row.Start.Enabled = $true
    $Row.Stop.Enabled = $false
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
        $cfg = [pscustomobject]@{
            version = 2
            authAddr = $script:authBox.Text.Trim()
            worldAddr = $script:worldBox.Text.Trim()
            realmIndex = [int]$script:realmBox.Value
            portalAttempts = [int]$script:attemptsBox.Value
            accounts = $accounts
        }
        $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
    }
    catch { Append-Log "Config save error: $($_.Exception.Message)" }
}

function Load-Config {
    if (-not (Test-Path -LiteralPath $configPath)) { return $null }
    try { return (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json) }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Nie mozna wczytac configu. Startuje pusty config.`r`n$($_.Exception.Message)", "Portal Clicker", "OK", "Warning") | Out-Null
        return $null
    }
}

function Start-Row($Row) {
    $login = $Row.Login.Text.Trim()
    $password = $Row.Password.Text
    if ([string]::IsNullOrWhiteSpace($login)) { return }
    if ([string]::IsNullOrEmpty($password)) {
        Set-RowStatus $Row "BRAK HASLA" ([System.Drawing.Color]::Firebrick)
        Append-Log "[$login] pominiety: brak hasla"
        return
    }
    if ($Row.Process) {
        try { if (-not $Row.Process.HasExited) { return } } catch {}
    }

    try {
        Ensure-AdbReady
        Save-Config
        Stop-RemoteSlot $Row $false

        $remoteName = Get-RowRemoteName $Row
        $remoteSlot = "/data/local/tmp/$remoteName"
        & $script:adb shell "cp $script:remoteBase $remoteSlot && chmod 755 $remoteSlot" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Nie udalo sie przygotowac $remoteSlot" }

        $assignments = New-Object 'System.Collections.Generic.List[string]'
        $assignments.Add("WOW112_MODE=$(Quote-Sh 'portal-clicker')")
        $assignments.Add("WOW112_AUTH_ADDR=$(Quote-Sh $script:authBox.Text.Trim())")
        $assignments.Add("WOW112_ACCOUNT=$(Quote-Sh $login)")
        $assignments.Add("WOW112_PASSWORD=$(Quote-Sh $password)")
        $assignments.Add("WOW112_REALM_INDEX=$(Quote-Sh ([string]$script:realmBox.Value))")
        $assignments.Add("WOW112_SOAK_SECONDS='0'")
        $assignments.Add("WOW112_RECONNECT_LIMIT=$(Quote-Sh ([string]$ReconnectLimit))")
        $assignments.Add("WOW112_RECONNECT_DELAY_MS='0'")
        $assignments.Add("WOW112_PORTAL_ATTEMPTS=$(Quote-Sh ([string]$script:attemptsBox.Value))")
        $world = $script:worldBox.Text.Trim()
        if (-not [string]::IsNullOrWhiteSpace($world)) { $assignments.Add("WOW112_WORLD_ADDR=$(Quote-Sh $world)") }
        $remoteCommand = "exec env " + ($assignments -join " ") + " " + (Quote-Sh $remoteSlot)

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:adb
        $psi.Arguments = "shell"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $proc.EnableRaisingEvents = $true

        $queue = $script:eventQueue
        $idForOutput = $Row.Id
        $outHandler = {
            param($sender, $e)
            if (-not [string]::IsNullOrWhiteSpace($e.Data)) {
                $queue.Enqueue([pscustomobject]@{ Kind = 'OUT'; Id = $idForOutput; Text = $e.Data })
            }
        }.GetNewClosure()
        $errHandler = {
            param($sender, $e)
            if (-not [string]::IsNullOrWhiteSpace($e.Data)) {
                $queue.Enqueue([pscustomobject]@{ Kind = 'ERR'; Id = $idForOutput; Text = $e.Data })
            }
        }.GetNewClosure()
        $exitHandler = {
            param($sender, $e)
            $code = -1
            try { $code = $sender.ExitCode } catch {}
            $queue.Enqueue([pscustomobject]@{ Kind = 'EXIT'; Id = $idForOutput; Code = $code })
        }.GetNewClosure()

        $proc.add_OutputDataReceived($outHandler)
        $proc.add_ErrorDataReceived($errHandler)
        $proc.add_Exited($exitHandler)
        if (-not $proc.Start()) { throw "Nie udalo sie uruchomic adb shell." }
        $Row.Process = $proc
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()
        $proc.StandardInput.WriteLine($remoteCommand)
        $proc.StandardInput.Close()

        Set-RowStatus $Row "STARTING" ([System.Drawing.Color]::DarkOrange)
        $Row.Start.Enabled = $false
        $Row.Stop.Enabled = $true
        Append-Log "[$login] starting; pierwsza postac na koncie"
    }
    catch {
        Set-RowStatus $Row "ERROR" ([System.Drawing.Color]::Firebrick)
        $Row.Start.Enabled = $true
        $Row.Stop.Enabled = $false
        Append-Log "[$login] START ERROR: $($_.Exception.Message)"
    }
}

function Add-AccountRow($Account = $null) {
    $id = if ($Account -and $Account.id) { [string]$Account.id } else { [Guid]::NewGuid().ToString("N") }
    if ($id.Length -lt 8) { $id = [Guid]::NewGuid().ToString("N") }

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Width = 890
    $panel.Height = 46
    $panel.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 1)

    $enabled = New-Object System.Windows.Forms.CheckBox
    $enabled.Location = New-Object System.Drawing.Point(8, 13)
    $enabled.Width = 22
    $enabled.Checked = if ($Account) { [bool]$Account.enabled } else { $true }

    $login = New-Object System.Windows.Forms.TextBox
    $login.Location = New-Object System.Drawing.Point(38, 10)
    $login.Size = New-Object System.Drawing.Size(190, 24)
    if ($Account) { $login.Text = [string]$Account.login }

    $password = New-Object System.Windows.Forms.TextBox
    $password.Location = New-Object System.Drawing.Point(238, 10)
    $password.Size = New-Object System.Drawing.Size(190, 24)
    $password.UseSystemPasswordChar = $true
    if ($Account) { $password.Text = Unprotect-Password ([string]$Account.password) }

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(438, 13)
    $status.Size = New-Object System.Drawing.Size(128, 22)
    $status.Text = "STOPPED"
    $status.ForeColor = [System.Drawing.Color]::DimGray

    $start = New-Object System.Windows.Forms.Button
    $start.Location = New-Object System.Drawing.Point(575, 7)
    $start.Size = New-Object System.Drawing.Size(80, 30)
    $start.Text = "Start"

    $stop = New-Object System.Windows.Forms.Button
    $stop.Location = New-Object System.Drawing.Point(663, 7)
    $stop.Size = New-Object System.Drawing.Size(80, 30)
    $stop.Text = "Stop"
    $stop.Enabled = $false

    $remove = New-Object System.Windows.Forms.Button
    $remove.Location = New-Object System.Drawing.Point(751, 7)
    $remove.Size = New-Object System.Drawing.Size(115, 30)
    $remove.Text = "Usun konto"

    $row = [pscustomobject]@{
        Id = $id; Panel = $panel; Enabled = $enabled; Login = $login; Password = $password
        Status = $status; Start = $start; Stop = $stop; Remove = $remove; Process = $null
    }

    $start.Add_Click(({ try { Start-Row $row } catch { Append-Log "START handler: $($_.Exception.Message)" } }.GetNewClosure()))
    $stop.Add_Click(({ try { Stop-RemoteSlot $row $true } catch { Append-Log "STOP handler: $($_.Exception.Message)" } }.GetNewClosure()))
    $remove.Add_Click(({
        try {
            Stop-RemoteSlot $row $false
            [void]$script:rows.Remove($row)
            $script:rowsPanel.Controls.Remove($row.Panel)
            $row.Panel.Dispose()
            Save-Config
        }
        catch { Append-Log "REMOVE handler: $($_.Exception.Message)" }
    }.GetNewClosure()))

    $panel.Controls.AddRange(@($enabled, $login, $password, $status, $start, $stop, $remove))
    [void]$script:rows.Add($row)
    $script:rowsPanel.Controls.Add($panel)
}

function Start-All {
    try {
        Ensure-AdbReady
        Save-Config
        $script:startAllTimer.Stop()
        $script:startQueue.Clear()
        foreach ($row in @($script:rows)) {
            if ($row.Enabled.Checked -and -not [string]::IsNullOrWhiteSpace($row.Login.Text)) {
                $script:startQueue.Enqueue($row)
            }
        }
        Append-Log "Start all: kolejka $($script:startQueue.Count) kont"
        if ($script:startQueue.Count -gt 0) {
            $row = $script:startQueue.Dequeue()
            Start-Row $row
            if ($script:startQueue.Count -gt 0) { $script:startAllTimer.Start() }
        }
    }
    catch { Append-Log "START ALL ERROR: $($_.Exception.Message)" }
}

function Stop-All {
    try {
        $script:startAllTimer.Stop()
        $script:startQueue.Clear()
        foreach ($row in @($script:rows)) { Stop-RemoteSlot $row $false }
        Append-Log "All clickers stopped"
    }
    catch { Append-Log "STOP ALL ERROR: $($_.Exception.Message)" }
}

$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = "WoW112 Headless Portal Clickers - SAFE GUI"
$script:form.Size = New-Object System.Drawing.Size(940, 700)
$script:form.MinimumSize = New-Object System.Drawing.Size(940, 600)
$script:form.StartPosition = "CenterScreen"

$top = New-Object System.Windows.Forms.Panel
$top.Dock = "Top"
$top.Height = 112

$title = New-Object System.Windows.Forms.Label
$title.Location = New-Object System.Drawing.Point(12, 10)
$title.Size = New-Object System.Drawing.Size(500, 24)
$title.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$title.Text = "Headless Summoning Portal Clickers - SAFE GUI"
$top.Controls.Add($title)

$authLabel = New-Object System.Windows.Forms.Label
$authLabel.Location = New-Object System.Drawing.Point(12, 43)
$authLabel.Size = New-Object System.Drawing.Size(38, 22)
$authLabel.Text = "Auth"
$top.Controls.Add($authLabel)

$script:authBox = New-Object System.Windows.Forms.TextBox
$script:authBox.Location = New-Object System.Drawing.Point(52, 40)
$script:authBox.Size = New-Object System.Drawing.Size(190, 24)
$script:authBox.Text = $AuthAddr
$top.Controls.Add($script:authBox)

$worldLabel = New-Object System.Windows.Forms.Label
$worldLabel.Location = New-Object System.Drawing.Point(252, 43)
$worldLabel.Size = New-Object System.Drawing.Size(42, 22)
$worldLabel.Text = "World"
$top.Controls.Add($worldLabel)

$script:worldBox = New-Object System.Windows.Forms.TextBox
$script:worldBox.Location = New-Object System.Drawing.Point(296, 40)
$script:worldBox.Size = New-Object System.Drawing.Size(150, 24)
$script:worldBox.Text = $WorldAddr
$top.Controls.Add($script:worldBox)

$realmLabel = New-Object System.Windows.Forms.Label
$realmLabel.Location = New-Object System.Drawing.Point(456, 43)
$realmLabel.Size = New-Object System.Drawing.Size(44, 22)
$realmLabel.Text = "Realm"
$top.Controls.Add($realmLabel)

$script:realmBox = New-Object System.Windows.Forms.NumericUpDown
$script:realmBox.Location = New-Object System.Drawing.Point(502, 40)
$script:realmBox.Size = New-Object System.Drawing.Size(55, 24)
$script:realmBox.Minimum = 0
$script:realmBox.Maximum = 99
$script:realmBox.Value = $RealmIndex
$top.Controls.Add($script:realmBox)

$attemptsLabel = New-Object System.Windows.Forms.Label
$attemptsLabel.Location = New-Object System.Drawing.Point(568, 43)
$attemptsLabel.Size = New-Object System.Drawing.Size(62, 22)
$attemptsLabel.Text = "Attempts"
$top.Controls.Add($attemptsLabel)

$script:attemptsBox = New-Object System.Windows.Forms.NumericUpDown
$script:attemptsBox.Location = New-Object System.Drawing.Point(632, 40)
$script:attemptsBox.Size = New-Object System.Drawing.Size(48, 24)
$script:attemptsBox.Minimum = 1
$script:attemptsBox.Maximum = 8
$script:attemptsBox.Value = [Math]::Max(1, [Math]::Min(8, $PortalAttempts))
$top.Controls.Add($script:attemptsBox)

$script:adbStatus = New-Object System.Windows.Forms.Label
$script:adbStatus.Location = New-Object System.Drawing.Point(696, 43)
$script:adbStatus.Size = New-Object System.Drawing.Size(170, 22)
$script:adbStatus.Text = "ADB: not prepared"
$script:adbStatus.ForeColor = [System.Drawing.Color]::DimGray
$top.Controls.Add($script:adbStatus)

$add = New-Object System.Windows.Forms.Button
$add.Location = New-Object System.Drawing.Point(12, 73)
$add.Size = New-Object System.Drawing.Size(115, 30)
$add.Text = "+ Dodaj konto"
$add.Add_Click({ try { Add-AccountRow; Save-Config } catch { Append-Log "ADD ERROR: $($_.Exception.Message)" } })
$top.Controls.Add($add)

$startAll = New-Object System.Windows.Forms.Button
$startAll.Location = New-Object System.Drawing.Point(135, 73)
$startAll.Size = New-Object System.Drawing.Size(115, 30)
$startAll.Text = "Start all"
$startAll.Add_Click({ Start-All })
$top.Controls.Add($startAll)

$stopAll = New-Object System.Windows.Forms.Button
$stopAll.Location = New-Object System.Drawing.Point(258, 73)
$stopAll.Size = New-Object System.Drawing.Size(115, 30)
$stopAll.Text = "Stop all"
$stopAll.Add_Click({ Stop-All })
$top.Controls.Add($stopAll)

$save = New-Object System.Windows.Forms.Button
$save.Location = New-Object System.Drawing.Point(381, 73)
$save.Size = New-Object System.Drawing.Size(115, 30)
$save.Text = "Zapisz"
$save.Add_Click({ Save-Config; Append-Log "Config saved" })
$top.Controls.Add($save)

$configLabel = New-Object System.Windows.Forms.Label
$configLabel.Location = New-Object System.Drawing.Point(510, 79)
$configLabel.Size = New-Object System.Drawing.Size(390, 22)
$configLabel.Text = "Bez pola Postac: zawsze pierwsza postac na koncie."
$top.Controls.Add($configLabel)

$headers = New-Object System.Windows.Forms.Panel
$headers.Dock = "Top"
$headers.Height = 28
$headerTexts = @(
    @{ X = 8; W = 25; T = "On" },
    @{ X = 38; W = 190; T = "Login" },
    @{ X = 238; W = 190; T = "Haslo" },
    @{ X = 438; W = 128; T = "Status" }
)
foreach ($h in $headerTexts) {
    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point($h.X, 5)
    $label.Size = New-Object System.Drawing.Size($h.W, 20)
    $label.Text = $h.T
    $label.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $headers.Controls.Add($label)
}

$script:logBox = New-Object System.Windows.Forms.RichTextBox
$script:logBox.Dock = "Bottom"
$script:logBox.Height = 230
$script:logBox.ReadOnly = $true
$script:logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$script:logBox.BackColor = [System.Drawing.Color]::White

$script:rowsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$script:rowsPanel.Dock = "Fill"
$script:rowsPanel.FlowDirection = "TopDown"
$script:rowsPanel.WrapContents = $false
$script:rowsPanel.AutoScroll = $true
$script:rowsPanel.Padding = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)

$script:form.Controls.Add($script:rowsPanel)
$script:form.Controls.Add($script:logBox)
$script:form.Controls.Add($headers)
$script:form.Controls.Add($top)

$script:startAllTimer = New-Object System.Windows.Forms.Timer
$script:startAllTimer.Interval = 900
$script:startAllTimer.Add_Tick({
    try {
        $script:startAllTimer.Stop()
        if ($script:startQueue.Count -gt 0) {
            $next = $script:startQueue.Dequeue()
            Start-Row $next
        }
        if ($script:startQueue.Count -gt 0) { $script:startAllTimer.Start() }
    }
    catch { Append-Log "START QUEUE ERROR: $($_.Exception.Message)" }
})

$script:eventTimer = New-Object System.Windows.Forms.Timer
$script:eventTimer.Interval = 150
$script:eventTimer.Add_Tick({
    try {
        $evt = $null
        while ($script:eventQueue.TryDequeue([ref]$evt)) {
            $row = Find-Row ([string]$evt.Id)
            if (-not $row) { continue }
            $login = $row.Login.Text.Trim()
            if ($evt.Kind -eq 'OUT') {
                $line = [string]$evt.Text
                Append-Log "[$login] $line"
                if ($line.Contains('[PORTAL] CLICKER ACTIVE')) { Set-RowStatus $row "ACTIVE" ([System.Drawing.Color]::DarkGreen) }
                elseif ($line.Contains('[PORTAL] USE attempt=')) { Set-RowStatus $row "CLICKED" ([System.Drawing.Color]::DarkBlue) }
                elseif ($line.Contains('[PORTAL] discovered')) { Set-RowStatus $row "PORTAL FOUND" ([System.Drawing.Color]::DarkCyan) }
            }
            elseif ($evt.Kind -eq 'ERR') {
                Append-Log "[$login][ERR] $($evt.Text)"
                Set-RowStatus $row "ERROR" ([System.Drawing.Color]::Firebrick)
            }
            elseif ($evt.Kind -eq 'EXIT') {
                if (-not $script:closing) {
                    Set-RowStatus $row "EXIT $($evt.Code)" ([System.Drawing.Color]::Firebrick)
                    Append-Log "[$login] adb session exited: $($evt.Code)"
                }
                $row.Process = $null
                $row.Start.Enabled = $true
                $row.Stop.Enabled = $false
            }
            $evt = $null
        }
    }
    catch { Append-Log "EVENT QUEUE ERROR: $($_.Exception.Message)" }
})
$script:eventTimer.Start()

try {
    $config = Load-Config
    if ($config) {
        if ($config.authAddr) { $script:authBox.Text = [string]$config.authAddr }
        if ($null -ne $config.worldAddr) { $script:worldBox.Text = [string]$config.worldAddr }
        if ($null -ne $config.realmIndex) { $script:realmBox.Value = [decimal]$config.realmIndex }
        if ($null -ne $config.portalAttempts) { $script:attemptsBox.Value = [decimal][Math]::Max(1, [Math]::Min(8, [int]$config.portalAttempts)) }
        foreach ($account in @($config.accounts)) { Add-AccountRow $account }
    }
    while ($script:rows.Count -lt 3) { Add-AccountRow }

    $buildInfo = Join-Path $PSScriptRoot "BUILD_INFO.txt"
    if (Test-Path -LiteralPath $buildInfo) {
        $exact = Get-Content -LiteralPath $buildInfo | Where-Object { $_ -like 'EXACT_SHA=*' } | Select-Object -First 1
        if ($exact) { Append-Log $exact }
    }
    Append-Log "SAFE GUI ready. Start all uruchamia konta co 900 ms."

    $script:form.Add_FormClosing({
        param($sender, $e)
        if ($script:closing) { return }
        $running = $false
        foreach ($row in $script:rows) {
            if ($row.Process) { try { if (-not $row.Process.HasExited) { $running = $true; break } } catch {} }
        }
        if ($running) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Zamkniecie GUI zatrzyma wszystkie uruchomione clickery. Zamknac?",
                "Portal Clicker",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
        }
        $script:closing = $true
        $script:eventTimer.Stop()
        Save-Config
        Stop-All
    })

    [void]$script:form.ShowDialog()
}
catch {
    try {
        if (-not (Test-Path -LiteralPath $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
        $details = "$(Get-Date -Format o)`r`n$($_ | Out-String)`r`n$($_.ScriptStackTrace)"
        Set-Content -LiteralPath $crashPath -Value $details -Encoding UTF8
    }
    catch {}
    [System.Windows.Forms.MessageBox]::Show("GUI crash: $($_.Exception.Message)`r`nLog: $crashPath", "Portal Clicker GUI", "OK", "Error") | Out-Null
    exit 1
}
