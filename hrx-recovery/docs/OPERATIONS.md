# 新恢复工程运行与验证

只使用全新隔离库。源码依赖JDK21、Maven3.9+、Node>=22.12、PostgreSQL16+；本次实测17.11，不能改写为精确16.x通过。默认无用户、项目、授权和业务记录；须由授权管理员建立真实映射和独立批准的项目能力，应用没有授权写接口。

复制.env.example仅作参考，将实际密码放密钥管理。HRX_MIGRATE默认false，迁移与运行账号分开；新库DBA执行scripts/bootstrap.sql，迁移使用hrx_recovery_migrator/SET ROLE hrx_recovery_owner。运行账号非owner、非superuser、非BYPASSRLS、不是owner成员。示例引导不设置密码，只供隔离库或DBA按组织规范补充，不能把空密码用于生产。

前端 npm ci、npm test、npm run build。开发时设置HRX_API_TARGET=http://127.0.0.1:8080运行npm run dev；生产需可信同源网关与HRX_AUTH登录适配器，不能把测试Token带入生产。

后端 mvn clean verify。默认仅单元测试运行；未设置HRX_TEST_DB_URL时集成测试明确跳过，不能声称通过。

完整隔离复现：设置PGBIN为PostgreSQL的bin目录，将Maven加入PATH，然后 bash scripts/verify-isolated.sh。脚本创建loopback新临时集群，运行新迁移/测试/构建/恢复演练，退出删除。设置HRX_BROWSER=true启用Chromium，HRX_CHROMIUM可覆盖默认/usr/bin/chromium。

文件扫描测试另设HRX_CLAMSCAN（绝对路径）和HRX_SIGNATURES（专用测试签名目录）。测试HDB签名可使用：

```
44d88612fea8a8f36de82e1278abb02f:68:TEST-EICAR-ONLY
```

这只是已知EICAR样本签名，不提供生产防病毒保护。生产需要企业认可、持续更新的完整病毒库、可追溯版本、隔离和配额/并发/超时/保留策略。HRX_FILES_ENABLED默认false；配置目录、扫描器、签名库、版本后才可上传。存储为专用绝对私有路径，POSIX目录0700/文件0600，不静态暴露。尚未提供扫描更新后的全量复扫、对象存储和完整配额运维。

归档源码ZIP、逐文件manifest和SHA256；Git保存每阶段提交。只存临时工作区不能算用户已收到文件。当前公开仓库备份须得到明确许可，主分支不自动合并。
