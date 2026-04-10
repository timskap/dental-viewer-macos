// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DentalViewer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DentalViewer", targets: ["DentalViewer"])
    ],
    targets: [
        .executableTarget(
            name: "DentalViewer",
            path: "Sources/DentalViewer"
        )
    ]
)
