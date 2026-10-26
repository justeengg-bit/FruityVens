"""The app's supported categories and explicit handling of unresolved labels."""

from __future__ import annotations

import json
import re
from pathlib import Path

import pandas as pd

CATEGORY_PATH = Path(__file__).resolve().parents[1] / "assets/data/fruit_categories.json"
CATEGORY_DOCUMENT = json.loads(CATEGORY_PATH.read_text(encoding="utf-8"))
FRUIT_CATEGORIES = tuple(CATEGORY_DOCUMENT["categories"])


def _key(name: str) -> str:
    return re.sub(r"[\W_]+", " ", name.casefold()).strip()


_NAMES = {_key(name): name for name in FRUIT_CATEGORIES}
_NAMES.update({_key(alias): name for alias, name in CATEGORY_DOCUMENT["aliases"].items()})
_AMBIGUOUS = {_key(name) for name in CATEGORY_DOCUMENT["ambiguous_names"]}


def resolve_category(name: str) -> tuple[str | None, str | None]:
    key = _key(str(name))
    if key in _AMBIGUOUS:
        return None, "Mango variety unspecified; confirm Mango Carabao, Indian Mango, or Apple Mango"
    canonical = _NAMES.get(key)
    return (canonical, None) if canonical else (None, "Outside the supported fruit categories")


def split_supported_sales(transactions: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Keep original labels for audit; never guess a missing mango variety."""
    rows = transactions.copy()
    if rows.empty:
        return rows, pd.DataFrame(columns=[*rows.columns, "source_fruit", "category_issue"])
    rows["source_fruit"] = rows["fruit"]
    resolved = rows["fruit"].map(resolve_category)
    rows["category_issue"] = resolved.map(lambda value: value[1])
    valid = rows["category_issue"].isna()
    issues = rows[~valid].copy()
    rows.loc[valid, "fruit"] = resolved[valid].map(lambda value: value[0])
    return rows[valid].drop(columns="category_issue").copy(), issues


def category_coverage(transactions: pd.DataFrame, predictions: pd.DataFrame) -> pd.DataFrame:
    """Represent every category; missing history has no invented sales quantity."""
    records = []
    for fruit in FRUIT_CATEGORIES:
        rows = transactions[transactions["fruit"] == fruit]
        checked = predictions[(predictions["fruit"] == fruit) & (predictions["model"] == "Selected policy")]
        records.append({
            "fruit": fruit,
            "transaction_count": len(rows),
            "selling_days": int(rows["date"].nunique()),
            "total_kg": float(rows["weight_kg"].sum()) if len(rows) else None,
            "first_sale": str(rows["date"].min()) if len(rows) else None,
            "last_sale": str(rows["date"].max()) if len(rows) else None,
            "generated_transactions": int(rows["generated"].sum()),
            "tested_days": int(checked["date"].nunique()),
            "history_status": "Sales history available" if len(rows) else "No recorded sales history",
            "evaluation_status": "Sample evaluation only" if len(checked) and rows["generated"].any()
            else "Evaluated on recorded input" if len(checked)
            else "Insufficient earlier history" if len(rows) else "Not evaluated: no history",
        })
    return pd.DataFrame(records)
