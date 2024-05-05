
print(MemoryLayout<Speak>.size)
let tmp = [UInt8](repeating: 0, count: 10)
let tmpData = Data(tmp)
let copyTmpData = tmpData.subdata(0..<Int(10))
copyTmpData

