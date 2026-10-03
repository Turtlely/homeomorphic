# Batch Vivado build for the Real Digital Urbana board (XC7S50-CSGA324-1).
#
# Usage:
#   vivado -mode batch -source tools/build_urbana.tcl -nojournal -nolog
#   vivado -mode batch -source tools/build_urbana.tcl -nojournal -nolog -tclargs <seed>
#
# Each build gets a new random PRNG seed, unless you give one with -tclargs.
# The seed is written to build/vivado/prng_seed.txt.

set project_root [file normalize [file join [file dirname [info script]] ..]]
set output_dir   [file join $project_root build vivado]
file mkdir $output_dir

# PRNG seed: 1 .. 2^31-1 (it must not be 0)
if {[llength $argv] > 0} {
    set seed [lindex $argv 0]
} else {
    expr {srand([clock clicks])}
    set seed [expr {int(rand() * 0x7FFFFFFE) + 1}]
}
set seed_file [open [file join $output_dir prng_seed.txt] w]
puts $seed_file $seed
close $seed_file
puts "PRNG_SEED = $seed"

set rtl_files [list \
    [file join $project_root rtl fhe_encrypt_byte.v] \
    [file join $project_root rtl fhe_capitalize_seq.v] \
    [file join $project_root rtl fhe_prng.v] \
    [file join $project_root rtl uart_rx.v] \
    [file join $project_root rtl uart_tx.v] \
    [file join $project_root rtl fhe_controller.v] \
    [file join $project_root rtl fhe_top.v] \
]

read_verilog $rtl_files
read_xdc [file join $project_root constraints urbana.xdc]

synth_design -top fhe_top -part xc7s50csga324-1 -generic PRNG_SEED=$seed
opt_design
place_design
phys_opt_design
route_design

report_utilization    -file [file join $output_dir utilization.rpt]
report_timing_summary -file [file join $output_dir timing.rpt]
write_bitstream -force [file join $output_dir fhe_top.bit]

# stop with an error if the design does not meet timing
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts "Worst setup slack: $wns ns"
if {$wns < 0} {
    error "Timing failed: worst setup slack is $wns ns"
}
