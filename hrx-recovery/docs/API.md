# 恢复版API与业务边界

全部 /api/v1 接口需要验证的Bearer JWT及有效本地员工映射。无有效Token为401；无本地激活账号为403。身份不采纳浏览器传入的requestedBy/userId。生产需要配置 issuer/audience，以及部署壳注入的可信 HRX_AUTH.getAccessToken 适配器；不存在则业务默认拒绝。

采购资源 supply_chain 的权限 read/create/update/approve/receive/inspect/read_price 按明确人工批准的项目范围生效。controlled_file:read/create还需关联采购对象read。恢复版暂不恢复旧ORG/委托/岗位矩阵，不放宽为默认全公司。

- GET /me/profile、/me/capabilities：本人资料和导航能力，不能代替服务端对象授权。
- GET /supply-chain/projects、/projects/{id}/participants：授权项目及有update能力的采购责任人。
- GET /supply-chain/demands?page=0&size=20&q=：最多100条/页；无权限无记录。
- GET /supply-chain/demands/{id}、/{id}/events：详情与追加事件。未授权对象返回404。
- POST /supply-chain/demands：projectId,bomLine,materialCode,description,unit,quantity,requiredDate,leadTimeDays,criticalPath,buyerUserId。
- POST /supply-chain/demands/{id}/events：expectedRevision,eventCode,note,payload,evidenceRefs。
- GET /supply-chain/supplier-delivery：按授权单据/收货时承诺计算的批次准交样本，无承诺不伪造准交率。

所有POST需要8–128位安全字符的Idempotency-Key。同键同请求重放，同键异请求409；并发由数据库事务锁与版本锁检查，不允许多写事件。写入成功body在提交后发送；处理成HTTP错误仍回滚，提交失败不发送成功body。

流程：DRAFT → SUBMITTED → SOURCING → APPROVED → ORDERED → PART_RECEIVED/RECEIVED → CLOSED。REJECT回到DRAFT，重新询价开新轮；CANCEL只能在收货前，已批准订单取消需要独立批准人。每行内部PO登记，不向供应商发单或记库存。

QUOTE：supplier,currency（三位大写）,unitPrice，至少证据引用；必须同币种。APPROVE：quoteId，至少两家供应商，单一来源需singleSourceReason≥10字符。申请/采购/报价作者不能自批。
ISSUE_PO：poNumber和证据。PROMISE：promisedDate和供应商证据。
RECEIVE：quantity,batch,receivedDate，净已收（累计收-累计退）不可超量，禁止未来到货，申请人和采购人不可收货。
IQC：receiptId,acceptedQty,rejectedQty，总计等于收货批次。收货人不可检验同批；每批仅一次IQC，合格满量才CLOSED。拒收保留缺口，不自动补货或抹平库存。

价格属于保密字段，普通read不返回unitPrice，运行账号无原始报价JSON SELECT，只能调用当前身份的受控投影。

文件：GET /files/status、GET /files?demandId=、POST /files（multipart: demandId,documentId可选,expectedVersion,file）、GET /files/{id}/content。新文档expectedVersion=0；追加版本按当前版本写，冲突409，不能移动到其他需求。文件≤10MB，扫描CLEAN方可引用/下载；INFECTED/SCAN_FAILED隔离。下载重新检查对象与文件权限、实际字节SHA256，附件方式返回，禁浏览器内联执行。

文件关闭时手工hrx-file引用只是未验证登记。启用时每一条引用必须是同需求、当前身份可读、CLEAN、实际存在且完整性一致。病毒库、扫描容量和文件/数据库联合备份仍需生产运维验收。测试签名库只测试扫描链路，不能代替生产保护。


Recovery0.2的RETURN_REQUEST/RETURN_APPROVE/RETURN_REJECT/RETURN_SHIP payload、独立职责和补货数量定义见RETURNS.md。查询新增returned_qty（累计已退）、outstanding_rejected_qty（未退拒收）、receivable_qty（可收空间）；risk_code支持REPLACEMENT_PENDING。原累计收货和累计拒收不被覆盖。业务日期采用Asia/Shanghai。


Recovery0.3多行订单（完整约束见PURCHASE_ORDERS.md）：

- GET /purchase-orders?page=0&size=20&q=：按项目权限分页查询；金额为精确十进制字符串，无read_price返回null。
- GET /purchase-orders/candidates：当前指定采购员的已批准且未预留需求，最多300行。
- GET /purchase-orders/{id}、/{id}/lines、/{id}/events、/{id}/actions：授权订单及当前身份的动作提示；写入再次加锁校验。
- POST /purchase-orders：orderNo,note,lines:[{demandId,expectedRevision}]，1–100行；同项目／标准化供应商／币种，数量价格不可覆盖。
- POST /purchase-orders/{id}/events：expectedRevision,eventCode（APPROVED/REJECTED/ISSUED/CANCELLED）,note,evidenceRefs。批准和下单需证据；申请/采购/本轮报价作者不能整单自批。原子下单逐需求追加ISSUE_PO与审计。
- GET /files?purchaseOrderId= 与 POST /files multipart purchaseOrderId：与demandId互斥，订单文件不可跨对象引用或移动版本。

purchase_order资源read/create/approve/issue/cancel需人工配置，迁移不授予任何人员业务权限。订单读取同时需supply_chain:read；组单需create及供应链update/read_price；整单审批需approve及read_price。需求查询新增reserved_purchase_order_id/reserved_order_no/reserved_order_status，预留后单行ISSUE_PO/CANCEL返回409。整单退回或取消在下单前释放预留并保留历史；已下单变更流程未实现。
