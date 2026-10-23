"""FruityVens seasonal XGBoost demand forecast server.

Run from the project root:

    uvicorn tool.forecast_server:app --host 0.0.0.0 --port 8787

For production-like Firebase reads, set FIREBASE_SERVICE_ACCOUNT to a Firebase
Admin SDK JSON file. For local development, Flutter can send the transaction
snapshot directly in the request body.

On Cloud Run, leave FIREBASE_SERVICE_ACCOUNT unset. Firebase Admin uses Google
Application Default Credentials from the Cloud Run service account.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd
from fastapi import FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from xgboost import XGBRegressor

from tool.forecast_seasonality import SEASONAL_FEATURES, SeasonalMarketHistory

try:
    import firebase_admin
    from firebase_admin import auth, credentials, db
except ImportError:  # Firebase Admin is optional for local payload forecasts.
    firebase_admin = None
    auth = None
    credentials = None
    db = None


DATABASE_URL = os.getenv(
    "FIREBASE_DATABASE_URL",
    "https://fruityv-default-rtdb.asia-southeast1.firebasedatabase.app",
)
SERVICE_ACCOUNT_PATH = os.getenv(
    "FIREBASE_SERVICE_ACCOUNT",
    "firebase-service-account.json",
)
REQUIRE_FIREBASE_AUTH = os.getenv(
    "FRUITYVENS_REQUIRE_FIREBASE_AUTH",
    "false",
).lower() in {"1", "true", "yes"}
VERIFY_FIREBASE_AUTH = REQUIRE_FIREBASE_AUTH or os.getenv(
    "FRUITYVENS_VERIFY_FIREBASE_AUTH",
    "false",
).lower() in {"1", "true", "yes"}
MIN_ML_ROWS = int(os.getenv("FRUITYVENS_FORECAST_MIN_ML_ROWS", "8"))
MIN_OBSERVED_SALES_DAYS = int(os.getenv("FRUITYVENS_FORECAST_MIN_OBSERVED_DAYS", "30"))
BUSINESS_TIMEZONE = ZoneInfo("Asia/Manila")
MARKET_HISTORY = SeasonalMarketHistory.load()
FORECAST_FEATURES = [
    "fruit_code",
    "day_of_week",
    "month",
    "quarter",
    "year_sin",
    "year_cos",
    "is_weekend",
    "previous_unit_price",
    "kg_last_1d",
    "kg_last_3d",
    "kg_last_7d",
    "kg_last_14d",
    "kg_last_28d",
    "kg_same_weekday",
    "kg_last_year",
    "year_history_available",
    "kg_avg_7d",
    "trend_3_vs_7",
    "days_since_sale",
] + SEASONAL_FEATURES


app = FastAPI(title="FruityVens Seasonal Demand Forecast Server")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)


class ForecastRequest(BaseModel):
    horizon_days: int = Field(default=7, ge=1, le=14)
    inventory: list[dict[str, Any]] = Field(default_factory=list)
    salesSnapshot: dict[str, Any] = Field(default_factory=dict)
    transactions: list[dict[str, Any]] = Field(default_factory=list)


@dataclass
class ForecastContext:
    data: pd.DataFrame
    source: str
    uid: str | None = None


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "engine": "XGBRegressor",
        "seasonalDataset": MARKET_HISTORY.version,
        "firebaseAdmin": _firebase_ready(),
        "requiresFirebaseAuth": REQUIRE_FIREBASE_AUTH,
        "minimumObservedSalesDays": MIN_OBSERVED_SALES_DAYS,
    }


@app.post("/forecast")
def forecast(
    request: ForecastRequest,
    authorization: str = Header(default=""),
) -> dict[str, Any]:
    context = _forecast_context(request, authorization)
    transactions = _normalize_transactions(context.data)
    today = pd.Timestamp(datetime.now(BUSINESS_TIMEZONE).date())
    if not transactions.empty:
        # Today's ledger is incomplete. Train and validate on closed days only.
        transactions = transactions[transactions["date"] < today.date()].copy()
    data_coverage = _data_coverage(transactions)
    if transactions.empty:
        return _empty_response(
            source="FruityVens seasonal demand forecast",
            model="insufficient-data",
            message="No completed sales before today are available for forecasting yet.",
            data_coverage=data_coverage,
        )
    if data_coverage["observedDays"] < MIN_OBSERVED_SALES_DAYS:
        return _empty_response(
            source="FruityVens vendor sales",
            model="collecting-history",
            message=(
                f"Collecting sales history: {data_coverage['observedDays']} "
                f"of {MIN_OBSERVED_SALES_DAYS} selling days recorded."
            ),
            data_coverage=data_coverage,
        )

    daily = _daily_sales_frame(transactions)
    if (today - daily["date"].max()).days > 30:
        return _empty_response(
            source="FruityVens seasonal demand forecast",
            model="stale-history",
            message="The latest completed sale is more than 30 days old. Update sales history before forecasting current demand.",
            data_coverage=data_coverage,
        )
    training, fruit_codes = _training_frame(daily)
    validation = _validate_models(daily, request.horizon_days)
    model_name = validation["selectedModel"]
    confidence = _confidence_label(transactions, validation)
    forecast_start = today + pd.Timedelta(days=1)
    model = None
    if len(training) >= MIN_ML_ROWS:
        if model_name == "XGBRegressor":
            model = _train_model(training)
    else:
        model_name = "Recent average"
    values = _forecast_values(
        daily, model, fruit_codes, forecast_start, request.horizon_days, model_name
    )
    predictions = [
        _prediction_payload(fruit, weights, daily, confidence, forecast_start)
        for fruit, weights in values.items()
    ]

    predictions = sorted(
        predictions,
        key=lambda item: item["predictedKgTotal"],
        reverse=True,
    )
    summary = _summary(
        predictions,
        model_name=model_name,
        confidence=confidence,
        horizon_days=request.horizon_days,
    )

    return {
        "summary": summary,
        "source": "FruityVens seasonal demand forecast",
        "model": model_name,
        "uid": context.uid,
        "dataSource": context.source,
        "horizonDays": request.horizon_days,
        "confidence": confidence,
        "forecastStart": forecast_start.date().isoformat(),
        "forecastEnd": (forecast_start + pd.Timedelta(days=request.horizon_days - 1))
        .date()
        .isoformat(),
        "validation": validation,
        "dataCoverage": data_coverage,
        "predictions": predictions,
    }


def _forecast_context(request: ForecastRequest, authorization: str) -> ForecastContext:
    uid = _verified_uid(authorization)
    if uid and _firebase_ready():
        try:
            firebase_rows = _load_firebase_transactions(uid)
        except Exception:
            firebase_rows = []
        if firebase_rows:
            return ForecastContext(
                data=pd.DataFrame(firebase_rows),
                source="firebase",
                uid=uid,
            )

    if REQUIRE_FIREBASE_AUTH and not uid:
        raise HTTPException(status_code=401, detail="Missing valid Firebase ID token.")

    return ForecastContext(
        data=pd.DataFrame(request.transactions),
        source="request-payload",
        uid=uid,
    )


def _firebase_ready() -> bool:
    if firebase_admin is None:
        return False
    if firebase_admin._apps:
        return True
    options = {"databaseURL": DATABASE_URL}
    try:
        if os.path.exists(SERVICE_ACCOUNT_PATH):
            cred = credentials.Certificate(SERVICE_ACCOUNT_PATH)
            firebase_admin.initialize_app(cred, options)
        else:
            firebase_admin.initialize_app(options=options)
    except Exception:
        return False
    return True


def _verified_uid(authorization: str) -> str | None:
    if not VERIFY_FIREBASE_AUTH:
        return None
    if not authorization:
        return None
    if not authorization.startswith("Bearer "):
        if not REQUIRE_FIREBASE_AUTH:
            return None
        raise HTTPException(status_code=401, detail="Invalid Authorization header.")
    if not _firebase_ready():
        if REQUIRE_FIREBASE_AUTH:
            raise HTTPException(
                status_code=500,
                detail="Firebase Admin is not configured on the forecast server.",
            )
        return None
    token = authorization.replace("Bearer ", "", 1).strip()
    try:
        decoded = auth.verify_id_token(token)
    except Exception as error:
        if not REQUIRE_FIREBASE_AUTH:
            return None
        raise HTTPException(status_code=401, detail=f"Invalid Firebase token: {error}")
    return decoded["uid"]


def _load_firebase_transactions(uid: str) -> list[dict[str, Any]]:
    snapshot = db.reference(f"users/{uid}/transactions").get() or {}
    rows: list[dict[str, Any]] = []
    for cloud_id, item in snapshot.items():
        if not isinstance(item, dict):
            continue
        row = dict(item)
        row.setdefault("cloudId", cloud_id)
        rows.append(row)
    return rows


def _normalize_transactions(raw: pd.DataFrame) -> pd.DataFrame:
    if raw.empty:
        return pd.DataFrame()

    rows: list[dict[str, Any]] = []
    for item in raw.to_dict(orient="records"):
        status = str(item.get("status", "sold")).strip().lower()
        if status and status not in {"sold", "sale", "done", "completed", "paid"}:
            continue

        fruit = _first_text(item, "fruitName", "fruit", "fruitType", "name")
        sold_at = _parse_date(item.get("soldAt") or item.get("timestamp"))
        weight_kg = _weight_kg(item)
        total_centavos = _centavos(
            item.get("totalPrice")
            or item.get("totalPriceCentavos")
            or item.get("priceCentavos")
            or item.get("price"),
            cents_when_integer=(
                "totalPrice" in item
                or "totalPriceCentavos" in item
                or "priceCentavos" in item
            ),
        )
        unit_price = _centavos(
            item.get("unitPrice")
            or item.get("pricePerKgCentavos")
            or item.get("pricePerKg"),
            cents_when_integer=("unitPrice" in item or "pricePerKgCentavos" in item),
        )
        if unit_price <= 0 and weight_kg > 0 and total_centavos > 0:
            unit_price = round(total_centavos / weight_kg)

        if not fruit or sold_at is None or weight_kg <= 0:
            continue

        rows.append(
            {
                "cloud_id": str(item.get("cloudId") or item.get("id") or ""),
                "fruit": fruit,
                "sold_at": sold_at,
                "date": sold_at.astimezone(BUSINESS_TIMEZONE).date(),
                "weight_kg": weight_kg,
                "unit_price": max(0, unit_price),
                "total_centavos": max(0, total_centavos),
                "generated": item.get("generated") is True
                or str(item.get("cloudId", "")).startswith("sample_cdo_"),
            }
        )

    return pd.DataFrame(rows)


def _data_coverage(transactions: pd.DataFrame) -> dict[str, Any]:
    if transactions.empty:
        return {
            "transactionCount": 0,
            "observedDays": 0,
            "dataStart": None,
            "dataEnd": None,
            "fruits": [],
            "calendarMonths": 0,
            "generatedTransactionCount": 0,
        }

    date_values = transactions["date"]
    fruits = sorted(transactions["fruit"].dropna().unique())
    return {
        "transactionCount": int(len(transactions)),
        "observedDays": int(date_values.nunique()),
        "dataStart": date_values.min().isoformat(),
        "dataEnd": date_values.max().isoformat(),
        "fruits": fruits,
        "calendarMonths": len({(date.year, date.month) for date in date_values}),
        "generatedTransactionCount": int(transactions["generated"].sum()),
    }


def _daily_sales_frame(transactions: pd.DataFrame) -> pd.DataFrame:
    daily = (
        transactions.groupby(["fruit", "date"], as_index=False)
        .agg(
            kg_sold=("weight_kg", "sum"),
            revenue_centavos=("total_centavos", "sum"),
            transactions=("cloud_id", "count"),
            avg_unit_price=("unit_price", "mean"),
        )
        .sort_values(["fruit", "date"])
    )
    daily["date"] = pd.to_datetime(daily["date"])
    return _fill_missing_days(daily)


def _fill_missing_days(daily: pd.DataFrame) -> pd.DataFrame:
    end = daily["date"].max()
    frames = []
    for fruit, rows in daily.groupby("fruit"):
        # Do not invent zero sales before a fruit first appears in the ledger.
        filled = rows.set_index("date").reindex(
            pd.date_range(rows["date"].min(), end, freq="D")
        )
        filled.index.name = "date"
        filled["fruit"] = fruit
        for column in ["kg_sold", "revenue_centavos", "transactions"]:
            filled[column] = filled[column].fillna(0)
        filled["avg_unit_price"] = (
            filled["avg_unit_price"].replace(0, np.nan).ffill().fillna(0)
        )
        frames.append(filled.reset_index())
    return pd.concat(frames, ignore_index=True).sort_values(["fruit", "date"])


def _training_frame(daily: pd.DataFrame) -> tuple[pd.DataFrame, dict[str, int]]:
    fruit_codes = {
        fruit: index for index, fruit in enumerate(sorted(daily["fruit"].unique()))
    }
    featured = _with_features(daily, fruit_codes)
    # Each row predicts its own date from strictly earlier sales and prices.
    featured["target_kg"] = featured["kg_sold"]
    training = featured[featured.groupby("fruit").cumcount() >= 7].copy()
    return training, fruit_codes


def _with_features(daily: pd.DataFrame, fruit_codes: dict[str, int]) -> pd.DataFrame:
    frame = daily.copy().sort_values(["fruit", "date"])
    frame["fruit_code"] = frame["fruit"].map(fruit_codes).fillna(-1)
    frame["day_of_week"] = frame["date"].dt.dayofweek
    frame["month"] = frame["date"].dt.month
    frame["quarter"] = frame["date"].dt.quarter
    angle = 2 * np.pi * (frame["date"].dt.dayofyear - 1) / 365.25
    frame["year_sin"] = np.sin(angle)
    frame["year_cos"] = np.cos(angle)
    frame["is_weekend"] = frame["day_of_week"].isin([5, 6]).astype(int)

    grouped = frame.groupby("fruit", group_keys=False)
    frame["previous_unit_price"] = grouped["avg_unit_price"].transform(
        lambda series: series.shift(1).ffill()
    )
    for window in [1, 3, 7, 14, 28]:
        frame[f"kg_last_{window}d"] = grouped["kg_sold"].transform(
            lambda series, size=window: (
                series.shift(1)
                .rolling(
                    size,
                    min_periods=1,
                )
                .sum()
            )
        )
    frame["kg_avg_7d"] = frame["kg_last_7d"] / 7
    frame["kg_same_weekday"] = grouped["kg_sold"].shift(7)
    frame["kg_last_year"] = grouped["kg_sold"].shift(365)
    frame["year_history_available"] = frame["kg_last_year"].notna().astype(int)
    frame["trend_3_vs_7"] = frame["kg_last_3d"] - (frame["kg_last_7d"] * 3 / 7)
    frame["days_since_sale"] = grouped["kg_sold"].transform(_days_since_positive)
    return MARKET_HISTORY.add_features(frame).fillna(0)


def _days_since_positive(series: pd.Series) -> pd.Series:
    distance: list[int] = []
    last_seen: int | None = None
    for index, value in enumerate(series.shift(1).fillna(0)):
        if value > 0:
            last_seen = index
            distance.append(1)
        elif last_seen is None:
            distance.append(30)
        else:
            distance.append(index - last_seen + 1)
    return pd.Series(distance, index=series.index)


def _train_model(training: pd.DataFrame):
    x_train = training[FORECAST_FEATURES].fillna(0)
    y_train = training["target_kg"].clip(lower=0)
    model = XGBRegressor(
        objective="reg:squarederror",
        tree_method="hist",
        n_estimators=180,
        learning_rate=0.05,
        max_depth=3,
        min_child_weight=4,
        reg_lambda=2.0,
        reg_alpha=0.1,
        n_jobs=2,
        random_state=42,
    )
    model.fit(x_train, y_train)
    return model


def _forecast_values(
    daily: pd.DataFrame,
    model,
    fruit_codes: dict[str, int],
    forecast_start: pd.Timestamp,
    horizon_days: int,
    model_name: str,
) -> dict[str, list[float]]:
    working = daily.copy()
    predictions_by_fruit: dict[str, list[float]] = {
        fruit: [] for fruit in sorted(daily["fruit"].unique())
    }

    forecast_end = forecast_start + pd.Timedelta(days=horizon_days - 1)
    # Bridge missing dates recursively so lag windows remain calendar days.
    for forecast_date in pd.date_range(
        daily["date"].max() + pd.Timedelta(days=1), forecast_end
    ):
        future_rows = []
        for fruit in predictions_by_fruit:
            last_price = (
                working[working["fruit"] == fruit]["avg_unit_price"]
                .replace(0, np.nan)
                .dropna()
                .tail(1)
            )
            future_rows.append(
                {
                    "fruit": fruit,
                    "date": forecast_date,
                    "kg_sold": 0,
                    "revenue_centavos": 0,
                    "transactions": 0,
                    "avg_unit_price": float(last_price.iloc[0])
                    if not last_price.empty
                    else 0,
                }
            )

        forecast_features = pd.DataFrame(future_rows)
        if model_name == "XGBRegressor":
            candidate = pd.concat([working, forecast_features], ignore_index=True)
            recent = candidate[
                candidate["date"] >= forecast_date - pd.Timedelta(days=366)
            ]
            featured = _with_features(recent, fruit_codes)
            forecast_features = featured[featured["date"] == forecast_date]
            model_values = model.predict(forecast_features[FORECAST_FEATURES])
        else:
            model_values = [
                _baseline_value(
                    working[working["fruit"] == row["fruit"]], forecast_date, model_name
                )
                for _, row in forecast_features.iterrows()
            ]
        additions = []
        for (_, row), prediction in zip(forecast_features.iterrows(), model_values):
            fruit = row["fruit"]
            prediction = max(0.0, float(prediction))
            if forecast_date >= forecast_start:
                predictions_by_fruit[fruit].append(prediction)
            additions.append(
                {
                    "fruit": fruit,
                    "date": forecast_date,
                    "kg_sold": prediction,
                    "revenue_centavos": 0,
                    "transactions": 0,
                    "avg_unit_price": row["avg_unit_price"],
                }
            )
        working = pd.concat([working, pd.DataFrame(additions)], ignore_index=True)
    return predictions_by_fruit


def _baseline_value(
    history: pd.DataFrame, date: pd.Timestamp, model_name: str
) -> float:
    if model_name == "Weekly seasonal naive":
        previous = history[history["date"] == date - pd.Timedelta(days=7)]
        if not previous.empty:
            return float(previous["kg_sold"].iloc[0])
    return float(history.tail(14)["kg_sold"].mean())


def _validate_models(daily: pd.DataFrame, horizon_days: int) -> dict[str, Any]:
    names = ["Weekly seasonal naive", "Recent average", "XGBRegressor"]
    errors: dict[str, list[float]] = {name: [] for name in names}
    actual_total = 0.0
    validation_dates = set()
    for offset in [2 * horizon_days + 1, horizon_days + 1]:
        origin = daily["date"].max() - pd.Timedelta(days=offset)
        history = daily[daily["date"] <= origin].copy()
        if history.empty or history["date"].nunique() < 14:
            continue
        training, codes = _training_frame(history)
        if len(training) < MIN_ML_ROWS:
            continue
        model = _train_model(training)
        start = origin + pd.Timedelta(days=2)
        candidate_values = {
            name: _forecast_values(history, model, codes, start, horizon_days, name)
            for name in names
        }
        for fruit in codes:
            for index in range(horizon_days):
                date = start + pd.Timedelta(days=index)
                observed = daily[(daily["fruit"] == fruit) & (daily["date"] == date)]
                if observed.empty:
                    continue
                actual = float(observed["kg_sold"].iloc[0])
                actual_total += actual
                validation_dates.add(date)
                for name in names:
                    errors[name].append(
                        abs(actual - candidate_values[name][fruit][index])
                    )
    candidates = [
        {
            "model": name,
            "maeKg": round(float(np.mean(values)), 4),
            "wapePercent": round(sum(values) / actual_total * 100, 2)
            if actual_total > 0
            else None,
        }
        for name, values in errors.items()
        if values
    ]
    selected = min(candidates, key=lambda item: item["maeKg"]) if candidates else None
    return {
        "method": "rolling-origin recursive forecast",
        "horizonDays": horizon_days,
        "evaluatedDays": len(validation_dates),
        "evaluatedFruitDays": len(errors[names[0]]),
        "selectedModel": selected["model"] if selected else "Recent average",
        "maeKg": selected["maeKg"] if selected else None,
        "wapePercent": selected["wapePercent"] if selected else None,
        "candidates": candidates,
    }


def _prediction_payload(
    fruit: str,
    daily_predictions: list[float],
    daily: pd.DataFrame,
    confidence: str,
    forecast_start: pd.Timestamp,
) -> dict[str, Any]:
    rounded_predictions = [round(float(value), 2) for value in daily_predictions]
    total = float(sum(rounded_predictions))
    tomorrow = rounded_predictions[0] if rounded_predictions else 0
    fruit_days = daily[daily["fruit"] == fruit].sort_values("date")
    baseline = (
        float(fruit_days.tail(7)["kg_sold"].mean()) if not fruit_days.empty else 0
    )
    return {
        "fruit": fruit,
        "predictedKgTomorrow": round(tomorrow, 2),
        "predictedKgTotal": round(total, 2),
        "recommendation": _recommendation(total, baseline, len(daily_predictions)),
        "confidence": confidence,
        "reason": _reason(fruit, total, baseline, confidence, len(daily_predictions))
        + _seasonal_reason(fruit, forecast_start),
        "seasonality": MARKET_HISTORY.context(fruit, forecast_start),
        "dailyPredictions": rounded_predictions,
    }


def _recommendation(
    predicted_total: float, baseline_daily: float, horizon_days: int
) -> str:
    heavy_threshold = max(5.0, baseline_daily * horizon_days * 1.25)
    medium_threshold = max(2.0, baseline_daily * horizon_days * 0.65)
    if predicted_total >= heavy_threshold:
        return "Heavy restock"
    if predicted_total >= medium_threshold:
        return "Medium restock"
    if predicted_total > 0:
        return "Light top-up"
    return "Watch"


def _reason(
    fruit: str,
    predicted_total: float,
    baseline_daily: float,
    confidence: str,
    horizon_days: int,
) -> str:
    if predicted_total <= 0:
        return f"{fruit} has no measurable recent sales signal."
    baseline = baseline_daily * horizon_days
    trend = (
        "above"
        if predicted_total > baseline * 1.1
        else "below"
        if predicted_total < baseline * 0.9
        else "near"
    )
    return (
        f"{fruit} is forecast at {predicted_total:.1f} kg over the next {horizon_days} days, "
        f"{trend} its recent baseline. Confidence is {confidence}."
    )


def _seasonal_reason(fruit: str, date: pd.Timestamp) -> str:
    supply = MARKET_HISTORY.context(fruit, date).get("supply")
    if supply is None:
        return " No historical production seasonality is available for this fruit."
    index = supply["seasonalIndex"]
    direction = "above" if index > 1.1 else "below" if index < 0.9 else "near"
    category = (
        f" General {supply['category'].lower()} context."
        if supply["usesCategoryFallback"]
        else ""
    )
    return (
        f" Historical {supply['period']} production in {supply['geography']} is {direction} "
        f"the annual average across {supply['referenceYears']} reference years.{category}"
    )


def _summary(
    predictions: list[dict[str, Any]],
    model_name: str,
    confidence: str,
    horizon_days: int,
) -> str:
    if not predictions:
        return "No forecast could be generated because there are no usable sold transactions yet."
    leaders = predictions[:3]
    leader_text = ", ".join(
        f"{item['fruit']} {item['predictedKgTotal']:.2f} kg ({item['recommendation']})"
        for item in leaders
    )
    return (
        f"Demand forecast for the next {horizon_days} days: {leader_text}. "
        f"Model: {model_name}. Confidence is {confidence}; add more sales history "
        "to make the forecast steadier."
    )


def _confidence_label(transactions: pd.DataFrame, validation: dict[str, Any]) -> str:
    error = validation["wapePercent"]
    recent_day = transactions["date"].max()
    stale_days = (datetime.now(BUSINESS_TIMEZONE).date() - recent_day).days
    per_fruit_days = transactions.groupby("fruit")["date"].nunique().min()
    if (
        transactions["generated"].any()
        or error is None
        or stale_days > 7
        or per_fruit_days < 30
    ):
        return "low"
    if validation["evaluatedDays"] >= 14 and error <= 25 and per_fruit_days >= 180:
        return "high"
    if validation["evaluatedDays"] >= 7 and error <= 50 and per_fruit_days >= 60:
        return "medium"
    return "low"


def _empty_response(
    source: str,
    model: str,
    message: str,
    data_coverage: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "summary": message,
        "source": source,
        "model": model,
        "confidence": "low",
        "dataCoverage": data_coverage
        or {
            "transactionCount": 0,
            "observedDays": 0,
            "dataStart": None,
            "dataEnd": None,
            "fruits": [],
        },
        "predictions": [],
    }


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
        return max(0, float(item["weightKg"]))
    value = item.get("weightGrams") or item.get("weight")
    if value is None:
        return 0
    amount = float(value)
    if amount > 50:
        return max(0, amount / 1000)
    return max(0, amount)


def _centavos(value: Any, *, cents_when_integer: bool = False) -> int:
    if value is None:
        return 0
    number = float(value)
    if cents_when_integer:
        return round(number)
    return round(number * 100)
