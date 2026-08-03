# Watch-News.ps1
# 日中に短い間隔で実行し、(1)相場急変につながりうるニュース (2)保有株の急な値動き
# を検知したら即メールでアラートする。タスクスケジューラから平日日中に繰り返し実行される想定。

. "$PSScriptRoot\Common.ps1"

$settings = Get-KabuConfig -Name "settings"
$keywords = Get-KabuConfig -Name "news_keywords"
$portfolio = (Get-KabuConfig -Name "portfolio").holdings

if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
$newsStatePath  = Join-Path $script:StateDir "news_seen.json"
$priceStatePath = Join-Path $script:StateDir "price_alert_state.json"
# Get-KabuNewsItems は Common.ps1 で共通定義（Get-MorningReport.ps1 と共用）

# --- 状態読み込み ---
# 「初回実行」はクエリ単位で判定する。スクリプト自体は既に動いていても、
# ポートフォリオに新しい銘柄を追加すると新しい検索クエリが生まれるため、
# そのクエリの過去記事を一括アラートしてしまわないよう、クエリ初見時は
# シードのみ（通知なし）とし、そのクエリを既知として記録した以降のみ通知する。
$newsStateExists = Test-Path $newsStatePath
$newsState = if ($newsStateExists) {
    Get-Content -Path $newsStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    [PSCustomObject]@{ seenLinks = @(); seenQueries = @() }
}
$seenSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($newsState.seenLinks))
$seenQueriesSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($newsState.seenQueries))

$today = Get-Date -Format "yyyy-MM-dd"
$priceState = if (Test-Path $priceStatePath) {
    Get-Content -Path $priceStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
} else { $null }
if (-not $priceState -or $priceState.date -ne $today) {
    $priceState = [PSCustomObject]@{ date = $today; alerted = @{} }
}
$alertedMap = @{}
if ($priceState.alerted) {
    $priceState.alerted.PSObject.Properties | ForEach-Object { $alertedMap[$_.Name] = $true }
}

$alerts = New-Object System.Collections.Generic.List[string]

# --- 1. 一般市況ニュース（緊急キーワード一致のみ通知） ---
foreach ($q in $keywords.generalNewsQueries) {
    $queryIsNew = -not $seenQueriesSet.Contains($q)
    foreach ($item in (Get-KabuNewsItems -Query $q -MaxItems 20)) {
        if ($seenSet.Contains($item.Link)) { continue }
        $seenSet.Add($item.Link) | Out-Null
        if ($queryIsNew) { continue }
        $hit = $keywords.urgentKeywords | Where-Object { $item.Title -like "*$_*" } | Select-Object -First 1
        if ($hit) {
            $alerts.Add("<li><b>[市況]</b> $($item.Title) <span style='color:#888;font-size:12px;'>(キーワード: $hit)</span><br/><a href='$($item.Link)'>記事リンク</a></li>")
        }
    }
    $seenQueriesSet.Add($q) | Out-Null
    Start-Sleep -Milliseconds 400
}

# --- 2. 保有株の個別ニュース（新着はキーワード問わず通知） ---
foreach ($h in $portfolio) {
    $newsQuery = if ($h.assetType -eq "fund") { $h.proxyName } else { $h.name }
    $queryIsNew = -not $seenQueriesSet.Contains($newsQuery)
    foreach ($item in (Get-KabuNewsItems -Query $newsQuery -MaxItems 20)) {
        if ($seenSet.Contains($item.Link)) { continue }
        $seenSet.Add($item.Link) | Out-Null
        if ($queryIsNew) { continue }
        $alerts.Add("<li><b>[保有株: $($h.name)]</b> $($item.Title)<br/><a href='$($item.Link)'>記事リンク</a></li>")
    }
    $seenQueriesSet.Add($newsQuery) | Out-Null
    Start-Sleep -Milliseconds 400
}

# --- 3. 保有株の急な値動きチェック（個別株のみ。fund=投資信託は日本時間日中は
#        連動指数の市場が閉まっており当欄でのチェックが意味を持たないため対象外） ---
foreach ($h in $portfolio) {
    if ($h.assetType -eq "fund") { continue }
    if ($alertedMap.ContainsKey($h.ticker)) { continue }
    $c = Get-YahooChart -Ticker $h.ticker -Range "1d" -Interval "5m"
    Start-Sleep -Milliseconds 300
    if (-not $c -or -not $c.PreviousClose -or $c.PreviousClose -eq 0) { continue }
    $changePct = [math]::Round((($c.RegularPrice - $c.PreviousClose) / $c.PreviousClose) * 100, 2)
    if ([math]::Abs($changePct) -ge [double]$settings.alertThresholdPct) {
        $dir = if ($changePct -gt 0) { "急騰" } else { "急落" }
        $alerts.Add("<li><b>[保有株の急変: $($h.name)]</b> 本日 $dir 中（前日比 $changePct%、現在値 $($c.RegularPrice)）</li>")
        $alertedMap[$h.ticker] = $true
    }
}

# --- 4. 為替(ドル円)の急変チェック（fund保有者向け：円建て評価額に直結するため） ---
$hasFund = @($portfolio | Where-Object { $_.assetType -eq "fund" -and $_.fxAdjusted }).Count -gt 0
if ($hasFund -and -not $alertedMap.ContainsKey("JPY=X")) {
    $fx = Get-YahooChart -Ticker "JPY=X" -Range "1d" -Interval "5m"
    Start-Sleep -Milliseconds 300
    if ($fx -and $fx.PreviousClose -and $fx.PreviousClose -ne 0) {
        $fxChangePct = [math]::Round((($fx.RegularPrice - $fx.PreviousClose) / $fx.PreviousClose) * 100, 2)
        if ([math]::Abs($fxChangePct) -ge [double]$settings.alertThresholdPct) {
            $dir = if ($fxChangePct -gt 0) { "円安" } else { "円高" }
            $alerts.Add("<li><b>[為替急変]</b> ドル円が本日 $dir 方向に急変中（$fxChangePct%、$($fx.RegularPrice)円）。外貨建て資産(オルカン/S&P500等)の評価額に影響する可能性があります。</li>")
            $alertedMap["JPY=X"] = $true
        }
    }
}

# --- 送信 ---
if ($alerts.Count -gt 0) {
    $body = @"
<div style='font-family:sans-serif;'>
<h2>kabuzidou 急変アラート $(Get-Date -Format "yyyy-MM-dd HH:mm")</h2>
<p style='background:#f8d7da;padding:8px;border-radius:4px;font-size:13px;'>
以下、相場や保有株に影響しうる新着情報を検知しました。内容の確認と投資判断はご自身でお願いします。
</p>
<ul>
$($alerts -join "`n")
</ul>
</div>
"@
    Send-KabuMail -Subject "【株alert】急な変動/ニュースを検知 $(Get-Date -Format 'HH:mm')" -BodyHtml $body
    Write-KabuLog "アラート送信: $($alerts.Count)件"
} else {
    Write-KabuLog "アラート対象なし"
}

# --- 状態保存 ---
$trimmedLinks = @($seenSet) | Select-Object -Last 800
[PSCustomObject]@{ seenLinks = $trimmedLinks; seenQueries = @($seenQueriesSet) } | ConvertTo-Json -Depth 3 | Set-Content -Path $newsStatePath -Encoding UTF8
[PSCustomObject]@{ date = $today; alerted = $alertedMap } | ConvertTo-Json -Depth 3 | Set-Content -Path $priceStatePath -Encoding UTF8
