# iOS Core NFC test client

STM32の`release` FWと同じMailboxプロトコルを使う、iPhone実機用の検証アプリ。
Android版に相当する次の試験を行える。

1. `STATUS`: EPDを更新せず、MCU・Mailbox・VDDを確認
2. `10秒無通信`: Core NFCセッションを接続したまま10秒間コマンドを送らず、
   iPhoneがRF電界とMCU状態を維持できるか確認
3. `内蔵パターン`: 10種類から選択し、1-byteのpattern IDで全画面Partial
4. `10種類を連続`: Core NFCの制限時間前に安全停止し、次のセッションで続行
5. `画像分割転送`: 内蔵チェック画像、またはFilesから選んだ正確に4,736-byteの
   `EPD_NATIVE_1BPP`画像を220-byteずつ転送して更新

## 実機へ入れる

1. [NamecardNFCTest.xcodeproj](NamecardNFCTest.xcodeproj)をXcodeで開く。
2. 左の青い`NamecardNFCTest`プロジェクトを選び、`TARGETS > NamecardNFCTest >
   Signing & Capabilities`で自分の`Team`を選ぶ。
3. `Near Field Communication Tag Reading` capabilityがあることを確認する。
4. Macへ接続したiPhoneを実行先に選び、Xcode左上のRun（▶）を押す。
5. iPhone側でDeveloper Modeや開発者の信頼を求められた場合は案内に従う。

NFCはSimulatorでは使えないため、動作確認は必ず実機で行う。初回のみApple IDを
Xcodeへ追加して開発署名する必要がある。App Store提出は不要。

コマンドラインで署名なしコンパイルだけ確認する場合:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project NamecardNFCTest.xcodeproj \
  -scheme NamecardNFCTest -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/namecard-ios-derived CODE_SIGNING_ALLOWED=NO build
```

## 試験手順

先にVS Codeの`FW: Flash release`で最新FWを書き込み、ST-Linkと外部給電を外す。
ST25DVは基板ごとに静的`MB_MODE=1`、`EH_MODE=0`を設定しておく。

まず`STATUS`、次に`10秒無通信`を実行する。どちらも通ったら内蔵パターン1回、
10種類の連続更新、最後に内蔵チェック画像の分割転送を試す。Core NFC画面が出たら
iPhone上端のNFCアンテナ部を基板へ固定し、完了まで画面ロックやアプリ切替をしない。

画像形式は296×128、1-bit、4,736 bytes、MSB first、`1=白`、SSD1680 RAM順。
Filesから選ぶ場合も拡張子ではなくサイズと内容で判定する。

Core NFCの読取セッションには時間上限があり、アプリは48〜55秒で自動的に区切る。
画像は最後にACKされたTransfer ID/Sequence/Offsetをメモリ上に保持し、タグロスト後も
同じセッション内で再検出する。時間上限でセッションが終了した場合は、再度
`選択画像を分割転送・更新`を押すと保持した進捗から再開する。MCUが電源断していれば
FWの応答に合わせてSTARTから自動再送する。

`EXECUTE` ACK後は最低2秒、充電待ちでは1.5秒、Core NFCコマンドを意図的に送らない。
この間もiOSがRF給電を維持する保証はないため、まず10秒無通信試験を実機・iOS版ごとに
確認する。10秒試験のPASSは、無通信前に作ったSTM32のRAM状態が無通信後も残っていた
ことを意味する。

Core NFCのISO 15693 custom commandはnon-addressed＋high data rateで送る。Core NFCが
ST manufacturer codeを付加するため、アプリ側のparameterにはmanufacturer codeや
UIDを重ねて入れない。
