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

entity core is
  port (
    clk_i                : in    std_logic;                     -- 25 MHz core clock
    reset_n_i            : in    std_logic;                     -- Asynchronous active low reset input
    rst_o                : out   std_logic;                     -- Synchronous active high reset output

    -- 7 segment display: common anode and cathode
    sseg_an_o            : out   std_logic_vector(7 downto 0);  -- common anode: selects digit
    sseg_ca_o            : out   std_logic_vector(7 downto 0);  -- cathode: selects segment within a digit

    -- serial communication
    uart_rxd_i           : in    std_logic;                     -- receive data
    uart_txd_o           : out   std_logic;                     -- send data
    uart_rts_i           : in    std_logic;                     -- (active low) equals cts from dte, i.e. fpga is allowed to send to dte
    uart_cts_o           : out   std_logic;                     -- (active low) clear to send (dte is allowed to send to fpga)

    -- switches and LEDs
    switches_i           : in    std_logic_vector(15 downto 0); -- 16 on/off "dip" switches
    leds_o               : out   std_logic_vector(15 downto 0); -- 16 LEDs

    -- PS/2 keyboard
    ps2_clk_i            : in    std_logic;
    ps2_dat_i            : in    std_logic;

    -- Interface to VGA driver
    vga_en_o             : buffer std_logic;
    vga_we_o             : out   std_logic;
    vga_reg_o            : out   std_logic_vector(4 downto 0);
    vga_wr_data_o        : out   std_logic_vector(15 downto 0);
    vga_rd_data_i        : in    std_logic_vector(15 downto 0);
    vga_right_int_n_o    : out   std_logic;
    vga_right_igrant_n_i : in    std_logic;
    vga_left_int_n_i     : in    std_logic;
    vga_left_igrant_n_o  : out   std_logic;

    -- SD Card
    sd_reset_o           : out   std_logic;
    sd_clk_o             : out   std_logic;
    sd_mosi_o            : out   std_logic;
    sd_miso_i            : in    std_logic;
    sd_dat_o             : out   std_logic_vector(3 downto 1)
  );
end entity core;

architecture rtl of core is

  signal hw_reset           : std_logic; -- asynchronous, active high
  signal rst                : std_logic; -- synchronous, active high

  -- CPU control signals
  signal cpu_addr           : std_logic_vector(15 downto 0);
  signal cpu_data_in        : std_logic_vector(15 downto 0);
  signal cpu_data_out       : std_logic_vector(15 downto 0);
  signal cpu_data_dir       : std_logic;
  signal cpu_data_valid     : std_logic;
  signal cpu_wait_for_data  : std_logic;
  signal cpu_halt           : std_logic;
  signal cpu_ins_cnt_strobe : std_logic;
  signal cpu_int_n          : std_logic;
  signal cpu_igrant_n       : std_logic;

  -- MMIO control signals
  signal rom_enable        : std_logic;
  signal rom_busy          : std_logic;
  signal rom_data_out      : std_logic_vector(15 downto 0);
  signal ram_enable        : std_logic;
  signal ram_busy          : std_logic;
  signal ram_data_out      : std_logic_vector(15 downto 0);
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

  -- enable displaying of address bus on system halt, if switch 2 is on
  signal i_til_reg0_enable : std_logic;
  signal i_til_data_in     : std_logic_vector(15 downto 0);

begin

  rst_o <= rst;

  vga_wr_data_o <= cpu_data_out;

  -- Merge data outputs from all devices into a single data input to the CPU.
  -- This requires that all devices output 0's when not selected.
  cpu_data_in   <= pore_rom_data_out or
                   rom_data_out      or
                   ram_data_out      or
                   switch_data_out   or
                   kbd_data_out      or
                   vga_rd_data_i     or
                   uart_data_out     or
                   timer_data_out    or
                   cyc_data_out      or
                   ins_data_out      or
                   eae_data_out      or
                   sd_data_out       or
                   int_data_out      or
                   sys_data_out;

  -- QNICE CPU
  cpu : entity work.qnice_cpu
    port map (
      clk            => clk_i,
      reset          => rst,
      wait_for_data  => cpu_wait_for_data,
      addr           => cpu_addr,
      data_in        => cpu_data_in,
      data_out       => cpu_data_out,
      data_dir       => cpu_data_dir,
      data_valid     => cpu_data_valid,
      halt           => cpu_halt,
      ins_cnt_strobe => cpu_ins_cnt_strobe,
      int_n          => cpu_int_n,
      igrant_n       => cpu_igrant_n
    );

  -- ROM: up to 64kB consisting of up to 32.000 16 bit words
  rom : entity work.brom
    generic map (
      FILE_NAME => ROM_FILE
    )
    port map (
      clk     => clk_i,
      ce      => rom_enable,
      address => cpu_addr(14 downto 0),
      data    => rom_data_out,
      busy    => rom_busy
    );

  -- RAM: up to 64kB consisting of up to 32.000 16 bit words
  ram : entity work.bram
    port map (
      clk     => clk_i,
      ce      => ram_enable,
      address => cpu_addr(14 downto 0),
      we      => cpu_data_dir,
      data_i  => cpu_data_out,
      data_o  => ram_data_out,
      busy    => ram_busy
    );

  -- PORE ROM: Power On & Reset Execution ROM
  -- contains code that is executed during power on and/or during reset
  -- MMIO is managing the PORE process
  pore_rom : entity work.brom
    generic map (
      FILE_NAME => PORE_ROM_FILE
    )
    port map (
      clk     => clk_i,
      ce      => pore_rom_enable,
      address => cpu_addr(14 downto 0),
      data    => pore_rom_data_out,
      busy    => pore_rom_busy
    );

  -- TIL display emulation (4 digits)
  til_leds : entity work.til_display
    port map (
      clk             => clk_i,
      reset           => rst,
      til_reg0_enable => i_til_reg0_enable,
      til_reg1_enable => til_reg1_enable,
      data_in         => i_til_data_in,
      sseg_an         => sseg_an_o,
      sseg_ca         => sseg_ca_o
    );

  -- special UART with FIFO that can be directly connected to the CPU bus
  uart : entity work.bus_uart
    port map (
      clk          => clk_i,
      reset        => rst,
      fast         => switches_i(3),
      rx           => uart_rxd_i,
      tx           => uart_txd_o,
      rts          => uart_rts_i,
      cts          => uart_cts_o,
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
      clk          => clk_i,
      reset        => rst,
      ps2_clk      => ps2_clk_i,
      ps2_data     => ps2_dat_i,
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
      clk         => clk_i,
      reset       => rst,
      int_n_out   => vga_right_int_n_o,
      grant_n_in  => vga_right_igrant_n_i,
      int_n_in    => '1',
      grant_n_out => open,
      en          => tin_en,
      we          => tin_we,
      reg         => tin_reg,
      data_in     => cpu_data_out,
      data_out    => timer_data_out
    );

  -- cycle counter
  cyc : entity work.cycle_counter
    port map (
      clk      => clk_i,
      impulse  => '1',
      reset    => rst,
      en       => cyc_en,
      we       => cyc_we,
      reg      => cyc_reg,
      data_in  => cpu_data_out,
      data_out => cyc_data_out
    );

  -- instruction counter
  ins : entity work.cycle_counter
    port map (
      clk      => clk_i,
      impulse  => cpu_ins_cnt_strobe,
      reset    => rst,
      en       => ins_en,
      we       => ins_we,
      reg      => ins_reg,
      data_in  => cpu_data_out,
      data_out => ins_data_out
    );

  -- EAE - Extended Arithmetic Element (32-bit multiplication, division, modulo)
  eae_inst : entity work.eae
    port map (
      clk      => clk_i,
      reset    => rst,
      en       => eae_en,
      we       => eae_we,
      reg      => eae_reg,
      data_in  => cpu_data_out,
      data_out => eae_data_out
    );

  -- SYSINFO
  sys_inst : entity work.sysinfo
    port map (
      clk      => clk_i,
      reset    => rst,
      en       => sys_en,
      we       => sys_we,
      reg      => sys_reg,
      data_in  => cpu_data_out,
      data_out => sys_data_out
    );

  -- SD Card
  sd_card : entity work.sdcard
    port map (
      clk      => clk_i,
      reset    => rst,
      en       => sd_en,
      we       => sd_we,
      reg      => sd_reg,
      data_in  => cpu_data_out,
      data_out => sd_data_out,
      sd_reset => sd_reset_o,
      sd_clk   => sd_clk_o,
      sd_mosi  => sd_mosi_o,
      sd_miso  => sd_miso_i
    );

  interrupt_controller : entity work.interrupt_controller
    port map (
      clk_i     => clk_i,
      rst_i     => rst,
      en_i      => int_en,
      we_i      => int_we,
      reg_i     => int_reg,
      data_i    => cpu_data_out,
      data_o    => int_data_out,
      int_n_o   => cpu_int_n,
      grant_n_i => cpu_igrant_n,
      int_n_i   => vga_left_int_n_i,
      grant_n_o => vga_left_igrant_n_o
    );

  -- memory mapped i/o controller
  hw_reset <= not reset_n_i;
  mmio_controller : entity work.mmio_mux
    generic map (
      GD_PORE     => true, -- yes, use PORE system
      GD_TIL      => true, -- yes, support TIL leds
      GD_SWITCHES => true, -- yes, support SWITCHES
      GD_HRAM     => false -- no, do not support HyperRAM
    )
    port map (
      hw_reset          => hw_reset,
      clk               => clk_i, -- @TODO change debouncer bitsize when going to 100 MHz
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
      vga_en            => vga_en_o,
      vga_we            => vga_we_o,
      vga_reg           => vga_reg_o,
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
      reset_ctl         => rst,
      reset_pre_pore    => open,
      reset_post_pore   => open,

      -- no HyperRAM available
      hram_en           => open,
      hram_we           => open,
      hram_reg          => open,
      hram_cpu_ws       => '0'
    );

  -- emulate the toggle switches as described in doc/README.md
  switch_driver : process (switch_reg_enable, switches_i)
  begin
    if switch_reg_enable = '1' then
      switch_data_out <= switches_i;
    else
      switch_data_out <= (others => '0');
    end if;
  end process switch_driver;

  -- debug mode handling: if switch 2 is on then:
  --   show the current cpu address in realtime on the LEDs
  --   on halt show the PC of the HALT command (aka address bus value) on TIL
  debug_mode_handler : process (switches_i, cpu_addr, cpu_data_out, cpu_halt, til_reg0_enable)
  begin
    i_til_reg0_enable <= til_reg0_enable;
    i_til_data_in     <= cpu_data_out;
    leds_o            <= cpu_halt & "000000000000000";

    -- debug mode
    if switches_i(2) = '1' then
      leds_o <= cpu_addr;

      if cpu_halt = '1' then
        i_til_reg0_enable <= '1';
        i_til_data_in     <= cpu_addr;
      end if;
    end if;
  end process debug_mode_handler;

  -- pull DAT1, DAT2 and DAT3 to GND (Nexys' pull-ups by default pull to VDD)
  sd_dat_o <= "000";

end architecture rtl;

