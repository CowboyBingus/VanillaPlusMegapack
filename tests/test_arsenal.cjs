// Runs the installed manager backend against an isolated filesystem and profile.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const crypto = require('crypto');
const source = path.resolve(process.argv[3]);
const base = path.resolve(process.argv[4]);
fs.mkdirSync(base, {recursive: true});
const fixture = path.join(base, 'manager-fixture-' + crypto.randomUUID());
assert(!fs.existsSync(fixture), 'Fixture already exists; inspect before retrying.');
const fsExtra = require(path.join(source, 'node_modules/fs-extra'));
const extractZip = require(path.join(source, 'node_modules/extract-zip'));
const AdmZip = require(path.join(source, 'node_modules/adm-zip'));
const JSON5 = require(path.join(source, 'node_modules/json5'));
const game = path.join(fixture, 'Helldivers 2');
const data = path.join(game, 'data');
const library = path.join(fixture, 'library');
const temp = path.join(fixture, 'temp');
const state = path.join(fixture, 'state');
for (const folder of [data, path.join(game, 'bin'), library, temp, state]) fs.mkdirSync(folder, {recursive:true});
const records = {modsList:[], modsLibrary:[], userModsDir:library, userGameDir:game,
  selectedProfile:'test', dataPath:state, setModsActive:true, setAllOptionsActive:true, data:{test:{mods:[]}}};
const logs = [];
const localConsole = Object.fromEntries(['log','warn','error'].map(level=>[level,(...args)=>logs.push({level,message:args.map(String).join(' ')})]));
const utils = {
  readData:(key,all)=>{logs.push({config_read:key,all:!!all});return all?records.data:records[key];},
  writeData:(key,value)=>{records[key]=value;fs.writeFileSync(path.join(state, 'settings.json'),JSON.stringify(records,null,2));},
  cleanFileName:value=>value.replace(/[<>:"/\\|?*]/g,'_'),
  generateUniqueFileName:(name,extension,directory)=>{let result=name,n=1;while(fs.existsSync(path.join(directory,result+extension)))result=name+'-'+n++;return result;},
  stripBOM:value=>value.replace(/^\uFEFF/,''),
  forceDeletePath:async target=>{assert(path.resolve(target).startsWith(fixture+path.sep));await fsExtra.remove(target);},
};
const localDB = {initialized:true, removeModHeaders:()=>true};
const cache = new Map();
function load(relative) {
  const absolute=path.join(source,'obfuscated_src/main',relative);
  if(cache.has(absolute))return cache.get(absolute).exports;
  const module={exports:{}};cache.set(absolute,module);
  function localRequire(name) {
    if(['fs','path','crypto'].includes(name))return require(name);
    if(name==='fs-extra')return fsExtra;
    if(name==='extract-zip')return extractZip;
    if(name==='adm-zip')return AdmZip;
    if(name==='json5')return JSON5;
    if(name==='electron')return {dialog:{showOpenDialog:async()=>{throw new Error('Unexpected UI access');}}};
    if(name.endsWith('/utils')||name==='./utils')return utils;
    if(name.endsWith('/constants'))return {MODS_DIR:library,DATA_PATH:state};
    if(name.endsWith('/LocalDB'))return localDB;
    if(['node-unrar-js','node-7z','7zip-min','7zip-bin'].includes(name))return {};
    if(name.startsWith('.')) {
      const resolved=path.relative(path.join(source,'obfuscated_src/main'),path.resolve(path.dirname(absolute),name+'.js'));
      return load(resolved);
    }
    throw new Error('Unexpected dependency: '+name);
  }
  const context=vm.createContext({module,exports:module.exports,require:localRequire,console:localConsole,
    process:{platform:process.platform,env:{DEV:'true'},resourcesPath:''},Buffer,setTimeout,clearTimeout});
  new vm.Script(fs.readFileSync(absolute,'utf8'),{filename:absolute}).runInContext(context,{timeout:5000});
  return module.exports;
}
const handler=load('modsHandler.js');
const icons=load('modules/iconHandler.js');
const deployer=load('modules/modDeployer.js');
const remover=load('modules/modRemover.js');
const gameState=load('modules/gameStateManager.js');
const release=path.resolve(process.argv[2]);
const listFiles=directory=>fs.readdirSync(directory,{recursive:true,withFileTypes:true}).filter(e=>e.isFile()).map(e=>path.relative(directory,path.join(e.parentPath||e.path,e.name)).replaceAll('\\','/')).sort();
const digest=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const expected=new AdmZip(release);
const manifest=JSON5.parse(expected.readAsText('manifest.json'));
const archiveName='9ba626afa44a3aa3.patch_';
// An option's archives in deployment order: its patch_N files by N (Mod Bindings Menu has two).
const archivesOf=option=>expected.getEntries().map(e=>e.entryName)
 .filter(name=>name.startsWith(option.Include[0]+'/'+archiveName)&&/_\d+$/.test(name))
 .sort((a,b)=>Number(a.split('_').pop())-Number(b.split('_').pop()));
function verify(mask) {
 const archives=manifest.Options.filter((_,i)=>mask & (1<<i)).flatMap(archivesOf);
 assert.equal(listFiles(data).length,archives.length*3);
 archives.forEach((archive,index)=>{
  for(const suffix of ['', '.stream', '.gpu_resources']) {
   const actual=fs.readFileSync(path.join(data,archiveName+index+suffix));
   const original=expected.readFile(archive+suffix);
   assert.equal(digest(actual),digest(original));
  }
 });
 assert.equal(listFiles(path.join(game,'bin')).length,0);
}
(async()=>{
 await handler.processAndValidateZipsFromRenderer(library,[release]);
 assert.equal(records.modsList.length,1);
 const mod=records.modsList[0];mod.enabled=true;
 const optionCount=manifest.Options.length;
 const fullMask=(1<<optionCount)-1;
 assert.equal(mod.options.length,optionCount);
 assert.equal(mod.label,manifest.Name);
 assert.equal(mod.description,manifest.Description);
 assert.equal(digest(fs.readFileSync(await icons.getModPackIcon(mod.path))),digest(expected.readFile(manifest.IconPath)));
 for(let i=0;i<optionCount;i++) {
  assert.equal(mod.options[i].name,manifest.Options[i].Name);
  assert.equal(mod.options[i].description,manifest.Options[i].Description);
  assert.equal(mod.options[i].enabled,true);
  assert.equal(digest(fs.readFileSync(mod.options[i].iconPath)),digest(expected.readFile(manifest.Options[i].Image)));
 }
 records.modsLibrary=[mod];records.data.test.mods=[mod];
 // Start with everything, then remove all, each singleton, each complement,
 // and every remaining subset. This catches stale files after changing options.
 const masks=[fullMask,0,...Array.from({length:fullMask+1},(_,i)=>i)];
 for(const mask of masks) {
  await remover.purgeMods();
  assert.equal(listFiles(game).length,0);
  mod.options.forEach((option,i)=>{option.enabled=!!(mask & (1<<i));});
  await deployer.deployMod(mod.uuid,[mod],data,temp,state,[mod]);
  verify(mask);
 }
 await remover.purgeMods();
 mod.enabled=false;
 await deployer.deployMod(mod.uuid,[mod],data,temp,state,[mod]);verify(0);
 mod.enabled=true;
 mod.options.forEach(option=>{option.enabled=true;});
 await deployer.deployMod(mod.uuid,[mod],data,temp,state,[mod]);verify(fullMask);
 mod.patchFileNames=listFiles(data);
 await remover.removeInstalledMod(0,'test');assert.equal(listFiles(game).length,0);
 const result={manager_version:'0.36.0',options:optionCount,all_subsets:true,subsets:fullMask+1,payloads_match:true,purge_reenable_remove:true,game_launched:false,live_profile_changed:false,release_sha256:digest(fs.readFileSync(release))};
 fs.writeFileSync(path.join(base,'arsenal-compatibility.json'),JSON.stringify(result,null,2));
 console.log(JSON.stringify(result,null,2));
})().catch(error=>{fs.writeFileSync(path.join(fixture,'backend-log.json'),JSON.stringify(logs,null,2));console.error(error);process.exitCode=1;});
