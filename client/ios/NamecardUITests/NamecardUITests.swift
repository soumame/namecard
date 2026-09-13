import XCTest
import UIKit

@MainActor
final class NamecardUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        XCTAssertTrue(app.buttons["editor.addText"].waitForExistence(timeout: 10))
    }

    func testJapaneseTextSavePersistsAndReopensInEditor() throws {
        addText("山田 太郎")
        let cardName = "名刺UI-\(UUID().uuidString.prefix(8))"
        app.buttons["editor.output"].tap()
        app.buttons["editor.save"].tap()
        let nameField = app.textFields["library.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        enterText(cardName, in: nameField)
        app.buttons["library.confirmSave"].tap()
        XCTAssertTrue(app.staticTexts[cardName].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
        let thumbnail = app.images.matching(NSPredicate(format: "label == %@", "\(cardName)の完成画像")).firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 3), "保存直後にキャッシュ済みサムネイルを表示する")
        XCTAssertGreaterThan(thumbnail.frame.height, 0)

        app.terminate()
        app.launch()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts[cardName].waitForExistence(timeout: 5), "保存したBINと名称は再起動後も保持される")
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 3), "再起動後も保存BINからサムネイルを表示する")
        // Library is ordered by updatedAt descending, so this newly saved card is first.
        app.buttons["library.edit"].firstMatch.tap()
        XCTAssertTrue(app.buttons["editor.addText"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.buttons["New"].isSelected)
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled, "Libraryの編集は完成画像を1レイヤーとして読み込む")
        app.buttons["editor.output"].tap()
        app.buttons["プレビュー"].tap()
        XCTAssertTrue(app.navigationBars["完成画像"].waitForExistence(timeout: 3))
        let previewImage = app.images["editor.previewImage"]
        XCTAssertTrue(previewImage.waitForExistence(timeout: 3), "初回のプレビューにも保存済み画像を表示する")
        XCTAssertGreaterThan(previewImage.frame.height, 0)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Libraryから読み込んだ日本語名刺"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testUndoAndRedoAfterAddingText() {
        let undo = app.buttons["editor.undo"]
        let redo = app.buttons["editor.redo"]
        XCTAssertFalse(undo.isEnabled)
        XCTAssertFalse(redo.isEnabled)
        addText("編集テスト")
        XCTAssertTrue(undo.isEnabled)
        XCTAssertFalse(redo.isEnabled)
        undo.tap()
        XCTAssertFalse(undo.isEnabled)
        XCTAssertTrue(redo.isEnabled)
        redo.tap()
        XCTAssertTrue(undo.isEnabled)
        XCTAssertFalse(redo.isEnabled)
    }

    func testTextFormattingAndSystemFontPickerBeforeAdding() {
        app.buttons["editor.addText"].tap()
        let field = app.textFields["editor.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        enterText("Namecard 日本語", in: field)
        let bold = app.buttons["editor.text.bold"]
        let italic = app.buttons["editor.text.italic"]
        let underline = app.buttons["editor.text.underline"]
        XCTAssertEqual(bold.value as? String, "オン")
        bold.tap()
        italic.tap()
        underline.tap()
        XCTAssertEqual(bold.value as? String, "オフ")
        XCTAssertEqual(italic.value as? String, "オン")
        XCTAssertEqual(underline.value as? String, "オン")
        let keyboardScreenshot = XCTAttachment(screenshot: app.screenshot())
        keyboardScreenshot.name = "テキスト書式とキーボード"
        keyboardScreenshot.lifetime = .keepAlways
        add(keyboardScreenshot)
        app.buttons["editor.text.font"].tap()
        let family = app.buttons["editor.text.font.Courier New"]
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("Courier")
        XCTAssertTrue(family.waitForExistence(timeout: 3))
        family.tap()
        XCTAssertTrue(app.buttons["editor.text.font"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Courier New"].exists)
        XCTAssertEqual(italic.value as? String, "オン")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "フォントと斜体・下線のプレビュー"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["editor.confirmText"].tap()
        XCTAssertTrue(app.buttons["editor.undo"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled)
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        app.buttons["editor.redo"].tap()
        app.buttons["editor.output"].tap()
        app.buttons["プレビュー"].tap()
        XCTAssertTrue(app.images["editor.previewImage"].waitForExistence(timeout: 3))
    }

    func testViewportRotationSnapTogglesIndependently() {
        let rotation = app.buttons["editor.viewportRotationSnap"]
        let objectRotation = app.buttons["editor.objectRotationSnap"]
        // Querying an offscreen Liquid Glass button's hittability can throw before scrolling on iOS 26.
        for _ in 0..<3 { app.scrollViews.firstMatch.swipeLeft() }
        XCTAssertTrue(rotation.isHittable)
        XCTAssertTrue(objectRotation.isHittable)
        XCTAssertEqual(rotation.value as? String, "オフ")
        XCTAssertEqual(objectRotation.value as? String, "オフ")
        XCTAssertEqual(app.buttons["editor.positionSnap"].value as? String, "オフ")
        objectRotation.tap()
        XCTAssertEqual(objectRotation.value as? String, "オン")
        XCTAssertEqual(rotation.value as? String, "オフ")
        rotation.tap()
        XCTAssertEqual(rotation.value as? String, "オン")
        XCTAssertEqual(objectRotation.value as? String, "オン")
        XCTAssertEqual(app.buttons["editor.positionSnap"].value as? String, "オフ")
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled)
        objectRotation.tap()
        XCTAssertEqual(objectRotation.value as? String, "オフ")
        XCTAssertEqual(rotation.value as? String, "オン")
        rotation.tap()
        XCTAssertEqual(rotation.value as? String, "オフ")
    }

    func testGray4WriteDisabledButSaveAvailable() {
        app.buttons["editor.format"].tap()
        app.buttons["4階調"].firstMatch.tap()
        let explanation = app.staticTexts["editor.gray4.explanation"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 3))
        XCTAssertTrue(explanation.label.contains("NFCセッション"))
        XCTAssertFalse(app.buttons["editor.write"].isEnabled)
        app.buttons["editor.output"].tap()
        XCTAssertTrue(app.buttons["editor.save"].isEnabled)
        XCTAssertTrue(app.buttons["editor.export"].isEnabled)
    }

    func testDistributionNoticeMatchesBuildChannel() {
        let notice = app.staticTexts["distribution.betaNotice.New"]
        #if NAMECARD_BETA
        XCTAssertTrue(notice.waitForExistence(timeout: 3))
        // safeAreaInset text can report an enclosing accessibility frame on iOS 26.
        // Check usable controls here; retain a screenshot for visual layout review.
        XCTAssertTrue(app.buttons["editor.output"].isHittable)
        // The checked-in pilot audience includes all supported iPhones/OS versions.
        // Core NFC availability is checked when scanning, including on Simulator.
        XCTAssertTrue(app.buttons["editor.write"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "ベータ試験版の案内と操作バー"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        #else
        XCTAssertFalse(notice.exists)
        #endif
    }

    func testStatusOnSimulatorShowsUnavailableAndCanClose() throws {
        #if targetEnvironment(simulator)
        app.tabBars.buttons["Settings"].tap()
        let status = app.buttons["settings.status"]
        for _ in 0..<4 {
            if status.exists && status.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(status.exists)
        XCTAssertTrue(status.isHittable)
        status.tap()
        let message = app.staticTexts["この環境ではNFCを利用できません。NFC対応のiPhone実機で確認してください。"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertFalse(app.images["checkmark.circle.fill"].exists, "Simulatorで完了と表示しない")
        app.buttons["閉じる"].tap()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected)
        #else
        throw XCTSkip("SimulatorのNFC非対応表示を確認するテストです。実機NFCは検証手順書に従ってください。")
        #endif
    }

    func testURLFormDismissesBeforeSimulatorNFCProgress() throws {
        #if targetEnvironment(simulator)
        app.buttons["editor.setURL"].tap()
        let field = app.textFields["editor.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        enterText("https://example.com/namecard", in: field)
        app.buttons["editor.confirmURL"].tap()
        let message = app.staticTexts["この環境ではNFCを利用できません。NFC対応のiPhone実機で確認してください。"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertFalse(field.exists)
        app.buttons["閉じる"].tap()
        XCTAssertTrue(app.buttons["editor.setURL"].waitForExistence(timeout: 3))
        #else
        throw XCTSkip("Simulatorで入力フォームからNFC進捗への遷移を確認します。")
        #endif
    }

    func testClearURLNeedsNoInputAndDismissesBeforeNFCProgress() throws {
        #if targetEnvironment(simulator)
        app.buttons["editor.setURL"].tap()
        let field = app.textFields["editor.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["editor.confirmURL"].isEnabled)
        let clear = app.buttons["editor.clearURL"]
        XCTAssertTrue(clear.isEnabled)
        clear.tap()
        let message = app.staticTexts["この環境ではNFCを利用できません。NFC対応のiPhone実機で確認してください。"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertFalse(field.exists)
        XCTAssertFalse(app.images["checkmark.circle.fill"].exists)
        app.buttons["閉じる"].tap()
        XCTAssertTrue(app.buttons["editor.setURL"].waitForExistence(timeout: 3))
        #else
        throw XCTSkip("SimulatorでURLクリアからNFC進捗への遷移を確認します。")
        #endif
    }

    func testQRCodePreviewAddsImageAndSupportsUndoRedo() {
        openQRTool()
        let field = app.textFields["editor.qrURL"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["editor.generateQR"].isEnabled)
        enterText("example.com/namecard", in: field)
        app.buttons["editor.generateQR"].tap()
        XCTAssertTrue(app.images["editor.qrPreview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["https://example.com/namecard"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "QRコード生成プレビュー"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["editor.addQRToCanvas"].tap()
        XCTAssertTrue(app.buttons["editor.undo"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled)
        app.buttons["editor.undo"].tap()
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled)
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        app.buttons["editor.redo"].tap()
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled)
    }

    func testChangingQRURLRemovesStalePreview() {
        openQRTool()
        let field = app.textFields["editor.qrURL"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        enterText("example.com", in: field)
        app.buttons["editor.generateQR"].tap()
        XCTAssertTrue(app.images["editor.qrPreview"].waitForExistence(timeout: 5))
        field.tap()
        field.typeText("/new")
        XCTAssertFalse(app.images["editor.qrPreview"].exists)
        XCTAssertFalse(app.buttons["editor.addQRToCanvas"].exists)
        app.buttons["閉じる"].tap()
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled)
    }

    private func openQRTool() {
        let qr = app.buttons["editor.qrCode"]
        if !qr.isHittable {
            let url = app.buttons["editor.setURL"]
            url.press(forDuration: 0.1, thenDragTo: app.buttons["editor.addText"])
        }
        XCTAssertTrue(qr.waitForExistence(timeout: 3))
        qr.tap()
    }

    private func addText(_ value: String) {
        app.buttons["editor.addText"].tap()
        let field = app.textFields["editor.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        enterText(value, in: field)
        let confirm = app.buttons["editor.confirmText"]
        XCTAssertEqual(confirm.label, "追加")
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        let added = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
                                              object: app.buttons["editor.undo"])
        XCTAssertEqual(XCTWaiter.wait(for: [added], timeout: 3), .completed)
    }

    private func enterText(_ value: String, in field: XCUIElement) {
        // Paste via the real edit menu: direct typeText cannot synthesize arbitrary kanji on the kana keyboard.
        UIPasteboard.general.string = value
        field.tap()
        field.press(forDuration: 1.2)
        let paste = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'ペースト' OR label == 'Paste'")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        paste.tap()
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 3), .completed)
    }

}
