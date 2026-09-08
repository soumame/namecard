# 位置合わせの触覚案内・試作

2026-09-08。iPhone側の短い振動で、既存ACKから推定した電源・通信の安定を案内します。
初回のUIKit版は「書き込み中に振動しない。試す設定は確認済み」との報告を受けました。
試すボタンでの実出力と、書き込み時の判定・再生要求のログは未取得です。
Core Hapticsへ変更し、起動・再生エラーと判定の診断を追加しました。
変更後、ユーザーから書き換え・振動とも正しく動作したとの報告を受けました。
OFF／ON比較の回数・時間・電圧ログは未取得です。併せて報告されたテキスト操作時の約3秒のHangは
[別途切り分け中](PERFORMANCE.md)です。
距離計、RSSI、EPD更新成功の判定ではありません。
公開用の給電検証結果には含めません。

## 試し方

1. `Namecard Hardware` schemeでiPhone XRへビルドします。
2. Settings →「振動による位置案内（試作）」→「振動で位置を案内」をONにします。初期状態はOFFで、設定は端末内に保存します。
3. 「安定時の振動を試す」で短い合図を確認します。Simulatorなどの非対応環境では無効です。
4. 白黒画像を書き込み、NFCシート表示中にも振動を感じるか確認します。
   弱い短い振動から、条件が揃うとはっきりした短い合図になります。その位置を維持してください。
   合図は通信状態の目安であり、書き込み完了の合図ではありません。
5. 同じ画像・位置・清掃設定でOFF／ONを各3回比較し、所要時間、切断・復帰、アプリと表示の完了、振動の有無を記録します。
   Settingsログの「触覚案内」にはON／OFF、端末対応、判定、再生要求、エンジン結果を残します。
6. DATA中の切断では振動が止まり、同じ名刺への再検出後に新しい応答から案内を再開するか確認します。
   EXECUTE以降、完了確認保留、キャンセル、背景移行、セッション終了後に案内が続かないことを確認します。

NFCシート外の試し振動だけ成功し、通信中に振動しない場合は、その違いを記録してください。
APIの対応判定・呼出し成功は実際の振動を保証しません。システム設定やNFCシートとの共存は実機で確認します。
通信への影響が分かるまでは試作の初期OFFを維持します。

## 振動しない場合のログ

Settingsの通信ログから「触覚案内」の行を保存します。

- `判定=weak ... 応答=900ms ... 再生要求=0`など: 電圧・応答時間・直近のエラーによる抑止です。
- `再生要求 #...`がある: アプリの判定は振動を要求しています。
- `CoreHaptics 起動失敗`／`再生失敗`／`stopped reason=...`／`reset`: エンジン側のエラーや中断です。
- `CoreHaptics 再生開始`があるのに感じない: APIで再生開始は受理されていますが、実出力の証明にはなりません。
  NFCシート外の試すボタンとの差を記録します。
- `案内終了: 再生要求=...`は接続ごとの合計です。`app=active/inactive/background`でその時点のアプリ状態も確認できます。

UIKitの触覚APIはシステムが出力を判断するため、呼び出しただけでは振動を確認できません。
NFCシートが今回の原因と断定せず、API起動・判定・実際の感触を分けて評価します。
[Appleの触覚出力の説明](https://developer.apple.com/documentation/applepencil/playing-haptic-feedback-in-your-app)を参照しました。

## 入力と暫定判定

`LinkFeedback`は副作用のないSwiftの状態判定、`NFCHapticGuide`は設定・寿命・診断、`CoreGuideHaptics`は振動出力を担当します。
`FeedbackMailbox`が既存通信を1対1で包み、EXECUTEを送る前に案内を止めます。
新しいNFCコマンド、待機、再試行は追加しません。DATAは128 bytesのままです。

| 条件 | 案内 |
|---|---|
| 0mV、応答なし、最後の有効応答から1.5秒以上 | 応答待ち、振動なし |
| 3050mV未満、応答800ms以上、通信失敗後2秒以内 | 不安定、振動なし |
| 上記以外で3200mV未満または応答350ms以上 | 軽いパルス、最短1.2秒間隔 |
| 3200mV以上かつ応答350ms未満 | 安定確認中、最短0.75秒間隔 |
| 強い条件のACKが3回以上、0.5秒以上継続 | はっきりした合図を1回、その後は最短2秒間隔の軽いパルス |
| COMMIT、quiet指定のあるACK | 古い測定値を破棄し、振動停止 |
| EXECUTE送信前、またはFWのEXECUTE_ACK／REFRESHING | 更新中。以降のSTATUSがREADYでも案内を再開しない |

数値は既存の通信状態表示を基にした暫定値です。3.3Vの電圧だけからRF電界や余剰電力を判断しません。
最低VDD・EH制御値は診断用に残し、今回の振動判定には使いません。加速度・ジャイロも未使用です。
START／PATTERNで次の処理を始める場合だけ更新中の抑止を解除し、新しい測定から判定します。
接続IDを照合し、以前の接続の遅れた応答は案内を再開できません。

振動はCore Hapticsの`hapticTransient`による有限のパルスです。
強度はgentle=0.25、approaching=0.45、locked=0.65で、実際の感触は端末・OSに依存します。
sharpnessはgentle／approaching=0.3、locked=0.7です。旧UIKit版と同じ感触になるとは仮定しません。
エンジンは非同期に起動し、2秒の起動タイムアウト・接続ごと最大3回の起動試行を設けます。
起動待ち中の要求は0.5秒で失効します。EXECUTE・COMMIT・不安定・古い応答では予約済みの振動も破棄します。
設定OFF・背景移行・セッション終了時はエンジンを停止し、古い起動通知からの再生を拒否します。
試すボタンの後は3秒でエンジンを停止します。音声イベントやバックグラウンド動作は追加しません。
Core Hapticsの`supportsHaptics`で対応判定します。NFCシートに独自グラフィックは追加せず、
アプリの進捗画面には案内状態と「最後の応答」を表示します。
以前の、時刻を考慮せず残った電圧だけから「良好」と表示する処理は置き換えました。

API資料: [Core Hapticsの起動と中断](https://developer.apple.com/documentation/corehaptics/preparing-your-app-to-play-haptics)、
[Core Haptics対応判定](https://developer.apple.com/documentation/corehaptics/chhapticengine/capabilitiesforhardware())。

## 自動検証

共通57件（触覚判定8件を追加）、アプリ単体32件（寿命・接続ID・通信の転送4件を追加）、既存UI5件が成功しました。
Core Hapticsへの変更後は、追加の6件を含むアプリ単体38件が成功しています。
起動中の取消し、古いエンジン通知の拒否、古い振動要求の破棄、失敗・再起動上限・診断ログを検証しました。
共通57件とUI5件は初回試作時の結果です。
Simulator向けDebugと署名なし実機向けHardwareTestの検証用ビルドも成功しています。
アセット除外などローカル環境の制約は[検証記録](VALIDATION.md)を参照してください。
これらの試験は、振動の感触やRF給電への影響を検証したものではありません。

## Androidへ追加する場合

今回のAndroid作業は実コードとAPIの確認のみです。アプリへの振動追加は未実施です。

- `St25Mailbox.onExchangeResult`にACK・応答時間・要求種別があり、`MainActivity.observeNfcLink`と
  `WriteProgress.kt`に通信状態の表示が実装されています。同じ値で今回の判定をKotlinへ移植できます。
- 既存の通知箇所はACKのdecode直後です。振動へ使う前に、対象要求との対応・転送位置・FW成功応答を検証する必要があります。
  EXECUTEはACK受信時ではなく送信前に抑止し、画像・内蔵パターン・一括／旧FW清掃・4階調のすべての経路を扱います。
- UI用の短い振動は`View.performHapticFeedback`と既定のtick／確認用の効果が候補です。
  特別な権限は不要で、システムの触覚設定を尊重します。現在のManifestにはVIBRATE権限はありません。
- 強度を直接制御する方式ではVIBRATE権限と`hasAmplitudeControl()`の確認が必要です。
  Pixel 9 ProとPOCO X3 NFCの実機能力は未取得です。強度制御がなければ短い既定効果の間隔で区別し、
  小さい振幅の指定が最大振幅として再生される方式をそのまま採用しません。
- Reader Modeの進捗は既存のCompose画面で表示するため、アニメーションや位置図の追加もしやすい構成です。
  現コードはAndroid 14以降の`getNfcAntennaInfo()`による位置表示も実装済みです。
  APIはnullになり得るため、Pixel／POCOが実際に座標を返すか確認します。これは静的なアンテナ位置で、RSSIではありません。
- 既存のReader Mode復旧・接続所有者の世代判定に合わせて振動タスクを終了し、背景移行・切断・完了後の残留振動を防ぎます。
  iOSと同じく応答の鮮度を管理し、4階調の長い無通信時間中にも測定や「良好」のパルスを追加しません。

Android API資料: [触覚APIと能力判定](https://developer.android.com/develop/ui/views/haptics/haptics-apis)、
[UIイベントの触覚](https://developer.android.com/develop/ui/views/haptics/haptic-feedback)、
[NFCアンテナ位置](https://developer.android.com/reference/android/nfc/NfcAdapter#getNfcAntennaInfo())。
