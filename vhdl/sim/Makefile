SRC_DIR = ..
#SRCS += $(SRC_DIR)/cpu_constants.vhd
SRCS += $(SRC_DIR)/tools.vhd
SRCS += $(SRC_DIR)/fifo.vhd
SRCS += $(SRC_DIR)/kbd_constants.vhd
SRCS += $(SRC_DIR)/hw/nexys4ddr/env1_globals.vhd
SRCS += $(SRC_DIR)/debounce.vhd
SRCS += $(SRC_DIR)/hw/nexys4ddr/nibble_to_cathode.vhd
SRCS += $(SRC_DIR)/hw/nexys4ddr/sytargetcnt.vhd
SRCS += $(SRC_DIR)/hw/nexys4ddr/drive_7digits.vhd
SRCS += $(SRC_DIR)/hw/nexys4ddr/til_display.vhd
SRCS += $(SRC_DIR)/hw/nexys4ddr/ps2_keyboard.vhd
SRCS += $(SRC_DIR)/hw/nexys4ddr/ps2_keyboard_to_ascii.vhd
SRCS += $(SRC_DIR)/hw/nexys4ddr/keyboard.vhd
#SRCS += $(SRC_DIR)/alu_shifter.vhd
#SRCS += $(SRC_DIR)/alu.vhd
SRCS += $(SRC_DIR)/basic_uart.vhd
#SRCS += $(SRC_DIR)/block_ram.vhd
#SRCS += $(SRC_DIR)/block_rom_ise.vhd
#SRCS += $(SRC_DIR)/block_rom.vhd
SRCS += $(SRC_DIR)/bus_uart.vhd
SRCS += $(SRC_DIR)/byte_bram.vhd
SRCS += $(SRC_DIR)/cycle_counter.vhd
SRCS += $(SRC_DIR)/daisy_chain.vhd
SRCS += $(SRC_DIR)/EAE.vhd
SRCS += $(SRC_DIR)/interrupt_controller.vhd
SRCS += $(SRC_DIR)/mmio_mux.vhd
#SRCS += $(SRC_DIR)/register_file.vhd
#SRCS += $(SRC_DIR)/qnice_cpu.vhd
SRCS += $(SRC_DIR)/sd_spi.vhd
SRCS += $(SRC_DIR)/sdcard.vhd
SRCS += $(SRC_DIR)/sysinfo.vhd
SRCS += $(SRC_DIR)/timer.vhd
SRCS += $(SRC_DIR)/timer_module.vhd
SRCS += $(SRC_DIR)/sim/uart.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/cpu_constants.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/sub/one_stage_fifo.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/sub/one_stage_buffer.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/sub/two_stage_buffer.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/sub/two_stage_fifo.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/sub/dp_ram.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/sub/pipe_concat.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/registers/registers.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/debug.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/cpu_main/sub/sequencer.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/cpu_main/sub/microcode.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/cpu_main/sub/alu_flags.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/cpu_main/sub/alu_data.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/cpu_main/sub/alu.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/cpu_main/prepare.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/cpu_main/decode.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/cpu_main/write.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/cpu_main/cpu_main.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/fetch/icache.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/fetch/fetch.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/memory/memory.vhd
SRCS += $(SRC_DIR)/../qnice_cpu/src/cpu.vhd
SRCS += $(SRC_DIR)/core.vhd
SRCS += $(SRC_DIR)/sim/tb_core.vhd


OPT_WAVE = --wave=tb_core.ghw
OPT_STOP_TIME = --stop-time=3000us

all:
	ghdl -a --std=08 -frelaxed -fexplicit -fsynopsys $(SRCS)
	ghdl -r --std=08 -frelaxed -fexplicit -fsynopsys tb_core $(OPT_WAVE) $(OPT_STOP_TIME)

show:
	gtkwave tb_core.ghw tb_core.gtkw

clean:
	rm -rf tb_core.ghw
	rm -rf work-obj93.cf
	rm -rf work-obj08.cf

