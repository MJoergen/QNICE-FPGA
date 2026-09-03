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
    clk       : in    std_logic;                     -- 100 MHz clock
    reset_n   : in    std_logic;                     -- CPU reset button (negative, i.e. 0 = reset)

    -- 7 segment display: common anode and cathode
    sseg_an   : out   std_logic_vector(7 downto 0);  -- common anode: selects digit
    sseg_ca   : out   std_logic_vector(7 downto 0);  -- cathode: selects segment within a digit

    -- serial communication
    uart_rxd  : in    std_logic;                     -- receive data
    uart_txd  : out   std_logic;                     -- send data
    uart_rts  : in    std_logic;                     -- (active low) equals cts from dte, i.e. fpga is allowed to send to dte
    uart_cts  : out   std_logic;                     -- (active low) clear to send (dte is allowed to send to fpga)

    -- switches and LEDs
    switches  : in    std_logic_vector(15 downto 0); -- 16 on/off "dip" switches
    leds      : out   std_logic_vector(15 downto 0); -- 16 LEDs

    -- PS/2 keyboard
    ps2_clk   : in    std_logic;
    ps2_dat   : in    std_logic;

    -- VGA
    vga_red   : out   std_logic_vector(3 downto 0);
    vga_green : out   std_logic_vector(3 downto 0);
    vga_blue  : out   std_logic_vector(3 downto 0);
    vga_hs    : out   std_logic;
    vga_vs    : out   std_logic;

    -- SD Card
    sd_reset  : out   std_logic;
    sd_clk    : out   std_logic;
    sd_mosi   : out   std_logic;
    sd_miso   : in    std_logic;
    sd_dat    : out   std_logic_vector(3 downto 1)
  );
end entity env1;

architecture beh of env1 is

  -- CPU control signals
  signal cpu_addr           : std_logic_vector(15 downto 0);
  signal cpu_data_out       : std_logic_vector(15 downto 0);
  signal cpu_data_dir       : std_logic;
  signal cpu_data_valid     : std_logic;
  signal cpu_wait_for_data  : std_logic;
  signal cpu_halt           : std_logic;
  signal cpu_ins_cnt_strobe : std_logic;
  signal cpu_int_n          : std_logic;
  signal cpu_igrant_n       : std_logic;
  signal daisy_int_n        : std_logic;
  signal daisy_igrant_n     : std_logic;
  signal vga_int_n          : std_logic;
  signal vga_igrant_n       : std_logic;

  -- MMIO control signals
  signal rom_enable        : std_logic;
  signal rom_busy          : std_logic;
  signal rom_data_out      : std_logic_vector(15 downto 0);
  signal ram_enable        : std_logic;
  signal ram_busy          : std_logic;
  signal ram_data_out      : std_logic_vector(15 downto 0);
  signal use_pore_rom      : std_logic;
  signal pore_rom_enable   : std_logic;
  signal pore_rom_busy     : std_logic;
  signal pore_rom_data_out : std_logic_vector(15 downto 0);
  signal til_reg0_enable   : std_logic;
  signal til_reg1_enable   : std_logic;
  signal switch_reg_enable : std_logic;
  signal switch_data_out   : std_logic_vector(15 downto 0);
  signal kbd_en            : std_logic;
  signal kbd_we            : std_logic;
  signal kbd_reg           : std_logic_vector(1 downto 0);
  signal kbd_data_out      : std_logic_vector(15 downto 0);
  signal tin_en            : std_logic;
  signal tin_we            : std_logic;
  signal tin_reg           : std_logic_vector(2 downto 0);
  signal timer_data_out    : std_logic_vector(15 downto 0);
  signal vga_en            : std_logic;
  signal vga_we            : std_logic;
  signal vga_reg           : std_logic_vector(4 downto 0);
  signal vga_data_out      : std_logic_vector(15 downto 0);
  signal int_en            : std_logic;
  signal int_we            : std_logic;
  signal int_reg           : std_logic_vector(2 downto 0);
  signal int_data_out      : std_logic_vector(15 downto 0);
  signal uart_en           : std_logic;
  signal uart_we           : std_logic;
  signal uart_reg          : std_logic_vector(1 downto 0);
  signal uart_data_out     : std_logic_vector(15 downto 0);
  signal uart_cpu_ws       : std_logic;
  signal cyc_en            : std_logic;
  signal cyc_we            : std_logic;
  signal cyc_reg           : std_logic_vector(1 downto 0);
  signal cyc_data_out      : std_logic_vector(15 downto 0);
  signal ins_en            : std_logic;
  signal ins_we            : std_logic;
  signal ins_reg           : std_logic_vector(1 downto 0);
  signal ins_data_out      : std_logic_vector(15 downto 0);
  signal eae_en            : std_logic;
  signal eae_we            : std_logic;
  signal eae_reg           : std_logic_vector(2 downto 0);
  signal eae_data_out      : std_logic_vector(15 downto 0);
  signal sd_en             : std_logic;
  signal sd_we             : std_logic;
  signal sd_reg            : std_logic_vector(2 downto 0);
  signal sd_data_out       : std_logic_vector(15 downto 0);
  signal sys_en            : std_logic;
  signal sys_we            : std_logic;
  signal sys_reg           : std_logic_vector(0 downto 0);
  signal sys_data_out      : std_logic_vector(15 downto 0);

  -- VGA control signals
  signal vga_color : std_logic_vector(14 downto 0);
  signal vga_hsync : std_logic;
  signal vga_vsync : std_logic;

  -- Main system clock (CPU & memory & I/O devices)
  signal slow_clock : std_logic := '0';

  -- 25 MHz or 25.175 MHz pixelclock for VGA
  -- The 25.175 MHz pixelclock creates a much sharper image on most monitors, but the
  -- code for creating it is not as portable as the 25 MHz code (which is a simple clock divider)
  -- Have a look at hw/README.md "General advise for porting"
  signal clk25mhz : std_logic   := '0';

  -- MMCME related signals
  signal clk_fb_main     : std_logic;
  signal pll_locked_main : std_logic;

  signal reset_ctl : std_logic;

  -- enable displaying of address bus on system halt, if switch 2 is on
  signal i_til_reg0_enable : std_logic;
  signal i_til_data_in     : std_logic_vector(15 downto 0);

  -- CPU instruction memory bus
  signal cpu_wbi_cyc     : std_logic;
  signal cpu_wbi_stb     : std_logic;
  signal cpu_wbi_stall   : std_logic;
  signal cpu_wbi_addr    : std_logic_vector(15 downto 0);
  signal cpu_wbi_ack     : std_logic;
  signal cpu_wbi_rd_data : std_logic_vector(15 downto 0);

  -- CPU data memory bus
  signal cpu_wbd_cyc     : std_logic;
  signal cpu_wbd_stb     : std_logic;
  signal cpu_wbd_stall   : std_logic;
  signal cpu_wbd_addr    : std_logic_vector(15 downto 0);
  signal cpu_wbd_addr_d  : std_logic_vector(15 downto 0);
  signal cpu_wbd_we      : std_logic;
  signal cpu_wbd_wr_dat  : std_logic_vector(15 downto 0);
  signal cpu_wbd_ack     : std_logic;
  signal cpu_wbd_rd_data : std_logic_vector(15 downto 0);

  -- Outputs from memory and I/O devices
  signal pore_rom_inst_out : std_logic_vector(15 downto 0);
  signal rom_inst_out      : std_logic_vector(15 downto 0);
  signal ram_inst_out      : std_logic_vector(15 downto 0);
  signal io_data_out       : std_logic_vector(15 downto 0);

  signal pore_rom_a_addr    : std_logic_vector(14 downto 0);
  signal pore_rom_a_rd_en   : std_logic;
  signal pore_rom_a_rd_data : std_logic_vector(15 downto 0);
  signal pore_rom_b_addr    : std_logic_vector(14 downto 0);
  signal pore_rom_b_rd_en   : std_logic;
  signal pore_rom_b_rd_data : std_logic_vector(15 downto 0);
  signal pore_rom_a_rd_en_d : std_logic;
  signal pore_rom_b_rd_en_d : std_logic;

  signal rom_a_addr      : std_logic_vector(14 downto 0);
  signal rom_a_rd_en     : std_logic;
  signal rom_a_rd_data   : std_logic_vector(15 downto 0);
  signal rom_b_addr      : std_logic_vector(14 downto 0);
  signal rom_b_rd_en     : std_logic;
  signal rom_b_rd_data   : std_logic_vector(15 downto 0);
  signal rom_a_rd_en_d   : std_logic;
  signal rom_b_rd_en_d   : std_logic;

  signal ram_a_addr      : std_logic_vector(14 downto 0);
  signal ram_a_rd_en     : std_logic;
  signal ram_a_rd_data   : std_logic_vector(15 downto 0);
  signal ram_b_addr      : std_logic_vector(14 downto 0);
  signal ram_b_rd_en     : std_logic;
  signal ram_b_rd_data   : std_logic_vector(15 downto 0);
  signal ram_b_wr_en     : std_logic;
  signal ram_b_wr_data   : std_logic_vector(15 downto 0);
  signal ram_a_rd_en_d   : std_logic;
  signal ram_b_rd_en_d   : std_logic;

begin

  -- Merge data outputs from all devices into a single data input to the CPU.
  -- This requires that all devices output 0's when not selected.
  --
  -- Here we have added a "rising_edge" to ensure the data read from I/O devices
  -- are properly registered (i.e. delayed one clock cycle).
  -- Furthermore, we've removed the RAM and ROM, because their outputs are
  -- already registered.
  io_data_out <= switch_data_out   or
                 kbd_data_out      or
                 vga_data_out      or
                 uart_data_out     or
                 timer_data_out    or
                 cyc_data_out      or
                 ins_data_out      or
                 eae_data_out      or
                 sd_data_out       or
                 int_data_out      or
                 sys_data_out
                 when rising_edge(slow_clock);

  -- Memory map of instruction memory bus (handled here)
  -- 0x0000 - 0x7FFF : ROM / PORE_ROM
  -- 0x8000 - 0xFFFF : RAM
  --
  -- Memory map of data memory bus (handled in mmio_mux.vhd)
  -- 0x0000 - 0x7FFF : ROM / PORE_ROM
  -- 0x8000 - 0xFEFF : RAM
  -- 0xFF00 - 0xFFFF : I/O
  --
  -- Dual-Port memory is used for ROM/RAM.
  -- Port A is for instruction memory
  -- Port B is for data memory
  -- Both read ports are registered
  cpu_wbi_rd_data <= ram_inst_out or rom_inst_out or pore_rom_inst_out;
  cpu_wbd_rd_data <= ram_data_out or rom_data_out or pore_rom_data_out or io_data_out;


  i_clk : entity work.clk
    port map (
      sys_clk_i  => clk,
      clk25mhz_o => clk25mhz,
      clk50mhz_o => slow_clock
    );


  -- QNICE CPU
  cpu_inst : entity work.cpu
    generic map (
      G_WRITES_FILE         => "", -- only used in simulation
      G_REGISTER_BANK_WIDTH => 8
    )
    port map (
      clk_i       => slow_clock,
      rst_i       => reset_ctl,
      wbi_cyc_o   => cpu_wbi_cyc,
      wbi_stb_o   => cpu_wbi_stb,
      wbi_stall_i => cpu_wbi_stall,
      wbi_addr_o  => cpu_wbi_addr,
      wbi_ack_i   => cpu_wbi_ack,
      wbi_data_i  => cpu_wbi_rd_data,
      wbd_cyc_o   => cpu_wbd_cyc,
      wbd_stb_o   => cpu_wbd_stb,
      wbd_stall_i => cpu_wbd_stall,
      wbd_addr_o  => cpu_wbd_addr,
      wbd_we_o    => cpu_wbd_we,
      wbd_dat_o   => cpu_wbd_wr_dat,
      wbd_ack_i   => cpu_wbd_ack,
      wbd_data_i  => cpu_wbd_rd_data,
      inst_done_o => cpu_ins_cnt_strobe,
      halt_o      => cpu_halt
    ); -- cpu_inst

  -- Both Instruction and data memory buses always accept the request without
  -- delay.
  cpu_wbi_stall   <= '0';
  cpu_wbd_stall   <= '0';

  -- Instruction memory always responds with read data on the following clock
  -- cycle.
  -- Data memory may hold back read data indefinitely.
  cpu_wbi_ack     <= cpu_wbi_cyc and cpu_wbi_stb when rising_edge(slow_clock);
  cpu_wbd_ack     <= not cpu_wait_for_data       when rising_edge(slow_clock);

  -- The Wishbone protocol is transaction based, which means the cpu_wbd_addr
  -- signal is only valid when cpu_wbd_stb is asserted. However, the I/O devices
  -- expect the CPU address to be valid in every clock cycle. So, we add a
  -- register here to hold the last valid value.
  cpu_wbd_addr_proc : process (slow_clock)
  begin
     if rising_edge(slow_clock) then
        if cpu_wbd_stb = '1' then
           cpu_wbd_addr_d <= cpu_wbd_addr;
        end if;
     end if;
  end process cpu_wbd_addr_proc;

  cpu_addr       <= cpu_wbd_addr when cpu_wbd_stb = '1' else cpu_wbd_addr_d;
  cpu_data_out   <= cpu_wbd_wr_dat;
  cpu_data_dir   <= cpu_wbd_cyc and cpu_wbd_stb and cpu_wbd_we and not cpu_wbd_stall;
  cpu_data_valid <= '1';
  cpu_igrant_n   <= '1'; -- TBD: Interrupt support not yet implemented


  -- ROM: up to 64kB consisting of up to 32.000 16 bit words
  rom_inst : entity work.dp_ram
    generic map (
      G_INIT_FILE => ROM_FILE,
      G_RAM_STYLE => "block",
      G_B_READ    => true,
      G_ADDR_SIZE => 15,
      G_DATA_SIZE => 16
    )
    port map (
      clk_i       => slow_clock,
      rst_i       => '0',
      a_addr_i    => rom_a_addr,
      a_rd_en_i   => rom_a_rd_en,
      a_rd_data_o => rom_a_rd_data,
      b_addr_i    => rom_b_addr,
      b_rd_en_i   => rom_b_rd_en,
      b_rd_data_o => rom_b_rd_data,
      b_wr_en_i   => '0',
      b_wr_data_i => (others => '0')
    ); -- dp_ram_inst

  rom_a_addr    <= cpu_wbi_addr(14 downto 0);
  rom_a_rd_en   <= cpu_wbi_cyc and cpu_wbi_stb and not cpu_wbi_addr(15) and not use_pore_rom;
  rom_b_addr    <= cpu_wbd_addr(14 downto 0);
  rom_b_rd_en   <= cpu_wbd_cyc and cpu_wbd_stb and not cpu_wbd_we and rom_enable;

  rom_a_rd_en_d <= rom_a_rd_en when rising_edge(slow_clock);
  rom_b_rd_en_d <= rom_b_rd_en when rising_edge(slow_clock);

  -- ROM output must be zero when not accessed
  rom_inst_out <= rom_a_rd_data when rom_a_rd_en_d = '1' else X"0000";
  rom_data_out <= rom_b_rd_data when rom_b_rd_en_d = '1' else X"0000";
  rom_busy     <= '0';


  -- RAM: up to 64kB consisting of up to 32.000 16 bit words
  dp_ram_inst : entity work.dp_ram
    generic map (
      G_INIT_FILE => "",
      G_RAM_STYLE => "block",
      G_B_READ    => true,
      G_ADDR_SIZE => 15,
      G_DATA_SIZE => 16
    )
    port map (
      clk_i       => slow_clock,
      rst_i       => '0',
      a_addr_i    => ram_a_addr,
      a_rd_en_i   => ram_a_rd_en,
      a_rd_data_o => ram_a_rd_data,
      b_addr_i    => ram_b_addr,
      b_rd_en_i   => ram_b_rd_en,
      b_rd_data_o => ram_b_rd_data,
      b_wr_en_i   => ram_b_wr_en,
      b_wr_data_i => ram_b_wr_data
    ); -- dp_ram_inst

  ram_a_addr    <= cpu_wbi_addr(14 downto 0);
  ram_a_rd_en   <= cpu_wbi_cyc and cpu_wbi_stb and cpu_wbi_addr(15);
  ram_b_addr    <= cpu_wbd_addr(14 downto 0);
  ram_b_rd_en   <= cpu_wbd_cyc and cpu_wbd_stb and not cpu_wbd_we and ram_enable;
  ram_b_wr_en   <= cpu_wbd_cyc and cpu_wbd_stb and cpu_wbd_we and ram_enable;
  ram_b_wr_data <= cpu_wbd_wr_dat;

  ram_a_rd_en_d <= ram_a_rd_en when rising_edge(slow_clock);
  ram_b_rd_en_d <= ram_b_rd_en when rising_edge(slow_clock);

  -- RAM output must be zero when not accessed
  ram_inst_out <= ram_a_rd_data when ram_a_rd_en_d = '1' else X"0000";
  ram_data_out <= ram_b_rd_data when ram_b_rd_en_d = '1' else X"0000";
  ram_busy     <= '0';


  -- PORE ROM: Power On & Reset Execution ROM
  -- contains code that is executed during power on and/or during reset
  -- MMIO is managing the PORE process
  pore_rom_inst : entity work.dp_ram
    generic map (
      G_INIT_FILE => PORE_ROM_FILE,
      G_RAM_STYLE => "block",
      G_B_READ    => true,
      G_ADDR_SIZE => 15,
      G_DATA_SIZE => 16
    )
    port map (
      clk_i       => slow_clock,
      rst_i       => '0',
      a_addr_i    => pore_rom_a_addr,
      a_rd_en_i   => pore_rom_a_rd_en,
      a_rd_data_o => pore_rom_a_rd_data,
      b_addr_i    => pore_rom_b_addr,
      b_rd_en_i   => pore_rom_b_rd_en,
      b_rd_data_o => pore_rom_b_rd_data,
      b_wr_en_i   => '0',
      b_wr_data_i => (others => '0')
    ); -- dp_ram_inst

  pore_rom_a_addr    <= cpu_wbi_addr(14 downto 0);
  pore_rom_a_rd_en   <= cpu_wbi_cyc and cpu_wbi_stb and not cpu_wbi_addr(15) and use_pore_rom;
  pore_rom_b_addr    <= cpu_wbd_addr(14 downto 0);
  pore_rom_b_rd_en   <= cpu_wbd_cyc and cpu_wbd_stb and not cpu_wbd_we and pore_rom_enable;

  pore_rom_a_rd_en_d <= pore_rom_a_rd_en when rising_edge(slow_clock);
  pore_rom_b_rd_en_d <= pore_rom_b_rd_en when rising_edge(slow_clock);

  -- PORE_ROM output must be zero when not accessed
  pore_rom_inst_out <= pore_rom_a_rd_data when pore_rom_a_rd_en_d = '1' else X"0000";
  pore_rom_data_out <= pore_rom_b_rd_data when pore_rom_b_rd_en_d = '1' else X"0000";
  pore_rom_busy     <= '0';


  -- VGA: 80x40 textmode VGA adaptor
  i_vga_multicolor : entity work.vga_multicolor
    port map (
      cpu_clk_i     => slow_clock,
      cpu_rst_i     => reset_ctl,
      cpu_en_i      => vga_en,
      cpu_we_i      => vga_we,
      cpu_reg_i     => vga_reg,
      cpu_data_i    => cpu_data_out,
      cpu_data_o    => vga_data_out,
      cpu_int_n_o   => daisy_int_n,
      cpu_grant_n_i => daisy_igrant_n,
      cpu_int_n_i   => vga_int_n,
      cpu_grant_n_o => vga_igrant_n,

      vga_clk_i     => clk25mhz,
      vga_hsync_o   => vga_hsync,
      vga_vsync_o   => vga_vsync,
      vga_color_o   => vga_color,
      vga_data_en_o => open
    ); -- i_vga_multicolor

  -- wire the simplified color system of the VGA component to the VGA outputs.
  -- Convert from 15-bit to 12-bit by discarding the LSB of each color channel.
  vga_red   <= vga_color(14 downto 11);
  vga_green <= vga_color(9 downto 6);
  vga_blue  <= vga_color(4 downto 1);
  vga_hs    <= vga_hsync;
  vga_vs    <= vga_vsync;

  -- TIL display emulation (4 digits)
  til_leds : entity work.til_display
    port map (
      clk             => slow_clock,
      reset           => reset_ctl,
      til_reg0_enable => i_til_reg0_enable,
      til_reg1_enable => til_reg1_enable,
      data_in         => i_til_data_in,
      sseg_an         => sseg_an,
      sseg_ca         => sseg_ca
    );

  -- special UART with FIFO that can be directly connected to the CPU bus
  uart : entity work.bus_uart
    port map (
      clk          => slow_clock,
      reset        => reset_ctl,
      fast         => switches(3),
      rx           => uart_rxd,
      tx           => uart_txd,
      rts          => uart_rts,
      cts          => uart_cts,
      uart_en      => uart_en,
      uart_we      => uart_we,
      uart_reg     => uart_reg,
      uart_cpu_ws  => uart_cpu_ws,
      cpu_data_in  => cpu_data_out,
      cpu_data_out => uart_data_out
    );

  -- PS/2 keyboard
  kbd : entity work.keyboard
    port map (
      clk          => slow_clock,
      reset        => reset_ctl,
      ps2_clk      => ps2_clk,
      ps2_data     => ps2_dat,
      kbd_en       => kbd_en,
      kbd_we       => kbd_we,
      kbd_reg      => kbd_reg,
      cpu_data_in  => cpu_data_out,
      cpu_data_out => kbd_data_out
    );

  timer_interrupt : entity work.timer_module
    generic map (
      CLK_FREQ => SYSTEM_SPEED
    )
    port map (
      clk         => slow_clock,
      reset       => reset_ctl,
      int_n_out   => vga_int_n,
      grant_n_in  => vga_igrant_n,
      int_n_in    => '1',  -- no more devices to in Daisy Chain: 1=no interrupt
      grant_n_out => open, -- ditto: open=grant goes nowhere
      en          => tin_en,
      we          => tin_we,
      reg         => tin_reg,
      data_in     => cpu_data_out,
      data_out    => timer_data_out
    );

  -- cycle counter
  cyc : entity work.cycle_counter
    port map (
      clk      => slow_clock,
      impulse  => '1',
      reset    => reset_ctl,
      en       => cyc_en,
      we       => cyc_we,
      reg      => cyc_reg,
      data_in  => cpu_data_out,
      data_out => cyc_data_out
    );

  -- instruction counter
  ins : entity work.cycle_counter
    port map (
      clk      => slow_clock,
      impulse  => cpu_ins_cnt_strobe,
      reset    => reset_ctl,
      en       => ins_en,
      we       => ins_we,
      reg      => ins_reg,
      data_in  => cpu_data_out,
      data_out => ins_data_out
    );

  -- EAE - Extended Arithmetic Element (32-bit multiplication, division, modulo)
  eae_inst : entity work.eae
    port map (
      clk      => slow_clock,
      reset    => reset_ctl,
      en       => eae_en,
      we       => eae_we,
      reg      => eae_reg,
      data_in  => cpu_data_out,
      data_out => eae_data_out
    );

  -- SYSINFO
  sys_inst : entity work.sysinfo
    port map (
      clk      => slow_clock,
      reset    => reset_ctl,
      en       => sys_en,
      we       => sys_we,
      reg      => sys_reg,
      data_in  => cpu_data_out,
      data_out => sys_data_out
    );

  -- SD Card
  sd_card : entity work.sdcard
    port map (
      clk      => slow_clock,
      reset    => reset_ctl,
      en       => sd_en,
      we       => sd_we,
      reg      => sd_reg,
      data_in  => cpu_data_out,
      data_out => sd_data_out,
      sd_reset => sd_reset,
      sd_clk   => sd_clk,
      sd_mosi  => sd_mosi,
      sd_miso  => sd_miso
    );

  interrupt_controller : entity work.interrupt_controller
    port map (
      clk_i     => slow_clock,
      rst_i     => reset_ctl,
      en_i      => int_en,
      we_i      => int_we,
      reg_i     => int_reg,
      data_i    => cpu_data_out,
      data_o    => int_data_out,
      int_n_o   => cpu_int_n,
      grant_n_i => cpu_igrant_n,
      int_n_i   => daisy_int_n,
      grant_n_o => daisy_igrant_n
    );

  -- memory mapped i/o controller
  mmio_controller : entity work.mmio_mux
    generic map (
      GD_PORE     => true, -- yes, use PORE system
      GD_TIL      => true, -- yes, support TIL leds
      GD_SWITCHES => true, -- yes, support SWITCHES
      GD_HRAM     => false -- no, do not support HyperRAM
    )
    port map (
      hw_reset          => not reset_n,
      clk               => slow_clock, -- @TODO change debouncer bitsize when going to 100 MHz
      addr              => cpu_addr,
      data_dir          => cpu_data_dir,
      data_valid        => cpu_data_valid,
      cpu_wait_for_data => cpu_wait_for_data,
      cpu_halt          => cpu_halt,
      cpu_igrant_n      => cpu_igrant_n,
      rom_enable        => rom_enable,
      rom_busy          => rom_busy,
      ram_enable        => ram_enable,
      ram_busy          => ram_busy,
      use_pore_rom      => use_pore_rom,
      pore_rom_enable   => pore_rom_enable,
      pore_rom_busy     => pore_rom_busy,
      til_reg0_enable   => til_reg0_enable,
      til_reg1_enable   => til_reg1_enable,
      switch_reg_enable => switch_reg_enable,
      kbd_en            => kbd_en,
      kbd_we            => kbd_we,
      kbd_reg           => kbd_reg,
      tin_en            => tin_en,
      tin_we            => tin_we,
      tin_reg           => tin_reg,
      vga_en            => vga_en,
      vga_we            => vga_we,
      vga_reg           => vga_reg,
      int_en            => int_en,
      int_we            => int_we,
      int_reg           => int_reg,
      uart_en           => uart_en,
      uart_we           => uart_we,
      uart_reg          => uart_reg,
      uart_cpu_ws       => uart_cpu_ws,
      cyc_en            => cyc_en,
      cyc_we            => cyc_we,
      cyc_reg           => cyc_reg,
      ins_en            => ins_en,
      ins_we            => ins_we,
      ins_reg           => ins_reg,
      eae_en            => eae_en,
      eae_we            => eae_we,
      eae_reg           => eae_reg,
      sys_en            => sys_en,
      sys_we            => sys_we,
      sys_reg           => sys_reg,
      sd_en             => sd_en,
      sd_we             => sd_we,
      sd_reg            => sd_reg,
      reset_ctl         => reset_ctl,
      reset_pre_pore    => open,
      reset_post_pore   => open,

      -- no HyperRAM available
      hram_en           => open,
      hram_we           => open,
      hram_reg          => open,
      hram_cpu_ws       => '0'
    );

  -- emulate the toggle switches as described in doc/README.md
  switch_driver : process (switch_reg_enable, switches)
  begin
    if switch_reg_enable = '1' then
      switch_data_out <= switches;
    else
      switch_data_out <= (others => '0');
    end if;
  end process switch_driver;

  -- debug mode handling: if switch 2 is on then:
  --   show the current cpu address in realtime on the LEDs
  --   on halt show the PC of the HALT command (aka address bus value) on TIL
  debug_mode_handler : process (switches, cpu_addr, cpu_data_out, cpu_halt, til_reg0_enable)
  begin
    i_til_reg0_enable <= til_reg0_enable;
    i_til_data_in     <= cpu_data_out;
    leds              <= cpu_halt & "000000000000000";

    -- debug mode
    if switches(2) = '1' then
      leds <= cpu_addr;

      if cpu_halt = '1' then
        i_til_reg0_enable <= '1';
        i_til_data_in     <= cpu_addr;
      end if;
    end if;
  end process debug_mode_handler;

  -- pull DAT1, DAT2 and DAT3 to GND (Nexys' pull-ups by default pull to VDD)
  sd_dat <= "000";

end architecture beh;

