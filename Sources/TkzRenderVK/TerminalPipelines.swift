// TerminalPipelines — the three Vulkan pipelines of the terminal renderer (WOR-313 S4b), built from
// the committed SPIR-V (TkzShadersSPIRV) and the binding contract in TkzShaderTypes.glsl.
//
//   background   full-screen triangle (TRIANGLE_LIST × 3), blending OFF
//   rect         instanced TRIANGLE_STRIP × 4, premultiplied ONE / ONE_MINUS_SRC_ALPHA
//   glyph        instanced TRIANGLE_STRIP × 4, premultiplied ONE / ONE_MINUS_SRC_ALPHA
//
// The same blend state as the Metal descriptor (TerminalRenderer.swift), for colour and alpha. The
// colour format is B8G8R8A8_UNORM, never _SRGB: blending is gamma-space, as on the Mac (ADR-0003).
// All three are vertex-input-free, use dynamic rendering (no VkRenderPass), and take the viewport
// and scissor as dynamic state, since every pane draws into its own rect of a shared target.
//
// One pipeline layout serves all three, so push constants and bound sets survive pipeline changes:
//   push constants  the whole 80-byte `TkzUniforms`, vertex and fragment stages
//   set 0           binding `TKZ_BUFFER_INDEX_INSTANCES`: the pass's instance storage buffer
//   set 1           bindings `TKZ_TEXTURE_INDEX_*`: both atlases as sampled images (no sampler; the
//                   shaders use `texelFetch`), bound for the glyph pass
//
// Not `Sendable`; lives with the renderer.

import CVulkan
import TkzShaderTypes
import TkzShadersSPIRV

/// The descriptor-set numbers, `TKZ_DESCRIPTOR_SET_*` in TkzShaderTypes.glsl. The C header has no
/// sets (Metal has none); a mismatch with the SPIR-V is a validation error at pipeline creation.
enum TerminalDescriptorSet {
    static let instances: UInt32 = 0
    static let atlases: UInt32 = 1
}

final class TerminalPipelines {
    /// The colour attachment format every pipeline renders to.
    static let colorFormat = VK_FORMAT_B8G8R8A8_UNORM
    /// Push-constant range: all of `TkzUniforms`.
    static let pushConstantSize = UInt32(MemoryLayout<TkzUniforms>.size)
    static let pushConstantStages = VkShaderStageFlags(VK_SHADER_STAGE_VERTEX_BIT.rawValue | VK_SHADER_STAGE_FRAGMENT_BIT.rawValue)

    let device: VulkanDevice
    let instanceSetLayout: VkDescriptorSetLayout
    let atlasSetLayout: VkDescriptorSetLayout
    let layout: VkPipelineLayout
    let background: VkPipeline
    let rect: VkPipeline
    let glyph: VkPipeline

    init(device: VulkanDevice) throws {
        let vk = device.handle
        var cleanup: [() -> Void] = []
        var committed = false
        defer { if !committed { cleanup.reversed().forEach { $0() } } }

        // Set 0: the instance buffer. The bg pass reads it in the fragment stage, the others in
        // the vertex stage.
        let instanceSetLayout = try Self.makeSetLayout(vk, bindings: [
            Self.binding(UInt32(TKZ_BUFFER_INDEX_INSTANCES), VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, Self.pushConstantStages),
        ])
        cleanup.append { vkDestroyDescriptorSetLayout(vk, instanceSetLayout, nil) }
        // Set 1: both atlases, always (as on Metal, where an unbound declared texture faults).
        let fragment = VkShaderStageFlags(VK_SHADER_STAGE_FRAGMENT_BIT.rawValue)
        let atlasSetLayout = try Self.makeSetLayout(vk, bindings: [
            Self.binding(UInt32(TKZ_TEXTURE_INDEX_GRAYSCALE), VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, fragment),
            Self.binding(UInt32(TKZ_TEXTURE_INDEX_COLOR), VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, fragment),
        ])
        cleanup.append { vkDestroyDescriptorSetLayout(vk, atlasSetLayout, nil) }

        var layoutInfo = VkPipelineLayoutCreateInfo()
        layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        var range = VkPushConstantRange(stageFlags: Self.pushConstantStages, offset: 0, size: Self.pushConstantSize)
        let setLayouts: [VkDescriptorSetLayout?] = [instanceSetLayout, atlasSetLayout]
        var pipelineLayout: VkPipelineLayout?
        let layoutResult = setLayouts.withUnsafeBufferPointer { setLayouts in
            withUnsafePointer(to: &range) { range in
                layoutInfo.setLayoutCount = UInt32(setLayouts.count)
                layoutInfo.pSetLayouts = setLayouts.baseAddress
                layoutInfo.pushConstantRangeCount = 1
                layoutInfo.pPushConstantRanges = range
                return vkCreatePipelineLayout(vk, &layoutInfo, nil, &pipelineLayout)
            }
        }
        try vkCheck(layoutResult, "vkCreatePipelineLayout")
        guard let pipelineLayout else { throw VulkanError("vkCreatePipelineLayout", VK_ERROR_INITIALIZATION_FAILED) }
        cleanup.append { vkDestroyPipelineLayout(vk, pipelineLayout, nil) }

        // The six modules are needed only while the pipelines are created.
        var modules: [TkzSPIRVShader: VkShaderModule] = [:]
        defer { modules.values.forEach { vkDestroyShaderModule(vk, $0, nil) } }
        for shader in TkzSPIRVShader(0)..<TkzSPIRVShader(TKZ_SPIRV_SHADER_COUNT) {
            modules[shader] = try Self.makeModule(vk, shader)
        }
        func pipeline(_ vertex: Int, _ fragment: Int, topology: VkPrimitiveTopology, blending: Bool) throws -> VkPipeline {
            guard let vertexModule = modules[TkzSPIRVShader(vertex)], let fragmentModule = modules[TkzSPIRVShader(fragment)] else {
                throw VulkanError("TerminalPipelines (missing SPIR-V module)", VK_ERROR_INITIALIZATION_FAILED)
            }
            let made = try Self.makePipeline(vk, layout: pipelineLayout, vertex: vertexModule, fragment: fragmentModule,
                                             topology: topology, blending: blending)
            cleanup.append { vkDestroyPipeline(vk, made, nil) }
            return made
        }
        let background = try pipeline(TKZ_SPIRV_BG_VERTEX, TKZ_SPIRV_BG_FRAGMENT, topology: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, blending: false)
        let rect = try pipeline(TKZ_SPIRV_RECT_VERTEX, TKZ_SPIRV_RECT_FRAGMENT, topology: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, blending: true)
        let glyph = try pipeline(TKZ_SPIRV_GLYPH_VERTEX, TKZ_SPIRV_GLYPH_FRAGMENT, topology: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, blending: true)

        self.device = device
        self.instanceSetLayout = instanceSetLayout
        self.atlasSetLayout = atlasSetLayout
        self.layout = pipelineLayout
        self.background = background
        self.rect = rect
        self.glyph = glyph
        committed = true
    }

    deinit {
        // Recorded frames may still reference the pipelines; dropping a renderer is rare.
        let vk = device.handle
        vkQueueWaitIdle(device.queue)
        for pipeline in [background, rect, glyph] { vkDestroyPipeline(vk, pipeline, nil) }
        vkDestroyPipelineLayout(vk, layout, nil)
        vkDestroyDescriptorSetLayout(vk, atlasSetLayout, nil)
        vkDestroyDescriptorSetLayout(vk, instanceSetLayout, nil)
    }

    // MARK: - Builders

    private static func binding(
        _ index: UInt32, _ type: VkDescriptorType, _ stages: VkShaderStageFlags
    ) -> VkDescriptorSetLayoutBinding {
        VkDescriptorSetLayoutBinding(binding: index, descriptorType: type, descriptorCount: 1, stageFlags: stages,
                                     pImmutableSamplers: nil)
    }

    private static func makeSetLayout(_ vk: VkDevice, bindings: [VkDescriptorSetLayoutBinding]) throws -> VkDescriptorSetLayout {
        var layout: VkDescriptorSetLayout?
        let result = bindings.withUnsafeBufferPointer { bindings in
            var info = VkDescriptorSetLayoutCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
            info.bindingCount = UInt32(bindings.count)
            info.pBindings = bindings.baseAddress
            return vkCreateDescriptorSetLayout(vk, &info, nil, &layout)
        }
        try vkCheck(result, "vkCreateDescriptorSetLayout")
        guard let layout else { throw VulkanError("vkCreateDescriptorSetLayout", VK_ERROR_INITIALIZATION_FAILED) }
        return layout
    }

    private static func makeModule(_ vk: VkDevice, _ shader: TkzSPIRVShader) throws -> VkShaderModule {
        guard let spirv = tkz_spirv_module(shader)?.pointee else {
            throw VulkanError("tkz_spirv_module(\(shader))", VK_ERROR_INITIALIZATION_FAILED)
        }
        var info = VkShaderModuleCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
        info.codeSize = spirv.codeSize
        info.pCode = spirv.code
        var module: VkShaderModule?
        try vkCheck(vkCreateShaderModule(vk, &info, nil, &module), "vkCreateShaderModule(\(String(cString: spirv.metalFunction)))")
        guard let module else { throw VulkanError("vkCreateShaderModule", VK_ERROR_INITIALIZATION_FAILED) }
        return module
    }

    private static func makePipeline(
        _ vk: VkDevice, layout: VkPipelineLayout, vertex: VkShaderModule, fragment: VkShaderModule,
        topology: VkPrimitiveTopology, blending: Bool
    ) throws -> VkPipeline {
        var arena = VulkanArena()
        let entryPoint = arena.cString(TKZ_SPIRV_ENTRY_POINT)
        func stage(_ bit: VkShaderStageFlagBits, _ module: VkShaderModule) -> VkPipelineShaderStageCreateInfo {
            var info = VkPipelineShaderStageCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
            info.stage = bit
            info.module = module
            info.pName = entryPoint
            return info
        }
        let stages = arena.array([stage(VK_SHADER_STAGE_VERTEX_BIT, vertex), stage(VK_SHADER_STAGE_FRAGMENT_BIT, fragment)])

        // Quads come from gl_VertexIndex and gl_InstanceIndex: nothing to describe.
        var vertexInput = VkPipelineVertexInputStateCreateInfo()
        vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO

        var inputAssembly = VkPipelineInputAssemblyStateCreateInfo()
        inputAssembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
        inputAssembly.topology = topology

        // Viewport and scissor are dynamic; only their counts are fixed.
        var viewport = VkPipelineViewportStateCreateInfo()
        viewport.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
        viewport.viewportCount = 1
        viewport.scissorCount = 1

        // No culling: the bg triangle's winding is the mirror of Metal's (tkz_bg_vertex).
        var rasterization = VkPipelineRasterizationStateCreateInfo()
        rasterization.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
        rasterization.polygonMode = VK_POLYGON_MODE_FILL
        rasterization.cullMode = VkCullModeFlags(VK_CULL_MODE_NONE.rawValue)
        rasterization.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE
        rasterization.lineWidth = 1

        var multisample = VkPipelineMultisampleStateCreateInfo()
        multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
        multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT

        // Every fragment function returns premultiplied colour.
        var attachment = VkPipelineColorBlendAttachmentState()
        attachment.blendEnable = VkBool32(blending ? VK_TRUE : VK_FALSE)
        attachment.srcColorBlendFactor = VK_BLEND_FACTOR_ONE
        attachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
        attachment.colorBlendOp = VK_BLEND_OP_ADD
        attachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE
        attachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
        attachment.alphaBlendOp = VK_BLEND_OP_ADD
        attachment.colorWriteMask = VkColorComponentFlags(VK_COLOR_COMPONENT_R_BIT.rawValue | VK_COLOR_COMPONENT_G_BIT.rawValue
            | VK_COLOR_COMPONENT_B_BIT.rawValue | VK_COLOR_COMPONENT_A_BIT.rawValue)
        var colorBlend = VkPipelineColorBlendStateCreateInfo()
        colorBlend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
        colorBlend.attachmentCount = 1
        colorBlend.pAttachments = UnsafePointer(arena.pointer(attachment))

        let dynamicStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]
        var dynamic = VkPipelineDynamicStateCreateInfo()
        dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
        dynamic.dynamicStateCount = UInt32(dynamicStates.count)
        dynamic.pDynamicStates = UnsafePointer(arena.array(dynamicStates))

        var rendering = VkPipelineRenderingCreateInfo()
        rendering.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO
        rendering.colorAttachmentCount = 1
        rendering.pColorAttachmentFormats = UnsafePointer(arena.pointer(colorFormat))

        var info = VkGraphicsPipelineCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
        info.pNext = UnsafeRawPointer(arena.pointer(rendering))
        info.stageCount = 2
        info.pStages = UnsafePointer(stages)
        info.pVertexInputState = UnsafePointer(arena.pointer(vertexInput))
        info.pInputAssemblyState = UnsafePointer(arena.pointer(inputAssembly))
        info.pViewportState = UnsafePointer(arena.pointer(viewport))
        info.pRasterizationState = UnsafePointer(arena.pointer(rasterization))
        info.pMultisampleState = UnsafePointer(arena.pointer(multisample))
        info.pColorBlendState = UnsafePointer(arena.pointer(colorBlend))
        info.pDynamicState = UnsafePointer(arena.pointer(dynamic))
        info.layout = layout

        var pipeline: VkPipeline?
        try vkCheck(vkCreateGraphicsPipelines(vk, nil, 1, &info, nil, &pipeline), "vkCreateGraphicsPipelines")
        guard let pipeline else { throw VulkanError("vkCreateGraphicsPipelines", VK_ERROR_INITIALIZATION_FAILED) }
        return pipeline
    }
}

// MARK: - Per-slot descriptor sets

/// The descriptor sets one `FrameRing` slot draws with: one instance set per `SlotBuffer` role and
/// one atlas set. Per slot, because a set must not be updated while a pending command buffer uses
/// it, and the slot's fence (waited in `acquire`) is exactly the proof that its last frame is done.
/// Every encoded frame rewrites the sets it binds, before recording any bind: a handful of
/// descriptor writes, and no stale handle can survive a buffer grow or an atlas replacement.
final class FrameDescriptors {
    /// The instance roles a frame binds (the staging buffer is never bound).
    static let roles: [SlotBuffer] = [.background, .rectsBelow, .glyphs, .rectsAbove]

    let device: VulkanDevice
    /// The pipelines whose set layouts these were allocated with.
    let pipelines: ObjectIdentifier
    private let pool: VkDescriptorPool
    private let instanceSets: [SlotBuffer: VkDescriptorSet]
    private let atlasSet: VkDescriptorSet

    init(device: VulkanDevice, pipelines: TerminalPipelines) throws {
        let vk = device.handle
        let sizes = [
            VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, descriptorCount: UInt32(Self.roles.count)),
            VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, descriptorCount: 2),
        ]
        var pool: VkDescriptorPool?
        let poolResult = sizes.withUnsafeBufferPointer { sizes in
            var info = VkDescriptorPoolCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
            info.maxSets = UInt32(Self.roles.count + 1)
            info.poolSizeCount = UInt32(sizes.count)
            info.pPoolSizes = sizes.baseAddress
            return vkCreateDescriptorPool(vk, &info, nil, &pool)
        }
        try vkCheck(poolResult, "vkCreateDescriptorPool")
        guard let pool else { throw VulkanError("vkCreateDescriptorPool", VK_ERROR_INITIALIZATION_FAILED) }

        // Destroying the pool frees its sets.
        let layouts: [VkDescriptorSetLayout?] = Array(repeating: pipelines.instanceSetLayout, count: Self.roles.count)
            + [pipelines.atlasSetLayout]
        var sets = [VkDescriptorSet?](repeating: nil, count: layouts.count)
        let allocateResult = layouts.withUnsafeBufferPointer { layouts in
            var info = VkDescriptorSetAllocateInfo()
            info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
            info.descriptorPool = pool
            info.descriptorSetCount = UInt32(layouts.count)
            info.pSetLayouts = layouts.baseAddress
            return vkAllocateDescriptorSets(vk, &info, &sets)
        }
        let handles = sets.compactMap { $0 }
        guard allocateResult == VK_SUCCESS, handles.count == layouts.count else {
            vkDestroyDescriptorPool(vk, pool, nil)
            throw VulkanError("vkAllocateDescriptorSets", allocateResult == VK_SUCCESS ? VK_ERROR_INITIALIZATION_FAILED : allocateResult)
        }

        self.device = device
        self.pipelines = ObjectIdentifier(pipelines)
        self.pool = pool
        self.instanceSets = Dictionary(uniqueKeysWithValues: zip(Self.roles, handles))
        self.atlasSet = handles[Self.roles.count]
    }

    deinit {
        // Only ever dropped with its slot, after the ring has waited for the slot's fence.
        vkDestroyDescriptorPool(device.handle, pool, nil)
    }

    /// Points the instance set of each role in `buffers` at its buffer, and the atlas set at
    /// `atlases` (grayscale, colour), in one `vkUpdateDescriptorSets`. Returns the sets to bind.
    func update(
        buffers: [SlotBuffer: VkBuffer], atlases: (grayscale: VkImageView, color: VkImageView)
    ) -> (instances: [SlotBuffer: VkDescriptorSet], atlases: VkDescriptorSet) {
        var arena = VulkanArena()
        var writes: [VkWriteDescriptorSet] = []
        for (role, buffer) in buffers {
            guard let set = instanceSets[role] else { continue }
            var write = VkWriteDescriptorSet()
            write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
            write.dstSet = set
            write.dstBinding = UInt32(TKZ_BUFFER_INDEX_INSTANCES)
            write.descriptorCount = 1
            write.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
            write.pBufferInfo = UnsafePointer(arena.pointer(
                VkDescriptorBufferInfo(buffer: buffer, offset: 0, range: VkDeviceSize(VK_WHOLE_SIZE))))
            writes.append(write)
        }
        for (binding, view) in [(TKZ_TEXTURE_INDEX_GRAYSCALE, atlases.grayscale), (TKZ_TEXTURE_INDEX_COLOR, atlases.color)] {
            var write = VkWriteDescriptorSet()
            write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
            write.dstSet = atlasSet
            write.dstBinding = UInt32(binding)
            write.descriptorCount = 1
            write.descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE
            write.pImageInfo = UnsafePointer(arena.pointer(
                VkDescriptorImageInfo(sampler: nil, imageView: view, imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)))
            writes.append(write)
        }
        writes.withUnsafeBufferPointer { writes in
            vkUpdateDescriptorSets(device.handle, UInt32(writes.count), writes.baseAddress, 0, nil)
        }
        return (instanceSets.filter { buffers[$0.key] != nil }, atlasSet)
    }
}

// MARK: - Arena

/// Heap copies of the structs and arrays one create call points at, freed together when the arena
/// is dropped, so a struct with many nested pointers needs no nested `withUnsafe…` scopes (the
/// same idea as `VulkanChain`, without the pNext linking).
struct VulkanArena: ~Copyable {
    private var allocations: [(pointer: UnsafeMutableRawPointer, release: (UnsafeMutableRawPointer) -> Void)] = []

    init() {}

    /// A copy of `value` that lives as long as the arena.
    mutating func pointer<Value>(_ value: Value) -> UnsafeMutablePointer<Value> {
        array([value])
    }

    /// A copy of `values`, contiguous, that lives as long as the arena.
    mutating func array<Value>(_ values: [Value]) -> UnsafeMutablePointer<Value> {
        let pointer = UnsafeMutablePointer<Value>.allocate(capacity: max(values.count, 1))
        _ = UnsafeMutableBufferPointer(start: pointer, count: values.count).initialize(from: values)
        let count = values.count
        allocations.append((UnsafeMutableRawPointer(pointer), {
            $0.assumingMemoryBound(to: Value.self).deinitialize(count: count).deallocate()
        }))
        return pointer
    }

    /// A NUL-terminated copy of `string`.
    mutating func cString(_ string: String) -> UnsafePointer<CChar> {
        UnsafePointer(array(Array(string.utf8CString)))
    }

    deinit {
        for allocation in allocations { allocation.release(allocation.pointer) }
    }
}
