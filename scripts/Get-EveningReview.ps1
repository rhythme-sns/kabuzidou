# Get-EveningReview.ps1
# 朝レポート(Get-MorningReport.ps1 = アナリスト)で提示した予測が実際どうだったかを、当日の終値で答え合わせする。
# JST 17:13頃（東証の大引け後）に実行される想定（.github/workflows/evening-review.yml参照）。
# ここでは2つの役割を順に実行する:
#   1. 監査官: 予測と実績を照合し、的中/外れの因果関係を厳格に分析 → state/audits/$date.json に保存（無期限蓄積）
#   2. 戦略コンサルタント: 監査官の分析から反省点・繰り返しの負けパターンを抽出し、
#      次回以降のアナリスト(Get-MorningReport.ps1)への申し送りとして state/lessons.json に蓄積
# 蓄積されたstate/audits/はGet-WeeklyStrategy.ps1（ストラテジスト）が全期間データとして参照する。

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

# ============================================================
# 役割1: 監査官 — 予測と実績を照合し、的中/外れの因果関係を厳格に分析する
# 失敗時は生データ（予測 vs 実績）のみのメールにフォールバックし、
# 監査ファイルの保存・戦略コンサルタントの実行はスキップする
# （不正確な分析を後工程やアナリストへの申し送りに混入させないため）。
# ============================================================
$auditResult = $null
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

        $auditorSystemPrompt = @"
あなたは日本の個人投資家向け株価予測システムの結果を検証する、厳格な監査官です。
朝の予測担当(アナリスト)が提示した各銘柄の予測（変動目安aiExpectedMove・信頼度aiConfidencePct・保有株の見立てview）と、
その日の終値時点での実際の騰落率(actualChangePct、当日始値からではなく前日終値基準)・当日の値幅(actualRangePct、
高値と安値の差を終値比%にしたもの)を照合し、日本語で以下を生成してください。
甘い評価はせず、外れた場合は予測のどこが弱点だったか、材料（ニュース・出来高・トレンド・値幅）のどれが決め手/誤りだったかまで
踏み込んで因果関係を分析すること。actualRangePctが大きい銘柄は日中の振れ幅も大きかった点を踏まえて評価すること。

- items: 各銘柄について
  - id: 対応するid
  - verdict: "的中" (予測方向・程度が概ね合っていた) / "概ね妥当" (方向は合っていたが程度に差がある、または材料通りだが小幅) / "外れ" (予測方向と逆に動いた) / "判定不能" (予測が曖昧で判定できない) のいずれか
  - causalAnalysis: なぜその判定になったのかの因果分析（1文、専門用語を避けて簡潔に。「〜だったため的中」「〜を見誤り外れ」のように原因を明示）
- overallCausalSummary: 本日全体の的中/外れの傾向を2〜3文で要約し、どの材料が有効/無効だったかに触れること

統計的に厳密な評価ではなく、あくまで参考情報の改善のための定性評価であることを踏まえてください。
"@

        $auditorSchema = @{
            type = "object"
            properties = @{
                items = @{
                    type = "array"
                    items = @{
                        type = "object"
                        properties = @{
                            id             = @{ type = "string" }
                            verdict        = @{ type = "string"; enum = @("的中", "概ね妥当", "外れ", "判定不能") }
                            causalAnalysis = @{ type = "string" }
                        }
                        required = @("id", "verdict", "causalAnalysis")
                        additionalProperties = $false
                    }
                }
                overallCausalSummary = @{ type = "string" }
            }
            required = @("items", "overallCausalSummary")
            additionalProperties = $false
        }

        $auditResult = Invoke-KabuAnthropicMessages -SystemPrompt $auditorSystemPrompt `
            -UserContent "本日の予測と実績の一覧です。指示された形式で因果分析してください:`n$itemsJson" -Schema $auditorSchema
        if ($auditResult) {
            Write-KabuLog "監査官による因果分析成功: $($auditResult.items.Count)件"
        }
    } catch {
        Write-KabuLog "監査官による因果分析失敗のため生データのみで続行: $($_.Exception.Message)" -Level "WARN"
        $auditResult = $null
    }
}

if ($auditResult) {
    Save-KabuAudit -Date $todayIso -Audit ([PSCustomObject]@{
        date                  = $todayIso
        items                 = $auditResult.items | ForEach-Object {
            $auditItem = $_
            $src = $reviewItems | Where-Object { $_.Id -eq $auditItem.id } | Select-Object -First 1
            [PSCustomObject]@{
                id              = $auditItem.id
                name            = if ($src) { $src.Name } else { "" }
                ticker          = if ($src) { $src.Ticker } else { "" }
                section         = if ($src) { $src.Section } else { "" }
                baseClose       = if ($src) { $src.BaseClose } else { $null }
                actualOpen      = if ($src) { $src.ActualOpen } else { $null }
                actualHigh      = if ($src) { $src.ActualHigh } else { $null }
                actualLow       = if ($src) { $src.ActualLow } else { $null }
                actualClose     = if ($src) { $src.ActualClose } else { $null }
                actualChangePct = if ($src) { $src.ActualChangePct } else { $null }
                actualRangePct  = if ($src) { $src.ActualRangePct } else { $null }
                aiExpectedMove  = if ($src) { $src.AiExpectedMove } else { "" }
                aiConfidencePct = if ($src) { $src.AiConfidencePct } else { $null }
                isBuyCandidate  = if ($src) { $src.IsBuyCandidate } else { $false }
                verdict         = $auditItem.verdict
                causalAnalysis  = $auditItem.causalAnalysis
            }
        }
        overallCausalSummary = $auditResult.overallCausalSummary
        itemCount             = $reviewItems.Count
    })
    Write-KabuLog "監査結果をstate/audits/$todayIso.jsonに保存"
}

# ============================================================
# 役割2: 戦略コンサルタント — 監査官の因果分析から反省点・繰り返しの負けパターンを抽出し、
# 次回以降のアナリストへの申し送りとしてstate/lessons.jsonに蓄積する。
# 監査官の分析が無ければ（失敗/AI無効）実行しない。
# ============================================================
$consultantResult = $null
if ($auditResult -and $settings.enableAiInsights) {
    try {
        $auditItemsForPrompt = $auditResult.items | ForEach-Object {
            $auditItem = $_
            $src = $reviewItems | Where-Object { $_.Id -eq $auditItem.id } | Select-Object -First 1
            [PSCustomObject]@{
                id             = $auditItem.id
                name           = if ($src) { $src.Name } else { "" }
                section        = if ($src) { $src.SectionLabel } else { "" }
                verdict        = $auditItem.verdict
                causalAnalysis = $auditItem.causalAnalysis
            }
        }
        $auditItemsJson = $auditItemsForPrompt | ConvertTo-Json -Depth 5 -Compress
        $recentLessonsContext = Get-KabuLessonsContext

        $consultantSystemPrompt = @"
あなたは日本の個人投資家向け株価予測システムの改善を担当する、戦略コンサルタントです。
監査官による本日の因果分析結果（各銘柄の的中/外れとその理由、全体総括）をもとに、日本語で以下を生成してください。

- reflectionPoints: 本日の因果分析から得られる具体的な反省点を1〜3件（配列。「〜という材料だけでは信頼度を上げすぎない」のように具体的に）
- losingPatternNote: 過去の教訓（下記【過去の教訓】参照。無ければ本日のデータのみから）と照らして、繰り返し起きている負けパターンがあれば具体的に指摘する。繰り返しパターンが見られなければ「特に繰り返しパターンは見られない」のように明記する
- calibrationNotes: 次回以降のアナリスト(朝レポート生成AI)への引き継ぎメモ。confidencePctやexpectedMoveの見積もりをどう調整すべきかを1〜2文で具体的に。抽象論ではなく、次回のAIが読んで行動を変えられる具体性を持たせること

【過去の教訓】
$(if ($recentLessonsContext) { $recentLessonsContext } else { "(まだ蓄積なし)" })
"@

        $consultantSchema = @{
            type = "object"
            properties = @{
                reflectionPoints = @{ type = "array"; items = @{ type = "string" } }
                losingPatternNote = @{ type = "string" }
                calibrationNotes  = @{ type = "string" }
            }
            required = @("reflectionPoints", "losingPatternNote", "calibrationNotes")
            additionalProperties = $false
        }

        $consultantResult = Invoke-KabuAnthropicMessages -SystemPrompt $consultantSystemPrompt `
            -UserContent "本日の監査官による因果分析です:`n$auditItemsJson`n`n全体総括: $($auditResult.overallCausalSummary)" -Schema $consultantSchema
        if ($consultantResult) {
            Write-KabuLog "戦略コンサルタントによる反省点抽出成功"
        }
    } catch {
        Write-KabuLog "戦略コンサルタントによる反省点抽出失敗: $($_.Exception.Message)" -Level "WARN"
        $consultantResult = $null
    }
}

$verdictMap = @{}
if ($auditResult) {
    foreach ($v in $auditResult.items) { $verdictMap[$v.id] = $v }
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
        "<b style='color:$color;'>$($v.verdict)</b><br/><span style='font-size:12px;color:#555;'>$($v.causalAnalysis)</span>"
    } else { "-" }
    "<tr><td style='padding:4px 8px;'>$($r.SectionLabel)</td><td style='padding:4px 8px;'>$($r.Name)</td>" +
    "<td style='padding:4px 8px;font-size:13px;'>$predicted$confText</td>" +
    "<td style='padding:4px 8px;'>$($r.ActualOpen)</td><td style='padding:4px 8px;'>$($r.ActualHigh)</td><td style='padding:4px 8px;'>$($r.ActualLow)</td><td style='padding:4px 8px;'>$($r.ActualClose)</td>" +
    "<td style='padding:4px 8px;color:$(if($r.ActualChangePct -ge 0){"#c0392b"}else{"#2471a3"});'>$(Format-Pct $r.ActualChangePct)</td>" +
    "<td style='padding:4px 8px;'>$(Format-Pct $r.ActualRangePct)</td>" +
    "<td style='padding:4px 8px;'>$verdictHtml</td></tr>"
}

$auditHtml = if ($auditResult -and $auditResult.overallCausalSummary) {
    "<h3>監査官による本日の総括（因果分析）</h3><p>$($auditResult.overallCausalSummary)</p>"
} else {
    "<p style='color:#888;'>AI分析が利用できなかったため、総括はありません（予測 vs 実績の生データのみ表示）。</p>"
}

$consultantHtml = if ($consultantResult) {
    $reflectionHtml = if ($consultantResult.reflectionPoints -and $consultantResult.reflectionPoints.Count -gt 0) {
        "<ul>" + (($consultantResult.reflectionPoints | ForEach-Object { "<li>$_</li>" }) -join "") + "</ul>"
    } else { "<p style='color:#888;'>特になし</p>" }
    "<h3>戦略コンサルタントからの反省点</h3>$reflectionHtml" +
    "<p><b>負けパターンの傾向:</b> $($consultantResult.losingPatternNote)</p>"
} else { "" }

$jstNow = Get-KabuJstNow
$body = @"
<div style='font-family:sans-serif;'>
<h2>kabuzidou 結果検証(答え合わせ) $($jstNow.ToString("yyyy-MM-dd HH:mm"))</h2>
<p style='background:#fff3cd;padding:8px;border-radius:4px;font-size:13px;'>
本日朝レポート(アナリスト)で提示した予測と、大引け時点の実績を監査官が照合したものです。的中/外れの判定は統計的な精度指標ではなく、
今後の見積もり改善のための参考情報です。
</p>
$auditHtml
$consultantHtml
<h3>銘柄別 予測 vs 実績</h3>
<table style='border-collapse:collapse;font-size:14px;'>
<tr><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>区分</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>銘柄</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>朝の予測</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>始値</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>高値</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>安値</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>終値</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>前日比</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>値幅</th><th style='text-align:left;padding:4px 8px;border-bottom:1px solid #ccc;'>判定</th></tr>
$($rowsHtml -join "")
</table>
</div>
"@

Send-KabuMail -Subject "【株info】$($jstNow.ToString('yyyy-MM-dd')) 結果検証(答え合わせ)" -BodyHtml $body
Write-KabuLog "答え合わせメール送信完了: $($reviewItems.Count)件"

# --- 教訓の保存（次回以降のアナリストへの申し送り） ---
if ($consultantResult -and $consultantResult.calibrationNotes) {
    Add-KabuLesson -Lesson ([PSCustomObject]@{
        date              = $todayIso
        overallSummary    = $auditResult.overallCausalSummary
        reflectionPoints  = $consultantResult.reflectionPoints
        losingPatternNote = $consultantResult.losingPatternNote
        calibrationNotes  = $consultantResult.calibrationNotes
        itemCount         = $reviewItems.Count
    })
    Write-KabuLog "教訓をstate/lessons.jsonに保存"
}

Write-KabuLog "=== 夕方レポート(答え合わせ)生成完了 ==="
