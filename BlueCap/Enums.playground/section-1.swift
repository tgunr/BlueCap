// Playground - noun: a place where people can play

import Foundation

protocol Deserialized {
    typealias SelfType
    class func deserialize(data:NSData) -> SelfType
}

protocol DeserializedEnum {
    typealias SelfType
    typealias ValueType : Deserialized
    class func fromNative(value:ValueType) -> SelfType?
}

extension Byte : Deserialized {
    static func deserialize(data:NSData) -> Byte {
        var value : Byte = 0
        data.getBytes(&value, length:sizeof(Byte))
        return value
    }
}

enum Enabled : Byte, DeserializedEnum {
    case No  = 0
    case Yes = 1
    static func fromNative(value:Byte) -> Enabled? {
        switch(value) {
        case 0:
            return Enabled.No
        case 1:
            return Enabled.Yes
        default:
            return nil
        }
    }
}

class EnumDeserialized<EnumType:DeserializedEnum where EnumType.ValueType == EnumType.ValueType.SelfType, EnumType == EnumType.SelfType> {
    func anyValue(data:NSData) -> Any? {
        let value = EnumType.ValueType.deserialize(data)
        return EnumType.fromNative(value)
    }
}

let enumDeserialized = EnumDeserialized<Enabled>()
let values : [Byte] = [0x01]
let data = NSData(bytes:values, length:1)
(enumDeserialized.anyValue(data) as Enabled) == Enabled.Yes

var a : Dictionary<String, [String]> = [:]
a["1"] = ["2"]
if let vals = a["1"] {
    let x = vals + ["3"]
}

var callbacks : Dictionary<Int, (value:Int)->Int> = [:]

func f(value:Int) -> Int {
    return value + 2
}

callbacks[1] = f
var h = callbacks[1]
callbacks[1]
h!(value: 2)
