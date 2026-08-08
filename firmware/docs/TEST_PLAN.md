# Validation sequence and acceptance gates

## 0. Hardware gate

[HARDWARE_GATE.md](HARDWARE_GATE.md)を全項目実施する。C19、BS1、VSH2、PA6の
いずれかが不一致なら以後へ進まない。

## 1. External 3.3V

`external-power-self-test`をflashする。起動時に生成パターンをFull更新し、中央部を
変更して全画面Partial更新する。

- Fullが5秒以内、Partialが2秒以内に完了
- 終了後PA6 Low、EPD_SWほぼ0V
- BUSYを意図的にHigh固定した場合も2秒後にEPD電源OFF
- MOSI/SCK/CS断線ではwrite-only SPIだけで検出できないため、表示不成立を目視確認。
  シーケンス終了後はPA6 Lowになること

このビルドは外部電源専用。NFC合格回数には数えない。

## 2. NFC fixed image

`nfc-fixed-test`をflashし、デバッガーと外部電源を完全に外す。スマホはNFC-V画面を
開いて電界だけ維持し、通信操作はしない。

現行基板の探索ビルドは、実測した`SYS_VDD=2.5～2.7V`に合わせて、充電完了2.50V、
EPD電源ON後2.30V、更新開始前2.25Vを下限とする。これはPartial成立性の確認値であり、
GDEY029T94の推奨3.3V動作や量産マージンを満たすことを意味しない。
画像は8行ずつ37帯に分割し、各帯でEPDをDeep Sleep・電源OFFしてから再充電する。
旧画像RAMには更新済み帯だけを含む現在状態を毎回再構築し、次の帯だけを遷移させる。
追加タンク容量による充電時間増加を許容するため、探索ビルドの充電待ちは各帯60秒とする。
Partial BUSY中はADC測定を止め、SysTickを10Hzへ落としてBUSY EXTIを主な復帰源にする。

- 距離約5mm以下で10/10回Partial成功
- 探索試験ではTP1が開始前2.50V以上。量産判定では開始前2.95V以上、終了後2.4V以上
- 毎回の電源再投入でハングせず再試行
- 5回ごとに外部電源Fullで残像リセット

ここで失敗する場合、MailboxやSTM32画像処理は原因ではない。EH、蓄電、TPS22917、
EPD配線、OTP Partialシーケンスを先に直す。

### 2.1 Final one-shot decision test

外付け330uFを4個接続した状態で`nfc-fixed-one-shot`をflashする。画面は先に
`prepare-white`と外部3.3Vで全面白に揃える。書き込み完了後はST-Linkと外部電源を
完全に外し、スマホの電界だけで全画面Partialを1回実行する。低電圧閾値と充電待ち
60秒は分割版と同じだが、`NAMECARD_NFC_BAND_ROWS=0`として再初期化と波形起動を
1回に限定する。

- 濃い固定画像を最後まで表示: 現行電源構成でFW継続。Mailbox結合試験へ進む
- 完走するが薄い: 駆動電圧・連続受電不足として次版基板へ進む
- リセット、途中停止、無表示: 瞬間電力または連続受電不足として次版基板へ進む
- 合否判定中はスマホ位置を固定し、同じ機種・向き・距離で3回実施する。各試行の前に
  `prepare-white`を外部3.3Vで実行して、必ず全面白から開始する

この試験では、1回だけ偶然成功しても量産可とは判定しない。3回すべて同程度の濃さで
完走することを、現行基板で製品FW開発を続ける最低条件とする。

## 3. Mailbox protocol

`release`とAndroid test clientを使用する。

- 240-byte DATA×19 + 176-byte DATA×1（合計4,736）
- 同じDATAを2回送り、offsetが一度だけ進む
- Sequence違反で期待Sequence/Offsetが返る
- Header CRC16、Payload CRC16、画像CRC32を個別に破壊して拒否される
- START/DATA/COMMIT/EXECUTEのACKを1回読み損ね、同一フレーム再送で回復
- 4,736 bytes + COMMIT成功前はPA6がHighにならない

## 4. Power removal matrix

各状態でスマホを離し、次のタッチでSTARTから正常再試行できること。

| 切断点 | 期待結果 |
|---|---|
| DATA受信中 | RAM消失、次回START必須 |
| CHARGING | PA6はLowのまま |
| EPD RAM転送中 | BOR/reset後、早期PA6 Low |
| Partial BUSY中 | BOR/reset後、早期PA6 Low。次回再試行 |
| EXECUTE ACK未読 | 1秒で中止、PA6 Low |

## 5. Final order decision

- 主対象スマホ10/10回
- 別OSスマホ10/10回
- 転送開始からCOMPLETEまで無操作で完了
- 更新中最低VDDをSTATUSに記録
- Flash 28KiB以下、静的RAM 7KiB以下
- 5回Partial後の外部Fullで残像が回復

FWの20ms VDD診断だけでは短い電圧降下を捕捉できない。量産発注前の最終1回は、
オシロスコープまたは十分高速なロガーでSYS_VDDとEPD_SWを同時確認する。
