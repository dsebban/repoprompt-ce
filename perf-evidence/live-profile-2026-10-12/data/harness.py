import subprocess, json, time, sys, os, threading
sys.path.insert(0,'/tmp/rpce-prof/load')
D='/tmp/rpce-prof'
def t(*a):
    try:
        r=subprocess.run(['tern','ctl','--control','/tmp/rpce-tern.sock',*a],capture_output=True,text=True,timeout=15)
    except subprocess.TimeoutExpired:
        return {'timeout':True}
    try: return json.loads(r.stdout)
    except Exception: return {'raw':r.stdout,'err':r.stderr}
def zoomed():
    s=t('state');
    try: return s['tabs'][0]['zoomed']
    except Exception: return None
def setzoom(w):
    for _ in range(3):
        if zoomed()==w: return
        t('zoom'); time.sleep(0.8)
def pstate():
    s=t('state'); bl=s.get('profile_blocks',{}).get('blocks',[])
    return bl[-1] if bl else {}
CLI=os.path.expanduser("~/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli")
def drive(cmds,secs,log):
    end=time.time()+secs;i=0
    while time.time()<end:
        c=cmds[i%len(cmds)];i+=1
        t0=time.time();r=subprocess.run([CLI]+c,capture_output=True,text=True)
        log.append((c[3],round(time.time()-t0,3),r.returncode))
def snap(n):
    setzoom(True); t('shot',n); setzoom(False)
def scenario(name,cmds,terms,secs=15):
    out=open(f'{D}/evidence.jsonl','a')
    setzoom(False)
    t('procs','filter','RepoPrompt'); t('procs','select','RepoPrompt')
    # fresh procs focus needed
    t('profile','record')
    time.sleep(1.5)
    log=[]
    if cmds: drive(cmds,secs,log)
    else: time.sleep(secs)
    time.sleep(6)
    base=pstate()
    t('profile','idle','off'); t('profile','invert','off'); t('profile','zoom','root')
    snap(f'{name}__00_overview')
    rec={'scenario':name,'summary':base,'calls':log,'terms':{}}
    t('profile','invert','on'); snap(f'{name}__01_bottomup_selftime'); t('profile','invert','off')
    for term in terms:
        t('profile','find',term); st=pstate()
        t('profile','pick',term); t('profile','select',term)
        st2=pstate()
        safe=''.join(c if c.isalnum() else '_' for c in term)[:40]
        snap(f'{name}__t_{safe}')
        rec['terms'][term]={'functions_matching':st.get('functions'),'selected':st2.get('selected'),'picked':st2.get('picked'),'samples':st2.get('samples')}
        t('profile','pick','none')
    t('profile','find','')
    t('focus','left'); time.sleep(0.5)
    out.write(json.dumps(rec)+'\n'); out.close()
    print(name,json.dumps(rec)[:600],flush=True)
if __name__=='__main__':
    from drive import SC, call
    G=['posix_spawn','listWorktrees','parseGitDate']
    SC['e_code_structure_nosig']=[call("get_code_structure",{"paths":["Sources/RepoPrompt/Infrastructure/WorkspaceContext/"],"signatures":False})]
    T={
     'idle':(['listWorktrees','posix_spawn','parseGitDate','updateGitContextRefreshLoop','canonicalPath','waitForTerminationStatus','AgentRotatingTipsView','NSHostingView','commit_transaction','collect_animations'],25),
     'a_get_file_tree':(['get_file_tree','JSONEncoder','Regex','AG::Graph::UpdateStack::update'],15),
     'b_search_content_regex':(['SearchLineIndex','Regex','JSONEncoder','FileHandle'],15),
     'c_search_path':(['MCPRoutingStateStore','JSONEncoder','Regex','posix_spawn'],15),
     'd_read_file_large':(['Regex','JSONDecoder','JSONEncoder','MCPExternalEventsMonitor'],15),
     'e_code_structure_dir':(['scanLocked','openat','CodeMapRootManifestStore','Regex'],15),
     'e_code_structure_nosig':(['scanLocked','openat','CodeMapRootManifestStore'],12),
     'f_workspace_context':(['AG::Graph::UpdateStack::update','MCPRoutingStateStore','Regex','JSONEncoder'],15),
     'g_git':(['posix_spawn','listWorktrees','parseGitDate','GitService'],15),
    }
    for n,(terms,secs) in T.items():
        scenario(n,SC.get(n),terms,secs)
