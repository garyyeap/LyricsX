import Cocoa
import SwiftCF
import CoreGraphicsExt
import CoreTextExt

class KaraokeLabel: NSTextField {
    @objc dynamic var isVertical = false {
        didSet {
            clearCache()
            invalidateIntrinsicContentSize()
        }
    }

    @objc dynamic var drawFurigana = false {
        didSet {
            clearCache()
            invalidateIntrinsicContentSize()
        }
    }

    @objc dynamic var drawRomajin = false {
        didSet {
            clearCache()
            invalidateIntrinsicContentSize()
        }
    }

    override var attributedStringValue: NSAttributedString {
        didSet {
            clearCache()
        }
    }

    override var stringValue: String {
        didSet {
            clearCache()
        }
    }

    @objc override dynamic var font: NSFont? {
        didSet {
            clearCache()
        }
    }

    @objc override dynamic var textColor: NSColor? {
        didSet {
            clearCache()
        }
    }

    private func invalidateFrameCache() {
        _attrString = nil
        _ctFrame = nil
        _progressFrame = nil
        needsDisplay = true
    }

    private func clearCache() {
        invalidateFrameCache()
        needsLayout = true
        removeProgressAnimation()
    }

    private var _attrString: NSAttributedString?
    private var _progressFrame: CTFrame?
    private var romajinAnnotations: [(String, NSRange)] = []
    private var lastLayoutBounds: NSSize = .zero
    private var verticalProgress: VerticalProgressAnimation?
    private var storedProgressColor: NSColor?
    private var progressRefreshTimer: Timer?
    private var progressLayer: CALayer?

    private struct VerticalProgressAnimation {
        var tags: [(TimeInterval, Int)]
        var duration: TimeInterval
        var startTime: CFTimeInterval
        var pausedElapsed: TimeInterval?
    }

    private var attrString: NSAttributedString {
        if let attrString = _attrString {
            return attrString
        }
        let attrString = NSMutableAttributedString(attributedString: attributedStringValue)
        let string = attrString.string as NSString
        let shouldDrawFurigana = drawFurigana && string.dominantLanguage == "ja"
        let shouldDrawRomajin = drawRomajin && string.dominantLanguage == "ja"
        let tokenizer = CFStringTokenizer.create(string: .from(string))
        romajinAnnotations = []
        for tokenType in IteratorSequence(tokenizer) where tokenType.contains(.isCJWordMask) {
            if isVertical {
                let tokenRange = tokenizer.currentTokenRange()
                let attr: [NSAttributedString.Key: Any] = [
                    .verticalGlyphForm: true,
                    .baselineOffset: (font?.pointSize ?? 24) * 0.25,
                ]
                attrString.addAttributes(attr, range: tokenRange.asNS)
            }
            guard shouldDrawFurigana else { continue }
            if let (furigana, range) = tokenizer.currentFuriganaAnnotation(in: string) {
                var attr: [CFAttributedString.Key: Any] = [.ctRubySizeFactor: 0.5]
                attr[.ctForegroundColor] = textColor
                let annotation = CTRubyAnnotation.create(furigana, attributes: attr)
                attrString.addAttribute(.cf(.ctRubyAnnotation), value: annotation, range: range)
            }
            if shouldDrawRomajin, let (romajin, range) = tokenizer.currentRomanjiAnnotation(in: string) {
                romajinAnnotations.append((romajin as String, range))
            }
        }
        textColor?.do { attrString.addAttributes([.foregroundColor: $0], range: attrString.fullRange) }
        _attrString = attrString
        return attrString
    }

    private var _ctFrame: CTFrame?

    private func ctFrame() -> CTFrame {
        if let ctFrame = _ctFrame {
            return ctFrame
        }
        layoutSubtreeIfNeeded()
        let progression: CTFrameProgression = isVertical ? .rightToLeft : .topToBottom
        let frameAttr: [CTFrame.AttributeKey: Any] = [.progression: progression.rawValue as NSNumber]
        let framesetter = CTFramesetter.create(attributedString: attrString)
        let (suggestSize, fitRange) = framesetter.suggestFrameSize(constraints: bounds.size, frameAttributes: frameAttr)
        let path = CGPath(rect: CGRect(origin: .zero, size: suggestSize), transform: nil)
        let ctFrame = framesetter.frame(stringRange: fitRange, path: path, frameAttributes: frameAttr)
        _ctFrame = ctFrame
        _progressFrame = nil
        return ctFrame
    }

    private func progressFrame() -> CTFrame? {
        guard let color = storedProgressColor else { return nil }
        if let progressFrame = _progressFrame {
            return progressFrame
        }
        let colored = NSMutableAttributedString(attributedString: attrString)
        colored.addAttributes([.foregroundColor: color], range: colored.fullRange)
        let progression: CTFrameProgression = isVertical ? .rightToLeft : .topToBottom
        let frameAttr: [CTFrame.AttributeKey: Any] = [.progression: progression.rawValue as NSNumber]
        let framesetter = CTFramesetter.create(attributedString: colored)
        let (suggestSize, fitRange) = framesetter.suggestFrameSize(constraints: bounds.size, frameAttributes: frameAttr)
        let path = CGPath(rect: CGRect(origin: .zero, size: suggestSize), transform: nil)
        let progressFrame = framesetter.frame(stringRange: fitRange, path: path, frameAttributes: frameAttr)
        _progressFrame = progressFrame
        return progressFrame
    }

    override func setFrameSize(_ newSize: NSSize) {
        if bounds.size != newSize {
            invalidateFrameCache()
        }
        super.setFrameSize(newSize)
    }

    override func layout() {
        super.layout()
        if lastLayoutBounds != bounds.size {
            lastLayoutBounds = bounds.size
            invalidateFrameCache()
        }
    }

    override var intrinsicContentSize: NSSize {
        let progression: CTFrameProgression = isVertical ? .rightToLeft : .topToBottom
        let frameAttr: [CTFrame.AttributeKey: Any] = [.progression: progression.rawValue as NSNumber]
        let framesetter = CTFramesetter.create(attributedString: attrString)
        let constraints = CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        return framesetter.suggestFrameSize(constraints: constraints, frameAttributes: frameAttr).size
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        let cgContext = context.cgContext
        let frame = ctFrame()

        cgContext.textMatrix = .identity
        cgContext.translateBy(x: 0, y: bounds.height)
        cgContext.scaleBy(x: 1.0, y: -1.0)
        CTFrameDraw(frame, cgContext)

        if isVertical {
            drawVerticalProgress(in: cgContext, frame: frame)
        }

        drawRomajiAnnotations(in: cgContext, frame: frame)
    }

    // MARK: - Vertical progress (draw only; same flipped context as white text)

    private func verticalLineRect(line: CTLine, origin: CGPoint) -> CGRect {
        line.bounds().applying(.translate(x: origin.x, y: origin.y))
    }

    private func resolvedVerticalProgressMap(
        line: CTLine,
        progress: [(TimeInterval, Int)]
    ) -> [(TimeInterval, CGFloat)] {
        guard let index = progress.firstIndex(where: { $0.0 > 0 }) else { return [] }
        var map = progress.map { ($0.0, line.offset(charIndex: $0.1).primary) }
        if index > 0 {
            let height = map[index - 1].1 + CGFloat(map[index - 1].0) * (map[index].1 - map[index - 1].1) / CGFloat(map[index].0 - map[index - 1].0)
            map.replaceSubrange(..<index, with: [(0, height)])
        }
        return map
    }

    private func progressLength(at elapsed: TimeInterval, map: [(TimeInterval, CGFloat)]) -> CGFloat {
        guard let last = map.last else { return 0 }
        if elapsed <= 0 {
            return map.first?.1 ?? 0
        }
        if elapsed >= last.0 {
            return last.1
        }
        guard let nextIndex = map.firstIndex(where: { $0.0 > elapsed }) else {
            return last.1
        }
        let next = map[nextIndex]
        let prev = map[nextIndex - 1]
        let ratio = (elapsed - prev.0) / (next.0 - prev.0)
        return prev.1 + CGFloat(ratio) * (next.1 - prev.1)
    }

    private func currentVerticalElapsed() -> TimeInterval? {
        guard let verticalProgress else { return nil }
        if let pausedElapsed = verticalProgress.pausedElapsed {
            return pausedElapsed
        }
        return CACurrentMediaTime() - verticalProgress.startTime
    }

    private func drawVerticalProgress(in cgContext: CGContext, frame: CTFrame) {
        guard let verticalProgress,
              let progressColoredFrame = progressFrame(),
              let elapsed = currentVerticalElapsed(),
              let line = frame.lines.first,
              let origin = frame.lineOrigins(range: CFRange(location: 0, length: 1)).first else {
            return
        }

        let lineRect = verticalLineRect(line: line, origin: origin)
        let map = resolvedVerticalProgressMap(line: line, progress: verticalProgress.tags)
        let height = progressLength(at: elapsed, map: map)
        guard height > 0 else { return }

        let clipHeight = min(height, lineRect.height)
        let clipRect = CGRect(
            x: lineRect.origin.x,
            y: lineRect.origin.y,
            width: lineRect.width,
            height: clipHeight
        )

        cgContext.saveGState()
        cgContext.textMatrix = .identity
        cgContext.translateBy(x: 0, y: bounds.height)
        cgContext.scaleBy(x: 1.0, y: -1.0)
        cgContext.clip(to: clipRect)
        CTFrameDraw(progressColoredFrame, cgContext)
        cgContext.restoreGState()
    }

    private func startProgressRefreshTimer() {
        stopProgressRefreshTimer()
        progressRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.verticalProgress != nil else {
                timer.invalidate()
                return
            }
            if let elapsed = self.currentVerticalElapsed(),
               let duration = self.verticalProgress?.duration,
               elapsed >= duration {
                self.stopProgressRefreshTimer()
            }
            self.needsDisplay = true
        }
    }

    private func stopProgressRefreshTimer() {
        progressRefreshTimer?.invalidate()
        progressRefreshTimer = nil
    }

    // MARK: - Progress

    private func ensureProgressLayer() -> CALayer {
        if let progressLayer {
            return progressLayer
        }
        wantsLayer = true
        let layer = CALayer()
        self.layer?.addSublayer(layer)
        progressLayer = layer
        return layer
    }

    @objc dynamic var progressColor: NSColor? {
        get {
            return storedProgressColor ?? progressLayer?.backgroundColor.flatMap(NSColor.init)
        }
        set {
            storedProgressColor = newValue
            _progressFrame = nil
            progressLayer?.backgroundColor = newValue?.cgColor
            needsDisplay = true
        }
    }

    func setProgressAnimation(color: NSColor, progress: [(TimeInterval, Int)]) {
        removeProgressAnimation()
        layoutSubtreeIfNeeded()
        storedProgressColor = color

        let frame = ctFrame()
        guard let line = frame.lines.first,
              let origin = frame.lineOrigins(range: CFRange(location: 0, length: 1)).first else {
            return
        }

        if isVertical {
            guard progress.contains(where: { $0.0 > 0 }) else { return }
            verticalProgress = VerticalProgressAnimation(
                tags: progress,
                duration: progress.last!.0,
                startTime: CACurrentMediaTime(),
                pausedElapsed: nil
            )
            startProgressRefreshTimer()
            needsDisplay = true
            return
        }

        var lineBounds = line.bounds()
        var transform = CGAffineTransform.translate(x: origin.x, y: origin.y)
        transform *= .flip(height: bounds.height)
        lineBounds.apply(t: transform)

        let progressLayer = ensureProgressLayer()
        progressLayer.isHidden = false
        progressLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        progressLayer.frame = lineBounds
        progressLayer.backgroundColor = color.cgColor
        let mask = CALayer()
        mask.frame = progressLayer.bounds
        let img = NSImage(size: progressLayer.bounds.size, flipped: false) { _ in
            let context = NSGraphicsContext.current!.cgContext
            let ori = lineBounds.applying(.flip(height: self.bounds.height)).origin
            context.concatenate(.translate(x: -ori.x, y: -ori.y))
            CTFrameDraw(frame, context)
            return true
        }
        mask.contents = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        progressLayer.mask = mask

        guard let index = progress.firstIndex(where: { $0.0 > 0 }) else { return }
        var map = progress.map { ($0.0, line.offset(charIndex: $0.1).primary) }
        if index > 0 {
            let progress = map[index - 1].1 + CGFloat(map[index - 1].0) * (map[index].1 - map[index - 1].1) / CGFloat(map[index].0 - map[index - 1].0)
            map.replaceSubrange(..<index, with: [(0, progress)])
        }

        let duration = map.last!.0
        let animation = CAKeyframeAnimation()
        animation.keyTimes = map.map { ($0.0 / duration) as NSNumber }
        animation.values = map.map { $0.1 }
        animation.keyPath = "bounds.size.width"
        animation.duration = duration
        progressLayer.add(animation, forKey: "inlineProgress")
    }

    func pauseProgressAnimation() {
        if var verticalProgress {
            if verticalProgress.pausedElapsed == nil {
                verticalProgress.pausedElapsed = CACurrentMediaTime() - verticalProgress.startTime
                self.verticalProgress = verticalProgress
            }
            stopProgressRefreshTimer()
            needsDisplay = true
            return
        }
        guard let progressLayer else { return }
        let pausedTime = progressLayer.convertTime(CACurrentMediaTime(), from: nil)
        progressLayer.speed = 0
        progressLayer.timeOffset = pausedTime
    }

    func resumeProgressAnimation() {
        if var verticalProgress, let pausedElapsed = verticalProgress.pausedElapsed {
            verticalProgress.startTime = CACurrentMediaTime() - pausedElapsed
            verticalProgress.pausedElapsed = nil
            self.verticalProgress = verticalProgress
            startProgressRefreshTimer()
            needsDisplay = true
            return
        }
        guard let progressLayer else { return }
        let pausedTime = progressLayer.timeOffset
        progressLayer.speed = 1
        progressLayer.timeOffset = 0
        progressLayer.beginTime = 0
        let timeSincePause = progressLayer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        progressLayer.beginTime = timeSincePause
    }

    func removeProgressAnimation() {
        stopProgressRefreshTimer()
        verticalProgress = nil
        storedProgressColor = nil
        _progressFrame = nil
        guard let progressLayer else {
            needsDisplay = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.speed = 1
        progressLayer.timeOffset = 0
        progressLayer.removeAnimation(forKey: "inlineProgress")
        progressLayer.frame = .zero
        progressLayer.mask = nil
        progressLayer.backgroundColor = nil
        CATransaction.commit()
        needsDisplay = true
    }

    private func drawRomajiAnnotations(in context: CGContext, frame: CTFrame) {
        guard drawRomajin, !romajinAnnotations.isEmpty else { return }

        let lines = frame.lines
        let origins = frame.lineOrigins(range: CFRangeMake(0, lines.count))
        var annotationIndex = 0

        // 处理每行和每个 glyph run
        for (line, origin) in zip(lines, origins) {
            let runs = line.glyphRuns
            for run in runs {
                let range = run.stringRange
                var subIndex = 0

                while annotationIndex + subIndex < romajinAnnotations.count {
                    let (romajin, annotationRange) = romajinAnnotations[annotationIndex + subIndex]
                    if NSRange(location: range.location, length: range.length).contains(annotationRange.location) {
                        var ascent: CGFloat = 0
                        var descent: CGFloat = 0
                        var leading: CGFloat = 0
                        let width = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), &ascent, &descent, &leading)
                        var position = CGPoint.zero
                        CTRunGetPositions(run, CFRangeMake(0, 1), &position)
                        let glyphX = origin.x + position.x

                        let relativeOffset = CGFloat(annotationRange.location - range.location) / CGFloat(range.length) * width
                        let glyphBounds = CGRect(
                            x: glyphX + relativeOffset,
                            y: origin.y - descent,
                            width: width / CGFloat(range.length) * CGFloat(annotationRange.length),
                            height: ascent + descent
                        )

                        let fontSize = font?.pointSize ?? 24
                        var rubyFontSize = fontSize * 0.3
                        let rubyFontBase = NSFont.systemFont(ofSize: rubyFontSize)
                        let rubyAttrBase: [NSAttributedString.Key: Any] = [
                            .foregroundColor: textColor ?? .black,
                            .font: rubyFontBase,
                        ]
                        var rubyString = NSAttributedString(string: romajin, attributes: rubyAttrBase)
                        var rubyWidth = rubyString.size().width
                        let maxWidth = glyphBounds.width

                        while rubyWidth > maxWidth * 0.8, rubyFontSize > 1 {
                            rubyFontSize *= 0.9
                            let rubyFont = NSFont.systemFont(ofSize: rubyFontSize)
                            let rubyAttr: [NSAttributedString.Key: Any] = [
                                .font: rubyFont,
                                .foregroundColor: textColor ?? .black,
                            ]
                            rubyString = NSAttributedString(string: romajin, attributes: rubyAttr)
                            rubyWidth = rubyString.size().width
                        }

                        let glyphWidth = glyphBounds.width
                        let xOffset = (glyphWidth - rubyWidth) / 2
                        let rubyPoint = CGPoint(
                            x: glyphBounds.minX + xOffset,
                            y: glyphBounds.minY - fontSize * 0.2
                        )
                        let rubyLine = CTLineCreateWithAttributedString(rubyString)
                        context.textPosition = rubyPoint
                        CTLineDraw(rubyLine, context)

                        subIndex += 1
                    } else {
                        break
                    }
                }
                annotationIndex += subIndex
            }
        }

        // 处理剩余的 annotations
        while annotationIndex < romajinAnnotations.count {
            let (romajin, _) = romajinAnnotations[annotationIndex]
            if let lastLine = lines.last, let lastOrigin = origins.last, let lastRun = lastLine.glyphRuns.last {
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let width = CTRunGetTypographicBounds(lastRun, CFRangeMake(0, 0), &ascent, &descent, &leading)
                var position = CGPoint.zero
                CTRunGetPositions(lastRun, CFRangeMake(0, 1), &position)
                let glyphX = lastOrigin.x + position.x + width
                let glyphBounds = CGRect(
                    x: glyphX,
                    y: lastOrigin.y - descent,
                    width: width,
                    height: ascent + descent
                )

                let fontSize = font?.pointSize ?? 24
                var rubyFontSize = fontSize * 0.3
                let rubyAttrBase: [NSAttributedString.Key: Any] = [
                    .foregroundColor: textColor ?? .black,
                ]
                var rubyString = NSAttributedString(string: romajin, attributes: rubyAttrBase)
                var rubyWidth = rubyString.size().width
                let maxWidth = glyphBounds.width

                while rubyWidth > maxWidth * 0.8, rubyFontSize > 1 {
                    rubyFontSize *= 0.9
                    let rubyFont = NSFont.systemFont(ofSize: rubyFontSize)
                    let rubyAttr: [NSAttributedString.Key: Any] = [
                        .font: rubyFont,
                        .foregroundColor: textColor ?? .black,
                    ]
                    rubyString = NSAttributedString(string: romajin, attributes: rubyAttr)
                    rubyWidth = rubyString.size().width
                }

                let glyphWidth = glyphBounds.width
                let xOffset = (glyphWidth - rubyWidth) / 2
                let rubyPoint = CGPoint(
                    x: glyphBounds.minX + xOffset,
                    y: glyphBounds.minY - 0.2 * fontSize
                )
                let rubyLine = CTLineCreateWithAttributedString(rubyString)
                context.textPosition = rubyPoint
                CTLineDraw(rubyLine, context)
            }
            annotationIndex += 1
        }
    }
}
