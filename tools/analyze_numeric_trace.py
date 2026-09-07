#!/usr/bin/env python3
"""Analyze a Windows WPR CPU trace exported by ``tracerpt -of XML``.

The XML export can be hundreds of megabytes, so the parser intentionally uses
``ElementTree.iterparse`` and keeps only process/thread/image intervals,
sample records, and aggregate counters.  SampledProfile (PerfInfo opcode 46)
records carry an instruction pointer and thread id while the exported System
element does not reliably carry a process id.  Thread start/end payloads and
Image load/unload intervals are therefore joined by timestamp.

This tool reports observed address/module distributions.  It does not invent
function names when both the PE symbol table and a linker map are absent; in
that case it reports RVA and nearest linked-disassembly instruction text only.
When ``nbody.map`` (or ``--symbol-map``) is present, it joins sampled RVAs to
the lld-link/ld64 map and records the map path and hash with the artifacts.
"""

from __future__ import annotations

import argparse
import bisect
import collections
import dataclasses
import datetime as _datetime
import hashlib
import json
import platform
import re
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Iterable, Optional


PERFINFO_GUID = "{ce1dbfb4-137e-4da6-87b0-3f59aa102cbc}"
SAMPLED_PROFILE_OPCODE = "46"
SCHEMA = "lnako.numeric-trace-analysis.v1"
SAMPLED_PROFILE_REFERENCE = "https://learn.microsoft.com/en-us/windows/win32/etw/sampledprofile"
PERFINFO_REFERENCE = "https://learn.microsoft.com/en-us/windows/win32/etw/perfinfo"


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _parse_int(value: Optional[str]) -> Optional[int]:
    if value is None:
        return None
    text = value.strip().replace(",", "")
    if not text:
        return None
    try:
        return int(text, 16 if text.lower().startswith("0x") else 10)
    except ValueError:
        return None


def _time_ns(value: Optional[str]) -> Optional[int]:
    if not value:
        return None
    try:
        parsed = _datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_datetime.timezone.utc)
    # ``datetime.timestamp`` returns a float.  ETW timestamps commonly carry
    # seven fractional digits (100 ns), and converting a 2026 timestamp via a
    # float loses hundreds of nanoseconds before the interval join.  Keep the
    # fraction from the source text and do the epoch arithmetic with integers.
    fraction_match = re.search(r"\.(\d+)(?=(?:Z|[+-]\d{2}:?\d{2})?$)", value.strip())
    fraction_ns = int((fraction_match.group(1) + "000000000")[:9]) if fraction_match else 0
    epoch = _datetime.datetime(1970, 1, 1, tzinfo=_datetime.timezone.utc)
    whole_second = parsed.astimezone(_datetime.timezone.utc).replace(microsecond=0)
    delta = whole_second - epoch
    return (delta.days * 86_400 + delta.seconds) * 1_000_000_000 + fraction_ns


def _guid_key(value: Optional[str]) -> str:
    if not value:
        return ""
    return value.strip().strip("{}").lower()


def _is_perfinfo_sample(system: dict[str, str]) -> bool:
    if system.get("opcode") != SAMPLED_PROFILE_OPCODE:
        return False
    # tracerpt places the PerfInfo provider in ExtendedTracingInfo/EventGuid;
    # some exports instead retain it as System/Provider Guid.  Require one of
    # those explicit provider identifiers so an unrelated opcode 46 event is
    # never interpreted as a CPU sample just because its GUID is omitted.
    perfinfo = _guid_key(PERFINFO_GUID)
    return any(
        _guid_key(system.get(name)) == perfinfo
        for name in ("event_guid", "provider_guid")
        if system.get(name)
    )


def _basename(value: str) -> str:
    return re.split(r"[\\/]", value)[-1].lower()


def _child(element: ET.Element, name: str) -> Optional[ET.Element]:
    return next((item for item in element if _local_name(item.tag) == name), None)


def _data_map(element: ET.Element) -> dict[str, str]:
    container = _child(element, "EventData")
    if container is None:
        return {}
    return {
        child.attrib.get("Name", ""): (child.text or "").strip()
        for child in container
        if _local_name(child.tag) == "Data"
    }


def _rendering(element: ET.Element) -> dict[str, str]:
    container = _child(element, "RenderingInfo")
    if container is None:
        return {}
    return {
        _local_name(child.tag): (child.text or "")
        for child in container
        if _local_name(child.tag) in {"EventName", "Opcode", "Provider"}
    }


def _system(element: ET.Element) -> dict[str, str]:
    container = _child(element, "System")
    if container is None:
        return {}
    result: dict[str, str] = {}
    for child in container:
        name = _local_name(child.tag)
        if name == "TimeCreated":
            result["time"] = child.attrib.get("SystemTime", "")
        elif name == "Opcode":
            result["opcode"] = child.text or ""
        elif name == "Provider":
            result["provider_guid"] = child.attrib.get("Guid", "")
        elif name == "Execution":
            result.update({key.lower(): value for key, value in child.attrib.items()})
    extended = _child(element, "ExtendedTracingInfo")
    if extended is not None:
        event_guid = _child(extended, "EventGuid")
        if event_guid is not None:
            result["event_guid"] = event_guid.text or ""
    return result


def _payload_hex(element: ET.Element) -> str:
    direct = _child(element, "BinaryEventData")
    if direct is not None:
        return "".join((direct.text or "").split())
    processing = _child(element, "ProcessingErrorData")
    if processing is not None:
        payload = _child(processing, "EventPayload")
        if payload is not None:
            return "".join((payload.text or "").split())
    return ""


def _payload_pid_tid(element: ET.Element, data: dict[str, str]) -> tuple[Optional[int], Optional[int]]:
    payload = _payload_hex(element)
    if len(payload) >= 16:
        try:
            return struct.unpack("<II", bytes.fromhex(payload[:16]))
        except ValueError:
            pass
    process_id = _parse_int(data.get("ProcessId"))
    thread_id = _parse_int(data.get("ThreadId"))
    return process_id, thread_id


@dataclasses.dataclass
class ProcessInterval:
    pid: int
    start_ns: int
    end_ns: Optional[int]
    image: str
    command_line: str


@dataclasses.dataclass
class ThreadInterval:
    pid: int
    tid: int
    start_ns: int
    end_ns: Optional[int]


@dataclasses.dataclass
class ModuleInterval:
    pid: int
    base: int
    size: int
    path: str
    start_ns: int
    end_ns: Optional[int]


@dataclasses.dataclass
class Sample:
    time_ns: int
    ip: int
    tid: int
    count: int
    cpu: Optional[int]


class TraceCollector:
    """Collect the small amount of state needed to join ETW records."""

    def __init__(self, target_image: str) -> None:
        self.target_image = target_image.lower()
        self.processes: list[ProcessInterval] = []
        self.threads: list[ThreadInterval] = []
        self.modules: list[ModuleInterval] = []
        self.samples: list[Sample] = []
        self.event_counts: collections.Counter[str] = collections.Counter()
        self._open_processes: collections.defaultdict[int, list[ProcessInterval]] = collections.defaultdict(list)
        self._open_threads: collections.defaultdict[tuple[int, int], list[ThreadInterval]] = collections.defaultdict(list)
        self._open_modules: collections.defaultdict[tuple[int, int, int, str], list[ModuleInterval]] = collections.defaultdict(list)
        self.trace_start_ns: Optional[int] = None
        self.trace_end_ns: Optional[int] = None

    def _record_event_time(self, timestamp: Optional[str]) -> Optional[int]:
        parsed = _time_ns(timestamp)
        if parsed is None:
            return None
        if self.trace_start_ns is None or parsed < self.trace_start_ns:
            self.trace_start_ns = parsed
        if self.trace_end_ns is None or parsed > self.trace_end_ns:
            self.trace_end_ns = parsed
        return parsed

    def _close_process(self, pid: int, timestamp: Optional[int]) -> None:
        if timestamp is None:
            return
        for interval in reversed(self._open_processes[pid]):
            if interval.end_ns is None:
                interval.end_ns = timestamp
                return

    def _close_thread(self, pid: int, tid: int, timestamp: Optional[int]) -> None:
        if timestamp is None:
            return
        for interval in reversed(self._open_threads[(pid, tid)]):
            if interval.end_ns is None:
                interval.end_ns = timestamp
                return

    def _close_module(self, pid: int, base: int, timestamp: Optional[int]) -> None:
        if timestamp is None:
            return
        candidates = [
            item
            for key, intervals in self._open_modules.items()
            if key[0] == pid and key[1] == base
            for item in reversed(intervals)
            if item.end_ns is None
        ]
        if candidates:
            candidates[0].end_ns = timestamp

    def consume(self, element: ET.Element) -> None:
        rendered = _rendering(element)
        system = _system(element)
        data = _data_map(element)
        timestamp = self._record_event_time(system.get("time"))
        rendered_opcode = rendered.get("Opcode", "")
        event_name = rendered.get("EventName", "")
        provider = rendered.get("Provider", "") or system.get("provider_guid", "") or system.get("event_guid", "")
        count_key = f"{provider or event_name or 'unknown'}/{rendered_opcode or system.get('opcode', '')}"
        self.event_counts[count_key] += 1

        if event_name == "Process" and rendered_opcode in {"Start", "End", "Terminate"}:
            pid = _parse_int(data.get("ProcessId"))
            if pid is not None and timestamp is not None:
                if rendered_opcode == "Start":
                    interval = ProcessInterval(pid, timestamp, None, data.get("ImageFileName", ""), data.get("CommandLine", ""))
                    self.processes.append(interval)
                    self._open_processes[pid].append(interval)
                else:
                    self._close_process(pid, timestamp)

        if event_name == "Thread" and rendered_opcode in {"Start", "End"}:
            pid, tid = _payload_pid_tid(element, data)
            if pid is not None and tid is not None and timestamp is not None:
                if rendered_opcode == "Start":
                    interval = ThreadInterval(pid, tid, timestamp, None)
                    self.threads.append(interval)
                    self._open_threads[(pid, tid)].append(interval)
                else:
                    self._close_thread(pid, tid, timestamp)

        if event_name == "Image" and rendered_opcode in {"Load", "DCStart", "UnLoad"}:
            pid = _parse_int(data.get("ProcessId"))
            base = _parse_int(data.get("ImageBase"))
            size = _parse_int(data.get("ImageSize"))
            path = data.get("FileName", "")
            if pid is not None and base is not None and timestamp is not None:
                if rendered_opcode in {"Load", "DCStart"} and size is not None and size > 0:
                    key = (pid, base, size, path.lower())
                    interval = ModuleInterval(pid, base, size, path, timestamp, None)
                    self.modules.append(interval)
                    self._open_modules[key].append(interval)
                elif rendered_opcode == "UnLoad":
                    self._close_module(pid, base, timestamp)

        if _is_perfinfo_sample(system):
            payload = _payload_hex(element)
            try:
                ip, tid, count = struct.unpack("<QII", bytes.fromhex(payload))
            except (ValueError, struct.error):
                ip = tid = count = None
            if ip is not None and tid is not None and timestamp is not None:
                cpu = _parse_int(system.get("processorid"))
                self.samples.append(Sample(timestamp, ip, tid, count, cpu))

    def finalize(self) -> None:
        end = self.trace_end_ns or 0
        for interval in self.processes:
            if interval.end_ns is None:
                interval.end_ns = end
        for interval in self.threads:
            if interval.end_ns is None:
                interval.end_ns = end
        for interval in self.modules:
            if interval.end_ns is None:
                interval.end_ns = end


def _parse_trace(path: Path, target_image: str) -> TraceCollector:
    collector = TraceCollector(target_image)
    context = ET.iterparse(path, events=("start", "end"))
    _, root = next(context)
    for event, element in context:
        if event != "end" or _local_name(element.tag) != "Event":
            continue
        collector.consume(element)
        element.clear()
        root.clear()
    collector.finalize()
    return collector


def _active(intervals: Iterable[object], timestamp_ns: int) -> Optional[object]:
    candidates = [
        interval
        for interval in intervals
        if interval.start_ns <= timestamp_ns and (interval.end_ns is None or timestamp_ns <= interval.end_ns)
    ]
    return max(candidates, key=lambda item: item.start_ns) if candidates else None


def _counter_items(counter: collections.Counter, limit: int = 30) -> list[dict[str, object]]:
    return [{"value": str(value), "count": count} for value, count in counter.most_common(limit)]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _artifact_metadata(directory: Path, names: Iterable[str]) -> tuple[dict[str, dict[str, object]], list[str]]:
    artifacts: dict[str, dict[str, object]] = {}
    missing: list[str] = []
    for name in names:
        path = directory / name
        if not path.is_file():
            missing.append(name)
            continue
        artifacts[name] = {"path": str(path), "bytes": path.stat().st_size, "sha256": _sha256(path)}
    return artifacts, missing


def _read_json(path: Path) -> Optional[dict[str, object]]:
    if not path.is_file():
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def _counter_log_contexts(path: Path) -> list[dict[str, int]]:
    if not path.is_file():
        return []
    # Dynamic runtimes can report more than one context. Keep each report
    # separate: nested allocators may overlap, so summing is not meaningful.
    text = path.read_text(encoding="utf-8", errors="replace")
    return [_parse_counter_record(line) for line in text.splitlines() if "lnako perf counters:" in line]


def _counter_log(path: Path) -> dict[str, int]:
    contexts = _counter_log_contexts(path)
    return contexts[0] if len(contexts) == 1 else {}


def _parse_counter_record(text: str) -> dict[str, int]:
    values: dict[str, int] = {}
    pattern = re.compile(r"\.([A-Za-z0-9_]+)\s*=\s*([0-9]+)")
    # Zig prints helper entry counters as nested structs. Preserve their
    # namespace so repeated `calls`/`successes`/`failures` never overwrite one
    # another or appear to be a process-wide total.
    nested = re.compile(r"\.([A-Za-z0-9_]+)\s*=\s*(?:[A-Za-z_][A-Za-z0-9_.]*|\.)?\s*\{([^{}]*)\}")
    def flatten(match: re.Match) -> str:
        for field in pattern.finditer(match.group(2)):
            values[f"{match.group(1)}_{field.group(1)}"] = int(field.group(2))
        return ""
    text = nested.sub(flatten, text)
    for match in pattern.finditer(text):
        values[match.group(1)] = int(match.group(2))
    return values


def _trace_summary(path: Path) -> dict[str, object]:
    if not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8", errors="replace")
    result: dict[str, object] = {}
    for key, pattern in {
        "events_processed": r"Total Events\s+Processed\s+([0-9,]+)",
        "events_lost": r"Total Events\s+Lost\s+([0-9,]+)",
        "sampled_profile_events": r"\|\s*([0-9,]+)\s+PerfInfo\s+0\s+46\s+2\s+\{",
        "stackwalk_events": r"\|\s*([0-9,]+)\s+StackWalk\s+0\s+Stack\s+2\s+\{",
    }.items():
        match = re.search(pattern, text)
        if match:
            result[key] = int(match.group(1).replace(",", ""))
    return result


def _symbol_table_empty(path: Path) -> Optional[bool]:
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"Symbols\s*\[\s*\]", text, re.DOTALL)
    return match is not None


def _linked_disassembly(path: Path, sample_rvas: collections.Counter[int]) -> dict[str, object]:
    if not path.is_file():
        return {"available": False}
    # The dump starts with a Windows path such as ``D:\\...\\nbody.exe:``.
    # Requiring a sufficiently long hexadecimal address followed by whitespace
    # keeps that header from being mistaken for an instruction at RVA 0xd.
    address_pattern = re.compile(r"^([0-9A-Fa-f]{8,}):\s")
    instructions: list[tuple[int, str]] = []
    call_count = 0
    sqrt_addresses: list[int] = []
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = address_pattern.match(line)
            if not match:
                continue
            address = int(match.group(1), 16)
            text = line.rstrip()[:240]
            instructions.append((address, text))
            if re.search(r"\bcall(?:q|l)?\b", text):
                call_count += 1
            if re.search(r"\b(?:v?sqrt\w*|fsqrt)\b", text, re.IGNORECASE):
                sqrt_addresses.append(address)
    if not instructions:
        return {"available": True, "instruction_count": 0, "call_instruction_count": 0, "sqrt_instruction_count": 0}
    instructions.sort()
    addresses = [address for address, _ in instructions]
    preferred_base = min(addresses) & ~0xFFFFF
    nearest_counter: collections.Counter[tuple[int, str, int]] = collections.Counter()
    nearest_sqrt = 0
    if sample_rvas:
        for rva, count in sample_rvas.items():
            target = preferred_base + rva
            index = bisect.bisect_right(addresses, target) - 1
            if index < 0:
                continue
            instruction_address, text = instructions[index]
            delta = target - instruction_address
            nearest_counter[(instruction_address - preferred_base, text, delta)] += count
            if text.lower().find("sqrt") >= 0 and delta <= 32:
                nearest_sqrt += count
    return {
        "available": True,
        "instruction_count": len(instructions),
        "call_instruction_count": call_count,
        "sqrt_instruction_count": len(sqrt_addresses),
        "preferred_image_base": f"0x{preferred_base:x}",
        "sqrt_rvas": [f"0x{address - preferred_base:x}" for address in sqrt_addresses],
        "sample_nearest_instructions": [
            {"rva": f"0x{address:x}", "delta": delta, "count": count, "text": text}
            for (address, text, delta), count in nearest_counter.most_common(30)
        ],
        "sample_near_sqrt_count": nearest_sqrt,
        "symbol_resolution": "address-only; function names require a non-empty PE symbol table",
    }


@dataclasses.dataclass(frozen=True)
class MapSymbol:
    address: int
    size: Optional[int]
    name: str
    section_end: Optional[int] = None


@dataclasses.dataclass(frozen=True)
class MapSection:
    address: int
    size: int
    name: str


def _parse_map_address(value: str) -> Optional[int]:
    value = value.strip().rstrip(",")
    if value.lower().startswith("0x"):
        value = value[2:]
    if not value or not re.fullmatch(r"[0-9A-Fa-f]+", value):
        return None
    return int(value, 16)


def _load_symbol_map(path: Path) -> tuple[list[MapSymbol], Optional[int], str, list[MapSection]]:
    """Read the symbol rows emitted by lld-link and ld64-style map files."""

    if not path.is_file():
        return [], None, "missing", []
    symbols: list[MapSymbol] = []
    sections: list[MapSection] = []
    preferred_base: Optional[int] = None
    map_format = "unknown"
    in_symbols = False
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            stripped = line.strip()
            preferred_match = re.search(r"Preferred\s+load\s+address\s+is\s+((?:0x)?[0-9A-Fa-f]+)", line, re.IGNORECASE)
            if preferred_match:
                preferred_base = _parse_map_address(preferred_match.group(1))
                map_format = "lld-link"
            if re.match(r"^\s*Address\s+Size\s+Align\s+Out\s+In\s+Symbol\b", line, re.IGNORECASE):
                in_symbols = True
                map_format = "lld-link-rva"
                continue
            if stripped.lower().startswith("# symbols:") or "Publics by Value" in line:
                in_symbols = True
                if "Publics by Value" in line:
                    map_format = "lld-link"
                continue
            if stripped.lower().startswith("# sections:"):
                in_symbols = False
                continue
            if not in_symbols and map_format not in {"lld-link", "lld-link-rva"}:
                continue

            # LLVM 22 lld-link's private /lldmap format is an RVA table:
            # Address Size Align Out In Symbol
            # 00001000 00000000 0 main
            # A zero-size, zero-align row is a symbol.  Section rows are
            # retained so a final symbol can be bounded without guessing.
            if map_format == "lld-link-rva":
                rva_row = re.match(
                    r"^\s*((?:0x)?[0-9A-Fa-f]{8,})\s+((?:0x)?[0-9A-Fa-f]{8,})\s+(\d+)\s+(.+?)\s*$",
                    line,
                )
                if rva_row:
                    address = _parse_map_address(rva_row.group(1))
                    size = _parse_map_address(rva_row.group(2))
                    align = int(rva_row.group(3), 10)
                    tail = rva_row.group(4).strip()
                    if address is not None and size is not None and tail:
                        first = tail.split()[0]
                        if first.startswith(".") and ":(" not in first and not first.startswith("/"):
                            sections.append(MapSection(address, size, first))
                        elif align == 0:
                            symbols.append(MapSymbol(address, size, tail.split()[0]))
                    continue

            # lld-link's public table commonly looks like:
            # 0001:00001000  _main  0000000140001000  ...
            segment_row = re.match(
                r"^\s*[0-9A-Fa-f]{1,4}:[0-9A-Fa-f]{8}\s+(\S+)\s+((?:0x)?[0-9A-Fa-f]{8,})(?:\s|$)",
                line,
            )
            if segment_row:
                address = _parse_map_address(segment_row.group(2))
                if address is not None:
                    symbols.append(MapSymbol(address, None, segment_row.group(1)))
                continue

            # Some lld-link versions omit the segment:offset column in the
            # public table and begin with the absolute Rva+Base address.
            direct_row = re.match(
                r"^\s*((?:0x)?[0-9A-Fa-f]{12,})\s+(\S+)(?:\s|$)",
                line,
            )
            if direct_row and not re.fullmatch(r"(?:0x)?[0-9A-Fa-f]+", direct_row.group(2)):
                address = _parse_map_address(direct_row.group(1))
                if address is not None:
                    symbols.append(MapSymbol(address, None, direct_row.group(2)))
                map_format = "lld-link"
                continue

            # ld64's symbol section is ``address size [file] name``.  Keep
            # this parser because it makes the evidence format portable while
            # retaining the same RVA-to-name output on every host.
            mac_row = re.match(
                r"^\s*((?:0x)?[0-9A-Fa-f]+)\s+((?:0x)?[0-9A-Fa-f]+)\s+(?:\[\s*\d+\]\s+)?(.+?)\s*$",
                line,
            )
            if mac_row:
                address = _parse_map_address(mac_row.group(1))
                size = _parse_map_address(mac_row.group(2))
                name = mac_row.group(3).strip()
                if address is not None and size is not None and name:
                    symbols.append(MapSymbol(address, size, name))
                    map_format = "ld64"

    unique: dict[tuple[int, str], MapSymbol] = {}
    for symbol in symbols:
        if symbol.name and symbol.address not in {0, 0xFFFFFFFFFFFFFFFF}:
            unique.setdefault((symbol.address, symbol.name), symbol)
    symbols = sorted(unique.values(), key=lambda item: (item.address, item.name))
    if preferred_base is None and symbols and map_format != "lld-link-rva":
        preferred_base = min(item.address for item in symbols) & ~0xFFFFF
    if sections:
        sections.sort(key=lambda item: (item.address, item.size, item.name))
        symbols = [
            dataclasses.replace(
                symbol,
                section_end=min(
                    section.address + section.size
                    for section in sections
                    if section.address <= symbol.address < section.address + section.size
                )
                if any(section.address <= symbol.address < section.address + section.size for section in sections)
                else None,
            )
            for symbol in symbols
        ]
    return symbols, preferred_base, map_format, sections


def _symbol_map_evidence(path: Optional[Path], sample_rvas: collections.Counter[int], fallback_base: Optional[int]) -> dict[str, object]:
    if path is None:
        return {"available": False, "reason": "no map artifact selected"}
    if not path.is_file():
        return {"available": False, "path": str(path), "reason": "map artifact missing"}
    symbols, preferred_base, map_format, sections = _load_symbol_map(path)
    address_is_rva = map_format == "lld-link-rva"
    if preferred_base is None:
        preferred_base = fallback_base
    result: dict[str, object] = {
        "available": True,
        "path": str(path),
        "format": map_format,
        "address_kind": "rva" if address_is_rva else "absolute",
        "symbol_count": len(symbols),
        "zero_size_symbol_count": sum(1 for symbol in symbols if symbol.size == 0),
        "preferred_image_base": f"0x{preferred_base:x}" if preferred_base is not None else None,
        "sections": [
            {"rva": f"0x{section.address:x}", "size": section.size, "name": section.name}
            for section in sections
        ],
        "symbol_resolution": "link-map" if symbols and (address_is_rva or preferred_base is not None) else "unresolved",
    }
    if not symbols or (not address_is_rva and preferred_base is None):
        result.update(
            {
                "sampled_symbol_top": [],
                "sampled_address_symbol_top": [],
                "unresolved_sample_count": sum(sample_rvas.values()),
                "unresolved_reason": "no usable symbol rows or image base",
            }
        )
        return result

    symbols_by_address = [item.address for item in symbols]
    symbol_hits: collections.Counter[tuple[int, Optional[int], str, Optional[int]]] = collections.Counter()
    address_hits: collections.Counter[tuple[int, int, str, int]] = collections.Counter()
    unresolved = 0
    for rva, count in sample_rvas.items():
        target = rva if address_is_rva else preferred_base + rva
        index = bisect.bisect_right(symbols_by_address, target) - 1
        if index < 0:
            unresolved += count
            continue
        symbol = symbols[index]
        delta = target - symbol.address
        bounds: list[int] = []
        if symbol.size is not None and symbol.size > 0:
            bounds.append(symbol.address + symbol.size)
        if index + 1 < len(symbols) and symbols[index + 1].address > symbol.address:
            bounds.append(symbols[index + 1].address)
        if symbol.section_end is not None and symbol.section_end > symbol.address:
            bounds.append(symbol.section_end)
        effective_end = min(bounds) if bounds else None
        if effective_end is not None and target >= effective_end:
            unresolved += count
            continue
        # A public map may omit both symbol sizes and section rows.  In that
        # shape only the exact symbol address is proven; treating the final
        # symbol as extending to infinity would misattribute unrelated code.
        if effective_end is None and target != symbol.address:
            unresolved += count
            continue
        symbol_rva = symbol.address if address_is_rva else symbol.address - preferred_base
        effective_size = effective_end - symbol.address if effective_end is not None else None
        symbol_hits[(symbol_rva, symbol.size, symbol.name, effective_size)] += count
        address_hits[(rva, symbol_rva, symbol.name, delta)] += count
    result["sampled_symbol_top"] = [
        {"rva": f"0x{rva:x}", "size": size, "effective_size": effective_size, "name": name, "count": count}
        for (rva, size, name, effective_size), count in symbol_hits.most_common(100)
    ]
    result["sampled_address_symbol_top"] = [
        {"rva": f"0x{rva:x}", "symbol_rva": f"0x{symbol_rva:x}", "delta": delta, "name": name, "count": count}
        for (rva, symbol_rva, name, delta), count in address_hits.most_common(100)
    ]
    result["unresolved_sample_count"] = unresolved
    if unresolved:
        result["unresolved_reason"] = "sample RVA falls outside every mapped symbol/section range"
    return result


def _resolve_symbol_map(directory: Path, target_image: str, explicit: Optional[Path]) -> Optional[Path]:
    if explicit is not None:
        return explicit.resolve()
    candidates = [directory / f"{target_image}.map", directory / f"{Path(target_image).stem}.map", directory / "nbody.map"]
    existing = [path for path in candidates if path.is_file()]
    if existing:
        return existing[0]
    maps = sorted(directory.glob("*.map"))
    return maps[0] if len(maps) == 1 else None


def _map_samples(collector: TraceCollector, target_image: str) -> dict[str, object]:
    target_image = target_image.lower()
    target_pids = {item.pid for item in collector.processes if _basename(item.image) == target_image}
    processes_by_pid: collections.defaultdict[int, list[ProcessInterval]] = collections.defaultdict(list)
    threads_by_tid: collections.defaultdict[int, list[ThreadInterval]] = collections.defaultdict(list)
    modules_by_pid: collections.defaultdict[int, list[ModuleInterval]] = collections.defaultdict(list)
    for item in collector.processes:
        processes_by_pid[item.pid].append(item)
    for item in collector.threads:
        threads_by_tid[item.tid].append(item)
    for item in collector.modules:
        modules_by_pid[item.pid].append(item)
    for values in processes_by_pid.values():
        values.sort(key=lambda item: item.start_ns)
    for values in threads_by_tid.values():
        values.sort(key=lambda item: item.start_ns)
    for values in modules_by_pid.values():
        values.sort(key=lambda item: item.start_ns)

    all_modules = collections.Counter[str]()
    all_cpus = collections.Counter[str]()
    target_cpus = collections.Counter[str]()
    nbody_pids = collections.Counter[int]()
    nbody_tids = collections.Counter[int]()
    nbody_ip_rvas: collections.Counter[tuple[int, int, int]] = collections.Counter()
    nbody_rvas = collections.Counter[int]()
    nbody_rva_buckets = collections.Counter[int]()
    outcomes = collections.Counter[str]()
    nbody_bases: collections.Counter[int] = collections.Counter()
    sample_times = [item.time_ns for item in collector.samples]

    for sample in collector.samples:
        all_cpus[str(sample.cpu) if sample.cpu is not None else "unknown"] += 1
        thread = _active(threads_by_tid.get(sample.tid, ()), sample.time_ns)
        pid = thread.pid if isinstance(thread, ThreadInterval) else None
        process = _active(processes_by_pid.get(pid, ()), sample.time_ns) if pid is not None else None
        module = None
        if pid is not None:
            candidates = []
            for item in modules_by_pid.get(pid, ()):
                if item.start_ns <= sample.time_ns <= (item.end_ns or sample.time_ns) and item.base <= sample.ip < item.base + item.size:
                    candidates.append(item)
            if candidates:
                module = max(candidates, key=lambda item: item.start_ns)
        if module is not None:
            module_name = _basename(module.path) or "unnamed-image"
        elif sample.ip >= 0xFFFF000000000000:
            module_name = "kernel/unresolved"
        else:
            module_name = "unresolved"
        all_modules[module_name] += 1

        if sample.tid == 0:
            outcomes["thread_id_zero"] += 1
        elif thread is None:
            outcomes["thread_unresolved"] += 1
        else:
            outcomes["thread_resolved"] += 1
        if pid is None:
            outcomes["process_unresolved"] += 1
            continue
        if process is None:
            outcomes["process_interval_unresolved"] += 1
            continue
        if _basename(process.image) != target_image:
            outcomes["other_process"] += 1
            continue
        outcomes["nbody_process"] += 1
        nbody_pids[pid] += 1
        nbody_tids[sample.tid] += 1
        if sample.cpu is not None:
            target_cpus[str(sample.cpu)] += 1
        if module is not None and _basename(module.path) == target_image:
            outcomes["nbody_executable"] += 1
            rva = sample.ip - module.base
            nbody_ip_rvas[(sample.ip, module.base, rva)] += 1
            nbody_rvas[rva] += 1
            nbody_rva_buckets[(rva // 0x1000) * 0x1000] += 1
            nbody_bases[module.base] += 1
        elif sample.ip >= 0xFFFF000000000000:
            outcomes["nbody_kernel"] += 1
        else:
            outcomes["nbody_other_user_image_or_unresolved"] += 1

    duration_ms = None
    if sample_times:
        duration_ms = (max(sample_times) - min(sample_times)) / 1_000_000
    return {
        "sample_events": len(collector.samples),
        "sample_time_range": {
            "first_ns": min(sample_times) if sample_times else None,
            "last_ns": max(sample_times) if sample_times else None,
            "duration_ms": duration_ms,
        },
        "outcomes": dict(outcomes),
        "process": {
            "target_image": target_image,
            "target_pid_count": len(target_pids),
            "target_pids": {f"0x{pid:x}": count for pid, count in sorted(nbody_pids.items())},
            "target_thread_count": len(
                {
                    item.tid
                    for item in collector.threads
                    if (
                        (process := _active(processes_by_pid.get(item.pid, ()), item.start_ns)) is not None
                        and _basename(process.image) == target_image
                    )
                }
            ),
            "target_threads": {str(tid): count for tid, count in nbody_tids.most_common()},
        },
        "module_distribution": _counter_items(all_modules, 60),
        "cpu_distribution": _counter_items(all_cpus, 40),
        "target_cpu_distribution": _counter_items(target_cpus, 40),
        "target_ip_top": [
            {"ip": f"0x{ip:x}", "base": f"0x{base:x}", "rva": f"0x{rva:x}", "count": count}
            for (ip, base, rva), count in nbody_ip_rvas.most_common(50)
        ],
        "target_rva_top": [
            {"rva": f"0x{rva:x}", "count": count}
            for rva, count in nbody_rvas.most_common(50)
        ],
        "target_rva_4k_buckets": [
            {"rva": f"0x{rva:x}", "count": count}
            for rva, count in nbody_rva_buckets.most_common(50)
        ],
        "target_image_bases": [
            {"base": f"0x{base:x}", "count": count}
            for base, count in nbody_bases.most_common()
        ],
        "_sample_rvas": nbody_rvas,
    }


def _static_evidence(directory: Path, profile: Optional[dict[str, object]], mapped: dict[str, object], symbol_empty: Optional[bool]) -> dict[str, object]:
    code = profile.get("code", {}) if isinstance(profile, dict) else {}
    static_calls = code.get("static_call_sites", {}) if isinstance(code, dict) else {}
    if not isinstance(static_calls, dict):
        static_calls = {}
    relevant_calls = {
        name: count
        for name, count in static_calls.items()
        if any(token in name for token in ("aot_math", "aot_arithmetic", "aot_index", "aot_global", "aot_array", "aot_iterator", "aot_string", "aot_runtime", "aot_exception", "aot_dispatch", "aot_element"))
    }
    result: dict[str, object] = {
        "profile_static_call_sites": relevant_calls,
        "profile_typed_definitions": code.get("typed_definitions", []) if isinstance(code, dict) else [],
        "profile_sqrt_mentions": code.get("sqrt_mentions") if isinstance(code, dict) else None,
        "profile_stack_probe_mentions": code.get("stack_probe_mentions") if isinstance(code, dict) else None,
        "pe_symbols_empty": symbol_empty,
        "sampled_function_names": "unresolved" if symbol_empty else "requires symbol parser",
    }
    ll_path = directory / "nbody.ll"
    if ll_path.is_file():
        text = ll_path.read_text(encoding="utf-8", errors="replace")
        calls = collections.Counter(re.findall(r"\bcall\b[^@\n]*@([A-Za-z0-9_.$]+)", text))
        result["llvm_ir_call_sites"] = {
            name: count
            for name, count in calls.items()
            if name.startswith("lnako_aot_")
        }
        result["llvm_ir_direct_sqrt_mentions"] = len(re.findall(r"(?:llvm\.)?sqrt|sqrt\.f64", text, re.IGNORECASE))
    else:
        result["llvm_ir_call_sites"] = None
    result["sampling_address_resolution"] = {
        "target_executable_samples": mapped.get("outcomes", {}).get("nbody_executable", 0),
        "rva_only": True,
        "symbol_names": "unavailable" if symbol_empty else "not implemented",
    }
    return result


def _runtime_evidence(directory: Path) -> dict[str, object]:
    contexts = _counter_log_contexts(directory / "runtime-counters.log")
    values = contexts[0] if len(contexts) == 1 else {}
    managed_fields = {
        name: values[name]
        for name in ("allocations", "allocated_bytes", "string_payload_allocations", "string_payload_bytes", "concat_calls", "concat_output_bytes", "gc_collections", "gc_scanned_objects", "gc_scanned_bytes", "gc_reclaimed_objects", "gc_reclaimed_bytes")
        if name in values
    }
    telemetry_fields = {
        name: values[name]
        for name in ("allocator_telemetry_active", "allocator_telemetry_init_failures", "allocator_alloc_calls", "allocator_resize_calls", "allocator_remap_calls", "allocator_free_calls", "allocator_live_bytes", "allocator_peak_live_bytes", "gc_mark_ns", "gc_sweep_ns")
        if name in values
    }
    return {
        "counter_values": values,
        "counter_context_count": len(contexts),
        "counter_contexts": contexts,
        "counter_scope": "single runtime report" if len(contexts) == 1 else "no single runtime total; contexts are absent or may overlap",
        "managed_object_and_payload_fields": managed_fields,
        "allocator_telemetry_fields": telemetry_fields,
        "allocator_telemetry_status": (
            "multiple runtime reports; inspect each context separately" if len(contexts) > 1
            else "observed by this runtime" if values.get("allocator_telemetry_active") == 1
            else "initialization failed; values are unavailable" if values.get("allocator_telemetry_init_failures", 0) > 0
            else "not observed by this runtime (disabled or borrowed allocator)" if "allocator_telemetry_active" in values
            else "availability not recorded"
        ),
        "aot_helper_entry_fields": {
            name: count for name, count in values.items()
            if name.startswith("aot_") and name.endswith(("_calls", "_successes", "_failures"))
        },
        "allocator_telemetry_missing": [
            name
            for name in ("allocator_alloc_calls", "allocator_resize_calls", "allocator_remap_calls", "allocator_free_calls", "allocator_live_bytes", "allocator_peak_live_bytes", "gc_mark_ns", "gc_sweep_ns")
            if name not in values
        ],
        "units_and_limits": {
            "allocations": "managed Object headers, not malloc calls",
            "allocated_bytes": "accounted managed Object/payload bytes, not allocator live bytes",
            "allocator_telemetry": "allocator vtable operations are unavailable when the corresponding fields are absent",
            "gc_scanned_bytes": "Object header bytes visited by the mark phase; inline UTF-16 units do not contain roots",
            "aot_helper_entries": "instrumented ABI entries in the separate counter run; nested wrapper/fallback entries can both count, so these fields must not be summed as unique language calls",
        },
    }


def _required_trace_failures(result: dict[str, object]) -> list[str]:
    """Return failures for the strict CI trace-usability gate.

    The regular report intentionally keeps partial joins and missing optional
    artifacts as diagnostics.  CI can opt into this narrow gate so a broken
    exporter or an empty profile cannot be mistaken for usable CPU evidence.
    """

    failures: list[str] = []
    mapping = result.get("mapping", {})
    if not isinstance(mapping, dict):
        mapping = {}
    sample_events = mapping.get("sample_events", 0)
    if not isinstance(sample_events, int) or sample_events <= 0:
        failures.append("no SampledProfile events were decoded")
    outcomes = mapping.get("outcomes", {})
    if not isinstance(outcomes, dict):
        outcomes = {}
    if not isinstance(outcomes.get("nbody_process", 0), int) or outcomes.get("nbody_process", 0) <= 0:
        failures.append("no SampledProfile event joined the target process")
    if not isinstance(outcomes.get("nbody_executable", 0), int) or outcomes.get("nbody_executable", 0) <= 0:
        failures.append("no SampledProfile event joined the target executable")
    summary = result.get("trace_summary", {})
    if isinstance(summary, dict) and isinstance(summary.get("events_lost"), int) and summary["events_lost"] > 0:
        failures.append(f"trace summary reports {summary['events_lost']} lost events")
    return failures


def analyze(
    input_path: Path,
    output_path: Optional[Path] = None,
    artifact_dir: Optional[Path] = None,
    target_image: str = "nbody.exe",
    symbol_map_path: Optional[Path] = None,
) -> dict[str, object]:
    input_path = input_path.resolve()
    directory = (artifact_dir or input_path.parent).resolve()
    collector = _parse_trace(input_path, target_image)
    mapped = _map_samples(collector, target_image)
    sample_rvas = mapped.pop("_sample_rvas")
    profile = _read_json(directory / "profile.json")
    symbol_empty = _symbol_table_empty(directory / "imports-symbols.txt")
    resolved_map_path = _resolve_symbol_map(directory, target_image, symbol_map_path)
    artifact_names = [
        input_path.name,
        "nbody-cpu.etl",
        "profile.json",
        "nbody.exe",
        "nbody.ll",
        "nbody.s",
        "linked-disassembly.txt",
        "imports-symbols.txt",
        "runtime-counters.log",
        "trace-summary.txt",
    ]
    if resolved_map_path is not None and resolved_map_path.parent == directory:
        artifact_names.append(resolved_map_path.name)
    artifacts, missing_artifacts = _artifact_metadata(directory, dict.fromkeys(artifact_names))
    if resolved_map_path is not None and resolved_map_path.is_file() and resolved_map_path.name not in artifacts:
        artifacts[resolved_map_path.name] = {
            "path": str(resolved_map_path),
            "bytes": resolved_map_path.stat().st_size,
            "sha256": _sha256(resolved_map_path),
        }
    trace_artifact = artifacts.get(input_path.name)
    if trace_artifact is None or Path(str(trace_artifact["path"])).resolve() != input_path:
        artifacts[f"trace:{input_path.name}"] = {
            "path": str(input_path),
            "bytes": input_path.stat().st_size,
            "sha256": _sha256(input_path),
        }
        trace_sha256 = artifacts[f"trace:{input_path.name}"]["sha256"]
    else:
        trace_sha256 = trace_artifact["sha256"]
    summary = _trace_summary(directory / "trace-summary.txt")
    linked = _linked_disassembly(directory / "linked-disassembly.txt", sample_rvas)
    linked_base = _parse_map_address(str(linked["preferred_image_base"])) if linked.get("preferred_image_base") else None
    symbol_map = _symbol_map_evidence(resolved_map_path, sample_rvas, linked_base)
    static_abi = _static_evidence(directory, profile, mapped, symbol_empty)
    if symbol_map.get("symbol_resolution") == "link-map":
        static_abi["sampled_function_names"] = "link-map"
        static_abi["sampling_address_resolution"]["symbol_names"] = "link-map"
        linked["symbol_resolution"] = "link-map"
    address_join = (
        "nbody.exe samples are reported as runtime-image-relative RVAs, then matched to linked-disassembly addresses; a usable linker map additionally resolves sampled RVAs to function names within proven symbol ranges"
        if symbol_map.get("symbol_resolution") == "link-map"
        else "nbody.exe samples are reported as runtime-image-relative RVAs, then matched to linked-disassembly addresses; function names remain unavailable without a usable linker map or PE symbol parser"
    )
    missing: list[str] = []
    if symbol_empty and symbol_map.get("symbol_resolution") != "link-map":
        missing.append("PE symbol table is empty; sampled nbody.exe addresses remain function-name unresolved")
    if not collector.samples:
        missing.append("no SampledProfile opcode 46 events were decoded")
    if mapped.get("outcomes", {}).get("thread_unresolved", 0):
        missing.append("some SampledProfile ThreadId values have no active Thread Start/End interval")
    if mapped.get("outcomes", {}).get("nbody_other_user_image_or_unresolved", 0):
        missing.append("some nbody-thread samples did not resolve to nbody.exe or a mapped image")
    if resolved_map_path is not None and not resolved_map_path.is_file():
        missing.append("symbol map artifact is missing")
    missing.extend(f"artifact missing: {name}" for name in missing_artifacts if name not in {input_path.name})
    if linked.get("available") and linked.get("symbol_resolution", "").startswith("address-only") and symbol_map.get("symbol_resolution") != "link-map":
        missing.append("linked disassembly has instruction addresses but no function symbols")
    if symbol_map.get("available") and symbol_map.get("symbol_resolution") != "link-map":
        missing.append("symbol map exists but contains no usable symbol rows or image base")
    result: dict[str, object] = {
        "schema": SCHEMA,
        "analyzer": {
            "source_sha256": _sha256(Path(__file__)),
            "python_version": platform.python_version(),
        },
        "input": {
            "trace": {"path": str(input_path), "sha256": trace_sha256},
            "artifact_directory": str(directory),
            "artifacts": artifacts,
        },
        "trace_summary": summary,
        "event_counts": dict(collector.event_counts),
        "sampled_profile_schema": {
            "provider_guid": PERFINFO_GUID,
            "opcode": int(SAMPLED_PROFILE_OPCODE),
            "payload_fields": ["InstructionPointer:uint64", "ThreadId:uint32", "Count:uint32"],
            "count_field_used": False,
            "references": [SAMPLED_PROFILE_REFERENCE, PERFINFO_REFERENCE],
        },
        "mapping": mapped,
        "runtime_gc_allocator": _runtime_evidence(directory),
        "static_abi": static_abi,
        "linked_disassembly": linked,
        "symbol_map": symbol_map,
        "profile_manifest": profile,
        "interpretation": {
            "sample_counts": "one decoded SampledProfile event per counted record; the ETW Count payload is retained in parsing but not used as a weight",
            "process_join": "nbody attribution is an observed timestamp join from SampledProfile ThreadId to Thread and Process intervals; unresolved records are reported separately",
            "address_join": address_join,
            "sqrt_sampling": "zero samples near a sqrt instruction is an observation of this sample set, not proof that no sqrt call executed",
            "runtime_counters": "runtime-counters.log values are a separate run artifact and are not inferred from ETW sample counts",
        },
        "missing_information": missing,
    }
    if output_path is not None:
        output_path = output_path.resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return result


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="tracerpt XML export")
    parser.add_argument("--output", required=True, type=Path, help="analysis JSON output")
    parser.add_argument("--artifact-dir", type=Path, help="directory containing profile.json and build artifacts")
    parser.add_argument("--image-name", default="nbody.exe", help="target image basename (default: nbody.exe)")
    parser.add_argument("--symbol-map", type=Path, help="optional lld-link/ld64 map file; otherwise nbody.map or a single *.map is auto-detected")
    parser.add_argument(
        "--require-usable-trace",
        action="store_true",
        help="fail after writing the report when the trace has no usable target samples or explicit event loss",
    )
    args = parser.parse_args(argv)
    if not args.input.is_file():
        parser.error(f"input does not exist: {args.input}")
    result = analyze(args.input, args.output, args.artifact_dir, args.image_name, args.symbol_map)
    mapping = result["mapping"]
    outcomes = mapping["outcomes"]
    print(
        f"analyzed {mapping['sample_events']} SampledProfile events; "
        f"nbody process samples={outcomes.get('nbody_process', 0)}, "
        f"nbody.exe samples={outcomes.get('nbody_executable', 0)}; "
        f"output={args.output}"
    )
    if args.require_usable_trace:
        failures = _required_trace_failures(result)
        if failures:
            print(f"trace usability check failed: {'; '.join(failures)}", file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
