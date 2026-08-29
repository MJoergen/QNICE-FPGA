# CPU Replacement

This blog will describe the effort of retro-fitting my pipelined QNICE CPU into
this design.

## Current design
The current design uses the following interface

```
entity QNICE_CPU is
port (
   -- clock
   clk            : in  std_logic;
   reset          : in  std_logic;
   wait_for_data  : in  std_logic;                          -- 1=CPU adds wait cycles while re-reading from bus
   addr           : out std_logic_vector(15 downto 0);      -- 16 bit address bus
   -- bidirectional 16 bit data bus
   data_in        : in  std_logic_vector(15 downto 0);      -- receive data
   data_out       : out std_logic_vector(15 downto 0);      -- send data
   data_dir       : out std_logic;                          -- 1=DATA is sending, 0=DATA is receiving
   data_valid     : out std_logic;                          -- while DATA_DIR = 1: DATA contains valid data
   -- signals about the CPU state
   halt           : out std_logic;                          -- 1=CPU halted due to the HALT command, 0=running
   ins_cnt_strobe : out std_logic;                          -- goes high for one clock cycle for each new instruction
   -- interrupt system                                      -- refer to doc/intro/qnice_intro.pdf to learn how this works
   int_n          : in  std_logic := '1';
   igrant_n       : out std_logic
);
```

The utilization report shows:
* Slice LUTs       = 3468
   * LUT as Logic  = 2060
   * LUT as Memory = 1408
* Slice Registers  =  396
* Block RAM        =    0

