"""Build the separate, self-contained Token Lab. Does not change the main checkout."""
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess,sys,zipfile
from preservation_policy import apply_lab_preservation_policy

ROOT=Path(__file__).resolve().parent
MAIN=ROOT.parent
if not (MAIN/'backend').is_dir():
    MAIN=ROOT.parent/'main-snapshot'
if not (MAIN/'backend').is_dir():
    raise RuntimeError('Token Lab needs the adjacent Grabber source or main-snapshot folder.')
OUT=(ROOT/'dist') if MAIN.name=='main-snapshot' else MAIN/'dist'/'token-lab-v0.1.3'
STAGE=ROOT/'build'/'runtime'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def main():
    version=re.search(r'const string Version="(\d+\.\d+\.\d+)"', (ROOT/'Lab.cs').read_text(encoding='utf-8-sig')).group(1)
    OUT.mkdir(parents=True,exist_ok=True)
    STAGE.mkdir(parents=True,exist_ok=True)
    shutil.copytree(MAIN/'backend',STAGE/'backend',dirs_exist_ok=True)
    ui_files=['GuiBackend.ps1','InstalledGames.ps1','App.ico']
    if (MAIN/'src/ui/ReceiptStorage.ps1').exists():
        ui_files.append('ReceiptStorage.ps1')
    for name in ui_files:
        shutil.copy2(MAIN/'src/ui'/name,STAGE/name)
    shutil.copy2(ROOT/'Runner.ps1',STAGE/'Runner.ps1')
    (STAGE/'BACKEND_VERSION').write_text((MAIN/'VERSION').read_text().strip(),encoding='utf-8')
    sys.path.insert(0,str(MAIN/'tools'))
    import runtime_layout
    import package_policy
    import exe_metadata
    files=runtime_layout.prepare(MAIN,STAGE)
    apply_lab_preservation_policy(files)
    files += [STAGE/n for n in ui_files+['Runner.ps1','BACKEND_VERSION']]
    # Fixed source-owned allowlist. No results, receipts, credentials or mutable runtime locks.
    assert len(set(files))==len(files)
    payload=ROOT/'build'/'payload.zip'
    with zipfile.ZipFile(payload,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        for file in sorted(files):
            assert file.name.lower() not in ('pop.bin','issued-token.xml','registration.lock','appxmanifest.xml')
            z.writestr(file.relative_to(STAGE).as_posix(),file.read_bytes())
    csc=Path(os.environ['WINDIR'])/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    exe=OUT/('GFW8 Token Lab v'+version+'.exe')
    info=exe_metadata.assembly_info(ROOT/'build/AssemblyInfo.cs','GFW8 Token Lab',
        'Developer receipt and Xbox token diagnostics',version)
    subprocess.run([str(csc),'/nologo','/target:winexe','/platform:x64','/optimize+',
        '/win32icon:'+str(STAGE/'App.ico'),'/reference:System.Windows.Forms.dll',
        '/reference:System.Drawing.dll','/reference:System.Web.Extensions.dll',
        '/reference:System.IO.Compression.dll','/resource:'+str(payload)+',Lab.Payload',
        '/out:'+str(exe),str(ROOT/'Lab.cs'),str(ROOT/'MetroChrome.cs'),str(info)],check=True)
    details=exe_metadata.verify(exe,'GFW8 Token Lab',version)
    (OUT/'FILE-DETAILS.json').write_text(json.dumps([details],indent=2)+'\n',encoding='utf-8')
    subprocess.run([str(exe),'--verify-bundle',str(ROOT/'build'/'verified.json')],check=True)
    subprocess.run([str(exe),'--self-test'],check=True)
    ps=Path(os.environ['WINDIR'])/'System32/WindowsPowerShell/v1.0/powershell.exe'
    subprocess.run([str(ps),'-NoProfile','-ExecutionPolicy','Bypass','-File',str(ROOT/'Test-Preservation.ps1'),'-Runtime',str(STAGE)],check=True)
    subprocess.run([str(ps),'-NoProfile','-ExecutionPolicy','Bypass','-File',str(ROOT/'Test-Lab.ps1'),'-Runtime',str(STAGE)],check=True)
    subprocess.run([str(ps),'-NoProfile','-ExecutionPolicy','Bypass','-File',str(ROOT/'Test-ReceiptBatch.ps1'),'-Runtime',str(STAGE)],check=True)
    shutil.copy2(ROOT/'README.txt',OUT/'README.txt')
    shutil.copy2(MAIN/'THIRD-PARTY-NOTICES.md',OUT/'THIRD-PARTY-NOTICES.md')
    provenance={'version':version,'backendVersion':(MAIN/'VERSION').read_text().strip(),
        'exeSha256':sha(exe),'payloadSha256':sha(payload),
        'backendFiles':{p.relative_to(STAGE).as_posix():sha(p) for p in files},
        'checks':['bundle verification','UI event/default-sign-in/stop-request fixtures','offline preservation fixtures','offline batch/report/cleanup fixtures','offline receipt pacing/cooldown/throttle/cancellation fixtures']}
    (OUT/'BUILD-INFO.json').write_text(json.dumps(provenance,indent=2)+'\n',encoding='utf-8')
    with zipfile.ZipFile(OUT/'GFW8-Token-Lab-Source.zip','w',zipfile.ZIP_DEFLATED) as z:
        for name in ['Lab.cs','MetroChrome.cs','Runner.ps1','build.py','Test-Lab.ps1','Test-ReceiptBatch.ps1','README.txt','preservation_policy.py','Test-Preservation.ps1']:
            z.write(ROOT/name,'token-lab/'+name)
        for name in ui_files:
            z.write(MAIN/'src/ui'/name,'main-snapshot/src/ui/'+name)
        for file in package_policy.inputs(MAIN,'backend'):
            z.write(file,'main-snapshot/backend/'+file.relative_to(MAIN/'backend').as_posix())
        for name in ['VERSION','THIRD-PARTY-NOTICES.md']:
            z.write(MAIN/name,'main-snapshot/'+name)
        z.write(MAIN/'tools/runtime_layout.py','main-snapshot/tools/runtime_layout.py')
        z.write(MAIN/'tools/package_policy.py','main-snapshot/tools/package_policy.py')
        z.write(MAIN/'tools/package-inputs.json','main-snapshot/tools/package-inputs.json')
        z.write(MAIN/'tools/exe_metadata.py','main-snapshot/tools/exe_metadata.py')
    print(json.dumps({'exe':str(exe),'bytes':exe.stat().st_size,'sha256':sha(exe)}))
if __name__=='__main__':main()
