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
const archiveName='9ba626afa44a3aa3.patch_0';
const listFiles=directory=>fs.readdirSync(directory,{recursive:true,withFileTypes:true}).filter(e=>e.isFile()).map(e=>path.relative(directory,path.join(e.parentPath||e.path,e.name)).replaceAll('\\','/')).sort();
const digest=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const expected=new AdmZip(release);
const names=['','.stream','.gpu_resources'].map(s=>archiveName+s);
function verify(){
 assert.deepEqual(listFiles(data),names.slice().sort());
 for(const name of names)assert.equal(digest(fs.readFileSync(path.join(data,name))),digest(expected.readFile('data/'+name)));
 assert.equal(listFiles(path.join(game,'bin')).length,0);
}
async function verifyPresentation(mod, packageZip) {
 const manifest=JSON5.parse(packageZip.readAsText('manifest.json'));
 const unpacked=mod.path;
 const packIcon=await icons.getModPackIcon(unpacked);
 const optionIcon=await icons.getOptionIconPath(unpacked,manifest.Options[0].Image);
 assert(packIcon && optionIcon,'Arsenal must resolve both images');
 assert.equal(digest(fs.readFileSync(packIcon)),digest(packageZip.readFile(manifest.IconPath)));
 assert.equal(digest(fs.readFileSync(optionIcon)),digest(packageZip.readFile(manifest.Options[0].Image)));
 assert.equal(mod.label,manifest.Name);
 assert.equal(mod.options[0].name,manifest.Options[0].Name);
 assert.equal(mod.description,manifest.Description);
 assert.equal(mod.iconPath,packIcon);
 assert.equal(mod.options[0].iconPath,optionIcon);
}
(async()=>{
 const imported=await handler.processAndValidateZipsFromRenderer(library,[release]);
 assert.equal(records.modsList.length,1);
 const mod=records.modsList[0];mod.enabled=true;
 await verifyPresentation(mod,expected);
 assert.equal(mod.options.length,1);assert.equal(mod.options[0].enabled,true);
 records.modsLibrary=[mod];records.data.test.mods=[mod];
 let deployed=await deployer.deployMod(mod.uuid,[mod],data,temp,state,[mod]);
 assert.equal(deployed[0].deployed,true);verify();
 await remover.purgeMods();assert.equal(listFiles(game).length,0);
 mod.enabled=false;
 await deployer.deployMod(mod.uuid,[mod],data,temp,state,[mod]);assert.equal(listFiles(game).length,0);
 mod.enabled=true;
 await deployer.deployMod(mod.uuid,[mod],data,temp,state,[mod]);verify();
 mod.patchFileNames=listFiles(data);
 await remover.removeInstalledMod(0,'test');assert.equal(listFiles(game).length,0);
 const result={manager_version:'0.36.0',imported:true,artwork_and_descriptions_verified:true,deployed_files_verified_byte_for_byte:true,disable_reenable_remove:true,custom_dlls:0,game_launched:false,live_profile_changed:false,release_sha256:digest(fs.readFileSync(release))};
 fs.writeFileSync(path.join(base,'arsenal-compatibility.json'),JSON.stringify(result,null,2));
 console.log(JSON.stringify(result,null,2));
})().catch(error=>{fs.writeFileSync(path.join(fixture,'backend-log.json'),JSON.stringify(logs,null,2));console.error(error);process.exitCode=1;});
