// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "hiredis-swift",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .library(name: "Hiredis", targets: ["Hiredis"])
  ],
  targets: [
    .target(
      name: "CHiredis",
      path: "Sources/CHiredis",
      sources: [
        "CHiredis.c",
        "Vendor/hiredis/alloc.c",
        "Vendor/hiredis/async.c",
        "Vendor/hiredis/hiredis.c",
        "Vendor/hiredis/net.c",
        "Vendor/hiredis/read.c",
        "Vendor/hiredis/sds.c",
        "Vendor/hiredis/sockcompat.c",
      ],
      publicHeadersPath: "include",
      cSettings: [
        .headerSearchPath("include/hiredis"),
        .headerSearchPath("Vendor/hiredis"),
      ]
    ),
    .target(
      name: "Hiredis",
      dependencies: ["CHiredis"]
    ),
    .testTarget(
      name: "HiredisTests",
      dependencies: ["Hiredis"]
    ),
  ],
  swiftLanguageModes: [.v6],
  cLanguageStandard: .c99
)
