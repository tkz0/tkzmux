// SPIRVReflection — just enough of a SPIR-V reader to check the committed modules against
// TkzShaderTypes.h: entry points, decorations, member offsets, types, variables and the case
// literals of `OpSwitch`. No validation (spirv-val already ran in scripts/build-shaders-linux.sh)
// and no names: `glslc -O` strips `OpName`/`OpMemberName`, so blocks are found by storage class
// and members by index, which is declaration order and therefore C field order.
//
// Numbers are from the SPIR-V 1.6 specification, section 3 (binary form) and the opcode tables.

struct SPIRVReflection {
    enum ReflectionError: Error, CustomStringConvertible {
        case badHeader(magic: UInt32, count: Int)
        case truncated(at: Int)

        var description: String {
            switch self {
            case let .badHeader(magic, count): "not SPIR-V: magic 0x\(String(magic, radix: 16)), \(count) words"
            case let .truncated(index): "instruction at word \(index) runs past the end"
            }
        }
    }

    enum Op {
        static let entryPoint: UInt32 = 15
        static let typeInt: UInt32 = 21
        static let typeFloat: UInt32 = 22
        static let typeVector: UInt32 = 23
        static let typeImage: UInt32 = 25
        static let typeArray: UInt32 = 28
        static let typeRuntimeArray: UInt32 = 29
        static let typeStruct: UInt32 = 30
        static let typePointer: UInt32 = 32
        static let constant: UInt32 = 43
        static let variable: UInt32 = 59
        static let decorate: UInt32 = 71
        static let memberDecorate: UInt32 = 72
        static let switchBranch: UInt32 = 251
    }

    enum Decoration {
        static let block: UInt32 = 2
        static let arrayStride: UInt32 = 6
        static let binding: UInt32 = 33
        static let descriptorSet: UInt32 = 34
        static let offset: UInt32 = 35
    }

    enum StorageClass {
        static let uniformConstant: UInt32 = 0
        static let input: UInt32 = 1
        static let uniform: UInt32 = 2
        static let output: UInt32 = 3
        static let pushConstant: UInt32 = 9
        static let storageBuffer: UInt32 = 12
    }

    enum ExecutionModel {
        static let vertex: UInt32 = 0
        static let fragment: UInt32 = 4
    }

    indirect enum SPIRVType: Equatable {
        case int(width: UInt32, signed: Bool)
        case float(width: UInt32)
        case vector(component: UInt32, count: UInt32)
        case array(element: UInt32, length: UInt32)
        case runtimeArray(element: UInt32)
        case structure(members: [UInt32])
        /// `OpTypeImage` operands after the result id: sampled type, Dim, Depth, Arrayed, MS,
        /// Sampled, Image Format.
        case image(dim: UInt32, depth: UInt32, arrayed: UInt32, multisampled: UInt32, sampled: UInt32, format: UInt32)
    }

    struct EntryPoint: Equatable {
        let model: UInt32
        let name: String
    }

    struct Variable {
        let id: UInt32
        let storageClass: UInt32
        /// The pointee type (the variable's own type is always a pointer).
        let type: UInt32
    }

    static let magic: UInt32 = 0x0723_0203

    let version: UInt32
    private(set) var entryPoints: [EntryPoint] = []
    private(set) var types: [UInt32: SPIRVType] = [:]
    private(set) var variables: [Variable] = []
    /// `OpConstant` values of 32-bit scalars, by id.
    private(set) var constants: [UInt32: UInt32] = [:]
    /// id → decoration → literal operands.
    private(set) var decorations: [UInt32: [UInt32: [UInt32]]] = [:]
    /// struct id → member index → `Offset`.
    private(set) var memberOffsets: [UInt32: [Int: UInt32]] = [:]
    /// The case literals of every `OpSwitch`, in order (32-bit selectors only).
    private(set) var switchLiterals: [[UInt32]] = []

    init(words: [UInt32]) throws {
        guard words.count >= 5, words[0] == Self.magic else {
            throw ReflectionError.badHeader(magic: words.first ?? 0, count: words.count)
        }
        version = words[1]
        var pointers: [UInt32: (storageClass: UInt32, type: UInt32)] = [:]
        var index = 5
        while index < words.count {
            let opcode = words[index] & 0xFFFF
            let count = Int(words[index] >> 16)
            guard count > 0, index + count <= words.count else { throw ReflectionError.truncated(at: index) }
            let operands = Array(words[(index + 1)..<(index + count)])
            switch opcode {
            case Op.entryPoint:
                entryPoints.append(EntryPoint(model: operands[0], name: Self.string(operands.dropFirst(2))))
            case Op.typeInt:
                types[operands[0]] = .int(width: operands[1], signed: operands[2] != 0)
            case Op.typeFloat:
                types[operands[0]] = .float(width: operands[1])
            case Op.typeVector:
                types[operands[0]] = .vector(component: operands[1], count: operands[2])
            case Op.typeImage:
                types[operands[0]] = .image(dim: operands[2], depth: operands[3], arrayed: operands[4],
                                            multisampled: operands[5], sampled: operands[6], format: operands[7])
            case Op.typeArray:
                types[operands[0]] = .array(element: operands[1], length: operands[2])
            case Op.typeRuntimeArray:
                types[operands[0]] = .runtimeArray(element: operands[1])
            case Op.typeStruct:
                types[operands[0]] = .structure(members: Array(operands.dropFirst()))
            case Op.typePointer:
                pointers[operands[0]] = (operands[1], operands[2])
            case Op.constant where operands.count == 3:
                constants[operands[1]] = operands[2]
            case Op.variable:
                if let pointer = pointers[operands[0]] {
                    variables.append(Variable(id: operands[1], storageClass: operands[2], type: pointer.type))
                }
            case Op.decorate:
                decorations[operands[0], default: [:]][operands[1]] = Array(operands.dropFirst(2))
            case Op.memberDecorate where operands[2] == Decoration.offset:
                memberOffsets[operands[0], default: [:]][Int(operands[1])] = operands[3]
            case Op.switchBranch:
                // selector, default, then (literal, label) pairs.
                switchLiterals.append(stride(from: 2, to: operands.count, by: 2).map { operands[$0] })
            default:
                break
            }
            index += count
        }
    }

    /// A nul-terminated literal string packed little-endian into words.
    private static func string(_ words: ArraySlice<UInt32>) -> String {
        var bytes: [UInt8] = []
        outer: for word in words {
            for shift in stride(from: 0, to: 32, by: 8) {
                let byte = UInt8(truncatingIfNeeded: word >> UInt32(shift))
                if byte == 0 { break outer }
                bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Queries

    func variables(in storageClass: UInt32) -> [Variable] {
        variables.filter { $0.storageClass == storageClass }
    }

    func decoration(_ decoration: UInt32, of id: UInt32) -> [UInt32]? {
        decorations[id]?[decoration]
    }

    /// The `Offset` of every member of a struct, in member order; nil if one is missing.
    func offsets(ofStruct id: UInt32) -> [Int]? {
        guard case let .structure(members)? = types[id], let decorated = memberOffsets[id] else { return nil }
        var result: [Int] = []
        for member in members.indices {
            guard let offset = decorated[member] else { return nil }
            result.append(Int(offset))
        }
        return result
    }

    /// Size in bytes of an explicitly laid-out type: scalars and vectors by width, arrays by
    /// `ArrayStride × length`, structs up to the end of their last member (std430 rounds the
    /// stride of an array of them up to the struct alignment, which is what `ArrayStride` holds).
    /// Nil for runtime arrays, images and anything undecorated.
    func byteSize(of id: UInt32) -> Int? {
        switch types[id] {
        case let .int(width, _)?, let .float(width)?:
            return Int(width) / 8
        case let .vector(component, count)?:
            return byteSize(of: component).map { $0 * Int(count) }
        case let .array(_, lengthID)?:
            guard let stride = decoration(Decoration.arrayStride, of: id)?.first,
                  let length = constants[lengthID] else { return nil }
            return Int(stride) * Int(length)
        case let .structure(members)?:
            guard let offsets = offsets(ofStruct: id), let last = members.last,
                  let lastSize = byteSize(of: last) else { return members.isEmpty ? 0 : nil }
            return offsets[offsets.count - 1] + lastSize
        default:
            return nil
        }
    }

    /// Byte size of every member of a struct, in member order.
    func memberSizes(ofStruct id: UInt32) -> [Int?] {
        guard case let .structure(members)? = types[id] else { return [] }
        return members.map { byteSize(of: $0) }
    }
}
