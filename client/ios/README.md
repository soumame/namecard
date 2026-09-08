# Namecard for iOS

iOS 17以降向けのSwiftUIアプリです。販売済みの名刺基板・FWを変更せず、
Androidと同じ296×128 BINを利用します。現在は開発版で、TestFlight／App Storeでは未配布です。

## 開発環境

- Xcode 26以降、Swift 6 toolchain。外部Swiftパッケージは不要です。
- iOS 26では標準のナビゲーションとコントロール、およびエディタの操作面にLiquid Glassを使用します。
  iOS 17〜18では同じ機能と階層を保った標準Material／Buttonスタイルへフォールバックします。
- `Namecard.xcodeproj`を開き、通常は`Namecard` schemeを使用します。
- SimulatorではNFC以外の編集・Library・ファイル機能を確認できます。
- 実機ではApple Developer ProgramのTeamとNear Field Communication Tag Readingを設定します。
  Team ID、証明書、プロビジョニングプロファイルはリポジトリへ保存しません。

```sh
swift test --package-path client/ios/NamecardCore
python3 client/ios/tools/generate_project.py --check
xcodebuild -project client/ios/Namecard.xcodeproj -scheme Namecard \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

`python3 client/ios/tools/select_simulator.py`でインストール済みiPhoneのUDIDを取得し、
`-destination 'platform=iOS Simulator,id=<UDID>' test`でアプリ単体試験とUI試験を実行します。
Xcodeプロジェクトは標準ライブラリだけの`tools/generate_project.py`から再生成でき、
同期グループによってSwiftファイルが自動的にターゲットへ入ります。

### SDKとSimulator Runtimeの不一致がある場合

インストール済みRuntimeでもschemeの実行先選択が拒否される環境では、最新ソースを
ターゲット指定でビルドし、生成済み成果物からプロジェクトに依存しない`.xctestrun`を作成できます。
`select_simulator.py`が出力する`NAMECARD_SIMULATOR_ID=...`をシェルに設定して実行します。

```sh
xcodebuild -project client/ios/Namecard.xcodeproj -target NamecardTests \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO \
  SYMROOT=/tmp/namecard-products OBJROOT=/tmp/namecard-objects build
python3 client/ios/tools/make_simulator_test_run.py \
  --products /tmp/namecard-products/Debug-iphonesimulator \
  --output /tmp/namecard-tests.xctestrun
xcodebuild test-without-building -xctestrun /tmp/namecard-tests.xctestrun \
  -destination "platform=iOS Simulator,id=$NAMECARD_SIMULATOR_ID" \
  -parallel-testing-enabled NO
```

UI試験はビルド対象を`NamecardUITests`にし、生成ツールへ`--ui`を追加します。
ツールは選択中のXcodeと実際の`Info.plist`を読み、実行設定だけを生成します。
ビルド・Simulator起動・テスト実行・Runtimeダウンロードは行いません。

`actool`もRuntime不足で失敗する場合、切り分け用のターゲットビルドには
`EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets`を一時指定できます。その成果物によるテストは、
アセットを含む完全ビルドや配布用Archiveの検証には含めません。SDKに対応するRuntimeを
導入後、除外指定なしで検証してください。

## 機能

- **New:** 画像・日本語テキスト、移動／サイズ／回転、重なり、Undo／Redo、グリッド・スナップ、紙面表示の変換。
- **Library:** 完成BIN保存、取込、名称変更、削除、書き出し、完成画像を1レイヤーとして再編集。
- **Settings:** 白黒クリーニング、10内蔵パターン、STATUS、端末内のコピー可能な通信ログ。
- **振動による位置案内（試作）:** SettingsでONにすると、表示書き込み中の既存ACKから電源・応答の安定を短い振動で案内します。初期OFF。手順とAndroid向けの検討は[触覚案内](docs/HAPTIC_FEEDBACK.md)を参照してください。
- **URL:** HTTP(S)のNDEF書込・読み返し・Mailbox復旧。既知の未フォーマットST25DV04Kにも対応します。
- **BIN:** 白黒4,736 bytes、4階調9,472 bytes。ヘッダーなし、Androidと相互利用可能です。

4階調の作成・保存・BIN入出力は利用できますが、NFC書き込みは無効です。
現FWはEXECUTE後に60秒のRF無通信を要求し、Core NFCのセッション上限に収まりません。
4階調を黙って白黒へ変換しません。Androidで4階調表示した名刺から白黒へ戻す経路も、
独立したFull更新の給電検証が必要なため、現在は拒否します。

## 給電検証と公開制限

通常のDebug／Releaseは`Resources/HardwareValidation.json`に実測結果のある端末・OSだけ
表示書き込みを許可します。初期状態のリストは空です。編集・BIN・URL・STATUSは使用できます。
**テスト通過だけで実測リストを埋めないでください。**

`Namecard Hardware` schemeは実機で給電を測定するための専用ビルドです。
通常／一括／旧FWの更新時間に仮の8／20／8秒を使います。計測値ではありません。
4階調書込と4階調からの移行はこのschemeでも無効です。
公開用Archiveは両schemeともReleaseを使用し、実機検証の迂回フラグを含めません。

詳細は[実機試験](docs/HARDWARE_VALIDATION.md)と[配布手順](docs/DISTRIBUTION.md)を参照してください。
自動テストの結果と、この開発環境に残るビルド上の制約は[検証記録](docs/VALIDATION.md)に記載しています。

## 通信と復旧

ST25の通常速度MailboxコマンドをCore NFCの`customCommand`へ渡します。
DATAは128 bytes、ACKは32 bytes。NC v1とCRC、応答の識別・転送位置を検証します。
Mailboxの空き／ACK確認は50ms間隔です。DATAの一時エラー・ACK喪失は、残り時間を確認し、
同じフレームを最大3回（初回を含む）まで送信します。遅れて届いた一致するACKも検証して回収します。
副作用のないMB_CTRL（ST25 AD）読み取りは、一時的なRF応答エラーに限り100／200ms待って最大3回試します。
接続喪失・設定エラーはこの読取再試行の対象外です。Mailboxの内容を消費する読み取りや書き込みには適用しません。
起動・COMMIT後は1.5秒、EXECUTE後はFWのquiet指定以上、RFコマンドを止めます。
実測した更新上限＋5秒をセッション内に確保できなければ、EXECUTE前に再スキャンを案内します。

画像とACK進捗はRAMに保持し、同じUIDだけに再開します。アプリ終了後は再度画像を選択します。
START／DATA中の接続喪失では、有効なセッション内で最大6回、同じUIDのタグを再検出します。
元の60秒期限は延長せず、MCUのRAMが失われていれば画像を最初から転送します。
COMMIT以降にはこの再検出を行いません。OSがセッションを終了した場合や復旧回数を使い切った場合は、
画面から同じ名刺を再スキャンしてください。通信ログには端末識別子・OS・コマンド・ACK位置・VDD・残り秒数を残します。
EXECUTE送信後のACK喪失時は、アプリ側から電界を切らずOSのセッション終了を待ちます。
EXECUTE ACKとquiet待機後の完了確認で、一時的な通信エラー・破損フレームが出た場合は、同じ接続でSTATUSだけを
最大3回（初回を含む）確認します。quietと元の更新時間上限・セッション期限を守り、更新命令は追加しません。
接続喪失や位置不一致はこの再試行の対象外です。確認できなければ、表示は更新済みの可能性がある旨と未確認の理由を表示します。
再接続のSTATUS COMPLETEだけでは目的の画像と断定せず、安全に再転送します。
セッション終了時はCore NFCの遅れた応答を待たずにアプリ側の通信処理をキャンセルし、
後から届く応答は破棄します。転送状態の後始末が終わると、画面から再スキャンできます。
終了後は最低1秒、Core NFCが使用中（Code 203）の場合は2／4／6秒の待機を設け、再スキャンの連打を防ぎます。
この待機はアプリ側の対策であり、OSのNFCリソース解放を保証する時間ではありません。
COMMIT応答の喪失後に本体がCHARGING／READYを返した場合、STATUSだけで対象画像を判断せず、
元画像とUIDを保持して新しいTransfer IDでSTARTから清掃付き再転送します。
EXECUTE前に転送位置の矛盾を検出した場合も、次のスキャンに矛盾した再開位置を持ち越しません。

NFCシステムシートの通常の進捗表示は最大毎秒1回とし、段階変更・エラー・完了はすぐ反映します。
アプリの通常進捗は最大毎秒4回です。NFCの画面を独立させ、進捗でエディター・Library全体を再描画しません。
通信ログは引き続き全イベントを記録し、通信中は全文のライブ描画を止めます。コピーでは記録済みの全文を取得できます。

URLはPREPARE応答後だけMailboxを停止します。URL復旧記録をApplication Supportへ原子的に保存し、
未フォーマット品はCC／長さ0／本体／最終長の順に更新します。
中断後の同じUIDで書き込み予定と一致する場合だけ復旧し、未知データや保護領域は初期化しません。
静的MB_MODE、EH_MODE、パスワード、FW、基板は変更しません。

## 保存とプライバシー

Libraryはアプリ内にBIN＋JSONを保存します。編集レイヤーとUndo／Redo、クリーニング設定は
起動中だけ保持します。LibraryとURL復旧記録はOSバックアップに含まれる場合があります。
振動による位置案内のON／OFFは端末内に保存し、次回起動時にも維持します。
ユーザー操作によるFilesへの書き出し先にはiCloud等も選択できます。
[プライバシーポリシー](docs/PRIVACY.md)を参照してください。
