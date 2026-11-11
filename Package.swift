// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "Rift",
	platforms: [.macOS(.v14)],
	products: [
		.library(name: "Rift", targets: ["Rift"]),
		.library(name: "RiftCore", targets: ["RiftCore"]),
		.executable(name: "RiftDemo", targets: ["RiftDemo"]),
	],
	targets: [
		// Platform-independent layout tree, geometry and interaction math.
		.target(name: "RiftCore"),
		// AppKit view, pane drag & drop, SwiftUI wrapper.
		.target(name: "Rift", dependencies: ["RiftCore"]),
		.executableTarget(name: "RiftDemo", dependencies: ["Rift"], exclude: ["Themes"]),
		.testTarget(name: "RiftCoreTests", dependencies: ["RiftCore"]),
	]
)
