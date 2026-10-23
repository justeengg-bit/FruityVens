# FruityVens sales analysis and forecast evaluation

**GENERATED SAMPLE SALES — demonstration only; not measured real-world forecasting accuracy.**

Input: `/home/marzomir/Documents/FruityVens/assets/data/cdo_sample_sales_2026.json`. Closed sales dates: 2026-07-01 through 2026-10-08.
Transactions: 1,241; generated: 1,241.
Partial day excluded: 2026-10-09.

## Chronological test design

The first development period ends 2026-09-09. The service chooses a method
separately for each fruit using up to four earlier forecast windows and lowest daily MAE.
The initial choice is **Per-fruit selection**.
The later test period runs 2026-09-11 through 2026-10-08,
with 4 successive 7-day blocks. Each block trains on
records ending two calendar days before the first forecast date, reproducing the app's one-day
incomplete-ledger bridge. The bridge is predicted recursively and not scored. The model is refit
before later blocks using only data available at that block's origin; no actual sale within its
forecast horizon is supplied back as an input. This is rolling operational evaluation, not one
single 28-day-ahead forecast.

All methods score the same 252 fruit-days. **Selected policy** is the
system's actual procedure: choose the method for each fruit using only records available before
each block, then score it on the later sales. Earlier test-block sales can enter training and
selection for later blocks once they would have become available. They never enter an earlier
forecast. The policy is not a fourth machine learning model. Fixed candidate scores remain visible.
Default XGBoost parameters are reused; no tuning uses the upcoming block. Previously examined
datasets cannot serve as fresh confirmatory experiments. The bundled generated sample has already
been examined during development and remains a demonstration.

## Comparison on the test periods

| Method | MAE (kg/fruit/day) | RMSE (kg/fruit/day) | WAPE | Bias (kg/fruit/day) |
| --- | ---: | ---: | ---: | ---: |
| Weekly seasonal naive | 1.764 | 2.515 | 94.85% | -0.004 |
| Recent average | 1.535 | 2.063 | 82.51% | +0.011 |
| XGBRegressor | 1.599 | 2.132 | 85.98% | +0.036 |
| Selected policy | 1.528 | 2.069 | 82.16% | -0.083 |

MAE = mean absolute prediction error. RMSE emphasizes larger misses.
WAPE = sum of absolute errors / total actual kilograms × 100; it is undefined when total actual sales
are zero. Bias = mean(prediction − actual); positive means overforecasting. WAPE is an error
percentage, not classification accuracy. Do not report 100 − WAPE as a generic accuracy score.

## Quantities over a planning period

The period is **7 days**. There are
36 complete fruit-periods per method. These errors first sum
sales within each fruit/period, then compare totals; they differ from averaging daily errors.

| Method | MAE (kg/fruit/period) | WAPE of period totals | Total underforecast (kg) | Total overforecast (kg) |
| --- | ---: | ---: | ---: | ---: |
| Recent average | 5.456 | 41.90% | 96.795 | 99.607 |
| Selected policy | 5.246 | 40.29% | 104.898 | 83.967 |
| Weekly seasonal naive | 6.010 | 46.16% | 108.750 | 107.625 |
| XGBRegressor | 5.633 | 43.26% | 96.897 | 105.877 |

Underforecast and overforecast compare predictions with recorded sales. They are **not measured
stockouts, lost sales, leftover stock, or spoilage**. Those outcomes require stock and operational
records. Daily errors must still be checked because fruit is perishable and the timing matters.

## What a vendor can assess

| Fruit | Daily MAE (kg) | Period MAE (kg) | Daily improvement vs recent average | Days within tolerance | Periods within tolerance | Evidence status |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Apple | 1.356 | 5.035 | -5.03% | Not assessed | Not assessed | Sample demonstration only |
| Banana | 2.246 | 6.985 | 0.00% | Not assessed | Not assessed | Sample demonstration only |
| Calamansi | 0.621 | 1.768 | -2.47% | Not assessed | Not assessed | Sample demonstration only |
| Grapes | 0.590 | 1.205 | 0.00% | Not assessed | Not assessed | Sample demonstration only |
| Mango | 1.652 | 5.729 | 2.69% | Not assessed | Not assessed | Sample demonstration only |
| Orange | 1.056 | 3.836 | 0.00% | Not assessed | Not assessed | Sample demonstration only |
| Papaya | 1.394 | 4.022 | 0.00% | Not assessed | Not assessed | Sample demonstration only |
| Pineapple | 1.615 | 2.455 | 5.44% | Not assessed | Not assessed | Sample demonstration only |
| Watermelon | 3.225 | 16.181 | 0.00% | Not assessed | Not assessed | Sample demonstration only |

Positive improvement means the selected procedure beat the recent-average baseline on the same
fruit-days; negative means it did worse. Zero baseline error makes the percentage undefined.
Daily tolerance: **Not assessed**;
period-total tolerance: **Not assessed**;
required share within tolerance: **Not assessed**.
These limits must be chosen with the vendor before checking the final evaluation. No universal
acceptable percentage is assumed. Meeting a chosen target on these records does not guarantee
future performance. The current app supplies fruit prices but no usable stock quantities, so
forecasts describe expected sales and do not calculate an order quantity.

## Interpretation and limits

The sales-history plots are exploratory and do not measure forecast accuracy. The learning curve
is a separate one-day-ahead development diagnostic; it uses observed earlier validation-day sales
as lag features. It must not be confused with the recursive seven-day test results. Historical
seasonality comes from the same bundled PSA features as the production server. Missing dates
after a fruit's introduction are assumed to have zero recorded sales, as in the app. Closures,
stockouts, and missing uploads cannot be distinguished from zero demand. The target is recorded
sales, not unconstrained customer demand. Fruits absent from a block's training history are not
evaluated in that block. History declared complete: False.
Assumed zero fruit-days: 251. Results from generated records demonstrate the pipeline, not measured
real-world vendor performance. No phone, Firebase, or hosted-service records were read or changed.

## Files

- `index.html`: local visual report; open in any browser.
- `all_figures.pdf`: all 11 figures in one document.
- `predictions.csv`: every model/date/fruit prediction, actual, signed error, and absolute error.
- `actual_vs_predicted.csv`: actual kilograms, the three candidate forecasts, and the selected policy.
- `model_metrics.csv`, `fruit_metrics.csv`, `block_metrics.csv`, `horizon_metrics.csv`: error tables.
- `period_predictions.csv`, `period_metrics.csv`, `fruit_period_metrics.csv`: total quantities and errors per planning period.
- `vendor_assessment.csv`: per-fruit baseline comparison and chosen tolerance checks.
- `selection_history.csv`: the method chosen before each fruit's test block.
- `daily_sales.csv`: daily kilograms, revenue in centavos, transaction counts, and price per fruit.
- `learning_curve.csv`: training and development-validation MAE by boosting round.
- `development_selection.json`: initial per-fruit choices using earlier validation records.
- `run_metadata.json`: source hashes, dates, parameters, and library versions.

## Figures

### Daily sales and revenue

![Daily sales and revenue](01_daily_sales.png)

Completed transactions only. Weight and revenue are separate measures; the trailing average summarizes past sales.

[PDF](01_daily_sales.pdf)

### Sales trends by fruit

![Sales trends by fruit](02_fruit_trends.png)

Each line is a seven-day trailing average, not a fitted forecast or proof of annual seasonality.

[PDF](02_fruit_trends.pdf)

### Distribution of sales quantities

![Distribution of sales quantities](03_sales_distribution.png)

Left: daily fruit sales, including assumed zero-sale dates. Right: basket weights from individual transactions.

[PDF](03_sales_distribution.pdf)

### Average sales by day of week

![Average sales by day of week](04_weekday_sales.png)

An exploratory summary of the available period; differences do not establish a causal weekday effect.

[PDF](04_weekday_sales.pdf)

### Forecast errors on later test periods

![Forecast errors on later test periods](05_model_comparison.png)

All methods predict the same fruit-days over 7-day blocks. Selected policy chooses a method per fruit using earlier sales only. Scores use unrounded predictions.

[PDF](05_model_comparison.pdf)

### Actual versus predicted sales by fruit

![Actual versus predicted sales by fruit](06_actual_vs_predicted.png)

Dotted boundaries mark new 7-day forecast blocks. Selection and training use only earlier sales; actual sales within a block never become forecast inputs. Reference actuals are sample values when the dataset is generated.

[PDF](06_actual_vs_predicted.pdf)

### Training and validation MAE versus boosting rounds

![Training and validation MAE versus boosting rounds](07_learning_curve.png)

One-day-ahead diagnostic: validation features use earlier observed sales. This is not the recursive seven-day test score; the final test period is excluded entirely.

[PDF](07_learning_curve.pdf)

### XGBoost agreement and error distribution

![XGBoost agreement and error distribution](08_prediction_errors.png)

A point near the diagonal indicates close agreement. Signed errors show the direction of misses; opposite errors do not cancel in MAE or WAPE.

[PDF](08_prediction_errors.pdf)

### Actual and predicted 7-day sales totals

![Actual and predicted 7-day sales totals](09_period_sales.png)

Totals are calculated separately for each fruit and forecast block. Good agreement here can hide errors in daily timing; read alongside the daily plots. These are sales quantities, not recommended purchase quantities.

[PDF](09_period_sales.pdf)

### Selected forecasting policy: errors by fruit

![Selected forecasting policy: errors by fruit](10_fruit_errors.png)

Each bar measures later errors after choosing the method on earlier history. Lower is better; an acceptable error depends on the vendor's quantities, replenishment timing, and costs.

[PDF](10_fruit_errors.pdf)

### Forecast error by distance into the future

![Forecast error by distance into the future](11_horizon_errors.png)

Compare the requested forecast days on the same test blocks. A predicted bridge day precedes day 1 because the current day's ledger is incomplete. A longer horizon need not have monotonically increasing errors.

[PDF](11_horizon_errors.pdf)
