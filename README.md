# mela-watch-timer

Apple Watch用のポモドーロタイマー。25分の集中と5分の休憩を切り替えます。

- [仕様・開発上の注意](CLAUDE.md)
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
