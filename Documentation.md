---

## FIT Based DTB Packaging and Selection
 
### Motivation & Goals
 
Qualcomm supports multiple SoCs and boards within a single software release binary, which requires packaging all corresponding Device Tree Blobs (DTBs) into a single image. To ensure the appropriate DTB(O)s are selected for each platform, a mechanism for dynamic devicetree selection is necessary. Flattened Image Tree (FIT) is a standard file format for packaging images which is widely used in community. This format can be leveraged by UEFI firmware to facilitate DTB selection and meet platform-specific requirements. Appropriate DTB selected for the platform by UEFI firmware is passed to HLOS supporting EFI boot.

#### Terminology
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
 
The requirement is to enable DT selection through a widely accepted, upstream-aligned approach. Need to package different DTBs in the same image and enable the firmware (e.g. UEFI) to select right DTB for the hardware platform (soc/board).

---
 
### Design
 
The FIT-based approach, commonly adopted within the U-Boot community, offers a standardized solution for this purpose.
This design would be the first implementation utilizing FIT to facilitate DT selection from a multi-DTB binary.
There are different components that play a role in the kernel booting process which typically includes the devicetree, kernel image and a ramdisk image. FIT provides a flexible and extensible format to support these multiple components.
FIT also supports multiple configurations, so that the same FIT can be used to boot multiple platforms, with some components in common (e.g., kernel) and some specific to that platform (e.g., devicetree).
The Flattened Image Tree Specification (FITSpec) suggests the possible image selection mechanism.

**Detailed Description:**
1. In the FIT ITS file, each configuration comprises of a compatible string along with a declaration for the base DT blob and the overlays in sequence. Few such configuration node examples are provided in the .its tree format below.
2. This implementation uses a metadata binary structured in DT format for selecting the appropriate configuration. A node, named fdt-qcom-metadata.dtb, for metadata binary is provided under images node in the FIT tree with type “qcom_metadata”.
3. The compatible string suffixes in the FIT tree can be put in any order but node corresponding to each suffix must be present in the qcom-dtb-metadata binary.
If any new suffix is introduced, it must be added to metadata (pls refer qcom-dtb-metadata.dts below this section). The new suffix sub-node must be added under the relevant node.
   - Suggested pattern: `<soc>-<soc-sku>-<socver>-<board>-<boardrev>-<board-subtype-peripheral-subtype>-<board-subtype-storage-type>-<board-subtype-memory-size>-<softsku>-<oem>`
4. There is to be build-time check to find any gaps/disparity between the compatible string suffixes versus their metadata definitions.
5. Each of the suffixes inside the compatible string need to be exact match for a DTB to get selected. Upon any mismatch a configuration is rejected, and search moves ahead with other available configurations.
6. The compatible string that gets matched has its corresponding DTB(O)s selected for boot up.

---
 
#### qcom-fitimage.its

Refer: https://github.com/qualcomm-linux/qcom-dtb-metadata/blob/main/qcom-fitimage.its
 
---
 
### DTB Metadata Description and Parsing
 
- The QCOM metadata supports soc, soc-sku, socver, board, boardrev, board-subtype-peripheral-subtype, board-subtype-storage-type, board-subtype-memory-size, softsku and oem DT nodes. Sub-nodes of respective type can be added under each node.

- The SoC specific identifiers are encapsulated in DT properties named msm-id and socver-id.

- Each sub-node under soc node must contain msm-id property of type <u32>.
Bits 0-15 of the 32-bit value represents the chip identifier, and the remaining bits are reserved.

- Each sub-node under soc-sku node should contain msm-id property of type <u32>.
Bits 20-21 of the 32-bit value represent package-id, bits 16-19 represent the foundry-id and the remaining bits are ignored by the firmware.

- Each sub-node under socver node should contain socver-id property of type <u32>.
Bits 0-3 represent the chip minor version, bits 4-7 represent the chip major version, and the remaining bits are reserved.

- The board specific identifiers are encapsulated in DT properties named board-id, boardrev-id and board-subtype.

- Each sub-node under board node must contain a board-id property of type <u32>.
Bits 0-7 represent the board type, and the remaining bits are reserved.

- Each sub-node under boardrev node must contain a boardrev-id property of type <u32>.
Bits 0-3 represent the board minor version, bits 4-7 represent the board major version, and the remaining bits are reserved.

- Each sub-node under board-subtype-peripheral-subtype, board-subtype-storage-type and board-subtype-memory-size nodes should contain a board-subtype property of type <u32>.
When board-subtype property is present in sub-node of board-subtype-peripheral-subtype node, bits 0-7 represent the peripheral-based subtype and the remaining bits are ignored by the firmware.
When board-subtype property is present in sub-node of board-subtype-storage-type node, bits 12-14 represent the storage type and the remaining bits are ignored by the firmware.
When board-subtype property is present in sub-node of board-subtype-memory-size node, bits 8-11 represent the memory size and the remaining bits are ignored by the firmware.
Remaining bits in the board-subtype property are reserved for future use.

- Each sub-node under oem node must contain a property named oem-id which is of <u32> type.
The oem-id represents the OEM. It is to be added by the OEM for selection of their board specific DT.

- Each sub-node under softsku node must contain a property named softsku-id which is of <u32> type.
The softsku-id represents the software SKU. It is added for soft SKU (license) based selection of DT.

- The msm-id and socver-id get compared with the chip identifier value read from the SoC.

- The board-id, boardrev-id and board-subtype-peripheral-subtype and oem-id get compared with the hardware description values (Configuration Data Table - CDT) flashed on the board's persistent memory.

- The board-subtype-storage-type gets compared with the board's boot device type detected by the UEFI firmware.

- The board-subtype-memory-size gets compared with the board's DDR size detected by the UEFI firmware.

---
 
#### Guidelines for adding socver and boardrev

- For any platform, the configuration entry with the shortest compatible string (containing only the soc and board fields) must always reference the latest hardware (soc / board) version.

- When adding support for a new hardware version that requires a separate DTB, update the fdt property in the configuration with the shortest compatible string so that it points to the DTB of the latest hardware version.
If the previously supported latest hardware version must continue to be used, add a new socver / boardrev entry in the metadata DTS for the earlier hardware. Additionally, add a new configuration entry in the FIT ITS that corresponds to the platform compatible with the newly added socver / boardrev.

- Consider the following example:
The "soc" platform supports two chip versions — socv1.0 and socv1.1 — and both versions share the same DTB (soc-v1.dtb).

FIT ITS:
```dts
config-1 {
	compatible = "qcom,soc";
	fdt = "fdt-soc-v1.dtb";
};

```
Now a new chip version socv2.0 is introduced, which requires new DTB (soc-v2.dtb).
The older chip versions must continue to be supported.

Updated FIT ITS:
```dts
config-1 {
        compatible = "qcom,soc";
        fdt = "fdt-soc-v2.dtb";
};

config-2 {
        compatible = "qcom,soc-socv1.0";
        fdt = ""fdt-soc-v1.dtb"
};

config-3 {
        compatible = "qcom,soc-socv1.1";
        fdt = "fdt-soc-v1.dtb";
};

```
Updated Metadata DTB:
```dts
socv1.0 {
        socver-id = <0x10>;
};

socv1.1 {
        socver-id = <0x11>;
};

```

- If older hardware requires a separate DT and is not currently supported in the FIT, add the required socver / boardrev entries in alphabetical order.

---

#### qcom-metadata.dts

Refer: https://github.com/qualcomm-linux/qcom-dtb-metadata/blob/main/qcom-metadata.dts
 
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

sudo apt-get update
sudo apt-get install device-tree-compiler
 
dtc -I dts -O dtb -o qcom-metadata.dtb qcom-metadata.dts
 
sudo apt-get update
sudo apt-get install u-boot-tools
 
mkimage -f qcom-fitimage.its <current-path>/out/qclinux_fit.img -E -B 8
 
# script generate_boot_bins.sh is available at https://github.com/qualcomm-linux/kmake-image/
./generate_boot_bins.sh "/<current-path>/out" "/<current-path>/dtb.bin"
# Note- everything kept in "out" directory will be packed into dtb.bin
 
flash <meta> &&
fastboot erase dtb_a && fastboot erase dtb_b &&
fastboot flash dtb_a dtb.bin &&
fastboot flash dtb_b dtb.bin
 
```

**Sample Workflow for Creation of FIT image for QLI based Boards**

UEFI firmware looks for the DTB image flashed in dtb_a partition via dtb.bin. If dtb.bin has "qclinux_fit.img", UEFI firmware proceeds with FIT based DT selection. If dtb.bin has "combined-dtb.dtb", it proceeds with legacy DT selection mechanism based on msm-id, board-id which are part of DT files itself.

For the FIT based DT selection, "qclinux_fit.img" contains qcom-fitimage.its along with all dtb/dtbo appended to it. The size and offset of each of the appended dtb/dtbo are part of generated FIT image.

For the Legacy DT selection, "combined-dtb.dtb" contains all dtb packed.
Script based creation of FIT image can be achieved using kmake-image/make_fitimage.sh at main · qualcomm-linux/kmake-image.

For the manual creation of FIT image, steps are given below.
```sh
# Install the necessary tools:
sudo apt-get install device-tree-compiler u-boot-tools mtools
# Clone the qcom-dtb-metadata project
git clone git@github.com:qualcomm-linux/qcom-dtb-metadata.git
mkdir fit_image
cp -rap qcom-dtb-metadata/qcom-fitimage.its qcom-dtb-metadata/qcom-next-fitimage.its qcom-dtb-metadata/qcom-metadata.dts fit_image/

# Copy the dtb/dtbo files from the kernel tree to the fit_image directory. For steps on cloning and building the Qualcomm Linux Kernel Tree, pls refer https://github.com/qualcomm-linux/kmake-image/blob/main/README.md.
# Checkout and build Qualcomm Linux Kernel : main branch, if you need dtb/dtbo from upstream kernel (https://github.com/qualcomm-linux/kernel/tree/main)
# Checkout and build Qualcomm Linux Kernel : qcom-next branch, if you need dtb/dtbo from qcom-next kernel (https://github.com/qualcomm-linux/kernel/tree/qcom-next). 
mkdir -p fit_image/arch/arm64/boot/dts/qcom/
# Copy the compiled *dtb* files from the kernel's kobj directory into your fit_image directory
cp -rap kobj/arch/arm64/boot/dts/qcom/*.dtb* fit_image/arch/arm64/boot/dts/qcom/

# Compile qcom-metadata.dts into qcom-metadata.dtb
cd fit_image
dtc -I dts -O dtb -o qcom-metadata.dtb qcom-metadata.dts

# Generate qclinux_fit.img from qcom-fitimage.its (or qcom-next-fitimage.its)
# Name of .img file has to be qclinux_fit.img since this name is hardcoded in UEFI code.
	# Naming convention used in UEFI code:
	#define FIT_BINARY_FILE         L"\\qclinux_fit.img"
	#define COMBINED_DTB_FILE       L"\\combined-dtb.dtb"
	#define SECONDARY_DTB_FILE      L"\\secondary-dtb.dtb"
# "-E" flag places binary data outside the FIT structure. However, since /incbin/ is used in the .its file, all binaries are appended into the same image. The FIT structure contains the offset and size for each appended binary.
# "-B 8" flag enforces 8‑byte alignment for the image since 8-byte alignment is normally recommended as per standards.
mkdir out
# For kernel main branch based FIT image creation
mkimage -f qcom-fitimage.its out/qclinux_fit.img -E -B 8
# For kernel qcom-next branch based FIT image creation
mkimage -f qcom-next-fitimage.its out/qclinux_fit.img -E -B 8

# Pack qclinux_fit.img into fitimage.bin. This fitimage.bin shall be flashed onto dtb_a partition of the board.
cd ..
git clone git@github.com:qualcomm-linux/kmake-image.git
cd kmake-image
sudo chmod +x generate_boot_bins.sh
./generate_boot_bins.sh bin --input ../fit_image/out/ --output ../fitimage.bin

# Steps to inspect the generated FIT image
cd ..
git clone https://github.com/PabloCastellano/extract-dtb.git
# Create the "/dtb" folder containing each of the dtb/dtbo
./extract-dtb/extract_dtb/extract_dtb.py fitimage.bin
# To verify the ITS DTB contents
fdtdump dtb/01_dtbdump_%i2\{.dtb
# To verify the metadata DTB contents
fdtdump dtb/02_dtbdump_Image_with_compressed_metadata_blob.dtb

# Flash the generated fitimage.bin into dtb_a partition
fastboot flash dtb_a fitimage.bin
```
---

### Document Version 1.0

### Author: Kaushal Kumar <kaushal.kumar@oss.qualcomm.com>
### Reviewer: Naina Mehta <naina.mehta@oss.qualcomm.com>
