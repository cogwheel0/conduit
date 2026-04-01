from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable

import tiktoken


ENC = tiktoken.get_encoding("cl100k_base")


@dataclass(frozen=True)
class DynamicBudget:
    hard_context: int
    reserved_output: int
    safety_margin: int
    absolute_prompt_ceiling: int
    prompt_target: int


def build_budget(context_size: int) -> DynamicBudget:
    hard_context = max(2048, int(context_size))

    # Safer defaults for local 64k inference:
    # keep generation room large and trim prompts earlier.
    if hard_context >= 65536:
        reserved_output = 4096
        safety_margin = 4096
        prompt_target = 46000
    elif hard_context >= 32768:
        reserved_output = 3072
        safety_margin = 2048
        prompt_target = 22000
    else:
        reserved_output = max(1024, min(2048, hard_context // 8))
        safety_margin = max(1024, hard_context // 16)
        prompt_target = int((hard_context - reserved_output - safety_margin) * 0.85)

    absolute_prompt_ceiling = hard_context - reserved_output - safety_margin

    # Guardrails
    absolute_prompt_ceiling = max(1024, absolute_prompt_ceiling)
    prompt_target = max(768, min(prompt_target, absolute_prompt_ceiling))

    return DynamicBudget(
        hard_context=hard_context,
        reserved_output=reserved_output,
        safety_margin=safety_margin,
        absolute_prompt_ceiling=absolute_prompt_ceiling,
        prompt_target=prompt_target,
    )


def estimate_tokens(text: str) -> int:
    if not text:
        return 0
    return len(ENC.encode(text))


def estimate_messages_tokens(messages: Iterable[dict]) -> int:
    total = 0
    for msg in messages:
        total += estimate_tokens(msg.get("role", ""))
        total += estimate_tokens(msg.get("content", ""))
        total += 6
    return total


def total_prompt_tokens(
    system_prompt: str,
    summary: str,
    messages: list[dict],
) -> int:
    return (
        estimate_tokens(system_prompt)
        + estimate_tokens(summary)
        + estimate_messages_tokens(messages)
    )


def trim_recent_messages(
    messages: list[dict],
    summary: str,
    system_prompt: str,
    context_size: int,
) -> tuple[list[dict], int]:
    budget = build_budget(context_size)
    working = list(messages)

    while working:
        total = total_prompt_tokens(system_prompt, summary, working)
        if total <= budget.prompt_target:
            return working, total
        working.pop(0)

    total = total_prompt_tokens(system_prompt, summary, [])
    return [], total
