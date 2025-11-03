# Makefile for compiling qcom-metadata.dts to qcom-metadata.dtb
#
DTC      ?= dtc
SRC      := qcom-metadata.dts
OUT      := qcom-metadata.dtb
O        ?= .

OUTFILE  := $(O)/$(OUT)

all: $(OUTFILE)

$(OUTFILE): $(SRC)
	@mkdir -p $(O)
	@$(DTC) -I dts -O dtb -o $(OUTFILE) $(SRC)
	@echo "DTC $(OUTFILE)"

clean:
	@rm -f $(OUTFILE)
	@echo "CLEAN $(OUTFILE)"
