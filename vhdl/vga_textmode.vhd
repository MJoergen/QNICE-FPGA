-- 80x40 Textmode VGA
-- meant to be connected with the QNICE CPU as data I/O controled through MMIO
-- tristate outputs go high impedance when not enabled
-- done by sy2002 in December 2015/January 2016

-- Features:
-- * 80x40 text mode
-- * one color for the whole screen
-- * hardware cursor
-- * large video memory: 64.000 bytes, stores 20 screens aka "pages" (selectable via global var VGA_RAM_SIZE)
-- * hardware scrolling
--
-- Registers:
--
-- register 0: status and control register
--    bits(11:10) hardware scrolling / offset enable: enables the use of the offset registers 4 and 5 for
--                reading/writing to the vram (bit 11 = 1, register 5) and/or
--                for displaying vram contents (bit 10 = 1, register 4)
--    bit 9       busy: vga is currently busy, e.g. clearing the screen, printing, etc.
--                while busy, vga will ignore commands (they can be still written into the registers though)
--    bit 8       clear screen: write 1, read: 1 = clearscreen still active, 0 = ready
--    bit 7       VGA enable signal (1 = on, 0 switches off the vga signal generation)
--    bit 6       HW cursor enable bit
--    bit 5       blink HW cursor enable bit
--    bit 4       HW cursor mode (0 = big; 1 = small)
--    bits(2:0)   output color for the whole screen (3-bit rgb, 8 colors)
-- register 1: cursor x position read/write (0..79)
-- register 2: cusror y position read/write (0..39)
-- register 3: write: print character written into this register's (7 downto 0) bits at cursor x/y position
--             read: bits (7 downto 0) contains the character in video ram at address (cursor x, y)
-- register 4: vga display offset register used e.g. for hardware scrolling (0..63999)
-- register 5: vga read/write offset register used for accessing the whole vram (0..63999)
--
-- this component uses Javier Valcarce's vga core
-- http://www.javiervalcarce.eu/html/vhdl-vga80x40-en.html

-- how to make fonts, see http://nafe.sourceforge.net/
-- then use the psf2coe.rb and then coe2rom.pl toolchain to generate .rom files
-- in case the Source Forge link is not available: nafe-0.1.tar.gz is stored in the 'vga' subfolder
-- alternative: as psf2coe.rb does not seem to work, use
-- xxd -p -c 1 -u lat9w-12.psfu | sed -e '1,4d' > lat9w-12.coe
-- to convert "type 1" psfu's that are made by nafe from the original Linux font files to create the .coe

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.env1_globals.all;

entity vga_textmode is
port (
   reset    : in std_logic;     -- async reset
   clk      : in std_logic;     -- system clock
   clk50MHz : in std_logic;     -- needs to be a 50 MHz clock

   -- VGA registers
   en       : in std_logic;     -- enable for reading from or writing to the bus
   we       : in std_logic;     -- write to VGA's registers via system's data bus
   reg      : in std_logic_vector(3 downto 0);     -- register selector
   data     : inout std_logic_vector(15 downto 0); -- system's data bus
   
   -- VGA output signals, monochrome only
   R        : out std_logic;
   G        : out std_logic;
   B        : out std_logic;
   hsync    : out std_logic;
   vsync    : out std_logic
);
end vga_textmode;

architecture beh of vga_textmode is

component vga80x40
port (
   reset       : in  std_logic;
   clk25MHz    : in  std_logic;

   -- VGA signals, monochrome only   
   R           : out std_logic;
   G           : out std_logic;
   B           : out std_logic;
   hsync       : out std_logic;
   vsync       : out std_logic;
   
   -- address and data lines of video ram for text
   TEXT_A           : out std_logic_vector(11 downto 0);
   TEXT_D           : in  std_logic_vector(07 downto 0);
   
   -- address and data lines of font rom
   FONT_A           : out std_logic_vector(11 downto 0);
   FONT_D           : in  std_logic_vector(07 downto 0);
   
   -- hardware cursor x and y positions
   ocrx    : in  std_logic_vector(7 downto 0);
   ocry    : in  std_logic_vector(7 downto 0);
   
   -- control register
   octl    : in  std_logic_vector(7 downto 0)
);   
end component;

component video_bram
generic (
   SIZE_BYTES     : integer;    -- size of the RAM/ROM in bytes
   CONTENT_FILE   : string;     -- if not empty then a prefilled RAM ("ROM") from a .rom file is generated
   FILE_LINES     : integer;    -- size of the content file in lines (files may be smaller than the RAM/ROM size)   
   DEFAULT_VALUE  : bit_vector  -- default value to fill the memory with
);
port (
   clk            : in std_logic;
   we             : in std_logic;   
   address_i      : in std_logic_vector(15 downto 0);
   address_o      : in std_logic_vector(15 downto 0);
   data_i         : in std_logic_vector(7 downto 0);
   data_o         : out std_logic_vector(7 downto 0);

   -- performant reading facility
   pr_clk         : in std_logic;
   pr_addr        : in std_logic_vector(15 downto 0);
   pr_data        : out std_logic_vector(7 downto 0)   
);
end component;

component SyTargetCounter is
generic (
   COUNTER_FINISH : integer;                 -- target value
   COUNTER_WIDTH  : integer range 2 to 32    -- bit width of target value
);
port (
   clk       : in std_logic;                 -- clock
   reset     : in std_logic;                 -- async reset
   
   cnt       : out std_logic_vector(COUNTER_WIDTH -1 downto 0); -- current value
   overflow  : out std_logic := '0' -- true for one clock cycle when the counter wraps around
);
end component;


-- VGA specific clock, also used for video ram and font rom
signal clk25MHz            : std_logic;

-- signals for wiring video and font ram with the vga80x40 component
signal vga_text_a          : std_logic_vector(11 downto 0);
signal vga_text_d          : std_logic_vector(7 downto 0);
signal vga_font_a          : std_logic_vector(11 downto 0);
signal vga_font_d          : std_logic_vector(7 downto 0);

-- VGA control flipflops
signal vga_x               : std_logic_vector(7 downto 0);
signal vga_y               : std_logic_vector(6 downto 0);
signal vga_char            : std_logic_vector(7 downto 0);
signal vga_ctl             : std_logic_vector(7 downto 0);

type vga_command_type is ( vc_idle,          -- idle is not literally idle: the vram is constantly being painted
                           vc_print,         -- print a character aka transfer a byte into vram
                           vc_print_store,   -- make sure we, addr and data are stable long enough for the vram
                           vc_clrscr,        -- clear the screen
                           vc_clrscr_run,
                           vc_clrscr_store,
                           vc_clrscr_inc
                         );
signal vga_cmd             : vga_command_type := vc_idle;
signal vga_busy            : std_logic;
                      
---- memory read functionality
signal vga_read_data       : std_logic_vector(7 downto 0); -- ff: store current read values
                      
-- vram control signals
signal vmem_disp_addr      : std_logic_vector(15 downto 0); -- realtime vga display (the vga80x40 component scans it all the time)
signal vmem_addr           : std_logic_vector(15 downto 0); -- accessing the vram via the cpu
signal vmem_we             : std_logic;
signal vmem_data           : std_logic_vector(7 downto 0);

-- hardware scrolling and whole vram access
signal vmem_offs_rw        : std_logic := '0';
signal vmem_offs_display   : std_logic := '0';
signal offs_display        : std_logic_vector(15 downto 0) := (others => '0');
signal offs_rw             : std_logic_vector(15 downto 0) := (others => '0');
signal print_addr_w_offs   : std_logic_vector(15 downto 0);

-- command type: print char
signal vga_print           : std_logic := '0';
signal reset_vga_print     : std_logic;
signal print_addr          : std_logic_vector(11 downto 0);

-- command type: clear screen
signal clrscr_cnt          : IEEE.NUMERIC_STD.unsigned(15 downto 0);
signal vga_clrscr          : std_logic := '0';
signal reset_vga_clrscr    : std_logic;

-- state machine signals
signal fsm_next_vga_cmd    : vga_command_type;
signal fsm_clrscr_cnt      : IEEE.NUMERIC_STD.unsigned(15 downto 0);


begin

   vga : vga80x40
      port map (
         reset => reset,
         clk25MHz => clk25MHz,
         R => R,
         G => G,
         B => B,
         hsync => hsync,
         vsync => vsync,
         TEXT_A => vga_text_a,
         TEXT_D => vga_text_d,
         FONT_A => vga_font_a,
         FONT_D => vga_font_d,
         ocrx => vga_x,
         ocry => "0" & vga_y,
         octl => vga_ctl
      );

   video_ram : video_bram
      generic map (
         SIZE_BYTES => VGA_RAM_SIZE,                     -- see env1_globals.vhd
         CONTENT_FILE => "../vga_textmode.vhd",          -- dummy file that is not read ...
         FILE_LINES => 0,                                -- ... because FILE_LINES = 0
         DEFAULT_VALUE => x"20"                          -- ACSII code of the space character
      )
      port map (
         clk => clk25MHz,
         we => vmem_we,
         address_o => vmem_disp_addr,
         data_o => vga_text_d,
         address_i => vmem_addr,
         data_i => vmem_data,
         pr_clk => clk,
         pr_addr => print_addr_w_offs,
         pr_data => vga_read_data
      );
      
   font_rom : video_bram
      generic map (
         SIZE_BYTES => 3072,
         CONTENT_FILE => "lat9w-12_sy2002.rom",
         FILE_LINES => 3072,
         DEFAULT_VALUE => x"00"
      )
      port map (
         clk => clk25MHz,
         we => '0',
         address_o => "0000" & vga_font_a,
         data_o => vga_font_d,
         address_i => (others => '0'),
         data_i => (others => '0'),
         pr_clk => '0',
         pr_addr => (others => '0')
      );
         
   fsm_advance_state : process(clk25MHz, reset)
   begin
      if reset = '1' then
         vga_cmd <= vc_idle;
         clrscr_cnt <= (others => '0');
      else
         if falling_edge(clk25MHz) then
            vga_cmd <= fsm_next_vga_cmd;
            clrscr_cnt <= fsm_clrscr_cnt;
         end if;
      end if;     
   end process;
   
   fsm_calc_state : process(vga_cmd, vga_print, vga_clrscr, clrscr_cnt)
   variable new_clrscr_cnt : IEEE.NUMERIC_STD.unsigned(15 downto 0);
   begin
      fsm_next_vga_cmd <= vga_cmd;
      fsm_clrscr_cnt <= clrscr_cnt;
      reset_vga_print <= '0';
      reset_vga_clrscr <= '0';
      
      case vga_cmd is
         -- while in idle mode, new commands are recognized
         when vc_idle =>
            -- trigger print command
            if vga_print = '1' then
               fsm_next_vga_cmd <= vc_print;
            end if;

            -- trigger clearscreen command
            if vga_clrscr = '1' then
               fsm_next_vga_cmd <= vc_clrscr;
            end if;
            
         -- command execution: print
         when vc_print =>
            reset_vga_print <= '1';
            fsm_next_vga_cmd <= vc_print_store;
         
         when vc_print_store =>
            fsm_next_vga_cmd <= vc_idle;
                       
         -- command execution: clear screen
         when vc_clrscr =>
            fsm_clrscr_cnt <= (others => '0');
            fsm_next_vga_cmd <= vc_clrscr_run;
            
         when vc_clrscr_run =>
            fsm_next_vga_cmd <= vc_clrscr_store;
         
         when vc_clrscr_store =>
            fsm_next_vga_cmd <= vc_clrscr_inc;
         
         when vc_clrscr_inc =>
            new_clrscr_cnt := clrscr_cnt + 1;
            fsm_clrscr_cnt <= new_clrscr_cnt;
            if new_clrscr_cnt = VGA_RAM_SIZE then
               reset_vga_clrscr <= '1';
               fsm_next_vga_cmd <= vc_idle;
            else
               fsm_next_vga_cmd <= vc_clrscr_run;
            end if;
            
         when others => null;   
      end case;      
   end process;
   
   calc_vmem_signals : process(vga_cmd, print_addr_w_offs, vga_char, clrscr_cnt)
   begin      
      case vga_cmd is
         when vc_print | vc_print_store  =>
            vmem_we <= '1';
            vmem_addr <= print_addr_w_offs;            
            vmem_data <= vga_char;
            
         when vc_clrscr_run | vc_clrscr_store =>
            vmem_we <= '1';
            vmem_addr <= std_logic_vector(clrscr_cnt);
            vmem_data <= x"20"; -- space character
            
         when others =>
            vmem_we <= '0';
            vmem_addr <= (others => '0');            
            vmem_data <= (others => '0');
            
      end case;
   end process;
      
   write_vga_registers : process(clk, reset)
      variable vx : IEEE.NUMERIC_STD.unsigned(7 downto 0);
      variable vy : IEEE.NUMERIC_STD.unsigned(6 downto 0);
      variable memory_pos : std_logic_vector(13 downto 0); -- x + (80 * y)
   begin  
      if reset = '1' then
         vga_x <= (others => '0');
         vga_y <= (others => '0');
         vga_ctl <= (others => '0');
         vga_char <= (others => '0');
         print_addr <= (others => '0');
         vmem_offs_display <= '0';
         vmem_offs_rw <= '0';         
         offs_display <= (others => '0');
         offs_rw <= (others => '0');
      else                  
         if falling_edge(clk) then
            if en = '1' and we = '1' then
               case reg is
                  -- status register
                  when x"0" =>
                     vga_ctl <= data(7 downto 0);
                     vmem_offs_display <= data(10);
                     vmem_offs_rw <= data(11);
                     
                  -- cursor x register
                  when x"1" =>
                     vga_x <= data(7 downto 0);
                     vx := IEEE.NUMERIC_STD.unsigned(data(7 downto 0));
                     vy := IEEE.NUMERIC_STD.unsigned(vga_y);
                     memory_pos := std_logic_vector(vx + (vy * 80));                     
                     print_addr <= memory_pos(11 downto 0);
                  
                  -- cursor y register
                  when x"2" =>
                     vga_y <= data(6 downto 0);
                     vx := IEEE.NUMERIC_STD.unsigned(vga_x);
                     vy := IEEE.NUMERIC_STD.unsigned(data(6 downto 0));
                     memory_pos := std_logic_vector(vx + (vy * 80));
                     print_addr <= memory_pos(11 downto 0);

                  -- character print register
                  when x"3" =>
                     vga_char <= data(7 downto 0);                  
                     vx := IEEE.NUMERIC_STD.unsigned(vga_x);
                     vy := IEEE.NUMERIC_STD.unsigned(vga_y);
                     memory_pos := std_logic_vector(vx + (vy * 80));                  
                     print_addr <= memory_pos(11 downto 0);
                     
                  -- offset registers
                  when x"4" => offs_display <= data;
                  when x"5" => offs_rw <= data;
                  
                  when others => null;
               end case;
            end if;
         end if;
      end if;
   end process;
   
   detect_vga_print : process(clk, reset, reset_vga_print)
   begin
      if reset = '1' or reset_vga_print = '1' then
         vga_print <= '0';
      else
         if falling_edge(clk) then
            if en = '1' and we = '1' and reg = x"3" then         
               vga_print <= '1';
            end if;
         end if;
      end if;
   end process;
   
   detect_vga_clrscr : process(clk, reset, reset_vga_clrscr)
   begin
      if reset = '1' or reset_vga_clrscr = '1' then
         vga_clrscr <= '0';
      else
         if falling_edge(clk) then
            if en = '1' and we = '1' and reg = x"0" then
               vga_clrscr <= data(8);
            end if;
         end if;
      end if;
   end process;
         
   read_vga_registers : process(en, we, reg, vga_ctl, vga_x, vga_y, vga_char, vga_busy, vga_clrscr, vga_read_data,
                                vmem_offs_rw, vmem_offs_display, offs_display, offs_rw)
   begin   
      if en = '1' and we = '0' then
         case reg is            
            when x"0" => data <= "0000" &                               -- status register
                                 vmem_offs_rw &                         --    bit 11
                                 vmem_offs_display &                    --    bit 10
                                 vga_busy &                             --    bit 9
                                 vga_clrscr &                           --    bit 8
                                 vga_ctl;                               --    bits 0..7
            when x"1" => data <= x"00"  & vga_x;                        -- cursor x register
            when x"2" => data <= x"00" & '0' & vga_y;                   -- cursor y register
            when x"3" => data <= x"00"  & vga_read_data;                -- character print/read register
            when x"4" => data <= offs_display;                          -- display offset register
            when x"5" => data <= offs_rw;                               -- memory access (read/write) offset register
            when others => data <= (others => '0');
         end case;
      else
         data <= (others => 'Z');
      end if;
   end process;
   
   calc_vmem_disp_addr : process(vmem_offs_display, offs_display, vga_text_a)
      variable disp_addr : IEEE.NUMERIC_STD.unsigned(16 downto 0);
      variable disp_offs : IEEE.NUMERIC_STD.unsigned(16 downto 0);
   begin
      if vmem_offs_display = '1' then
         -- address for display = address generated by the vga80x40 component plus offset
         disp_offs := "0" & IEEE.NUMERIC_STD.unsigned(offs_display);
         disp_addr := disp_offs + IEEE.NUMERIC_STD.unsigned(vga_text_a);
         
         -- manual wrap around due to the (0..VGA_RAM_SIZE-1) memory size
         if disp_addr > (VGA_RAM_SIZE - 1) then
            disp_addr := disp_addr - VGA_RAM_SIZE;
         end if;
         
         vmem_disp_addr <= std_logic_vector(disp_addr(15 downto 0));
      else
         vmem_disp_addr <= "0000" & vga_text_a;      
      end if;
   end process;
   
   calc_print_addr_w_offs : process(vmem_offs_rw, offs_rw, print_addr)
      variable disp_addr : IEEE.NUMERIC_STD.unsigned(16 downto 0);
      variable disp_offs : IEEE.NUMERIC_STD.unsigned(16 downto 0);   
   begin
      if vmem_offs_rw = '1' then
         disp_offs := "0" & IEEE.NUMERIC_STD.unsigned(offs_rw);
         disp_addr := disp_offs + IEEE.NUMERIC_STD.unsigned(print_addr);
         if disp_addr > (VGA_RAM_SIZE - 1) then
            disp_addr := disp_addr - VGA_RAM_SIZE;
         end if;
         
         print_addr_w_offs <= std_logic_vector(disp_addr(15 downto 0));
      else
         print_addr_w_offs <= "0000" & print_addr;
      end if;
   end process;
   
   clk25MHz <= '0' when reset = '1' else
               not clk25MHz when rising_edge(clk50MHz);
   vga_busy <= '0' when vga_cmd = vc_idle else '1';
end beh;
