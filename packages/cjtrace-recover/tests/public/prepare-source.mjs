#!/usr/bin/env zx
// Dependency preparation contract; real compiler/CLI semantics are exercised
// separately by the normal producer and installed demangler consumers.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const work=fs.mkdtempSync(path.join(process.env.TMPDIR??os.tmpdir(),'trace-source-'));
const prepare=new URL('../../build/prepare-demangler.mjs',import.meta.url).pathname;
const before=`        if (MatchForward(MANGLE_FLOAT16_PREFIX, MANGLE_FLOAT16_PREFIX.size)) {
            SkipString(MANGLE_FLOAT16_PREFIX)
        } else {
            SkipChar(ch)
        }
        return DemangleInfo(GetPrimitiveDemangleMap(ch), DemanglerTypeKind.PRIMITIVE)
`;
const after=before.replace('            SkipChar(ch)',`            if (ch == b'D') {
                return Reject("invalid primitive type")
            }
            SkipChar(ch)`);
const rows=[],checks=[];
function check(name,fn){try{fn();checks.push({name,assertionExecuted:true,pass:true});}catch(error){checks.push({name,assertionExecuted:true,pass:false,error:String(error)});}fs.writeFileSync(work+'/assertions.json',JSON.stringify(checks,null,2));}
for(const [name,primitive,expected]of [['old-source',before,0],['upstream-source',after,0],['source-drift',after.replace('SkipChar(ch)','SkipUnexpected(ch)'),1]]) {
 const input=path.join(work,name),output=input+'-prepared';fs.mkdirSync(input);
 for(const file of ['CangjieDemangle','DeCompression','DemangleUtils'])fs.writeFileSync(input+'/'+file+'.cj','package cjcj::mangle\n// independent copied control\n');
 fs.writeFileSync(input+'/Demangler.cj',primitive);
 fs.writeFileSync(input+'/MangleUtils.cj','package cjcj::mangle\npublic let TEST_CONSTANT = 7\n'+['StartsWith','EndsWith','IsDigit','IsAlpha','IsAlnum','IsPrimitivePrefix'].map(n=>'public func '+n+'() { return true }').join('\n'));
 fs.writeFileSync(input+'/Compression.cj','public class StringRef { }\npublic class IntRef { }\n');
 const p=spawnSync(process.execPath,[prepare,input,output],{encoding:'utf8'});
 rows.push({name,argv:[process.execPath,prepare,input,output],rc:p.status,signal:p.signal,error:p.error?.message??null});
 fs.writeFileSync(work+'/'+name+'.stdout',p.stdout??'');fs.writeFileSync(work+'/'+name+'.stderr',p.stderr??'');fs.writeFileSync(work+'/commands.json',JSON.stringify(rows,null,2));
 check(name+' preparation result',()=>{assert.equal(p.signal,null,name);assert.equal(p.status,expected,name+' '+p.stderr);});
 check(name+' input original unchanged',()=>assert.equal(fs.readFileSync(input+'/Demangler.cj','utf8'),primitive));
 check(name+' independent copied control',()=>assert.equal(fs.readFileSync(output+'/DemangleUtils.cj','utf8'),fs.readFileSync(input+'/DemangleUtils.cj','utf8')));
 if(expected===0)check(name+' bare D guard and Dh branch',()=>assert.equal(fs.readFileSync(output+'/Demangler.cj','utf8'),after));
 else check(name+' source drift diagnostic',()=>assert.match(p.stderr,/source shape changed/));
}
assert(checks.every(c=>c.pass),'TRACE_SOURCE_PREPARATION_TARGET '+work);
console.log('TRACE_SOURCE_PREPARATION_PASS '+work);
