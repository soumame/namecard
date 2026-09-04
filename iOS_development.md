# iOSアプリの開発方法と計画

## 現在の状況

このプロジェクトには、現時点でビルド可能なiOSアプリや配布済みIPAはありません。以下は、既存のAndroidアプリとファームウェアをiOSへ移植するための設計資料です。

iOS版は技術的に実現できる可能性が高いと考えています。その根拠は次の通りです。

- AppleのCore NFCはNFC Type 5 / ISO 15693タグの読み書きと、`0xA0`〜`0xDF`のメーカー独自コマンドをサポートしています。
- この名刺のST25DV04Kとの通信で使うコマンドは`0xAA`、`0xAC`、`0xAD`、`0xAE`で、Core NFCの対応範囲に入っています。
- STMicroelectronicsは、ST25DVを扱うiOS用NFC TapアプリとFTM（Fast Transfer Mode）の実装例を公開しています。

ただし、Core NFCのセッション管理、転送可能サイズ、NFCアンテナ位置、RF給電中の安定性はAndroidと同一ではありません。この基板と独自プロトコルを使ったiPhone実機検証はまだないため、「対応済み」ではなく「実現可能性が高い」という段階です。

## まだ作成していない理由

主な理由は開発・配布予算です。XcodeとSimulatorを使い、UI、画像変換、通信プロトコルなどNFC以外の部分を開発・テストするだけなら無料で始められます。しかし、Core NFCを有効にしたアプリをiPhoneへ署名・インストールして実機検証するには`Near Field Communication Tag Reading`のCapabilityが必要です。このCapabilityは無料のPersonal Teamでは利用できず、Apple Developer Programへの加入が必要です。執筆時点のApple公表価格は年間99 USDまたは地域ごとの価格です。App StoreやTestFlightでの配布にも加入が必要です。

そのため、現在はAndroid版とハードウェアの完成を優先しています。iOS版を作らない技術的な方針があるわけではありません。

- [Apple Developer Program](https://developer.apple.com/programs/)
- [Apple Developer Programのメンバーシップ比較](https://developer.apple.com/support/compare-memberships/)
- [iOSでサポートされるCapability](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)

すべてのiPhone実機向けアプリにはコード署名が必要です。無料のApple AccountでもPersonal Teamによる署名はできますが、AppleのCapability対応表では`Near Field Communication (NFC) Tag Reading`はApple Developer ProgramまたはApple Developer Enterprise Program向けで、無料のApple Developer欄には対応表示がありません。そのため、このアプリのNFC機能を実機でビルド・検証する時点から有料メンバーシップが必要です。

## 目標とする機能

iOS版では、単にNFCへ画像を書くだけでなく、Android版と同じ主要機能を目標にします。

| Android版の機能 | iOS版の候補 |
| --- | --- |
| Jetpack Compose UI | SwiftUI |
| テキスト・画像レイヤー編集 | SwiftUI gestures + Core Graphics |
| 移動、拡大縮小、回転、整列、Undo/Redo | SwiftUI state + UndoManager |
| 1-bitディザ画像 | Core Graphicsで描画後、同じ4×4 Bayer変換 |
| 4階調画像 | SSD1680用2プレーンへ変換 |
| NFC-V / ST25DV Mailbox | Core NFC `NFCTagReaderSession` + `NFCISO15693Tag` |
| 中断後の再開 | `STATUS`応答のsequence/offsetから再開 |
| URL書き込み | `NFCNDEFTag`によるNDEF URI書き込みと読み返し |
| LibraryとBIN入出力 | Application Support配下のJSON + BIN、Document Picker |
| 内蔵パターン・状態確認 | 既存の`PATTERN` / `STATUS`コマンド |

UIコードをそのまま共有することはできませんが、画像形式と通信プロトコルは共通です。まずプロトコル部分をSwiftで忠実に移植し、その上へSwiftUIを載せる構成が最も小さく始められます。

## 正とする既存実装

移植時は次のファイルを仕様の基準にしてください。

- [`client/android/app/src/main/java/jp/namecard/nfctest/NamecardProtocol.kt`](client/android/app/src/main/java/jp/namecard/nfctest/NamecardProtocol.kt) — ST25DV Mailbox、フレーム生成、ACK解析
- [`client/android/app/src/main/java/jp/namecard/nfctest/NativeImageFormat.kt`](client/android/app/src/main/java/jp/namecard/nfctest/NativeImageFormat.kt) — 1-bit・4階調画像変換
- [`client/android/app/src/main/java/jp/namecard/nfctest/MainActivity.kt`](client/android/app/src/main/java/jp/namecard/nfctest/MainActivity.kt) — 転送、再試行、NDEF書き込みの状態遷移
- [`firmware/Core/Inc/nc_protocol.h`](firmware/Core/Inc/nc_protocol.h) — ファームウェア側の定数とフレーム定義
- [`firmware/Core/Src/nc_protocol.c`](firmware/Core/Src/nc_protocol.c) — フレーム検証と転送状態
- [`firmware/Core/Src/app.c`](firmware/Core/Src/app.c) — 充電、表示更新、ACKの意味

Android側の挙動だけを推測して別プロトコルを作らず、ファームウェア側の定義とも照合してください。

## 開発環境を用意する

必要なものは次の通りです。

- 現行Xcodeが動作するMac
- Core NFCを利用できる実機iPhone。SimulatorではNFC通信を検証できません
- v5基板と現行ファームウェア
- Apple Developer Programのメンバーシップ。Core NFCを有効にした実機ビルドと一般公開の両方で必要です

XcodeでSwiftUI Appを作り、将来的には`client/ios/`へ配置します。Bundle Identifierは自分のTeamで一意な値に変更してください。

Targetの`Signing & Capabilities`から`Near Field Communication Tag Reading`を追加し、`Info.plist`へ`NFCReaderUsageDescription`を設定します。Capabilityを追加すると、XcodeがNFC reader session用entitlementを生成します。

- [Apple: Building an NFC Tag-Reader App](https://developer.apple.com/documentation/corenfc/building-an-nfc-tag-reader-app)
- [Apple: Core NFC](https://developer.apple.com/documentation/corenfc)

## 推奨ディレクトリ構成

```text
client/ios/
  Namecard.xcodeproj
  Namecard/
    App/
    Features/Editor/
    Features/Library/
    Features/Settings/
    Image/NativeImageFormat.swift
    NFC/ISO15693Session.swift
    NFC/ST25Mailbox.swift
    Protocol/NamecardProtocol.swift
    Protocol/Ack.swift
    Storage/CardLibrary.swift
  NamecardTests/
```

`NamecardProtocol`、`Ack`、`NativeImageFormat`はCore NFCやSwiftUIに依存させず、通常のunit testだけで検証できるようにします。

## 実装手順

### 1. プロトコルをSwiftへ移植する

Namecard protocolのフレームは最大256 bytesで、16-byte headerの後ろに最大240-byte payloadが続きます。複数byte整数はlittle endianです。

| Offset | Size | 内容 |
| ---: | ---: | --- |
| 0 | 2 | Magic: ASCII `NC` |
| 2 | 1 | Version: `1` |
| 3 | 1 | Type |
| 4 | 2 | Transfer ID |
| 6 | 2 | Sequence |
| 8 | 2 | Offset |
| 10 | 2 | Payload length |
| 12 | 2 | Header CRC16 |
| 14 | 2 | Payload CRC16 |
| 16 | 可変 | Payload |

CRC16は初期値`0xFFFF`、多項式`0x1021`のCRC-16/CCITTです。Header CRCの計算時はoffset 12〜13を除外します。画像全体の検証にはCRC-32/IEEEを使います。

コマンド種別は次の通りです。

| Type | Value | 用途 |
| --- | ---: | --- |
| START | `0x01` | 画像サイズ、形式、CRCを通知 |
| DATA | `0x02` | 画像データを分割送信 |
| COMMIT | `0x03` | 受信画像を検証・確定 |
| STATUS | `0x04` | 状態、電圧、中断位置を取得 |
| EXECUTE | `0x05` | e-paper更新を開始 |
| PATTERN | `0x06` | 内蔵試験パターンを表示 |
| NDEF_WRITE_PREPARE | `0x07` | NDEF書き込み前にMailboxを停止 |
| ACK | `0x80` | 成功・進捗応答 |
| ERROR | `0x81` | エラー応答 |

最初にAndroidのunit testと同じ入力・期待値をSwift XCTestへ移植し、CRC、フレーム、ACK、画像変換が一致することを確認します。

### 2. Core NFCでST25DVへ接続する

`NFCTagReaderSession`を`.iso15693`で開始し、検出した`.iso15693`タグへ`session.connect(to:)`で接続します。`NFCISO15693Tag`はISO 15693の標準コマンドとメーカー独自コマンドを送信できます。

この名刺で必要なST25DVコマンドは次の通りです。

| Command | Value | Request parameters |
| --- | ---: | --- |
| Fast Write Message | `0xAA` | `[frame length - 1] + frame` |
| Fast Read Message | `0xAC` | `[start offset, response length - 1]` |
| Read Dynamic Configuration | `0xAD` | `[register address]` |
| Write Dynamic Configuration | `0xAE` | `[register address, value]` |

STのmanufacturer codeは`0x02`です。Core NFCの`customCommand` APIはmanufacturer codeなどISO 15693の外側のフレームを組み立てるため、`customRequestParameters`にはAndroidのraw `NfcV.transceive()`と違ってUIDやmanufacturer codeを重ねて入れず、表のST固有parameterだけを渡します。

概念的には次の呼び出しになります。

```swift
let response = try await tag.customCommand(
    requestFlags: [.highDataRate, .address],
    customCommandCode: 0xAD,
    customRequestParameters: Data([registerAddress])
)
```

Core NFCがメーカー独自コマンド`0xA0`〜`0xDF`を扱えることはAppleのAPI仕様に明記されています。

- [Apple: NFCISO15693Tag](https://developer.apple.com/documentation/corenfc/nfciso15693tag)
- [Apple: customCommand](https://developer.apple.com/documentation/corenfc/nfciso15693tag/customcommand%28requestflags%3Acustomcommandcode%3Acustomrequestparameters%3Acompletionhandler%3A%29)
- [ST: ST25DV Fast Transfer Mode application note](https://www.st.com/resource/en/application_note/an4910-data-exchange-between-wired-ic-and-wireless-rf-iso-15693-using-fast-transfer-mode-supported-by-st25dvi2c-series-stmicroelectronics.pdf)
- [ST: NFC Tap iOS application](https://www.st.com/en/embedded-software/stsw-st25ios001.html)

STのiOSサンプルは参考になりますが、このプロジェクトのプロトコル自体は小さいため、最初の試作ではSDK全体を組み込まずCore NFCへ直接実装する方が依存関係を抑えられます。

### 3. Mailbox交換を実装する

Android版と同じ順序で次を実装します。

1. `MB_CTRL_Dyn`を読み、必要なら`MB_EN`を有効化する
2. Mailboxが空くまで待つ
3. `0xAA`でNamecard frameを書き込む
4. 約50 ms待ち、`MB_CTRL_Dyn`の`HOST_PUT_MSG`をpollする
5. `0xAC`で32-byte ACKを読み、CRCと内容を検証する
6. ACKが返す`expectedSequence`と`expectedOffset`を次の送信へ使う

1回のDATA payloadはprotocol上240 bytes以下です。Core NFCで安定する最大値はiPhone実機で測定し、最初は128 bytes程度から試してください。端末やOSで制約が異なる場合に備え、値を固定せずtransport層で調整できるようにします。

### 4. 画像を同じ形式へ変換する

SwiftUIの編集結果をCore Graphicsで296×128 pixelのARGB画像へ描画し、Android版と同じnative formatへ変換します。

- 1-bit: 4,736 bytes
- 4階調: 4,736 bytes × 2 planes = 9,472 bytes
- Native index: `x * 16 + y / 8`
- Bit mask: `0x80 >> (y & 7)`
- 1-bitの閾値: Android版と同じ4×4 Bayer matrix

透明pixelは白背景へ合成してから輝度を計算します。AndroidでexportしたBINとiOSで生成したBINをbyte単位で比較するgolden testを用意してください。

### 5. 画像転送の状態機械を移植する

基本フローは次の通りです。

```text
STATUS → START → DATA × N → COMMIT → 充電待ち → STATUS → EXECUTE → STATUS
```

重要なのは、通信切断を失敗として最初からやり直すのではなく、再タッチ後の`STATUS`に含まれるsequence/offsetから再開することです。4階調ではplane 0を保存してからplane 1を送ります。

RF通信は名刺への給電も兼ねる一方、頻繁な通信がVRESの充電を妨げる場合があります。Android版と同様に、ACKの`vddMv`を見てDATA間隔を調整し、COMMIT後は通信を止めて充電時間を確保します。

iOS側のreader sessionはOSにより中断・無効化されることがあるため、1回のsessionで必ず完了する前提にしないでください。アプリ側に転送ID、plane、sequence、offsetを保持し、「名刺を離してもう一度タッチ」で安全に続行できるUIにします。

### 6. NDEF URL書き込みを移植する

`NFCISO15693Tag`は`NFCNDEFTag`としても利用できます。Android版と同じく、次の順序を守ります。

1. `NDEF_WRITE_PREPARE`を送り、ファームウェアに画像処理停止を要求する
2. ST25DV Mailboxを無効化する
3. NDEF URI recordを書き込む
4. 書いたNDEFを読み返して一致を確認する
5. Mailboxを再び有効化する

URLは`http`または`https`だけを許可し、Android版と同じ480-byte上限を適用します。途中でsessionが切れた場合も、次回接続時にMailboxを再開できるよう`defer`相当の後処理を用意します。

### 7. SwiftUIの編集画面とLibraryを作る

通信が安定してから、UIを次の順序で追加します。

1. 画像選択と296×128 preview
2. テキスト・画像layer
3. drag、pinch、rotation、整列、grid、snap
4. Undo/Redoとlayer順序
5. 1-bit / 4階調切り替え
6. Library保存、rename、import/export
7. 書き込み進捗、アンテナ位置、再タッチ案内

BINファイル形式をAndroid版と同じにすれば、両OS間でデータを交換できます。

## 開発計画

期限は未定です。機能を一度に移植せず、実機で不確実性を潰す順序にします。

| Phase | 完了条件 | 状況 |
| --- | --- | --- |
| 0. Feasibility spike | iPhoneでST25DVを検出し、`STATUS` ACKを取得 | 未着手 |
| 1. Transport | Mailbox、CRC、retry、再タッチ再開のXCTestと実機確認 | 未着手 |
| 2. Hardware update | PATTERN、1-bit画像、4階調画像を順に表示 | 未着手 |
| 3. Editor | 画像・文字編集とAndroid互換BIN生成 | 未着手 |
| 4. Library / URL | 保存、入出力、NDEF URL書き込み | 未着手 |
| 5. Distribution | 複数iPhoneで検証し、配布方法と予算を決定 | 未着手 |

最初の到達点は完全なUIではなく、`STATUS`と`PATTERN`が動く最小アプリです。ここが成功すれば、Core NFCからMailbox経由でファームウェアを制御できることを確認できます。

## 実機テスト項目

- `NFCTagReaderSession.readingAvailable`がtrueになること
- ST25DV04KだけをISO 15693タグとして選択できること
- `MB_EN`の有効化、32-byte ACK、CRC検証
- 10種類の内蔵パターン
- 1-bit画像と4階調画像
- 転送中に名刺を離し、再タッチで続行できること
- 弱いアンテナ位置でVDDに応じた待ち時間が働くこと
- URL書き込み後、アプリ外から通常のNFCタッチでURLが開くこと
- 異なるiPhoneモデル・iOSバージョンでの転送時間と安定性

## 実装・検証できた方へ

このリポジトリの独自部分はMIT Licenseです。iOS版の試作、Core NFCでのST25DV Mailbox疎通、対応端末の検証結果だけでも歓迎します。

Pull RequestまたはIssueに加えて、実装や実機検証ができた場合は[https://tokumaru.work](https://tokumaru.work)からご連絡ください。
