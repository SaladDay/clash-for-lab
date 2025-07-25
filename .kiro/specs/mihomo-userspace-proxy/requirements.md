# Requirements Document

## Introduction

基于现有的clash-for-linux-install项目，改造一个使用mihomo内核的用户空间代理管理工具。该工具需要在不需要sudo权限的情况下，能够在服务器后台稳定运行Clash代理，让服务器本身能通过代理访问外部网络，并提供灵活的命令行界面来管理订阅配置。

## Requirements

### Requirement 1

**User Story:** 作为一个普通用户，我希望能够在没有sudo权限的情况下安装和运行mihomo代理，以便在受限环境中使用代理服务。

#### Acceptance Criteria

1. WHEN 用户执行安装脚本 THEN 系统应该将所有文件安装到用户家目录下而不是系统目录
2. WHEN 用户运行代理服务 THEN 系统应该使用用户权限启动mihomo进程而不需要systemd服务
3. WHEN 代理服务启动 THEN 系统应该使用非特权端口（>1024）来避免权限问题

### Requirement 2

**User Story:** 作为一个服务器管理员，我希望代理服务能够在后台稳定运行，以便服务器能够持续通过代理访问外部网络。

#### Acceptance Criteria

1. WHEN 用户启动代理服务 THEN 系统应该在后台启动mihomo进程并保持运行
2. WHEN 用户登出或断开SSH连接 THEN 代理服务应该继续在后台运行
3. WHEN 用户执行网络请求 THEN 流量应该通过mihomo代理转发

### Requirement 3

**User Story:** 作为一个用户，我希望能够手动和自动更新Clash订阅配置文件，以便保持代理节点的可用性。

#### Acceptance Criteria

1. WHEN 用户提供订阅URL THEN 系统应该能够下载并转换配置文件
2. WHEN 用户执行手动更新命令 THEN 系统应该立即更新订阅配置并重启服务
3. WHEN 用户设置自动更新 THEN 系统应该定期检查并更新订阅配置

### Requirement 4

**User Story:** 作为一个用户，我希望有一个灵活的命令行界面来管理代理服务，以便方便地控制代理的各种功能。

#### Acceptance Criteria

1. WHEN 用户执行基本命令 THEN 系统应该提供开启、关闭、状态查看等核心功能
2. WHEN 用户管理订阅 THEN 系统应该提供添加、更新、查看订阅的命令
3. WHEN 用户配置代理 THEN 系统应该提供端口、密钥等基本配置选项