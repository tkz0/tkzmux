// RenderTarget — what a `VulkanTerminalRenderer` frame draws into (WOR-313 S4b).
//
// A B8G8R8A8_UNORM colour image with COLOR_ATTACHMENT usage, its view, its size, and its current
// layout. The layout is tracked on the target, not in the renderer, because several recorders touch
// the same image in turn: every pane's frame (each from its own surface's `FrameRing` slot), the
// readback, and later the presentation ring's queue-family transfers (WOR-313 S5a). Each records
// a barrier from the tracked layout and leaves the new one behind. One queue executes the
// submissions in order, so the layout at record time is the layout at execution time, as long as
// everything is submitted in the order it was recorded (the renderer submits each frame at once).
//
// `OffscreenTarget` is one (headless, tests, vtdump, the readback rung of S5b); the exportable
// dmabuf images of S5a are the other.

import CVulkan

public protocol VulkanRenderTarget: AnyObject {
    var image: VkImage { get }
    var view: VkImageView { get }
    var width: UInt32 { get }
    var height: UInt32 { get }
    /// The layout the last recorded command left the image in. UNDEFINED until the first.
    var layout: VkImageLayout { get set }
}

/// The source scope of a barrier on an image last left in `layout` by tkzmux's own commands: the
/// stage and write that produced that layout. Reads (a readback) need only the execution
/// dependency, so their access is NONE.
func lastAccess(of layout: VkImageLayout) -> VulkanScope {
    switch layout {
    case VK_IMAGE_LAYOUT_UNDEFINED:
        (VK_PIPELINE_STAGE_2_NONE, VK_ACCESS_2_NONE)
    case VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL:
        (VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT)
    case VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL:
        (VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_NONE)
    default:
        (VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, VK_ACCESS_2_MEMORY_WRITE_BIT)
    }
}
