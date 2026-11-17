import test from 'node:test';import assert from 'node:assert/strict';import {actions,retryKey,businessToday} from './workflow.js';
const caps={supply_chain:{read:true,update:true,approve:true,receive:true,inspect:true,read_price:true}},d={current_status:'SOURCING',requested_by:'requester',buyer_user_id:'buyer',sourcing_round:1,received_qty:0};
test('申请人/采购人不能自批，即使同时有审批能力',()=>{for(const who of ['buyer','requester'])assert.deepEqual(actions(d,who,caps),['QUOTE','CANCEL']);});
test('缺省拒绝和独立价格授权',()=>{assert.deepEqual(actions(d,'reviewer',{}),[]);assert.deepEqual(actions(d,'reviewer',{supply_chain:{approve:true}}),[]);assert.deepEqual(actions(d,'reviewer',caps),['APPROVE','REJECT']);});
test('本轮报价作者不能批准',()=>{assert.deepEqual(actions(d,'reviewer',caps,[{event_code:'QUOTE',actor_user_id:'reviewer',sourcing_round:1}]),[]);});
test('收货与检验分离，已检验批次不可复检',()=>{const demand={...d,current_status:'RECEIVED'},receipt={event_id:'r1',event_code:'RECEIVE',actor_user_id:'receiver'};assert.deepEqual(actions(demand,'receiver',caps,[receipt]),[]);assert.deepEqual(actions(demand,'inspector',caps,[receipt]),['IQC']);assert.deepEqual(actions(demand,'inspector',caps,[receipt,{event_code:'IQC',payload:'{"receiptId":"r1"}'}]),[]);});
test('终态无动作，批准后取消需独立授权',()=>{assert.deepEqual(actions({...d,current_status:'CLOSED'},'buyer',caps),[]);assert.deepEqual(actions({...d,current_status:'ORDERED'},'buyer',caps),['PROMISE']);assert.ok(actions({...d,current_status:'ORDERED'},'reviewer',caps).includes('CANCEL'));});
test('请求不变重试键不变，修改请求更换键',()=>{const ref={current:null};const first=retryKey(ref,{a:1});assert.equal(first,retryKey(ref,{a:1}));assert.notEqual(first,retryKey(ref,{a:2}));});

test('拒收退货申请、批准和发运继续职责分离',()=>{
 const demand={...d,current_status:'RECEIVED',received_qty:10,accepted_qty:8,rejected_qty:2,returned_qty:0};
 const receipt={event_id:'receipt',event_code:'RECEIVE',actor_user_id:'warehouse',payload:'{"quantity":10}'},inspection={event_id:'inspection',event_code:'IQC',actor_user_id:'inspector',payload:'{"receiptId":"receipt","acceptedQty":8,"rejectedQty":2}'};
 assert.deepEqual(actions(demand,'warehouse',caps,[receipt,inspection]),['RETURN_REQUEST']);assert.deepEqual(actions(demand,'inspector',caps,[receipt,inspection]),[]);
 const request={event_id:'return',event_code:'RETURN_REQUEST',actor_user_id:'warehouse',payload:'{"inspectionId":"inspection","receiptId":"receipt","returnQuantity":2}'};
 assert.deepEqual(actions(demand,'warehouse',caps,[receipt,inspection,request]),[]);assert.deepEqual(actions(demand,'approver',caps,[receipt,inspection,request]),['RETURN_APPROVE','RETURN_REJECT']);assert.deepEqual(actions(demand,'inspector',caps,[receipt,inspection,request]),[]);
 const approved={event_id:'approval',event_code:'RETURN_APPROVE',actor_user_id:'approver',payload:'{"returnRequestId":"return"}'};
 assert.deepEqual(actions(demand,'warehouse',caps,[receipt,inspection,request,approved]),['RETURN_SHIP']);assert.deepEqual(actions(demand,'approver',caps,[receipt,inspection,request,approved]),[]);
 const shipped={event_code:'RETURN_SHIP',actor_user_id:'warehouse',payload:'{"returnRequestId":"return"}'};
 assert.deepEqual(actions(demand,'warehouse',caps,[receipt,inspection,request,approved,shipped]),[]);
});
test('退货申请退回后可重新发起，同一检验的活跃申请不能重复',()=>{
 const demand={...d,current_status:'RECEIVED'},receipt={event_id:'receipt',event_code:'RECEIVE',actor_user_id:'warehouse',payload:'{}'},inspection={event_id:'inspection',event_code:'IQC',actor_user_id:'inspector',payload:'{"receiptId":"receipt","rejectedQty":2}'},request={event_id:'return',event_code:'RETURN_REQUEST',actor_user_id:'warehouse',payload:'{"inspectionId":"inspection","receiptId":"receipt","returnQuantity":2}'};
 const rejected={event_code:'RETURN_REJECT',actor_user_id:'approver',payload:'{"returnRequestId":"return"}'};
 assert.deepEqual(actions(demand,'warehouse',caps,[receipt,inspection,request]),[]);assert.deepEqual(actions(demand,'warehouse',caps,[receipt,inspection,request,rejected]),['RETURN_REQUEST']);
});

test('同一收货UUID的大小写不绕过前端已检验识别',()=>{
 const receipt={event_id:'ABC-RECEIPT',event_code:'RECEIVE',actor_user_id:'warehouse',payload:'{}'},iqc={event_id:'i',event_code:'IQC',actor_user_id:'inspector',payload:'{"receiptId":"abc-receipt","acceptedQty":5,"rejectedQty":0}'};
 assert.deepEqual(actions({...d,current_status:'RECEIVED'},'inspector',caps,[receipt,iqc]),[]);
});
test('业务日期按上海时区跨日，而非浏览器UTC截断',()=>{
 assert.equal(businessToday(new Date('2026-11-17T16:30:00Z')),'2026-11-18');assert.equal(businessToday(new Date('2026-11-17T15:59:59Z')),'2026-11-17');
});
