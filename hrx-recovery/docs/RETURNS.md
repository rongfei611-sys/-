# 拒收退货与补货（恢复版0.2）

本功能登记内部退货与替换证据，不发起供应商指令，不执行ERP/库存/财务过账。

新增事件：RETURN_REQUEST / RETURN_APPROVE / RETURN_REJECT / RETURN_SHIP。沿用每次写入的Idempotency-Key、expectedRevision、审计和项目级服务端授权。

1. 收货权限人员从同需求已完成的IQC记录发起退货，仅限该批拒收数量全部退回；不能自行输入更多数量，不允许重复退同一批。
2. 退货申请人不能是采购申请人、采购责任人或该批检验人。批准人需approve权限，并独立于采购申请人/采购责任人、退货申请人、原收货人和检验人；退回后可重新提出申请。
3. 只有已独立批准的退货能登记发运。发运人必须为原退货申请人，并与检验人、批准人分离。记录shipmentNo、shippedDate及证据，日期不早于原收货、不晚于今天。
4. 发运后才开放等量补货收货空间；补货仍需独立收货、单独IQC。不得将“已批准退货”直接视为已退运或已补齐。

累计收货received_qty与累计拒收rejected_qty保留；累计已退returned_qty另计。待检=累计收货-累计合格-累计拒收；未退拒收=累计拒收-累计已退；可收空间=需求-累计收货+累计已退。净已收不得超过需求，已退不得超过拒收。齐套仍仅以累计合格达到需求判定。

JSON payload：
- RETURN_REQUEST：inspectionId（IQC事件ID）；数据库根据拒收检验生成returnQuantity、receiptId，忽略客户端伪造数量。
- RETURN_APPROVE / RETURN_REJECT：returnRequestId；退回理由放note。
- RETURN_SHIP：returnRequestId,shipmentNo,shippedDate。

申请、批准、发运要求证据；文件服务启用时引用须为同需求、CLEAN、实际存在且哈希一致。审批退回不强制附件，仍需说明。

新增V004向前迁移，V001–V003不变。不删除或改写历史事件。该功能不提供已合格关闭后的保修退货、部分退货、货值退款、供应商主数据或税务处理；这些另建受控流程。
