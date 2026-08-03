# Common.ps1
# kabuzidou 共通関数モジュール。各スクリプトの先頭で ". $PSScriptRoot\Common.ps1" として読み込む。

$script:RootDir   = Split-Path -Parent $PSScriptRoot
$script:ConfigDir = Join-Path $RootDir "config"
$script:StateDir  = Join-Path $RootDir "state"
$script:LogDir    = Join-Path $RootDir "logs"
$script:CredPath  = Join-Path $env:LOCALAPPDATA "kabuzidou\smtp_cred.xml"
$script:AnthropicKeyPath = Join-Path $env:LOCALAPPDATA "kabuzidou\anthropic_key.xml"

function Write-KabuLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Source = "kabuzidou",
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
    )
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    $line = "{0} [{1}] [{2}] {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Source, $Message
    $logFile = Join-Path $script:LogDir ("{0}.log" -f (Get-Date -Format "yyyy-MM"))
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-KabuConfig {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $script:ConfigDir "$Name.json"
    if (-not (Test-Path $path)) { throw "設定ファイルが見つかりません: $path" }
    return Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-KabuSmtpCredential {
    # GitHub Actions等CI環境では KABU_SMTP_USER / KABU_SMTP_PASS 環境変数（Secrets経由）を優先する。
    # ローカルPCでは、Setup-Credentials.ps1 で保存した DPAPI 暗号化ファイルを読み込む。
    # DPAPI は「このWindowsユーザーアカウント かつ このPC」でしか復号できないため、
    # 平文でパスワードを保存するより安全（資格情報ファイルを他人にコピーされても復号不可）。
    if ($env:KABU_SMTP_USER -and $env:KABU_SMTP_PASS) {
        $securePass = ConvertTo-SecureString -String $env:KABU_SMTP_PASS -AsPlainText -Force
        return New-Object System.Management.Automation.PSCredential($env:KABU_SMTP_USER, $securePass)
    }
    if (-not (Test-Path $script:CredPath)) {
        throw "SMTP認証情報が未設定です。先に scripts\Setup-Credentials.ps1 を実行してください。"
    }
    return Import-Clixml -Path $script:CredPath
}

function Send-KabuMail {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$BodyHtml
    )
    $settings = Get-KabuConfig -Name "settings"
    $cred = Get-KabuSmtpCredential

    $smtp = New-Object System.Net.Mail.SmtpClient($settings.smtpServer, [int]$settings.smtpPort)
    $smtp.EnableSsl = $true
    $smtp.Credentials = New-Object System.Net.NetworkCredential($cred.UserName, $cred.Password)

    $mail = New-Object System.Net.Mail.MailMessage
    $mail.From = New-Object System.Net.Mail.MailAddress($settings.fromAddress, "kabuzidou")
    foreach ($to in $settings.toAddresses) { $mail.To.Add($to) }
    $mail.Subject = $Subject
    $mail.SubjectEncoding = [System.Text.Encoding]::UTF8
    $mail.Body = $BodyHtml
    $mail.BodyEncoding = [System.Text.Encoding]::UTF8
    $mail.IsBodyHtml = $true

    try {
        $smtp.Send($mail)
        Write-KabuLog "メール送信成功: $Subject"
    } catch {
        Write-KabuLog "メール送信失敗: $($_.Exception.Message)" -Level "ERROR"
        throw
    } finally {
        $mail.Dispose()
        $smtp.Dispose()
    }
}

function Get-YahooChart {
    # Yahoo Finance の非公式チャートAPI（APIキー不要）から日足/分足データを取得する。
    # 日本株は "7203.T" のように証券コード+.T で指定する。
    param(
        [Parameter(Mandatory)][string]$Ticker,
        [string]$Range = "1mo",
        [string]$Interval = "1d"
    )
    $uri = "https://query1.finance.yahoo.com/v8/finance/chart/{0}?range={1}&interval={2}" -f $Ticker, $Range, $Interval
    $headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" }
    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15
    } catch {
        Write-KabuLog "株価取得失敗 ($Ticker): $($_.Exception.Message)" -Level "WARN"
        return $null
    }
    $result = $resp.chart.result
    if (-not $result) { return $null }
    $r = $result[0]
    $quote = $r.indicators.quote[0]
    [PSCustomObject]@{
        Ticker         = $Ticker
        Name           = $r.meta.symbol
        Currency       = $r.meta.currency
        RegularPrice   = $r.meta.regularMarketPrice
        PreviousClose  = $r.meta.chartPreviousClose
        Timestamps     = $r.timestamp
        Close          = $quote.close
        Volume         = $quote.volume
        High           = $quote.high
        Low            = $quote.low
        Open           = $quote.open
    }
}

function Get-KabuNewsItems {
    # Google News RSS（APIキー不要）でキーワード検索する。Watch-News.ps1 と Get-MorningReport.ps1 で共用。
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$MaxItems = 5
    )
    $encoded = [Uri]::EscapeDataString($Query)
    $uri = "https://news.google.com/rss/search?q=$encoded&hl=ja&gl=JP&ceid=JP:ja"
    try {
        $resp = Invoke-RestMethod -Uri $uri -TimeoutSec 15
    } catch {
        Write-KabuLog "ニュース取得失敗 ($Query): $($_.Exception.Message)" -Level "WARN"
        return @()
    }
    # Invoke-RestMethod は RSS/Atom フィードを検出すると <item> 要素の配列を直接返すことがあるため、
    # 通常のXML構造 ($resp.rss.channel.item) とフラット配列の両方に対応する。
    $items = if ($resp -and ($resp | Get-Member -Name "rss" -ErrorAction SilentlyContinue)) {
        @($resp.rss.channel.item)
    } else {
        @($resp)
    }
    return $items | Where-Object { $_ -and $_.link } | Select-Object -First $MaxItems | ForEach-Object {
        [PSCustomObject]@{ Title = [string]$_.title; Link = [string]$_.link; PubDate = [string]$_.pubDate }
    }
}

function Get-KabuChartReasonText {
    # モメンタム指標(数値)から「なぜ上がりそう/下がりそうと判定したか」を日本語の短文にする。
    param([Parameter(Mandatory)]$Momentum)
    $clauses = New-Object System.Collections.Generic.List[string]

    if ($Momentum.ChangePct -ge 3)        { $clauses.Add("前日比+$($Momentum.ChangePct)%と急伸") }
    elseif ($Momentum.ChangePct -le -3)   { $clauses.Add("前日比$($Momentum.ChangePct)%と急落") }
    elseif ($Momentum.ChangePct -gt 0)    { $clauses.Add("前日比+$($Momentum.ChangePct)%") }
    elseif ($Momentum.ChangePct -lt 0)    { $clauses.Add("前日比$($Momentum.ChangePct)%") }

    if ($Momentum.TrendPct5d -ge 5)       { $clauses.Add("直近5日で+$($Momentum.TrendPct5d)%の上昇基調") }
    elseif ($Momentum.TrendPct5d -le -5)  { $clauses.Add("直近5日で$($Momentum.TrendPct5d)%の下落基調") }

    if ($Momentum.VolumeRatio -ge 2)      { $clauses.Add("出来高が平均の$($Momentum.VolumeRatio)倍に急増") }

    if ($clauses.Count -eq 0) { $clauses.Add("直近チャートに大きな変化なし") }
    return ($clauses -join "、") + "（チャートより）"
}

function Get-KabuNewsReasonText {
    # 関連ニュースの最新見出しを「根拠」の材料として1件取得する。見つからなければ$nullを返す。
    param([Parameter(Mandatory)][string]$Query)
    $items = Get-KabuNewsItems -Query $Query -MaxItems 1
    if ($items.Count -eq 0) { return $null }
    $item = $items[0]
    return [PSCustomObject]@{ Text = "「$($item.Title)」との報道"; Link = $item.Link }
}

function Get-KabuAnthropicApiKey {
    # GitHub Actions等CI環境では ANTHROPIC_API_KEY 環境変数（Secrets経由）を優先する。
    # ローカルPCでは、Setup-ClaudeApiKey.ps1 で保存した DPAPI 暗号化ファイルからAPIキーを復号して返す。
    if ($env:ANTHROPIC_API_KEY) {
        return $env:ANTHROPIC_API_KEY
    }
    if (-not (Test-Path $script:AnthropicKeyPath)) {
        throw "Claude APIキーが未設定です。先に scripts\Setup-ClaudeApiKey.ps1 を実行してください。"
    }
    $secure = Import-Clixml -Path $script:AnthropicKeyPath
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Get-KabuAIInsights {
    # 銘柄ごとの「チャート根拠＋ニュース見出し」をClaude APIに渡し、
    #   ・要約（ニュース内容の要約込み）
    #   ・変動幅の目安（例: +1〜3%程度）
    #   ・信頼度%（統計的な的中率ではなく、材料がどれだけ揃っているかの目安であることを明記）
    #   ・買い目候補のみ: おすすめ度(0-100)と具体的な買い目理由
    # をまとめて1回のAPI呼び出しで生成する（コストを抑えるためバッチ処理）。
    # 失敗しても例外をthrowし、呼び出し側でルールベースのみにフォールバックする。
    param([Parameter(Mandatory)][array]$Items)

    if ($Items.Count -eq 0) { return @{} }

    $settings = Get-KabuConfig -Name "settings"
    $model = if ($settings.anthropicModel) { $settings.anthropicModel } else { "claude-haiku-4-5" }
    $apiKey = Get-KabuAnthropicApiKey

    $itemsForPrompt = $Items | ForEach-Object {
        [PSCustomObject]@{
            id             = $_.id
            name           = $_.name
            context        = $_.context
            changePct      = $_.changePct
            trendPct5d     = $_.trendPct5d
            isBuyCandidate = [bool]$_.isBuyCandidate
        }
    }
    $itemsJson = $itemsForPrompt | ConvertTo-Json -Depth 5 -Compress

    $systemPrompt = @"
あなたは日本の個人投資家向けに、株価情報を分かりやすく要約するアシスタントです。
与えられた各銘柄の「チャートの動き」と「関連ニュース見出し」から、以下を日本語で生成してください。

- summary: ニュース内容を要約し、チャートの動きと合わせて「なぜそう見えるか」を1〜2文で説明。ニュースが無ければチャートのみから。
- expectedMove: 本日の値動きの大まかな目安（例: 「+1〜3%程度の上昇余地」「-2%前後の下落リスク」）。過去の値動き幅から導く参考値であり、断定はしないこと。
- confidencePct: 0〜100の整数。これは統計的な的中率ではなく、「材料（ニュース・出来高・トレンドの一致度）がどれだけ揃っているか」を示す目安。材料が薄い場合は30〜50、複数の材料が一致する場合でも70を超えることは稀とし、過信させる数値にしないこと。
- recommendationScore: isBuyCandidateがtrueの銘柄のみ0〜100の整数（それ以外は0でよい）。中期上昇トレンド中の押し目としての魅力度の目安。
- buyRationale: isBuyCandidateがtrueの銘柄のみ、具体的で分かりやすい買い目理由を1〜2文（それ以外は空文字でよい）。

投資助言ではなく参考情報の提示に徹し、誇張した表現は避けてください。
"@

    $schema = @{
        type = "object"
        properties = @{
            items = @{
                type = "array"
                items = @{
                    type = "object"
                    properties = @{
                        id                   = @{ type = "string" }
                        summary              = @{ type = "string" }
                        expectedMove         = @{ type = "string" }
                        confidencePct        = @{ type = "integer" }
                        recommendationScore  = @{ type = "integer" }
                        buyRationale         = @{ type = "string" }
                    }
                    required = @("id","summary","expectedMove","confidencePct","recommendationScore","buyRationale")
                    additionalProperties = $false
                }
            }
        }
        required = @("items")
        additionalProperties = $false
    }

    $bodyJson = @{
        model    = $model
        max_tokens = 4096
        system   = $systemPrompt
        messages = @(
            @{ role = "user"; content = "次の銘柄一覧について、指示された形式で分析してください:`n$itemsJson" }
        )
        output_config = @{
            format = @{
                type   = "json_schema"
                schema = $schema
            }
        }
    } | ConvertTo-Json -Depth 10

    # Windows PowerShell 5.1 の Invoke-RestMethod は、サーバーが Content-Type に charset を
    # 付けない場合（Anthropic APIはこれに該当）に日本語を文字化けさせるバグがある。
    # 送信は明示的にUTF-8バイト列化し、受信は生バイトを取得して自前でUTF-8デコードすることで回避する。
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)
    $headers = @{
        "x-api-key"         = $apiKey
        "anthropic-version" = "2023-06-01"
    }

    try {
        $webResp = Invoke-WebRequest -Uri "https://api.anthropic.com/v1/messages" -Method Post -Headers $headers `
            -Body $bodyBytes -ContentType "application/json; charset=utf-8" -TimeoutSec 60 -UseBasicParsing
    } catch {
        $detail = $_.Exception.Message
        if ($_.Exception.Response) {
            try {
                $errStream = $_.Exception.Response.GetResponseStream()
                $errBytes = New-Object System.IO.MemoryStream
                $errStream.CopyTo($errBytes)
                $detail = [System.Text.Encoding]::UTF8.GetString($errBytes.ToArray())
            } catch { }
        }
        throw "Claude API呼び出し失敗: $detail"
    }
    $rawBytes = $webResp.RawContentStream.ToArray()
    $resp = [System.Text.Encoding]::UTF8.GetString($rawBytes) | ConvertFrom-Json

    if ($resp.stop_reason -eq "refusal") {
        Write-KabuLog "Claude APIが応答を拒否しました（AI要約なしで続行）" -Level "WARN"
        return @{}
    }

    $textBlock = $resp.content | Where-Object { $_.type -eq "text" } | Select-Object -First 1
    if (-not $textBlock) { return @{} }
    $parsed = $textBlock.text | ConvertFrom-Json

    $result = @{}
    foreach ($item in $parsed.items) {
        $result[$item.id] = $item
    }
    return $result
}

function Get-KabuMomentum {
    # 直近の終値の推移から単純なモメンタム指標を計算する。
    # あくまで過去の値動きを要約した「参考情報」であり、将来の値動きを保証するものではない。
    param([Parameter(Mandatory)]$Chart)

    $closes = @($Chart.Close | Where-Object { $_ -ne $null })
    $volumes = @($Chart.Volume | Where-Object { $_ -ne $null })
    if ($closes.Count -lt 2) { return $null }

    $last      = $closes[-1]
    $prev      = $closes[-2]
    $changePct = if ($prev -ne 0) { [math]::Round((($last - $prev) / $prev) * 100, 2) } else { 0 }

    $lookback = [math]::Min(5, $closes.Count - 1)
    $base     = $closes[-($lookback + 1)]
    $trendPct = if ($base -ne 0) { [math]::Round((($last - $base) / $base) * 100, 2) } else { 0 }

    $avgVol = if ($volumes.Count -gt 1) { ($volumes[0..($volumes.Count - 2)] | Measure-Object -Average).Average } else { 0 }
    $lastVol = if ($volumes.Count -gt 0) { $volumes[-1] } else { 0 }
    $volRatio = if ($avgVol -gt 0) { [math]::Round($lastVol / $avgVol, 2) } else { 0 }

    [PSCustomObject]@{
        Ticker      = $Chart.Ticker
        LastClose   = $last
        ChangePct   = $changePct
        TrendPct5d  = $trendPct
        VolumeRatio = $volRatio
    }
}
