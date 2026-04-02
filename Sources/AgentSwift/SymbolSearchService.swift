import Foundation
import SwiftParser
import SwiftSyntax

/// Searches Swift files for symbol definitions (functions, classes, structs, enums, protocols, typealiases, properties).
/// Uses SwiftSyntax for accurate AST-based search — no regex guessing.
public struct SymbolSearchService {

    /// A found symbol definition.
    public struct SymbolResult: Sendable {
        public let name: String
        public let kind: String        // "func", "class", "struct", "enum", "protocol", "typealias", "var", "let"
        public let filePath: String
        public let line: Int
        public let column: Int
        public let signature: String   // Full declaration signature (first line)
    }

    /// Search a directory for symbol definitions matching a query.
    /// - Parameters:
    ///   - query: Symbol name to search for (case-sensitive, partial match supported)
    ///   - directory: Directory to search recursively
    ///   - exactMatch: If true, only exact name matches. If false, contains match.
    /// - Returns: Array of matching symbol definitions
    public static func search(query: String, in directory: String, exactMatch: Bool = false) -> [SymbolResult] {
        let fm = FileManager.default
        var results: [SymbolResult] = []

        guard let enumerator = fm.enumerator(atPath: directory) else { return [] }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift"),
                  !relativePath.contains(".build/"),
                  !relativePath.contains("DerivedData"),
                  !relativePath.contains(".xcodeproj") else { continue }

            let fullPath = (directory as NSString).appendingPathComponent(relativePath)
            guard let source = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }

            let tree = Parser.parse(source: source)
            let visitor = SymbolFinder(query: query, exactMatch: exactMatch, filePath: fullPath, source: source)
            visitor.walk(tree)
            results.append(contentsOf: visitor.results)
        }

        return results.sorted { $0.filePath < $1.filePath || ($0.filePath == $1.filePath && $0.line < $1.line) }
    }

    /// List all top-level symbols in a single file.
    public static func symbols(in filePath: String) -> [SymbolResult] {
        guard let source = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }
        let tree = Parser.parse(source: source)
        let visitor = SymbolFinder(query: "", exactMatch: false, filePath: filePath, source: source)
        visitor.walk(tree)
        return visitor.results
    }
}

// MARK: - AST Visitor

private class SymbolFinder: SyntaxVisitor {
    let query: String
    let exactMatch: Bool
    let filePath: String
    let lines: [String]
    var results: [SymbolSearchService.SymbolResult] = []

    init(query: String, exactMatch: Bool, filePath: String, source: String) {
        self.query = query
        self.exactMatch = exactMatch
        self.filePath = filePath
        self.lines = source.components(separatedBy: "\n")
        super.init(viewMode: .sourceAccurate)
    }

    private func matches(_ name: String) -> Bool {
        if query.isEmpty { return true } // List all mode
        return exactMatch ? name == query : name.localizedCaseInsensitiveContains(query)
    }

    private func location(of node: some SyntaxProtocol) -> (line: Int, column: Int) {
        let loc = node.startLocation(converter: SourceLocationConverter(fileName: filePath, tree: node.root))
        return (loc.line, loc.column)
    }

    private func signature(at line: Int) -> String {
        guard line > 0, line <= lines.count else { return "" }
        return lines[line - 1].trimmingCharacters(in: .whitespaces)
    }

    private func addResult(name: String, kind: String, node: some SyntaxProtocol) {
        guard matches(name) else { return }
        let loc = location(of: node)
        results.append(SymbolSearchService.SymbolResult(
            name: name, kind: kind, filePath: filePath,
            line: loc.line, column: loc.column,
            signature: signature(at: loc.line)
        ))
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        addResult(name: node.name.text, kind: "func", node: node)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        addResult(name: node.name.text, kind: "class", node: node)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        addResult(name: node.name.text, kind: "struct", node: node)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        addResult(name: node.name.text, kind: "enum", node: node)
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        addResult(name: node.name.text, kind: "protocol", node: node)
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        addResult(name: node.name.text, kind: "typealias", node: node)
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let keyword = node.bindingSpecifier.text  // "var" or "let"
        for binding in node.bindings {
            if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                addResult(name: pattern.identifier.text, kind: keyword, node: node)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        addResult(name: "init", kind: "init", node: node)
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let typeName = node.extendedType.trimmedDescription
        addResult(name: typeName, kind: "extension", node: node)
        return .visitChildren
    }
}
