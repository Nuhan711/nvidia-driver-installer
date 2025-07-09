#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
将.pot文件转换为Shell脚本中的语言包格式

此文件仅在更新.pot文件后运行一次，然后需要将生成的语言包的Shell脚本代码复制到主代码中
"""

import re
import sys
import argparse
from pathlib import Path


def parse_pot_file(pot_file_path):
    """
    解析.pot文件，提取msgid和msgstr对

    Args:
        pot_file_path: .pot文件路径

    Returns:
        list: 包含(msgid, msgstr)元组的列表
    """
    entries = []

    try:
        with open(pot_file_path, "r", encoding="utf-8") as file:
            content = file.read()
    except FileNotFoundError:
        print(f"错误: 找不到文件 {pot_file_path}")
        return []
    except Exception as e:
        print(f"错误: 读取文件时出错 - {e}")
        return []

    # 正则表达式匹配msgid和msgstr对
    # 支持多行字符串
    pattern = r'msgid\s+"([^"]*(?:\\.[^"]*)*)"\s*msgstr\s+"([^"]*(?:\\.[^"]*)*)"'
    matches = re.findall(pattern, content, re.MULTILINE | re.DOTALL)

    for msgid, msgstr in matches:
        # 处理转义字符
        msgid = msgid.replace('\\"', '"').replace("\\\\", "\\")
        msgstr = msgstr.replace('\\"', '"').replace("\\\\", "\\")

        # 跳过空的msgstr
        if msgstr.strip():
            entries.append((msgid, msgstr))

    return entries


def generate_shell_lang_pack(entries, pack_name="LANG_PACK_ZH_CN"):
    """
    生成Shell脚本格式的语言包

    Args:
        entries: (msgid, msgstr)元组列表
        pack_name: 语言包变量名

    Returns:
        str: 格式化的Shell语言包代码
    """
    if not entries:
        return f"# 没有找到有效的翻译条目\ndeclare -A {pack_name}\n{pack_name}=()\n"

    # 生成Shell数组声明
    output = f"declare -A {pack_name}\n\n"
    output += "# 初始化语言包\n"
    output += f"{pack_name}=(\n"

    for msgid, msgstr in entries:
        # 转义Shell中的特殊字符
        escaped_msgid = msgid.replace('"', '\\"')
        escaped_msgstr = msgstr.replace('"', '\\"')

        output += f'    ["{escaped_msgid}"]="{escaped_msgstr}"\n'

    output += ")\n"

    return output


def main():
    parser = argparse.ArgumentParser(description="将.pot文件转换为Shell脚本语言包格式")
    parser.add_argument("pot_file", help=".pot文件路径")
    parser.add_argument(
        "-n",
        "--name",
        default="LANG_PACK_ZH_CN",
        help="语言包变量名 (默认: LANG_PACK_ZH_CN)",
    )
    parser.add_argument("-o", "--output", help="输出文件路径 (默认: 输出到控制台)")

    args = parser.parse_args()

    # 检查输入文件是否存在
    pot_file = Path(args.pot_file)
    if not pot_file.exists():
        print(f"错误: 文件 {pot_file} 不存在")
        sys.exit(1)

    # 解析.pot文件
    print(f"正在解析文件: {pot_file}")
    entries = parse_pot_file(pot_file)

    if not entries:
        print("警告: 没有找到有效的翻译条目")
    else:
        print(f"找到 {len(entries)} 个翻译条目")

    # 生成Shell语言包
    shell_code = generate_shell_lang_pack(entries, args.name)

    # 输出结果
    if args.output:
        try:
            with open(args.output, "w", encoding="utf-8") as file:
                file.write(shell_code)
            print(f"输出已保存到: {args.output}")
        except Exception as e:
            print(f"错误: 保存文件时出错 - {e}")
            sys.exit(1)
    else:
        print("\n生成的Shell语言包代码:")
        print("-" * 50)
        print(shell_code)


if __name__ == "__main__":
    main()
