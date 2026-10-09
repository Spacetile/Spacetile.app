import CoreGraphics
import Foundation
import Testing
@testable import SpacetileCore

@Suite struct DisplayToggles {
    @Test(arguments: [
        ("toggle spacing", Command?.some(.toggle(.spacing))),
        ("toggle border", .toggle(.border)),
        ("toggle dim", .toggle(.dim)),
        ("toggle", nil),
        ("toggle gaps", nil),
        ("toggle dim now", nil),
    ])
    func parse(text: String, command: Command?) {
        #expect(Command(text) == command)
        if let command { #expect(command.text == text) }
    }

    @Test func listedInKeys() {
        for setting in SettingToggle.allCases {
            #expect(KeyAction.listedCommands.contains(Command.toggle(setting).text))
        }
    }

    @Test func spacingOnBorderAndDimOffByDefault() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(Settings.default))
        #expect(decoded.usesSpacing)
        #expect(!decoded.showsActiveBorder)
        #expect(!decoded.dimsInactive)
    }

    @Test func spacingOffTilesEdgeToEdgeAndKeepsTheValues() {
        var settings = Settings.default
        settings.padding = 12
        settings.gap = 8
        settings.flip(.spacing)
        let off = settings.spacing(forDisplayWidth: 2000)
        #expect(off.padding == 0 && off.gap == 0)
        #expect(settings.padding == 12 && settings.gap == 8)
        settings.flip(.spacing)
        let on = settings.spacing(forDisplayWidth: 2000)
        #expect(on.padding == 12 && on.gap == 8)
    }

    @Test func flippingTwiceComesBack() {
        var settings = Settings.default
        settings.flip(.border)
        settings.flip(.dim)
        #expect(settings.showsActiveBorder && settings.dimsInactive)
        settings.flip(.border)
        settings.flip(.dim)
        #expect(!settings.showsActiveBorder && !settings.dimsInactive)
    }
}
