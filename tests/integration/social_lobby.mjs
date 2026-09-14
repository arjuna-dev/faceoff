// Local-only test fixture: phone ownership is seeded through the dev database,
// never through a production RPC or a client-accessible authentication bypass.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const base = 'http://127.0.0.1:7352';
const accounts = [];
const run = Date.now();
const sockets = [];
async function auth(id) {
 const r = await fetch(base+'/v2/account/authenticate/device?create=true', {method:'POST',headers:{'Content-Type':'application/json',Authorization:'Basic '+Buffer.from('devserverkey:').toString('base64')},body:JSON.stringify({id})});
 assert.equal(r.status,200,'device bootstrap');
 const s = await r.json(); s.uid = JSON.parse(Buffer.from(s.token.split('.')[1],'base64url')).uid; accounts.push(s); return s;
}
async function rpc(a, id, data={}) {
 const r=await fetch(base+'/v2/rpc/'+id,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+a.token},body:JSON.stringify(JSON.stringify(data))});
 const body=await r.json(); return {status:r.status,data:r.ok?JSON.parse(body.payload):body};
}
function seed(a,name,phone) {
 const records=[['profiles','phone',a.uid,{name,phone}],['phone_directory',createHash('sha256').update(phone).digest('hex'),'00000000-0000-0000-0000-000000000000',{user_id:a.uid,name}]];
 for (const [collection,key,user,value] of records) {
  const json=JSON.stringify(value).replaceAll("'","''");
  execFileSync('docker',['exec','-i','faceoff-dev-postgres-1','psql','-U','nakama','-d','nakama','-v','ON_ERROR_STOP=1'],{input:`INSERT INTO storage(collection,key,user_id,value,version,read,write) VALUES ('${collection}','${key}','${user}','${json}',md5('${json}'),0,0) ON CONFLICT(collection,key,user_id) DO UPDATE SET value=EXCLUDED.value,version=EXCLUDED.version;`,stdio:['pipe','pipe','pipe']});
 }
}
async function connect(a) {
 const ws=new WebSocket('ws://127.0.0.1:7352/ws?lang=en&status=true&token='+encodeURIComponent(a.token));
 const messages=[];ws.addEventListener('message',e=>messages.push(JSON.parse(e.data))); sockets.push(ws);
 await new Promise((resolve,reject)=>{ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',()=>reject(new Error('socket connection')),{once:true})});
 return {ws,messages};
}
async function wait(p,label) {for(let i=0;i<100;i++){const v=p();if(v)return v;await new Promise(r=>setTimeout(r,30));}throw new Error('Timeout: '+label)}
async function join(c,id) {const cid=String(Math.random());c.ws.send(JSON.stringify({cid,match_join:{match_id:id}}));return wait(()=>c.messages.find(m=>m.cid===cid),'join response')}
try {
 const a=await auth('faceoff-social-test-a-'+run), b=await auth('faceoff-social-test-b-'+run), stranger=await auth('faceoff-social-test-stranger-'+run);
 assert.notEqual((await rpc(stranger,'faceoff_call_invite',{target:a.uid})).status,200,'unverified account cannot invite');
 assert.notEqual((await rpc(stranger,'faceoff_invite_link',{phone:'+4522206992'})).status,200,'unverified account cannot create invite links');
 const custom=await fetch(base+'/v2/account/authenticate/custom?create=true',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Basic '+Buffer.from('devserverkey:').toString('base64')},body:JSON.stringify({id:'+15550000001',vars:{code:'123456'}})});
 assert.notEqual(custom.status,200,'unverified phone authentication denied');
 const link=await fetch(base+'/v2/account/link/custom',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+stranger.token},body:JSON.stringify({id:'phone:+15550000001'})});
 assert.notEqual(link.status,200,'phone identity linking bypass denied');
 seed(a,'Alice','+15550000001');seed(b,'Bob','+15550000002');
 assert.equal((await rpc(a,'faceoff_contacts',{phones:['+15550000002']})).data.contacts[0].user_id,b.uid);
 const inviteLink=await rpc(a,'faceoff_invite_link',{phone:'+4522206992'});
 assert.equal(inviteLink.status,200,JSON.stringify(inviteLink.data));
 assert.match(inviteLink.data.token,/^[0-9a-f-]{36}$/i,'invite link is an opaque UUID handle');
 const resolvedInvite=await rpc(stranger,'faceoff_invite_resolve',{token:inviteLink.data.token});
 assert.equal(resolvedInvite.status,200,JSON.stringify(resolvedInvite.data));
 assert.equal(resolvedInvite.data.phone,'+4522206992','invite resolves to the prefilled phone');
 assert.notEqual((await rpc(stranger,'faceoff_invite_claim',{token:inviteLink.data.token})).status,200,'unverified recipient cannot claim an invite');
 assert.notEqual((await rpc(b,'faceoff_invite_resolve',{token:'not-a-token'})).status,200,'malformed invite cannot be resolved');
 const claimLink=await rpc(a,'faceoff_invite_link',{phone:'+15550000002'});
 assert.equal(claimLink.status,200,JSON.stringify(claimLink.data));
 const claimed=await rpc(b,'faceoff_invite_claim',{token:claimLink.data.token});
 assert.equal(claimed.status,200,JSON.stringify(claimed.data));
 assert.equal(claimed.data.claimed,true,'verified recipient can claim an invite for its phone');
 const claimedInbox=await rpc(b,'faceoff_inbox');
 assert.equal(claimedInbox.status,200,JSON.stringify(claimedInbox.data));
 assert.ok(claimedInbox.data.contacts.some(c=>c.user_id===a.uid),'invite claim creates the recipient contact record');
 const wa=await connect(a),wb=await connect(b),wx=await connect(stranger);
 let invite=await rpc(a,'faceoff_call_invite',{target:b.uid});assert.equal(invite.status,200,JSON.stringify(invite.data));
 let id=invite.data.id;
 assert.notEqual((await rpc(a,'faceoff_call_invite',{target:b.uid})).status,200,'busy call cannot be duplicated');
 assert.notEqual((await rpc(a,'faceoff_call_action',{id,action:'accept'})).status,200,'caller cannot accept own call');
 assert.notEqual((await rpc(b,'faceoff_call_action',{id,action:'cancel'})).status,200,'callee cannot cancel outgoing');
 assert.equal((await rpc(b,'faceoff_call_action',{id,action:'decline'})).data.status,'declined');
 assert.notEqual((await rpc(b,'faceoff_call_action',{id,action:'accept'})).status,200,'declined call cannot start');
 invite=await rpc(a,'faceoff_call_invite',{target:b.uid}); id=invite.data.id;
 assert.equal((await rpc(a,'faceoff_call_action',{id,action:'cancel'})).data.status,'cancelled');
 execFileSync('docker',['exec','-i','faceoff-dev-postgres-1','psql','-U','nakama','-d','nakama','-v','ON_ERROR_STOP=1'],{input:`UPDATE storage SET value=jsonb_set(jsonb_set(value,'{status}','"ringing"'),'{expires}','0') WHERE collection='calls' AND key='${id}';`,stdio:['pipe','pipe','pipe']});
 assert.equal((await rpc(b,'faceoff_call_action',{id,action:'status'})).data.status,'expired');
 assert.notEqual((await rpc(b,'faceoff_call_action',{id,action:'accept'})).status,200,'expired call cannot start');
 invite=await rpc(a,'faceoff_call_invite',{target:b.uid}); id=invite.data.id;
 const accepted=await rpc(b,'faceoff_call_action',{id,action:'accept'});assert.equal(accepted.status,200,JSON.stringify(accepted.data));
 const match=accepted.data.match_id;assert.ok(match);
 assert.ok((await join(wx,match)).error,'stranger denied entry');
 assert.ok((await join(wa,match)).match);
 assert.ok(!wa.messages.some(m=>m.match_data&&Number(m.match_data.op_code)===5&&JSON.parse(Buffer.from(m.match_data.data,'base64')).count===2),'one player cannot start');
 assert.ok((await join(wb,match)).match);
 for(const c of [wa,wb])await wait(()=>c.messages.find(m=>m.match_data&&Number(m.match_data.op_code)===5&&JSON.parse(Buffer.from(m.match_data.data,'base64')).count===2),'two-player ready');
 assert.equal((await rpc(b,'faceoff_message',{target:a.uid,text:'Hello'})).status,200,'recipient may reply');
 assert.equal((await rpc(a,'faceoff_call_action',{id,action:'end'})).data.status,'ended');
 const godot = execFileSync('godot',['--headless','--path','.','-s','tests/social_clients.gd'],{env:{...process.env,FACE_OFF_TEST_STORAGE_PREFIX:String(run),FACE_OFF_TEST_A:'faceoff-social-test-a-'+run,FACE_OFF_TEST_B:'faceoff-social-test-b-'+run,FACE_OFF_ONLINE_SERVER_KEY:'devserverkey'},timeout:30000,encoding:'utf8'});
 console.log(godot.trim());
 const mainFlow = execFileSync('godot',['--headless','--path','.','-s','tests/social_main.gd'],{env:{...process.env,FACE_OFF_TEST_STORAGE_PREFIX:String(run),FACE_OFF_DISABLE_NETWORK:'1',FACE_OFF_TEST_A:'faceoff-social-test-a-'+run,FACE_OFF_TEST_B:'faceoff-social-test-b-'+run,FACE_OFF_ONLINE_SERVER_KEY:'devserverkey'},timeout:30000,encoding:'utf8'});
 console.log(mainFlow.trim());
 console.log('PASS: verified discovery, invitation roles, decline/cancel, accepted-only match, stranger rejection, two-player readiness and replies');
} finally {for(const ws of sockets)ws.close();}
