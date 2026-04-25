# mela-watch-timer

Apple Watch 専用のシンプルなポモドーロタイマー。

## 概要

25分の集中セッションと5分の休憩セッションをループするポモドーロタイマー。
バックグラウンド中はローカル通知でタイマー完了を通知する。

## 技術スタック

- **プラットフォーム**: watchOS 26.4+
- **言語**: Swift 6
- **UI フレームワーク**: SwiftUI
- **状態管理**: `@Observable` (Swift Observation フレームワーク)
- **通知**: `UserNotifications` (バックグラウンド完了通知)
- **触覚フィードバック**: `WKInterfaceDevice`

## アーキテクチャ

```
mela-watch-timer Watch App/
├── mela_watch_timerApp.swift   # エントリーポイント、通知権限リクエスト
├── PomodoroTimer.swift          # タイマーモデル (@Observable)
├── ContentView.swift            # メイン UI
└── Assets.xcassets/
```

ロジックとUIを分離するシンプルな単層アーキテクチャ。`PomodoroTimer` はUIに依存しない純粋なモデルとして設計する。

## タイマー仕様

- **集中フェーズ**: 25分（`work`）
- **休憩フェーズ**: 5分（`rest`）
- **ループ**: work → rest → work → rest ...
- **完了カウント**: 集中セッション完了数をリング内ドットで表示（最大8個）

## バックグラウンド対応

タイマー開始時に `UNUserNotificationCenter` でローカル通知をスケジュール。
アプリ復帰時に `endDate` から残り時間を再計算して UI を最新状態に同期する。

## ビルド・実行

```bash
# Xcode で開く
open mela-watch-timer.xcodeproj
```

Apple Watch 実機または watchOS Simulator を選択してビルド・実行。

## 開発上の注意

- watchOS シミュレーターでは触覚フィードバック (`WKInterfaceDevice.play`) は動作しない
- ローカル通知の動作確認は実機推奨
- `@Observable` の観測対象プロパティは `private(set)` を使い、変更はモデルメソッド経由に限定する
- タイマーの `Timer` は `RunLoop.main` + `.common` モードで登録してスクロール中も確実に発火させる
