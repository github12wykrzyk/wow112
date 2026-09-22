# WoW112 Guardian hybrid installer. Run as your normal Windows user.
$ErrorActionPreference = 'Stop'
$repo = 'github12wykrzyk/wow112'
$folder = Join-Path $env:LOCALAPPDATA 'WoW112Guardian'
New-Item -ItemType Directory -Path $folder -Force | Out-Null

function Require-Program($name, $id) {
    if (Get-Command $name -ErrorAction SilentlyContinue) { return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "Missing $name. Install $id through winget and rerun."
    }
    Write-Host "Installing $id..."
    & winget install -e --id $id --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget failed: $id" }
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User') + ';' + $env:Path
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Restart PowerShell after installing $id and rerun this installer."
    }
}
Require-Program 'gh.exe' 'GitHub.cli'
Require-Program 'ollama.exe' 'Ollama.Ollama'
Require-Program 'py.exe' 'Python.Python.3.12'

& gh auth status --hostname github.com *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Sign in to GitHub using your own browser.'
    & gh auth login --hostname github.com --web --scopes repo,workflow
    if ($LASTEXITCODE -ne 0) { throw 'GitHub login failed' }
}
# GitHub CLI may be authenticated without Git for Windows. Do not refresh credentials:
# gh auth refresh can fail while trying to configure a missing git executable.
# The following read-only GitHub API request validates repository access directly.

$ref = (& gh api ("repos/" + $repo + "/git/ref/heads/main") | Out-String | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch main HEAD' }
$sha = [string]$ref.object.sha
if ($sha -notmatch '^[a-f0-9]{40}$') { throw 'Invalid main SHA' }
foreach ($name in @('guardian.py','guardian_local.py')) {
    $endpoint = "repos/" + $repo + "/contents/tools/" + $name + "?ref=" + $sha
    $record = (& gh api $endpoint | Out-String | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or $record.encoding -ne 'base64') { throw "Cannot fetch $name" }
    [IO.File]::WriteAllBytes((Join-Path $folder $name), [Convert]::FromBase64String(($record.content -replace '\s','')))
}

Write-Host 'Downloading local programming model (approximately 5 GB)...'
& ollama pull qwen2.5-coder:7b
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
