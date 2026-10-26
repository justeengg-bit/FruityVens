import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
import pandas as pd

from tool import evaluate_forecast as evaluation
from tool import forecast_server as server
from tool.fruit_categories import FRUIT_CATEGORIES


class EvaluationTests(unittest.TestCase):
    def test_error_plot_keeps_unknown_categories_visible_without_zero_error_bars(self):
        assessment = pd.DataFrame({"fruit": ["Apple"], "daily_mae_kg": [1.5], "period_mae_kg": [3.]})
        fig = evaluation.fruit_error_figure(assessment, list(FRUIT_CATEGORIES), 7)
        try:
            for ax in fig.axes:
                self.assertEqual([label.get_text() for label in ax.get_yticklabels()], list(FRUIT_CATEGORIES))
                low, high = sorted(ax.get_ylim())
                for text in ax.texts:
                    self.assertLess(low, text.get_position()[1])
                    self.assertGreater(high, text.get_position()[1])
                self.assertEqual(len(ax.texts), 22)
                self.assertTrue(np.isnan(ax.patches[-1].get_width()))
        finally:
            evaluation.plt.close(fig)

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

    def test_each_block_selects_and_trains_on_only_earlier_history(self):
        dates = pd.date_range("2026-01-01", periods=80)
        daily = pd.DataFrame({"fruit": "Apple", "date": dates, "kg_sold": 2.,
                              "avg_unit_price": 100, "revenue_centavos": 200,
                              "transactions": 1})
        training_dates, forecast_calls, selection_dates = [], [], []

        def selection(history, horizon):
            selection_dates.append(history["date"].max())
            return {"selectedModel": "Recent average", "selectedByFruit": {"Apple": "Recent average"},
                    "candidates": [{"model": "Recent average"}]}

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
        self.assertEqual(len(result), 2 * 7 * 4)
        self.assertEqual(chosen["selectedModel"], "Recent average")
        self.assertEqual(selection_dates, [dates[-16], dates[-9]])
        self.assertLess(development["date"].max(), result["date"].min())
        self.assertEqual(training_dates, [dates[-16], dates[-9]])
        self.assertTrue(all(origin == start - pd.Timedelta(days=2) for origin, start in forecast_calls))
        self.assertTrue(np.all(result["absolute_error_kg"] == 0))
        self.assertTrue((result[result["model"] == "Selected policy"]["model_used"] == "Recent average").all())

    def test_period_error_and_daily_error_answer_different_questions(self):
        rows = pd.DataFrame({"model": "Selected policy", "fruit": "Apple", "block": 1,
                             "date": pd.date_range("2026-01-01", periods=2),
                             "actual_kg": [0., 10.], "predicted_kg": [10., 0.]})
        daily = evaluation.error_metrics(rows, tolerance_kg=1)
        periods = evaluation.planning_totals(rows, 2)
        period = evaluation.error_metrics(periods, tolerance_kg=1)
        self.assertEqual(daily["mae_kg"], 10)
        self.assertEqual(daily["within_tolerance_percent"], 0)
        self.assertEqual(daily["underforecast_kg"], 10)
        self.assertEqual(daily["overforecast_kg"], 10)
        self.assertEqual(period["mae_kg"], 0)
        self.assertEqual(period["within_tolerance_percent"], 100)

    def test_vendor_assessment_does_not_certify_generated_or_incomplete_records(self):
        rows = pd.DataFrame({"model": ["Selected policy", "Recent average"],
                             "fruit": "Apple", "block": 1, "date": pd.Timestamp("2026-01-01"),
                             "actual_kg": [2., 2.], "predicted_kg": [2., 3.]})
        totals = evaluation.planning_totals(rows, 1)
        metadata = {"daily_tolerance_kg": 0.5, "period_tolerance_kg": None,
                    "target_within_tolerance_percent": 80, "generated_transactions": 2,
                    "history_complete_declared": True}
        result = evaluation.vendor_assessment(rows, totals, metadata).iloc[0]
        self.assertEqual(result["daily_within_tolerance_percent"], 100)
        self.assertEqual(result["assessment"], "Sample demonstration only")
        metadata.update(generated_transactions=0, history_complete_declared=False)
        result = evaluation.vendor_assessment(rows, totals, metadata).iloc[0]
        self.assertEqual(result["assessment"], "Confirm complete sales records first")
        metadata["history_complete_declared"] = True
        result = evaluation.vendor_assessment(rows, totals, metadata).iloc[0]
        self.assertEqual(result["assessment"], "Within chosen target on tested records")
        metadata["daily_tolerance_kg"] = None
        metadata["target_within_tolerance_percent"] = None
        result = evaluation.vendor_assessment(rows, totals, metadata).iloc[0]
        self.assertEqual(result["assessment"], "Tolerance target not specified")

    def test_later_sales_cannot_change_an_earlier_policy_choice_or_prediction(self):
        dates = pd.date_range("2026-01-01", periods=80)
        daily = pd.DataFrame({"fruit": "Apple", "date": dates, "kg_sold": 2.,
                              "avg_unit_price": 100, "revenue_centavos": 200, "transactions": 1})

        def selection(history, horizon):
            name = "XGBRegressor" if history["kg_sold"].max() > 2 else "Recent average"
            return {"selectedModel": name, "selectedByFruit": {"Apple": name}, "candidates": [{"model": name}]}

        def predict(history, model, codes, start, horizon, name):
            return {"Apple": [float(history["kg_sold"].mean())] * horizon}

        changed = daily.copy()
        changed.loc[changed["date"] >= dates[-14], "kg_sold"] = 100
        with patch.object(server, "_validate_models", side_effect=selection), \
             patch.object(server, "_train_model", return_value=object()), \
             patch.object(server, "_forecast_values", side_effect=predict):
            before, _, _ = evaluation.backtest(daily, 2, 7)
            after, _, _ = evaluation.backtest(changed, 2, 7)
        columns = ["fruit", "date", "model", "model_used", "predicted_kg"]
        pd.testing.assert_frame_equal(before[before["block"] == 1][columns], after[after["block"] == 1][columns])
        self.assertEqual(after[(after["block"] == 2) & (after["model"] == "Selected policy")]["model_used"].iloc[0], "XGBRegressor")

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
