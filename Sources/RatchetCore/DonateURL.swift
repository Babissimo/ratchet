// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where "Donate" goes. The site's footer and demo menu, and `.github/FUNDING.yml`, point at the
/// same GitHub Sponsors profile, so change them together. Nil keeps the item out of the menu.
public enum DonateURL {
    public static let page: URL? = URL(string: "https://github.com/sponsors/Babissimo")
}
