# View sales and forecast graphs locally

The evaluation is separate from Flutter and the hosted service. It reads a local
transaction file, reuses `tool/forecast_server.py`, and writes static research
figures and CSV tables. It never calls Firebase or the forecast endpoint.

From the FruityVens project root:

```sh
uv venv .venv-evaluation --python /home/marzomir/.local/bin/python3.14
uv pip install --python .venv-evaluation/bin/python -r requirements-evaluation.txt
.venv-evaluation/bin/python -m tool.evaluate_forecast
```

On another computer, select your installed Python 3.10+ interpreter when creating
the environment. The separate environment avoids changing the app's Python setup.

Open `reports/forecast_evaluation/revised_sample/README.md` with VS Code's Markdown Preview
(Ctrl+Shift+V), or open `index.html` in a browser. PNGs open directly in VS Code.
Each figure is saved at 300 DPI and as a vector PDF. `all_figures.pdf` collects them.
The earlier `sample/` report is retained for comparison. For the practical meaning
of the results, read [evaluating usefulness for vendors](vendor_forecast_evaluation.md).

## Included figures

1. Daily total kilograms and revenue, with trailing seven-day averages.
2. Seven-day sales trends for every fruit.
3. Daily sales and transaction-weight distributions, including zero-sale fruit-days.
4. Average kilograms sold by weekday.
5. Test MAE and WAPE comparison of XGBoost, previous week, recent average, and the selected policy.
6. Actual versus predicted daily kilograms for every fruit.
7. XGBoost training/development-validation MAE versus boosting rounds.
8. XGBoost actual/predicted scatter and signed-error histogram.
9. Actual and predicted total kilograms per fruit and forecast period.
10. Selected policy's daily and period-total MAE by fruit.
11. Daily MAE by requested forecast day for all methods.

## Evaluation design

Default: reserve the last four complete weeks for evaluation in four successive
seven-day blocks. For every block, the server selects a method separately for
each fruit using up to four earlier validation windows and lowest daily MAE.
The chosen method is then tested on the upcoming sales. The **Selected policy**
series evaluates this procedure, while fixed candidate results remain available.
Choices are saved in `selection_history.csv`. Models refit at each block using
only records available before that forecast. Earlier test-block sales may enter
later training/selection after they become available; upcoming sales cannot.
A one-day recursive bridge reproduces the app's incomplete-today convention.
Actual values inside a forecast block never become recursive prediction inputs.
No hyperparameters are optimized against the final test scores.

The learning curve is a different diagnostic: MAE after each of 180 boosting
rounds on earlier training and later development-validation rows. It uses
observed earlier-day lags, so it represents one-day-ahead learning, not the
recursive seven-day test. This distinction is printed in the figure caption.
Logging uses XGBoost's `eval_set` and `evals_result()` interfaces described in the
[official API](https://xgboost.readthedocs.io/en/stable/python/python_api.html#xgboost.XGBRegressor).
[Matplotlib](https://matplotlib.org/stable/api/_as_gen/matplotlib.figure.Figure.savefig.html)
exports the PNG and PDF figures.

Metrics are MAE, RMSE, WAPE, signed bias (prediction minus actual), and separate
underforecast/overforecast totals. These are
errors, not a classification accuracy percentage. The report contains per-fruit,
per-block, and per-horizon tables plus every raw prediction. File hashes, library
versions, parameters, dates, and sample provenance are saved in run metadata.
Period errors first aggregate actual/predicted kilograms for each fruit and block.
They are not the same as averaging daily errors within a block. Timing errors can
cancel in a period total, so both levels are reported. Forecast errors do not
measure actual spoilage or lost sales.

## Vendor-chosen tolerances

No generic "good accuracy" percentage is assumed. Optional CLI arguments are
`--daily-tolerance-kg`, `--period-tolerance-kg`, and
`--target-within-tolerance-percent`. Agree on these with the vendor before final
testing. For example, a vendor might choose 0.5 kg daily error and require 80%
of forecasts to fall within it; these are illustrative choices, not defaults or
validated industry thresholds. Tolerance pass rates appear in `vendor_assessment.csv`
and the local report. Omitted criteria remain "Not assessed".

Use `--history-complete` only after verifying the daily ledger. It is a declaration,
not an automatic audit. Generated data always remains "Sample demonstration only".
Even a real-data backtest meeting chosen tolerances is not a guarantee of future
performance; preserve future operating periods for prospective evaluation.

## Input and provenance

The default bundled dataset is **generated**, not real vendor sales. Its October 9
partial day is excluded; July 1–October 8 are complete scenario dates. Resulting
figures demonstrate the method and cannot establish real-world vendor accuracy.
Daily gaps after a fruit's first sale follow the production zero-sales assumption;
closed days, missing records, and stockouts cannot currently be distinguished.

For a local transaction export:

```sh
.venv-evaluation/bin/python -m tool.evaluate_forecast \
  --input /absolute/path/to/transactions.json \
  --exclude-generated \
  --output reports/forecast_evaluation/recorded_sales
```

JSON may be a transaction array or an object containing `transactions`; CSV exports
are also accepted. Use `fruitName`, `soldAt`, `weightKg` or `weightGrams`, `status`,
and `totalPriceCentavos` or `totalPrice` (integer centavos). Explicit gram units
are converted by the shared server normalizer. Naive date strings
are interpreted in Asia/Manila. Input must contain complete daily ledgers; provide
an ISO `cutoff` field in the JSON wrapper when the final date is partial. The
cutoff date and any later records are then excluded. Today/future dates are always
excluded. PSA price/production rows are not sales input.

`--test-weeks` controls the number of blocks (default 4), `--horizon-days` controls
days per block (default 7). At least 30 development calendar days, the bridge, and
the test blocks are required. Re-running replaces the named generated report files
in the selected output folder.

The service excludes generated records by default. Its explicit
`include_generated_sales: true` option exists only for demonstrations; the local
evaluation intentionally includes the bundled sample and labels its provenance.

## Methodological references

- [Forecasting: Principles and Practice — time series cross-validation](https://otexts.com/fpp3/toolbox.html#time-series-cross-validation)
- [Hyndman — WAPE definition and limitations](https://robjhyndman.com/hyndsight/wape.html)
- [Panarese et al. — sales forecasts, actual/predicted plots, and error comparisons](https://www.mdpi.com/2076-3417/12/21/11054)
