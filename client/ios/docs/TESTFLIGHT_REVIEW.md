# MameCard：TestFlight外部テストの登録資料

対象は`0.1.0 (1)`（2026-09-08アップロード）です。App Store Connectの登録名は
`MameCard`、ホーム画面の表示名は`Namecard Beta`、Bundle IDは`work.tokumaru.namecard`です。
内部テストでのインストール・利用についてユーザーから成功報告を受けています。
2026-09-09に外部グループ「名刺ユーザーテスト」へ追加し、ベータ版App Reviewへ提出しました。
App Store Connectで`0.1.0 (1)`の「審査待ち」を確認済みです。
外部テスターは0人、テスターへの自動通知はOFFで、招待リンクはまだ作成していません。

## 入力先と準備状況

App Store Connect → MameCard → TestFlight → テスト情報へ入力します。

| 項目 | 内容・状態 |
| --- | --- |
| ベータ版アプリの説明 | 下記の日本語原稿を保存済み |
| フィードバックメールアドレス | 所有者の指定値を保存済み。再読込後の画面で確認 |
| マーケティングURL | `https://github.com/soumame/namecard`を保存済み |
| プライバシーポリシーURL | `https://github.com/soumame/namecard/blob/main/client/ios/docs/PRIVACY.md`を保存済み |
| 審査連絡先の姓・名・電話番号・メール | 所有者の指定値を保存済み。電話番号は国際形式に正規化し、再読込後の画面で確認 |
| サインインが必要です | OFF。アプリにアカウント機能はない |
| 審査メモ | 下記の英語原稿を保存済み。基板送付不可と、確認済みのiPhone版実演動画URLを記載 |
| ビルドごとの「テスト内容」 | `0.1.0 (1)`に登録済み。原稿は下記 |
| 審査用の実演動画 | iPhone版の白黒書き込み動画を受領。2026-09-09にログイン不要の取得と映像内容を確認済み（約30秒、下記参照） |
| 審査用基板の送付 | 提供しない（2026-09-09に所有者の方針を確認済み）。iPhone版の実演動画で審査を依頼 |
| 外部テストグループ | 名刺ユーザーテスト（`19cb5ac1-9c2d-4198-8abd-c4c051b8dce2`） |
| ベータ審査 | 2026-09-09提出。`0.1.0 (1)`は「審査待ち」 |
| 自動的にテスターに通知 | OFF。承認後の配布開始時に案内する |

連絡先の実値はこの公開リポジトリへ書きません。電話番号は国番号を含めて入力します。
上記の保存状況と提出結果は2026-09-09に登録画面で確認したものです。
今後この原稿を変更した場合、App Store Connectにも反映して保存を確認してください。

## 基板を送付しない審査方針

Appleの[App Review案内](https://developer.apple.com/app-store/review/)には、特殊な環境や
ハードウェアが必要な機能について、実演動画またはハードウェアを用意する旨が記載されています。
[App Review担当者の案内](https://developer.apple.com/forums/thread/810791)も、実際のApple端末と
接続先ハードウェアの双方を映した動画を求めています。

基板は送付せず、提出するTestFlightビルドをiPhoneで動かす実演動画と操作説明を用意して審査を依頼します。
編集・Library・BIN入出力は審査担当者の端末だけで確認できます。既存のAndroid版動画を使う場合は
「Android版の補足資料」と明記し、iOS版の動作証拠にはしません。
動画で承認されるかは個別審査によります。現物を求められても送付を約束せず、追加動画や説明で
審査できるか確認します。基板の提供可否は確認済みであり、提出準備の未回答項目には戻しません。

## ベータ版アプリの説明（日本語）

```text
MameCardは、NFC給電で動作する専用の電子ペーパー名刺基板の画像とURLを書き換えるアプリです。名刺への書き込みには対応する名刺基板と、iOS 17以降のNFC対応iPhoneが必要です。販売済み基板のファームウェアを変更せずに利用できます。

「New」で写真や日本語テキストを配置し、296×128の名刺画像を作成できます。移動・拡大縮小・回転、重なり順の変更、Undo／Redo、グリッドとスナップに対応します。

作成した完成画像は「Library」に保存でき、名称変更、再書き込み、BINファイルの取込・書き出しができます。BINはAndroid版と交換できます。編集・保存・BIN入出力は基板がなくても利用できます。

白黒画像の書き込み、書き換え前のクリーニング、内蔵パターン、URL設定、STATUS確認と通信ログを利用できます。書き込み中はiPhoneの上端と名刺のアンテナを重ね、アプリが完了を表示するまで固定してください。端末や当て方によって通信が中断する場合があります。再スキャンの案内が出たら同じ名刺で再開します。

4階調は編集・プレビュー・保存・BIN入出力のみ対応します。このベータ版では4階調のNFC書き込みと、4階調表示済みの名刺から白黒へ戻す操作は利用できません。

画像・テキスト・URLは端末内で処理します。アプリのアカウント登録、広告、課金はありません。ホーム画面には「Namecard Beta」と表示されます。
```

## ビルド0.1.0 (1)のテスト内容（登録済み）

```text
初回TestFlightビルドです。販売済みの電子ペーパー名刺基板と、iOS 17以降のNFC対応iPhoneでお試しください。FWの変更は不要です。

確認してほしい内容
・画像と日本語テキストの作成、Libraryへの保存・再起動後の読込
・Files経由でのBIN取込と書き出し、AndroidとのBIN交換
・白黒画像の書き込み、クリーニングON／OFF、内蔵パターン、URL設定
・切断後に同じ名刺を再スキャンして復帰できること
・Settingsで振動による位置案内をONにしたときの案内

異なる白黒画像A／Bを交互に書き込み、アプリが完了を表示するまで名刺をiPhoneのNFCアンテナ位置に固定してください。表示が変わっても確認保留やエラーになった場合は、その状態を報告してください。

4階調は編集・プレビュー・保存・BIN入出力のみ対応します。4階調のNFC書き込みと、4階調表示済みからの白黒更新は対象外です。

報告にはiPhone機種、iOSバージョン、名刺の基板版、操作、所要時間、切断回数、エラー文を添えてください。通信ログはSettingsからコピーできます。個人情報を含む画像やURLは共有前に確認してください。
```

## 審査メモ（英語）

日本語UIのため、操作に必要なボタン名を原文のまま併記しています。
下記の本文には、確認済みのiPhone版実演動画URLを含めています。
全体がApp Store Connectの4,000文字以内に収まることを確認してください。

```text
MameCard 0.1.0 (1) is a companion app for our dedicated NFC-powered electronic-paper business card. Its Home Screen name is "Namecard Beta". The app UI is in Japanese; relevant labels are included below.

Hardware: NFC operations require an NFC-capable iPhone running iOS 17 or later and our compatible business-card board (ST25DV04K, STM32G031K8, SSD1680, 296 x 128 display). An ordinary NFC sticker cannot perform the display functions. The board is powered by the iPhone's NFC field; no pairing, battery, USB connection, or firmware update is required for normal use.

Hardware samples are not available for shipment. We request review using an iPhone demonstration video together with the hardware-independent app features listed below.

iPhone hardware demonstration (about 30 seconds; no login required):
https://i.gyazo.com/e6c6b81a9c74d2d1046a03b21bc5fbc5.mp4
The video shows the app's "Test" text and apple image, NFC writing with the iPhone held over the card, the completion message near the end, and the resulting black/white image on the physical display. It demonstrates image writing; URL setup is described below.

No app login, demo credentials, subscriptions, in-app purchases, or backend services are required. Image editing and Library/file operations can be reviewed without the board. Processing and app storage are local; the app does not upload images, URLs, or logs to a developer server. The privacy-policy link opens the public GitHub page.

Without hardware:
1. Open New. Use the top-left image format selector to select "ドット密度" (black/white dithering).
2. Tap "テキスト", enter "HELLO", then "追加". Drag the text; use two fingers to resize or rotate. "写真" imports a selected photo. The tools row scrolls horizontally.
3. Open the top-right ellipsis menu. "プレビュー" previews the result; "Libraryに保存" saves a named finished image; "BINを書き出す" exports a file.
4. Open Library to view the saved card. "編集" opens its finished image as one layer. The card's ellipsis menu provides rename, export, delete and NFC write. The top-right import button accepts Android-compatible BIN files (4,736-byte black/white or 9,472-byte four-gray).

With the compatible board:
1. Start with a card displaying a black/white image. In Settings, tap "STATUS確認" to open the system NFC sheet, then align the iPhone's upper edge with the card antenna. This reads device status.
2. In New, create a black/white image and tap "名刺に書き込む". Keep the card steady at the iPhone's upper edge until the app reports completion. Settings > "書き換え前のクリーニング" enables the default white/black/white cleaning sequence before the new image. Brief panel flashes are expected.
3. In Settings, choose "1. チェック柄" under "内蔵パターン" and tap "選択パターンを書込" to test a built-in pattern.
4. In New, tap "URL" in the tools row, enter https://example.com, then tap "書き込む" and scan. The app writes the NDEF URL and verifies it by reading it back. This changes the card's URL, not its displayed image.

If communication is interrupted, follow "同じ名刺で再スキャン" in the progress view, or "前回の操作を再開" in Settings. Reuse the same card and keep the app running while resuming. An incomplete URL operation uses Settings > "URL設定を再開". Do not treat a changed panel alone as confirmation if the app reports an unconfirmed result.

Four-gray editing, preview, saving and BIN import/export are available. Four-gray NFC writing and conversion of an already four-gray physical display to black/white are deliberately unavailable in this beta. Use a black/white card for NFC tests. Settings also offers optional vibration guidance and a communication log.
```

## 確認済みの実演動画

動画URL: [iPhoneと名刺基板の白黒書き込み実演](https://i.gyazo.com/e6c6b81a9c74d2d1046a03b21bc5fbc5.mp4)

2026-09-09にCookieや認証を付けずHTTP 200で取得でき、形式はMP4、長さは約29.6秒でした。
確認した内容は、iPhone版New画面の「Test」とリンゴの画像、実物のiPhoneを名刺へ重ねたNFC操作、
終盤の「処理完了しました」の表示、名刺に表示された同じ白黒画像です。
動画だけではビルド番号を確認できず、URL設定・Library操作は映っていません。
これらを実演済みとは記載せず、審査メモでは白黒書き込みの動画として案内します。

元動画は約253 MiBです。取得は成功していますが、回線によって読み込みに時間がかかる場合は
内容や待機時間を変えない圧縮版を用意し、公開URLを改めて確認できます。
動画ファイル自体はリポジトリへ追加しません。審査中はURLを削除・非公開化しないでください。

## 追加の実演動画が必要になった場合の撮影手順

以下は追加説明が必要になった場合の撮影用台本です。3〜5分程度を目安にし、
実際の更新待ち時間を省略せず撮影します。尺はAppleの規定として指定したものではありません。
画面収録だけでは名刺の変化が見えないため、別のカメラでiPhoneと名刺を同時に写します。
Pixelを撮影用カメラに使って構いません。実演するアプリはiPhoneのTestFlightから起動します。

| 順番 | 撮影する操作 | 見えるようにするもの |
| --- | --- | --- |
| 1 | TestFlightのMameCard 0.1.0 (1)からアプリを開く | バージョン・ビルド番号、実際のiPhone機種・iOS、使用する名刺基板 |
| 2 | Newで「テキスト」→「HELLO」→「追加」。位置・大きさを調整 | 日本語UIと編集操作 |
| 3 | 「保存とプレビュー」メニューからLibraryに保存 | Libraryに完成画像が残ること |
| 4 | 白黒の名刺へ「名刺に書き込む」。クリーニングはON | 当てる位置、NFCシート、進捗、全更新過程、アプリの完了表示と名刺の新しい画像 |
| 5 | NewのURLから`https://example.com`を書き込む | URL入力とアプリの完了表示 |
| 6 | Settingsでチェック柄を書き込む | 画像転送後も別の書き込みができ、名刺がチェック柄になること |
| 7 | Newの画像方式を4階調へ変更 | プレビュー・保存は可能で、NFC書き込みは説明付きで無効になること |

最初の名刺は白黒表示済みのものを使用します。動画で個人の写真・連絡先・実際のURLを
使う必要はありません。失敗した場合は成功したように編集せず、アプリの再スキャン案内に
沿った復帰過程も含めるか、その試行を別途説明します。

完成した動画は、Appleの審査担当者がログインやアクセス申請なしで開けるURLを用意し、
審査メモへ追加します。実機・提出ビルドの動作を記録するもので、Simulatorや合成動画を
NFC動作の証拠として扱いません。基板を送付しない方針と動画URLを審査メモに記載して提出し、
追加資料が求められた場合はその内容に応じて対応します。

## 残りの作業

1. ベータ審査の結果を確認する。追加説明や動画が求められた場合は対応する。基板は送付しない。
2. 承認後に外部テストの配布を開始し、招待リンクを作成する。自動通知はOFFのため、配布開始の操作も確認する。
3. iPhone・iOS 17以降に合わせた募集条件と、専用基板が必要なことを案内する。
4. 利用可能なリンクを確認できてからREADMEへ掲載する。

この提出はTestFlight外部テスト用です。App Store向けReleaseの
[実機検証条件](HARDWARE_VALIDATION.md)を満たしたことにはなりません。

## Appleの参照資料

- [テスト情報の入力](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/): ベータ説明、フィードバック先、審査情報。
- [外部テスターの招待](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/): グループ作成、初回ビルドの審査、承認後の招待。
- [App Review案内](https://developer.apple.com/app-store/review/): 特殊なハードウェアを使う機能の実演動画またはハードウェアの準備。
- [App Review担当者のTips](https://developer.apple.com/forums/thread/810791): Apple実機と接続先ハードウェアを一緒に映す動画。
- [審査前の準備](https://developer.apple.com/app-store/review/guidelines/#before-you-submit): 審査に必要なハードウェア・資料へのアクセス。
