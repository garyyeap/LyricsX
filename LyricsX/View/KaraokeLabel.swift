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
    private var hasHorizontalProgress = false
    private var storedProgressColor: NSColor?
    private var progressRefreshTimer: Timer?

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
//    private var ctFrame: CTFrame {
//        if let ctFrame = _ctFrame {
//            return ctFrame
//        }
//        layoutSubtreeIfNeeded()
//        let progression: CTFrameProgression = isVertical ? .rightToLeft : .topToBottom
//        let frameAttr: [CTFrame.AttributeKey: Any] = [.progression: progression.rawValue as NSNumber]
//        let framesetter = CTFramesetter.create(attributedString: attrString)
//        print(bounds.size)
//        let (suggestSize, fitRange) = framesetter.suggestFrameSize(constraints: bounds.size, frameAttributes: frameAttr)
//        let path = CGPath(rect: CGRect(origin: .zero, size: suggestSize), transform: nil)
//        let ctFrame = framesetter.frame(stringRange: fitRange, path: path, frameAttributes: frameAttr)
//        _ctFrame = ctFrame
//        return ctFrame
//    }

    private func makeFrame(for attributedString: NSAttributedString) -> CTFrame {
        let progression: CTFrameProgression = isVertical ? .rightToLeft : .topToBottom
        let frameAttr: [CTFrame.AttributeKey: Any] = [.progression: progression.rawValue as NSNumber]
        let framesetter = CTFramesetter.create(attributedString: attributedString)
        let (suggestSize, fitRange) = framesetter.suggestFrameSize(constraints: bounds.size, frameAttributes: frameAttr)
        let path = CGPath(rect: CGRect(origin: .zero, size: suggestSize), transform: nil)
        return framesetter.frame(stringRange: fitRange, path: path, frameAttributes: frameAttr)
    }

    private func ctFrame(_ dirtyRect: NSRect? = nil) -> CTFrame {
        if let ctFrame = _ctFrame {
            return ctFrame
        }
        if dirtyRect == nil {
            layoutSubtreeIfNeeded()
        }
        let ctFrame = makeFrame(for: attrString)
        _ctFrame = ctFrame
        return ctFrame
    }

    private func progressFrame() -> CTFrame? {
        guard let color = storedProgressColor ?? progressColor else { return nil }
        if let progressFrame = _progressFrame {
            return progressFrame
        }
        let colored = NSMutableAttributedString(attributedString: attrString)
        colored.addAttributes([.foregroundColor: color], range: colored.fullRange)
        let progressFrame = makeFrame(for: colored)
        _progressFrame = progressFrame
        return progressFrame
    }

    override func setFrameSize(_ newSize: NSSize) {
        if bounds.size != newSize {
            invalidateFrameCache()
            refreshHorizontalProgressLayerFrame()
        }
        super.setFrameSize(newSize)
    }

    override func layout() {
        super.layout()
        if lastLayoutBounds != bounds.size {
            lastLayoutBounds = bounds.size
            invalidateFrameCache()
            refreshHorizontalProgressLayerFrame()
        }
    }

    private func refreshHorizontalProgressLayerFrame() {
        guard hasHorizontalProgress else { return }
        guard let lineRect = horizontalProgressLineRect(from: ctFrame()) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.frame = lineRect
        CATransaction.commit()
        needsDisplay = true
    }

    private func configureFlippedTextContext(_ context: CGContext) {
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1.0, y: -1.0)
    }

    private func drawVerticalProgressMask(frame: CTFrame, in context: CGContext, lineBounds: CGRect) {
        let ori = lineBounds.applying(.flip(height: bounds.height)).origin
        context.concatenate(.translate(x: -ori.x, y: -ori.y))
        CTFrameDraw(frame, context)
    }

    private func horizontalProgressLineRect(from frame: CTFrame) -> CGRect? {
        guard let line = frame.lines.first,
              let origin = frame.lineOrigins(range: CFRange(location: 0, length: 1)).first else {
            return nil
        }
        var lineBounds = line.bounds()
        lineBounds = lineBounds.applying(.translate(x: origin.x, y: origin.y))
        return lineBounds
    }

    private func horizontalProgressClipRect(width: CGFloat, lineRect: CGRect) -> CGRect {
        let clipWidth = min(max(width, 0), lineRect.width)
        return CGRect(
            x: lineRect.origin.x,
            y: lineRect.origin.y,
            width: clipWidth,
            height: lineRect.height
        )
    }

    private func currentHorizontalProgressWidth() -> CGFloat {
        guard hasHorizontalProgress else { return 0 }
        let animatedBounds = progressLayer.presentation()?.bounds ?? progressLayer.bounds
        return animatedBounds.width
    }

    private func startProgressRefreshTimer() {
        stopProgressRefreshTimer()
        progressRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if self.progressLayer.animation(forKey: "inlineProgress") == nil, self.progressLayer.speed > 0 {
                self.stopProgressRefreshTimer()
                self.needsDisplay = true
                return
            }
            self.needsDisplay = true
        }
    }

    private func stopProgressRefreshTimer() {
        progressRefreshTimer?.invalidate()
        progressRefreshTimer = nil
    }

    override var intrinsicContentSize: NSSize {
        let progression: CTFrameProgression = isVertical ? .rightToLeft : .topToBottom
        let frameAttr: [CTFrame.AttributeKey: Any] = [.progression: progression.rawValue as NSNumber]
        let framesetter = CTFramesetter.create(attributedString: attrString)
        let constraints = CGSize(width: CGFloat.infinity, height: .infinity)
        return framesetter.suggestFrameSize(constraints: constraints, frameAttributes: frameAttr).size
    }

    override func draw(_ dirtyRect: NSRect) {
//        let image = NSImage(size: dirtyRect.size, flipped: true) { rect in
//            guard let context = NSGraphicsContext.current else { return false }
//            let cgContext = context.cgContext
//            cgContext.textMatrix = .identity
//            cgContext.translateBy(x: 0, y: rect.height)
//            cgContext.scaleBy(x: 1.0, y: -1.0)
//            CTFrameDraw(self.ctFrame, cgContext)
//            return true
//        }
//        image.draw(in: dirtyRect)
        guard let context = NSGraphicsContext.current else { return }
        let cgContext = context.cgContext
        let frame = ctFrame(dirtyRect)
        configureFlippedTextContext(cgContext)
        CTFrameDraw(frame, cgContext)

        if hasHorizontalProgress,
           let progressFrame = progressFrame(),
           let lineRect = horizontalProgressLineRect(from: frame),
           currentHorizontalProgressWidth() > 0 {
            cgContext.saveGState()
            cgContext.clip(to: horizontalProgressClipRect(width: currentHorizontalProgressWidth(), lineRect: lineRect))
            CTFrameDraw(progressFrame, cgContext)
            cgContext.restoreGState()
        }

        drawRomajiAnnotations(in: cgContext, frame: frame)
    }

    // MARK: - Progress

    // TODO: multi-line
    private lazy var progressLayer: CALayer = {
        let pLayer = CALayer()
        wantsLayer = true
        layer?.addSublayer(pLayer)
        return pLayer
    }()

    @objc dynamic var progressColor: NSColor? {
        get {
            return storedProgressColor ?? progressLayer.backgroundColor.flatMap(NSColor.init)
        }
        set {
            storedProgressColor = newValue
            _progressFrame = nil
            progressLayer.backgroundColor = isVertical ? newValue?.cgColor : nil
            needsDisplay = true
        }
    }

    func setProgressAnimation(color: NSColor, progress: [(TimeInterval, Int)]) {
        removeProgressAnimation()
        layoutSubtreeIfNeeded()
        storedProgressColor = color
        _progressFrame = nil

        let frame = ctFrame()
        guard let line = frame.lines.first,
              let origin = frame.lineOrigins(range: CFRange(location: 0, length: 1)).first else {
            return
        }

        if isVertical {
            setVerticalProgressAnimation(color: color, frame: frame, line: line, origin: origin, progress: progress)
        } else {
            setHorizontalProgressAnimation(frame: frame, line: line, origin: origin, progress: progress)
        }
    }

    private func setVerticalProgressAnimation(
        color: NSColor,
        frame: CTFrame,
        line: CTLine,
        origin: CGPoint,
        progress: [(TimeInterval, Int)]
    ) {
        hasHorizontalProgress = false
        progressLayer.isHidden = false
        progressLayer.backgroundColor = color.cgColor
        progressLayer.mask = nil

        var lineBounds = line.bounds()
        var transform = CGAffineTransform.translate(x: origin.x, y: origin.y)
        transform.transform(by: .swap() * .translate(y: -lineBounds.width))
        transform *= .flip(height: bounds.height)
        lineBounds.apply(t: transform)

        progressLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        progressLayer.frame = lineBounds

        let mask = CALayer()
        mask.frame = progressLayer.bounds
        let img = NSImage(size: progressLayer.bounds.size, flipped: false) { _ in
            let context = NSGraphicsContext.current!.cgContext
            self.drawVerticalProgressMask(frame: frame, in: context, lineBounds: lineBounds)
            return true
        }
        mask.contents = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        progressLayer.mask = mask

        addInlineProgressAnimation(to: line, progress: progress, progressOffset: 0, isVertical: true)
    }

    private func setHorizontalProgressAnimation(
        frame: CTFrame,
        line: CTLine,
        origin: CGPoint,
        progress: [(TimeInterval, Int)]
    ) {
        hasHorizontalProgress = true
        progressLayer.isHidden = true
        progressLayer.backgroundColor = nil
        progressLayer.mask = nil

        guard let lineRect = horizontalProgressLineRect(from: frame) else { return }

        progressLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        progressLayer.frame = lineRect

        addInlineProgressAnimation(to: line, progress: progress, progressOffset: 0, isVertical: false)
        startProgressRefreshTimer()
        needsDisplay = true
    }

    private func addInlineProgressAnimation(
        to line: CTLine,
        progress: [(TimeInterval, Int)],
        progressOffset: CGFloat,
        isVertical: Bool
    ) {
        guard let index = progress.firstIndex(where: { $0.0 > 0 }) else { return }
        var map = progress.map { ($0.0, line.offset(charIndex: $0.1).primary + progressOffset) }
        if index > 0 {
            let progress = map[index - 1].1 + CGFloat(map[index - 1].0) * (map[index].1 - map[index - 1].1) / CGFloat(map[index].0 - map[index - 1].0)
            map.replaceSubrange(..<index, with: [(0, progress)])
        }

        let duration = map.last!.0
        let animation = CAKeyframeAnimation()
        animation.keyTimes = map.map { ($0.0 / duration) as NSNumber }
        animation.values = map.map { $0.1 }
        animation.keyPath = isVertical ? "bounds.size.height" : "bounds.size.width"
        animation.duration = duration
        progressLayer.add(animation, forKey: "inlineProgress")
    }

    func pauseProgressAnimation() {
        let pausedTime = progressLayer.convertTime(CACurrentMediaTime(), from: nil)
        progressLayer.speed = 0
        progressLayer.timeOffset = pausedTime
        stopProgressRefreshTimer()
    }

    func resumeProgressAnimation() {
        let pausedTime = progressLayer.timeOffset
        progressLayer.speed = 1
        progressLayer.timeOffset = 0
        progressLayer.beginTime = 0
        let timeSincePause = progressLayer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        progressLayer.beginTime = timeSincePause
        if hasHorizontalProgress {
            startProgressRefreshTimer()
            needsDisplay = true
        }
    }

    func removeProgressAnimation() {
        stopProgressRefreshTimer()
        hasHorizontalProgress = false
        storedProgressColor = nil
        _progressFrame = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.speed = 1
        progressLayer.timeOffset = 0
        progressLayer.isHidden = false
        progressLayer.backgroundColor = nil
        progressLayer.mask = nil
        progressLayer.removeAnimation(forKey: "inlineProgress")
        progressLayer.frame = .zero
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
