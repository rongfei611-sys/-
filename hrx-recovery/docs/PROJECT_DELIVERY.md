# 项目交付里程碑（Recovery0.6）

按HRX_OS_CODEX_HANDOFF_V19_4业务方向继续扩展项目交付模块。当前实现项目里程碑计划、责任人、计划日期、进展、延期、完成证据、独立复核和项目受控文件。不是完整项目管理或合同验收系统，不自动改变采购、库存、质量放行或付款状态。

新增项目范围资源project_delivery:read/create/update/verify，须人工批准；迁移不自动给任何人权限。仅有该资源的用户不继承supply_chain权限，原采购项目列表显式过滤采购范围。项目基础资料仍由原业务项目表引用，不提供无授权项目/人员/角色维护接口。

里程碑创建者需read/create，负责人员必须是同项目已激活且具有read/update的员工。项目与责任人、标题和创建人创建后不可改；日期变更必须追加RESCHEDULE事件，保存调整前后日期、原因和操作者。项目和责任人选择器各最多300条已授权记录。

状态与职责：

- PLANNED → START → IN_PROGRESS：仅指定负责人，需update。
- NOTE：创建人或负责人需update，可在PLANNED/IN_PROGRESS追加进展。
- RESCHEDULE：负责人需update，在PLANNED/IN_PROGRESS调整日期并说明。
- IN_PROGRESS → SUBMIT → SUBMITTED：负责人提交完成记录，必须引用项目证据。
- SUBMITTED → CONFIRM → CONFIRMED：具有verify的独立人员确认完成记录，必须引用项目证据；不能是创建人、负责人或提交人。
- SUBMITTED → RETURN → IN_PROGRESS：同样由独立verify人员退回；负责人可补充后再次提交。
- PLANNED/IN_PROGRESS → CANCEL → CANCELLED：仅创建人且需update。

SUBMITTED冻结进展/日期更改，先由复核人退回。CONFIRMED/CANCELLED为终态，不提供重开或删除。独立确认只确认本里程碑完成记录，不代表FAT/SAT、ECN/NCR、合同验收或生产许可。AI不代替人员批准。

OPEN概念对应尚未CONFIRMED/CANCELLED的里程碑；计划日期早于Asia/Shanghai当日时标记超期，已提交但未确认仍可超期。允许录入过去日期，不把空项目视为已完成项目。项目总览显示总数、已确认、待复核和超期行数，不将里程碑个数当成加权项目完成率。

所有POST要求Idempotency-Key。追加事件要求expectedRevision，数据库锁定里程碑并再次检查范围、职责、状态和证据引用格式；同键重放稳定，并发一胜一冲突。审计与事件/幂等同事务提交。应用只能SELECT里程碑表，不可直接改状态或事件。

API：

- GET /api/v1/project-delivery/projects：授权项目与里程碑行数。
- GET /api/v1/project-delivery/projects/{id}/participants：同项目可负责员工。
- GET /api/v1/project-delivery/milestones?projectId=&state=ALL&page=0&size=20：按项目、状态或OVERDUE分页，最多100条/页。
- GET /api/v1/project-delivery/milestones/{id}、/{id}/events。
- POST /api/v1/project-delivery/milestones：projectId,title,plannedDate,responsibleUserId。
- POST /api/v1/project-delivery/milestones/{id}/events：expectedRevision,eventCode,note,plannedDate,evidenceRefs；仅RESCHEDULE接受且必须提供plannedDate。

文件：GET /files?projectId= 及POST multipart projectId。demandId/purchaseOrderId/projectId恰好一个；同文档版本不能跨需求、订单或项目移动。project_delivery:read之外还需controlled_file:read/create。项目文件在同项目里程碑间共享，引用固定到不可变版本；新增版本不会改写既有完成记录证据。下载重新授权、扫描CLEAN并校验实际SHA256，隔离文件不可下载/引用。

启用文件服务后，提交/确认及其他提供的引用都必须是本项目内的可读CLEAN真实文件，其他项目/需求/订单、缺失/隔离文件均拒绝。未配置文件服务时手工引用仍只作未验证登记。测试使用TEST签名，非生产病毒库。

V008仅针对本独立恢复工程，新增表/RLS/受控函数，扩展三类文件归属和项目参考资料读取策略；不改写V001–V007。旧迁移及数据不被删除或重写。

待补齐：项目层级与依赖、基线审批/变更、工作日历、工时/成本、合同验收、工程/质量全模块、跨组织委托、企业系统对接与生产验收。当前模块不是原旧版本全部源码的恢复。
