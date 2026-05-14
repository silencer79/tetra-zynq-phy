# =============================================================================
# generate_viterbi_ip.tcl  — Xilinx Viterbi LogiCORE v9.1 für UL SCH/HU
# =============================================================================
# Erzeugt ein Viterbi-Decoder-IP mit den TETRA-Parametern aus
# `rtl/rx/tetra_ul_viterbi_r14.v` abgeleitet:
#
#   K = 5  (effektiv 4, da g[4]=0 in allen 4 Polys)
#   R = 1/4
#   G1 = 11000  (= s[0]^s[1])              = 24 dec
#   G2 = 10110  (= s[0]^s[2]^s[3])         = 22 dec
#   G3 = 11100  (= s[0]^s[1]^s[2])         = 28 dec
#   G4 = 11010  (= s[0]^s[1]^s[3])         = 26 dec
#   Soft = 5-bit unsigned (matcht to_vit_soft() output)
#   Traceback = 32
#
# Output:  ip/vit_ul_sch_hu/vit_ul_sch_hu.xci
# =============================================================================

set PROJ_DIR [file dirname [file dirname [file normalize [info script]]]]
set IP_DIR   $PROJ_DIR/ip
file mkdir $IP_DIR

# Temp-Project, IP daraus extrahieren
create_project -force vit_ip_gen $PROJ_DIR/build/vit_ip_gen \
    -part xc7z020clg400-1
set_property target_language Verilog [current_project]

# IP erstellen mit Default-Properties
create_ip -name viterbi -version 9.1 -vendor xilinx.com -library ip \
    -module_name vit_ul_sch_hu -dir $IP_DIR

# TETRA-spezifische Konfiguration
set_property -dict [list \
    CONFIG.Constraint_Length     {5} \
    CONFIG.Output_Rate0          {4} \
    CONFIG.Convolution0_Code0    {11000} \
    CONFIG.Convolution0_Code1    {10110} \
    CONFIG.Convolution0_Code2    {11100} \
    CONFIG.Convolution0_Code3    {11010} \
    CONFIG.Soft_Width            {5} \
    CONFIG.Coding                {Soft_Coding} \
    CONFIG.Data_Format           {Unsigned_Binary} \
    CONFIG.Architecture          {Parallel} \
    CONFIG.Traceback_Length      {32} \
    CONFIG.Puncturing            {None} \
    CONFIG.Channels              {1} \
    CONFIG.Best_State            {false} \
    CONFIG.BER_Symbol_Count      {false} \
    CONFIG.Norm                  {false} \
    CONFIG.Block_Valid           {true} \
    CONFIG.Reduced_Latency       {false} \
] [get_ips vit_ul_sch_hu]

# Inspektion vor Generation
puts ""
puts "=== Effektive Konfiguration ==="
foreach prop {Constraint_Length Output_Rate0 Convolution0_Code0 \
              Convolution0_Code1 Convolution0_Code2 Convolution0_Code3 \
              Soft_Width Coding Data_Format Traceback_Length Architecture} {
    set val [get_property "CONFIG.$prop" [get_ips vit_ul_sch_hu]]
    puts [format "  CONFIG.%-22s = %s" $prop $val]
}

# Generieren
generate_target {synthesis simulation instantiation_template} \
    [get_ips vit_ul_sch_hu]

# Cache-Files
catch {config_ip_cache -export [get_ips vit_ul_sch_hu]}

# IP-XCI Path ausgeben
puts ""
puts "=== Generated IP ==="
puts "  XCI: [get_property IP_FILE [get_ips vit_ul_sch_hu]]"

close_project

puts ""
puts "DONE: viterbi LogiCORE generated."
