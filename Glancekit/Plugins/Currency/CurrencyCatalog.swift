import Foundation

/// Static ISO-4217 currency metadata used by the Currency glance's settings UI.
///
/// The code list is derived once from `Locale.commonISOCurrencyCodes` so the
/// picker offers real, selectable codes instead of a free-text field. Localized
/// names, symbols and flag emoji are best-effort niceties layered on top.
enum CurrencyCatalog {
    /// All common ISO currency codes, uppercased and sorted.
    static let codes: [String] = Locale.commonISOCurrencyCodes
        .map { $0.uppercased() }
        .sorted()

    /// A localized human name for a currency code, e.g. "US Dollar" for "USD".
    /// Falls back to the raw code when the platform has no name for it.
    static func name(for code: String) -> String {
        Locale.current.localizedString(forCurrencyCode: code.uppercased()) ?? code.uppercased()
    }

    /// The currency's symbol where the platform knows one (e.g. "$", "€", "¥").
    /// Returns `nil` when no distinct symbol is available.
    static func symbol(for code: String) -> String? {
        let upper = code.uppercased()
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = upper
        // When a symbol is unknown, Foundation echoes the code back — treat that
        // (and an empty string) as "no distinct symbol".
        if let symbol = fmt.currencySymbol, !symbol.isEmpty, symbol.uppercased() != upper {
            return symbol
        }
        return nil
    }

    /// A flag emoji for the currency, derived from the first two letters of the
    /// code (which for most currencies is the ISO country code). Special-cased
    /// for the euro; returns `nil` for metals/funds (X-prefixed) and anything
    /// that doesn't map to a plausible region.
    static func flag(for code: String) -> String? {
        let upper = code.uppercased()
        if upper == "EUR" { return "🇪🇺" }
        // X-prefixed codes are supranational / metals / test codes (XAU, XDR…).
        guard upper.count >= 2, !upper.hasPrefix("X") else { return nil }
        let region = String(upper.prefix(2))
        var scalars = ""
        for ch in region.unicodeScalars {
            guard ch.value >= 65, ch.value <= 90,
                  let scalar = Unicode.Scalar(0x1F1E6 + (ch.value - 65)) else {
                return nil
            }
            scalars.unicodeScalars.append(scalar)
        }
        return scalars.isEmpty ? nil : scalars
    }

    /// A compact label combining flag, code and localized name for pickers/rows,
    /// e.g. "🇺🇸 USD — US Dollar".
    static func label(for code: String) -> String {
        let upper = code.uppercased()
        let name = name(for: upper)
        if let flag = flag(for: upper) {
            return "\(flag) \(upper) — \(name)"
        }
        return "\(upper) — \(name)"
    }
}
