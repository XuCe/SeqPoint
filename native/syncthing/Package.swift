// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SeqpointSyncthing",
    platforms: [.iOS(.v15)],
    products: [.library(name: "SeqpointSyncthing", targets: ["SeqpointSyncthing"])],
    targets: [.binaryTarget(
        name: "SeqpointSyncthing",
        path: "artifacts/SeqpointSyncthing.xcframework"
    )]
)
