# Validation sequence and acceptance gates

## 0. Hardware gate

[HARDWARE_GATE.md](HARDWARE_GATE.md)を全項目実施する。v4では旧基板の既知の
C19、BS1、VSH2問題は回路図修正済みであり、リワークは不要。ただし実装基板で
短絡、部品極性、FPC接点面、PA6によるEPD電源OFFを確認できなければ先へ進まない。

## 1. EPDなし / External 3.3V

最初はEPDのFPCを外し、電流制限20–30mAの外部3.3VとST-Linkだけを接続する。

1. `FW: Provision BOR3 (2.5V falling)`を一度だけ実行する。
2. `FW: Flash release`を実行する。
3. TP8/SYS_VDDが約3.3V、TP6/EPD_SWがほぼ0Vであることを確認する。
4. 外部電源を切り、PA0/PWR_HOLDが電源を逆給電していないことを確認する。

次に電源を切った状態でFPCを接続し、外部3.3Vで
`external-power-self-test`をflashする。起動時に生成パターンをFull更新し、中央部を
変更して全画面Partial更新する。

- Fullが5秒以内、Partialが2秒以内に完了
- 終了後PA6 Low、EPD_SWほぼ0V
- BUSYを意図的にHigh固定した場合も2秒後にEPD電源OFF
- MOSI/SCK/CS断線ではwrite-only SPIだけで検出できないため、表示不成立を目視確認。
  シーケンス終了後はPA6 Lowになること

このビルドは外部電源専用。NFC合格回数には数えない。

量産初期化では続けて`FW: Flash prepare-white`を実行する。このビルドはST25DVの
factory-default I2C passwordを提示してstatic `EH_MODE=0`と
`FTM.MB_MODE=1`を書込み・read-backし、画面を
Full白更新した後、同じ白画像をSTM32内蔵Flashのdisplay storeへcommitする。最後に
`FW: Flash release`をmass eraseなしで書き込む。

## 2. NFC fixed image — one-shot

画面を先に`prepare-white`と外部3.3Vで全面白に揃える。次に
`nfc-fixed-one-shot`をflashし、書き込み完了後はST-Linkと外部電源を完全に外す。
スマホはNFC-V画面を開いて電界だけを維持し、通信操作はしない。

v4ではTPS63900の3.3V VRESと基板上約1.65mFを使用し、充電完了3.20V、EPD電源ON後
2.85V、更新開始直前2.80Vを下限とする。全画面Partialを1回だけ実行し、充電待ちは
最大60秒とする。診断ビルドはPartial BUSY中のSysTickを10Hzへ落とし、100msごとに
最低VDDを保持する。

- 距離約5mm以下で10/10回Partial成功
- TP1/TP11が開始前3.20V以上、FW記録の更新中最低VDDが2.80V以上
- 毎回の電源再投入でハングせず再試行
- 5回ごとに外部電源Fullで残像リセット
- 同じスマホ・向き・距離で最低3回すべて同程度の濃さで完走してから10回試験へ進む

ここで失敗する場合、MailboxやSTM32画像処理は原因ではない。EH、蓄電、TPS22917、
EPD配線、OTP Partialシーケンスを先に直す。

### 2.1 8-row fallback diagnostic

one-shotが電圧低下で失敗するときだけ`nfc-fixed-test`を使用する。このビルドは画像を
8行ずつ37帯に分け、各帯でEPDをDeep Sleep・電源OFFしてから再充電する。閾値は
one-shotと同じ3.20V / 2.85V / 2.80Vであり、旧基板向けの低電圧閾値や外付け容量は
使用しない。

- one-shot失敗、8行版成功: 全画面更新時の電力マージン不足
- 両方とも同じ帯で停止: EH、PWR_HOLD、PVD/BOR、EPD昇圧部を再確認
- 完走するが薄い: EPD駆動波形またはEPD高圧電源を再確認

8行版の成功だけで量産合格とはしない。最終判定はone-shot全画面Partialで行う。

## 3. Mailbox protocol

`release`とAndroid test clientを使用する。

- 最初にSTATUS確認だけを行い、表示が変化せずACK、VDD、stateを取得できる
- 全面白へ戻し、1-byteの`NFC OK` PATTERN→STATUS→EXECUTEで全画面更新できる
- 10種類の内蔵PATTERNを電界を切らずに連続更新し、各回COMPLETEかつ表示濃度が揃う
- 連続試験中のTagLost後、完了済み番号を飛ばして未完了PATTERNから再開できる
- 画像転送中のTagLost、NFC IOException、ACK timeout後にホーム画面へ戻らず
  Reader Modeが再開し、保存済みOffsetから再送できる
- 再び全面白へ戻してから、以下の4,736-byte分割転送へ進む
- 240-byte DATA×19 + 176-byte DATA×1（合計4,736）
- 同じDATAを2回送り、offsetが一度だけ進む
- Sequence違反で期待Sequence/Offsetが返る
- Header CRC16、Payload CRC16、画像CRC32を個別に破壊して拒否される
- START/DATA/COMMIT/EXECUTEのACKを1回読み損ね、同一フレーム再送で回復
- 4,736 bytes + COMMIT成功前はPA6がHighにならない
- COMMIT後の最初のREADYまでにFlash stageと再充電が入り、PA6はLowのまま
- 更新完了後に完全に電源を切り、別画像へ更新しても旧画像差分が正しい
- 9,472-byte 4階調BINを送り、EXECUTE後に32行帯域ごとの更新と再充電を繰り返して
  COMPLETEまで無操作で完走する。次帯域の更新後も描画済み帯域の濃度が低下せず、
  末尾16行に未更新・境界線・階調ずれがない
- 4階調更新中のCHARGINGではAndroidがEXECUTEを再送せず、同じTransfer IDのまま
  FWの次帯域を待つ。途中で離した場合は保存済みplane 0からplane 1再送で回復する

## 4. Power removal matrix

各状態でスマホを離し、次のタッチで正常再試行または保存済み更新を再開できること。

| 切断点 | 期待結果 |
|---|---|
| DATA受信中 | RAM消失、次回START必須 |
| CHARGING（Flash保存前） | PA6はLow。RAM消失時は次回START |
| CHARGING（Flash保存後） | pending slotから同じTransfer ID/Sequenceを復元 |
| EPD RAM転送中 | PVDでPA6 Low・PA0解放。次回はpending targetを再実行 |
| Partial BUSY中 | PVDでPA6 Low・PA0解放。次回はold->pending targetを再実行 |
| EXECUTE ACK未読 | 1秒で中止、PA6 Low |

## 5. Final order decision

- 主対象スマホ10/10回
- 別機種のAndroidスマホ10/10回
- 転送開始からCOMPLETEまで無操作で完了
- 更新中最低VDDをSTATUSに記録し、2.80V以上
- アプリFlash 20KiB以下、表示store 12KiB、静的RAM 7KiB以下
- 5回Partial後の外部Fullで残像が回復

FWの20ms VDD診断だけでは短い電圧降下を捕捉できない。量産発注前の最終1回は、
オシロスコープまたは十分高速なロガーでSYS_VDDとEPD_SWを同時確認する。
