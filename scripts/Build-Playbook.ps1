# Build-Playbook.ps1
# state/audits/ と state/predictions/ の全期間データを結合し、区分・確信度帯・トレンド幅帯・
# 材料種別・値動きの荒さ・個別銘柄ごとの的中率を定量集計して state/playbook.json に一本化する。
# Get-WeeklyStrategy.ps1(Claude APIによる文章での傾向抽出)を補完する、LLMを使わない決定的な集計ツール。
# データが増えるたびに再実行すれば、最新の全期間傾向を反映したplaybookに更新される。

. "$PSScriptRoot\Common.ps1"

Write-KabuLog "=== Playbook再集計開始 ==="

$auditHistory = Get-KabuAuditHistory
if ($auditHistory.Count -eq 0) {
    Write-KabuLog "監査データが無いためPlaybook生成をスキップ" -Level "WARN"
    exit 0
}

$GoodVerdicts = @("的中", "概ね妥当")

function New-KabuHitRate($items) {
    $n = @($items).Count
    if ($n -eq 0) { return [PSCustomObject]@{ n = 0; hitRatePct = $null; detail = @{} } }
    $detail = [ordered]@{}
    foreach ($it in $items) {
        $v = $it.verdict
        if (-not $detail.Contains($v)) { $detail[$v] = 0 }
        $detail[$v]++
    }
    $good = 0
    foreach ($v in $GoodVerdicts) { if ($detail.Contains($v)) { $good += $detail[$v] } }
    return [PSCustomObject]@{ n = $n; hitRatePct = [math]::Round(($good / $n) * 100, 1); detail = $detail }
}

function Get-KabuConfBucket($c) {
    if ($null -eq $c) { return "unknown" }
    if ($c -lt 20) { return "0-19" }
    if ($c -lt 30) { return "20-29" }
    if ($c -lt 40) { return "30-39" }
    return "40+"
}

function Get-KabuTrendBucket($t) {
    if ($null -eq $t) { return "unknown" }
    if ($t -ge 15) { return ">=15%" }
    if ($t -ge 5) { return "5-15%" }
    if ($t -ge 0) { return "0-5%" }
    return "<0%"
}

# --- audits(結果)とpredictions(材料・確信度・trend等)を(date,section,name)で結合 ---
$dataset = New-Object System.Collections.Generic.List[object]
foreach ($audit in $auditHistory) {
    $date = $audit.date
    $prediction = Get-KabuPredictionSnapshot -Date $date
    $predMap = @{}
    if ($prediction) {
        foreach ($p in @($prediction.items)) {
            $predMap["$($p.section)|$($p.name)"] = $p
        }
    }
    foreach ($it in @($audit.items)) {
        $p = $predMap["$($it.section)|$($it.name)"]
        $dataset.Add([PSCustomObject]@{
            date            = $date
            section         = $it.section
            name            = $it.name
            ticker          = $it.ticker
            isBuyCandidate  = $it.isBuyCandidate
            aiConfidencePct = $it.aiConfidencePct
            trendPct5d      = if ($p) { $p.trendPct5d } else { $null }
            baseRangePct    = if ($p) { $p.baseRangePct } else { $null }
            materialType    = if ($p -and $p.materialType) { $p.materialType } else { $null }
            actualChangePct = $it.actualChangePct
            actualRangePct  = $it.actualRangePct
            verdict         = $it.verdict
            causalAnalysis  = $it.causalAnalysis
        })
    }
}

$dataset = @($dataset.ToArray())
$total = $dataset.Count
$overallHitRatePct = [math]::Round((@($dataset | Where-Object { $GoodVerdicts -contains $_.verdict }).Count / $total) * 100, 1)

$verdictCounts = [ordered]@{}
foreach ($it in $dataset) {
    if (-not $verdictCounts.Contains($it.verdict)) { $verdictCounts[$it.verdict] = 0 }
    $verdictCounts[$it.verdict]++
}

$bySection = [ordered]@{}
foreach ($sec in ($dataset.section | Sort-Object -Unique)) {
    $bySection[$sec] = New-KabuHitRate ($dataset | Where-Object { $_.section -eq $sec })
}

$byConf = [ordered]@{}
foreach ($b in @("0-19", "20-29", "30-39", "40+")) {
    $byConf[$b] = New-KabuHitRate ($dataset | Where-Object { (Get-KabuConfBucket $_.aiConfidencePct) -eq $b })
}

$byTrend = [ordered]@{ faller = [ordered]@{}; riser = [ordered]@{} }
foreach ($sec in @("faller", "riser")) {
    foreach ($b in @("<0%", "0-5%", "5-15%", ">=15%")) {
        $byTrend[$sec][$b] = New-KabuHitRate ($dataset | Where-Object { $_.section -eq $sec -and (Get-KabuTrendBucket $_.trendPct5d) -eq $b })
    }
}

$byMaterial = [ordered]@{}
foreach ($mt in @("disclosure", "news", "chart_only")) {
    $byMaterial[$mt] = New-KabuHitRate ($dataset | Where-Object { $_.materialType -eq $mt })
}
$byMaterial["untagged"] = New-KabuHitRate ($dataset | Where-Object { -not $_.materialType })

$byVolatility = [ordered]@{
    "<=6%" = New-KabuHitRate ($dataset | Where-Object { $null -ne $_.baseRangePct -and $_.baseRangePct -le 6 })
    ">6%"  = New-KabuHitRate ($dataset | Where-Object { $null -ne $_.baseRangePct -and $_.baseRangePct -gt 6 })
}

$buyCandidateStats = New-KabuHitRate ($dataset | Where-Object { $_.isBuyCandidate })

$problemTickers = $dataset | Group-Object -Property ticker, name | Where-Object { $_.Count -ge 5 } | ForEach-Object {
    $hr = New-KabuHitRate $_.Group
    $first = $_.Group[0]
    [PSCustomObject]@{ ticker = $first.ticker; name = $first.name; appearances = $_.Count; n = $hr.n; hitRatePct = $hr.hitRatePct; detail = $hr.detail }
} | Sort-Object -Property hitRatePct

$patterns = @(
    [PSCustomObject]@{
        id = "confidence-discipline-works"
        finding = "aiConfidencePctが20%未満の予測は的中+概ね妥当率$($byConf['0-19'].hitRatePct)%(n=$($byConf['0-19'].n))で、20%以上の各帯より明確に高い。確信度を低く抑える運用そのものが精度向上に寄与している。"
        evidence = $byConf
        recommendation = "具体的な一次情報による強い裏付けが無い限り、aiConfidencePctは20%未満をデフォルトとする。"
    },
    [PSCustomObject]@{
        id = "sections-balance-check"
        finding = "riser/faller/pullback/breakoutの4区分の的中+概ね妥当率のばらつきを毎回確認し、特定区分だけが突出して悪化していないかを追跡する。"
        evidence = $bySection
        recommendation = "区分間の差が大きい場合は、その区分の確信度運用を優先的に見直す。"
    },
    [PSCustomObject]@{
        id = "riser-mid-trend-check"
        finding = "riser(上がりそう)のtrendPct5d帯ごとの的中率を確認し、中間帯(5〜15%)が他帯より弱くなっていないか追跡する。"
        evidence = $byTrend.riser
        recommendation = "trendPct5dが5〜15%のriser候補は確信度を追加で引き下げることを検討する。"
    },
    [PSCustomObject]@{
        id = "faller-high-trend-check"
        finding = "faller(下がりそう)のtrendPct5d帯ごとの的中率を確認し、+15%以上の急騰銘柄への反転予測が弱くなっていないか追跡する(サンプル数に注意)。"
        evidence = $byTrend.faller
        recommendation = "trendPct5dが+15%以上のfaller候補は確信度を上げすぎず反発リスクを併記する。"
    },
    [PSCustomObject]@{
        id = "chronic-problem-tickers"
        finding = "出現回数5回以上で的中率が低い銘柄(problemTickers参照)は個別銘柄レベルでの構造的な予測困難性がある可能性が高い。"
        evidence = @($problemTickers | Select-Object -First 5)
        recommendation = "problemTickersに載っている銘柄が候補に挙がった場合は、個別に確信度上限を設けるか予測困難である旨を明記する。"
    },
    [PSCustomObject]@{
        id = "volatility-effect"
        finding = "baseRangePctが6%を超える値動きの荒い銘柄と6%以下の銘柄の的中率差を確認する。"
        evidence = $byVolatility
        recommendation = "差が大きい場合は値動きの荒い銘柄の確信度を追加で引き下げ、差が小さければ値幅レンジの調整のみに留める。"
    },
    [PSCustomObject]@{
        id = "materialtype-tracking"
        finding = "TDnet適時開示(disclosure)/ニュース(news)/材料なし(chart_only)別の的中率を継続追跡する。データが薄いうちは断定しない。"
        evidence = $byMaterial
        recommendation = "disclosureのサンプルが十分に蓄積されてから材料種別ごとの傾向を判断する。"
    }
)

$tradingRules = @(
    [PSCustomObject]@{ condition = "具体的な一次情報(決算・適時開示等)による強い裏付けが無い"; action = "aiConfidencePct < 20 をデフォルトとする" }
    [PSCustomObject]@{ condition = "section == riser AND 5% <= trendPct5d < 15%"; action = "aiConfidencePctを追加で5〜10pt引き下げる" }
    [PSCustomObject]@{ condition = "section == faller AND trendPct5d >= 15%"; action = "確信度を上げすぎず反発リスクを併記する(サンプル少、参考程度)" }
    [PSCustomObject]@{ condition = "problemTickersに載っている銘柄が候補に挙がった場合"; action = "個別に確信度上限を設けるか、予測困難である旨を明記する" }
    [PSCustomObject]@{ condition = "baseRangePct > 6%（値動きが荒い）"; action = "値幅レンジの上下限は実績を踏まえて広めに設定する" }
)

$playbook = [PSCustomObject]@{
    generatedAt        = (Get-KabuJstNow).ToString("yyyy-MM-dd")
    sourceRange        = [PSCustomObject]@{ from = $dataset[0].date; to = $dataset[-1].date }
    auditDaysCount     = $auditHistory.Count
    totalItems         = $total
    verdictCounts      = $verdictCounts
    overallHitRatePct  = $overallHitRatePct
    bySection          = $bySection
    byConfidenceBucket = $byConf
    byTrendBucket      = $byTrend
    byMaterialType     = $byMaterial
    byVolatility       = $byVolatility
    buyCandidateStats  = $buyCandidateStats
    problemTickers     = @($problemTickers)
    patterns           = $patterns
    tradingRules       = $tradingRules
    dataset            = @($dataset)
}

$path = Join-Path $script:StateDir "playbook.json"
$playbook | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
Write-KabuLog "Playbookをstate/playbook.jsonに保存（$total 件、$($auditHistory.Count) 日分、全体的中+概ね妥当率 $overallHitRatePct%）"
Write-KabuLog "=== Playbook再集計完了 ==="
