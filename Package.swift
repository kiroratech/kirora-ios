// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kirora",
    platforms: [
        .iOS(.v13),
        .macCatalyst(.v14),
        // The core builds and is tested on macOS too; push and lifecycle need UIKit.
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "Kirora", targets: ["Kirora"]),
        // For the app's Notification Service Extension: reports deliveries and shows
        // images. Depends on nothing else, as an extension should.
        .library(name: "KiroraNotificationService", targets: ["KiroraNotificationService"]),
    ],
    targets: [
        .target(
            name: "Kirora",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "KiroraNotificationService",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "KiroraTests", dependencies: ["Kirora", "KiroraNotificationService"]),
    ]
)
