# Get-EveningReview.ps1
# 朝レポート(Get-MorningReport.ps1)で提示した予測が実際どうだったかを、当日の終値で答え合わせする。
# JST 17:13頃（東証の大引け後）に実行される想定（.github/workflows/evening-review.yml参照）。
# 結果はメール送信するとともに、AI分析による教訓(calibrationNotes)をstate/lessons.jsonに蓄積し、
# 翌朝以降のGet-MorningReport.ps1のAI見積もり精度向上に役立てる。

. "$PSScriptRoot\Common.ps1"

Write-KabuLog "=== 夕方レポート(答え合わせ)生成開始 ==="

$settings = Get-KabuConfig -Name "settings"
if ($settings.PSObject.Properties.Name -contains "eveningReviewEnabled" -and -not $settings.eveningReviewEnabled) {
    Write-KabuLog "eveningReviewEnabled=falseのためスキップ"
    exit 0
}

$todayIso = (Get-KabuJstNow).ToString("yyyy-MM-dd")
$snapshot = Get-KabuPredictionSnapshot -Date $todayIso
if (-not $snapshot -or -not $snapshot.items -or @($snapshot.items).Count -eq 0) {
    Write-KabuLog "本日($todayIso)の予測スナップショットが見つからないため答え合わせをスキップ（朝レポート未実行または休場日の可能性）"
    exit 0
}

function Get-KabuActualOHLC {
    # 大引け後の実績値（始値・高値・安値・終値・値幅）をチャートから取得する。
    param([Parameter(Mandatory)][string]$Ticker)
    $c = Get-YahooChart -Ticker $Ticker -Range "5d" -Interval "1d"
    if (-not $c) { return $null }
    return Get-KabuMomentum -Chart $c
}

$sectionLabels = @{
    riser     = "本日上がりそうなグロース株"
    faller    = "本日下がりそうなグロース株"
    breakout  = "短期エントリー候補(ブレイクアウト型)"
    pullback  = "押し目買い候補"
    portfolio = "保有株"
}

# --- 各予測項目の実績値（始値・高値・安値・終値・値幅）を取得し、朝との差分を計算する ---
$reviewItems = New-Object System.Collections.Generic.List[object]
foreach ($p in $snapshot.items) {
    $actualM = Get-KabuActualOHLC -Ticker $p.ticker
    Start-Sleep -Milliseconds 300
    $actualClose = if ($actualM) { $actualM.LastClose } else { $null }
    if (-not $actualClose -or -not $p.baseClose -or $p.baseClose -eq 0) {
        Write-KabuLog "実績値取得スキップ ($($p.name)/$($p.ticker))" -Level "WARN"
        continue
    }
    $actualChangePct = [math]::Round((($actualClose - [double]$p.baseClose) / [double]$p.baseClose) * 100, 2)
    $id = "item$($reviewItems.Count + 1)"
    $reviewItems.Add([PSCustomObject]@{
        Id                    = $id
        Section               = $p.section
        SectionLabel          = if ($sectionLabels.ContainsKey($p.section)) { $sectionLabels[$p.section] } else { $p.section }
        Name                  = $p.name
        Ticker                = $p.ticker
        BaseClose             = $p.baseClose
        ActualOpen            = $actualM.LastOpen
        ActualHigh            = $actualM.LastHigh
        ActualLow             = $actualM.LastLow
        ActualClose           = $actualClose
        ActualChangePct       = $actualChangePct
        ActualRangePct        = $actualM.RangePct
        AiExpectedMove        = $p.aiExpectedMove
        AiConfidencePct       = $p.aiConfidencePct
        AiSummary             = $p.aiSummary
        View                  = $p.view
        IsBuyCandidate        = [bool]$p.isBuyCandidate
    })
}

if ($reviewItems.Count -eq 0) {
    Write-KabuLog "実績値を取得できた予測項目が0件のため答え合わせをスキップ"
    exit 0
}

# --- AI(Claude API)による的中度評価・全体分析・教訓抽出 ---
# 失敗時は生データ（予測 vs 実績）のみのメールにフォールバックし、教訓の保存はスキップする
# （不正確な教訓を次回以降のプロンプトに混入させないため）。
$aiReview = $null
if ($settings.enableAiInsights) {
    try {
        $itemsForPrompt = $reviewItems | ForEach-Object {
            [PSCustomObject]@{
                id              = $_.Id
                name            = $_.Name
                section         = $_.SectionLabel
                isBuyCandidate  = $_.IsBuyCandidate
                aiExpectedMove  = $_.AiExpectedMove
                aiConfidencePct = $_.AiConfidencePct
                view            = $_.View
                actualChangePct = $_.ActualChangePct
                actualRangePct  = $_.ActualRangePct
            }
        }
        $itemsJson = $itemsForPrompt | ConvertTo-Json -Depth 5 -Compress

        $systemPrompt = @"
あなたは日本の個人投資家向けの株価予測システムの精度検証を行うアシスタントです。
朝レポートで提示した各銘柄の予測（変動目安aiExpectedMove・信頼度aiConfidencePct・保有株の見立てview）と、
その日の終値時点での実際の騰落率(actualChangePct、当日始値からではなく前日終値基準)・当日の値幅(actualRangePct、
高値と安値の差を終値比%にしたもの)を比較し、日本語で以下を生成してください。
actualRangePctが大きい銘柄は日中の振れ幅も大きかったことを踏まえてコメントしてください
（例: 終値ベースでは小幅でも値幅が大きければ「日中の振れ幅は大きかった」等）。

- items: 各銘柄について
  - id: 対応するid
  - verdict: "的中" (予測方向・程度が概ね合っていた) / "概ね妥当" (方向は合っていたが程度に差がある、または材料通りだが小幅) / "外れ" (予測方向と逆に動いた) / "判定不能" (予測が曖昧で判定できない) のいずれか
  - comment: 予測と実績を踏まえた一言コメント（1文、専門用語を避けて簡潔に）
- overallSummary: 本日全体の的中傾向を2〜3文で要約（例: 何件中何件が的中傾向だったか、どのセクションが強かった/弱かったか）
- calibrationNotes: 次回以降の朝レポート生成AIへの引き継ぎメモ。confidencePctやexpectedMoveの見積もりをどう調整すべきかを1〜2文で具体的に（例:「出来高急増を伴う銘柄は的中率が高い傾向。信頼度50%台でも外れる例が複数あったため、材料が薄い場合はより慎重な変動目安にすべき」）。抽象論ではなく、次回のAIが読んで行動を変えられる具体性を持たせること。

統計的に厳密な評価ではなく、あくまで参考情報の改善のための定性評価であることを踏まえてください。
"@

        $schema = @{
            type = "object"
            properties = @{
                items = @{
                    type = "array"
                    items = @{
                        type = "object"
                        properties = @{
                            id      = @{ type = "string" }
                            verdict = @{ type = "string"; enum = @("的中", "概ね妥当", "外れ", "判定不能") }
                            comment = @{ type = "string" }
                        }
                        required = @("id", "verdict", "comment")
                        additionalProperties = $false
                    }
                }
                overallSummary   = @{ type = "string" }
                calibrationNotes = @{ type = "string" }
            }
            required = @("items", "overallSummary", "calibrationNotes")
            additionalProperties = $false
        }

        $aiReview = Invoke-KabuAnthropicMessages -SystemPrompt $systemPrompt `
            -UserContent "本日の予測と実績の一覧です。指示された形式で分析してください:`n$itemsJson" -Schema $schema
        if ($aiReview) {
            Write-KabuLog "答え合わせAI分析成功: $($aiReview.items.Count)件"
        }
    } catch {
        Write-KabuLog "答え合わせAI分析失敗のため生データのみで続行: $($_.Exception.Message)" -Level "WARN"
        $aiReview = $null
    }
}

$verdictMap = @{}
if ($aiReview) {
    foreach ($v in $aiReview.items) { $verdictMap[$v.id] = $v }
}

# --- メール本文組み立て ---
function Format-Pct($v) {
    if ($null -eq $v) { return "-" }
    $sign = if ($v -gt 0) { "+" } else { "" }
    return "$sign$v%"
}

$rowsHtml = foreach ($r in ($reviewItems | Sort-Object -Property Section)) {
    $predicted = if ($r.Section -eq "portfolio") { $r.View } else { $r.AiExpectedMove }
    if (-not $predicted) { $predicted = "(AI見積もりなし)" }
    $confText = if ($null -ne $r.AiConfidencePct) { "（信頼度$($r.AiConfidencePct)%）" } else { "" }
    $v = $verdictMap[$r.Id]
    $verdictHtml = if ($v) {
        $color = switch ($v.verdict) {
            "的中"     { "#1e7e34" }
            "概ね妥当" { "#856404" }
            "外れ"     { "#c0392b" }
            default    { "#888" }
        }
        "<b style='color:$color;'>$($v.verdict)</b><br/><span style='font-size:12px;color:#555;'>$($v.comment)</span>"
    } else { "-" }
    "<tr><td style='padding:4px 8px;'>$($r.SectionLabel)</td><td style='padding:4px 8px;'>$($r.Name)</td>" +
    "<td style='padding:4px 8px;font-size:13px;'>$predicted$confText</td>" +
    "<td style='padding:4px 8px;'>$($r.ActualOpen)</td><td style='padding:4px 8px;'>$($r.ActualHigh)</td><td style='padding:4px 8px;'>$($r.ActualLow)</td><td style='padding:4px 8px;'>$($r.ActualClose)</td>" +
    "<td style='padding:4px 8px;color:$(if($r.ActualChangePct -ge 0){"#c0392b"}else{"#2471a3"});'>$(Format-Pct $r.ActualChangePct)</td>" +
    "<td style='padding:4px 8px;'>$(Format-Pct $r.ActualRangePct)</td>" +
    "<td style='padding:4px 8px;'>$verdictHtml</td></tr>"
}

$overallHtml = if ($aiReview -and $aiReview.overallSummary) {
    "<h3>本日の総括</h3><p>$($aiReview.overallSummary)</p>"
} else {
    "<p style='color:#888;'>AI分析が利用できなかったため、総括はありません（予測 vs 実績の生データのみ表示）。</p>"
}

$jstNow = Get-KabuJstNow
$body = @"
<div style='font-family:sans-serif;'>
<h2>kabuzidou 結果検証(答え合わせ) $($jstNow.ToString("yyyy-MM-dd HH:mm"))</h2>
<p style='background:#fff3cd;padding:8px;border-radius:4px;font-size:13px;'>
本日朝レポートで提示した予測と、大引け時点の実績を比較したものです。的中/外れの判定は統計的な精度指標ではなく、
今後の見積もり改善のための参考情報です。
</p>
$overallHtml
<h3>銘柄別 予測 vs 実績</h3>
<table style='border-collapse:collapse;font-size:14px;'>
<tr><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>区分</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>銘柄</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>朝の予測</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>始値</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>高値</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>安値</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>終値</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>前日比</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>値幅</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>判定</th></tr>
$($rowsHtml -join "")
</table>
</div>
"@

Send-KabuMail -Subject "【株info】$($jstNow.ToString('yyyy-MM-dd')) 結果検証(答え合わせ)" -BodyHtml $body
Write-KabuLog "答え合わせメール送信完了: $($reviewItems.Count)件"

# --- 教訓の保存（次回以降の朝レポートAIプロンプトに反映） ---
if ($aiReview -and $aiReview.calibrationNotes) {
    Add-KabuLesson -Lesson ([PSCustomObject]@{
        date             = $todayIso
        overallSummary   = $aiReview.overallSummary
        calibrationNotes = $aiReview.calibrationNotes
        itemCount        = $reviewItems.Count
    })
    Write-KabuLog "教訓をstate/lessons.jsonに保存"
}

Write-KabuLog "=== 夕方レポート(答え合わせ)生成完了 ==="
