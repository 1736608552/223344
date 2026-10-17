#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import json
import sys
import os

def main():
    tag = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('TAG', '')
    if not tag:
        tag = 'v2.6.94'
    
    notes = ''
    changelogs_path = '.github/changelogs.json'
    if os.path.exists(changelogs_path):
        try:
            with open(changelogs_path, 'r', encoding='utf-8') as f:
                data = json.load(f)
                notes = data.get(tag, '')
                if not notes:
                    clean_tag = tag[1:] if tag.startswith('v') else tag
                    notes = data.get('v' + clean_tag, '') or data.get(clean_tag, '')
        except Exception as e:
            print(f'Error reading {changelogs_path}: {e}', file=sys.stderr)
            
    if not notes:
        # 尝试从 FIXLOG.md 读取
        fixlog_path = 'FIXLOG.md'
        if os.path.exists(fixlog_path):
            try:
                with open(fixlog_path, 'r', encoding='utf-8') as f:
                    content = f.read()
                    target_header = f'## {tag}'
                    if target_header in content:
                        parts = content.split(target_header)
                        if len(parts) > 1:
                            section = parts[1].split('\n---')[0]
                            notes = target_header + section
            except Exception as e:
                print(f'Error reading {fixlog_path}: {e}', file=sys.stderr)

    if not notes:
        notes = f'## LunaTV Mobile {tag} 正式版发布\n\n- 智能跳过片头片尾、弹幕满帧渲染与短剧历史全链路优化。'

    footer = f'''\n\n### 安装包下载\n- **Android 手机/平板端**：\n  - LunaTV-Mobile-{tag}.apk：正式版完整安装包（推荐 Android 用户安装）\n  - app-release.apk：直链通用版\n- **Android TV 电视与盒子端**：\n  - LunaTV-TV-{tag}-arm64-v8a.apk：**主流 64 位高性能 TV 专属包**（推荐近几年主流 64 位 Android TV、小米/索尼/TCL/当贝及高性能外贸电视盒子安装，解码渲染性能最佳）\n  - LunaTV-TV-{tag}-armeabi-v7a.apk：**通用 32 位老旧 TV 专属包**（广泛兼容绝大多数老款智能电视、普及型电视盒子及运行在 32 位底层模式的电视设备）\n  - LunaTV-TV-{tag}-hisense.apk：**海信电视（Hisense / VIDAA）专用包**（针对海信聚好看等系统的第三方安装校验策略，采用专属独立包名与 32 位底层架构深度适配，彻底解决海信电视安装提示“安装包损坏/有风险”或解析失败的问题）\n- **iOS 苹果端**：\n  - LunaTV-Mobile-{tag}-unsigned.ipa：苹果免签名安装包（支持 TrollStore 巨魔直装、AltStore / SideStore 个人自签、爱思助手/牛蛙助手电脑签名安装）\n  - app-release-unsigned.ipa：直链免签名版\n- **Windows PC 桌面端**：\n  - LunaTV-PC-{tag}-windows-x64.zip：Windows 64位绿色免安装包（解压后运行 LunaTV.exe 即可播放）\n  - LunaTV-PC-windows-x64.zip：直链通用版\n- **校验文件**：\n  - SHA256SUMS.txt：各平台安装包 SHA-256 完整性校验值\n'''

    output_path = 'release_notes.md'
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(notes.strip() + footer)
    print(f'Generated {output_path} successfully for {tag} ({len(notes)} chars)')

if __name__ == '__main__':
    main()
