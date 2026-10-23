# FruityVens Seasonal Demand Forecast

The forecast estimates daily kilograms sold for each fruit over the next seven
days. Only completed transactions are targets. Pending worker requests,
cancelled records, removed records, today's incomplete ledger, and future dates
are excluded. Business dates use Asia/Manila. The exact forecast dates are
returned by the server and retained by the app's chart.

## Sales And Calendar Features

XGBoost regression uses fruit identity, the date being predicted, month,
quarter, weekday, weekend, and cyclical annual calendar features. Sales features
include the previous day's weight and price, previous 3/7/14/28-day totals,
the previous same weekday, and the weight 365 days earlier when it exists.
Each training row predicts that row's daily weight from earlier records.
Same-day revenue, transaction counts, prices, and target weights are never
prediction inputs. Later prices are not backfilled into earlier days.

A fruit's daily ledger starts at its first recorded sale. Missing dates after
that first sale are assumed to have zero recorded sales. This assumes the
ledger is complete; missing uploads, closures, stockouts, and unrecorded sales
cannot currently be distinguished. Forecasted sales are not uncensored demand.
Prices are carried forward unless more recorded prices are available.

If the last closed sales day precedes the forecast origin, the server recursively
predicts each intervening calendar day before returning the requested horizon.
It requests refreshed history if the latest completed sale is over 30 days old.

## Historical Seasonality

The server reads `assets/data/psa_market_history.json`. It computes fruit-specific
monthly retail-price and quarterly production indices. Within each complete
year, a period's value is divided by that year's mean; indices are averaged
across at least two complete reference years. This reduces the effect of price
inflation and changes in annual production on the seasonal profile.

The closest eligible series is chosen in city, province, region, national order,
using the asset's variant priorities. Mango variants may use general mango
context if their own eligible series is unavailable. The response identifies
the geography, reference period, source, years, and category fallback. Missing
signals are explicitly marked unavailable, with neutral numeric inputs.

Historical production identifies seasonal supply patterns at quarterly
resolution. It cannot identify an exact harvest month or prove that a vendor's
customers will buy more fruit. Monthly price seasonality is a separate signal.
The model must learn any relationship with recorded vendor sales. Calendar
features alone cannot establish annual demand patterns from a few months of
transactions; repeated genuine annual history is needed to assess those patterns.

For each target year, the entire preceding year and all later years are excluded
from the PSA profile. This conservative publication buffer prevents observations
from later periods entering historical forecasts. The asset does not contain
release dates or historical revision vintages, so validation cannot establish
what exact official data was available at every past forecast origin.

## Model Selection And Confidence

The server compares `XGBRegressor`, weekly seasonal naive, and a recent
14-day-average forecast using two successive historical windows. Each candidate
trains only on dates before its window and predicts recursively, including the
same one-day bridge used when today's incomplete sales are excluded. There is
no random date shuffle or use of held-out sales as recursive inputs.

The lowest mean absolute error (MAE, kg per fruit/day) selects the production
model. A baseline may win. The response also includes WAPE, evaluated days,
evaluated fruit-days, and candidate scores. These recent validation windows are
used for model selection; they are not an independent test set or evidence of
performance throughout an entire year. Hyperparameters are conservative defaults,
not a claim of optimal tuning. Longer operational monitoring remains necessary.

Confidence combines validation error, per-fruit selling-day coverage, and
freshness. It remains low when generated records are included, history is sparse,
or validation is unavailable. Generated records remain marked in response
metadata and can exercise the workflow, but cannot establish real vendor demand
or real-world forecasting accuracy. PSA observations never enter the sales table.

## AI Advice And Hosting

Firebase AI optionally produces qualitative advice from computed recommendations
and historical seasonal context. Its text is appended to the numeric summary;
the model's weights, dates, confidence, and recommendations remain authoritative.
Advice with numeric characters is discarded. If AI is unavailable, the app
retains the server's forecast and deterministic advice.

The Flutter app defaults to the HTTPS Render service
`https://fruityvens.onrender.com`. USB forwarding is only needed for explicitly
configured local development. Updating server source locally does not update
Render: the revised backend and requirements must be deployed there.

## References

- [XGBoost parameters](https://xgboost.readthedocs.io/en/stable/parameter.html)
- [Time series forecasting with lagged features and chronological evaluation](https://scikit-learn.org/stable/auto_examples/applications/plot_time_series_lagged_features.html)
- [PSA market data and geographic selection](market_outlook_methodology.md)
