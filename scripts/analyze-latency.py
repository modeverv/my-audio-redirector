#!/usr/bin/env python3
"""Analyze a bounded callback-buffer capture, or generate a quiet test WAV.

Requires NumPy. This script never opens an audio device. Capture samples remain
in memory while analyzing; the report contains numerical results, not audio.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import sys
import wave

import numpy as np


BOUNDARY = (
    "Difference between driver-reported host timestamps of corresponding audio "
    "frames in the named callback buffers. Not an ADC/DAC, acoustic, or original "
    "application-to-PC-Tap latency measurement."
)
ARRIVAL_BOUNDARY = (
    "Output callback entry minus input callback entry for matched frames; "
    "includes callback block phase and is not output completion or presentation latency."
)
DEFAULT_PAIRS = [("pc_tap", "d4_output"), ("d4_return", "rme_output")]


class CaptureError(ValueError):
    pass


def finite_number(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise CaptureError(f"{label} must be a finite number")
    return float(value)


def db(value):
    return 20 * math.log10(max(float(value), 1e-15))


class Stream:
    def __init__(self, record, nominal_rate):
        self.name = record.get("name", "unnamed")
        if "capacityExceeded" in record and record["capacityExceeded"] is not False:
            raise CaptureError(f"{self.name}: capture capacity was exceeded or unknown")
        if record.get("channels") != 2:
            raise CaptureError(f"{self.name}: exactly two channels are required")
        blocks = record.get("blocks", [])
        if len(blocks) < 2:
            raise CaptureError(f"{self.name}: at least two timestamped blocks are required")
        hosts, sample_times, arrivals, lengths, arrays = [], [], [], [], []
        for number, block in enumerate(blocks):
            prefix = f"{self.name} block {number}"
            frames = block.get("frames")
            if isinstance(frames, bool) or not isinstance(frames, int) or not 0 < frames <= 4096:
                raise CaptureError(f"{prefix}: frames must be 1..4096")
            flags = block.get("timeFlags")
            if isinstance(flags, bool) or not isinstance(flags, int) or flags & 3 != 3:
                raise CaptureError(f"{prefix}: valid sampleTime and hostTime flags are required")
            host = finite_number(block.get("hostSeconds"), f"{prefix} hostSeconds")
            sample = finite_number(block.get("sampleTime"), f"{prefix} sampleTime")
            arrival = finite_number(block.get("arrivalSeconds"), f"{prefix} arrivalSeconds")
            values = np.asarray(block.get("samples", []), dtype=np.float64)
            if values.ndim != 1 or values.size != frames * 2 or not np.all(np.isfinite(values)):
                raise CaptureError(f"{prefix}: samples must contain exactly frames*2 finite values")
            if hosts and (host <= hosts[-1] or abs(sample - sample_times[-1] - lengths[-1]) > .5):
                raise CaptureError(f"{prefix}: discontinuous sample timeline or non-increasing host time")
            hosts.append(host); sample_times.append(sample); arrivals.append(arrival)
            lengths.append(frames); arrays.append(values.reshape(frames, 2))
        self.hosts = np.asarray(hosts)
        self.arrivals = np.asarray(arrivals)
        self.lengths = np.asarray(lengths)
        sample_times = np.asarray(sample_times)
        # Estimate each device's rate independently. Sample-time origins are
        # never compared across devices. Center before fitting large clocks.
        h = self.hosts - np.mean(self.hosts)
        s = sample_times - np.mean(sample_times)
        self.rate = float(np.dot(h, s) / np.dot(h, h))
        if not math.isfinite(self.rate) or abs(self.rate / nominal_rate - 1) > .01:
            raise CaptureError(f"{self.name}: timestamp rate differs from nominal by more than 1%")
        residual = h - s / self.rate
        self.fit_residual_us = float(np.max(np.abs(residual)) * 1e6)
        self.values = np.concatenate(arrays)
        if "frames" in record and record["frames"] != len(self.values):
            raise CaptureError(f"{self.name}: reported frame count does not match captured blocks")
        self.times = np.concatenate([host + np.arange(n) / self.rate for host, n in zip(hosts, lengths)])
        if np.any(np.diff(self.times) <= 0):
            raise CaptureError(f"{self.name}: timestamp blocks overlap or run backwards")
        self.start = float(self.times[0])
        self.end = float(self.times[-1])

    def at(self, times, channel):
        return np.interp(times, self.times, self.values[:, channel], left=np.nan, right=np.nan)

    def arrivals_at(self, times):
        indices = np.searchsorted(self.hosts, times, side="right") - 1
        return self.arrivals[np.clip(indices, 0, len(self.arrivals) - 1)]

    def description(self):
        return {
            "name": self.name, "frames": len(self.values), "blocks": len(self.hosts),
            "estimated_sample_rate": self.rate,
            "rate_offset_ppm": (self.rate / 48000 - 1) * 1e6,
            "clock_fit_max_residual_us": self.fit_residual_us,
            "host_duration_seconds": self.end - self.start,
        }


def correlate_window(x, y, rate, min_correlation, min_margin, min_fit_snr_db):
    """Normalized valid cross-correlation: y is longer by the lag range."""
    n, count = len(x), len(y) - len(x) + 1
    if not np.all(np.isfinite(x)) or not np.all(np.isfinite(y)):
        return {"status": "rejected", "reason": "capture does not cover this host-time window"}
    x = x - np.mean(x)
    y = y - np.mean(y)
    energy = float(np.dot(x, x))
    rms = math.sqrt(energy / n)
    if rms < 10 ** (-90 / 20):
        return {"status": "rejected", "reason": "input is silent or below -90 dBFS RMS"}
    fft_size = 1 << (n + len(y) - 2).bit_length()
    cross = np.fft.irfft(np.fft.rfft(y, fft_size) * np.conj(np.fft.rfft(x, fft_size)), fft_size)[:count]
    sums = np.concatenate(([0.], np.cumsum(y)))
    squares = np.concatenate(([0.], np.cumsum(y * y)))
    total = sums[n:] - sums[:-n]
    output_energy = np.maximum(squares[n:] - squares[:-n] - total * total / n, 0)
    denominator = np.sqrt(energy * output_energy)
    correlations = np.divide(cross, denominator, out=np.zeros_like(cross), where=denominator > 1e-30)
    correlations = np.clip(correlations, -1, 1)
    magnitude = np.abs(correlations)
    peak = int(np.argmax(magnitude))
    # Exclude only the main lobe, not other periodic matches or echoes.
    exclusion = max(1, round(rate * .001))
    alternatives = magnitude.copy()
    alternatives[max(0, peak - exclusion):min(count, peak + exclusion + 1)] = 0
    second = float(np.max(alternatives))
    fraction = 0.
    if 0 < peak < count - 1:
        left, center, right = magnitude[peak - 1:peak + 2]
        curvature = left - 2 * center + right
        if curvature < -1e-12:
            fraction = float(np.clip(.5 * (left - right) / curvature, -.5, .5))
    aligned = np.interp(np.arange(n) + peak + fraction, np.arange(len(y)), y)
    aligned -= np.mean(aligned)
    gain = float(np.dot(x, aligned) / energy)
    predicted = gain * x
    residual = aligned - predicted
    fit_snr = 10 * math.log10(max(float(np.dot(predicted, predicted)), 1e-30) /
                            max(float(np.dot(residual, residual)), 1e-30))
    coefficient = float(magnitude[peak])
    margin = coefficient - second
    reasons = []
    if coefficient < min_correlation:
        reasons.append("weak correlation (unrelated audio, noise, or FX transformation)")
    if margin < min_margin:
        reasons.append("ambiguous correlation peak (periodic signal or multiple delays)")
    if fit_snr < min_fit_snr_db:
        reasons.append("poor delayed-signal fit")
    if count > 1 and peak == count - 1:
        reasons.append("correlation peak reaches upper lag bound; delay may be outside search range")
    return {
        "status": "rejected" if reasons else "accepted", "reason": "; ".join(reasons) if reasons else None,
        "lag_frames": peak + fraction, "correlation": coefficient,
        "second_peak_correlation": second, "peak_margin": margin,
        "fit_snr_db": fit_snr, "gain": gain, "polarity": 1 if gain >= 0 else -1,
        "input_rms_dbfs": db(rms), "search_boundary_peak": peak in (0, count - 1),
    }


def distribution(values):
    return {"median": float(np.median(values)), "min": float(np.min(values)), "max": float(np.max(values))}


def capture_health(capture):
    issues = []
    if "success" in capture and capture["success"] is not True:
        issues.append("capture CLI did not report success" + (f": {capture['error']}" if capture.get("error") else ""))
    if "cleanupConfirmed" in capture and capture["cleanupConfirmed"] is not True:
        issues.append("capture cleanup was not confirmed")
    for name, expected_state in (("beforeStop", "running"), ("afterStop", "off")):
        if name not in capture:
            continue
        status = capture[name]
        if not isinstance(status, dict):
            issues.append(f"{name}: missing status object")
            continue
        for field in ("fault", "nonFinite", "clipped"):
            if status.get(field) != 0:
                issues.append(f"{name}: {field} is nonzero or unknown")
        if "state" in status and status["state"] != expected_state:
            issues.append(f"{name}: state is not {expected_state}")
        sources = status.get("sources")
        if not isinstance(sources, list) or len(sources) != 3:
            issues.append(f"{name}: three source health records are required")
        else:
            for index, source in enumerate(sources):
                if not isinstance(source, dict) or source.get("underruns") != 0 or source.get("overflows") != 0:
                    issues.append(f"{name}: source {index} has underrun/overflow or missing counters")
    verified = all(key in capture for key in ("success", "cleanupConfirmed", "beforeStop", "afterStop"))
    return {"verified": verified and not issues, "issues": issues,
            "note": None if verified else "Raw capture has no complete CLI health envelope; only supplied health fields can be checked."}


def analyze_pair(source, destination, rate=48000, window_seconds=.3, max_lag_ms=100,
                 min_correlation=.8, min_margin=.15, min_fit_snr_db=3, min_windows=3):
    n = round(rate * window_seconds)
    lag_frames = round(rate * max_lag_ms / 1000)
    start = max(source.start, destination.start)
    last_start = min(source.end - (n - 1) / rate, destination.end - (n + lag_frames - 1) / rate)
    count = max(0, int(math.floor((last_start - start) / window_seconds + 1e-7)) + 1)
    windows, channels = [], []
    for number in range(count):
        t0 = start + number * window_seconds
        input_times = t0 + np.arange(n) / rate
        output_times = t0 + np.arange(n + lag_frames) / rate
        for channel in range(2):
            x, y = source.at(input_times, channel), destination.at(output_times, channel)
            result = correlate_window(x, y, rate, min_correlation, min_margin, min_fit_snr_db)
            result.update({"window": number, "channel": channel + 1, "input_host_start_seconds": t0})
            if "lag_frames" in result:
                delay = result.pop("lag_frames") / rate
                result["latency_ms"] = delay * 1000
                result["latency_frames_at_nominal_rate"] = delay * rate
                result["matched_output_host_start_seconds"] = t0 + delay
                arrival = (destination.arrivals_at(input_times + delay) - source.arrivals_at(input_times)) * 1000
                result["callback_entry_difference_ms"] = {
                    "mean": float(np.mean(arrival)), "min": float(np.min(arrival)), "max": float(np.max(arrival))}
                aligned = destination.at(input_times + delay, channel)
                if max(float(np.max(np.abs(x))), float(np.max(np.abs(aligned)))) >= .999:
                    result["status"] = "rejected"
                    result["reason"] = "clipped or full-scale samples in matched window"
            windows.append(result)
    for channel in (1, 2):
        accepted = [w for w in windows if w["channel"] == channel and w["status"] == "accepted"]
        row = {"channel": channel, "status": "measured" if len(accepted) >= min_windows else "unmeasured",
               "accepted_windows": len(accepted), "total_windows": count}
        if row["status"] == "measured":
            row["latency_ms"] = distribution([w["latency_ms"] for w in accepted])
            row["latency_frames_at_nominal_rate"] = distribution([w["latency_frames_at_nominal_rate"] for w in accepted])
            row["correlation"] = distribution([w["correlation"] for w in accepted])
            row["peak_margin"] = distribution([w["peak_margin"] for w in accepted])
            row["fit_snr_db"] = distribution([w["fit_snr_db"] for w in accepted])
            row["callback_entry_difference_ms"] = {
                "median_window_mean": float(np.median([w["callback_entry_difference_ms"]["mean"] for w in accepted])),
                "min": min(w["callback_entry_difference_ms"]["min"] for w in accepted),
                "max": max(w["callback_entry_difference_ms"]["max"] for w in accepted)}
        else:
            row["reason"] = f"fewer than {min_windows} unambiguous windows; silence, other audio, or FX may prevent matching"
        channels.append(row)
    measured = all(c["status"] == "measured" for c in channels)
    return {
        "input": source.name, "output": destination.name, "status": "measured" if measured else "unmeasured",
        "channels": channels, "windows": windows,
        "channel_median_skew_ms": abs(channels[0]["latency_ms"]["median"] - channels[1]["latency_ms"]["median"]) if measured else None,
    }


def analyze_capture(capture, pairs=None, **options):
    rate = finite_number(capture.get("sampleRate"), "sampleRate")
    if rate != 48000:
        raise CaptureError("this capture format currently requires sampleRate=48000")
    health = capture_health(capture)
    streams, errors, descriptions = {}, {}, []
    for record in capture.get("streams", []):
        name = record.get("name")
        if not isinstance(name, str) or name in streams or name in errors:
            raise CaptureError("stream names must be unique strings")
        try:
            streams[name] = Stream(record, rate)
            descriptions.append(streams[name].description())
        except (CaptureError, ValueError, TypeError) as error:
            errors[name] = str(error)
    results = []
    for source, destination in pairs or DEFAULT_PAIRS:
        invalid = [errors.get(name, f"missing stream {name}") for name in (source, destination) if name not in streams]
        invalid.extend(health["issues"])
        if invalid:
            results.append({"input": source, "output": destination, "status": "unmeasured", "reason": "; ".join(invalid)})
        else:
            results.append(analyze_pair(streams[source], streams[destination], rate=rate, **options))
    return {
        "schema": 1, "sample_rate": rate, "boundary": BOUNDARY, "arrival_boundary": ARRIVAL_BOUNDARY,
        "method": "independent timestamp-rate fit, common host-time grid, per-channel normalized cross-correlation",
        "notes": [
            "fit_snr_db is delayed linear-fit signal/residual ratio, not a hardware noise-floor measurement.",
            "Fractional peak interpolation improves the estimate; it does not establish sub-sample hardware accuracy.",
            "No device/stream latency or FIFO/SRC estimate is added to measured timestamp differences.",
            "Only accepted windows contribute to summaries; rejected windows remain in the report.",
        ],
        "analysis_settings": {"window_seconds": options.get("window_seconds", .3),
                              "lag_search_ms": [0, options.get("max_lag_ms", 100)],
                              "min_correlation": options.get("min_correlation", .8),
                              "min_peak_margin": options.get("min_margin", .15),
                              "min_fit_snr_db": options.get("min_fit_snr_db", 3),
                              "min_accepted_windows_per_channel": options.get("min_windows", 3)},
        "capture_health": health, "streams": descriptions, "stream_errors": errors, "pairs": results,
    }


def test_signal(rate=48000, duration=10., level_dbfs=-42., seed=270928):
    if not 1 <= duration <= 60 or not -80 <= level_dbfs <= -12:
        raise CaptureError("WAV duration must be 1..60 seconds and peak level -80..-12 dBFS")
    frames = round(rate * duration)
    rng = np.random.default_rng(seed)
    samples = rng.standard_normal((frames, 2))
    frequencies = np.fft.rfftfreq(frames, 1 / rate)
    # Non-repeating, independently seeded stereo, limited to 150 Hz..8 kHz.
    response = np.ones_like(frequencies)
    response[frequencies < 150] = 0
    response[frequencies > 8000] = 0
    low = (frequencies >= 150) & (frequencies < 300)
    high = (frequencies > 7000) & (frequencies <= 8000)
    response[low] = .5 - .5 * np.cos(np.pi * (frequencies[low] - 150) / 150)
    response[high] = .5 + .5 * np.cos(np.pi * (frequencies[high] - 7000) / 1000)
    samples = np.fft.irfft(np.fft.rfft(samples, axis=0) * response[:, None], n=frames, axis=0)
    samples *= 10 ** (level_dbfs / 20) / np.max(np.abs(samples), axis=0)
    fade = min(round(rate * .02), frames // 2)
    ramp = .5 - .5 * np.cos(np.linspace(0, np.pi, fade))
    samples[:fade] *= ramp[:, None]
    samples[-fade:] *= ramp[::-1, None]
    return samples


def generate_wav(path, duration=10., level_dbfs=-42., seed=270928):
    samples = test_signal(duration=duration, level_dbfs=level_dbfs, seed=seed)
    pcm = np.rint(samples * 32767).astype("<i2")
    with wave.open(str(path), "wb") as output:
        output.setnchannels(2); output.setsampwidth(2); output.setframerate(48000)
        output.writeframes(pcm.tobytes())
    return {"path": str(path), "sample_rate": 48000, "channels": 2, "duration_seconds": duration,
            "peak_dbfs": level_dbfs, "rms_dbfs": [db(np.sqrt(np.mean(samples[:, c] ** 2))) for c in range(2)],
            "seed": seed, "signal": "independent non-repeating stereo PRNG noise, 150 Hz..8 kHz, 20 ms fades",
            "played": False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", nargs="?", default="-", help="capture JSON file, or - for stdin")
    parser.add_argument("--output", type=Path, help="write analysis JSON to this file instead of stdout")
    parser.add_argument("--pair", action="append", help="INPUT:OUTPUT; repeat for multiple paths")
    parser.add_argument("--window-seconds", type=float, default=.3)
    parser.add_argument("--max-lag-ms", type=float, default=100)
    parser.add_argument("--min-correlation", type=float, default=.8)
    parser.add_argument("--min-peak-margin", type=float, default=.15)
    parser.add_argument("--min-fit-snr-db", type=float, default=3)
    parser.add_argument("--min-windows", type=int, default=3)
    parser.add_argument("--generate-wav", type=Path, help="only create a test WAV; never play it")
    parser.add_argument("--duration", type=float, default=10)
    parser.add_argument("--level-dbfs", type=float, default=-42)
    parser.add_argument("--seed", type=int, default=270928)
    args = parser.parse_args(argv)
    try:
        if args.generate_wav:
            result = generate_wav(args.generate_wav, args.duration, args.level_dbfs, args.seed)
            code = 0
        else:
            if not .05 <= args.window_seconds <= 2 or not 0 < args.max_lag_ms <= 1000 or args.min_windows < 1:
                raise CaptureError("window must be .05..2 seconds, lag 0..1000 ms, and min-windows >=1")
            if not 0 < args.min_correlation <= 1 or not 0 <= args.min_peak_margin <= 1 or not math.isfinite(args.min_fit_snr_db):
                raise CaptureError("invalid correlation quality thresholds")
            pairs = None
            if args.pair:
                pairs = []
                for value in args.pair:
                    pieces = value.split(":")
                    if len(pieces) != 2 or not all(pieces):
                        raise CaptureError("--pair requires INPUT:OUTPUT")
                    pairs.append(tuple(pieces))
            if args.capture == "-":
                capture = json.load(sys.stdin)
            else:
                with open(args.capture, encoding="utf-8") as file:
                    capture = json.load(file)
            result = analyze_capture(capture, pairs=pairs, window_seconds=args.window_seconds,
                                     max_lag_ms=args.max_lag_ms, min_correlation=args.min_correlation,
                                     min_margin=args.min_peak_margin, min_fit_snr_db=args.min_fit_snr_db,
                                     min_windows=args.min_windows)
            code = 0 if all(pair["status"] == "measured" for pair in result["pairs"]) else 1
        payload = json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
        if args.output:
            args.output.write_text(payload, encoding="utf-8")
        else:
            print(payload, end="")
        return code
    except (CaptureError, ValueError, TypeError, KeyError, OSError) as error:
        print(f"latency analysis: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
