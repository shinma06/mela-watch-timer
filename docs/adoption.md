# このプロジェクトへの導入

- 導入元: [shinma06/agent-harness-template](https://github.com/shinma06/agent-harness-template/tree/e822318a6c0fa7175a89687b929197dfae879184)
- 採用revision: `e822318a6c0fa7175a89687b929197dfae879184`（2026-09-30）。導入作業は [Issue #1](https://github.com/shinma06/mela-watch-timer/issues/1)。
- 既存CLAUDE.mdを正本にして共通契約を追記し、AGENTS.mdからsymlinkで参照。Swift言語モードと手動フェーズ開始の説明を実装に合わせて補正。
- scripts/tests/hooksと共通Skillsを採用。project.md、README、入口の説明、Xcode用ignoreをこのプロジェクトへ適合。
- upstream固有の調査台帳 `docs/inventory.md` は取り込まない。外部設定のexamplesとsetupガイドは参照用であり、個人設定へ自動適用しない。
- 導入前のcore.hooksPathは未設定、default hooksに有効なcustom hookはなし。bootstrapは共通Git設定に作用するため、mainにも導入が反映されたことを確認する。
- 更新は上記revisionとの差分を専用PRで確認する。戻す場合は導入変更をPRでrevertし、その時点のhooks所有者を確認したうえで、この導入だけによるcore.hooksPath設定を解除する。
- ユーザー承認でrepositoryをpublicへ変更。公開前に既存8 commit・21種類のblob・Issue #1を既知の秘密候補と個人絶対パスについて検査し、検出0。完全なsecret scannerの代替ではない。
- MCP・Plugins・認証・GUI・schedulerの再設定は行わない。実行・CI・独立レビューの結果と残条件は導入PRを正本にする。

# 別プロジェクトへの適用と更新

## 新規プロジェクト

1. GitHub Templateから作成・cloneし、初期ファイルを確認。
2. 実装言語/目的/コマンド/統合先/受入をproject.mdへ記入。元環境の製品名・model・SDK・Issue/Project IDは不要。
3. 小さなIssue専用branch/worktreeを作り、bootstrapとcheckを実行。
4. [クライアント](setup/clients.md)と必要な外部ツールだけ設定。
5. 最初のPRでCIと独立reviewの経路を確認し、[GitHub保護](setup/github.md)を設定。

Templateとして生成された初期commit以降の変更はPRへ通します。新規repositoryの初期化を、既存mainへの直接pushの許可に読み替えません。

## 既存プロジェクト

既存のIssue/branch/worktreeで差分を作成します。blind copy、`cp -r`での上書きやhook置換はしません。

| 移植するもの | 統合方法 |
| --- | --- |
| AGENTS/CLAUDE | 現在の正本を維持し、所有・検証・privacy等の不足を統合 |
| start/finish Skills | 同名既存Skillの契約と比較し、正本1つへ統合 |
| Cursor rule | 既存alwaysApplyとの重複を避け、共通正本への入口を追加 |
| docs | 既存workflow/architectureの正本へ接続。project.mdも既存文書を参照 |
| scripts/hooks | guard/check呼出しを既存hooksへ統合。既存テストを維持 |
| CI | 導入先のworkflowへharness-checks相当を追加。アプリのtest/buildは別途保持 |
| examples | 必要な項目だけ本人の設定へ適用。認証値を含めない |
| GUI lease | ホスト上の全利用者と共通namespaceを調整。旧active leaseを放置しない |
| registry | 新規登録から使用。旧owner/source/stateを自動移行しない |

`check.py`はGit追跡ファイルの限定構文・リンク・秘密候補・path検査とharnessテストです。導入先に相対リンクの特殊記法や別tool生成物がある場合は、意味を理解して検査範囲を適合させます。機密検査は既知パターンだけで、secret scannerの完全な代替ではありません。

## 更新・戻し方

templateの更新は導入先の専用PRで比較し、元の規約・required testsを保持して必要部分だけ取り込みます。固定のupstream同期scriptや自動上書きは同梱しません。

導入を取り消す場合も専用PRで戻し、core.hooksPathは変更前の値へ当該repositoryだけ戻します。既存custom hooksを削除せず、進行中claim・GUI lease・private registryの担当を確認します。設定と実行状態の削除を一括で行いません。

## 削除/置換した元環境依存

製品のMission/仕様/名称/保存ID、Kotlin/JDK/SDK固定、製品CLI/ACPイベント、GUI比較Case、過去Issue/PR番号、Project/ruleset ID、個人パス/host、個人の専門領域、固定model、過去の承認、認証値、private wire、履歴とcacheを汎用規約から除外しました。移植元の受入結果は導入先のpassへ引き継ぎません。
