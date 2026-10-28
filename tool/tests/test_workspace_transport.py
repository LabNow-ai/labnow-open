"""运行身份文件/原生SDK传输自动化；依赖替身不代表真实Console授权R。"""
import asyncio
import base64
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

PATH=Path(__file__).resolve().parents[2]/"src/labnow-open-etc/adapters/workspace_transport.py"
spec=importlib.util.spec_from_file_location("workspace_transport_under_test",PATH)
m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m)
BASE="https://console.invalid/console/api/token/runtime/v1"
def encoded(value):return base64.urlsafe_b64encode(json.dumps(value,separators=(",",":")).encode()).decode().rstrip("=")
def token(patch=None):
 now=int(time.time());value={"aud":m.AUDIENCE,"adapter":"hermes","iat":now,"exp":now+300}
 value.update(patch or {})
 return encoded(m.HEADER)+"."+encoded(value)+"."+"a"*43


class SourceTests(unittest.TestCase):
 def setUp(self):
  self.temporary=tempfile.TemporaryDirectory(prefix="workspace-source-",dir="/run")
  self.root=Path(self.temporary.name);self.value=token()
  self.claims=json.loads(base64.urlsafe_b64decode(self.value.split(".")[1]+"="*(-len(self.value.split(".")[1])%4)))
  self.policy={"version":1,"protected_env":["LABNOW_RUN_TOKEN"]}
  self.descriptor={"version":1,"adapter_id":"hermes","base_url":BASE,"model":"labnow-managed","expires_at":self.claims["exp"]}
  self.write("openclaw-managed-identity.json",self.policy)
  self.write("openclaw-runtime-identity.json",{"LABNOW_RUN_TOKEN":self.value},0o400)
  self.write("workspace-model.json",self.descriptor)
  self.source=m.WorkspaceSource(self.root,verify_mount=lambda *a:True)
 def tearDown(self):self.temporary.cleanup()
 def write(self,name,value,mode=0o444):
  p=self.root/name;p.write_text(json.dumps(value));p.chmod(mode)
 def test_native_contract_and_repr_hides_token(self):
  value=self.source.read();self.assertEqual(value.token,self.value);self.assertNotIn(self.value,repr(value));self.assertEqual(value.base_url,BASE)
 def test_expired_wrong_purpose_or_adapter_rejects(self):
  for patch2 in [{"exp":int(time.time())-1},{"aud":"foreign"},{"adapter":"openclaw"},{"iat":int(time.time())+1}]:
   with self.subTest(patch=patch2):
    self.write("openclaw-runtime-identity.json",{"LABNOW_RUN_TOKEN":token(patch2)},0o400)
    with self.assertRaises(m.WorkspaceTransportError):self.source.read()
 def test_extra_fields_wrong_target_or_model_rejects(self):
  for change in [{"role":"admin"},{"base_url":"http://console.invalid/console/api/token/runtime/v1"},{"base_url":BASE+"?x=1"},{"model":"foreign"},{"expires_at":0}]:
   self.write("workspace-model.json",{**self.descriptor,**change})
   with self.subTest(change=change),self.assertRaises(m.WorkspaceTransportError):self.source.read()
 def test_world_readable_secret_missing_policy_and_bad_mount_rejects(self):
  p=self.root/"openclaw-runtime-identity.json";p.chmod(0o444)
  with self.assertRaises(m.WorkspaceTransportError):self.source.read()
  p.chmod(0o400)
  with self.assertRaises(m.WorkspaceTransportError):m.WorkspaceSource(self.root,verify_mount=lambda *a:False).read()
  (self.root/"openclaw-managed-identity.json").unlink()
  with self.assertRaises(m.WorkspaceTransportError):self.source.read()
 def test_symlink_and_duplicate_json_keys_rejects(self):
  p=self.root/"workspace-model.json";p.unlink();p.symlink_to(self.root/"openclaw-managed-identity.json")
  with self.assertRaises(m.WorkspaceTransportError):self.source.read()
  p.unlink();p.write_text('{"version":1,"version":1}');p.chmod(0o444)
  with self.assertRaises(m.WorkspaceTransportError):self.source.read()


@unittest.skipUnless(importlib.util.find_spec("httpx") and importlib.util.find_spec("openai"),"需固定原生Hermes镜像的httpx/OpenAI SDK")
class NativeSDKTests(unittest.TestCase):
 def setUp(self):
  import httpx,openai
  self.httpx,self.openai=httpx,openai
  self.originals=[(cls,cls.__init__) for cls in [httpx.Client,httpx.AsyncClient,openai.OpenAI,openai.AsyncOpenAI]]
  self.environment=patch.dict(os.environ,{"LABNOW_RUN_MANAGED":"1"});self.environment.start()
  self.value=token();self.reads=0;self.calls=[]
  def read():self.reads+=1;return m.Snapshot(self.value,BASE,"labnow-managed",int(time.time())+300,"hermes")
  m._INSTALLED=False;m.install(source=SimpleNamespace(read=read))
 def tearDown(self):
  for cls,original in self.originals:cls.__init__=original
  m._INSTALLED=False
  if hasattr(self.httpx,"_labnow_workspace_transport_installed"):delattr(self.httpx,"_labnow_workspace_transport_installed")
  self.environment.stop()
 def handle(self,request):
  self.calls.append((str(request.url),request.headers.get("authorization")))
  return self.httpx.Response(200,json={"id":"fixture","object":"chat.completion","created":1,"model":"labnow-managed","choices":[{"index":0,"message":{"role":"assistant","content":"fixture"},"finish_reason":"stop"}]})
 def client(self,key=m.SENTINEL,base=BASE,**options):
  return self.openai.OpenAI(api_key=key,base_url=base,http_client=self.httpx.Client(transport=self.httpx.MockTransport(self.handle)),**options)
 def test_same_native_sdk_instance_adopts_new_token_without_changing_api_key(self):
  with self.client(max_retries=7) as client:
   self.assertEqual(client.max_retries,0)
   for seed in ["first","second"]:
    self.value=token({"jti":seed})
    client.chat.completions.create(model="labnow-managed",messages=[{"role":"user","content":"fixture"}],max_tokens=16)
   self.assertEqual(client.api_key,m.SENTINEL)
  self.assertEqual(len(self.calls),2);self.assertNotEqual(self.calls[0][1],self.calls[1][1]);self.assertTrue(all(c[0].endswith("/chat/completions/") for c in self.calls))
 def test_own_provider_key_and_options_preserved_without_reading_source(self):
  with self.client("fixture-own-key","https://own.invalid/v1",max_retries=7) as client:
   self.assertEqual(client.max_retries,7)
   client.chat.completions.create(model="own-model",messages=[{"role":"user","content":"fixture"}])
  self.assertEqual(self.reads,0);self.assertEqual(self.calls[0][1],"Bearer fixture-own-key")
 def test_foreign_target_rejected_before_transport(self):
  with self.client(base="https://foreign.invalid/v1") as client:
   with self.assertRaises(self.openai.APIConnectionError):client.chat.completions.create(model="labnow-managed",messages=[{"role":"user","content":"fixture"}])
  self.assertFalse(self.calls)
 def test_redirect_not_followed_with_or_without_authorization_copy(self):
  calls=[]
  def redirect(request):calls.append(str(request.url));return self.httpx.Response(302,headers={"location":"https://foreign.invalid/collect"})
  with self.httpx.Client(transport=self.httpx.MockTransport(redirect),follow_redirects=True) as client:
   with self.assertRaises(m.WorkspaceTransportError):client.get(BASE+"/models",headers={"authorization":"Bearer "+m.SENTINEL})
  self.assertEqual(len(calls),1)
 def test_async_client_uses_identical_bound_transport(self):
  async def run():
   async with self.openai.AsyncOpenAI(api_key=m.SENTINEL,base_url=BASE,http_client=self.httpx.AsyncClient(transport=self.httpx.MockTransport(self.handle))) as client:
    self.assertEqual(client.max_retries,0)
    await client.chat.completions.create(model="labnow-managed",messages=[{"role":"user","content":"fixture"}],max_tokens=16)
  asyncio.run(run());self.assertEqual(len(self.calls),1)
 def test_sdk_retry_header_and_source_failure_have_no_network_dispatch(self):
  with self.httpx.Client(transport=self.httpx.MockTransport(self.handle)) as client:
   with self.assertRaises(m.WorkspaceTransportError):client.get(BASE+"/models",headers={"authorization":"Bearer "+m.SENTINEL,"x-stainless-retry-count":"1"})
  self.assertFalse(self.calls)


if __name__=="__main__":unittest.main()
