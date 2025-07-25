# 测试说明

本目录包含 mihomo 用户空间代理的测试脚本，用于验证安装和功能的正确性。

## 测试脚本

### 1. 新功能测试 (test_new_features.sh)

测试新添加的功能，包括：

- restart 重启命令
- status 显示订阅URI
- subscribe 订阅管理命令

**使用方法：**
```bash
./test/test_new_features.sh
```

### 2. 安装验证 (verify_installation.sh)

验证安装过程和基本配置：

- 安装目录检查
- 配置文件验证
- 基本功能测试

**使用方法：**
```bash
./test/verify_installation.sh
```

### 3. 功能测试 (functional_test.sh)

测试已安装系统的基本功能，包括：

- 目录结构检查
- 二进制文件验证
- 配置文件检查
- 脚本函数验证
- 进程管理功能
- 用户权限验证
- 命令帮助信息
- 环境变量设置

**使用方法：**
```bash
# 在已安装的系统上运行
./test/functional_test.sh
```

**前提条件：**
- mihomo 已经安装在 `~/tools/mihomo/`
- 所有必要的配置文件已存在

### 4. 集成测试 (integration_test.sh)

测试完整的安装和操作流程，包括：

- 全新安装过程
- 基本命令功能
- 代理启停操作
- 配置文件管理
- 订阅更新功能

**使用方法：**
```bash
# 在干净的环境中运行（会自动安装）
./test/integration_test.sh
```

**注意事项：**
- 此测试会完全重新安装 mihomo
- 会清理现有的安装和配置
- 需要网络连接来下载订阅配置

## 测试环境要求

### 系统要求
- Linux 系统 (CentOS, Debian, Ubuntu 等)
- bash 或 zsh shell
- 用户权限（无需 sudo）
- 网络连接（用于订阅测试）

### 依赖工具
测试脚本会验证以下工具的可用性：
- curl 或 wget
- tar, gzip
- ps, kill
- crontab

## 测试输出

测试脚本使用颜色编码的输出：
- 🔵 **蓝色**: 信息消息
- 🟢 **绿色**: 测试通过
- 🔴 **红色**: 测试失败
- 🟡 **黄色**: 警告消息

## 故障排除

### 常见问题

1. **权限错误**
   - 确保对 `~/tools/mihomo/` 目录有读写权限
   - 检查脚本文件是否有执行权限

2. **网络连接问题**
   - 检查网络连接
   - 验证订阅 URL 是否可访问
   - 考虑使用代理或镜像源

3. **端口冲突**
   - 检查端口 7890, 9090 是否被占用
   - 测试会自动处理端口冲突

4. **配置文件问题**
   - 检查 YAML 文件格式
   - 验证订阅配置的有效性

### 调试模式

启用详细输出：
```bash
# 启用 bash 调试模式
bash -x ./test/functional_test.sh

# 或者设置环境变量
export DEBUG=1
./test/integration_test.sh
```

### 日志文件

测试过程中的日志文件位置：
- mihomo 运行日志: `~/tools/mihomo/logs/mihomo.log`
- 订阅更新日志: `~/tools/mihomo/mihomoctl.log`
- subconverter 日志: `~/tools/mihomo/bin/subconverter/latest.log`

## 手动测试步骤

如果自动测试失败，可以按以下步骤手动验证：

### 1. 基本安装验证
```bash
# 检查安装目录
ls -la ~/tools/mihomo/

# 检查二进制文件
~/tools/mihomo/bin/mihomo -v
~/tools/mihomo/bin/yq --version
```

### 2. 配置验证
```bash
# 检查配置文件
cat ~/tools/mihomo/config.yaml
cat ~/tools/mihomo/mixin.yaml

# 验证配置语法
~/tools/mihomo/bin/mihomo -d ~/tools/mihomo -f ~/tools/mihomo/runtime.yaml -t
```

### 3. 功能验证
```bash
# 加载脚本
source ~/tools/mihomo/script/common.sh
source ~/tools/mihomo/script/clashctl.sh

# 测试命令
mihomoctl status
mihomoctl on
mihomoctl status
mihomoctl off
```

### 4. 网络测试
```bash
# 启动代理后测试网络连接
mihomoctl on
curl -I http://www.google.com
mihomoctl off
```

## 贡献测试

如果您发现测试中的问题或想要添加新的测试用例：

1. 在 `test/` 目录下创建新的测试脚本
2. 遵循现有的命名约定和代码风格
3. 添加适当的错误处理和日志输出
4. 更新此 README 文档

## 许可证

测试脚本遵循与主项目相同的许可证。