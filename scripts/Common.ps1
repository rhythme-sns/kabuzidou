# Common.ps1
# kabuzidou 共通関数モジュール。各スクリプトの先頭で ". $PSScriptRoot\Common.ps1" として読み込む。

$script:RootDir   = Split-Path -Parent $PSScriptRoot
$script:ConfigDir = Join-Path $RootDir "config"
$script:StateDir  = Join-Path $RootDir "state"
$script:LogDir    = Join-Path $RootDir "logs"
$script:CredPath  = Join-Path $env:LOCALAPPDATA "kabuzidou\smtp_cred.xml"
$script:AnthropicKeyPath = Join-Path $env:LOCALAPPDATA "kabuzidou\anthropic_key.xml"

function Get-KabuJstNow {
    # GitHub Actions等CI環境のランナーは常にUTCで動作するため、Get-Date（ローカル時刻）を
    # そのまま使うとローカルPC(JST)実行時とCI実行時でレポート日付・アラート時刻が9時間ズレる。
    # UTC基準からJST(UTC+9)へ明示的に変換することで、実行環境によらず時刻表示を一致させる。
    return [DateTime]::UtcNow.AddHours(9)
}

function Write-KabuLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Source = "kabuzidou",
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
    )
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    $jstNow = Get-KabuJstNow
    $line = "{0} [{1}] [{2}] {3}" -f ($jstNow.ToString("yyyy-MM-dd HH:mm:ss")), $Level, $Source, $Message
    $logFile = Join-Path $script:LogDir ("{0}.log" -f ($jstNow.ToString("yyyy-MM")))
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

function New-KabuAIItem {
    # 朝レポート/急変アラートで共用するAI問い合わせアイテムのファクトリ。
    # idはItemsリスト内で一意であればよいため、追加前のCountをそのまま採番に使う。
    param(
        # Mandatory + コレクション型の組み合わせだと、PowerShellは中身が空のリストを渡しただけで
        # 「空のコレクションはバインドできない」というエラーを投げる（要素0件の状態でも$Items自体はnullではないのに）。
        # このリストは呼び出し側で1件目を追加する時点では必ず空なので、AllowEmptyCollectionが必須。
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Items,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context,
        [double]$ChangePct = 0,
        [double]$TrendPct5d = 0,
        [Nullable[double]]$RangePct = $null,
        [bool]$IsBuyCandidate = $false
    )
    $id = "item$($Items.Count + 1)"
    $Items.Add([PSCustomObject]@{
        id = $id; name = $Name; context = $Context
        changePct = $ChangePct; trendPct5d = $TrendPct5d; rangePct = $RangePct; isBuyCandidate = $IsBuyCandidate
    })
    return $id
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

    if ($null -ne $Momentum.RangePct) {
        $clauses.Add("本日の値幅は高値$($Momentum.LastHigh)・安値$($Momentum.LastLow)(値幅$($Momentum.RangePct)%)")
        if ($Momentum.LastHigh -ne $Momentum.LastLow -and $null -ne $Momentum.LastClose) {
            $closePos = ($Momentum.LastClose - $Momentum.LastLow) / ($Momentum.LastHigh - $Momentum.LastLow)
            if ($closePos -ge 0.8)    { $clauses.Add("高値圏で引けており強含み") }
            elseif ($closePos -le 0.2) { $clauses.Add("安値圏で引けており弱含み") }
        }
    }

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

function Get-KabuTdnetDisclosures {
    # TDnet(適時開示情報閲覧サービス)を、yanoshin氏の非公式JSON API(APIキー不要)経由で企業コード別に取得する。
    # 決算・業績予想修正・配当変更・業務提携などの一次情報で、Google Newsの記事化を待つと後追いになりがちな
    # 「材料」の取りこぼしを補うために使う（監査官の分析で繰り返し指摘されていた検知漏れへの対処）。
    param(
        [Parameter(Mandatory)][string]$Ticker,
        [int]$MaxItems = 3,
        [int]$LookbackDays = 2
    )
    $code = $Ticker -replace '\.T$', ''
    if ($code -notmatch '^[0-9A-Za-z]{4}$') { return @() }
    $uri = "https://webapi.yanoshin.jp/webapi/tdnet/list/$code.json?limit=$MaxItems"
    try {
        $resp = Invoke-RestMethod -Uri $uri -TimeoutSec 15
    } catch {
        Write-KabuLog "適時開示取得失敗 ($Ticker): $($_.Exception.Message)" -Level "WARN"
        return @()
    }
    $cutoff = (Get-KabuJstNow).AddDays(-$LookbackDays)
    return @($resp.items) | Where-Object { $_ -and $_.Tdnet } | ForEach-Object { $_.Tdnet } |
        Where-Object { $_.pubdate -and ([DateTime]$_.pubdate) -ge $cutoff } |
        Select-Object -First $MaxItems |
        ForEach-Object { [PSCustomObject]@{ Title = [string]$_.title; Link = [string]$_.document_url; PubDate = [string]$_.pubdate } }
}

function Get-KabuDisclosureReasonText {
    # 直近(既定2日以内)のTDnet適時開示のうち最新1件を「根拠」の材料として取得する。無ければ$nullを返す。
    param([Parameter(Mandatory)][string]$Ticker)
    $items = Get-KabuTdnetDisclosures -Ticker $Ticker -MaxItems 1
    if ($items.Count -eq 0) { return $null }
    $item = $items[0]
    return [PSCustomObject]@{ Text = "適時開示「$($item.Title)」"; Link = $item.Link }
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

function Invoke-KabuAnthropicMessages {
    # Claude API (Messages API, json_schema出力) への呼び出しを行う共通関数。
    # Get-KabuAIInsights と Get-KabuEveningReview で共用する。
    # 失敗時は例外をthrowする（呼び出し側でルールベースへのフォールバックを判断させるため）。
    param(
        [Parameter(Mandatory)][string]$SystemPrompt,
        [Parameter(Mandatory)][string]$UserContent,
        [Parameter(Mandatory)][hashtable]$Schema,
        [int]$MaxTokens = 4096
    )

    $settings = Get-KabuConfig -Name "settings"
    $model = if ($settings.anthropicModel) { $settings.anthropicModel } else { "claude-haiku-4-5" }
    $apiKey = Get-KabuAnthropicApiKey

    $bodyJson = @{
        model    = $model
        max_tokens = $MaxTokens
        system   = $SystemPrompt
        messages = @(
            @{ role = "user"; content = $UserContent }
        )
        output_config = @{
            format = @{
                type   = "json_schema"
                schema = $Schema
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
        Write-KabuLog "Claude APIが応答を拒否しました" -Level "WARN"
        return $null
    }

    $textBlock = $resp.content | Where-Object { $_.type -eq "text" } | Select-Object -First 1
    if (-not $textBlock) { return $null }
    return $textBlock.text | ConvertFrom-Json
}

function Get-KabuAIInsights {
    # 銘柄ごとの「チャート根拠＋ニュース見出し」をClaude APIに渡し、
    #   ・要約（ニュース内容の要約込み）
    #   ・変動幅の目安（例: +1〜3%程度）
    #   ・信頼度%（統計的な的中率ではなく、材料がどれだけ揃っているかの目安であることを明記）
    #   ・買い目候補のみ: おすすめ度(0-100)と具体的な買い目理由
    # をまとめて1回のAPI呼び出しで生成する（コストを抑えるためバッチ処理）。
    # 失敗しても例外をthrowし、呼び出し側でルールベースのみにフォールバックする。
    param(
        [Parameter(Mandatory)][array]$Items,
        [string]$LessonsContext = ""
    )

    if ($Items.Count -eq 0) { return @{} }

    $itemsForPrompt = $Items | ForEach-Object {
        [PSCustomObject]@{
            id             = $_.id
            name           = $_.name
            context        = $_.context
            changePct      = $_.changePct
            trendPct5d     = $_.trendPct5d
            rangePct       = $_.rangePct
            isBuyCandidate = [bool]$_.isBuyCandidate
        }
    }
    $itemsJson = $itemsForPrompt | ConvertTo-Json -Depth 5 -Compress

    $lessonsBlock = if ($LessonsContext) {
        "`n`n【過去の的中率検証から得られた注意点（直近の答え合わせ結果より）】`n$LessonsContext`nこれらの傾向を踏まえて、confidencePctやexpectedMoveの見積もりを必要に応じて調整してください。"
    } else { "" }

    $systemPrompt = @"
あなたは日本の個人投資家向けに、株価情報を分かりやすく要約するアシスタントです。
与えられた各銘柄の「チャートの動き（前日比changePct、5日トレンドtrendPct5d、当日の値幅rangePct＝高値と安値の差を終値比%にしたもの）」と
「関連ニュース見出し」から、以下を日本語で生成してください。
rangePctが大きい銘柄は値動きが荒く、目安レンジも広めに・信頼度も控えめにするなど、値幅の大小も見積もりに反映してください。

- summary: ニュース内容を要約し、チャートの動き（値幅の大きさも含めて）と合わせて「なぜそう見えるか」を1〜2文で説明。ニュースが無ければチャートのみから。
- expectedMove: 本日の値動きの大まかな目安（例: 「+1〜3%程度の上昇余地」「-2%前後の下落リスク」）。過去の値動き幅（rangePct）から導く参考値であり、断定はしないこと。
- confidencePct: 0〜100の整数。これは統計的な的中率ではなく、「材料（ニュース・出来高・トレンドの一致度）がどれだけ揃っているか」を示す目安。材料が薄い場合は30〜50、複数の材料が一致する場合でも70を超えることは稀とし、過信させる数値にしないこと。
- recommendationScore: isBuyCandidateがtrueの銘柄のみ0〜100の整数（それ以外は0でよい）。中期上昇トレンド中の押し目としての魅力度の目安。
- buyRationale: isBuyCandidateがtrueの銘柄のみ、具体的で分かりやすい買い目理由を1〜2文（それ以外は空文字でよい）。

投資助言ではなく参考情報の提示に徹し、誇張した表現は避けてください。$lessonsBlock
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

    $parsed = Invoke-KabuAnthropicMessages -SystemPrompt $systemPrompt `
        -UserContent "次の銘柄一覧について、指示された形式で分析してください:`n$itemsJson" -Schema $schema
    if (-not $parsed) { return @{} }

    $result = @{}
    foreach ($item in $parsed.items) {
        $result[$item.id] = $item
    }
    return $result
}

function Save-KabuPredictionSnapshot {
    # 朝レポートで提示した予測（候補銘柄・AIの変動目安/信頼度・保有株の見立て）を
    # 日付単位でstate配下に保存する。夕方の答え合わせ(Get-EveningReview.ps1)で参照する。
    param(
        [Parameter(Mandatory)][array]$Items,
        [Parameter(Mandatory)][string]$Date
    )
    $dir = Join-Path $script:StateDir "predictions"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir "$Date.json"
    [PSCustomObject]@{ date = $Date; items = $Items } | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding UTF8
}

function Get-KabuPredictionSnapshot {
    # 指定日の朝レポート予測スナップショットを読み込む。存在しなければ$nullを返す。
    param([Parameter(Mandatory)][string]$Date)
    $path = Join-Path $script:StateDir "predictions\$Date.json"
    if (-not (Test-Path $path)) { return $null }
    return Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-KabuAudit {
    # 監査官(Get-EveningReview.ps1)が生成した「予測vs実績の因果分析」を日付単位でstate配下に保存する。
    # predictionsとは異なりプルーニングしない（ストラテジストが全期間のデータを俯瞰するための蓄積用）。
    param(
        [Parameter(Mandatory)]$Audit,
        [Parameter(Mandatory)][string]$Date
    )
    $dir = Join-Path $script:StateDir "audits"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir "$Date.json"
    $Audit | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
}

function Get-KabuAudit {
    # 指定日の監査官の因果分析結果を読み込む。存在しなければ$nullを返す。
    param([Parameter(Mandatory)][string]$Date)
    $path = Join-Path $script:StateDir "audits\$Date.json"
    if (-not (Test-Path $path)) { return $null }
    return Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-KabuAuditHistory {
    # 蓄積された監査官の因果分析結果を全件、日付昇順で読み込む。ストラテジストの入力データ。
    $dir = Join-Path $script:StateDir "audits"
    if (-not (Test-Path $dir)) { return @() }
    $files = Get-ChildItem -Path $dir -Filter "*.json" | Sort-Object -Property Name
    return @($files | ForEach-Object { Get-Content -Path $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json })
}

function Save-KabuStrategy {
    # ストラテジスト(Get-WeeklyStrategy.ps1)が生成した取引基準を日付単位でstate配下に保存する。
    # 過去分もプルーニングせず残す（基準がどう変遷したかの記録として）。
    param(
        [Parameter(Mandatory)]$Strategy,
        [Parameter(Mandatory)][string]$Date
    )
    $dir = Join-Path $script:StateDir "strategy"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir "$Date.json"
    $Strategy | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
}

function Get-KabuLessons {
    # 過去の答え合わせ分析（教訓）の履歴を読み込む。存在しなければ空配列を返す。
    $path = Join-Path $script:StateDir "lessons.json"
    if (-not (Test-Path $path)) { return @() }
    $data = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($data)
}

function Add-KabuLesson {
    # 答え合わせ分析（教訓）を1件追記し、直近$KeepLast件のみ保持する（無限に肥大化させないため）。
    # ストラテジスト(Get-WeeklyStrategy.ps1)が長期の勝敗パターンを抽出する材料にもなるため、
    # 朝レポートのプロンプトに使う直近数件だけでなく、ある程度長期間分（目安1年強の営業日数）保持する。
    param(
        [Parameter(Mandatory)]$Lesson,
        [int]$KeepLast = 300
    )
    $path = Join-Path $script:StateDir "lessons.json"
    $existing = Get-KabuLessons
    $updated = @($existing) + @($Lesson)
    if ($updated.Count -gt $KeepLast) {
        $updated = $updated[($updated.Count - $KeepLast)..($updated.Count - 1)]
    }
    $updated | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding UTF8
}

function Get-KabuLessonsContext {
    # 直近の教訓をAIプロンプトに埋め込みやすいテキストブロックに整形する。
    param([int]$MaxLessons = 5)
    $lessons = Get-KabuLessons
    if ($lessons.Count -eq 0) { return "" }
    $recent = $lessons | Select-Object -Last $MaxLessons
    $lines = foreach ($l in $recent) {
        "- $($l.date): $($l.calibrationNotes)"
    }
    return ($lines -join "`n")
}

function Get-KabuMomentum {
    # 直近の終値の推移から単純なモメンタム指標を計算する。
    # あくまで過去の値動きを要約した「参考情報」であり、将来の値動きを保証するものではない。
    param([Parameter(Mandatory)]$Chart)

    $closesRaw = @($Chart.Close)
    $opensRaw  = @($Chart.Open)
    $highsRaw  = @($Chart.High)
    $lowsRaw   = @($Chart.Low)
    $volumes   = @($Chart.Volume | Where-Object { $_ -ne $null })

    # Open/High/Lowは終値と同じインデックス（同じ日）で揃える必要があるため、
    # 終値がnullでない日のインデックスを基準に4系列をまとめて抽出する。
    $validIdx = @(0..($closesRaw.Count - 1) | Where-Object { $null -ne $closesRaw[$_] })
    if ($validIdx.Count -lt 2) { return $null }

    $closes = @($validIdx | ForEach-Object { $closesRaw[$_] })
    $opens  = @($validIdx | ForEach-Object { $opensRaw[$_] })
    $highs  = @($validIdx | ForEach-Object { $highsRaw[$_] })
    $lows   = @($validIdx | ForEach-Object { $lowsRaw[$_] })

    $last      = $closes[-1]
    $prev      = $closes[-2]
    $changePct = if ($prev -ne 0) { [math]::Round((($last - $prev) / $prev) * 100, 2) } else { 0 }

    $lookback = [math]::Min(5, $closes.Count - 1)
    $base     = $closes[-($lookback + 1)]
    $trendPct = if ($base -ne 0) { [math]::Round((($last - $base) / $base) * 100, 2) } else { 0 }

    $avgVol = if ($volumes.Count -gt 1) { ($volumes[0..($volumes.Count - 2)] | Measure-Object -Average).Average } else { 0 }
    $lastVol = if ($volumes.Count -gt 0) { $volumes[-1] } else { 0 }
    $volRatio = if ($avgVol -gt 0) { [math]::Round($lastVol / $avgVol, 2) } else { 0 }

    $lastOpen = $opens[-1]
    $lastHigh = $highs[-1]
    $lastLow  = $lows[-1]
    $rangeAbs = if ($null -ne $lastHigh -and $null -ne $lastLow) { [math]::Round($lastHigh - $lastLow, 2) } else { $null }
    $rangePct = if ($null -ne $rangeAbs -and $last -ne 0) { [math]::Round(($rangeAbs / $last) * 100, 2) } else { $null }

    [PSCustomObject]@{
        Ticker      = $Chart.Ticker
        LastOpen    = $lastOpen
        LastHigh    = $lastHigh
        LastLow     = $lastLow
        LastClose   = $last
        ChangePct   = $changePct
        TrendPct5d  = $trendPct
        VolumeRatio = $volRatio
        RangeAbs    = $rangeAbs
        RangePct    = $rangePct
    }
}
