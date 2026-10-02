// SPIRVLayoutTests — the committed SPIR-V in Sources/TkzShadersSPIRV agrees with TkzShaderTypes.h.
//
// The Vulkan pipelines (WOR-313) read the same bytes the Metal pipelines read: `TkzUniforms` as
// push constants and the instance arrays as storage buffers. Nothing at runtime would notice if the
// GLSL port laid a field out differently, so this suite checks the compiled modules themselves:
//   1. every module is SPIR-V 1.6 with one `main` entry point of the right stage;
//   2. the push-constant block and every SSBO element type have `OpMemberDecorate Offset`s equal to
//      `MemoryLayout.offset(of:)` on the C structs, field by field, and the C sizes (80/4/32/32);
//   3. descriptor sets and bindings are the C buffer/texture indices, and nothing else is bound;
//   4. TkzShaderTypes.glsl mirrors every C constant (rect styles, glyph flags, indices, version),
//      and its glyph byte offsets equal the C ones;
//   5. the rect fragment switch covers exactly the C rect styles;
//   6. the module table and the generated header agree with TKZ_FN_* and the glslc pin.
// Pipeline creation and pixels are WOR-313 S3 (conformance) and S4b (renderer).

import Foundation
import Testing
import TkzShaderTypes
import TkzShadersSPIRV

// MARK: - Fixtures

/// The repository root, from this file's path (Tests/TkzShadersSPIRVTests/<this file>).
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private struct Module {
    let shader: TkzSPIRVShader
    let table: TkzSPIRVModule
    let reflection: SPIRVReflection

    init(_ shader: Int) throws {
        self.shader = TkzSPIRVShader(shader)
        let entry = try #require(tkz_spirv_module(self.shader))
        table = entry.pointee
        let words = Array(UnsafeBufferPointer(start: table.code, count: table.codeSize / 4))
        reflection = try SPIRVReflection(words: words)
    }

    var name: String { String(cString: table.metalFunction) }
}

private let allShaders = [
    Int(TKZ_SPIRV_BG_VERTEX), Int(TKZ_SPIRV_BG_FRAGMENT),
    Int(TKZ_SPIRV_RECT_VERTEX), Int(TKZ_SPIRV_RECT_FRAGMENT),
    Int(TKZ_SPIRV_GLYPH_VERTEX), Int(TKZ_SPIRV_GLYPH_FRAGMENT),
]

/// `#define TKZ_<NAME> <integer>[u]` lines of TkzShaderTypes.glsl.
private func glslDefines() throws -> [String: Int] {
    let url = repoRoot.appendingPathComponent("Sources/TkzShadersSPIRV/glsl/TkzShaderTypes.glsl")
    var defines: [String: Int] = [:]
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "#define", parts[1].hasPrefix("TKZ_") else { continue }
        var literal = parts[2]
        if literal.hasSuffix("u") { literal = literal.dropLast() }
        if let value = Int(literal) { defines[String(parts[1])] = value }
    }
    return defines
}

/// Expected offsets of a C struct's fields, in declaration order.
private func offsets<T>(_ type: T.Type, _ fields: [PartialKeyPath<T>]) -> [Int?] {
    fields.map { MemoryLayout<T>.offset(of: $0) }
}

// Key paths are not Sendable, so these are computed rather than stored globals.
private var uniformFields: [PartialKeyPath<TkzUniforms>] { [
    \.viewportSizePx, \.cellSizePx, \.gridOriginPx, \.grayscaleAtlasSizePx, \.colorAtlasSizePx,
    \.gridSize, \.defaultBackground, \.defaultForeground, \.cursorColor, \.cursorTextColor,
    \.minContrast, \.reserved0, \.reserved1, \.reserved2,
] }

private var rectFields: [PartialKeyPath<TkzRectInstance>] { [
    \.originPx, \.sizePx, \.color, \.style, \.thicknessPx, \.reserved0,
] }

/// TkzShaderTypes.glsl's `TKZ_GLYPH_OFFSET_*` names for the `TkzGlyphInstance` fields.
private var glyphFields: [(define: String, field: PartialKeyPath<TkzGlyphInstance>)] { [
    ("TKZ_GLYPH_OFFSET_GRID_POS", \.gridPos),
    ("TKZ_GLYPH_OFFSET_OFFSET_PX", \.offsetPx),
    ("TKZ_GLYPH_OFFSET_SIZE_PX", \.sizePx),
    ("TKZ_GLYPH_OFFSET_ATLAS_POS", \.atlasPos),
    ("TKZ_GLYPH_OFFSET_COLOR", \.color),
    ("TKZ_GLYPH_OFFSET_BG_COLOR", \.bgColor),
    ("TKZ_GLYPH_OFFSET_FLAGS", \.flags),
    ("TKZ_GLYPH_OFFSET_RESERVED0", \.reserved0),
] }

/// Every C constant TkzShaderTypes.glsl must mirror, with its C value.
private let cConstants: [String: Int] = [
    "TKZ_SHADER_TYPES_VERSION": Int(TKZ_SHADER_TYPES_VERSION),
    "TKZ_BUFFER_INDEX_UNIFORMS": Int(TKZ_BUFFER_INDEX_UNIFORMS),
    "TKZ_BUFFER_INDEX_INSTANCES": Int(TKZ_BUFFER_INDEX_INSTANCES),
    "TKZ_TEXTURE_INDEX_GRAYSCALE": Int(TKZ_TEXTURE_INDEX_GRAYSCALE),
    "TKZ_TEXTURE_INDEX_COLOR": Int(TKZ_TEXTURE_INDEX_COLOR),
    "TKZ_GLYPH_FLAG_COLOR": Int(TKZ_GLYPH_FLAG_COLOR),
    "TKZ_GLYPH_FLAG_UNDER_CURSOR": Int(TKZ_GLYPH_FLAG_UNDER_CURSOR),
    "TKZ_GLYPH_FLAG_MIN_CONTRAST": Int(TKZ_GLYPH_FLAG_MIN_CONTRAST),
    "TKZ_GLYPH_FLAG_WIDE": Int(TKZ_GLYPH_FLAG_WIDE),
    "TKZ_RECT_STYLE_SOLID": Int(TKZ_RECT_STYLE_SOLID),
    "TKZ_RECT_STYLE_HOLLOW": Int(TKZ_RECT_STYLE_HOLLOW),
    "TKZ_RECT_STYLE_UNDERLINE_SINGLE": Int(TKZ_RECT_STYLE_UNDERLINE_SINGLE),
    "TKZ_RECT_STYLE_UNDERLINE_DOUBLE": Int(TKZ_RECT_STYLE_UNDERLINE_DOUBLE),
    "TKZ_RECT_STYLE_UNDERLINE_CURLY": Int(TKZ_RECT_STYLE_UNDERLINE_CURLY),
    "TKZ_RECT_STYLE_UNDERLINE_DOTTED": Int(TKZ_RECT_STYLE_UNDERLINE_DOTTED),
    "TKZ_RECT_STYLE_UNDERLINE_DASHED": Int(TKZ_RECT_STYLE_UNDERLINE_DASHED),
    "TKZ_RECT_STYLE_STRIKETHROUGH": Int(TKZ_RECT_STYLE_STRIKETHROUGH),
    "TKZ_RECT_STYLE_COUNT": Int(TKZ_RECT_STYLE_COUNT),
]

private struct LayoutMismatch: Error, CustomStringConvertible {
    let description: String
}

/// The single storage buffer of a module: its variable and the element type of its runtime array.
private func instanceBuffer(_ module: Module) throws -> (variable: SPIRVReflection.Variable, element: UInt32) {
    let r = module.reflection
    let buffers = r.variables(in: SPIRVReflection.StorageClass.storageBuffer)
    try #require(buffers.count == 1, "\(module.name): \(buffers.count) storage buffers")
    let block = buffers[0].type
    #expect(r.decoration(SPIRVReflection.Decoration.block, of: block) != nil)
    guard case let .structure(members)? = r.types[block], members.count == 1,
          case let .runtimeArray(element)? = r.types[members[0]] else {
        throw LayoutMismatch(description: "\(module.name): the SSBO block is not { T items[]; }")
    }
    #expect(r.offsets(ofStruct: block) == [0])
    return (buffers[0], element)
}

private func arrayStride(_ module: Module, ofArrayHolding element: UInt32) -> Int? {
    let r = module.reflection
    for (id, type) in r.types {
        if case let .runtimeArray(e) = type, e == element {
            return r.decoration(SPIRVReflection.Decoration.arrayStride, of: id)?.first.map(Int.init)
        }
    }
    return nil
}

// MARK: - Tests

@Suite("Committed SPIR-V matches TkzShaderTypes.h")
struct SPIRVLayoutTests {
    @Test("every module is SPIR-V 1.6 with one `main` of the stage its table entry names")
    func entryPoints() throws {
        #expect(Int(TKZ_SPIRV_SHADER_COUNT) == allShaders.count)
        for shader in allShaders {
            let module = try Module(shader)
            #expect(module.table.codeSize % 4 == 0)
            #expect(module.table.codeSize > 20)
            #expect(module.reflection.version == 0x0001_0600, "\(module.name): SPIR-V 1.6 is what vulkan1.3 targets")
            #expect(String(cString: module.table.entryPoint) == TKZ_SPIRV_ENTRY_POINT)

            let isVertex = module.name.hasSuffix("_vertex")
            let stage = UInt32(isVertex ? TKZ_SPIRV_STAGE_VERTEX : TKZ_SPIRV_STAGE_FRAGMENT)
            let model = isVertex ? SPIRVReflection.ExecutionModel.vertex : SPIRVReflection.ExecutionModel.fragment
            #expect(module.table.stage == stage, "\(module.name)")
            #expect(module.reflection.entryPoints == [.init(model: model, name: TKZ_SPIRV_ENTRY_POINT)],
                    "\(module.name)")
        }
        #expect(tkz_spirv_module(TkzSPIRVShader(TKZ_SPIRV_SHADER_COUNT)) == nil)
    }

    @Test("the table names the Metal functions in TKZ_FN_* order")
    func metalFunctionNames() throws {
        let names = try allShaders.map { try Module($0).name }
        #expect(names == [TKZ_FN_BG_VERTEX, TKZ_FN_BG_FRAGMENT, TKZ_FN_RECT_VERTEX,
                          TKZ_FN_RECT_FRAGMENT, TKZ_FN_GLYPH_VERTEX, TKZ_FN_GLYPH_FRAGMENT])
    }

    @Test("push constants are TkzUniforms: 80 bytes, every field at its C offset")
    func pushConstants() throws {
        #expect(MemoryLayout<TkzUniforms>.size == 80)
        let expected = offsets(TkzUniforms.self, uniformFields)
        var users: [String] = []
        for shader in allShaders {
            let module = try Module(shader)
            let r = module.reflection
            let blocks = r.variables(in: SPIRVReflection.StorageClass.pushConstant)
            guard let block = blocks.first else { continue }
            users.append(module.name)
            #expect(blocks.count == 1)
            #expect(r.decoration(SPIRVReflection.Decoration.block, of: block.type) != nil)
            #expect(r.offsets(ofStruct: block.type)?.map { Optional($0) } == expected, "\(module.name)")
            #expect(r.byteSize(of: block.type) == MemoryLayout<TkzUniforms>.size, "\(module.name)")
            // Every member is 4 bytes per component, so no two members may overlap either.
            let sizes = r.memberSizes(ofStruct: block.type)
            let starts = r.offsets(ofStruct: block.type) ?? []
            for i in 1..<starts.count {
                #expect(starts[i - 1] + (sizes[i - 1] ?? .max) <= starts[i], "\(module.name) member \(i - 1)")
            }
        }
        // The pipeline layout needs one range for the vertex and fragment stages because of these.
        #expect(users == [TKZ_FN_BG_FRAGMENT, TKZ_FN_RECT_VERTEX, TKZ_FN_GLYPH_VERTEX])
    }

    @Test("the background SSBO is TkzBgCell[]: a plain uint array, stride 4")
    func backgroundCells() throws {
        #expect(MemoryLayout<TkzBgCell>.size == 4)
        #expect(MemoryLayout<TkzBgCell>.offset(of: \.color) == 0)
        let module = try Module(Int(TKZ_SPIRV_BG_FRAGMENT))
        let (_, element) = try instanceBuffer(module)
        #expect(module.reflection.types[element] == .int(width: 32, signed: false))
        #expect(arrayStride(module, ofArrayHolding: element) == MemoryLayout<TkzBgCell>.stride)
    }

    @Test("the rect SSBO is TkzRectInstance[]: std430, every field at its C offset, stride 32")
    func rectInstances() throws {
        #expect(MemoryLayout<TkzRectInstance>.size == 32)
        let module = try Module(Int(TKZ_SPIRV_RECT_VERTEX))
        let r = module.reflection
        let (_, element) = try instanceBuffer(module)
        #expect(r.offsets(ofStruct: element)?.map { Optional($0) } == offsets(TkzRectInstance.self, rectFields))
        #expect(r.memberSizes(ofStruct: element) == [8, 8, 4, 4, 4, 4])
        #expect(r.byteSize(of: element) == MemoryLayout<TkzRectInstance>.size)
        #expect(arrayStride(module, ofArrayHolding: element) == MemoryLayout<TkzRectInstance>.stride)
    }

    @Test("the glyph SSBO is uvec4[2] per TkzGlyphInstance, and the GLSL byte offsets are the C ones")
    func glyphInstances() throws {
        #expect(MemoryLayout<TkzGlyphInstance>.size == 32)
        let module = try Module(Int(TKZ_SPIRV_GLYPH_VERTEX))
        let r = module.reflection
        let (_, element) = try instanceBuffer(module)
        guard case let .structure(members)? = r.types[element], members.count == 1,
              case let .array(word, _)? = r.types[members[0]],
              case let .vector(component, 4)? = r.types[word] else {
            Issue.record("glyph instance is not struct { uvec4 words[2]; }")
            return
        }
        #expect(r.types[component] == .int(width: 32, signed: false))
        #expect(r.offsets(ofStruct: element) == [0])
        #expect(r.decoration(SPIRVReflection.Decoration.arrayStride, of: members[0])?.first == 16)
        #expect(r.byteSize(of: element) == MemoryLayout<TkzGlyphInstance>.size)
        #expect(arrayStride(module, ofArrayHolding: element) == MemoryLayout<TkzGlyphInstance>.stride)

        let defines = try glslDefines()
        for (define, field) in glyphFields {
            #expect(defines[define] == MemoryLayout<TkzGlyphInstance>.offset(of: field), "\(define)")
        }
    }

    @Test("descriptor sets and bindings are the C indices, and nothing else is bound")
    func bindings() throws {
        let defines = try glslDefines()
        let instanceSet = try #require(defines["TKZ_DESCRIPTOR_SET_INSTANCES"])
        let atlasSet = try #require(defines["TKZ_DESCRIPTOR_SET_ATLASES"])
        #expect(instanceSet != atlasSet)

        for shader in allShaders {
            let module = try Module(shader)
            let r = module.reflection
            let buffers = r.variables(in: SPIRVReflection.StorageClass.storageBuffer)
            let images = r.variables(in: SPIRVReflection.StorageClass.uniformConstant)
            #expect(r.variables(in: SPIRVReflection.StorageClass.uniform).isEmpty, "\(module.name): no UBOs")

            for buffer in buffers {
                #expect(r.decoration(SPIRVReflection.Decoration.descriptorSet, of: buffer.id) == [UInt32(instanceSet)])
                #expect(r.decoration(SPIRVReflection.Decoration.binding, of: buffer.id)
                        == [UInt32(TKZ_BUFFER_INDEX_INSTANCES)])
            }
            let usesInstances = [TKZ_FN_BG_FRAGMENT, TKZ_FN_RECT_VERTEX, TKZ_FN_GLYPH_VERTEX].contains(module.name)
            #expect(buffers.count == (usesInstances ? 1 : 0), "\(module.name)")

            if module.name == TKZ_FN_GLYPH_FRAGMENT {
                // Two sampled images, no samplers: GL_EXT_samplerless_texture_functions + texelFetch.
                let bindings = images.compactMap { r.decoration(SPIRVReflection.Decoration.binding, of: $0.id)?.first }
                #expect(Set(bindings) == [UInt32(TKZ_TEXTURE_INDEX_GRAYSCALE), UInt32(TKZ_TEXTURE_INDEX_COLOR)])
                for image in images {
                    #expect(r.decoration(SPIRVReflection.Decoration.descriptorSet, of: image.id) == [UInt32(atlasSet)])
                    // Dim 2D (1), not depth, not arrayed, single-sampled, sampled (1), format Unknown.
                    #expect(r.types[image.type] == .image(dim: 1, depth: 0, arrayed: 0, multisampled: 0,
                                                          sampled: 1, format: 0))
                }
            } else {
                #expect(images.isEmpty, "\(module.name): only the glyph fragment binds textures")
            }
        }
    }

    @Test("TkzShaderTypes.glsl mirrors every C constant and adds only Vulkan-side ones")
    func glslMirror() throws {
        let defines = try glslDefines()
        for (name, value) in cConstants.sorted(by: { $0.key < $1.key }) {
            #expect(defines[name] == value, "\(name)")
        }
        let vulkanOnly = Set(["TKZ_DESCRIPTOR_SET_INSTANCES", "TKZ_DESCRIPTOR_SET_ATLASES"] + glyphFields.map(\.define))
        let unknown = Set(defines.keys).subtracting(cConstants.keys).subtracting(vulkanOnly)
        #expect(unknown.isEmpty, "not in the C header: \(unknown.sorted())")
    }

    @Test("the rect fragment switch has a case for every C rect style and no other")
    func rectStyles() throws {
        let module = try Module(Int(TKZ_SPIRV_RECT_FRAGMENT))
        let switches = module.reflection.switchLiterals
        try #require(switches.count == 1)
        #expect(Set(switches[0]) == Set((0..<UInt32(TKZ_RECT_STYLE_COUNT)).map { $0 }))
        #expect(switches[0].count == Int(TKZ_RECT_STYLE_COUNT))
    }

    @Test("the generated header records the pinned glslc from docs/linux/dev.md")
    func compilerPin() throws {
        let devMD = try String(contentsOf: repoRoot.appendingPathComponent("docs/linux/dev.md"), encoding: .utf8)
        var pin: String?
        for line in devMD.split(separator: "\n") {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            if words.count >= 3, words[0] == "pin", words[1] == "glslc" {
                pin = String(words[2])
                break
            }
        }
        #expect(pin == TKZ_SPIRV_SHADERC_VERSION)
        #expect(TKZ_SPIRV_GLSLC_FLAGS.contains("--target-env=vulkan1.3"))
        #expect(TKZ_SPIRV_GLSLC_FLAGS.hasPrefix("-O "))
    }
}
