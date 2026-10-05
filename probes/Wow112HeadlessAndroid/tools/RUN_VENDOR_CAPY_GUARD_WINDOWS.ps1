param(
    [int]$RestartDelaySeconds = 5,
    [switch]$Once,
    [switch]$SelfTest,
    [int]$ExternalTimeoutSeconds = 5,
    [int]$DbCacheHours = 168
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$Account = 'octowar1'
$MaxBuyoutCopper = 200000   # 20g
$MinProfitCopper = 2        # strictly > 1 copper
$MaxExternalCandidates = 250
$env:WOW112_ACCOUNT = $Account

$logDir = Join-Path $PSScriptRoot 'logs'
$stateDir = Join-Path $PSScriptRoot 'state'
$dbCachePath = Join-Path $stateDir 'vendor_db_cache.csv'
$ledgerPath = Join-Path $stateDir 'vendor_buy_ledger.csv'
$ahGuidPath = Join-Path $stateDir 'ah_guid.txt'
$mailboxGuidPath = Join-Path $stateDir 'mailbox_guid.txt'
$ahFailurePath = Join-Path $stateDir 'ah_guid_failures.txt'
New-Item -ItemType Directory -Force $logDir, $stateDir | Out-Null

$script:DbCache = @{}
$script:CapyHealthy = $true
$script:TurtleApiHealthy = $true
$script:TurtleLegacyHealthy = $true

function Read-PasswordOnce {
    if (-not [string]::IsNullOrWhiteSpace($env:WOW112_PASSWORD)) { return }
    $secure = Read-Host "Haslo WoW dla $Account" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $env:WOW112_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Convert-HtmlMoneyToCopper([string]$html, [string]$label = 'Sells for') {
    if ([string]::IsNullOrWhiteSpace($html)) { return $null }

    # Structured data first. These variants cover common JSON/SSR conventions.
    foreach ($pattern in @(
        '"sellPrice"\s*:\s*(\d+)',
        '"sell_price"\s*:\s*(\d+)',
        '"SellPrice"\s*:\s*(\d+)',
        '"price"\s*:\s*\{[^\}]{0,300}"sell"\s*:\s*(\d+)'
    )) {
        $m = [regex]::Match($html, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) { return [uint32]$m.Groups[1].Value }
    }

    $idx = $html.IndexOf($label, [StringComparison]::OrdinalIgnoreCase)
    if ($idx -lt 0) {
        $idx = $html.IndexOf('Sell Price', [StringComparison]::OrdinalIgnoreCase)
    }
    if ($idx -lt 0) { return $null }

    $len = [Math]::Min(2200, $html.Length - $idx)
    $chunk = [System.Net.WebUtility]::HtmlDecode($html.Substring($idx, $len))

    # Preserve money units from image metadata before stripping tags.
    $chunk = [regex]::Replace(
        $chunk,
        '<img\b[^>]*(?:alt|title|aria-label)\s*=\s*["'']([^"'']+)["''][^>]*>',
        ' $1 ',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    # Fallback for coin icon filenames/classes where alt/title is absent.
    $chunk = [regex]::Replace($chunk, '(?i)<img\b[^>]*(?:gold|coin_gold|money-gold)[^>]*>', ' g ')
    $chunk = [regex]::Replace($chunk, '(?i)<img\b[^>]*(?:silver|coin_silver|money-silver)[^>]*>', ' s ')
    $chunk = [regex]::Replace($chunk, '(?i)<img\b[^>]*(?:copper|coin_copper|money-copper)[^>]*>', ' c ')
    $chunk = [regex]::Replace($chunk, '<[^>]+>', ' ')
    $chunk = [regex]::Replace($chunk, '\s+', ' ')

    $stop = [regex]::Match($chunk, '(?i)(Display\s*ID|Disenchant\s*ID|Allowable\s*Races|Item\s*data|Referenced\s*by)')
    if ($stop.Success) { $chunk = $chunk.Substring(0, $stop.Index) }

    $gold = 0L; $silver = 0L; $copper = 0L; $found = $false
    $m = [regex]::Match($chunk, '(?i)(\d+)\s*(?:g|gold)\b')
    if ($m.Success) { $gold = [int64]$m.Groups[1].Value; $found = $true }
    $m = [regex]::Match($chunk, '(?i)(\d+)\s*(?:s|silver)\b')
    if ($m.Success) { $silver = [int64]$m.Groups[1].Value; $found = $true }
    $m = [regex]::Match($chunk, '(?i)(\d+)\s*(?:c|copper)\b')
    if ($m.Success) { $copper = [int64]$m.Groups[1].Value; $found = $true }
    if (-not $found) { return $null }

    $total = ($gold * 10000L) + ($silver * 100L) + $copper
    if ($total -lt 0 -or $total -gt [uint32]::MaxValue) { return $null }
    return [uint32]$total
}

function Convert-TurtleJsonToCopper([string]$json) {
    if ([string]::IsNullOrWhiteSpace($json)) { return $null }
    try { $o = $json | ConvertFrom-Json }
    catch { return $null }

    if ($null -ne $o.price -and $null -ne $o.price.sell) { return [uint32]$o.price.sell }
    foreach ($name in @('sellPrice','sell_price','SellPrice')) {
        if ($null -ne $o.$name) { return [uint32]$o.$name }
    }
    return $null
}

function Assert-Eq($Actual, $Expected, [string]$Name) {
    if ($Actual -ne $Expected) { throw "SELFTEST FAIL $Name expected=$Expected actual=$Actual" }
}

function Test-ExternalConsensus([uint32]$LivePrice, $Db) {
    $observed = @()
    if ($null -ne $Db.Capy) { $observed += [pscustomobject]@{ Source='Capy'; Price=[uint32]$Db.Capy } }
    if ($null -ne $Db.TurtleApi) { $observed += [pscustomobject]@{ Source='TurtleApi'; Price=[uint32]$Db.TurtleApi } }
    if ($null -ne $Db.TurtleLegacy) { $observed += [pscustomobject]@{ Source='TurtleLegacy'; Price=[uint32]$Db.TurtleLegacy } }

    if ($observed.Count -eq 0) {
        return [pscustomobject]@{ Pass=$false; Reason='NO_EXTERNAL_PRICE'; Sources='' }
    }
    foreach ($x in $observed) {
        if ($x.Price -ne $LivePrice) {
            return [pscustomobject]@{
                Pass=$false
                Reason="MISMATCH_$($x.Source)_$($x.Price)_VS_LIVE_$LivePrice"
                Sources=(($observed | ForEach-Object { "$($_.Source)=$($_.Price)" }) -join ';')
            }
        }
    }
    return [pscustomobject]@{
        Pass=$true
        Reason='MATCH'
        Sources=(($observed | ForEach-Object { "$($_.Source)=$($_.Price)" }) -join ';')
    }
}

if ($SelfTest) {
    $capyHtml = '<div>Quick facts</div><div>Sells for 11<img alt="g"> 58<img alt="s"> 33<img alt="c"></div><div>Display ID</div>'
    Assert-Eq (Convert-HtmlMoneyToCopper $capyHtml 'Sells for') 115833 'capy-gsc-parser'
    Assert-Eq (Convert-HtmlMoneyToCopper '<div>Sells for 5<img title="c"></div>') 5 'capy-copper-parser'
    Assert-Eq (Convert-TurtleJsonToCopper '{"price":{"buy":463333,"sell":115833}}') 115833 'turtle-json-parser'
    $ok = Test-ExternalConsensus 115833 ([pscustomobject]@{ Capy=115833; TurtleApi=115833; TurtleLegacy=$null })
    Assert-Eq $ok.Pass $true 'external-consensus-match'
    $bad = Test-ExternalConsensus 115833 ([pscustomobject]@{ Capy=115833; TurtleApi=115832; TurtleLegacy=$null })
    Assert-Eq $bad.Pass $false 'external-consensus-veto'
    Write-Host '[SELFTEST] PASS parsers + external consensus' -ForegroundColor Green
    exit 0
}

function Invoke-HttpGetText([string]$Url, [string]$Source) {
    $headers = @{ 'User-Agent' = 'Mozilla/5.0 WoW112VendorGuard/2.0' }
    try {
        $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec $ExternalTimeoutSeconds -Headers $headers -Uri $Url
        return [string]$r.Content
    } catch {
        Write-Host "[DB-GUARD] $Source request failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return $null
    }
}

function Load-DbCache {
    $script:DbCache = @{}
    if (-not (Test-Path $dbCachePath)) { return }
    try {
        foreach ($row in Import-Csv $dbCachePath) {
            if ([string]::IsNullOrWhiteSpace($row.ItemId)) { continue }
            $script:DbCache[[string]$row.ItemId] = $row
        }
    } catch {
        Write-Host "[DB-CACHE] ignored corrupt cache: $($_.Exception.Message)" -ForegroundColor Yellow
        $script:DbCache = @{}
    }
}

function Save-DbCache {
    @($script:DbCache.Values) | Sort-Object { [uint32]$_.ItemId } | Export-Csv -NoTypeInformation -Encoding UTF8 $dbCachePath
}

function Get-CachedExternalPrice([uint32]$ItemId) {
    $key = [string]$ItemId
    if (-not $script:DbCache.ContainsKey($key)) { return $null }
    $r = $script:DbCache[$key]
    try { $checked = [datetime]::Parse($r.CheckedUtc).ToUniversalTime() }
    catch { return $null }
    if (((Get-Date).ToUniversalTime() - $checked).TotalHours -gt $DbCacheHours) { return $null }

    $toNullable = {
        param($v)
        if ([string]::IsNullOrWhiteSpace([string]$v)) { return $null }
        return [uint32]$v
    }
    return [pscustomobject]@{
        Capy = & $toNullable $r.Capy
        TurtleApi = & $toNullable $r.TurtleApi
        TurtleLegacy = & $toNullable $r.TurtleLegacy
        Cached = $true
    }
}

function Put-CachedExternalPrice([uint32]$ItemId, $Db) {
    $script:DbCache[[string]$ItemId] = [pscustomobject]@{
        ItemId = $ItemId
        Capy = if ($null -eq $Db.Capy) { '' } else { [string][uint32]$Db.Capy }
        TurtleApi = if ($null -eq $Db.TurtleApi) { '' } else { [string][uint32]$Db.TurtleApi }
        TurtleLegacy = if ($null -eq $Db.TurtleLegacy) { '' } else { [string][uint32]$Db.TurtleLegacy }
        CheckedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    Save-DbCache
}

function Test-DbSourceHealth {
    # Devilsaur Leather is a tiny, stable reference: current 1.18.1 DBs report sell=5c.
    $knownItem = 15417
    $expected = 5

    $capyText = Invoke-HttpGetText "https://db.capycraft.org/item/$knownItem" 'Capy-health'
    $capyPrice = Convert-HtmlMoneyToCopper $capyText 'Sells for'
    $script:CapyHealthy = ($null -ne $capyPrice -and [uint32]$capyPrice -eq $expected)

    $turtleText = Invoke-HttpGetText "https://api.tortoiseclothing.org/i/$knownItem" 'TurtleApi-health'
    $turtlePrice = Convert-TurtleJsonToCopper $turtleText
    $script:TurtleApiHealthy = ($null -ne $turtlePrice -and [uint32]$turtlePrice -eq $expected)

    # Legacy site is fallback-only; health is evaluated lazily if needed.
    $script:TurtleLegacyHealthy = $true

    Write-Host "[DB-HEALTH] capy=$script:CapyHealthy turtle_api=$script:TurtleApiHealthy reference_item=$knownItem expected=${expected}c" -ForegroundColor Cyan
    if (-not $script:CapyHealthy -and -not $script:TurtleApiHealthy) {
        Write-Host '[DB-HEALTH] no primary external source healthy. BUY remains fail-closed.' -ForegroundColor Red
    }
}

function Get-ExternalVendorPrice([uint32]$ItemId) {
    $cached = Get-CachedExternalPrice $ItemId
    if ($null -ne $cached) {
        Write-Host "[DB-CACHE] HIT item=$ItemId capy=$($cached.Capy) turtle=$($cached.TurtleApi) legacy=$($cached.TurtleLegacy)"
        return $cached
    }

    $capy = $null
    $turtleApi = $null
    $turtleLegacy = $null

    if ($script:CapyHealthy) {
        $html = Invoke-HttpGetText "https://db.capycraft.org/item/$ItemId" 'Capy'
        $capy = Convert-HtmlMoneyToCopper $html 'Sells for'
    }

    if ($script:TurtleApiHealthy) {
        $json = Invoke-HttpGetText "https://api.tortoiseclothing.org/i/$ItemId" 'TurtleApi'
        $turtleApi = Convert-TurtleJsonToCopper $json
    }

    # Only spend a request on the legacy Turtle page when the JSON API did not
    # give us a price for this item. It is a fallback, never a weaker override.
    if ($null -eq $turtleApi -and $script:TurtleLegacyHealthy) {
        $legacy = Invoke-HttpGetText "https://database.turtle-wow.org/?item=$ItemId" 'TurtleLegacy'
        $turtleLegacy = Convert-HtmlMoneyToCopper $legacy 'Sells for'
        if ($null -eq $legacy) { $script:TurtleLegacyHealthy = $false }
    }

    $result = [pscustomobject]@{
        Capy = $capy
        TurtleApi = $turtleApi
        TurtleLegacy = $turtleLegacy
        Cached = $false
    }
    if ($null -ne $capy -or $null -ne $turtleApi -or $null -ne $turtleLegacy) {
        Put-CachedExternalPrice $ItemId $result
    }
    return $result
}

function Clear-ExactTargetEnv {
    foreach ($n in @(
        'WOW112_BUY_EXPECT_AUCTION_ID','WOW112_BUY_EXPECT_ITEM_ID','WOW112_BUY_EXPECT_BUYOUT',
        'WOW112_BUY_EXPECT_COUNT','WOW112_BUY_EXPECT_VENDOR_UNIT'
    )) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
}

function Apply-GuidCache {
    if (Test-Path $ahGuidPath) {
        $v = (Get-Content $ahGuidPath -Raw).Trim()
        if ($v -match '^0x[0-9A-Fa-f]{1,16}$') {
            $env:WOW112_AH_GUID = $v
            Write-Host "[GUID-CACHE] AH=$v" -ForegroundColor DarkCyan
        }
    }
    if (Test-Path $mailboxGuidPath) {
        $v = (Get-Content $mailboxGuidPath -Raw).Trim()
        if ($v -match '^0x[0-9A-Fa-f]{1,16}$') {
            $env:WOW112_MAILBOX_GUID = $v
            Write-Host "[GUID-CACHE] MAILBOX=$v" -ForegroundColor DarkCyan
        }
    }
}

function Learn-GuidCache([string]$LogPath) {
    if (-not (Test-Path $LogPath)) { return }
    $text = Get-Content $LogPath -Raw
    $m = [regex]::Match($text, '\[AH\] MSG_AUCTION_HELLO PASS guid=(0x[0-9A-Fa-f]+)')
    if ($m.Success) {
        $m.Groups[1].Value | Set-Content -Encoding ascii $ahGuidPath
        '0' | Set-Content -Encoding ascii $ahFailurePath
    }
    $m2 = [regex]::Match($text, 'mailbox=(0x[0-9A-Fa-f]+)')
    if ($m2.Success) { $m2.Groups[1].Value | Set-Content -Encoding ascii $mailboxGuidPath }
    Apply-GuidCache
}

function Register-AhFailure([string]$LogPath) {
    if (-not (Test-Path $LogPath)) { return }
    if (-not (Select-String -Path $LogPath -Pattern 'server did not return MSG_AUCTION_HELLO' -Quiet)) { return }
    $n = 0
    if (Test-Path $ahFailurePath) { [void][int]::TryParse((Get-Content $ahFailurePath -Raw).Trim(), [ref]$n) }
    $n++
    [string]$n | Set-Content -Encoding ascii $ahFailurePath
    Write-Host "[GUID-CACHE] AH hello failure count=$n" -ForegroundColor Yellow
    if ($n -ge 3) {
        Remove-Item $ahGuidPath -ErrorAction SilentlyContinue
        Remove-Item Env:WOW112_AH_GUID -ErrorAction SilentlyContinue
        '0' | Set-Content -Encoding ascii $ahFailurePath
        Write-Host '[GUID-CACHE] cleared stale AH GUID after 3 hello failures; discovery re-enabled.' -ForegroundColor Yellow
    }
}

function Invoke-Headless([string]$LogPath) {
    $exe = Join-Path $PSScriptRoot 'wow112-headless-windows.exe'
    if (-not (Test-Path $exe)) { throw "Brak binarki: $exe" }
    Apply-GuidCache
    & $exe 2>&1 | Tee-Object -FilePath $LogPath
    $code = $LASTEXITCODE
    Learn-GuidCache $LogPath
    Register-AhFailure $LogPath
    return $code
}

function Write-Ledger([string]$Decision, $Candidate, $Db, [string]$Detail) {
    $row = [pscustomobject]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Decision = $Decision
        AuctionId = if ($null -eq $Candidate) { '' } else { $Candidate.Auction }
        ItemId = if ($null -eq $Candidate) { '' } else { $Candidate.Item }
        Count = if ($null -eq $Candidate) { '' } else { $Candidate.Count }
        BuyoutCopper = if ($null -eq $Candidate) { '' } else { $Candidate.Buyout }
        LiveVendorUnitCopper = if ($null -eq $Candidate) { '' } else { $Candidate.Unit }
        ExpectedProfitCopper = if ($null -eq $Candidate) { '' } else { $Candidate.Profit }
        CapyCopper = if ($null -eq $Db -or $null -eq $Db.Capy) { '' } else { $Db.Capy }
        TurtleApiCopper = if ($null -eq $Db -or $null -eq $Db.TurtleApi) { '' } else { $Db.TurtleApi }
        TurtleLegacyCopper = if ($null -eq $Db -or $null -eq $Db.TurtleLegacy) { '' } else { $Db.TurtleLegacy }
        Detail = $Detail
    }
    if (Test-Path $ledgerPath) { $row | Export-Csv -NoTypeInformation -Append -Encoding UTF8 $ledgerPath }
    else { $row | Export-Csv -NoTypeInformation -Encoding UTF8 $ledgerPath }
}

Load-DbCache
Read-PasswordOnce
Test-DbSourceHealth

Write-Host '[CONFIG] VENDOR ONLY | profit >=2c (>1c) | buyout <=20g | FULL AH | max 1 purchase/process' -ForegroundColor Cyan
Write-Host '[CONFIG] External rule: >=1 external price required; ANY returned mismatch vetoes BUY.' -ForegroundColor Cyan
Write-Host '[CONFIG] Sources: CapyDB + Turtle JSON API; legacy Turtle HTML fallback. GUID cache enabled.' -ForegroundColor Cyan

$env:WOW112_RECONNECT_LIMIT = '10'
$env:WOW112_RECONNECT_DELAY_MS = '0'

try {
    do {
        Clear-ExactTargetEnv
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $scanLog = Join-Path $logDir "vendor_scan_$stamp.log"

        $env:WOW112_AUTOBUY_ACTION = 'scan-only'
        $env:WOW112_AUTOBUY_STRATEGY = 'vendor'
        $env:WOW112_AUTOBUY_MAX_BUYOUT = "$MaxBuyoutCopper"
        $env:WOW112_AUTOBUY_MIN_PROFIT = "$MinProfitCopper"
        $env:WOW112_AH_SCAN_PAGE_START = '0'
        $env:WOW112_AH_SCAN_PAGES = '0'  # specialized full-sweep build: 0 = until short page
        $env:WOW112_VENDOR_ITEM_QUERY_WINDOW = '64'
        $env:WOW112_AUTOBUY_MAX_PURCHASES = '1'
        Remove-Item Env:WOW112_AUTOBUY_CONFIRM -ErrorAction SilentlyContinue

        Write-Host ''
        Write-Host '================ FULL VENDOR SCAN ================' -ForegroundColor Cyan
        $scanExit = Invoke-Headless $scanLog
        if ($scanExit -ne 0) {
            Write-Host "[SCAN] failed exit=$scanExit; NO BUY." -ForegroundColor Red
            Write-Ledger 'SCAN_FAIL' $null $null "exit=$scanExit log=$scanLog"
            if ($Once) { break }
            Start-Sleep -Seconds $RestartDelaySeconds
            continue
        }

        $candidates = @()
        foreach ($line in Get-Content $scanLog) {
            if ($line -notmatch '\[POC07-CANDIDATE\]') { continue }
            $m = [regex]::Match($line, 'rank=(?<rank>\d+)\s+page=(?<page>\d+)\s+strategy=vendor\s+auction_id=(?<auction>\d+)\s+item_id=(?<item>\d+)\s+count=(?<count>\d+)\s+buyout=(?<buyout>\d+).*?unit_value=(?<unit>\d+)\s+gross_value=(?<gross>\d+)\s+expected_profit=(?<profit>-?\d+)')
            if (-not $m.Success) { continue }
            $candidates += [pscustomobject]@{
                Rank=[int]$m.Groups['rank'].Value; Page=[int]$m.Groups['page'].Value
                Auction=[uint32]$m.Groups['auction'].Value; Item=[uint32]$m.Groups['item'].Value
                Count=[uint32]$m.Groups['count'].Value; Buyout=[uint32]$m.Groups['buyout'].Value
                Unit=[uint32]$m.Groups['unit'].Value; Gross=[uint64]$m.Groups['gross'].Value
                Profit=[int64]$m.Groups['profit'].Value
            }
        }

        if ($candidates.Count -eq 0) {
            Write-Host '[SCAN] no qualified vendor candidate. NO BUY.' -ForegroundColor Yellow
            Write-Ledger 'NO_CANDIDATE' $null $null $scanLog
            if ($Once) { break }
            Start-Sleep -Seconds $RestartDelaySeconds
            continue
        }

        $chosen = $null
        $chosenDb = $null
        $checked = 0
        foreach ($c in ($candidates | Sort-Object Rank)) {
            if ($c.Profit -lt $MinProfitCopper -or $c.Buyout -gt $MaxBuyoutCopper) { continue }
            $checked++
            if ($checked -gt $MaxExternalCandidates) {
                Write-Host "[DB-GUARD] reached external verification cap=$MaxExternalCandidates for this sweep." -ForegroundColor Yellow
                break
            }

            Write-Host "[DB-GUARD] checking rank=$($c.Rank) item=$($c.Item) live_vendor=$($c.Unit)c profit=$($c.Profit)c buyout=$($c.Buyout)c"
            $db = Get-ExternalVendorPrice $c.Item
            $consensus = Test-ExternalConsensus $c.Unit $db
            if (-not $consensus.Pass) {
                Write-Host "[DB-GUARD] SKIP item=$($c.Item) reason=$($consensus.Reason) sources=$($consensus.Sources)" -ForegroundColor Yellow
                continue
            }

            $chosen = $c
            $chosenDb = $db
            Write-Host "[DB-GUARD] PASS item=$($c.Item) live=$($c.Unit)c sources=$($consensus.Sources)" -ForegroundColor Green
            Write-Ledger 'DB_PASS' $c $db $consensus.Sources
            break
        }

        if ($null -eq $chosen) {
            Write-Host '[DB-GUARD] no externally verified candidate. NO BUY.' -ForegroundColor Yellow
            Write-Ledger 'NO_DB_VERIFIED_CANDIDATE' $null $null "checked=$checked"
            if ($Once) { break }
            Start-Sleep -Seconds $RestartDelaySeconds
            continue
        }

        # Exact-target BUY pass. The specialized Rust build independently refuses
        # relaxed strategy/price/profit values and refuses any auction other than
        # this externally verified tuple.
        $env:WOW112_AUTOBUY_ACTION = 'buy-one'
        $env:WOW112_AUTOBUY_CONFIRM = 'YES'
        $env:WOW112_AUTOBUY_STRATEGY = 'vendor'
        $env:WOW112_AUTOBUY_MAX_PURCHASES = '1'
        $env:WOW112_AUTOBUY_MAX_BUYOUT = "$MaxBuyoutCopper"
        $env:WOW112_AUTOBUY_MIN_PROFIT = "$MinProfitCopper"
        $env:WOW112_AH_SCAN_PAGE_START = "$($chosen.Page)"
        $env:WOW112_AH_SCAN_PAGES = '1'
        $env:WOW112_BUY_EXPECT_AUCTION_ID = "$($chosen.Auction)"
        $env:WOW112_BUY_EXPECT_ITEM_ID = "$($chosen.Item)"
        $env:WOW112_BUY_EXPECT_BUYOUT = "$($chosen.Buyout)"
        $env:WOW112_BUY_EXPECT_COUNT = "$($chosen.Count)"
        $env:WOW112_BUY_EXPECT_VENDOR_UNIT = "$($chosen.Unit)"

        $buyLog = Join-Path $logDir "vendor_buy_$stamp.log"
        Write-Host ''
        Write-Host "================ GUARDED BUY rank=$($chosen.Rank) item=$($chosen.Item) auction=$($chosen.Auction) ================" -ForegroundColor Green
        $buyExit = Invoke-Headless $buyLog
        if ($buyExit -eq 0 -and (Select-String -Path $buyLog -Pattern '\[POC07-BUY\] BUY-ONE PASS purchases=1' -Quiet)) {
            Write-Host '[BUY] CONFIRMED PASS purchases=1' -ForegroundColor Green
            Write-Ledger 'BUY_CONFIRMED' $chosen $chosenDb $buyLog
        } else {
            Write-Host "[BUY] no confirmed purchase (exit=$buyExit). Check $buyLog" -ForegroundColor Yellow
            Write-Ledger 'BUY_NOT_CONFIRMED' $chosen $chosenDb "exit=$buyExit log=$buyLog"
        }

        if ($Once) { break }
        Start-Sleep -Seconds $RestartDelaySeconds
    } while ($true)
}
finally {
    Clear-ExactTargetEnv
    $env:WOW112_PASSWORD = $null
}
