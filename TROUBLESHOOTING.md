# 故障排除指南

## 常见问题及解决方案

### 1. 端口冲突问题

#### 问题描述
在多用户环境中，可能出现端口被占用的情况，导致mihomo启动失败。

#### 错误日志示例
```
level=error msg="Start DNS server(UDP) error: listen udp 0.0.0.0:1053: bind: address already in use"
level=error msg="Mixed(http+socks) proxy listening error: listen tcp 127.0.0.1:7890: bind: address already in use"
level=error msg="RESTful API listening error: listen tcp [::]:9090: bind: address already in use"
```

#### 解决方案

##### 自动解决（推荐）
脚本已内置端口冲突检测和自动分配功能：

1. **重新启动服务**：
   ```bash
   clash restart
   ```

2. **查看端口分配结果**：
   ```bash
   clash status
   ```

3. **脚本会自动**：
   - 检测端口占用情况
   - 随机分配新的可用端口
   - 更新配置文件
   - 显示端口变更信息

##### 手动解决
如果需要指定特定端口，可以编辑配置文件：

1. **编辑Mixin配置**：
   ```bash
   clash mixin -e
   ```

2. **修改端口配置**：
   ```yaml
   # Web控制台端口
   external-controller: "0.0.0.0:自定义端口"
   
   # 代理端口（在原始配置中设置）
   mixed-port: 自定义端口
   
   # DNS端口
   dns:
     listen: "0.0.0.0:自定义端口"
   ```

3. **重启服务**：
   ```bash
   clash restart
   ```

#### 端口范围建议
为避免冲突，建议使用以下端口范围：
- **代理端口**: 17000-18000
- **Web控制台**: 19000-20000  
- **DNS端口**: 15000-16000

### 2. 权限问题

#### 问题描述
用户空间运行时的权限相关问题。

#### 解决方案

1. **确保目录权限**：
   ```bash
   chmod -R 755 ~/tools/mihomo/
   ```

2. **检查脚本权限**：
   ```bash
   chmod +x ~/tools/mihomo/script/*.sh
   ```

3. **验证用户权限**：
   ```bash
   ls -la ~/tools/mihomo/
   ```

### 3. 配置文件问题

#### 问题描述
配置文件格式错误或内容无效。

#### 解决方案

1. **验证配置文件**：
   ```bash
   ~/tools/mihomo/bin/mihomo -d ~/tools/mihomo -f ~/tools/mihomo/runtime.yaml -t
   ```

2. **检查YAML语法**：
   ```bash
   ~/tools/mihomo/bin/yq eval ~/tools/mihomo/runtime.yaml
   ```

3. **重新生成配置**：
   ```bash
   clash update
   ```

### 4. 网络连接问题

#### 问题描述
无法访问订阅链接或代理服务器。

#### 解决方案

1. **检查网络连接**：
   ```bash
   curl -I http://www.google.com
   ```

2. **测试订阅链接**：
   ```bash
   curl -I "你的订阅链接"
   ```

3. **使用代理测试**：
   ```bash
   clash on
   curl -I http://www.google.com
   ```

### 5. 进程管理问题

#### 问题描述
进程无法正常启动或停止。

#### 解决方案

1. **检查进程状态**：
   ```bash
   clash status
   ```

2. **手动清理进程**：
   ```bash
   pkill -f mihomo
   rm -f ~/tools/mihomo/config/mihomo.pid
   ```

3. **重新启动**：
   ```bash
   clash on
   ```

### 6. 日志分析

#### 查看日志文件
```bash
# mihomo运行日志
tail -f ~/tools/mihomo/logs/mihomo.log

# 订阅更新日志
tail -f ~/tools/mihomo/mihomoctl.log

# subconverter日志
tail -f ~/tools/mihomo/bin/subconverter/latest.log
```

#### 常见日志信息
- `level=info`: 正常信息
- `level=warning`: 警告信息
- `level=error`: 错误信息
- `level=fatal`: 致命错误

### 7. 环境变量问题

#### 问题描述
代理环境变量未正确设置。

#### 解决方案

1. **检查环境变量**：
   ```bash
   echo $http_proxy
   echo $https_proxy
   echo $all_proxy
   ```

2. **重新设置代理**：
   ```bash
   clash proxy on
   ```

3. **清除代理设置**：
   ```bash
   clash proxy off
   ```

### 8. 多用户环境注意事项

#### 问题描述
多个用户同时使用可能导致冲突。

#### 解决方案

1. **使用不同端口范围**：
   - 用户A: 17000-17999
   - 用户B: 18000-18999
   - 用户C: 19000-19999

2. **独立配置目录**：
   每个用户的配置都在各自的 `~/tools/mihomo/` 目录下

3. **避免全局设置**：
   不要修改系统级配置，只使用用户级设置

### 9. 性能优化

#### 问题描述
代理服务运行缓慢或资源占用过高。

#### 解决方案

1. **调整日志级别**：
   ```yaml
   log-level: warning  # 减少日志输出
   ```

2. **优化DNS设置**：
   ```yaml
   dns:
     enable: true
     enhanced-mode: fake-ip
     nameserver:
       - 114.114.114.114
       - 8.8.8.8
   ```

3. **监控资源使用**：
   ```bash
   ps aux | grep mihomo
   ```

### 10. 获取帮助

如果以上解决方案都无法解决问题：

1. **运行诊断脚本**：
   ```bash
   ./test/test_port_conflict.sh
   ```

2. **收集系统信息**：
   ```bash
   uname -a
   clash status
   cat ~/tools/mihomo/logs/mihomo.log | tail -50
   ```

3. **提交Issue**：
   在项目仓库中提交详细的错误信息和系统环境

## 预防措施

1. **定期更新**：保持mihomo内核和脚本的最新版本
2. **备份配置**：定期备份重要配置文件
3. **监控日志**：定期检查日志文件，及时发现问题
4. **测试功能**：在重要变更后运行测试脚本验证功能
5. **文档更新**：保持配置文档与实际设置同步