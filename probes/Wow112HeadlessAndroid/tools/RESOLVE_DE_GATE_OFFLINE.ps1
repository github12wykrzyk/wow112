param(
    [Parameter(Mandatory=$true)][string]$CandidateCsv,
    [Parameter(Mandatory=$true)][string]$CacheCsv,
    [Parameter(Mandatory=$true)][string]$SafeCsv,
    [string]$MissingCsv = ""
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($MissingCsv)) {
    $MissingCsv = Join-Path (Split-Path -Parent $SafeCsv) 'V5_MISSING_ITEM_IDS.csv'
}

if (-not (Test-Path -LiteralPath $CandidateCsv)) { throw "Candidate CSV not found: $CandidateCsv" }
if (-not (Test-Path -LiteralPath $CacheCsv)) { throw "Offline DE cache not found: $CacheCsv" }

$rows = @(Import-Csv -LiteralPath $CandidateCsv)
$cache = @{}
foreach ($entry in @(Import-Csv -LiteralPath $CacheCsv)) {
    if ($entry.item_id -match '^\d+$' -and $entry.disenchant_id -match '^\d+$') {
        $cache[[uint32]$entry.item_id] = [uint32]$entry.disenchant_id
    }
}

if ($rows.Count -eq 0) {
    'rank,auction_id,item_id,count,buyout,unit_value,gross_value,expected_profit,page,owner_guid,disenchant_id' | Set-Content -LiteralPath $SafeCsv -Encoding UTF8
    'item_id' | Set-Content -LiteralPath $MissingCsv -Encoding UTF8
    Write-Host '[V5-OFFLINE-GATE] PASS raw_candidates=0 safe_candidates=0 missing_unique=0 runtime_http=DISABLED'
    exit 0
}

$itemIds = @($rows | ForEach-Object { [uint32]$_.item_id } | Sort-Object -Unique)
$missing = @($itemIds | Where-Object { -not $cache.ContainsKey([uint32]$_) })
@($missing | ForEach-Object { [pscustomobject]@{ item_id=[uint32]$_ } }) | Export-Csv -LiteralPath $MissingCsv -NoTypeInformation -Encoding UTF8

$safe = New-Object System.Collections.Generic.List[object]
$blockedZero = 0
$blockedUnknown = 0
foreach ($row in $rows) {
    $id = [uint32]$row.item_id
    if (-not $cache.ContainsKey($id)) {
        $blockedUnknown++
        continue
    }
    $de = [uint32]$cache[$id]
    if ($de -eq 0) {
        $blockedZero++
        continue
    }
    $safe.Add([pscustomobject]@{
        rank = $row.rank
        auction_id = $row.auction_id
        item_id = $row.item_id
        count = $row.count
        buyout = $row.buyout
        unit_value = $row.unit_value
        gross_value = $row.gross_value
        expected_profit = $row.expected_profit
        page = $row.page
        owner_guid = $row.owner_guid
        disenchant_id = $de
    })
}

$ordered = @($safe | Sort-Object @{Expression={[int64]$_.expected_profit};Descending=$true}, @{Expression={[uint64]$_.buyout};Ascending=$true}, @{Expression={[uint64]$_.auction_id};Ascending=$true})
if ($ordered.Count -gt 0) {
    $ordered | Export-Csv -LiteralPath $SafeCsv -NoTypeInformation -Encoding UTF8
} else {
    'rank,auction_id,item_id,count,buyout,unit_value,gross_value,expected_profit,page,owner_guid,disenchant_id' | Set-Content -LiteralPath $SafeCsv -Encoding UTF8
}

$coveredUnique = $itemIds.Count - $missing.Count
Write-Host ''
Write-Host "[V5-OFFLINE-GATE] PASS raw_candidates=$($rows.Count) unique_items=$($itemIds.Count) cache_entries=$($cache.Count) covered_unique=$coveredUnique missing_unique=$($missing.Count) blocked_de0=$blockedZero blocked_unknown=$blockedUnknown safe_candidates=$($ordered.Count)"
Write-Host '[V5-OFFLINE-GATE] runtime_http=DISABLED unknown_fail_closed=YES positive_disenchant_id_only=YES'
Write-Host "[V5-OFFLINE-GATE] safe_csv=$SafeCsv missing_csv=$MissingCsv cache_csv=$CacheCsv"
for ($i = 0; $i -lt [Math]::Min(20, $ordered.Count); $i++) {
    $row = $ordered[$i]
    Write-Host "[V5-SAFE-CANDIDATE] rank=$i auction_id=$($row.auction_id) item_id=$($row.item_id) disenchant_id=$($row.disenchant_id) buyout=$($row.buyout) expected_profit=$($row.expected_profit)"
}
if ($missing.Count -gt 0) {
    Write-Host "[V5-OFFLINE-GATE] NOTE missing item IDs were fail-closed. Upload $MissingCsv to extend the cache."
}
