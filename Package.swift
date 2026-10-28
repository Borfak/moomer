// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Moomer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "moomer", targets: ["Moomer"]),
        .executable(name: "moomer-capture-load", targets: ["CaptureLoad"]),
        .executable(name: "moomer-audit-host", targets: ["AuditHost"])
    ],
    targets: [
        .target(name: "MoomerCore"),
        .executableTarget(name: "CaptureLoad", path: "Tools/CaptureLoad"),
        .executableTarget(name: "AuditHost", path: "Tools/AuditHost"),
        .executableTarget(
            name: "Moomer",
            dependencies: ["MoomerCore"],
            resources: [.copy("Shaders")]
        ),
        .testTarget(name: "MoomerTests", dependencies: ["MoomerCore", "Moomer"])
    ]
)
