# NFC Namecard/Badge

NFCによる給電（Energy Harvesting）を用いた、書き換え可能な電子ペーパー / NFCタグ / マイコンと、ファームウェア、Android・iOSアプリです。

Maker Faire Tokyo 2026のブース「そうまめの部屋」で販売します。

## リポジトリ構成

- `namecard.kicad_sch` / `namecard.kicad_pcb` — KiCad回路図・基板設計
- [`production/`](production/) — Gerber、BOM、CPLなどの製造データ
- [`firmware/`](firmware/) — STM32ファームウェア
- [`client/android/`](client/android/) — Androidアプリ
- [`client/ios/`](client/ios/) — iOSアプリ（TestFlight内部テスト中・外部テスト審査待ち）
- [`iOS_development.md`](iOS_development.md) — iOS版の移植方法と開発計画

Maker Faire Tokyo 2026向けの現行製造データは[`production/v5/`](production/v5/)にあります。JLCPCBへ入稿するファイルと注意点は同ディレクトリのREADMEを確認してください。

## Androidアプリのインストール

**[最新版のAndroidアプリ（namecard.apk）をダウンロード](https://github.com/soumame/namecard/releases/download/android-main/namecard.apk)**

利用にはAndroid 8.0以降のNFC対応端末が必要です。

1. 上のリンクから`namecard.apk`をダウンロードする
2. ブラウザからのインストールが止められた場合は、表示された設定画面で今回使用したブラウザからのインストールを許可する
3. 設定画面から戻り、`namecard.apk`をインストールする
4. インストール後、必要に応じてブラウザからのインストール許可をOFFへ戻す
5. アプリを開き、画像やテキストを編集してから`NFCに書込`を選び、完了するまで名刺を端末のNFCアンテナへ固定する

アップデートするときは、最新版APKを再度ダウンロードして既存アプリの上からインストールしてください。アプリを先にアンインストールすると、Libraryに保存した画像も削除されます。

このアプリが要求するAndroid権限はNFCのみです。リリースにはAPKと一緒にSHA-256チェックサムを掲載しています。過去のバージョンと更新内容は[Releases](https://github.com/soumame/namecard/releases)で確認できます。

うまく書き込めない場合は、スマートフォンのNFCアンテナ位置を確認し、ケースを外してからもう一度お試しください。書き込み中は名刺を動かしたり、ほかのアプリへ切り替えたりしないでください。

## iOSアプリ

iOS 17以降のNFC対応iPhone向けに実装し、MameCardとしてTestFlight内部テストを開始しています。
2026-09-09に0.1.0（1）を外部テスト審査へ提出し、現在は「審査待ち」です。
まだ一般向けのインストールリンクはありません。iPhone XR／iOS 18で白黒画像・URL設定・
クリーニング・振動案内の動作報告を受けています。ほかの機種での確認と給電・時間の計測を進めます。

4階調は編集・プレビュー・保存・BIN入出力に対応しますが、iOSからの4階調NFC書き込みと、
4階調表示からの白黒移行は無効です。販売済みの基板・FWの変更は不要です。
開発・配布の手順は[iOSアプリのREADME](client/ios/README.md)を参照してください。

## 開発状況について

詳しい開発状況は[ブログ記事](https://tokumaru.work/ja/tech/maker-faire-tokyo-2026/)をご確認ください。

## Q&A

### なんでアプリがPlay Storeで公開されていないの?

- 少量製作のハードウェア向けアプリであるため、現在は署名済みAPKをGitHub Releasesで公開しています。
- ソースコードもこのリポジトリで確認できます。

### iOS版はいつ使えるの?

- 現在はTestFlight内部テスト中で、外部テストはAppleの審査待ちです。承認後に外部向けの試験配布を開始し、このREADMEへインストール導線を掲載します。実機検証後にApp Store公開を目指します。
- Apple Developer Programには登録済みです。現在の配布手順は[iOS配布ドキュメント](client/ios/docs/DISTRIBUTION.md)を参照してください。

### 1枚あたりの原価は？いくらで売るの？

- 部品の調達や製品の仕様次第ですが、30枚量産すると1枚あたり2500~3000円超えとなります。
  - たくさん発注すれば安くなるので、大量生産すれば2000~2500円くらいを狙えると考えています。
- それに自分の開発に使う道具の調達や時間を入れると、5000円くらいで売るのが妥当かなと考えています。

## ライセンス

このリポジトリで独自に作成したハードウェア設計、製造データ、ファームウェア、Android・iOSアプリ、文書は[MIT License](LICENSE)で提供します。自由に利用・改変・再配布できますが、著作権表示とライセンス表示を保持してください。

STM32Cube/CMSISやMaterial Symbolsなどの第三者著作物には、それぞれのライセンスが適用されます。詳細は[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)を確認してください。
