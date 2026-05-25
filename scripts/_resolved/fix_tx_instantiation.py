#!/usr/bin/env python3
"""
fix_tx_instantiation.py — Automate TX chain instantiation correction

This script replaces the TX chain instantiation in tetra_zynq_top.v
to add SB burst support parameters and ports.

Author: Ralph (autonomous agent)
Date: 2026-04-08
"""

import re
import sys
from pathlib import Path

def main():
    # File paths
    rtl_dir = Path(__file__).parent.parent / 'rtl'
    top_file = rtl_dir / 'tetra_zynq_top.v'

    if not top_file.exists():
        print(f"ERROR: {top_file} not found")
        sys.exit(1)

    # Read the file
    print(f"Reading {top_file}...")
    content = top_file.read_text()
    original_content = content

    # Define the old and new instantiation blocks
    # The old block starts at line ~573 and ends at ~597

    old_pattern = re.compile(
        r'tetra_tx_chain #\(\s*'
        r'\.IQ_WIDTH\s*\(IQ_WIDTH\),\s*'
        r'\.BLOCK_BITS\(BLOCK_BITS\),\s*'
        r'\.BB_BITS\s*\(BB_BITS\)\s*'
        r'\)\s*u_tx_chain\s*\(\s*'
        r'\.clk_sys\s*\(clk_sys\),\s*'
        r'\.rst_n_sys\(rst_n_sys\),\s*'
        r'// Slot payload buses.*?\n\s*'
        r'\.block1_sys\s*\(\{4\*BLOCK_BITS\}\{1\'?b0\}\}\),\s*'
        r'\.block2_sys\s*\(\{4\*BLOCK_BITS\}\{1\'?b0\}\}\),\s*'
        r'\.bb_sys\s*\(\{4\*BB_BITS\}\{1\'?b0\}\}\),\s*'
        r'\.slot_en_sys.*?\n\s*'
        r'\.tx_slot_num_sys.*?\n\s*'
        r'\.tx_slot_pulse_sys\(tx_slot_pulse_sys_w\),\s*'
        r'// clk_lvds domain.*?\n\s*'
        r'\.clk_lvds\s*\(clk_lvds\),\s*'
        r'\.rst_n_lvds\(rst_n_lvds\),\s*'
        r'// TX IQ output.*?\n\s*'
        r'\.tx_i_lvds\s*\(tx_i_lvds\),\s*'
        r'\.tx_q_lvds\s*\(tx_q_lvds\),\s*'
        r'\.tx_valid_lvds\(tx_valid_lvds\),\s*'
        r'// Status.*?\n\s*'
        r'\.tx_busy_sys\s*\(\)\s*'
        r'\);',
        re.DOTALL
    )

    new_instantiation = '''tetra_tx_chain #(
        .IQ_WIDTH (IQ_WIDTH),
        .BLOCK_BITS(BLOCK_BITS),
        .BB_BITS (BB_BITS),
        .BKN1_SB_BITS(240),
        .BB_SB_BITS (28)
    ) u_tx_chain (
        .clk_sys (clk_sys),
        .rst_n_sys (rst_n_sys),
        // Slot payload buses (NDB) — zeros for now
        .block1_sys ({(4*BLOCK_BITS){1'b0}}),
        .block2_sys ({(4*BLOCK_BITS){1'b0}}),
        .bb_sys ({(4*BB_BITS){1'b0}}),
        // SB payload — used for slot 0 (base station sync burst)
        .sb_bkn1_data_sys (sb_bkn1_data_sys),
        .sb_bkn2_data_sys (sb_bkn2_data_sys),
        .sb_bb_data_sys (sb_bb_data_sys),
        // Per-slot configuration
        .slot_en_sys (4'b0001), // Slot 0 enabled (BUG-04 fix)
        .slot_burst_type_sys(slot_burst_type_sys),
        // TX timing from free-running timer (BUG-01 fix)
        .tx_slot_num_sys (tx_slot_cnt_sys),
        .tx_slot_pulse_sys(tx_slot_pulse_sys_w),
        // clk_lvds domain
        .clk_lvds (clk_lvds),
        .rst_n_lvds (rst_n_lvds),
        // TX IQ output to AD9361
        .tx_i_lvds (tx_i_lvds),
        .tx_q_lvds (tx_q_lvds),
        .tx_valid_lvds (tx_valid_lvds),
        // Status
        .tx_busy_sys ()
    );'''

    # Perform the replacement
    match = old_pattern.search(content)
    if match:
        print("Found TX chain instantiation block, replacing...")
        content = old_pattern.sub(new_instantiation, content)
    else:
        # Fallback: try line-based replacement
        print("Regex pattern failed, trying line-based replacement...")

        # Find line numbers
        lines = content.split('\n')
        start_line = None
        end_line = None

        for i, line in enumerate(lines):
            if 'tetra_tx_chain #(' in line and start_line is None:
                start_line = i
            if start_line is not None and ');' in line and 'u_tx_chain' in '\n'.join(lines[start_line:i+1]):
                end_line = i
                break

        if start_line is None or end_line is None:
            print("ERROR: Could not locate TX chain instantiation")
            sys.exit(1)

        print(f"Found instantiation at lines {start_line+1} to {end_line+1}")

        # Replace the lines
        new_lines = lines[:start_line] + new_instantiation.split('\n') + lines[end_line+1:]
        content = '\n'.join(new_lines)

    # Check if content changed
    if content == original_content:
        print("WARNING: No changes made (content identical)")
        sys.exit(0)

    # Write back
    print(f"Writing corrected {top_file}...")
    top_file.write_text(content)

    print("✓ TX chain instantiation corrected")
    print("\nChanges made:")
    print("  - Added parameters: BKN1_SB_BITS=240, BB_SB_BITS=28")
    print("  - Added SB inputs: sb_bkn1_data_sys, sb_bkn2_data_sys, sb_bb_data_sys")
    print("  - Added: slot_burst_type_sys")
    print("  - Changed: slot_en_sys = 4'b0001 (Slot 0 enabled)")
    print("  - Changed: tx_slot_num_sys = tx_slot_cnt_sys (free-running timer)")
    print("  - Updated comments for clarity")

    return 0

if __name__ == '__main__':
    sys.exit(main())
