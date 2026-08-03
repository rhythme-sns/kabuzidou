# Get-MorningReport.ps1
# 毎朝、市場概況・値上がり/値下がり候補・買い目候補・保有株の見立てをまとめてメール送信する。
# タスクスケジューラから平日朝に自動実行される想定（Register-Tasks.ps1 参照）。

. "$PSScriptRoot\Common.ps1"

Write-KabuLog "=== 朝レポート生成開始 ==="

$watchlist = (Get-KabuConfig -Name "watchlist").stocks
$portfolio = (Get-KabuConfig -Name "portfolio").holdings
$settings  = Get-KabuConfig -Name "settings"

# AI(Claude API)への一括問い合わせ用にアイテムを集めておく。実際の呼び出しはレポートの全セクションを
# 組み立てた後に1回だけ行う（コストを抑えるため）。
$aiItems = New-Object System.Collections.Generic.List[object]
$script:aiIdCounter = 0
function New-KabuAIItem {
    param([string]$Name, [string]$Context, [double]$ChangePct, [double]$TrendPct5d, [bool]$IsBuyCandidate = $false)
    $script:aiIdCounter++
    $id = "item$($script:aiIdCounter)"
    $aiItems.Add([PSCustomObject]@{
        id = $id; name = $Name; context = $Context
        changePct = $ChangePct; trendPct5d = $TrendPct5d; isBuyCandidate = $IsBuyCandidate
    })
    return $id
}

function Format-Pct($v) {
    if ($null -eq $v) { return "-" }
    $sign = if ($v -gt 0) { "+" } else { "" }
    return "$sign$v%"
}

# --- 市場概況（前営業日の主要指標） ---
$indices = @(
    @{ Ticker = "^N225";  Name = "日経平均" },
    @{ Ticker = "^GSPC";  Name = "S&P500(米)" },
    @{ Ticker = "JPY=X";  Name = "ドル円" }
)
$indexRows = foreach ($idx in $indices) {
    $c = Get-YahooChart -Ticker $idx.Ticker -Range "5d" -Interval "1d"
    Start-Sleep -Milliseconds 300
    if (-not $c) { continue }
    $m = Get-KabuMomentum -Chart $c
    if (-not $m) { continue }
    "<tr><td>$($idx.Name)</td><td>$($m.LastClose)</td><td>$(Format-Pct $m.ChangePct)</td></tr>"
}

# --- ウォッチリストのモメンタム収集 ---
# category: growth=グロース市場中心の値動きが大きい銘柄（短期売買のメイン対象）、large=大型株（参考程度）
$results = foreach ($stock in $watchlist) {
    $c = Get-YahooChart -Ticker $stock.ticker -Range "1mo" -Interval "1d"
    Start-Sleep -Milliseconds 300
    if (-not $c) { continue }
    $m = Get-KabuMomentum -Chart $c
    if (-not $m) { continue }
    [PSCustomObject]@{
        Ticker      = $stock.ticker
        Name        = $stock.name
        Category    = $(if ($stock.category) { $stock.category } else { "large" })
        ChangePct   = $m.ChangePct
        TrendPct5d  = $m.TrendPct5d
        VolumeRatio = $m.VolumeRatio
        LastClose   = $m.LastClose
    }
}
$growthResults = $results | Where-Object { $_.Category -eq "growth" }
$largeResults  = $results | Where-Object { $_.Category -ne "growth" }

# --- グロース株（短期売買のメイン対象） ---
$grRisers = $growthResults | Sort-Object -Property ChangePct -Descending | Select-Object -First 6
$grFallers = $growthResults | Sort-Object -Property ChangePct | Select-Object -First 6
# 出来高急増＋上昇中: ブレイクアウト型の短期エントリー候補
$grBreakout = $growthResults | Where-Object { $_.ChangePct -gt 2 -and $_.VolumeRatio -ge 1.5 } |
    Sort-Object -Property VolumeRatio -Descending | Select-Object -First 5
# 押し目買い候補: 中期トレンドはプラスだが直近で一服している銘柄
$grPullback = $growthResults | Where-Object { $_.TrendPct5d -gt 2 -and $_.ChangePct -lt 0 } |
    Sort-Object -Property TrendPct5d -Descending | Select-Object -First 5

# --- 大型株（参考情報。短期売買のメインはグロース株のため簡易表示のみ） ---
$lgRisers = $largeResults | Sort-Object -Property ChangePct -Descending | Select-Object -First 3
$lgFallers = $largeResults | Sort-Object -Property ChangePct | Select-Object -First 3

# --- 選出された銘柄にだけ「根拠」を付与する（全銘柄に付けるとニュース取得回数が多すぎるため） ---
# 根拠 = (1)チャートの動き（前日比・5日トレンド・出来高）から機械的に導く説明
#      + (2)関連ニュースの最新見出し（見つかった場合のみ）
$newsReasonCache = @{}
function Add-KabuReason($rows, [bool]$IsBuyCandidate = $false) {
    foreach ($r in $rows) {
        $momentum = [PSCustomObject]@{ ChangePct = $r.ChangePct; TrendPct5d = $r.TrendPct5d; VolumeRatio = $r.VolumeRatio }
        $chartReason = Get-KabuChartReasonText -Momentum $momentum

        if (-not $newsReasonCache.ContainsKey($r.Name)) {
            $newsReasonCache[$r.Name] = Get-KabuNewsReasonText -Query $r.Name
            Start-Sleep -Milliseconds 300
        }
        $newsReason = $newsReasonCache[$r.Name]

        $reasonText = if ($newsReason) { "$chartReason。$($newsReason.Text)" } else { $chartReason }
        $r | Add-Member -MemberType NoteProperty -Name "Reason" -Value $reasonText -Force
        $r | Add-Member -MemberType NoteProperty -Name "ReasonLink" -Value $(if ($newsReason) { $newsReason.Link } else { $null }) -Force

        $aiId = New-KabuAIItem -Name $r.Name -Context $reasonText -ChangePct $r.ChangePct -TrendPct5d $r.TrendPct5d -IsBuyCandidate $IsBuyCandidate
        $r | Add-Member -MemberType NoteProperty -Name "AIId" -Value $aiId -Force
    }
    return $rows
}
$grRisers = Add-KabuReason $grRisers
$grFallers = Add-KabuReason $grFallers
$grBreakout = Add-KabuReason $grBreakout -IsBuyCandidate $true
$grPullback = Add-KabuReason $grPullback -IsBuyCandidate $true

function Get-KabuAIHtml($AIId, $Insights) {
    # AI(Claude API)の分析結果をHTML断片にする。未取得/失敗時は空文字（ルールベース表示のみになる）。
    if (-not $Insights.ContainsKey($AIId)) { return "" }
    $ai = $Insights[$AIId]
    $lines = New-Object System.Collections.Generic.List[string]
    if ($ai.summary) { $lines.Add("AI要約: $($ai.summary)") }
    if ($ai.expectedMove) { $lines.Add("変動目安: $($ai.expectedMove)（信頼度: $($ai.confidencePct)%）") }
    if ($ai.recommendationScore -and $ai.recommendationScore -gt 0) {
        $lines.Add("買い目おすすめ度: $($ai.recommendationScore)/100 — $($ai.buyRationale)")
    }
    if ($lines.Count -eq 0) { return "" }
    return "<div style='margin-top:2px;'>" + ($lines -join "<br/>") + "</div>"
}

function Build-Table($rows, $cols, $Insights) {
    $header = "<tr>" + (($cols | ForEach-Object { "<th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>$_</th>" }) -join "") + "</tr>"
    $body = foreach ($r in $rows) {
        $reasonCell = if ($r.ReasonLink) { "$($r.Reason) <a href='$($r.ReasonLink)' style='font-size:12px;'>[記事]</a>" } else { $r.Reason }
        $aiHtml = Get-KabuAIHtml -AIId $r.AIId -Insights $Insights
        "<tr><td style='padding:4px 8px;'>$($r.Name)</td><td style='padding:4px 8px;'>$($r.Ticker)</td>" +
        "<td style='padding:4px 8px;'>$($r.LastClose)</td>" +
        "<td style='padding:4px 8px;color:$(if($r.ChangePct -ge 0){"#c0392b"}else{"#2471a3"});'>$(Format-Pct $r.ChangePct)</td>" +
        "<td style='padding:4px 8px;'>$(Format-Pct $r.TrendPct5d)</td>" +
        "<td style='padding:4px 8px;'>x$($r.VolumeRatio)</td></tr>" +
        "<tr><td colspan='6' style='padding:0 8px 8px 8px;font-size:12px;color:#555;'>根拠: $reasonCell$aiHtml</td></tr>"
    }
    return "<table style='border-collapse:collapse;font-size:14px;'>$header$($body -join '')</table>"
}
$cols = @("銘柄", "コード", "終値", "前日比", "5日トレンド", "出来高倍率")

function Build-SimpleTable($rows) {
    # 大型株の参考表示用。根拠・AI要約は付けない簡易テーブル（短期売買のメインはグロース株のため）。
    $header = "<tr>" + (($cols | ForEach-Object { "<th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>$_</th>" }) -join "") + "</tr>"
    $body = foreach ($r in $rows) {
        "<tr><td style='padding:4px 8px;'>$($r.Name)</td><td style='padding:4px 8px;'>$($r.Ticker)</td>" +
        "<td style='padding:4px 8px;'>$($r.LastClose)</td>" +
        "<td style='padding:4px 8px;color:$(if($r.ChangePct -ge 0){"#c0392b"}else{"#2471a3"});'>$(Format-Pct $r.ChangePct)</td>" +
        "<td style='padding:4px 8px;'>$(Format-Pct $r.TrendPct5d)</td>" +
        "<td style='padding:4px 8px;'>x$($r.VolumeRatio)</td></tr>"
    }
    return "<table style='border-collapse:collapse;font-size:13px;color:#555;'>$header$($body -join '')</table>"
}

# --- 保有株セクション ---
# assetType が "fund" (投資信託) の場合、基準価額は1日1回更新かつ直接取得できないため、
# 連動する指数(proxyTicker)＋為替(fxAdjusted時)から推定した参考値を出す。
$portfolioHtml = ""
if ($portfolio -and $portfolio.Count -gt 0) {
    $fxChart = Get-YahooChart -Ticker "JPY=X" -Range "5d" -Interval "1d"
    Start-Sleep -Milliseconds 300
    $fxMomentum = if ($fxChart) { Get-KabuMomentum -Chart $fxChart } else { $null }

    $rows = foreach ($h in $portfolio) {
        $assetType = if ($h.assetType) { $h.assetType } else { "stock" }

        if ($assetType -eq "fund") {
            $c = Get-YahooChart -Ticker $h.proxyTicker -Range "1mo" -Interval "1d"
            Start-Sleep -Milliseconds 300
            if (-not $c) { continue }
            $m = Get-KabuMomentum -Chart $c
            if (-not $m) { continue }
            $fxPct = if ($h.fxAdjusted -and $fxMomentum) { $fxMomentum.ChangePct } else { 0 }
            $estPct = [math]::Round($m.ChangePct + $fxPct, 2)
            $fxTrendPct = if ($h.fxAdjusted -and $fxMomentum) { $fxMomentum.TrendPct5d } else { 0 }
            $estTrend = [math]::Round($m.TrendPct5d + $fxTrendPct, 2)
            $view = "推定値（連動指数 $($h.proxyName): $(Format-Pct $m.ChangePct)" + $(if ($h.fxAdjusted) { "、ドル円: $(Format-Pct $fxPct)" } else { "" }) + "）"
            $newsReason = Get-KabuNewsReasonText -Query $h.proxyName
            Start-Sleep -Milliseconds 300
            if ($newsReason) { $view += "。$($newsReason.Text) <a href='$($newsReason.Link)' style='font-size:12px;'>[記事]</a>" }
            $aiId = New-KabuAIItem -Name $h.name -Context $view -ChangePct $estPct -TrendPct5d $estTrend
            [PSCustomObject]@{ Name = $h.name; Ticker = $h.proxyName; LastClose = "(推定)"; ChangePct = $estPct; TrendPct5d = $estTrend; VolumeRatio = "-"; View = $view; AIId = $aiId }
        } else {
            $c = Get-YahooChart -Ticker $h.ticker -Range "1mo" -Interval "1d"
            Start-Sleep -Milliseconds 300
            if (-not $c) { continue }
            $m = Get-KabuMomentum -Chart $c
            if (-not $m) { continue }
            $view = if ($m.ChangePct -gt 1 -and $m.TrendPct5d -gt 0) { "続伸に注意（強い上昇基調）" }
                    elseif ($m.ChangePct -lt -1 -and $m.TrendPct5d -lt 0) { "下落継続に注意（弱い基調）" }
                    elseif ($m.VolumeRatio -gt 2) { "出来高急増、方向感の変化に注意" }
                    else { "目立った変化なし、様子見" }
            $view += "（" + (Get-KabuChartReasonText -Momentum $m) + "）"
            $newsReason = Get-KabuNewsReasonText -Query $h.name
            Start-Sleep -Milliseconds 300
            if ($newsReason) { $view += "。$($newsReason.Text) <a href='$($newsReason.Link)' style='font-size:12px;'>[記事]</a>" }
            $aiId = New-KabuAIItem -Name $h.name -Context $view -ChangePct $m.ChangePct -TrendPct5d $m.TrendPct5d
            [PSCustomObject]@{ Name = $h.name; Ticker = $h.ticker; LastClose = $m.LastClose; ChangePct = $m.ChangePct; TrendPct5d = $m.TrendPct5d; VolumeRatio = $m.VolumeRatio; View = $view; AIId = $aiId }
        }
    }
    $portfolioRows = $rows
} else {
    $portfolioRows = @()
}

# --- AI(Claude API)による要約・変動幅目安・信頼度・買い目おすすめ度の一括生成 ---
# 全セクション分をまとめて1回のAPI呼び出しにすることでコストを抑える。
# 失敗（未設定・ネットワークエラー・レート制限など）してもレポート全体は止めず、
# ルールベースの内容のみで送信する。
$aiInsights = @{}
if ($settings.enableAiInsights -and $aiItems.Count -gt 0) {
    try {
        $aiInsights = Get-KabuAIInsights -Items $aiItems
        Write-KabuLog "AI要約生成成功: $($aiInsights.Count)件"
    } catch {
        Write-KabuLog "AI要約生成失敗のためルールベースのみで続行: $($_.Exception.Message)" -Level "WARN"
        $aiInsights = @{}
    }
}

if ($portfolio -and $portfolio.Count -gt 0) {
    $prows = foreach ($r in $portfolioRows) {
        $aiHtml = Get-KabuAIHtml -AIId $r.AIId -Insights $aiInsights
        "<tr><td style='padding:4px 8px;'>$($r.Name)</td><td style='padding:4px 8px;'>$($r.Ticker)</td>" +
        "<td style='padding:4px 8px;'>$($r.LastClose)</td>" +
        "<td style='padding:4px 8px;color:$(if($r.ChangePct -ge 0){"#c0392b"}else{"#2471a3"});'>$(Format-Pct $r.ChangePct)</td>" +
        "<td style='padding:4px 8px;'>$($r.View)$aiHtml</td></tr>"
    }
    $portfolioHtml = "<h3>保有株の本日の見立て</h3><table style='border-collapse:collapse;font-size:14px;'>" +
        "<tr><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>銘柄</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>コード/参照指数</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>終値</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>前日比(推定含む)</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>コメント</th></tr>" +
        ($prows -join "") + "</table>"
} else {
    $portfolioHtml = "<p style='color:#888;'>保有株が config\portfolio.json に登録されていません。編集すると保有株の見立てが表示されます。</p>"
}

$today = Get-Date -Format "yyyy-MM-dd (ddd)"

$body = @"
<div style='font-family:sans-serif;'>
<h2>kabuzidou 朝レポート $today</h2>
<p style='background:#fff3cd;padding:8px;border-radius:4px;font-size:13px;'>
※本レポートは過去の値動き・出来高・ニュース見出しから機械的/AIが算出した参考情報であり、将来の株価上昇/下落を保証するものではありません。
「信頼度」「おすすめ度」も統計的な的中率ではなく、材料がどれだけ揃っているかの目安に過ぎません。投資判断はご自身の責任で行ってください。
</p>

<h3>市場概況</h3>
<table style='border-collapse:collapse;font-size:14px;'>
<tr><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>指標</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>値</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>前日比</th></tr>
$($indexRows -join "")
</table>

<h2 style='margin-top:24px;'>グロース株（短期売買メイン）</h2>

<h3>本日上がりそうなグロース株</h3>
$(Build-Table $grRisers $cols $aiInsights)

<h3>本日下がりそうなグロース株</h3>
$(Build-Table $grFallers $cols $aiInsights)

<h3>短期エントリー候補（出来高急増・上昇中のブレイクアウト型）</h3>
$(if ($grBreakout.Count -gt 0) { Build-Table $grBreakout $cols $aiInsights } else { "<p style='color:#888;'>条件に合致する銘柄はありませんでした。</p>" })

<h3>押し目買い候補（中期上昇トレンド中の一服）</h3>
$(if ($grPullback.Count -gt 0) { Build-Table $grPullback $cols $aiInsights } else { "<p style='color:#888;'>条件に合致する銘柄はありませんでした。</p>" })

<h2 style='margin-top:24px;'>大型株（参考情報）</h2>
<h3>値上がり上位</h3>
$(Build-SimpleTable $lgRisers)
<h3>値下がり上位</h3>
$(Build-SimpleTable $lgFallers)

$portfolioHtml

<p style='font-size:12px;color:#888;margin-top:16px;'>watchlist・portfolioは config フォルダのJSONを編集することで自由に変更できます。</p>
</div>
"@

Send-KabuMail -Subject "【株info】$today 朝レポート" -BodyHtml $body
Write-KabuLog "=== 朝レポート生成完了 ==="
