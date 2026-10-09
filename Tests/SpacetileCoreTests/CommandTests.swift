import Testing
@testable import SpacetileCore

@Suite struct CommandParsing {
    @Test(arguments: [
        ("focus west", Command?.some(.focus(.west))),
        ("swap south", .swap(.south)),
        ("border horizontal -100", .moveBorder(.horizontal, -100)),
        ("layout stack", .setLayout(.stack)),
        ("rotate 270", .rotate(.threeQuarter)),
        ("zoom", .toggleZoom),
        ("space 10", .focusSpace(10)),
        ("send 3", .sendToSpace(3)),
        ("stack prev", .cycleStack(forward: false)),
        ("stack up", nil),
        ("capture studio desk", .capture("studio desk")),
        ("load laptop", .load("laptop")),
        ("preselect north", .preselect(.north)),
        ("join east", .join(.east)),
        ("split", .toggleSplit),
        ("space next", .stepSpace(forward: true)),
        ("space last", .lastSpace),
        ("place left", .place(.edge(.west, fraction: nil))),
        ("place right 3/4", .place(.edge(.east, fraction: 0.75))),
        ("place top-left", .place(.corner(vertical: .north, horizontal: .west))),
        ("place center", .place(.center)),
        ("place bottom-right-sixth", .place(.sixth(column: 2, row: 1))),
        ("place left-top", nil),
        ("place left 2", nil),
        ("send next", .sendStep(forward: true)),
        ("pause", .togglePause),
        ("settings", .openSettings),
        ("display next", .focusDisplay(forward: true)),
        ("display prev", .focusDisplay(forward: false)),
        ("send display next", .sendToDisplay(forward: true)),
        ("send display left", nil),
        ("grow", .resize(grow: true)),
        ("pop out", .popOut),
        ("pop in", .popIn),
        ("pop", nil),
        ("ratio", nil),
        ("focus up", nil),
        ("border vertical", nil),
        ("", nil),
    ])
    func parses(text: String, expected: Command?) {
        #expect(Command(text) == expected)
    }
}
