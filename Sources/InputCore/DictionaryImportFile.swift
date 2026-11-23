import Foundation

public enum DictionaryImportFile {
    private enum ReadError: LocalizedError {
        case tooLarge, notFile
        var errorDescription: String? {
            switch self {
            case .tooLarge: "文件超过 16 MiB，请拆分后分别导入。"
            case .notFile: "请选择普通文件。"
            }
        }
    }

    public static func read(_ url: URL) throws -> Data {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw ReadError.notFile }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try readChunks(limit: 16 * 1024 * 1024, read: handle.read(upToCount:))
    }

    static func readChunks(limit: Int, read: (Int) throws -> Data?) throws -> Data {
        var data = Data()
        while let chunk = try read(min(65536, limit - data.count + 1)), !chunk.isEmpty {
            guard chunk.count <= limit - data.count else { throw ReadError.tooLarge }
            data.append(chunk)
        }
        return data
    }
}
