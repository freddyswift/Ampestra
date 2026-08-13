import Foundation

enum MachOUUIDError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidUUID(String)
    case unsupportedBinary
    case malformedLoadCommands
    case missingUUIDCommand

    var description: String {
        switch self {
        case .invalidArguments:
            return "usage: set_macho_uuid.swift <thin-macho> <uuid>"
        case .invalidUUID(let value):
            return "invalid UUID: \(value)"
        case .unsupportedBinary:
            return "only little-endian 64-bit Mach-O files are supported"
        case .malformedLoadCommands:
            return "malformed Mach-O load commands"
        case .missingUUIDCommand:
            return "Mach-O file has no LC_UUID command"
        }
    }
}

func littleEndianUInt32(in data: Data, at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else {
        throw MachOUUIDError.malformedLoadCommands
    }

    return UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}

func uuidBytes(_ uuid: UUID) -> Data {
    var value = uuid.uuid
    return withUnsafeBytes(of: &value) { Data($0) }
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw MachOUUIDError.invalidArguments
    }

    let binaryURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let rawUUID = CommandLine.arguments[2]
    guard let uuid = UUID(uuidString: rawUUID) else {
        throw MachOUUIDError.invalidUUID(rawUUID)
    }

    let data = try Data(contentsOf: binaryURL, options: .mappedIfSafe)
    let machHeader64Size = 32
    let lcUUID = UInt32(0x1b)
    let uuidCommandSize = 24

    guard data.count >= machHeader64Size,
          try littleEndianUInt32(in: data, at: 0) == 0xfeedfacf else {
        throw MachOUUIDError.unsupportedBinary
    }

    let commandCount = Int(try littleEndianUInt32(in: data, at: 16))
    var commandOffset = machHeader64Size
    var uuidOffset: Int?

    for _ in 0..<commandCount {
        let command = try littleEndianUInt32(in: data, at: commandOffset)
        let commandSize = Int(try littleEndianUInt32(in: data, at: commandOffset + 4))
        guard commandSize >= 8, commandOffset + commandSize <= data.count else {
            throw MachOUUIDError.malformedLoadCommands
        }

        if command == lcUUID {
            guard commandSize == uuidCommandSize else {
                throw MachOUUIDError.malformedLoadCommands
            }
            uuidOffset = commandOffset + 8
            break
        }

        commandOffset += commandSize
    }

    guard let uuidOffset else {
        throw MachOUUIDError.missingUUIDCommand
    }

    let handle = try FileHandle(forWritingTo: binaryURL)
    try handle.seek(toOffset: UInt64(uuidOffset))
    try handle.write(contentsOf: uuidBytes(uuid))
    try handle.close()
} catch {
    FileHandle.standardError.write(Data("set_macho_uuid: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
