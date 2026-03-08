import AppKit
import ApplicationServices
import Carbon
import Foundation

protocol ExecutionEngine {
    func execute(plan: ActionPlan) async -> ExecutionResult
}

final class ActionExecutor: ExecutionEngine {
    func execute(plan: ActionPlan) async -> ExecutionResult {
        var completed: [String] = []
        var actionResults: [ActionExecutionRecord] = []
        for action in plan.actions {
            let start = Date()
            do {
                try execute(action)
                completed.append(action.id)
                let latencyMs = elapsedMillis(since: start)
                actionResults.append(
                    ActionExecutionRecord(
                        id: action.id,
                        status: .success,
                        errorCode: nil,
                        latencyMs: latencyMs
                    )
                )
                Logger.info("Executed action \(action.id): \(action.kind.rawValue)")
            } catch {
                let latencyMs = elapsedMillis(since: start)
                let code = errorCode(from: error)
                actionResults.append(
                    ActionExecutionRecord(
                        id: action.id,
                        status: .failure,
                        errorCode: code,
                        latencyMs: latencyMs
                    )
                )
                return ExecutionResult(
                    status: .failure,
                    completedActions: completed,
                    failedActionId: action.id,
                    reason: error.localizedDescription,
                    recoverySuggestion: "Retry command",
                    actionResults: actionResults
                )
            }
        }

        return ExecutionResult(
            status: .success,
            completedActions: completed,
            failedActionId: nil,
            reason: nil,
            recoverySuggestion: nil,
            actionResults: actionResults
        )
    }

    private func execute(_ action: AgentAction) throws {
        switch action.kind {
        case .openApp:
            try openApp(action)
        case .type:
            try typeText(action.text)
        case .keyCombo:
            try pressKeyCombo(action.keyCombo)
        case .runAppleScript:
            try runAppleScript(action.text ?? action.target ?? "")
        case .wait:
            try wait(action)
        case .click:
            try withRetry { try clickTarget(action.target, clickCount: 1) }
        case .doubleClick:
            try withRetry { try clickTarget(action.target, clickCount: 2) }
        case .scroll:
            try scrollTarget(action.target)
        case .selectMenuItem:
            try withRetry { try selectMenuItem(action.target) }
        }
    }

    private func wait(_ action: AgentAction) throws {
        let timeout = max(0.05, Double(action.timeoutMs) / 1000.0)
        guard let target = action.target, !target.isEmpty else {
            Thread.sleep(forTimeInterval: timeout)
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isElementPresent(target) {
                return
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        throw ActionExecutionError.elementNotFound("Wait condition timed out for '\(target)'")
    }

    private func openApp(_ action: AgentAction) throws {
        if let bundleID = action.appBundleId, !bundleID.isEmpty {
            guard let resolvedURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw ActionExecutionError.invalidActionPayload("Could not resolve bundle id: \(bundleID)")
            }
            let semaphore = DispatchSemaphore(value: 0)
            var openError: Error?
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true

            NSWorkspace.shared.openApplication(at: resolvedURL, configuration: configuration) { _, error in
                openError = error
                semaphore.signal()
            }

            if semaphore.wait(timeout: .now() + 5) == .timedOut {
                throw ActionExecutionError.invalidActionPayload("Timed out launching app bundle id \(bundleID)")
            }
            if let openError {
                throw ActionExecutionError.invalidActionPayload("Launch failed: \(openError.localizedDescription)")
            }
        } else {
            guard let appName = action.target, !appName.isEmpty else {
                throw ActionExecutionError.invalidActionPayload("Missing app name for open_app")
            }
            let escaped = escapeAppleScriptText(appName)
            try runAppleScript(
                """
                tell application "\(escaped)"
                    activate
                end tell
                """
            )
        }
    }

    private func typeText(_ text: String?) throws {
        guard let text, !text.isEmpty else {
            throw ActionExecutionError.invalidActionPayload("Missing text for type action")
        }
        guard ensureFocusedApplicationAvailable() != nil else {
            throw ActionExecutionError.elementNotFound("Focused app unavailable")
        }
        let escaped = escapeAppleScriptText(text)
        try runAppleScript(
            """
            tell application "System Events"
                keystroke "\(escaped)"
            end tell
            """
        )
    }

    private func pressKeyCombo(_ combo: String?) throws {
        guard let combo, !combo.isEmpty else {
            throw ActionExecutionError.invalidActionPayload("Missing key_combo value")
        }
        let parts = combo
            .lowercased()
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let key = parts.last else {
            throw ActionExecutionError.invalidActionPayload("Invalid key_combo format: \(combo)")
        }

        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default:
                throw ActionExecutionError.invalidActionPayload("Unsupported modifier: \(modifier)")
            }
        }

        guard let keyCode = keyCode(for: key) else {
            throw ActionExecutionError.invalidActionPayload("Unsupported key: \(key)")
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw ActionExecutionError.systemEventCreationFailed
        }

        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func runAppleScript(_ script: String) throws {
        guard !script.isEmpty else {
            throw ActionExecutionError.invalidActionPayload("AppleScript payload is empty")
        }
        var error: NSDictionary?
        let scriptObject = NSAppleScript(source: script)
        _ = scriptObject?.executeAndReturnError(&error)
        if let error {
            throw ActionExecutionError.appleScriptFailed(error.description)
        }
    }

    private func clickTarget(_ target: String?, clickCount: Int) throws {
        guard AXIsProcessTrusted() else {
            throw ActionExecutionError.permissions("Accessibility permission is required for click actions")
        }
        guard let target, !target.isEmpty else {
            throw ActionExecutionError.invalidActionPayload("Missing target for click action")
        }

        guard let focusedApp = ensureFocusedApplicationAvailable() else {
            throw ActionExecutionError.elementNotFound("Focused app unavailable")
        }

        let rootElement: AXUIElement
        if let windowAny = copyAttribute(focusedApp, attribute: kAXFocusedWindowAttribute as CFString) {
            rootElement = windowAny as! AXUIElement
        } else {
            rootElement = focusedApp
        }

        guard let matchedElement = findElement(containing: target, in: rootElement, maxDepth: 8, maxNodes: 500) else {
            throw ActionExecutionError.elementNotFound("Could not find element matching target '\(target)'")
        }
        let element = interactionElement(for: matchedElement)
        let matchedRole = (copyAttribute(matchedElement, attribute: kAXRoleAttribute as CFString) as? String) ?? "UnknownRole"
        let interactionRole = (copyAttribute(element, attribute: kAXRoleAttribute as CFString) as? String) ?? "UnknownRole"
        if matchedRole != interactionRole {
            Logger.info("Promoted interaction target from role \(matchedRole) to \(interactionRole) for '\(target)'")
        }

        if try pressElementOrAncestor(element) {
            return
        }

        if try clickElementByCoordinates(element, clickCount: clickCount) {
            return
        }

        throw ActionExecutionError.elementInteractionFailed("Could not interact with target '\(target)' using AXPress or coordinate click")
    }

    private func scrollTarget(_ target: String?) throws {
        let normalized = (target ?? "down").lowercased()
        let isUp = normalized.contains("up")
        let isLeft = normalized.contains("left")
        let isRight = normalized.contains("right")
        let magnitude = extractMagnitude(from: normalized, defaultValue: 8)

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ActionExecutionError.systemEventCreationFailed
        }

        let vertical: Int32
        if isUp {
            vertical = Int32(magnitude)
        } else {
            vertical = -Int32(magnitude)
        }

        let horizontal: Int32
        if isLeft {
            horizontal = Int32(magnitude)
        } else if isRight {
            horizontal = -Int32(magnitude)
        } else {
            horizontal = 0
        }

        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else {
            throw ActionExecutionError.systemEventCreationFailed
        }
        event.post(tap: .cghidEventTap)
    }

    private func selectMenuItem(_ target: String?) throws {
        guard let target, !target.isEmpty else {
            throw ActionExecutionError.invalidActionPayload("Missing target for select_menu_item action")
        }
        guard let appName = NSWorkspace.shared.frontmostApplication?.localizedName, !appName.isEmpty else {
            throw ActionExecutionError.invalidActionPayload("Unable to detect frontmost app for menu selection")
        }

        let components = splitMenuPath(target)
        guard components.count >= 2 else {
            throw ActionExecutionError.invalidActionPayload(
                "Menu path must be like 'File > New Window' (received: \(target))"
            )
        }

        let menu = escapeAppleScriptText(components[0])
        let item = escapeAppleScriptText(components[1])
        let app = escapeAppleScriptText(appName)

        try runAppleScript(
            """
            tell application "System Events"
                tell process "\(app)"
                    click menu item "\(item)" of menu "\(menu)" of menu bar 1
                end tell
            end tell
            """
        )
    }

    private func keyCode(for key: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "a": CGKeyCode(kVK_ANSI_A),
            "b": CGKeyCode(kVK_ANSI_B),
            "c": CGKeyCode(kVK_ANSI_C),
            "d": CGKeyCode(kVK_ANSI_D),
            "e": CGKeyCode(kVK_ANSI_E),
            "f": CGKeyCode(kVK_ANSI_F),
            "g": CGKeyCode(kVK_ANSI_G),
            "h": CGKeyCode(kVK_ANSI_H),
            "i": CGKeyCode(kVK_ANSI_I),
            "j": CGKeyCode(kVK_ANSI_J),
            "k": CGKeyCode(kVK_ANSI_K),
            "l": CGKeyCode(kVK_ANSI_L),
            "m": CGKeyCode(kVK_ANSI_M),
            "n": CGKeyCode(kVK_ANSI_N),
            "o": CGKeyCode(kVK_ANSI_O),
            "p": CGKeyCode(kVK_ANSI_P),
            "q": CGKeyCode(kVK_ANSI_Q),
            "r": CGKeyCode(kVK_ANSI_R),
            "s": CGKeyCode(kVK_ANSI_S),
            "t": CGKeyCode(kVK_ANSI_T),
            "u": CGKeyCode(kVK_ANSI_U),
            "v": CGKeyCode(kVK_ANSI_V),
            "w": CGKeyCode(kVK_ANSI_W),
            "x": CGKeyCode(kVK_ANSI_X),
            "y": CGKeyCode(kVK_ANSI_Y),
            "z": CGKeyCode(kVK_ANSI_Z),
            "0": CGKeyCode(kVK_ANSI_0),
            "1": CGKeyCode(kVK_ANSI_1),
            "2": CGKeyCode(kVK_ANSI_2),
            "3": CGKeyCode(kVK_ANSI_3),
            "4": CGKeyCode(kVK_ANSI_4),
            "5": CGKeyCode(kVK_ANSI_5),
            "6": CGKeyCode(kVK_ANSI_6),
            "7": CGKeyCode(kVK_ANSI_7),
            "8": CGKeyCode(kVK_ANSI_8),
            "9": CGKeyCode(kVK_ANSI_9),
            "enter": CGKeyCode(kVK_Return),
            "return": CGKeyCode(kVK_Return),
            "space": CGKeyCode(kVK_Space),
            "tab": CGKeyCode(kVK_Tab),
            "escape": CGKeyCode(kVK_Escape),
            "esc": CGKeyCode(kVK_Escape),
            "up": CGKeyCode(kVK_UpArrow),
            "down": CGKeyCode(kVK_DownArrow),
            "left": CGKeyCode(kVK_LeftArrow),
            "right": CGKeyCode(kVK_RightArrow),
        ]
        return map[key]
    }

    private func escapeAppleScriptText(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func splitMenuPath(_ target: String) -> [String] {
        let delimiters = [" > ", ">", "/", "->"]
        var working = target
        for delimiter in delimiters {
            working = working.replacingOccurrences(of: delimiter, with: "|")
        }
        return working
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func extractMagnitude(from text: String, defaultValue: Int) -> Int {
        let digits = text.filter(\.isNumber)
        if let value = Int(digits), value > 0 {
            return min(value, 50)
        }
        return defaultValue
    }

    private func copyAttribute(_ element: AXUIElement, attribute: CFString) -> AnyObject? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        return value
    }

    private func copyElementAttribute(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func copyAXValueAttribute(_ element: AXUIElement, attribute: CFString) -> AXValue? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }

    private func copyActionNames(_ element: AXUIElement) -> [String] {
        var namesRef: CFArray?
        let result = AXUIElementCopyActionNames(element, &namesRef)
        guard result == .success, let namesRef else { return [] }
        return (namesRef as [AnyObject]).compactMap { $0 as? String }
    }

    private func pressElementOrAncestor(_ element: AXUIElement, maxAncestorDepth: Int = 4) throws -> Bool {
        var current: AXUIElement? = element
        var depth = 0

        while let candidate = current, depth <= maxAncestorDepth {
            let actions = copyActionNames(candidate)
            if actions.contains(kAXPressAction as String) {
                let result = AXUIElementPerformAction(candidate, kAXPressAction as CFString)
                if result == .success {
                    return true
                }
                Logger.info("AXPress failed at depth \(depth) with AXError \(result.rawValue); trying fallback")
            }

            current = copyElementAttribute(candidate, attribute: kAXParentAttribute as CFString)
            depth += 1
        }

        return false
    }

    private func clickElementByCoordinates(_ element: AXUIElement, clickCount: Int, maxAncestorDepth: Int = 4) throws -> Bool {
        var current: AXUIElement? = element
        var depth = 0

        while let candidate = current, depth <= maxAncestorDepth {
            if let point = elementCenter(candidate) {
                try postMouseClick(at: point, clickCount: max(1, clickCount))
                return true
            }
            current = copyElementAttribute(candidate, attribute: kAXParentAttribute as CFString)
            depth += 1
        }
        return false
    }

    private func elementCenter(_ element: AXUIElement) -> CGPoint? {
        if let positionValue = copyAXValueAttribute(element, attribute: kAXPositionAttribute as CFString),
           let sizeValue = copyAXValueAttribute(element, attribute: kAXSizeAttribute as CFString)
        {
            var position = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetType(positionValue) == .cgPoint,
               AXValueGetType(sizeValue) == .cgSize,
               AXValueGetValue(positionValue, .cgPoint, &position),
               AXValueGetValue(sizeValue, .cgSize, &size),
               size.width > 1,
               size.height > 1
            {
                return CGPoint(x: position.x + (size.width / 2.0), y: position.y + (size.height / 2.0))
            }
        }
        return nil
    }

    private func postMouseClick(at point: CGPoint, clickCount: Int) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ActionExecutionError.systemEventCreationFailed
        }

        for idx in 1 ... clickCount {
            guard let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
            ),
            let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else {
                throw ActionExecutionError.systemEventCreationFailed
            }

            mouseDown.setIntegerValueField(.mouseEventClickState, value: Int64(idx))
            mouseUp.setIntegerValueField(.mouseEventClickState, value: Int64(idx))
            mouseDown.post(tap: .cghidEventTap)
            mouseUp.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func findElement(
        containing target: String,
        in root: AXUIElement,
        maxDepth: Int,
        maxNodes: Int
    ) -> AXUIElement? {
        if let indexed = findElementByIndex(containing: target, in: root, maxDepth: maxDepth, maxNodes: maxNodes) {
            return indexed
        }

        let needle = target.lowercased()
        let tokens = needle
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { !$0.isEmpty }
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        var best: (element: AXUIElement, score: Int, depth: Int, order: Int)?
        var order = 0

        while !queue.isEmpty, visited < maxNodes {
            let (element, depth) = queue.removeFirst()
            visited += 1
            order += 1

            let score = elementScore(element, needle: needle, tokens: tokens)
            if score > 0 {
                if let current = best {
                    if score > current.score || (score == current.score && depth < current.depth) || (score == current.score && depth == current.depth && order < current.order) {
                        best = (element, score, depth, order)
                    }
                } else {
                    best = (element, score, depth, order)
                }
            }

            guard depth < maxDepth else { continue }
            if let children = copyAttribute(element, attribute: kAXChildrenAttribute as CFString) as? [AnyObject] {
                for child in children {
                    queue.append((child as! AXUIElement, depth + 1))
                }
            }
        }

        if best != nil {
            Logger.info("AX matcher chose best score \(best?.score ?? 0) for target '\(target)'")
        }
        return best?.element
    }

    private func findElementByIndex(
        containing target: String,
        in root: AXUIElement,
        maxDepth: Int,
        maxNodes: Int
    ) -> AXUIElement? {
        guard let requestedIndex = indexedTargetValue(from: target) else {
            return nil
        }

        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if visited == requestedIndex {
                Logger.info("AX matcher resolved direct index [\(requestedIndex)]")
                return element
            }

            guard depth < maxDepth else { continue }
            if let children = copyAttribute(element, attribute: kAXChildrenAttribute as CFString) as? [AnyObject] {
                for child in children {
                    queue.append((child as! AXUIElement, depth + 1))
                }
            }
        }

        return nil
    }

    private func indexedTargetValue(from target: String) -> Int? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["),
           let closing = trimmed.firstIndex(of: "]") {
            let digits = trimmed[trimmed.index(after: trimmed.startIndex) ..< closing]
            return Int(digits)
        }
        let compact = trimmed.filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return nil }
        guard compact.allSatisfy(\.isNumber) else { return nil }
        return Int(compact)
    }

    private func interactionElement(for element: AXUIElement, maxAncestorDepth: Int = 4) -> AXUIElement {
        var current = element
        var depth = 0

        while depth <= maxAncestorDepth {
            let role = (copyAttribute(current, attribute: kAXRoleAttribute as CFString) as? String) ?? ""
            let actions = copyActionNames(current)
            if actions.contains(kAXPressAction as String) || actionableRoles.contains(role) {
                Logger.info("Found actionable interaction node at depth \(depth) with role \(role)")
                return current
            }
            guard let parent = copyElementAttribute(current, attribute: kAXParentAttribute as CFString) else {
                break
            }
            current = parent
            depth += 1
        }

        if let descendant = findInteractiveDescendant(from: element, maxDepth: maxAncestorDepth) {
            Logger.info("No actionable ancestor found for matched target; using interactive descendant fallback")
            return descendant
        }

        return element
    }

    private func findInteractiveDescendant(from element: AXUIElement, maxDepth: Int) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(element, 0)]
        while !queue.isEmpty {
            let (candidate, depth) = queue.removeFirst()
            let role = (copyAttribute(candidate, attribute: kAXRoleAttribute as CFString) as? String) ?? ""
            let actions = copyActionNames(candidate)
            if actions.contains(kAXPressAction as String) || actionableRoles.contains(role) {
                return candidate
            }
            guard depth < maxDepth else { continue }
            if let children = copyAttribute(candidate, attribute: kAXChildrenAttribute as CFString) as? [AnyObject] {
                for child in children {
                    queue.append((child as! AXUIElement, depth + 1))
                }
            }
        }
        return nil
    }

    private var actionableRoles: Set<String> {
        [
            kAXButtonRole as String,
            kAXCellRole as String,
            kAXRowRole as String,
            kAXMenuItemRole as String,
            "AXLink",
            kAXTextFieldRole as String,
            kAXPopUpButtonRole as String,
            kAXRadioButtonRole as String,
            kAXCheckBoxRole as String,
            kAXTabGroupRole as String
        ]
    }

    private func elementScore(_ element: AXUIElement, needle: String, tokens: [String]) -> Int {
        let fields: [(CFString, Int)] = [
            (kAXTitleAttribute as CFString, 8),
            (kAXDescriptionAttribute as CFString, 5),
            (kAXValueAttribute as CFString, 4),
            (kAXRoleAttribute as CFString, 3),
            (kAXRoleDescriptionAttribute as CFString, 2),
        ]

        var score = 0
        for (field, weight) in fields {
            guard let value = copyAttribute(element, attribute: field) else { continue }
            let text = String(describing: value).lowercased()
            if text.contains(needle) {
                score += weight * 2
            }
            for token in tokens where text.contains(token) {
                score += weight
            }
        }
        if let enabled = copyAttribute(element, attribute: kAXEnabledAttribute as CFString) as? Bool {
            score += enabled ? 2 : -2
        }
        return score
    }

    private func isElementPresent(_ target: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let focusedApp = ensureFocusedApplicationAvailable() else {
            return false
        }
        let root: AXUIElement
        if let windowAny = copyAttribute(focusedApp, attribute: kAXFocusedWindowAttribute as CFString) {
            root = windowAny as! AXUIElement
        } else {
            root = focusedApp
        }
        return findElement(containing: target, in: root, maxDepth: 7, maxNodes: 500) != nil
    }

    private func focusedApplicationElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        if let focusedAppAny = copyAttribute(
            systemWide,
            attribute: kAXFocusedApplicationAttribute as CFString
        ) {
            return (focusedAppAny as! AXUIElement)
        }
        if let focusedUIElementAny = copyAttribute(
            systemWide,
            attribute: kAXFocusedUIElementAttribute as CFString
        ) {
            let focusedUIElement = focusedUIElementAny as! AXUIElement
            var pid: pid_t = 0
            if AXUIElementGetPid(focusedUIElement, &pid) == .success, pid > 0 {
                return AXUIElementCreateApplication(pid)
            }
        }
        if let app = frontmostRunningApplication() {
            return AXUIElementCreateApplication(app.processIdentifier)
        }
        return nil
    }

    private func ensureFocusedApplicationAvailable(
        timeout: TimeInterval = 0.9,
        pollInterval: TimeInterval = 0.06
    ) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() <= deadline {
            if let focusedApp = focusedApplicationElement() {
                return focusedApp
            }
            if let app = frontmostRunningApplication() {
                _ = app.activate(options: [])
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return focusedApplicationElement()
    }

    private func frontmostRunningApplication() -> NSRunningApplication? {
        if Thread.isMainThread {
            return NSWorkspace.shared.frontmostApplication
        }
        var app: NSRunningApplication?
        DispatchQueue.main.sync {
            app = NSWorkspace.shared.frontmostApplication
        }
        return app
    }

    private func withRetry<T>(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 0.12,
        operation: () throws -> T
    ) throws -> T {
        var attempt = 0
        while true {
            do {
                return try operation()
            } catch {
                attempt += 1
                let message = error.localizedDescription.lowercased()
                let shouldRetry = message.contains("element not found") || message.contains("interaction failed")
                if !shouldRetry || attempt >= maxAttempts {
                    throw error
                }
                let delay = min(0.8, baseDelay * pow(2.0, Double(attempt - 1)))
                Thread.sleep(forTimeInterval: delay)
            }
        }
    }

    private func elapsedMillis(since start: Date) -> Int {
        Int(max(0, Date().timeIntervalSince(start) * 1000.0))
    }

    private func errorCode(from error: Error) -> String {
        if let local = error as? LocalizedError, let description = local.errorDescription {
            if description.contains("Permission") {
                return "permission_denied"
            }
            if description.contains("Element not found") {
                return "element_not_found"
            }
            if description.contains("Element interaction failed") {
                return "element_interaction_failed"
            }
            if description.contains("AppleScript") {
                return "applescript_failed"
            }
        }
        return "execution_error"
    }
}

private enum ActionExecutionError: LocalizedError {
    case unsupportedAction(String)
    case invalidActionPayload(String)
    case appleScriptFailed(String)
    case systemEventCreationFailed
    case permissions(String)
    case elementNotFound(String)
    case elementInteractionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedAction(kind):
            return "Unsupported action kind: \(kind)"
        case let .invalidActionPayload(message):
            return "Invalid action payload: \(message)"
        case let .appleScriptFailed(message):
            return "AppleScript execution failed: \(message)"
        case .systemEventCreationFailed:
            return "Could not create keyboard event."
        case let .permissions(message):
            return "Permission error: \(message)"
        case let .elementNotFound(message):
            return "Element not found: \(message)"
        case let .elementInteractionFailed(message):
            return "Element interaction failed: \(message)"
        }
    }
}
