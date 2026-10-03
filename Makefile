# Makefile for the toy homomorphic encryption project
#
#   make              run all testbenches and the Python tests (same as "make test")
#   make <tb_name>    run one testbench, for example "make fhe_top_tb"
#   make pytest       run the Python tests only
#   make wave         run the chain testbench and open its waveform in GTKWave
#   make bitstream    build the FPGA bitstream with Vivado (SEED=<n> sets the PRNG seed)
#   make program      load the bitstream into the Urbana board
#   make gui          start the PC client (PORT=COM5 selects the port)
#   make gui-sim      start the PC client with the simulated FPGA (no board)
#   make demo         run fhe_demo.py
#   make clean        remove the build directory
#   make help         show this list

# On Windows, make uses cmd.exe when you start it from PowerShell or cmd.
# The recipes need a POSIX shell (rm, tee, grep), so use the sh from Git for Windows.
# PROGRA~1 is the short name of "Program Files". make cannot use a path with spaces here.
ifeq ($(OS),Windows_NT)
GIT_SH := C:/PROGRA~1/Git/bin/sh.exe
ifneq ($(wildcard $(GIT_SH)),)
SHELL := $(GIT_SH)
# make runs simple commands (rm, mkdir) without the shell, so put the Git tools on PATH too.
export PATH := C:\PROGRA~1\Git\usr\bin;$(PATH)
endif
# use the newest Vivado installation, if vivado is not on PATH
VIVADO_FOUND := $(lastword $(sort $(wildcard C:/AMDDesignTools/*/Vivado/bin/vivado.bat C:/Xilinx/Vivado/*/bin/vivado.bat)))
endif

IVERILOG ?= iverilog
VVP      ?= vvp
GTKWAVE  ?= gtkwave
PYTHON   ?= python
VIVADO   ?= $(if $(VIVADO_FOUND),$(VIVADO_FOUND),vivado)

IVFLAGS  := -g2005 -Wall

BUILD    := build

# RTL source files. Add a new module here.
RTL := rtl/fhe_encrypt_byte.v \
       rtl/fhe_decrypt_byte.v \
       rtl/fhe_capitalize_byte.v \
       rtl/fhe_capitalize_seq.v \
       rtl/fhe_prng.v \
       rtl/uart_rx.v \
       rtl/uart_tx.v \
       rtl/fhe_controller.v \
       rtl/fhe_top.v

# Testbenches: each name is tb/<name>.v, and the top module has the same name
TBS := fhe_encrypt_byte_tb \
       fhe_decrypt_byte_tb \
       fhe_capitalize_byte_tb \
       fhe_chain_tb \
       fhe_capitalize_seq_tb \
       uart_tb \
       fhe_top_tb

.PHONY: all test $(TBS) pytest wave bitstream program gui gui-sim demo clean help

all: test

# Run every testbench and the Python tests. Stop with an error if one fails.
test: $(TBS) pytest
	@echo "All tests passed."

# Run one testbench. A testbench passes only if its log contains "PASS"
# and does not contain "FAIL" or "ERROR".
$(TBS): %: $(BUILD)/%.out
	@echo "=== $@"
	@$(VVP) -n $< | tee $(BUILD)/$@.log
	@grep -q "^PASS" $(BUILD)/$@.log
	@! grep -q -E "FAIL|ERROR" $(BUILD)/$@.log

# Compile one testbench with all RTL files. -s selects the top module.
$(BUILD)/%.out: tb/%.v $(RTL) | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -s $* -o $@ $(RTL) $<

$(BUILD):
	mkdir -p $(BUILD)

pytest:
	@echo "=== Python tests"
	cd sw && $(PYTHON) -m pytest -q -p no:cacheprovider

wave: fhe_chain_tb
	$(GTKWAVE) $(BUILD)/fhe_chain_tb.vcd

# Vivado runs in build/vivado, so its scratch files (.Xil, logs) stay out of the project root.
bitstream:
	mkdir -p $(BUILD)/vivado
	cd $(BUILD)/vivado && "$(VIVADO)" -mode batch -nojournal -nolog \
		-source ../../tools/build_urbana.tcl $(if $(SEED),-tclargs $(SEED))

program:
	mkdir -p $(BUILD)/vivado
	cd $(BUILD)/vivado && "$(VIVADO)" -mode batch -nojournal -nolog \
		-source ../../tools/program_urbana.tcl

gui:
	cd sw && $(PYTHON) fhe_gui.py $(if $(PORT),--port $(PORT))

gui-sim:
	cd sw && $(PYTHON) fhe_gui.py --sim

demo:
	$(PYTHON) fhe_demo.py

clean:
	rm -rf $(BUILD)

help:
	@echo "make              run all testbenches and the Python tests"
	@echo "make <tb_name>    run one testbench: $(TBS)"
	@echo "make pytest       run the Python tests only"
	@echo "make wave         run fhe_chain_tb and open the waveform in GTKWave"
	@echo "make bitstream    build build/vivado/fhe_top.bit (SEED=<n> sets the PRNG seed)"
	@echo "make program      load the bitstream into the Urbana board"
	@echo "make gui          start the PC client (PORT=COM5 selects the port)"
	@echo "make gui-sim      start the PC client with the simulated FPGA"
	@echo "make demo         run fhe_demo.py"
	@echo "make clean        remove $(BUILD)/"
	@echo "Vivado: $(VIVADO)"
