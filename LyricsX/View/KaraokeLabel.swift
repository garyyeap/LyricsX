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
    private var horizontalProgress: HorizontalProgressAnimation?
    private var storedProgressColor: NSColor?
    private var progressRefreshTimer: Timer?

    private struct HorizontalProgressAnimation {
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

    private func ctFrame() -> CTFrame {
        if let ctFrame = _ctFrame {
            return ctFrame
        }
        layoutSubtreeIfNeeded()
        let ctFrame = makeFrame(for: attrString)
        _ctFrame = ctFrame
        _progressFrame = nil
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

    private func drawCTFrame(_ frame: CTFrame, in context: CGContext, offsetTo origin: CGPoint = .zero) {
        configureFlippedTextContext(context)
        context.translateBy(x: -origin.x, y: -origin.y)
        CTFrameDraw(frame, context)
    }

    private func progressLineBounds(for line: CTLine, origin: CGPoint) -> (frameBounds: CGRect, xOffset: CGFloat) {
        var localBounds = line.bounds()
        if !isVertical {
            let glyphBounds = line.bounds(options: [.useGlyphPathBounds])
            if !glyphBounds.isNull {
                localBounds = glyphBounds
            }
        }
        let xOffset = -localBounds.origin.x
        var frameBounds = localBounds
        var transform = CGAffineTransform.translate(x: origin.x, y: origin.y)
        if isVertical {
            transform.transform(by: .swap() * .translate(y: -localBounds.width))
            transform *= .flip(height: bounds.height)
        }
        frameBounds.apply(t: transform)
        return (frameBounds, xOffset)
    }

    private func horizontalProgressMetrics(line: CTLine, origin: CGPoint) -> (lineRect: CGRect, xOffset: CGFloat) {
        var localBounds = line.bounds(options: [.useGlyphPathBounds])
        if localBounds.isNull {
            localBounds = line.bounds()
        }
        let xOffset = -localBounds.origin.x
        let lineRect = localBounds.applying(.translate(x: origin.x, y: origin.y))
        return (lineRect, xOffset)
    }

    private func configureFlippedTextContext(_ context: CGContext) {
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1.0, y: -1.0)
    }

    private func drawVerticalProgressMask(frame: CTFrame, in context: CGContext, lineBounds: CGRect) {
        // Mask bitmap uses unflipped coordinates; lineBounds is already in layer space.
        let ori = lineBounds.applying(.flip(height: bounds.height)).origin
        context.concatenate(.translate(x: -ori.x, y: -ori.y))
        CTFrameDraw(frame, context)
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

    private func resolvedProgressMap(
        line: CTLine,
        xOffset: CGFloat,
        progress: [(TimeInterval, Int)]
    ) -> [(TimeInterval, CGFloat)] {
        guard let index = progress.firstIndex(where: { $0.0 > 0 }) else { return [] }
        var map = progress.map { ($0.0, line.offset(charIndex: $0.1).primary + xOffset) }
        if index > 0 {
            let width = map[index - 1].1 + CGFloat(map[index - 1].0) * (map[index].1 - map[index - 1].1) / CGFloat(map[index].0 - map[index - 1].0)
            map.replaceSubrange(..<index, with: [(0, width)])
        }
        return map
    }

    private func progressWidth(at elapsed: TimeInterval, map: [(TimeInterval, CGFloat)]) -> CGFloat {
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

    private func currentHorizontalProgressElapsed() -> TimeInterval? {
        guard let horizontalProgress else { return nil }
        if let pausedElapsed = horizontalProgress.pausedElapsed {
            return pausedElapsed
        }
        return CACurrentMediaTime() - horizontalProgress.startTime
    }

    private func startProgressRefreshTimer() {
        stopProgressRefreshTimer()
        progressRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.horizontalProgress != nil else {
                timer.invalidate()
                return
            }
            if let elapsed = self.currentHorizontalProgressElapsed(),
               let duration = self.horizontalProgress?.duration,
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

    override var intrinsicContentSize: NSSize {
        let progression: CTFrameProgression = isVertical ? .rightToLeft : .topToBottom
        let frameAttr: [CTFrame.AttributeKey: Any] = [.progression: progression.rawValue as NSNumber]
        let framesetter = CTFramesetter.create(attributedString: attrString)
        let constraints = CGSize(width: CGFloat.infinity, height: .infinity)
        return framesetter.suggestFrameSize(constraints: constraints, frameAttributes: frameAttr).size
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        let cgContext = context.cgContext
        let frame = ctFrame()

        drawCTFrame(frame, in: cgContext)

        if let horizontalProgress,
           let progressColoredFrame = progressFrame(),
           let line = frame.lines.first,
           let origin = frame.lineOrigins(range: CFRange(location: 0, length: 1)).first {
            let (lineRect, xOffset) = horizontalProgressMetrics(line: line, origin: origin)
            let map = resolvedProgressMap(line: line, xOffset: xOffset, progress: horizontalProgress.tags)
            let elapsed = horizontalProgress.pausedElapsed ?? (CACurrentMediaTime() - horizontalProgress.startTime)
            let width = progressWidth(at: elapsed, map: map)
            if width > 0 {
                cgContext.saveGState()
                configureFlippedTextContext(cgContext)
                cgContext.clip(to: horizontalProgressClipRect(width: width, lineRect: lineRect))
                CTFrameDraw(progressColoredFrame, cgContext)
                cgContext.restoreGState()
            }
        }

        configureFlippedTextContext(cgContext)
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
        invalidateFrameCache()

        let frame = ctFrame()
        guard let line = frame.lines.first,
              let origin = frame.lineOrigins(range: CFRange(location: 0, length: 1)).first else {
            return
        }

        if isVertical {
            setVerticalProgressAnimation(color: color, frame: frame, line: line, origin: origin, progress: progress)
        } else {
            setHorizontalProgressAnimation(progress: progress)
        }
    }

    private func setVerticalProgressAnimation(
        color: NSColor,
        frame: CTFrame,
        line: CTLine,
        origin: CGPoint,
        progress: [(TimeInterval, Int)]
    ) {
        horizontalProgress = nil
        progressLayer.isHidden = false
        progressLayer.backgroundColor = color.cgColor
        progressLayer.mask = nil

        let (lineBounds, _) = progressLineBounds(for: line, origin: origin)

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

    private func setHorizontalProgressAnimation(progress: [(TimeInterval, Int)]) {
        guard progress.contains(where: { $0.0 > 0 }) else { return }
        horizontalProgress = HorizontalProgressAnimation(
            tags: progress,
            duration: progress.last!.0,
            startTime: CACurrentMediaTime(),
            pausedElapsed: nil
        )
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
        if var horizontalProgress {
            if horizontalProgress.pausedElapsed == nil {
                horizontalProgress.pausedElapsed = CACurrentMediaTime() - horizontalProgress.startTime
                self.horizontalProgress = horizontalProgress
            }
            stopProgressRefreshTimer()
            needsDisplay = true
            return
        }
        let pausedTime = progressLayer.convertTime(CACurrentMediaTime(), from: nil)
        progressLayer.speed = 0
        progressLayer.timeOffset = pausedTime
    }

    func resumeProgressAnimation() {
        if var horizontalProgress, let pausedElapsed = horizontalProgress.pausedElapsed {
            horizontalProgress.startTime = CACurrentMediaTime() - pausedElapsed
            horizontalProgress.pausedElapsed = nil
            self.horizontalProgress = horizontalProgress
            startProgressRefreshTimer()
            needsDisplay = true
            return
        }
        let pausedTime = progressLayer.timeOffset
        progressLayer.speed = 1
        progressLayer.timeOffset = 0
        progressLayer.beginTime = 0
        let timeSincePause = progressLayer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        progressLayer.beginTime = timeSincePause
    }

    func removeProgressAnimation() {
        stopProgressRefreshTimer()
        horizontalProgress = nil
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
