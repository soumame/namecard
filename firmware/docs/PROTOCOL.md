# Namecard Mailbox protocol v1

すべてlittle-endian。1つのST25DV Mailboxメッセージに1フレームを格納する。

## Header — 16 bytes

| Offset | Size | Field | Value |
|---:|---:|---|---|
| 0 | 2 | Magic | ASCII `NC` |
| 2 | 1 | Version | `1` |
| 3 | 1 | Type | 下表 |
| 4 | 2 | Transfer ID | セッションID |
| 6 | 2 | Sequence | START=0、受理ごとに+1 |
| 8 | 2 | Offset | 画像先頭からのbyte offset |
| 10 | 2 | Payload length | 0〜240 |
| 12 | 2 | Header CRC16 | bytes 0〜11 + 14〜15 |
| 14 | 2 | Payload CRC16 | Payloadのみ |

CRC16はCCITT-FALSE（poly `0x1021`、init `0xFFFF`、xorout 0）。画像CRC32は
IEEE/zlib（poly `0xEDB88320`）。

| Type | Code | Payload |
|---|---:|---|
| START | `0x01` | 16-byte metadata |
| DATA | `0x02` | 最大240 bytes |
| COMMIT | `0x03` | なし |
| STATUS | `0x04` | なし |
| EXECUTE | `0x05` | なし |
| PATTERN | `0x06` | `u8 pattern_id` |
| ACK | `0x80` | 16-byte status |
| ERROR | `0x81` | 16-byte status |

## START metadata — 16 bytes

```text
u16 width       = 296
u16 height      = 128
u16 total_len   = 4736
u8  format      = 1 (EPD_NATIVE_1BPP) or 2 (EPD_GRAY4_PLANE)
u8  update_mode = 1 (1bpp) or plane_index 0/1 (4-gray)
u32 image_crc32
u32 flags
```

format 1の`flags` bit 0（`0x00000001`）はFW一括クリーニング要求。対応FWはtargetを一度だけ
FlashへPREPARED保存し、EXECUTE後に白→黒→白→targetを連続Partial更新する。
中間3フレームはFlashへ保存せず、target完了時だけCOMMITTEDマーカーを書く。
未定義bitはコマンドエラーとする。format 2では`flags=0`だけを許可する。

画像はSSD1680 RAM順で、16 bytes × 296 rows、MSB first、`1=white`。
MCUは回転、反転、圧縮展開を行わない。

4階調は同じTransfer IDでformat 2を2セッション連続送信する。各セッションの
`total_len`は4,736 bytesで、plane 0をCOMMITしてREADYになった後、plane 1を
START/DATA/COMMITする。plane 1のCOMMIT後だけEXECUTEを送る。9,472-byte BINでは
先頭4,736 bytesがSSD1680 RAM `0x24`、後半がRAM `0x26`である。Androidの2bpp値
`00/01/10/11 = 黒/濃灰/薄灰/白`に対し、各RAM bitはそれぞれ
`(1,1)/(0,1)/(1,0)/(0,0)`となる。

## PATTERN — lightweight bring-up

画像4,736 bytesを転送せず、MCU内蔵の固定画像を選ぶ試験用コマンド。Payloadは
1 byteだけで、次の10種類を選ぶ。Sequence=0、Offset=0で送る。

| ID | Pattern |
|---:|---|
| 1 | checker |
| 2 | NFC OK text |
| 3 | solid black |
| 4 | solid white |
| 5 | long-axis bars |
| 6 | short-axis bars |
| 7 | grid |
| 8 | diagonal stripes |
| 9 | target |
| 10 | TEST 10 text |

受理後は画像がCOMMIT済みの状態になり、ACKが示す次のSequence=1、Offset=4736を
使ってSTATUS→EXECUTEへ進む。PATTERNも全画面Partialなので、初回試験では物理画面を
あらかじめ全面白へ揃える。

## ACK payload — 16 bytes

| Offset | Size | Field |
|---:|---:|---|
| 0 | 1 | ACK対象Type |
| 1 | 1 | ACK code: 0 OK, 1 duplicate, 2 status, 3 charging, 4 ready, `0x80` error |
| 2 | 1 | App state |
| 3 | 1 | Error code |
| 4 | 2 | 次に期待するSequence |
| 6 | 2 | 次に期待するOffset |
| 8 | 2 | 現在VDD mV |
| 10 | 2 | 診断区間の最低VDD mV |
| 12 | 2 | RF quiet要求 ms |
| 14 | 1 | `EH_CTRL_Dyn` raw value |
| 15 | 1 | capability flags（下表） |

| Bit | Meaning |
|---:|---|
| 0 | Mailbox enabled |
| 1 | committed imageあり |
| 2 | recovery pendingあり |
| 3 | FW一括クリーニング対応 |
| 4 | 一括クリーニング実行中 |
| 5 | native 4階調対応 |
| 6 | committed表示が4階調 |
| 7 | pendingが4階調plane 0 |

App stateはBOOT=0、RECEIVING=1、CHARGING=2、READY=3、EXECUTE_ACK=4、
REFRESHING=5、COMPLETE=6、ERROR=7。

## Transfer rules

1. STARTは既存セッションを破棄する。DATA受信中の電源断後はSTARTから送る。
2. DATAはSequenceとOffsetの両方が期待値と一致した場合だけコピーする。
3. 直前と同一のType/Sequence/Offset/Length/CRCは重複として再適用せずACKする。
4. COMMITは4,736 bytesと画像CRC32の両方を確認する。
5. COMMIT後、STATUSを最大500ms程度の間隔で読み、state=READYを待つ。
6. READYでEXECUTEを送る。ACKを最後まで読み、`quiet_ms`の間はRFコマンドを送らず
   電界だけ維持する。
7. FWはACKの`HOST_PUT_MSG`がRF読取によりclearされた後、さらに100ms待ってPA6をONする。
8. COMMIT後は新画像をSTM32 Flashのinactive slotへ保存してからREADYになる。この間も
   App stateはCHARGING=2。保存後に再充電するため、STATUSを継続してREADYまで待つ。
9. Flash保存後の電源断ではbit2が立ち、保存済みTransfer ID/SequenceでEXECUTEを再送できる。
10. STARTのflags bit0とACK capability bit3を組み合わせた場合、FWはEXECUTE後に
    白→黒→白→targetを内部で進める。各Partial間はCHARGINGへ戻り、3.20V/100msと
    100ms guardを満たしてから次段階へ進む。AndroidはSTATUSを低頻度で読み、
    COMPLETEまで同じRF電界を維持する。
11. 一括クリーニング途中の電源断ではPREPARED targetが残る。再起動後にbit2を確認し、
    同じTransfer ID/SequenceでEXECUTEを再送すると、安全側として白段階からやり直す。
12. 4階調plane 0はinactive Flash slotへPREPARED保存する。plane 1は4,736-byte RAMへ
    受信し、同じTransfer IDのpending plane 0がある場合だけCOMMIT/EXECUTEを許可する。
13. 4階調plane 1の受信中または表示中に電源断した場合、ACK bit7を確認してplane 1を
    STARTから再送する。plane 0の再転送は不要。表示完了後だけplane 0をCOMMITTEDにする。
14. committed表示が4階調の状態からformat 1/PATTERNへ戻す場合、FWは最初の白をFull更新し、
    続けて黒→白→targetをPartial更新する。4階調planeを1bpp旧画像としては使用しない。
15. 4階調はGate Start PositionとMUXを使って32行ずつ10回に分けて駆動する。各帯域を
    HW/SW Reset、2段階の4階調初期化、RAM plane転送、C7、Deep Sleep、EPD電源OFFまでの
    独立サイクルにする。初期化の2段階間とRAM転送後はEPD電源を維持したまま、帯域完了後は
    EPD電源を切って3.20V/100msまで再充電する。
    296行の末尾8行はSSD1680の最小MUX=16に合わせ、直前8行と重ねて16行更新する。
    AndroidはEXECUTE ACK後に最低60秒RFコマンドを止め、CHARGING中はEXECUTEを再送せず
    FWの自動帯域継続を待つ。

PATTERNはSTART/DATA/COMMITの代わりに1フレームだけ送る。CRC、ACK、充電、EXECUTE、
RF quiet、EPD更新は通常画像と同じ経路を通るため、Mailbox立上げの中間試験に使用する。
直前の表示はCRC付きFlash slotからSSD1680の旧画像RAMへ直接転送する。このため追加RAM
なしで10種類を連続Partial更新でき、電源断後も旧画像を復元できる。Flash slotが一度も
初期化されていない基板だけは旧画面=白を前提とするため、出荷時に`prepare-white`を実行する。

端末のNFC-V最大転送長が小さい場合、DATAだけ240 bytes未満にしてよい。FWは可変長
DATAを受理する。240 bytesなら20 DATAフレームになる。
