# 実機インストール・TestFlight・App Store

iPhone XR／iOS 18で、ユーザーから白黒画像・内蔵パターン・URL・クリーニング・振動案内の
動作報告を受けています。給電と所要時間の計測、2機種以上で各経路10回連続成功の記録は未完了です。
2026-09-08にBeta 0.1.0（1）をApp Store Connectへアップロードしました。
「開発者テスト」グループへ追加済みで、内部テスターがTestFlightからインストールできます。
外部向けの招待リンクとApp Storeでの一般公開はまだありません。

## 登録済みアプリ

- App Store Connectのアプリ名: `MameCard`
- Apple ID: `6809809285`
- Bundle ID: `work.tokumaru.namecard`
- SKU: `namecard-ios`
- 内部テストグループ: `開発者テスト`（ビルドは手動で追加）

初回のホーム画面の表示名は`Namecard Beta`です。
次回のアップロードではBuild番号を`2`以上に増やします。

## 配布構成

| Xcode scheme | Run | Archive | 用途 |
| --- | --- | --- | --- |
| `Namecard` | Debug | Release | 通常版。実測済みの端末・OS・経路だけ表示書き込みを許可 |
| `Namecard Hardware` | HardwareTest | Release | 開発者がUSB接続した実機で給電・更新時間を測定 |
| `Namecard Beta` | Beta | Beta | TestFlightで協力者が白黒更新・中断復旧などを試すベータ版 |

Betaは最適化を有効にし、DEBUG／HARDWARE_TESTINGを含めません。専用のNAMECARD_BETAで
試験対象を選び、ホーム画面の名前とアプリ画面にベータ版と表示します。
現在の対象はiOS 17以降のNFC対応iPhoneです。対象の変更方法は[ベータ試験](BETA_TESTING.md)を参照してください。

BetaとHardwareTestは通常／一括清掃／旧FW更新に仮の8／20／8秒を使います。
実測値ではなく、端末や当て方によって書き込みに失敗する場合があります。
元のセッション期限、EXECUTE前の5秒の余裕、quiet待機、UIDとACK照合は維持します。
4階調のNFC書き込みと、未検証の4階調表示からの移行はベータ版でも無効です。

HardwareValidation.jsonは実測結果専用です。ベータ配布のために記録を埋める必要はありません。
App Store向けReleaseの公開条件は[実機試験](HARDWARE_VALIDATION.md)と
check_release_readiness.pyで引き続き確認します。BetaをそのままApp Store審査へ選択しないでください。

## TestFlightへの初回アップロード

1. Xcode Settings → AccountsでApple Accountを追加し、加入済みTeamが使えることを確認する。
   CLIの認証は不要です。Teamが表示されない、またはプロファイルを取得できない場合は、ここで登録状況を確認します。
2. Namecard.xcodeprojのNamecard targetでSigning & Capabilitiesを開く。
   Beta構成のTeam、Bundle ID work.tokumaru.namecard、Automatically manage signing、
   Near Field Communication Tag Readingを確認する。既存の署名設定は再生成時にも保持されます。
3. App Store Connectに、同じBundle IDのアプリを作成する。
   プライバシーポリシーは[公開済みの本文](https://github.com/soumame/namecard/blob/main/client/ios/docs/PRIVACY.md)を使用できる。
   アプリのSettingsからも同じ本文を開ける。アプリ名・日本語・Bundle ID・SKUを設定する。
4. XcodeでNamecard Beta schemeと実機用の汎用ビルド先を選び、Product → Archiveを実行する。
   VersionとBuildは通常版と共通です。アップロード済みのBuild番号は再利用せず増やします。
5. Organizerで対象Archiveを選び、Validate App、Distribute AppからApp Store Connectへアップロードする。
   外部テストにも使うため、配布方式の「TestFlight Internal Only」は選ばない。
   署名・entitlement・審査への適合は、ローカルの構成確認だけでは保証されません。
6. App Store ConnectのTestFlightでビルド処理完了を待ち、必要な輸出コンプライアンス等の質問へ回答する。
   内部テスターへ配布し、インストールからBIN取込・画像更新・URL・中断復旧まで再確認する。
7. 購入者など外部テスター向けには、テスト情報・連絡先・専用基板が必要なこと・操作方法を登録し、
   外部テストの審査を受ける。招待または公開リンクを用意できてから、リポジトリREADMEに導線を掲載する。

初回ビルドの説明文・英語の審査メモ・動画撮影手順は
[TestFlight外部テストの登録資料](TESTFLIGHT_REVIEW.md)を使用できます。
指定済み連絡先の入力・保存と、iPhone版の実演動画の準備は別途必要です。
審査用の基板は送付せず、実演動画と操作説明で審査を依頼します。

利用者はTestFlightアプリからインストールします。利用者のDeveloper Program加入は不要です。
TestFlightのビルドには90日の有効期限があります。[AppleのTestFlight概要](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)

## アップロード前のローカル確認

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s client/ios/tools -p 'test_*.py' -v
python3 client/ios/tools/generate_project.py --check
swift test --package-path client/ios/NamecardCore
xcodebuild -project client/ios/Namecard.xcodeproj -scheme 'Namecard Beta' \
  -configuration Beta -destination 'generic/platform=iOS' \
  -archivePath /tmp/NamecardBeta.xcarchive CODE_SIGNING_ALLOWED=NO archive
python3 client/ios/tools/check_distribution_build.py \
  --archive /tmp/NamecardBeta.xcarchive --channel beta
```

上記は署名なしの検証用Archiveです。そのまま実機へインストール・配布はできません。
アップロードするArchiveは、前節のXcode署名設定で別途作成します。
構成確認ツールは配布区分・アイコン・必要リソースを検査し、署名やAppleの審査、実機動作は検査しません。
CIは通常Release・HardwareTest・Betaの署名なしビルドと、通常／BetaのSimulatorテストを実行します。
アップロードや自動公開は行いません。Betaの単体テスト時だけ`ENABLE_TESTABILITY=YES`を指定し、
Simulator試験は`ONLY_ACTIVE_ARCH=YES`で選択中の端末のCPUに揃えます。

証明書の秘密鍵、プロビジョニングプロファイル、App Store Connect API鍵はcommitしません。
Team IDは認証情報ではありません。既存のTeam指定はプロジェクト再生成で保持します。

## App Store公開へ進む条件

- [実機試験](HARDWARE_VALIDATION.md)の時間計測と2機種以上・各経路10回連続成功を記録し、
  check_release_readiness.pyを通す。Namecard schemeのReleaseで新しくArchiveする。
- 製品名、対応端末／OS、説明、スクリーンショット、サポートURLを登録する。
- [プライバシーポリシー](PRIVACY.md)を公開アクセス可能なURLに掲載し、実装に沿ってApp Privacyを申告する。
- 基板の接触位置、白黒書き込みとURL設定を、提出ビルドが動くiPhoneと名刺を一緒に映した
  操作動画・説明でReview Notesへ案内する。基板は送付しない方針を明記し、追加資料の依頼に対応する。
- 4階調NFC書き込みが非対応であること、FW更新が不要であることを明記する。
- 審査と公開が完了してから、App StoreのURLをリポジトリREADMEへ掲載する。

関連資料: [AppleのArchive・配布手順](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)、
[Apple NFC設定](https://developer.apple.com/documentation/corenfc/building-an-nfc-tag-reader-app)、
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)。
