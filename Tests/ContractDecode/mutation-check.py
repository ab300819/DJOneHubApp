#!/usr/bin/env python3
"""Checks that the contract tests would notice a broken DTO.

@verifies NFR-007
@testcase IT-013

A suite that only decodes proves less than it looks: give an optional field the
wrong key and it decodes to nil, silently, and every decode test still passes.
So each drift below is injected into the real source, `make test` is run, and
the drift is only counted as caught when a *test* fails — a compile error does
not count, because it says nothing about whether the assertions have teeth.

The source is restored after every round, including on failure.
"""

import pathlib
import subprocess
import sys

MODELS = "Sources/Core/Models.swift"
CORE_JSON = "Sources/Core/CoreJSON.swift"

DRIFTS = [
    ("改键名 usb_device→usbdevice", MODELS,
     'case usbDevice = "usb_device"',
     'case usbDevice = "usbdevice"'),
    ("改 class 键名", MODELS,
     'case interfaceClass = "class"',
     'case interfaceClass = "klass"'),
    ("改 sampled_at_ms", MODELS,
     'case sampledAtMS = "sampled_at_ms"',
     'case sampledAtMS = "sampled_at_millis"'),
    ("让 index 指向错键", MODELS,
     'struct ModuleNoteResult: Decodable, Sendable {\n'
     '    let message: String\n'
     '    let index: Int?\n}',
     'struct ModuleNoteResult: Decodable, Sendable {\n'
     '    let message: String\n'
     '    let index: Int?\n\n'
     '    enum CodingKeys: String, CodingKey {\n'
     '        case message\n'
     '        case index = "idx"\n'
     '    }\n}'),
    ("改 responses", MODELS,
     '        case responses\n',
     '        case responses = "response"\n'),
    ("去掉 null 判定", CORE_JSON,
     'payload.isEmpty || payload == Data("null".utf8)',
     'payload.isEmpty'),
]


def run(label, path, old, new):
    source = pathlib.Path(path)
    original = source.read_text()
    if old not in original:
        return label, "—", "⛔ 注入点不存在，漂移清单已与源码脱节"
    source.write_text(original.replace(old, new, 1))
    try:
        finished = subprocess.run(["make", "test"], capture_output=True, text=True)
    finally:
        source.write_text(original)

    output = finished.stdout + finished.stderr
    failing = sorted({
        line.split("'")[1].split(".")[-1].rstrip("]")
        for line in output.splitlines() if "' failed (" in line
    })
    if "BUILD FAILED" in output or "** TEST BUILD FAILED" in output:
        return label, finished.returncode, "⚠️ 编译失败——不算测试抓到，请换一种漂移"
    if finished.returncode != 0 and failing:
        return label, finished.returncode, "✅ " + ", ".join(failing)
    if finished.returncode == 0:
        return label, 0, "❌ 仍然通过——该漂移无人发现"
    return label, finished.returncode, "? 退出码非 0 但没有失败用例名"


results = [run(*drift) for drift in DRIFTS]

print()
print(f"{'漂移':<26} {'退出码':<7} 判定")
for label, code, verdict in results:
    print(f"{label:<26} {str(code):<7} {verdict}")

caught = sum(1 for _, _, verdict in results if verdict.startswith("✅"))
print(f"\n{caught}/{len(results)} 种漂移被测试抓到")
sys.exit(0 if caught == len(results) else 1)
