import Foundation
import IOKit.usb
import PullockUSB
import Testing

private func stick(_ instance: UInt64, vendor: UInt16 = 0x1234) -> USBDevice {
    USBDevice(instance: instance, vendorID: vendor, productID: 0x4321, serial: .missing)
}

@Test func anyVendorWithoutSerialCanBeChosenAndOnlySelectedRemovalMatches() throws {
    let watcher = UUID()
    var selection = try ConnectionSelection(instance: 10, inventory: [stick(10), stick(20)], watcherID: watcher)
    let unrelated = selection.removed(20)
    #expect(!unrelated)
    #expect(!selection.expired)
    let selected = selection.removed(10)
    let duplicate = selection.removed(10)
    #expect(selected)
    #expect(!duplicate)
    #expect(selection.expired)
}

@Test func sameModelReconnectDoesNotReplaceSelectedConnection() throws {
    let watcher = UUID()
    var selection = try ConnectionSelection(instance: 10, inventory: [stick(10)], watcherID: watcher)
    #expect(throws: ConnectionSelectionError.missing) { try selection.reconcile([stick(20)], watcherID: watcher) }
    #expect(throws: ConnectionSelectionError.expired) { try selection.reconcile([stick(10)], watcherID: watcher) }
}

@Test func watcherAndLifecycleBoundariesPermanentlyExpireSelection() throws {
    let watcher = UUID()
    var selection = try ConnectionSelection(instance: 10, inventory: [stick(10)], watcherID: watcher)
    #expect(throws: ConnectionSelectionError.wrongWatcher) { try selection.reconcile([stick(10)], watcherID: UUID()) }
    #expect(selection.expired)
    selection = try ConnectionSelection(instance: 10, inventory: [stick(10)], watcherID: watcher)
    selection.invalidate()
    #expect(throws: ConnectionSelectionError.expired) { try selection.reconcile([stick(10)], watcherID: watcher) }
}

@Test func missingDuplicateAndChangedDescriptorsCannotSelectAnotherDevice() throws {
    let watcher = UUID()
    #expect(throws: ConnectionSelectionError.missing) { try ConnectionSelection(instance: 20, inventory: [stick(10)], watcherID: watcher) }
    #expect(throws: ConnectionSelectionError.invalidInventory) {
        try ConnectionSelection(instance: 10, inventory: [stick(10), stick(10)], watcherID: watcher)
    }
    var selection = try ConnectionSelection(instance: 10, inventory: [stick(10)], watcherID: watcher)
    #expect(throws: ConnectionSelectionError.missing) { try selection.reconcile([stick(10, vendor: 0x9999)], watcherID: watcher) }
}

@Test func displayNamesAreBoundedAndNotExportedInDiagnosticReports() throws {
    var properties: [String: Any] = [kUSBVendorID: NSNumber(value: 0x1234), kUSBProductID: NSNumber(value: 0x4321),
        "USB Product Name": " Personal device "]
    let device = try USBDescriptorParser.parse(instance: 1, properties: properties)
    #expect(device.displayName == "Personal device")
    #expect(!String(describing: device.reportFields(using: ReportRedactor())).contains("Personal device"))
    for name in ["bad\nname", "bad\u{202E}name", String(repeating: "x", count: 257)] {
        properties["USB Product Name"] = name
        #expect(try USBDescriptorParser.parse(instance: 1, properties: properties).displayName == nil)
    }
}
