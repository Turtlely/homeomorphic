# Constraints for rtl/fhe_top.v on the Real Digital Urbana board (XC7S50-CSGA324-1).

# 100 MHz clock
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports CLK_100MHZ]
create_clock -period 10.000 -name clk_100mhz [get_ports CLK_100MHZ]

# USB-UART bridge. The board schematic names the nets from the bridge side:
# the bridge TX (B16) drives the FPGA RX, and the FPGA TX (A16) drives the bridge RX.
set_property -dict {PACKAGE_PIN B16 IOSTANDARD LVCMOS33} [get_ports UART_RXD]
set_property -dict {PACKAGE_PIN A16 IOSTANDARD LVCMOS33} [get_ports UART_TXD]

# BTN[0]: reset
set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS25} [get_ports {BTN[0]}]

# LEDs
set_property -dict {PACKAGE_PIN C13 IOSTANDARD LVCMOS33} [get_ports {LED[0]}]
set_property -dict {PACKAGE_PIN C14 IOSTANDARD LVCMOS33} [get_ports {LED[1]}]
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33} [get_ports {LED[2]}]
set_property -dict {PACKAGE_PIN D15 IOSTANDARD LVCMOS33} [get_ports {LED[3]}]

# The UART input, the button, and the LEDs are asynchronous to the clock.
set_false_path -from [get_ports {UART_RXD BTN[0]}]
set_false_path -to   [get_ports {UART_TXD LED[*]}]

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
