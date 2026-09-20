# RV32IM SoC - convenience targets (all real work lives in scripts/)

PYTHON ?= python3
SEEDS  ?= 50

.PHONY: all test isa random fw demo mutation wave clean help

all: test

help:
	@echo "make test       full regression: ISA + random co-simulation + firmware"
	@echo "make isa        directed ISA tests (co-simulated against the ISS)"
	@echo "make random     SEEDS=N constrained-random programs (default 50)"
	@echo "make demo       run the firmware demo and show the UART console"
	@echo "make mutation   inject RTL bugs and check the test-suite kills them"
	@echo "make wave       dump build/wave.vcd for the firmware demo"
	@echo "make clean"

test:
	$(PYTHON) scripts/run_tests.py isa random fw -n $(SEEDS)

isa:
	$(PYTHON) scripts/run_tests.py isa

random:
	$(PYTHON) scripts/run_tests.py random -n $(SEEDS)

fw demo:
	$(PYTHON) scripts/run_tests.py fw -v

mutation:
	$(PYTHON) scripts/mutation_test.py

wave: fw
	vvp -n build/sim/tb_soc.vvp +hex=build/fw/demo/demo.hex +uart_in=ping,exit +vcd

clean:
	rm -rf build
