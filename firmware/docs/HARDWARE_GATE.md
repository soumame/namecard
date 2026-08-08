# Hardware gate — FW試験前に必須

## STOP: TPS22917 C19

現行のIPC netlistでは次の接続になっている。

```text
U3 pin 4 CT ─ C19 1nF ─ GND
```

TPS22917の仕様はCTコンデンサを`CT–VIN`間に接続する。TIもCTをGNDへ接続しない
よう明示している。この差はPA6制御やLUTでは修正できない。

試験前にC19のGND側を浮かせ、`SYS_VDD`へ接続して`CT–SYS_VDD = 1nF`とする。
CT openは最速立上りになるが、NFCの弱い電源では突入電流を増やすので初回条件に
しない。リワーク後に無通電でCT–GNDが短絡していないことを確認する。

## FPC / EPD確認

コネクタ実装方向とFPC接点面を含め、パネル側の論理端子で測定する。回路上のJ1番号
だけを信用しない。

- `BS1`: GNDへ直結（導通レンジでほぼ0Ω）
- `VSH2`: 1µFを介してGND。直流短絡でないこと
- `VCI`: TPS22917出力`EPD_SW`
- `CS/DC/RST/BUSY/SCK/MOSI`: 指定したMCUピンへ導通
- `VSS`: GND

現行netlistではJ1-17にC2、J1-20にGNDがあるため、24ピンFPCの反転を含めて
`BS1`と`VSH2`の実端子を特に確認する。不一致なら配線リワークが終わるまでFWで
EPDをONにしない。

## TPS22917 / PA6をDMMだけで確認する

1. `release`を外部3.3Vで起動する。EPD_SWがほぼ0Vであること。
2. PA6–U3 ONの導通を無通電で確認する。
3. `external-power-self-test`を使用し、EPD_SWが約3.3Vへ上がること。
4. 試験終了またはエラー後、EPD_SWが再びほぼ0Vになること。

オシロスコープなしでは立上り時間や瞬間的な谷は確認できない。FWの`minimum_vdd_mv`
は20msサンプリングなので、20ms未満のドロップを「存在しない」とは判定できない。
発注可否の最終確認ではオシロスコープを借りるか、最低値保持付き電圧ロガーを使う。

## ST25DV04K provisioning

外部電源を接続して一度だけ、RF側から次を静的設定する。

- `MB_MODE=1`: Fast Transfer Modeを許可
- `EH_MODE=0`: RF電界検出後にEHを自動有効化

FWは起動後に動的`MB_EN`を設定し、`EH_CTRL_Dyn`をSTATUSへ返す。ただし
`EH_MODE`が誤っているとMCU自身が起動できず、FWから直すことはできない。

## 初回試験条件

- SWDデバッガー、USB-UART、外部電源を完全に外すのは外部電源試験合格後
- スマホ–アンテナ距離は約5mm以下、位置を固定
- TP1/SYS_VDDをDMMで測り、更新前2.95V以上、更新後2.4V以上
- 5回のPartialごとに外部電源でFullを1回行う
