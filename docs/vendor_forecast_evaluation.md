# Does the forecast help a fruit vendor?

The system estimates kilograms sold for each fruit on upcoming dates. A useful
forecast should help a vendor plan quantities while keeping errors within a
range that the vendor can tolerate. That must be demonstrated with complete,
genuine sales records and the vendor's operating conditions.

## What changed

- Operational forecasts exclude generated transactions by default.
- All 23 specific categories are represented. Guava is excluded; generic Mango
  sales require variety review before forecasting. The three mango varieties stay separate.
- Explicit grams are always converted to kilograms; naive dates use Manila time.
- Each fruit chooses among XGBoost, previous-week sales, and the recent average
  using up to four earlier forecast checks. The simplest method can win.
- The local report tests the complete selection procedure on later sales.
- Daily errors, total-period errors, and errors for each fruit are visible.
- Optional vendor-chosen tolerances measure the share of forecasts close enough
  for the vendor's stated needs. No universal accuracy threshold is invented.
- Advice describes expected sales. The app currently records prices but does not
  supply usable stock quantities, so no purchase quantity is calculated.

## Read the results

| Measure | Question it answers |
| --- | --- |
| Daily MAE in kg | How far off is an individual fruit's daily forecast, on average? |
| Period-total MAE in kg | How far off is the total quantity for that fruit over the forecast period? |
| WAPE | How large are absolute errors compared with the observed sales volume in that test? |
| Signed bias | Does the model tend to predict too much or too little? |
| Underforecast and overforecast kg | How much prediction error occurs in each direction, without cancelling? |
| Improvement against recent average | Does the selection procedure actually beat a simple alternative on later dates? |
| Share within a chosen kg tolerance | How often is the error within the limit agreed with the vendor? |

WAPE is an error, not a classification accuracy percentage. It is undefined for
all-zero actuals and can be hard to compare across differing periods or sales
levels. Use it alongside kg errors and baseline comparisons, not alone.

The category-coverage figure and first four numbered figures explain input coverage
and sales history. The daily actual/predicted plot and
error comparison assess forecasting. Period totals help with quantity planning,
but may hide timing mistakes: predicting 10 kg on the wrong day can produce a
perfect weekly total and still be unhelpful for perishable stock. The boosting
round plot is a separate training diagnostic, not the operational test score.

## Agree on success before final testing

1. Record how often the vendor restocks, how many days the fruit remains saleable,
   and which fruit quantities need separate decisions.
2. Agree on acceptable error in kilograms for daily sales and/or the replenishment
   period. Also agree on the required share of predictions within that tolerance.
   Different fruits may need different limits; the present CLI supports a common
   limit per run, so per-fruit limits should be assessed using the exported rows.
3. Verify that records cover all sales. Record closures, stockouts, missing uploads,
   and unavailable fruits separately. The existing transaction-only input cannot
   distinguish those situations from zero sales.
4. Evaluate in chronological order. Choose methods on earlier data, issue the
   forecast, then compare with later completed sales. Avoid changing thresholds
   or tuning the model to improve the already examined final test scores.
5. Compare with the recent average and same weekday last week. Check each fruit,
   each requested day, and each planning period. Record the number of tested periods.
6. Confirm results on new future records before relying on the method. To claim
   reduced waste or fewer stockouts, additionally measure usable stock, purchases,
   spoilage, and availability during a vendor trial. Forecast error alone does
   not demonstrate those business outcomes.

For illustration only: if a vendor accepts a 0.5 kg daily error and requires 80%
of forecasts to meet it, the evaluation should count the forecasts whose absolute
error is at most 0.5 kg and divide by the number tested. Those numbers are not
recommended defaults; choose limits with the vendor before the final experiment.

## Current evidence

Open [the revised local report](../reports/forecast_evaluation/revised_sample/index.html)
or [the figure PDF](../reports/forecast_evaluation/revised_sample/all_figures.pdf).
It uses generated sample transactions. It demonstrates calculations and exposes
weaknesses; it does not establish real-world vendor accuracy. No tolerance has
been chosen, so tolerance-based usefulness remains unassessed.

The corrected report includes all 23 supported categories. Eight have usable sample
history; 15 have no category-specific history. The 194 transactions labelled only
Mango remain in the original source and are listed for variety review, rather than
being guessed or split among mango varieties.

On the corrected sample run (28 test dates, eight evaluated fruits, four seven-day blocks):

| Method | Daily MAE (kg/fruit/day) | MAE of seven-day totals (kg/fruit/week) |
| --- | ---: | ---: |
| Recent average | 1.514 | 5.354 |
| XGBoost | 1.579 | 5.646 |
| Per-fruit selected policy | 1.522 | 5.289 |

The selected procedure has slightly worse daily MAE than the recent average,
and slightly better error in weekly totals. Its daily WAPE is 85.55%. These are sample results,
not evidence of reliable vendor forecasting or statistically established superiority.

## Literature supporting the evaluation approach

- [Panarese et al. (2022): sales forecasting with gradient boosting, actual-versus-predicted plots and error measures](https://www.mdpi.com/2076-3417/12/21/11054).
- [Turgut and Erdem: daily fruit/vegetable sales forecasting and model comparisons](https://link.springer.com/chapter/10.1007/978-3-030-76724-2_3).
- [Forecasting: Principles and Practice: chronological cross-validation](https://otexts.com/fpp3/toolbox.html#time-series-cross-validation).
- [Hyndman: standard WAPE definition and its limitations](https://robjhyndman.com/hyndsight/wape.html).

These sources support the method and purpose. Their accuracy results do not
transfer to FruityVens. Panarese's printed WAPE equation differs from the standard
sum-of-absolute-errors / sum-of-actuals formula used here; use the explicit formula
documented in this project's report when describing the implementation.
