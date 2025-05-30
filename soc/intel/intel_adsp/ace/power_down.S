/* Copyright (c) 2022 Intel Corporation
 * SPDX-License-Identifier: Apache-2.0
 */

#include "asm_memory_management.h"

	.section .text, "ax"
	.align 64
power_down_literals:
	.literal_position
ipc_flag:
	.word 0x80000000 // IPC_DIPCTDR_BUSY
sram_dis_loop_cnt:
	.word 4096

	.global power_down
	.type power_down, @function

 /**
 * @brief Perform power down.
 *
 * Depending on arguments, memories are switched off.
 *
 * @param A2 - argument for LPSRAM
 * @param A3 - argument for HPSRAM
 * @param A4 - send response to ipc
 */

#define IPC_HOST_BASE			0x00073000
#define b_disable_lpsram		a2
#define b_disable_hpsram		a3
#define b_ipc_response			a4
#define temp_reg0			a6
#define temp_reg1			a7
#define temp_reg2			a8
#define temp_reg3			a9
#define temp_reg4			a10
#define temp_reg5			a11
#define temp_reg6			a12
#define p_ipc_regs			a13
#define u32_ipc_response_mask		a14
#define pfl_reg				a15

power_down:
	entry sp, 32
	/**
	 * effectively executes:
	 * xthal_dcache_region_lock(&literals, 128);
	 * xthal_icache_region_lock(&powerdown, 256);
	 */
	movi pfl_reg, power_down_literals
	dpfl pfl_reg, 0
	dpfl pfl_reg, 64

	movi pfl_reg, power_down
	ipfl pfl_reg, 0
	ipfl pfl_reg, 64
	ipfl pfl_reg, 128
	ipfl pfl_reg, 192

	/* move some values to registries before switching off whole memory */
	/* load address of DIPCTDR register */
	movi p_ipc_regs, IPC_HOST_BASE
	movi u32_ipc_response_mask, 0x20000000
#if CONFIG_XTENSA_MMU
	/**
	 * Preload the IPC register to ensure the TLB entry is present.
	 * This addresses an issue on platforms with an MMU where a
	 * LoadStoreTLBMissCause exception occurs when accessing hardware
	 * registers during the power-down process. By preloading the IPC
	 * register, we ensure that the necessary TLB entry is available,
	 * preventing a double exception (LoadStoreTLBMissCause followed by
	 * InstrPIFDataErrorCause) when accessing the IPC register after
	 * HPSRAM is powered down.
	 *
	 * Two solutions were considered:
	 * 1. Use TLB way9 to lock IPC MMIO registers (Zephyr PR80333)
	 * 2. Manually force TLB entry to be fetched in power_down (this solution)
	 *
	 * The decision was made to proceed with this solution due to its
	 * simplicity and directness, despite the potential performance benefits
	 * of the TLB way9 approach. The TLB way9 approach would also reserve
	 * way9, potentially limiting its use for other purposes in the future.
	 */
	l32i pfl_reg, p_ipc_regs, 0
#endif

_PD_DISABLE_LPSRAM:
/**
 * effectively executes:
 * if (b_disable_lpsram) {
 *     ace_lpsram_power_down_entire();
 * }
 */
	beqz b_disable_lpsram, _PD_DISABLE_HPSRAM
	m_ace_lpsram_power_down_entire temp_reg0, temp_reg1, temp_reg2, temp_reg3

_PD_DISABLE_HPSRAM:
/**
 * effectively executes:
 * if (b_disable_hpsram) {
 *     ace_hpsram_power_down_entire();
 * }
 */
	beqz b_disable_hpsram, _PD_SEND_IPC
	m_ace_hpsram_power_down_entire temp_reg0, temp_reg1, temp_reg2, temp_reg3

_PD_SEND_IPC:
	/**
	 * Send IPC to host informing of PD completion - Clear BUSY
	 * bit by writing IPC_DIPCTDR_BUSY to IPC_DIPCTDR
	 * and writing IPC_DIPCTDA_DONE to IPC_DIPCTDA
	 */

	/**
	 * effecfively executes:
	 * if (b_ipc_response)
	 * {
	 *     temp_reg0 = *p_ipc_regs;
	 *     temp_reg0 = temp_reg0 | 0x80000000;
	 *     temp_reg0 = temp_reg0 | u32_ipc_response_mask;
	 *     *(p_ipc_regs + 0x180) = 0x0;
	 *     *(p_ipc_regs + 0x10) = temp_reg0;
	 * }
	 */
	beqz b_ipc_response, _PD_SLEEP
	/* copy value from IPCxTDR */
	l32i temp_reg0, p_ipc_regs, 0
	/* set IPC Busy bit to 1 */
	movi temp_reg1, 1
	slli temp_reg1, temp_reg1, 31
	or temp_reg0, temp_reg0, temp_reg1
	/* mark the message as a reply */
	or temp_reg0, temp_reg0, u32_ipc_response_mask
	/* clear IPCxIDD i.e. message extension */
	movi temp_reg1, 0
	s32i temp_reg1, p_ipc_regs, 0x180
	/* write response to IPCxIDR */
	s32i temp_reg0, p_ipc_regs, 0x10

_PD_SLEEP:
/* effecfively executes:
 * xmp_spin()
 * waiti 5
 */
	movi temp_reg0, 128
loop:
	addi temp_reg0, temp_reg0, -1
	bnez temp_reg0, loop

	extw
	extw
	waiti 5
	1:
	j 1b

.size power_down , . - power_down
