# Sample CDO sales, July–October 2026

**Generated data. These are invented transactions, not actual Cagayan de Oro vendor sales or official 2026 observations.** At the user's request, they were imported directly into normal sales history. They contribute to the normal dashboard, analytics, reports, and forecasts and use the app's existing Firebase sync.

The [JSON asset](../assets/data/cdo_sample_sales_2026.json) and [downloadable CSV](data/cdo_sample_sales_2026.csv) contain 1,249 transactions across 101 consecutive dates, July 1–October 9, 2026. Each date has 8–19 transactions. October 9 is a partial day, ending at 2026-10-09T11:01:42+08:00. Timestamps use Manila's +08:00 offset; no transaction reaches the October 9 noon cutoff.

The scenario totals 1,865.375 kg and PHP 170,338.24. These totals describe generated sample data only.

## Category correction for the current forecast report

This is the preserved legacy nine-name source. The current application and
forecast report use 23 specific categories, with Guava excluded and the three
mango varieties kept separate. The original generic Mango labels are not enough
to identify a variety and have not been silently relabelled. After the October 9
partial day is excluded, 194 Mango transactions require category review; 1,047
other transactions are included in the corrected evaluation. See
[the current report](../reports/forecast_evaluation/revised_sample/README.md).
The source totals above therefore differ from the category-resolved report totals.

## Import into normal history

The import completed on the connected phone: 1,249 generated records were added while preserving 139 existing sales, leaving 1,388 records in normal SQLite sales history. Stable `sample_cdo_` cloud IDs identify the generated records and prevent duplicate imports or overwriting matching records. The one-time “Add July–October sales” button has been removed; the imported records remain in History. There is no separate sample mode.

After import, totals can contain both existing sales and generated records. Keep the generated-data labels and ID prefix when displaying, exporting, or synchronizing this history. A forecast based on these records is a demonstration using generated inputs, not evidence of actual demand or measured forecast accuracy. Firebase publication uses the application's existing account and sync flow; generating the asset itself does not contact Firebase.

## Historical price anchors

The generator reads the existing [bundled PSA extract](../assets/data/psa_market_history.json), dataset `psa-openstat-2010-2025-v1`, imported 2026-08-21T15:43:00.630Z. Its source is [PSA table 2M4ARA07, Fruits: Retail Prices of Agricultural Commodities](https://openstat.psa.gov.ph/PXWeb/pxweb/en/DB/DB__2M__2018/0042M4ARA07.px/). No fresh source download or verification of 2026 prices was performed.

For each fruit, the nearest available geography is selected first (city, province, region, country), followed by the extract's variety priority. The latest positive monthly price through 2025 becomes an anchor. All selected anchors are December 2025. Regional and national fallbacks retain their real geography; they are not claimed as city observations.

| Fruit | Historical variety | Historical geography | December 2025 PHP/kg |
| --- | --- | --- | ---: |
| Apple | Red Delicious | Northern Mindanao (Region X) | 137.50 |
| Banana | Latundan | Cagayan de Oro City | 60.00 |
| Grapes | Seedless | Philippines | 250.36 |
| Mango | Ripe mango | Northern Mindanao (Region X) | 146.25 |
| Orange | Sintones | Philippines | 162.33 |
| Papaya | Solo | Cagayan de Oro City | 53.67 |
| Pineapple | Hawaiian | Cagayan de Oro City | 80.50 |
| Watermelon | Pakwan | Northern Mindanao (Region X) | 46.79 |
| Calamansi | Loose | Northern Mindanao (Region X) | 70.18 |

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

The generator uses only Python's standard library, a fixed seed (20260701), and the bundled source asset. It overwrites only the JSON, CSV, and this document. Its validation checks unique sample IDs, exact totals, all daily coverage, transaction counts, fruit coverage, integer units, monotonic timestamps, business hours, timezone, and the final cutoff. Identical inputs reproduce identical output files. It does not access SQLite, Firebase, credentials, or the network.

Synthetic forecasts can illustrate charts and recommendations. They must not be presented as measured forecasting performance or evidence of actual vendor demand.
