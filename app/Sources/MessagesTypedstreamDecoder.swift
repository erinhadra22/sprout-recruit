import Foundation

// Independent, bounded parser for the leading string in Apple's legacy archive.
// Format references (no implementation code copied):
// https://github.com/dgelessus/python-typedstream/blob/master/src/typedstream/stream.py
// https://github.com/dgelessus/python-typedstream/blob/master/src/typedstream/types/foundation.py
// Class layouts are also verified against synthetic NSArchiver output in tests.
// This reads bytes only: no archived class is ever looked up or instantiated.
enum MessagesTypedstreamDecoder {
    static func text(_ data:Data)->String? {
        guard data.count<=262_144 else { return nil }
        var parser=Parser(bytes:Array(data))
        return try? parser.leadingText()
    }
    private enum Invalid:Error { case archive }
    private struct ClassInfo:Equatable { let name:String;let version:Int }
    private enum Entry { case object(String);case type([ClassInfo]);case cString }
    private struct Parser {
        let bytes:[UInt8]
        var offset=0,littleEndian=true,operations=4096
        var strings:[String]=[],objects:[Entry]=[]
        mutating func byte() throws -> UInt8 {
            operations -= 1
            guard operations>=0,offset<bytes.count else { throw Invalid.archive }
            defer { offset += 1 };return bytes[offset]
        }
        mutating func take(_ count:Int) throws -> [UInt8] {
            guard count>=0,count<=262_144,offset<=bytes.count,count<=bytes.count-offset else { throw Invalid.archive }
            defer { offset += count };return Array(bytes[offset..<offset+count])
        }
        mutating func expect(_ expected:UInt8) throws { guard try byte()==expected else { throw Invalid.archive } }
        mutating func integer(_ first:UInt8?=nil,signed:Bool) throws -> Int {
            let head=try first ?? byte()
            if head==0x81 || head==0x82 {
                let width=head==0x81 ? 2 : 4
                let stored=try take(width),ordered=littleEndian ? Array(stored.reversed()) : stored
                let value=ordered.reduce(UInt32(0)) { ($0<<8)|UInt32($1) }
                if signed { return width==2 ? Int(Int16(bitPattern:UInt16(value))) : Int(Int32(bitPattern:value)) }
                return Int(value)
            }
            guard !(0x80...0x91).contains(head) else { throw Invalid.archive }
            return signed ? Int(Int8(bitPattern:head)) : Int(head)
        }
        mutating func rawString(maximum:Int) throws -> String {
            let count=try integer(signed:false)
            guard count<=maximum,let string=String(bytes:try take(count),encoding:.utf8),!string.contains("\0") else { throw Invalid.archive }
            return string
        }
        mutating func sharedString() throws -> String {
            let head=try byte()
            if head==0x84 {
                guard strings.count<128 else { throw Invalid.archive }
                let string=try rawString(maximum:128);strings.append(string);return string
            }
            let index=try integer(head,signed:true)+110
            guard index>=0,index<strings.count else { throw Invalid.archive }
            return strings[index]
        }
        mutating func classChain() throws -> [ClassInfo] {
            var definitions:[ClassInfo]=[],head=try byte()
            while head==0x84 {
                guard definitions.count<4 else { throw Invalid.archive }
                definitions.append(ClassInfo(name:try sharedString(),version:try integer(signed:true)))
                head=try byte()
            }
            var tail:[ClassInfo]=[]
            if head != 0x85 {
                let index=try integer(head,signed:true)+110
                guard index>=0,index<objects.count,case let .type(existing)=objects[index] else { throw Invalid.archive }
                tail=existing
            }
            guard definitions.count+tail.count<=4,objects.count+definitions.count<=256 else { throw Invalid.archive }
            let chain=definitions+tail
            for index in definitions.indices { objects.append(.type(Array(chain[index...]))) }
            return chain
        }
        mutating func newObject() throws -> [ClassInfo] {
            try expect(0x84)
            guard objects.count<256 else { throw Invalid.archive }
            let index=objects.count;objects.append(.object(""))
            let chain=try classChain()
            objects[index] = .object(chain.first?.name ?? "")
            return chain
        }
        func isString(_ chain:[ClassInfo])->Bool {
            chain==[ClassInfo(name:"NSString",version:1),ClassInfo(name:"NSObject",version:0)] ||
            chain==[ClassInfo(name:"NSMutableString",version:1),ClassInfo(name:"NSString",version:1),ClassInfo(name:"NSObject",version:0)]
        }
        func isAttributedString(_ chain:[ClassInfo])->Bool {
            chain==[ClassInfo(name:"NSAttributedString",version:0),ClassInfo(name:"NSObject",version:0)] ||
            chain==[ClassInfo(name:"NSMutableAttributedString",version:0),ClassInfo(name:"NSAttributedString",version:0),ClassInfo(name:"NSObject",version:0)]
        }
        mutating func skipObject(depth:Int,dictionary:Bool=false) throws {
            guard depth<=12,offset<bytes.count else { throw Invalid.archive }
            let head=bytes[offset]
            if head==0x85 { try expect(0x85);guard !dictionary else { throw Invalid.archive };return }
            if head != 0x84 {
                let index=try integer(signed:true)+110
                guard index>=0,index<objects.count,case let .object(name)=objects[index],
                      !dictionary || ["NSDictionary","NSMutableDictionary"].contains(name) else { throw Invalid.archive }
                return
            }
            let chain=try newObject()
            if dictionary {
                let plain=[ClassInfo(name:"NSDictionary",version:0),ClassInfo(name:"NSObject",version:0)]
                guard chain==plain || chain==[ClassInfo(name:"NSMutableDictionary",version:0)]+plain else { throw Invalid.archive }
            }
            while offset<bytes.count,bytes[offset] != 0x86 {
                let encoding=try sharedString()
                guard !encoding.isEmpty,encoding.utf8.count<=32 else { throw Invalid.archive }
                for code in encoding.utf8 {
                    switch code {
                    case 64:try skipObject(depth:depth+1) // @, object
                    case 43:_=try take(integer(signed:false)) // +, opaque bytes
                    case 105,108,115,113:_=try integer(signed:true) // i l s q
                    case 73,76,83,81:_=try integer(signed:false) // I L S Q
                    case 99,67:_=try byte() // c C are literal bytes
                    case 66:guard try byte()<=1 else { throw Invalid.archive } // B
                    case 102,100: // f d
                        let head=try byte()
                        if head==0x83 { _=try take(code==102 ? 4 : 8) }
                        else { _=try integer(head,signed:true) }
                    case 42: // *, a shared C string with an object-table identity
                        let head=try byte()
                        if head==0x84 {
                            _=try sharedString();guard objects.count<256 else { throw Invalid.archive };objects.append(.cString)
                        } else if head != 0x85 {
                            let index=try integer(head,signed:true)+110
                            guard index>=0,index<objects.count,case .cString=objects[index] else { throw Invalid.archive }
                        }
                    case 35:_=try classChain() // #
                    case 37,58:_=try sharedString() // % :
                    case 33:break // !, explicitly ignored value
                    default:throw Invalid.archive
                    }
                }
            }
            try expect(0x86)
        }
        mutating func leadingText() throws -> String {
            try expect(4);try expect(11)
            let signature=String(bytes:try take(11),encoding:.ascii)
            guard signature=="streamtyped" || signature=="typedstream" else { throw Invalid.archive }
            littleEndian=signature=="streamtyped"
            guard try integer(signed:false)==1000,try sharedString()=="@" else { throw Invalid.archive }
            let root=try newObject(),attributed=isAttributedString(root)
            if attributed {
                guard try sharedString()=="@",isString(try newObject()) else { throw Invalid.archive }
            } else { guard isString(root) else { throw Invalid.archive } }
            guard try sharedString()=="+" else { throw Invalid.archive }
            let text=try rawString(maximum:262_144)
            guard text.count<=50_000 else { throw Invalid.archive }
            try expect(0x86) // Complete NSString, including its exact byte length.
            if !attributed || text.isEmpty {
                if attributed { try expect(0x86) }
                guard offset==bytes.count else { throw Invalid.archive }
            } else {
                // Attribute values never supply body text. Walk their typed
                // boundaries only, so truncated archives cannot pass as complete.
                var remaining=text.utf16.count
                while remaining>0 {
                    guard try sharedString()=="iI" else { throw Invalid.archive }
                    let run=try integer(signed:true),length=try integer(signed:false)
                    guard run>0,run<=4096,length>0,length<=remaining,try sharedString()=="@" else { throw Invalid.archive }
                    try skipObject(depth:0,dictionary:true)
                    remaining -= length
                }
                try expect(0x86)
                guard offset==bytes.count else { throw Invalid.archive }
            }
            return text
        }
    }
}
