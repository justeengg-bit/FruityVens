# FruityVens Market Outlook Methodology

## Scope

The market outlook is a secondary-data feature for a fruit vendor located in
Cagayan de Oro City. It is separate from the personalized seven-day demand
forecast. PSA retail prices and production volumes must never be inserted into
`sales_transactions` or presented as kilograms sold by the FruityVens user.

The feature estimates:

- next-month retail-price direction from monthly price observations; and
- next-quarter supply direction from quarterly production observations.

It does not estimate vendor-level sales until FruityVens has collected genuine
transactions from that vendor.

## Official datasets

1. Philippine Statistics Authority, table `2M4ARA07`, *Fruits: Retail Prices
   of Agricultural Commodities by Geolocation, Commodity, Year and Period*.
   The bundled extract contains monthly observations from 2018 through 2025.
   <https://openstat.psa.gov.ph/Metadata/2M4ARA07>
2. Philippine Statistics Authority, table `2E4EVCP2`, *Fruit Crops: Volume of
   Production, by Region, Province, Quarter, and Semester*. The bundled extract
   contains quarterly observations from 2010 through 2025.
   <https://openstat.psa.gov.ph/PXWeb/pxweb/en/DB/DB__2E__CS/0072E4EVCP2.px/>

`tool/fetch_psa_market_history.mjs` downloads non-missing observations from the
PSA PXWeb API and regenerates `assets/data/psa_market_history.json`. Each stored
record retains its geography, period, unit, source commodity, table ID, URL,
and import timestamp.

## Geographic selection

For each fruit and metric, the app selects the closest series with sufficient
observations in this order:

1. Cagayan de Oro City
2. Misamis Oriental
3. Northern Mindanao (Region X)
4. Philippines

The selected geography is displayed in the app. A national series is therefore
not presented as Cagayan de Oro data.

## Mango variants

- Mango Carabao uses the PSA Carabao/Kalabaw series.
- Indian Mango uses the PSA Indian Mango series when it has enough observations.
  Otherwise, the supply signal is explicitly marked as general mango context.
- Apple Mango has no separate PSA series. The app uses general mango context
  only and labels both its price and supply signals as category fallbacks.

## Forecast and validation

For every eligible series, FruityVens compares three transparent models:

- seasonal naive;
- recent moving average; and
- local linear trend.

The models are evaluated with rolling one-step-ahead validation over recent
historical periods. The model with the lowest mean absolute error is used for
the next period. Direction is reported as increasing, stable, or decreasing;
the stable band accounts for both a three-percent movement threshold and the
model's measured validation error. Confidence depends on observation coverage
and weighted absolute percentage error, not on a generated AI statement.

Random train/test splitting is not used because it would leak future time-series
information into training.

PSA releases can lag the device date. The UI therefore displays the exact
forecast period after the latest official observation, such as `Jan 2026` or
`Q1 2026`. It must not relabel that estimate as the device's current "next
month" or silently extrapolate several unpublished periods.

## Literature basis

Fresh-food microforecasting research treats store-item sales as the demand
target and price, calendar, promotion, and weather as supporting variables:
<https://doi.org/10.1016/j.matcom.2017.12.006>.

Research on perishable retail promotions likewise evaluates forecast models
against observed product sales rather than replacing sales with external price
records: <https://doi.org/10.1016/j.ijpe.2015.10.022>.

The M5 retail forecasting study supports time-aware evaluation, explanatory
variables, and careful treatment of intermittent product-level demand:
<https://doi.org/10.1016/j.ijforecast.2021.11.013>.

These studies support using PSA indicators as market context while continuing
to collect genuine FruityVens transactions for personalized demand forecasts.
