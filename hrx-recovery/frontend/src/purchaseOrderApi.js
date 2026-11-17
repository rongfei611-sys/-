import {request} from './client.js';
const base='/api/v1/purchase-orders',path=id=>`${base}/${encodeURIComponent(id)}`,write=(url,body,key)=>request(url,{method:'POST',body:JSON.stringify(body),headers:{'Idempotency-Key':key}});
export const orders={list:(page=0,q='')=>request(`${base}?${new URLSearchParams({page,size:20,q})}`),candidates:()=>request(`${base}/candidates`),get:id=>request(path(id)),fulfillment:id=>request(`${path(id)}/fulfillment`),lines:id=>request(`${path(id)}/lines`),events:id=>request(`${path(id)}/events`),actions:id=>request(`${path(id)}/actions`),create:(body,key)=>write(base,body,key),append:(id,body,key)=>write(`${path(id)}/events`,body,key)};
export const orderStatus={PENDING_APPROVAL:'待整单审批',APPROVED:'整单已批准',ISSUED:'内部订单已登记',REJECTED:'已退回',CANCELLED:'已取消'};
export const orderLabels={APPROVED:'批准整单',REJECTED:'退回整单',ISSUED:'登记整单下单',CANCELLED:'取消整单'};
export const compatible=(a,b)=>!a||a.project_id===b.project_id&&a.supplier.trim().toLowerCase()===b.supplier.trim().toLowerCase()&&a.currency===b.currency;
