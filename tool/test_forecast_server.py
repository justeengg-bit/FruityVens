import unittest
from datetime import datetime, timedelta
from unittest.mock import patch

import numpy as np
import pandas as pd
from pandas.testing import assert_series_equal
from xgboost import XGBRegressor

from tool import forecast_server as server
from tool.forecast_seasonality import SeasonalMarketHistory


def sales(days=60, end=None):
    end = end or datetime.now(server.BUSINESS_TIMEZONE).date() - timedelta(days=1)
    return [
        {
            "cloudId": f"sale_{index}",
            "fruitName": "Watermelon",
            "weightKg": 2.0,
            "totalPriceCentavos": 10000,
            "soldAt": (end - timedelta(days=days - index - 1)).isoformat(),
            "status": "Sold",
        }
        for index in range(days)
    ]


def market_records():
    records = []
    for year in range(2018, 2027):
        for quarter, weight in enumerate([10, 40, 20, 10], start=1):
            records.append(
                {
                    "seriesKey": "mango-region",
                    "fruitName": "Mango",
                    "metric": "production_volume",
                    "geography": "Northern Mindanao (Region X)",
                    "geographyLevel": "region",
                    "seriesPriority": 0,
                    "periodGranularity": "quarter",
                    "periodStart": f"{year}-{quarter * 3 - 2:02d}-01",
                    "value": weight if year <= 2023 else weight * 1000,
                    "sourceTable": "PSA production",
                    "sourceUrl": "https://example.test/psa",
                }
            )
    return records


class ForecastTests(unittest.TestCase):
    def test_target_day_uses_only_earlier_sales_and_prices(self):
        daily = server._daily_sales_frame(
            server._normalize_transactions(pd.DataFrame(sales()))
        )
        codes = {"Watermelon": 0}
        before = server._with_features(daily, codes)
        row = daily.index[-2]
        changed = daily.copy()
        changed.loc[
            row, ["kg_sold", "avg_unit_price", "transactions", "revenue_centavos"]
        ] = 99999
        after = server._with_features(changed, codes)
        assert_series_equal(
            before.loc[row, server.FORECAST_FEATURES],
            after.loc[row, server.FORECAST_FEATURES],
        )
        self.assertEqual(after.iloc[-1]["kg_last_1d"], 99999)
        training, _ = server._training_frame(daily)
        self.assertTrue((training["target_kg"] == training["kg_sold"]).all())

    def test_fill_does_not_create_pre_introduction_history(self):
        transactions = sales(40)
        transactions[-1] = {**transactions[-1], "fruitName": "Mango"}
        daily = server._daily_sales_frame(
            server._normalize_transactions(pd.DataFrame(transactions))
        )
        self.assertEqual(len(daily[daily["fruit"] == "Mango"]), 1)

    def test_xgboost_model_can_fit_causal_features(self):
        daily = server._daily_sales_frame(
            server._normalize_transactions(pd.DataFrame(sales()))
        )
        training, _ = server._training_frame(daily)
        model = server._train_model(training)
        self.assertIsInstance(model, XGBRegressor)
        self.assertTrue(
            np.isfinite(model.predict(training[server.FORECAST_FEATURES])).all()
        )

    def test_validation_keeps_future_dates_out_and_selects_better_baseline(self):
        daily = server._daily_sales_frame(
            server._normalize_transactions(pd.DataFrame(sales()))
        )
        seen_dates = []

        class BadModel:
            def predict(self, rows):
                return np.zeros(len(rows))

        def train(rows):
            seen_dates.append(rows["date"].max())
            return BadModel()

        with patch.object(server, "_train_model", side_effect=train):
            result = server._validate_models(daily, 7)
        self.assertEqual(
            seen_dates,
            [
                daily["date"].max() - pd.Timedelta(days=15),
                daily["date"].max() - pd.Timedelta(days=8),
            ],
        )
        self.assertEqual(result["selectedModel"], "Weekly seasonal naive")
        self.assertEqual(result["evaluatedDays"], 14)
        self.assertEqual(result["maeKg"], 0)

    def test_recursive_forecast_bridges_dates_and_uses_target_calendar(self):
        daily = server._daily_sales_frame(
            server._normalize_transactions(
                pd.DataFrame(sales(end=pd.Timestamp("2026-01-30").date()))
            )
        )
        observed_months = []

        class Model:
            def predict(self, rows):
                observed_months.append(int(rows["month"].iloc[0]))
                return rows["kg_last_1d"].to_numpy() + 1

        result = server._forecast_values(
            daily,
            Model(),
            {"Watermelon": 0},
            pd.Timestamp("2026-02-01"),
            2,
            "XGBRegressor",
        )
        self.assertEqual(result["Watermelon"], [4, 5])
        self.assertEqual(observed_months, [1, 2, 2])

    def test_endpoint_preserves_horizon_and_excludes_unapproved_or_incomplete_sales(
        self,
    ):
        rows = [{**item, "generated": True} for item in sales(45)]
        today = datetime.now(server.BUSINESS_TIMEZONE).date()
        for status in ["Pending", "Cancelled", "Removed"]:
            rows.append({**rows[0], "status": status, "weightKg": 999})
        rows.extend(
            [
                {**rows[0], "soldAt": today.isoformat()},
                {**rows[0], "soldAt": (today + timedelta(days=10)).isoformat()},
            ]
        )
        result = server.forecast(
            server.ForecastRequest(transactions=rows, horizon_days=3), authorization=""
        )
        self.assertEqual(result["dataCoverage"]["transactionCount"], 45)
        self.assertEqual(result["dataCoverage"]["generatedTransactionCount"], 45)
        self.assertEqual(result["confidence"], "low")
        self.assertEqual(
            result["forecastStart"], (today + timedelta(days=1)).isoformat()
        )
        self.assertEqual(result["forecastEnd"], (today + timedelta(days=3)).isoformat())
        self.assertEqual(len(result["predictions"][0]["dailyPredictions"]), 3)
        self.assertIn("3 days", result["predictions"][0]["reason"])
        self.assertIn("supply", result["predictions"][0]["seasonality"])

    def test_utc_sale_is_assigned_to_manila_business_day(self):
        rows = server._normalize_transactions(
            pd.DataFrame([{**sales(1)[0], "soldAt": "2026-01-31T18:00:00Z"}])
        )
        self.assertEqual(rows.iloc[0]["date"].isoformat(), "2026-02-01")


class SeasonalityTests(unittest.TestCase):
    def test_complete_prior_years_define_seasonal_supply_without_future_data(self):
        history = SeasonalMarketHistory(market_records(), "fixture")
        result = history.context("Mango", pd.Timestamp("2025-05-01"))["supply"]
        self.assertEqual(result["seasonalIndex"], 2.0)
        self.assertEqual(result["referenceYears"], 6)
        self.assertEqual(result["dataEnd"], "2023-10-01")
        self.assertEqual(result["period"], "Q2")

    def test_variant_fallback_is_explicit_and_unknown_fruit_has_no_signal(self):
        history = SeasonalMarketHistory(market_records())
        supply = history.context("Apple Mango", pd.Timestamp("2025-05-01"))["supply"]
        self.assertTrue(supply["usesCategoryFallback"])
        self.assertEqual(supply["category"], "Mango")
        features = history.features("Unknown", pd.Timestamp("2025-05-01"))
        self.assertEqual(features["market_supply_available"], 0)
        self.assertEqual(features["market_supply_index"], 1)


if __name__ == "__main__":
    unittest.main()
