import Foundation

var d = Data(repeating: 0, count: 11)
d.count
d.reserveCapacity(64)
d.count
var e = Data(repeating: 1, count: 64)
d = e.subdata(in: 0..<e.count)

