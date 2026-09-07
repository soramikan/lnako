#!/usr/bin/env python3
"""Small regression test for the streaming Windows trace analyzer."""

from __future__ import annotations

import json
import collections
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from analyze_numeric_trace import (  # noqa: E402
    _counter_log,
    _required_trace_failures,
    _runtime_evidence,
    _symbol_map_evidence,
    _time_ns,
    analyze,
    main,
)


def _event(body: str) -> str:
    return f"<Event>{body}</Event>"


def _sample(timestamp: str, ip: int, tid: int, cpu: int, event_guid: str | None = "{ce1dbfb4-137e-4da6-87b0-3f59aa102cbc}") -> str:
    payload = struct.pack("<QII", ip, tid, 1).hex()
    tracing = (
        f'<ExtendedTracingInfo><EventGuid>{event_guid}</EventGuid></ExtendedTracingInfo>'
        if event_guid is not None
        else ""
    )
    return _event(
        f'<System><Opcode>46</Opcode><TimeCreated SystemTime="{timestamp}"/>'
        f'<Execution ProcessorID="{cpu}"/></System>'
        f'<BinaryEventData>{payload}</BinaryEventData>'
        f"{tracing}"
    )


def _process(timestamp: str, opcode: str, pid: int, image: str | None = None) -> str:
    image_data = f'<Data Name="ImageFileName">{image}</Data>' if image is not None else ""
    return _event(
        f'<System><Opcode>1</Opcode><TimeCreated SystemTime="{timestamp}"/></System><EventData>'
        f'<Data Name="ProcessId">0x{pid:x}</Data>{image_data}</EventData>'
        f'<RenderingInfo><Opcode>{opcode}</Opcode><EventName>Process</EventName></RenderingInfo>'
    )


def _thread(timestamp: str, opcode: str, pid: int, tid: int) -> str:
    payload = struct.pack("<II", pid, tid).hex()
    return _event(
        f'<System><Opcode>1</Opcode><TimeCreated SystemTime="{timestamp}"/></System>'
        f'<ProcessingErrorData><EventPayload>{payload}</EventPayload></ProcessingErrorData>'
        f'<RenderingInfo><Opcode>{opcode}</Opcode><EventName>Thread</EventName></RenderingInfo>'
    )


def _image(timestamp: str, opcode: str, pid: int, base: int, size: int, path: str) -> str:
    return _event(
        f'<System><Opcode>10</Opcode><TimeCreated SystemTime="{timestamp}"/></System><EventData>'
        f'<Data Name="ImageBase">0x{base:x}</Data><Data Name="ImageSize">0x{size:x}</Data>'
        f'<Data Name="ProcessId">0x{pid:x}</Data><Data Name="FileName">{path}</Data></EventData>'
        f'<RenderingInfo><Opcode>{opcode}</Opcode><EventName>Image</EventName></RenderingInfo>'
    )


class NumericTraceAnalyzerTest(unittest.TestCase):
    def test_require_usable_trace_rejects_empty_samples_after_writing_report(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            trace = directory / "events.xml"
            output = directory / "analysis.json"
            trace.write_text("<Events></Events>\n", encoding="utf-8")

            exit_code = main([
                "--input", str(trace),
                "--output", str(output),
                "--require-usable-trace",
            ])

            self.assertEqual(exit_code, 2)
            self.assertTrue(output.is_file())
            result = json.loads(output.read_text(encoding="utf-8"))
            failures = _required_trace_failures(result)
            self.assertIn("no SampledProfile events were decoded", failures)
            self.assertIn("no SampledProfile event joined the target process", failures)
            self.assertIn("no SampledProfile event joined the target executable", failures)

    def test_require_usable_trace_rejects_explicit_event_loss(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            trace = directory / "events.xml"
            output = directory / "analysis.json"
            trace.write_text(
                "<Events>"
                + _process("2026-01-01T00:00:00.0000000+00:00", "Start", 0x42, "C:\\nbody.exe")
                + _thread("2026-01-01T00:00:00.0010000+00:00", "Start", 0x42, 100)
                + _image("2026-01-01T00:00:00.0011000+00:00", "Load", 0x42, 0x100000, 0x4000, "C:\\nbody.exe")
                + _sample("2026-01-01T00:00:00.0020000+00:00", 0x101020, 100, 0)
                + "</Events>",
                encoding="utf-8",
            )
            (directory / "trace-summary.txt").write_text(
                "Total Events  Processed 4\nTotal Events  Lost 2\n", encoding="utf-8"
            )

            exit_code = main([
                "--input", str(trace),
                "--output", str(output),
                "--require-usable-trace",
            ])

            self.assertEqual(exit_code, 2)
            result = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(result["mapping"]["outcomes"]["nbody_process"], 1)
            self.assertEqual(result["mapping"]["outcomes"]["nbody_executable"], 1)
            self.assertEqual(_required_trace_failures(result), ["trace summary reports 2 lost events"])

    def test_require_usable_trace_accepts_valid_join_without_loss(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            trace = directory / "events.xml"
            output = directory / "analysis.json"
            trace.write_text(
                "<Events>"
                + _process("2026-01-01T00:00:00.0000000+00:00", "Start", 0x42, "C:\\nbody.exe")
                + _thread("2026-01-01T00:00:00.0010000+00:00", "Start", 0x42, 100)
                + _image("2026-01-01T00:00:00.0011000+00:00", "Load", 0x42, 0x100000, 0x4000, "C:\\nbody.exe")
                + _sample("2026-01-01T00:00:00.0020000+00:00", 0x101020, 100, 0)
                + "</Events>",
                encoding="utf-8",
            )
            (directory / "trace-summary.txt").write_text(
                "Total Events  Processed 4\nTotal Events  Lost 0\n", encoding="utf-8"
            )

            exit_code = main([
                "--input", str(trace),
                "--output", str(output),
                "--require-usable-trace",
            ])

            self.assertEqual(exit_code, 0)
            result = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(_required_trace_failures(result), [])

    def test_allocator_availability_distinguishes_missing_from_zero(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / "runtime-counters.log"
            for active, failures, status in [
                (0, 0, "not observed by this runtime (disabled or borrowed allocator)"),
                (0, 1, "initialization failed; values are unavailable"),
                (1, 0, "observed by this runtime"),
            ]:
                path.write_text(
                    f"lnako perf counters: .{{ .allocator_telemetry_active = {active}, "
                    f".allocator_telemetry_init_failures = {failures}, .allocator_alloc_calls = 0 }}\n",
                    encoding="utf-8",
                )
                self.assertEqual(_runtime_evidence(directory)["allocator_telemetry_status"], status)

    def test_multiple_runtime_reports_are_not_merged_or_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            path = directory / "runtime-counters.log"
            path.write_text(
                "lnako perf counters: .{ .allocator_alloc_calls = 486 }\n"
                "lnako perf counters: .{ .allocator_alloc_calls = 663 }\n", encoding="utf-8",
            )
            result = _runtime_evidence(directory)
            self.assertEqual(_counter_log(path), {})
            self.assertEqual(result["counter_context_count"], 2)
            self.assertEqual(result["counter_values"], {})
            self.assertEqual(result["counter_contexts"], [
                {"allocator_alloc_calls": 486}, {"allocator_alloc_calls": 663},
            ])

    def test_nested_helper_counters_keep_entry_names(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "runtime-counters.log"
            path.write_text(
                "lnako perf counters: .{ .allocations = 3, "
                ".aot_math_value = .{ .calls = 12, .successes = 11, .failures = 1 }, "
                ".aot_math_f64 = runtime.counters.Counters.AotEntryCounters{ .calls = 9, .successes = 9, .failures = 0 }, "
                ".gc_mark_ns = 42 }\n", encoding="utf-8",
            )
            result = _counter_log(path)
            self.assertEqual(result["allocations"], 3)
            self.assertEqual(result["gc_mark_ns"], 42)
            self.assertEqual(result["aot_math_value_calls"], 12)
            self.assertEqual(result["aot_math_value_failures"], 1)
            self.assertEqual(result["aot_math_f64_calls"], 9)
            self.assertNotIn("calls", result)
            self.assertNotIn("failures", result)

    def test_reads_llvm_lldmap_rva_rows_and_bounds_zero_size_symbols(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            map_path = Path(temporary) / "probe.map"
            map_path.write_text(
                "Address  Size     Align Out     In      Symbol\n"
                "00001000 00000010  4096 .text\n"
                "00001000 00000010    16         probe.obj:(.text)\n"
                "00001000 00000000     0                 main\n"
                "00002000 00000008  4096 .rdata\n"
                "00002000 00000008     4         probe.obj:(.xdata)\n",
                encoding="utf-8",
            )

            result = _symbol_map_evidence(
                map_path,
                collections.Counter({0x1000: 2, 0x1005: 3, 0x1010: 4}),
                0x140000000,
            )

            self.assertEqual(result["format"], "lld-link-rva")
            self.assertEqual(result["address_kind"], "rva")
            self.assertEqual(result["preferred_image_base"], "0x140000000")
            self.assertEqual(result["symbol_count"], 1)
            self.assertEqual(result["zero_size_symbol_count"], 1)
            self.assertEqual(result["symbol_resolution"], "link-map")
            self.assertEqual(result["sampled_symbol_top"][0]["name"], "main")
            self.assertEqual(result["sampled_symbol_top"][0]["count"], 5)
            self.assertEqual(result["sampled_symbol_top"][0]["effective_size"], 0x10)
            self.assertEqual(result["unresolved_sample_count"], 4)

    def test_joins_sample_thread_process_and_image_intervals(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            trace = directory / "nbody-events.xml"
            trace.write_text(
                "<Events>"
                + _event(
                    '<System><Opcode>1</Opcode><TimeCreated SystemTime="2026-01-01T00:00:00.0000000+00:00"/>'
                    "</System><EventData>"
                    '<Data Name="ProcessId">0x42</Data><Data Name="ImageFileName">nbody.exe</Data>'
                    "</EventData><RenderingInfo><Opcode>Start</Opcode><EventName>Process</EventName>"
                    "</RenderingInfo>"
                )
                + _event(
                    '<System><Opcode>1</Opcode><TimeCreated SystemTime="2026-01-01T00:00:00.0010000+00:00"/>'
                    "</System><ProcessingErrorData><EventPayload>4200000064000000</EventPayload>"
                    "</ProcessingErrorData><RenderingInfo><Opcode>Start</Opcode><EventName>Thread</EventName>"
                    "</RenderingInfo>"
                )
                + _event(
                    '<System><Opcode>10</Opcode><TimeCreated SystemTime="2026-01-01T00:00:00.0011000+00:00"/>'
                    "</System><EventData>"
                    '<Data Name="ImageBase">0x100000</Data><Data Name="ImageSize">0x4000</Data>'
                    '<Data Name="ProcessId">66</Data><Data Name="FileName">C:\\nbody.exe</Data>'
                    "</EventData><RenderingInfo><Opcode>Load</Opcode><EventName>Image</EventName>"
                    "</RenderingInfo>"
                )
                + _sample("2026-01-01T00:00:00.0020000+00:00", 0x101020, 100, 2)
                + _sample("2026-01-01T00:00:00.0025000+00:00", 0xFFFFF802C3C9D28F, 999, 1)
                + _event(
                    '<System><Opcode>2</Opcode><TimeCreated SystemTime="2026-01-01T00:00:00.0030000+00:00"/>'
                    "</System><ProcessingErrorData><EventPayload>4200000064000000</EventPayload>"
                    "</ProcessingErrorData><RenderingInfo><Opcode>End</Opcode><EventName>Thread</EventName>"
                    "</RenderingInfo>"
                )
                + _event(
                    '<System><Opcode>2</Opcode><TimeCreated SystemTime="2026-01-01T00:00:00.0040000+00:00"/>'
                    '</System><EventData><Data Name="ProcessId">0x42</Data></EventData>'
                    "<RenderingInfo><Opcode>End</Opcode><EventName>Process</EventName></RenderingInfo>"
                )
                + "</Events>",
                encoding="utf-8",
            )
            (directory / "runtime-counters.log").write_text(
                "lnako perf counters: .{ .allocations = 3, .allocated_bytes = 24, .gc_collections = 1, .gc_scanned_objects = 2 }\n",
                encoding="utf-8",
            )
            (directory / "profile.json").write_text(
                json.dumps({"code": {"static_call_sites": {"lnako_aot_arithmetic": 1}, "typed_definitions": []}}),
                encoding="utf-8",
            )
            (directory / "imports-symbols.txt").write_text("Symbols [\n]\n", encoding="utf-8")
            (directory / "linked-disassembly.txt").write_text(
                "nbody.exe: file format coff-x86-64\n"
                "140001000: 90                            nop\n"
                "140001020: e8 00 00 00 00                  callq 0x140001025 <.text+0x1025>\n",
                encoding="utf-8",
            )
            (directory / "nbody.map").write_text(
                " Preferred load address is 0000000140000000\n"
                " Address         Publics by Value              Rva+Base\n"
                " 0001:00001000       _main                     0000000140001000\n"
                " 0001:00001020       _helper                   0000000140001020\n",
                encoding="utf-8",
            )
            (directory / "trace-summary.txt").write_text(
                "Total Events  Processed 2\nTotal Events  Lost 0\n"
                "|          2   PerfInfo             0               46              2               {ce1dbfb4-137e-4da6-87b0-3f59aa102cbc}|\n",
                encoding="utf-8",
            )
            output = directory / "analysis.json"

            result = analyze(trace, output)

            self.assertEqual(result["mapping"]["sample_events"], 2)
            self.assertEqual(result["mapping"]["outcomes"]["nbody_process"], 1)
            self.assertEqual(result["mapping"]["outcomes"]["nbody_executable"], 1)
            self.assertEqual(result["mapping"]["process"]["target_pid_count"], 1)
            self.assertEqual(result["trace_summary"]["sampled_profile_events"], 2)
            self.assertEqual(result["runtime_gc_allocator"]["managed_object_and_payload_fields"]["allocations"], 3)
            self.assertEqual(result["static_abi"]["profile_static_call_sites"]["lnako_aot_arithmetic"], 1)
            self.assertTrue(result["static_abi"]["pe_symbols_empty"])
            self.assertEqual(result["linked_disassembly"]["instruction_count"], 2)
            self.assertEqual(result["linked_disassembly"]["preferred_image_base"], "0x140000000")
            self.assertEqual(result["linked_disassembly"]["sample_nearest_instructions"][0]["rva"], "0x1020")
            self.assertEqual(result["mapping"]["target_ip_top"][0]["rva"], "0x1020")
            self.assertEqual(result["mapping"]["target_cpu_distribution"][0], {"value": "2", "count": 1})
            self.assertEqual(result["symbol_map"]["symbol_resolution"], "link-map")
            self.assertEqual(result["symbol_map"]["sampled_symbol_top"][0]["name"], "_helper")
            self.assertEqual(result["static_abi"]["sampled_function_names"], "link-map")
            self.assertEqual(result["static_abi"]["sampling_address_resolution"]["symbol_names"], "link-map")
            self.assertEqual(result["linked_disassembly"]["symbol_resolution"], "link-map")
            self.assertIn("linker map", result["interpretation"]["address_join"])
            self.assertFalse(any("function-name unresolved" in item for item in result["missing_information"]))
            self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["schema"], "lnako.numeric-trace-analysis.v1")
            self.assertTrue(result["input"]["trace"]["sha256"])

    def test_does_not_extend_final_map_symbol_past_a_proven_range(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            map_path = Path(temporary) / "public.map"
            map_path.write_text(
                " Preferred load address is 0000000140000000\n"
                " Address         Publics by Value              Rva+Base\n"
                " 0001:00001000       _only                     0000000140001000\n",
                encoding="utf-8",
            )

            result = _symbol_map_evidence(
                map_path,
                collections.Counter({0x1000: 1, 0x9000: 2}),
                None,
            )

            self.assertEqual(result["symbol_resolution"], "link-map")
            self.assertEqual(result["sampled_symbol_top"][0]["name"], "_only")
            self.assertEqual(result["sampled_symbol_top"][0]["count"], 1)
            self.assertEqual(result["unresolved_sample_count"], 2)

    def test_requires_perfinfo_guid_and_preserves_100ns_timestamps(self) -> None:
        self.assertEqual(_time_ns("1970-01-01T00:00:00.0000001Z"), 100)
        self.assertEqual(
            _time_ns("2026-09-07T04:26:56.102326800+00:00")
            - _time_ns("2026-09-07T04:26:56.102326700+00:00"),
            100,
        )
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            trace = directory / "events.xml"
            trace.write_text(
                "<Events>"
                + _sample("2026-01-01T00:00:00.0010000+00:00", 0x100010, 10, 0, event_guid=None)
                + _sample("2026-01-01T00:00:00.0010001+00:00", 0x100010, 10, 0)
                + "</Events>",
                encoding="utf-8",
            )

            result = analyze(trace)

            self.assertEqual(result["mapping"]["sample_events"], 1)
            self.assertEqual(result["mapping"]["sample_time_range"]["duration_ms"], 0.0)

    def test_pid_and_tid_reuse_requires_the_active_target_process(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            trace = directory / "events.xml"
            trace.write_text(
                "<Events>"
                + _process("2026-01-01T00:00:00.0000000+00:00", "Start", 0x42, "C:\\nbody.exe")
                + _thread("2026-01-01T00:00:00.0010000+00:00", "Start", 0x42, 100)
                + _image("2026-01-01T00:00:00.0011000+00:00", "Load", 0x42, 0x100000, 0x4000, "C:\\nbody.exe")
                + _sample("2026-01-01T00:00:00.0020000+00:00", 0x101020, 100, 0)
                + _thread("2026-01-01T00:00:00.0030000+00:00", "End", 0x42, 100)
                + _process("2026-01-01T00:00:00.0031000+00:00", "End", 0x42)
                + _process("2026-01-01T00:00:00.0040000+00:00", "Start", 0x42, "C:\\other.exe")
                + _thread("2026-01-01T00:00:00.0041000+00:00", "Start", 0x42, 100)
                + _image("2026-01-01T00:00:00.0042000+00:00", "Load", 0x42, 0x200000, 0x4000, "C:\\other.exe")
                + _sample("2026-01-01T00:00:00.0050000+00:00", 0x201020, 100, 0)
                + _thread("2026-01-01T00:00:00.0051000+00:00", "Start", 0x77, 200)
                + _sample("2026-01-01T00:00:00.0060000+00:00", 0x201020, 200, 0)
                + "</Events>",
                encoding="utf-8",
            )

            result = analyze(trace)
            outcomes = result["mapping"]["outcomes"]

            self.assertEqual(result["mapping"]["sample_events"], 3)
            self.assertEqual(outcomes["nbody_process"], 1)
            self.assertEqual(outcomes["nbody_executable"], 1)
            self.assertEqual(outcomes["other_process"], 1)
            self.assertEqual(outcomes["process_interval_unresolved"], 1)
            self.assertEqual(result["mapping"]["process"]["target_pids"], {"0x42": 1})
            self.assertEqual(result["mapping"]["process"]["target_threads"], {"100": 1})


if __name__ == "__main__":
    unittest.main()
