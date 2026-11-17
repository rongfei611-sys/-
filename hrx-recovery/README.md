# HRX-OS 恢复工程

这是 2026-11-17 根据本对话可见代码与业务契约重建的独立开发工程，**不是原 V19.5 压缩包的完整恢复**。原 V001–V014、确认版HTML、旧模块全部源码和原测试证据已不可取得；不能声称原文件哈希或旧测试仍有效。

优先重建采购/PMC、JWT身份、服务端权限/RLS、幂等/并发、受控文件及可运行界面。原项目交付、工程支持、成长、呆滞料、ECN/NCR/FAT/SAT完整模块继续列为缺失，不创建空壳入口或伪造经营数据。

本工程采用新的数据库基线，**只用于新的隔离数据库**，不得覆盖旧系统数据库。详见 docs/RECOVERY.md。所有实际测试结果另行记录，不沿用之前的33/37通过声明。

当前检查点的真实验证见 docs/VALIDATION.md。源码已放入当前挂载仓库子目录 hrx-recovery，本地Git分支 recovery/hrx-20261117；不再只放临时目录。

开发：JDK21、Maven3.9+、Node>=22.12、PostgreSQL16+。前端 npm ci / npm test / npm run build；后端使用全新隔离数据库引导角色后运行 mvn verify。真实数据库测试须设置 HRX_TEST_DB_URL，数据库名必须以 hrx_test_ 开头；HRX_BROWSER=true启用Chromium脚本。企业OIDC仍由部署壳注入HRX_AUTH，不存在时默认拒绝业务操作。
