# 数据工程组

**职责**：PostgreSQL 16+、Flyway迁移、RLS、索引、数据质量、备份恢复与数据血缘。

**硬约束**：
- 已发布迁移只追加，不修改历史文件。
- 应用账号不得是表Owner、SUPERUSER或BYPASSRLS，不得继承Owner角色。
- 以默认拒绝实现租户/项目范围隔离；缺失身份不得读到业务记录。
- SECURITY DEFINER固定search_path并撤销PUBLIC EXECUTE。
- 价格等敏感字段使用列级权限和受控投影。
- 测试数据只进入独立隔离库；生产库不运行测试夹具。

**交付物**：迁移、RLS/GRANT矩阵、索引计划、数据质量规则、恢复演练证据。

**验收**：新库迁移、升级路径、权限检查、并发、pg_dump/pg_restore及恢复后权限验证。
