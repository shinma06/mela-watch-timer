# mela-watch-timer

[minee 4](https://mineetimer.com/ja/products/minee-4)の体験をApple Watchで模倣するプロジェクトです。現在は25分の集中と5分の休憩を切り替えるタイマーを実装しています。全画面を赤と青だけで表す新しいタイマーへ再構築する仕様を定義しています。新仕様は未実装です。

- [再構築のプロダクト要件と画面仕様](docs/requirements.md)
- [タイマー・通知・保存の技術設計](docs/timer-design.md)
- [受入条件と実装順序](docs/timer-acceptance.md)
- [現行実装・目的・開発上の注意](CLAUDE.md)
- [構成・ビルド・検証](docs/project.md)
- [開発フロー](docs/workflow.md)
- [ハーネスの導入元・更新・戻し方](docs/adoption.md)

Xcodeで `mela-watch-timer.xcodeproj` を開き、Apple Watch実機またはwatchOS Simulatorを選択して実行します。

## 開発ハーネス

Python 3.11以上で、各cloneに対して次を実行します。既存のcustom hooksがある場合はbootstrapが停止するため、[hooksの説明](docs/operations.md)に従って統合してください。

```bash
python3 scripts/doctor.py
python3 scripts/check.py
python3 scripts/bootstrap.py
```

変更はIssue番号付きの専用branch/worktreeからPRへ進めます。共通チェックはアプリのbuildや実機試験の代替ではありません。
