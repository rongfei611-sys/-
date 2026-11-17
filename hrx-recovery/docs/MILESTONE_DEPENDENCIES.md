# 项目里程碑前置依赖（Recovery0.7）

继续按HRX_OS_CODEX_HANDOFF_V19_4方向完善项目交付。新增同项目里程碑之间的前置关系、阻塞筛选、日期倒挂提示与关联导航；不把统计、依赖解除或完成记录确认等同于合同验收、生产许可或质量放行。

创建里程碑时可提供predecessorIds，0–30个不同的同项目已有里程碑UUID。不可引用不存在、取消或其他项目的里程碑，即使同时拥有两个项目的权限也不能混用。旧请求省略或传空列表保持无依赖。

依赖在创建时固定，不提供修改、删除或给历史里程碑追加依赖的API。所有边只从新建节点指向已存在节点，因此应用可创建的图无自引用/循环；不做自动推断、自动延期或自动串联状态。旧0.6里程碑不被自动加依赖。

开始门槛：全部前置里程碑必须已经由独立人员CONFIRM，后续负责人才能START。SUBMIT/CONFIRM也再次检查前置条件。前置仅已提交、进行中、计划中均不能解除阻塞。前置完成后后续仍保持PLANNED，须负责人手动开始。

取消门槛：存在任何未取消后续事项时，不能取消当前前置事项。先人工取消不再需要的后续事项才可取消前置，不自动级联取消；CONFIRMED/CANCELLED终态规则不变。取消前置与创建后续共同锁定前置行，避免留下依赖已取消节点的有效事项。

日期风险：前置计划日期晚于当前计划时给出数量提示，不自动改计划日期。延期仍由指定负责人追加带理由与前后日期的RESCHEDULE事件。日期倒挂不替代正式项目基线审批或排程算法。

新增读模型字段：predecessor_count、unconfirmed_predecessors、active_successors、late_predecessor_dates、blocked。blocked仅表示PLANNED且仍有未确认前置；已取消的事项不记入阻塞数。项目汇总新增blocked_milestones，列表支持state=BLOCKED及q标题搜索；项目权限继续按project_delivery:read检查。

API变化：

- POST /api/v1/project-delivery/milestones：原字段加可选predecessorIds。创建与全部依赖同事务完成，任一无效关系整体回滚，重复引用422、跨项目/不存在403、取消前置409、超过30项400。
- GET /api/v1/project-delivery/milestones?state=BLOCKED&q=&projectId=&page=0&size=20。
- GET /api/v1/project-delivery/milestones/{id}/dependencies：predecessors与successors列表、successorTotal；前置最多30项，后续显示前100项并标识总数，不称为完整项目图。
- 原START/SUBMIT/CONFIRM遇前置阻塞、CANCEL遇活跃后续均409；旧版本也仍409。

新增V009：依赖表RLS、复合外键强制两端同项目、运行账号仅SELECT、security_invoker进度视图、受控创建函数与原状态函数的依赖检查。未修改V001–V008、未新增默认授权。创建身份和审计由服务端处理；边的创建人/时间对应不可变里程碑创建记录。运行账号无直接插入/更新/删除关系权限。

兼容：无依赖的新创建请求继续采用旧四字段记录的幂等指纹，保证0.6已保存的milestone.create键可重放。显式空数组与省略一致；带非空前置列表的同键不同请求冲突，不将旧键用于新计划。

验证包括：多前置逐一确认解阻、取消保护、跨项目拒绝、重复/不存在/取消节点的整体回滚、取消与创建并发互斥、旧版指纹重放、RLS及禁止直接改关系。浏览器实测前置选择/搜索、阻塞筛选、关联导航、独立确认前置与手动启动后续。

未实现：依赖关系后续变更审批、项目完整WBS、工期估算/自动排程、正式关键路径算法、跨项目依赖、基线审批/合同验收，以及工程/质量全模块；不能用当前阻塞视图宣称项目全量风险已覆盖。
