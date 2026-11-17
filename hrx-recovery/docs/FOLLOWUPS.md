# 采购跟进待办（Recovery0.5）

按HRX_OS_CODEX_HANDOFF_V19_4业务方向继续开发。采购与齐套缺口可在需求详情内登记跟进事项、到期日；全局待办页可查本人负责或授权范围内全部待办，并跳回需求处理。只创建人员工作提醒，不自动发消息或对外催单。

责任人固定采用该需求的指定采购员，浏览器不能指定任意人员或伪造创建人。创建者必须是需求申请人或采购员，具有同项目supply_chain:read/update；指定采购员须为有效且具有read/update能力的员工。已CLOSED/CANCELLED的需求不能新建任务，已有待办仍可按权限人工收尾。

任务标题、关联需求、责任人、创建人不可编辑。OPEN任务可以：

- NOTE：创建人或责任人追加说明。
- RESCHEDULE：仅责任人调整到期日，说明必填，保留旧到期日和每次调整历史。
- COMPLETE：仅责任人完成人工跟进；不改变采购状态或登记交期、收货、检验、付款事实。
- CANCEL：仅任务创建人取消；保留历史。

DONE/CANCELLED为待办终态，不提供重开或删除。事件expectedRevision控制并发；所有POST需要Idempotency-Key；同请求重放稳定、异请求冲突。同一需求允许多条不同工作任务，系统不声称标题相同就代表同一业务事项。

到期日采用Asia/Shanghai业务日期；OPEN且到期日早于业务当日才算超期，当日不算超期。允许登记过去到期日以录入遗留工作。任务不会因到货或IQC完成自动关闭，也不能作为质量放行证明。

跟进证据可选。提供时，文件服务启用就验证为本需求下的当前可读CLEAN版本，并检查实际字节与SHA256；其他需求、隔离、缺失文件不能引用。未启用文件服务的手工引用仍只是未验证登记。

API：

- GET /api/v1/supply-chain/followups?page=0&size=20&state=OPEN&mine=true&demandId=：state支持OPEN/OVERDUE/DONE/CANCELLED/ALL，mine按当前服务端身份过滤，demandId可选；最多100条/页。
- GET /api/v1/supply-chain/followups/{id}、/{id}/events：授权任务与追加历史，越权对象404。
- POST /api/v1/supply-chain/followups：demandId,title,dueDate。
- POST /api/v1/supply-chain/followups/{id}/events：expectedRevision,eventCode,note,dueDate,evidenceRefs；只有RESCHEDULE接受且必须提供dueDate，其余必须为空。

V007新增RLS表、受控写函数和索引，不修改V001–V006。应用仅SELECT新表，不能直接INSERT/UPDATE/DELETE；函数固定search_path、撤销PUBLIC执行，写入重新检查当前身份与范围。审计和幂等记录与任务事件同事务提交。迁移不插入用户、业务数据或授权。

尚未实现：任意跨人分派、工作日历/节假日、企业消息推送、外部供应商门户、任务附件独立归属、多级督办或跨项目委托；不得将当前任务状态等同于供应商履约或项目整体状态。
