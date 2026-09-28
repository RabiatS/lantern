// swift-tools-version: 6.0
// Apple's Stable Diffusion port from mlx-swift-examples (MIT, see LICENSE),
// carried here as a local package because the upstream manifest declares iOS 16
// while MLX requires iOS 17, which stops it building as a dependency.
import PackageDescription

let package = Package(
    name: "StableDiffusionKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "StableDiffusion", targets: ["StableDiffusion"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.4")),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMajor(from: "1.3.0")),
    ],
    targets: [
        .target(
            name: "StableDiffusion",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "Sources/StableDiffusion",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
