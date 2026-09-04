# Namecard v5 production package

Maker Faire Tokyo 2026向けv5のJLCPCB製造データです。

## JLCPCBへのアップロード

JLCPCBでは次の3ファイルをそれぞれ指定してください。外側の`namecard_v5_production.zip`をGerberとしてアップロードしないでください。

1. PCB fabrication: `namecard_v5_gerbers.zip`
2. BOM: `namecard_v5_bom.csv`
3. CPL / Pick and Place: `namecard_v5_cpl.csv`

アップロード後、JLCPCBの部品照合結果、実装面、回転、極性を注文確定前に確認してください。

## ファイル一覧

| File | Purpose |
| --- | --- |
| `namecard_v5_gerbers.zip` | Gerberおよびドリルデータ |
| `namecard_v5_bom.csv` | 1台あたりのJLCPCB実装BOM |
| `namecard_v5_bom.xlsx` | 同じBOMの閲覧・編集用ワークブック |
| `namecard_v5_cpl.csv` | JLCPCB実装対象69点の座標データ |
| `jlcpcb_purchased_parts_30pcs.xls` | 30台分＋予備を含むJLCPCB購入部品の原本 |
| `LICENSE` | 製造データのMIT License |
| `SHA256SUMS` | 上記ファイルのSHA-256チェックサム |

購入部品原本の`Qty`は発注数量であり、1台あたりの数量ではありません。公開BOMではDesignator数から1台あたりの`Quantity`へ正規化しています。J2（1×5ピンヘッダ）は購入部品原本に含まれないため、BOM/CPLから除外しています。必要なら手実装してください。

今回の購入部品原本に合わせた主な変更は次の通りです。

| Reference | JLCPCB Part # | Part |
| --- | --- | --- |
| L1 | C167813 | FNR4018S470MT, 47uH |
| U1 | C432203 | STM32G031K8T6 |
| U2 | C2908287 | ST25DV04K-IER6C3 |

BOM/CPLの列構成はJLCPCBのKiCad向けガイドに合わせています。

- <https://jlcpcb.com/help/article/how-to-generate-the-bom-and-centroid-file-from-kicad>
