"""
flashcard 调度内核 · FSRS-lite (三档评分版)
================================================
原生壳只需要把「记得 / 模糊 / 忘记」三个状态丢进来，
这里负责算出下一次到期时间。

评分映射 (对齐 FSRS 的 1/2/3/4 中取三档):
    忘记 (again) -> 1
    模糊 (hard)  -> 2  (介于 Again 和 Good 之间，简化处理)
    记得 (good)  -> 3

状态字段 (每张卡片一份):
    stability  (S) 天  —— 记忆稳定性
    difficulty (D) 1~10 —— 记忆难度
    reps             —— 复习次数
    lapses           —— 遗忘次数
    due              —— 下次到期 (ISO 日期)
    last_review      —— 上次复习 (ISO 日期)
    state            —— new / learning / review / relearning
"""

from __future__ import annotations
import math
from dataclasses import dataclass, field, asdict
from datetime import date, timedelta


# ---- FSRS 默认权重 (FSRS-4.5 公开权重前若干项，够用) ----
W = [0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2290, 0.8975,
     0.0310, 1.6474, 0.1367, 1.0461, 2.1072, 0.0793, 0.3246,
     1.5870, 0.2272, 2.8755]

RATING_AGAIN = 1
RATING_HARD = 2
RATING_GOOD = 3

RATING_NAME = {1: "again", 2: "hard", 3: "good"}
NAME_RATING = {"again": 1, "hard": 2, "good": 3, "忘记": 1, "模糊": 2, "记得": 3}

REQUEST_RETENTION = 0.90   # 目标保留率 90%
MAX_INTERVAL = 365         # 最大间隔封顶（天）。没有这根保险丝，
                           # 连续答对的稳定性会把到期日推到几十年后。
LEARNING_INTERVAL = 1      # 学习/重学阶段间隔（天）：今天刚学或忘掉的卡，
                           # 明天必须复习。这是硬规则，不交给 FSRS 拍脑袋。

# 遗忘惩罚强度：忘记后稳定性最多保留原值的 1/e^1.5 ≈ 22.3%。
# 手调参数（不是 FSRS 论文值）：原代码写死的 2.0 太狠（只剩 13.5%），
# 1.5 明显下调但不至于一次忘记打回原形。
# **改这里必须同时改 Dart 端 app/lib/services/scheduler.dart 的
# kForgetRetainExp**，两端必须一致，否则拟合出来的参数在真机上不成立。
FORGET_RETAIN_EXP = 1.5


def _clamp(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))


def forgetting_curve(elapsed_days: float, stability: float) -> float:
    """可提取概率 R(t, S) = (1 + FACTOR * t / S) ^ DECAY"""
    if stability <= 0:
        return 0.0
    decay = -0.5
    factor = 0.9 ** (1 / decay) - 1  # ≈ 0.2345
    return (1 + factor * elapsed_days / stability) ** decay


def next_interval(stability: float, retention: float = REQUEST_RETENTION,
                  max_ivl: int = MAX_INTERVAL) -> int:
    """反解 forgetting_curve，得到给定保留率下的间隔天数（封顶）"""
    decay = -0.5
    factor = 0.9 ** (1 / decay) - 1
    ivl = stability / factor * (retention ** (1 / decay) - 1)
    return max(1, min(max_ivl, round(ivl)))


def init_stability(rating: int) -> float:
    return max(0.1, W[rating - 1])


def init_difficulty(rating: int) -> float:
    d = W[4] - (rating - 3) * W[5]
    return _clamp(d, 1.0, 10.0)


def next_difficulty(d: float, rating: int) -> float:
    nd = d - W[6] * (rating - 3)
    # 均值回归，防止难度漂移
    nd = W[7] * init_difficulty(3) + (1 - W[7]) * nd
    return _clamp(nd, 1.0, 10.0)


def stability_after_recall(d: float, s: float, r: float, rating: int) -> float:
    hard_penalty = W[15] if rating == RATING_HARD else 1.0
    # 三档制没有 Easy 档：good 是中性，绝不能吃 easy_bonus。
    # 否则稳定性指数爆炸（实测 3.71 → 35.6 → 247 → 1370，到期干到 2031）。
    easy_bonus = 1.0
    inc = math.exp(W[8]) * (11 - d) * (s ** -W[9]) * \
          (math.exp((1 - r) * W[10]) - 1) * hard_penalty * easy_bonus
    return max(0.1, s * (1 + inc))


def stability_after_forget(d: float, s: float, r: float) -> float:
    # 必须与 Dart scheduler.dart 的 kForgetRetainExp 保持一致。
    # 旧代码写的是 W[17]，但 W 只有 17 项（索引 0..16），`len(W) > 17` 恒为
    # False —— 那个分支是死代码，实际一直走 `s / 2.0`（保留 50%），
    # 而 Dart 端是 1/e^1.5（保留 22.3%）。两端差一倍多，
    # 用这份代码拟合出来的参数跟真机跑的根本不是同一个算法。
    s_min = s / math.exp(FORGET_RETAIN_EXP)
    ns = W[11] * (d ** -W[12]) * ((s + 1) ** W[13] - 1) * math.exp((1 - r) * W[14])
    return max(0.1, min(ns, s_min))


@dataclass
class CardState:
    stability: float = 0.0
    difficulty: float = 0.0
    reps: int = 0
    lapses: int = 0
    due: str = ""
    last_review: str = ""
    state: str = "new"

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict) -> "CardState":
        return cls(**{k: d.get(k, v) for k, v in cls().__dict__.items()})


def review(card: CardState, rating, today: date | None = None) -> CardState:
    """
    核心 API：喂进一张卡 + 一个评分，吐出更新后的卡。
    rating 可以是 1/2/3 或 'again'/'hard'/'good'/'忘记'/'模糊'/'记得'
    """
    if isinstance(rating, str):
        rating = NAME_RATING[rating.strip().lower()]
    if rating not in (1, 2, 3):
        raise ValueError(f"非法评分: {rating}")

    today = today or date.today()

    if card.state == "new":
        # 首次学习：无论评分如何，一律进入 learning，明天必须复习
        card.stability = init_stability(rating)
        card.difficulty = init_difficulty(rating)
        card.state = "learning"
        ivl = LEARNING_INTERVAL
    elif card.state in ("learning", "relearning"):
        # 学习/重学阶段：答对毕业进 review，答错继续留在学习阶段
        last = date.fromisoformat(card.last_review) if card.last_review else today
        elapsed = max(0, (today - last).days)
        r = forgetting_curve(elapsed, card.stability) if card.stability > 0 else 0.0
        if rating == RATING_AGAIN:
            card.stability = stability_after_forget(card.difficulty, card.stability, r)
            card.lapses += 1
            card.state = "relearning"
            ivl = LEARNING_INTERVAL
        else:
            card.stability = stability_after_recall(card.difficulty, card.stability, r, rating)
            card.state = "review"
            ivl = next_interval(card.stability)
        card.difficulty = next_difficulty(card.difficulty, rating)
    else:
        # 正式复习阶段
        last = date.fromisoformat(card.last_review) if card.last_review else today
        elapsed = max(0, (today - last).days)
        r = forgetting_curve(elapsed, card.stability)
        if rating == RATING_AGAIN:
            # 忘记：打回重学，明天必须复习
            card.stability = stability_after_forget(card.difficulty, card.stability, r)
            card.lapses += 1
            card.state = "relearning"
            ivl = LEARNING_INTERVAL
        else:
            card.stability = stability_after_recall(card.difficulty, card.stability, r, rating)
            card.state = "review"
            ivl = next_interval(card.stability)
        card.difficulty = next_difficulty(card.difficulty, rating)

    card.reps += 1
    card.last_review = today.isoformat()
    card.due = (today + timedelta(days=ivl)).isoformat()

    return card


if __name__ == "__main__":
    # 自测：一张新卡，三档不同评分走一遍
    for name in ("again", "hard", "good"):
        c = CardState()
        c = review(c, name, date(2026, 9, 13))
        print(f"评分={name:5s} -> S={c.stability:6.2f} D={c.difficulty:5.2f} "
              f"到期={c.due} 状态={c.state}")
    # 连续答对三天的演化
    c = CardState()
    d = date(2026, 9, 13)
    for i in range(4):
        c = review(c, "good", d)
        print(f"第{i+1}次 good: S={c.stability:.2f} 到期={c.due}")
        d = date.fromisoformat(c.due)

    # ---- 跨端一致性自检 ----
    # 忘记路径曾经在两端算出两个值：Python 走死代码分支的 s/2.0（保留 50%），
    # Dart 走 s/e^1.5（保留 22.3%）。用这份代码拟合出的参数，
    # 在真机上跑的根本不是同一个算法。这里钉一个 golden 值，
    # 改权重 / 改公式时若对不上，说明又跟 scheduler.dart 走偏了。
    c = CardState(state="review", stability=10.0, difficulty=5.0,
                  last_review="2026-09-01")
    c = review(c, "again", date(2026, 9, 17))
    expect = 10.0 / math.exp(FORGET_RETAIN_EXP)
    assert abs(c.stability - expect) < 1e-9, (
        f"遗忘惩罚与 Dart 端不一致：{c.stability} != {expect}。"
        f"检查 core/fsrs.py 的 FORGET_RETAIN_EXP 与 "
        f"app/lib/services/scheduler.dart 的 kForgetRetainExp 是否还相等。"
    )
    print(f"自检通过：忘记后 S={c.stability:.4f} = 10/e^{FORGET_RETAIN_EXP}"
          f"（与 Dart 端一致）")
