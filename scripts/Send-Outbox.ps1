# Send-Outbox.ps1
# state/outbox/pending.json を読み込み、SMTP経由でメール送信する「発送係」専用スクリプト。
# 分析(市況リサーチ・AI要約・HTML本文組み立て)は claude.ai/code/routines のクラウドエージェントが担当し、
# その結果を state/outbox/pending.json に {subject, bodyHtml} 形式で書き込んでリポジトリにpushする。
# このスクリプトはそのpushをトリガーに .github/workflows/send-outbox.yml から実行され、
# 中身をそのままメール送信するだけ(LLM呼び出し・ANTHROPIC_API_KEYは一切不要)。

. "$PSScriptRoot\Common.ps1"

Write-KabuLog "=== Outbox送信開始 ==="

$outboxPath = Join-Path $script:StateDir "outbox\pending.json"
if (-not (Test-Path $outboxPath)) {
    Write-KabuLog "state/outbox/pending.json が見つからないため送信スキップ"
    exit 0
}

$pending = Get-Content -Path $outboxPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $pending.subject -or -not $pending.bodyHtml) {
    Write-KabuLog "pending.jsonにsubject/bodyHtmlが無いため送信スキップ" -Level "WARN"
    exit 0
}

Send-KabuMail -Subject $pending.subject -BodyHtml $pending.bodyHtml
Write-KabuLog "Outbox送信完了 (type=$($pending.type)): $($pending.subject)"

Remove-Item -Path $outboxPath -Force
Write-KabuLog "=== Outbox送信終了 ==="
