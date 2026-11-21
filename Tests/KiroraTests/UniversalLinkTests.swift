import Foundation
import Testing
@testable import Kirora

@Suite("Universal links")
struct UniversalLinkTests {
    /// Only hosts the app lists are its own: Flutter's and React Native's app delegates say
    /// they handled any web link, so their answer can't decide.
    @Test func onlyListedHostsStayInTheApp() {
        let hosts = ["shop.example.com", "*.example.org"]
        let own = [
            "https://shop.example.com/orders/1", "http://SHOP.example.com/", "https://a.example.org/x",
            "https://a.b.example.org/",
        ]
        let opened = [
            "https://dev.monietab.com/kiroraTestPage", "https://example.com/", "https://example.org/",
            "https://shop.example.com.evil.test/", "https://notexample.org/", "myapp://orders/1",
        ]
        for link in own { #expect(isOwnUniversalLink(URL(string: link)!, hosts: hosts), "\(link)") }
        for link in opened { #expect(!isOwnUniversalLink(URL(string: link)!, hosts: hosts), "\(link)") }
    }

    @Test func noHostsListedOpensEveryLink() {
        #expect(!isOwnUniversalLink(URL(string: "https://shop.example.com/")!, hosts: []))
        #expect(universalLinkHosts.isEmpty)
    }
}
