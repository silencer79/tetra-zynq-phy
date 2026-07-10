# Makefile for TETRA PHY Software
#
# Cross-compilation for ARM (Zynq)
#
# Usage:
#   make              # Build userspace tools
#   make module       # Build kernel module
#   make install      # Install to /lib/modules/$(KERNELRELEASE)/extra/
#   make clean        # Clean build artifacts

# Kernel sources (adjust for your build machine)
KERNEL_SRC ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

# Cross-compilation settings (for ARM)
ARCH ?= arm
CROSS_COMPILE ?= arm-linux-gnueabihf-
CC = $(CROSS_COMPILE)gcc
CFLAGS = -Wall -Wextra -O2 -march=armv7-a -static

# Module name
obj-m += tetra_char_dev.o

# Compiler flags for kernel module
ccflags-y := -Wall -Werror

# =============================================================================
# Build Targets
# =============================================================================

all: tetra_sysinfo tetra_ul_mon tetra_attach_daemon

tetra_sysinfo: tetra_hal.c tetra_hal.h
	$(CC) $(CFLAGS) -o $@ $<

tetra_ul_mon: tetra_ul_mon.c tetra_hal.h
	$(CC) $(CFLAGS) -o $@ $<

ETSI_CODEC_SRC = etsi_codec/sub_cc.c etsi_codec/sub_cd.c \
                 etsi_codec/ccod_tet.c etsi_codec/cdec_tet.c \
                 etsi_codec/tetra_op.c etsi_codec/arrays_globals.c

tetra_attach_daemon: tetra_attach_daemon.c tetra_db.c tetra_db.h \
                     tetra_tx_transport.c tetra_tx_transport.h \
                     tetra_grpack_body.c tetra_grpack_body.h \
                     tetra_cmce_body.c tetra_cmce_body.h \
                     tetra_cmce_parser.c tetra_cmce_parser.h \
                     tetra_call_fsm.c tetra_call_fsm.h \
                     tetra_mm_demand_parser.c tetra_mm_demand_parser.h \
                     tetra_voice_filler.c tetra_voice_filler.h \
                     tetra_voice_pipe.c tetra_voice_pipe.h \
                     tetra_sds_dl_frag.c tetra_sds_dl_frag.h \
                     tetra_channel_codec.c tetra_channel_codec.h \
                     tetra_tch_s_codec.c tetra_tch_s_codec.h \
                     tetra_etsi_tch_s.c tetra_etsi_tch_s.h \
                     tetra_bs_tch_s.c tetra_bs_tch_s.h \
                     tetra_ul_rx_service.c tetra_ul_rx_service.h \
                     tetra_ul_reassembly.c tetra_ul_reassembly.h \
                     tetra_ul_mac_parse.c tetra_ul_mac_parse.h \
                     tetra_ul_rx_mailbox.c tetra_ul_rx_mailbox.h \
                     $(ETSI_CODEC_SRC) etsi_codec/channel.h \
                     tetra_hal.h
	$(CC) $(CFLAGS) -Ietsi_codec -o $@ tetra_attach_daemon.c tetra_db.c \
		tetra_tx_transport.c tetra_grpack_body.c tetra_cmce_body.c \
		tetra_cmce_parser.c tetra_call_fsm.c tetra_mm_demand_parser.c \
		tetra_voice_filler.c tetra_voice_pipe.c tetra_sds_dl_frag.c tetra_channel_codec.c \
		tetra_tch_s_codec.c tetra_etsi_tch_s.c tetra_bs_tch_s.c \
		tetra_ul_rx_service.c tetra_ul_reassembly.c tetra_ul_mac_parse.c \
		tetra_ul_rx_mailbox.c \
		$(ETSI_CODEC_SRC)

# Host-side regression for tetra_grpack_build() — built with the host gcc
# (NOT the cross-compiler) so it runs on the build machine.  Run via
# `make test`.
test_grpack: test_grpack_body.c tetra_grpack_body.c tetra_grpack_body.h
	gcc -Wall -Werror -O2 -o /tmp/test_grpack \
		test_grpack_body.c tetra_grpack_body.c

test_cmce_parser: test_cmce_parser.c tetra_cmce_parser.c tetra_cmce_parser.h
	gcc -Wall -Werror -O2 -o /tmp/test_cmce_parser \
		test_cmce_parser.c tetra_cmce_parser.c

test_cmce_body: test_cmce_body.c tetra_cmce_body.c tetra_cmce_body.h
	gcc -Wall -Werror -O2 -o /tmp/test_cmce_body \
		test_cmce_body.c tetra_cmce_body.c

test_schf_rt: test_schf_roundtrip.c tetra_channel_codec.c tetra_channel_codec.h
	gcc -Wall -Werror -O2 -o /tmp/test_schf_rt \
		test_schf_roundtrip.c tetra_channel_codec.c

test_schhu_rt: test_schhu_roundtrip.c tetra_channel_codec.c tetra_channel_codec.h
	gcc -Wall -Werror -O2 -o /tmp/test_schhu_rt \
		test_schhu_roundtrip.c tetra_channel_codec.c

test_ul_soft: test_soft_gain.c tetra_channel_codec.c tetra_channel_codec.h
	gcc -Wall -Werror -O2 -o /tmp/test_ul_soft \
		test_soft_gain.c tetra_channel_codec.c -lm

test_ul_reass: test_ul_reass.c tetra_ul_reassembly.c tetra_ul_reassembly.h
	gcc -Wall -Werror -O2 -o /tmp/test_ul_reass \
		test_ul_reass.c tetra_ul_reassembly.c

test_ul_lsds: test_ul_lsds.c tetra_ul_reassembly.c tetra_ul_reassembly.h
	gcc -Wall -Werror -O2 -o /tmp/test_ul_lsds \
		test_ul_lsds.c tetra_ul_reassembly.c

test_ul_rx_mb: test_ul_rx_mailbox.c tetra_ul_rx_mailbox.c tetra_ul_rx_mailbox.h \
		tetra_channel_codec.c tetra_channel_codec.h
	gcc -Wall -Werror -O2 -o /tmp/test_ul_rx_mb \
		test_ul_rx_mailbox.c tetra_ul_rx_mailbox.c tetra_channel_codec.c

test_ul_mac_parse: test_ul_mac_parse.c tetra_ul_mac_parse.c tetra_ul_mac_parse.h
	gcc -Wall -Werror -O2 -o /tmp/test_ul_mac_parse \
		test_ul_mac_parse.c tetra_ul_mac_parse.c

test_ul_rx_service: test_ul_rx_service.c tetra_ul_rx_service.c tetra_ul_reassembly.c \
		tetra_ul_mac_parse.c tetra_ul_rx_mailbox.c tetra_channel_codec.c
	gcc -Wall -Werror -O2 -o /tmp/test_ul_rx_service \
		test_ul_rx_service.c tetra_ul_rx_service.c tetra_ul_reassembly.c \
		tetra_ul_mac_parse.c tetra_ul_rx_mailbox.c tetra_channel_codec.c

# Phase-1 ECHT-LUFT: SW-SCH/HU-Decode == Referenz auf einem realen UL-WAV.
# Kette: gen_ul_wav_iq_stim (WAV align + Referenz-Decode) → phase1_dump_soft
# (RTL-emulierter Soft) → SW-Decode-Vergleich. Braucht python3+numpy+scipy.
UL_WAV ?= wavs/local_cell_425-440mhz/UL_baseband_430650000Hz_21-13-38_21-06-2026.wav
test_ul_realair: test_ul_realair.c tetra_channel_codec.c tetra_channel_codec.h
	cd .. && python3 scripts/gen_ul_wav_iq_stim.py $(UL_WAV)
	cd .. && python3 scripts/phase1_dump_soft.py
	gcc -Wall -Werror -O2 -o /tmp/test_ul_realair test_ul_realair.c tetra_channel_codec.c
	cd .. && /tmp/test_ul_realair sim_out/ul_wav_soft.hex sim_out/ul_wav_exp.hex

# RTL-Paritaet: SW-SCH/HU-Soft-Decode == RTL-TB-Vektoren (tb_ul_sch_hu_decoder.v).
# Regeneriert den Vektor deterministisch (python3+numpy) → getrennt vom pure-C 'test'.
test_ul_parity: test_ul_rtl_parity.c tetra_channel_codec.c tetra_channel_codec.h
	python3 ../scripts/gen_sch_hu_tv.py --out-dir ../sim_out
	gcc -Wall -Werror -O2 -o /tmp/test_ul_rtl_parity \
		test_ul_rtl_parity.c tetra_channel_codec.c
	/tmp/test_ul_rtl_parity ../sim_out/ul_sch_hu_soft.hex ../sim_out/ul_sch_hu_exp.hex

test: test_grpack test_cmce_parser test_cmce_body test_schf_rt test_schhu_rt test_ul_soft test_ul_reass test_ul_lsds test_ul_rx_mb test_ul_mac_parse test_ul_rx_service
	/tmp/test_grpack
	/tmp/test_cmce_parser
	/tmp/test_cmce_body
	/tmp/test_schf_rt
	/tmp/test_schhu_rt
	/tmp/test_ul_soft
	/tmp/test_ul_reass
	/tmp/test_ul_lsds
	/tmp/test_ul_rx_mb
	/tmp/test_ul_mac_parse
	/tmp/test_ul_rx_service

module:
	$(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) \
		-C $(KERNEL_SRC) M=$(PWD) modules

install:
	$(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) \
		-C $(KERNEL_SRC) M=$(PWD) modules_install

clean:
	rm -f tetra_sysinfo tetra_ul_mon tetra_attach_daemon
	rm -f /tmp/test_grpack /tmp/test_cmce_parser /tmp/test_cmce_body
	$(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) \
		-C $(KERNEL_SRC) M=$(PWD) clean 2>/dev/null || true
	rm -f Module.symvers modules.order

# =============================================================================
# Development Targets
# =============================================================================

# Load module (requires root)
load:
	insmod tetra_char_dev.ko

# Unload module (requires root)
unload:
	rmmod tetra_char_dev

# Check module info
info:
	modinfo tetra_char_dev.ko

# Device tree node for testing (append to your .dts)
dt-node:
	@echo "Add the following node to your device tree:"
	@echo ""
	@echo "tetra_phy: tetra-phy@40000000 {"
	@echo "    compatible = \"midnightblue,tetra-phy\";"
	@echo "    reg = <0x40000000 0x10000>;"
	@echo "    status = \"okay\";"
	@echo "};"

.PHONY: all modules install clean load unload info dt-node test \
        test_grpack test_cmce_parser test_cmce_body
