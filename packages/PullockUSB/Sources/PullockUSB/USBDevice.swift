import Foundation
import IOKit.usb
import PullockCore

public struct USBDevice: Equatable, Sendable {
    public let instance: UInt64
    public let vendorID: UInt16
    public let productID: UInt16
    public let serial: SerialEvidence
    public let serialDescriptorIndex: UInt8?

    public init(instance: UInt64, vendorID: UInt16, productID: UInt16,
                serial: SerialEvidence, serialDescriptorIndex: UInt8? = nil) {
        self.instance = instance; self.vendorID = vendorID; self.productID = productID
        self.serial = serial; self.serialDescriptorIndex = serialDescriptorIndex
    }

    public var observation: DeviceObservation {
        let value: String?
        if case let .presentUnqualified(serial, _) = serial { value = serial } else { value = nil }
        return DeviceObservation(instance: instance, vendorID: vendorID, productID: productID, serial: value)
    }

    public func reportFields(using redactor: ReportRedactor) -> [String: String] {
        var fields = redactor.fields(for: serial)
        fields["instance_token"] = redactor.token(domain: "instance", value: String(instance))
        fields["vendor_id"] = String(format: "0x%04x", vendorID)
        fields["product_id"] = String(format: "0x%04x", productID)
        fields["transport"] = "USB"
        if let serialDescriptorIndex { fields["serial_descriptor_index"] = String(serialDescriptorIndex) }
        return fields
    }
}

public enum DescriptorError: String, Error, Sendable { case invalidInstance, invalidIdentifiers, invalidSerialIndex }

public enum USBDescriptorParser {
    public static let serialKeys = [kUSBHostDevicePropertySerialNumberString, "USB Serial Number"]
    public static var propertyKeys: [String] {
        [kUSBVendorID, kUSBProductID, kUSBHostDevicePropertySerialNumberStringIndex] + serialKeys
    }

    public static func parse(instance: UInt64, properties: [String: Any]) throws -> USBDevice {
        guard instance != 0 else { throw DescriptorError.invalidInstance }
        guard let vendor = usbIdentifier(properties[kUSBVendorID]), vendor != 0,
              let product = usbIdentifier(properties[kUSBProductID]), product != 0 else {
            throw DescriptorError.invalidIdentifiers
        }
        var index: UInt8?
        if let raw = properties[kUSBHostDevicePropertySerialNumberStringIndex] {
            guard let value = usbIdentifier(raw), let byte = UInt8(exactly: value) else {
                throw DescriptorError.invalidSerialIndex
            }
            index = byte
        }
        return USBDevice(instance: instance, vendorID: vendor, productID: product,
            serial: SerialEvidence.read(properties, keys: serialKeys), serialDescriptorIndex: index)
    }
}
