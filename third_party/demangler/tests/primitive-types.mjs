#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
const [binary, output] = process.argv.slice(2);
if (!binary || !output) throw Error('usage: node primitive-types.mjs <installed-cjfilt> <output>');
fs.mkdirSync(output, {recursive: true});
const cases = [
  {name:'bare-D-rejected', input:'D', valid:false},
  {name:'float16-control', input:'Dh', valid:true, type:'Float16'},
  {name:'int32-control', input:'i', valid:true, type:'Int32'},
];
const results = cases.map(item => {
  const argv=[binary,'-T','-l',item.input];
  const p=spawnSync(argv[0],argv.slice(1),{encoding:'utf8'});
  fs.writeFileSync(path.join(output,item.name+'.stdout'),p.stdout??'');
  fs.writeFileSync(path.join(output,item.name+'.stderr'),p.stderr??'');
  const validation=p.stdout?.match(/^validation:\s+(valid|invalid)$/m)?.[1];
  const type=p.stdout?.match(/^demangled:\s+(.+)$/m)?.[1];
  return {...item,argv,rc:p.status,signal:p.signal,error:p.error?.message??null,
    assertionReached:p.status===0&&validation!==undefined,
    pass:p.status===0&&validation===(item.valid?'valid':'invalid')&&(!item.type||type===item.type),validation,type};
});
fs.writeFileSync(path.join(output,'assertions.json'),JSON.stringify(results,null,2)+'\n');
console.log(JSON.stringify(results));
process.exitCode=results.every(row=>row.pass)?0:1;
