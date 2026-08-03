# Setup-ClaudeApiKey.ps1
# ★これは必ずユーザー本人が手動でこのファイルを実行してください（Claude Codeからは実行できません）。
# Claude API（Anthropic）のAPIキーを対話入力し、DPAPIで暗号化して
#   %LOCALAPPDATA%\kabuzidou\anthropic_key.xml
# に保存します。ニュース要約・信頼度・買い目のおすすめ度の生成に使われます。
#
# 事前準備:
#   1. https://console.anthropic.com （claude.aiのログインとは別のAPI用アカウント）でサインアップ
#   2. クレジットカードを登録し、少額チャージ（$5程度から）
#   3. 「API Keys」からキーを発行（sk-ant-... の形式）
#
# 実行方法（PowerShellを開いて）:
#   cd "C:\Users\reon2\OneDrive\デスクトップ\kabuzidou\scripts"
#   .\Setup-ClaudeApiKey.ps1
#
# 目安コスト: このシステムの使い方（1日1回のバッチ処理、Haiku 4.5使用）なら月1ドル未満。

$credDir = Join-Path $env:LOCALAPPDATA "kabuzidou"
if (-not (Test-Path $credDir)) { New-Item -ItemType Directory -Path $credDir -Force | Out-Null }
$keyPath = Join-Path $credDir "anthropic_key.xml"

Write-Host "=== kabuzidou Claude APIキー設定 ===" -ForegroundColor Cyan
Write-Host "https://console.anthropic.com で発行したAPIキー（sk-ant-...）を入力してください。" -ForegroundColor Yellow
Write-Host ""

$secureKey = Read-Host "Anthropic APIキー" -AsSecureString
$secureKey | Export-Clixml -Path $keyPath

Write-Host ""
Write-Host "保存しました: $keyPath" -ForegroundColor Green
Write-Host "config\settings.json の enableAiInsights を true にすると、次回のレポートからAI要約が有効になります。" -ForegroundColor Yellow
