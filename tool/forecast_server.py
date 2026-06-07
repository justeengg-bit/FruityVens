"""FruityVens Gradient Boosting forecast server.

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
from datetime import datetime, timedelta, timezone
from typing import Any

import numpy as np
import pandas as pd
from fastapi import FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from sklearn.ensemble import GradientBoostingRegressor, HistGradientBoostingRegressor

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
MIN_ML_ROWS = int(os.getenv("FRUITYVENS_FORECAST_MIN_ML_ROWS", "8"))
LARGE_DATASET_ROWS = int(os.getenv("FRUITYVENS_FORECAST_HIST_ROWS", "10000"))
FORECAST_FEATURES = [
    "fruit_code",
    "day_of_week",
    "month",
    "is_weekend",
    "avg_unit_price",
    "transactions",
    "revenue_centavos",
    "kg_last_1d",
    "kg_last_3d",
    "kg_last_7d",
    "kg_last_14d",
    "kg_avg_7d",
    "trend_3_vs_7",
    "days_since_sale",
]


app = FastAPI(title="FruityVens Gradient Boosting Forecast Server")
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
        "engine": "GradientBoostingRegressor",
        "firebaseAdmin": _firebase_ready(),
        "requiresFirebaseAuth": REQUIRE_FIREBASE_AUTH,
    }


@app.post("/forecast")
def forecast(
    request: ForecastRequest,
    authorization: str = Header(default=""),
) -> dict[str, Any]:
    context = _forecast_context(request, authorization)
    transactions = _normalize_transactions(context.data)
    if transactions.empty:
        return _empty_response(
            source="Gradient Boosting Regression",
            model="insufficient-data",
            message="No sold transactions are available for forecasting yet.",
        )

    daily = _daily_sales_frame(transactions)
    training, fruit_codes = _training_frame(daily)
    confidence = _confidence_label(
        transaction_count=len(transactions),
        observed_days=daily["date"].nunique(),
    )

    if len(training) >= MIN_ML_ROWS:
        model, model_name = _train_model(training)
        predictions = _predict_horizon(
            daily=daily,
            model=model,
            fruit_codes=fruit_codes,
            horizon_days=request.horizon_days,
            confidence=confidence,
        )
    else:
        model_name = "weighted-sales-velocity fallback"
        predictions = _velocity_fallback(
            daily=daily,
            horizon_days=request.horizon_days,
            confidence="low",
        )

    predictions = sorted(
        predictions,
        key=lambda item: item["predictedKgTotal"],
        reverse=True,
    )
    summary = _summary(predictions, model_name=model_name, confidence=confidence)

    return {
        "summary": summary,
        "source": "FruityVens ML Forecast Server",
        "model": model_name,
        "uid": context.uid,
        "dataSource": context.source,
        "horizonDays": request.horizon_days,
        "confidence": confidence,
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
        if status and status not in {"sold", "sale"}:
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
            cents_when_integer=(
                "unitPrice" in item or "pricePerKgCentavos" in item
            ),
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
                "date": sold_at.date(),
                "weight_kg": weight_kg,
                "unit_price": max(0, unit_price),
                "total_centavos": max(0, total_centavos),
            }
        )

    return pd.DataFrame(rows)


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
    fruits = sorted(daily["fruit"].dropna().unique())
    start = daily["date"].min()
    end = daily["date"].max()
    full_index = pd.MultiIndex.from_product(
        [fruits, pd.date_range(start, end, freq="D")],
        names=["fruit", "date"],
    )
    filled = (
        daily.set_index(["fruit", "date"])
        .reindex(full_index)
        .reset_index()
        .sort_values(["fruit", "date"])
    )
    for column in ["kg_sold", "revenue_centavos", "transactions"]:
        filled[column] = filled[column].fillna(0)
    filled["avg_unit_price"] = (
        filled.groupby("fruit")["avg_unit_price"]
        .ffill()
        .bfill()
        .fillna(0)
    )
    return filled


def _training_frame(daily: pd.DataFrame) -> tuple[pd.DataFrame, dict[str, int]]:
    fruit_codes = {fruit: index for index, fruit in enumerate(sorted(daily["fruit"].unique()))}
    featured = _with_features(daily, fruit_codes)
    featured["target_next_day_kg"] = featured.groupby("fruit")["kg_sold"].shift(-1)
    training = featured.dropna(subset=["target_next_day_kg"]).copy()
    return training, fruit_codes


def _with_features(daily: pd.DataFrame, fruit_codes: dict[str, int]) -> pd.DataFrame:
    frame = daily.copy().sort_values(["fruit", "date"])
    frame["fruit_code"] = frame["fruit"].map(fruit_codes).fillna(-1)
    frame["day_of_week"] = frame["date"].dt.dayofweek
    frame["month"] = frame["date"].dt.month
    frame["is_weekend"] = frame["day_of_week"].isin([5, 6]).astype(int)

    grouped = frame.groupby("fruit", group_keys=False)
    for window in [1, 3, 7, 14]:
        frame[f"kg_last_{window}d"] = grouped["kg_sold"].transform(
            lambda series, size=window: series.shift(1).rolling(
                size,
                min_periods=1,
            ).sum()
        )
    frame["kg_avg_7d"] = frame["kg_last_7d"] / 7
    frame["trend_3_vs_7"] = frame["kg_last_3d"] - (frame["kg_last_7d"] * 3 / 7)
    frame["days_since_sale"] = grouped["kg_sold"].transform(_days_since_positive)
    return frame.fillna(0)


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
    y_train = training["target_next_day_kg"].clip(lower=0)
    if len(training) >= LARGE_DATASET_ROWS:
        model = HistGradientBoostingRegressor(
            max_iter=350,
            learning_rate=0.05,
            max_leaf_nodes=31,
            l2_regularization=0.02,
            random_state=42,
        )
        model_name = "HistGradientBoostingRegressor"
    else:
        model = GradientBoostingRegressor(
            n_estimators=260,
            learning_rate=0.05,
            max_depth=3,
            min_samples_split=4,
            loss="squared_error",
            random_state=42,
        )
        model_name = "GradientBoostingRegressor"
    model.fit(x_train, y_train)
    return model, model_name


def _predict_horizon(
    daily: pd.DataFrame,
    model,
    fruit_codes: dict[str, int],
    horizon_days: int,
    confidence: str,
) -> list[dict[str, Any]]:
    working = daily.copy()
    today = pd.Timestamp(datetime.now(timezone.utc).date())
    predictions_by_fruit: dict[str, list[float]] = {
        fruit: [] for fruit in sorted(daily["fruit"].unique())
    }

    for offset in range(1, horizon_days + 1):
        forecast_date = today + pd.Timedelta(days=offset)
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
                    "avg_unit_price": float(last_price.iloc[0]) if not last_price.empty else 0,
                }
            )

        candidate = pd.concat([working, pd.DataFrame(future_rows)], ignore_index=True)
        featured = _with_features(candidate, fruit_codes)
        forecast_features = featured[featured["date"] == forecast_date]
        for _, row in forecast_features.iterrows():
            fruit = row["fruit"]
            feature_row = pd.DataFrame(
                [row[FORECAST_FEATURES].to_dict()],
                columns=FORECAST_FEATURES,
            ).fillna(0)
            prediction = float(model.predict(feature_row)[0])
            prediction = max(0, prediction)
            predictions_by_fruit[fruit].append(prediction)
            working = pd.concat(
                [
                    working,
                    pd.DataFrame(
                        [
                            {
                                "fruit": fruit,
                                "date": forecast_date,
                                "kg_sold": prediction,
                                "revenue_centavos": 0,
                                "transactions": 0,
                                "avg_unit_price": row["avg_unit_price"],
                            }
                        ]
                    ),
                ],
                ignore_index=True,
            )

    return [
        _prediction_payload(
            fruit=fruit,
            daily_predictions=values,
            daily=daily,
            confidence=confidence,
        )
        for fruit, values in predictions_by_fruit.items()
    ]


def _velocity_fallback(
    daily: pd.DataFrame,
    horizon_days: int,
    confidence: str,
) -> list[dict[str, Any]]:
    predictions = []
    for fruit in sorted(daily["fruit"].unique()):
        fruit_days = daily[daily["fruit"] == fruit].sort_values("date")
        recent = fruit_days.tail(7)
        recent_weights = recent["kg_sold"].to_numpy(dtype=float)
        if len(recent_weights) == 0:
            daily_average = 0
        else:
            weights = np.linspace(0.7, 1.3, len(recent_weights))
            daily_average = float(np.average(recent_weights, weights=weights))
        pattern = [0.92, 1.00, 1.06, 1.02, 1.12, 1.18, 1.08]
        daily_predictions = [
            max(0, daily_average * pattern[index % len(pattern)])
            for index in range(horizon_days)
        ]
        predictions.append(
            _prediction_payload(
                fruit=fruit,
                daily_predictions=daily_predictions,
                daily=daily,
                confidence=confidence,
            )
        )
    return predictions


def _prediction_payload(
    fruit: str,
    daily_predictions: list[float],
    daily: pd.DataFrame,
    confidence: str,
) -> dict[str, Any]:
    total = float(sum(daily_predictions))
    tomorrow = float(daily_predictions[0]) if daily_predictions else 0
    fruit_days = daily[daily["fruit"] == fruit].sort_values("date")
    baseline = float(fruit_days.tail(7)["kg_sold"].mean()) if not fruit_days.empty else 0
    return {
        "fruit": fruit,
        "predictedKgTomorrow": round(tomorrow, 2),
        "predictedKgTotal": round(total, 2),
        "recommendation": _recommendation(total, baseline),
        "confidence": confidence,
        "reason": _reason(fruit, total, baseline, confidence),
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


def _reason(fruit: str, predicted_total: float, baseline_daily: float, confidence: str) -> str:
    if predicted_total <= 0:
        return f"{fruit} has no measurable recent sales signal."
    trend = "above" if predicted_total > baseline_daily * 7 else "near"
    return (
        f"{fruit} is forecast at {predicted_total:.1f} kg over the next 7 days, "
        f"{trend} its recent baseline. Confidence is {confidence}."
    )


def _summary(predictions: list[dict[str, Any]], model_name: str, confidence: str) -> str:
    if not predictions:
        return "No forecast could be generated because there are no usable sold transactions yet."
    leaders = predictions[:3]
    leader_text = ", ".join(
        f"{item['fruit']} {item['predictedKgTotal']:.2f} kg ({item['recommendation']})"
        for item in leaders
    )
    return (
        f"Gradient Boosting forecast for the next 7 days: {leader_text}. "
        f"Model: {model_name}. Confidence is {confidence}; add more sales history "
        "to make the forecast steadier."
    )


def _confidence_label(transaction_count: int, observed_days: int) -> str:
    if transaction_count >= 50 and observed_days >= 14:
        return "high"
    if transaction_count >= 15 and observed_days >= 5:
        return "medium"
    return "low"


def _empty_response(source: str, model: str, message: str) -> dict[str, Any]:
    return {
        "summary": message,
        "source": source,
        "model": model,
        "confidence": "low",
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
