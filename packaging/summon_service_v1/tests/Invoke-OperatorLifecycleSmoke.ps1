[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Root)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$rootFull=[IO.Path]::GetFullPath($Root)
$work=Join-Path $env:TEMP ('summon-launcher-smoke-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

function Run-Launcher([string]$Name,[int]$Expected=0,[int]$TimeoutSeconds=35){
  $launcher=Join-Path $rootFull $Name
  if(-not(Test-Path -LiteralPath $launcher -PathType Leaf)){throw "launcher missing: $Name"}
  $out=Join-Path $work ($Name+'.out.log'); $err=Join-Path $work ($Name+'.err.log')
  $args='/d /s /c ""'+$launcher+'""'
  Write-Host "LAUNCHER START name=$Name expected=$Expected timeout=${TimeoutSeconds}s"
  $p=Start-Process -FilePath 'cmd.exe' -ArgumentList $args -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  if(-not $p.WaitForExit($TimeoutSeconds*1000)){
    try{$p.Kill()}catch{}
    throw "$Name timed out after ${TimeoutSeconds}s"
  }
  $p.WaitForExit(); $p.Refresh()
  $stdout=if(Test-Path $out){Get-Content $out -Raw}else{''}; $stderr=if(Test-Path $err){Get-Content $err -Raw}else{''}
  if($stdout){Write-Host $stdout.TrimEnd()}; if($stderr){Write-Host "STDERR $($stderr.TrimEnd())"}
  if($p.ExitCode -ne $Expected){throw "$Name exit=$($p.ExitCode) expected=$Expected"}
  Write-Host "LAUNCHER PASS name=$Name exit=$($p.ExitCode)"
}

$env:WOW112_PASSWORD='PACKAGING_WRAPPER_CANARY_SECRET'
try {
  Run-Launcher 'START_SUMMON_SERVICE.cmd' 0 35
  Run-Launcher 'STATUS_SUMMON_SERVICE.cmd' 0 20
  Run-Launcher 'BACKUP_DATA.cmd' 0 60
  Run-Launcher 'STATUS_SUMMON_SERVICE.cmd' 0 20
  Run-Launcher 'OPEN_CONSOLE.cmd' 0 20
  Run-Launcher 'STOP_SUMMON_SERVICE.cmd' 0 35
  Run-Launcher 'OPEN_CONSOLE.cmd' 3 20
  $backups=@(Get-ChildItem -LiteralPath (Join-Path $rootFull 'backups/data') -Filter '*.zip' -File)
  if($backups.Count -lt 1){throw 'safe backup launcher produced no backup'}
  $hits=Get-ChildItem -LiteralPath (Join-Path $rootFull 'logs') -File -Recurse -ErrorAction SilentlyContinue | Select-String -SimpleMatch 'PACKAGING_WRAPPER_CANARY_SECRET' -ErrorAction SilentlyContinue
  if($hits){throw 'credential canary leaked to logs'}
  Write-Host "OPERATOR LIFECYCLE SMOKE PASS backups=$($backups.Count)"
} finally {
  Remove-Item Env:WOW112_PASSWORD -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
