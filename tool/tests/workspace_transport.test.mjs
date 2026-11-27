import test from "node:test";
import assert from "node:assert/strict";
import { createWorkspaceFetch, createWorkspaceSource, workspaceGuardedFetchOptions, SENTINEL } from "../../src/labnow-open-etc/adapters/workspace_transport.mjs";

const base = "https://console.invalid/console/api/token/runtime/v1";
const header = Buffer.from(JSON.stringify({alg:"HS256",typ:"labnow-run+jwt",v:1})).toString("base64url");
const token = (id="a", patch={}) => header + "." + Buffer.from(JSON.stringify({aud:"labnow-console-workspace-model-v1",adapter:"openclaw",iat:100,exp:400,jti:id,...patch})).toString("base64url") + "." + "a".repeat(43);
const body = JSON.stringify({model:"labnow-managed",messages:[{role:"user",content:"fixture"}],max_tokens:16});
function fixture() {
  let value=token(), count=0;
  const calls=[];
  const send=async (input,init)=>{const request=new Request(input,init);calls.push({url:request.url,method:request.method,headers:new Headers(request.headers),body:request.method==="POST"?await request.text():null,redirect:request.redirect});return new Response(JSON.stringify({object:"chat.completion"}),{headers:{"Content-Type":"application/json"}});};
  const source={read(){count++;return{token:value,baseUrl:base,model:"labnow-managed",expiresAt:400};}};
  return {calls,fetch:createWorkspaceFetch({source,send}),set:value2=>value=value2,count:()=>count};
}
const request=(f,extra={})=>f.fetch(base+"/chat/completions",{method:"POST",headers:{authorization:"Bearer "+SENTINEL,"Content-Type":"application/json",...extra},body});

test("配置标记只在固定模型路径换为系统身份，保持JSON与信号",async()=>{
 const f=fixture(),response=await request(f);
 assert.equal(response.status,200);assert.equal(f.calls.length,1);
 assert.equal(f.calls[0].url,base+"/chat/completions/");assert.equal(f.calls[0].headers.get("authorization"),"Bearer "+token());
 assert.equal(f.calls[0].body,body);assert.equal(f.calls[0].redirect,"error");
});
test("同一SDK缓存的标记/旧JWT在下一次发送使用新身份",async()=>{
 const f=fixture();await request(f);f.set(token("b"));await request(f,{authorization:"Bearer "+token("a")});
 assert.equal(f.calls[0].headers.get("authorization"),"Bearer "+token("a"));assert.equal(f.calls[1].headers.get("authorization"),"Bearer "+token("b"));assert.equal(f.count(),2);
});
test("自持Key保持原始fetch入参，不读平台源",async()=>{
 let input,options,reads=0;
 const target="https://own.invalid/v1/chat/completions",init={method:"POST",headers:{authorization:"Bearer fixture-own-key"},body};
 const fetch=createWorkspaceFetch({source:{read(){reads++;throw Error("must_not_read");}},send:async(a,b)=>{input=a;options=b;return new Response("ok");}});
 assert.equal((await fetch(target,init)).status,200);assert.equal(input,target);assert.equal(options,init);assert.equal(reads,0);
});
test("跨来源、任意路径、查询参数及方法覆盖在发送前拒绝",async()=>{
 for(const [url,method] of [["https://foreign.invalid/v1/chat/completions","POST"],[base+"/admin","POST"],[base+"/chat/completions?user_id=foreign","POST"],[base+"/models","DELETE"]]){
  const f=fixture(),r=await f.fetch(url,{method,headers:{authorization:"Bearer "+SENTINEL},body:method==="POST"?body:undefined});
  assert.equal(r.status,403);assert.equal(f.calls.length,0);assert.equal(r.headers.get("x-should-retry"),"false");
 }
});
test("原生SDK重试计数拒绝，原始模型操作不重放",async()=>{
 const f=fixture();assert.equal((await request(f,{"x-stainless-retry-count":"1"})).status,409);assert.equal(f.calls.length,0);
});
test("模型列表允许GET固定路径且不改变原响应",async()=>{
 const f=fixture();const r=await f.fetch(base+"/models",{headers:{authorization:"Bearer "+SENTINEL}});
 assert.equal(r.status,200);assert.equal(f.calls[0].url,base+"/models/");
});
test("源故障和网络故障均只回安全错误，不泄露身份或自动重试",async()=>{
 const secret=token();let count=0;
 for(const broken of [true,false]){
  const fetch=createWorkspaceFetch({source:{read(){if(broken)throw Error(secret);return{token:secret,baseUrl:base};}},send:async()=>{count++;throw Error(secret);}});
  const r=await fetch(base+"/chat/completions",{method:"POST",headers:{authorization:"Bearer "+SENTINEL},body});
  assert.equal(r.status,503);assert.equal(r.headers.get("x-should-retry"),"false");assert.equal((await r.text()).includes(secret),false);
 }
 assert.equal(count,1);
});
test("其他header不能携带平台JWT",async()=>{
 const f=fixture();assert.equal((await request(f,{"x-copy":token()})).status,503);assert.equal(f.calls.length,0);
});
function sourceFixture(patch={}){
 const t=token("a",patch),policy={names:["LABNOW_RUN_TOKEN"],values:[t],digest:"fixture-stable"};
 let meta={version:1,adapter_id:"openclaw",base_url:base,model:"labnow-managed",expires_at:400};
 const source=createWorkspaceSource({policy:{read(){return policy;}},readDescriptor(){return{value:meta,encoded:Buffer.from(JSON.stringify(meta))};},now:()=>100});
 return{source,policy,setMeta:m=>meta=m,meta};
}
test("系统合同检查目的、300秒、adapter与明确HTTPS目标",()=>{
 assert.equal(sourceFixture().source.read().token,token());
 for(const patch of [{aud:"foreign"},{adapter:"hermes"},{iat:101},{exp:100},{exp:401}])assert.throws(()=>sourceFixture(patch).source.read());
 for(const patch of [{base_url:"http://console.invalid/console/api/token/runtime/v1"},{base_url:base+"?x=1"},{model:"foreign"},{expires_at:401},{role:"admin"}]){
  const f=sourceFixture();f.setMeta({...f.meta,...patch});assert.throws(()=>f.source.read());
 }
});
test("读期间轮换失败关闭，不缓存授权成功",()=>{
 const f=sourceFixture();let n=0;
 const source=createWorkspaceSource({policy:{read(){return{...f.policy,digest:String(n++)};}},readDescriptor(){return{value:f.meta,encoded:Buffer.from("fixture")};},now:()=>100});
 assert.throws(()=>source.read());
});


test("原生槽保留dispatcher和取消信号，不把当前JWT写回SDK入参",async()=>{
 const previous=process.env.LABNOW_RUN_MANAGED;process.env.LABNOW_RUN_MANAGED="1";
 try {
  const dispatcher={},abort=new AbortController();let sent,reads=0;
  const headers=new Headers({authorization:"Bearer "+SENTINEL,"content-type":"application/json"});
  const options={url:base+"/chat/completions",init:{method:"POST",headers,body,signal:abort.signal},policy:{allowedHostnames:["console.invalid"]},maxRedirects:4};
  const prepared=workspaceGuardedFetchOptions(options,async(input,init)=>{sent={input,init};return new Response("ok");},{read(){reads++;return{token:token(),baseUrl:base};}});
  assert.equal(prepared.maxRedirects,0);assert.equal(prepared.policy,options.policy);assert.notEqual(prepared,options);
  const response=await prepared.fetchImpl(options.url,{...options.init,dispatcher});
  assert.equal(response.status,200);assert.equal(reads,1);assert.equal(sent.init.dispatcher,dispatcher);
  assert.equal(sent.init.headers.get("authorization"),"Bearer "+token());assert.equal(headers.get("authorization"),"Bearer "+SENTINEL);
  assert.equal(await new Request(sent.input,sent.init).text(),body);abort.abort();assert.equal(sent.init.signal.aborted,true);
 } finally {if(previous===undefined)delete process.env.LABNOW_RUN_MANAGED;else process.env.LABNOW_RUN_MANAGED=previous;}
});
test("原生普通模式和自持Key不改变原始guard选项",()=>{
 const previous=process.env.LABNOW_RUN_MANAGED;
 try {
  const own={url:base,init:{headers:{authorization:"Bearer fixture-own"}}};
  process.env.LABNOW_RUN_MANAGED="1";assert.equal(workspaceGuardedFetchOptions(own,()=>{}),own);
  process.env.LABNOW_RUN_MANAGED="0";const marked={url:base,init:{headers:{authorization:"Bearer "+SENTINEL}}};assert.equal(workspaceGuardedFetchOptions(marked,()=>{}),marked);
 } finally {if(previous===undefined)delete process.env.LABNOW_RUN_MANAGED;else process.env.LABNOW_RUN_MANAGED=previous;}
});
