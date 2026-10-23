// Bolo: hold a key, speak English or Hindi, and the words are typed wherever your cursor is.
// Speech recognition and the optional clean-up both run on the Mac (Apple's on-device models). Built for Raj Tries Ep 9.
import AppKit
import AVFoundation
import Speech
import FoundationModels
import ServiceManagement
import ApplicationServices

let ACCENT = NSColor(srgbRed: 0.898, green: 0.220, blue: 0.231, alpha: 1)   // #E5383B
let INK = NSColor(srgbRed: 0.10, green: 0.09, blue: 0.09, alpha: 1)
let MUTED = NSColor(srgbRed: 0.48, green: 0.44, blue: 0.43, alpha: 1)

// MARK: - Settings

enum Lang: String, CaseIterable { case auto, english, hindi
    var title: String { switch self { case .auto: return "Auto (English + Hindi)"; case .english: return "English"; case .hindi: return "Hindi" } }
}
enum HindiScript: String { case devanagari, roman }
enum Hotkey: String { case fn, rightOption
    var title: String { self == .fn ? "Hold fn (🌐)" : "Hold right ⌥ Option" }
    var keyCode: UInt16 { self == .fn ? 63 : 61 }
}
struct Settings {
    static let d = UserDefaults.standard
    static var lang: Lang { get { Lang(rawValue: d.string(forKey: "lang") ?? "") ?? .auto } set { d.set(newValue.rawValue, forKey: "lang") } }
    static var script: HindiScript { get { HindiScript(rawValue: d.string(forKey: "script") ?? "") ?? .roman } set { d.set(newValue.rawValue, forKey: "script") } }
    static var hotkey: Hotkey { get { Hotkey(rawValue: d.string(forKey: "hotkey") ?? "") ?? .fn } set { d.set(newValue.rawValue, forKey: "hotkey") } }
    static var cleanup: Bool { get { d.object(forKey: "cleanup") as? Bool ?? true } set { d.set(newValue, forKey: "cleanup") } }
    static var words: Int { get { d.integer(forKey: "words") } set { d.set(newValue, forKey: "words") } }
}

// MARK: - Speech: microphone -> Apple's on-device dictation model

struct BoloError: LocalizedError { let msg: String; var errorDescription: String? { msg } }

let EN = Locale(identifier: "en-IN"), HI = Locale(identifier: "hi-IN")

/// Makes sure the on-device model for each locale is installed (Hindi downloads once, the first time it's used).
func ensureModels(_ locales: [Locale], progress: ((Double) -> Void)? = nil) async throws {
    for l in locales {
        let t = DictationTranscriber(locale: l, preset: .longDictation)
        if await AssetInventory.status(forModules: [t]) == .installed { continue }
        guard let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) else { continue }
        let obs = req.progress.observe(\.fractionCompleted) { p, _ in progress?(p.fractionCompleted) }
        try await req.downloadAndInstall(); obs.invalidate()
    }
}

/// One utterance: feed audio buffers in, get the transcript out. In Auto mode English and Hindi listen
/// side by side and the more confident transcript wins.
final class Utterance {
    let locales: [Locale]
    private let transcribers: [DictationTranscriber]
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let stream: AsyncStream<AnalyzerInput>
    private var collectors: [Task<(String, Double), Error>] = []
    private var converter: AVAudioConverter?
    let format: AVAudioFormat

    init(locales: [Locale]) async throws {
        self.locales = locales
        transcribers = locales.map { DictationTranscriber(locale: $0, preset: .longDictation) }
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: transcribers) else { throw BoloError(msg: "No speech model for this language") }
        format = fmt
        (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        analyzer = SpeechAnalyzer(modules: transcribers)
        for t in transcribers {
            collectors.append(Task {
                var text = "", conf = 0.0, n = 0.0
                for try await r in t.results {
                    text += String(r.text.characters)
                    for run in r.text.runs { if let c = run.transcriptionConfidence { conf += c; n += 1 } }
                }
                return (text.trimmingCharacters(in: .whitespacesAndNewlines), n > 0 ? conf / n : 0)
            })
        }
        try await analyzer.start(inputSequence: stream)
    }

    func feed(_ buf: AVAudioPCMBuffer) {
        if buf.format == format { input.yield(AnalyzerInput(buffer: buf)); return }
        if converter == nil { converter = AVAudioConverter(from: buf.format, to: format) }
        guard let cv = converter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * format.sampleRate / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
        var used = false; var err: NSError?
        cv.convert(to: out, error: &err) { _, st in
            if used { st.pointee = .noDataNow; return nil }
            used = true; st.pointee = .haveData; return buf
        }
        if err == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    /// Finish listening; returns every model's transcript.
    func finish() async throws -> [(String, Double, Locale)] {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        var outs: [(String, Double, Locale)] = []
        for (i, c) in collectors.enumerated() { let (t, conf) = try await c.value; outs.append((t, conf, locales[i])) }
        if ProcessInfo.processInfo.environment["BOLO_DEBUG"] != nil { for o in outs { print(String(format: "  %@ english-words %.2f mix %.2f: %@", o.2.identifier, englishWordShare(o.0), englishMix(o.0), o.0)) } }
        return outs
    }
}

/// Share of letters that are Devanagari.
func devanagariShare(_ s: String) -> Double {
    var dev = 0, letters = 0
    for u in s.unicodeScalars where CharacterSet.letters.contains(u) { letters += 1; if (0x0900...0x097F).contains(u.value) { dev += 1 } }
    return letters == 0 ? 0 : Double(dev) / Double(letters)
}

/// Share of words in a transcript that are real English words (NSSpellChecker). English speech scores ~0.9+;
/// Hindi speech run through the English model comes out as Roman Hindi ("Bhai aaj office nahi…") and scores low.
func englishWordShare(_ s: String) -> Double {
    let words = s.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init).filter { $0.count > 1 }
    guard !words.isEmpty else { return 1 }
    let sc = NSSpellChecker.shared
    let ok = words.filter { w in sc.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound }
    return Double(ok.count) / Double(words.count)
}

/// Roman Hindi from the English model comes out in Title Case ("Kya Hum Aaj Raat"); lower-case the non-English words.
func fixRomanHindiCase(_ s: String) -> String {
    var out: [String] = []; var start = true
    for w in s.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
        var x = (w == "I" || w.hasPrefix("I'") || w.rangeOfCharacter(from: .decimalDigits) != nil) ? w : w.lowercased()
        if start, let f = x.first { x = f.uppercased() + x.dropFirst() }
        out.append(x); start = w.hasSuffix(".") || w.hasSuffix("?") || w.hasSuffix("!")
    }
    return out.joined(separator: " ")
}

enum Pick { case english(String), hindi(String), hinglish(hindi: String, roman: String, mixed: Bool) }

/// How much real English is mixed in: English function words plus correctly spelled longer words, per word.
/// Roman Hindi ("bhai aaj office nahi aa paunga") scores ~0.1; Hinglish with English phrases ("the presentation is almost done") ~0.35.
let EN_FUNCTION = Set("the a an is are was were be been am will would can could should to of in on at for from with by and or but if so this that these those it its my your our their his her me you we they he she what when where which who how not no do does did have has had just about".split(separator: " ").map(String.init))
func englishMix(_ s: String) -> Double {
    let words = s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
    guard !words.isEmpty else { return 0 }
    let sc = NSSpellChecker.shared
    let n = words.filter { w in EN_FUNCTION.contains(w) || (w.count >= 5 && sc.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound) }.count
    return Double(n) / Double(words.count)
}

/// Chooses what to type from the models' transcripts, given the language setting.
/// Auto: real English stays English; Hindi (or Hindi mixed with English) goes to Hindi, or to Hinglish if that's the chosen script.
func choose(_ outs: [(String, Double, Locale)]) -> Pick {
    let en = outs.first { $0.2 == EN }?.0 ?? "", hi = outs.first { $0.2 == HI }?.0 ?? ""
    switch Settings.lang {
    case .english: return .english(en)
    case .hindi: return Settings.script == .roman ? .hinglish(hindi: hi, roman: en, mixed: false) : .hindi(hi)
    case .auto:
        let share = en.isEmpty ? 0 : englishWordShare(en)
        if share >= 0.72 || hi.isEmpty { return .english(en) }
        // mixed Hindi + English (lots of real English words): Roman letters read best, whatever the script setting,
        // because the Hindi model spells English words in Devanagari ("प्रेजेंट इस ऑलमोस्ट डन")
        if englishMix(en) >= 0.25 { return .hinglish(hindi: hi, roman: en, mixed: true) }
        return Settings.script == .roman ? .hinglish(hindi: hi, roman: en, mixed: false) : .hindi(hi)
    }
}

// MARK: - Clean-up and Hinglish, with the on-device Apple Intelligence model

func polish(_ pick: Pick) async -> String {
    let model = SystemLanguageModel.default
    let ai: Bool = { if case .available = model.availability { return true }; return false }()
    func ask(_ instructions: String, _ text: String, minRatio: Double = 0.75, maxRatio: Double = 1.4) async -> String {
        guard ai, text.split(separator: " ").count > 2 else { return text }
        guard let r = try? await LanguageModelSession(instructions: instructions).respond(to: text, options: GenerationOptions(samplingMode: .greedy)) else { return text }
        let c = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return !c.isEmpty && Double(c.count) >= Double(text.count) * minRatio && Double(c.count) <= Double(text.count) * maxRatio ? c : text
    }
    func tidyHindi(_ t: String) async -> String {
        guard Settings.cleanup || t.range(of: "[A-Za-z]{3,}", options: .regularExpression) != nil else { return t }
        return await ask("You tidy dictated Hindi text written in Devanagari. If any Hindi words are written in Latin letters or glued together (for example \"KalShaamKo\" or \"Meinraat\"), write them in Devanagari with proper spaces. Remove filler sounds, fix punctuation (use । for full stops). Keep every word and its meaning, never translate, never answer. Output only the text.", t, minRatio: 0.6)
    }
    switch pick {
    case .english(let t):
        guard Settings.cleanup else { return basicClean(t) }
        return basicClean(await ask("You tidy dictated English text. Remove only filler words and stutters (um, uh, umm, erm, \"I'm so\" at the start). Keep every other word exactly as spoken, fix punctuation and capitalisation, never rephrase, never answer. Output only the text.", t))
    case .hindi(let t):
        return basicClean(await tidyHindi(t))
    case .hinglish(let hindi, let roman, let mixed):
        // mixed Hindi + English: the English model's Roman text is already how people type it
        if mixed || hindi.isEmpty { return basicClean(fixRomanHindiCase(roman)) }
        // pure Hindi: clean Devanagari first (the safety filter trips on glued Latin bits), then transliterate
        let dev = await tidyHindi(hindi)
        let r = await ask("You transliterate Hindi written in Devanagari into Hinglish: the same words in everyday Roman letters, the way Indians text on WhatsApp (for example: \"कल मिलते हैं\" becomes \"kal milte hain\"). Keep every word, never swap a word for another one, keep English words as they are, do not translate. Output only the transliterated text.", dev, minRatio: 0.6, maxRatio: 2.2)
        return basicClean(r.range(of: "[\u{0900}-\u{097F}]", options: .regularExpression) == nil ? r : fixRomanHindiCase(roman))
    }
}

func basicClean(_ s: String) -> String {
    var t = s.replacingOccurrences(of: #"(?i)\b(um+|uh+|erm+)\b[,.]?\s*"#, with: "", options: .regularExpression)
    t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    if let f = t.first, f.isLowercase, t.unicodeScalars.first.map({ $0.value < 0x0900 }) == true { t = f.uppercased() + t.dropFirst() }
    return t
}

// MARK: - Typing into the app under the cursor

func typeIntoFrontApp(_ text: String) -> Bool {
    let pb = NSPasteboard.general
    let saved = pb.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
        let copy = NSPasteboardItem(); for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }; return copy
    } ?? []
    pb.clearContents(); pb.setString(text, forType: .string)
    guard AXIsProcessTrusted() else { return false }        // without Accessibility the text stays on the clipboard
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true), up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
    down?.flags = .maskCommand; up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { pb.clearContents(); if !saved.isEmpty { pb.writeObjects(saved) } }   // put the clipboard back
    return true
}

// MARK: - The pill at the bottom of the screen

final class PillView: NSView {
    enum Mode { case listening, working, done, error }
    var mode: Mode = .listening { didSet { needsDisplay = true } }
    var level: CGFloat = 0
    var label = "Listening…"
    private var levels = [CGFloat](repeating: 0.05, count: 22)
    private var tick = 0
    func push(_ l: CGFloat) { levels.removeFirst(); levels.append(max(0.06, min(1, l))); needsDisplay = true }

    override func draw(_ r: NSRect) {
        let b = bounds.insetBy(dx: 14, dy: 12)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.22); sh.shadowBlurRadius = 16; sh.shadowOffset = NSSize(width: 0, height: -5); sh.set()
        NSColor.white.setFill(); NSBezierPath(roundedRect: b, xRadius: b.height / 2, yRadius: b.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        let dot = NSRect(x: b.minX + 14, y: b.midY - 8, width: 16, height: 16)
        (mode == .done ? NSColor(srgbRed: 0.16, green: 0.65, blue: 0.37, alpha: 1) : ACCENT).setFill(); NSBezierPath(ovalIn: dot).fill()
        if mode == .listening {    // live waveform
            let x0 = dot.maxX + 12, w: CGFloat = 4, gap: CGFloat = 3
            for (i, l) in levels.enumerated() {
                let h = max(4, (b.height - 18) * l); let x = x0 + CGFloat(i) * (w + gap)
                ACCENT.withAlphaComponent(0.35 + 0.65 * l).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: b.midY - h / 2, width: w, height: h), xRadius: 2, yRadius: 2).fill()
            }
        } else {
            let t = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: mode == .error ? ACCENT : INK])
            t.draw(with: NSRect(x: dot.maxX + 12, y: b.midY - 9, width: b.maxX - dot.maxX - 26, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

final class FloatPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false; level = .statusBar; ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]; hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { false }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let pill = FloatPanel(size: NSSize(width: 230, height: 64))
    let pillView = PillView(frame: NSRect(x: 0, y: 0, width: 230, height: 64))
    var status: NSStatusItem!
    let engine = AVAudioEngine()
    var utt: Utterance?
    var starting: Task<Void, Never>?
    var pending: [AVAudioPCMBuffer] = []          // audio captured while the model spins up
    var holding = false, busy = false
    var hideWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        pill.contentView = pillView
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Bolo")
        rebuildMenu()
        // hold-to-talk key: global (other apps) + local (our own menus)
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in self?.flags(e) }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in self?.flags(e); return e }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        Task { try? await ensureModels([EN]) }
        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            flash("\(Settings.hotkey.title), speak, let go", mode: .done, for: 5)
        }
    }

    func rebuildMenu() {
        let m = NSMenu()
        let w = Settings.words; let saved = Double(w) / 40 - Double(w) / 150     // typing ~40 wpm vs speaking ~150 wpm
        m.addItem(withTitle: "\(Settings.hotkey.title) and speak", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(withTitle: w > 0 ? "\(w.formatted()) words · \(Int(saved.rounded())) min saved" : "No words yet", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(.separator())
        let lang = NSMenu(); for l in Lang.allCases { let it = lang.addItem(withTitle: l.title, action: #selector(setLang(_:)), keyEquivalent: ""); it.representedObject = l.rawValue; it.target = self; it.state = Settings.lang == l ? .on : .off }
        m.addItem(withTitle: "Language", action: nil, keyEquivalent: "").submenu = lang
        let sc = NSMenu(); for (t, v) in [("हिन्दी (Devanagari)", HindiScript.devanagari), ("Hinglish (kal milte hain)", HindiScript.roman)] { let it = sc.addItem(withTitle: t, action: #selector(setScript(_:)), keyEquivalent: ""); it.representedObject = v.rawValue; it.target = self; it.state = Settings.script == v ? .on : .off }
        m.addItem(withTitle: "Hindi comes out as", action: nil, keyEquivalent: "").submenu = sc
        let hk = NSMenu(); for v in [Hotkey.fn, .rightOption] { let it = hk.addItem(withTitle: v.title, action: #selector(setHotkey(_:)), keyEquivalent: ""); it.representedObject = v.rawValue; it.target = self; it.state = Settings.hotkey == v ? .on : .off }
        m.addItem(withTitle: "Key", action: nil, keyEquivalent: "").submenu = hk
        let cl = m.addItem(withTitle: "Clean up with Apple Intelligence", action: #selector(toggleCleanup(_:)), keyEquivalent: ""); cl.target = self; cl.state = Settings.cleanup ? .on : .off
        m.addItem(.separator())
        if !AXIsProcessTrusted() { let a = m.addItem(withTitle: "Allow typing into apps…", action: #selector(openAX), keyEquivalent: ""); a.target = self }
        let login = m.addItem(withTitle: "Open at login", action: #selector(toggleLogin(_:)), keyEquivalent: ""); login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(withTitle: "Quit Bolo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = m
    }
    @objc func setLang(_ i: NSMenuItem) { Settings.lang = Lang(rawValue: i.representedObject as! String)!; rebuildMenu(); prepareLanguages() }
    @objc func setScript(_ i: NSMenuItem) { Settings.script = HindiScript(rawValue: i.representedObject as! String)!; rebuildMenu() }
    @objc func setHotkey(_ i: NSMenuItem) { Settings.hotkey = Hotkey(rawValue: i.representedObject as! String)!; rebuildMenu() }
    @objc func toggleCleanup(_ i: NSMenuItem) { Settings.cleanup.toggle(); rebuildMenu() }
    @objc func openAX() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc func toggleLogin(_ i: NSMenuItem) {
        do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } } catch {}
        rebuildMenu()
    }

    var locales: [Locale] { switch Settings.lang { case .auto: return [EN, HI]; case .english: return [EN]; case .hindi: return [HI] } }
    func prepareLanguages() {
        let ls = locales
        Task {
            await MainActor.run { self.flash("Getting the speech model ready…", mode: .working, for: nil) }
            do { try await ensureModels(ls) { p in DispatchQueue.main.async { self.pillView.label = "Downloading Hindi model… \(Int(p * 100))%"; self.pillView.needsDisplay = true } }
                 await MainActor.run { self.flash("Ready", mode: .done, for: 1.5) } }
            catch { await MainActor.run { self.flash("Couldn't get the model: \(error.localizedDescription)", mode: .error, for: 4) } }
        }
    }

    // MARK: hold to talk
    func flags(_ e: NSEvent) {
        guard e.keyCode == Settings.hotkey.keyCode else { return }
        let down = Settings.hotkey == .fn ? e.modifierFlags.contains(.function) : e.modifierFlags.contains(.option)
        if down && !holding && !busy { holding = true; begin() }
        else if !down && holding { holding = false; end() }
    }

    func begin() {
        pending.removeAll(); utt = nil
        showPill(.listening)
        let input = engine.inputNode, fmt = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
            guard let self else { return }
            var sum: Float = 0; if let ch = buf.floatChannelData?[0] { for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] } }
            let rms = sqrt(sum / Float(max(1, buf.frameLength))); let lvl = CGFloat(min(1, max(0, (20 * log10(max(rms, 1e-6)) + 55) / 40)))
            DispatchQueue.main.async { self.pillView.push(lvl) }
            DispatchQueue.main.async { if let u = self.utt { u.feed(buf) } else { self.pending.append(buf) } }
        }
        do { try engine.start() } catch { flash("Microphone unavailable", mode: .error, for: 3); return }
        let ls = locales
        starting = Task { [weak self] in
            do {
                let u = try await Utterance(locales: ls)
                await MainActor.run { guard let self else { return }; self.utt = u; for b in self.pending { u.feed(b) }; self.pending.removeAll() }
            } catch { await MainActor.run { self?.flash(ls.contains(HI) ? "Choose Language → Hindi once to download it" : "Speech model not ready yet", mode: .error, for: 4) } }
        }
    }

    func end() {
        busy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in       // keep the last syllable
            engine.inputNode.removeTap(onBus: 0); engine.stop()
            showPill(.working, label: "Typing…")
            Task {
                await starting?.value
                guard let u = await MainActor.run(body: { self.utt }) else { await MainActor.run { self.busy = false; self.hidePill() }; return }
                do {
                    let outs = try await u.finish()
                    if outs.allSatisfy({ $0.0.isEmpty }) { await MainActor.run { self.busy = false; self.flash("Didn't catch that", mode: .error, for: 1.5) }; return }
                    let pick = await MainActor.run { choose(outs) }
                    let text = await polish(pick)
                    await MainActor.run {
                        let typed = typeIntoFrontApp(text)
                        Settings.words += text.split(whereSeparator: \.isWhitespace).count; self.rebuildMenu()
                        self.busy = false
                        self.flash(typed ? "Typed \(text.split(whereSeparator: \.isWhitespace).count) words" : "Copied. Press ⌘V", mode: .done, for: 1.2)
                    }
                } catch { await MainActor.run { self.busy = false; self.flash(error.localizedDescription, mode: .error, for: 3) } }
            }
        }
    }

    // MARK: pill
    func showPill(_ m: PillView.Mode, label: String = "") {
        hideWork?.cancel(); pillView.mode = m; pillView.label = label
        let scr = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        pill.setFrameOrigin(NSPoint(x: scr.visibleFrame.midX - pill.frame.width / 2, y: scr.visibleFrame.minY + 28))
        pill.alphaValue = 1; pill.orderFrontRegardless()
    }
    func hidePill() { NSAnimationContext.runAnimationGroup { c in c.duration = 0.2; pill.animator().alphaValue = 0 } }
    func flash(_ s: String, mode: PillView.Mode, for secs: Double?) {
        showPill(mode, label: s)
        if let secs { let w = DispatchWorkItem { [weak self] in self?.hidePill() }; hideWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + secs, execute: w) }
    }
}

// MARK: - Test hooks (no UI): Bolo --transcribe file.wav [auto|english|hindi] [roman]
let argv = CommandLine.arguments
if argv.count > 2, argv[1] == "--transcribe" {
    let url = URL(fileURLWithPath: argv[2])
    UserDefaults.standard.setVolatileDomain(["lang": argv.count > 3 ? argv[3] : "auto", "script": argv.count > 4 ? "roman" : "devanagari"], forName: UserDefaults.argumentDomain)   // test only, never saved
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let ls: [Locale] = Settings.lang == .auto ? [EN, HI] : Settings.lang == .english ? [EN] : [HI]
            let t0 = Date()
            try await ensureModels(ls) { p in print(String(format: "model download %.0f%%", p * 100)) }
            let u = try await Utterance(locales: ls)
            let f = try AVAudioFile(forReading: url)
            while f.framePosition < f.length {
                guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 4096) else { break }
                try f.read(into: b); if b.frameLength == 0 { break }; u.feed(b)
            }
            let outs = try await u.finish()
            let pick = choose(outs)
            print("pick: \(pick)")
            print("typed: \(await polish(pick))")
            print(String(format: "%.2fs", Date().timeIntervalSince(t0)))
        } catch { print("ERROR", error) }
        sem.signal()
    }
    while sem.wait(timeout: .now() + 0.01) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
