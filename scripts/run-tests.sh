#!/bin/bash
# L1 单元测试。CLT 环境没有 XCTest/swift-testing，用自建 harness（见 docs/SPEC.md §4）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --product lidawake-tests
exec "$ROOT/.build/release/lidawake-tests"
