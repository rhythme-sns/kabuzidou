# Setup-Credentials.ps1
# ★これは必ずユーザー本人が手動でこのファイルを実行してください（Claude Codeからは実行できません）。
# 送信用メールアカウントのアプリパスワードを対話入力し、DPAPIで暗号化して
#   %LOCALAPPDATA%\kabuzidou\smtp_cred.xml
# に保存します。DPAPI暗号化は「このWindowsアカウント + このPC」の組み合わせでしか復号できないため、
# 平文で保存するより安全です（このファイルをコピーして他のPCに持って行っても使えません）。
#
# 実行方法（PowerShellを開いて）:
#   cd "C:\Users\reon2\OneDrive\デスクトップ\kabuzidou\scripts"
#   .\Setup-Credentials.ps1
#
# Gmailを使う場合は、事前に以下が必要です:
#   1. Googleアカウントで2段階認証を有効にする
#   2. https://myaccount.google.com/apppasswords でアプリパスワード(16桁)を発行する
#      ※ 通常のGoogleログインパスワードではなく、このアプリパスワードを使います

$credDir = Join-Path $env:LOCALAPPDATA "kabuzidou"
if (-not (Test-Path $credDir)) { New-Item -ItemType Directory -Path $credDir -Force | Out-Null }
$credPath = Join-Path $credDir "smtp_cred.xml"

Write-Host "=== kabuzidou 送信用メールアカウント設定 ===" -ForegroundColor Cyan
Write-Host "Gmailの場合、パスワードは「アプリパスワード」(16桁)を入力してください。通常ログイン用パスワードは使えません。" -ForegroundColor Yellow
Write-Host ""

$userName = Read-Host "送信元メールアドレス (例: yourname@gmail.com)"
$securePassword = Read-Host "アプリパスワード" -AsSecureString

$cred = New-Object System.Management.Automation.PSCredential($userName, $securePassword)
$cred | Export-Clixml -Path $credPath

Write-Host ""
Write-Host "保存しました: $credPath" -ForegroundColor Green
Write-Host "config\settings.json の fromAddress もこのメールアドレスに合わせて編集してください。" -ForegroundColor Yellow
