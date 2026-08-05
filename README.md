# kabuzidou 株メール通知システム

毎朝、以下をメール（reon24520@gmail.com）に自動送信します。

- 本日上がりそうな銘柄 / 下がりそうな銘柄の候補（モメンタム・出来高から機械的に算出）
- 買い目候補（中期上昇トレンド中の押し目）
- 保有株が今日どう動きそうかの見立て
- 市場概況（日経平均・S&P500・ドル円の前日比）

さらに毎日17:13頃（東証の大引け後）に、その日の朝レポートの予測が実際どうだったかを答え合わせするメールを送ります。予測と実績の差分・AIによる的中度評価と全体総括を送信し、そこから得た教訓（見積もりの調整ポイント）を蓄積して、翌朝以降のレポート生成AIにフィードバックします（`state/lessons.json`）。

日中（8:30〜15:30、15分おき）に、相場急変につながりうるニュースや保有株の急な値動き（既定は±3%）を検知するアラート機能もあります。**現在は既定でオフになっています**（`config\settings.json` の `newsWatchAlertsEnabled`）。検知・状態保存自体は動き続けるため、`true` に戻せばそのまま再開できます。

**重要な注意点**: これは過去の値動き・出来高・ニュース見出しから機械的に作る参考情報であり、株価予測を保証するものではありません。投資判断は自己責任でお願いします。

## 仕組み

- データ取得: Yahoo Finance の非公式チャートAPI（APIキー不要、日本株は `7203.T` のような証券コード指定）
- ニュース: Google News RSS（キーワード検索、APIキー不要）
- 配信: Gmail の SMTP（アプリパスワード使用）
- 実行: GitHub Actions（`.github/workflows/`）。PCの電源に関係なく実行されるのが利点だが、
  `schedule`(cron)トリガーはベストエフォートで数時間単位の遅延が起きうるため使用していない。
  代わりに外部cronサービスからGitHub APIの `workflow_dispatch` を正確なJST時刻に呼び出す
  （詳細は下記「メール配信スケジュール」）。ローカルPCでの実行用に Windows タスクスケジューラ
  版（`Register-Tasks.ps1`）も用意してあるが、現在の主経路はGitHub Actions。
- 認証情報: GitHub Actions実行時はリポジトリのSecrets（`KABU_SMTP_USER`/`KABU_SMTP_PASS`/`ANTHROPIC_API_KEY`）。
  ローカル実行時はDPAPIで暗号化し `%LOCALAPPDATA%\kabuzidou\smtp_cred.xml` に保存（このPC・このWindowsアカウントでしか復号不可）

## 初回セットアップ（3ステップ）

### 1. Gmailのアプリパスワードを発行する

送信専用に使うGoogleアカウント（今使っているreon24520@gmail.comでも、別に用意した送信専用アカウントでもOK）で:

1. https://myaccount.google.com/security で「2段階認証」を有効にする
2. https://myaccount.google.com/apppasswords でアプリパスワード（16桁）を発行する

### 2. 認証情報を登録する

PowerShellを開いて:

```powershell
cd "C:\Users\reon2\OneDrive\デスクトップ\kabuzidou\scripts"
.\Setup-Credentials.ps1
```

送信元メールアドレスと、上で発行したアプリパスワード（Googleの通常ログインパスワードではない）を入力してください。

その後 `config\settings.json` の `fromAddress` を、入力した送信元メールアドレスに合わせて編集してください（`toAddresses` は既に reon24520@gmail.com になっています）。

### 3. 保有株を登録する

`config\portfolio.json` を編集し、実際に保有している銘柄を追加してください。

```json
{
  "holdings": [
    { "ticker": "7203.T", "name": "トヨタ自動車" },
    { "ticker": "6758.T", "name": "ソニーグループ" }
  ]
}
```

証券コードは「4桁のコード + `.T`」です（例: 任天堂なら `7974.T`）。

### 4. タスクスケジューラに登録する

```powershell
.\Register-Tasks.ps1
```

管理者権限を求められて失敗する場合は、PowerShellを「管理者として実行」してから再度実行してください。

## メール配信スケジュール（正確な時刻に届ける設定）

GitHub Actionsの`schedule`(cron)トリガーは公式に「ベストエフォート」とされており、実測でも
朝レポート・夕方レビューとも10時間以上遅延することが確認されています（2026-08-03/04）。
そのため`schedule`は使わず、外部の無料cronサービスから正確なJST時刻にGitHub APIを叩いて
ワークフローを起動する方式にしています。以下は [cron-job.org](https://cron-job.org) を使う手順です
（他の外部cron/監視サービスでも同じ要領で設定可能）。

### 1. GitHub Personal Access Token（PAT）を発行する

1. https://github.com/settings/personal-access-tokens/new を開く
2. Repository access → "Only select repositories" → `rhythme-sns/kabuzidou` を選択
3. Permissions → Repository permissions → **Actions: Read and write** に設定
4. Generate token → 表示されたトークン（`github_pat_...`）をコピーして保存
   （このトークンはワークフローを起動できる権限を持つ機密情報です。cron-job.org以外には貼らないでください）

### 2. cron-job.org に無料アカウント登録する

https://cron-job.org/en/signup/ でメールアドレス登録するだけでOK（無料枠で十分）。

### 3. 朝レポート用のジョブを作成する

「Create cronjob」から:

- **Title**: `kabuzidou-morning-report`
- **URL**: `https://api.github.com/repos/rhythme-sns/kabuzidou/actions/workflows/morning-report.yml/dispatches`
- **Request method**: `POST`
- **Common → Timezone**: `Asia/Tokyo`
- **Schedule**: 毎週 月〜金曜日、`08:00`
- **Advanced → Headers**（Key: Value形式で追加）:
  - `Authorization`: `Bearer <手順1で発行したトークン>`
  - `Accept`: `application/vnd.github+json`
  - `X-GitHub-Api-Version`: `2022-11-28`
  - `Content-Type`: `application/json`
- **Advanced → Request body**: `{"ref":"master"}`

### 4. 夕方レビュー用のジョブを作成する

同様にもう1つ作成:

- **Title**: `kabuzidou-evening-review`
- **URL**: `https://api.github.com/repos/rhythme-sns/kabuzidou/actions/workflows/evening-review.yml/dispatches`
- それ以外（Headers・body・Request method）は手順3と同じ
- **Schedule**: 毎週 月〜金曜日、`17:13`（Timezoneは`Asia/Tokyo`）

### 5. 動作確認

cron-job.orgの各ジョブ画面から「Test run」を実行し、GitHubリポジトリの Actions タブで
ワークフローが起動してメールが届くか確認してください。以後は登録した時刻ちょうどに
GitHub API経由で起動されるため、GitHub Actions自体の`schedule`遅延の影響を受けません。

## 動作確認

登録後、すぐに手動実行してメールが届くか確認できます。

```powershell
Start-ScheduledTask -TaskName "Kabuzidou-MorningReport"
Start-ScheduledTask -TaskName "Kabuzidou-NewsWatch"
```

数十秒〜数分待ってから届いているか確認してください。届かない場合は `logs\` フォルダ内のログを確認してください。

## カスタマイズ

- `config\watchlist.json` : スクリーニング対象の銘柄一覧（自由に追加・削除可）
- `config\portfolio.json` : 保有株一覧
- `config\news_keywords.json` : 急変とみなすニュースキーワード
- `config\settings.json` : SMTP設定、送信先メールアドレス、急変アラートの閾値（`alertThresholdPct`、既定3%）、`newsWatchAlertsEnabled`（日中アラートのメール送信有無、既定false）、`eveningReviewEnabled`（17:13答え合わせメールの有無、既定true）

## 制限事項

- PCがスリープ/シャットダウン中は実行されません（`Register-Tasks.ps1` で `-WakeToRun` を設定していますが、スリープからの復帰は機種依存で確実ではありません）。ノートPCなら朝の時間帯は電源ONまたは有線接続＋スリープ復帰設定を推奨します。
- Yahoo Finance の非公式APIを利用しているため、まれに取得失敗することがあります（その銘柄はスキップされログに記録されます）。
- 「上がりそう/下がりそう」は将来予測ではなく、過去の値動き・出来高の機械的な要約です。
