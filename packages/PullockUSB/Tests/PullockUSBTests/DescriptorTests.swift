import Foundation
import IOKit.usb
import PullockUSB
import Testing

private func properties() -> [String: Any] {
    [kUSBVendorID: NSNumber(value: 0x1050), kUSBProductID: NSNumber(value: 0x0407),
     kUSBHostDevicePropertySerialNumberStringIndex: NSNumber(value: 0)]
}

@Test func actualMissingSerialShapeStaysUnenrollable() throws {
    let device = try USBDescriptorParser.parse(instance: 1, properties: properties())
    #expect(device.serial == .missing)
    #expect(device.serialDescriptorIndex == 0)
    #expect(device.observation.serial == nil)
    #expect(EnrollmentReview.blocker(candidate: 1, inventory: [device], qualifiedProfiles: []) == .missingSerial)
}

@Test func typedBoundsRejectMalformedUSBDescriptors() {
    #expect(throws: DescriptorError.invalidInstance) { try USBDescriptorParser.parse(instance: 0, properties: properties()) }
    for invalid: Any in [true, "4176", 4176.0, -1, 0, 65536] {
        var input = properties(); input[kUSBVendorID] = invalid
        #expect(throws: DescriptorError.invalidIdentifiers) { try USBDescriptorParser.parse(instance: 1, properties: input) }
    }
    for invalid: Any in [true, "1", 1.0, -1, 256] {
        var input = properties(); input[kUSBHostDevicePropertySerialNumberStringIndex] = invalid
        #expect(throws: DescriptorError.invalidSerialIndex) { try USBDescriptorParser.parse(instance: 1, properties: input) }
    }
}

@Test func serialAliasConflictIsPreservedAndRedacted() throws {
    var input = properties()
    input[USBDescriptorParser.serialKeys[0]] = "TEST-FIRST"
    input[USBDescriptorParser.serialKeys[1]] = "TEST-SECOND"
    let device = try USBDescriptorParser.parse(instance: 42, properties: input)
    #expect(device.serial == .conflicting)
    let fields = device.reportFields(using: ReportRedactor())
    #expect(fields["serial_status"] == "conflicting")
    #expect(fields["serial_token"] == nil)
    #expect(!String(describing: fields).contains("TEST-FIRST"))
    #expect(fields["instance_token"] != "42")
}

@Test func descriptorProjectionPreservesExactSerialAndReportIsRunScoped() throws {
    var input = properties()
    input[USBDescriptorParser.serialKeys[0]] = " TEST-AbC "
    let device = try USBDescriptorParser.parse(instance: 42, properties: input)
    #expect(device.observation.serial == " TEST-AbC ")
    let first = device.reportFields(using: ReportRedactor())
    let second = device.reportFields(using: ReportRedactor())
    #expect(first["serial_token"] != second["serial_token"])
    #expect(first["instance_token"] != second["instance_token"])
    #expect(!String(describing: first).contains("TEST-AbC"))
}
