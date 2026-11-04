import Foundation

func runMessagesTypedstreamDecoderTests() throws {
    func check(_ value:Bool,_ message:String) throws { if !value { throw StoreError(message:"Messages typedstream test: "+message) } }
    // NSArchiver is used only to GENERATE trusted synthetic fixtures. Production
    // decoding never invokes NSUnarchiver or instantiates an archived class.
    func archive(_ value:Any)->Data { NSArchiver.archivedData(withRootObject:value) }
    let text="Hello 🌱 — exact reply\nSecond line"
    let styled=NSMutableAttributedString(string:text)
    styled.addAttribute(NSAttributedString.Key("FixtureAttribute"),value:"MISLEADING ATTRIBUTE TEXT",range:NSRange(location:0,length:2))
    styled.addAttribute(NSAttributedString.Key("FixtureNumber"),value:NSNumber(value:7),range:NSRange(location:2,length:3))
    let fixtures:[Any]=[NSAttributedString(string:text),NSMutableAttributedString(string:text),NSString(string:text),NSMutableString(string:text),styled]
    for value in fixtures { try check(MessagesTypedstreamDecoder.text(archive(value))==text,"canonical mutable/immutable classes decode their leading string, not attribute strings") }
    for count in [0,1,127,128,255,256,20_000] {
        let long=String(repeating:"🌱",count:count)
        try check(MessagesTypedstreamDecoder.text(archive(NSAttributedString(string:long)))==long,"UTF-8 payload length and one/two/four-byte encoded lengths are handled")
    }
    let valid=archive(NSAttributedString(string:text))
    for end in 0..<valid.count { try check(MessagesTypedstreamDecoder.text(valid.prefix(end))==nil,"every truncated prefix fails closed") }
    var trailing=valid;trailing.append(0x86)
    try check(MessagesTypedstreamDecoder.text(trailing)==nil,"trailing data is not accepted as part of the root archive")
    var wrongHeader=valid;wrongHeader[0]=3
    try check(MessagesTypedstreamDecoder.text(wrongHeader)==nil,"unsupported streamer version is rejected")
    wrongHeader=valid;wrongHeader[2]=0
    try check(MessagesTypedstreamDecoder.text(wrongHeader)==nil,"signature is validated at the start, never scanned for")
    let className=Data("NSAttributedString".utf8)
    let classRange=valid.range(of:className)!
    var wrongClass=valid;wrongClass[classRange.lowerBound]=88
    try check(MessagesTypedstreamDecoder.text(wrongClass)==nil,"unrecognized leading archive class is rejected")
    var wrongVersion=valid;wrongVersion[classRange.upperBound]=1
    try check(MessagesTypedstreamDecoder.text(wrongVersion)==nil,"unsupported class version is rejected")
    let content=valid.range(of:Data(text.utf8))!
    var invalidUTF8=valid;invalidUTF8[content.lowerBound]=0xff
    try check(MessagesTypedstreamDecoder.text(invalidUTF8)==nil,"invalid UTF-8 is never repaired into invented text")
    var badLength=valid;badLength[content.lowerBound-1]=0x82
    try check(MessagesTypedstreamDecoder.text(badLength)==nil,"malformed or oversized declared content length is rejected")
    let refPattern=Data([0x01,0x94,0x84,0x01,0x2b])
    if let ref=valid.range(of:refPattern) {
        var badReference=valid;badReference[ref.lowerBound+1]=0x92
        try check(MessagesTypedstreamDecoder.text(badReference)==nil,"class backreference cannot resolve to an object slot")
    } else { throw StoreError(message:"Canonical fixture class-reference layout changed.") }
    try check(MessagesTypedstreamDecoder.text(archive(["NSString":"not a reply"]))==nil,"dictionary roots and tempting embedded strings are not message bodies")
    try check(MessagesTypedstreamDecoder.text(archive(NSAttributedString(string:String(repeating:"x",count:50_001))))==nil,"decoded text respects the Store character limit")
    try check(MessagesTypedstreamDecoder.text(Data(repeating:0,count:262_145))==nil,"archive bytes are capped before parsing")
    print("PASS: structural typedstream decoding with generated NSArchiver fixtures, Unicode/lengths, references, attributes and exhaustive truncation; no live data.")
}
