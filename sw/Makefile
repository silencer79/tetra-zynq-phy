# Makefile for TETRA FPGA Character Device Driver
#
# Cross-compilation for ARM (Zynq)
#
# Usage:
#   make              # Build kernel module
#   make install      # Install to /lib/modules/$(KERNELRELEASE)/extra/
#   make clean        # Clean build artifacts

# Kernel sources (adjust for your build machine)
KERNEL_SRC ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

# Cross-compilation settings (for ARM)
ARCH ?= arm
CROSS_COMPILE ?= arm-linux-gnueabihf-

# Module name
obj-m += tetra_char_dev.o

# Compiler flags
ccflags-y := -Wall -Werror

# =============================================================================
# Build Targets
# =============================================================================

all: modules

modules:
	$(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) \
		-C $(KERNEL_SRC) M=$(PWD) modules

install:
	$(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) \
		-C $(KERNEL_SRC) M=$(PWD) modules_install

clean:
	$(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) \
		-C $(KERNEL_SRC) M=$(PWD) clean
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

.PHONY: all modules install clean load unload info dt-node
