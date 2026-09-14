local nk = require('nakama')
local M = {}
local function fail(message,code) error({message,code or 13}) end
local function read(collection, key, user)
    return nk.storage_read({{collection=collection,key=key,user_id=user}})[1]
end
local function write(collection,key,user,value,version)
    return nk.storage_write({{collection=collection,key=key,user_id=user,value=value,version=version,permission_read=0,permission_write=0}})
end
local function phone(raw)
    local p = tostring(raw or ''):gsub('[%s%(%)%-%.]','')
    if p:sub(1,2)=='00' then p='+'..p:sub(3) end
    if not p:match('^%+[1-9]%d+$') or #p<9 or #p>16 then fail('Use a full phone number with country code',3) end
    return p
end
local function profile(user)
    local obj=read('profiles','phone',user)
    if not obj then fail('Verify your phone number in Profile first',7) end
    return obj.value
end
local function invite_token(raw)
    local token=tostring(raw or '')
    -- UUID v4 tokens are opaque, high-entropy handles. Keep the parser strict so
    -- callers cannot turn the resolver into an arbitrary storage lookup.
    if not token:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89aAbB]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') then
        fail('Invite link is invalid',3)
    end
    return token
end
local function limit(user,key,seconds,max)
    local obj=read('rate_limits',key,user)
    local v=obj and obj.value or {start=0,count=0}
    if os.time()-v.start>=seconds then v={start=os.time(),count=0} end
    if v.count>=max then fail('Please wait before trying again',8) end
    v.count=v.count+1
    write('rate_limits',key,user,v,obj and obj.version or '*')
end
-- Keep a conservative, server-side euro estimate in addition to the provider's
-- billing controls. This is a protective circuit breaker, not a statement of
-- Twilio's final invoice amount. The month key is UTC so every Nakama node
-- shares the same bucket when the database is replicated. The storage key keeps
-- its old name for compatibility with already-deployed budget records.
local function charge_verification(context)
    local env=context.env or {}
    local limit_eur=tonumber(env.FACE_OFF_SMS_BUDGET_EUR or '10') or 10
    local alert_eur=tonumber(env.FACE_OFF_SMS_ALERT_EUR or '6') or 6
    local estimate_eur=tonumber(env.FACE_OFF_SMS_ESTIMATE_EUR or '0.20') or 0.20
    if limit_eur<=0 or alert_eur<0 or estimate_eur<=0 or alert_eur>limit_eur then
        fail('Verification-message budget configuration is invalid',9)
    end
    local limit_cents=math.floor(limit_eur*100+0.5)
    local alert_cents=math.floor(alert_eur*100+0.5)
    local unit_cents=math.max(1,math.ceil(estimate_eur*100-0.000001))
    local month=os.date('!%Y-%m')
    local obj=read('billing','sms_budget',nil)
    local value=obj and obj.value or {}
    if value.month~=month then
        value={month=month,cents=0,alerted=false}
    end
    local before=tonumber(value.cents or 0) or 0
    local after=before+unit_cents
    if after>limit_cents then
        fail('Verification-message budget limit reached. Try again next month.',9)
    end
    local crossed=(not value.alerted and after>=alert_cents)
    value.cents=after
    value.alerted=value.alerted or crossed
    value.unit_cents=unit_cents
    value.limit_cents=limit_cents
    value.alert_cents=alert_cents
    write('billing','sms_budget',nil,value,obj and obj.version or '*')
    return {alert=crossed}
end
local function twilio(context,path,body)
    local env=context.env or {}
    local sid=env.TWILIO_ACCOUNT_SID or ''
    local secret=env.TWILIO_AUTH_TOKEN or ''
    local service=env.TWILIO_VERIFY_SERVICE_SID or ''
    if sid=='' or secret=='' or service=='' then fail('Phone verification is not configured on the server yet',9) end
    local code,headers,result=nk.http_request('https://verify.twilio.com/v2/Services/'..service..'/'..path,'POST',{
        ['Authorization']='Basic '..nk.base64_encode(sid..':'..secret),['Content-Type']='application/x-www-form-urlencoded'
    },body,10000)
    if code<200 or code>=300 then
        local provider_code=nil
        local ok,data=pcall(nk.json_decode,result or '')
        if ok and type(data)=='table' then provider_code=tonumber(data.code) end
        if provider_code==60605 then
            fail('Verification delivery is disabled for this destination country. Ask the server owner to enable it in Twilio or use a paid account.',9)
        elseif provider_code==60200 then
            fail('The phone number was rejected. Enter it in full international format.',3)
        elseif provider_code==60203 then
            fail('Too many verification attempts. Please wait before trying again.',8)
        elseif provider_code==60624 then
            fail('The Twilio trial verification limit was reached. Ask the server owner to upgrade the account.',9)
        end
        fail('Phone verification failed. Check the number or request a new code.',9)
    end
    return nk.json_decode(result)
end
local function verify_channel(context)
    local value=tostring((context.env or {}).TWILIO_VERIFY_CHANNEL or 'sms'):lower()
    if value~='sms' and value~='whatsapp' then
        fail('TWILIO_VERIFY_CHANNEL must be sms or whatsapp',9)
    end
    return value
end
nk.register_rpc(function(context,payload)
    local env=context.env or {}
    if not env.TWILIO_ACCOUNT_SID or env.TWILIO_ACCOUNT_SID=='' or not env.TWILIO_AUTH_TOKEN or env.TWILIO_AUTH_TOKEN=='' or not env.TWILIO_VERIFY_SERVICE_SID or env.TWILIO_VERIFY_SERVICE_SID=='' then
        fail('Phone verification is not configured on the server yet',9)
    end
    local d=nk.json_decode(payload)
    local p=phone(d.phone)
    local channel=verify_channel(context)
    limit(context.user_id,'sms',3600,5)
    limit(nil,'sms_global',86400,30)
    local budget=charge_verification(context)
    twilio(context,'Verifications','To=%2B'..p:sub(2)..'&Channel='..channel)
    return nk.json_encode({sent=true,channel=channel,budget_alert=budget.alert})
end,'faceoff_phone_send')
-- Custom authentication is exclusively phone + provider-verified OTP. No client
-- may authenticate merely by knowing another player's phone number.
nk.register_req_before(function(context,request)
    local account=request.account or {}
    local vars=account.vars or {}
    local p=phone(account.id)
    local code=tostring(vars.code or '')
    if not code:match('^%d%d%d%d%d%d$') then fail('Enter the six digit verification code',3) end
    limit(nil,'verify_'..nk.sha256_hash(p),60,6)
    local result=twilio(context,'VerificationCheck','To=%2B'..p:sub(2)..'&Code='..code)
    if result.status~='approved' then fail('Incorrect or expired verification code',7) end
    account.vars={name=tostring(vars.name or ''):sub(1,60)}
    account.id='phone:'..p
    request.account=account
    return request
end,'AuthenticateCustom')
nk.register_req_after(function(context,response,request)
    local p=phone((request.account.id or ''):gsub('^phone:',''))
    local user,username=nk.authenticate_custom('phone:'..p,nil,false)
    local old=read('profiles','phone',user)
    local name=old and old.value.name or 'Fighter'
    local vars=request.account.vars or {}
    if vars.name and #vars.name>0 then name=string.sub(vars.name,1,60) end
    write('profiles','phone',user,{phone=p,name=name})
    write('phone_directory',nk.sha256_hash(p),nil,{user_id=user,name=name})
end,'AuthenticateCustom')
nk.register_rpc(function(context,payload)
    local obj=read('profiles','phone',context.user_id)
    return nk.json_encode({profile=obj and obj.value or false,user_id=context.user_id,video_available=false,voice_available=true})
end,'faceoff_profile')
nk.register_rpc(function(context,payload)
    profile(context.user_id)
    limit(context.user_id,'discovery',60,10)
    local d=nk.json_decode(payload)
    local found={}
    for _,raw in ipairs(d.phones or {}) do
        local ok,p=pcall(phone,raw)
        if ok then
            local obj=read('phone_directory',nk.sha256_hash(p),nil)
            if obj and obj.value.user_id~=context.user_id then
                table.insert(found,{phone=p,user_id=obj.value.user_id,name=obj.value.name})
                write('contacts',obj.value.user_id,context.user_id,{user_id=obj.value.user_id,name=obj.value.name})
            end
        end
    end
    return nk.json_encode({contacts=found})
end,'faceoff_contacts')
-- Create a short-lived opaque invite handle. The phone number stays in private
-- server storage instead of being embedded in an SMS link or URL.
nk.register_rpc(function(context,payload)
    local me=profile(context.user_id)
    local d=nk.json_decode(payload)
    local p=phone(d.phone)
    limit(context.user_id,'invite_link',60,12)
    local token=nk.uuid_v4()
    local expires=os.time()+86400
    write('invite_links',token,nil,{phone=p,inviter=context.user_id,inviter_name=tostring(me.name or 'Friend'):sub(1,60),expires=expires},'*')
    return nk.json_encode({token=token,expires=expires})
end,'faceoff_invite_link')
-- Resolve an invite on the recipient's device-authenticated session. Resolving
-- only pre-fills the number; AuthenticateCustom still requires a fresh OTP.
nk.register_rpc(function(context,payload)
    local d=nk.json_decode(payload)
    local token=invite_token(d.token)
    limit(context.user_id,'invite_resolve',60,30)
    local obj=read('invite_links',token,nil)
    if not obj or not obj.value or tonumber(obj.value.expires or 0)<os.time() then
        fail('Invite link has expired',5)
    end
    local value=obj.value
    return nk.json_encode({phone=phone(value.phone),inviter_name=tostring(value.inviter_name or 'Friend'):sub(1,60),expires=tonumber(value.expires)})
end,'faceoff_invite_resolve')
local function notify(user,content,sender)
    nk.notification_send(user,'Faceoff',content,101,sender,true)
end
-- Claiming an invite is allowed only after the recipient has completed phone
-- authentication. It creates the same mutual contact records as discovery, so
-- the inviter can call immediately without importing contacts again.
nk.register_rpc(function(context,payload)
    local me=profile(context.user_id)
    local d=nk.json_decode(payload)
    local token=invite_token(d.token)
    limit(context.user_id,'invite_claim',60,6)
    local obj=read('invite_links',token,nil)
    if not obj or not obj.value or tonumber(obj.value.expires or 0)<os.time() then
        fail('Invite link has expired',5)
    end
    local value=obj.value
    local recipient_phone=phone(me.phone)
    if recipient_phone~=phone(value.phone) then
        fail('Invite is for a different phone number',7)
    end
    local inviter=tostring(value.inviter or '')
    if inviter=='' or inviter==context.user_id then
        return nk.json_encode({claimed=false})
    end
    write('contacts',inviter,context.user_id,{user_id=inviter,name=tostring(value.inviter_name or 'Friend'):sub(1,60),phone=recipient_phone})
    write('contacts',context.user_id,inviter,{user_id=context.user_id,name=tostring(me.name or 'Fighter'):sub(1,60),phone=recipient_phone})
    notify(inviter,{type='contact',user_id=context.user_id,name=tostring(me.name or 'Fighter'):sub(1,60),phone=recipient_phone},context.user_id)
    return nk.json_encode({claimed=true,user_id=inviter,name=tostring(value.inviter_name or 'Friend'):sub(1,60)})
end,'faceoff_invite_claim')
nk.register_rpc(function(context,payload)
    local me=profile(context.user_id)
    local d=nk.json_decode(payload)
    local target=tostring(d.target or '')
    if target==context.user_id or not read('contacts',target,context.user_id) then fail('Select an imported Faceoff contact',7) end
    profile(target)
    limit(context.user_id,'invite',60,6)
    if d.kind=='video' then fail('Face video is not available yet',9) end
    local function reserve(user,id)
        local old=read('active_call','current',user)
        if old then
            local prev=read('calls',old.value.id,nil)
            if not prev and old.value.reserved_until and old.value.reserved_until>os.time() then fail('Call request is already in progress',9) end
            if prev and ((prev.value.status=='ringing' and prev.value.expires>os.time()) or (prev.value.status=='accepted' and os.time()<prev.value.expires+3600)) then
                fail('This person is already in a call',9)
            end
        end
        write('active_call','current',user,{id=id,reserved_until=os.time()+3},old and old.version or '*')
    end
    local id=nk.uuid_v4()
    reserve(context.user_id,id)
    reserve(target,id)
    local call={id=id,caller=context.user_id,callee=target,caller_name=me.name,status='ringing',expires=os.time()+60,kind=d.kind or 'call'}
    write('calls',id,nil,call,'*')
    write('contacts',context.user_id,target,{user_id=context.user_id,name=me.name})
    notify(target,{type='call',call=call},context.user_id)
    return nk.json_encode(call)
end,'faceoff_call_invite')
nk.register_rpc(function(context,payload)
    profile(context.user_id)
    local d=nk.json_decode(payload)
    local obj=read('calls',tostring(d.id),nil)
    if not obj then fail('Call no longer exists',5) end
    local call=obj.value
    if context.user_id~=call.caller and context.user_id~=call.callee then fail('Not your call',7) end
    local action=d.action or 'status'
    if call.status=='ringing' and os.time()>call.expires then call.status='expired' end
    if action=='end' and call.status=='ended' then return nk.json_encode(call) end
    if action=='end' and call.status=='accepted' then
        call.status='ended'
        local ok=pcall(write,'calls',call.id,nil,call,obj.version)
        if not ok then
            local latest=read('calls',call.id,nil)
            if latest and latest.value.status=='ended' then return nk.json_encode(latest.value) end
            fail('Call changed; please retry',9)
        end
        if call.match_id then pcall(nk.match_signal,call.match_id,'end') end
        notify(call.caller,{type='call',call=call},context.user_id)
        notify(call.callee,{type='call',call=call},context.user_id)
        return nk.json_encode(call)
    end
    if action~='status' then
        if call.status~='ringing' then fail('Call is already '..call.status,9) end
        if action=='accept' or action=='decline' then
            if context.user_id~=call.callee then fail('Only the recipient can answer',7) end
            call.status=action=='accept' and 'accepted' or 'declined'
        elseif action=='cancel' then
            if context.user_id~=call.caller then fail('Only the caller can cancel',7) end
            call.status='cancelled'
        else fail('Invalid call action',3) end
        -- Reserve transition atomically before allocating a match. Concurrent
        -- accept/cancel cannot both succeed or create duplicate matches.
        local versions=write('calls',call.id,nil,call,obj.version)
        if call.status=='accepted' then
            call.match_id=nk.match_create('faceoff_match',{allowed_users={call.caller,call.callee},call_id=call.id})
            write('calls',call.id,nil,call,versions[1].version)
        end
        notify(call.caller,{type='call',call=call},context.user_id)
        notify(call.callee,{type='call',call=call},context.user_id)
    end
    return nk.json_encode(call)
end,'faceoff_call_action')
nk.register_rpc(function(context,payload)
    local me=profile(context.user_id)
    local d=nk.json_decode(payload)
    local target=tostring(d.target or '')
    if not read('contacts',target,context.user_id) then fail('Select an imported Faceoff contact',7) end
    limit(context.user_id,'message',60,30)
    local text=tostring(d.text or ''):sub(1,1000)
    if text=='' then fail('Message is empty',3) end
    write('contacts',context.user_id,target,{user_id=context.user_id,name=me.name})
    local message={id=nk.uuid_v4(),type=d.ping and 'ping' or 'message',sender=context.user_id,name=me.name,text=text,time=os.time()}
    notify(target,message,context.user_id)
    return nk.json_encode(message)
end,'faceoff_message')
-- Public link APIs must not allow claiming a phone identity without OTP.
for _,hook in ipairs({'LinkCustom','UnlinkCustom'}) do
    nk.register_req_before(function() fail('Phone identity linking is not available',7) end,hook)
end
nk.register_rpc(function(context,payload)
    profile(context.user_id)
    local objects=nk.storage_list(context.user_id,'contacts',100)
    local contacts={}
    for _,obj in ipairs(objects) do table.insert(contacts,obj.value) end
    return nk.json_encode({contacts=contacts})
end,'faceoff_inbox')
return M
