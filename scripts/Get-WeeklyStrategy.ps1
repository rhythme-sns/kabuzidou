# Get-WeeklyStrategy.ps1
# ストラテジスト: これまで蓄積された監査官の因果分析(state/audits/)と
# 戦略コンサルタントの反省点(state/lessons.json)を全期間分俯瞰し、
# 繰り返し現れる勝ちパターン・負けパターンを抽出して取引基準を作成、メールで報告する。
# 毎週末（例: 土曜朝）に実行される想定（.github/workflows/weekly-strategy.yml参照。
# GitHub Actionsのschedule遅延問題を避けるため、朝レポート/夕方レビューと同様に
# 外部cronサービスからworkflow_dispatchを叩く運用。README.mdの「メール配信スケジュール」参照）。

. "$PSScriptRoot\Common.ps1"

Write-KabuLog "=== 週次ストラテジストレポート生成開始 ==="

$settings = Get-KabuConfig -Name "settings"
if ($settings.PSObject.Properties.Name -contains "weeklyStrategyEnabled" -and -not $settings.weeklyStrategyEnabled) {
    Write-KabuLog "weeklyStrategyEnabled=falseのためスキップ"
    exit 0
}
if (-not $settings.enableAiInsights) {
    Write-KabuLog "enableAiInsights=falseのため週次ストラテジストレポートはスキップ（AI分析が前提のため）"
    exit 0
}

$auditHistory = Get-KabuAuditHistory
$minDays = if ($settings.weeklyStrategyMinDays) { [int]$settings.weeklyStrategyMinDays } else { 5 }
$todayIso = (Get-KabuJstNow).ToString("yyyy-MM-dd")

if ($auditHistory.Count -lt $minDays) {
    Write-KabuLog "監査データが$($auditHistory.Count)日分しかなく($minDays日未満)、パターン抽出には不十分なためスキップ"
    $jstNow = Get-KabuJstNow
    $body = @"
<div style='font-family:sans-serif;'>
<h2>kabuzidou 週次 取引基準レポート $($jstNow.ToString("yyyy-MM-dd"))</h2>
<p>まだ監査官の分析データが $($auditHistory.Count) 日分しか蓄積されていません（パターン抽出には最低 $minDays 日分が必要です）。
朝レポート・夕方の答え合わせが継続して実行されれば、データが貯まり次第このレポートで意味のあるパターン分析が届くようになります。</p>
</div>
"@
    Send-KabuMail -Subject "【株info】週次 取引基準レポート $($jstNow.ToString('yyyy-MM-dd'))（データ蓄積中）" -BodyHtml $body
    Write-KabuLog "=== 週次ストラテジストレポート生成完了（データ不足のため簡易版） ==="
    exit 0
}

# --- 監査官の日次因果分析を、日付ごとの的中/外れ件数と全体総括に要約する（プロンプトを軽量に保つため） ---
$auditSummaryForPrompt = $auditHistory | ForEach-Object {
    $verdictCounts = [ordered]@{ "的中" = 0; "概ね妥当" = 0; "外れ" = 0; "判定不能" = 0 }
    foreach ($it in @($_.items)) {
        if ($it.verdict -and $verdictCounts.Contains($it.verdict)) { $verdictCounts[$it.verdict]++ }
    }
    [PSCustomObject]@{
        date                  = $_.date
        itemCount             = $_.itemCount
        verdictCounts         = $verdictCounts
        overallCausalSummary  = $_.overallCausalSummary
    }
}

# --- 戦略コンサルタントが蓄積してきた反省点・負けパターンの記録（既に凝縮された材料） ---
$lessons = Get-KabuLessons
$lessonsForPrompt = $lessons | ForEach-Object {
    [PSCustomObject]@{
        date              = $_.date
        reflectionPoints  = $_.reflectionPoints
        losingPatternNote = $_.losingPatternNote
        calibrationNotes  = $_.calibrationNotes
    }
}

$auditJson = $auditSummaryForPrompt | ConvertTo-Json -Depth 6 -Compress
$lessonsJson = $lessonsForPrompt | ConvertTo-Json -Depth 6 -Compress

$systemPrompt = @"
あなたは日本の個人投資家向け株価予測システムの、全期間データを俯瞰するストラテジストです。
これまでの監査官による日次の因果分析結果の集計（日ごとの的中/外れ件数と全体総括、auditHistory）と、
戦略コンサルタントが日々蓄積してきた反省点・負けパターンの記録（lessonsHistory）をもとに、
個別銘柄の一時的な話ではなく、期間を通じて繰り返し観測される傾向に注目して、日本語で以下を生成してください。

- winPatterns: 繰り返し的中に繋がっている「勝ちパターン」を配列で（根拠となった材料の傾向を具体的に。例:「出来高2倍以上かつニュース材料が伴う銘柄は的中率が高い」）
- losePatterns: 繰り返し外れに繋がっている「負けパターン」を配列で（同様に具体的に）
- tradingCriteria: 今後の取引判断に使える具体的な基準（実行可能なルールの形で配列。例:「出来高1.5倍未満の銘柄は短期エントリー候補から除外する」）
- summary: 全期間を通じた傾向の総括を2〜4文で

データが十分でない領域については無理に断定せず、材料が薄い場合はその旨を明記してください。統計的に厳密な検証ではなく、
参考情報としての傾向分析であることを踏まえてください。
"@

$schema = @{
    type = "object"
    properties = @{
        winPatterns     = @{ type = "array"; items = @{ type = "string" } }
        losePatterns    = @{ type = "array"; items = @{ type = "string" } }
        tradingCriteria = @{ type = "array"; items = @{ type = "string" } }
        summary         = @{ type = "string" }
    }
    required = @("winPatterns", "losePatterns", "tradingCriteria", "summary")
    additionalProperties = $false
}

$strategyResult = $null
try {
    $strategyResult = Invoke-KabuAnthropicMessages -SystemPrompt $systemPrompt `
        -UserContent "auditHistory(日次集計、$($auditHistory.Count)日分):`n$auditJson`n`nlessonsHistory(戦略コンサルタントの記録、$($lessons.Count)件):`n$lessonsJson" `
        -Schema $schema -MaxTokens 8192
} catch {
    Write-KabuLog "ストラテジストによるパターン抽出失敗: $($_.Exception.Message)" -Level "ERROR"
}

if (-not $strategyResult) {
    Write-KabuLog "ストラテジストの分析結果が空のため終了"
    exit 1
}

Save-KabuStrategy -Date $todayIso -Strategy ([PSCustomObject]@{
    date            = $todayIso
    auditDaysCount  = $auditHistory.Count
    lessonsCount    = $lessons.Count
    winPatterns     = $strategyResult.winPatterns
    losePatterns    = $strategyResult.losePatterns
    tradingCriteria = $strategyResult.tradingCriteria
    summary         = $strategyResult.summary
})
Write-KabuLog "取引基準をstate/strategy/$todayIso.jsonに保存"

function Build-KabuList($items) {
    if (-not $items -or @($items).Count -eq 0) { return "<p style='color:#888;'>特になし</p>" }
    return "<ul>" + ((@($items) | ForEach-Object { "<li>$_</li>" }) -join "") + "</ul>"
}

$jstNow = Get-KabuJstNow
$body = @"
<div style='font-family:sans-serif;'>
<h2>kabuzidou 週次 取引基準レポート $($jstNow.ToString("yyyy-MM-dd"))</h2>
<p style='background:#fff3cd;padding:8px;border-radius:4px;font-size:13px;'>
監査官の因果分析($($auditHistory.Count)日分)と戦略コンサルタントの反省点($($lessons.Count)件)を全期間俯瞰し、
繰り返し現れる勝ちパターン・負けパターンから取引基準を抽出したものです。統計的に厳密な検証ではなく、参考情報です。
</p>
<h3>総括</h3>
<p>$($strategyResult.summary)</p>
<h3>勝ちパターン</h3>
$(Build-KabuList $strategyResult.winPatterns)
<h3>負けパターン</h3>
$(Build-KabuList $strategyResult.losePatterns)
<h3>今後の取引基準</h3>
$(Build-KabuList $strategyResult.tradingCriteria)
</div>
"@

Send-KabuMail -Subject "【株info】週次 取引基準レポート $($jstNow.ToString('yyyy-MM-dd'))" -BodyHtml $body
Write-KabuLog "週次ストラテジストレポート送信完了"
Write-KabuLog "=== 週次ストラテジストレポート生成完了 ==="
