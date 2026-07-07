import Foundation

/// Maps an input event to a mutation of the browser model, returning a side
/// effect the imperative driver must perform (analysis and quitting live
/// outside the pure layer). Pure and total, so the whole key-handling contract
/// is unit-testable without a terminal.
public enum BrowserReducer {

    public enum Effect: Equatable, Sendable {
        case none
        case quit
        /// The selection changed (or a re-scan was requested); the driver should
        /// analyze the selected app if it isn't cached.
        case analyzeSelected
    }

    public static func apply(_ event: InputEvent, to m: inout AppBrowserModel, pageStep: Int) -> Effect {
        switch event {
        case .up:        m.move(-1);                return .analyzeSelected
        case .down:      m.move(1);                 return .analyzeSelected
        case .pageUp:    m.move(-max(1, pageStep)); return .analyzeSelected
        case .pageDown:  m.move(max(1, pageStep));  return .analyzeSelected
        case .home:      m.moveToStart();           return .analyzeSelected
        case .end:       m.moveToEnd();             return .analyzeSelected
        case .left, .right:                         return .none
        case .tab:       m.cycleSort();             return .analyzeSelected
        case .enter:     m.reanalyzeSelected();     return .analyzeSelected
        case .backspace: m.deleteFilterChar();      return .analyzeSelected
        case .escape:
            if m.filterIsEmpty { return .quit }
            m.clearFilter();                        return .analyzeSelected
        case .ctrlC:                                return .quit
        case .char(let c): m.appendFilter(c);       return .analyzeSelected
        }
    }
}
