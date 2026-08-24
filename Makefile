.DEFAULT_GOAL := help

CONFIG    ?= Debug
PRODUCT   := build/Build/Products/$(CONFIG)/DJOneHub.app

.PHONY: help
help: ## 列出可用目标
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: project
project: ## 由 project.yml 生成 Xcode 工程
	@command -v xcodegen >/dev/null 2>&1 \
		|| { echo "未找到 xcodegen，安装：brew install xcodegen"; exit 1; }
	xcodegen generate

.PHONY: build
build: project ## 构建 App
	xcodebuild -project DJOneHub.xcodeproj -scheme DJOneHub \
		-configuration $(CONFIG) -derivedDataPath build build

.PHONY: run
run: build ## 构建并运行（接真实模块）
	"$(PRODUCT)/Contents/MacOS/DJOneHub"

.PHONY: demo
demo: build ## 构建并以演示数据运行，无需硬件
	DJONEHUB_DEMO=1 "$(PRODUCT)/Contents/MacOS/DJOneHub"

.PHONY: test
test: project ## 跑契约解码测试（IT-011 IT-012）
	xcodebuild -project DJOneHub.xcodeproj -scheme DJOneHub \
		-configuration $(CONFIG) -derivedDataPath build test

.PHONY: mutation
mutation: ## 注入 DTO 漂移，验证测试真的会失败（IT-013）
	python3 Tests/ContractDecode/mutation-check.py

.PHONY: fmt
fmt: ## 格式化 Swift 源码（需 swift-format）
	@command -v swift-format >/dev/null 2>&1 \
		|| { echo "未找到 swift-format"; exit 1; }
	swift-format format --in-place --recursive Sources

.PHONY: clean
clean: ## 清理构建产物与生成的工程
	rm -rf build DJOneHub.xcodeproj
