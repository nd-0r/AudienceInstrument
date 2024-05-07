import Foundation

var sendBuffer = Data()
var tmpBuffer = Data()

private func serializePing() {
    let timeStartedSending = getCurrentTimeInNs()

    BluetoothService.serializeMeasurementMessage(MeasurementMessage.with {
        $0.sequenceNumber = 1
        $0.initiatingPeerID = 3752
        $0.delayInNs = timeStartedSending
    }, toBuffer: &tmpBuffer)

    BluetoothService.serializeLength(
        BluetoothService.LengthPrefixType(tmpBuffer.count),
        toBuffer: &sendBuffer
    )

    sendBuffer.append(tmpBuffer)
}

serializePing()
let len = BluetoothService.deserializeLength(fromBuffer: sendBuffer.prefix(upTo: Data.Index(BluetoothService.lengthPrefixSize)))
let message = BluetoothService.deserializeMeasurementMessage(fromBuffer: sendBuffer[Data.Index(BluetoothService.lengthPrefixSize)..<Data.Index(BluetoothService.lengthPrefixSize + len)])

message.initiatingPeerID
