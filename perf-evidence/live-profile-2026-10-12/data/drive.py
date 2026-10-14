import subprocess, sys, time, os, json, statistics
CLI=os.path.expanduser("~/Library/Application Support/RepoPrompt CE/repoprompt_ce_cli")
PID=13579
L="/tmp/rpce-prof/load"
BIG=["Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift",
"Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift",
"Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift",
"Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift",
"Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift"]
def call(tool, args):
    return ["-w","3","-c",tool,"-j",json.dumps(args)]
SC={
 "a_get_file_tree":[call("get_file_tree",{"type":"files","mode":"full"})],
 "b_search_content_regex":[call("file_search",{"pattern":r"func\s+\w+.*async.*throws","mode":"content","max_results":200})],
 "c_search_path":[call("file_search",{"pattern":"*ViewModel*.swift","mode":"path","regex":False,"max_results":200})],
 "d_read_file_large":[call("read_file",{"path":p}) for p in BIG],
 "e_code_structure_dir":[call("get_code_structure",{"paths":["Sources/RepoPrompt/Infrastructure/WorkspaceContext/"]})],
 "f_workspace_context":[call("workspace_context",{})],
 "g_git":[call("git",{"op":"status"}),call("git",{"op":"diff","compare":"uncommitted","detail":"files"}),call("git",{"op":"log"})],
}
def ps():
    o=subprocess.run(["ps","-p",str(PID),"-o","%cpu=,rss="],capture_output=True,text=True).stdout.split()
    return o
def run(name):
    cmds=SC[name]
    pre=ps()
    sp=subprocess.Popen(["sample",str(PID),"10","1","-file",f"{L}/{name}.txt"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    t_end=time.time()+9.5
    lat=[];errs=0;sizes=[]
    i=0
    while time.time()<t_end:
        c=cmds[i%len(cmds)];i+=1
        t=time.time()
        r=subprocess.run([CLI]+c,capture_output=True,text=True)
        d=time.time()-t
        ok=r.returncode==0 and not r.stdout.startswith("Error")
        if not ok: errs+=1
        lat.append((c[3],round(d,3),ok,len(r.stdout)))
    post_during=ps()
    sp.wait()
    post=ps()
    json.dump({"name":name,"pre":pre,"during_end":post_during,"post":post,"calls":lat,"errs":errs},open(f"{L}/{name}.json","w"))
    ls=[x[1] for x in lat]
    print(name,"n=",len(ls),"min/med/max",min(ls),statistics.median(ls),max(ls),"errs",errs,"pre",pre,"end",post_during,"post",post,"bytes",lat[0][3],flush=True)
if __name__=="__main__":
    for n in sys.argv[1:]:
        run(n); time.sleep(3)
