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
import textwrap
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
from tool.forecast_metrics import error_metrics
from tool.fruit_categories import CATEGORY_PATH, FRUIT_CATEGORIES, category_coverage, split_supported_sales

ROOT = Path(__file__).resolve().parents[1]
MODELS = [*server.CANDIDATE_MODELS, "Selected policy"]
COLORS = {MODELS[0]: "#d08b24", MODELS[1]: "#208570", MODELS[2]: "#456cc4", MODELS[3]: "#a14678"}
MODEL_LABELS = {MODELS[0]: "Previous week", MODELS[1]: "Recent average", MODELS[2]: "XGBoost", MODELS[3]: "Selected policy"}


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
        prepared.append(row)
    transactions = server._normalize_transactions(pd.DataFrame(prepared))
    if transactions.empty:
        raise ValueError("No completed transactions remain after filtering.")
    today = datetime.now(server.BUSINESS_TIMEZONE).date()
    complete = transactions["date"] < today
    excluded_partial_day = None
    if document.get("cutoff"):
        cutoff = server._parse_date(document["cutoff"])
        if cutoff is None:
            raise ValueError("The input cutoff must be a valid date or timestamp.")
        excluded_partial_day = cutoff.astimezone(server.BUSINESS_TIMEZONE).date()
        complete &= transactions["date"] < excluded_partial_day
    transactions = transactions[complete].copy()
    valid = np.isfinite(transactions["weight_kg"]) & (transactions["weight_kg"] > 0)
    transactions = transactions[valid].copy()
    if transactions.empty:
        raise ValueError("No valid closed-day transactions remain.")
    return transactions, excluded_partial_day


def summarize(rows: pd.DataFrame, by: list[str], tolerance_kg: float | None = None) -> pd.DataFrame:
    result = []
    for keys, group in rows.groupby(by, sort=False):
        if not isinstance(keys, tuple):
            keys = (keys,)
        result.append({**dict(zip(by, keys)), **error_metrics(group, tolerance_kg)})
    return pd.DataFrame(result)


def backtest(daily: pd.DataFrame, test_weeks: int, horizon: int):
    """Evaluate fixed candidates and the actual selection procedure on later blocks."""
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
        # Selection only sees records available before this forecast is issued.
        current_selection = selection if fold == 0 else server._validate_models(history, horizon)
        chosen = current_selection["selectedByFruit"]
        print(f"Evaluating block {fold + 1}/{test_weeks}: {start.date()} onward", flush=True)
        forecasts = {
            name: server._forecast_values(history, model, codes, start, horizon, name)
            for name in server.CANDIDATE_MODELS
        }
        forecasts["Selected policy"] = {
            fruit: forecasts[chosen.get(fruit, "Recent average")][fruit] for fruit in codes
        }
        for name in MODELS:
            values = forecasts[name]
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
                        "model_used": chosen.get(fruit, "Recent average") if name == "Selected policy" else name,
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


def planning_totals(predictions: pd.DataFrame, horizon: int) -> pd.DataFrame:
    """Keep each fruit and forecast period separate; timing errors may cancel only here."""
    rows = predictions.groupby(["model", "fruit", "block"], as_index=False).agg(
        date=("date", "min"), actual_kg=("actual_kg", "sum"),
        predicted_kg=("predicted_kg", "sum"), days=("date", "nunique"),
    )
    rows = rows[rows["days"] == horizon].copy()
    rows["error_kg"] = rows["predicted_kg"] - rows["actual_kg"]
    rows["absolute_error_kg"] = rows["error_kg"].abs()
    return rows


def vendor_assessment(predictions, totals, metadata):
    """Describe tolerance checks without assigning a universal accuracy threshold."""
    records = []
    for fruit, rows in predictions[predictions["model"] == "Selected policy"].groupby("fruit"):
        daily = error_metrics(rows, metadata["daily_tolerance_kg"])
        period_rows = totals[(totals["model"] == "Selected policy") & (totals["fruit"] == fruit)]
        period = error_metrics(period_rows, metadata["period_tolerance_kg"])
        baseline_rows = predictions[(predictions["model"] == "Recent average") & (predictions["fruit"] == fruit)]
        baseline = error_metrics(baseline_rows)["mae_kg"]
        status = "Tolerance target not specified"
        target = metadata["target_within_tolerance_percent"]
        rates = [rate for rate in [daily["within_tolerance_percent"], period["within_tolerance_percent"]]
                 if rate is not None]
        if target is not None and rates:
            status = "Within chosen target on tested records" if all(rate >= target for rate in rates) else "Outside chosen target on tested records"
        if metadata["generated_transactions"]:
            status = "Sample demonstration only"
        elif not metadata["history_complete_declared"]:
            status = "Confirm complete sales records first"
        records.append({
            "fruit": fruit, "daily_mae_kg": daily["mae_kg"],
            "daily_wape_percent": daily["wape_percent"],
            "daily_bias_kg": daily["bias_kg"],
            "daily_underforecast_kg": daily["underforecast_kg"],
            "daily_overforecast_kg": daily["overforecast_kg"],
            "period_mae_kg": period["mae_kg"], "period_wape_percent": period["wape_percent"],
            "daily_within_tolerance_percent": daily["within_tolerance_percent"],
            "period_within_tolerance_percent": period["within_tolerance_percent"],
            "daily_tolerance_kg": metadata["daily_tolerance_kg"],
            "period_tolerance_kg": metadata["period_tolerance_kg"],
            "improvement_vs_recent_average_percent": (1 - daily["mae_kg"] / baseline) * 100 if baseline > 0 else None,
            "tested_days": len(rows), "tested_periods": len(period_rows), "assessment": status,
        })
    return pd.DataFrame(records)


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
        wrapped = textwrap.fill(caption, width=int(fig.get_figwidth() * 12))
        lines = len(wrapped.splitlines())
        footer_top = 0.035 + (0.13 * lines + 0.1) / fig.get_figheight()
        fig.text(0.06, 0.035, wrapped, fontsize=8, va="bottom", color="#43515e")
        for legend in fig.legends:
            legend.set_bbox_to_anchor((0.5, footer_top + 0.005))
        bottom = footer_top + (0.05 if fig.legends else 0.025)
        fig.tight_layout(rect=(0.025, bottom, 0.985, 0.93))
        fig.savefig(self.output / f"{stem}.png", dpi=300)
        fig.savefig(self.output / f"{stem}.pdf")
        self.pdf.savefig(fig)
        self.items.append({"stem": stem, "title": title, "caption": caption})
        plt.close(fig)


def date_axis(ax):
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%b %d"))
    ax.xaxis.set_major_locator(mdates.AutoDateLocator(minticks=4, maxticks=7))
    ax.set_xlabel("Date")


def missing_panel(ax, message="No recorded sales history"):
    ax.text(0.5, 0.5, message, ha="center", va="center", transform=ax.transAxes,
            fontsize=10, color="#776970", wrap=True)
    ax.set_xticks([])
    ax.set_yticks([])
    ax.grid(False)
    ax.set_facecolor("#faf8f8")


def add_figure_legend(fig, axes, columns):
    entries = {}
    for ax in axes.flat:
        handles, labels = ax.get_legend_handles_labels()
        entries.update(zip(labels, handles))
    if entries:
        fig.legend(list(entries.values()), list(entries), loc="lower center", ncol=columns,
                   frameon=False, fontsize=9)


def fruit_error_figure(assessment, fruit_order, horizon):
    fig, axes = plt.subplots(1, 2, figsize=(14, 10))
    ordered = assessment.set_index("fruit").reindex(fruit_order).reset_index()
    for ax, column, title, unit in [
        (axes[0], "daily_mae_kg", "Daily error", "MAE (kg per fruit/day)"),
        (axes[1], "period_mae_kg", "Period-total error", f"MAE (kg per fruit/{horizon}-day period)"),
    ]:
        ax.barh(ordered["fruit"], ordered[column], color=COLORS["Selected policy"])
        ax.set(xlabel=unit, title=title)
        # NaN bars do not extend automatic limits. All categories need visible rows.
        ax.set_yticks(range(len(ordered)), ordered["fruit"])
        ax.set_ylim(len(ordered) - 0.5, -0.5)
        for index, value in enumerate(ordered[column]):
            if pd.isna(value):
                ax.text(0.01, index, "Not evaluated — no usable history", va="center",
                        transform=ax.get_yaxis_transform(), fontsize=8, color="#776970")
    return fig


def generate_figures(output, transactions, daily, predictions, metrics, learning, provenance, periods, assessment, horizon, coverage, issues):
    plt.rcParams.update({
        "font.family": "DejaVu Sans", "font.size": 10,
        "axes.spines.top": False, "axes.spines.right": False,
        "axes.grid": True, "grid.alpha": 0.18, "axes.axisbelow": True,
        "savefig.facecolor": "white", "figure.facecolor": "white",
    })
    with PdfPages(output / "all_figures.pdf") as pdf:
        figures = Figures(output, pdf, provenance)
        reference_label = "Sample reference sales" if transactions["generated"].any() else "Recorded sales"
        fig, ax = plt.subplots(figsize=(12, 9))
        ax.barh(coverage["fruit"], coverage["transaction_count"], color="#456cc4")
        ax.invert_yaxis()
        limit = max(1, coverage["transaction_count"].max())
        ax.set_xlim(0, limit * 1.65)
        for index, row in enumerate(coverage.itertuples()):
            label = f"{row.transaction_count} transactions" if row.transaction_count else "No recorded sales history"
            ax.text(row.transaction_count + limit * 0.015, index, label, va="center", fontsize=9)
        ax.set_xlabel("Completed input transactions assigned to this category")
        figures.save(fig, "00_category_coverage", f"Sales-history coverage: all {len(FRUIT_CATEGORIES)} categories",
                     f"Counts describe the input file, not demand. {len(issues)} transactions need category review and are excluded from these category-specific analyses. No missing fruit history is filled with invented sales.")
        totals = daily.groupby("date")[["kg_sold", "revenue_centavos"]].sum()
        fig, axes = plt.subplots(2, 1, figsize=(12, 8), sharex=True)
        for ax, column, divisor, unit in [
            (axes[0], "kg_sold", 1, "Kilograms sold"),
            (axes[1], "revenue_centavos", 100, "Revenue (PHP)"),
        ]:
            values = totals[column] / divisor
            ax.plot(totals.index, values, lw=1.1, color="#7c99cb", label="Daily classified-sales total")
            ax.plot(totals.index, values.rolling(7, min_periods=7).mean(),
                    lw=2.4, color="#284c86", label="7-day trailing average")
            ax.set_ylabel(unit)
            ax.set_ylim(bottom=0)
            ax.legend(loc="upper left", frameon=False)
        date_axis(axes[1])
        figures.save(fig, "01_daily_sales", "Daily sales and revenue",
                     f"Completed sales assigned to supported categories only; {len(issues)} unresolved/out-of-scope transactions are excluded. Weight and revenue are separate measures; the trailing average summarizes past sales.")

        fruit_order = list(FRUIT_CATEGORIES)
        columns, rows = 3, math.ceil(len(fruit_order) / 3)
        fig, axes = plt.subplots(rows, columns, figsize=(14, 2.7 * rows), squeeze=False)
        for ax, fruit in zip(axes.flat, fruit_order):
            data = daily[daily["fruit"] == fruit]
            ax.set_title(fruit, fontweight="bold")
            if data.empty:
                missing_panel(ax)
                continue
            average = data["kg_sold"].rolling(7, min_periods=7).mean()
            if not average.notna().any():
                missing_panel(ax, "Fewer than 7 daily observations\nTrend not estimated")
                continue
            ax.plot(data["date"], average, lw=1.6, color="#456cc4")
            ax.set_ylabel("kg/day (7-day mean)")
            ax.set_ylim(bottom=0)
            date_axis(ax)
            ax.tick_params(axis="both", labelsize=8)
        for ax in list(axes.flat)[len(fruit_order):]:
            ax.set_visible(False)
        figures.save(fig, "02_fruit_trends", f"Sales trends: all {len(fruit_order)} supported categories",
                     "Each available line is a seven-day trailing average of classified sales. Empty panels mean no recorded history, not zero demand. Generic Mango records cannot be assigned to a variety without confirmation. Panels have separate kg scales.")

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
                     "Summary of classified sales in the available period. For the bundled sample, higher weekend transaction counts were deliberately programmed; this is not evidence of real vendor weekday demand.")

        fig, axes = plt.subplots(1, 2, figsize=(12, 5.5))
        labels = [MODEL_LABELS[name] for name in metrics["model"]]
        for ax, column, label in [(axes[0], "mae_kg", "MAE (kg per fruit/day)"),
                                  (axes[1], "wape_percent", "WAPE (%)")]:
            values = pd.to_numeric(metrics[column], errors="coerce")
            bars = ax.bar(labels, values.fillna(0), color=[COLORS[n] for n in metrics["model"]], width=0.6)
            ax.set_ylabel(label)
            ax.set_title("Lower error is better")
            ax.set_ylim(0, max(1.0, values.fillna(0).max()) * 1.23)
            digits = 3 if column == "mae_kg" else 2
            ax.bar_label(bars, labels=[f"{v:.{digits}f}" if pd.notna(v) else "Undefined" for v in values], padding=5, fontsize=10)
            ax.tick_params(axis="x", labelsize=9)
        figures.save(fig, "05_model_comparison", "Forecast errors on later test periods",
                     f"All methods predict the same fruit-days over {horizon}-day blocks. Selected policy chooses a method per fruit using earlier sales only. Scores use unrounded predictions.")

        columns = min(3, len(fruit_order))
        rows = math.ceil(len(fruit_order) / columns)
        fig, axes = plt.subplots(rows, columns, figsize=(14, 3.2 * rows), squeeze=False)
        for ax, fruit in zip(axes.flat, fruit_order):
            sample = predictions[(predictions["fruit"] == fruit) & (predictions["model"] == MODELS[2])].sort_values("date")
            ax.set_title(fruit, fontweight="bold")
            if sample.empty:
                status = coverage.set_index("fruit").loc[fruit, "evaluation_status"]
                missing_panel(ax, status.replace(": ", ":\n"))
                continue
            ax.plot(sample["date"], sample["actual_kg"], color="#293642", lw=1.7, marker="o", ms=2.5, label=reference_label)
            for name in MODELS:
                part = predictions[(predictions["fruit"] == fruit) & (predictions["model"] == name)].sort_values("date")
                ax.plot(part["date"], part["predicted_kg"], color=COLORS[name], lw=1.25, ls="--", label=MODEL_LABELS[name])
            for boundary in predictions["forecast_start"].unique()[1:]:
                ax.axvline(pd.Timestamp(boundary), color="#777777", lw=0.8, ls=":")
            ax.set_title(fruit, fontweight="bold")
            ax.set_ylabel("kg/day")
            ax.set_ylim(bottom=0)
            date_axis(ax)
        for ax in list(axes.flat)[len(fruit_order):]:
            ax.set_visible(False)
        add_figure_legend(fig, axes, 5)
        figures.save(fig, "06_actual_vs_predicted", "Actual versus predicted sales by fruit",
                     f"Dotted boundaries mark new {horizon}-day forecast blocks. Selection and training use only earlier sales; actual sales within a block never become forecast inputs. Reference actuals are sample values when the dataset is generated.")

        fig, ax = plt.subplots(figsize=(12, 5.5))
        ax.plot(learning["boosting_round"], learning["training_mae_kg"], color="#456cc4", lw=2, label="Training MAE")
        ax.plot(learning["boosting_round"], learning["validation_mae_kg"], color="#d08b24", lw=2, label="Development validation MAE")
        ax.set(xlabel="Boosting round (tree added)", ylabel="MAE (kg per fruit/day)", ylim=(0, None))
        ax.legend(frameon=False)
        figures.save(fig, "07_learning_curve", "Training and validation MAE versus boosting rounds",
                     "One-day-ahead diagnostic: validation features use earlier observed sales. This is not the recursive seven-day test score; the final test period is excluded entirely.")

        selected = predictions[predictions["model"] == "Selected policy"]
        fig, axes = plt.subplots(1, 2, figsize=(12, 5.5))
        axes[0].scatter(selected["actual_kg"], selected["predicted_kg"], alpha=0.55, color=COLORS["Selected policy"], s=20)
        limit = max(1.0, selected["actual_kg"].max(), selected["predicted_kg"].max()) * 1.05
        axes[0].plot([0, limit], [0, limit], color="#293642", ls="--", label="Perfect agreement")
        axes[0].set(xlabel="Reference kilograms per fruit/day", ylabel="Predicted kilograms per fruit/day", xlim=(0, limit), ylim=(0, limit), title="Selected procedure: prediction agreement")
        axes[0].legend(frameon=False)
        axes[1].hist(selected["error_kg"], bins=25, color=COLORS["Selected policy"], edgecolor="white")
        axes[1].axvline(0, color="#293642", ls="--")
        axes[1].set(xlabel="Prediction minus actual (kg)", ylabel="Number of fruit-days", title="Negative: underforecast / positive: overforecast")
        figures.save(fig, "08_prediction_errors", "Selected procedure: agreement and error distribution",
                     "Only category-resolved fruit-days with evaluated predictions are shown. A point near the diagonal indicates close agreement; positive error means overforecasting. Sample reference quantities are generated when the input is synthetic.")

        fig, axes = plt.subplots(rows, columns, figsize=(14, 3.2 * rows), squeeze=False)
        for ax, fruit in zip(axes.flat, fruit_order):
            observed = periods[(periods["fruit"] == fruit) & (periods["model"] == "Selected policy")].sort_values("block")
            ax.set_title(fruit, fontweight="bold")
            if observed.empty:
                missing_panel(ax, coverage.set_index("fruit").loc[fruit, "evaluation_status"].replace(": ", ":\n"))
                continue
            ax.plot(observed["date"], observed["actual_kg"], "o-", color="#293642", label=reference_label)
            for name in ["Recent average", "Selected policy"]:
                part = periods[(periods["fruit"] == fruit) & (periods["model"] == name)].sort_values("block")
                ax.plot(part["date"], part["predicted_kg"], "o--", color=COLORS[name], label=MODEL_LABELS[name])
            ax.set(ylabel=f"kg / {horizon}-day period", ylim=(0, None))
            date_axis(ax)
            ax.set_xlabel("Forecast period starts")
            ax.tick_params(axis="both", labelsize=8)
        for ax in list(axes.flat)[len(fruit_order):]:
            ax.set_visible(False)
        add_figure_legend(fig, axes, 3)
        figures.save(fig, "09_period_sales", f"Actual and predicted {horizon}-day sales totals",
                     "Totals are calculated separately for each fruit and forecast block. Good agreement here can hide errors in daily timing; read alongside the daily plots. These are sales quantities, not recommended purchase quantities.")

        fig = fruit_error_figure(assessment, fruit_order, horizon)
        figures.save(fig, "10_fruit_errors", "Selected forecasting policy: errors by fruit",
                     "All supported categories are listed. Missing bars mean not evaluated; they do not represent zero error. Compare kg errors with sales volume and the vendor's tolerance before judging usefulness.")

        fig, ax = plt.subplots(figsize=(12, 5.5))
        for name in MODELS:
            part = predictions[predictions["model"] == name].groupby("horizon_day")["absolute_error_kg"].mean()
            ax.plot(part.index, part.values, "o-", color=COLORS[name], label=MODEL_LABELS[name])
        ax.set(xlabel="Requested forecast day (day 1 is tomorrow)", ylabel="MAE (kg per fruit/day)", ylim=(0, None))
        ax.set_xticks(range(1, horizon + 1))
        ax.legend(frameon=False)
        figures.save(fig, "11_horizon_errors", "Forecast error by distance into the future",
                     "Compare requested days on the same test blocks. Weekly-spaced origins start on the same weekday, so this plot mixes forecast-distance and weekday effects. It does not isolate the causal effect of predicting further ahead. A bridge precedes requested day 1.")
    return figures.items


def display(value, digits=2, suffix=""):
    return "Not assessed" if value is None or pd.isna(value) else f"{value:.{digits}f}{suffix}"


def write_report(output, metadata, metrics, figures, period_metrics, assessment, coverage, issues):
    score_rows = "\n".join(
        f"| {row.model} | {row.mae_kg:.3f} | {row.rmse_kg:.3f} | {display(row.wape_percent, suffix='%')} | {row.bias_kg:+.3f} |"
        for row in metrics.itertuples()
    )
    period_score_rows = "\n".join(
        f"| {r.model} | {r.mae_kg:.3f} | {display(r.wape_percent, suffix='%')} | {r.underforecast_kg:.3f} | {r.overforecast_kg:.3f} |"
        for r in period_metrics.itertuples()
    )
    fruit_score_rows = "\n".join(
        f"| {r.fruit} | {display(r.daily_mae_kg, 3)} | {display(r.period_mae_kg, 3)} | {display(r.improvement_vs_recent_average_percent, suffix='%')} | {display(r.daily_within_tolerance_percent, suffix='%')} | {display(r.period_within_tolerance_percent, suffix='%')} | {r.assessment} |"
        for r in assessment.itertuples()
    )
    coverage_rows = "\n".join(
        f"| {r.fruit} | {r.transaction_count} | {r.selling_days} | {r.history_status} | {r.evaluation_status} |"
        for r in coverage.itertuples()
    )
    issue_rows = "\n".join(
        f"| {name} | {len(group)} | {group['weight_kg'].sum():.3f} | {group['category_issue'].iloc[0]} |"
        for name, group in issues.groupby("fruit")
    ) or "| None | 0 | 0 | No category issues |"
    captions = "\n\n".join(
        f"### {item['title']}\n\n![{item['title']}]({item['stem']}.png)\n\n{item['caption']}\n\n[PDF]({item['stem']}.pdf)"
        for item in figures
    )
    report = f"""# FruityVens sales analysis and forecast evaluation

**{metadata['provenance']}**

Input: `{metadata['input']}`. Closed sales dates: {metadata['sales_start']} through {metadata['sales_end']}.
Transactions: {metadata['transaction_count']:,}; generated: {metadata['generated_transactions']:,}.
Partial day excluded: {metadata['excluded_partial_day'] or 'none declared'}.

## Supported categories and input audit

The agreed catalog contains **{metadata['category_count']} specific categories**. Guava and generic
Mango are not supported categories. Mango Carabao, Indian Mango, and Apple Mango are separate.
This source file contains {metadata['source_transaction_count']} completed closed-day transactions:
**{metadata['transaction_count']}** can be assigned to supported categories;
**{metadata['category_issue_count']}** need category review and are excluded from the sales plots,
training, and accuracy calculations below. The original input records have not been relabelled.

| Original label needing review | Transactions | Kilograms | Reason |
| --- | ---: | ---: | --- |
{issue_rows}

**{metadata['fruit_count']} of {metadata['category_count']} categories have usable sales history**.
Every category appears below and in the trend/comparison panels. Missing history means unknown;
it is never represented by invented zero-demand lines or zero prediction errors.

| Supported category | Input transactions | Selling days | Sales-history status | Evaluation status |
| --- | ---: | ---: | --- | --- |
{coverage_rows}

## Chronological test design

The first development period ends {metadata['development_end']}. The service chooses a method
separately for each fruit using up to four earlier forecast windows and lowest daily MAE.
The initial choice is **{metadata['selected_on_development']}**.
The later test period runs {metadata['test_start']} through {metadata['test_end']},
with {metadata['test_weeks']} successive {metadata['horizon_days']}-day blocks. Each block trains on
records ending two calendar days before the first forecast date, reproducing the app's one-day
incomplete-ledger bridge. The bridge is predicted recursively and not scored. The model is refit
before later blocks using only data available at that block's origin; no actual sale within its
forecast horizon is supplied back as an input. This is rolling operational evaluation, not one
single {metadata['test_weeks'] * metadata['horizon_days']}-day-ahead forecast.

All methods score the same {metadata['evaluated_fruit_days']} fruit-days. **Selected policy** is the
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
{score_rows}

MAE = mean absolute prediction error. RMSE emphasizes larger misses.
WAPE = sum of absolute errors / total actual kilograms × 100; it is undefined when total actual sales
are zero. Bias = mean(prediction − actual); positive means overforecasting. WAPE is an error
percentage, not classification accuracy. Do not report 100 − WAPE as a generic accuracy score.

## Quantities over a planning period

The period is **{metadata['horizon_days']} days**. There are
{metadata['evaluated_fruit_periods']} complete fruit-periods per method. These errors first sum
sales within each fruit/period, then compare totals; they differ from averaging daily errors.

| Method | MAE (kg/fruit/period) | WAPE of period totals | Total underforecast (kg) | Total overforecast (kg) |
| --- | ---: | ---: | ---: | ---: |
{period_score_rows}

Underforecast and overforecast compare predictions with recorded sales. They are **not measured
stockouts, lost sales, leftover stock, or spoilage**. Those outcomes require stock and operational
records. Daily errors must still be checked because fruit is perishable and the timing matters.

## What a vendor can assess

| Fruit | Daily MAE (kg) | Period MAE (kg) | Daily improvement vs recent average | Days within tolerance | Periods within tolerance | Evidence status |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
{fruit_score_rows}

Positive improvement means the selected procedure beat the recent-average baseline on the same
fruit-days; negative means it did worse. Zero baseline error makes the percentage undefined.
Daily tolerance: **{display(metadata['daily_tolerance_kg'], suffix=' kg')}**;
period-total tolerance: **{display(metadata['period_tolerance_kg'], suffix=' kg')}**;
required share within tolerance: **{display(metadata['target_within_tolerance_percent'], suffix='%')}**.
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
evaluated in that block. History declared complete: {metadata['history_complete_declared']}.
Assumed zero fruit-days: {metadata['assumed_zero_fruit_days']}. Results from generated records demonstrate the pipeline, not measured
real-world vendor performance. No phone, Firebase, or hosted-service records were read or changed.

## Files

- `index.html`: local visual report; open in any browser.
- `all_figures.pdf`: all {len(figures)} figures in one document.
- `predictions.csv`: every model/date/fruit prediction, actual, signed error, and absolute error.
- `actual_vs_predicted.csv`: actual kilograms, the three candidate forecasts, and the selected policy.
- `model_metrics.csv`, `fruit_metrics.csv`, `block_metrics.csv`, `horizon_metrics.csv`: error tables.
- `period_predictions.csv`, `period_metrics.csv`, `fruit_period_metrics.csv`: total quantities and errors per planning period.
- `vendor_assessment.csv`: per-fruit baseline comparison and chosen tolerance checks.
- `selection_history.csv`: the method chosen before each fruit's test block.
- `daily_sales.csv`: daily kilograms, revenue in centavos, transaction counts, and price per fruit.
- `category_coverage.csv`: every supported category and its history/evaluation status.
- `category_review.csv`: completed records requiring a specific supported fruit label.
- `input_reconciliation.json`: original, included, and excluded transaction/weight/revenue totals.
- `learning_curve.csv`: training and development-validation MAE by boosting round.
- `development_selection.json`: initial per-fruit choices using earlier validation records.
- `run_metadata.json`: source hashes, dates, parameters, and library versions.

## Figures

{captions}
"""
    (output / "README.md").write_text(report, encoding="utf-8")
    headers = "<tr><th>Method</th><th>MAE (kg/fruit/day)</th><th>RMSE</th><th>WAPE</th><th>Bias (kg)</th></tr>"
    rows = "".join(
        f"<tr><td>{html.escape(r.model)}</td><td>{r.mae_kg:.3f}</td><td>{r.rmse_kg:.3f}</td><td>{display(r.wape_percent, suffix='%')}</td><td>{r.bias_kg:+.3f}</td></tr>"
        for r in metrics.itertuples()
    )
    vendor_table = assessment[["fruit", "daily_mae_kg", "period_mae_kg",
                               "improvement_vs_recent_average_percent",
                               "daily_within_tolerance_percent", "period_within_tolerance_percent",
                               "assessment"]].rename(columns={
        "fruit": "Fruit", "daily_mae_kg": "Daily MAE (kg)", "period_mae_kg": "Period MAE (kg)",
        "improvement_vs_recent_average_percent": "Improvement vs average (%)",
        "daily_within_tolerance_percent": "Days within tolerance (%)",
        "period_within_tolerance_percent": "Periods within tolerance (%)", "assessment": "Evidence status",
    }).to_html(index=False, float_format=lambda v: f"{v:.2f}", na_rep="Not assessed", border=0)
    coverage_table = coverage[["fruit", "transaction_count", "selling_days", "history_status", "evaluation_status"]].to_html(index=False, border=0)
    issues_table = issues.groupby(["fruit", "category_issue"], as_index=False).agg(
        transaction_count=("fruit", "size"), kilograms=("weight_kg", "sum")
    ).to_html(index=False, float_format=lambda value: f"{value:.3f}", border=0) if not issues.empty else "<p>No unresolved category labels.</p>"
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
<p><b>{metadata['fruit_count']} of {metadata['category_count']} supported categories have usable history.</b>
{metadata['category_issue_count']} of {metadata['source_transaction_count']} input transactions need category review.
They are excluded from the graphs and model scores below; their original labels are preserved.</p>
<p>Later test period: <b>{metadata['test_start']} to {metadata['test_end']}</b>, evaluated in
{metadata['test_weeks']} successive {metadata['horizon_days']}-day forecast blocks. Selected policy chooses
a method for each fruit before each block using earlier sales. Lower errors are better.</p>
<div class="scroll"><table>{headers}{rows}</table></div>
<p><a href="all_figures.pdf">Download all figures (PDF)</a> · <a href="predictions.csv">Prediction data (CSV)</a> ·
<a href="README.md">Methodology and interpretation</a> · <a href="run_metadata.json">Run metadata</a></p>
<small>Selection and training are repeated using earlier history before each later block.
The learning curve is a separate one-day-ahead diagnostic. Generated sales cannot establish real vendor accuracy.</small></div>
<section><h2>All {metadata['category_count']} supported categories</h2>
<p>Mango Carabao, Indian Mango, and Apple Mango are separate categories. Guava is excluded.
Missing history is shown explicitly, without invented sales or zero error scores.</p>
<div class="scroll">{coverage_table}</div>
<h2>Labels needing review</h2><div class="scroll">{issues_table}</div>
<p><a href="category_coverage.csv">Category coverage CSV</a> · <a href="category_review.csv">Records needing review</a> ·
<a href="input_reconciliation.json">Reconciled input totals</a></p></section>
<section><h2>Does the forecast help sales planning?</h2>
<p>Compare daily errors, {metadata['horizon_days']}-day total errors, and performance against the recent average.
Positive improvement means smaller daily errors than the average. Tolerance checks need limits chosen with the vendor.</p>
<p>Daily tolerance: {display(metadata['daily_tolerance_kg'], suffix=' kg')}; period tolerance:
{display(metadata['period_tolerance_kg'], suffix=' kg')}; target share within tolerance:
{display(metadata['target_within_tolerance_percent'], suffix='%')}.</p>
<div class="scroll">{vendor_table}</div>
<p>Expected sales must be compared with usable stock and delivery timing before buying.
Forecast under- or overestimation does not measure actual spoilage or lost sales.</p>
<p><a href="vendor_assessment.csv">Vendor assessment CSV</a> · <a href="period_metrics.csv">Period error CSV</a> ·
<a href="selection_history.csv">Methods chosen before each forecast</a></p></section>
{cards}</main></html>""", encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=ROOT / "assets/data/cdo_sample_sales_2026.json")
    parser.add_argument("--output", type=Path, default=ROOT / "reports/forecast_evaluation/revised_sample")
    parser.add_argument("--test-weeks", type=int, default=4)
    parser.add_argument("--horizon-days", type=int, default=7)
    parser.add_argument("--exclude-generated", action="store_true")
    parser.add_argument("--history-complete", action="store_true",
                        help="Declare that all operating-day sales, including zero sales, are represented.")
    parser.add_argument("--daily-tolerance-kg", type=float,
                        help="Vendor-chosen acceptable absolute error per fruit/day; no default.")
    parser.add_argument("--period-tolerance-kg", type=float,
                        help="Vendor-chosen acceptable error in each fruit's horizon total; no default.")
    parser.add_argument("--target-within-tolerance-percent", type=float,
                        help="Vendor-chosen share of forecasts that should meet the specified tolerance.")
    args = parser.parse_args(argv)
    if args.test_weeks < 1 or not 1 <= args.horizon_days <= 14:
        parser.error("Use at least one test week/block and a horizon of 1–14 days.")
    for tolerance in [args.daily_tolerance_kg, args.period_tolerance_kg]:
        if tolerance is not None and (not math.isfinite(tolerance) or tolerance < 0):
            parser.error("Tolerances must be finite, nonnegative kilograms.")
    if args.target_within_tolerance_percent is not None:
        if not 0 < args.target_within_tolerance_percent <= 100:
            parser.error("The target share must be greater than zero and at most 100 percent.")
        if args.daily_tolerance_kg is None and args.period_tolerance_kg is None:
            parser.error("Specify a daily or period tolerance before choosing a target share.")
    source_transactions, partial = load_sales(args.input, args.exclude_generated)
    transactions, issues = split_supported_sales(source_transactions)
    if transactions.empty:
        raise ValueError("No sales have a supported specific category. Confirm mango varieties and category names first.")
    daily = server._daily_sales_frame(transactions)
    predictions, development, selection = backtest(daily, args.test_weeks, args.horizon_days)
    metrics = summarize(predictions, ["model"], args.daily_tolerance_kg).set_index("model").loc[MODELS].reset_index()
    totals = planning_totals(predictions, args.horizon_days)
    period_metrics = summarize(totals, ["model"], args.period_tolerance_kg).rename(columns={"fruit_days": "fruit_periods"})
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
        "evaluation_source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "metrics_source_sha256": hashlib.sha256((ROOT / "tool/forecast_metrics.py").read_bytes()).hexdigest(),
        "category_asset_sha256": hashlib.sha256(CATEGORY_PATH.read_bytes()).hexdigest(),
        "category_source_sha256": hashlib.sha256((ROOT / "tool/fruit_categories.py").read_bytes()).hexdigest(),
        "seasonality_source_sha256": hashlib.sha256((ROOT / "tool/forecast_seasonality.py").read_bytes()).hexdigest(),
        "psa_asset_sha256": hashlib.sha256((ROOT / "assets/data/psa_market_history.json").read_bytes()).hexdigest(),
        "provenance": provenance,
        "transaction_count": len(transactions), "generated_transactions": generated,
        "source_transaction_count": len(source_transactions),
        "category_issue_count": len(issues),
        "category_count": len(FRUIT_CATEGORIES),
        "fruit_count": int(transactions["fruit"].nunique()),
        "sales_start": str(transactions["date"].min()), "sales_end": str(transactions["date"].max()),
        "excluded_partial_day": str(partial) if partial else None,
        "development_end": str(development["date"].max().date()),
        "learning_validation_start": str(validation_start.date()),
        "test_start": str(predictions["date"].min().date()),
        "test_end": str(predictions["date"].max().date()),
        "test_weeks": args.test_weeks, "horizon_days": args.horizon_days,
        "evaluated_fruit_days": int(len(predictions) / len(MODELS)),
        "evaluated_fruit_periods": int(len(totals) / len(MODELS)),
        "assumed_zero_fruit_days": int(daily["assumed_zero"].sum()),
        "history_complete_declared": args.history_complete,
        "daily_tolerance_kg": args.daily_tolerance_kg,
        "period_tolerance_kg": args.period_tolerance_kg,
        "target_within_tolerance_percent": args.target_within_tolerance_percent,
        "selected_on_development": selection["selectedModel"],
        "versions": {"python": platform.python_version(), "numpy": np.__version__,
                     "pandas": pd.__version__, "xgboost": xgboost.__version__, "matplotlib": matplotlib.__version__},
        "parameters": server._train_model(server._training_frame(development)[0]).get_params(),
    }
    coverage = category_coverage(transactions, predictions)
    assessment = coverage[["fruit", "history_status", "evaluation_status"]].merge(
        vendor_assessment(predictions, totals, metadata), on="fruit", how="left"
    )
    assessment["assessment"] = assessment["assessment"].fillna(assessment["evaluation_status"])
    coverage.to_csv(output / "category_coverage.csv", index=False)
    issues.to_csv(output / "category_review.csv", index=False)

    def source_totals(rows):
        return {"transactions": len(rows), "kilograms": float(rows["weight_kg"].sum()),
                "revenue_centavos": int(rows["total_centavos"].sum())}

    (output / "input_reconciliation.json").write_text(json.dumps({
        "completed_closed_day_input": source_totals(source_transactions),
        "included_in_analysis": source_totals(transactions),
        "excluded_for_category_review": source_totals(issues),
        "scope": "After status, date, weight, and optional generated-record filters; before category resolution",
        "original_input_modified": False,
    }, indent=2), encoding="utf-8")
    predictions.to_csv(output / "predictions.csv", index=False)
    metrics.to_csv(output / "model_metrics.csv", index=False)
    comparison = predictions.pivot(
        index=["block", "date", "fruit", "actual_kg"],
        columns="model", values="predicted_kg",
    ).reset_index()
    comparison.to_csv(output / "actual_vs_predicted.csv", index=False)
    daily.to_csv(output / "daily_sales.csv", index=False)
    learning.to_csv(output / "learning_curve.csv", index=False)
    totals.to_csv(output / "period_predictions.csv", index=False)
    period_metrics.to_csv(output / "period_metrics.csv", index=False)
    summarize(totals, ["model", "fruit"], args.period_tolerance_kg).rename(
        columns={"fruit_days": "fruit_periods"}
    ).to_csv(output / "fruit_period_metrics.csv", index=False)
    assessment.to_csv(output / "vendor_assessment.csv", index=False)
    predictions[predictions["model"] == "Selected policy"][[
        "block", "training_end", "forecast_start", "fruit", "model_used"
    ]].drop_duplicates().to_csv(output / "selection_history.csv", index=False)
    for filename, columns in [("fruit_metrics.csv", ["model", "fruit"]),
                              ("block_metrics.csv", ["model", "block"]),
                              ("horizon_metrics.csv", ["model", "horizon_day"])]:
        summarize(predictions, columns, args.daily_tolerance_kg).to_csv(output / filename, index=False)
    (output / "development_selection.json").write_text(json.dumps(selection, indent=2, allow_nan=False), encoding="utf-8")
    # get_params may contain NaN defaults; retain only explicitly serializable values.
    metadata["parameters"] = {k: v for k, v in metadata["parameters"].items()
                              if v is not None and not (isinstance(v, float) and math.isnan(v))}
    (output / "run_metadata.json").write_text(json.dumps(metadata, indent=2, allow_nan=False), encoding="utf-8")
    print("Generating local PNG and PDF figures...", flush=True)
    figures = generate_figures(output, transactions, daily, predictions, metrics, learning, provenance,
                               totals, assessment, args.horizon_days, coverage, issues)
    write_report(output, metadata, metrics, figures, period_metrics, assessment, coverage, issues)
    print(metrics[["model", "mae_kg", "rmse_kg", "wape_percent"]].to_string(index=False))
    print(f"\n{provenance}\nOpen: {output / 'index.html'}", flush=True)


if __name__ == "__main__":
    main()
