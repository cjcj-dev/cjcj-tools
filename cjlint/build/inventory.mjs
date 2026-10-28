#!/usr/bin/env zx
// Extract obligations from the immutable reference, never from port status.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const base='271b2f4c20be309205eca5e58bb09ffa24727a64';
const git=(...args)=>execFileSync('git',args,{cwd:root,encoding:'utf8'});
const read=f=>git('show',`${base}:${f}`);
const files=git('ls-tree','-r','--name-only',base).trim().split('\n');
const checker='cjlint/src/checker/Checker.cpp';
const registrations=[...read(checker).matchAll(/RegisterRule<(\w+)>\("([^"]+)", CompileStage::(\w+)\)/g)].map(m=>({
  implementation:m[1],id:m[2],stage:m[3],registration:`${checker}:${read(checker).slice(0,m.index).split('\n').length}`,
  sources:files.filter(f=>f.startsWith('cjlint/src/rules/')&&f.includes(m[1])&&f.endsWith('.cpp'))
}));
const diagnostics=[...read('cjlint/src/common/DiagnosticsAll.def').matchAll(/^(MANDATORY|SUGGESTIONS)\((\w+), (".*")\)/gm)].filter(m=>!m[2].startsWith('mandatory_diag_')).map(m=>({level:m[1],name:m[2],message:JSON.parse(m[3])}));
const configs=Object.fromEntries(files.filter(f=>f.startsWith('cjlint/config/')&&f.endsWith('.json')).map(f=>[f,JSON.parse(read(f))]));
const defaultRules=configs['cjlint/config/cjlint_rule_list.json'].RuleList;
const ids=[...new Set(registrations.map(r=>r.id))];
const inventory={base,registrations,uniqueRuleCount:ids.length,defaultRules,diagnostics,configs,
  cli:{source:'cjlint/src/main.cpp',options:['-h','-v','-f','-e','-o','-r','-c','-m','--import-path'],reportFormats:['json','csv'],
    obligations:['directory packages and subpackages','config-relative exclusions and re-inclusion','source ignore comments','diagnostic exclusions by rule/path/line/column','compiler diagnostics and failures','report write failures','installed default config and modules resolution']},
  referenceTests:files.filter(f=>f.startsWith('tests/')&&f.includes('cjlint')),
  ruleSources:files.filter(f=>f.startsWith('cjlint/src/rules/')),
  coverage:ids.map(id=>({id,defaultEnabled:defaultRules.includes(id),stages:registrations.filter(r=>r.id===id).map(r=>r.stage),status:'NOT_PORTED_OR_NOT_VERIFIED'}))};
fs.mkdirSync(path.join(root,'cjlint/cangjie'),{recursive:true});
fs.writeFileSync(path.join(root,'cjlint/cangjie/reference-surface.json'),JSON.stringify(inventory,null,2)+'\n');
const quote=s=>JSON.stringify(s).replaceAll('${','\\${');
let cj='// Generated from the fixed reference by build/inventory.mjs.\npackage cjlint\n\n';
cj+=`let allRuleIds: Array<String> = [${ids.map(quote).join(', ')}]\n`;
cj+=`let defaultRuleIds: Array<String> = [${defaultRules.map(quote).join(', ')}]\n`;
cj+='\nfunc diagnosticMessage(kind: String): String {\n    return match (kind) {\n';
for(const d of diagnostics)cj+=`        case ${quote(d.name)} => ${quote(d.message)}\n`;
cj+='        case _ => throw Exception("Unknown diagnostic kind: " + kind)\n    }\n}\n';
cj+='\nfunc diagnosticLevel(kind: String): String {\n    return match (kind) {\n';
for(const d of diagnostics.filter(d=>d.level==='MANDATORY'))cj+=`        case ${quote(d.name)} => "MANDATORY"\n`;
cj+='        case _ => "SUGGESTIONS"\n    }\n}\n';
fs.mkdirSync(path.join(root,'cjlint/cangjie/src'),{recursive:true});
fs.writeFileSync(path.join(root,'cjlint/cangjie/src/Reference.cj'),cj);
console.log(JSON.stringify({base,registrations:registrations.length,rules:ids.length,defaults:defaultRules.length,diagnostics:diagnostics.length}));
