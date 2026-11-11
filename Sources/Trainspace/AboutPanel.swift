import AppKit

/// The standard About panel, with the data credits, licenses and notes every source asks for.
@MainActor
enum AboutPanel {
    static func show() {
        let c = CreditsText()
        c.heading("Train data")
        c.text("Live positions, trip updates and timetables from each railway's public feeds: ")
        c.link("WMATA", "https://developer.wmata.com", then: "; ")
        c.link("MDOT MTA", "https://www.mta.maryland.gov/developer-resources", then: " (MARC, Light RailLink and Metro SubwayLink, live via Swiftly); ")
        c.link("VRE", "https://www.vre.org", then: "; ")
        c.link("Amtrak", "https://www.amtrak.com", then: "; ")
        c.link("MTA", "https://www.mta.info/developers", then: " (New York City Transit, Staten Island Railway, LIRR, Metro-North); ")
        c.link("NJ TRANSIT", "https://www.njtransit.com/developer-tools", then: "; ")
        c.text("PATH (Port Authority of New York and New Jersey); ")
        c.link("SEPTA", "https://www3.septa.org/gtfsrt/", then: "; PATCO; and the MBTA. ")
        c.text("MBTA data is provided by the Massachusetts Department of Transportation (MassDOT). Some timetables come via the ")
        c.link("Mobility Database", "https://mobilitydatabase.org", then: ".\n")
        c.text("Map: ")
        c.link("Natural Earth", "https://www.naturalearthdata.com", then: " (public domain). Apple Map style: © Apple Maps.\n")
        c.heading("Please note")
        c.text("Trainspace isn't affiliated with or endorsed by any of these railways or agencies. Train positions and times may not be real time and can be wrong or missing; hollow trains are estimated from the timetable. Check with the railway before you travel.\n")
        c.heading("Typefaces")
        c.text("Roboto, Montserrat, Open Sans and Public Sans, under the SIL Open Font License 1.1 (license files are in the app's Resources/Fonts). The dot-matrix lettering is original.\n")
        c.heading("Privacy")
        c.text("Your location isn't sent to any train feed, and nothing is sent to the developer. ")
        c.link("Privacy policy", "https://grantkovich.com/privacy/", then: "\n")
        c.heading("Made by")
        c.link("Grant Kovich", "https://grantkovich.com", then: " · ")
        c.link("Feedback", "https://grantkovich.com/contact/", then: "")
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: c.string])
    }
}

/// Small builder for the About panel's credits.
@MainActor
final class CreditsText {
    let string = NSMutableAttributedString()
    private let body: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        .foregroundColor: NSColor.labelColor,
    ]

    func heading(_ s: String) {
        if string.length > 0 { string.append(NSAttributedString(string: "\n", attributes: body)) }
        string.append(NSAttributedString(string: s + "\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]))
    }

    func text(_ s: String) { string.append(NSAttributedString(string: s, attributes: body)) }

    func link(_ title: String, _ url: String, then: String) {
        var attrs = body
        attrs[.link] = URL(string: url)
        string.append(NSAttributedString(string: title, attributes: attrs))
        text(then)
    }

    func line(_ lead: String, link title: String, _ url: String, then: String) {
        text(lead)
        link(title, url, then: then)
    }
}
