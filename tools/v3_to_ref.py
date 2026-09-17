#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v3 书籍 JSON  ->  reference/最新版源码 的 WordCard 形状。

目标：让 books/ 下的数据能直接喂给 reference/最新版源码/src/flashcard/data.ts
的 DECK（WordCard[]），从而用上它那套专属渲染：
  · collocations  -> 「词组搭配」tab
  · derivatives   -> 「派生」tab
  · synonyms/antonyms -> 「近义」tab
  · root/rootSummary  -> 「词根」tab
  · exams         -> 真题浮层

用法：
  python3 tools/v3_to_ref.py /mnt/Flashcard/books/english_zhenti_shengciben [...]
  # 每个书目录里生成 ref_deck.json（不改原文件）
"""
import json
import os
import re
import sys
import glob

CN_SPLIT = re.compile(r"[；;，,、]\s*")


def split_cn(s):
    """'有缺陷的，有瑕疵的；站不住脚的' -> ['有缺陷的','有瑕疵的','站不住脚的']"""
    if s is None:
        return []
    if isinstance(s, list):
        out = []
        for x in s:
            out.extend(split_cn(x))
        return out
    return [p for p in CN_SPLIT.split(str(s).strip()) if p]


def strip_u(s):
    return re.sub(r"</?u\s*>", "", s or "")


def rel_to_flat(items):
    """[{word, senses:[{pos,cn}]}] -> [{word, pos, cn:[...]}]"""
    out = []
    for it in items or []:
        if isinstance(it, str):
            out.append({"word": it, "pos": "", "cn": []})
            continue
        w = str(it.get("word") or "")
        senses = it.get("senses") or it.get("meanings")
        if senses:
            for s in senses:
                if isinstance(s, str):
                    out.append({"word": w, "pos": "", "cn": split_cn(s)})
                else:
                    out.append({"word": w, "pos": str(s.get("pos") or ""),
                                "cn": split_cn(s.get("cn"))})
        else:
            out.append({"word": w, "pos": str(it.get("pos") or ""),
                        "cn": split_cn(it.get("cn"))})
    return out


def rel_to_words(items):
    """新源码 synonyms/antonyms 只要词 -> string[]"""
    return [x["word"] for x in rel_to_flat(items) if x.get("word")]


ROOT_SEG = re.compile(r"^(前缀|后缀|词根|词源|构词)\s*[:：=]?\s*(.+)$")


def parse_root(text):
    """自由文本尽量抠成 {tag,text}[]；抠不动整条塞一个。"""
    if not text:
        return []
    t = str(text).strip()
    items = []
    for seg in re.split(r"[;\n]+", t):
        seg = seg.strip()
        if not seg:
            continue
        m = ROOT_SEG.match(seg)
        if m:
            items.append({"tag": m.group(1), "text": m.group(2).strip()})
    return items or [{"tag": "词根", "text": t}]


def title_of(b):
    return str((b or {}).get("title") or "").strip()


def pair_en_cn(it):
    if not isinstance(it, dict):
        return {"en": str(it), "cn": ""}
    return {
        "en": str(it.get("en") or it.get("k") or it.get("left") or ""),
        "cn": str(it.get("cn") or it.get("v") or it.get("right") or ""),
    }


def convert_card(c, n):
    word = str(c.get("word") or "")
    senses = []
    for s in c.get("senses") or []:
        if isinstance(s, str):
            senses.append({"pos": "", "cn": split_cn(s)})
        else:
            senses.append({"pos": str(s.get("pos") or ""), "cn": split_cn(s.get("cn"))})

    collocations, root_items, root_summary, tags, keep_blocks = [], [], "", [], []
    for b in c.get("blocks") or []:
        bt = title_of(b)
        typ = str(b.get("type") or "").lower()
        if typ == "pairs" and ("搭配" in bt or "短语" in bt):
            collocations.extend(pair_en_cn(it) for it in (b.get("items") or []))
        elif "词根" in bt or "词源" in bt:
            raw = b.get("text") or b.get("html") or ""
            root_items = parse_root(raw)
            root_summary = str(raw).strip()
        elif any(k in bt for k in ("考频", "频次", "重要程度")):
            tags.append(str(b.get("text") or "").strip())
        else:
            keep_blocks.append(b)

    if c.get("exam_tag"):
        tags.append(str(c["exam_tag"]))

    return {
        "id": re.sub(r"\W+", "_", word.lower()).strip("_") or "c%d" % n,
        "word": word,
        "syllable": c.get("syllable") or "",
        "phonetic": (c.get("phonetic_us") or c.get("phonetic_uk") or "").strip(),
        "verified": bool(c.get("phonetic_us")),
        "senses": senses,
        "sentence": {"en": strip_u(c.get("sentence_en")), "cn": c.get("sentence_cn") or ""},
        "collocations": collocations,
        "derivatives": rel_to_flat(c.get("derivatives")),
        "synonyms": rel_to_words(c.get("synonyms")),
        "antonyms": rel_to_words(c.get("antonyms")),
        "root": root_items,
        "rootSummary": root_summary,
        "exams": [],
        "blocks": keep_blocks,
        "tags": tags,
    }


def convert_book(book_dir):
    idx_path = os.path.join(book_dir, "index.json")
    idx = json.load(open(idx_path, encoding="utf-8")) if os.path.exists(idx_path) else {}
    cards = []
    for f in sorted(glob.glob(os.path.join(book_dir, "ch_*.json"))):
        d = json.load(open(f, encoding="utf-8"))
        for c in d.get("cards") or []:
            cards.append(convert_card(c, len(cards)))
    out = {
        "format": "flashcard.deck.ref",
        "note": "面向 reference/最新版源码 WordCard[]；blocks/tags 是扩展字段",
        "book_id": idx.get("book_id") or os.path.basename(book_dir),
        "title": idx.get("title") or "",
        "cards": cards,
    }
    dst = os.path.join(book_dir, "ref_deck.json")
    json.dump(out, open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    return dst, len(cards)


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    for book_dir in argv:
        dst, n = convert_book(book_dir)
        print("%s  ->  %d cards" % (dst, n))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
