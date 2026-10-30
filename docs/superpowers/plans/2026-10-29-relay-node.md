# Relay Node Implementation Plan

> 执行方式：superpowers:executing-plans，主会话串行实施。TODO为状态锚；每个代码步骤≤50行且逐文件校验。

**Goal:** 提供可部署个人节点与当前客户端的错时云同步闭环。
**Architecture:** Go签名文件节点 + 现有加密同步runtime + Flutter设置 + Caddy/Compose。
**Tech Stack:** Go标准库、Dart既有crypto/HTTP、Flutter既有组件、Docker Compose。
**Spec:** docs/superpowers/specs/2026-10-29-relay-node-design.md

## 约束
- 当前工作区包含既有未提交功能，保留所有无关改动；不新增数据库同步协议或依赖。
- 每次只执行TODO当前步骤；新文件按≤50行增量建立，每次go vet/针对测试或dart analyze。
- 无自动历史回收；云同步状态诚实；端到端可信成员/epoch验证保持。

## 原子实施任务（各任务内按50行增量标记）
- [x] 节点go.mod与认证合同类型；Go编译校验。
- [x] 节点路径/文件写入测试、最小存储实现，逐文件校验。
- [x] 签名/重放/权限测试与实现，逐文件校验。
- [x] HTTP路由/限额/原子覆盖/重启持久测试与实现。
- [x] CLI入口与服务超时/退出控制；go test及go vet。
- [x] Dart relay请求签名、HTTP限制、目录/文件验证及测试。
- [x] Runtime通用私有接收入口改动，现有LAN测试。
- [x] Runtime relay轮次控制交换/发布/接收/ACK，逐段校验。
- [x] 真实Go节点下A离线→B上线→B离线→A上线及节点重启集成。
- [x] App云同步入口及状态/公开配置导出，单文件测试。
- [x] Flutter云中转地址持久保存与按钮接线，Widget回归。
- [x] Dockerfile、Compose、Caddyfile、示例配置与README部署步骤。
- [x] Docker构建/配置/启动与针对性检查。
- [x] 独立审查并修复确认问题，完整相关回归，报告验收边界。

完成验证：Go race/vet、核心895项、App446项、双端真实Go TLS错时及失败重试、Caddy Compose签名读写/容器重建持久性、macOS实机设置页；两项审查问题已处理。公网与移动真机待用户部署后按README验收。
