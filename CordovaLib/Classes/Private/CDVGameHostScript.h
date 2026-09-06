/*
    Licensed to the Apache Software Foundation (ASF) under one
    or more contributor license agreements.  See the NOTICE file
    distributed with this work for additional information
    regarding copyright ownership.  The ASF licenses this file
    to you under the Apache License, Version 2.0 (the
    "License"); you may not use this file except in compliance
    with the License.  You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing,
    software distributed under the License is distributed on an
    "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
    KIND, either express or implied.  See the License for the
    specific language governing permissions and limitations
    under the License.
*/

static NSString *CDVGameHostScript(void)
{
    return @"(() => {"
    @"const pending = new Map(); let nextID = 0;"
    @"const send = body => window.webkit.messageHandlers.host.postMessage(body);"
    @"const decode = value => {"
    @" if (value && value.CDVType === 'ArrayBuffer') return Uint8Array.from(atob(value.data), c => c.charCodeAt(0)).buffer;"
    @" return value;"
    @"};"
    @"const receive = (id, status, value, keep) => {"
    @" const p = pending.get(id); if (!p) return;"
    @" if (status === 0 && keep) return;"
    @" const args = value && value.CDVType === 'MultiPart' ? value.messages.map(decode) : [decode(value)];"
    @" if (!p.stream || !keep) { pending.delete(id); clearTimeout(p.timer); }"
    @" if (status === 1) p.success(...args); else p.failure(value);"
    @"};"
    @"const start = (service, action, args, success, failure, stream, timeout) => {"
    @" const id = String(++nextID);"
    @" const cancel = () => { const p = pending.get(id); if (!p) return; pending.delete(id); clearTimeout(p.timer); send({type:'cancel',id}).catch(() => {}); if (!stream) failure({code:'CANCELLED',message:'Host call cancelled'}); };"
    @" const timer = timeout > 0 ? setTimeout(() => { if (!pending.has(id)) return; pending.delete(id); send({type:'cancel',id}).catch(() => {}); failure({code:'TIMEOUT',message:'Host call timed out'}); }, timeout) : null;"
    @" pending.set(id,{success,failure,stream,timer});"
    @" send({type:'plugin',id,service,action,args,stream}).catch(error => { if (!pending.has(id)) return; pending.delete(id); clearTimeout(timer); failure(error); });"
    @" return cancel;"
    @"};"
    @"const host = {"
    @" getLoadedPlugins: () => send({type:'plugins'}),"
    @" callPlugin: (service, action, args = [], timeout = 30000) => new Promise((resolve,reject) => start(service,action,args,resolve,reject,false,timeout)),"
    @" subscribePlugin: (service, action, args, success, failure = () => {}) => start(service,action,args,success,failure,true,0),"
    @" postMessage: message => send({type:'message',message}),"
    @" ready: () => send({type:'ready'}),"
    @" onmessage: null,"
    @" _receive: receive,"
    @" _message: message => { if (typeof host.onmessage === 'function') host.onmessage(message); }"
    @"};"
    @"Object.defineProperty(window,'host',{value:host,writable:false,configurable:false});"
    @"window.__$cognifit$__isWebViewClone = true;"
    @"})();";
}
