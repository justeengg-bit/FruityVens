"""Forecast errors in kilograms, shared by the service and local evaluation."""

from __future__ import annotations

import numpy as np
import pandas as pd


def error_metrics(rows: pd.DataFrame, tolerance_kg: float | None = None) -> dict:
    actual = rows["actual_kg"].to_numpy(dtype=float)
    predicted = rows["predicted_kg"].to_numpy(dtype=float)
    if not len(actual) or not (np.isfinite(actual).all() and np.isfinite(predicted).all()):
        raise ValueError("Metrics require nonempty, finite actuals and predictions.")
    if tolerance_kg is not None and (not np.isfinite(tolerance_kg) or tolerance_kg < 0):
        raise ValueError("The acceptable error must be a finite, nonnegative kg value.")
    error = predicted - actual
    absolute = np.abs(error)
    total = float(actual.sum())
    return {
        "mae_kg": float(absolute.mean()),
        "rmse_kg": float(np.sqrt(np.mean(error ** 2))),
        "wape_percent": float(absolute.sum() / total * 100) if total > 0 else None,
        "bias_kg": float(error.mean()),
        "underforecast_kg": float(np.maximum(-error, 0).sum()),
        "overforecast_kg": float(np.maximum(error, 0).sum()),
        "within_tolerance_percent": float(np.mean(absolute <= tolerance_kg) * 100)
        if tolerance_kg is not None else None,
        "tolerance_kg": tolerance_kg,
        "actual_kg": total,
        "predicted_kg": float(predicted.sum()),
        "fruit_days": len(rows),
    }
