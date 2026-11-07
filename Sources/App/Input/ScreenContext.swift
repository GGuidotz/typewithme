// Il testo visibile nella finestra in primo piano, riconosciuto sul Mac (cattura della sola finestra con
// ScreenCaptureKit e OCR con Vision), per dare contesto al modello di completamento. Non aspetta mai: `text(for:)`
// risponde subito con l'ultimo testo riconosciuto, se ancora valido, e intanto avvia in background un aggiornamento
// (uno alla volta, a distanza di qualche secondo): il contesto arriva con la richiesta successiva.
// Privacy: il testo resta solo in memoria, mai su disco, mai nel registro (solo stati e conteggi). Mai la nostra finestra.

import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

@MainActor
final class ScreenContext {
    /// Quanto vale un testo riconosciuto, e la distanza minima tra due aggiornamenti. Una finestra nuova (o un'altra
    /// app) si legge subito; la stessa finestra si rilegge di rado: cattura e OCR costano, e mentre scrivi nello stesso
    /// campo il contesto resta comunque fermo (Completer.windowContext).
    private static let maxAge: TimeInterval = 60
    private static let minInterval: TimeInterval = 15
    private nonisolated static let maxPixels: CGFloat = 2000
    private nonisolated static let maxCharacters = 1_500

    private struct Snapshot {
        let pid: pid_t
        let windowID: CGWindowID
        let text: String
        let date: Date
    }

    private var snapshot: Snapshot?
    private var task: Task<Void, Never>?
    private var lastStart: Date?
    /// La finestra dell'ultimo aggiornamento partito: la distanza minima vale solo per lei.
    private var lastTarget: (pid: pid_t, windowID: CGWindowID?)?

    /// Quante catture sono riuscite e quanto è durata l'ultima (cattura e OCR), per la diagnostica.
    private(set) var captures = 0

    /// Vero mentre una cattura con OCR è in corso: il testo arriverà tra poco.
    var isRefreshing: Bool { task != nil }
    private(set) var lastDurationMs: Int?

    // MARK: - Permesso

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    // MARK: - Uso

    /// Subito, senza attendere: l'ultimo testo della finestra in primo piano di `pid`, se è la stessa e ha meno di
    /// 20 secondi. Se manca o è vecchio avvia un aggiornamento in background.
    func text(for pid: pid_t) -> String? {
        guard pid != getpid(), Self.hasPermission else { return nil }
        let windowID = Self.frontWindowID(pid: pid)
        var result: String?
        var fresh = false
        if let s = snapshot, s.pid == pid, s.windowID == windowID, !s.text.isEmpty {
            let age = Date().timeIntervalSince(s.date)
            if age < Self.maxAge { result = s.text }
            fresh = age < Self.maxAge
        }
        if !fresh { refresh(pid: pid, windowID: windowID) }
        return result
    }

    /// Da chiamare quando cambia app: scarta il testo e annulla l'aggiornamento in corso.
    func invalidate() {
        snapshot = nil
        task?.cancel()
        task = nil
    }

    // MARK: - Aggiornamento

    private func refresh(pid: pid_t, windowID: CGWindowID?) {
        guard task == nil else { return }
        if let last = lastStart, let target = lastTarget, target.pid == pid, target.windowID == windowID,
           Date().timeIntervalSince(last) < Self.minInterval { return }
        lastStart = Date()
        lastTarget = (pid, windowID)
        task = Task { [weak self] in
            let started = Date()
            let outcome = await Self.capture(pid: pid)
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            switch outcome {
            case .success(let windowID, let text, let lines):
                self.snapshot = Snapshot(pid: pid, windowID: windowID, text: text, date: Date())
                self.captures += 1
                self.lastDurationMs = Int(Date().timeIntervalSince(started) * 1000)
                diag(.engine, "screen context: \(lines) lines")
            case .failure(let reason):
                self.snapshot = nil
                diag(.engine, "screen context: \(reason)")
            }
        }
    }

    // MARK: - Cattura e OCR (fuori dal main actor)

    private enum Outcome {
        case success(windowID: CGWindowID, text: String, lines: Int)
        case failure(String)
    }

    private nonisolated static func capture(pid: pid_t) async -> Outcome {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            return .failure("window list unavailable")
        }
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.isOnScreen
        }
        guard let window = candidates.max(by: { area($0.frame) < area($1.frame) }) else {
            return .failure("no window found")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        var width = window.frame.width * (scale > 0 ? scale : 1)
        var height = window.frame.height * (scale > 0 ? scale : 1)
        guard width >= 1, height >= 1 else { return .failure("empty window") }
        let longSide = Swift.max(width, height)
        if longSide > maxPixels {
            let k = maxPixels / longSide
            width *= k
            height *= k
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(width.rounded())
        configuration.height = Int(height.rounded())
        configuration.showsCursor = false
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return .failure("capture failed")
        }
        if Task.isCancelled { return .failure("cancelled") }
        let lines = await Task.detached(priority: .utility) { recognize(image) }.value
        guard let lines else { return .failure("recognition failed") }
        let text = join(lines)
        return .success(windowID: window.windowID, text: text, lines: lines.count)
    }

    /// Le righe riconosciute, dall'alto in basso e da sinistra a destra. nil se Vision fallisce.
    private nonisolated static func recognize(_ image: CGImage) -> [String]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["it-IT", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        let observations = request.results ?? []
        // Coordinate normalizzate con l'origine in basso: più in alto = y più grande. Le righe quasi alla stessa
        // altezza (entro l'1%) contano come la stessa riga e si ordinano da sinistra.
        let sorted = observations.sorted { a, b in
            let ra = (a.boundingBox.midY * 100).rounded()
            let rb = (b.boundingBox.midY * 100).rounded()
            if ra != rb { return ra > rb }
            return a.boundingBox.origin.x < b.boundingBox.origin.x
        }
        return sorted.compactMap { $0.topCandidates(1).first?.string }
    }

    /// Spazi compressi, righe vuote tolte, al massimo `maxCharacters` caratteri in ordine di lettura.
    private nonisolated static func join(_ lines: [String]) -> String {
        var out = ""
        var count = 0
        for line in lines {
            let clean = line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if clean.isEmpty { continue }
            let room = maxCharacters - count - (out.isEmpty ? 0 : 1)
            if room <= 0 { break }
            if !out.isEmpty { out += "\n"; count += 1 }
            let piece = clean.count > room ? String(clean.prefix(room)) : clean
            out += piece
            count += piece.count
        }
        return out
    }

    // MARK: - Finestre

    private nonisolated static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    /// La finestra normale più grande di `pid` sullo schermo (stesso criterio dell'aggiornamento), senza permessi.
    private static func frontWindowID(pid: pid_t) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        var best: (id: CGWindowID, area: CGFloat)?
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            let a = area(bounds)
            if best == nil || a > best!.area { best = (number, a) }
        }
        return best?.id
    }
}
