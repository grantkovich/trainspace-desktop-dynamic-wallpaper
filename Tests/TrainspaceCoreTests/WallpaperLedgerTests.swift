import Foundation
import Testing
@testable import TrainspaceCore

@Suite struct WallpaperLedgerTests {
    let app = "Trainspace"
    let still = "/Users/me/Library/Containers/com.grantkovich.trainspace/Data/Library/Application Support/Trainspace/Wallpapers/display-1-a.jpg"
    let oldStill = "/Users/me/Library/Containers/com.trainspace.wallpaper/Data/Library/Application Support/Trainspace/Wallpapers/display-1-b.jpg"
    let mine = "/Users/me/Pictures/Lake.heic"

    @Test func recognisesStillsFromAnyBundleID() {
        #expect(WallpaperLedger.isOurs(still, appName: app))
        #expect(WallpaperLedger.isOurs(oldStill, appName: app))
        #expect(!WallpaperLedger.isOurs(mine, appName: app))
        #expect(!WallpaperLedger.isOurs("/System/Library/Desktop Pictures/Sonoma.heic", appName: app))
    }

    @Test func remembersTheUsersPictureNotOurs() {
        var ledger = WallpaperLedger()
        ledger.observe(display: "A", current: mine, appName: app)
        ledger.observe(display: "A", current: still, appName: app)   // our still went on
        #expect(ledger.originals["A"] == mine)
        #expect(ledger.restoreAction(display: "A", current: still, appName: app) == .restore(mine))
    }

    @Test func leavesTheUsersPictureAlone() {
        var ledger = WallpaperLedger()
        ledger.observe(display: "A", current: mine, appName: app)
        #expect(ledger.restoreAction(display: "A", current: "/Users/me/Pictures/New.jpg", appName: app) == .nothingToDo)
        #expect(ledger.restoreAction(display: "A", current: nil, appName: app) == .nothingToDo)
    }

    /// The bug this replaces: after a failed restore the record was deleted, the next still went
    /// on top of the old still, and the user's picture was lost for good.
    @Test func keepsOriginalsAfterRestoringSoOtherSpacesCanBeFixed() {
        var ledger = WallpaperLedger()
        ledger.observe(display: "A", current: mine, appName: app)
        ledger.restored(display: "A")
        #expect(ledger.restoreAction(display: "A", current: still, appName: app) == .restore(mine))
        ledger.observe(display: "A", current: oldStill, appName: app)   // a still, not a new original
        #expect(ledger.originals["A"] == mine)
    }

    @Test func flagsAStillWithNoRecordForManualRestore() {
        var ledger = WallpaperLedger()
        #expect(ledger.restoreAction(display: "B", current: oldStill, appName: app) == .unknown)
        ledger.failed(display: "B")
        #expect(ledger.needsManualRestore)
        ledger.chose(mine, for: ["B"])
        #expect(!ledger.needsManualRestore)
        #expect(ledger.restoreAction(display: "B", current: still, appName: app) == .restore(mine))
    }

    @Test func aNewPictureClearsTheStuckFlag() {
        var ledger = WallpaperLedger()
        ledger.failed(display: "A")
        ledger.observe(display: "A", current: mine, appName: app)
        #expect(!ledger.needsManualRestore)
    }

    @Test func roundTripsThroughJSON() throws {
        var ledger = WallpaperLedger()
        ledger.observe(display: "A", current: mine, appName: app)
        ledger.failed(display: "B")
        let data = try JSONEncoder().encode(ledger)
        #expect(try JSONDecoder().decode(WallpaperLedger.self, from: data) == ledger)
    }
}
