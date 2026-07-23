* n64 mupen gles3 core seems to play fast and the audio crackles a lot
    * needs an on-device session: check retro_get_system_av_info fps vs the
      emulation-thread pacing, and whether GL HW-render frame delivery bypasses
      the frame-duration accumulator on Android
* These errors show up for validation with vulkan, tested with the azahar core
[SK::VulkanContext::Init::<lambda_1>::operator ()] VkValidation: vkQueueSubmit(): pSubmits[0] command buffer VkCommandBuffer 0x1c5ac5470d0 expects VkImage 0x100000000010 (subresource: aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, mipLevel = 0, arrayLayer = 0) to be in layout VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL--instead, current layout is VK_IMAGE_LAYOUT_UNDEFINED.
The Vulkan spec states: If a descriptor with type equal to any of VK_DESCRIPTOR_TYPE_SAMPLE_WEIGHT_IMAGE_QCOM, VK_DESCRIPTOR_TYPE_BLOCK_MATCH_IMAGE_QCOM, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, or VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT is accessed as a result of this command, all image subresources identified by that descriptor must be in the image layout identified when the descriptor was written (https://docs.vulkan.org/spec/latest/chapters/drawing.html#VUID-vkCmdDraw-None-09600)
[SK::VulkanContext::Init::<lambda_1>::operator ()] VkValidation: vkCmdBindIndexBuffer(): indexType is VK_INDEX_TYPE_UINT8 but indexTypeUint8 feature was not enabled.
The Vulkan spec states: If indexType is VK_INDEX_TYPE_UINT8, the indexTypeUint8 feature must be enabled (https://docs.vulkan.org/spec/latest/chapters/drawing.html#VUID-vkCmdBindIndexBuffer-indexType-08787)

* I don't see the model loaded for the playstation original or the DS Lite and Mega drive (i do see for genesis)
* when downloading the media from screenscraper (manual, box, etc), it should show  a notification (that also stacks up) just like where it shows Hashing ROM
* when opening up the system menu for the first time, it looks like it is 'moving' for a very brief second to where it needs to be

# GBA

* the power light doesn't come on when it is turned on
* the power switch doesn't slide to on when it is slide
* the buttons don't seem to animate

# 3DS

* The texture on the 3DS Shell appears off for some reason?
* Closing the lid with the hindge back to 0 deg, doesnt look flush, nor does it look like it's on the right pivot

# DS Phat

* The cartridge appears to stick out when it is placed in and it doesn't appear to go in the slot right

# Genesis / Mega Drive


# Core-Info Known Issues

As this is a submodule, we need to somehow upstream the issues we found

* There is an insconsistency with the `systemname` "C64" where the corrisponding `systemid` is called either "commodore_c64" or "commodore_64"
