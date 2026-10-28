// Launcher.swift - the start screen (SwiftUI): a title page on the left, the settings on an "instruction manual" page on
// the right. Art and colours come from the player's own copy at runtime: the app icon tools/make_ipa.py makes from
// Tunic.app's PlayerIcon.icns. Nothing from the game ships in the repo. The shim (MacShim.m) creates it through
// MSSwiftLauncher.make(...) and gets resolution + performance overlay back in onPlay; every other choice is in
// UserDefaults - CyPort* = CyPort's own settings (unchanged), Port* = the mobile kit's (shared with the in-game Phone
// Settings panel, TunicControls.m), TunicMetalHUD.
import SwiftUI
import UIKit

/// the colour between the start screen and the game (MacShim.m MSTunicNight): Play fades into it, no flash
private let night = Color(red: 0.067, green: 0.082, blue: 0.090)

/// colours sampled from the game's icon art; Tunic-like fallbacks (warm paper, deep ink, ember) if it can't be read
private struct Palette {
    var paper = Color(red: 0.96, green: 0.93, blue: 0.86)
    var desk = Color(red: 0.88, green: 0.83, blue: 0.74)
    var ink = Color(red: 0.13, green: 0.17, blue: 0.19)
    var accent = Color(red: 0.89, green: 0.52, blue: 0.24)
    var uiInk = UIColor(red: 0.13, green: 0.17, blue: 0.19, alpha: 1)
    var uiAccent = UIColor(red: 0.89, green: 0.52, blue: 0.24, alpha: 1)
    var uiDesk = UIColor(red: 0.88, green: 0.83, blue: 0.74, alpha: 1)
    var art: UIImage?

    static func load() -> Palette {
        var p = Palette()
        guard let path = Bundle.main.path(forResource: "AppIcon60x60@2x", ofType: "png"),
              let img = UIImage(contentsOfFile: path), let cg = img.cgImage else { return p }
        p.art = img
        let n = 24
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return p }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var hsb: [(h: CGFloat, s: CGFloat, b: CGFloat)] = []
        for i in 0..<(n * n) where px[i * 4 + 3] > 200 {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(red: CGFloat(px[i * 4]) / 255, green: CGFloat(px[i * 4 + 1]) / 255, blue: CGFloat(px[i * 4 + 2]) / 255, alpha: 1)
                .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            hsb.append((h, s, b))
        }
        guard hsb.count > 40 else { return p }
        // accent: the art's most saturated mid-bright colour, kept readable under dark ink text
        if let a = hsb.filter({ $0.b > 0.45 && $0.s > 0.35 }).max(by: { $0.s * $0.b < $1.s * $1.b }) {
            p.uiAccent = UIColor(hue: a.h, saturation: min(max(a.s, 0.45), 0.80), brightness: min(max(a.b, 0.72), 0.92), alpha: 1)
        }
        // ink: the art's dark tones, deepened
        let dark = hsb.sorted { $0.b < $1.b }.prefix(max(8, hsb.count / 5))
        let dh = dark.map { $0.h }.reduce(0, +) / CGFloat(dark.count), ds = dark.map { $0.s }.reduce(0, +) / CGFloat(dark.count)
        p.uiInk = UIColor(hue: dh, saturation: min(max(ds, 0.25), 0.55), brightness: 0.20, alpha: 1)
        // paper + desk: the art's light tones, nearly white - the page is tinted by the art, not coloured by it
        let light = hsb.sorted { $0.b > $1.b }.prefix(max(8, hsb.count / 4))
        let lh = light.map { $0.h }.reduce(0, +) / CGFloat(light.count)
        let paperUI = UIColor(hue: lh, saturation: 0.09, brightness: 0.97, alpha: 1)
        p.uiDesk = UIColor(hue: lh, saturation: 0.15, brightness: 0.86, alpha: 1)
        p.paper = Color(uiColor: paperUI); p.desk = Color(uiColor: p.uiDesk)
        p.ink = Color(uiColor: p.uiInk); p.accent = Color(uiColor: p.uiAccent)
        return p
    }
}

private final class LauncherModel: ObservableObject {
    let resolutions: [String]
    let notes: [String]
    @Published var resolution: Int
    @Published var overlay: Int
    @Published var starting = false
    let onPlay: (Int, Int) -> Void
    init(resolutions: [String], notes: [String], resolution: Int, overlay: Int, onPlay: @escaping (Int, Int) -> Void) {
        self.resolutions = resolutions; self.notes = notes; self.resolution = resolution; self.overlay = overlay; self.onPlay = onPlay
    }
}

/// a little give under the finger
private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// paper grain: fixed speckle (seeded, the same every time), drawn once
private struct Grain: View {
    let ink: Color
    var body: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 0x7E57_C0DE
            func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
            let count = Int(size.width * size.height / 260)
            for _ in 0..<count {
                let r = rnd() * 0.9 + 0.3
                ctx.fill(Path(ellipseIn: CGRect(x: rnd() * size.width, y: rnd() * size.height, width: r, height: r)),
                         with: .color(ink.opacity(0.035 + rnd() * 0.03)))
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

private struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let pal: Palette
    // CyPort's settings (unchanged meaning, read by MacShim.m)
    @AppStorage("CyPortLookSensitivity") private var lookSensitivity = 1.5
    @AppStorage("CyPortLowLatency") private var lowLatency = false
    @AppStorage("CyPortSmoothPacing") private var smoothPacing = true
    // the mobile kit's settings (shared with the in-game Phone Settings panel)
    @AppStorage("PortAspect") private var aspect = 0
    @AppStorage("PortScaling") private var scaling = 0
    @AppStorage("PortFrameRate") private var frameRate = 1
    @AppStorage("PortTouchControls") private var touchControls = true
    @AppStorage("PortTouchOpacity") private var touchOpacity = 65
    @AppStorage("PortTouchSize") private var touchSize = 100
    @AppStorage("PortFloatingStick") private var floatingStick = false
    @AppStorage("PortHaptics") private var haptics = true
    @AppStorage("TunicMetalHUD") private var metalHUD = false
    @State private var appeared = false
    @State private var leaving = false

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    private var dataWhere: String {
        let fm = FileManager.default
        if fm.fileExists(atPath: Bundle.main.bundlePath + "/Game/Resources/Data/data.unity3d") { return "Inside the app" }
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""
        if fm.fileExists(atPath: docs + "/Tunic/Data/data.unity3d") { return "Imported to this \(device)" }
        return "Not found"
    }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    private func tick() { UISelectionFeedbackGenerator().selectionChanged() }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                pal.desk.ignoresSafeArea()
                Grain(ink: pal.ink).ignoresSafeArea()
                HStack(spacing: 0) {
                    titlePage(height: geo.size.height)
                        .frame(width: geo.size.width * 0.40)
                    manualPage
                        .padding(.vertical, 14).padding(.trailing, 16)
                        .offset(x: appeared ? 0 : 24)
                }
                .opacity(appeared ? 1 : 0)
                night.ignoresSafeArea().opacity(leaving ? 1 : 0).allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.light)
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { appeared = true } }
        .onChange(of: aspect) { _ in tick() }.onChange(of: scaling) { _ in tick() }.onChange(of: frameRate) { _ in tick() }
        .onChange(of: touchControls) { _ in tick() }.onChange(of: floatingStick) { _ in tick() }.onChange(of: haptics) { _ in tick() }
        .onChange(of: metalHUD) { _ in tick() }.onChange(of: smoothPacing) { _ in tick() }.onChange(of: lowLatency) { _ in tick() }
        .onChange(of: model.overlay) { _ in tick() }.onChange(of: model.resolution) { _ in tick() }
    }

    // MARK: title page

    private func titlePage(height: CGFloat) -> some View {
        let art = min(height * 0.36, 150)
        return VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 8)
            if let img = pal.art {
                Image(uiImage: img).resizable().interpolation(.high).aspectRatio(1, contentMode: .fit)
                    .frame(width: art, height: art)
                    .clipShape(RoundedRectangle(cornerRadius: art * 0.22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: art * 0.22, style: .continuous).stroke(pal.ink.opacity(0.12), lineWidth: 1))
                    .shadow(color: pal.ink.opacity(0.22), radius: 14, y: 8)
            }
            Text("TUNIC")
                .font(.system(size: 44, weight: .semibold, design: .serif)).tracking(11)
                .foregroundStyle(pal.ink).padding(.top, 18)
            Text("Your copy of the Mac game, on this \(device).")
                .font(.system(.footnote, design: .serif)).italic()
                .foregroundStyle(pal.ink.opacity(0.62)).padding(.top, 2)
            Button(action: play) {
                HStack(spacing: 10) {
                    if model.starting { ProgressView().tint(pal.ink) } else { Image(systemName: "play.fill").font(.system(size: 14, weight: .bold)) }
                    Text(model.starting ? "Starting" : "Play").font(.system(size: 19, weight: .semibold, design: .serif)).tracking(1.5)
                }
                .foregroundStyle(pal.ink)
                .frame(width: 200, height: 50)
                .background(pal.accent, in: Capsule())
                .overlay(Capsule().stroke(pal.ink.opacity(0.20), lineWidth: 1))
            }
            .buttonStyle(PressScale())
            .disabled(model.starting)
            .padding(.top, 22)
            Text("Version \(version)  ·  game data: \(dataWhere.lowercased())")
                .font(.caption2).foregroundStyle(pal.ink.opacity(0.45)).padding(.top, 12)
            Spacer(minLength: 8)
        }
        .padding(.leading, 30).padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func play() {
        guard !model.starting else { return }
        model.starting = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeIn(duration: 0.28)) { leaving = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.onPlay(model.resolution, model.overlay) }
    }

    // MARK: manual page

    private var manualPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                section(1, "Display") {
                    row("Resolution", note: model.notes[model.resolution].isEmpty ? nil : model.notes[model.resolution].capitalizedFirst) {
                        chipMenu(model.resolutions[model.resolution]) {
                            Picker("Resolution", selection: $model.resolution) {
                                ForEach(Array(model.resolutions.enumerated()).reversed(), id: \.offset) { i, r in
                                    Text(model.notes[i].isEmpty ? r : "\(r)  ·  \(model.notes[i])").tag(i)
                                }
                            }
                        }
                    }
                    row("Aspect ratio") {
                        chipMenu(["iPhone Default", "1.943:1", "16:9", "4:3"][max(0, min(3, aspect))]) {
                            Picker("Aspect ratio", selection: $aspect) {
                                Text("iPhone Default").tag(0); Text("1.943:1").tag(1); Text("16:9").tag(2); Text("4:3").tag(3)
                            }
                        }
                    }
                    row("Screen scaling", note: aspect == 0 ? "Used when the aspect ratio isn't iPhone Default." : nil) {
                        Picker("Screen scaling", selection: $scaling) { Text("Fit").tag(0); Text("Stretch").tag(1) }
                            .pickerStyle(.segmented).frame(width: 170).disabled(aspect == 0)
                    }
                    row("Frame rate", note: frameRate == 2 ? "120 needs a ProMotion screen." : nil) {
                        Picker("Frame rate", selection: $frameRate) { Text("30").tag(0); Text("60").tag(1); Text("120").tag(2) }
                            .pickerStyle(.segmented).frame(width: 170)
                    }
                }
                section(2, "Controls") {
                    row("Touch controls") { toggle($touchControls) }
                    row("Touch opacity") { slider(Binding(get: { Double(touchOpacity) }, set: { touchOpacity = Int($0) }), 20...100, step: 5, "\(touchOpacity)%") }
                    row("Touch size") { slider(Binding(get: { Double(touchSize) }, set: { touchSize = Int($0) }), 70...150, step: 10, "\(touchSize)%") }
                    row("Left stick") {
                        Picker("Left stick", selection: $floatingStick) { Text("Fixed").tag(false); Text("Floating").tag(true) }
                            .pickerStyle(.segmented).frame(width: 170)
                    }
                    row("Vibration") { toggle($haptics) }
                    row("Look sensitivity", note: "How fast the right stick turns.") {
                        slider($lookSensitivity, 0.25...4, step: 0.05, String(format: "%.1f×", lookSensitivity))
                    }
                    row("Low-latency input", note: lowLatency ? "Snappier controls. Costs a few FPS when the GPU is the limit." : "Off: best frame rate.") { toggle($lowLatency) }
                }
                section(3, "Performance") {
                    row("Performance overlay") {
                        Picker("Performance overlay", selection: $model.overlay) { Text("Off").tag(0); Text("FPS").tag(1); Text("Detailed").tag(2) }
                            .pickerStyle(.segmented).frame(width: 200)
                    }
                    row("Metal HUD", note: "The resolution the game really renders, against the screen's, with FPS, frame time and memory. Apple's own HUD: Settings › Developer › Graphics HUD.") { toggle($metalHUD) }
                    row("Smooth frame pacing", note: smoothPacing ? "Even frame times: holds 120, 60, 40 or 30 FPS, whatever the \(device) keeps up with." : "Off: the frame rate setting only.") { toggle($smoothPacing) }
                }
                section(4, "Data") {
                    row("Game data") { Text(dataWhere).font(.system(size: 15, design: .serif)).foregroundStyle(pal.ink.opacity(0.7)) }
                    row("Saves") { Text("Kept on this \(device)").font(.system(size: 15, design: .serif)).foregroundStyle(pal.ink.opacity(0.7)) }
                }
                Text("The same display and touch settings are in the game too: tap the gear at the top of the screen.")
                    .font(.system(.caption, design: .serif)).italic().foregroundStyle(pal.ink.opacity(0.5))
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(pal.paper)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(pal.ink.opacity(0.10), lineWidth: 1))
                .shadow(color: pal.ink.opacity(0.14), radius: 18, y: 8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .tint(pal.accent)
    }

    // MARK: pieces

    private func section<C: View>(_ n: Int, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("\(n)").font(.system(size: 12, weight: .bold, design: .serif)).foregroundStyle(pal.paper)
                    .frame(width: 22, height: 22).background(pal.ink, in: Circle())
                Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(2.4).foregroundStyle(pal.ink.opacity(0.75))
                Rectangle().fill(pal.ink.opacity(0.15)).frame(height: 1)
            }
            content()
        }
    }
    private func row<C: View>(_ title: String, note: String? = nil, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 12) {
                Text(title).font(.system(size: 16, design: .serif)).foregroundStyle(pal.ink).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                control()
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(pal.ink.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func toggle(_ b: Binding<Bool>) -> some View { Toggle("", isOn: b).labelsHidden().fixedSize() }
    private func slider(_ v: Binding<Double>, _ range: ClosedRange<Double>, step: Double, _ label: String) -> some View {
        HStack(spacing: 10) {
            Slider(value: v, in: range, step: step).frame(width: 130)
            Text(label).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(pal.ink).frame(width: 46, alignment: .trailing)
        }
    }
    private func chipMenu<C: View>(_ value: String, @ViewBuilder _ content: () -> C) -> some View {
        Menu { content() } label: {
            HStack(spacing: 6) {
                Text(value).font(.system(size: 15, weight: .medium).monospacedDigit())
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(pal.ink)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(pal.ink.opacity(0.07), in: Capsule())
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

private final class LauncherHostingController: UIHostingController<LauncherView> {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
}

@objc(MSSwiftLauncher) public final class MSSwiftLauncher: NSObject {
    /// resolutions/notes indexed like the shim's display modes (smallest first); onPlay(resolutionIndex, overlay)
    @objc public static func make(resolutions: [String], notes: [String], current: Int, overlay: Int,
                                  onPlay: @escaping (Int, Int) -> Void) -> UIViewController {
        let pal = Palette.load()
        // segmented controls in the page's colours (UIKit underneath SwiftUI's segmented pickers)
        let seg = UISegmentedControl.appearance()
        seg.selectedSegmentTintColor = pal.uiAccent
        seg.setTitleTextAttributes([.foregroundColor: pal.uiInk], for: .normal)
        seg.setTitleTextAttributes([.foregroundColor: pal.uiInk, .font: UIFont.systemFont(ofSize: 13, weight: .semibold)], for: .selected)
        let model = LauncherModel(resolutions: resolutions, notes: notes,
                                  resolution: max(0, min(current, resolutions.count - 1)), overlay: max(0, min(overlay, 2)), onPlay: onPlay)
        let vc = LauncherHostingController(rootView: LauncherView(model: model, pal: pal))
        vc.view.backgroundColor = pal.uiDesk
        return vc
    }
}
