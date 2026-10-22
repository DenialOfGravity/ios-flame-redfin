/* GMU firmware for the GPU probe (stock vendor.img, never commit it). */
#ifdef SHIM_GPUPROBE
	.section .rodata
	.balign 16
	.global gmu_fw, gmu_fw_end
gmu_fw:
	.incbin "../research/gpu/fw/a640_gmu.bin"
gmu_fw_end:
#endif
#ifdef SHIM_GPUPROBE
	.balign 16
	.global zap_mdt, zap_mdt_end, zap_b02, zap_b02_end
zap_mdt:
	.incbin "../research/gpu/fw/a640_zap.mdt"
zap_mdt_end:
	.balign 16
zap_b02:
	.incbin "../research/gpu/fw/a640_zap.b02"
zap_b02_end:
#endif
#ifdef SHIM_GPUPROBE
	.balign 16
	.global sqe_fw, sqe_fw_end
sqe_fw:
	.incbin "../research/gpu/fw/a630_sqe.fw"
sqe_fw_end:
#endif
