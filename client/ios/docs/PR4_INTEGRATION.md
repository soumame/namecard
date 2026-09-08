# PR #4からの選択統合

2026-09-08。対象はKazuya Ueoka（[@fromkk](https://github.com/fromkk)）による
[PR #4「iOSクライアントを追加」](https://github.com/soumame/namecard/pull/4)、
コミット`511c05a5957a041d301c3b0433e5a4369d8436e1`です。
`client/ios`を配布対象として、既存の対応機能とNFC復旧処理に合わせて改善を取り込みました。
これはローカル実装への選択統合の記録です。PR一式のGitマージではありません。

## 採用した改善

PRの[LibraryStore](https://github.com/fromkk/namecard/blob/511c05a5957a041d301c3b0433e5a4369d8436e1/iOS/Namecard/Features/Library/LibraryStore.swift#L16)
を参考に、Libraryサムネイルを読み込み時に生成し、SwiftUIの画面更新では再利用する方式を採用しました。

- `AppModel.reload()`で画像を生成し、`MainView`はキャッシュを参照します。
- 同じID・方式・BINなら、再読み込みや名称変更でも同じ画像を再利用します。
- BIN変更時には再生成し、削除・破損により一覧から消えたカードの画像は解放します。
- 現行仕様に合わせ、白黒と4階調の両方を扱います。完成BINの保存内容は変えません。

初回の生成とLibraryのファイル読み込みは引き続きメインスレッド上です。
大量の保存カードがある場合の初回読み込み時間・メモリ使用量は未計測です。
この改善を、デバッガ接続時に報告された約3秒のHangの原因特定・解消とは扱いません。

## ほかの差分の判断

| PRの内容 | 判断と理由 |
| --- | --- |
| アプリ一式・Editor・Library・BIN入出力 | 現行実装に同等機能があるため重複追加しません。スナップ、紙面表示の変換、4階調編集・保存も現行仕様を維持します。 |
| 白黒BINのnative配置・Bayer変換 | 現行`NativeImage`と同じ方式です。Android期待BINとの照合を持つ現行実装を使います。 |
| 日本語を含むURLのエンコード | 現行`URLCodec`も対応済みです。不正escape・scheme・480-byte上限を含むAndroid互換の検証を維持します。 |
| PATTERN後のoffset=4,736、DATA=128 bytes、Core NFC形式のSTコマンド | 現行実装に反映済みの条件です。追加の通信方式変更はありません。 |
| 中断後の画像再開・完了確認 | 現行のUID照合、ACK対応検証、元画像からの再送、セッション期限・quiet制御を使います。下記のPR内の問題を持ち込まないためです。 |
| URL書き込み・Mailbox復旧 | 現行のraw読出し検証、復旧記録、同一UIDでの再開、Mailbox再開確認までを維持します。 |
| 最低OS・プロジェクト構成 | PRのアプリはiOS 18.6以上、テストは26.5以上の設定です。現行アプリのiOS 17以上と`NamecardCore`分離を維持します。 |
| iPhone 17 Pro＋v5基板での成功報告 | PR版についての作者の報告として参照します。統合版の2機種目の実機試験や10回連続成功の記録には転記しません。 |

## PRの通信処理をそのまま採用しない理由

コード確認で以下の差異を認めました。PR版の実機で不具合を再現したという意味ではありません。

1. [再スキャン直後](https://github.com/fromkk/namecard/blob/511c05a5957a041d301c3b0433e5a4369d8436e1/iOS/Namecard/NFC/NamecardTransfer.swift#L180)
   は、保持した`executeSent`と汎用STATUSの`COMPLETE`だけで完了扱いします。
   [保持状態の再利用](https://github.com/fromkk/namecard/blob/511c05a5957a041d301c3b0433e5a4369d8436e1/iOS/Namecard/NFC/NamecardWriter.swift#L174)
   にUID照合もなく、別の名刺や以前の画像の状態を今回の成功と取り違える余地があります。
2. [ACKのdecode](https://github.com/fromkk/namecard/blob/511c05a5957a041d301c3b0433e5a4369d8436e1/iOS/Namecard/Protocol/Ack.swift#L35)
   はCRCを確認しますが、要求とのTransfer ID・対象コマンド・要求sequenceの照合を行いません。
   現行実装では古いACKや不正な前進位置を拒否します。
3. [URL処理の終了時](https://github.com/fromkk/namecard/blob/511c05a5957a041d301c3b0433e5a4369d8436e1/iOS/Namecard/NFC/NamecardWriter.swift#L169)
   はMailbox再開失敗を無視して成功表示します。現行実装はエラーと復旧記録を残します。
4. [画像更新の45秒期限](https://github.com/fromkk/namecard/blob/511c05a5957a041d301c3b0433e5a4369d8436e1/iOS/Namecard/NFC/NamecardTransfer.swift#L314)
   はEXECUTE後から計算され、起動・転送に使ったセッション時間を含みません。
   現行実装はセッション全体の残り時間と更新時間上限＋5秒を確認してからEXECUTEします。

## 統合版の確認

- Library用の回帰試験を追加：再読込・名称変更での同一画像の再利用、同じIDのBIN差し替え、
  破損・削除時のキャッシュ除去、白黒／4階調、再起動後の画像一致を確認しました。
- 既存UI試験へ、保存直後・アプリ再起動後のLibraryサムネイル表示の確認を追加しました。
- 既存の別UID拒否、不明なCOMPLETEの再送、Mailbox再開失敗時の未完了保持も回帰確認しました。
- 共通57件、アプリ単体41件、UI5件が成功しました。環境・制約は[検証記録](VALIDATION.md)に記載しています。

統合時にはプロジェクト生成の`--check`に既存の不一致がありました。Xcodeが保存した`project.pbxproj`と
生成スクリプトに、書式・objectVersion・空の同期グループ属性・Team指定・visionOS互換設定などの差があります。
Library統合時にはプロジェクトの再生成を行いませんでした。
同日のベータ配布準備で、生成器をXcodeの設定へ合わせ、書式ではなく内容を比較するよう修正しました。
署名・バージョン指定を保持して再生成し、`--check`と生成器の回帰試験は成功しています。
GitHub上のCI実行結果は、ローカルでの確認とは別に確認します。

次の実機試験は、この統合版で画像A／Bの連続書き込み、清掃ON／OFF、URL、切断復旧を確認し、
[実機試験表](HARDWARE_VALIDATION.md)へ同じ版・端末・OS・基板構成で記録します。
