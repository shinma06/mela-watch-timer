# mela

残り時間を赤と青の広がりで感じる、Apple Watch専用の集中タイマーです。[minee 4](https://mineetimer.com/ja/products/minee-4)の体験を参照し、Watch全体の表示領域を使います。円の中心は画面中心で、主画面に数字・目盛り・ボタンを置きません。

画面をタップすると操作が開きます。集中は1〜120分、休憩は1〜60分に設定でき、初期値は25分／5分です。一時停止・再開に対応し、完了後の次の回は自分で開始します。完了した集中の回数と時間を、今日を含む7日分の記録で確認できます。

通知は最初に必要になったときに許可を求め、音と振動はWatchの設定に従います。通知を使わなくても計時できます。設定と記録はWatch内に保存し、通信・アカウント・iPhoneアプリは不要です。記録は設定から削除できます。アンインストールや別のWatchへの記録引継ぎは保証しません。

v1の実装・自動試験と、実機・利用体験の合格は別に管理しています。[Issue #8](https://github.com/shinma06/mela-watch-timer/issues/8)で最新の検証状況と未完了条件を確認してください。通知・触覚・Always Onの実動作はSimulatorだけでは確認できません。

- [プロダクト要件と画面仕様](docs/requirements.md)
- [タイマー・通知・保存の技術設計](docs/timer-design.md)
- [受入条件と実機確認の手順](docs/timer-acceptance.md)
- [構成・ビルド・テストの実行](docs/project.md)
- [開発フロー](docs/workflow.md)
- [ハーネスの導入元・更新・戻し方](docs/adoption.md)

Xcodeで `mela-watch-timer.xcodeproj` を開き、共有scheme `mela-watch-timer Watch App` とwatchOS 26.4以上の端末を選択します。アプリの表示名はmelaです。実機へのインストールには利用者の署名設定が必要です。TestFlight／App Storeへの配布は実施していません。

## 開発ハーネス

Python 3.11以上で、各cloneに対して次を実行します。既存のcustom hooksがある場合はbootstrapが停止するため、[hooksの説明](docs/operations.md)に従って統合してください。

```bash
python3 scripts/doctor.py
python3 scripts/check.py
python3 scripts/bootstrap.py
```

変更はIssue番号付きの専用branch/worktreeからPRへ進めます。共通チェックはアプリのbuildや実機試験の代替ではありません。
