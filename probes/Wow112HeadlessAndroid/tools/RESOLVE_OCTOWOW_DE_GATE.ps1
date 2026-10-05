param(
    [Parameter(Mandatory=$true)][string]$CandidateCsv,
    [string]$CacheCsv = (Join-Path $PSScriptRoot "DE_DISENCHANT_CACHE.csv"),
    [string]$SafeCsv = (Join-Path $PSScriptRoot "V5_SAFE_CANDIDATES.csv"),
    [int]$TimeoutSec = 15,
    [int]$Retries = 3
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Parse-DisenchantId([string]$Html) {
    if ([string]::IsNullOrWhiteSpace($Html)) { return $null }
    $plain = [regex]::Replace($Html, '<[^>]+>', ' ')
    $plain = [System.Net.WebUtility]::HtmlDecode($plain)
    $patterns = @(
        'Disenchant ID:\s*(\d+)',
        'DisenchantId\s*[:=]?\s*(\d+)',
        'disenchantId\s*[:=]?\s*(\d+)',
        '"DisenchantId"\s*:\s*(\d+)',
        '"disenchantId"\s*:\s*(\d+)'
    )
    foreach ($pattern in $patterns) {
        $m = [regex]::Match($plain, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) { return [uint32]$m.Groups[1].Value }
        $m = [regex]::Match($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) { return [uint32]$m.Groups[1].Value }
    }
    return $null
}

function Get-DatabaseDisenchantId([uint32]$ItemId) {
    $sources = @(
        [pscustomobject]@{ Name='OctoWow'; Url="https://octowow.st/db/?item=$ItemId" },
        [pscustomobject]@{ Name='CapyDB';  Url="https://db.capycraft.org/item/$ItemId" }
    )
    $headers = @{
        'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/154.0.0.0 Safari/537.36'
        'Accept'='text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
        'Accept-Language'='en-US,en;q=0.9'
        'Cache-Control'='no-cache'
    }
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($source in $sources) {
        for ($attempt = 1; $attempt -le $Retries; $attempt++) {
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri $source.Url -TimeoutSec $TimeoutSec -Headers $headers
                $de = Parse-DisenchantId ([string]$response.Content)
                if ($null -eq $de) { throw "Disenchant ID field not found" }
                return [pscustomobject]@{ Ok=$true; DisenchantId=[uint32]$de; Url=$source.Url; Source=$source.Name; Error="" }
            }
            catch {
                $errors.Add(("{0} attempt={1}: {2}" -f $source.Name, $attempt, $_.Exception.Message))
                if ($attempt -lt $Retries) { Start-Sleep -Milliseconds (200 * $attempt) }
            }
        }
    }
    return [pscustomobject]@{ Ok=$false; DisenchantId=$null; Url=''; Source=''; Error=($errors -join ' | ') }
}

if (-not (Test-Path -LiteralPath $CandidateCsv)) { throw "Candidate CSV not found: $CandidateCsv" }
$rows = @(Import-Csv -LiteralPath $CandidateCsv)
if ($rows.Count -eq 0) {
    "rank,auction_id,item_id,count,buyout,unit_value,gross_value,expected_profit,page,owner_guid,disenchant_id" | Set-Content -LiteralPath $SafeCsv -Encoding UTF8
    Write-Host "[V5-GATE] PASS raw_candidates=0 safe_candidates=0"
    exit 0
}

$cache = @{}
if (Test-Path -LiteralPath $CacheCsv) {
    foreach ($entry in @(Import-Csv -LiteralPath $CacheCsv)) {
        if ($entry.item_id -match '^\d+$' -and $entry.disenchant_id -match '^\d+$') {
            $id = [uint32]$entry.item_id
            $de = [uint32]$entry.disenchant_id
            $cache[$id] = $de
        }
    }
}

$itemIds = @($rows | ForEach-Object { [uint32]$_.item_id } | Sort-Object -Unique)
$resolvedNow = 0
$lookupFailed = 0
foreach ($itemId in $itemIds) {
    if ($cache.ContainsKey($itemId)) { continue }
    $result = Get-DatabaseDisenchantId $itemId
    if ($result.Ok) {
        $cache[$itemId] = [uint32]$result.DisenchantId
        $resolvedNow++
        Write-Host "[V5-GATE] RESOLVED item_id=$itemId disenchant_id=$($result.DisenchantId) source=$($result.Source)"
        Start-Sleep -Milliseconds 40
    }
    else {
        $lookupFailed++
        Write-Warning "[V5-GATE] UNKNOWN item_id=$itemId fail_closed=YES reason=$($result.Error)"
    }
}

$cacheOut = foreach ($id in @($cache.Keys | Sort-Object)) {
    [pscustomobject]@{ item_id=[uint32]$id; disenchant_id=[uint32]$cache[$id] }
}
$cacheOut | Export-Csv -LiteralPath $CacheCsv -NoTypeInformation -Encoding UTF8

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
$ordered | Export-Csv -LiteralPath $SafeCsv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "[V5-GATE] PASS raw_candidates=$($rows.Count) unique_items=$($itemIds.Count) cache_entries=$($cache.Count) resolved_now=$resolvedNow blocked_de0=$blockedZero blocked_unknown=$blockedUnknown lookup_failed=$lookupFailed safe_candidates=$($ordered.Count)"
Write-Host "[V5-GATE] source=OctoWow_primary_CapyDB_fallback exact_Disenchant_ID positive_only=YES unknown_fail_closed=YES"
Write-Host "[V5-GATE] safe_csv=$SafeCsv cache_csv=$CacheCsv"
for ($i = 0; $i -lt [Math]::Min(20, $ordered.Count); $i++) {
    $row = $ordered[$i]
    Write-Host "[V5-SAFE-CANDIDATE] rank=$i auction_id=$($row.auction_id) item_id=$($row.item_id) disenchant_id=$($row.disenchant_id) buyout=$($row.buyout) expected_profit=$($row.expected_profit)"
}

if ($lookupFailed -gt 0) {
    Write-Host "[V5-GATE] NOTE lookup failures were excluded; rerun later to fill cache."
}
