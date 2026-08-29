## Nexys4 DDR mapping for QNICE-FPGA
## done by sy2002 in May 2020

## External clock signal (100 MHz)
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 10.000 -name clk [get_ports clk]

## Handle the Clock Domain Crossing
## Any register wrapped inside a generate statement with the name `gen_cdc`
## will be considered part of a Clock Domain Crossing.
set_false_path -from [get_clocks -of_objects [get_pins i_clk/i_mmcme2_adv/CLKOUT0]] \
               -to [get_pins -hierarchical {*gen_cdc.*/D}]
set_false_path -from [get_clocks -of_objects [get_pins i_clk/i_mmcme2_adv/CLKOUT1]] \
               -to [get_pins -hierarchical {*gen_cdc.*/D}]

## EAE's combinatorial division networks take longer than
## the regular clock period, so we specify a multicycle path
## see also the comments in EAE.vhd and explanations in UG903/chapter 5/Multicycle Paths as well as ug911/page 25
set_multicycle_path -from [get_cells {{eae_inst/op0_reg*} {eae_inst/op1_reg*}}] -to [get_cells {eae_inst/res_reg[*]}] -setup 3
set_multicycle_path -from [get_cells {{eae_inst/op0_reg*} {eae_inst/op1_reg*}}] -to [get_cells {eae_inst/res_reg[*]}] -hold 2

## The following set_max delay works fine, too at 50 MHz main clock and is an alternative to the multicycle path
#set_max_delay -from [get_cells {{eae_inst/op0_reg[*]} {eae_inst/op1_reg[*]}}] -to [get_cells {eae_inst/res_reg[*]}] 34.000

## Reset button
set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports reset_n]

## 7 segment display
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {sseg_ca[0]}]
set_property -dict {PACKAGE_PIN R10 IOSTANDARD LVCMOS33} [get_ports {sseg_ca[1]}]
set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVCMOS33} [get_ports {sseg_ca[2]}]
set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS33} [get_ports {sseg_ca[3]}]
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33} [get_ports {sseg_ca[4]}]
set_property -dict {PACKAGE_PIN T11 IOSTANDARD LVCMOS33} [get_ports {sseg_ca[5]}]
set_property -dict {PACKAGE_PIN L18 IOSTANDARD LVCMOS33} [get_ports {sseg_ca[6]}]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports {sseg_ca[7]}]

set_property -dict {PACKAGE_PIN J17 IOSTANDARD LVCMOS33} [get_ports {sseg_an[0]}]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} [get_ports {sseg_an[1]}]
set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS33} [get_ports {sseg_an[2]}]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports {sseg_an[3]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {sseg_an[4]}]
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS33} [get_ports {sseg_an[5]}]
set_property -dict {PACKAGE_PIN K2  IOSTANDARD LVCMOS33} [get_ports {sseg_an[6]}]
set_property -dict {PACKAGE_PIN U13 IOSTANDARD LVCMOS33} [get_ports {sseg_an[7]}]

## USB-RS232 Interface
set_property -dict {PACKAGE_PIN C4  IOSTANDARD LVCMOS33} [get_ports uart_rxd]
set_property -dict {PACKAGE_PIN D4  IOSTANDARD LVCMOS33} [get_ports uart_txd]
set_property -dict {PACKAGE_PIN D3  IOSTANDARD LVCMOS33} [get_ports uart_cts]
set_property -dict {PACKAGE_PIN E5  IOSTANDARD LVCMOS33} [get_ports uart_rts]

## Switches
set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVCMOS33} [get_ports {switches[0]}]
set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVCMOS33} [get_ports {switches[1]}]
set_property -dict {PACKAGE_PIN M13 IOSTANDARD LVCMOS33} [get_ports {switches[2]}]
set_property -dict {PACKAGE_PIN R15 IOSTANDARD LVCMOS33} [get_ports {switches[3]}]
set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports {switches[4]}]
set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVCMOS33} [get_ports {switches[5]}]
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports {switches[6]}]
set_property -dict {PACKAGE_PIN R13 IOSTANDARD LVCMOS33} [get_ports {switches[7]}]
set_property -dict {PACKAGE_PIN T8  IOSTANDARD LVCMOS33} [get_ports {switches[8]}]
set_property -dict {PACKAGE_PIN U8  IOSTANDARD LVCMOS33} [get_ports {switches[9]}]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} [get_ports {switches[10]}]
set_property -dict {PACKAGE_PIN T13 IOSTANDARD LVCMOS33} [get_ports {switches[11]}]
set_property -dict {PACKAGE_PIN H6  IOSTANDARD LVCMOS33} [get_ports {switches[12]}]
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33} [get_ports {switches[13]}]
set_property -dict {PACKAGE_PIN U11 IOSTANDARD LVCMOS33} [get_ports {switches[14]}]
set_property -dict {PACKAGE_PIN V10 IOSTANDARD LVCMOS33} [get_ports {switches[15]}]

## PS/2 keyboard
set_property -dict {PACKAGE_PIN F4  IOSTANDARD LVCMOS33} [get_ports ps2_clk]
set_property -dict {PACKAGE_PIN B2  IOSTANDARD LVCMOS33} [get_ports ps2_dat]

## LEDs
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {leds[0]}]
set_property -dict {PACKAGE_PIN K15 IOSTANDARD LVCMOS33} [get_ports {leds[1]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports {leds[2]}]
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports {leds[3]}]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports {leds[4]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {leds[5]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {leds[6]}]
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports {leds[7]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {leds[8]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33} [get_ports {leds[9]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {leds[10]}]
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports {leds[11]}]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports {leds[12]}]
set_property -dict {PACKAGE_PIN V14 IOSTANDARD LVCMOS33} [get_ports {leds[13]}]
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33} [get_ports {leds[14]}]
set_property -dict {PACKAGE_PIN V11 IOSTANDARD LVCMOS33} [get_ports {leds[15]}]

## VGA
set_property -dict {PACKAGE_PIN A3  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {vga_red[0]}]
set_property -dict {PACKAGE_PIN B4  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {vga_red[1]}]
set_property -dict {PACKAGE_PIN C5  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {vga_red[2]}]
set_property -dict {PACKAGE_PIN A4  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {vga_red[3]}]
set_property -dict {PACKAGE_PIN C6  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {vga_green[0]}]
set_property -dict {PACKAGE_PIN A5  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {vga_green[1]}]
set_property -dict {PACKAGE_PIN B6  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {vga_green[2]}]
set_property -dict {PACKAGE_PIN A6  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {vga_green[3]}]
set_property -dict {PACKAGE_PIN B7  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {vga_blue[0]}]
set_property -dict {PACKAGE_PIN C7  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {vga_blue[1]}]
set_property -dict {PACKAGE_PIN D7  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {vga_blue[2]}]
set_property -dict {PACKAGE_PIN D8  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {vga_blue[3]}]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports vga_hs]
set_property -dict {PACKAGE_PIN B12 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports vga_vs]

##Micro SD Connector
set_property -dict {PACKAGE_PIN E2  IOSTANDARD LVCMOS33} [get_ports sd_reset]
set_property -dict {PACKAGE_PIN B1  IOSTANDARD LVCMOS33} [get_ports sd_clk]
set_property -dict {PACKAGE_PIN C1  IOSTANDARD LVCMOS33} [get_ports sd_mosi]
set_property -dict {PACKAGE_PIN C2  IOSTANDARD LVCMOS33} [get_ports sd_miso]
set_property -dict {PACKAGE_PIN E1  IOSTANDARD LVCMOS33} [get_ports {sd_dat[1]}]
set_property -dict {PACKAGE_PIN F1  IOSTANDARD LVCMOS33} [get_ports {sd_dat[2]}]
set_property -dict {PACKAGE_PIN D2  IOSTANDARD LVCMOS33} [get_ports {sd_dat[3]}]
#set_property -dict {PACKAGE_PIN A1  IOSTANDARD LVCMOS33} [get_ports sd_cd]

## Configuration Bank Voltage Select
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

