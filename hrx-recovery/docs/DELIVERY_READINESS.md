# 订单履约与项目齐套（Recovery0.4）

继续HRX_OS_CODEX_HANDOFF_V19_4的业务方向，在现有可运行恢复工程上开发。原附件缺失不再阻断开发；本轮不声明原历史源码已恢复。

订单履约接口GET /api/v1/purchase-orders/{id}/fulfillment：订单头、汇总、逐行当前状态在同一条SQL语句内读取，返回as_of快照时间和Asia/Shanghai业务日期。读权限同时需要purchase_order:read和supply_chain:read，按项目验证；无权对象404。只读人员可看数量与交期，接口不包含单价、金额或原始报价JSON。

只有订单已ISSUED且需求上存在该订单生成的ISSUE_PO事件时，才关联当前交付数据。PENDING_APPROVAL/APPROVED/REJECTED/CANCELLED均显示NOT_ISSUED，实时收退货/合格/缺口字段null。旧订单退回、需求另行组单后，旧单不能认领新单履约。

每行按自己的单位展示需求量、累计收货、累计已退、净已收、累计合格、累计拒收、待检、未退拒收、合格缺口及可收空间；数量按数据库精确十进制字符串返回。净已收＝累计收货－累计已退；待检＝累计收货－累计合格－累计拒收；未退拒收＝累计拒收－累计已退；合格缺口＝需求量－累计合格。不跨物料或单位相加。

汇总只统计行数：合格齐套、需用超期、承诺待确认、承诺延后、待检、未退拒收和退货后待补货。风险可重叠，汇总不等于互斥状态分布。已下单且每行均CLOSED才显示READY；有收货但待检/拒收/补货均不是合格齐套。

项目齐套：

- GET /api/v1/supply-chain/readiness?page=0&size=20&q=：按项目编码或名称查询，最多100项目/页，仅supply_chain:read授权项目。
- GET /api/v1/supply-chain/readiness/{project}/demands?filter=SHORTAGE&page=0&size=20：同范围下按关键路径、需用日期分页查询需求；未授权项目404。
- 支持ALL/SHORTAGE/READY/OVERDUE/CRITICAL/IQC/REJECTED/PROMISE_MISSING/PROMISE_LATE/REPLACEMENT筛选；未知筛选400。

齐套率＝CLOSED需求行数／未取消需求行数。空项目或只有取消行时显示暂无有效需求，不显示100%或虚构率值。缺口和关键路径缺口不计取消行。按行统计，不能代表BOM完整性、库存可投产或全项目交付验收。

数据投影：V006新增security_invoker视图supply_progress，继续执行底层需求RLS；现有需求查询与新报表共用一份风险/数量定义。订单投影函数固定search_path、撤销PUBLIC执行权，并逐对象校验当前身份。无身份不可读，无授权写接口，无新增默认业务授权，不改变任何业务状态。

页面支持从项目明细或订单履约行进入原需求流程；所有写动作仍走原服务端职责分离、证据、版本、幂等与审计。页面只帮助定位业务，不自动批准或过账。

未完成：实时推送、企业供应商主数据、库存可用量、BOM覆盖率、项目/工程/质量全模块、原岗位矩阵，以及正式生产环境联调；当前不因统计显示READY而自动放行生产。
