import Foundation
import Shared

public final class SourceGraph {
    private(set) public var allDeclarations: Set<Declaration> = []

    private(set) var rootDeclarations: Set<Declaration> = []
    private(set) var rootReferences: Set<Reference> = []
    private(set) var allReferences: Set<Reference> = []
    private(set) var reachableDeclarations: Set<Declaration> = []
    private(set) var redundantDeclarations: Set<Declaration> = []
    private(set) var retainedDeclarations: Set<Declaration> = []

    private var ignoredDeclarations: Set<Declaration> = []
    private var allReferencesByUsr: [String: Set<Reference>] = [:]
    private var allDeclarationsByKind: [Declaration.Kind: Set<Declaration>] = [:]
    private var allExplicitDeclarationsByUsr: [String: Declaration] = [:]
    private var reachableDeclarationCounts: [Declaration: Int] = [:]

    private let mutationQueue: DispatchQueue

    var xibReferences: [XibReference] = []
    var infoPlistReferences: [InfoPlistReference] = []

    public var resultDeclarations: Set<Declaration> {
        unreachableDeclarations.union(redundantDeclarations).subtracting(ignoredDeclarations)
    }

    public var unreachableDeclarations: Set<Declaration> {
        return allDeclarations.subtracting(reachableDeclarations)
    }

    public init() {
        mutationQueue = DispatchQueue(label: "SourceGraph.mutationQueue")
    }

    func identifyRootDeclarations() {
        rootDeclarations = allDeclarations.filter { $0.parent == nil }
    }

    func identifyRootReferences() {
        rootReferences = allReferences.filter { $0.parent == nil }
    }

    func declarations(ofKind kind: Declaration.Kind) -> Set<Declaration> {
        return allDeclarationsByKind[kind] ?? []
    }

    func declarations(ofKinds kinds: [Declaration.Kind]) -> Set<Declaration> {
        return Set(kinds.compactMap { allDeclarationsByKind[$0] }.joined())
    }

    func explicitDeclaration(withUsr usr: String) -> Declaration? {
        return allExplicitDeclarationsByUsr[usr]
    }

    func references(to decl: Declaration) -> Set<Reference> {
        Set(decl.usrs.flatMap { allReferencesByUsr[$0, default: []] })
    }

    func hasReferences(to decl: Declaration) -> Bool {
        decl.usrs.contains { !allReferencesByUsr[$0, default: []].isEmpty }
    }

    func markRedundant(_ declaration: Declaration) {
        mutationQueue.sync {
            _ = redundantDeclarations.insert(declaration)
        }
    }

    func markIgnored(_ declaration: Declaration) {
        mutationQueue.sync {
            _ = ignoredDeclarations.insert(declaration)
        }
    }

    func isIgnored(_ declaration: Declaration) -> Bool {
        mutationQueue.sync {
            ignoredDeclarations.contains(declaration)
        }
    }

    func markRetained(_ declaration: Declaration) {
        mutationQueue.sync {
            _ = retainedDeclarations.insert(declaration)
        }
    }

    func unmarkRetained(_ declaration: Declaration) {
        mutationQueue.sync {
            _ = retainedDeclarations.remove(declaration)
        }
    }

    func isRetained(_ declaration: Declaration) -> Bool {
        mutationQueue.sync {
            retainedDeclarations.contains(declaration)
        }
    }

    func add(_ declaration: Declaration) {
        mutationQueue.sync {
            allDeclarations.insert(declaration)
            allDeclarationsByKind[declaration.kind, default: []].insert(declaration)

            if !declaration.isImplicit {
                declaration.usrs.forEach { allExplicitDeclarationsByUsr[$0] = declaration }
            }
        }
    }

    func remove(_ declaration: Declaration) {
        mutationQueue.sync {
            declaration.parent?.declarations.remove(declaration)
            allDeclarations.remove(declaration)
            allDeclarationsByKind[declaration.kind]?.remove(declaration)
            rootDeclarations.remove(declaration)
            reachableDeclarations.remove(declaration)
            declaration.usrs.forEach { allExplicitDeclarationsByUsr.removeValue(forKey: $0) }
        }
    }

    func add(_ reference: Reference) {
        mutationQueue.sync {
            _ = allReferences.insert(reference)

            if allReferencesByUsr[reference.usr] == nil {
                allReferencesByUsr[reference.usr] = []
            }

            allReferencesByUsr[reference.usr]?.insert(reference)
        }
    }

    func add(_ reference: Reference, from declaration: Declaration) {
        mutationQueue.sync {
            if reference.isRelated {
                _ = declaration.related.insert(reference)
            } else {
                _ = declaration.references.insert(reference)
            }
        }

        add(reference)
    }

    func remove(_ reference: Reference) {
        mutationQueue.sync {
            _ = allReferences.remove(reference)
            allReferences.subtract(reference.descendentReferences)
            allReferencesByUsr[reference.usr]?.remove(reference)
        }

        if let parent = reference.parent as? Declaration {
            mutationQueue.sync {
                parent.references.remove(reference)
                parent.related.remove(reference)
            }
        } else if let parent = reference.parent as? Reference {
            _ = mutationQueue.sync {
                parent.references.remove(reference)
            }
        }
    }

    @discardableResult
    func incrementReachable(_ declaration: Declaration) -> Int {
        mutationQueue.sync {
            reachableDeclarations.insert(declaration)
            reachableDeclarationCounts[declaration, default: 0] += 1
            return reachableDeclarationCounts[declaration, default: 0]
        }
    }

    @discardableResult
    func decrementReachable(_ declaration: Declaration) -> Int {
        mutationQueue.sync {
            reachableDeclarationCounts[declaration, default: 0] -= 1
            let count = reachableDeclarationCounts[declaration, default: 0]

            if count == 0 {
                reachableDeclarationCounts.removeValue(forKey: declaration)
                reachableDeclarations.remove(declaration)
            }

            return count
        }
    }

    func accept(visitor: SourceGraphVisitor.Type) throws {
        try visitor.make(graph: self).visit()
    }

    func superclassReferences(of decl: Declaration) -> [Reference] {
        var references: [Reference] = []

        for reference in decl.immediateSuperclassReferences {
            references.append(reference)

            if let superclassDecl = explicitDeclaration(withUsr: reference.usr) {
                references = superclassReferences(of: superclassDecl) + references
            }
        }

        return references
    }

    func superclasses(of decl: Declaration) -> [Declaration] {
        return superclassReferences(of: decl).compactMap {
            explicitDeclaration(withUsr: $0.usr)
        }
    }

    func immediateSubclasses(of decl: Declaration) -> [Declaration] {
        let allClasses = allDeclarationsByKind[.class] ?? []
        return allClasses
            .filter {
                $0.related.contains(where: { ref in
                    ref.kind == .class && decl.usrs.contains(ref.usr)
                })
            }.filter { $0 != decl }
    }

    func subclasses(of decl: Declaration) -> [Declaration] {
        let immediate = immediateSubclasses(of: decl)
        return immediate + immediate.flatMap { subclasses(of: $0) }
    }

    func mutating(_ block: () -> Void) {
        mutationQueue.sync(execute: block)
    }

    func extendedDeclaration(forExtension extensionDeclaration: Declaration) throws -> Declaration? {
        guard let extendedKind = extensionDeclaration.kind.extendedKind?.referenceEquivalent else {
            throw PeripheryError.sourceGraphIntegrityError(message: "Unknown extended reference kind for extension '\(extensionDeclaration.kind.rawValue)'")
        }

        guard let extendedReference = extensionDeclaration.references.first(where: { $0.kind == extendedKind && $0.name == extensionDeclaration.name }) else { return nil }

        if let extendedDeclaration = allExplicitDeclarationsByUsr[extendedReference.usr] {
            return extendedDeclaration
        }

        return nil
    }
}
