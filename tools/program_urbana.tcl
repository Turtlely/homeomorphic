# Program the Urbana board with build/vivado/fhe_top.bit over USB-JTAG.
#
# Usage:
#   vivado -mode batch -source tools/program_urbana.tcl -nojournal -nolog
#
# This loads the FPGA configuration memory only. The design is lost when
# the board loses power.

set project_root [file normalize [file join [file dirname [info script]] ..]]
set bitfile      [file join $project_root build vivado fhe_top.bit]

if {![file exists $bitfile]} {
    error "No bitstream at $bitfile. Run \"make bitstream\" first."
}

open_hw_manager
connect_hw_server
open_hw_target

set device [lindex [get_hw_devices xc7s50*] 0]
if {$device eq ""} {
    error "No XC7S50 found on the JTAG chain. Check the USB cable and the board power."
}
current_hw_device $device
set_property PROGRAM.FILE $bitfile $device
program_hw_devices $device
puts "Programmed $device with $bitfile"

close_hw_target
disconnect_hw_server
close_hw_manager
