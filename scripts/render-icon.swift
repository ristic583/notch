// Renders Resources/AppIcon.svg into Resources/AppIcon.png (1024 px, transparent).
// Quick Look draws the SVG with WebKit but on a white page, so the icon body is
// cut back out along Apple's grid: an 824 body, corner radius 185.
//
//   swift scripts/render-icon.swift   (scripts/make-icon.sh runs it)
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let svg = root.appendingPathComponent("Resources/AppIcon.svg")
let output = root.appendingPathComponent("Resources/AppIcon.png")
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("notch-icon-render")
try? FileManager.default.removeItem(at: scratch)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

let quickLook = Process()
quickLook.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
quickLook.arguments = ["-t", "-s", "1024", "-o", scratch.path, svg.path]
quickLook.standardOutput = FileHandle.nullDevice
quickLook.standardError = FileHandle.nullDevice
try quickLook.run()
quickLook.waitUntilExit()

let rendered = scratch.appendingPathComponent("AppIcon.svg.png")
guard let image = NSImage(contentsOf: rendered)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
      image.width == 1024 else {
    FileHandle.standardError.write(Data("Quick Look couldn't render \(svg.path)\n".utf8))
    exit(1)
}
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                       cornerWidth: 185, cornerHeight: 185, transform: nil))
context.clip()
context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("Wrote Resources/AppIcon.png")
