# Namecard NFC / EPD validation firmware

STM32G030K6、ST25DV04K、GDEY029T94（SSD1680）用の発注可否判断FW。
製品FWではなく、次の3段階を別ビルドで検証する。

1. `external-power-self-test`: 外部3.3VでFull→全画面Partial
2. `prepare-white`: 外部3.3VでNFC試験用の全面白をFull表示
3. `nfc-fixed-test`: NFC継続給電だけで生成済み固定画像を8行ずつPartial
4. `nfc-fixed-one-shot`: 外付け蓄電容量を使い、固定画像を全画面Partial 1回で更新
5. `release`: Mailbox画像転送→充電→EXECUTE→全画面Partial

現行基板の実測では`V_EH_RAW`が約2.8V、`SYS_VDD`が2.5～2.7Vだったため、
`nfc-fixed-test`だけは成立性確認用に2.50V/2.30V/2.25Vの低電圧閾値を使用する。
さらに8行ずつPartial更新し、各帯の間でEPD電源を切って再充電する。
`release`は2.95V/2.85V/2.80Vの保守的な閾値を維持する。

最初に必ず [ハードウェアゲート](docs/HARDWARE_GATE.md) を実施する。現行回路データには
TPS22917のC19接続に停止条件が見つかっており、未リワークでのEPD試験は禁止する。

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

- Flash 28KiB以下
- 静的RAM 7KiB以下
- ヒープ0、スタック予約1KiB以上

## VS Codeから書き込む

リポジトリのルートをVS Codeで開き、`Terminal → Run Task...`から実行する。

- `FW: Flash external-power-self-test`
- `FW: Flash prepare-white`
- `FW: Flash nfc-fixed-test`
- `FW: Flash nfc-fixed-one-shot`
- `FW: Flash release`

Flash Taskは対応するConfigureとBuildを先に実行し、STM32CubeProgrammer CLIで
ST-Link/SWD書き込み、verify、resetまで行う。現MacではCubeProgrammerのarm64版が
NEON要件で起動しないため、TaskはUniversal Binaryのx86_64側をRosettaで起動する。

`FW: Flash nfc-fixed-test`だけは、外部電源で試験画像を先に更新しないよう書き込み後に
MCUをhaltする。Task完了後にST-Linkと外部3.3Vを外し、スマホのRF給電で次回起動する。
`FW: Flash nfc-fixed-one-shot`も同じ書き込み手順で、8行分割を行わず全画面Partialを
1回だけ実行する。外付け4個の330uFを接続した最終Go/No-Go判定用とする。

最初は必ず`FW: Flash external-power-self-test`を選ぶ。C19とFPCのハードウェア
ゲートが未確認の状態ではFlash Taskを実行しない。

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

実機送信用の最小Android NFC-Vクライアントは
[`tools/android-client`](tools/android-client/README.md) にある。

## Safety behaviour

- `main()`の最初、`HAL_Init()`より前にPA6をLowにする。
- EPD電源OFF時はCS/DC/RST/SCK/MOSIをAnalog/No Pullへ戻す。
- 画像4,736 bytesをCRC32まで検証する前にEPD電源を入れない。
- `release`では2.95Vを100ms維持、電源ON後2.85V、更新直前2.80Vを確認する。
- `nfc-fixed-test`では現行基板の成立性確認に限り2.50V/2.30V/2.25Vを使用する。
- 同テストでは296行を8行ずつ37回に分け、各Partialの間に再充電する。
- `nfc-fixed-one-shot`は同じ低電圧閾値と60秒充電待ちを使用し、全画面Partialを1回だけ行う。
- 充電待ちは同テストのみ60秒、通常版は15秒。BUSY 2秒、EXECUTE ACK読取1秒。
- 同テストのPartial BUSY中はADC診断を止め、SysTickを10Hzへ落としてWFIする。
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
`0x80`を適用する。NFC検証ビルドは出荷時の表示が全面白である前提で、`0x26`を白に初期化する。
任意の表示から連続して書き換える製品版では、旧画像を不揮発領域へ保持する必要が
ある。Good Display配布STM32アーカイブはこの環境では取得できなかったため、量産前に
同アーカイブと`0x3C`、`0x21`を含む初期化値を再照合すること。
