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
                     tetra_mac_resource_dl_builder.c tetra_mac_resource_dl_builder.h \
                     tetra_sch_f_encoder.c tetra_sch_f_encoder.h \
                     tetra_dl_pdu.c tetra_dl_pdu.h \
                     tetra_voice_filler.c tetra_voice_filler.h \
                     tetra_voice_pipe.c tetra_voice_pipe.h \
                     tetra_channel_codec.c tetra_channel_codec.h \
                     tetra_tch_s_codec.c tetra_tch_s_codec.h \
                     tetra_etsi_tch_s.c tetra_etsi_tch_s.h \
                     tetra_bs_tch_s.c tetra_bs_tch_s.h \
                     $(ETSI_CODEC_SRC) etsi_codec/channel.h \
                     tetra_hal.h
	$(CC) $(CFLAGS) -Ietsi_codec -o $@ tetra_attach_daemon.c tetra_db.c \
		tetra_tx_transport.c tetra_grpack_body.c tetra_cmce_body.c \
		tetra_cmce_parser.c tetra_call_fsm.c tetra_mm_demand_parser.c \
		tetra_mac_resource_dl_builder.c tetra_sch_f_encoder.c \
		tetra_dl_pdu.c \
		tetra_voice_filler.c tetra_voice_pipe.c tetra_channel_codec.c \
		tetra_tch_s_codec.c tetra_etsi_tch_s.c tetra_bs_tch_s.c \
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

test: test_grpack test_cmce_parser test_cmce_body
	/tmp/test_grpack
	/tmp/test_cmce_parser
	/tmp/test_cmce_body

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
