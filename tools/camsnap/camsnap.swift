// camsnap: grab one still from a macOS camera (e.g. Continuity Camera iPhone).
// usage: camsnap -l            list cameras
//        camsnap OUT.jpg [name-substring] [warmup-seconds]
import AVFoundation
import AppKit

let args = CommandLine.arguments
let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices

if args.count < 2 || args[1] == "-l" {
    for d in devices { print("\(d.localizedName)\t\(d.deviceType.rawValue)\t\(d.uniqueID)") }
    exit(0)
}
let out = URL(fileURLWithPath: args[1])
let want = args.count > 2 ? args[2].lowercased() : "iphone"
let warmup = args.count > 3 ? Double(args[3]) ?? 2.0 : 2.0
guard let dev = devices.first(where: { $0.localizedName.lowercased().contains(want) }) ?? devices.first else {
    FileHandle.standardError.write("no camera\n".data(using: .utf8)!); exit(1)
}

let sem = DispatchSemaphore(value: 0)
AVCaptureDevice.requestAccess(for: .video) { ok in
    if !ok { FileHandle.standardError.write("camera access denied\n".data(using: .utf8)!); exit(2) }
    sem.signal()
}
sem.wait()

final class Grab: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var start = Date(); let warmup: Double; let out: URL; var done = false
    init(warmup: Double, out: URL) { self.warmup = warmup; self.out = out }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        if done || Date().timeIntervalSince(start) < warmup { return }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        let rep = NSBitmapImageRep(ciImage: ci)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return }
        try? data.write(to: out); done = true
        print("\(out.path) \(rep.pixelsWide)x\(rep.pixelsHigh) from \(c.inputPorts.first?.input.description ?? "")")
        exit(0)
    }
}

let session = AVCaptureSession()
session.sessionPreset = .high
let input = try AVCaptureDeviceInput(device: dev)
session.addInput(input)
let output = AVCaptureVideoDataOutput()
output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
let grab = Grab(warmup: warmup, out: out)
output.setSampleBufferDelegate(grab, queue: DispatchQueue(label: "grab"))
session.addOutput(output)
FileHandle.standardError.write("using \(dev.localizedName)\n".data(using: .utf8)!)
session.startRunning()
DispatchQueue.main.asyncAfter(deadline: .now() + warmup + 10) {
    FileHandle.standardError.write("timeout\n".data(using: .utf8)!); exit(3)
}
RunLoop.main.run()
