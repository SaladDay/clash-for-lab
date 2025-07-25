# Implementation Plan

- [x] 1. 修改核心配置和目录结构
  - 更新 common.sh 中的所有路径变量，将系统目录改为用户目录
  - 修改 CLASH_BASE_DIR 从 /opt/clash 到 $HOME/tools/mihomo
  - 移除所有 sudo 调用和权限检查
  - _Requirements: 1.1, 1.2_

- [x] 2. 实现用户级进程管理
  - 创建进程管理函数：start_mihomo(), stop_mihomo(), is_mihomo_running()
  - 使用 nohup 和 PID 文件替代 systemd 服务管理
  - 修改 clashon/clashoff/clashstatus 函数使用新的进程管理
  - _Requirements: 1.2, 2.1, 2.2_

- [x] 3. 更新配置文件和代理管理
  - 修改配置文件操作移除 sudo 调用
  - 更新代理环境变量设置函数
  - 修改配置合并和备份逻辑使用用户权限
  - 确保使用非特权端口（>1024）
  - _Requirements: 1.3, 2.3, 3.1_

- [x] 4. 修改订阅更新和安装脚本
  - 更新 clashupdate() 函数移除 sudo 调用
  - 修改 install.sh 使用用户目录安装
  - 更新自动更新使用用户级 crontab
  - 移除 systemd 服务创建代码
  - _Requirements: 1.1, 3.1, 3.2, 3.3_

- [x] 5. 完善命令行接口和测试
  - 保持原有命令接口兼容性
  - 更新帮助信息和状态显示
  - 创建基本的功能测试脚本
  - 更新 README.md 文档
  - _Requirements: 4.1, 4.2, 4.3_