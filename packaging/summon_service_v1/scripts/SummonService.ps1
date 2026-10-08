[CmdletBinding()]
param(
    [ValidateSet('Start','Stop','Status','Console','Backup','Rollback','Upgrade','Verify','Supervisor')]
    [string]$Action,
    [string]$Root,
    [string]$Package,
    [string]$ExpectedSourceSha,
    [switch]$NoPrompt,
    [string]$CredentialFile,
    [switch]$SkipHashVerification
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-Root([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
    return [IO.Path]::GetFullPath($Path).TrimEnd([char]'\',[char]'/')
}

function Ensure-Layout([string]$PackageRoot) {
    foreach ($name in @('data','logs','state','backups','backups/data','backups/releases')) {
        $p = Join-Path $PackageRoot $name
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
}

function Assert-Writable([string]$PackageRoot) {
    Ensure-Layout $PackageRoot
    $probe = Join-Path $PackageRoot ('state/.write-test-' + [Guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($probe, 'ok'); Remove-Item -LiteralPath $probe -Force }
    catch { throw "Package root is not writable: $PackageRoot" }
}

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing required file: $Path" }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-Config([string]$PackageRoot) { return Read-Json (Join-Path $PackageRoot 'config/service.json') }
function Get-Manifest([string]$PackageRoot) { return Read-Json (Join-Path $PackageRoot 'manifest.json') }

function Get-SafeChildPath([string]$PackageRoot, [string]$RelativePath) {
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw "Manifest/config path must be relative: $RelativePath" }
    $rootFull = (Normalize-Root $PackageRoot) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath((Join-Path $PackageRoot $RelativePath))
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes package root: $RelativePath" }
    return $full
}

function Get-Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Quote-ProcessArg([string]$Value) {
    if ($null -eq $Value) { return '""' }
    if ($Value.Contains('"')) { throw 'Process argument contains an unsupported quote character.' }
    return '"' + $Value + '"'
}

function Verify-Package([string]$PackageRoot, [string]$ExpectedSha) {
    $manifest = Get-Manifest $PackageRoot
    if ($manifest.schema_version -ne 1) { throw 'Unsupported manifest schema.' }
    if (($manifest.source_sha -as [string]) -notmatch '^[0-9a-fA-F]{40}$') { throw 'Manifest source_sha is not an exact 40-hex SHA.' }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha) -and $manifest.source_sha -ne $ExpectedSha) {
        throw "Source SHA mismatch. expected=$ExpectedSha actual=$($manifest.source_sha)"
    }
    foreach ($entry in @($manifest.files)) {
        $rel = $entry.path -as [string]
        $expected = ($entry.sha256 -as [string]).ToLowerInvariant()
        if ($expected -notmatch '^[0-9a-f]{64}$') { throw "Bad SHA256 in manifest: $rel" }
        $full = Get-SafeChildPath $PackageRoot $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Manifest file missing: $rel" }
        $actual = Get-Sha256 $full
        if ($actual -ne $expected) { throw "SHA256 mismatch: $rel" }
    }
    return $manifest
}

function Write-Log([string]$PackageRoot, [string]$Message) {
    $line = [DateTime]::UtcNow.ToString('o') + ' ' + $Message
    $path = Join-Path $PackageRoot 'logs/supervisor.log'
    $cfg = $null
    try { $cfg = Get-Config $PackageRoot } catch { }
    $max = if ($cfg -and $cfg.logging.max_file_bytes) { [int64]$cfg.logging.max_file_bytes } else { 5242880 }
    $keep = if ($cfg -and $cfg.logging.max_files) { [int]$cfg.logging.max_files } else { 10 }
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path
        if ($item.Length -ge $max) {
            for ($i=$keep-1; $i -ge 1; $i--) {
                $old = "$path.$i"; $new = "$path." + ($i+1)
                if (Test-Path -LiteralPath $old) { Move-Item -LiteralPath $old -Destination $new -Force }
            }
            Move-Item -LiteralPath $path -Destination "$path.1" -Force
        }
    }
    Add-Content -LiteralPath $path -Value $line -Encoding UTF8
}

function Prune-ServiceRunLogs([string]$PackageRoot, $Config) {
    $limit = [Math]::Max(2, [int]$Config.logging.max_files)
    $keepExisting = [Math]::Max(0, $limit - 2)
    $files = @(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'logs') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^service-.*\.(out|err)\.log$' } |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($files.Count -gt $keepExisting) {
        $files | Select-Object -Skip $keepExisting | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Get-TrackedProcess([string]$PidFile, [string]$ExpectedExecutable) {
    if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) { return $null }
    try { $pidValue = [int](Get-Content -LiteralPath $PidFile -Raw).Trim(); $p = Get-Process -Id $pidValue -ErrorAction Stop }
    catch { return $null }
    if ($ExpectedExecutable) {
        try {
            $actual = [IO.Path]::GetFullPath($p.Path)
            $expected = [IO.Path]::GetFullPath($ExpectedExecutable)
            if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { return $null }
        } catch { return $null }
    }
    return $p
}

function Save-CredentialDpapi([string]$PackageRoot, $Config, [scriptblock]$PromptProvider = $null) {
    $envName = $Config.credential.environment_variable -as [string]
    if ([string]::IsNullOrWhiteSpace($envName)) { throw 'credential.environment_variable is required.' }
    $plainFromEnv = [Environment]::GetEnvironmentVariable($envName, 'Process')
    $secure = $null
    if (-not [string]::IsNullOrEmpty($plainFromEnv)) {
        $secure = ConvertTo-SecureString $plainFromEnv -AsPlainText -Force
    } elseif ($Config.credential.prompt_if_missing -eq $true) {
        if ($NoPrompt) { throw "Credential source '$envName' is missing and prompting is disabled." }
        if ($PromptProvider) { $secure = & $PromptProvider }
        else { $secure = Read-Host 'WoW password (not logged or written in plaintext)' -AsSecureString }
    } else { throw "Credential source '$envName' is missing." }
    if ($null -eq $secure) { throw 'Credential prompt returned no secret.' }
    $target = Join-Path $PackageRoot 'state/credential.dpapi'
    $cipher = ConvertFrom-SecureString -SecureString $secure
    [IO.File]::WriteAllText($target, $cipher)
    return $target
}

function Start-ServiceSupervisor([string]$PackageRoot) {
    Assert-Writable $PackageRoot
    if (-not $SkipHashVerification) { Verify-Package $PackageRoot $null | Out-Null }
    $cfg = Get-Config $PackageRoot
    $serviceExe = Get-SafeChildPath $PackageRoot ($cfg.service_executable -as [string])
    if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) { throw "Service binary missing: $serviceExe" }
    $supervisorPid = Join-Path $PackageRoot 'state/supervisor.pid'
    $existing = Get-TrackedProcess $supervisorPid $null
    if ($existing) { Write-Host "Summon Service already running (supervisor PID $($existing.Id))."; return }
    Remove-Item -LiteralPath $supervisorPid -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $PackageRoot 'state/supervisor.stop') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $PackageRoot 'state/service.stop') -Force -ErrorAction SilentlyContinue
    $cred = Save-CredentialDpapi $PackageRoot $cfg
    $ps = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $ps)) { $ps = (Get-Command powershell.exe -ErrorAction Stop).Source }
    $args = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File ' + (Quote-ProcessArg $PSCommandPath) + ' -Action Supervisor -Root ' + (Quote-ProcessArg $PackageRoot) + ' -CredentialFile ' + (Quote-ProcessArg $cred)
    $hostOut = Join-Path $PackageRoot 'logs/supervisor-host.out.log'
    $hostErr = Join-Path $PackageRoot 'logs/supervisor-host.err.log'
    $proc = Start-Process -FilePath $ps -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput $hostOut -RedirectStandardError $hostErr
    Set-Content -LiteralPath $supervisorPid -Value $proc.Id -Encoding ASCII
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(5,[int]$cfg.supervisor.health_timeout_seconds))
    do {
        Start-Sleep -Milliseconds 250
        if ($proc.HasExited) {
            $detail = ''
            if (Test-Path -LiteralPath $hostErr) { $detail = (Get-Content -LiteralPath $hostErr -Raw -ErrorAction SilentlyContinue).Trim() }
            if ($detail.Length -gt 1000) { $detail = $detail.Substring(0,1000) }
            throw "Supervisor exited during startup with code $($proc.ExitCode). $detail"
        }
        $servicePidFile = Join-Path $PackageRoot 'state/service.pid'
        if (Test-Path -LiteralPath $servicePidFile) { Write-Host "Summon Service started (supervisor PID $($proc.Id))."; return }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Supervisor started but service PID was not published before timeout.'
}

function Stop-ServiceSupervisor([string]$PackageRoot) {
    Ensure-Layout $PackageRoot
    $pidFile = Join-Path $PackageRoot 'state/supervisor.pid'
    $p = Get-TrackedProcess $pidFile $null
    if (-not $p) {
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        Write-Host 'Summon Service is not running.'
        return
    }
    Set-Content -LiteralPath (Join-Path $PackageRoot 'state/supervisor.stop') -Value ([DateTime]::UtcNow.ToString('o')) -Encoding ASCII
    $cfg = Get-Config $PackageRoot
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(5,[int]$cfg.supervisor.graceful_stop_seconds + 5))
    while (-not $p.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250; $p.Refresh() }
    if (-not $p.HasExited) { throw "Supervisor did not stop after graceful-stop deadline; refusing an implicit hard kill." }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $PackageRoot 'state/credential.dpapi') -Force -ErrorAction SilentlyContinue
    Write-Host 'Summon Service stopped.'
}

function Get-ServiceStatus([string]$PackageRoot, [switch]$Quiet) {
    Ensure-Layout $PackageRoot
    $supervisor = Get-TrackedProcess (Join-Path $PackageRoot 'state/supervisor.pid') $null
    $cfg = $null; try { $cfg = Get-Config $PackageRoot } catch { if (-not $Quiet) { Write-Host "CONFIG ERROR: $($_.Exception.Message)" }; return $false }
    $serviceExe = Get-SafeChildPath $PackageRoot ($cfg.service_executable -as [string])
    $service = Get-TrackedProcess (Join-Path $PackageRoot 'state/service.pid') $serviceExe
    $healthPath = Join-Path $PackageRoot 'state/health.json'
    $healthy = $false
    if ($supervisor -and $service -and (Test-Path -LiteralPath $healthPath)) {
        $age = [DateTime]::UtcNow - (Get-Item -LiteralPath $healthPath).LastWriteTimeUtc
        $healthy = $age.TotalSeconds -le [Math]::Max(3,[int]$cfg.supervisor.health_timeout_seconds)
    }
    if (-not $Quiet) {
        if ($healthy) { Write-Host "RUNNING healthy supervisor=$($supervisor.Id) service=$($service.Id)" }
        elseif ($supervisor) { Write-Host "DEGRADED supervisor=$($supervisor.Id) service=$($(if($service){$service.Id}else{'none'}))" }
        else { Write-Host 'STOPPED' }
    }
    return $healthy
}

function Invoke-Console([string]$PackageRoot) {
    if (-not $SkipHashVerification) { Verify-Package $PackageRoot $null | Out-Null }
    $cfg = Get-Config $PackageRoot
    $exe = Get-SafeChildPath $PackageRoot ($cfg.console_executable -as [string])
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Operator console binary missing: $exe" }
    $consoleArgs = '--root ' + (Quote-ProcessArg $PackageRoot) + ' --events ' + (Quote-ProcessArg (Join-Path $PackageRoot 'data/events.jsonl'))
    Start-Process -FilePath $exe -ArgumentList $consoleArgs | Out-Null
}

function New-DataBackup([string]$PackageRoot) {
    Assert-Writable $PackageRoot
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $stage = Join-Path $env:TEMP ('summon-backup-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        foreach ($name in @('config','data')) {
            $src = Join-Path $PackageRoot $name
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $stage $name) -Recurse -Force }
        }
        $manifest = Get-Manifest $PackageRoot
        @{ source_sha=$manifest.source_sha; version=$manifest.version; created_utc=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'backup.json') -Encoding UTF8
        $zip = Join-Path $PackageRoot "backups/data/data-$stamp.zip"
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
        Write-Host $zip
        return $zip
    } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}

function New-ReleaseSnapshot([string]$PackageRoot) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $manifest = Get-Manifest $PackageRoot
    $zip = Join-Path $PackageRoot "backups/releases/release-$stamp-$($manifest.source_sha).zip"
    $stage = Join-Path $env:TEMP ('summon-release-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        foreach ($name in @('bin','scripts','docs','config','data','manifest.json','VERSION','README.md','START_SUMMON_SERVICE.cmd','STOP_SUMMON_SERVICE.cmd','STATUS_SUMMON_SERVICE.cmd','OPEN_CONSOLE.cmd','BACKUP_DATA.cmd','ROLLBACK.cmd','UPGRADE_SUMMON_SERVICE.cmd')) {
            $src = Join-Path $PackageRoot $name
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $stage $name) -Recurse -Force }
        }
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
        return $zip
    } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}

function Restore-Snapshot([string]$PackageRoot, [string]$Snapshot, [switch]$StartAfter) {
    if (-not (Test-Path -LiteralPath $Snapshot -PathType Leaf)) { throw "Rollback snapshot missing: $Snapshot" }
    Stop-ServiceSupervisor $PackageRoot
    $stage = Join-Path $env:TEMP ('summon-rollback-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        Expand-Archive -LiteralPath $Snapshot -DestinationPath $stage -Force
        Verify-Package $stage $null | Out-Null
        foreach ($name in @('bin','scripts','docs','config','data')) {
            $dst = Join-Path $PackageRoot $name; $src = Join-Path $stage $name
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force }
        }
        foreach ($name in @('manifest.json','VERSION','README.md','START_SUMMON_SERVICE.cmd','STOP_SUMMON_SERVICE.cmd','STATUS_SUMMON_SERVICE.cmd','OPEN_CONSOLE.cmd','BACKUP_DATA.cmd','ROLLBACK.cmd','UPGRADE_SUMMON_SERVICE.cmd')) {
            $src = Join-Path $stage $name
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $PackageRoot $name) -Force }
        }
    } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    if ($StartAfter) { Start-ServiceSupervisor $PackageRoot }
}

function Invoke-Rollback([string]$PackageRoot) {
    Ensure-Layout $PackageRoot
    $snapshot = Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'backups/releases') -Filter 'release-*.zip' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $snapshot) { throw 'No release rollback snapshot available.' }
    Restore-Snapshot $PackageRoot $snapshot.FullName -StartAfter
    if (-not (Get-ServiceStatus $PackageRoot -Quiet)) { throw 'Rollback restored files but health check failed.' }
    Write-Host "Rollback complete: $($snapshot.Name)"
}

function Invoke-Upgrade([string]$PackageRoot, [string]$PackagePath, [string]$ExpectedSha) {
    if ([string]::IsNullOrWhiteSpace($PackagePath) -or -not (Test-Path -LiteralPath $PackagePath)) { throw 'Upgrade package path is required.' }
    Assert-Writable $PackageRoot
    $stage = Join-Path $env:TEMP ('summon-upgrade-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    $snapshot = $null
    try {
        if ((Get-Item -LiteralPath $PackagePath).PSIsContainer) { Get-ChildItem -LiteralPath $PackagePath -Force | Copy-Item -Destination $stage -Recurse -Force }
        else { Expand-Archive -LiteralPath $PackagePath -DestinationPath $stage -Force }
        Verify-Package $stage $ExpectedSha | Out-Null
        New-DataBackup $PackageRoot | Out-Null
        $snapshot = New-ReleaseSnapshot $PackageRoot
        Stop-ServiceSupervisor $PackageRoot
        foreach ($name in @('bin','scripts','docs')) {
            $src = Join-Path $stage $name; $dst = Join-Path $PackageRoot $name
            if (Test-Path -LiteralPath $src) {
                if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
                Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
            }
        }
        foreach ($name in @('manifest.json','VERSION','README.md','START_SUMMON_SERVICE.cmd','STOP_SUMMON_SERVICE.cmd','STATUS_SUMMON_SERVICE.cmd','OPEN_CONSOLE.cmd','BACKUP_DATA.cmd','ROLLBACK.cmd','UPGRADE_SUMMON_SERVICE.cmd')) {
            $src = Join-Path $stage $name
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $PackageRoot $name) -Force }
        }
        $migration = Join-Path $PackageRoot 'scripts/migrate.ps1'
        if (Test-Path -LiteralPath $migration) { & $migration -Root $PackageRoot }
        Start-ServiceSupervisor $PackageRoot
        $cfg = Get-Config $PackageRoot
        $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(5,[int]$cfg.supervisor.health_timeout_seconds))
        do { if (Get-ServiceStatus $PackageRoot -Quiet) { Write-Host 'Upgrade complete and healthy.'; return }; Start-Sleep -Milliseconds 500 } while ([DateTime]::UtcNow -lt $deadline)
        throw 'Post-upgrade health check failed.'
    } catch {
        $failure = $_
        if ($snapshot -and (Test-Path -LiteralPath $snapshot)) {
            Write-Warning "Upgrade failed; rolling back exact pre-upgrade snapshot. $($failure.Exception.Message)"
            try { Restore-Snapshot $PackageRoot $snapshot -StartAfter } catch { throw "Upgrade failed and rollback also failed. upgrade=$($failure.Exception.Message) rollback=$($_.Exception.Message)" }
        }
        throw $failure
    } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-Supervisor([string]$PackageRoot, [string]$DpapiFile) {
    Ensure-Layout $PackageRoot
    $cfg = Get-Config $PackageRoot
    $serviceExe = Get-SafeChildPath $PackageRoot ($cfg.service_executable -as [string])
    $lockPath = Join-Path $PackageRoot 'state/supervisor.lock'
    try {
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        throw 'A supervisor instance already owns this package root.'
    }
    try {
        Set-Content -LiteralPath (Join-Path $PackageRoot 'state/supervisor.pid') -Value $PID -Encoding ASCII
        Write-Log $PackageRoot 'supervisor_started'
        $restartTimes = New-Object Collections.Generic.List[DateTime]
        while (-not (Test-Path -LiteralPath (Join-Path $PackageRoot 'state/supervisor.stop'))) {
            Remove-Item -LiteralPath (Join-Path $PackageRoot 'state/service.stop') -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $DpapiFile)) { throw 'Encrypted credential state is missing.' }
            $cipher = (Get-Content -LiteralPath $DpapiFile -Raw).Trim()
            $secure = ConvertTo-SecureString $cipher
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            $envName = $cfg.credential.environment_variable -as [string]
            [Environment]::SetEnvironmentVariable($envName, $plain, 'Process')
            Prune-ServiceRunLogs $PackageRoot $cfg
            $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
            $stdout = Join-Path $PackageRoot "logs/service-$stamp.out.log"; $stderr = Join-Path $PackageRoot "logs/service-$stamp.err.log"
            Remove-Item -LiteralPath (Join-Path $PackageRoot 'state/health.json') -Force -ErrorAction SilentlyContinue
            $args = '--config ' + (Quote-ProcessArg (Join-Path $PackageRoot 'config/service.json')) + ' --data-dir ' + (Quote-ProcessArg (Join-Path $PackageRoot 'data')) + ' --log-dir ' + (Quote-ProcessArg (Join-Path $PackageRoot 'logs')) + ' --stop-file ' + (Quote-ProcessArg (Join-Path $PackageRoot 'state/service.stop')) + ' --health-file ' + (Quote-ProcessArg (Join-Path $PackageRoot 'state/health.json'))
            $child = Start-Process -FilePath $serviceExe -ArgumentList $args -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            [Environment]::SetEnvironmentVariable($envName, $null, 'Process'); $plain = $null
            Set-Content -LiteralPath (Join-Path $PackageRoot 'state/service.pid') -Value $child.Id -Encoding ASCII
            Write-Log $PackageRoot "service_started pid=$($child.Id)"
            while (-not $child.HasExited) {
                if (Test-Path -LiteralPath (Join-Path $PackageRoot 'state/supervisor.stop')) {
                    Set-Content -LiteralPath (Join-Path $PackageRoot 'state/service.stop') -Value ([DateTime]::UtcNow.ToString('o')) -Encoding ASCII
                    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(1,[int]$cfg.supervisor.graceful_stop_seconds))
                    while (-not $child.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200; $child.Refresh() }
                    if (-not $child.HasExited) { Write-Log $PackageRoot 'service_graceful_stop_timeout hard_kill=true'; Stop-Process -Id $child.Id -Force }
                    break
                }
                Start-Sleep -Milliseconds 250; $child.Refresh()
            }
            Remove-Item -LiteralPath (Join-Path $PackageRoot 'state/service.pid') -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath (Join-Path $PackageRoot 'state/supervisor.stop')) { break }
            $now=[DateTime]::UtcNow; $restartTimes.Add($now)
            $window=[int]$cfg.supervisor.restart_window_seconds
            for ($i=$restartTimes.Count-1; $i -ge 0; $i--) { if (($now-$restartTimes[$i]).TotalSeconds -gt $window) { $restartTimes.RemoveAt($i) } }
            if ($restartTimes.Count -gt [int]$cfg.supervisor.max_restarts) { Write-Log $PackageRoot 'restart_budget_exhausted'; throw 'Crash restart budget exhausted.' }
            Write-Log $PackageRoot "service_exited code=$($child.ExitCode) restart=true"
            Start-Sleep -Seconds ([Math]::Max(0,[int]$cfg.supervisor.restart_backoff_seconds))
        }
        Write-Log $PackageRoot 'supervisor_stopped'
    } finally {
        Remove-Item -LiteralPath (Join-Path $PackageRoot 'state/service.pid') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $PackageRoot 'state/supervisor.pid') -Force -ErrorAction SilentlyContinue
        if ($lock) { $lock.Dispose() }
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Main {
    $packageRoot = Normalize-Root $Root
    try {
        switch ($Action) {
            'Start' { Start-ServiceSupervisor $packageRoot }
            'Stop' { Stop-ServiceSupervisor $packageRoot }
            'Status' { if (Get-ServiceStatus $packageRoot) { exit 0 } else { exit 3 } }
            'Console' { Invoke-Console $packageRoot }
            'Backup' { New-DataBackup $packageRoot | Out-Null }
            'Rollback' { Invoke-Rollback $packageRoot }
            'Upgrade' { Invoke-Upgrade $packageRoot $Package $ExpectedSourceSha }
            'Verify' { Verify-Package $packageRoot $ExpectedSourceSha | Out-Null; Write-Host 'Package verification PASS.' }
            'Supervisor' { Invoke-Supervisor $packageRoot $CredentialFile }
            default { throw 'Action is required.' }
        }
        exit 0
    } catch {
        $stack = $_.ScriptStackTrace
        if ([string]::IsNullOrWhiteSpace($stack)) { Write-Error $_.Exception.Message }
        else { Write-Error ($_.Exception.Message + [Environment]::NewLine + $stack) }
        exit 1
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }
