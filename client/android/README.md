# Android NFC-V client

Android Studioでこのディレクトリを開き、実機へインストールする。アプリは
`New`、`Library`、`Settings`の3タブで構成する。

クライアント本体はKotlin 2.3とJetpack Compose 1.9 / Material 3で実装する。
全画面と296×128エディターCanvasはCompose UIで、ドラッグ、2本指ピンチ、回転も
Composeのpointer inputで処理する。NFCのブロッキングI/Oは`Dispatchers.IO`上の
コルーチンで実行し、画面終了時はコルーチンとNFC接続をまとめてキャンセルする。
プロトコル、ACK検証、転送再開状態はUIから分離し、JVM単体テストでCRCと画像形式を
確認する。

- `New`: 296×128キャンバスへ画像とテキストを配置し、Library保存、BIN書出、NFC書込
- `Library`: 保存またはインポートしたカードをギャラリー表示し、名称変更、書出、削除、再書込
- `Settings`: 書換え前クリーニング、10種類の内蔵パターン、STATUS確認、通信ログ

画像送信前に`ドット密度（白黒）`または`4階調（ピクセル濃度）`を選ぶ。4階調は
各ピクセルを黒・濃灰・薄灰・白へ量子化し、4,736-byteのSSD1680 RAM planeを2枚送る。
第1 planeはFWがFlashへ保存するため、途中でMCUが再起動しても第2 planeだけ再送できる。

画像エディターまたは既存BINから書き込む場合、実パネルで前画面のゴーストが
確認されたため、既定で`白 → 黒 → 白`の3回のPartialクリーニング後に
本画像を更新する。v0.8対応FWでは画像を1回だけ転送・Flash保存し、FW内部で
`白 → 黒 → 白 → 本画像`を連続実行する。中間画像のNFC転送とFlash書込みがなく、
従来方式より短時間で済む。旧FWではAndroidが各段階を順に送る互換動作へ自動で戻る。
途中で電源断した場合、保存済み本画像から一括クリーニングを白段階から安全に再開する。

Settingsの`書き換え前のクリーニング`をOFFにすると、
前回の確定済み画像から直接Partial更新する高速試験になる。ただしゴーストが残る
可能性がある。OFFでもrecovery pendingまたはERROR状態の場合は自動クリーニングする。
これはNFC給電で可能なPartialクリーニングであり、保守時のFull白更新は従来どおり
外部3.3Vの`prepare-white`を使用する。

## Newエディター

Newタブには、実ディスプレイと同じ296×128の横長キャンバスを常時表示する。

1. 上部の`送信方式`からドット密度または4階調を選ぶ
2. 下部の`テキストを追加`で文字を入力する。日本語も端末のシステムフォントで描画する
3. `画像を追加`から端末内のJPEG、PNG、WebPなどを選ぶ
4. オブジェクトを1本指で移動し、2本指でサイズと回転角を直接変更する
5. 1回の追加・削除・レイヤー変更・ジェスチャーを`Undo` / `Redo`できる
6. `Libraryに保存`は現在の完成画像をアプリ内部へ保存する
7. `BIN書出`は選択方式に応じた4,736-byteまたは9,472-byteデータを端末へ保存する
8. `NFCに書込`は生成済みBINを再開対応NFC転送へセットする。その後、名刺へタッチして
   完了まで位置を固定する

画像とテキストは白背景へ合成される。ドット密度方式は輝度と4×4 ordered ditheringで
1bitへ変換する。4階調方式は輝度を4段階へ量子化し、SSD1680の2つのRAM planeへ変換する。
どちらも16 bytes × 296 rows、MSB firstのネイティブ順である。
選択枠は編集UIだけに表示され、BINには含まれない。

## Library

Libraryは完成画像のネイティブBINと名称・送信方式をアプリ内部ストレージへ保存する。
カードは296×128のプレビュー付きで2列表示し、NFC書込、名称変更、BIN書出、削除ができる。
上部の`インポート`は4,736-byteをドット密度、9,472-byteを4階調として自動判定する。
Libraryは完成画像を保存する機能であり、テキストや画像の編集レイヤーまでは保持しない。

## 配布用APK

`main`ブランチへAndroid関連の変更をpushすると、GitHub Actionsが単体テストとLintを
実行し、release署名済みAPKをビルドする。成功したAPKは次の固定URLで公開する。

https://github.com/soumame/namecard/releases/download/android-main/namecard.apk

初回実行前に、更新時にも継続して使用するrelease署名鍵を用意する。鍵を失うと、すでに
インストールされたアプリを上書き更新できない。鍵ファイルとパスワードはリポジトリへ
commitせず、それぞれ安全な場所へバックアップする。

```sh
keytool -genkeypair -v \
  -keystore namecard-release.jks \
  -storetype JKS \
  -alias namecard \
  -keyalg RSA \
  -keysize 4096 \
  -validity 10000
```

リポジトリの`Settings` → `Secrets and variables` → `Actions`へ、次のRepository
secretsを登録する。

- `ANDROID_RELEASE_KEYSTORE_BASE64`: `namecard-release.jks`をBase64化した内容
- `ANDROID_RELEASE_STORE_PASSWORD`: keystoreのパスワード
- `ANDROID_RELEASE_KEY_ALIAS`: 上の例では`namecard`
- `ANDROID_RELEASE_KEY_PASSWORD`: 鍵のパスワード

macOSとGitHub CLIを使う場合、keystoreは次のコマンドで登録できる。残り3つは
`gh secret set シークレット名`を実行し、表示される入力欄へ値を貼り付ける。

```sh
base64 < namecard-release.jks | gh secret set ANDROID_RELEASE_KEYSTORE_BASE64
gh secret set ANDROID_RELEASE_STORE_PASSWORD
gh secret set ANDROID_RELEASE_KEY_ALIAS
gh secret set ANDROID_RELEASE_KEY_PASSWORD
```

workflowはCI用`versionCode`として`100000 + GitHub run number`を設定する。テストまたは
Lintが失敗した場合、公開中のAPKは置き換えない。手動で再実行するときはActionsの
`Android release`から`Run workflow`を選ぶ。

販売物のQRコードは、インストール説明を確認できる次のURLへ向ける。

https://github.com/soumame/namecard

CLIでは同梱のGradle Wrapperを使う。Android SDKは`ANDROID_HOME`、またはgit管理外の
`local.properties`に設定する。初回だけWrapperが検証済みGradle 8.13を取得する。
ComposeのコンパイルとLintに必要なGradleヒープは`gradle.properties`で2GiBに設定する。

```sh
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
```

APKは`app/build/outputs/apk/debug/app-debug.apk`へ生成される。電源投入後の最初の
Partialだけは物理画面が全面白である前提。内蔵パターンの連続試験中は、FWが直前の
表示をRAMに保持するため、途中で`prepare-white`を実行する必要はない。
VS Codeからは`Android: Build NFC test client`、USBデバッグ接続後は
`Android: Install NFC test client`を選んでもよい。分割転送用のサンプルを端末へ
用意するには`Android: Push sample native image`を実行し、アプリからDownload内の
`namecard-checker.bin`を選択する。

`INSTALL_FAILED_UPDATE_INCOMPATIBLE`は、端末内の旧APKと新APKのデバッグ署名が
異なる場合に発生する。VS Codeの
`Android: Clean install NFC test client (signature reset)`を一度だけ実行する。
このタスクは`work.tokumaru.namecard`の旧版とアプリデータを削除してから再インストール
する。以後、同じデバッグ鍵を使う限り通常の`Android: Install NFC test client`で
上書きできる。

クライアントはST25DVの通常速度Mailboxコマンド（`AAh`〜`AEh`）を使う。DATA間隔は
ACKのVDDに応じて50/200/500msを自動選択し、電圧に余裕がある時は固定500ms待機を省く。端末の
`maxTransceiveLength`が小さい場合はDATA payloadを240 bytes未満へ自動的に縮める。
FWは可変長DATAを受理するため、転送フレーム数だけが20より増える。

COMMIT/PATTERN ACK後はまず1.5秒間、VRES充電のため`transceive()`を止める。
通常/旧FW互換更新では`EXECUTE` ACK後も最低2秒間通信を止める。4階調では32行ごとに
Reset、2段階初期化、C7、Deep Sleep、EPD OFFを独立して行い再充電するため最低60秒、
FW一括クリーニング
ではACK指定値（最低1秒）のあとSTATUSを低頻度で確認し、FWが再充電と4段階更新を
進める間はNFC-V接続とRF電界を残す。
Reader Modeのpresence check間隔は120秒に設定し、4階調の再充電中に余計なRFコマンドを
発生させない。転送中は画面ロックを抑止する。別アプリへの切替を
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
MCU起動のため4秒間RF通信を止める。続いて`EH_CTRL_Dyn.VCC_ON`を確認し、VCCがまだ
立ち上がっていなければ1秒間隔・最大8秒でMailbox有効化を再試行する。UIDが表示されてから
`MCU ACK timeout`になる場合は、NFC検出では
なくV_EH、MCU起動、I2C、またはFW側Mailbox応答を調べる。ST25公式アプリはタグICだけ
と通信できれば反応する一方、このアプリの全試験は継続給電でMCUも動かすため、安定
動作する距離は公式アプリの読取距離より短くなる。

画像DATA転送中に`TagLost`、通常のNFC `IOException`、ACK timeout、Mailbox busyに
なった場合、Android側は最後にACK済みのTransfer ID、Sequence、Offsetを保持する。
古い`Tag`オブジェクトを閉じ、Reader Modeを300ms後に再初期化するため、ホーム画面へ
戻らなくても再検出できる。ファイルを選び直さず、そのまま再タッチすると同じDATAから
再送する。MCUが状態を保持していれば重複ACKまたは次のOffsetから継続し、電源断で
MCUが再起動していれば`NC_ERROR_TRANSFER_ID`を受けてSTARTから自動的にやり直す。
Androidアプリ自体を終了・再インストールした場合、RAM上の再開情報は失われる。
NewまたはLibraryから書込を開始した後は生成済みBINをRAMに保持するため、NFC転送中に
タグを見失っても画像を選び直す必要はない。
10パターン連続試験は、完了した番号をAndroid側に保持する。途中でTagLostまたはACK
timeoutになってもReader Modeを再起動し、同じ位置へ戻せば未完了番号から再試行する。
ただし名刺側MCUも電源断した場合は旧画像RAMの対応を失うため、濃度評価は最初から
やり直す。
