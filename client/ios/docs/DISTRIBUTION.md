# 実機インストール・TestFlight・App Store

ユーザーからビルド・起動・STATUS表示までの成功報告を受けています。
電子ペーパーへの書き込み・給電計測は未実施で、公開済みURLや審査成功はまだありません。

## Developer Programが利用可能になったら

1. Xcode Settings → Accountsで登録したApple Accountを追加し、加入済みTeamの表示を確認する。
2. Namecard.xcodeprojを開き、Namecard targetのSigning & CapabilitiesでそのTeamを選ぶ。
3. Bundle ID `work.tokumaru.namecard`を自分のTeamへ登録し、Near Field Communication Tag Readingを有効にする。
   利用できないIDの場合は所有しているIDへ変更し、公開後は維持する。
4. USB接続したiPhoneを信頼し、Developer Modeを有効にする。`Namecard Hardware` schemeで
   実機へインストールする。仮の時間予算を用いる計測用ビルドであることに注意する。
5. HARDWARE_VALIDATION.mdに従って試験・時間予算・対応端末を記録する。

証明書、秘密鍵、Team ID、App Store Connect API鍵をソースへcommitしません。
Developer Programの反映待ちやNFC entitlementを含むプロファイルが生成できない場合は、
Simulator開発を続け、実機試験以降を待ちます。

## TestFlight

1. `check_release_readiness.py`とCIを通し、通常Namecard schemeのReleaseでArchiveする。
2. Xcode OrganizerのValidate Appでentitlement、署名、アイコン、PrivacyInfo.xcprivacyを確認する。
3. App Store Connectにアプリを作成してUploadし、内部テスターへ配布する。
4. 実機の購入者フローでBIN取込・画像更新・URL・中断復旧を再確認する。
5. 外部TestFlight配布時はテスト内容と基板が必要なことを説明し、必要な審査を受ける。

CLIが利用可能になった場合も、署名情報は環境から与えます。例:

```sh
python3 client/ios/tools/check_release_readiness.py
xcodebuild -project client/ios/Namecard.xcodeproj -scheme Namecard \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath /tmp/Namecard.xcarchive DEVELOPMENT_TEAM=<TEAM_ID> \
  -allowProvisioningUpdates archive
```

アップロードはOrganizerから実行します。CIはテストと署名なしビルドだけを行い、
検証記録がない状態で自動公開しません。

## App Store審査用チェック

- 製品名、対応端末／OS、説明、スクリーンショット、サポートURLを登録する。
- PRIVACY.mdを公開アクセス可能なURLに掲載し、App Privacyは実装に即して「データを収集しない」と申告する。
- 基板の入手方法、接触位置、白黒書き込みとURL設定の操作動画・説明をReview Notesへ添付する。
- 審査担当者が必要とする基板等のリソースを用意する。
- 4階調NFC書き込みが非対応であること、FW更新が不要であることを明記する。
- 実機検証完了後だけ公開し、公開URLができたらリポジトリREADMEへ掲載する。

関連資料: [Apple NFC設定](https://developer.apple.com/documentation/corenfc/building-an-nfc-tag-reader-app)、
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)。
