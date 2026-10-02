# プロジェクト情報

[プロダクト要件](requirements.md)、[技術設計](timer-design.md)、[受入条件](timer-acceptance.md)を仕様の正本とします。以下はv1の実装構成です。実機・利用体験の未確認を含む最新の結果は[Issue #8](https://github.com/shinma06/mela-watch-timer/issues/8)で管理します。

| 項目 | 現在の値 |
| --- | --- |
| 目的 | minee 4の体験をApple Watchで模倣。全画面の赤・青だけで残り時間を表す |
| 対象 | Watch-only、watchOS 26.4以上、SwiftUI、Observation、UserNotifications、WatchKit |
| 言語 | Swift 6モード（`SWIFT_VERSION = 6.0`）。検証環境はXcode 27.0 (27A266a)、Apple Swift 6.4 |
| 依存 | Apple SDKのみ。第三者パッケージ、ネットワーク、アカウントなし |
| モデル | Appが1つ所有する `@MainActor @Observable TimerModel` |
| 時間 | 同じプロセスではContinuousClock、再起動時は保存したDateの期限。描画はTimelineView |
| 保存 | Application Supportの `mela/state-v1.json` へCodableのsnapshotをatomic write |
| 通知 | 現在の1回だけ予約。sessionID/tokenで古い予約・結果・アクションを無効化 |
| 記録 | 自然完了した集中だけ1回保存。7日表示、14日保持、確認付き削除 |
| 統合先 | main。developは使用しない |
| ハーネス | Python 3.11以上の標準ライブラリ、Bash。macOS/Linux |
| 作業管理 | GitHub Issues / PR。1 Issue、1 writer、専用branch/worktree |
| CI | `harness-checks`（Ubuntu / Python 3.11）。アプリbuild/testはローカルのmacOS＋Xcode経路 |
| レビュー | writerとは別セッションで固定HEAD/baseを確認する |
| GitHub保護 | PR・harness-checks成功・会話解決が必要。直接push、force push、保護の迂回はしない |
| 認証・秘密 | 正規ログインとOSの資格情報保存。Git管理しない |

## sourceとテスト

| ファイル | 責務 |
| --- | --- |
| `mela_watch_timerApp.swift` | モデルと通知delegateの所有、通知カテゴリ |
| `TimerState.swift` | Codable/Sendableの状態、入力検証、状態遷移、時計、記録集計、幾何 |
| `TimerModel.swift` | 操作の直列化、保存後の状態確定、復元・期限照合・通知アクション |
| `TimerServices.swift` | StateStore actor、通知worker、OSアダプタ、触覚 |
| `ContentView.swift` | 全画面のShape、操作sheet、案内、設定、記録、VoiceOver |
| `TimerTests/` | Swift Testing。実モデル・worker・Shape・ファイル保存を対象にA01〜A20を検証 |

アプリsourceは `mela-watch-timer Watch App/`。Xcodeのfile-system synchronized groupです。共有scheme `mela-watch-timer Watch App` のTest actionに `TimerTests` を登録しています。旧PomodoroTimerと毎秒のTimerは使用しません。

## ビルドとテスト

Xcode 27のDeveloperディレクトリを `DEVELOPER_DIR` へ指定します。グローバルなxcode-selectを変更する必要はありません。Simulatorの起動・インストール・実行前には[GUI運用](operations.md)に従います。

```bash
: "${DEVELOPER_DIR:?使用するXcodeのDeveloperディレクトリを設定してください}"
xcodebuild -version
xcodebuild -showsdks
xcodebuild -list -project mela-watch-timer.xcodeproj

xcodebuild -project mela-watch-timer.xcodeproj \
  -scheme 'mela-watch-timer Watch App' -configuration Debug \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath .harness-local/DerivedData CODE_SIGNING_ALLOWED=NO build

xcodebuild -project mela-watch-timer.xcodeproj \
  -scheme 'mela-watch-timer Watch App' -configuration Release \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath .harness-local/DerivedData CODE_SIGNING_ALLOWED=NO build

: "${MELA_WATCH_SIMULATOR_ID:?試験対象のwatchOS Simulator IDを指定してください}"
: "${MELA_RUN_ID:?未使用の結果名を指定してください}"
xcodebuild -project mela-watch-timer.xcodeproj \
  -scheme 'mela-watch-timer Watch App' -configuration Debug \
  -destination "platform=watchOS Simulator,id=${MELA_WATCH_SIMULATOR_ID}" \
  -parallel-testing-enabled NO \
  -derivedDataPath .harness-local/DerivedData \
  -resultBundlePath ".harness-local/TestResults-${MELA_RUN_ID}.xcresult" \
  CODE_SIGNING_ALLOWED=NO test
```

26.4と27.xの両方でtestを行います。`build-for-testing`はコンパイルの確認であり、testの実行成功ではありません。実機向けの署名なしコンパイルはRelease buildのdestinationを `generic/platform=watchOS` にして確認できます。インストール・通知・触覚の確認は別に必要です。

ハーネスや文書の変更では新規ファイルをstage後に実行します。

```bash
python3 scripts/check.py
python3 scripts/doctor.py
```

## 完了と実機確認

- A01〜A20、Debug/Release build、独立レビュー、現行CIと会話解決を確認してPRを統合します。
- [M01〜M15](timer-acceptance.md#画面と実機の試験)の端末条件、VoiceOver・Dynamic Type、通知・触覚、AOD、電力、利用体験の結果を別に残します。
- 実機を使えない条件はblocked、未実施はpending、不具合はfail。Simulatorの成功を実機のpassにはしません。
- アプリ表示名はmela、version 1.0 / build 1、既存bundle IDと署名設定を維持しています。アイコンは実装した2色の図形から作成したオリジナル素材です。
- 署名・配布先・価格・Apple側の手続きは実装・PR統合と別に扱います。
