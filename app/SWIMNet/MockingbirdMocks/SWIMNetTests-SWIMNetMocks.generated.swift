//
//  SWIMNetTests-SWIMNetMocks.generated.swift
//  SWIMNet
//
//  Generated by Mockingbird v0.20.0.
//  DO NOT EDIT
//

@testable import Mockingbird
@testable import SWIMNet
import Foundation
import Swift

private let mkbGenericStaticMockContext = Mockingbird.GenericStaticMockContext()

// MARK: - Mocked DidUpdateCallbackProtocol
public final class DidUpdateCallbackProtocolMock: SWIMNet.DidUpdateCallbackProtocol, Mockingbird.Mock {
  typealias MockingbirdSupertype = SWIMNet.DidUpdateCallbackProtocol
  public static let mockingbirdContext = Mockingbird.Context()
  public let mockingbirdContext = Mockingbird.Context(["generator_version": "0.20.0", "module_name": "SWIMNet"])

  fileprivate init(sourceLocation: Mockingbird.SourceLocation) {
    self.mockingbirdContext.sourceLocation = sourceLocation
    DidUpdateCallbackProtocolMock.mockingbirdContext.sourceLocation = sourceLocation
  }

  // MARK: Mocked `didUpdate`()
  public func `didUpdate`() -> Void {
    return self.mockingbirdContext.mocking.didInvoke(Mockingbird.SwiftInvocation(selectorName: "`didUpdate`() -> Void", selectorType: Mockingbird.SelectorType.method, arguments: [], returnType: Swift.ObjectIdentifier((Void).self))) {
      self.mockingbirdContext.recordInvocation($0)
      let mkbImpl = self.mockingbirdContext.stubbing.implementation(for: $0)
      if let mkbImpl = mkbImpl as? () -> Void { return mkbImpl() }
      for mkbTargetBox in self.mockingbirdContext.proxy.targets(for: $0) {
        switch mkbTargetBox.target {
        case .super:
          break
        case .object(let mkbObject):
          guard var mkbObject = mkbObject as? MockingbirdSupertype else { break }
          let mkbValue: Void = mkbObject.`didUpdate`()
          self.mockingbirdContext.proxy.updateTarget(&mkbObject, in: mkbTargetBox)
          return mkbValue
        }
      }
      if let mkbValue = self.mockingbirdContext.stubbing.defaultValueProvider.value.provideValue(for: (Void).self) { return mkbValue }
      self.mockingbirdContext.stubbing.failTest(for: $0, at: self.mockingbirdContext.sourceLocation)
    }
  }

  public func `didUpdate`() -> Mockingbird.Mockable<Mockingbird.FunctionDeclaration, () -> Void, Void> {
    return Mockingbird.Mockable<Mockingbird.FunctionDeclaration, () -> Void, Void>(context: self.mockingbirdContext, invocation: Mockingbird.SwiftInvocation(selectorName: "`didUpdate`() -> Void", selectorType: Mockingbird.SelectorType.method, arguments: [], returnType: Swift.ObjectIdentifier((Void).self)))
  }
}

/// Returns a concrete mock of `DidUpdateCallbackProtocol`.
public func mock(_ type: SWIMNet.DidUpdateCallbackProtocol.Protocol, file: StaticString = #file, line: UInt = #line) -> DidUpdateCallbackProtocolMock {
  return DidUpdateCallbackProtocolMock(sourceLocation: Mockingbird.SourceLocation(file, line))
}

// MARK: - Mocked SendDelegate
public final class SendDelegateMock: SWIMNet.SendDelegate, Mockingbird.Mock {
  typealias MockingbirdSupertype = SWIMNet.SendDelegate
  public static let mockingbirdContext = Mockingbird.Context()
  public let mockingbirdContext = Mockingbird.Context(["generator_version": "0.20.0", "module_name": "SWIMNet"])

  fileprivate init(sourceLocation: Mockingbird.SourceLocation) {
    self.mockingbirdContext.sourceLocation = sourceLocation
    SendDelegateMock.mockingbirdContext.sourceLocation = sourceLocation
  }

  // MARK: Mocked `send`(`from`: any PeerIdT, sendTo `peerId`: any PeerIdT, withDVDict `dv`: any Sendable)
  public func `send`(`from`: any PeerIdT, sendTo `peerId`: any PeerIdT, withDVDict `dv`: any Sendable) async throws -> Void {
    return try await self.mockingbirdContext.mocking.didInvoke(Mockingbird.SwiftInvocation(selectorName: "`send`(`from`: any PeerIdT, sendTo `peerId`: any PeerIdT, withDVDict `dv`: any Sendable) async throws -> Void", selectorType: Mockingbird.SelectorType.method, arguments: [Mockingbird.ArgumentMatcher(`from`), Mockingbird.ArgumentMatcher(`peerId`), Mockingbird.ArgumentMatcher(`dv`)], returnType: Swift.ObjectIdentifier((Void).self))) {
      self.mockingbirdContext.recordInvocation($0)
      let mkbImpl = self.mockingbirdContext.stubbing.implementation(for: $0)
      if let mkbImpl = mkbImpl as? (any PeerIdT, any PeerIdT, any Sendable) async throws -> Void { return try await mkbImpl(`from`, `peerId`, `dv`) }
      if let mkbImpl = mkbImpl as? () async throws -> Void { return try await mkbImpl() }
      for mkbTargetBox in self.mockingbirdContext.proxy.targets(for: $0) {
        switch mkbTargetBox.target {
        case .super:
          break
        case .object(let mkbObject):
          guard var mkbObject = mkbObject as? MockingbirdSupertype else { break }
          let mkbValue: Void = try await mkbObject.`send`(from: `from`, sendTo: `peerId`, withDVDict: `dv`)
          self.mockingbirdContext.proxy.updateTarget(&mkbObject, in: mkbTargetBox)
          return mkbValue
        }
      }
      if let mkbValue = self.mockingbirdContext.stubbing.defaultValueProvider.value.provideValue(for: (Void).self) { return mkbValue }
      self.mockingbirdContext.stubbing.failTest(for: $0, at: self.mockingbirdContext.sourceLocation)
    }
  }

  public func `send`(`from`: @autoclosure () -> any PeerIdT, sendTo `peerId`: @autoclosure () -> any PeerIdT, withDVDict `dv`: @autoclosure () -> any Sendable) async -> Mockingbird.Mockable<Mockingbird.ThrowingAsyncFunctionDeclaration, (any PeerIdT, any PeerIdT, any Sendable) async throws -> Void, Void> {
    return Mockingbird.Mockable<Mockingbird.ThrowingAsyncFunctionDeclaration, (any PeerIdT, any PeerIdT, any Sendable) async throws -> Void, Void>(context: self.mockingbirdContext, invocation: Mockingbird.SwiftInvocation(selectorName: "`send`(`from`: any PeerIdT, sendTo `peerId`: any PeerIdT, withDVDict `dv`: any Sendable) async throws -> Void", selectorType: Mockingbird.SelectorType.method, arguments: [Mockingbird.resolve(`from`), Mockingbird.resolve(`peerId`), Mockingbird.resolve(`dv`)], returnType: Swift.ObjectIdentifier((Void).self)))
  }
}

/// Returns a concrete mock of `SendDelegate`.
public func mock(_ type: SWIMNet.SendDelegate.Protocol, file: StaticString = #file, line: UInt = #line) -> SendDelegateMock {
  return SendDelegateMock(sourceLocation: Mockingbird.SourceLocation(file, line))
}
