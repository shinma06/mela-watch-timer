# プロジェクト情報

仕様と開発上の注意の正本は [CLAUDE.md](../CLAUDE.md) です。AGENTS.mdはそのsymlinkで、同じ共通契約を読み込みます。

| 項目 | 現在の値 |
| --- | --- |
| 目的 | minee 4の体験をApple Watchで模倣する。[目的・参照製品の正本](../CLAUDE.md#目的と参照製品) |
| 対象 | watchOS 26.4以上、SwiftUI、Observation、UserNotifications、WatchKit |
| Swift | `project.pbxproj`の言語モードは5.0。Swift compilerの版と混同しない |
| source | `mela-watch-timer Watch App/`。Xcodeのfile-system synchronized group |
| アーキテクチャ | MainActorのObservableモデルとSwiftUI View。Android/MVVMは前提にしない |
| 統合先 | main。developは使用しない |
| ハーネス | Python 3.11以上の標準ライブラリ、Bash。macOS/Linux |
| 作業管理 | GitHub Issues / PR。必要が生じるまでProject/Milestoneは設けない |
| CI | `harness-checks`（Ubuntu / Python 3.11）。アプリbuildは含まない |
| レビュー | writerとは別セッションで固定HEAD/baseを確認する |
| GitHub保護 | ユーザー承認でpublicへ変更。mainはPR・harness-checks成功・会話解決を必須とし、force pushと削除を禁止する方針。実適用の確認結果は導入PRに記録 |
| 認証・秘密 | 正規ログインとOSの資格情報保存。Git管理しない |

## 検証コマンド

ハーネス変更では新規ファイルをstage後に実行します。

```bash
python3 scripts/check.py
python3 scripts/doctor.py
```

アプリ変更ではwatchOS 26.4以上に対応するSDKを持つXcodeを使用します。`xcode-select -p`がCommandLineToolsを指す場合、使用するXcodeのDeveloperディレクトリを`DEVELOPER_DIR`でコマンドに指定します。グローバルな選択を無断変更しません。

```bash
xcodebuild -list -project mela-watch-timer.xcodeproj
xcodebuild -project mela-watch-timer.xcodeproj \
  -scheme 'mela-watch-timer Watch App' \
  -configuration Debug \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath .harness-local/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

アプリのtest targetはまだありません。`xcodebuild test`成功を主張せず、buildと対象変更の手動確認を記録します。ハーネスのみの変更ではアプリsource/project差分がないことを確認し、アプリbuildの要否を判断します。

## 完了と実機確認

- 共通check、変更に必要なbuild、独立レビュー、CIが成功したPRをmainへ統合する。
- タイマーやUIを変更した場合は開始・一時停止・再開・スキップ・完了・画面復帰を確認する。通知許可の拒否も対象にする。
- 通知と触覚フィードバックの実動作は実機で確認する。Simulatorのbuild成功を実機確認として扱わない。
- 今回の導入はアプリの挙動・UIを変更しないためGUI試験は対象外。配布・署名・リリース自動化も追加しない。
