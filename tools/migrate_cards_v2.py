#!/usr/bin/env python3
"""把书目录从 schema 1（卡片内联在各章）迁到 schema 2（全书卡池 + 章内 id 索引）。

    books/<book_id>/cards.jsonl   一行一张卡，id 唯一  ← 唯一真源
    books/<book_id>/ch_0001.json  {"title": ..., "passage": ..., "cards": ["id", ...]}
    books/<book_id>/index.json    schema: 2, card_count: N

为什么要迁：schema 1 里卡片挂在章下面，同一个词想出现在两章就得复制两份，
于是「要么不许重复收录，要么同一张卡背两遍 / 两份内容各改各的」。schema 2
下卡片只存一份，章只引用 id，调度状态按 id 唯一 —— 一卡一位，多处出现。

用法：
    python3 tools/migrate_cards_v2.py <书目录> [--dry-run] [--no-backup]
    python3 tools/migrate_cards_v2.py <books 根目录> --all

⚠️ 先装新版 APK 再迁数据：老 APK 读到 schema 2 的章文件（cards 是字符串数组）
会整章读空。脚本默认先整目录备份成 <书目录>.v1bak-<时间戳>。
"""
import argparse
import json
import os
import shutil
import sys
import time

CH_PREFIX = "ch_"


def chapter_files(d):
    out = []
    for n in sorted(os.listdir(d)):
        if not n.startswith(CH_PREFIX) or not n.endswith(".json"):
            continue
        stem = n[len(CH_PREFIX):-len(".json")]
        if not stem.isdigit():      # ch_0001.json.bak / .pre_xxx 一律跳过
            continue
        out.append(n)
    return out


def migrate(book_dir, dry_run=False, backup=True):
    chs = chapter_files(book_dir)
    if not chs:
        print(f"  跳过 {book_dir}（没有 ch_*.json）")
        return None

    pool, order = {}, []
    conflicts, no_id, dangling = [], [], []
    chapters = {}

    for name in chs:
        path = os.path.join(book_dir, name)
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        ids = []
        for e in data.get("cards") or []:
            if isinstance(e, str):
                ids.append(e)                      # 已经是引用
                continue
            if not isinstance(e, dict):
                continue
            cid = e.get("id") or e.get("word")
            if not e.get("id"):
                no_id.append((name, e.get("word")))
                e["id"] = cid          # 缺 id 的卡补上，卡池靠它当主键
            if not cid:
                continue
            if cid in pool:
                if pool[cid] != e:
                    conflicts.append((cid, name))
            else:
                pool[cid] = e
                order.append(cid)
            ids.append(cid)
        chapters[name] = (data, ids)

    # 章里引用了卡池里没有的 id（理论上不会有，兜底报出来）
    for name, (_, ids) in chapters.items():
        for i in ids:
            if i not in pool:
                dangling.append((name, i))

    print(f"  {os.path.basename(book_dir)}: {len(chs)} 章 / {len(pool)} 张卡")
    if conflicts:
        print(f"  ⚠️ 同 id 内容不一致 {len(conflicts)} 处（保留先出现的）：{conflicts[:5]}")
    if no_id:
        print(f"  ⚠️ 缺 id，已用 word 补 {len(no_id)} 张：{no_id[:5]}")
    if dangling:
        print(f"  ⚠️ 悬空引用 {len(dangling)} 处：{dangling[:5]}")

    if dry_run:
        print("  --dry-run，不写盘")
        return dict(chapters=len(chs), cards=len(pool), conflicts=len(conflicts))

    if backup:
        bak = f"{book_dir.rstrip('/')}.v1bak-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copytree(book_dir, bak)
        print(f"  备份 → {bak}")

    with open(os.path.join(book_dir, "cards.jsonl"), "w", encoding="utf-8") as f:
        for cid in order:
            f.write(json.dumps(pool[cid], ensure_ascii=False, separators=(",", ":")))
            f.write("\n")

    for name, (data, ids) in chapters.items():
        data["cards"] = ids
        with open(os.path.join(book_dir, name), "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")

    idx_path = os.path.join(book_dir, "index.json")
    if os.path.exists(idx_path):
        with open(idx_path, encoding="utf-8") as f:
            idx = json.load(f)
    else:
        idx = {"book_id": os.path.basename(book_dir), "template": "bubei_react_v1"}
    idx["schema"] = 2
    idx["card_count"] = len(pool)
    with open(idx_path, "w", encoding="utf-8") as f:
        json.dump(idx, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print("  完成 → cards.jsonl + 章内 id 索引 + index.json schema=2")
    return dict(chapters=len(chs), cards=len(pool), conflicts=len(conflicts))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--all", action="store_true", help="path 是 books 根目录，逐个书目录迁")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-backup", action="store_true")
    a = ap.parse_args()

    targets = []
    if a.all:
        for n in sorted(os.listdir(a.path)):
            p = os.path.join(a.path, n)
            if os.path.isdir(p) and chapter_files(p):
                targets.append(p)
    else:
        targets = [a.path]

    if not targets:
        print("没找到可迁移的书目录")
        return 1

    for t in targets:
        migrate(t, dry_run=a.dry_run, backup=not a.no_backup)
    return 0


if __name__ == "__main__":
    sys.exit(main())
