"""Lightweight FruityVens forecast server for PythonAnywhere free accounts.

This version avoids pandas, scipy, scikit-learn, and firebase-admin so it can
fit inside PythonAnywhere's small free storage quota. Flutter sends the current
transaction snapshot in the request body, and this server returns the same
response shape as the FastAPI/scikit-learn development server.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from typing import Any

from flask import Flask, jsonify, request


app = Flask(__name__)
MIN_OBSERVED_SALES_DAYS = 30


@app.after_request
def add_cors_headers(response):
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    return response


@app.get("/health")
def health():
    return jsonify(
        {
            "ok": True,
            "engine": "LightweightTrendForecast",
            "firebaseAdmin": False,
            "requiresFirebaseAuth": False,
            "minimumObservedSalesDays": MIN_OBSERVED_SALES_DAYS,
        }
    )


@app.route("/forecast", methods=["POST", "OPTIONS"])
def forecast():
    if request.method == "OPTIONS":
        return ("", 204)

    payload = request.get_json(silent=True) or {}
    horizon_days = int(payload.get("horizon_days") or 7)
    horizon_days = max(1, min(14, horizon_days))
    transactions = _normalize_transactions(payload.get("transactions") or [])

    if not transactions:
        return jsonify(
            {
                "summary": "No sold transactions are available for forecasting yet.",
                "source": "PythonAnywhere Forecast Server",
                "model": "insufficient-data",
                "dataSource": "request-payload",
                "horizonDays": horizon_days,
                "confidence": "low",
                "dataCoverage": {
                    "transactionCount": 0,
                    "observedDays": 0,
                    "dataStart": None,
                    "dataEnd": None,
                    "fruits": [],
                },
                "predictions": [],
            }
        )

    daily = _daily_sales(transactions)
    observed_days = {item["sold_date"] for item in transactions}
    data_coverage = _data_coverage(transactions)
    if len(observed_days) < MIN_OBSERVED_SALES_DAYS:
        return jsonify(
            {
                "summary": (
                    f"Collecting genuine sales history: {len(observed_days)} of "
                    f"{MIN_OBSERVED_SALES_DAYS} selling days recorded."
                ),
                "source": "FruityVens vendor sales",
                "model": "collecting-history",
                "dataSource": "request-payload",
                "horizonDays": horizon_days,
                "confidence": "low",
                "dataCoverage": data_coverage,
                "predictions": [],
            }
        )
    confidence = _confidence_label(len(transactions), len(observed_days))
    predictions = [
        _prediction_for_fruit(fruit, days, horizon_days, confidence)
        for fruit, days in sorted(daily.items())
    ]
    predictions.sort(key=lambda item: item["predictedKgTotal"], reverse=True)

    return jsonify(
        {
            "summary": _summary(predictions, confidence),
            "source": "PythonAnywhere Forecast Server",
            "model": "LightweightTrendForecast",
            "dataSource": "request-payload",
            "horizonDays": horizon_days,
            "confidence": confidence,
            "dataCoverage": data_coverage,
            "predictions": predictions,
        }
    )


def _normalize_transactions(raw: list[Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for item in raw:
        if not isinstance(item, dict):
            continue

        status = str(item.get("status", "sold")).strip().lower()
        if status and status not in {"sold", "sale"}:
            continue

        fruit = _first_text(item, "fruitName", "fruit", "fruitType", "name")
        sold_at = _parse_date(item.get("soldAt") or item.get("timestamp"))
        weight_kg = _weight_kg(item)
        if not fruit or sold_at is None or weight_kg <= 0:
            continue

        rows.append(
            {
                "fruit": fruit,
                "sold_date": sold_at.date(),
                "weight_kg": weight_kg,
            }
        )
    return rows


def _daily_sales(transactions: list[dict[str, Any]]) -> dict[str, dict[date, float]]:
    daily: dict[str, dict[date, float]] = defaultdict(lambda: defaultdict(float))
    for item in transactions:
        daily[item["fruit"]][item["sold_date"]] += item["weight_kg"]
    return daily


def _prediction_for_fruit(
    fruit: str,
    daily: dict[date, float],
    horizon_days: int,
    confidence: str,
) -> dict[str, Any]:
    last_day = max(daily)
    recent_values = [
        daily.get(last_day - timedelta(days=offset), 0.0)
        for offset in range(13, -1, -1)
    ]
    recent_7 = sum(recent_values[-7:])
    previous_7 = sum(recent_values[:7])
    baseline_daily = _weighted_average(recent_values[-7:])
    trend_factor = _trend_factor(recent_7, previous_7)
    weekday_factors = _weekday_factors(daily)

    today = datetime.now(timezone.utc).date()
    daily_predictions: list[float] = []
    for offset in range(1, horizon_days + 1):
        forecast_day = today + timedelta(days=offset)
        weekday_factor = weekday_factors.get(forecast_day.weekday(), 1.0)
        daily_predictions.append(max(0.0, baseline_daily * trend_factor * weekday_factor))

    total = sum(daily_predictions)
    tomorrow = daily_predictions[0] if daily_predictions else 0.0
    recommendation = _recommendation(total, baseline_daily)

    return {
        "fruit": fruit,
        "predictedKgTomorrow": round(tomorrow, 2),
        "predictedKgTotal": round(total, 2),
        "recommendation": recommendation,
        "confidence": confidence,
        "reason": _reason(fruit, recommendation, confidence),
        "dailyPredictions": [round(value, 2) for value in daily_predictions],
    }


def _data_coverage(transactions: list[dict[str, Any]]) -> dict[str, Any]:
    observed_days = sorted({item["sold_date"] for item in transactions})
    return {
        "transactionCount": len(transactions),
        "observedDays": len(observed_days),
        "dataStart": observed_days[0].isoformat() if observed_days else None,
        "dataEnd": observed_days[-1].isoformat() if observed_days else None,
        "fruits": sorted({item["fruit"] for item in transactions}),
    }


def _weighted_average(values: list[float]) -> float:
    if not values:
        return 0.0
    weights = list(range(1, len(values) + 1))
    total_weight = sum(weights)
    return sum(value * weight for value, weight in zip(values, weights)) / total_weight


def _trend_factor(recent_7: float, previous_7: float) -> float:
    if previous_7 <= 0:
        return 1.12 if recent_7 > 0 else 1.0
    ratio = recent_7 / previous_7
    if ratio >= 1.35:
        return 1.18
    if ratio >= 1.12:
        return 1.08
    if ratio <= 0.65:
        return 0.82
    if ratio <= 0.88:
        return 0.92
    return 1.0


def _weekday_factors(daily: dict[date, float]) -> dict[int, float]:
    totals: dict[int, float] = defaultdict(float)
    counts: dict[int, int] = defaultdict(int)
    for sold_date, weight in daily.items():
        weekday = sold_date.weekday()
        totals[weekday] += weight
        counts[weekday] += 1

    averages = {
        weekday: totals[weekday] / max(1, counts[weekday]) for weekday in totals
    }
    if not averages:
        return {}
    overall = sum(averages.values()) / len(averages)
    if overall <= 0:
        return {}
    return {
        weekday: min(1.25, max(0.75, average / overall))
        for weekday, average in averages.items()
    }


def _recommendation(predicted_total: float, baseline_daily: float) -> str:
    heavy_threshold = max(5.0, baseline_daily * 7 * 1.25)
    medium_threshold = max(2.0, baseline_daily * 7 * 0.65)
    if predicted_total >= heavy_threshold:
        return "Heavy restock"
    if predicted_total >= medium_threshold:
        return "Medium restock"
    if predicted_total > 0:
        return "Light top-up"
    return "Watch"


def _reason(fruit: str, recommendation: str, confidence: str) -> str:
    clean = recommendation.lower()
    if "heavy" in clean:
        action = "Recent sales point to strong demand."
    elif "medium" in clean:
        action = "Sales are steady enough to prepare a refill."
    elif "light" in clean:
        action = "Sales are present, but demand looks modest."
    else:
        action = "There is not enough movement yet to refill confidently."
    return f"{fruit}: {action} Confidence is {confidence}."


def _summary(predictions: list[dict[str, Any]], confidence: str) -> str:
    if not predictions:
        return "No forecast could be generated because there are no usable sold transactions yet."
    leaders = predictions[:3]
    leader_text = ", ".join(
        f"{item['fruit']} ({item['recommendation']})" for item in leaders
    )
    return (
        f"Forecast ready for the next 7 days: {leader_text}. "
        f"Confidence is {confidence}; add more sales history to improve it."
    )


def _confidence_label(transaction_count: int, observed_days: int) -> str:
    if transaction_count >= 500 and observed_days >= 180:
        return "high"
    if transaction_count >= 100 and observed_days >= 60:
        return "medium"
    return "low"


def _first_text(item: dict[str, Any], *keys: str) -> str:
    for key in keys:
        value = item.get(key)
        if value is None:
            continue
        text = str(value).strip()
        if text:
            return text
    return ""


def _parse_date(value: Any) -> datetime | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        timestamp = float(value)
        if timestamp > 10_000_000_000:
            timestamp /= 1000
        return datetime.fromtimestamp(timestamp, tz=timezone.utc)
    text = str(value).strip()
    if not text:
        return None
    text = text.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _weight_kg(item: dict[str, Any]) -> float:
    if item.get("weightKg") is not None:
        return max(0.0, float(item["weightKg"]))
    value = item.get("weightGrams") or item.get("weight")
    if value is None:
        return 0.0
    amount = float(value)
    if amount > 50:
        return max(0.0, amount / 1000)
    return max(0.0, amount)
