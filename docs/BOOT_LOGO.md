# Boot logo

The build pipeline now treats the custom 480x272 logo as part of boot assembly.

Flow:

1. [Media/boot-logo-artillery.bmp](../Media/boot-logo-artillery.bmp) is the source bitmap.
2. `tools/build-armbian-bootimg.sh` packs `resource.img` from the factory template.
3. `tools/patch-resource-logos.py` patches both `logo.bmp` and `logo_kernel.bmp` slots.

If the logo file is missing, the assembler keeps the template logo and prints a warning.
