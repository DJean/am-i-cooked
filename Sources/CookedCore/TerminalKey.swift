public enum TerminalKey: Sendable, Equatable {
    case tabLeft, tabRight, up, down, previous, next, toggle, share, shareCompany, quit, compare
    case text(String), enter, escape, backspace, clear, tab
    public var command: Self {
        guard case let .text(text) = self else { return self }
        if text == "S" { return .shareCompany }
        switch text.lowercased() {
        case "a": return .tabLeft
        case "d": return .tabRight
        case " ": return .toggle
        case "s": return .share
        case "q": return .quit
        case "c": return .compare
        case "k": return .up
        case "j": return .down
        default: return self
        }
    }
    public func globalCommand(searching: Bool) -> Self? {
        guard !searching else { return nil }
        switch command {
        case .tab: return .tabRight
        case .tabLeft, .tabRight, .share, .shareCompany, .quit: return command
        default: return nil
        }
    }
}

public struct TerminalKeyDecoder {
    private enum EscapeState { case none, escape, sequence }
    private var escapeState = EscapeState.none
    private var utf8: [UInt8] = []
    private var utf8Count = 0
    public init() {}
    public mutating func flushEscape() -> [TerminalKey] {
        guard escapeState != .none else { return [] }
        escapeState = .none; return [.escape]
    }
    public mutating func decode(_ bytes: [UInt8]) -> [TerminalKey] {
        var keys: [TerminalKey] = []
        for byte in bytes {
            if byte == 27 {
                if escapeState != .none { keys.append(.escape) }
                escapeState = .escape; utf8 = []
                continue
            }
            if escapeState == .escape {
                if byte == 91 || byte == 79 { escapeState = .sequence; continue }
                keys.append(.escape); escapeState = .none
            }
            if escapeState == .sequence {
                if (64...126).contains(byte) {
                    escapeState = .none
                    switch byte {
                    case 65: keys.append(.up)
                    case 66: keys.append(.down)
                    case 67: keys.append(.next)
                    case 68: keys.append(.previous)
                    default: keys.append(.escape)
                    }
                }
                continue
            }
            if (128...191).contains(byte), !utf8.isEmpty {
                utf8.append(byte)
                if utf8.count == utf8Count {
                    if let s = String(bytes: utf8, encoding: .utf8) { keys.append(.text(s)) }
                    utf8 = []
                }
                continue
            }
            utf8 = []
            if byte >= 194 && byte <= 244 {
                utf8Count = byte < 224 ? 2 : byte < 240 ? 3 : 4; utf8 = [byte]; continue
            }
            switch byte {
            case 10, 13: keys.append(.enter)
            case 9: keys.append(.tab)
            case 8, 127: keys.append(.backspace)
            case 21: keys.append(.clear)
            case 32...126: keys.append(.text(String(UnicodeScalar(byte))))
            default: break
            }
        }
        return keys
    }
}
