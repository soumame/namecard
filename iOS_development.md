# iOSアプリの実装構成と検証計画

## 現在の状況

`client/ios/`にSwiftUIとCore NFCによるiOSアプリを実装済みで、MameCardとして
TestFlightでベータ配布しています。以前の「未実装・移植予定」という計画から更新した資料です。

利用する場合は[事前登録フォーム](https://forms.gle/RqQPmfoJ9aMMtRm66)へ回答してください。
回答後にTestFlightの参加リンクをお送りします。対応条件・試験内容・報告方法は
[ベータ試験ガイド](client/ios/docs/BETA_TESTING.md)を参照してください。

iPhone XR／iOS 18で白黒画像、内蔵パターン、URL設定、クリーニング、振動案内の動作報告があります。
給電・更新時間の計測と、2機種以上で各公開対象経路10回連続成功の記録は未完了です。
App Store公開に向けた条件は[実機検証](client/ios/docs/HARDWARE_VALIDATION.md)にまとめています。

## 実装済みの機能と制限

- **New:** 画像・日本語テキスト・QRコードの追加、テキスト書式、移動・拡縮・回転、重なり順、
  Undo／Redo、グリッド、位置・要素回転・表示回転のスナップ。
- **Library:** 完成画像の保存、名称変更、削除、BIN取込・書出、完成画像を1レイヤーとして再編集。
- **Settings:** 白黒クリーニング、10種類の内蔵パターン、STATUS確認、通信ログ、任意の振動案内。
- **URL:** HTTP(S)のNDEF書き込み、URLクリア、読み返し、同じUIDの名刺での中断復旧。
- **画像形式:** Androidと同じ296×128、白黒4,736 bytes／4階調9,472 bytesのヘッダーなしBIN。

4階調は編集・プレビュー・保存・BIN入出力のみ対応します。iOSからの4階調NFC書き込みと、
4階調表示済み・更新中断済みの名刺から白黒へ移行する操作は無効です。
現FWの4階調更新にはEXECUTE後60秒のRF無通信が必要で、現行のCore NFCセッション内では完了できません。
白黒への移行にもFull更新を含む別の給電・時間検証が必要です。販売済み基板・FWの変更は不要です。

詳しい操作方法と通信仕様は[iOS README](client/ios/README.md)を参照してください。
上記は現行ソースの機能です。配布済みビルドの変更点はTestFlightの「テスト内容」で確認してください。

## 開発環境とビルド

- Xcode 26以降とSwift 6 toolchainを使用します。アプリのSwift言語モードは5です。
- 最低対応OSはiOS 17です。NFC通信には対応iPhoneと名刺基板が必要です。
- Simulatorでは編集・Library・BINと模擬通信のテストを実行できます。RF給電は実機で確認します。
- `client/ios/Namecard.xcodeproj`を開きます。外部Swiftパッケージは不要です。
- Bundle IDは`work.tokumaru.namecard`です。Apple Developer Programには登録済みです。
  実機ビルドでは自分のTeamとNear Field Communication Tag Readingを設定します。
  個人の派生アプリは、自分のTeamで使用できるBundle IDに変更してください。

リポジトリのルートで実行します。

```sh
swift test --package-path client/ios/NamecardCore
python3 client/ios/tools/generate_project.py --check
xcodebuild -project client/ios/Namecard.xcodeproj -scheme Namecard \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Xcodeプロジェクトは`client/ios/tools/generate_project.py`で再生成できます。
NFC利用目的は`Config/Info.plist`、entitlementは`Config/Namecard.entitlements`に定義済みです。
署名・配布、Simulator選択、Runtime不一致時の手順は
[iOS README](client/ios/README.md#開発環境)と[配布手順](client/ios/docs/DISTRIBUTION.md)を参照してください。

## 現在のディレクトリ構成

```text
client/ios/
  Namecard.xcodeproj
  Config/                    # Info.plist、NFC entitlement
  Namecard/
    App/                     # 3タブ、Library表示、配布・実機検証設定
    Editor/                  # 編集、テキスト書式、QRコード
    NFC/                     # Core NFC、Mailbox、URL、触覚案内
    Resources/               # アイコン、プライバシー、試験対象設定
  NamecardCore/
    Sources/NamecardCore/    # 画像形式、NCプロトコル、転送、URL、保存
    Tests/NamecardCoreTests/ # Android期待BINとの照合、模擬通信テスト
  NamecardTests/             # エディター、URL、通信・配布設定のテスト
  NamecardUITests/           # 画面操作のテスト
  tools/                    # プロジェクト生成、配布構成の検査
  docs/                     # 配布・検証・実機試験の記録
```

`NamecardCore`はCore NFCやSwiftUIに依存しないSwift Packageです。
エディターのUndo／Redoは`EditorModel`の履歴で管理し、Libraryには編集レイヤーではなく完成BINを保存します。

## 通信実装の参照先

- [`NCProtocol.swift`](client/ios/NamecardCore/Sources/NamecardCore/NCProtocol.swift): NC v1フレーム、CRC、ACK検証。
- [`TransferCoordinator.swift`](client/ios/NamecardCore/Sources/NamecardCore/TransferCoordinator.swift): 白黒画像・パターン・清掃、残り時間、再スキャンからの再開。
- [`ST25Mailbox.swift`](client/ios/Namecard/NFC/ST25Mailbox.swift): Core NFCのISO 15693独自コマンドとMailbox交換。
- [`NativeImage.swift`](client/ios/NamecardCore/Sources/NamecardCore/NativeImage.swift): 白黒・4階調BIN変換。
- [`URLCodec.swift`](client/ios/NamecardCore/Sources/NamecardCore/URLCodec.swift)／[`URLWriter.swift`](client/ios/Namecard/NFC/URLWriter.swift): URL検証、NDEF／Type 5、復旧記録。
- [ファームウェアのプロトコル仕様](firmware/docs/PROTOCOL.md): コマンド、画像形式、ACK、更新手順の共通仕様。

ST25DVの通常速度Mailboxコマンド`0xAA`／`0xAC`／`0xAD`／`0xAE`を使います。
Core NFCの`customRequestParameters`へはST固有のパラメーターだけを渡し、Androidのrawフレームにある
manufacturer codeやUIDを重複させません。DATAは128 bytes、ACKは32 bytesです。
FWのDATA上限240 bytesに対して128 bytesを選ぶのは現行アプリの設定であり、iPhone実機の最大値ではありません。

転送状態はRAMで保持し、同じUIDの名刺でのみ再開します。URLの中断復旧記録は端末内へ保存するため、
アプリ再起動後もSettingsから再開できます。URL操作では`NDEF_WRITE_PREPARE`のACKを確認してから
Mailboxを停止し、NDEFの書き込み・読み返し後に再開します。静的なEH／Mailbox設定やパスワードは変更しません。

Androidとの互換性は、[NativeImageFormat.kt](client/android/app/src/main/java/jp/namecard/nfctest/NativeImageFormat.kt)、
[NamecardProtocol.kt](client/android/app/src/main/java/jp/namecard/nfctest/NamecardProtocol.kt)、
[nc_protocol.h](firmware/Core/Inc/nc_protocol.h)と照合します。
Android実装から生成した期待BINとの全バイト比較を共通テストに含めています。

## 配布構成と今後の検証

| Scheme | 用途と表示書き込みの条件 |
| --- | --- |
| `Namecard` | 通常Debug／Release。`HardwareValidation.json`の実測記録がある端末・OS・経路だけ許可。現在のリストは空 |
| `Namecard Hardware` | 開発者の実機計測用。通常／一括清掃／旧FWに仮の8／20／8秒を使用。ArchiveはRelease |
| `Namecard Beta` | TestFlight試験用。`BetaDistribution.json`で対象を指定し、同じ仮の時間予算を使用。ArchiveはBeta |

Betaの対象は現在iOS 17以降のNFC対応iPhoneです。どの構成も4階調NFC書き込みと未検証の白黒移行は無効です。
ベータでの成功報告や自動テストだけで、通常版の実測記録を埋めないでください。

今後の作業は、同じ販売品構成での連続画像更新・清掃・URL設定／クリア・切断復旧の再試験、
所要時間と最低電圧の計測、複数iPhoneでの検証です。URL通信の改善後の実機試験、
QRコードの実パネル読み取り、テキスト操作時のHangの切り分けも残っています。
試験結果は[検証記録](client/ios/docs/VALIDATION.md)と[実機試験表](client/ios/docs/HARDWARE_VALIDATION.md)へ記録します。

実測後に`HardwareValidation.json`へ端末・OS・経路別の上限時間と根拠を反映し、
`python3 client/ios/tools/check_release_readiness.py`でApp Store公開条件を確認します。
現在は実測記録がないため、このチェックは失敗する想定です。

## 開発・実機検証に協力する方へ

このリポジトリの独自部分は[MIT License](LICENSE)です。
Pull RequestまたはIssueに、アプリのVersion／Build、機種・OS、基板構成、再現手順と試行結果を添えてください。
実機でのフィードバックに共有するログ・画像・URLは、送信前に内容を確認してください。
