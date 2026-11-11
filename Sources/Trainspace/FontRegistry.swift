import CoreText
import Foundation

/// Registers the agency typefaces bundled in Resources/Fonts (Roboto, Montserrat, Open Sans;
/// open licences) for this process, so text and Core Text measurement can use them by name.
enum FontRegistry {
    static func registerBundledFonts() {
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Fonts")]
        guard let dir = dirs.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension.lowercased() == "ttf" {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered (a second call) is fine; anything else is worth a note.
                let e = error?.takeRetainedValue()
                if let e, CFErrorGetCode(e) != CTFontManagerError.alreadyRegistered.rawValue {
                    NSLog("Trainspace: couldn't register font %@: %@", url.lastPathComponent, String(describing: e))
                }
            }
        }
    }
}
