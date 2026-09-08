# テキスト操作時のHang切り分け

2026-09-08、iPhone XR／iOS 18で触覚案内・画像書き込みの成功報告と、
テキスト書き込み時などの約3秒のHang報告を受けました。
入力中・追加確定・NFC開始のどの段階か、初回限定か、デバッガなしでも再現するかは未確認です。
SwiftUI、キーボード、画像処理、触覚出力のいずれが原因かはまだ特定していません。

## 実機での確認

1. まずXcodeの実行を停止し、iPhoneのホーム画面から同じアプリを起動します。
   テキスト欄を初めて開くとき、入力中、「追加」、「名刺に書き込む」を区別し、
   2回目も同じ位置で止まるか確認します。デバッガの有無で変わるかの比較であり、
   デバッガが原因だと仮定する手順ではありません。
2. 再現する場合はInstrumentsのTime ProfilerとHangsで記録し、停止区間のMain Threadを確認します。
   メインスレッドが計算しているのか、キーボードなどのシステム呼出しを待っているのかも確認します。
   CPU使用率が低くても待機によるHangの可能性があります。
3. `os_signposts`の`jp.namecard.ios`／`Performance`を合わせて確認します。
   文字列・画像・URL・UIDは計測ログに含めません。

## 追加した計測

同期処理を`PerformanceTrace`で囲み、100ms以上の場合のみOSログへ次の形式で記録します。
XcodeコンソールまたはmacOSのConsoleで`[Performance]`を検索してください。
SettingsのNFC通信ログとは別です。

```text
[Performance] Editor.draw 312ms main=true
```

これは形式を示す例であり、実測値ではありません。

| 名前 | 測定範囲 |
| --- | --- |
| `TextEntry.requestFocus` / `keyboardWillShow` / `keyboardDidShow` | 入力フォーカス要求・キーボード通知の時点（区間の長さではない） |
| `TextEntry.confirm` | 入力の確定、呼出元処理、dismiss要求まで |
| `Editor.addText` | テキストレイヤー追加（後続の画面描画は含まない） |
| `Editor.draw` | キャンバス／書き出しの描画・フォント計測 |
| `Editor.renderBIN` | 描画・画素抽出・BIN変換全体 |
| `Editor.decodeBIN` | Library・プレビューなどのBIN画像化 |
| `Editor.normalizeImage` | 読み込んだ画像の向き・サイズ・透過・グレースケール処理 |
| `Library.save` / `Library.reload` | 完成BINの保存とLibrary再読込 |
| `Haptics.init` / `requestStart` / `play` / `cancelPlayback` / `stop` | Core Hapticsの同期API呼出し部分（非同期の起動・停止完了待ちは含まない） |

区間は入れ子になるため、時間を合算しません。例えば`renderBIN`は`draw`を含みます。
短い処理の連続や計測範囲外のOS処理でもHangは起こり得るため、ログが出ないことはHangがない証拠ではありません。
NFCのACK・quiet待機は非同期であり、この計測の対象には含めません。

## コードを確認した時点で分かっていること

- 入力欄はローカルな`@State`を使い、1文字ごとに画像変換・NFC送信は行いません。
- 描画・BIN変換・画像正規化・Library読込は現在メインスレッドで行います。
  特に大きい画像や多数の保存カードは実測が必要です。
- 触覚エンジンの起動完了待ちは非同期ですが、初期化・プレイヤー作成等のAPI呼出し自体は同期です。
  非同期起動だけを理由に、全工程でメインスレッド停止がないとは断定できません。
- この変更は計測追加です。約3秒の実機Hangの再現・修正完了を示すものではありません。

参照: Appleの[応答性改善](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)、
[Hangの理解](https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app)、
[OSSignposter](https://developer.apple.com/documentation/os/ossignposter)。
