# kabuzidou 株メール通知システム

毎朝、以下をメール（reon24520@gmail.com）に自動送信します。

- 本日上がりそうな銘柄 / 下がりそうな銘柄の候補（モメンタム・出来高から機械的に算出）
- 買い目候補（中期上昇トレンド中の押し目）
- 保有株が今日どう動きそうかの見立て
- 市場概況（日経平均・S&P500・ドル円の前日比）

さらに毎日17:13頃（東証の大引け後）に、その日の朝レポートの予測が実際どうだったかを答え合わせするメールを送ります。
週末には、これまでの答え合わせデータを俯瞰して勝ちパターン・負けパターン・取引基準をまとめる週次レポートも届きます。

**重要な注意点**: これは過去の値動き・出来高・ニュース見出しから機械的に作る参考情報であり、株価予測を保証するものではありません。投資判断は自己責任でお願いします。

## 4つの役割（エージェント）構成

分析の各段階を、それぞれ独立した役割（システムプロンプト）を持つAI呼び出しに分けています。実行主体は
[claude.ai/code/routines](https://claude.ai/code/routines) のスケジュール実行クラウドエージェント（Claude Pro契約内、追加のAPI従量課金なし）です。

1. **アナリスト**（`kabuzidou-morning-report` routine、毎朝8:00 JST）: 市場・ウォッチリスト・保有株をリサーチし、根拠付きの予測データを `state/predictions/日付.json` に保存。メール本文を `state/outbox/pending.json` に書き出してリポジトリにpush。
2. **監査官**（`kabuzidou-evening-review` routineの前半、毎日17:13 JST）: アナリストの予測と大引け後の実績を照合し、的中/外れの**因果関係**を厳格に分析。結果を `state/audits/日付.json` に保存（無期限蓄積）。
3. **戦略コンサルタント**（同routineの後半、監査官と同じセッション内で連続実行）: 監査官の因果分析から本日の反省点・繰り返しの負けパターンを抽出し、次回以降のアナリストへの申し送りとして `state/lessons.json` に蓄積。ここまでの結果は夕方の答え合わせメール1通にまとめてoutboxに書き出す。
4. **ストラテジスト**（`kabuzidou-weekly-strategy` routine、毎週末）: `state/audits/` と `state/lessons.json` の全期間データを俯瞰し、繰り返し現れる勝ちパターン・負けパターンを抽出して取引基準を作成（`state/strategy/日付.json` にも保存）。蓄積が `weeklyStrategyMinDays`（既定5日）分に満たない間は「データ蓄積中」の簡易メールのみ届きます。

## 仕組み（分析とメール送信を分離）

分析（LLM呼び出し）とメール送信（SMTP）を別の仕組みに分離することで、Claude Pro契約の範囲内・API従量課金なしで運用できるようにしています。

1. **分析**: [claude.ai/code/routines](https://claude.ai/code/routines) に登録された3つのクラウドエージェント（上記の役割）が、スケジュール通りに起動 → Yahoo Financeの非公式チャートAPI・TDnet適時開示情報（yanoshin氏の非公式JSON API）・Google News RSS（いずれもAPIキー不要）から情報収集 → Claude自身の推論でリサーチ・分析 → 結果を `state/` 配下のJSONとメール本文（`state/outbox/pending.json`）に書き込み、リポジトリ（`rhythme-sns/kabuzidou`、masterブランチ）にpushします。ここではAnthropic APIキーへの課金は発生しません（Claude Proの利用枠内）。
   - 個別銘柄の「根拠」は、まずTDnet適時開示（決算・業績予想修正・配当変更・業務提携などの一次情報）を確認し、直近に開示が無ければGoogle Newsの見出しにフォールバックします。どちらが根拠になったか（`disclosure`/`news`/材料なし`chart_only`）は `materialType` として予測・答え合わせデータに記録され、週次ストラテジストが「材料の種類ごとの的中傾向」を定量的に分析する材料になります。
   - 市場概況にはウォッチリストの中心であるAI/SaaS系グロース株の地合いに連動しやすいNasdaq総合指数(^IXIC)も含めています（日経平均・S&P500・ドル円に加えて）。
2. **メール送信**: `state/outbox/**` へのpushをトリガーに GitHub Actions（`.github/workflows/send-outbox.yml`）が起動し、`pending.json` の中身をそのままGmail SMTP（アプリパスワード使用）で送信するだけの「発送係」です。LLM呼び出しは一切行わないため `ANTHROPIC_API_KEY` は不要です。送信後はoutboxファイルを削除してコミットします。
3. **認証情報**: GitHub Actions実行時はリポジトリのSecrets（`KABU_SMTP_USER`/`KABU_SMTP_PASS`）のみで足ります。

### ローカル実行（オプションのフォールバック）

自前のAnthropic APIキーを持っていて、従来通りローカルPCやGitHub Actions上でPowerShellスクリプト（`Get-MorningReport.ps1`等）を直接実行し、Claude APIで分析させたい場合はそのまま使えます（`config\settings.json` の `enableAiInsights`/`anthropicModel`、ローカル実行用の `Register-Tasks.ps1`、GitHub Actions上の `ANTHROPIC_API_KEY` Secretsなどは温存してあります）。ただし主経路ではなく、これらのスクリプトはroutinesが読む「計算ロジックの仕様書」としての役割も兼ねています。

## 初回セットアップ（3ステップ）

### 1. Gmailのアプリパスワードを発行する

送信専用に使うGoogleアカウント（今使っているreon24520@gmail.comでも、別に用意した送信専用アカウントでもOK）で:

1. https://myaccount.google.com/security で「2段階認証」を有効にする
2. https://myaccount.google.com/apppasswords でアプリパスワード（16桁）を発行する

### 2. 認証情報をGitHub Actions Secretsに登録する

リポジトリの Settings → Secrets and variables → Actions で以下を登録してください（メール送信用の`send-outbox.yml`が使用します）。

- `KABU_SMTP_USER`: 送信元メールアドレス
- `KABU_SMTP_PASS`: 上で発行したアプリパスワード（Googleの通常ログインパスワードではない）

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

### 4. routinesの起動確認

[claude.ai/code/routines](https://claude.ai/code/routines) に登録済みの3つのルーティン（`kabuzidou-morning-report` / `kabuzidou-evening-review` / `kabuzidou-weekly-strategy`）が有効（Enabled）になっているか確認してください。編集・一時停止・手動実行はこのページから行えます。

## 動作確認

routinesの画面から対象のルーティンを選び「Run now」で手動実行できます。実行後、数分待って以下を確認してください。

- GitHubリポジトリの Actions タブに `Kabuzidou Send Outbox` の実行履歴があるか
- reon24520@gmail.com にメールが届いているか

届かない場合は、まずroutineの実行ログ（claude.ai側）で分析自体が失敗していないか、次にGitHub Actionsの `send-outbox` ジョブでSMTP送信エラーが出ていないか（`KABU_SMTP_USER`/`KABU_SMTP_PASS` Secretsの設定ミスが典型）の順に確認してください。

## カスタマイズ

- `config\watchlist.json` : スクリーニング対象の銘柄一覧（自由に追加・削除可）
- `config\portfolio.json` : 保有株一覧
- `config\settings.json` : SMTP設定、送信先メールアドレス、`eveningReviewEnabled`（17:13答え合わせメールの有無、既定true）、`weeklyStrategyEnabled`（週次ストラテジストレポートの有無、既定true）、`weeklyStrategyMinDays`（パターン抽出に必要な最低監査データ日数、既定5）。`enableAiInsights`/`anthropicModel` はローカル実行フォールバック専用。
- 各ルーティンのスケジュール・プロンプト自体を変更したい場合は [claude.ai/code/routines](https://claude.ai/code/routines) から編集してください。

## 制限事項

- Yahoo Finance・TDnet(yanoshin氏の非公式API)のいずれも非公式APIのため、まれに取得失敗することがあります（その銘柄はスキップ、またはニュースRSSへのフォールバックになります）。
- 「上がりそう/下がりそう」は将来予測ではなく、過去の値動き・出来高・ニュース見出しから機械的/AIが要約した参考情報です。
- routinesのスケジュール最短間隔は1時間のため、日中の急変ニュース監視（15分おき）機能は廃止しました。
