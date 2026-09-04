# NFC Namecard/Badge

NFCによる給電（Energy Harvesting）を用いた、書き換え可能な電子ペーパー / NFCタグ / マイコンと、ファームウェア、Androidアプリです。

Maker Faire Tokyo 2026のブース「そうまめの部屋」で販売します。

## リポジトリ構成

- `namecard.kicad_sch` / `namecard.kicad_pcb` — KiCad回路図・基板設計
- [`production/`](production/) — Gerber、BOM、CPLなどの製造データ
- [`firmware/`](firmware/) — STM32ファームウェア
- [`client/android/`](client/android/) — Androidアプリ
- [`iOS_development.md`](iOS_development.md) — iOS版の移植方法と開発計画

Maker Faire Tokyo 2026向けの現行製造データは[`production/v5/`](production/v5/)にあります。JLCPCBへ入稿するファイルと注意点は同ディレクトリのREADMEを確認してください。

## Androidアプリのインストール

**[最新版のAndroidアプリ（namecard.apk）をダウンロード](https://github.com/soumame/namecard/releases/download/android-main/namecard.apk)**

利用にはAndroid 8.0以降のNFC対応端末が必要です。現在、このリポジトリからiOSアプリは提供していないため、iPhoneから表示内容を書き換えることはできません。iOS版の技術的な見通し、作り方、開発計画は[iOSアプリの開発方法と計画](iOS_development.md)にまとめています。

1. 上のリンクから`namecard.apk`をダウンロードする
2. ブラウザからのインストールが止められた場合は、表示された設定画面で今回使用したブラウザからのインストールを許可する
3. 設定画面から戻り、`namecard.apk`をインストールする
4. インストール後、必要に応じてブラウザからのインストール許可をOFFへ戻す
5. アプリを開き、画像やテキストを編集してから`NFCに書込`を選び、完了するまで名刺を端末のNFCアンテナへ固定する

アップデートするときは、最新版APKを再度ダウンロードして既存アプリの上からインストールしてください。アプリを先にアンインストールすると、Libraryに保存した画像も削除されます。

このアプリが要求するAndroid権限はNFCのみです。リリースにはAPKと一緒にSHA-256チェックサムを掲載しています。過去のバージョンと更新内容は[Releases](https://github.com/soumame/namecard/releases)で確認できます。

うまく書き込めない場合は、スマートフォンのNFCアンテナ位置を確認し、ケースを外してからもう一度お試しください。書き込み中は名刺を動かしたり、ほかのアプリへ切り替えたりしないでください。

## 開発状況について

詳しい開発状況は[ブログ記事](https://tokumaru.work/ja/tech/maker-faire-tokyo-2026/)をご確認ください。

## Q&A

### なんでアプリがPlay Storeで公開されていないの?

- 少量製作のハードウェア向けアプリであるため、現在は署名済みAPKをGitHub Releasesで公開しています。
- ソースコードもこのリポジトリで確認できます。

### なんでiOS版は作成されていないの?

- AppleのCore NFCは、この名刺で使うISO 15693タグとメーカー独自コマンドに対応しています。STMicroelectronicsもST25DV向けのiOS実装例を公開しているため、技術的には実現できる可能性が高いと考えています。ただし、この基板と独自通信プロトコルを使ったiPhone実機検証はまだ行っていません。
- XcodeとSimulatorを使い、画面や画像変換などNFC以外の部分を開発するだけなら無料で始められます。ただし、Core NFCを有効にしたアプリをiPhoneへ署名・インストールして実機検証するには`Near Field Communication Tag Reading`のCapabilityが必要で、無料のPersonal Teamでは利用できません。年間99 USD（または地域ごとの価格）のApple Developer Programへの加入が必要です。App StoreやTestFlightでの配布にも同じ加入が必要なため、現在は主に予算の都合からiOS版を作成・公開していません。
- 移植方法と段階的な計画は[iOSアプリの開発方法と計画](iOS_development.md)を参照してください。
- iOS版を実装または実機検証できた方は、Pull Requestに加えて[https://tokumaru.work](https://tokumaru.work)からご連絡ください。

### 1枚あたりの原価は？いくらで売るの？

- 部品の調達や製品の仕様次第ですが、30枚量産すると1枚あたり2500~3000円超えとなります。
  - たくさん発注すれば安くなるので、大量生産すれば2000~2500円くらいを狙えると考えています。
- それに自分の開発に使う道具の調達や時間を入れると、5000円くらいで売るのが妥当かなと考えています。

## ライセンス

このリポジトリで独自に作成したハードウェア設計、製造データ、ファームウェア、Androidアプリ、文書は[MIT License](LICENSE)で提供します。自由に利用・改変・再配布できますが、著作権表示とライセンス表示を保持してください。

STM32Cube/CMSISやMaterial Symbolsなどの第三者著作物には、それぞれのライセンスが適用されます。詳細は[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)を確認してください。
