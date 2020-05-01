library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;

package cache_row_type is
type cache_row_t is array (0 to 7) of unsigned(7 downto 0);
end package cache_row_type;

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use ieee.numeric_std.all;
use work.cache_row_type.all;
--use Std.TextIO.all;
--use work.debugtools.all;
--use work.cputypes.all;

entity hyperram is
  Port ( pixelclock : in std_logic; -- For slow devices bus interface is
         -- actually on pixelclock to reduce latencies
         -- Also pixelclock is the natural clock speed we apply to the HyperRAM.
         clock163 : in std_logic; -- Used for fast clock for HyperRAM
         clock325 : in std_logic; -- Used for fast clock for HyperRAM SERDES units

         -- Simple counter for number of requests received
         request_counter : out std_logic := '0';
         
         read_request : in std_logic;
         write_request : in std_logic;
         address : in unsigned(26 downto 0);
         wdata : in unsigned(7 downto 0);
         
         rdata : out unsigned(7 downto 0);
         data_ready_strobe : out std_logic := '0';
         busy : out std_logic := '0';

         -- Export current cache line for speeding up reads from slow_devices controller
         -- by skipping the need to hand us the request and get the response back.
         current_cache_line : out cache_row_t := (others => (others => '0'));
         current_cache_line_address : inout unsigned(26 downto 3) := (others => '0');
         current_cache_line_valid : out std_logic := '0';
         
         hr_d : inout unsigned(7 downto 0) := (others => 'Z'); -- Data/Address
         hr_rwds : inout std_logic := 'Z'; -- RW Data strobe
         hr_reset : out std_logic := '1'; -- Active low RESET line to HyperRAM
         hr_clk_n : out std_logic := '0';
         hr_clk_p : out std_logic := '1';

         hr2_d : inout unsigned(7 downto 0) := (others => 'Z'); -- Data/Address
         hr2_rwds : inout std_logic := 'Z'; -- RW Data strobe
         hr2_reset : out std_logic := '1'; -- Active low RESET line to HyperRAM
         hr2_clk_n : out std_logic := '0';
         hr2_clk_p : out std_logic := '1';


         hr_cs0 : out std_logic := '1';
         hr_cs1 : out std_logic := '1'
         );
end hyperram;

architecture gothic of hyperram is

  type state_t is (
    Idle,
    ReadSetup,
    WriteSetup,
    HyperRAMOutputCommand,
    HyperRAMDoWrite,
    HyperRAMOutputCommandSlow,
    StartBackgroundWrite,
    HyperRAMDoWriteSlow,
    HyperRAMFinishWriting,
    HyperRAMReadWaitSlow,
    HyperRAMReadWait
    );

  -- How many clock ticks need to expire between transactions to satisfy T_RWR
  -- of hyperrram for the T_RWR 40ns delay.
  -- We can also subtract one cycle for the time it takes to pull CS low, and then
  -- two more for the clocks before the critical moment, and one more for time
  -- covered by various latencies in the system (including clock 1/2 cycle delay).
  -- This effectively gets us down to 45ns. Taking another cycle would leave us
  -- at only 38.7ns, which is a bit too short.
  -- This gives us an effective 8-byte write latency of ~132ns = ~7.5MHz.
  -- For read it is ~143ns = 6.99MHz, which might just be a whisker too slow
  -- for MiniMig.  By reading only 4 bytes instead of 8, this would allow getting
  -- back down to ~120 -- 132ns, which should be enough.
  -- Actually, all of that is a bit moot, since it seems that we just have to apply
  -- some trial and error to get it right. 1 seems right with the current settings.
  signal rwr_delay : unsigned(7 downto 0) := to_unsigned(1,8);
  signal rwr_counter : unsigned(7 downto 0) := (others => '0');

  -- We prime the HyperRAM controller to set the value of CR0 initially on
  -- power up to minimise latency.
  
  
  signal state : state_t := WriteSetup;
  signal busy_internal : std_logic := '1';
  signal hr_command : unsigned(47 downto 0);

  signal hr_d_last : unsigned(7 downto 0);
  
  -- Used to assert CS line on BOTH hyperRAM modules at the same time
  -- when doing the initial configuration register write.
  signal first_transaction : std_logic := '1';
  
  -- Initial transaction is config register write
  signal config_reg_write : std_logic := '1';
  signal ram_address : unsigned(26 downto 0) :=
    "010000000000001000000000000"; -- = bottom 27 bits of x"A001000";
  signal ram_wdata : unsigned(7 downto 0) := x"00";
  signal ram_reading : std_logic := '0';
  signal ram_reading_held : std_logic := '0';

  -- We want to set config register 0 to $ffe6, to enable variable latency
  -- and 3 cycles instead of 6 for latency. This speeds up writing almost 2x.
  -- But at 80MHz instead of 40MHz bus, we have to increase the latency from
  -- 3 to 4 cycles to satisfy the 40ns minimum time requirement.
  -- This also sets the drive strength to the maximum, to get cleaner faster
  -- clock transitions. This fixes checkerboard read errors at 80MHz.
  
  signal conf_buf0 : unsigned(7 downto 0) := x"ff";
  signal conf_buf1 : unsigned(7 downto 0) := x"f6";
  signal conf_buf0_in : unsigned(7 downto 0) := x"ff";
  signal conf_buf1_in : unsigned(7 downto 0) := x"f6";
  signal conf_buf0_set : std_logic := '0';
  signal conf_buf1_set : std_logic := '0';
  signal last_conf_buf0_set : std_logic := '0';
  signal last_conf_buf1_set : std_logic := '0';

  -- 4 is correct for the part we have in the MEGA65, after we have set the
  -- config register to minimise latency.
  signal write_latency : unsigned(7 downto 0) := to_unsigned(5,8);
  -- And the matching extra latency is 5
  signal extra_write_latency : unsigned(7 downto 0) := to_unsigned(7,8);

  -- And for the 2nd trap-door hyperram.
  -- That module from 1BitSquared uses a different brand of hyperram
  -- and seems to have different timing.
  signal write_latency2 : unsigned(7 downto 0) := to_unsigned(1,8);
  signal extra_write_latency2 : unsigned(7 downto 0) := to_unsigned(3,8);

  
  signal fast_cmd_mode : std_logic := '0';
  signal fast_read_mode : std_logic := '1';
  signal fast_write_mode : std_logic := '0';
  signal read_phase_shift : std_logic := '1';
  signal write_phase_shift : std_logic := '1';
  signal byte0_fix : std_logic := '1';
  
  signal countdown : integer := 0;
  signal extra_latency : std_logic := '0';
  signal countdown_timeout : std_logic := '0';

  signal pause_phase : std_logic := '0';
  signal hr_clock : std_logic := '0';

  signal data_ready_toggle : std_logic := '0';
  signal last_data_ready_toggle : std_logic := '0';
  signal data_ready_strobe_hold : std_logic := '0';

  signal request_toggle : std_logic := '0';
  signal request_accepted : std_logic := '0';
  signal last_request_toggle : std_logic := '0';

  signal byte_phase : unsigned(5 downto 0) := to_unsigned(0,6);
  signal write_byte_phase : std_logic := '0';

  signal hr_ddr : std_logic := '0';
  signal hr_rwds_ddr : std_logic := '0';
  signal hr_reset_int : std_logic := '1';
  signal hr_rwds_int : std_logic := '0';
  signal hr_cs0_int : std_logic := '0';
  signal hr_cs1_int : std_logic := '0';
  signal hr_clk_p_int : std_logic := '0';
  signal hr_clk_n_int : std_logic := '0';

  signal cycle_count : integer := 0;

  -- Have a tiny little cache to reduce latency
  -- 8 byte cache rows, where we indicate the validity of
  -- each byte.
  signal cache_row0_valids : std_logic_vector(0 to 7) := (others => '0');
  signal cache_row0_address : unsigned(23 downto 0) := (others => '1');  
  signal cache_row0_data : cache_row_t := ( others => x"00" );

  signal cache_row1_valids : std_logic_vector(0 to 7) := (others => '0');
  signal cache_row1_address : unsigned(23 downto 0) := (others => '1');  
  signal cache_row1_data : cache_row_t := ( others => x"00" );

  -- Collect writes together to hide write latency
  signal write_collect0_dispatchable : std_logic := '0';
  signal write_collect0_address : unsigned(26 downto 3) := (others => '0');  
  signal write_collect0_valids : std_logic_vector(0 to 7) := (others => '0');
  signal write_collect0_data : cache_row_t := ( others => x"00" );
  signal write_collect0_toolate : std_logic := '0'; -- Set when its too late to
                                                    -- add more bytes to the write.
  signal write_collect0_flushed : std_logic := '1';

  signal write_collect1_dispatchable : std_logic := '0';
  signal write_collect1_address : unsigned(26 downto 3) := (others => '0');  
  signal write_collect1_valids : std_logic_vector(0 to 7) := (others => '0');
  signal write_collect1_data : cache_row_t := ( others => x"00" );
  signal write_collect1_toolate : std_logic := '0'; -- Set when its too late to
                                                    -- add more bytes to the write.
  signal write_collect1_flushed : std_logic := '1';
  

  type block_t is array (0 to 3) of cache_row_t;
  signal block_data : block_t := (others => (others => x"00"));
  signal block_address : unsigned(26 downto 5);
  signal block_valid : std_logic := '0';
  signal is_block_read : boolean := false;
  signal block_read_enable : std_logic := '1'; -- enable 32 byte read block fetching
  signal is_prefetch : boolean := false;
  signal ram_prefetch : boolean := false;
  signal flag_prefetch : std_logic := '1';  -- enable/disable prefetch of read
                                            -- blocks

  signal current_cache_line_update : cache_row_t := (others => (others => '0'));
  signal current_cache_line_new_address : unsigned(26 downto 3) := (others => '0');
  signal current_cache_line_update_all : std_logic := '0';
  signal current_cache_line_update_flags : std_logic_vector(0 to 7) := (others => '0');
  signal last_current_cache_line_update_all : std_logic := '0';
  signal last_current_cache_line_update_flags : std_logic_vector(0 to 7) := (others => '0');

  signal cache_row_update_toggle : std_logic := '0';
  signal last_cache_row_update_toggle : std_logic := '0';
  signal cache_row_update_address : unsigned(26 downto 3) := (others => '0');
  signal cache_row_update_byte : integer range 0 to 7 := 0;
  signal cache_row_update_value : unsigned(7 downto 0) := x"00";
  
  signal last_rwds : std_logic := '0';

  signal fake_data_ready_strobe : std_logic := '0';
  signal fake_rdata : unsigned(7 downto 0) := x"00";

  signal request_counter_int : std_logic := '0';

  signal cache_enabled : boolean := true;

  signal hr_rwds_high_seen : std_logic := '0';

  signal random_bits : unsigned(7 downto 0) := x"00";

  signal write_blocked : std_logic := '0';

  signal background_write : std_logic := '0';
  signal background_write_source : std_logic := '0';
  signal background_write_valids : std_logic_vector(0 to 7) := x"00";
  signal background_write_data : cache_row_t := (others => (others => '0'));
  signal background_write_count : integer range 0 to 6 := 0;

  -- If we get too many writes in short succession, we may need to queue up one
  -- of the writes, while waiting for slow_devices to notice
  signal queued_write : std_logic := '0';
  signal queued_wdata : unsigned(7 downto 0) := x"00";
  signal queued_waddr : unsigned(26 downto 0) := to_unsigned(0,27);

  -- Delay sending of the initial configuration write command
  -- to give the HyperRAM chip time to start up
  -- Datasheet says 150usec is required, we do that, plus a bit.
  signal start_delay_counter : integer
    := 150*(1000/162)+20
    -- plus a correction factor to get initial config register write correctly
    -- aligned with the clock
    +3;
  -- phaseshift has to also start at 1 for the above to work.
  signal hr_clk_phaseshift : std_logic := '1';
  signal hr_clk_phaseshift_current : std_logic := '1';
  signal last_hr_clk_phaseshift : std_logic := '1';
  
  signal hr_clk_fast : std_logic := '1';
  signal hr_clk_fast_current : std_logic := '1';
  signal hr_clk : std_logic := '0';

  signal hr_clock_phase : unsigned(2 downto 0) := "000";

  signal hyperram2_select : std_logic := '0';
  
  signal read_time_adjust : integer range 0 to 255 := 1;

begin
  process (pixelclock,clock163,clock325,hr_clk,hr_clk_phaseshift) is
    variable clock_status_vector : unsigned(4 downto 0);
    variable tempaddr : unsigned(26 downto 0);
  begin
    if rising_edge(pixelclock) then

--      report "read_request=" & std_logic'image(read_request) & ", busy_internal=" & std_logic'image(busy_internal)
--        & ", write_request=" & std_logic'image(write_request);

      -- Pseudo random bits so that we can do randomised cache row replacement
      if random_bits /= to_unsigned(251,8) then
        random_bits <= random_bits + 1;
      else
        random_bits <= x"00";
      end if;
      
      busy <= busy_internal or write_blocked or queued_write;

      -- Clear write block as soon as either write buffer clears
      if (write_collect0_dispatchable='0' and write_collect0_toolate='0' and write_collect0_flushed='0')
        or (write_collect1_dispatchable='0' and write_collect1_toolate='0' and write_collect1_flushed='0')
      then
        write_blocked <= queued_write;
      else
        write_blocked <= '1';
        busy <= '1';
      end if;

      fake_data_ready_strobe <= '0';

      if read_request = '1' or write_request = '1' then
        request_counter_int <= not request_counter_int;
        request_counter <= request_counter_int;
      end if;
      
--      report "CACHE cache0: address=$" & to_hstring(cache_row0_address&"000") & ", valids=" & to_string(cache_row0_valids)
--        & ", data = "
--        & to_hstring(cache_row0_data(0)) & " "
--        & to_hstring(cache_row0_data(1)) & " "
--        & to_hstring(cache_row0_data(2)) & " "
--        & to_hstring(cache_row0_data(3)) & " "
--        & to_hstring(cache_row0_data(4)) & " "
--        & to_hstring(cache_row0_data(5)) & " "
--        & to_hstring(cache_row0_data(6)) & " "
--        & to_hstring(cache_row0_data(7)) & " ";
--      report "CACHE cache1: address=$" & to_hstring(cache_row1_address&"000") & ", valids=" & to_string(cache_row1_valids)
--        & ", data = "
--        & to_hstring(cache_row1_data(0)) & " "
--        & to_hstring(cache_row1_data(1)) & " "
--        & to_hstring(cache_row1_data(2)) & " "
--        & to_hstring(cache_row1_data(3)) & " "
--        & to_hstring(cache_row1_data(4)) & " "
--        & to_hstring(cache_row1_data(5)) & " "
--        & to_hstring(cache_row1_data(6)) & " "
--        & to_hstring(cache_row1_data(7)) & " ";
--      report "CACHE write0: $" & to_hstring(write_collect0_address&"000") & ", v=" & to_string(write_collect0_valids)
--        & ", d=" & std_logic'image(write_collect0_dispatchable)
--        & ", late=" & std_logic'image(write_collect0_toolate)
--        & ", fl=" & std_logic'image(write_collect0_flushed)
--        & ", data = "
--        & to_hstring(write_collect0_data(0)) & " "
--        & to_hstring(write_collect0_data(1)) & " "
--        & to_hstring(write_collect0_data(2)) & " "
--        & to_hstring(write_collect0_data(3)) & " "
--        & to_hstring(write_collect0_data(4)) & " "
--        & to_hstring(write_collect0_data(5)) & " "
--        & to_hstring(write_collect0_data(6)) & " "
--        & to_hstring(write_collect0_data(7)) & " ";
--      report "CACHE write1: $" & to_hstring(write_collect1_address&"000") & ", v=" & to_string(write_collect1_valids)
--        & ", d=" & std_logic'image(write_collect1_dispatchable)
--        & ", late=" & std_logic'image(write_collect1_toolate)
--        & ", fl=" & std_logic'image(write_collect1_flushed)
--        & ", data = "
--        & to_hstring(write_collect1_data(0)) & " "
--        & to_hstring(write_collect1_data(1)) & " "
--        & to_hstring(write_collect1_data(2)) & " "
--        & to_hstring(write_collect1_data(3)) & " "
--        & to_hstring(write_collect1_data(4)) & " "
--        & to_hstring(write_collect1_data(5)) & " "
--        & to_hstring(write_collect1_data(6)) & " "
--        & to_hstring(write_collect1_data(7)) & " ";
--      report "CACHE block0: $" & to_hstring(block_address&"00000") & ", valid=" & std_logic'image(block_valid);
--      for i in 0 to 3 loop
--        report "CACHE block0 segment " & integer'image(i) & ": "
--        & to_hstring(block_data(i)(0)) & " "
--        & to_hstring(block_data(i)(1)) & " "
--        & to_hstring(block_data(i)(2)) & " "
--        & to_hstring(block_data(i)(3)) & " "
--        & to_hstring(block_data(i)(4)) & " "
--        & to_hstring(block_data(i)(5)) & " "
--        & to_hstring(block_data(i)(6)) & " "
--        & to_hstring(block_data(i)(7)) & " ";
--        
--      end loop;
      

      -- Clear write buffers once they have been flushed.
      -- We have to wipe the address and valids, so that they don't get stuck being
      -- used as stale sources for cache reading.
      if write_collect0_dispatchable = '1' and write_collect0_toolate <= '1' and write_collect0_flushed = '1' then
        write_collect0_dispatchable <= '0';
        write_collect0_address <= (others => '1');
        write_collect0_valids <= (others => '0');
      end if;
      if write_collect1_dispatchable = '1' and write_collect1_toolate <= '1' and write_collect1_flushed = '1' then
        write_collect1_dispatchable <= '0';
        write_collect1_address <= (others => '1');            
        write_collect1_valids <= (others => '0');
      end if;      

      if read_request='1' and busy_internal='0' and ((is_block_read = false) or (block_address /= address(26 downto 5))) then
        --report "Making read request";
        -- Begin read request

        -- Check for cache read
        -- We check the write buffers first, as any contents that they have
        -- must take priority over everything else
        if (block_valid='1') and (address(26 downto 5) = block_address) then
          fake_data_ready_strobe <= '1';
          fake_rdata <= block_data(to_integer(address(4 downto 3)))(to_integer(address(2 downto 0)));
          --report "DISPATCH: Returning data $"
          --  & to_hstring(block_data(to_integer(address(4 downto 3)))(to_integer(address(2 downto 0))))
          --  & " from read block.";
          -- Now update current cache line to speed up subsequent reads
          current_cache_line_update <= block_data(to_integer(address(4 downto 3)));
          current_cache_line_new_address <= address(26 downto 3);
          current_cache_line_update_all <= not current_cache_line_update_all;

          if (address(4 downto 3) = "11") and (flag_prefetch='1') then
            -- When attempting to read from the last 8 bytes of a block read,
            -- we schedule a pre-fetch of the next 32 bytes, so that we can hide
            -- the read latency as much as possible.
            ram_reading <= '1';
            tempaddr(26 downto 5) := address(26 downto 5) + 1;
            tempaddr(4 downto 0) := "00000";
            ram_address <= tempaddr;
            request_toggle <= not request_toggle;          
            ram_prefetch <= true;
            --report "DISPATCH: Dispatching pre-fetch of $" & to_hstring(tempaddr);
          end if;
          
        elsif cache_enabled and (address(26 downto 3 ) = write_collect0_address and write_collect0_valids(to_integer(address(2 downto 0))) = '1') then
          -- Write cache read-back
          fake_data_ready_strobe <= '1';
          fake_rdata <= write_collect0_data(to_integer(address(2 downto 0)));
          --report "DISPATCH: Returning data $"& to_hstring(write_collect0_data(to_integer(address(2 downto 0))))&" from write collect0";
        elsif cache_enabled and (address(26 downto 3 ) = write_collect1_address and write_collect1_valids(to_integer(address(2 downto 0))) = '1') then
          -- Write cache read-back
          fake_data_ready_strobe <= '1';
          fake_rdata <= write_collect1_data(to_integer(address(2 downto 0)));
          --report "DISPATCH: Returning data $"& to_hstring(write_collect1_data(to_integer(address(2 downto 0))))&" from write collect1";
        elsif cache_enabled and (address(26 downto 3 ) = cache_row0_address and cache_row0_valids(to_integer(address(2 downto 0))) = '1') then
          -- Cache read
          fake_data_ready_strobe <= '1';
          fake_rdata <= cache_row0_data(to_integer(address(2 downto 0)));
          --report "DISPATCH: Returning data $"& to_hstring(cache_row0_data(to_integer(address(2 downto 0))))&" from cache row0";
        elsif cache_enabled and (address(26 downto 3 ) = cache_row1_address and cache_row1_valids(to_integer(address(2 downto 0))) = '1') then
          -- Cache read
          fake_data_ready_strobe <= '1';
          fake_rdata <= cache_row1_data(to_integer(address(2 downto 0)));
          --report "DISPATCH: Returning data $"& to_hstring(cache_row1_data(to_integer(address(2 downto 0))))&" from cache row1";
        elsif address(23 downto 4) = x"FFFFF" and address(25 downto 24) = "11" then
          -- Allow reading from dummy debug bitbash registers at $BFFFFFx
          case address(3 downto 0) is
            when x"0" =>
              fake_rdata <= unsigned(cache_row1_valids);
            when x"1" =>
              fake_rdata <= hr_d;
            when x"2" =>
              fake_rdata(0) <= fast_cmd_mode;
              fake_rdata(1) <= fast_read_mode;
              fake_rdata(2) <= fast_write_mode;
              fake_rdata(3) <= read_phase_shift;
              fake_rdata(4) <= block_read_enable;
              fake_rdata(5) <= flag_prefetch;
              fake_rdata(6) <= byte0_fix;
              if cache_enabled then
                fake_rdata(7) <= '1';
              else
                fake_rdata(7) <= '0';
              end if;
            when x"3" =>
              fake_rdata <= write_latency;
            when x"4" =>
              fake_rdata <= extra_write_latency;
            when x"5" =>
              fake_rdata <= to_unsigned(read_time_adjust,8);
            when x"6" =>
              fake_rdata <= rwr_delay;
            when x"7" =>
              fake_rdata <= unsigned(cache_row0_valids);
            when x"8" =>
              fake_rdata <= conf_buf0;
            when x"9" =>
              fake_rdata <= conf_buf1;

            when x"a" =>
              fake_rdata <= cache_row0_address(7 downto 0);
            when x"b" =>
              fake_rdata <= cache_row0_address(15 downto 8);
            when x"c" =>
              fake_rdata <= cache_row0_address(23 downto 16);

            when x"d" =>
              fake_rdata <= write_latency2;
            when x"e" =>
              fake_rdata <= extra_write_latency2;
            when x"f" =>
              fake_rdata <= x"00";
              
              
            when others =>
              -- This seems to be what gets returned all the time
              fake_rdata <= x"42";
          end case;
          fake_data_ready_strobe <= '1';
          --report "asserting data_ready_strobe for fake read";
        elsif request_accepted = request_toggle then
          --report "request_toggle flipped";
          ram_reading <= '1';
          ram_address <= address;
          ram_prefetch <= false;
          request_toggle <= not request_toggle;          
        end if;
      elsif queued_write='1' and write_collect0_dispatchable='0' and write_collect0_flushed='0'
        and write_collect0_toolate='0' then

        --report "DISPATCH: Executing queued write to $" & to_hstring(queued_waddr);
        
        -- Push it out as a normal batched write, that can collect others if they
        -- come soon enough.
        
        write_collect0_valids <= (others => '0');
        write_collect0_valids(to_integer(queued_waddr(2 downto 0))) <= '1';
        write_collect0_data(to_integer(queued_waddr(2 downto 0))) <= queued_wdata;
        write_collect0_address <= queued_waddr(26 downto 3);
        write_collect0_dispatchable <= '1';

        queued_write <= '0';
        
      elsif write_request='1' and busy_internal='0' then
        --report "Making write request: addr $" & to_hstring(address) & " <= " & to_hstring(wdata);
        -- Begin write request
        -- Latch address and data

        if address(23 downto 4) = x"FFFFF" and address(25 downto 24) = "11" then
          case address(3 downto 0) is
            when x"0" =>
              null;
            when x"1" =>
              null;
            when x"2" =>
              fast_cmd_mode <= wdata(0);
              fast_read_mode <= wdata(1);
              fast_write_mode <= wdata(2);
              read_phase_shift <= wdata(3);
              block_read_enable <= wdata(4);
              flag_prefetch <= wdata(5);
              byte0_fix <= wdata(6);
              if wdata(7)='1' then
                cache_enabled <= true;
              else
                cache_enabled <= false;
              end if;
            when x"3" =>
              write_latency <= wdata;
            when x"4" =>
              extra_write_latency <= wdata;
            when x"5" =>
              read_time_adjust <= to_integer(wdata);
            when x"6" =>
              rwr_delay <= wdata;
            when x"8" =>
              conf_buf0_in <= wdata;
              conf_buf0_set <= not conf_buf0_set;
            when x"9" =>
              conf_buf1_in <= wdata;              
              conf_buf1_set <= not conf_buf1_set;
            when x"d" =>
              write_latency2 <= wdata;
            when x"e" =>
              extra_write_latency2 <= wdata;
            when others =>
              null;
          end case;
          fake_data_ready_strobe <= '1';
        else
          if cache_enabled = false then
            -- Do normal  write request
            --report "request_toggle flipped";
            ram_prefetch <= false;
            request_toggle <= not request_toggle;
            
          else
            -- Collect writes together for dispatch

            -- Can we add the write to an existing collected write?
            if write_collect0_toolate = '0' and write_collect0_address = address(26 downto 3)
              and write_collect0_dispatchable = '1' and write_collect0_toolate='0' then
              write_collect0_valids(to_integer(address(2 downto 0))) <= '1';
              write_collect0_data(to_integer(address(2 downto 0))) <= wdata;
            elsif write_collect1_toolate = '0' and write_collect1_address = address(26 downto 3)
              and write_collect1_dispatchable = '1' and write_collect1_toolate='0' then
              write_collect1_valids(to_integer(address(2 downto 0))) <= '1';
              write_collect1_data(to_integer(address(2 downto 0))) <= wdata;
            elsif write_collect0_dispatchable = '0' and write_collect0_toolate='0' then
              write_collect0_valids <= (others => '0');
              write_collect0_valids(to_integer(address(2 downto 0))) <= '1';
              write_collect0_data(to_integer(address(2 downto 0))) <= wdata;
              write_collect0_address <= address(26 downto 3);
              write_collect0_dispatchable <= '1';
              -- Block further writes if we already have one busy write buffer
              write_blocked <= '1';
            elsif write_collect1_dispatchable = '0' and write_collect1_toolate='0' then
              write_collect1_valids <= (others => '0');
              write_collect1_valids(to_integer(address(2 downto 0))) <= '1';
              write_collect1_data(to_integer(address(2 downto 0))) <= wdata;
              write_collect1_address <= address(26 downto 3);
              write_collect1_dispatchable <= '1';
              -- Block further writes if we already have one busy write buffer
              write_blocked <= '1';
            else
              -- No write collection point that we can use, so just block until
              -- one becomes available
--              report "DISPATCH: Write blocked due to busy write buffers: " &
--                " addr $" & to_hstring(address) & " <= " & to_hstring(wdata);
              queued_waddr <= address;
              queued_wdata <= wdata;
              queued_write <= '1';
            end if;

            -- Update short-circuit cache line
            -- (We don't change validity, since we don't know if it is
            -- valid or not).
            if address(26 downto 3) = current_cache_line_address(26 downto 3) then
              current_cache_line_update(to_integer(address(2 downto 0))) <= wdata;
              current_cache_line_update_flags(to_integer(address(2 downto 0))) <=
                not current_cache_line_update_flags(to_integer(address(2 downto 0)));
            end if;
            
            -- Update read cache structures when writing
            cache_row_update_address <= address(26 downto 3);
            cache_row_update_byte <= to_integer(address(2 downto 0));
            cache_row_update_value <= wdata;
            cache_row_update_toggle <= not cache_row_update_toggle;

          end if;
        end if;        
      else
        -- Nothing new to do
        if data_ready_toggle /= last_data_ready_toggle then
          last_data_ready_toggle <= data_ready_toggle;
          fake_data_ready_strobe <= '1';
        end if;
      end if;

    end if;
    -- Optionally delay HR_CLK by 1/2 an 160MHz clock cycle
    -- (actually just by optionally inverting it)
    if rising_edge(clock325) then
      hr_clock_phase <= hr_clock_phase + 1;
      -- Changing at the end of a phase cycle prevents us having any
      -- problematically short clock pulses when it matters.
      if hr_clock_phase="111" then
        hr_clk_fast_current <= hr_clk_fast;
        hr_clk_phaseshift_current <= hr_clk_phaseshift;
        if hr_clk_fast /= hr_clk_fast_current or hr_clk_phaseshift_current /= hr_clk_phaseshift then
--          report "Updating hr_clock_fast to " & std_logic'image(hr_clk_fast)
--            & ", hr_clk_phaseshift to " & std_logic'image(hr_clk_phaseshift);
        end if;
      end if;

      -- Only change clock mode when safe to do so
      clock_status_vector(4) := hr_clk_fast_current;
      clock_status_vector(3) := hr_clk_phaseshift_current;
      clock_status_vector(2 downto 0) := hr_clock_phase;
--      report "clock phase vector = " & to_string(std_logic_vector(clock_status_vector));
      case clock_status_vector is        
        -- Slow clock rate, no phase shift
        when "00000" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
        when "00001" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
        when "00010" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
        when "00011" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
        when "00100" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
        when "00101" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
        when "00110" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
        when "00111" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
                        
        -- Slow clock rate, with phase shift = bring forward tick by 1/2 a cycle
        when "01000" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
        when "01001" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
        when "01010" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
        when "01011" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
        when "01100" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
        when "01101" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
        when "01110" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
        when "01111" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
                        
        -- Fast clock rate, no phase shift
        when "10000" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
        when "10001" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
        when "10010" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
        when "10011" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
        when "10100" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
        when "10101" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
        when "10110" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
        when "10111" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
                        
        -- Fast clock rate, with phase shift
        when "11000" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
        when "11001" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
        when "11010" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
        when "11011" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
        when "11100" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
        when "11101" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
        when "11110" => hr_clk <= '1'; hr_clk_p <= '1'; hr_clk_n <= '0';
                        hr2_clk_p <= '1'; hr2_clk_n <= '0';                        
        when "11111" => hr_clk <= '0'; hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
                        
        when others => hr_clk <= '0';  hr_clk_p <= '0'; hr_clk_n <= '1';
                        hr2_clk_p <= '0'; hr2_clk_n <= '1';
      end case;
      
    end if;

    if rising_edge(clock163) then

      cycle_count <= cycle_count + 1;

      if data_ready_strobe_hold = '0' then      
        data_ready_strobe <= fake_data_ready_strobe;
        if fake_data_ready_strobe='1' then
--          report "holding data_ready_strobe via fake data = $" & to_hstring(fake_rdata);
          rdata <= fake_rdata;
        end if;
      else
--        report "holding data_ready_strobe for an extra cycle";
        data_ready_strobe <= '1';
      end if;
      data_ready_strobe_hold <= '0';
      
      -- HyperRAM state machine
--      report "State = " & state_t'image(state) & " @ Cycle " & integer'image(cycle_count)
--        & ", config_reg_write=" & std_logic'image(config_reg_write);
      
      if conf_buf0_set /= last_conf_buf0_set then
        last_conf_buf0_set <= conf_buf0_set;
        conf_buf0 <= conf_buf0_in;
      end if;
      if conf_buf1_set /= last_conf_buf1_set then
        last_conf_buf1_set <= conf_buf1_set;
        conf_buf1 <= conf_buf1_in;
      end if;
      
      if (state /= Idle) and ( start_delay_counter /= 0) then
        start_delay_counter <= start_delay_counter - 1;
      else
        start_delay_counter <= 0;
        
        case state is
          when Idle =>
--            report "Tristating hr_d";
            hr_d <= (others => 'Z');
            hr2_d <= (others => 'Z');

            first_transaction <= '0';
            is_block_read <= false;
            is_prefetch <= ram_prefetch;
            
            -- All commands need the clock offset by 1/2 cycle
            hr_clk_phaseshift <= write_phase_shift;
            hr_clk_fast <= '1';
            
            pause_phase <= '0';
            countdown_timeout <= '0';
            
            -- Invalidate cache if disabled
            if cache_enabled = false then
              cache_row0_valids <= (others => '0');
              cache_row1_valids <= (others => '0');
              current_cache_line_valid <= '0';
              block_valid <= '0';
            end if;

            if current_cache_line_update_all /= last_current_cache_line_update_all then
              last_current_cache_line_update_all <= current_cache_line_update_all;
              current_cache_line_address <= current_cache_line_new_address;
              current_cache_line <= current_cache_line_update;
            end if;
            for i in 0 to 7 loop
              if current_cache_line_update_flags(i) /= last_current_cache_line_update_flags(i)  then
                last_current_cache_line_update_flags(i) <= current_cache_line_update_flags(i);
                current_cache_line(i) <= current_cache_line_update(i);
              end if;
            end loop;

            if cache_row_update_toggle /= last_cache_row_update_toggle then
              last_cache_row_update_toggle <= cache_row_update_toggle;
              if cache_row0_address = cache_row_update_address then
                cache_row0_valids(cache_row_update_byte) <= '1';
                cache_row0_data(cache_row_update_byte) <= cache_row_update_value;
              end if;
              if cache_row1_address = cache_row_update_address then
                cache_row1_valids(cache_row_update_byte) <= '1';
                cache_row1_data(cache_row_update_byte) <= cache_row_update_value;
              end if;
              if block_address = cache_row_update_address(26 downto 5) then
                block_data(to_integer(cache_row_update_address(4 downto 3)))(cache_row_update_byte)
                  <= cache_row_update_value;
              end if;
            end if;                        
            
            -- Clear write buffer flags when they are empty
            if write_collect0_dispatchable = '0' then
              write_collect0_toolate <= '0';
              write_collect0_flushed <= '0';
            end if;
            if write_collect1_dispatchable = '0' then
              write_collect1_toolate <= '0';
              write_collect1_flushed <= '0';
            end if;
            
            -- Mark us ready for a new job, or pick up a new job
--            report
--              "r_t=" & std_logic'image(request_toggle)
--              & ", l_r_t=" & std_logic'image(last_request_toggle)
--              & ", hr_clk=" & std_logic'image(hr_clk)
--              & ", rwr_counter = " & integer'image(to_integer(rwr_counter));
            
            if rwr_counter /= to_unsigned(0,8) then
              rwr_counter <= rwr_counter - 1;
              hr_d <= x"bb";
              hr2_d <= x"bb";
            -- Phase 101 guarantees that the clock base change will happen
            -- within the comming clock cycle
            elsif hr_clock_phase(2 downto 1) = "10" then
              if request_toggle /= last_request_toggle then
                ram_reading_held <= ram_reading;
                
                if ram_reading = '1' then
--                  report "Waiting to start read";
                  request_accepted <= request_toggle;
                  last_request_toggle <= request_toggle;
                  state <= ReadSetup;
--                  report "Accepting job";
                  busy_internal <= '1';
                else
--                  report "Waiting to start write";
--                  report "Setting state to WriteSetup. random_bits=" & to_hstring(random_bits);
                  request_accepted <= request_toggle;
                  last_request_toggle <= request_toggle;
                  state <= WriteSetup;
--                  report "Accepting job";
                  busy_internal <= '1';

                  -- Update short-circuit cache line
                  -- (We don't change validity, since we don't know if it is
                  -- valid or not).
                  if ram_address(26 downto 3) = current_cache_line_address(26 downto 3) then
                    current_cache_line(to_integer(ram_address(2 downto 0))) <= ram_wdata;
                  end if;

                  -- Update cache
                  if cache_row0_address = ram_address(26 downto 3) then
                    cache_row0_valids(to_integer(ram_address(2 downto 0))) <= '1';
                    cache_row0_data(to_integer(ram_address(2 downto 0))) <= ram_wdata;        
                  elsif cache_row1_address = ram_address(26 downto 3) then
                    cache_row1_valids(to_integer(ram_address(2 downto 0))) <= '1';
                    cache_row1_data(to_integer(ram_address(2 downto 0))) <= ram_wdata;        
                  else
                    if random_bits(1)='0' then
                      cache_row0_valids <= (others => '0');
                      cache_row0_address <= ram_address(26 downto 3);
                      cache_row0_valids(to_integer(ram_address(2 downto 0))) <= '1';
                      cache_row0_data(to_integer(ram_address(2 downto 0))) <= ram_wdata;        
                    else
                      cache_row1_valids <= (others => '0');
                      cache_row1_address <= ram_address(26 downto 3);
                      cache_row1_valids(to_integer(ram_address(2 downto 0))) <= '1';
                      cache_row1_data(to_integer(ram_address(2 downto 0))) <= ram_wdata;        
                    end if;
                  end if;
                  
                end if;
              elsif write_collect0_dispatchable = '1' then
                -- Do background write.
                busy_internal <= '0';
                request_accepted <= request_toggle;

--                report "DISPATCH: Writing out collect0 @ $" & to_hstring(write_collect0_address&"000");
                
                -- Mark the write buffer as being processed.              
                write_collect0_flushed <= '0';
                -- And that it is not (yet) too late to add extra bytes to the write.
                write_collect0_toolate <= '0';

                background_write <= '1';
                background_write_source <= '0'; -- collect 0

                config_reg_write <= write_collect0_address(25);
                hyperram2_select <= write_collect0_address(23);

                -- Prepare command vector
                hr_command(47) <= '0'; -- WRITE
                hr_command(46) <= write_collect0_address(25); -- Memory, not register space
                hr_command(45) <= '1'; -- linear
                hr_command(44 downto 35) <= (others => '0'); -- unused upper address bits
                hr_command(15 downto 3) <= (others => '0'); -- reserved bits
                hr_command(34 downto 16) <= write_collect0_address(22 downto 4);
                hr_command(2) <= write_collect0_address(3);
                hr_command(1 downto 0) <= "00";
                hr_reset <= '1'; -- active low reset

                ram_reading_held <= '0';

                -- This is the delay before we assert CS
                countdown <= 0;

                -- We have to use this intermediate stage to get the clock
                -- phase right.
                state <= StartBackgroundWrite;
                
                if write_collect0_address(25)='1' then
                  -- 48 bits of CA followed by 16 bit register value
                  -- (we shift the buffered config register values out automatically)
                  countdown <= 6 + 1;
                else
                  countdown <= 6;
                end if;

              elsif write_collect1_dispatchable = '1' then
                busy_internal <= '0';              
                request_accepted <= request_toggle;

--                report "DISPATCH: Writing out collect1 @ $" & to_hstring(write_collect1_address&"000");
                
                -- Mark the write buffer as being processed.              
                write_collect1_flushed <= '0';
                -- And that it is not (yet) too late to add extra bytes to the write.
                write_collect1_toolate <= '0';

                config_reg_write <= write_collect1_address(25);
                hyperram2_select <= write_collect1_address(23);

                background_write <= '1';
                background_write_source <= '1'; -- collect 0

                -- Prepare command vector
                hr_command(47) <= '0'; -- WRITE
                hr_command(46) <= write_collect1_address(25); -- Memory, not register space
                hr_command(45) <= '1'; -- linear
                hr_command(44 downto 35) <= (others => '0'); -- unused upper address bits
                hr_command(15 downto 3) <= (others => '0'); -- reserved bits
                hr_command(34 downto 16) <= write_collect1_address(22 downto 4);
                hr_command(2) <= write_collect1_address(3);
                hr_command(1 downto 0) <= "00";

                ram_reading_held <= '0';
                
                hr_reset <= '1'; -- active low reset

                state <= StartBackgroundWrite;

                if write_collect1_address(25)='1' then
                  -- 48 bits of CA followed by 16 bit register value
                  -- (we shift the buffered config register values out automatically)
                  countdown <= 6 + 1;
                else
                  countdown <= 6;
                end if;

--                report "clk_queue <= '00'";

              else
--                report "Clearing busy_internal";
                busy_internal <= '0';
                request_accepted <= request_toggle;
              end IF;
              -- Release CS line between transactions
--              report "Releasing hyperram CS lines";
              hr_cs0 <= '1';
              hr_cs1 <= '1';
            end if;

          when StartBackgroundWrite =>
--            report "in StartBackgroundWrite to synchronise with clock";
            pause_phase <= '0';
            if fast_cmd_mode='1' then
              state <= HyperRAMOutputCommand;
              hr_clk_phaseshift <= write_phase_shift;
              hr_clk_fast <= '1';
            else
              state <= HyperRAMOutputCommandSlow;
              hr_clk_phaseshift <= write_phase_shift;
              hr_clk_fast <= '0';
            end if;            
            
          when ReadSetup =>
--            report "Setting up to read $" & to_hstring(ram_address) & " ( address = $" & to_hstring(address) & ")";

            hyperram2_select <= ram_address(23);
            
            -- Prepare command vector
            hr_command(47) <= '1'; -- READ
            -- Map actual RAM to bottom 32MB of 64MB space (repeated 4x)
            -- and registers to upper 32MB
--            hr_command(46) <= '1'; -- Memory address space (1) / Register
            hr_command(46) <= ram_address(25); -- Memory address space (1) / Register
                                               -- address space select (0) ?
            hr_command(45) <= '1'; -- Linear access (not wrapped)
            hr_command(44 downto 37) <= (others => '0'); -- unused upper address bits
            hr_command(34 downto 16) <= ram_address(22 downto 4);
            hr_command(15 downto 3) <= (others => '0'); -- reserved bits
            if ram_address(25) = '0' then
              -- Always read on 8 byte boundaries, and read a full cache line
              hr_command(2) <= ram_address(3);
              hr_command(1 downto 0) <= "00";
            else
              -- Except that register reads are weird: They read the same 2 bytes
              -- over and over again, so we have to make it set bit 0 of the CA
              -- for the "odd" registers"
              hr_command(2 downto 1) <= "00";
              hr_command(0) <= ram_address(3);
            end if;

            hr_reset <= '1'; -- active low reset
            countdown <= 0;
            pause_phase <= '0';

            if fast_cmd_mode='1' then
              state <= HyperRAMOutputCommand;
              hr_clk_fast <= '1';
              hr_clk_phaseshift <= write_phase_shift;
            else
              state <= HyperRAMOutputCommandSlow;
              hr_clk_fast <= '0';
              hr_clk_phaseshift <= write_phase_shift;
            end if;
            
            countdown <= 6;
            config_reg_write <= '0';
            
          when WriteSetup =>

--            report "Preparing hr_command etc";

            config_reg_write <= ram_address(25);
            hyperram2_select <= ram_address(23);
            
            -- Prepare command vector
            -- As HyperRAM addresses on 16bit boundaries, we shift the address
            -- down one bit.
            hr_command(47) <= '0'; -- WRITE
            hr_command(46) <= ram_address(25); -- Memory, not register space
            hr_command(45) <= '1'; -- linear
            
            hr_command(44 downto 35) <= (others => '0'); -- unused upper address bits
            hr_command(15 downto 3) <= (others => '0'); -- reserved bits
            
            hr_command(34 downto 16) <= ram_address(22 downto 4);
            hr_command(2 downto 0) <= ram_address(3 downto 1);

            hr_reset <= '1'; -- active low reset

            pause_phase <= '0';
            
            if fast_cmd_mode='1' then
              state <= HyperRAMOutputCommand;
              hr_clk_fast <= '1';
              hr_clk_phaseshift <= write_phase_shift;         
            else
              state <= HyperRAMOutputCommandSlow;
              hr_clk_fast <= '0';
              hr_clk_phaseshift <= write_phase_shift;
            end if;
            if ram_address(25)='1' then
              -- 48 bits of CA followed by 16 bit register value
              -- (we shift the buffered config register values out automatically)
              countdown <= 6 + 1;
            else
              countdown <= 6;
            end if;            
            
          when HyperRAMOutputCommandSlow =>
--            report "Writing command, ram_address=$" & to_hstring(ram_address);
            -- Call HyperRAM to attention
            hr_cs0 <= ram_address(23);
            hr_cs1 <= not (ram_address(23) or first_transaction);
            
            hr_rwds <= 'Z';
            hr2_rwds <= 'Z';

            -- Prepare for reading block data
            is_block_read <= false;
            if (ram_address(4 downto 3) = "00") and block_read_enable='1' and (ram_reading_held='1') then
              block_valid <= '0';
              block_address <= ram_address(26 downto 5);
              is_block_read <= true;
            end if;
            
            pause_phase <= not pause_phase;

            if pause_phase='1' then
              hr_clk_phaseshift <= write_phase_shift;

              if countdown_timeout='1' then
                -- Finished shifting out
                if ram_reading_held = '1' then
                  -- Reading: We can just wait until hr_rwds has gone low, and then
                  -- goes high again to indicate the first data byte
                  countdown <= 99;
                  hr_rwds_high_seen <= '0';
                  countdown_timeout <= '0';
                  if fast_read_mode='1' then
                    hr_clk_fast <= '1';
                    state <= HyperRAMReadWait;
                  else
                    pause_phase <= '1';
                    hr_clk_fast <= '0';
                    state <= HyperRAMReadWaitSlow;
                  end if;
                elsif config_reg_write='1' and ram_reading_held='0' then
                  -- Config register write.
                  -- These are a bit weird, as they have no latency, and all 16
                  -- bits have to get written at once.  So we will have 2 buffer
                  -- registers that get setup, and then ANY write to the register
                  -- area will write those values, which we have done by shifting
                  -- those through and sending 48+16 bits instead of the usual
                  -- 48.
                  if background_write='1' then
                    if background_write_source = '0' then
                      write_collect0_flushed <= '1';
                    else
                      write_collect1_flushed <= '1';
                    end if;
                  end if;
                  
                  state <= HyperRAMFinishWriting;
                else
                  -- Writing to memory, so count down the correct number of cycles;
                  -- Initial latency is reduced by 2 cycles for the last bytes
                  -- of the access command, and by 1 more to cover state
                  -- machine latency
                  if hyperram2_select='0' then
                    countdown <= to_integer(write_latency);
                  else
                    countdown <= to_integer(write_latency2);
                  end if;

                  -- We are not just about ready to start writing, so mark the
                  -- write buffer as too late to be added to, because we will
                  -- snap-shot it in a moment.
                  if background_write = '1' then
--                    report "WRITE: Asserting toolate signal";
                    background_write_count <= 4 + 2;
                    if background_write_source = '0' then
                      write_collect0_toolate <= '1';
                      write_collect0_flushed <= '0';
                    else
                      write_collect1_toolate <= '1';
                      write_collect1_flushed <= '0';
                    end if;
                  end if;
                  countdown_timeout <= '0';
                  if fast_write_mode='1' then
                    hr_clk_fast <= '1';
                    state <= HyperRAMDoWrite;
                  else
                    hr_clk_fast <= '0';
                    state <= HyperRAMDoWriteSlow;
                  end if;
                end if;
              end if;

            else
              
              -- Toggle data while clock steady
--              report "Presenting hr_command byte on hr_d = $" & to_hstring(hr_command(47 downto 40))
--                & ", clock = " & std_logic'image(hr_clk)
--                & ", countdown = " & integer'image(countdown);
              
              hr_d <= hr_command(47 downto 40);
              hr2_d <= hr_command(47 downto 40);
              hr_command(47 downto 8) <= hr_command(39 downto 0);

              -- Also shift out config register values, if required
              if config_reg_write='1' and ram_reading_held='0' then
--                report "shifting in conf value $" & to_hstring(conf_buf0);
                hr_command(7 downto 0) <= conf_buf0;
                conf_buf0 <= conf_buf1;
                conf_buf1 <= conf_buf0;
              else
                hr_command(7 downto 0) <= x"00";
              end if;
              
--              report "Writing command byte $" & to_hstring(hr_command(47 downto 40));

              if countdown = 3 and config_reg_write='1' then
                if background_write='1' then
                  if background_write_source = '0' then
                    write_collect0_toolate <= '1';
                  else
                    write_collect1_toolate <= '1';
                  end if;
                end if;
              end if;
            
              if countdown = 3 and (config_reg_write='0' or ram_reading_held='1') then
                extra_latency <= hr_rwds;
                if (hr_rwds='1' and hyperram2_select='0')
                  or (hr2_rwds='1' and hyperram2_select='1')
                then
--                  report "Applying extra latency";
                end if;                    
              end if;
              if countdown /= 0 then
                countdown <= countdown - 1;
              else
                countdown_timeout <= '1';
              end if;
            end if;
            byte_phase <= to_unsigned(0,6);
            write_byte_phase <= '0';
          when HyperRAMOutputCommand =>
--            report "Writing command";
            -- Call HyperRAM to attention
            hr_cs0 <= ram_address(23);
            hr_cs1 <= not (ram_address(23) or first_transaction);
            
            hr_rwds <= 'Z';
            hr2_rwds <= 'Z';

            hr_clk_phaseshift <= write_byte_phase;

            -- Toggle data while clock steady
--              report "Presenting hr_command byte on hr_d = $" & to_hstring(hr_command(47 downto 40))
--                & ", clock = " & std_logic'image(hr_clock)
--                & ", next_is_data = " & std_logic'image(next_is_data)
--                & ", countdown = " & integer'image(countdown)
--                & ", cs0= " & std_logic'image(hr_cs0);
            
            hr_d <= hr_command(47 downto 40);
            hr2_d <= hr_command(47 downto 40);
            hr_command(47 downto 8) <= hr_command(39 downto 0);

            -- Also shift out config register values, if required
            if config_reg_write='1' and ram_reading_held='0' then
--              report "shifting in conf value $" & to_hstring(conf_buf0);
              hr_command(7 downto 0) <= conf_buf0;
              conf_buf0 <= conf_buf1;
              conf_buf1 <= conf_buf0;
            else
              hr_command(7 downto 0) <= x"00";
            end if;
            
--            report "Writing command byte $" & to_hstring(hr_command(47 downto 40));
            
            if countdown = 3 and (config_reg_write='0' or ram_reading_held='1') then
              if hyperram2_select='0' then
                extra_latency <= hr_rwds;
              else
                extra_latency <= hr2_rwds;
              end if;
              if (hr_rwds='1' and hyperram2_select='0')
                or (hr2_rwds='1' and hyperram2_select='1') then
--                report "Applying extra latency";
              end if;                    
            end if;
            if countdown /= 0 then
              countdown <= countdown - 1;
            else
              -- Finished shifting out
              if ram_reading_held = '1' then
                -- Reading: We can just wait until hr_rwds has gone low, and then
                -- goes high again to indicate the first data byte
                countdown <= 99;
                hr_rwds_high_seen <= '0';
                if fast_read_mode='1' then
                  hr_clk_fast <= '1';
                  state <= HyperRAMReadWait;
                else
                  pause_phase <= '0';                  
                  hr_clk_fast <= '0';
                  state <= HyperRAMReadWaitSlow;
                end if;
              elsif config_reg_write='1' and ram_reading_held='0' then
                -- Config register write.
                -- These are a bit weird, as they have no latency, and all 16
                -- bits have to get written at once.  So we will have 2 buffer
                -- registers that get setup, and then ANY write to the register
                -- area will write those values, which we have done by shifting
                -- those through and sending 48+16 bits instead of the usual
                -- 48.

                if background_write='1' then
                  if background_write_source = '0' then
                    write_collect0_flushed <= '1';
                  else
                    write_collect1_flushed <= '1';
                  end if;
                end if;

                state <= HyperRAMFinishWriting;
              else
                -- Writing to memory, so count down the correct number of cycles;
                -- Initial latency is reduced by 2 cycles for the last bytes
                -- of the access command, and by 1 more to cover state
                -- machine latency                  
                if hyperram2_select='0' then
                  countdown <= to_integer(write_latency);
                else
                  countdown <= to_integer(write_latency2);
                end if;

                -- We are now just about ready to start writing, so mark the
                -- write buffer as too late to be added to, because we will
                -- snap-shot it in a moment.
                if background_write = '1' then
--                  report "WRITE: Asserting toolate signal";
                  background_write_count <= 4 + 2;
                  if background_write_source = '0' then
                    write_collect0_toolate <= '1';
                    write_collect0_flushed <= '0';
                  else
                    write_collect1_toolate <= '1';
                    write_collect1_flushed <= '0';
                  end if;
                end if;

                countdown_timeout <= '0';
                if fast_write_mode='1' then
                  state <= HyperRAMDoWrite;
                else
                  state <= HyperRAMDoWriteSlow;
                end if;
              end if;
            end if;
            byte_phase <= to_unsigned(0,6);
            write_byte_phase <= '0';

          when HyperRAMDoWrite =>
            hr_clk_phaseshift <= write_phase_shift;         

--            report "WRITE: LatencyWait state, bg_wr=" & std_logic'image(background_write)
--              & ", count=" & integer'image(background_write_count);

            -- Now snap-shot the write buffer data, and mark the slot as flushed
            if background_write = '1' then
              if background_write_source = '0' and write_collect0_toolate='1' and write_collect0_flushed = '0' then
                write_collect0_flushed <= '1';
--                report "WRITE: background_write_data copied from write_collect0. Valids = " & to_string(write_collect0_valids);
                background_write_data <= write_collect0_data;
                background_write_valids <= write_collect0_valids;
                
              elsif background_write_source = '1' and write_collect1_toolate='1' and write_collect1_flushed = '0' then
                write_collect1_flushed <= '1';
--                report "WRITE: background_write_data copied from write_collect1";
                background_write_data <= write_collect1_data;
                background_write_valids <= write_collect1_valids;
              end if;

              -- Invalidate read cache when writing
              if cache_enabled and (ram_address(26 downto 3 ) = cache_row0_address) then
                cache_row0_valids <= (others => '0');
              elsif cache_enabled and (ram_address(26 downto 3 ) = cache_row1_address) then
                cache_row1_valids <= (others => '0');
              end if;
            end if;
        
--            report "latency countdown = " & integer'image(countdown);

            -- Begin write mask pre-amble
            if ram_reading_held = '0' and countdown = 2 then
              hr_rwds <= '0';
              hr2_rwds <= '0';
              hr_d <= x"BE"; -- "before" data byte
              hr2_d <= x"BE"; -- "before" data byte
            end if;
            
            if countdown /= 0 then
              countdown <= countdown - 1;
            else
              if extra_latency='1' then
--                report "Waiting 6 more cycles for extra latency";
                -- If we were asked to wait for extra latency,
                -- then wait another 6 cycles.
                extra_latency <= '0';

                if hyperram2_select='0' then
                  countdown <= to_integer(extra_write_latency);
                else
                  countdown <= to_integer(extra_write_latency2);
                end if;
              else
                -- Latency countdown for writing is over, we can now
                -- begin writing bytes.                  
                
                -- HyperRAM works on 16-bit fundamental transfers.
                -- This means we need to have two half-cycles, and pick which
                -- one we want to write during.
                -- If RWDS is asserted, then the write is masked, i.e., won't
                -- occur.
                -- In this first 
                
--                report "Presenting hr_d with ram_wdata or background data";
                if background_write='1' then
--                  report "WRITE: Writing background byte $" & to_hstring(background_write_data(0))
--                    & ", valids= " & to_string(background_write_valids)
--                    & ", background words left = " & integer'image(background_write_count);
                  hr_d <= background_write_data(0);
                  hr2_d <= background_write_data(0);
                  background_write_data(0) <= background_write_data(1);
                  background_write_data(1) <= background_write_data(2);
                  background_write_data(2) <= background_write_data(3);
                  background_write_data(3) <= background_write_data(4);
                  background_write_data(4) <= background_write_data(5);
                  background_write_data(5) <= background_write_data(6);
                  background_write_data(6) <= background_write_data(7);
                  background_write_data(7) <= x"00";
                  
                  hr_rwds <= not background_write_valids(0);
                  hr2_rwds <= not background_write_valids(0);
                  background_write_valids(0 to 6) <= background_write_valids(1 to 7);
                  background_write_valids(7) <= '0';
                else
                  hr_d <= ram_wdata;
                  hr2_d <= ram_wdata;
                  hr_rwds <= ram_address(0) xor write_byte_phase;
                  hr2_rwds <= ram_address(0) xor write_byte_phase;
                end if;
                
                -- Write byte
                write_byte_phase <= '1';
                if background_write='0' then
                  if write_byte_phase = '0' and ram_address(0)='1' then
                    hr_d <= x"ee"; -- even "masked" data byte
                    hr2_d <= x"ee"; -- even "masked" data byte
                  elsif write_byte_phase = '1' and ram_address(0)='0' then
                    hr_d <= x"0d"; -- odd "masked" data byte                      
                    hr2_d <= x"0d"; -- odd "masked" data byte                      
                  end if;
                elsif write_byte_phase='1' then
--                  report "WRITE: Decrementing background_write_count from " & integer'image(background_write_count);
                  if background_write_count /= 0 then
                    background_write_count <= background_write_count - 1;
                  else
--                    report "Advancing to HyperRAMFinishWriting";
                    hr_clk_phaseshift <= write_phase_shift;         
                    state <= HyperRAMFinishWriting;                    
                  end if;
                end if;
              end if;
            end if;
          when HyperRAMDoWriteSlow =>
            pause_phase <= not pause_phase;

            if pause_phase = '1' then
              hr_clk_phaseshift <= write_phase_shift;
              if countdown_timeout = '1' then
--                report "Advancing to HyperRAMFinishWriting";
                state <= HyperRAMFinishWriting;                    
              end if;
            else
              
--              report "WRITE: LatencyWait state, bg_wr=" & std_logic'image(background_write)
--                & ", count=" & integer'image(background_write_count);

              -- Now snap-shot the write buffer data, and mark the slot as flushed
              if background_write = '1' then
                if background_write_source = '0' and write_collect0_toolate='1' and write_collect0_flushed = '0' then
                  write_collect0_flushed <= '1';
--                  report "WRITE: background_write_data copied from write_collect0. Valids = " & to_string(write_collect0_valids);
                  background_write_data <= write_collect0_data;
                  background_write_valids <= write_collect0_valids;
                elsif background_write_source = '1' and write_collect1_toolate='1' and write_collect1_flushed = '0' then
                  write_collect1_flushed <= '1';
--                  report "WRITE: background_write_data copied from write_collect1";
                  background_write_data <= write_collect1_data;
                  background_write_valids <= write_collect1_valids;
                end if;
              end if;

--              report "latency countdown = " & integer'image(countdown);

              -- Begin write mask pre-amble
              if ram_reading_held = '0' and countdown = 2 then
                hr_rwds <= '0';
                hr2_rwds <= '0';
                hr_d <= x"BE"; -- "before" data byte
                hr2_d <= x"BE"; -- "before" data byte
              end if;
              
              if countdown /= 0 then
                countdown <= countdown - 1;
              else
                if extra_latency='1' then
--                  report "Waiting 6 more cycles for extra latency";
                  -- If we were asked to wait for extra latency,
                  -- then wait another 6 cycles.
                  extra_latency <= '0';
                  if hyperram2_select='0' then
                    countdown <= to_integer(extra_write_latency);
                  else
                    countdown <= to_integer(extra_write_latency2);
                  end if;
                else
                  -- Latency countdown for writing is over, we can now
                  -- begin writing bytes.                  
                  
                  -- HyperRAM works on 16-bit fundamental transfers.
                  -- This means we need to have two half-cycles, and pick which
                  -- one we want to write during.
                  -- If RWDS is asserted, then the write is masked, i.e., won't
                  -- occur.
                  -- In this first 
                  
--                  report "Presenting hr_d with ram_wdata or background data";
                  if background_write='1' then
--                    report "WRITE: Writing background byte $" & to_hstring(background_write_data(0))
--                      & ", valids= " & to_string(background_write_valids)
--                      & ", background words left = " & integer'image(background_write_count);
                    hr_d <= background_write_data(0);
                    hr2_d <= background_write_data(0);
                    background_write_data(0) <= background_write_data(1);
                    background_write_data(1) <= background_write_data(2);
                    background_write_data(2) <= background_write_data(3);
                    background_write_data(3) <= background_write_data(4);
                    background_write_data(4) <= background_write_data(5);
                    background_write_data(5) <= background_write_data(6);
                    background_write_data(6) <= background_write_data(7);
                    background_write_data(7) <= x"00";
                    
                    hr_rwds <= not background_write_valids(0);
                    hr2_rwds <= not background_write_valids(0);
                    background_write_valids(0 to 6) <= background_write_valids(1 to 7);
                    background_write_valids(7) <= '0';
                  else
                    hr_d <= ram_wdata;
                    hr2_d <= ram_wdata;
                    hr_rwds <= ram_address(0) xor write_byte_phase;
                    hr2_rwds <= ram_address(0) xor write_byte_phase;
                  end if;
                  
                  -- Write byte
                  write_byte_phase <= '1';
                  if background_write='0' then
                    if write_byte_phase = '0' and ram_address(0)='1' then
                      hr_d <= x"ee"; -- even "masked" data byte
                      hr2_d <= x"ee"; -- even "masked" data byte
                    elsif write_byte_phase = '1' and ram_address(0)='0' then
                      hr_d <= x"0d"; -- odd "masked" data byte                      
                      hr2_d <= x"0d"; -- odd "masked" data byte                      
                    end if;
                  elsif write_byte_phase='1' then
--                    report "WRITE: Decrementing background_write_count from " & integer'image(background_write_count);
                    if background_write_count /= 0 then
                      background_write_count <= background_write_count - 1;
                    else
                      countdown_timeout <= '1';
                    end if;
                  end if;
                end if;
              end if;
            end if;
          when Hyperramfinishwriting =>
            -- Mask writing from here on.
            hr_cs0 <= '1';
            hr_cs1 <= '1';
            hr_rwds <= 'Z';
            hr2_rwds <= 'Z';
            hr_d <= x"FA"; -- "after" data byte
            hr2_d <= x"FA"; -- "after" data byte
            hr_clk_phaseshift <= write_phase_shift;         
--            report "clk_queue <= '00'";
            rwr_counter <= rwr_delay;
--            report "returning to idle";
            state <= Idle;
          when HyperRAMReadWait =>
            hr_rwds <= 'Z';
            hr2_rwds <= 'Z';
--            report "Presenting tri-state on hr_d";
            hr_d <= (others => 'Z');                       
            hr2_d <= (others => 'Z');                       
            if countdown = 0 then
              -- Timed out waiting for read -- so return anyway, rather
              -- than locking the machine hard forever.
              rdata <= x"DD";
              rdata(0) <= data_ready_toggle;
              rdata(1) <= busy_internal;
              data_ready_strobe <= '1';
              data_ready_strobe_hold <= '1';
              rwr_counter <= rwr_delay;
              hr_clk_phaseshift <= write_phase_shift;         
--              report "returning to idle";
              state <= Idle;
            else
              countdown <= countdown - 1;
            end if;

            hr_clk_phaseshift <= read_phase_shift xor hyperram2_select;

            if hyperram2_select='0' then
              last_rwds <= hr_rwds;
            else
              last_rwds <= hr2_rwds;
            end if;
            -- HyperRAM drives RWDS basically to follow the clock.
            -- But first valid data is when RWDS goes high, so we have to
            -- wait until we see it go high.
--              report "DISPATCH watching for data: rwds=" & std_logic'image(hr_rwds) & ", clock=" & std_logic'image(hr_clock)
--                & ", rwds seen=" & std_logic'image(hr_rwds_high_seen);

            if ((hr_rwds='1') and (hyperram2_select='0'))
              or ((hr2_rwds='1') and (hyperram2_select='1'))
            then
              hr_rwds_high_seen <= '1';
--                if hr_rwds_high_seen = '0' then
            --                report "DISPATCH saw hr_rwds go high at start of data stream";
--                end if;
            else
              hr_rwds_high_seen <= '0';
            end if;                
            if (((hr_rwds='1') and (hyperram2_select='0'))
              or ((hr2_rwds='1') and (hyperram2_select='1')))
              or (hr_rwds_high_seen='1') then
              -- Data has arrived: Latch either odd or even byte
              -- as required.
--                  report "DISPATCH Saw read data = $" & to_hstring(hr_d);

              
              -- Update cache
              if (byte_phase < 32) and is_block_read then
--                report "hr_sample='1'";
--                report "hr_sample='0'";
                if hyperram2_select='0' then
                  block_data(to_integer(byte_phase(4 downto 3)))(to_integer(byte_phase(2 downto 0)))
                    <= hr_d;
                else
                  block_data(to_integer(byte_phase(4 downto 3)))(to_integer(byte_phase(2 downto 0)))
                    <= hr2_d;
                end if;
              end if;
              if (byte_phase < 8) then
                -- Store the bytes in the cache row
                if cache_row0_address = ram_address(26 downto 3) then          
                  cache_row0_valids(to_integer(byte_phase)) <= '1';
--                  report "hr_sample='1'";
--                  report "hr_sample='0'";
                  if hyperram2_select='0' then
                    cache_row0_data(to_integer(byte_phase)) <= hr_d;
                  else
                    cache_row0_data(to_integer(byte_phase)) <= hr2_d;
                  end if;
                elsif cache_row1_address = ram_address(26 downto 3) then          
                  cache_row1_valids(to_integer(byte_phase)) <= '1';
--                  report "hr_sample='1'";
--                  report "hr_sample='0'";
                  if hyperram2_select='0' then
                    cache_row1_data(to_integer(byte_phase)) <= hr_d;
                  else
                    cache_row1_data(to_integer(byte_phase)) <= hr2_d;
                  end if;
                elsif random_bits(1) = '0' then
                  cache_row0_valids <= (others => '0');
                  cache_row0_address <= ram_address(26 downto 3);
                  cache_row0_valids(to_integer(byte_phase)) <= '1';
--                  report "hr_sample='1'";
--                  report "hr_sample='0'";
                  if hyperram2_select='0' then
                    cache_row0_data(to_integer(byte_phase)) <= hr_d;
                  else
                    cache_row0_data(to_integer(byte_phase)) <= hr2_d;
                  end if;
                else
                  cache_row1_valids <= (others => '0');
                  cache_row1_address <= ram_address(26 downto 3);
                  cache_row1_valids(to_integer(byte_phase)) <= '1';
--                  report "hr_sample='1'";
--                  report "hr_sample='0'";
                  if hyperram2_select='0' then
                    cache_row1_data(to_integer(byte_phase)) <= hr_d;
                  else
                    cache_row1_data(to_integer(byte_phase)) <= hr2_d;
                  end if;
                end if;
              elsif (byte_phase = 8) and (is_prefetch = false) then
                -- Export the appropriate cache line to slow_devices
                if cache_row0_address = ram_address(26 downto 3) and cache_enabled then          
                  if cache_row0_valids = x"FF" then
                    current_cache_line <= cache_row0_data;
                    current_cache_line_address(26 downto 3) <= ram_address(26 downto 3);
                    current_cache_line_valid <= '1';
                  end if;
                elsif cache_row1_address = ram_address(26 downto 3) and cache_enabled then          
                  if cache_row1_valids = x"FF" then
                    current_cache_line <= cache_row1_data;
                    current_cache_line_address(26 downto 3) <= ram_address(26 downto 3);
                    current_cache_line_valid <= '1';
                  end if;
                end if;
              end if;
              
              -- Quickly return the correct byte
              if to_integer(byte_phase) = (to_integer(ram_address(2 downto 0))+0) and (is_prefetch=false) then
--                report "DISPATCH: Returning freshly read data = $" & to_hstring(hr_d);
--                report "hr_return='1'";
--                report "hr_return='0'";
                if hyperram2_select='0' then
                  rdata <= hr_d;
                else
                  rdata <= hr2_d;
                end if;
                data_ready_strobe <= '1';
                data_ready_strobe_hold <= '1';
              end if;
--              report "byte_phase = " & integer'image(to_integer(byte_phase));
              if ((byte_phase = 7) and (is_block_read=false))
              or ((byte_phase = 31) and (is_block_read=true)) then
                rwr_counter <= rwr_delay;
--                report "returning to idle";
                state <= Idle;
                hr_cs0 <= '1';
                hr_cs1 <= '1';
                hr_clk_phaseshift <= write_phase_shift;
                if is_block_read then
                  block_valid <= '1';
                end if;
                is_prefetch <= false;
              else
                byte_phase <= byte_phase + 1;
              end if;
            end if;
          when HyperRAMReadWaitSlow =>
            hr_rwds <= 'Z';
            hr2_rwds <= 'Z';
--            report "Presenting tri-state on hr_d";
            hr_d <= (others => 'Z');
            hr2_d <= (others => 'Z');
            
            if hyperram2_select='0' then
              hr_d_last <= hr_d;
            else
              hr_d_last <= hr2_d;
            end if;
            
            pause_phase <= not pause_phase;

            if pause_phase = '1' then
              null;
            else
              hr_clk_phaseshift <= read_phase_shift xor hyperram2_select;
              if countdown = 0 then
                -- Timed out waiting for read -- so return anyway, rather
                -- than locking the machine hard forever.
                rdata <= x"DD";
                rdata(0) <= data_ready_toggle;
                rdata(1) <= busy_internal;
                data_ready_strobe <= '1';
                data_ready_strobe_hold <= '1';
                rwr_counter <= rwr_delay;
--                report "returning to idle";
                state <= Idle;
                hr_clk_phaseshift <= write_phase_shift;
              else
                countdown <= countdown - 1;
              end if;
              
              if hyperram2_select='0' then
                last_rwds <= hr_rwds;
              else
                last_rwds <= hr2_rwds;
              end if;
              -- HyperRAM drives RWDS basically to follow the clock.
              -- But first valid data is when RWDS goes high, so we have to
              -- wait until we see it go high.
--              report "DISPATCH watching for data: rwds=" & std_logic'image(hr_rwds) & ", clock=" & std_logic'image(hr_clock)
--                & ", rwds seen=" & std_logic'image(hr_rwds_high_seen);
              
              if ((hr_rwds='1') and (hyperram2_select='0')) or ((hr2_rwds='1') and (hyperram2_select='1'))
              then
                hr_rwds_high_seen <= '1';
              else
                hr_rwds_high_seen <= '0';
--                if hr_rwds_high_seen = '0' then
              --                report "DISPATCH saw hr_rwds go high at start of data stream";
--                end if;
              end if;                
              if (((hr_rwds='1') and (hyperram2_select='0')) or ((hr2_rwds='1') and (hyperram2_select='1')))
              or (hr_rwds_high_seen='1') then
                -- Data has arrived: Latch either odd or even byte
                -- as required.
--                  report "DISPATCH Saw read data = $" & to_hstring(hr_d);
                
                -- Update cache
                if byte_phase < 8 then
                  -- Store the bytes in the cache row
                  if cache_row0_address = ram_address(26 downto 3) then          
                    cache_row0_valids(to_integer(byte_phase)) <= '1';
--                    report "hr_sample='1'";
--                    report "hr_sample='0'";
                    if byte_phase = 0 and byte0_fix='1' then
                      cache_row0_data(to_integer(byte_phase)) <= hr_d_last;
                    else
                      if hyperram2_select='0' then
                        cache_row0_data(to_integer(byte_phase)) <= hr_d;
                      else
                        cache_row0_data(to_integer(byte_phase)) <= hr2_d;
                      end if;
                    end if;
                  elsif cache_row1_address = ram_address(26 downto 3) then          
                    cache_row1_valids(to_integer(byte_phase)) <= '1';
--                    report "hr_sample='1'";
--                    report "hr_sample='0'";
                    if byte_phase = 0 and byte0_fix='1' then
                      cache_row1_data(to_integer(byte_phase)) <= hr_d_last;
                    else
                      if hyperram2_select='0' then
                        cache_row1_data(to_integer(byte_phase)) <= hr_d;
                      else
                        cache_row1_data(to_integer(byte_phase)) <= hr2_d;
                      end if;
                    end if;
                  elsif random_bits(1) = '0' then
                    cache_row0_valids <= (others => '0');
                    cache_row0_address <= ram_address(26 downto 3);
                    cache_row0_valids(to_integer(byte_phase)) <= '1';
--                    report "hr_sample='1'";
--                    report "hr_sample='0'";
                    if byte_phase = 0 and byte0_fix='1' then
                      cache_row0_data(to_integer(byte_phase)) <= hr_d_last;
                    else
                      if hyperram2_select='0' then
                        cache_row0_data(to_integer(byte_phase)) <= hr_d;
                      else
                        cache_row0_data(to_integer(byte_phase)) <= hr2_d;
                      end if;
                    end if;
                  else
                    cache_row1_valids <= (others => '0');
                    cache_row1_address <= ram_address(26 downto 3);
                    cache_row1_valids(to_integer(byte_phase)) <= '1';
--                    report "hr_sample='1'";
--                    report "hr_sample='0'";
                    if byte_phase = 0 and byte0_fix='1' then
                      cache_row1_data(to_integer(byte_phase)) <= hr_d_last;
                    else
                      if hyperram2_select='0' then
                        cache_row1_data(to_integer(byte_phase)) <= hr_d;
                      else
                        cache_row1_data(to_integer(byte_phase)) <= hr2_d;
                      end if;
                    end if;
                  end if;
                else
                  -- Export the appropriate cache line to slow_devices
                  if cache_row0_address = ram_address(26 downto 3) and cache_enabled then          
                    if cache_row0_valids = x"FF" then
                      current_cache_line <= cache_row0_data;
                      current_cache_line_address(26 downto 3) <= ram_address(26 downto 3);
                      current_cache_line_valid <= '1';
                    end if;
                  elsif cache_row1_address = ram_address(26 downto 3) and cache_enabled then          
                    if cache_row1_valids = x"FF" then
                      current_cache_line <= cache_row1_data;
                      current_cache_line_address(26 downto 3) <= ram_address(26 downto 3);
                      current_cache_line_valid <= '1';
                    end if;
                  end if;
                end if;
                
                -- Quickly return the correct byte
                if to_integer(byte_phase) = (to_integer(ram_address(2 downto 0))+read_time_adjust) then
--                  report "DISPATCH: Returning freshly read data = $" & to_hstring(hr_d);
--                  report "hr_return='1'";
--                  report "hr_return='0'";
                  if byte_phase = 0 and byte0_fix='1' then
                    rdata <= hr_d_last;
                  else
                    if hyperram2_select='0' then
                      rdata <= hr_d;
                    else
                      rdata <= hr2_d;
                    end if;
                  end if;
                  data_ready_strobe <= '1';
                  data_ready_strobe_hold <= '1';
                end if;
--                report "byte_phase = " & integer'image(to_integer(byte_phase));
                if byte_phase = 7 + read_time_adjust then
                  rwr_counter <= rwr_delay;
--                  report "returning to idle";
                  state <= Idle;
                  hr_cs0 <= '1';
                  hr_cs1 <= '1';
                  hr_clk_phaseshift <= write_phase_shift;
                else
                  byte_phase <= byte_phase + 1;
                end if;
              end if;
            end if;
        end case;      
      end if;
    end if;
    
  end process;
end gothic;


