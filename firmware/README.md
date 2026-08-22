# Namecard NFC / EPD validation firmware

namecard v4（STM32G031K6、ST25DVxxKC、GDEY029T94/SSD1680）用の
立上げ・発注可否判断FW。次の段階を別ビルドで検証する。

1. `release`（EPD未接続）: MCU、自己保持、I²C、NFC Mailboxの基板単体確認
2. `external-power-self-test`: 外部3.3VでFull→全画面Partial
3. `prepare-white`: 外部3.3VでNFC試験用の全面白をFull表示
4. `nfc-fixed-one-shot`: 基板上VRESだけで固定画像を全画面Partial 1回
5. `nfc-fixed-test`: 電力不足時の切分け用に8行ずつPartial
6. `release`: Mailbox画像転送→充電→EXECUTE→全画面Partial

`release`は表示を変えないSTATUS、1-byteの内蔵`NFC OK`パターン、4,736-byteの
ネイティブ画像分割転送を同じFWで試せる。文字やレイアウトの製品レンダリングは
スマホ側で行い、MCUには汎用フォントや二枚目の画像RAMを持たせない。

v4ではTPS63900でVRESを3.3Vへ昇降圧し、全NFCビルドを
`3.20V充電完了 / 2.85V EPD ON後 / 2.80V更新直前`で統一する。
旧基板向け2.50V閾値は使用しない。

最初に必ず [ハードウェアゲート](docs/HARDWARE_GATE.md) を実施する。v4回路図では
C19とJ1の既知不具合は修正済みだが、実装基板の短絡・極性・FPC向きは別途確認する。

## Build

Arm GNU ToolchainとCMakeを使用する。コードはSTM32 HALで構成され、CubeIDEからは
既存CMakeプロジェクトとして開ける。

```sh
cd firmware
cmake --preset release
cmake --build --preset release
```

段階試験用:

```sh
cmake --preset external-power-self-test
cmake --build --preset external-power-self-test

cmake --preset prepare-white
cmake --build --preset prepare-white

cmake --preset nfc-fixed-test
cmake --build --preset nfc-fixed-test

cmake --preset nfc-fixed-one-shot
cmake --build --preset nfc-fixed-one-shot
```

生成物は各`build/<preset>/namecard_fw.{elf,hex,bin}`。リンカが次を強制する。

- アプリFlash 20KiB以下（末尾12KiBは表示画像2スロット）
- 静的RAM 7KiB以下
- ヒープ0、スタック予約1KiB以上

## VS Codeから書き込む

リポジトリのルートをVS Codeで開き、`Terminal → Run Task...`から実行する。

- `FW: Flash external-power-self-test`
- `FW: Flash prepare-white`
- `FW: Flash nfc-fixed-test`
- `FW: Flash nfc-fixed-one-shot`
- `FW: Flash release`
- `FW: Provision BOR3 (2.5V falling)`（初回に一度だけ）

Flash Taskは対応するConfigureとBuildを先に実行し、STM32CubeProgrammer CLIで
ST-Link/SWD書き込み、verify、resetまで行う。現MacではCubeProgrammerのarm64版が
NEON要件で起動しないため、TaskはUniversal Binaryのx86_64側をRosettaで起動する。

`FW: Flash nfc-fixed-test`は、外部電源で試験画像を先に更新しないよう書き込み後に
MCUをhaltする。Task完了後にST-Linkと外部3.3Vを外し、スマホのRF給電で次回起動する。
`FW: Flash nfc-fixed-one-shot`も同じ書き込み手順で、基板上の蓄電容量だけを使い、
8行分割を行わず全画面Partialを1回だけ実行する。v4の主Go/No-Go試験とする。

初回はEPDを外したままBOR Taskを実行し、`FW: Flash release`でMCU接続と
`TP6/EPD_SW=0V`を確認する。その後、電源を切ってFPCを接続し、
`FW: Flash external-power-self-test`へ進む。

## Host tests

```sh
cmake -S firmware/tests -B firmware/tests/build
cmake --build firmware/tests/build
ctest --test-dir firmware/tests/build --output-on-failure
```

純粋なフレーム生成・確認には依存ライブラリ不要のツールもある。

```sh
python3 firmware/tools/namecard_protocol.py generate \
  --test-pattern --transfer-id 0x1234 --output /tmp/namecard-frames
python3 firmware/tools/namecard_protocol.py decode /tmp/namecard-frames/00-start.bin
```

Maker Faire版の対応クライアントはAndroidのみとする。実機送信用のAndroid NFC-Vクライアントは
[`tools/android-client`](tools/android-client/README.md) にある。
iPhoneは専用Core NFCアプリでEH可能なことを確認済みだが、署名・entitlementと別の
検証工程が必要なため今回の製品サポート外とする。プロトコル自体はOS非依存のまま保つ。

4736-byteの試験画像は次で生成できる。

```sh
python3 firmware/tools/namecard_protocol.py make-image \
  --pattern nfc-ok --output /tmp/namecard-nfc-ok.bin
```

## Small-MCU product path

STM32G031K6のRAMには4,736-byte画像を1枚だけ保持し、文字描画はスマホ側で行う。
Flash先頭20KiBをFW、末尾12KiBをCRC付き6KiB×2スロットとして分離した。新画像は
EPD更新前に空きスロットへPREPARED保存し、BUSY完了後に別の64-bit COMMITTED
マーカーだけを書き込む。電源断後も旧画像と更新待ち画像を判別でき、ST25DV EEPROMの
容量には依存しない。詳細は [製品設計](docs/PRODUCT_DESIGN.md) を参照。

## Safety behaviour

- `main()`の最初、`HAL_Init()`より前にPA0/PWR_HOLDをHigh、PA6をLowにする。
- EPD電源OFF時はCS/DC/RST/SCK/MOSIをAnalog/No Pullへ戻す。
- PVD4の下降割り込みでPA6を即Low、EPD GPIOをAnalog化し、PA0保持を解放する。
- BOR3（下降約2.5V）はOption Byte Taskで設定し、PVDより下の最終保護とする。
- 画像4,736 bytesをCRC32まで検証する前にEPD電源を入れない。
- 全NFCビルドで3.20Vを100ms維持、電源ON後2.85V、更新直前2.80Vを確認する。
- 同テストでは296行を8行ずつ37回に分け、各Partialの間に再充電する。
- `nfc-fixed-one-shot`は同じ安全閾値と60秒充電待ちを使用し、全画面Partialを1回だけ行う。
- 充電待ちは同テストのみ60秒、通常版は15秒。BUSY 2秒、EXECUTE ACK読取1秒。
- 診断ビルドのPartial BUSY中はSysTickを100Hzへ落とし、20msごとにVREFINTを記録する。
- 診断OFF時はSysTickを10Hzへ落とし、BUSY EXTIを主な復帰源にする。
- SPI、BUSY、VDDの全エラー経路でDeep Sleepを試み、PA6をLowへ戻す。
- 更新中は20msごとのVREFINT測定で最低VDDを保持する。

プロトコル仕様は [PROTOCOL.md](docs/PROTOCOL.md)、実機手順と合格条件は
[TEST_PLAN.md](docs/TEST_PLAN.md) を参照。

## EPD driver scope

独自LUTは含まない。SSD1680のOTP Mode 1（Full）とMode 2（Partial）を
`0x22/0x20`で選択する。初期化値はGDEY029T94/SSD1680仕様表の標準シーケンスに
基づく。Mode 2の前には、現在の表示を旧画像RAM `0x26`、更新後画像をBW RAM
`0x24`へ設定する。外部電源セルフテストはFull表示したチェック柄を旧画像として
使い、Good Displayデモと同じくPartial直前にハードウェアResetとBorder Waveform
`0x80`を適用する。NFC固定画像ビルドは出荷時の表示が全面白である前提で、`0x26`を白に初期化する。
通常版はFlashにCOMMITTED保存された旧画像を`0x26`へ転送する。Good Display配布
STM32アーカイブはこの環境では取得できなかったため、量産前に
同アーカイブと`0x3C`、`0x21`を含む初期化値を再照合すること。
