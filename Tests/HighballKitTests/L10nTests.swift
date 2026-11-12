import XCTest
@testable import HighballKit

/// Existing English copy assertions must not depend on the developer's macOS language.
/// The argument domain is process-local: no preference file or installed app is changed.
class EnglishCopyTestCase: XCTestCase {
    private var savedArguments: [String: Any] = [:]
    override func setUp() {
        super.setUp()
        savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = savedArguments
        arguments["HighballLanguage"] = "en"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
    override func tearDown() {
        UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
        super.tearDown()
    }
}

final class L10nTests: EnglishCopyTestCase {
    private func use(_ language: String) {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["HighballLanguage"] = language
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    func testOverrideAndSystemPreferenceOrder() {
        XCTAssertEqual(L10n.language(override: "zh-Hans", preferredLanguages: ["fr-FR"]), .zhHans)
        XCTAssertEqual(L10n.language(override: "en", preferredLanguages: ["zh-Hans-CN"]), .en)
        XCTAssertEqual(L10n.language(override: "fr", preferredLanguages: ["en-US"]), .fr)
        XCTAssertEqual(L10n.language(override: nil, preferredLanguages: ["en-US", "zh-Hans"]), .en)
        XCTAssertEqual(L10n.language(override: nil, preferredLanguages: ["fr-CA", "en"]), .fr)
        XCTAssertEqual(L10n.language(override: nil, preferredLanguages: ["zh-CN"]), .zhHans)
        XCTAssertEqual(L10n.language(override: nil, preferredLanguages: ["zh-Hans-SG"]), .zhHans)
        XCTAssertEqual(L10n.language(override: nil, preferredLanguages: ["zh-Hant-TW", "en"]), .en)
        XCTAssertEqual(L10n.language(override: "invalid", preferredLanguages: ["fr"]), .fr)
        XCTAssertEqual(L10n.language(override: nil, preferredLanguages: ["de-DE"]), .en)
        XCTAssertEqual(L10n.language(override: nil, preferredLanguages: []), .en)
    }

    func testAllLanguagesAndFallbackPreserveUnknownContent() {
        for language in [L10n.Language.en, .fr, .zhHans] {
            let unknown = "New upstream text: 100% /tmp/game.exe\nWine DXVK DXMT D3DMetal"
            XCTAssertEqual(L10n.translate(unknown, language: language), unknown)
        }
        XCTAssertEqual(L10n.translate("Cancel", language: .en), "Cancel")
        XCTAssertEqual(L10n.translate("Cancel", language: .fr), "Annuler")
        XCTAssertEqual(L10n.translate("Cancel", language: .zhHans), "取消")
        use("fr")
        XCTAssertEqual(L10n.currentLanguage, .fr)
        XCTAssertEqual(L10n.translate("Cancel"), "Annuler")
    }

    func testChineseDynamicValuesAndPositionalFormatting() {
        use("zh-Hans")
        let title = "Starting %@ 100% 游戏 /tmp/A.exe"
        XCTAssertEqual(L10n.format("Starting %@", title), "正在启动 " + title)
        XCTAssertEqual(String(format: L10n.translate("Run %@ in %@?"), "Game", "Environment"),
                       "要在“Environment”中运行 Game 吗？")
        XCTAssertEqual(String(format: L10n.translate("%@%% of players"), "12"), "12% 的玩家")
        XCTAssertEqual(String(format: L10n.translate("Setting up %@: %@ (%d of %d)"), "Game", "VC++", 2, 3),
                       "正在配置 Game：VC++（第 2 项，共 3 项）")
    }

    func testPreferenceSwitchBetweenChineseAndEnglishKeepsFallback() {
        let newKey = "Future upstream feature %@"
        for (code, language, cancel) in [("zh-Hans", L10n.Language.zhHans, "取消"),
                                         ("en", .en, "Cancel"),
                                         ("zh-Hans", .zhHans, "取消")] {
            use(code)
            XCTAssertEqual(L10n.currentLanguage, language)
            XCTAssertEqual(L10n.translate("Cancel"), cancel)
            XCTAssertEqual(L10n.translate(newKey), newKey)
            XCTAssertEqual(L10n.format(newKey, "Game.exe"), "Future upstream feature Game.exe")
        }
    }

    func testChineseVerdictAndCurrentUpstreamPlan() throws {
        use("zh-Hans")
        let verdict = GamePageCopy.verdict(nil, myChip: "Apple M4 Pro")
        XCTAssertTrue(verdict.headline.contains("M4 Pro"))
        XCTAssertFalse(verdict.headline.contains("Nobody"))
        let plans = GamePageCopy.willDo(nil, recipe: nil, applied: false, bottleRenderer: .dxmt,
                                      explicit: true, needsDirect3D12: true)
        XCTAssertTrue(plans[0].text.contains("DirectX 12"))
        XCTAssertTrue(plans[0].text.contains("DXMT"))
        XCTAssertTrue(plans[0].text.contains("环境"))
        XCTAssertEqual(GamePageCopy.describe(.frameCap(60)), "将帧率限制为 60")
    }

    func testRecoveryPreservesActionAndArgumentOrder() {
        use("zh-Hans")
        let broken = Recovery.describe(HighballError.engineDamaged(engine: "engine-ID", files: ["ntdll.dll"]))
        XCTAssertTrue(broken.meaning.contains("ntdll.dll 从引擎 engine-ID 中丢失"))
        XCTAssertEqual(broken.action, .reinstallEngine("engine-ID"))
        let error = Recovery.describe(HighballError.processFailed(command: "gogdl download", status: 1, output: "raw error"))
        XCTAssertEqual(error.headline, "GOG 因错误而停止。")
        XCTAssertEqual(error.action, .retry)
        let raw = "Unknown upstream error: /tmp/Game.exe 100%"
        XCTAssertEqual(Recovery.describe(HighballError.failed(raw)).headline, raw)
    }

    func testUninstallExplainsSaveDataWithoutChangingRoute() {
        let route = Uninstall.Route.epic(appName: "Game")
        let text = Uninstall.confirmation(route: route, sizeOnDisk: 0, language: .zhHans)
        XCTAssertTrue(text.contains("不会备份任何内容"))
        XCTAssertTrue(text.contains("Epic 云存档都会保留"))
        XCTAssertTrue(Uninstall.isActionable(route))
        XCTAssertTrue(Uninstall.confirmation(route: route, sizeOnDisk: 0).hasPrefix("The Epic tools"))
    }

    func testChineseTransferKeepsGigabyteSupportAndStepParsing() {
        use("zh-Hans")
        XCTAssertEqual(ActivityText.transfer(received: 1 << 30, total: 2 << 30, rate: nil), "1.0 / 2.0 GB")
        XCTAssertEqual(ActivityText.transfer(received: 512 * 1024, total: 1024 * 1024, rate: nil), "0 / 1 MB")
        XCTAssertEqual(L10n.activityStage("Step 2 of 3 — Game %@.exe"), "第 2 步，共 3 步 — Game %@.exe")
        XCTAssertEqual(L10n.activityStage("Steam is updating itself — 1,000 of 2,000 KB"), "Steam 正在更新 — 1,000 / 2,000 KB")
        XCTAssertEqual(L10n.activityStage("Unrecognized future stage"), "Unrecognized future stage")
        XCTAssertEqual(ActivityText.steps(in: "Step 2 of 3 — Game.exe")?.done, 2)
        XCTAssertEqual(ActivityText.fraction(received: 50, total: 100), 0.5)
    }
}
