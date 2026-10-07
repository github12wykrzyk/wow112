Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$root = 'probes/Wow112HeadlessAndroid'
$tools = "$root/tools"
$src = "$root/src"
$cacheDir = "$root/.ci-cache/de"
$norm = Join-Path $cacheDir 'poc08-full-cache-normalized.csv'
$unresolved = Join-Path $cacheDir 'poc08-full-unresolved.csv'
$itemIds = "$tools/poc08_live_item_ids_20261005.txt"
New-Item -ItemType Directory -Force $cacheDir | Out-Null

Write-Host '[CI-FAST] harden shared BUY primitive'
python "$tools/vendor_mailbox_fastfix_patch.py" "$src/world_poc07.rs"
python "$tools/poc07_buy_neighborhood_patch.py" "$src/world_poc07.rs"
python "$tools/poc05_ah_hello_resilience_patch.py" "$src/world_poc05_retry.rs"

Write-Host '[CI-FAST] generate DE model base'
python "$tools/poc07_de_v4_patch.py" "$src/world_poc07_delive_v2.rs" "$src/world_poc07_delive_v4.rs"
python "$tools/poc07_de_v5_patch.py" "$src/world_poc07_delive_v4.rs" "$src/world_poc07_delive_v5.rs"
python "$tools/poc07_de_v52_turbo_patch.py" "$src/world_poc07_delive_v5.rs" "$src/world_poc07_delive_v52.rs"
python "$tools/poc07_de_v53_class_ceiling_patch.py" "$src/world_poc07_delive_v52.rs" "$src/world_poc07_delive_v53.rs"

function Test-DeCache([string]$CachePath, [string]$UnresolvedPath) {
  if (-not (Test-Path $CachePath) -or -not (Test-Path $UnresolvedPath)) { return $false }
  try {
    $expected = @(Get-Content $itemIds | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    $rows = @(Import-Csv $CachePath)
    $actual = @($rows | ForEach-Object { [int]$_.item_id } | Sort-Object -Unique)
    if ($rows.Count -lt 2200 -or $actual.Count -ne $expected.Count) { return $false }
    if (@(Compare-Object -ReferenceObject $expected -DifferenceObject $actual).Count -ne 0) { return $false }
    if (@(Import-Csv $UnresolvedPath).Count -ne 0) { return $false }
    return $true
  } catch { return $false }
}

$cacheSource = 'actions-cache'
if (-not (Test-DeCache $norm $unresolved)) {
  $cacheSource = 'prior-artifact'
  Write-Host '[DE-CACHE] miss; try prior successful artifact with identical cache inputs'
  $inputs = @(
    "$tools/build_de_cache_poc08_e0.py",
    "$tools/v52_seed_cache.csv",
    $itemIds,
    "$tools/poc08_de_cache_to_rust_provenance.py"
  )
  $artifactRoot = Join-Path $env:RUNNER_TEMP 'de-cache-prior-artifact'
  try {
    $runs = @((gh api "/repos/$env:GITHUB_REPOSITORY/actions/workflows/build_windows_ah_de_liquidation_v3.yml/runs?branch=$env:GITHUB_REF_NAME&status=success&per_page=10" | ConvertFrom-Json).workflow_runs)
    foreach ($run in $runs) {
      $oldSha = [string]$run.head_sha
      if ([string]::IsNullOrWhiteSpace($oldSha) -or $oldSha -eq $env:GITHUB_SHA) { continue }
      try { git fetch --no-tags --depth=1 origin $oldSha 2>$null } catch { continue }
      $nativePref = $PSNativeCommandUseErrorActionPreference
      $PSNativeCommandUseErrorActionPreference = $false
      git diff --quiet $oldSha $env:GITHUB_SHA -- @inputs
      $diffCode = $LASTEXITCODE
      $PSNativeCommandUseErrorActionPreference = $nativePref
      if ($diffCode -eq 1) { continue }
      if ($diffCode -ne 0) { continue }
      $arts = @((gh api "/repos/$env:GITHUB_REPOSITORY/actions/runs/$($run.id)/artifacts?per_page=100" | ConvertFrom-Json).artifacts)
      $art = $arts | Where-Object { -not $_.expired -and $_.name -like 'WoW112-AH-DE-LIQUIDATION-V31-WINDOWS-*' } | Select-Object -First 1
      if ($null -eq $art) { continue }
      Remove-Item $artifactRoot -Recurse -Force -ErrorAction SilentlyContinue
      New-Item -ItemType Directory -Force $artifactRoot | Out-Null
      try { gh run download "$($run.id)" --repo "$env:GITHUB_REPOSITORY" --name "$($art.name)" --dir $artifactRoot } catch { continue }
      $oldNorm = Get-ChildItem $artifactRoot -Recurse -Filter 'DE_DISENCHANT_CACHE_WITH_SOURCE.csv' | Select-Object -First 1
      $oldUnresolved = Get-ChildItem $artifactRoot -Recurse -Filter 'DE_CACHE_UNRESOLVED.csv' | Select-Object -First 1
      if ($null -eq $oldNorm -or $null -eq $oldUnresolved) { continue }
      Copy-Item $oldNorm.FullName $norm -Force
      Copy-Item $oldUnresolved.FullName $unresolved -Force
      if (Test-DeCache $norm $unresolved) {
        Write-Host "[DE-CACHE] PRIOR_ARTIFACT PASS run=$($run.id) sha=$oldSha inputs=UNCHANGED"
        break
      }
      Remove-Item $norm,$unresolved -Force -ErrorAction SilentlyContinue
    }
  } catch {
    Write-Host "[DE-CACHE] artifact fallback unavailable: $($_.Exception.Message)"
  }
}

if (-not (Test-DeCache $norm $unresolved)) {
  $cacheSource = 'cold-rebuild'
  Write-Host '[DE-CACHE] cold rebuild required'
  $raw = Join-Path $cacheDir 'poc08-full-cache.csv'
  python "$tools/build_de_cache_poc08_e0.py" --seed-cache "$tools/v52_seed_cache.csv" --item-ids $itemIds --output-cache $raw --unresolved $unresolved --workers 24 --timeout 10 --retries 1
  $rows = @(Import-Csv $raw)
  foreach ($r in $rows) { if ($r.source -eq 'LEGACY_SEED') { $r.source = 'SeedLegacy' } }
  $rows | Export-Csv $norm -NoTypeInformation -Encoding utf8
  Remove-Item $raw -Force -ErrorAction SilentlyContinue
}
if (-not (Test-DeCache $norm $unresolved)) { throw 'DE cache validation failed' }
$cacheRows = @(Import-Csv $norm).Count
python "$tools/poc08_de_cache_to_rust_provenance.py" --cache-csv $norm --output-rs "$src/poc08_de_cache_generated.rs"
Write-Host "[DE-CACHE] PASS source=$cacheSource rows=$cacheRows"

Write-Host '[CI-FAST] generate F2 risk engine'
python "$tools/poc08_economy_audit_patch.py" "$src/world_poc07_delive_v53.rs" "$src/world_poc08_economy_audit.rs"
python "$tools/poc08_reference_de_model_patch.py" "$src/world_poc08_economy_audit.rs" "$src/world_poc08_b_reference_compare.rs"
python "$tools/poc08_b_compile_fix.py" "$src/world_poc08_b_reference_compare.rs"
python "$tools/poc08_material_pricebook_patch.py" "$src/world_poc08_b_reference_compare.rs" "$src/world_poc08_c_pricebook.rs"
python "$tools/poc08_risk_gate_patch.py" "$src/world_poc08_c_pricebook.rs" "$src/world_poc08_d_risk.rs"
python "$tools/poc08_provenance_audit_patch.py" "$src/world_poc08_d_risk.rs" "$src/world_poc08_e_provenance.rs"
python "$tools/poc08_f0_eligibility_patch.py" "$src/world_poc08_e_provenance.rs" "$src/world_poc08_f0_eligibility.rs"
python "$tools/poc08_f1_live_patch.py" "$src/world_poc08_f0_eligibility.rs" "$src/world_poc08_f1_live.rs"
python "$tools/poc08_f2_exact_de_patch.py" "$src/world_poc08_f1_live.rs" "$src/world_poc08_f2_live.rs"
python "$tools/poc08_f2_critical_hardening_patch.py" "$src/world_poc08_f2_live.rs" "$src/world_poc08_f2_live.rs"
python "$tools/poc08_f2_order_fix.py" "$src/world_poc08_f2_live.rs"
python "$tools/poc08_f2_history_fix.py" "$src/world_poc08_f2_live.rs"
python "$tools/poc08_f2_pagination_fix.py" "$src/world_poc08_f2_live.rs"

Write-Host '[CI-FAST] merge unified engine + V1/V2/V3/V3.1 hardening'
python "$tools/poc08_unified_scan_patch.py" "$src/world_poc08_f2_live.rs" "$src/world_poc08_unified_scan.rs"
python "$tools/poc08_unified_action_patch.py" "$src/world_poc08_unified_scan.rs" "$src/world_poc08_unified.rs"
python "$tools/poc08_unified_multibuy_v3_patch.py" "$src/world_poc08_unified.rs"
python "$tools/poc08_de_price_hardening_v1_patch.py" "$src/world_poc08_unified.rs"
python "$tools/poc08_de_history_liquidity_v2_patch.py" "$src/world_poc08_unified.rs"
python "$tools/poc08_de_liquidation_v3_patch.py" "$src/world_poc08_unified.rs"
python "$tools/poc08_de_liquidation_v3_compilefix.py" "$src/world_poc08_unified.rs"
python "$tools/poc08_de_liquidation_v31_f0_patch.py" "$src/world_poc08_unified.rs"
$main = "$src/main.rs"
$t = Get-Content $main -Raw
$t = $t.Replace('mod world_poc07_vendorlive;','mod world_poc08_unified;')
$t = $t.Replace('world_poc07_vendorlive::login_poc07_vendorlive','world_poc08_unified::login_poc08_economy_audit')
Set-Content $main $t -Encoding utf8

Write-Host '[CI-FAST] static safety/policy smoke'
$unified = "$src/world_poc08_unified.rs"
foreach ($m in @('POC08-UNIFIED-MULTI','POC08_ESSENCE_PARITY_PAIRS','POC08-C-HISTORY-V2','POC08-C-LIQUIDATION-V3','SAME_FULL_AH_SNAPSHOT','POC08_MAT_GUARD_OWN_EXPOSURE','POC08_MAT_GUARD_OWN_EXPOSURE_BLOCK','POC08_MAT_GUARD_MARKET_SATURATION','POC08_MAT_GUARD_OWN_AT_FLOOR','WOW112_MATERIAL_OWN_SHARE_BLOCK_BPS','WOW112_MATERIAL_OWN_UNITS_BLOCK_MIN','depth_10_units','exposure_factor_bps','saturation_factor_bps','POC08-F0-V31','CONFIDENCE_HAIRCUT_NOT_KILL_SWITCH','WOW112_F1_DE_MIN_LIQUIDATION_PROFIT','WOW112_UNIFIED_DE_MAX_PER_DEID','WOW112_UNIFIED_DE_MAX_SPEND','NO_AUTO_RETRY_FROM_THIS_POINT=YES')) {
  if (-not (Select-String -Path $unified -Pattern $m -SimpleMatch -Quiet)) { throw "V3.1 marker missing: $m" }
}
$hello = "$src/world_poc05_retry.rs"
foreach ($m in @('[AH-HELLO-V2]','HELLO_TIMEOUT_SECS','HELLO_PACKET_SAFETY_CAP','Freshly discovered NPC wins')) {
  if (-not (Select-String -Path $hello -Pattern $m -SimpleMatch -Quiet)) { throw "AH hello marker missing: $m" }
}
$smoke = Join-Path $env:RUNNER_TEMP 'unified-smoke.txt'
'DE LIQUIDATION V3.1 + AH HELLO RESILIENCE STATIC POLICY PASS' | Set-Content $smoke

$manifest = "$root/Cargo.toml"
$testHit = Get-ChildItem $root -Recurse -Filter '*.rs' | Where-Object { $_.FullName -notmatch '\\target\\' } | Select-String -Pattern '#\s*\[test\]' | Select-Object -First 1
if ($null -ne $testHit) {
  Write-Host '[RUST-TESTS] real tests detected'
  cargo test --manifest-path $manifest --release
} else {
  Write-Host '[RUST-TESTS] SKIP zero-test compile'
}
Write-Host '[CI-FAST] single release build'
cargo build --manifest-path $manifest --release
$exe = "$root/target/release/wow112-headless-android-probe.exe"
$b = [IO.File]::ReadAllBytes($exe)
if ($b.Length -lt 2 -or $b[0] -ne 0x4d -or $b[1] -ne 0x5a) { throw 'PE smoke failed: MZ header missing' }
$exeSha = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "[PE-SMOKE] PASS bytes=$($b.Length) sha256=$exeSha"

$d = 'dist/windows-ah-de-liquidation-v31'
New-Item -ItemType Directory -Force "$d/runtime","$d/source" | Out-Null
Copy-Item $exe "$d/wow112-ah-de-liquidation-v31.exe"
Copy-Item $unified "$d/source/"
Copy-Item "$src/world_poc07.rs" "$d/source/world_poc07_buy_primitive.rs"
Copy-Item $hello "$d/source/world_poc05_retry.rs"
Copy-Item $norm "$d/runtime/DE_DISENCHANT_CACHE_WITH_SOURCE.csv"
Copy-Item $unresolved "$d/runtime/DE_CACHE_UNRESOLVED.csv"
Copy-Item $smoke "$d/SMOKE_TESTS.txt"
$inputHash = $env:DE_CACHE_INPUT_HASH
@"
BRANCH=$env:GITHUB_REF_NAME
EXACT_SHA=$env:GITHUB_SHA
PRODUCT=UNIFIED_VENDOR_DE_LIQUIDATION_AWARE_V3_1
CI_PATH=FAST_CACHE_AWARE_V1
DE_CACHE_SOURCE=$cacheSource
DE_CACHE_ROWS=$cacheRows
DE_CACHE_INPUT_HASH=$inputHash
MATERIAL_BOOK_SOURCE=SAME_FULL_AH_SNAPSHOT
OWN_AUCTIONS=COUNTED_AND_EXPOSURE_WEIGHTED_NOT_USED_AS_EXTERNAL_PRICE
MARKET_DEPTH=UNITS_WITHIN_5_10_20_PERCENT_PLUS_WEIGHTED_P25_MEDIAN
OWN_EXPOSURE_FACTOR_FLOOR_BPS_DEFAULT=6500
OWN_SHARE_BLOCK_BPS_DEFAULT=7500
OWN_UNITS_BLOCK_MIN_DEFAULT=10
MARKET_SATURATION_FACTOR_FLOOR_BPS=8000
DE_PRICE_PARITY=ALL_5_ESSENCE_FAMILIES_3_TO_1
DE_HISTORY_BUCKET_SECS_DEFAULT=1800
DE_HISTORY_MAX_AGE_DEFAULT=172800
DE_HISTORY_ACCEPT_LEGACY_DEFAULT=NO
DE_MEDIUM_LIQUIDITY_HAIRCUT_BPS_DEFAULT=8500
DE_COLD_START_HAIRCUT=30_PERCENT
F0_DECISION=LIQUIDATION_SAFE_EV_PLUS_BOUNDED_MODEL_CONFIDENCE_HAIRCUT
F0_MIN_DECISION_PROFIT_DEFAULT=2500
F0_MIN_DECISION_ROI_BPS_DEFAULT=2500
F0_MAX_PLOSS_BPS_DEFAULT=2500
F0_MODEL_DISAGREEMENT=CONFIDENCE_HAIRCUT_NOT_KILL_SWITCH
F0_MODEL_CONFIDENCE_FACTOR_FLOOR_BPS=8500
DE_MAX_PER_DEID_DEFAULT=3
DE_MAX_SPEND_PER_SNAPSHOT_DEFAULT=250000
AH_HELLO_RESILIENCE=TIME_BUDGET_BACKGROUND_EXEMPT_FRESH_NPC_FIRST
BUY_REVALIDATION=EXACT_TUPLE_PAGE_PLUS_MINUS_5
NO_AUTO_RETRY_AFTER_UNCERTAIN_SEND=YES
BINARY_SHA256=$exeSha
"@ | Set-Content "$d/BUILD_INFO.txt" -Encoding utf8

Write-Host "[CI-FAST] PASS cache=$cacheSource rows=$cacheRows exe_sha=$exeSha"
