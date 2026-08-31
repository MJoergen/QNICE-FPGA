----------------------------------------------------------------------------------
-- QNICE-FPGA on a Nexys4 DDR board
--
-- Top Module for synthesizing the whole machine
--
-- done on-again-off-again in 2015, 2016, 2020 by sy2002
----------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.env1_globals.all;

-- UNISIM is used for the Xilinx specific clock generator MMCME.
-- Comment everything about it out and comment in below-mentioned "generate_clk25MHz" process
-- to port this top file to another hardware and for more details refer to the file
-- "hw/README.md" section "General advise for porting"

library unisim;
  use unisim.vcomponents.all;

entity env1 is
  port (
    clk_i       : in    std_logic;                     -- 100 MHz clock
    reset_n_i   : in    std_logic;                     -- CPU reset button (negative, i.e. 0 = reset)

    -- 7 segment display: common anode and cathode
    sseg_an_o   : out   std_logic_vector(7 downto 0);  -- common anode: selects digit
    sseg_ca_o   : out   std_logic_vector(7 downto 0);  -- cathode: selects segment within a digit

    -- serial communication
    uart_rxd_i  : in    std_logic;                     -- receive data
    uart_txd_o  : out   std_logic;                     -- send data
    uart_rts_i  : in    std_logic;                     -- (active low) equals cts from dte, i.e. fpga is allowed to send to dte
    uart_cts_o  : out   std_logic;                     -- (active low) clear to send (dte is allowed to send to fpga)

    -- switches and LEDs
    switches_i  : in    std_logic_vector(15 downto 0); -- 16 on/off "dip" switches
    leds_o      : out   std_logic_vector(15 downto 0); -- 16 LEDs

    -- PS/2 keyboard
    ps2_clk_i   : in    std_logic;
    ps2_dat_i   : in    std_logic;

    -- VGA
    vga_red_o   : out   std_logic_vector(3 downto 0);
    vga_green_o : out   std_logic_vector(3 downto 0);
    vga_blue_o  : out   std_logic_vector(3 downto 0);
    vga_hs_o    : out   std_logic;
    vga_vs_o    : out   std_logic;

    -- SD Card
    sd_reset_o  : out   std_logic;
    sd_clk_o    : out   std_logic;
    sd_mosi_o   : out   std_logic;
    sd_miso_i   : in    std_logic;
    sd_dat_o    : out   std_logic_vector(3 downto 1)
  );
end entity env1;

architecture beh of env1 is

  -- Main system clock (CPU & memory & I/O devices)
  signal core_clk : std_logic := '0';
  signal core_rst : std_logic;

  -- CPU control signals
  signal core_vga_en             : std_logic;
  signal core_vga_we             : std_logic;
  signal core_vga_reg            : std_logic_vector(4 downto 0);
  signal core_vga_wr_data        : std_logic_vector(15 downto 0);
  signal core_vga_rd_data        : std_logic_vector(15 downto 0);
  signal core_vga_right_int_n    : std_logic;
  signal core_vga_right_igrant_n : std_logic;
  signal core_vga_left_int_n     : std_logic;
  signal core_vga_left_igrant_n  : std_logic;

  -- 25 MHz or 25.175 MHz pixelclock for VGA
  -- The 25.175 MHz pixelclock creates a much sharper image on most monitors, but the
  -- code for creating it is not as portable as the 25 MHz code (which is a simple clock divider)
  -- Have a look at hw/README.md "General advise for porting"
  signal vga_clk : std_logic;

  -- VGA control signals
  signal vga_color : std_logic_vector(14 downto 0);
  signal vga_hsync : std_logic;
  signal vga_vsync : std_logic;

begin

  clk_inst : entity work.clk
    port map (
      sys_clk_i  => clk_i,
      clk25mhz_o => vga_clk,
      clk50mhz_o => core_clk
    ); -- clk_inst : entity work.clk

  core_inst : entity work.core
    port map (
      clk_i                => core_clk,
      reset_n_i            => reset_n_i,
      rst_o                => core_rst,
      sseg_an_o            => sseg_an_o,
      sseg_ca_o            => sseg_ca_o,
      uart_rxd_i           => uart_rxd_i,
      uart_txd_o           => uart_txd_o,
      uart_rts_i           => uart_rts_i,
      uart_cts_o           => uart_cts_o,
      switches_i           => switches_i,
      leds_o               => leds_o,
      ps2_clk_i            => ps2_clk_i,
      ps2_dat_i            => ps2_dat_i,
      vga_en_o             => core_vga_en,
      vga_we_o             => core_vga_we,
      vga_reg_o            => core_vga_reg,
      vga_wr_data_o        => core_vga_wr_data,
      vga_rd_data_i        => core_vga_rd_data,
      vga_right_int_n_o    => core_vga_right_int_n,
      vga_right_igrant_n_i => core_vga_right_igrant_n,
      vga_left_int_n_i     => core_vga_left_int_n,
      vga_left_igrant_n_o  => core_vga_left_igrant_n,
      sd_reset_o           => sd_reset_o,
      sd_clk_o             => sd_clk_o,
      sd_mosi_o            => sd_mosi_o,
      sd_miso_i            => sd_miso_i,
      sd_dat_o             => sd_dat_o
    ); -- core_inst

  -- VGA: 80x40 textmode VGA adaptor
  vga_multicolor_inst : entity work.vga_multicolor
    port map (
      cpu_clk_i     => core_clk,
      cpu_rst_i     => core_rst,
      cpu_en_i      => core_vga_en,
      cpu_we_i      => core_vga_we,
      cpu_reg_i     => core_vga_reg,
      cpu_data_i    => core_vga_wr_data,
      cpu_data_o    => core_vga_rd_data,
      cpu_int_n_i   => core_vga_right_int_n,
      cpu_grant_n_o => core_vga_right_igrant_n,
      cpu_int_n_o   => core_vga_left_int_n,
      cpu_grant_n_i => core_vga_left_igrant_n,
      vga_clk_i     => vga_clk,
      vga_hsync_o   => vga_hsync,
      vga_vsync_o   => vga_vsync,
      vga_color_o   => vga_color,
      vga_data_en_o => open
    ); -- vga_multicolor_inst

  -- wire the simplified color system of the VGA component to the VGA outputs.
  -- Convert from 15-bit to 12-bit by discarding the LSB of each color channel.
  vga_red_o   <= vga_color(14 downto 11);
  vga_green_o <= vga_color(9 downto 6);
  vga_blue_o  <= vga_color(4 downto 1);
  vga_hs_o    <= vga_hsync;
  vga_vs_o    <= vga_vsync;

end architecture beh;

