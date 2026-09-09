#!/usr/bin/env python3
"""Set /chosen/bootargs on a DTB (Rockchip U-Boot uses this, not boot.img cmdline)."""
from __future__ import annotations

import argparse
import shutil
import struct
import subprocess
import sys
from pathlib import Path


def patch_with_fdtput(
    dtb: Path,
    bootargs: str,
    out: Path,
    stdout_path: str = "",
) -> None:
    fdtput = shutil.which("fdtput")
    if not fdtput:
        raise FileNotFoundError("fdtput not found (install device-tree-compiler)")

    tmp = out
    if out.resolve() != dtb.resolve():
        tmp.write_bytes(dtb.read_bytes())

    subprocess.check_call(
        [fdtput, "-t", "s", str(tmp), "/chosen", "bootargs", bootargs],
    )
    if stdout_path:
        subprocess.check_call(
            [fdtput, "-t", "s", str(tmp), "/chosen", "stdout-path", stdout_path],
        )


def compile_dts_source(dts: Path, out: Path, kernel_root: Path | None = None) -> None:
    """Compile a DTS source to a compact DTB so the final blob stays under the Rockchip resource slot."""
    cpp = shutil.which("cpp")
    dtc = shutil.which("dtc")
    if not cpp or not dtc:
        raise FileNotFoundError("cpp/dtc not found (install device-tree-compiler)")

    if kernel_root is None:
        candidates = [
            Path("/home/YOUR_USERNAME/scratch/Projects/rk3308bs-workspace/M1-SOC-Armbian-Build/cache/sources/linux-kernel-worktree"),
            Path("/home/YOUR_USERNAME/scratch/Projects/rk3308bs-workspace/M1-SOC-Armbian-Build/cache/sources/linux-kernel-worktree"),
        ]
        found = None
        for cand in candidates:
            if cand.exists():
                for child in sorted(cand.iterdir()):
                    if (child / "arch/arm64/boot/dts/rockchip/rk3308.dtsi").exists():
                        found = child
                        break
                if found is not None:
                    break
        if found is None:
            raise FileNotFoundError(
                "Could not locate linux-kernel-worktree with arch/arm64/boot/dts/rockchip/rk3308.dtsi; "
                "pass --kernel-root or compile from a binary DTB."
            )
        kernel_root = found

    pre = out.with_suffix(".pre.dts")
    try:
        with pre.open("wb") as pre_fh:
            subprocess.check_call(
                [
                    cpp,
                    "-nostdinc",
                    "-undef",
                    "-D__DTS__",
                    "-x",
                    "assembler-with-cpp",
                    "-I",
                    str(kernel_root / "arch/arm64/boot/dts"),
                    "-I",
                    str(kernel_root / "arch/arm64/boot/dts/rockchip"),
                    "-I",
                    str(kernel_root / "include"),
                    str(dts),
                ],
                stdout=pre_fh,
            )
        subprocess.check_call(
            [
                dtc,
                "-I",
                "dts",
                "-O",
                "dtb",
                "-o",
                str(out),
                "-i",
                str(kernel_root / "arch/arm64/boot/dts"),
                "-i",
                str(kernel_root / "arch/arm64/boot/dts/rockchip"),
                "-i",
                str(kernel_root / "include"),
                str(pre),
            ],
        )
    finally:
        if pre.exists():
            pre.unlink()


def extract_factory_dtb(resource: Path) -> bytes:
    data = resource.read_bytes()
    old_size, off = _find_fdt_slot(data)
    return data[off : off + struct.unpack(">I", data[off + 4 : off + 8])[0]]


def _remove_dts_subnode(text: str, name: str) -> str:
    """Remove a child node block like 'display-timings { ... };' from DTS source."""
    needle = f"{name} {{"
    start = text.find(needle)
    if start < 0:
        return text
    line_start = text.rfind("\n", 0, start) + 1
    depth = 0
    i = text.find("{", start)
    while i < len(text):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                while end < len(text) and text[end] in " \t":
                    end += 1
                if end < len(text) and text[end] == ";":
                    end += 1
                if end < len(text) and text[end] == "\n":
                    end += 1
                return text[:line_start] + text[end:]
        i += 1
    return text


def patch_rk3308_panel_dpi(dtb: Path) -> None:
    """Use upstream panel-dpi + panel-timing instead of legacy simple-panel binding."""
    dtc = shutil.which("dtc")
    if not dtc:
        raise FileNotFoundError("dtc not found (install device-tree-compiler)")

    dts = dtb.with_suffix(".panel.dts")
    subprocess.check_call([dtc, "-I", "dtb", "-O", "dts", "-o", str(dts), str(dtb)], stderr=subprocess.DEVNULL)
    text = dts.read_text()
    if 'compatible = "simple-panel"' in text:
        text = text.replace('compatible = "simple-panel"', 'compatible = "panel-dpi"', 1)
    text = _remove_dts_subnode(text, "display-timings")
    timing_block = (
        "\t\tpanel-timing {\n"
        "\t\t\tclock-frequency = <0x895440>;\n"
        "\t\t\thactive = <0x1e0>;\n"
        "\t\t\tvactive = <0x110>;\n"
        "\t\t\thback-porch = <0x2b>;\n"
        "\t\t\thfront-porch = <0x08>;\n"
        "\t\t\tvback-porch = <0x0c>;\n"
        "\t\t\tvfront-porch = <0x08>;\n"
        "\t\t\thsync-len = <0x04>;\n"
        "\t\t\tvsync-len = <0x04>;\n"
        "\t\t\thsync-active = <0x01>;\n"
        "\t\t\tvsync-active = <0x01>;\n"
        "\t\t\tde-active = <0x00>;\n"
        "\t\t\tpixelclk-active = <0x01>;\n"
        "\t\t};\n"
    )
    if "panel-timing {" not in text:
        panel_idx = text.find("panel {")
        if panel_idx < 0:
            raise RuntimeError("panel node not found in decompiled DTS")
        port_idx = text.find("port {", panel_idx)
        if port_idx < 0:
            raise RuntimeError("panel port node not found in decompiled DTS")
        line_start = text.rfind("\n", panel_idx, port_idx) + 1
        text = text[:line_start] + timing_block + text[line_start:]
    dts.write_text(text)
    subprocess.check_call(
        [dtc, "-I", "dts", "-O", "dtb", "-o", str(dtb), str(dts), "-Wno-unit_address_vs_reg"],
    )
    dts.unlink(missing_ok=True)
    print(
        "  panel compatible=panel-dpi panel-timing=480x272@9MHz "
        "(removed display-timings; bus-format unchanged on /panel)"
    )


def patch_goodix_factory_defaults(dtb: Path) -> None:
    fdtget = shutil.which("fdtget")
    fdtput = shutil.which("fdtput")
    if not fdtget or not fdtput:
        raise FileNotFoundError("fdtget/fdtput not found")

    candidates = [
        "/i2c@ff070000/goodix_ts@5d",
        "/i2c@ff070000/touchscreen@5d",
    ]
    node = None
    for cand in candidates:
        rc = subprocess.call(
            [fdtget, str(dtb), cand, "compatible"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if rc == 0:
            node = cand
            break

    if node is None:
        print("  goodix node not found, skipping factory defaults")
        return

    subprocess.check_call([fdtput, "-t", "i", str(dtb), node, "touchscreen-size-x", "800"])
    subprocess.check_call([fdtput, "-t", "i", str(dtb), node, "touchscreen-size-y", "480"])

    for prop, value in (("max-x", "800"), ("max-y", "480")):
        rc = subprocess.call(
            [fdtget, str(dtb), node, prop],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if rc == 0:
            subprocess.check_call([fdtput, "-t", "i", str(dtb), node, prop, value])

    print("  goodix: size=800x480 (factory GPIO flags preserved)")


def _find_goodix_node(dtb: Path) -> str | None:
    fdtget = shutil.which("fdtget")
    if not fdtget:
        raise FileNotFoundError("fdtget not found")
    for cand in ("/i2c@ff070000/goodix_ts@5d", "/i2c@ff070000/touchscreen@5d"):
        rc = subprocess.call(
            [fdtget, str(dtb), cand, "compatible"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if rc == 0:
            return cand
    return None


def patch_goodix_calibration(dtb: Path, min_x: int, size_x: int,
                             min_y: int, size_y: int) -> None:
    """Declare the physically-reachable GT911 coordinate window via the kernel
    touchscreen core's device-tree calibration properties.

    The GT911 digitizer glass is larger than the 480x272 panel, so with the
    stock 480x272 config only part of the reported coordinate range lands on
    the visible panel (measured: X 0..438, Y 34..179). Rather than rescaling
    the chip config (which cannot apply a Y offset without a driver hack), we
    tell the input core the real min/size on each axis. libinput then maps
    [min .. min+size-1] linearly onto the full screen, giving edge-to-edge
    touch with correct offset. See drivers/input/touchscreen.c
    touchscreen_parse_properties() -- it sets ABS min=touchscreen-min-* and
    max=touchscreen-size-*-1, which libinput uses to normalize coordinates.
    """
    fdtput = shutil.which("fdtput")
    if not fdtput:
        raise FileNotFoundError("fdtput not found")
    node = _find_goodix_node(dtb)
    if node is None:
        print("  goodix node not found, skipping calibration")
        return
    for prop, value in (
        ("touchscreen-min-x", min_x),
        ("touchscreen-size-x", size_x),
        ("touchscreen-min-y", min_y),
        ("touchscreen-size-y", size_y),
    ):
        subprocess.check_call([fdtput, "-t", "i", str(dtb), node, prop, str(value)])
    print(f"  goodix: calibration min-x={min_x} size-x={size_x} "
          f"min-y={min_y} size-y={size_y} (reachable window -> full screen)")


def _find_fdt_slot(data: bytes) -> tuple[int, int]:
    magic = b"\xd0\x0d\xfe\xed"
    candidates: list[tuple[int, int]] = []
    offset = 0
    while True:
        idx = data.find(magic, offset)
        if idx < 0:
            break
        if idx + 8 <= len(data):
            totalsize = struct.unpack(">I", data[idx + 4 : idx + 8])[0]
            if 64 <= totalsize <= len(data) - idx:
                candidates.append((totalsize, idx))
        offset = idx + 4
    if not candidates:
        raise SystemExit("No FDT magic found")
    totalsize, off = max(candidates, key=lambda x: x[0])
    slot_end = off + totalsize
    while slot_end < len(data) and data[slot_end] == 0 and (slot_end - off) <= 65536:
        slot_end += 1
    return slot_end - off, off


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dtb", type=Path, help="Input DTB (not needed with --from-factory-resource or --dts)")
    ap.add_argument("--dts", type=Path, help="Optional source .dts to compile first so the DTB stays compact enough for the resource slot")
    ap.add_argument("--kernel-root", type=Path, help="Optional linux-kernel-worktree root used to resolve include files when compiling --dts")
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument(
        "--console",
        default="",
        help="console= value (default: ttyFIQ0 with --from-factory-resource, else ttyS3,1500000n8)",
    )
    ap.add_argument(
        "--root-uuid",
        default="614e0000-0000-4b53-8000-1d28000054a9",
        help="rootfs GPT PARTUUID from parameter.txt uuid:rootfs=",
    )
    ap.add_argument("--bootargs", default="", help="Full bootargs override")
    ap.add_argument(
        "--extra-bootargs",
        default="",
        help="Extra tokens appended to the generated (or overridden) bootargs, "
        "e.g. debug flags like 'drm.debug=0x1f ignore_loglevel'",
    )
    ap.add_argument(
        "--stdout-path",
        default=None,
        help="/chosen/stdout-path (default: skip for factory DTB, else serial3:1500000n8)",
    )
    ap.add_argument(
        "--from-factory-resource",
        type=Path,
        help="Extract rk-kernel.dtb from factory resource.img instead of --dtb",
    )
    ap.add_argument(
        "--armbian-serial",
        action="store_true",
        help="Legacy: disable fiq-debugger and use ttyS3 (do not use on RK3308BS  -  console is ttyFIQ0)",
    )
    ap.add_argument(
        "--disable-thermal-critical",
        action="store_true",
        help="Downgrade soc-crit trip to passive at 120C",
    )
    ap.add_argument(
        "--rk3308bs-tsadc",
        action="store_true",
        help="Set tsadc compatible to rockchip,rk3308bs-tsadc (needs kernel patch 0002)",
    )
    ap.add_argument(
        "--disable-tsadc",
        action="store_true",
        help="Disable tsadc node in DTB as an emergency workaround for early thermal resets",
    )
    ap.add_argument(
        "--rk3308-vop-resets",
        action="store_true",
        help="Add CRU resets (axi/ahb/dclk) to vop@ff2e0000 (rockchipdrm bind needs ahb reset)",
    )
    ap.add_argument(
        "--rk3308-panel-dpi",
        action="store_true",
        help="Panel: panel-dpi + panel-timing (480x272@9MHz) for Linux 6.18 DRM",
    )
    ap.add_argument(
        "--goodix-factory-defaults",
        action="store_true",
        help="Force Goodix IRQ active-low and touchscreen size to 800x480",
    )
    ap.add_argument(
        "--goodix-calibration",
        metavar="MINX,SIZEX,MINY,SIZEY",
        default="",
        help="Declare reachable GT911 window via touchscreen-min/size props so "
             "libinput stretches it to full screen (e.g. 0,439,34,181)",
    )
    args = ap.parse_args()

    src = args.dtb
    if args.dts:
        src = args.output.with_suffix(".compiled.dtb")
        compile_dts_source(args.dts, src, kernel_root=args.kernel_root)
        print(f"Compiled DTS ({args.dts}) -> DTB ({len(src.read_bytes())} bytes)")
    if args.from_factory_resource:
        blob = extract_factory_dtb(args.from_factory_resource)
        src = args.output.with_suffix(".extracted.dtb")
        src.write_bytes(blob)
        print(f"Extracted factory DTB ({len(blob)} bytes) from {args.from_factory_resource}")
    elif not src:
        ap.error("Provide --dtb, --dts, or --from-factory-resource")

    console = args.console
    if not console:
        if args.armbian_serial or not args.from_factory_resource:
            console = "ttyS3,1500000n8"
        else:
            console = "ttyFIQ0"

    stdout_path = args.stdout_path
    if stdout_path is None:
        stdout_path = "serial3:1500000n8" if args.armbian_serial or not args.from_factory_resource else ""

    if args.bootargs:
        bootargs = args.bootargs
    else:
        bootargs = (
            f"earlycon=uart8250,mmio32,0xff0d0000 console={console} "
            f"root=PARTUUID={args.root_uuid} rootfstype=ext4 rw rootwait"
        )

    if args.extra_bootargs.strip():
        bootargs = f"{bootargs} {args.extra_bootargs.strip()}"

    try:
        patch_with_fdtput(
            src,
            bootargs,
            args.output,
            stdout_path=stdout_path,
        )
        if args.armbian_serial:
            fdtput = shutil.which("fdtput")
            if not fdtput:
                raise FileNotFoundError("fdtput not found")
            subprocess.check_call(
                [fdtput, "-t", "s", str(args.output), "/fiq-debugger", "status", "disabled"],
            )
            subprocess.check_call(
                [fdtput, "-t", "s", str(args.output), "/serial@ff0d0000", "status", "okay"],
            )
            print("  fiq-debugger=disabled serial@ff0d0000=okay (Armbian ttyS3 console)")
        if args.disable_thermal_critical:
            fdtput = shutil.which("fdtput")
            if not fdtput:
                raise FileNotFoundError("fdtput not found")
            crit = "/thermal-zones/soc-thermal/trips/soc-crit"
            subprocess.check_call(
                [fdtput, "-t", "s", str(args.output), crit, "type", "passive"],
            )
            subprocess.check_call(
                [fdtput, "-t", "i", str(args.output), crit, "temperature", "120000"],
            )
            print("  soc-crit=passive @ 120C")
        if args.rk3308bs_tsadc:
            fdtput = shutil.which("fdtput")
            if not fdtput:
                raise FileNotFoundError("fdtput not found")
            subprocess.check_call(
                [
                    fdtput,
                    "-t",
                    "s",
                    str(args.output),
                    "/tsadc@ff1f0000",
                    "compatible",
                    "rockchip,rk3308bs-tsadc",
                ],
            )
            print("  tsadc@ff1f0000 compatible=rockchip,rk3308bs-tsadc")
        if args.disable_tsadc:
            fdtput = shutil.which("fdtput")
            if not fdtput:
                raise FileNotFoundError("fdtput not found")
            subprocess.check_call(
                [fdtput, "-t", "s", str(args.output), "/tsadc@ff1f0000", "status", "disabled"],
            )
            print("  tsadc@ff1f0000 status=disabled")
        if args.rk3308_vop_resets:
            fdtput = shutil.which("fdtput")
            if not fdtput:
                raise FileNotFoundError("fdtput not found")
            # SRST_VOP_A/H/D = 38/39/40; cru phandle = 2 in factory DTB
            subprocess.check_call(
                [
                    fdtput,
                    "-t",
                    "i",
                    str(args.output),
                    "/vop@ff2e0000",
                    "resets",
                    "2",
                    "38",
                    "2",
                    "39",
                    "2",
                    "40",
                ],
            )
            subprocess.check_call(
                [
                    fdtput,
                    "-t",
                    "s",
                    str(args.output),
                    "/vop@ff2e0000",
                    "reset-names",
                    "axi",
                    "ahb",
                    "dclk",
                ],
            )
            print("  vop@ff2e0000 resets=SRST_VOP_A/H/D reset-names=axi,ahb,dclk")
        if args.rk3308_panel_dpi:
            patch_rk3308_panel_dpi(args.output)
        if args.goodix_factory_defaults:
            patch_goodix_factory_defaults(args.output)
        if args.goodix_calibration.strip():
            parts = [p.strip() for p in args.goodix_calibration.split(",")]
            if len(parts) != 4:
                print("--goodix-calibration needs MINX,SIZEX,MINY,SIZEY", file=sys.stderr)
                return 1
            cx0, cxs, cy0, cys = (int(p) for p in parts)
            patch_goodix_calibration(args.output, cx0, cxs, cy0, cys)
    except FileNotFoundError as exc:
        print(exc, file=sys.stderr)
        return 1

    print(f"Wrote {args.output}")
    print(f"  bootargs={bootargs!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
