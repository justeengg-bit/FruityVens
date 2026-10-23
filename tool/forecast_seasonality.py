"""Historical PSA seasonal context, kept separate from vendor sales targets."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd

DEFAULT_HISTORY_PATH = (
    Path(__file__).resolve().parents[1] / "assets/data/psa_market_history.json"
)
GEOGRAPHY_RANK = {"city": 0, "province": 1, "region": 2, "national": 3}
MANGO_VARIANTS = {"Apple Mango", "Indian Mango", "Mango Carabao"}
SEASONAL_FEATURES = [
    "market_price_index",
    "market_supply_index",
    "market_price_available",
    "market_supply_available",
]


class SeasonalMarketHistory:
    def __init__(self, records: list[dict[str, Any]], version: str = ""):
        self.version = version
        self.records = pd.DataFrame(records)
        self._profiles: dict[tuple[str, str, int], dict[str, Any] | None] = {}
        if not self.records.empty:
            self.records["periodStart"] = pd.to_datetime(self.records["periodStart"])
            self.records["value"] = pd.to_numeric(
                self.records["value"], errors="coerce"
            )
            self.records = self.records[
                np.isfinite(self.records["value"]) & (self.records["value"] >= 0)
            ]

    @classmethod
    def load(cls, path: Path = DEFAULT_HISTORY_PATH) -> SeasonalMarketHistory:
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
            return cls(document["records"], document.get("datasetVersion", ""))
        except (OSError, ValueError, KeyError):
            return cls([])

    def _profile(self, fruit: str, metric: str, year: int) -> dict[str, Any] | None:
        key = (fruit, metric, year)
        if key in self._profiles:
            return self._profiles[key]
        profile = None
        if not self.records.empty:
            # Publication dates are unavailable. Exclude the entire preceding
            # year as a conservative buffer, and never use future periods.
            eligible = self.records[
                (self.records["metric"] == metric)
                & (self.records["periodStart"].dt.year <= year - 2)
            ]
            candidates = [fruit]
            if fruit in MANGO_VARIANTS:
                candidates.append("Mango")
            for category in candidates:
                profiles = []
                for _, series in eligible[eligible["fruitName"] == category].groupby(
                    "seriesKey"
                ):
                    length = 12 if metric == "retail_price" else 4
                    granularity = "month" if length == 12 else "quarter"
                    series = series[series["periodGranularity"] == granularity].copy()
                    series["year"] = series["periodStart"].dt.year
                    series["phase"] = (
                        series["periodStart"].dt.month
                        if length == 12
                        else series["periodStart"].dt.quarter
                    )
                    series = series.drop_duplicates(["year", "phase"])
                    complete = series.groupby("year")["phase"].nunique()
                    complete_years = complete[complete == length].index
                    series = series[series["year"].isin(complete_years)]
                    if len(complete_years) < 2:
                        continue
                    annual_mean = series.groupby("year")["value"].transform("mean")
                    series = series[annual_mean > 0].copy()
                    if series["year"].nunique() < 2:
                        continue
                    series["index"] = series["value"] / annual_mean[annual_mean > 0]
                    first = series.iloc[0]
                    profiles.append(
                        {
                            "indices": series.groupby("phase")["index"]
                            .mean()
                            .to_dict(),
                            "geography": str(first["geography"]),
                            "geographyLevel": str(first["geographyLevel"]),
                            "priority": int(first.get("seriesPriority", 0)),
                            "sourceTable": str(first["sourceTable"]),
                            "sourceUrl": str(first["sourceUrl"]),
                            "category": category,
                            "usesCategoryFallback": category != fruit,
                            "referenceYears": int(series["year"].nunique()),
                            "dataStart": series["periodStart"].min().date().isoformat(),
                            "dataEnd": series["periodStart"].max().date().isoformat(),
                        }
                    )
                if profiles:
                    profile = min(
                        profiles,
                        key=lambda item: (
                            GEOGRAPHY_RANK.get(item["geographyLevel"], 4),
                            item["priority"],
                            -item["referenceYears"],
                        ),
                    )
                    break
        self._profiles[key] = profile
        return profile

    def context(self, fruit: str, date: pd.Timestamp) -> dict[str, Any]:
        result: dict[str, Any] = {"datasetVersion": self.version}
        for metric, name in [
            ("retail_price", "price"),
            ("production_volume", "supply"),
        ]:
            profile = self._profile(fruit, metric, date.year)
            if profile is None:
                continue
            phase = date.month if name == "price" else date.quarter
            result[name] = {
                k: value
                for k, value in profile.items()
                if k not in {"indices", "priority"}
            }
            result[name].update(
                {
                    "seasonalIndex": round(float(profile["indices"][phase]), 4),
                    "period": date.strftime("%b")
                    if name == "price"
                    else f"Q{date.quarter}",
                }
            )
        return result

    def features(self, fruit: str, date: pd.Timestamp) -> dict[str, float]:
        context = self.context(fruit, date)
        return {
            "market_price_index": context.get("price", {}).get("seasonalIndex", 1.0),
            "market_supply_index": context.get("supply", {}).get("seasonalIndex", 1.0),
            "market_price_available": float("price" in context),
            "market_supply_available": float("supply" in context),
        }

    def add_features(self, frame: pd.DataFrame) -> pd.DataFrame:
        keys = list(zip(frame["fruit"], frame["date"].dt.year, frame["date"].dt.month))
        values = {
            key: self.features(key[0], pd.Timestamp(year=key[1], month=key[2], day=1))
            for key in dict.fromkeys(keys)
        }
        seasonal = pd.DataFrame(
            [values[key] for key in keys],
            index=frame.index,
        )
        return frame.assign(
            **{column: seasonal[column] for column in SEASONAL_FEATURES}
        )
