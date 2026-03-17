# --- Variables ---
INC_DIR  = ../modules
BFLAGS   = -i $(INC_DIR) -f filelist.txt
TOP_MOD  = tb_pipeline
SNAPSHOT = riscv_sim
MEM_GEN  = ../mem_generator

# Vivado Tools
XVLOG = xvlog
XELAB = xelab
XSIM  = xsim

.PHONY: help clean sort addition negative fib

help:
	@echo "Usage: make <program_name> (e.g. make addition)"

# Generic Rule for all programs
sort addition negative fib xor:
# 1. Generate Hex Files
	$(MAKE) clean -C $(MEM_GEN)
	$(MAKE) $@ -C $(MEM_GEN)

# 2. Copy Hex Files to current directory
# Adjusting the path based on your 'imem_dmem' subfolder structure
	cp $(MEM_GEN)/imem_dmem/imem.hex .
	cp $(MEM_GEN)/imem_dmem/dmem.hex .
	
# 3. Vivado Simulation Flow
	$(XVLOG) $(BFLAGS)
	$(XELAB) -top $(TOP_MOD) -snapshot $(SNAPSHOT) -debug typical
	
# 4. Run Simulation
	$(XSIM) $(SNAPSHOT) -runall -log stdout

clean:
	@rm -rf xsim.dir/ .Xil/
	@rm -f xvlog.log xvlog.pb xelab.log xelab.pb xsim.log xsim.jou xsim.pb
	@rm -f pipeline.vcd
	@rm -f imem.hex dmem.hex