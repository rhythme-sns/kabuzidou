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
- 実行: Windows タスクスケジューラ（PCの電源が入っている必要があります）
- 認証情報: DPAPIで暗号化し `%LOCALAPPDATA%\kabuzidou\smtp_cred.xml` に保存（このPC・このWindowsアカウントでしか復号不可）

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
