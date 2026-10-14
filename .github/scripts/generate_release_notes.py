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

    footer = f'''\n\n### 安装包下载\n- **Android 端**：\n  - LunaTV-Mobile-{tag}.apk：正式版完整安装包（推荐 Android 用户安装）\n  - app-release.apk：直链通用版\n- **iOS 苹果端**：\n  - LunaTV-Mobile-{tag}-unsigned.ipa：苹果免签名安装包（支持 TrollStore 巨魔直装、AltStore / SideStore 个人自签、爱思助手/牛蛙助手电脑签名安装）\n  - app-release-unsigned.ipa：直链免签名版\n- **校验文件**：\n  - SHA256SUMS.txt：各平台安装包 SHA-256 完整性校验值\n'''

    output_path = 'release_notes.md'
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(notes.strip() + footer)
    print(f'Generated {output_path} successfully for {tag} ({len(notes)} chars)')

if __name__ == '__main__':
    main()
