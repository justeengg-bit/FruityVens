import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
import pandas as pd

from tool import evaluate_forecast as evaluation
from tool import forecast_server as server


class EvaluationTests(unittest.TestCase):
    def test_metrics_do_not_cancel_errors_and_handle_zero_actual_totals(self):
        rows = pd.DataFrame({"actual_kg": [2, 4, 0], "predicted_kg": [3, 3, 1]})
        result = evaluation.error_metrics(rows)
        self.assertEqual(result["mae_kg"], 1)
        self.assertEqual(result["wape_percent"], 50)
        self.assertAlmostEqual(result["bias_kg"], 1 / 3)
        rows["actual_kg"] = 0
        self.assertIsNone(evaluation.error_metrics(rows)["wape_percent"])

    def test_loader_excludes_partial_day_and_converts_small_gram_weights(self):
        document = {
            "kind": "synthetic_sales", "cutoff": "2026-01-03T12:00:00+08:00",
            "transactions": [
                {"fruitName": "Apple", "weightGrams": 25,
                 "soldAt": f"2026-01-0{day}T18:30:00", "status": status}
                for day, status in [(1, "Sold"), (2, "Cancelled"), (3, "Sold")]
            ],
        }
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "sales.json"
            source.write_text(json.dumps(document))
            rows, partial = evaluation.load_sales(source)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows.iloc[0]["weight_kg"], 0.025)
            self.assertEqual(str(rows.iloc[0]["date"]), "2026-01-01")
            self.assertTrue(rows.iloc[0]["generated"])
            self.assertEqual(str(partial), "2026-01-03")
            with self.assertRaisesRegex(ValueError, "No completed transactions"):
                evaluation.load_sales(source, exclude_generated=True)

    def test_each_block_uses_only_earlier_history_and_keeps_selection_separate(self):
        dates = pd.date_range("2026-01-01", periods=80)
        daily = pd.DataFrame({"fruit": "Apple", "date": dates, "kg_sold": 2.,
                              "avg_unit_price": 100, "revenue_centavos": 200,
                              "transactions": 1})
        training_dates, forecast_calls, selection_dates = [], [], []

        def selection(history, horizon):
            selection_dates.append(history["date"].max())
            return {"selectedModel": "Recent average", "candidates": [{"model": "Recent average"}]}

        def train(history):
            training_dates.append(history["date"].max())
            return object()

        def predict(history, model, codes, start, horizon, name):
            forecast_calls.append((history["date"].max(), start))
            return {fruit: [2.] * horizon for fruit in codes}

        with patch.object(server, "_validate_models", side_effect=selection), \
             patch.object(server, "_train_model", side_effect=train), \
             patch.object(server, "_forecast_values", side_effect=predict):
            result, development, chosen = evaluation.backtest(daily, 2, 7)
        self.assertEqual(len(result), 2 * 7 * 3)
        self.assertEqual(chosen["selectedModel"], "Recent average")
        self.assertEqual(selection_dates, [dates[-16]])
        self.assertLess(development["date"].max(), result["date"].min())
        self.assertEqual(training_dates, [dates[-16], dates[-9]])
        self.assertTrue(all(origin == start - pd.Timedelta(days=2) for origin, start in forecast_calls))
        self.assertTrue(np.all(result["absolute_error_kg"] == 0))

    def test_generated_prefix_is_preserved_when_reading_csv(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "sales.csv"
            pd.DataFrame([
                {"cloudId": "sample_cdo_one", "fruitName": "Banana",
                 "weightGrams": 50, "soldAt": "2026-01-01T08:00:00+08:00",
                 "status": "sold", "totalPrice": 100},
                {"cloudId": "recorded_two", "fruitName": "Banana",
                 "weightGrams": 100, "soldAt": "2026-01-01T09:00:00+08:00",
                 "status": "sold", "totalPrice": 200},
            ]).to_csv(source, index=False)
            rows, _ = evaluation.load_sales(source)
            self.assertEqual(int(rows["generated"].sum()), 1)
            rows, _ = evaluation.load_sales(source, exclude_generated=True)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows.iloc[0]["weight_kg"], 0.1)


if __name__ == "__main__":
    unittest.main()
