[CmdletBinding()]
param([string]$SourceSha = $env:GITHUB_SHA)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($SourceSha -notmatch '^[0-9a-fA-F]{40}$'){ $SourceSha='1111111111111111111111111111111111111111' }
$pkgSource=Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$work=Join-Path $env:TEMP ('summon-packaging-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$results=New-Object Collections.Generic.List[object]
$root=$null
function Record([string]$Name,[scriptblock]$Body){
  try { & $Body; $results.Add([pscustomobject]@{Test=$Name;Result='PASS'}); Write-Host "PASS $Name" }
  catch { $results.Add([pscustomobject]@{Test=$Name;Result='FAIL'}); Write-Host "FAIL $Name :: $($_.Exception.Message)"; throw }
}
function Build-Fixtures([string]$Out,[switch]$BadHealth){
  New-Item -ItemType Directory -Path $Out -Force | Out-Null
  $csc="$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"; if(-not(Test-Path $csc)){$csc="$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"}
  if(-not(Test-Path $csc)){throw 'Windows .NET Framework csc.exe unavailable on CI runner.'}
  $healthLine=if($BadHealth){''}else{'File.WriteAllText(health, "{\"ready\":true}");'}
  $service=@"
using System; using System.IO; using System.Threading;
class P { static string A(string[] a,string k){for(int i=0;i<a.Length-1;i++)if(a[i]==k)return a[i+1];return null;}
static int Main(string[] a){var stop=A(a,"--stop-file");var health=A(a,"--health-file");var data=A(a,"--data-dir");
if(data!=null && File.Exists(Path.Combine(data,"crash_once.request"))){File.Delete(Path.Combine(data,"crash_once.request"));return 23;}
while(true){if(data!=null && File.Exists(Path.Combine(data,"crash_once.request"))){File.Delete(Path.Combine(data,"crash_once.request"));return 23;} $healthLine if(stop!=null && File.Exists(stop)) return 0; Thread.Sleep(200);} } }
"@
  $console='using System; class P { static int Main(string[] a){ return 0; } }'
  Set-Content (Join-Path $Out 'service.cs') $service -Encoding UTF8; Set-Content (Join-Path $Out 'console.cs') $console -Encoding UTF8
  & $csc /nologo /target:exe /out:"$Out\WoW112SummonService.exe" "$Out\service.cs" | Out-Host; if($LASTEXITCODE){throw 'service fixture compile failed'}
  & $csc /nologo /target:exe /out:"$Out\WoW112SummonOperatorConsole.exe" "$Out\console.cs" | Out-Host; if($LASTEXITCODE){throw 'console fixture compile failed'}
}
function New-Package([string]$Version,[switch]$BadHealth){
  $bin=Join-Path $work ('bin-'+$Version+[Guid]::NewGuid().ToString('N')); Build-Fixtures $bin -BadHealth:$BadHealth
  $zip=Join-Path $work ("SummonService-$Version.zip")
  & (Join-Path $pkgSource 'scripts/Build-Package.ps1') -InputBinDir $bin -SourceSha $SourceSha -Version $Version -OutputZip $zip -DemoOnly
  if($LASTEXITCODE){throw 'Build-Package failed'}
  return $zip
}
function Expand-Package([string]$Zip,[string]$Name){$d=Join-Path $work $Name;New-Item -ItemType Directory $d|Out-Null;Expand-Archive $Zip $d -Force;return $d}
function Run([string]$Root,[string]$Action,[int[]]$Ok=@(0),[string]$Package=$null,[string]$Expected=$null){
  $script=Join-Path $Root 'scripts/SummonService.ps1'; $args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-Action',$Action,'-Root',$Root,'-NoPrompt')
  if($Package){$args+=@('-Package',$Package)};if($Expected){$args+=@('-ExpectedSourceSha',$Expected)}
  & powershell.exe @args | Out-Host; $c=$LASTEXITCODE; if($Ok -notcontains $c){throw "$Action exit=$c expected=$($Ok -join ',')"};return $c
}
try {
  $zip1=New-Package '1.0.0'; $root=Expand-Package $zip1 'live'; $env:WOW112_PASSWORD='PACKAGING_CANARY_SECRET'
  Record 'fresh install + exact manifest' { Run $root Verify | Out-Null; if(-not(Test-Path (Join-Path $root 'START_SUMMON_SERVICE.cmd'))){throw 'launcher missing'} }
  Record 'stop when not running is idempotent' { Run $root Stop | Out-Null }
  Record 'start twice keeps one supervisor' { Run $root Start | Out-Null; Start-Sleep 1; $p1=(Get-Content (Join-Path $root 'state/supervisor.pid') -Raw).Trim(); Run $root Start | Out-Null; $p2=(Get-Content (Join-Path $root 'state/supervisor.pid') -Raw).Trim(); if($p1-ne$p2){throw 'duplicate supervisor'}; Run $root Status | Out-Null }
  Record 'crash restart policy' { Set-Content (Join-Path $root 'data/crash_once.request') x; $before=(Get-Content (Join-Path $root 'state/service.pid') -Raw).Trim(); $deadline=(Get-Date).AddSeconds(10); do{Start-Sleep 1;$after=if(Test-Path (Join-Path $root 'state/service.pid')){(Get-Content (Join-Path $root 'state/service.pid') -Raw).Trim()}else{''}}while($after-eq$before -and (Get-Date)-lt$deadline); if(!$after -or $after-eq$before){throw 'service was not restarted'}; Run $root Status | Out-Null }
  Record 'data backup' { Run $root Backup | Out-Null; if(-not(Get-ChildItem (Join-Path $root 'backups/data') -Filter '*.zip')){throw 'backup missing'} }
  $zip2=New-Package '1.1.0'
  Record 'upgrade + health' { Run $root Upgrade -Package $zip2 -Expected $SourceSha | Out-Null; if((Get-Content (Join-Path $root VERSION)-Raw).Trim()-ne'1.1.0'){throw 'version not upgraded'}; Run $root Status | Out-Null }
  Record 'failed upgrade rolls back' { $bad=New-Package '1.2.0-badhealth' -BadHealth; $c=Run $root Upgrade -Ok @(1) -Package $bad -Expected $SourceSha; Start-Sleep 1; if((Get-Content (Join-Path $root VERSION)-Raw).Trim()-ne'1.1.0'){throw 'failed upgrade did not roll back'}; Run $root Status | Out-Null }
  Record 'manual rollback' { Run $root Rollback | Out-Null; Run $root Status | Out-Null }
  Record 'missing binary fails closed' { Run $root Stop | Out-Null; $exe=Join-Path $root 'bin/WoW112SummonService.exe'; $hold="$exe.hold"; Move-Item $exe $hold; try { Run $root Start -Ok @(1)|Out-Null } finally { Move-Item $hold $exe }; }
  Record 'bad SHA256 fails closed' { $exe=Join-Path $root 'bin/WoW112SummonOperatorConsole.exe'; $hold=Join-Path $work 'console-before-tamper.exe'; Copy-Item $exe $hold -Force; try { [IO.File]::AppendAllText($exe,'tamper'); Run $root Verify -Ok @(1)|Out-Null } finally { Copy-Item $hold $exe -Force } }
  Record 'config missing fails closed' { $cfg=Join-Path $root 'config/service.json'; $hold="$cfg.hold"; Move-Item $cfg $hold; try { Run $root Start -Ok @(1)|Out-Null } finally { Move-Item $hold $cfg } }
  Record 'password prompt branch uses SecureString and DPAPI' { . (Join-Path $pkgSource 'scripts/SummonService.ps1'); $old=$env:WOW112_PASSWORD; Remove-Item Env:WOW112_PASSWORD -ErrorAction SilentlyContinue; try { Ensure-Layout $root; $cfg=Get-Config $root; $f=Save-CredentialDpapi $root $cfg { ConvertTo-SecureString 'prompt-secret' -AsPlainText -Force }; if(-not(Test-Path $f)){throw 'DPAPI file missing'}; if((Get-Content $f -Raw)-match'prompt-secret'){throw 'plaintext leaked to DPAPI file'} } finally { $env:WOW112_PASSWORD=$old } }
  Record 'logs contain no credential canary' { Run $root Start | Out-Null; Start-Sleep 1; Run $root Stop | Out-Null; $hits=Get-ChildItem (Join-Path $root logs) -File -Recurse | Select-String -SimpleMatch 'PACKAGING_CANARY_SECRET' -ErrorAction SilentlyContinue; if($hits){throw 'credential found in logs'} }
  Record 'read-only root rejected' { $ro=Expand-Package $zip1 'readonly'; $acl=Get-Acl $ro; $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User; $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,'Write,Modify','ContainerInherit,ObjectInherit','None','Deny'); $acl.AddAccessRule($rule)|Out-Null; Set-Acl $ro $acl; try { Run $ro Start -Ok @(1)|Out-Null } finally { $acl=Get-Acl $ro; $acl.RemoveAccessRuleSpecific($rule); Set-Acl $ro $acl } }
  $results | Format-Table -AutoSize | Out-Host
  Write-Host 'PACKAGING TEST SUITE PASS'
} finally {
  try { if($root){ & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts/SummonService.ps1') -Action Stop -Root $root | Out-Null } } catch {}
  Remove-Item Env:WOW112_PASSWORD -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
