---
 
```markdown
## Multi-DTB Selection
 
### Introduction
 
#### Feature Description
 
Qualcomm supports multiple SoCs and boards within a single software release binary, which requires packaging all corresponding Device Tree Blobs (DTBs) into a single image. To ensure the appropriate DTB(O)s are selected for each platform, a mechanism for dynamic devicetree selection is necessary. Flattened Image Tree (FIT) is a standard file format for packaging images which is widely used in community. This format can be leveraged by UEFI firmware to facilitate multi-DTB selection and meet platform-specific requirements. Documentation about FIT is available in https://fitspec.osfw.foundation/.
The following naming convention is used:
- **FIT**: Flattened Image Tree.
- **DT**: Device Tree 
- **FDT**: Flattened Device Tree
- **.its**: image tree source.
- **.dtb**: device tree blob.
**References:**
- https://docs.u-boot.org/en/latest/usage/fit/index.html
- https://fitspec.osfw.foundation/
 
---
 
### Requirements
 
#### Requirements
 
The requirement is to enable DT selection through a widely accepted, upstream-aligned approach. The FIT-based approach, commonly adopted within the U-Boot community, offers a standardized solution for this purpose.
This design would be the first implementation utilizing FIT to facilitate DT selection from a multi-DTB binary.

---
 
### Design
 
#### Design Description
 
There are different components that play a role in the kernel booting process which typically includes the devicetree, kernel image and a ramdisk image. FIT provides a flexible and extensible format to support these multiple components.
FIT also supports multiple configurations, so that the same FIT can be used to boot multiple platforms, with some components in common (e.g., kernel) and some specific to that platform (e.g., devicetree).
The Flattened Image Tree Specification (FITSpec) suggests the possible image selection mechanism but doesn’t mandate any specific format.

**Detailed Description:**
1. In the FIT ITS file, each configuration comprises of a compatible string along with a declaration for the base DT blob and the overlays in sequence. Few such configuration node examples are provided in the .its tree format below.
2. This implementation uses a metadata binary structured in DT format for selecting the appropriate configuration. A node, named fdt-qcom-metadata.dtb, for metadata binary is provided under images node in the FIT tree with type “qcom_metadata”.
3. The compatible string suffixes in the FIT tree can be put in any order but node corresponding to each suffix must be present in the qcom-dtb-metadata binary.
If any new suffix is introduced, it must be added to metadata (pls refer qcom-dtb-metadata.dts below this section). The new suffix sub-node must be added under the relevant node.
   - Suggested pattern: `<soc>-<soc-sku>-<board>-<board-subtype-peripheral-subtype>-<board-subtype-storage-type>-<board-subtype-memory-size>-<softsku>-<oem>`
4. There is to be build-time check to find any gaps/disparity between the compatible string suffixes versus their metadata definitions.
5. Each of the suffixes inside the compatible string need to be exact match for a DTB to get selected. Upon any mismatch a configuration is rejected, and search moves ahead with other available configurations.
6. The compatible string that gets matched has its corresponding DTB(O)s selected for boot up.

---
 
#### Config table ITS
 
```dts
/dts-v1/;
 
/ {
	description = "Qualcomm FIT Image for DTBs";

	images {
		fdt-0 {
			description = "metadata for multi-DTB selection";
			data = /incbin/("./qcom-dts-metadata.dtb");
			type = "qcom_metadata";
		};
		fdt-1 {
			data = /incbin/("./arch/arm64/boot/dts/qcom/qcm6490-idp.dtb");
			type = "flat_dt";
		};
		fdt-2 {
			data = /incbin/("./arch/arm64/boot/dts/qcom/qcs6490-rb3gen2.dtb");
			type = "flat_dt";
		};
		fdt-3 {
			data = /incbin/("./arch/arm64/boot/dts/qcom/qcs6490-rb3gen2-vision-mezzanine.dtb");
			type = "flat_dt";
		};
		fdt-4 {
			data = /incbin/("./arch/arm64/boot/dts/qcom/qcs6490-rb3gen2-industrial-mezzanine.dtb");
			type = "flat_dt";
		};
		fdt-5 {
			data = /incbin/("./arch/arm64/boot/dts/qcom/lemans-evk.dtb");
			type = "flat_dt";
		};
		fdt-6 {
			data = /incbin/("./arch/arm64/boot/dts/qcom/qcs9100-ride.dtb");
			type = "flat_dt";
		};
		fdt-7 {
			data = /incbin/("./arch/arm64/boot/dts/qcom/qcs8300-ride.dtb");
			type = "flat_dt";
		};
		fdt-8 {
			data = /incbin/("./arch/arm64/boot/dts/qcom/monaco-evk.dtb");
			type = "flat_dt";
		};
		fdt-9 {
			data = /incbin/("./arch/arm64/boot/dts/qcom/qcs615-ride.dtb");
			type = "flat_dt";
		};
	};
 
	configurations {
		conf-1 {
			compatible = "qcom,qcm6490-idp";
			fdt = "fdt-1";
		};
		conf-2 {
			compatible = "qcom,qcs6490-iot";
			fdt = "fdt-2";
		};
		conf-3 {
			compatible = "qcom,qcs6490-iot-subtype2";
			fdt = "fdt-3";
		};
		conf-4 {
			compatible = "qcom,qcs6490r10-iot-subtype2";
			fdt = "fdt-3";
		};
		conf-5 {
			compatible = "qcom,qcs6490-iot-subtype9";
			fdt = "fdt-4";
		};
		conf-6 {
			compatible = "qcom,qcs9075-iot";
			fdt = "fdt-5";
		};
		conf-7 {
			compatible = "qcom,qcs9100-adp";
			fdt = "fdt-6";
		};
		conf-8 {
			compatible = "qcom,qcs8300-adp";
			fdt = "fdt-7";
		};
		conf-9 {
			compatible = "qcom,qcs8275-iot";
			fdt = "fdt-8";
		};
		conf-10 {
			compatible = "qcom,qcs615-adp";
			fdt = "fdt-9";
		};
	};
};
 
```
 
---
 
### DTB Metadata Description and Parsing
 
- The QCOM metadata supports soc, soc-sku, board, board-subtype-peripheral-subtype, board-subtype-storage-type, board-subtype-memory-size, softsku and oem DT nodes. Sub-nodes of respective type can be added under each node.

- The SoC specific identifiers are encapsulated in a DT property named msm-id .  

- Each sub-node under soc node must contain msm-id property of type <u32 u32>.
Bits 0-15 of the first 32-bit cell represents the chip identifier, and the remaining bits are reserved. 
Bits 0-7 of the second 32-bit cell represents the chip version, and the remaining bits are reserved. 
The chip version is further divided into major version (bits 4-7) and minor version (bits 0-3). 

-  Each sub-node under soc-sku node should contain msm-id property of type <u32>.
Bits 20-21 of the 32-bit value represent package-id, bits 16-19 represent the foundry-id and the remaining bits are ignored by the firmware.

- The board specific identifiers are encapsulated in DT properties named board-id and board-subtype.

- Each sub-node under board node must contain a board-id property is of the type <u32>. 
Bits 0-7 represent the board type, bits 8-11 represent the board major version, bits 12-15 represent the board minor version and the remaining bits are reserved.

- Each sub-node under board-subtype-peripheral-subtype, board-subtype-storage-type and board-subtype-memory-size nodes should contain a board-subtype property of type <u32>.
When board-subtype property is present in sub-node of board-subtype-peripheral-subtype node, bits 0-7 represent the peripheral-based subtype and the remaining bits are ignored by the firmware.
When board-subtype property is present in sub-node of board-subtype-storage-type node, bits 12-14 represent the storage type and the remaining bits are ignored by the firmware.
When board-subtype property is present in sub-node of board-subtype-memory-size node, bits 8-11 represent the memory size and the remaining bits are ignored by the firmware.
Remaining bits in the board-subtype property are reserved for future use.

- Each sub-node under oem node must contain a property named oem-id which is of <u32> type.
The oem-id represents the OEM. It is to be added by the OEM for selection of their board specific DT.

- Each sub-node under softsku node must contain a property named softsku-id which is of <u32> type.
The softsku-id represents the software SKU. It is added for soft SKU (license) based selection of DT.

- The msm-id gets compared with the chip identifier value read from the SoC.

- The board-id, board-subtype-peripheral-subtype and oem-id get compared with the hardware description values (Configuration Data Table - CDT) flashed on the board's persistent memory.

- The board-subtype-storage-type gets compared with the board's boot device type detected by the UEFI firmware.

- The board-subtype-memory-size gets compared with the board's DDR size detected by the UEFI firmware.

---
 
#### qcom-dtb-metadata.dts
 
```dts
// SPDX-License-Identifier: BSD-3-Clause
/*
* qcom dtb metadata device tree source
*
* Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
*
*/
 
/dts-v1/;
 
/ {
	description = "Image with compressed metadata blob";

	soc {
		qcm6490 {
			msm-id = <0x000001f1 0x0>;
		};

		qcm6490r10 {
			msm-id = <0x000001f1 0xa>;
		};
 
		qcs6490 {
			msm-id = <0x000001f2 0x0>;
		};
 
		qcs6490r10 {
			msm-id = <0x000001f2 0xa>;
		};
 
		qcs9100 {
			msm-id = <0x0000029b 0x0>;
		};
 
		qcs9075 {
			msm-id = <0x000002a4 0x0>;
		};
 
		qcs8300 {
			msm-id = <0x000002a2 0x0>;
		};
 
		qcs8275 {
			msm-id = <0x000002a3 0x0>;
		};
 
		qcs615 {
			msm-id = <0x000002a8 0x0>;
		};
	};
 
	soc-sku {
		sku0 {
			msm-id = <0x00030000>;
		};
	};
 
	board {
		cdp {
			board-id = <0x00000001>;
		};
 
		mtp {
			board-id = <0x00000008>;
		};
 
		adp {
			board-id = <0x00000019>;
		};
 
		iot {
			board-id = <0x00000020>;
		};
 
		atp {
			board-id = <0x00000021>;
		};
 
		idp {
			board-id = <0x00000022>;
		};
	};
 
	board-subtype-peripheral-subtype {
		subtype0 {
			board-subtype  = <0x00000000>;
		};
 
		subtype1 {
			board-subtype  = <0x00000001>;
		};
 
		subtype2 {
			board-subtype  = <0x00000002>;
		};
 
		subtype3 {
			board-subtype  = <0x00000003>;
		};
 
		subtype4 {
			board-subtype  = <0x00000004>;
		};
 
		subtype5 {
			board-subtype  = <0x00000005>;
		};
 
		subtype6 {
			board-subtype  = <0x00000006>;
		};
 
		subtype7 {
			board-subtype  = <0x00000007>;
		};
 
		subtype8 {
			board-subtype  = <0x00000008>;
		};
 
		subtype9 {
			board-subtype  = <0x00000009>;
		};
 
		subtype10 {
			board-subtype  = <0x0000000a>;
		};
	};
 
 
	board-subtype-storage-type {
		emmc {
			board-subtype = <0x00000000>;
		};
 
		ufs {
			board-subtype = <0x00001000>;
		};
 
		nand {
			board-subtype = <0x00002000>;
		};
	};
 
 
	board-subtype-memory-size {
		256MB {
			board-subtype = <0x00000100>;
		};
 
		512MB {
			board-subtype = <0x00000200>;
		};
 
		1GB {
			board-subtype = <0x00000300>;
		};
 
		2GB {
			board-subtype = <0x00000400>;
		};
 
		3GB {
			board-subtype = <0x00000500>;
		};
 
		4GB {
			board-subtype = <0x00000600>;
		};
 
		4GB+ {
			board-subtype = <0x00000000>;
		};
	};
 
	softsku {
		softsku0 {
			softsku-id = <0x0>;
		};
 
		softsku1 {
			softsku-id = <0x1>;
		};
	};
 
	oem {
		oem1 {
			oem-id = <0x1>;
		};
	};
};
 
 
```
 
---
 
### Image-building procedure
 
- FIT is normally built initially with image data in the ‘data’ property of each image node. It is also possible for this data to reside outside the FIT itself. This allows the ‘FDT’ part of the FIT to be quite small, so that it can be loaded and scanned without loading a large amount of data. Then when an image is needed it can be loaded from an external source.
- External FITs use ‘data-offset’ or ‘data-position’ instead of ‘data’. The mkimage tool can convert a FIT to use external data using the `-E` argument.
- The current Qualcomm UEFI firmware supports external FIT only. FIT image will have a configuration table FDT, metadata FDT and DTB and DTBO binaries stacked together. Configuration table FDT will have offset of the DTB/DTBO within the same buffer.
- The mkimage tool provides a `-B` argument to align each image to a specific block size.
- Current UEFI firmware implementation does not support compression property and hash node.
- Current UEFI firmware implementation supports devicetree only. Kernel, ramdisk etc images would be ignored by the firmware.

**Creation of FIT image which is 8-byte aligned:**
```sh
mkimage -f x.its x.itb -E -B 8

How to get dtc tool? 
sudo apt-get update
sudo apt-get install device-tree-compiler
 
compilation of qcom-metadata : (dts to dtb) : 
dtc -I dts -O dtb -o qcom-metadata.dtb qcom-metadata.dts
 
how to get mkimage tool:
sudo apt-get update
sudo apt-get install u-boot-tools
 
creation of fit image using .its
mkimage -f qcom-fitimage.its <current-path>/out/qclinux_fit.img -E -B 8
 
 
packing fit image into dtb.bin:
script generate_efi_boot.sh  is available at - kmake-image/generate_boot_bins.sh at main · qualcomm-linux/kmake-image
command: 
./generate_efi_boot.sh "/<current-path>/out" "/<current-path>/dtb.bin"
Note- everything kept in "out" directory will be packed into dtb.bin
 
flashing command:
flash <meta> &&
fastboot erase dtb_a && fastboot erase dtb_b &&
fastboot flash dtb_a dtb.bin &&
fastboot flash dtb_b dtb.bin
kmake-image/generate_boot_bins.sh at main · qualcomm-linux/kmake-image
Docker setup for building the Linux kernel. Contribute to qualcomm-linux/kmake-image development by creating an account on GitHub.
 
```
---

### Document Version 1.0

### Author: Kaushal Kumar kaushalk@qti.qualcomm.com
### Reviewer: Naina Mehta <nainmeht@qti.qualcomm.com>

```
---
