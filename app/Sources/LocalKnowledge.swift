import Foundation
import PDFKit
import CryptoKit
import Darwin

/// Reads exactly one path selected or typed by the user. No directory scan, URL fetch or content persistence.
enum LocalKnowledge {
    static let textExtensions = ["txt","md","markdown","csv","tsv","json","html","htm","log"]
    static let maxBytes = 10 * 1024 * 1024
    static let maxCharacters = 200000
    static func normalizedPath(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2000, !value.contains("\0"), !value.contains("\n"), !value.contains("\r"),
              value.hasPrefix("/") || value.hasPrefix("~/"), !value.hasPrefix("//") else {
            throw StoreError(message:"Enter an absolute local file path or a path beginning with ~/.")
        }
        let path = (value as NSString).expandingTildeInPath
        let normalized = (path as NSString).standardizingPath
        let parts = URL(fileURLWithPath:normalized).pathComponents.map{$0.lowercased()}
        guard !parts.contains(where:{[".ssh",".aws",".gnupg","keychains"].contains($0)}) else { throw StoreError(message:"Choose a company reference document, not a credential or key store.") }
        return normalized
    }
    static func preview(_ p: Record) throws -> Record {
        guard p["readConfirmed"] as? Bool == true else { throw StoreError(message:"Choose Preview to read this selected local file.") }
        let selected = try normalizedPath(AIContext.text(p,"path",max:2000,required:true))
        let query = try AIContext.text(p,"query",max:200)
        let url = URL(fileURLWithPath:selected).resolvingSymlinksInPath()
        _ = try normalizedPath(url.path)
        let ext = url.pathExtension.lowercased()
        guard textExtensions.contains(ext) || ext == "pdf" else { throw StoreError(message:"Preview supports text, Markdown, CSV, JSON, HTML and text-based PDF files. Export other documents to one of these formats.") }
        let resources: URLResourceValues
        do { resources = try url.resourceValues(forKeys:[.isRegularFileKey,.volumeIsLocalKey,.isUbiquitousItemKey,.ubiquitousItemDownloadingStatusKey]) }
        catch { throw StoreError(message:"That local file is unavailable. Check the path and access permission.") }
        guard resources.isRegularFile == true else { throw StoreError(message:"Choose one regular file, not a folder or special device.") }
        guard resources.volumeIsLocal == true else { throw StoreError(message:"Preview needs a file stored on a local disk.") }
        if resources.isUbiquitousItem == true {
            guard resources.ubiquitousItemDownloadingStatus == .current || resources.ubiquitousItemDownloadingStatus == .downloaded else {
                throw StoreError(message:"Download this file to the Mac first. Sprout will not fetch it from cloud storage.")
            }
        }
        let fd = Darwin.open(url.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw StoreError(message:"Cannot read the selected local file.") }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? handle.close() }
        var statInfo = stat()
        guard fstat(fd,&statInfo) == 0, statInfo.st_mode & S_IFMT == S_IFREG else { throw StoreError(message:"Choose a regular local file.") }
        guard statInfo.st_flags & UInt32(SF_DATALESS) == 0 else { throw StoreError(message:"Download this document to the Mac first. Cloud-only placeholders are not previewed.") }
        guard statInfo.st_size >= 0, statInfo.st_size <= maxBytes else { throw StoreError(message:"Choose a reference up to 10 MB for local preview.") }
        let data = try handle.read(upToCount:maxBytes+1) ?? Data()
        guard data.count <= maxBytes else { throw StoreError(message:"The file grew beyond the 10 MB preview limit.") }
        var extracted = "", truncated = false, pagesRead = 0, totalPages = 0
        if ext == "pdf" {
            guard let document = PDFDocument(data:data), !document.isLocked else { throw StoreError(message:"This PDF is locked or unreadable. Choose an unlocked text-based PDF.") }
            totalPages = document.pageCount
            for i in 0..<min(totalPages,100) {
                let page = document.page(at:i)?.string ?? ""
                let remaining = maxCharacters-extracted.count
                if remaining <= 0 { truncated = true; break }
                extracted += String(page.prefix(remaining))
                pagesRead += 1
                if page.count > remaining { truncated = true; break }
                if extracted.count < maxCharacters { extracted += "\n" }
            }
            truncated = truncated || pagesRead < totalPages
            guard !extracted.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw StoreError(message:"This PDF has no readable text. Scanned images need a separate OCR step; no OCR was run.") }
        } else {
            guard let value = String(data:data,encoding:.utf8) ?? String(data:data,encoding:.utf16), !value.contains("\0") else {
                throw StoreError(message:"This file is not readable UTF-8 or UTF-16 text.")
            }
            extracted = String(value.prefix(maxCharacters)); truncated = value.count > maxCharacters
        }
        var matches: [Record] = []
        if !query.isEmpty {
            for (index,line) in extracted.components(separatedBy:.newlines).enumerated() {
                if line.range(of:query,options:.caseInsensitive) != nil {
                    // Include the matching region, not only the first part of a long line.
                    let range = line.range(of:query,options:.caseInsensitive)!
                    let start = line.index(range.lowerBound,offsetBy:-120,limitedBy:line.startIndex) ?? line.startIndex
                    matches.append(["line":index+1,"text":String(line[start...].prefix(500))])
                    if matches.count == 50 { break }
                }
            }
        }
        let modified = Date(timeIntervalSince1970:TimeInterval(statInfo.st_mtimespec.tv_sec))
        return ["path":selected,"resolvedPath":url.path,"format":ext,"byteCount":data.count,"modifiedAt":ISO8601DateFormatter().string(from:modified),
                "sha256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),"preview":String(extracted.prefix(8000)),
                "previewTruncated":extracted.count > 8000,"extractionTruncated":truncated,"charactersExamined":extracted.count,
                "pagesRead":pagesRead,"totalPages":totalPages,"query":query,"matches":matches,"matchLimitReached":matches.count == 50,
                "scope":"One explicitly selected local file","networkUsed":false,"persistedContent":false,"verifiedForDrafting":false]
    }
}
