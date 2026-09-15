#!/usr/bin/env python3
"""Checks that the contract tests would notice a broken DTO.

@verifies NFR-007
@testcase IT-013

A suite that only decodes proves less than it looks: give an optional field the
wrong key and it decodes to nil, silently, and every decode test still passes.
So each drift below is injected into the real source, `make test` is run, and
the drift is only counted as caught when the test run itself rejects it — by a
named failure, or by crashing. A compile error does not count, because it says
nothing about whether the assertions have teeth.

A crash counts, and counts for more than a failure: the rollback drift traps on
unsigned underflow, which is the app dying rather than showing a wrong number.

The source is restored after every round, including on failure.
"""

import pathlib
import subprocess
import sys

MODELS = "Sources/Core/Models.swift"
CORE_JSON = "Sources/Core/CoreJSON.swift"
TRAFFIC = "Sources/Core/TrafficRate.swift"
NETWORK_VIEW = "Sources/Views/NetworkView.swift"

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

    # 视图层纯逻辑：分支都藏在判定里，去掉一个判定不会让任何东西编译失败
    ("速率：不认计数器回退", TRAFFIC,
     'guard elapsed >= minimumInterval, sample.rx >= previous.rx, sample.tx >= previous.tx else {',
     'guard elapsed >= minimumInterval else {'),
    ("速率：不认换网卡", TRAFFIC,
     'guard let previous, previous.interface == interface else {',
     'guard let previous else {'),
    ("速率：取消最短间隔", TRAFFIC,
     'static let minimumInterval: TimeInterval = 0.5',
     'static let minimumInterval: TimeInterval = 0'),
    ("速率：断线后不清基线", TRAFFIC,
     'guard let snapshot, snapshot.available, let interface = snapshot.interface else {\n            return (nil, nil)',
     'guard let snapshot, snapshot.available, let interface = snapshot.interface else {\n            return (previous, nil)'),
    ("容量：不提取 +CPBS 行", MODELS,
     'return line ?? (storageStatus.isEmpty ? "未返回容量信息" : storageStatus)',
     'return storageStatus'),
    ("可携带：漏掉读取能力", MODELS,
     'var portable: Bool { storageUsable && readSupported && writeSupported }',
     'var portable: Bool { storageUsable && writeSupported }'),
    ("空备注：不去空白", MODELS,
     '        [label, phone, tags].allSatisfy {\n'
     '            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty\n'
     '        }',
     '        [label, phone, tags].allSatisfy(\\.isEmpty)'),
    ("字节：速率允许为负", NETWORK_VIEW,
     'describe(UInt64(max(0, bytesPerSecond.rounded()))) + "/s"',
     'describe(UInt64(bytesPerSecond.rounded().magnitude)) + "/s"'),
    ("摘要：截断时不提示", MODELS,
     'var parts = stored > count ? ["显示最近 \\(count) 条 · 共 \\(stored) 条"] : ["共 \\(count) 条"]',
     'var parts = ["共 \\(count) 条"]'),
    ("摘要：不提保留模块副本", MODELS,
     '        if !autoCleanupME {\n            parts.append("保留模块副本")\n        }\n',
     ''),
    ("状态：stored 改键名", MODELS,
     'case count, polling, stored', 'case count, polling\n        case stored = "stored_count"'),
    ("字节：不降精度", NETWORK_VIEW,
     'String(format: value < 10 ? "%.2f %@" : "%.1f %@", value, units[unit])',
     'String(format: "%.2f %@", value, units[unit])'),
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
        # Restoring blindly would silently discard an edit made while the round
        # was running — which happened, and cost a whole run's credibility.
        if source.read_text() != original.replace(old, new, 1):
            raise SystemExit(
                f"⛔ {path} 在注入 “{label}” 期间被改动。本次结果作废，"
                f"源码保持当前状态未回滚，请自行确认后重跑。")
        source.write_text(original)

    output = finished.stdout + finished.stderr
    failing = sorted({
        line.split("'")[1].split(".")[-1].rstrip("]")
        for line in output.splitlines() if "' failed (" in line
    })
    if "BUILD FAILED" in output or "** TEST BUILD FAILED" in output:
        return label, finished.returncode, "⚠️ 编译失败——不算测试抓到，请换一种漂移"
    if finished.returncode == 0:
        return label, 0, "❌ 仍然通过——该漂移无人发现"
    if failing:
        return label, finished.returncode, "✅ " + ", ".join(failing)
    if "Restarting after unexpected exit" in output:
        return label, finished.returncode, "✅ 测试进程崩溃——该漂移会让 App 死掉，不只是显示错"
    return label, finished.returncode, "? 退出码非 0，但既无失败用例也无崩溃迹象"


results = [run(*drift) for drift in DRIFTS]

print()
print(f"{'漂移':<26} {'退出码':<7} 判定")
for label, code, verdict in results:
    print(f"{label:<26} {str(code):<7} {verdict}")

caught = sum(1 for _, _, verdict in results if verdict.startswith("✅"))
print(f"\n{caught}/{len(results)} 种漂移被测试抓到")
sys.exit(0 if caught == len(results) else 1)
