# 多行内部采购订单（恢复版0.3）

范围：同一项目、同一采购责任人、同供应商名称（忽略首尾空格/大小写）、同币种，1–100条已批准需求组成不可变PO。数量采用需求全量，单价/币种/供应商来自已批准报价；不接受浏览器覆盖，不做拆单数量、税费、汇率换算或财务结算。供应商名称匹配不等于恢复供应商主数据。

创建即PENDING_APPROVAL，订单行快照不可修改。APPROVED后由创建采购人ISSUED登记签发；REJECTED/CANCELLED在签发前释放需求占用，历史行和事件保留。签发后变更/取消/额度审批另建流程，本轮不提供。原单行登记仍保留，不能绕过多行PO的有效占用。

新增purchase_order:read/create/approve/issue/cancel项目能力，均需人工批准。PO读取还需supply_chain:read；整单批准还需supply_chain:read_price，并与所有行的申请人、采购人和本轮报价录入人分离。创建者须为所有行指定采购人，且具备各行update/read_price。签发者必须为PO创建人且具有issue和各行update。取消者为独立cancel权限人员，不能是任一行申请/采购人。

创建锁定全部需求（UUID稳定顺序），核对expectedRevision/APPROVED/无有效占用/同项目供应商币种；整单原子生成。行占用不改变需求业务状态或版本，阻止单行ISSUE_PO/CANCEL及重复组单。签发锁定PO与各需求，再核对原批准报价与版本，原子写入全部ISSUE_PO事件；任一行失败整体回滚。PO自身expectedRevision与Idempotency-Key控制并发和重试。

金额由数据库按原报价精确乘量、求和，只在read_price授权下返回字符串，普通账号隐藏unit_price/line_amount/total_amount，运行账号无原始价格列读取权。

API：
- GET /api/v1/purchase-orders?page=0&size=20&q=
- GET /api/v1/purchase-orders/candidates：本人可组单的已批准未占用需求与精确报价（最多300条）。
- GET /api/v1/purchase-orders/{id}、/{id}/lines、/{id}/events
- POST /api/v1/purchase-orders：orderNo,note,lines=[{demandId,expectedRevision}]
- POST /api/v1/purchase-orders/{id}/events：expectedRevision,eventCode(APPROVED/REJECTED/ISSUED/CANCELLED),note,evidenceRefs

APPROVED/ISSUED必须有证据；文件启用时必须为该PO自己的CLEAN文件，不得借用某一需求或其他PO文件。文件API新增可选purchaseOrderId，与demandId恰好一个；版本不可跨对象移动。归属和授权由数据库再次检查，需求文件原接口保持兼容。

本功能登记内部批准文件与签发状态，不自动发往供应商，不记库存/付款。项目金额额度制度、供应商合规、付款条件与审批后改单仍待业务Owner确认与后续实现。V005向前迁移，不修改V001–V004，不自动授予新能力。
