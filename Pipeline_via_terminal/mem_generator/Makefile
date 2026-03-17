#//////////////////////////////////////////////////////
#/////////////////INCLUDING CROSS-COMPILER/////////////

CC      = riscv-none-elf-gcc
AR      = riscv-none-elf-ar
OBJDUMP = riscv-none-elf-objdump
OBJCOPY = riscv-none-elf-objcopy
READELF = riscv-none-elf-readelf


#///// flags for RV32i architecture///////////////////
CFLAGS  = -march=rv32i -mabi=ilp32


#////Source for c code file ///////////////////////////
SRC_ADDITION     = code_addition.c
SRC_SORT     = code_sort.c
SRC_NEGATIVE = code_negative.c
SRC_FIB = fibonacci.c
SRC_XOR = xor.c

TARGET   = code.elf

.PHONY: all clean

#/// generating .text file of code cross-compiled from highlevel-c code to risc-v code
# ////////////// Copying and converting the text file into binary files
#/////// Python script to convert the binary files into the required hex files

addition: $(SRC_ADDITION)
	$(CC) -c  $(SRC_ADDITION) -o $(TARGET) $(CFLAGS)
	$(OBJCOPY) -O binary $(TARGET) ./imem_dmem/imem.bin
	$(OBJCOPY) -j .data -O binary $(TARGET) ./imem_dmem/dmem.bin
	$(OBJDUMP) -d $(TARGET) > ./imem_dmem/code.dis
	cd imem_dmem && python bin2hex.py

sort: $(SRC_SORT)
	$(CC) -c  $(SRC_SORT) -o $(TARGET) $(CFLAGS)
	$(OBJCOPY) -O binary $(TARGET) ./imem_dmem/imem.bin
	$(OBJCOPY) -j .data -O binary $(TARGET) ./imem_dmem/dmem.bin
	$(OBJDUMP) -d $(TARGET) > ./imem_dmem/code.dis
	cd imem_dmem && python bin2hex.py

negative: $(SRC_NEGATIVE)
	$(CC) -c  $(SRC_NEGATIVE) -o $(TARGET) $(CFLAGS)
	$(OBJCOPY) -O binary $(TARGET) ./imem_dmem/imem.bin
	$(OBJCOPY) -j .data -O binary $(TARGET) ./imem_dmem/dmem.bin
	$(OBJDUMP) -d $(TARGET) > ./imem_dmem/code.dis
	cd imem_dmem && python bin2hex.py

fib: $(SRC_FIB)
	$(CC) -c  $(SRC_FIB) -o $(TARGET) $(CFLAGS)
	$(OBJCOPY) -O binary $(TARGET) ./imem_dmem/imem.bin
	$(OBJCOPY) -j .data -O binary $(TARGET) ./imem_dmem/dmem.bin
	$(OBJDUMP) -d $(TARGET) > ./imem_dmem/code.dis
	cd imem_dmem && python bin2hex.py
xor: $(SRC_XOR)
	$(CC) -c  $(SRC_XOR) -o $(TARGET) $(CFLAGS)
	$(OBJCOPY) -O binary $(TARGET) ./imem_dmem/imem.bin
	$(OBJCOPY) -j .data -O binary $(TARGET) ./imem_dmem/dmem.bin
	$(OBJDUMP) -d $(TARGET) > ./imem_dmem/code.dis
	cd imem_dmem && python bin2hex.py

# /////clean function
clean:
	$(RM) $(TARGET) ./imem_dmem/imem.bin ./imem_dmem/imem.hex ./imem_dmem/dmem.bin ./imem_dmem/dmem.hex ./imem_dmem/code.dis
