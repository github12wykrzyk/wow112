param(
    [Parameter(Mandatory=$true)][string]$AhRoot,
    [string]$MailboxGuid='0xF11002A4A5002A0C'
)

$ErrorActionPreference='Stop'
$runner=Join-Path $PSScriptRoot 'RUN_LIFECYCLE_LOCAL_CANARY.ps1'
if(-not(Test-Path $runner)){throw "RUN_SETTLE_ONE_PROVEN_MAILBOX: missing $runner"}
if([string]::IsNullOrWhiteSpace($MailboxGuid)){throw 'RUN_SETTLE_ONE_PROVEN_MAILBOX: MailboxGuid must not be empty'}

# Read-only mailbox selection override only. The underlying Lifecycle canary owns
# the mutation permit, single invocation rule and hard-stop/no-retry semantics.
$old=$env:WOW112_MAILBOX_GUID
try {
    $env:WOW112_MAILBOX_GUID=$MailboxGuid
    Write-Host ("[SETTLE-CANARY] mailbox_override={0} mode=SettleOne single_invocation=YES" -f $MailboxGuid) -ForegroundColor Cyan
    & $runner -AhRoot $AhRoot -Mode SettleOne -Arm LIFECYCLE_CANARY_ONCE
    exit $LASTEXITCODE
} finally {
    if($null -eq $old){Remove-Item Env:WOW112_MAILBOX_GUID -ErrorAction SilentlyContinue}else{$env:WOW112_MAILBOX_GUID=$old}
}
