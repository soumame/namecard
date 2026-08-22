# Hardware gate — namecard v4

FWを書き込む前に、実装済み基板そのものを確認する。v4回路図では旧版の
`C19のCT接続`と`BS1/VSH2`入替えは修正済みなので、部品を外すリワークは不要。
ただしPCBAの実装不良やFPC向きは回路図チェックでは検出できない。

## 1. 無通電チェック

EPD、ST-Link、スマホを外す。TP7をGNDとして次を抵抗レンジで測定し、2枚を比較する。

| 測定点 | Net | 判定 |
|---|---|---|
| TP3 | V_EH_RAW | GNDへ固定短絡しない |
| TP10 | VRAW | GNDへ固定短絡しない |
| TP1またはTP11 | VRES_3V3 | GNDへ固定短絡しない |
| TP8 | SYS_VDD | GNDへ固定短絡しない |
| TP6 | EPD_SW | GNDへ固定短絡しない |

1.65mFのVRES容量があるため、測定開始時の抵抗が低く、充電に従って上がるのは正常。
数秒後も10Ω未満で固定される場合は通電しない。

極性は次を目視確認する。

- C14–C17: 正極が基板中央側
- C46/C48/C49: 正極が基板中央側
- C39: 正極が左側
- D1: カソード帯が左
- D2/D3/D5: カソード帯が右
- D6: カソード帯が左

## 2. EPDなしの初回通電

J2の3.3V/GNDへ電流制限20–30mAの外部3.3Vを接続する。5Vは禁止。
ST-LinkのVTrefは同じ3.3Vへ接続し、別の3.3V出力を並列接続しない。

1. `FW: Provision BOR3 (2.5V falling)`を一度だけ実行する。
2. `FW: Flash release`を書き込む。
3. TP8/SYS_VDDが約3.3V、TP6/EPD_SWがほぼ0Vであることを確認する。
4. STM32CubeProgrammerがSTM32G031K6を認識することを確認する。

PA0/PWR_HOLDはReset Handler後、HAL初期化より前からHighになる。PVD4下降検出時は
PA6をLow、EPDバスをAnalog、PA0をLowへ切り替える。BOR3はそれより低い電圧での
最終リセット保護であり、Option Byteを一度設定しなければ有効にならない。

## 3. FPC / EPD確認

必ず電源を切ってからFPCを接続する。コネクタ実装方向とFPC接点面を含め、
パネル側の論理端子で確認する。

- `BS1`: GNDへ直結（4-wire SPI）
- `VSH2`: C2 1µFを介してGND。直流短絡ではない
- `VCI/VDDIO`: `EPD_SW`
- `CS/DC/RST/BUSY/SCK/MOSI`: 対応するSTM32端子
- `VSS`: GND

外部3.3Vで`FW: Flash external-power-self-test`を実行し、FullとPartialの完了後に
TP6がほぼ0Vへ戻ることを確認する。

## 4. ST25DV provisioning

ST25公式アプリから静的設定を一度確認する。この設定はRF給電だけでも書き込める。
外部3.3Vを使う場合はEPD電源がOFFであることを確認する。

- `MB_MODE=1`: Fast Transfer Modeを許可
- `EH_MODE=0`: RF電界検出後にV_EHを自動有効化

新品のST25DVは`MB_MODE=0`、`EH_MODE=1`が初期値なので、実装した基板ごとに設定する。
工場出荷時のRF configuration password 0は8-byteすべて0。設定後はスマホを完全に
離してRF電界を一度切る。FWは動的`MB_EN`を設定できるが、静的`MB_MODE=0`では
`AEh`コマンドがerror `10h`（block not available）になり、MCUが起動する前に必要な
`EH_MODE`もFWからは直せない。

## 5. DMMだけで確認できる電源鎖

スマホをアンテナ上に固定し、次を順に測定する。

- TP3/V_EH_RAW: 実測目安2.3–2.7V
- TP10/VRAW: TP3よりわずかに低い
- TP1またはTP11/VRES_3V3: 3.20–3.3Vまで充電
- TP8/SYS_VDD: MCU動作中およそ3.3V
- TP6/EPD_SW: 待機中0V、更新中のみSYS_VDD相当

DMMでは短い電圧降下を捕捉できない。FWは診断ビルドでVREFINTを20msごとに記録し、
PVD4は非同期に電圧低下を検出する。量産判断前には可能ならオシロスコープまたは
高速ロガーでSYS_VDDとEPD_SWを同時確認する。
