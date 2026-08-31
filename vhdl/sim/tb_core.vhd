library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use std.textio.all;

entity tb_core is
end entity tb_core;

architecture tb of tb_core is

  signal clk     : std_logic := '1';
  signal reset_n : std_logic := '0';
  signal rst     : std_logic := '1';

  signal uart_tx_valid : std_logic := '0';
  signal uart_tx_ready : std_logic;
  signal uart_tx_data  : std_logic_vector(7 downto 0);
  signal uart_rx_valid : std_logic;
  signal uart_rx_ready : std_logic := '1';
  signal uart_rx_data  : std_logic_vector(7 downto 0);
  signal uart_tx       : std_logic;
  signal uart_rx       : std_logic;

begin

  clk     <= not clk after 10 ns;
  reset_n <= '0', '1' after 100 ns;

  core_inst : entity work.core
    port map (
      clk_i                => clk,
      reset_n_i            => reset_n,
      rst_o                => rst,
      sseg_an_o            => open,
      sseg_ca_o            => open,
      uart_rxd_i           => uart_tx,
      uart_txd_o           => uart_rx,
      uart_rts_i           => '1',
      uart_cts_o           => open,
      switches_i           => X"0008",
      leds_o               => open,
      ps2_clk_i            => '1',
      ps2_dat_i            => '1',
      vga_en_o             => open,
      vga_we_o             => open,
      vga_reg_o            => open,
      vga_wr_data_o        => open,
      vga_rd_data_i        => X"0000",
      vga_right_int_n_o    => open,
      vga_right_igrant_n_i => '1',
      vga_left_int_n_i     => '1',
      vga_left_igrant_n_o  => open,
      sd_reset_o           => open,
      sd_clk_o             => open,
      sd_mosi_o            => open,
      sd_miso_i            => '1',
      sd_dat_o             => open
    ); -- core_inst

  uart_inst : entity work.uart
    generic map (
      G_DIVISOR => 50_000_000 / 1_000_000
    )
    port map (
      clk_i      => clk,
      rst_i      => rst,
      tx_valid_i => uart_tx_valid,
      tx_ready_o => uart_tx_ready,
      tx_data_i  => uart_tx_data,
      rx_valid_o => uart_rx_valid,
      rx_ready_i => uart_rx_ready,
      rx_data_o  => uart_rx_data,
      uart_tx_o  => uart_tx,
      uart_rx_i  => uart_rx
    ); -- uart_inst

  uart_proc : process (clk)
    variable out_line : line;
  begin
    if rising_edge(clk) then
      if uart_rx_valid = '1' and uart_rx_ready = '1' then
        if uart_rx_data /= X"0D" then
          write(out_line, character'val(to_integer(unsigned(uart_rx_data))));
          if uart_rx_data = X"0A" then
            report out_line.all;
            deallocate(out_line);
          end if;
        end if;
      end if;
    end if;
  end process uart_proc;

end architecture tb;

