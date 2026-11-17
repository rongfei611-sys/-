export const status={DRAFT:'草稿',SUBMITTED:'已申请',SOURCING:'询价比价',APPROVED:'已批准',ORDERED:'内部PO已登记',PART_RECEIVED:'部分到货',RECEIVED:'已到货待检',CLOSED:'合格齐套',CANCELLED:'已取消'};
export const labels={SUBMIT:'提交申请',OPEN_RFQ:'开始询价',QUOTE:'登记报价',APPROVE:'批准报价',REJECT:'退回申请',ISSUE_PO:'登记内部PO',PROMISE:'登记交期承诺',RECEIVE:'登记批次到货',IQC:'独立来料检验',CANCEL:'取消需求'};
export const risk={READY:'合格齐套',CANCELLED:'已取消',IQC_REJECTED:'拒收待处理',OVERDUE:'需用超期',PROMISE_MISSING:'承诺待确认',PROMISE_LATE:'承诺延后',LEAD_TIME_RISK:'长交期采购风险',IQC_PENDING:'待检',IN_PROGRESS:'跟进中'};
export const parse=v=>typeof v==='string'?JSON.parse(v):v;
export function actions(d,actor,caps,events=[]){
 if(!actor||!d||['CLOSED','CANCELLED'].includes(d.current_status))return [];
 const owner=[d.requested_by,d.buyer_user_id].includes(actor),has=a=>caps?.supply_chain?.[a]===true,out=[];
 if(owner&&has('update')){if(d.current_status==='DRAFT')out.push('SUBMIT');if(d.current_status==='SUBMITTED')out.push('OPEN_RFQ');if(d.current_status==='SOURCING'&&has('read_price'))out.push('QUOTE');if(d.current_status==='APPROVED')out.push('ISSUE_PO');if(['ORDERED','PART_RECEIVED'].includes(d.current_status))out.push('PROMISE');if(['DRAFT','SUBMITTED','SOURCING'].includes(d.current_status))out.push('CANCEL');}
 if(!owner&&has('approve')){if(d.current_status==='SOURCING'&&has('read_price')&&!events.some(e=>e.event_code==='QUOTE'&&e.sourcing_round===d.sourcing_round&&e.actor_user_id===actor))out.push('APPROVE','REJECT');if(['APPROVED','ORDERED'].includes(d.current_status)&&Number(d.received_qty)===0)out.push('CANCEL');}
 if(!owner&&has('receive')&&['ORDERED','PART_RECEIVED'].includes(d.current_status))out.push('RECEIVE');
 if(!owner&&has('inspect')&&['PART_RECEIVED','RECEIVED'].includes(d.current_status)&&events.some(e=>e.event_code==='RECEIVE'&&e.actor_user_id!==actor&&!events.some(q=>q.event_code==='IQC'&&parse(q.payload).receiptId===e.event_id)))out.push('IQC');return out;
}
export function retryKey(ref,body){const signature=JSON.stringify(body);if(ref.current?.signature!==signature)ref.current={signature,key:crypto.randomUUID()};return ref.current.key;}
