import AppKit

let destination = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.14, green: 0.32, blue: 0.24, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 180, yRadius: 180).fill()
NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.91, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 253, y: 220, width: 518, height: 614), xRadius: 45, yRadius: 45).fill()
NSColor(calibratedRed: 0.78, green: 0.83, blue: 0.74, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 280, y: 246, width: 16, height: 560), xRadius: 6, yRadius: 6).fill()
NSColor(calibratedRed: 0.14, green: 0.32, blue: 0.24, alpha: 1).setFill()
for (i, height) in [85.0, 160, 250, 180, 105].enumerated() {
    NSBezierPath(roundedRect: NSRect(x: 356 + Double(i)*65, y: 525-height/2, width: 30, height: height), xRadius: 15, yRadius: 15).fill()
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = bitmap.representation(using: .png, properties: [:])!
func bigEndian(_ value: UInt32) -> Data { var number = value.bigEndian; return withUnsafeBytes(of: &number) { Data($0) } }
var result = Data("icns".utf8)
result.append(bigEndian(UInt32(16 + png.count)))
result.append(Data("ic10".utf8))
result.append(bigEndian(UInt32(8 + png.count)))
result.append(png)
try result.write(to: URL(fileURLWithPath: destination))
