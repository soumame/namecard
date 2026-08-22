# Android NFC-V test client

Android Studioでこのディレクトリを開き、実機へインストールする。画面上で次の
いずれかを選択してからST25DV04Kへタッチする。

1. `接続・STATUS確認`: Mailbox通信だけ。EPDは更新しない
2. `選択パターン`: 10種類から選び、1-byteのpattern IDだけで全画面Partialを実行
3. `10種類を連続書き換え`: checkerからTEST 10までを同じRF接続で順番に実行
4. `4736-byte画像`: `EPD_NATIVE_1BPP`を可変長DATAへ分割して転送

CLIで確認する場合はAndroid SDKの場所を`local.properties`へ設定して実行する。

```sh
gradle :app:assembleDebug
```

APKは`app/build/outputs/apk/debug/app-debug.apk`へ生成される。電源投入後の最初の
Partialだけは物理画面が全面白である前提。内蔵パターンの連続試験中は、FWが直前の
表示をRAMに保持するため、途中で`prepare-white`を実行する必要はない。
VS Codeからは`Android: Build NFC test client`、USBデバッグ接続後は
`Android: Install NFC test client`を選んでもよい。分割転送用のサンプルを端末へ
用意するには`Android: Push sample native image`を実行し、アプリからDownload内の
`namecard-checker.bin`を選択する。

クライアントはST25DVの通常速度Mailboxコマンド（`AAh`〜`AEh`）を使う。端末の
`maxTransceiveLength`が小さい場合はDATA payloadを240 bytes未満へ自動的に縮める。
FWは可変長DATAを受理するため、転送フレーム数だけが20より増える。

COMMIT/PATTERN ACK後はまず1.5秒間、VRES充電のため`transceive()`を止める。
`EXECUTE` ACKを読み終えた後も最低2秒間通信を止め、NFC-V接続とRF電界だけを残す。
Reader Modeのpresence check間隔は5秒に設定済み。画面ロックや別アプリへの切替を
行わず、完了表示まで端末を動かさないこと。

前提として、ST25DVの静的`MB_MODE=1`と`EH_MODE=0`を事前にプロビジョニングする。
このアプリは誤設定を隠さないため、静的設定やパスワードを変更しない。

## 初回プロビジョニングと切り分け

新品のST25DVでは、Fast Transfer Modeの静的許可`MB_MODE`が初期値0、Energy
Harvestingの`EH_MODE`が初期値1になっている。組み立てた基板ごとにST25公式アプリで
RF configuration passwordを提示し、次を一度だけ保存する。工場出荷時の
`RF_PWD_0`は8-byteすべて0である。

- `MB_MODE=1`: Mailboxの動的`MB_EN`変更を許可する
- `EH_MODE=0`: RF電界を検出したらV_EHを自動的に出力する

設定後はスマホを完全に離してRF電界を一度切り、改めてこのアプリを起動する。
`ST25 command AE error 10`または`Mailbox register unavailable`は、タグを検出できて
いないという意味ではない。ST25までコマンドは届いているが、通常は静的
`MB_MODE=0`のため動的Mailboxレジスタが利用不可になっていることを示す。

`FW error=18`はRF側のerror `18h`ではなく、FW内部の`NC_ERROR_NFC_IO`を10進表示
したもの。STM32とST25間のI2C/Mailboxアクセス失敗を表す。FWは短いI2C再試行を行い、
その後のMailbox読出しに成功した場合は起動直後の一時エラーを回復済みとして消去する。
繰り返し18になる場合は、UID検出後も位置を固定し、SYS_VDDとST25のVCC、SCL/SDAを
確認する。

このアプリはReader Modeでタグを検出した時点で`NFC-V検出 UID=...`を表示し、その後
MCU起動を1.5秒待つ。UIDが表示されてから`MCU ACK timeout`になる場合は、NFC検出では
なくV_EH、MCU起動、I2C、またはFW側Mailbox応答を調べる。ST25公式アプリはタグICだけ
と通信できれば反応する一方、このアプリの全試験は継続給電でMCUも動かすため、安定
動作する距離は公式アプリの読取距離より短くなる。

画像DATA転送中に`TagLost`になった場合、Android側は最後にACK済みのTransfer ID、
Sequence、Offsetを保持する。ファイルを選び直さず、そのまま再タッチすると同じDATA
から再送する。MCUが状態を保持していれば重複ACKまたは次のOffsetから継続し、電源断で
MCUが再起動していれば`NC_ERROR_TRANSFER_ID`を受けてSTARTから自動的にやり直す。
Androidアプリ自体を終了・再インストールした場合、RAM上の再開情報は失われる。
10パターン連続試験は、完了した番号をAndroid側に保持する。途中でTagLostまたはACK
timeoutになってもReader Modeを再起動し、同じ位置へ戻せば未完了番号から再試行する。
ただし名刺側MCUも電源断した場合は旧画像RAMの対応を失うため、濃度評価は最初から
やり直す。
