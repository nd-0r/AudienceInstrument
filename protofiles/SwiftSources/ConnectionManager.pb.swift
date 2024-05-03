// DO NOT EDIT.
// swift-format-ignore-file
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: ConnectionManager.proto
//
// For information on using the generated types, please see the documentation:
//   https://github.com/apple/swift-protobuf/

import Foundation
import SwiftProtobuf

// If the compiler emits an error on this type, it is because this file
// was generated by a version of the `protoc` Swift plug-in that is
// incompatible with the version of SwiftProtobuf to which you are linking.
// Please ensure that you are building against the same version of the API
// that was used to generate this file.
fileprivate struct _GeneratedWithProtocGenSwiftVersion: SwiftProtobuf.ProtobufAPIVersionCheck {
  struct _2: SwiftProtobuf.ProtobufAPIVersion_2 {}
  typealias Version = _2
}

struct ForwardingEntry {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var linkID: Int64 = 0

  var cost: UInt64 = 0

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}
}

struct NetworkMessage {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var distanceVector: Dictionary<Int64,ForwardingEntry> = [:]

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}
}

struct MeasurementMessage {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var sequenceNumber: UInt32 = 0

  var initiatingPeerID: Int64 = 0

  var toPeer: Int64 = 0

  var delayInNs: UInt64 = 0

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}
}

struct MessengerMessage {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var from: Int64 = 0

  var to: Int64 = 0

  var message: String = String()

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}
}

struct Init {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var freq: UInt32 = 0

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}
}

struct InitAck {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}
}

struct Speak {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var from: Int64 = 0

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}
}

struct Spoke {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var from: Int64 = 0

  var delayInNs: UInt64 = 0

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}
}

struct Done {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var distanceInM: Float = 0

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}
}

struct DistanceProtocolWrapper {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var type: DistanceProtocolWrapper.OneOf_Type? = nil

  var init_p: Init {
    get {
      if case .init_p(let v)? = type {return v}
      return Init()
    }
    set {type = .init_p(newValue)}
  }

  var initAck: InitAck {
    get {
      if case .initAck(let v)? = type {return v}
      return InitAck()
    }
    set {type = .initAck(newValue)}
  }

  var speak: Speak {
    get {
      if case .speak(let v)? = type {return v}
      return Speak()
    }
    set {type = .speak(newValue)}
  }

  var spoke: Spoke {
    get {
      if case .spoke(let v)? = type {return v}
      return Spoke()
    }
    set {type = .spoke(newValue)}
  }

  var done: Done {
    get {
      if case .done(let v)? = type {return v}
      return Done()
    }
    set {type = .done(newValue)}
  }

  var unknownFields = SwiftProtobuf.UnknownStorage()

  enum OneOf_Type: Equatable {
    case init_p(Init)
    case initAck(InitAck)
    case speak(Speak)
    case spoke(Spoke)
    case done(Done)

  #if !swift(>=4.1)
    static func ==(lhs: DistanceProtocolWrapper.OneOf_Type, rhs: DistanceProtocolWrapper.OneOf_Type) -> Bool {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch (lhs, rhs) {
      case (.init_p, .init_p): return {
        guard case .init_p(let l) = lhs, case .init_p(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      case (.initAck, .initAck): return {
        guard case .initAck(let l) = lhs, case .initAck(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      case (.speak, .speak): return {
        guard case .speak(let l) = lhs, case .speak(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      case (.spoke, .spoke): return {
        guard case .spoke(let l) = lhs, case .spoke(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      case (.done, .done): return {
        guard case .done(let l) = lhs, case .done(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      default: return false
      }
    }
  #endif
  }

  init() {}
}

struct MessageWrapper {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var data: MessageWrapper.OneOf_Data? = nil

  var networkMessage: NetworkMessage {
    get {
      if case .networkMessage(let v)? = data {return v}
      return NetworkMessage()
    }
    set {data = .networkMessage(newValue)}
  }

  var neighborAppMessage: NeighborAppMessage {
    get {
      if case .neighborAppMessage(let v)? = data {return v}
      return NeighborAppMessage()
    }
    set {data = .neighborAppMessage(newValue)}
  }

  var meshAppMessage: MeshAppMessage {
    get {
      if case .meshAppMessage(let v)? = data {return v}
      return MeshAppMessage()
    }
    set {data = .meshAppMessage(newValue)}
  }

  var unknownFields = SwiftProtobuf.UnknownStorage()

  enum OneOf_Data: Equatable {
    case networkMessage(NetworkMessage)
    case neighborAppMessage(NeighborAppMessage)
    case meshAppMessage(MeshAppMessage)

  #if !swift(>=4.1)
    static func ==(lhs: MessageWrapper.OneOf_Data, rhs: MessageWrapper.OneOf_Data) -> Bool {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch (lhs, rhs) {
      case (.networkMessage, .networkMessage): return {
        guard case .networkMessage(let l) = lhs, case .networkMessage(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      case (.neighborAppMessage, .neighborAppMessage): return {
        guard case .neighborAppMessage(let l) = lhs, case .neighborAppMessage(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      case (.meshAppMessage, .meshAppMessage): return {
        guard case .meshAppMessage(let l) = lhs, case .meshAppMessage(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      default: return false
      }
    }
  #endif
  }

  init() {}
}

struct NeighborAppMessage {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var data: NeighborAppMessage.OneOf_Data? = nil

  /// more (or fewer:) later?
  var distanceProtocolMessage: DistanceProtocolWrapper {
    get {
      if case .distanceProtocolMessage(let v)? = data {return v}
      return DistanceProtocolWrapper()
    }
    set {data = .distanceProtocolMessage(newValue)}
  }

  var unknownFields = SwiftProtobuf.UnknownStorage()

  enum OneOf_Data: Equatable {
    /// more (or fewer:) later?
    case distanceProtocolMessage(DistanceProtocolWrapper)

  #if !swift(>=4.1)
    static func ==(lhs: NeighborAppMessage.OneOf_Data, rhs: NeighborAppMessage.OneOf_Data) -> Bool {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch (lhs, rhs) {
      case (.distanceProtocolMessage, .distanceProtocolMessage): return {
        guard case .distanceProtocolMessage(let l) = lhs, case .distanceProtocolMessage(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      }
    }
  #endif
  }

  init() {}
}

struct MeshAppMessage {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  var data: MeshAppMessage.OneOf_Data? = nil

  var messengerMessage: MessengerMessage {
    get {
      if case .messengerMessage(let v)? = data {return v}
      return MessengerMessage()
    }
    set {data = .messengerMessage(newValue)}
  }

  var unknownFields = SwiftProtobuf.UnknownStorage()

  enum OneOf_Data: Equatable {
    case messengerMessage(MessengerMessage)

  #if !swift(>=4.1)
    static func ==(lhs: MeshAppMessage.OneOf_Data, rhs: MeshAppMessage.OneOf_Data) -> Bool {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch (lhs, rhs) {
      case (.messengerMessage, .messengerMessage): return {
        guard case .messengerMessage(let l) = lhs, case .messengerMessage(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      }
    }
  #endif
  }

  init() {}
}

#if swift(>=5.5) && canImport(_Concurrency)
extension ForwardingEntry: @unchecked Sendable {}
extension NetworkMessage: @unchecked Sendable {}
extension MeasurementMessage: @unchecked Sendable {}
extension MessengerMessage: @unchecked Sendable {}
extension Init: @unchecked Sendable {}
extension InitAck: @unchecked Sendable {}
extension Speak: @unchecked Sendable {}
extension Spoke: @unchecked Sendable {}
extension Done: @unchecked Sendable {}
extension DistanceProtocolWrapper: @unchecked Sendable {}
extension DistanceProtocolWrapper.OneOf_Type: @unchecked Sendable {}
extension MessageWrapper: @unchecked Sendable {}
extension MessageWrapper.OneOf_Data: @unchecked Sendable {}
extension NeighborAppMessage: @unchecked Sendable {}
extension NeighborAppMessage.OneOf_Data: @unchecked Sendable {}
extension MeshAppMessage: @unchecked Sendable {}
extension MeshAppMessage.OneOf_Data: @unchecked Sendable {}
#endif  // swift(>=5.5) && canImport(_Concurrency)

// MARK: - Code below here is support for the SwiftProtobuf runtime.

extension ForwardingEntry: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "ForwardingEntry"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "linkID"),
    2: .same(proto: "cost"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularInt64Field(value: &self.linkID) }()
      case 2: try { try decoder.decodeSingularUInt64Field(value: &self.cost) }()
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.linkID != 0 {
      try visitor.visitSingularInt64Field(value: self.linkID, fieldNumber: 1)
    }
    if self.cost != 0 {
      try visitor.visitSingularUInt64Field(value: self.cost, fieldNumber: 2)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: ForwardingEntry, rhs: ForwardingEntry) -> Bool {
    if lhs.linkID != rhs.linkID {return false}
    if lhs.cost != rhs.cost {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension NetworkMessage: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "NetworkMessage"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "distanceVector"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeMapField(fieldType: SwiftProtobuf._ProtobufMessageMap<SwiftProtobuf.ProtobufInt64,ForwardingEntry>.self, value: &self.distanceVector) }()
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.distanceVector.isEmpty {
      try visitor.visitMapField(fieldType: SwiftProtobuf._ProtobufMessageMap<SwiftProtobuf.ProtobufInt64,ForwardingEntry>.self, value: self.distanceVector, fieldNumber: 1)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: NetworkMessage, rhs: NetworkMessage) -> Bool {
    if lhs.distanceVector != rhs.distanceVector {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension MeasurementMessage: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "MeasurementMessage"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "sequenceNumber"),
    2: .same(proto: "initiatingPeerId"),
    3: .same(proto: "toPeer"),
    4: .same(proto: "delayInNS"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularUInt32Field(value: &self.sequenceNumber) }()
      case 2: try { try decoder.decodeSingularInt64Field(value: &self.initiatingPeerID) }()
      case 3: try { try decoder.decodeSingularInt64Field(value: &self.toPeer) }()
      case 4: try { try decoder.decodeSingularUInt64Field(value: &self.delayInNs) }()
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.sequenceNumber != 0 {
      try visitor.visitSingularUInt32Field(value: self.sequenceNumber, fieldNumber: 1)
    }
    if self.initiatingPeerID != 0 {
      try visitor.visitSingularInt64Field(value: self.initiatingPeerID, fieldNumber: 2)
    }
    if self.toPeer != 0 {
      try visitor.visitSingularInt64Field(value: self.toPeer, fieldNumber: 3)
    }
    if self.delayInNs != 0 {
      try visitor.visitSingularUInt64Field(value: self.delayInNs, fieldNumber: 4)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: MeasurementMessage, rhs: MeasurementMessage) -> Bool {
    if lhs.sequenceNumber != rhs.sequenceNumber {return false}
    if lhs.initiatingPeerID != rhs.initiatingPeerID {return false}
    if lhs.toPeer != rhs.toPeer {return false}
    if lhs.delayInNs != rhs.delayInNs {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension MessengerMessage: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "MessengerMessage"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "from"),
    2: .same(proto: "to"),
    3: .same(proto: "message"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularInt64Field(value: &self.from) }()
      case 2: try { try decoder.decodeSingularInt64Field(value: &self.to) }()
      case 3: try { try decoder.decodeSingularStringField(value: &self.message) }()
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.from != 0 {
      try visitor.visitSingularInt64Field(value: self.from, fieldNumber: 1)
    }
    if self.to != 0 {
      try visitor.visitSingularInt64Field(value: self.to, fieldNumber: 2)
    }
    if !self.message.isEmpty {
      try visitor.visitSingularStringField(value: self.message, fieldNumber: 3)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: MessengerMessage, rhs: MessengerMessage) -> Bool {
    if lhs.from != rhs.from {return false}
    if lhs.to != rhs.to {return false}
    if lhs.message != rhs.message {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension Init: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "Init"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "freq"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularUInt32Field(value: &self.freq) }()
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.freq != 0 {
      try visitor.visitSingularUInt32Field(value: self.freq, fieldNumber: 1)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: Init, rhs: Init) -> Bool {
    if lhs.freq != rhs.freq {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension InitAck: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "InitAck"
  static let _protobuf_nameMap = SwiftProtobuf._NameMap()

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let _ = try decoder.nextFieldNumber() {
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: InitAck, rhs: InitAck) -> Bool {
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension Speak: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "Speak"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "from"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularInt64Field(value: &self.from) }()
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.from != 0 {
      try visitor.visitSingularInt64Field(value: self.from, fieldNumber: 1)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: Speak, rhs: Speak) -> Bool {
    if lhs.from != rhs.from {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension Spoke: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "Spoke"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "from"),
    2: .same(proto: "delayInNS"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularInt64Field(value: &self.from) }()
      case 2: try { try decoder.decodeSingularUInt64Field(value: &self.delayInNs) }()
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.from != 0 {
      try visitor.visitSingularInt64Field(value: self.from, fieldNumber: 1)
    }
    if self.delayInNs != 0 {
      try visitor.visitSingularUInt64Field(value: self.delayInNs, fieldNumber: 2)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: Spoke, rhs: Spoke) -> Bool {
    if lhs.from != rhs.from {return false}
    if lhs.delayInNs != rhs.delayInNs {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension Done: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "Done"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "distanceInM"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularFloatField(value: &self.distanceInM) }()
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.distanceInM != 0 {
      try visitor.visitSingularFloatField(value: self.distanceInM, fieldNumber: 1)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: Done, rhs: Done) -> Bool {
    if lhs.distanceInM != rhs.distanceInM {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension DistanceProtocolWrapper: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "DistanceProtocolWrapper"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    2: .same(proto: "init"),
    3: .same(proto: "initAck"),
    4: .same(proto: "speak"),
    5: .same(proto: "spoke"),
    6: .same(proto: "done"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 2: try {
        var v: Init?
        var hadOneofValue = false
        if let current = self.type {
          hadOneofValue = true
          if case .init_p(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.type = .init_p(v)
        }
      }()
      case 3: try {
        var v: InitAck?
        var hadOneofValue = false
        if let current = self.type {
          hadOneofValue = true
          if case .initAck(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.type = .initAck(v)
        }
      }()
      case 4: try {
        var v: Speak?
        var hadOneofValue = false
        if let current = self.type {
          hadOneofValue = true
          if case .speak(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.type = .speak(v)
        }
      }()
      case 5: try {
        var v: Spoke?
        var hadOneofValue = false
        if let current = self.type {
          hadOneofValue = true
          if case .spoke(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.type = .spoke(v)
        }
      }()
      case 6: try {
        var v: Done?
        var hadOneofValue = false
        if let current = self.type {
          hadOneofValue = true
          if case .done(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.type = .done(v)
        }
      }()
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    // The use of inline closures is to circumvent an issue where the compiler
    // allocates stack space for every if/case branch local when no optimizations
    // are enabled. https://github.com/apple/swift-protobuf/issues/1034 and
    // https://github.com/apple/swift-protobuf/issues/1182
    switch self.type {
    case .init_p?: try {
      guard case .init_p(let v)? = self.type else { preconditionFailure() }
      try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
    }()
    case .initAck?: try {
      guard case .initAck(let v)? = self.type else { preconditionFailure() }
      try visitor.visitSingularMessageField(value: v, fieldNumber: 3)
    }()
    case .speak?: try {
      guard case .speak(let v)? = self.type else { preconditionFailure() }
      try visitor.visitSingularMessageField(value: v, fieldNumber: 4)
    }()
    case .spoke?: try {
      guard case .spoke(let v)? = self.type else { preconditionFailure() }
      try visitor.visitSingularMessageField(value: v, fieldNumber: 5)
    }()
    case .done?: try {
      guard case .done(let v)? = self.type else { preconditionFailure() }
      try visitor.visitSingularMessageField(value: v, fieldNumber: 6)
    }()
    case nil: break
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: DistanceProtocolWrapper, rhs: DistanceProtocolWrapper) -> Bool {
    if lhs.type != rhs.type {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension MessageWrapper: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "MessageWrapper"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    2: .same(proto: "networkMessage"),
    3: .same(proto: "neighborAppMessage"),
    4: .same(proto: "meshAppMessage"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 2: try {
        var v: NetworkMessage?
        var hadOneofValue = false
        if let current = self.data {
          hadOneofValue = true
          if case .networkMessage(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.data = .networkMessage(v)
        }
      }()
      case 3: try {
        var v: NeighborAppMessage?
        var hadOneofValue = false
        if let current = self.data {
          hadOneofValue = true
          if case .neighborAppMessage(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.data = .neighborAppMessage(v)
        }
      }()
      case 4: try {
        var v: MeshAppMessage?
        var hadOneofValue = false
        if let current = self.data {
          hadOneofValue = true
          if case .meshAppMessage(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.data = .meshAppMessage(v)
        }
      }()
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    // The use of inline closures is to circumvent an issue where the compiler
    // allocates stack space for every if/case branch local when no optimizations
    // are enabled. https://github.com/apple/swift-protobuf/issues/1034 and
    // https://github.com/apple/swift-protobuf/issues/1182
    switch self.data {
    case .networkMessage?: try {
      guard case .networkMessage(let v)? = self.data else { preconditionFailure() }
      try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
    }()
    case .neighborAppMessage?: try {
      guard case .neighborAppMessage(let v)? = self.data else { preconditionFailure() }
      try visitor.visitSingularMessageField(value: v, fieldNumber: 3)
    }()
    case .meshAppMessage?: try {
      guard case .meshAppMessage(let v)? = self.data else { preconditionFailure() }
      try visitor.visitSingularMessageField(value: v, fieldNumber: 4)
    }()
    case nil: break
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: MessageWrapper, rhs: MessageWrapper) -> Bool {
    if lhs.data != rhs.data {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension NeighborAppMessage: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "NeighborAppMessage"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    3: .same(proto: "distanceProtocolMessage"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 3: try {
        var v: DistanceProtocolWrapper?
        var hadOneofValue = false
        if let current = self.data {
          hadOneofValue = true
          if case .distanceProtocolMessage(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.data = .distanceProtocolMessage(v)
        }
      }()
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    // The use of inline closures is to circumvent an issue where the compiler
    // allocates stack space for every if/case branch local when no optimizations
    // are enabled. https://github.com/apple/swift-protobuf/issues/1034 and
    // https://github.com/apple/swift-protobuf/issues/1182
    try { if case .distanceProtocolMessage(let v)? = self.data {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 3)
    } }()
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: NeighborAppMessage, rhs: NeighborAppMessage) -> Bool {
    if lhs.data != rhs.data {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension MeshAppMessage: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "MeshAppMessage"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "messengerMessage"),
  ]

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try {
        var v: MessengerMessage?
        var hadOneofValue = false
        if let current = self.data {
          hadOneofValue = true
          if case .messengerMessage(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.data = .messengerMessage(v)
        }
      }()
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    // The use of inline closures is to circumvent an issue where the compiler
    // allocates stack space for every if/case branch local when no optimizations
    // are enabled. https://github.com/apple/swift-protobuf/issues/1034 and
    // https://github.com/apple/swift-protobuf/issues/1182
    try { if case .messengerMessage(let v)? = self.data {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
    } }()
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: MeshAppMessage, rhs: MeshAppMessage) -> Bool {
    if lhs.data != rhs.data {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}
