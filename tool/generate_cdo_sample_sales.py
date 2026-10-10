#!/usr/bin/env python3
"""Generate clearly labeled, deterministic synthetic CDO vendor sales.

Reads only the bundled historical PSA extract. Does not contact any service,
write to the app database, or create official 2026 observations.
"""

from __future__ import annotations

import csv
import hashlib
import json
import random
from collections import Counter, defaultdict
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HISTORY_PATH = ROOT / "assets/data/psa_market_history.json"
JSON_PATH = ROOT / "assets/data/cdo_sample_sales_2026.json"
CSV_PATH = ROOT / "docs/data/cdo_sample_sales_2026.csv"
DOC_PATH = ROOT / "docs/cdo_sample_sales.md"
START = date(2026, 7, 1)
END = date(2026, 10, 9)
MANILA = timezone(timedelta(hours=8))
CUTOFF = datetime(2026, 10, 9, 12, 0, tzinfo=MANILA)
SEED = 20260701
FRUITS = (
    "Apple", "Banana", "Grapes", "Mango", "Orange", "Papaya", "Pineapple",
    "Watermelon", "Calamansi",
)
# These weights, basket sizes, and all 2026 patterns are scenario assumptions.
FRUIT_WEIGHTS = (12, 22, 7, 17, 10, 9, 8, 8, 7)
BASKET_GRAMS = {
    "Apple": (500, 750, 1000, 1250, 1500, 2000),
    "Banana": (500, 750, 1000, 1500, 2000, 2500, 3000),
    "Grapes": (250, 375, 500, 750, 1000, 1250),
    "Mango": (500, 750, 1000, 1250, 1500, 2000, 2500),
    "Orange": (500, 750, 1000, 1250, 1500, 2000),
    "Papaya": (750, 1000, 1500, 2000, 2500, 3000),
    "Pineapple": (1000, 1250, 1500, 1750, 2000, 2500),
    "Watermelon": (1500, 2000, 2500, 3000, 3500, 4000, 5000),
    "Calamansi": (250, 375, 500, 750, 1000),
}
MONTH_PRICE_FACTORS = {7: Decimal("0.98"), 8: Decimal("1.00"),
                       9: Decimal("1.02"), 10: Decimal("1.03")}


def select_anchors(history: dict) -> list[dict]:
    """Prefer CDO, then province, region, country; retain actual provenance."""
    rank = {"city": 0, "province": 1, "region": 2, "national": 3}
    anchors = []
    for fruit in FRUITS:
        series = defaultdict(list)
        for record in history["records"]:
            if (record["fruitName"] == fruit
                    and record["metric"] == "retail_price"
                    and record["periodStart"] <= "2025-12-31"
                    and record["unit"] == "PHP/kg"
                    and record["value"] > 0):
                series[record["seriesKey"]].append(record)
        if not series:
            raise ValueError(f"No bundled historical retail-price anchor for {fruit}")
        selected = min(series.values(), key=lambda rows: (
            rank[rows[0]["geographyLevel"]], rows[0]["seriesPriority"],
            -len(rows), rows[0]["seriesKey"],
        ))
        latest = max(selected, key=lambda row: row["periodStart"])
        anchors.append({
            "fruitName": fruit,
            "historicalPricePhpPerKg": latest["value"],
            "periodStart": latest["periodStart"],
            "geography": latest["geography"],
            "geographyLevel": latest["geographyLevel"],
            "variant": latest["variant"],
            "seriesKey": latest["seriesKey"],
            "sourceCommodity": latest["sourceCommodity"],
            "sourceTable": latest["sourceTable"],
            "sourceUrl": latest["sourceUrl"],
        })
    return anchors


def generate() -> dict:
    history_bytes = HISTORY_PATH.read_bytes()
    history = json.loads(history_bytes)
    anchors = select_anchors(history)
    anchor_prices = {row["fruitName"]: Decimal(str(row["historicalPricePhpPerKg"]))
                     for row in anchors}
    transactions = []
    for day_offset in range((END - START).days + 1):
        day = START + timedelta(days=day_offset)
        rng = random.Random(SEED + day_offset)
        # Mild weekend/payday variation is invented for UI demonstrations.
        count = min(20, max(8, rng.randint(8, 15)
                           + (3 if day.weekday() >= 5 else 0)
                           + (2 if day.day in (15, 30, 31) else 0)))
        last_minute = 599  # 08:00 through 17:59 Manila on complete days.
        if day == END:
            count = 8
            last_minute = 239  # Partial final day: 08:00 through 11:59.
        minutes = sorted(rng.sample(range(last_minute + 1), count))
        for sequence, minute in enumerate(minutes, start=1):
            fruit = rng.choices(FRUITS, weights=FRUIT_WEIGHTS, k=1)[0]
            grams = rng.choice(BASKET_GRAMS[fruit])
            # One assumed price per fruit/week, with a small invented monthly shift.
            price_rng = random.Random(f"{SEED}:{fruit}:{day_offset // 7}")
            week_factor = Decimal(100 + price_rng.randint(-3, 3)) / 100
            price = anchor_prices[fruit] * MONTH_PRICE_FACTORS[day.month] * week_factor
            unit_price = int((price * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
            sold_at = (datetime.combine(day, time(8), MANILA)
                       + timedelta(minutes=minute, seconds=rng.randrange(60)))
            transactions.append({
                "cloudId": f"sample_cdo_{day:%Y%m%d}_{sequence:03d}",
                "fruitName": fruit,
                "weightGrams": grams,
                "unitPrice": unit_price,
                "totalPrice": (unit_price * grams + 500) // 1000,
                "status": "sold",
                "soldAt": sold_at.isoformat(),
            })
    day_counts = Counter(row["soldAt"][:10] for row in transactions)
    summary = {
        "transactionCount": len(transactions),
        "observedDays": len(day_counts),
        "fruitCount": len(FRUITS),
        "totalWeightGrams": sum(row["weightGrams"] for row in transactions),
        "totalRevenueCentavos": sum(row["totalPrice"] for row in transactions),
        "minTransactionsPerDay": min(day_counts.values()),
        "maxTransactionsPerDay": max(day_counts.values()),
        "firstSoldAt": transactions[0]["soldAt"],
        "lastSoldAt": transactions[-1]["soldAt"],
    }
    document = {
        "kind": "synthetic_sales",
        "label": "Sample CDO sales — synthetic, not actual vendor transactions",
        "startDate": START.isoformat(),
        "endDate": END.isoformat(),
        "cutoff": CUTOFF.isoformat(),
        "timezone": "Asia/Manila",
        "currency": "PHP",
        "generatorVersion": 1,
        "seed": SEED,
        "notes": [
            "Every transaction is invented and is imported into the app's normal sales history at the user's request; none is an actual vendor sale.",
            "All 2026 prices, transaction counts, basket sizes, demand, weekend and payday patterns are scenario assumptions, not official observations.",
            "Historical price anchors come from the bundled PSA extract through 2025. Geography and variety are retained for each anchor; regional/national data is not represented as CDO city data.",
            "July 1 through October 8 are complete scenario days. October 9 is a partial day ending before 12:00 Asia/Manila.",
            "unitPrice is integer centavos per kilogram; totalPrice is integer centavos, rounded half up from unitPrice × weightGrams / 1000.",
            "The app inserts these generated records into normal SQLite sales history, preserving existing records and deduplicating by the stable sample_cdo_ cloud IDs. They contribute to normal totals and forecasts and use the app's existing Firebase sync.",
            "Synthetic forecasts demonstrate the workflow and cannot establish real-world forecast accuracy or vendor demand.",
        ],
        "sources": [{
            "title": "PSA Fruits: Retail Prices of Agricultural Commodities — bundled historical extract",
            "url": anchors[0]["sourceUrl"],
            "table": "2M4ARA07",
            "localAsset": "assets/data/psa_market_history.json",
            "datasetVersion": history["datasetVersion"],
            "extractImportedAt": history["importedAt"],
            "sha256": hashlib.sha256(history_bytes).hexdigest(),
            "usage": "December 2025 historical price anchors only; no actual 2026 sales or prices were sourced.",
        }],
        "priceAnchors": anchors,
        "summary": summary,
        "transactions": transactions,
    }
    validate(document)
    return document


def validate(document: dict) -> None:
    rows = document["transactions"]
    assert document["kind"] == "synthetic_sales"
    assert len({row["cloudId"] for row in rows}) == len(rows)
    assert {row["fruitName"] for row in rows} == set(FRUITS)
    counts = Counter()
    previous = None
    for row in rows:
        sold_at = datetime.fromisoformat(row["soldAt"])
        assert sold_at.utcoffset() == timedelta(hours=8)
        assert START <= sold_at.date() <= END and sold_at < CUTOFF
        assert 8 <= sold_at.hour < 18
        assert previous is None or sold_at > previous
        assert row["cloudId"].startswith(f"sample_cdo_{sold_at:%Y%m%d}_")
        assert type(row["weightGrams"]) is int and 250 <= row["weightGrams"] <= 5000
        assert type(row["unitPrice"]) is int and row["unitPrice"] > 0
        assert type(row["totalPrice"]) is int
        assert row["totalPrice"] == (row["unitPrice"] * row["weightGrams"] + 500) // 1000
        assert row["status"] == "sold"
        counts[sold_at.date()] += 1
        previous = sold_at
    assert set(counts) == {START + timedelta(days=i) for i in range((END - START).days + 1)}
    assert all(8 <= count <= 20 for count in counts.values())
    assert sum(counts.values()) == document["summary"]["transactionCount"]
    assert sum(row["totalPrice"] for row in rows) == document["summary"]["totalRevenueCentavos"]
    assert sum(row["weightGrams"] for row in rows) == document["summary"]["totalWeightGrams"]


def documentation(document: dict) -> str:
    summary = document["summary"]
    table = "\n".join(
        f"| {row['fruitName']} | {row['variant']} | {row['geography']} | "
        f"{row['historicalPricePhpPerKg']:.2f} |"
        for row in document["priceAnchors"]
    )
    return f"""# Sample CDO sales, July–October 2026

**Generated data. These are invented transactions, not actual Cagayan de Oro vendor sales or official 2026 observations.** At the user's request, they were imported directly into normal sales history. They contribute to the normal dashboard, analytics, reports, and forecasts and use the app's existing Firebase sync.

The [JSON asset](../assets/data/cdo_sample_sales_2026.json) and [downloadable CSV](data/cdo_sample_sales_2026.csv) contain {summary['transactionCount']:,} transactions across {summary['observedDays']} consecutive dates, July 1–October 9, 2026. Each date has {summary['minTransactionsPerDay']}–{summary['maxTransactionsPerDay']} transactions. October 9 is a partial day, ending at {summary['lastSoldAt']}. Timestamps use Manila's +08:00 offset; no transaction reaches the October 9 noon cutoff.

The scenario totals {summary['totalWeightGrams'] / 1000:,.3f} kg and PHP {summary['totalRevenueCentavos'] / 100:,.2f}. These totals describe generated sample data only.

## Import into normal history

The import completed on the connected phone: 1,249 generated records were added while preserving 139 existing sales, leaving 1,388 records in normal SQLite sales history. Stable `sample_cdo_` cloud IDs identify the generated records and prevent duplicate imports or overwriting matching records. The one-time “Add July–October sales” button has been removed; the imported records remain in History. There is no separate sample mode.

After import, totals can contain both existing sales and generated records. Keep the generated-data labels and ID prefix when displaying, exporting, or synchronizing this history. A forecast based on these records is a demonstration using generated inputs, not evidence of actual demand or measured forecast accuracy. Firebase publication uses the application's existing account and sync flow; generating the asset itself does not contact Firebase.

## Historical price anchors

The generator reads the existing [bundled PSA extract](../assets/data/psa_market_history.json), dataset `{document['sources'][0]['datasetVersion']}`, imported {document['sources'][0]['extractImportedAt']}. Its source is [PSA table 2M4ARA07, Fruits: Retail Prices of Agricultural Commodities]({document['sources'][0]['url']}). No fresh source download or verification of 2026 prices was performed.

For each fruit, the nearest available geography is selected first (city, province, region, country), followed by the extract's variety priority. The latest positive monthly price through 2025 becomes an anchor. All selected anchors are December 2025. Regional and national fallbacks retain their real geography; they are not claimed as city observations.

| Fruit | Historical variety | Historical geography | December 2025 PHP/kg |
| --- | --- | --- | ---: |
{table}

## Scenario assumptions

- All sales, basket weights, timestamps and 2026 prices are simulated. Historical anchors provide a plausible reference, not evidence of what a vendor charged in 2026.
- Fruit selection uses fixed illustrative weights: Apple 12, Banana 22, Grapes 7, Mango 17, Orange 10, Papaya 9, Pineapple 8, Watermelon 8, Calamansi 7. These are not measured local market shares.
- Baskets range from 250 to 5,000 grams. Assumed business hours are 08:00–17:59, shortened to 08:00–11:59 on October 9.
- Full-day counts use a seeded 8–15 base, plus 3 on weekends and 2 on days 15, 30 or 31, capped at 20. October 9 contains 8 sample sales. These patterns are invented, not observed CDO behavior.
- Assumed July/August/September/October prices multiply historical anchors by 0.98/1.00/1.02/1.03, plus seeded weekly variation of −3% to +3%. There is no claim of measured inflation or seasonality.
- `unitPrice` is integer centavos per kilogram. `totalPrice` uses exact positive half-up rounding: `(unitPrice * weightGrams + 500) // 1000`. CSV columns retain the same units.
- IDs begin `sample_cdo_`; every record has status `sold`. The JSON explicitly marks `kind: synthetic_sales`, includes source metadata and historical anchors, and records the source asset SHA-256.

## Reproduce and validate

Run from any working directory:

```sh
python3 tool/generate_cdo_sample_sales.py
```

The generator uses only Python's standard library, a fixed seed ({SEED}), and the bundled source asset. It overwrites only the JSON, CSV, and this document. Its validation checks unique sample IDs, exact totals, all daily coverage, transaction counts, fruit coverage, integer units, monotonic timestamps, business hours, timezone, and the final cutoff. Identical inputs reproduce identical output files. It does not access SQLite, Firebase, credentials, or the network.

Synthetic forecasts can illustrate charts and recommendations. They must not be presented as measured forecasting performance or evidence of actual vendor demand.
"""


def main() -> None:
    document = generate()
    JSON_PATH.parent.mkdir(parents=True, exist_ok=True)
    JSON_PATH.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    CSV_PATH.parent.mkdir(parents=True, exist_ok=True)
    with CSV_PATH.open("w", encoding="utf-8", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=list(document["transactions"][0]))
        writer.writeheader()
        writer.writerows(document["transactions"])
    DOC_PATH.write_text(documentation(document), encoding="utf-8")
    print(json.dumps(document["summary"], indent=2))
    for path in (JSON_PATH, CSV_PATH, DOC_PATH):
        print(path.relative_to(ROOT))


if __name__ == "__main__":
    main()
