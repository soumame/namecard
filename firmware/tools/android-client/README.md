# Android NFC-V test client

Android Studioでこのディレクトリを開き、実機へインストールする。4736-byteの
`EPD_NATIVE_1BPP`ファイルを選択してからST25DV04Kへタッチする。

CLIで確認する場合はAndroid SDKの場所を`local.properties`へ設定して実行する。

```sh
gradle :app:assembleDebug
```

クライアントはST25DVの通常速度Mailboxコマンド（`AAh`〜`AEh`）を使う。端末の
`maxTransceiveLength`が小さい場合はDATA payloadを240 bytes未満へ自動的に縮める。
FWは可変長DATAを受理するため、転送フレーム数だけが20より増える。

`EXECUTE` ACKを読み終えた後は最低2秒間`transceive()`を呼ばず、NFC-V接続を保持
してRF電界だけを残す。画面ロックや別アプリへの切替を行わず、完了表示まで端末を
動かさないこと。

前提として、ST25DVの静的`MB_MODE=1`と`EH_MODE=0`を事前にプロビジョニングする。
このアプリは誤設定を隠さないため、静的設定やパスワードを変更しない。
