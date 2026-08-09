# Register-Tasks.ps1
# ★ローカルPCでの実行用（現在の主経路は claude.ai/code/routines + GitHub Actions、README.md参照）。
# ANTHROPIC_API_KEYを自前で持っていて、ローカルPCでも実行したい場合のオプション手段として残してある。
# ★ユーザー本人が手動で1回実行してください。
# Windowsタスクスケジューラに以下2つのタスクを登録します:
#   1. Kabuzidou-MorningReport   : 平日 朝8:00 に Get-MorningReport.ps1 を実行
#   2. Kabuzidou-EveningReview   : 平日 17:13 に Get-EveningReview.ps1 を実行（朝レポートの答え合わせ）
#
# 実行方法:
#   cd "C:\Users\reon2\OneDrive\デスクトップ\kabuzidou\scripts"
#   .\Register-Tasks.ps1
#
# 注意: PC がスリープ/シャットダウンしている時間帯はタスクは実行されません。
#       朝レポートを確実に受け取るには、その時間PCの電源が入っている（またはスリープからの復帰設定）必要があります。

$scriptsDir = $PSScriptRoot
$pwsh = (Get-Command powershell.exe).Source

function Register-KabuTask {
    param(
        [string]$TaskName,
        [string]$ScriptPath,
        [Microsoft.Management.Infrastructure.CimInstance[]]$Triggers
    )
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $Triggers -Settings $settings -Force -ErrorAction Stop | Out-Null
        Write-Host "登録成功: $TaskName" -ForegroundColor Green
    } catch {
        Write-Host "登録失敗: $TaskName -> $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "PowerShellを「管理者として実行」した上で再度お試しください。" -ForegroundColor Yellow
    }
}

# --- タスク1: 毎朝レポート（平日 8:00） ---
$morningTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At "08:00"
Register-KabuTask -TaskName "Kabuzidou-MorningReport" -ScriptPath (Join-Path $scriptsDir "Get-MorningReport.ps1") -Triggers $morningTrigger

# --- タスク2: 夕方の答え合わせ（平日 17:13、東証の大引け後） ---
$eveningTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At "17:13"
Register-KabuTask -TaskName "Kabuzidou-EveningReview" -ScriptPath (Join-Path $scriptsDir "Get-EveningReview.ps1") -Triggers $eveningTrigger

Write-Host ""
Write-Host "登録済みタスクの確認: タスクスケジューラ (taskschd.msc) の「タスク スケジューラ ライブラリ」を開いてください。" -ForegroundColor Cyan
Write-Host "手動でテスト実行するには:" -ForegroundColor Cyan
Write-Host "  Start-ScheduledTask -TaskName 'Kabuzidou-MorningReport'"
Write-Host "  Start-ScheduledTask -TaskName 'Kabuzidou-EveningReview'"
