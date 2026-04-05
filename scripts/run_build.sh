#!/bin/bash
# Wrapper to run vivado build with ADI_HDL_DIR set
export ADI_HDL_DIR=/home/kevin/openwifi/openwifi-hw/adi-hdl/library
exec vivado -mode batch -source scripts/vivado_build.tcl 2>&1 | tee build/vivado_build.log
