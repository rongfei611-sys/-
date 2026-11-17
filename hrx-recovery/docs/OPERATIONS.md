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


## 0.1升级到0.2

首次使用仍必须是本恢复工程的新库，绝不用于原丢失V19.x库。已有Recovery0.1可停流量后按Flyway顺序升级V004，再同步部署0.2API与前端。V004新增累计已退字段、替换为净收货平衡约束、扩展退货事件守卫；不删除历史数据，不改写V001–V003。

已经创建退货/补货事件后，旧0.1界面不能正确解释累计/净收货或新事件，不能单独回退前端冒充兼容。采用向前修复；若确需整体回退，按已演练的备份恢复并同时处理文件存储和业务记录。当前恢复演练只覆盖数据库结构/授权，不代表联合灾备验收。

应用数据库会话和界面业务日期固定Asia/Shanghai；其它时区企业需要后续显式配置并重新验收。0.2测试不使用固定过期需用日期。


## Recovery0.2升级到0.3

只适用于本独立恢复工程：停止写流量、备份数据库与私有文件后，按Flyway执行新增V005并部署0.3后端和前端，V001–V004未改写。首次安装仍需新隔离库；不得迁移原V19.x库。V005新增订单表、预留唯一索引、RLS及受控投影，并扩展文件单归属约束与需求事件守卫。新增purchase_order权限必须由DBA依据人工批准按项目配置，应用无授权写接口。

订单已下单后不支持更改或撤销，不应直接改表。备份恢复演练也检查订单无身份不可读、运行账号无原始价格或表更新权限。正式启用文件服务前需配置生产签名库及独立私有存储；TEST签名不能用于生产。


## Recovery0.3升级到0.4

仅限本恢复工程数据库。备份数据库和私有文件、停写后按Flyway执行新增V006，并同步部署0.4API与前端。V001–V005未改动；V006新增只读security_invoker视图和授权订单履约函数，不修改业务数据或自动授予业务能力。继续使用原supply_chain:read/purchase_order:read项目范围。

视图要求PostgreSQL16+；应用账号仍非owner/非BYPASSRLS，不得给视图写权限。可用verify-isolated.sh复现新库、全部测试、六个恢复迁移和pg_dump/pg_restore授权检查。此步骤不覆盖企业生产容量或数据库+私有文件联合灾备验收。
