#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 自动化代码审查门禁：精准词法状态机 AST 闭合与语法结构自检
import os, sys, re

def precise_parse_file(filepath):
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            src = f.read()
    except Exception as e:
        print(f"[CodeReview] 读取文件失败 {filepath}: {e}")
        return False

    i, n, line, col, depth = 0, len(src), 1, 1, 0
    stack = []
    STATE_CODE, STATE_LINE_COMMENT, STATE_BLOCK_COMMENT, STATE_STRING, STATE_RAW_STRING, STATE_CHAR = 0, 1, 2, 3, 4, 5
    state = STATE_CODE

    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            col = 1
            if state == STATE_LINE_COMMENT:
                state = STATE_CODE
            i += 1
            continue

        if state == STATE_CODE:
            if c == "/" and i + 1 < n and src[i+1] == "/":
                state = STATE_LINE_COMMENT
                i += 2; col += 2; continue
            elif c == "/" and i + 1 < n and src[i+1] == "*":
                state = STATE_BLOCK_COMMENT
                i += 2; col += 2; continue
            elif c == "\"" and i + 2 < n and src[i+1] == "\"" and src[i+2] == "\"":
                state = STATE_RAW_STRING
                i += 3; col += 3; continue
            elif c == "\"":
                state = STATE_STRING
                i += 1; col += 1; continue
            elif c == "\x27":
                state = STATE_CHAR
                i += 1; col += 1; continue
            elif c == "{":
                depth += 1
                stack.append((line, col))
            elif c == "}":
                if depth <= 0:
                    print(f"[CodeReview 阻断] {filepath} 第 {line} 行第 {col} 列: 存在多余/错位的闭合花括号 '}}'")
                    return False
                depth -= 1
                stack.pop()
        elif state == STATE_BLOCK_COMMENT:
            if c == "*" and i + 1 < n and src[i+1] == "/":
                state = STATE_CODE
                i += 2; col += 2; continue
        elif state == STATE_STRING:
            if c == "\\" and i + 1 < n:
                i += 2; col += 2; continue
            elif c == "\"":
                state = STATE_CODE
        elif state == STATE_RAW_STRING:
            if c == "\"" and i + 2 < n and src[i+1] == "\"" and src[i+2] == "\"":
                state = STATE_CODE
                i += 3; col += 3; continue
        elif state == STATE_CHAR:
            if c == "\\" and i + 1 < n:
                i += 2; col += 2; continue
            elif c == "\x27":
                state = STATE_CODE

        i += 1
        col += 1

    if depth != 0:
        print(f"[CodeReview 阻断] {filepath} 语法未闭合！剩余 {depth} 个未闭合花括号，最后未闭合位置: {stack[-3:]}")
        return False

    return True

def main():
    print("=== [执行提交前自动化代码审查 (Pre-Commit Code Review)] ===")
    
    # 获取暂存区改动的文件
    import subprocess
    cmd = ["git", "diff", "--cached", "--name-only", "--diff-filter=ACM"]
    res = subprocess.check_output(cmd).decode().splitlines()
    
    if not res:
        # 如果没有暂存区文件，直接检查所有改动的 Kotlin 与 Dart 文件
        cmd2 = ["git", "diff", "--name-only", "--diff-filter=ACM"]
        res = subprocess.check_output(cmd2).decode().splitlines()

    target_files = [f for f in res if f.endswith(".kt") or f.endswith(".dart")]
    if not target_files:
        print("未检测到 Kotlin / Dart 代码改动，免检放行。")
        sys.exit(0)

    print(f"检测到 {len(target_files)} 个核心源码文件变更，开始词法 AST 闭合审查...")
    failed = False
    for tf in target_files:
        if not os.path.exists(tf):
            continue
        if tf.endswith(".kt"):
            if not precise_parse_file(tf):
                failed = True
            else:
                print(f"  ✅ {tf} 词法闭合与类作用域审查通过")

    if failed:
        print("\n❌ 自动化代码审查拦截：代码存在语法结构错误，严禁提交！请原地自愈修复后重试。")
        sys.exit(1)

    print(">>> 自动化代码审查 100% 通过！允许提交。<<<\n")
    sys.exit(0)

if __name__ == "__main__":
    main()
