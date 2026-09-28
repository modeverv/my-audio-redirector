import copy
import importlib.util
import json
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import wave

import numpy as np


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "analyze-latency.py"
spec = importlib.util.spec_from_file_location("analyze_latency", SCRIPT)
latency = importlib.util.module_from_spec(spec)
spec.loader.exec_module(latency)


def block_stream(name, values, rate=48000., host_origin=10000., sample_origin=0., arrival_offset=.002):
    blocks = []
    for start in range(0, len(values), 64):
        data = values[start:start + 64]
        host = host_origin + start / rate
        blocks.append({"sampleTime": sample_origin + start, "hostSeconds": host,
                       "arrivalSeconds": host + arrival_offset, "timeFlags": 7,
                       "frames": len(data), "samples": data.ravel().tolist()})
    return {"name": name, "channels": 2, "blocks": blocks}


def synthetic_capture(delay=.0073125, ppm=0, periodic=False, unrelated=False, stereo_delays=None):
    rate = 48000
    duration = 2.
    reference = latency.test_signal(duration=3, level_dbfs=-42, seed=123)
    timeline = np.arange(len(reference)) / rate
    output_rate = rate * (1 + ppm * 1e-6)
    input_times = .5 + np.arange(round(duration * rate)) / rate
    output_times = .5 + np.arange(round(duration * output_rate)) / output_rate
    if periodic:
        reference = np.column_stack([.005 * np.sin(2 * np.pi * f * timeline) for f in (1000, 1500)])
    source = np.column_stack([np.interp(input_times, timeline, reference[:, c]) for c in range(2)])
    output_reference = latency.test_signal(duration=3, level_dbfs=-42, seed=456) if unrelated else reference
    output = np.column_stack([np.interp(output_times - (stereo_delays[c] if stereo_delays else delay),
                                       timeline, output_reference[:, c]) * (-.75 if c == 1 else .6) for c in range(2)])
    return {"sampleRate": rate, "streams": [
        block_stream("pc_tap", source, sample_origin=-12345.25),
        block_stream("d4_output", output, rate=output_rate, sample_origin=987654.75, arrival_offset=-.003),
    ]}


class LatencyTests(unittest.TestCase):
    def analyze(self, capture, **kwargs):
        return latency.analyze_capture(capture, pairs=[("pc_tap", "d4_output")], **kwargs)["pairs"][0]

    def test_fractional_delay_independent_origins_rates_and_inversion(self):
        for ppm in (0, 100, -100):
            result = self.analyze(synthetic_capture(ppm=ppm))
            self.assertEqual(result["status"], "measured")
            for channel in result["channels"]:
                self.assertAlmostEqual(channel["latency_ms"]["median"], 7.3125, delta=.022)
                self.assertGreaterEqual(channel["accepted_windows"], 5)
                self.assertGreater(channel["correlation"]["min"], .9)
                self.assertAlmostEqual(channel["callback_entry_difference_ms"]["median_window_mean"], 2.3125, delta=.04)
            self.assertTrue(all(w["polarity"] == -1 for w in result["windows"] if w["channel"] == 2))

    def test_stereo_delay_is_reported_per_channel(self):
        result = self.analyze(synthetic_capture(stereo_delays=[.004, .009]))
        self.assertEqual(result["status"], "measured")
        self.assertAlmostEqual(result["channels"][0]["latency_ms"]["median"], 4, delta=.022)
        self.assertAlmostEqual(result["channels"][1]["latency_ms"]["median"], 9, delta=.022)
        self.assertAlmostEqual(result["channel_median_skew_ms"], 5, delta=.022)

    def test_periodic_and_unrelated_audio_are_unmeasured(self):
        for options in ({"periodic": True}, {"unrelated": True}):
            result = self.analyze(synthetic_capture(**options))
            self.assertEqual(result["status"], "unmeasured")
            self.assertTrue(all(c["accepted_windows"] == 0 for c in result["channels"]))

    def test_silence_and_clipping_are_unmeasured(self):
        capture = synthetic_capture()
        for block in capture["streams"][0]["blocks"]:
            block["samples"] = [0.] * (block["frames"] * 2)
        self.assertEqual(self.analyze(capture)["status"], "unmeasured")
        capture = synthetic_capture()
        for stream in capture["streams"]:
            for block in stream["blocks"]:
                block["samples"] = np.clip(np.asarray(block["samples"]) * 1000, -1, 1).tolist()
        self.assertEqual(self.analyze(capture)["status"], "unmeasured")

    def test_upper_search_boundary_rejected_but_zero_delay_valid(self):
        upper = self.analyze(synthetic_capture(delay=.100))
        self.assertEqual(upper["status"], "unmeasured")
        self.assertTrue(all(w["search_boundary_peak"] and "upper lag bound" in w["reason"] for w in upper["windows"]))
        zero = self.analyze(synthetic_capture(delay=0))
        self.assertEqual(zero["status"], "measured")
        self.assertTrue(all(w["search_boundary_peak"] and w["status"] == "accepted" for w in zero["windows"]))
        for channel in zero["channels"]:
            self.assertEqual(channel["latency_ms"]["median"], 0)

    def test_invalid_flags_gaps_and_nonfinite_data_are_unmeasured(self):
        original = synthetic_capture()
        for field, value in (("timeFlags", 2), ("sampleTime", 0), ("hostSeconds", 0), ("samples", [float("nan")] * 128)):
            capture = copy.deepcopy(original)
            capture["streams"][0]["blocks"][10][field] = value
            result = self.analyze(capture)
            self.assertEqual(result["status"], "unmeasured")
            self.assertIn("reason", result)

    def test_extra_unrelated_audio_rejects_contaminated_windows(self):
        capture = synthetic_capture()
        rng = np.random.default_rng(1)
        # Contaminate the second half strongly, while retaining >=3 good windows.
        for block in capture["streams"][1]["blocks"][900:]:
            block["samples"] = (np.asarray(block["samples"]) + rng.normal(0, .02, 128)).tolist()
        result = self.analyze(capture)
        self.assertEqual(result["status"], "measured")
        self.assertTrue(any(w["status"] == "rejected" for w in result["windows"]))
        for channel in result["channels"]:
            self.assertAlmostEqual(channel["latency_ms"]["median"], 7.3125, delta=.022)

    def test_ambiguous_fx_echo_is_unmeasured(self):
        first = synthetic_capture(delay=.005)
        second = synthetic_capture(delay=.025)
        for a, b in zip(first["streams"][1]["blocks"], second["streams"][1]["blocks"]):
            a["samples"] = (.5 * (np.asarray(a["samples"]) + np.asarray(b["samples"]))).tolist()
        self.assertEqual(self.analyze(first)["status"], "unmeasured")

    def test_capture_health_and_capacity_are_mandatory_when_present(self):
        original = synthetic_capture()
        healthy = {"fault": 0, "nonFinite": 0, "clipped": 0,
                   "sources": [{"underruns": 0, "overflows": 0} for _ in range(3)]}
        original.update({"success": True, "cleanupConfirmed": True,
                         "beforeStop": dict(healthy, state="running"), "afterStop": dict(healthy, state="off")})
        self.assertTrue(latency.analyze_capture(original, pairs=[("pc_tap", "d4_output")])["capture_health"]["verified"])
        for mode in ("success", "cleanup", "fault", "nonfinite", "clipped", "underrun", "capacity", "frames"):
            capture = copy.deepcopy(original)
            if mode == "success": capture["success"] = False
            elif mode == "cleanup": capture["cleanupConfirmed"] = False
            elif mode == "fault": capture["afterStop"]["fault"] = 6
            elif mode == "nonfinite": capture["beforeStop"]["nonFinite"] = 1
            elif mode == "clipped": capture["beforeStop"]["clipped"] = 1
            elif mode == "underrun": capture["beforeStop"]["sources"][0]["underruns"] = 1
            elif mode == "capacity": capture["streams"][0]["capacityExceeded"] = True
            elif mode == "frames": capture["streams"][0]["frames"] = 1
            self.assertEqual(self.analyze(capture)["status"], "unmeasured", mode)

    def test_wav_is_quiet_independent_and_not_played(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "probe.wav"
            report = latency.generate_wav(path, duration=10)
            self.assertFalse(report["played"])
            with wave.open(str(path), "rb") as wav:
                self.assertEqual((wav.getframerate(), wav.getnchannels(), wav.getnframes()), (48000, 2, 480000))
                values = np.frombuffer(wav.readframes(480000), dtype="<i2").reshape(-1, 2) / 32767
            self.assertLessEqual(np.max(np.abs(values)), 10 ** (-42 / 20) + 1 / 32767)
            self.assertLess(abs(np.corrcoef(values.T)[0, 1]), .02)
            self.assertTrue(np.all(values[0] == 0) and np.all(values[-1] == 0))

    def test_cli_preserves_report_and_nonzero_status_for_unmeasured(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "capture.json"
            output = Path(directory) / "report.json"
            source.write_text(json.dumps(synthetic_capture(periodic=True)))
            code = latency.main([str(source), "--pair", "pc_tap:d4_output", "--output", str(output)])
            self.assertEqual(code, 1)
            report = json.loads(output.read_text())
            self.assertEqual(report["pairs"][0]["status"], "unmeasured")
            self.assertIn("Not an ADC/DAC", report["boundary"])

    def test_cli_reads_standard_input(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            with patch("sys.stdin", io.StringIO(json.dumps(synthetic_capture()))):
                code = latency.main(["-", "--pair", "pc_tap:d4_output", "--output", str(output)])
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(output.read_text())["pairs"][0]["status"], "measured")


if __name__ == "__main__":
    unittest.main()
