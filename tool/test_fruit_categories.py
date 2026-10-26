import json
import re
import unittest
from pathlib import Path

import pandas as pd

from tool import forecast_server as server
from tool.fruit_categories import (
    CATEGORY_PATH, FRUIT_CATEGORIES, category_coverage, resolve_category, split_supported_sales,
)


class CategoryTests(unittest.TestCase):
    def test_app_and_python_use_the_same_23_specific_categories(self):
        root = CATEGORY_PATH.parents[2]
        dart = (root / "lib/data/fruit_categories.dart").read_text()
        self.assertEqual(re.findall(r"'([^']+)'", dart), list(FRUIT_CATEGORIES))
        self.assertEqual(len(FRUIT_CATEGORIES), 23)
        self.assertEqual(len(set(FRUIT_CATEGORIES)), 23)
        self.assertNotIn("Mango", FRUIT_CATEGORIES)
        self.assertNotIn("Guava", FRUIT_CATEGORIES)
        self.assertTrue({"Mango Carabao", "Indian Mango", "Apple Mango"}.issubset(FRUIT_CATEGORIES))
        app = (root / "lib/main.dart").read_text()
        self.assertIn("_scanReadyFruitOrder = fruitCategoryNames", app)
        self.assertIn("_scanReadyFruits = fruitCategoryNames.toSet()", app)
        catalog = app.split("_catalog = <String, FruitInfo>{", 1)[1].split("\n  };", 1)[0]
        for fruit in FRUIT_CATEGORIES:
            self.assertIn(f"'{fruit}':", catalog)
        self.assertNotIn("'Guava':", catalog)
        self.assertNotIn("'Mango':", catalog)

    def test_aliases_preserve_varieties_and_generic_mango_is_never_guessed(self):
        for label, expected in [("Carabao Mango", "Mango Carabao"),
                                ("apple_mango", "Apple Mango"), ("indian mango", "Indian Mango"),
                                ("Strawberry", "Strawberries")]:
            self.assertEqual(resolve_category(label), (expected, None))
        for label in ["Mango", "ripe mango", "Mango ripe"]:
            name, issue = resolve_category(label)
            self.assertIsNone(name)
            self.assertIn("variety unspecified", issue)
        self.assertIsNone(resolve_category("Guava")[0])

    def test_category_review_preserves_unresolved_records_and_original_input(self):
        original = pd.DataFrame({"fruit": ["Apple", "Mango", "Carabao Mango", "Guava"],
                                 "weight_kg": [1., 2., 3., 4.]})
        before = original.copy(deep=True)
        valid, issues = split_supported_sales(original)
        pd.testing.assert_frame_equal(original, before)
        self.assertEqual(valid["fruit"].tolist(), ["Apple", "Mango Carabao"])
        self.assertEqual(issues["fruit"].tolist(), ["Mango", "Guava"])
        self.assertEqual(valid["weight_kg"].sum() + issues["weight_kg"].sum(), original["weight_kg"].sum())
        self.assertEqual(valid.iloc[1]["source_fruit"], "Carabao Mango")

    def test_absent_categories_have_unknown_sales_and_error_not_fabricated_zeroes(self):
        transactions = pd.DataFrame({"fruit": ["Apple"], "date": [pd.Timestamp("2026-01-01").date()],
                                     "weight_kg": [2.], "generated": [True]})
        predictions = pd.DataFrame({"fruit": ["Apple"], "date": [pd.Timestamp("2026-01-02")],
                                    "model": ["Selected policy"]})
        coverage = category_coverage(transactions, predictions).set_index("fruit")
        self.assertEqual(len(coverage), 23)
        self.assertEqual(coverage.loc["Apple", "transaction_count"], 1)
        self.assertEqual(coverage.loc["Apple", "tested_days"], 1)
        self.assertTrue(pd.isna(coverage.loc["Indian Mango", "total_kg"]))
        self.assertEqual(coverage.loc["Indian Mango", "history_status"], "No recorded sales history")
        self.assertEqual(coverage.loc["Indian Mango", "tested_days"], 0)

    def test_api_refuses_unclassified_mango_instead_of_predicting_a_variety(self):
        result = server.forecast(server.ForecastRequest(transactions=[{
            "fruitName": "Mango", "weightKg": 2., "status": "sold",
            "soldAt": "2026-01-01T09:00:00+08:00",
        }]), authorization="")
        self.assertEqual(result["predictions"], [])
        self.assertEqual(result["dataCoverage"]["excludedUnclassifiedTransactions"], 1)
        self.assertEqual(result["dataCoverage"]["supportedCategoryCount"], 23)
        self.assertEqual(len(result["dataCoverage"]["categoriesWithoutHistory"]), 23)
        self.assertIn("Mango Carabao", result["summary"])


if __name__ == "__main__":
    unittest.main()
