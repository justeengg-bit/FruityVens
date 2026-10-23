"""Local sales analysis and chronological forecast evaluation (no cloud writes).

Run from the repository root:
    .venv-evaluation/bin/python -m tool.evaluate_forecast

The default input is explicitly synthetic. See docs/forecast_evaluation.md.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import math
import platform
from datetime import datetime
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import xgboost
from matplotlib.backends.backend_pdf import PdfPages

from tool import forecast_server as server

ROOT = Path(__file__).resolve().parents[1]
MODELS = ["Weekly seasonal naive", "Recent average", "XGBRegressor"]
COLORS = {MODELS[0]: "#d08b24", MODELS[1]: "#208570", MODELS[2]: "#456cc4"}
MODEL_LABELS = {MODELS[0]: "Previous week", MODELS[1]: "Recent average", MODELS[2]: "XGBoost"}


def load_sales(path: Path, exclude_generated: bool = False):
    """Accept the bundled JSON, a transaction array, or an exported CSV."""
    if path.suffix.lower() == ".csv":
        document = {}
        records = pd.read_csv(path).where(pd.notna, None).to_dict("records")
    else:
        document = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(document, list):
            records, document = document, {}
        else:
            records = document.get("transactions", document.get("records", []))
            if isinstance(records, dict):
                records = [{**row, "cloudId": key} for key, row in records.items()]
    if not records:
        raise ValueError("Input must contain transaction rows, not PSA price/production observations.")
    prepared = []
    for original in records:
        row = dict(original)
        generated = (
            document.get("kind") == "synthetic_sales"
            or str(row.get("generated", "")).lower() == "true"
            or str(row.get("cloudId", "")).startswith("sample_cdo_")
        )
        if exclude_generated and generated:
            continue
        row["generated"] = generated
        # Respect declared units without the legacy server's small-gram heuristic.
        if row.get("weightKg") is None and row.get("weightGrams") is not None:
            row["weightKg"] = float(row["weightGrams"]) / 1000
        stamp = row.get("soldAt") or row.get("timestamp")
        if isinstance(stamp, str):
            parsed = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=server.BUSINESS_TIMEZONE)
            row["soldAt"] = parsed.isoformat()
        prepared.append(row)
    transactions = server._normalize_transactions(pd.DataFrame(prepared))
    if transactions.empty:
        raise ValueError("No completed transactions remain after filtering.")
    today = datetime.now(server.BUSINESS_TIMEZONE).date()
    complete = transactions["date"] < today
    excluded_partial_day = None
    if document.get("cutoff"):
        cutoff = datetime.fromisoformat(document["cutoff"])
        excluded_partial_day = cutoff.astimezone(server.BUSINESS_TIMEZONE).date()
        complete &= transactions["date"] < excluded_partial_day
    transactions = transactions[complete].copy()
    valid = np.isfinite(transactions["weight_kg"]) & (transactions["weight_kg"] > 0)
    transactions = transactions[valid].copy()
    if transactions.empty:
        raise ValueError("No valid closed-day transactions remain.")
    return transactions, excluded_partial_day


def error_metrics(rows: pd.DataFrame) -> dict:
    actual = rows["actual_kg"].to_numpy(dtype=float)
    predicted = rows["predicted_kg"].to_numpy(dtype=float)
    absolute = np.abs(predicted - actual)
    total = float(actual.sum())
    return {
        "mae_kg": float(absolute.mean()),
        "rmse_kg": float(np.sqrt(np.mean((predicted - actual) ** 2))),
        "wape_percent": float(absolute.sum() / total * 100) if total > 0 else None,
        "bias_kg": float(np.mean(predicted - actual)),
        "actual_kg": total,
        "predicted_kg": float(predicted.sum()),
        "fruit_days": len(rows),
    }


def summarize(rows: pd.DataFrame, by: list[str]) -> pd.DataFrame:
    result = []
    for keys, group in rows.groupby(by, sort=False):
        if not isinstance(keys, tuple):
            keys = (keys,)
        result.append({**dict(zip(by, keys)), **error_metrics(group)})
    return pd.DataFrame(result)


def backtest(daily: pd.DataFrame, test_weeks: int, horizon: int):
    """Freeze model choice on development data; evaluate later rolling blocks."""
    test_start = daily["date"].max() - pd.Timedelta(days=test_weeks * horizon - 1)
    # Mimic the app: latest closed sales precede an incomplete day, then tomorrow.
    first_origin = test_start - pd.Timedelta(days=2)
    development = daily[daily["date"] <= first_origin].copy()
    if development["date"].nunique() < 30:
        raise ValueError("Need at least 30 development days plus the requested test weeks and bridge day.")
    selection = server._validate_models(development, horizon)
    if not selection["candidates"]:
        raise ValueError("Not enough development history for model selection.")
    records = []
    for fold in range(test_weeks):
        start = test_start + pd.Timedelta(days=fold * horizon)
        origin = start - pd.Timedelta(days=2)
        history = daily[daily["date"] <= origin].copy()
        training, codes = server._training_frame(history)
        model = server._train_model(training)
        print(f"Evaluating block {fold + 1}/{test_weeks}: {start.date()} onward", flush=True)
        for name in MODELS:
            values = server._forecast_values(history, model, codes, start, horizon, name)
            for fruit, predictions in values.items():
                for index, prediction in enumerate(predictions):
                    date = start + pd.Timedelta(days=index)
                    observed = daily[(daily["fruit"] == fruit) & (daily["date"] == date)]
                    if observed.empty:
                        continue
                    actual = float(observed["kg_sold"].iloc[0])
                    records.append({
                        "block": fold + 1,
                        "training_end": origin.date().isoformat(),
                        "forecast_start": start.date().isoformat(),
                        "date": date,
                        "horizon_day": index + 1,
                        "fruit": fruit,
                        "model": name,
                        "actual_kg": actual,
                        "predicted_kg": float(prediction),
                        "error_kg": float(prediction) - actual,
                        "absolute_error_kg": abs(float(prediction) - actual),
                    })
    rows = pd.DataFrame(records)
    if rows.empty:
        raise ValueError("No comparable test predictions were produced.")
    # Newly introduced fruits without training records are outside this evaluation.
    common = rows.groupby(["date", "fruit"])["model"].nunique()
    if not (common == len(MODELS)).all():
        raise ValueError("Models did not evaluate the same fruit-days.")
    return rows, development, selection


def learning_history(development: pd.DataFrame):
    """One-step diagnostics on development data only; final test remains unseen."""
    featured, _ = server._training_frame(development)
    boundary = development["date"].max() - pd.Timedelta(days=6)
    train = featured[featured["date"] < boundary]
    validation = featured[featured["date"] >= boundary]
    # Reuse the production model's exact parameters, adding metric logging only.
    model = server._train_model(train)
    model.set_params(eval_metric="mae")
    model.fit(
        train[server.FORECAST_FEATURES], train["target_kg"],
        eval_set=[
            (train[server.FORECAST_FEATURES], train["target_kg"]),
            (validation[server.FORECAST_FEATURES], validation["target_kg"]),
        ],
        verbose=False,
    )
    results = model.evals_result()
    return pd.DataFrame({
        "boosting_round": range(1, len(results["validation_0"]["mae"]) + 1),
        "training_mae_kg": results["validation_0"]["mae"],
        "validation_mae_kg": results["validation_1"]["mae"],
    }), boundary


class Figures:
    def __init__(self, output: Path, pdf: PdfPages, provenance: str):
        self.output, self.pdf, self.provenance = output, pdf, provenance
        self.items = []

    def save(self, fig, stem, title, caption):
        fig.suptitle(title, fontsize=17, fontweight="bold", x=0.06, ha="left")
        fig.text(0.06, 0.018, self.provenance, fontsize=8, color="#6c4850")
        fig.tight_layout(rect=(0.025, 0.055, 0.985, 0.93))
        fig.savefig(self.output / f"{stem}.png", dpi=300)
        fig.savefig(self.output / f"{stem}.pdf")
        self.pdf.savefig(fig)
        self.items.append({"stem": stem, "title": title, "caption": caption})
        plt.close(fig)


def date_axis(ax):
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%b %d"))
    ax.xaxis.set_major_locator(mdates.AutoDateLocator(minticks=4, maxticks=7))
    ax.set_xlabel("Date")


def generate_figures(output, transactions, daily, predictions, metrics, learning, provenance):
    plt.rcParams.update({
        "font.family": "DejaVu Sans", "font.size": 10,
        "axes.spines.top": False, "axes.spines.right": False,
        "axes.grid": True, "grid.alpha": 0.18, "axes.axisbelow": True,
        "savefig.facecolor": "white", "figure.facecolor": "white",
    })
    with PdfPages(output / "all_figures.pdf") as pdf:
        figures = Figures(output, pdf, provenance)
        totals = daily.groupby("date")[["kg_sold", "revenue_centavos"]].sum()
        fig, axes = plt.subplots(2, 1, figsize=(12, 8), sharex=True)
        for ax, column, divisor, unit in [
            (axes[0], "kg_sold", 1, "Kilograms sold"),
            (axes[1], "revenue_centavos", 100, "Revenue (PHP)"),
        ]:
            values = totals[column] / divisor
            ax.plot(totals.index, values, lw=1.1, color="#7c99cb", label="Daily recorded total")
            ax.plot(totals.index, values.rolling(7, min_periods=7).mean(),
                    lw=2.4, color="#284c86", label="7-day trailing average")
            ax.set_ylabel(unit)
            ax.set_ylim(bottom=0)
            ax.legend(loc="upper left", frameon=False)
        date_axis(axes[1])
        figures.save(fig, "01_daily_sales", "Daily sales and revenue",
                     "Completed transactions only. Weight and revenue are separate measures; the trailing average summarizes past sales.")

        fruit_order = daily.groupby("fruit")["kg_sold"].sum().sort_values(ascending=False).index.tolist()
        fig, ax = plt.subplots(figsize=(12, 6))
        for fruit in fruit_order:
            data = daily[daily["fruit"] == fruit]
            ax.plot(data["date"], data["kg_sold"].rolling(7, min_periods=7).mean(), lw=1.5, label=fruit)
        ax.set_ylabel("Kilograms sold per day (7-day average)")
        ax.set_ylim(bottom=0)
        date_axis(ax)
        ax.legend(ncol=3, loc="upper left", frameon=False, fontsize=9)
        figures.save(fig, "02_fruit_trends", "Sales trends by fruit",
                     "Each line is a seven-day trailing average, not a fitted forecast or proof of annual seasonality.")

        fig, axes = plt.subplots(1, 2, figsize=(12, 5.5))
        axes[0].hist(daily["kg_sold"], bins=25, color="#456cc4", edgecolor="white")
        axes[0].set(xlabel="Kilograms per fruit per day", ylabel="Number of fruit-days",
                    title=f"Daily sales distribution ({len(daily):,} fruit-days)")
        zero = int((daily["kg_sold"] == 0).sum())
        axes[0].text(0.97, 0.94, f"Zero-sale days: {zero / len(daily):.1%}",
                     transform=axes[0].transAxes, ha="right", va="top")
        axes[1].hist(transactions["weight_kg"], bins=20, color="#208570", edgecolor="white")
        axes[1].set(xlabel="Kilograms per completed transaction", ylabel="Number of transactions",
                    title="Transaction weight distribution")
        figures.save(fig, "03_sales_distribution", "Distribution of sales quantities",
                     "Left: daily fruit sales, including assumed zero-sale dates. Right: basket weights from individual transactions.")

        fig, ax = plt.subplots(figsize=(12, 5.5))
        weekday = totals["kg_sold"].groupby(totals.index.dayofweek).mean().reindex(range(7))
        ax.bar(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], weekday,
               color=["#456cc4"] * 5 + ["#208570"] * 2)
        ax.set(xlabel="Day of week", ylabel="Average total kilograms sold per day")
        figures.save(fig, "04_weekday_sales", "Average sales by day of week",
                     "An exploratory summary of the available period; differences do not establish a causal weekday effect.")

        fig, axes = plt.subplots(1, 2, figsize=(12, 5.5))
        labels = [MODEL_LABELS[name] for name in metrics["model"]]
        for ax, column, label in [(axes[0], "mae_kg", "MAE (kg per fruit/day)"),
                                  (axes[1], "wape_percent", "WAPE (%)")]:
            bars = ax.bar(labels, metrics[column], color=[COLORS[n] for n in metrics["model"]], width=0.6)
            ax.set_ylabel(label)
            ax.set_title("Lower error is better")
            ax.set_ylim(0, max(metrics[column]) * 1.23)
            ax.bar_label(bars, fmt="%.2f", padding=5, fontsize=11)
        figures.save(fig, "05_model_comparison", "Forecast errors on later test periods",
                     "All methods predict the same fruit-days with a recursive seven-day horizon. Errors are computed before rounding; these are test scores, not training scores.")

        columns = min(3, len(fruit_order))
        rows = math.ceil(len(fruit_order) / columns)
        fig, axes = plt.subplots(rows, columns, figsize=(14, 3.2 * rows), squeeze=False)
        for ax, fruit in zip(axes.flat, fruit_order):
            sample = predictions[(predictions["fruit"] == fruit) & (predictions["model"] == MODELS[2])].sort_values("date")
            ax.plot(sample["date"], sample["actual_kg"], color="#293642", lw=1.7, marker="o", ms=2.5, label="Actual recorded sales")
            for name in MODELS:
                part = predictions[(predictions["fruit"] == fruit) & (predictions["model"] == name)].sort_values("date")
                ax.plot(part["date"], part["predicted_kg"], color=COLORS[name], lw=1.25, ls="--", label=MODEL_LABELS[name])
            ax.set_title(fruit, fontweight="bold")
            ax.set_ylabel("kg/day")
            ax.set_ylim(bottom=0)
            date_axis(ax)
        for ax in list(axes.flat)[len(fruit_order):]:
            ax.set_visible(False)
        handles, labels = axes.flat[0].get_legend_handles_labels()
        fig.legend(handles, labels, loc="lower center", bbox_to_anchor=(0.5, 0.045), ncol=4, frameon=False)
        figures.save(fig, "06_actual_vs_predicted", "Actual versus predicted sales by fruit",
                     "Forecasts are issued in separate seven-day blocks with a one-day bridge. Models refit before each block; actual values within a block never become recursive forecast inputs.")

        fig, ax = plt.subplots(figsize=(12, 5.5))
        ax.plot(learning["boosting_round"], learning["training_mae_kg"], color="#456cc4", lw=2, label="Training MAE")
        ax.plot(learning["boosting_round"], learning["validation_mae_kg"], color="#d08b24", lw=2, label="Development validation MAE")
        ax.set(xlabel="Boosting round (tree added)", ylabel="MAE (kg per fruit/day)", ylim=(0, None))
        ax.legend(frameon=False)
        figures.save(fig, "07_learning_curve", "XGBoost learning curve on development data",
                     "One-day-ahead diagnostic: validation features use earlier observed sales. This is not the recursive seven-day test score; the final test period is excluded entirely.")

        xgb = predictions[predictions["model"] == MODELS[2]]
        fig, axes = plt.subplots(1, 2, figsize=(12, 5.5))
        axes[0].scatter(xgb["actual_kg"], xgb["predicted_kg"], alpha=0.55, color=COLORS[MODELS[2]], s=20)
        limit = max(xgb["actual_kg"].max(), xgb["predicted_kg"].max()) * 1.05
        axes[0].plot([0, limit], [0, limit], color="#293642", ls="--", label="Perfect agreement")
        axes[0].set(xlabel="Actual kilograms per fruit/day", ylabel="Predicted kilograms per fruit/day", xlim=(0, limit), ylim=(0, limit), title="XGBoost: predicted versus actual")
        axes[0].legend(frameon=False)
        axes[1].hist(xgb["error_kg"], bins=25, color=COLORS[MODELS[2]], edgecolor="white")
        axes[1].axvline(0, color="#293642", ls="--")
        axes[1].set(xlabel="Prediction minus actual (kg)", ylabel="Number of fruit-days", title="Negative: underforecast / positive: overforecast")
        figures.save(fig, "08_prediction_errors", "XGBoost agreement and error distribution",
                     "A point near the diagonal indicates close agreement. Signed errors show the direction of misses; opposite errors do not cancel in MAE or WAPE.")
    return figures.items


def write_report(output, metadata, metrics, figures):
    score_rows = "\n".join(
        f"| {row.model} | {row.mae_kg:.3f} | {row.rmse_kg:.3f} | {row.wape_percent:.2f}% | {row.bias_kg:+.3f} |"
        for row in metrics.itertuples()
    )
    captions = "\n\n".join(
        f"### {item['title']}\n\n![{item['title']}]({item['stem']}.png)\n\n{item['caption']}\n\n[PDF]({item['stem']}.pdf)"
        for item in figures
    )
    report = f"""# FruityVens sales analysis and forecast evaluation

**{metadata['provenance']}**

Input: `{metadata['input']}`. Closed sales dates: {metadata['sales_start']} through {metadata['sales_end']}.
Transactions: {metadata['transaction_count']:,}; generated: {metadata['generated_transactions']:,}.
Partial day excluded: {metadata['excluded_partial_day'] or 'none declared'}.

## Chronological test design

The first development period ends {metadata['development_end']}. Model selection uses only that period,
with the server's two historical seven-day validation windows. The selected method is
**{metadata['selected_on_development']}** and is fixed before inspecting test results.
The later test period runs {metadata['test_start']} through {metadata['test_end']},
with {metadata['test_weeks']} successive {metadata['horizon_days']}-day blocks. Each block trains on
records ending two calendar days before the first forecast date, reproducing the app's one-day
incomplete-ledger bridge. The bridge is predicted recursively and not scored. The model is refit
before later blocks using only data available at that block's origin; no actual sale within its
forecast horizon is supplied back as an input. This is rolling operational evaluation, not one
single {metadata['test_weeks'] * metadata['horizon_days']}-day-ahead forecast.

All models score the same {metadata['evaluated_fruit_days']} fruit-days.
The numerically lowest test score is descriptive; the test period is not used to retune the model
or retrospectively change the development-selected method. Default production parameters are reused.

## Comparison on the test periods

| Method | MAE (kg/fruit/day) | RMSE (kg/fruit/day) | WAPE | Bias (kg/fruit/day) |
| --- | ---: | ---: | ---: | ---: |
{score_rows}

MAE = mean absolute prediction error. RMSE emphasizes larger misses.
WAPE = sum of absolute errors / total actual kilograms × 100; it is undefined when total actual sales
are zero. Bias = mean(prediction − actual); positive means overforecasting. WAPE is an error
percentage, not classification accuracy. Do not report 100 − WAPE as a generic accuracy score.

## Interpretation and limits

The sales-history plots are exploratory and do not measure forecast accuracy. The learning curve
is a separate one-day-ahead development diagnostic; it uses observed earlier validation-day sales
as lag features. It must not be confused with the recursive seven-day test results. Historical
seasonality comes from the same bundled PSA features as the production server. Missing dates
after a fruit's introduction are assumed to have zero recorded sales, as in the app. Closures,
stockouts, and missing uploads cannot be distinguished from zero demand. The target is recorded
sales, not unconstrained customer demand. Fruits absent from a block's training history are not
evaluated in that block. Results from generated records demonstrate the pipeline, not measured
real-world vendor performance. No phone, Firebase, or hosted-service records were read or changed.

## Files

- `index.html`: local visual report; open in any browser.
- `all_figures.pdf`: all eight figures in one document.
- `predictions.csv`: every model/date/fruit prediction, actual, signed error, and absolute error.
- `actual_vs_predicted.csv`: side-by-side actual kilograms and all three forecasts.
- `model_metrics.csv`, `fruit_metrics.csv`, `block_metrics.csv`, `horizon_metrics.csv`: error tables.
- `daily_sales.csv`: daily kilograms, revenue in centavos, transaction counts, and price per fruit.
- `learning_curve.csv`: training and development-validation MAE by boosting round.
- `development_selection.json`: the model comparison conducted before the test period.
- `run_metadata.json`: source hashes, dates, parameters, and library versions.

## Figures

{captions}
"""
    (output / "README.md").write_text(report, encoding="utf-8")
    headers = "<tr><th>Method</th><th>MAE (kg/fruit/day)</th><th>RMSE</th><th>WAPE</th><th>Bias (kg)</th></tr>"
    rows = "".join(
        f"<tr><td>{html.escape(r.model)}</td><td>{r.mae_kg:.3f}</td><td>{r.rmse_kg:.3f}</td><td>{r.wape_percent:.2f}%</td><td>{r.bias_kg:+.3f}</td></tr>"
        for r in metrics.itertuples()
    )
    cards = "\n".join(
        f'<section><h2>{html.escape(f["title"])}</h2><a href="{f["stem"]}.png"><img loading="lazy" src="{f["stem"]}.png" alt="{html.escape(f["title"])}"></a><p>{html.escape(f["caption"])}</p><a href="{f["stem"]}.pdf">Download figure PDF</a></section>'
        for f in figures
    )
    (output / "index.html").write_text(f"""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>FruityVens forecast evaluation</title><style>
body{{font:16px/1.6 system-ui,sans-serif;color:#263544;background:#f3f5f7;margin:0}}
main{{max-width:1120px;margin:auto;padding:32px 20px}}h1{{line-height:1.2}}h2{{font-size:23px}}
section,.intro{{background:white;border:1px solid #dde3e8;border-radius:12px;padding:24px;margin:24px 0}}
.notice{{padding:14px;background:#fff2d9;border-left:4px solid #bc7d18}}img{{width:100%;height:auto}}
table{{border-collapse:collapse;width:100%;font-size:14px}}td,th{{padding:12px;border-bottom:1px solid #ddd;text-align:left}}
a{{color:#235ea8}}.scroll{{overflow:auto}}small{{color:#586776}}
</style><main><h1>FruityVens: sales analysis and forecast evaluation</h1>
<p class="notice">{html.escape(metadata['provenance'])}</p>
<div class="intro"><p>{metadata['transaction_count']:,} completed transactions · {metadata['fruit_count']} fruits ·
{metadata['sales_start']} to {metadata['sales_end']}</p>
<p>Later test period: <b>{metadata['test_start']} to {metadata['test_end']}</b>, evaluated in
{metadata['test_weeks']} successive {metadata['horizon_days']}-day forecast blocks. Development-selected method:
<b>{html.escape(metadata['selected_on_development'])}</b>. Lower errors are better.</p>
<div class="scroll"><table>{headers}{rows}</table></div>
<p><a href="all_figures.pdf">Download all figures (PDF)</a> · <a href="predictions.csv">Prediction data (CSV)</a> ·
<a href="README.md">Methodology and interpretation</a> · <a href="run_metadata.json">Run metadata</a></p>
<small>Model parameters and selection use development data. Training is repeated before each later block.
The learning curve is a separate one-day-ahead diagnostic. Generated sales cannot establish real vendor accuracy.</small></div>
{cards}</main></html>""", encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=ROOT / "assets/data/cdo_sample_sales_2026.json")
    parser.add_argument("--output", type=Path, default=ROOT / "reports/forecast_evaluation/sample")
    parser.add_argument("--test-weeks", type=int, default=4)
    parser.add_argument("--horizon-days", type=int, default=7)
    parser.add_argument("--exclude-generated", action="store_true")
    args = parser.parse_args(argv)
    if args.test_weeks < 1 or not 1 <= args.horizon_days <= 14:
        parser.error("Use at least one test week/block and a horizon of 1–14 days.")
    transactions, partial = load_sales(args.input, args.exclude_generated)
    daily = server._daily_sales_frame(transactions)
    predictions, development, selection = backtest(daily, args.test_weeks, args.horizon_days)
    metrics = summarize(predictions, ["model"]).set_index("model").loc[MODELS].reset_index()
    learning, validation_start = learning_history(development)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    generated = int(transactions["generated"].sum())
    provenance = (
        "GENERATED SAMPLE SALES — demonstration only; not measured real-world forecasting accuracy."
        if generated else "RECORDED SALES INPUT — source authenticity must be established by the data owner."
    )
    metadata = {
        "created_at": datetime.now(server.BUSINESS_TIMEZONE).isoformat(),
        "input": str(args.input.resolve()),
        "input_sha256": hashlib.sha256(args.input.read_bytes()).hexdigest(),
        "forecast_source_sha256": hashlib.sha256((ROOT / "tool/forecast_server.py").read_bytes()).hexdigest(),
        "seasonality_source_sha256": hashlib.sha256((ROOT / "tool/forecast_seasonality.py").read_bytes()).hexdigest(),
        "psa_asset_sha256": hashlib.sha256((ROOT / "assets/data/psa_market_history.json").read_bytes()).hexdigest(),
        "provenance": provenance,
        "transaction_count": len(transactions), "generated_transactions": generated,
        "fruit_count": int(transactions["fruit"].nunique()),
        "sales_start": str(transactions["date"].min()), "sales_end": str(transactions["date"].max()),
        "excluded_partial_day": str(partial) if partial else None,
        "development_end": str(development["date"].max().date()),
        "learning_validation_start": str(validation_start.date()),
        "test_start": str(predictions["date"].min().date()),
        "test_end": str(predictions["date"].max().date()),
        "test_weeks": args.test_weeks, "horizon_days": args.horizon_days,
        "evaluated_fruit_days": int(len(predictions) / len(MODELS)),
        "selected_on_development": selection["selectedModel"],
        "versions": {"python": platform.python_version(), "numpy": np.__version__,
                     "pandas": pd.__version__, "xgboost": xgboost.__version__, "matplotlib": matplotlib.__version__},
        "parameters": server._train_model(server._training_frame(development)[0]).get_params(),
    }
    predictions.to_csv(output / "predictions.csv", index=False)
    metrics.to_csv(output / "model_metrics.csv", index=False)
    comparison = predictions.pivot(
        index=["block", "date", "fruit", "actual_kg"],
        columns="model", values="predicted_kg",
    ).reset_index()
    comparison.to_csv(output / "actual_vs_predicted.csv", index=False)
    daily.to_csv(output / "daily_sales.csv", index=False)
    learning.to_csv(output / "learning_curve.csv", index=False)
    for filename, columns in [("fruit_metrics.csv", ["model", "fruit"]),
                              ("block_metrics.csv", ["model", "block"]),
                              ("horizon_metrics.csv", ["model", "horizon_day"])]:
        summarize(predictions, columns).to_csv(output / filename, index=False)
    (output / "development_selection.json").write_text(json.dumps(selection, indent=2, allow_nan=False), encoding="utf-8")
    # get_params may contain NaN defaults; retain only explicitly serializable values.
    metadata["parameters"] = {k: v for k, v in metadata["parameters"].items()
                              if v is not None and not (isinstance(v, float) and math.isnan(v))}
    (output / "run_metadata.json").write_text(json.dumps(metadata, indent=2, allow_nan=False), encoding="utf-8")
    print("Generating local PNG and PDF figures...", flush=True)
    figures = generate_figures(output, transactions, daily, predictions, metrics, learning, provenance)
    write_report(output, metadata, metrics, figures)
    print(metrics[["model", "mae_kg", "rmse_kg", "wape_percent"]].to_string(index=False))
    print(f"\n{provenance}\nOpen: {output / 'index.html'}", flush=True)


if __name__ == "__main__":
    main()
