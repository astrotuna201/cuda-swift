//
//  Buffer.swift
//  Warp
//
//  Created by Richard Wei on 10/26/16.
//
//

import CUDARuntime

protocol DeviceArrayBufferProtocol : DeviceBufferProtocol, MutableCollection, RandomAccessCollection {
    typealias Index = Int
    typealias Indices = CountableRange<Int>

    var baseAddress: UnsafeMutableDevicePointer<Element> { get }
    var capacity: Int { get }

    init(capacity: Int)
    init(device: Device, capacity: Int)
    init(viewing other: Self, in range: Range<Int>)

    var startAddress: UnsafeMutableDevicePointer<Element> { get }
    var endAddress: UnsafeMutableDevicePointer<Element> { get }

    subscript(i: Int) -> DeviceValueBuffer<Element> { get set }
}

extension DeviceArrayBufferProtocol where Index == Int {
    init() {
        self.init(capacity: 0)
    }
    
    var startAddress: UnsafeMutableDevicePointer<Element> {
        return baseAddress.advanced(by: startIndex)
    }

    var endAddress: UnsafeMutableDevicePointer<Element> {
        return baseAddress.advanced(by: endIndex)
    }

    var count: Int {
        return endIndex - startIndex
    }

    func index(after i: Int) -> Int {
        return i + 1
    }

    func index(before i: Int) -> Int {
        return i - 1
    }
}

class LifetimeKeeper<Kept> {
    let retainee: Kept
    init(keeping retainee: Kept) {
        self.retainee = retainee
    }
}

final class DeviceArrayBuffer<Element> : DeviceArrayBufferProtocol {

    typealias SubSequence = DeviceArrayBuffer<Element>

    let device: Device
    var baseAddress: UnsafeMutableDevicePointer<Element>
    let capacity: Int
    let startIndex: Int, endIndex: Int
    var owner: AnyObject?
    private var lifetimeKeeper: LifetimeKeeper<[Element]>?
    private var valueRetainees: [DeviceValueBuffer<Element>?]


    init(capacity: Int) {
        device = Device.current
        self.capacity = capacity
        baseAddress = UnsafeMutableDevicePointer<Element>.allocate(capacity: capacity)
        startIndex = 0
        endIndex = capacity
        owner = nil
        valueRetainees = Array(repeating: nil, count: capacity)
    }

    convenience init(device: Device) {
        self.init(device: device, capacity: 0)
    }
    
    convenience init(device: Device, capacity: Int) {
        let contextualDevice = Device.current
        if device == contextualDevice {
            self.init(capacity: capacity)
        } else {
            Device.current = device
            self.init(capacity: capacity)
            Device.current = contextualDevice
        }
    }

    init(viewing other: DeviceArrayBuffer<Element>) {
        device = other.device
        capacity = other.capacity
        baseAddress = other.baseAddress
        startIndex = other.startIndex
        endIndex = other.endIndex
        owner = other
        lifetimeKeeper = other.lifetimeKeeper
        valueRetainees = other.valueRetainees
    }

    init(viewing other: DeviceArrayBuffer<Element>, in range: Range<Int>) {
        device = other.device
        capacity = other.capacity
        baseAddress = other.baseAddress
        precondition(other.startIndex <= range.lowerBound && other.endIndex >= range.upperBound,
                     "Array index out of bounds")
        startIndex = range.lowerBound
        endIndex = range.upperBound
        owner = other
        lifetimeKeeper = other.lifetimeKeeper
        valueRetainees = other.valueRetainees
    }

    convenience init<C: Collection>(_ elements: C, device: Device) where
        C.Iterator.Element == Element, C.IndexDistance == Int
    {
        self.init(device: device, capacity: elements.count)
        var elements = Array(elements)
        baseAddress.assign(fromHost: &elements, count: elements.count)
        lifetimeKeeper = LifetimeKeeper<[Element]>(keeping: elements)
    }

    convenience init(repeating repeatedValue: Element, count: Int, device: Device) {
        self.init(device: device, capacity: count)
        baseAddress.assign(repeatedValue, count: count)
    }

    convenience init(_ other: DeviceArrayBuffer<Element>) {
        self.init(device: other.device, capacity: other.count)
        lifetimeKeeper = other.lifetimeKeeper
        baseAddress.assign(from: other.startAddress, count: other.count)
    }
    
    deinit {
        if owner == nil {
            baseAddress.deallocate()
        }
    }

    var indices: CountableRange<Int> {
        return startIndex..<endIndex
    }

    /// Replaces the specified subrange of elements with the given collection.
    public func replaceSubrange<C : Collection>
        (_ subrange: Range<Int>, with newElements: C) where C.Iterator.Element == DeviceValueBuffer<Element> {
        let subrange = CountableRange(subrange)
        for (index, element) in zip(subrange, newElements) {
            self[index] = element
        }
    }

    public func replaceSubrange
        (_ subrange: Range<Int>, with newElements: DeviceArrayBuffer<Element>) {
        precondition(subrange.lowerBound >= startIndex && subrange.upperBound <= endIndex, 
                     "Array index out of subrange")
        for (i, valueBuf) in zip(CountableRange(subrange), newElements) {
            valueRetainees[i] = valueBuf
        }
        baseAddress.advanced(by: subrange.lowerBound)
            .assign(from: newElements.startAddress,
                    count: Swift.min(subrange.count, count))
    }

    /// Accesses the subsequence bounded by the given range.
    ///
    /// - Parameter bounds: A range of the collection's indices. The upper and
    ///   lower bounds of the `bounds` range must be valid indices of the
    ///   collection.
    subscript(bounds: Range<Int>) -> DeviceArrayBuffer<Element> {
        get {
            return DeviceArrayBuffer(viewing: self, in: bounds)
        }
        set {
            replaceSubrange(bounds, with: newValue)
        }
    }

    subscript(i: Int) -> DeviceValueBuffer<Element> {
        get {
            return DeviceValueBuffer(viewing: self, offsetBy: i)
        }
        set {
            valueRetainees[i] = newValue
            baseAddress.advanced(by: i).assign(from: newValue.baseAddress)
        }
    }

}
