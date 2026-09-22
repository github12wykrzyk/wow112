# WoW112 Guardian hybrid installer. Run as your normal Windows user.
$ErrorActionPreference = 'Stop'
$repo = 'github12wykrzyk/wow112'
$folder = Join-Path $env:LOCALAPPDATA 'WoW112Guardian'
New-Item -ItemType Directory -Path $folder -Force | Out-Null

function Find-Executable($name, [string[]]$knownPaths) {
    $found = Get-Command $name -ErrorAction SilentlyContinue
    if ($found -and $found.Source -and (Test-Path -LiteralPath $found.Source -PathType Leaf)) {
        return [string]$found.Source
    }
    foreach ($path in $knownPaths) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            return [string](Resolve-Path -LiteralPath $path).Path
        }
    }
    return $null
}
function Require-Program($name, $id, [string[]]$knownPaths) {
    $exe = Find-Executable $name $knownPaths
    if ($exe) {
        Write-Host "Found $name at $exe"
        return $exe
    }
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { throw "Cannot locate $name. winget is unavailable; install $id, then rerun." }
    Write-Host "Installing missing program $id..."
    & $winget.Source install -e --id $id --accept-source-agreements --accept-package-agreements
    $installCode = $LASTEXITCODE
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User') + ';' + $env:Path
    $exe = Find-Executable $name $knownPaths
    if ($exe) { return $exe }
    throw "Cannot locate $name after attempting $id (winget exit code: $installCode). Restart PowerShell or install the program, then rerun."
}

$ghExe = Require-Program 'gh.exe' 'GitHub.cli' @(
    (Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\GitHub CLI\gh.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\gh.exe')
)
$ollamaExe = Require-Program 'ollama.exe' 'Ollama.Ollama' @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
    (Join-Path $env:ProgramFiles 'Ollama\ollama.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ollama.exe')
)
$pyExe = Require-Program 'py.exe' 'Python.Python.3.12' @(
    (Join-Path $env:WINDIR 'py.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Launcher\py.exe'),
    (Join-Path $env:ProgramFiles 'Python Launcher\py.exe')
)
# Resolve the programs to their actual locations for this session and for the scheduled task.
$runtimeDirs = @((Split-Path -Parent $ghExe), (Split-Path -Parent $ollamaExe), (Split-Path -Parent $pyExe))
$runtimePrefix = ($runtimeDirs | Select-Object -Unique) -join ';'
$env:Path = $runtimePrefix + ';' + $env:Path

& $ghExe auth status --hostname github.com *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Sign in to GitHub using your own browser.'
    & $ghExe auth login --hostname github.com --web --scopes repo,workflow
    if ($LASTEXITCODE -ne 0) { throw 'GitHub login failed' }
}
# GitHub CLI may be authenticated without Git for Windows. Do not refresh credentials:
# gh auth refresh can fail while trying to configure a missing git executable.
# The following read-only GitHub API request validates repository access directly.

$ref = (& $ghExe api ("repos/" + $repo + "/git/ref/heads/main") | Out-String | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch main HEAD' }
$sha = [string]$ref.object.sha
if ($sha -notmatch '^[a-f0-9]{40}$') { throw 'Invalid main SHA' }
foreach ($name in @('guardian.py','guardian_local.py')) {
    $endpoint = "repos/" + $repo + "/contents/tools/" + $name + "?ref=" + $sha
    $record = (& $ghExe api $endpoint | Out-String | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or $record.encoding -ne 'base64') { throw "Cannot fetch $name" }
    [IO.File]::WriteAllBytes((Join-Path $folder $name), [Convert]::FromBase64String(($record.content -replace '\s','')))
}

Write-Host 'Downloading local programming model (approximately 5 GB)...'
& $ollamaExe pull qwen2.5-coder:7b
if ($LASTEXITCODE -ne 0) { throw 'Ollama model download failed' }

$runner = Join-Path $folder 'run_guardian.ps1'
$command = @'
$ErrorActionPreference = 'Continue'
$root = Join-Path $env:LOCALAPPDATA 'WoW112Guardian'
Set-Location $root
$log = Join-Path $root 'last_run.log'
"WoW112 Guardian local run" | Out-File -FilePath $log -Encoding utf8
& py -3 (Join-Path $root 'guardian_local.py') 2>&1 | Out-File -FilePath $log -Append -Encoding utf8
exit $LASTEXITCODE
'@
# Persist explicit executable locations in the task's process environment; PATH may be stale in a new session.
$pathLine = '$env:Path = ' + [char]39 + $runtimePrefix.Replace([string][char]39, ([string][char]39 + [string][char]39)) +
            [char]39 + ' + ";" + $env:Path'
$command = $pathLine + [Environment]::NewLine + $command
[IO.File]::WriteAllText($runner, $command, [Text.UTF8Encoding]::new($false))
$taskName = 'WoW112GuardianLocal'
$taskCommand = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $runner + '"'
& schtasks.exe /Create /F /SC HOURLY /MO 1 /TN $taskName /TR $taskCommand
if ($LASTEXITCODE -ne 0) { throw 'Windows Task Scheduler creation failed' }
Write-Host "Installed: $taskName. Runs hourly while Windows user is logged in."
Write-Host "Installed from verified main revision: $sha"
Write-Host "Log: $(Join-Path $folder 'last_run.log')"
Write-Host "Run now: schtasks /Run /TN $taskName"
Write-Host 'Uninstall: schtasks /Delete /F /TN WoW112GuardianLocal'
