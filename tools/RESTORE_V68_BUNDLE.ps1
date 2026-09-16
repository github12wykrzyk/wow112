$ErrorActionPreference = 'Stop'

Write-Host '[V68] RESTORE_V68_BUNDLE.ps1 is deprecated.'
Write-Host '[V68] Canonical V68 is stored as a delta against V67.'
Write-Host '[V68] Runtime: artifacts\V68\runtime\'
Write-Host '[V68] Source : artifacts\V68\source\'
Write-Host '[V68] See README_RESTORE.md in both directories.'
Write-Host '[V68] Do NOT use archives\V68_FULL_NO_EXE_BUNDLE_B64 as source of truth.'
throw 'Deprecated V68 full-bundle restore path intentionally disabled.'
