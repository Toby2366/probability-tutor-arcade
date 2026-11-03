#!/usr/bin/env python3
"""把内置小应用 Lua 源码转成 C 字节数组 + 头文件（含 size/md5）。

用法：
    python gen_builtin.py                      # 默认输出到 ../apps/arcs-mini/mcp-tools
    python gen_builtin.py --out <目录>          # 指定输出目录
    python gen_builtin.py --src <目录> --out <目录>

在 SDK 的 xiaogai-games 目录下运行时不需要任何参数。
每次修改 arcade.lua / dice.lua / coin.lua / galton.lua / hwtest.lua 后重跑一次。
"""
import argparse
import hashlib
import os

APPS = [
    ("dice", "dice", "1.0.0"),
    ("coin", "coin", "1.0.0"),
    ("galton", "galton", "1.0.0"),
    ("hwtest", "hwtest", "1.0.0"),
    ("arcade", "arcade", "1.0.0"),
]

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SRC = HERE
DEFAULT_OUT = os.path.abspath(os.path.join(HERE, "..", "apps", "arcs-mini", "mcp-tools"))


def gen(name, app_id, version, src_dir, out_dir):
    src_path = os.path.join(src_dir, name + ".lua")
    with open(src_path, "rb") as f:
        src = f.read()
    size = len(src)
    md5 = hashlib.md5(src).hexdigest()

    upper = name.upper()
    hdr = (
        "#ifndef MINIAPP_BUILTIN_%s_H\n"
        "#define MINIAPP_BUILTIN_%s_H\n\n"
        "#include <stddef.h>\n"
        "#include <stdint.h>\n\n"
        "#define MINIAPP_%s_ID      \"%s\"\n"
        "#define MINIAPP_%s_VERSION \"%s\"\n"
        "#define MINIAPP_%s_MD5     \"%s\"\n"
        "#define MINIAPP_%s_SIZE    %du\n\n"
        "extern const unsigned char miniapp_%s_lua[MINIAPP_%s_SIZE];\n\n"
        "#endif\n"
    ) % (upper, upper, upper, app_id, upper, version, upper, md5, upper, size,
         name, upper)

    lines = [
        '#include "miniapp_builtin_%s.h"' % name,
        "",
        "const unsigned char miniapp_%s_lua[MINIAPP_%s_SIZE] = {" % (name, upper),
    ]
    row = []
    for i, b in enumerate(src):
        row.append("0x%02X" % b)
        if len(row) == 16:
            lines.append("    " + ",".join(row) + ",")
            row = []
    if row:
        lines.append("    " + ",".join(row))
    lines.append("};")
    lines.append("")

    with open(os.path.join(out_dir, "miniapp_builtin_%s.h" % name), "w", newline="\n") as f:
        f.write(hdr)
    with open(os.path.join(out_dir, "miniapp_builtin_%s.c" % name), "w", newline="\n") as f:
        f.write("\n".join(lines))
    print("%-8s size=%-6d md5=%s" % (name, size, md5))


def main():
    ap = argparse.ArgumentParser(description="Lua 小应用 -> C 字节数组")
    ap.add_argument("--src", default=DEFAULT_SRC, help="Lua 源码目录（默认脚本所在目录）")
    ap.add_argument("--out", default=DEFAULT_OUT, help="输出目录（默认 ../apps/arcs-mini/mcp-tools）")
    args = ap.parse_args()

    src_dir = os.path.abspath(args.src)
    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)
    for name, app_id, version in APPS:
        gen(name, app_id, version, src_dir, out_dir)
    print("done ->", out_dir)


if __name__ == "__main__":
    main()
